# Shifdr Routes: Events (build spec for Claude Code)

This adds **events** (group drives) to the Shifdr Routes website. An organizer picks a route, sets a date, meetup point and meal stop, and gets an invite link and code to share. Anyone with the link sees a public event page. Later, the Shifdr native app will read the same events and take over messaging, notifications and the live drive.

**Out of scope for this work:** connecting to the Shifdr app, push notifications, chat, live location, voice, universal links / deferred deep links. Leave clean seams for them (noted below), but don't build them.

Background: the product concept is the Claude doc "Shifdr Drives: Concept". This spec is the website part of it.

---

## 1. Ground rules (how this repo works)

- **One file.** The whole app is `index.html`: plain JS, no build step, no framework. Keep it that way. Add code in clearly marked sections next to the existing Discover code.
- **Libraries** load from CDNs with exact versions (MapLibre GL 4.7.1 from unpkg, supabase-js 2.45.4 from jsdelivr). Add one only if it's really needed. The QR code library below is the one expected addition.
- **Map:** raster tiles plus the existing canvas overlay for lines. Don't switch to vector tiles or GL line layers; the canvas overlay exists because workers fail on `file://`.
- **Backend:** Supabase project *Shifdr Routes* (`dmcgpfizozkkujboctac`). The anon key is already in `index.html`. All schema changes go in a new file in `supabase/migrations/`, named like `20261028000000_events.sql`, applied with the Supabase MCP `apply_migration`.
- **No destructive migrations.** Don't drop or rename existing tables, columns, policies or functions (`routes_in_view` stays even though it's unused). Use `alter policy` rather than drop and recreate.
- **No paid services.** No SMS, no paid email, no paid APIs.
- **Deletes:** only admins (`public.is_admin()`) can delete routes. Events follow the rule in §3.
- **Deploy:** `main` auto-deploys to https://shifdr-routes.vercel.app. Work on a branch (`events`). Apply the migration before merging, because the live site must never point at tables that don't exist yet. Merge to `main` only when everything in §9 passes.
- **Writing style in the UI:** short, plain labels, the same tone as the existing site. Times are shown in the event's time zone, e.g. "Sat, Nov 8 · 8:30 AM".

---

## 2. What to build, in order

1. Database: `events`, `event_people`, the RPCs, and RLS (§3).
2. Create and edit an event from a route page (§4).
3. Invite link and code, with share and QR (§5).
4. Public event page at `/e/<CODE>` (§6).
5. Roster on the website: join on the web and organizer-added people (§7).
6. Plan checks: lunch clock, road work on the event date, plan B notes (§8).
7. "My events" in the account panel, and "Previous drives" on route pages (§8.4).
8. README update and tests (§9).

Commit after each step.

---

## 3. Data model

### `public.events`
| column | type | notes |
|---|---|---|
| `id` | uuid pk | `gen_random_uuid()` |
| `code` | text unique not null | invite code, see §5 |
| `route_id` | uuid → `routes(id)` | `on delete restrict`, so a route with events can't be deleted |
| `route_snapshot` | jsonb not null | copy of the route's `shifdr.route/v1` record at creation, so later edits to the route don't change a planned drive. Store the **reversed** record if the organizer chose reverse. |
| `organizer_id` | uuid → `profiles(id)` | default `auth.uid()` |
| `title` | text not null | 1–120 chars; defaults to the route name |
| `description` | text | ≤ 2000 chars |
| `starts_at` | timestamptz not null | departure from the first meetup point |
| `time_zone` | text not null | IANA name, default `America/Chicago` |
| `meetups` | jsonb not null | array of 1–2 `{name, ll:[lng,lat], depart_at, note}`. The first is the main meetup; the second is optional ("Group 2 waits here"). |
| `meal` | jsonb | `{name, ll, mile, reservation:boolean, reservation_name, phone, last_seating_at, note}` |
| `regroups` | jsonb | array of `{name, ll, mile}`; default `[]` |
| `plan_b` | jsonb | array of `{mile_from, mile_to, text}`, e.g. "If FM 2434 is closed, take US 90 to Columbus, +12 min"; default `[]` |
| `status` | text | `draft` · `published` · `cancelled` · `finished`; default `draft` |
| `capacity_cars` | int | optional |
| `organizer_notes` | text | after-drive notes, ≤ 4000 chars |
| `actual_minutes` | int | optional, filled in after the drive |
| `created_at`, `updated_at` | timestamptz | trigger keeps `updated_at` current |

**Co-organizers:** `public.event_organizers (event_id, user_id, role text check (role in ('organizer','co')))`, pk `(event_id, user_id)`. When an event is created, a trigger inserts the creator as `organizer`. Helper: `public.is_event_organizer(eid uuid) returns boolean` (security definer, `search_path = ''`).

### `public.event_people` (the roster)
This is the table the Shifdr app will write to later. Design it for that.

| column | type | notes |
|---|---|---|
| `id` | uuid pk | |
| `event_id` | uuid → `events(id)` | `on delete cascade` |
| `user_id` | uuid → `profiles(id)` | null for people the organizer added by hand |
| `display_name` | text not null | |
| `phone` | text | only organizers can read it |
| `role` | text | `driver` · `passenger` |
| `car` | jsonb | drivers: `{year, make, model, color}` |
| `extra_people` | int | for drivers: passengers riding along who haven't joined themselves; default 0 |
| `rides_with` | uuid → `event_people(id)` | for passengers: whose car |
| `needs_ride` | boolean | passengers only |
| `seats_open` | int | drivers only |
| `meetup_index` | int | 0 or 1 |
| `rsvp` | text | `in` · `maybe` · `out`; default `in` |
| `source` | text | `web` · `organizer` · `app` (the app will use `app`) |
| `created_at`, `updated_at` | timestamptz | |

Unique `(event_id, user_id)` where `user_id` is not null.

**Counts:**
- cars = drivers with `rsvp = 'in'`
- people = those drivers + their `extra_people` + passengers with `rsvp = 'in'` whose `rides_with` is set or who need a ride

Put this logic in **one** SQL function, `public.event_counts(eid)`, returning `{cars, people, by_meetup:[{cars, people}]}`, so the website and the app count the same way.

### Security (RLS)
- Events must **not be listable** by the public. Nobody can browse all events; you need the code.
  - `events` select is allowed only for organizers, co-organizers and people on the roster.
  - Everyone else reads through `public.event_by_code(code text)`: security definer, `search_path = ''`, granted to `anon` and `authenticated`. It returns only `status in ('published','finished','cancelled')` events (drafts only to their organizers) and only safe fields: everything except `organizer_notes` (until finished), plus `event_counts`, the organizer's display name, and **for anon only counts**. Signed-in viewers also get the roster's first names and cars, never phone numbers.
- `events` insert: authenticated, `organizer_id = auth.uid()`, and the route must be public or owned by the user.
- `events` update: organizers and co-organizers only. `organizer_id`, `code`, `route_id` and `created_at` can't change (trigger, as `routes_set_geometry` does for owner).
- `events` delete: admins only. Organizers **cancel** instead.
- `event_people`:
  - Users can insert, update and delete their own row (`user_id = auth.uid()`), only on `published` events.
  - Organizers can insert, update and delete any row on their event, including people added by hand.
  - Select is allowed for your own row and for organizers (full rows, including phone). Everyone else gets names only, via `event_by_code`.
- Run the Supabase security and performance advisors after the migration and fix anything new.

---

## 4. Create and edit an event (website)

- **Entry point:** on a route page (Discover detail), when signed in, add **Plan a drive** next to *Open in builder*. If the route page is reversed, the event uses the reversed direction (say so in the form).
- **Event form** (in the side panel, the same style as the route page; mobile must work at 360 px wide):
  - **Title** (prefilled with the route name) and **Description**.
  - **Date** and **Departure time**; **Time zone** (default `America/Chicago`, from the browser if different).
  - **Meetup point:** prefilled with the route's Start (name and location). *Change* uses the existing place search or a map tap, the same as the Stops panel. **+ Add a second meetup point** (uncommon) adds name, location and "Group 2 waits here until Group 1 arrives" as the default note; departure time is computed (see §8) but editable.
  - **Meal stop:** choose one of the route's pit stops, or search a place. Fields: Reservation (yes/no), Name it's under, Restaurant phone, Last seating time, Note.
  - **Regroup points:** start with the route's other pit stops, and allow add and remove.
  - **Co-organizer:** optional. Add by email of an existing account; if the email isn't found, say "They need to sign in to Shifdr Routes once first."
  - **Car limit** (optional).
- **Buttons:** *Save draft* and *Publish*. Publishing shows the invite (§5). Organizers can edit a published event, but editing the date, time or meetup shows "Everyone on the roster will need to know. Messaging comes with the app; for now, share the update yourself." (Leave a function stub `notifyEventChange(event, changes)` that does nothing yet. This is the seam for app notifications.)
- **Cancel event:** status `cancelled`, with a reason; the event page shows it clearly.
- **Map:** while editing, show the route line plus markers for meetup(s), meal, regroups and plan B stretches. Reuse the existing marker styles.

---

## 5. Invite link and code

- **Code:** 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no 0/O, 1/I/L), generated in SQL on insert (retry on collision). Shown grouped as `K7Q-4MZ`; accept it typed in any case, with or without the dash.
- **Link:** `https://shifdr-routes.vercel.app/e/K7Q4MZ`.
  - Add `vercel.json` with a rewrite of `/e/:code` to `/index.html`. On load, read the code from the path, or from `?e=CODE` as a fallback that also works on `file://`.
  - The existing `?r=<route id>` links must keep working.
- **Share panel** after publishing, and on the event page for organizers:
  - the link, with **Copy link**;
  - the code;
  - **Share** (Web Share API when available, else copy);
  - a QR code of the link (use `qrcodejs` 1.0.0 from cdnjs, or another small library with a pinned version);
  - **Copy invite text**, ready to paste into a text or email:
    > Drive: Hill Country Loop · Sat, Nov 8 · Meet 8:30 AM at Buc-ee's Katy. Details and sign-up: https://shifdr-routes.vercel.app/e/K7Q4MZ (code K7Q-4MZ)
- **Seam for the app:** leave the `/e/` path free for the app's universal links later. Don't serve `apple-app-site-association` or `assetlinks.json` yet, and don't block those paths.

---

## 6. Public event page (`/e/<CODE>`)

This is what someone sees when they tap the invite, before they have the app. It must work signed out, on a phone, fast.

- **Layout:** the side panel on desktop, a bottom sheet on mobile (reuse the existing panel behavior). The map fits the route.
- **Header:** title; date and time in the event's time zone; status badge (*Cancelled* in red, *Finished* in gray); "Organized by Dan".
- **Meetup:**
  - name, departure time, **Directions** link (`https://www.google.com/maps/dir/?api=1&destination=lat,lng`) and an Apple Maps link;
  - if there's a second meetup: "Group 2 waits at Sealy Shell, about 9:05 AM".
- **Route summary:** miles, drive time, roads (reuse the route page pieces), **Export GPX** (from `route_snapshot`), and **Open route page**.
- **Meal stop:** name, planned arrival from the lunch clock (§8.1), "Reservation for 14 under Morton" when set.
- **Who's coming:**
  - signed out: "10 cars · 14 people";
  - signed in: the counts plus a list of first name and car ("Dan · 1973 911T, Silver").
- **Join:**
  - **Get the Shifdr app** buttons, placeholder store URLs from a constant `APP_LINKS = { ios: null, android: null }`. While null, show "The Shifdr app is coming soon" and hide the buttons.
  - **Join on the web** for now (§7).
- **Add to calendar:** download an `.ics` with the departure time, meetup location and the event link.
- **Road work:** a *Check road work for this date* button, using the existing `checkRoadWork` with the event's date and `route_snapshot` lines.
- **Bad or unknown code:** "We couldn't find that drive. Check the code with the organizer." plus a box to type a code.
- **Page title and share preview:** set `document.title` to the event title. Open Graph tags can't be per-event in a static page; leave a generic preview.

---

## 7. Roster on the website (until the app takes over)

- **Join on the web:**
  - The button signs you in (existing Google or email code), then shows a short form:
    - name (prefilled from the profile) and phone number (organizers only see it);
    - **Driver**, with car year, make, model and color, "+ passengers" and "seats open"; or **Passenger**, with whose car you're riding in (pick from the roster's drivers) or "need a ride";
    - meetup point, if there are two;
    - **I'm in** / **Maybe**.
  - Save the car to the profile, so the next event prefills it. Add `profiles.car jsonb` and `profiles.phone text` in the migration. Phone is readable only by its owner; add the policy.
  - After joining, show "You're in", with **Change** and **I can't make it** (sets `rsvp = 'out'`).
- **Organizer view** of the roster:
  - the full list with phones, grouped by meetup point, plus **car count and headcount per meetup point**;
  - "Need a ride" and "Seats open" side by side;
  - **+ Add someone**, for people who won't install or sign in: name, phone, role, car;
  - **Copy phone numbers**, so the organizer can start a group text from his own phone;
  - **Download roster (CSV)**.
- **Lock-in:** a toggle to close sign-ups (`status` stays `published`; add an `events.signups_closed boolean`).

---

## 8. Plan checks

### 8.1 Lunch clock
- **Planned arrival at the meal stop** = departure + router drive time from the meetup to the meal stop's mile + 10 minutes per regroup point before it.
  - Compute drive time to a mile from the segment durations in `route_snapshot`: walk the segments, accumulating distance and duration, and interpolate inside the segment that contains the mile.
  - Put this in one function, `etaAtMile(record, mile)`, reused for the second meetup.
- **Display:** "Arrive about 12:50 PM: 70 min before last seating (2:00 PM)".
  - Amber under 30 minutes of buffer; red under 15, or past last seating.
  - Show it on the event form (updating live as the time changes) and on the event page.
- **Second meetup:** its default departure is the ETA of group 1 at that point.

### 8.2 Road work on the event date
In the event form and on the event page, run `checkRoadWork` with the event date. In the form, list issues with their mile, and offer **Add plan B for this stretch**, which prefills `mile_from` and `mile_to`.

### 8.3 Plan B notes
A list of stretches (mile range plus text), shown on the event page as "If … then …" and highlighted on the map as a dashed amber section.

### 8.4 My events and Previous drives
- **Account panel → My events:**
  - **Upcoming** (organizing, and joined), then **Past**.
  - Each row shows title, date, car count and headcount, and status.
  - Rows open the event.
  - "Have a code?" box.
- **Route page → Previous drives:**
  - finished events on this route that the viewer is allowed to see, plus a count of all of them;
  - date, cars and people, planned vs. actual time;
  - organizer notes (once finished).
  - Use an RPC `route_drive_history(route_id)` (security definer) that returns only aggregate fields and notes, no names.
- **After the drive:**
  - Once `starts_at` is in the past, organizers see **Finish drive**: actual total time, notes ("CR 15A is gravel for about 3 miles, take FM 531 instead"), and status → `finished`.
  - Notes pinned to map locations are a later step; don't build them now.

---

## 9. Testing and done criteria

Test with Playwright, as before: headless Chromium is preinstalled, and `require('playwright')` works.

Test against the live Supabase project, using a throwaway test user, and clean up the test rows afterwards. Leave Dan's eight public routes untouched.

The work is done when all of these pass:

1. **Create:** a signed-in user plans a drive from a public route (normal and reversed), saves a draft, then publishes. The code is 6 characters from the allowed set, and the link opens the event.
2. **Private by design:**
   - anon `select * from events` returns nothing;
   - anon `event_by_code` on a valid code returns counts but no names or phones;
   - an invalid code returns nothing;
   - a draft code returns nothing to anyone but its organizers.
3. **Join on the web:** a second user joins as a driver with 1 extra person, and a third as a passenger in that car. The counts read 1 car, 3 people. "I can't make it" drops them.
4. **Organizer:**
   - sees phones;
   - adds a person by hand;
   - copies numbers;
   - downloads the CSV;
   - closes sign-ups (the join button then disappears for others);
   - cancels the event (the page shows Cancelled).
5. **Non-organizer:** can't edit the event or see phones, enforced by RLS (test with the REST API directly, not just the UI).
6. **Lunch clock:** for a route with a pit stop at a known mile, `etaAtMile` matches a hand calculation from the segment durations to within a minute. The amber and red thresholds show.
7. **Second meetup:** its default time equals group 1's ETA there; the event page shows "Group 2 waits at …".
8. **Links:**
   - `/e/CODE`, `/e/code-with-dash`, `?e=CODE` and `?r=<route id>` all work on the deployed preview;
   - unknown codes show the friendly message.
9. **Mobile:** at 360×740, the event page, form and roster have no horizontal scroll, and buttons are at least 40 px tall.
10. **Nothing broken:** the builder, Discover, ratings, reverse, GPX import and export, and the road check still work. Re-run the existing checks.
11. **Security:** the Supabase advisors show no new security warnings.
12. **Docs:** the README gets an **Events** section in the same style as the others.

---

## 10. Seams to leave for the Shifdr app (don't build)

- `event_people.source = 'app'`, and the `event_counts` function, are what the app will use.
- `notifyEventChange(event, changes)` is a no-op stub where push notifications will be sent from later.
- `APP_LINKS` holds the store URLs.
- The `/e/<code>` path is kept for universal and app links.
- Keep all event reads and writes in a small set of named functions (`getEventByCode`, `saveEvent`, `joinEvent`, `listMyEvents`), so pointing them at a shared backend later is one change.
