-- Events: group drives on a route, with an invite code and a roster.
-- Events can't be listed by the public. People on the roster and organizers read the table;
-- everyone else needs the code and reads through event_by_code.
-- The Shifdr app will later write the roster (event_people, source 'app') and count with event_counts.

-- Helpers used by the policies live here, outside the public API.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- Profiles: the car prefills the next sign-up; the phone is readable only by its owner.
alter table public.profiles add column car jsonb, add column phone text check (char_length(phone) <= 40);
-- Row-level security can't hide a column, so everyone else gets a column list without them.
revoke select on public.profiles from anon, authenticated;
grant select (id, display_name, created_at) on public.profiles to anon, authenticated;

create function public.my_private_profile() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('phone', p.phone, 'car', p.car) from public.profiles p where p.id = (select auth.uid());
$$;
revoke execute on function public.my_private_profile() from public, anon;
grant execute on function public.my_private_profile() to authenticated;

-- Invite codes are typed by hand, so 0/O and 1/I/L are left out. "k7q-4mz" and "K7Q4MZ" are the same code.
create function public.normalize_event_code(code text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$'),
  route_id uuid not null references public.routes (id) on delete restrict,
  route_snapshot jsonb not null check (route_snapshot ->> 'schema' = 'shifdr.route/v1' and octet_length(route_snapshot::text) < 5000000),
  organizer_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  description text check (char_length(description) <= 2000),
  starts_at timestamptz not null,
  time_zone text not null default 'America/Chicago',
  meetups jsonb not null check (jsonb_typeof(meetups) = 'array' and jsonb_array_length(meetups) between 1 and 2),
  meal jsonb check (meal is null or jsonb_typeof(meal) = 'object'),
  regroups jsonb not null default '[]' check (jsonb_typeof(regroups) = 'array'),
  plan_b jsonb not null default '[]' check (jsonb_typeof(plan_b) = 'array'),
  status text not null default 'draft' check (status in ('draft', 'published', 'cancelled', 'finished')),
  cancel_reason text check (char_length(cancel_reason) <= 500),
  signups_closed boolean not null default false,
  capacity_cars int check (capacity_cars > 0),
  organizer_notes text check (char_length(organizer_notes) <= 4000),
  actual_minutes int check (actual_minutes > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.events enable row level security;
create index events_route_idx on public.events (route_id, starts_at desc);
create index events_organizer_idx on public.events (organizer_id, starts_at desc);

-- Co-organizers. The creator is added as 'organizer' when the event is made.
create table public.event_organizers (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'co' check (role in ('organizer', 'co')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.event_organizers enable row level security;
create index event_organizers_user_idx on public.event_organizers (user_id);

-- The roster. user_id is empty for people the organizer added by hand.
create table public.event_people (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  phone text check (char_length(phone) <= 40),
  role text not null default 'driver' check (role in ('driver', 'passenger')),
  car jsonb check (car is null or jsonb_typeof(car) = 'object'),
  extra_people int not null default 0 check (extra_people between 0 and 20),
  rides_with uuid references public.event_people (id) on delete set null,
  needs_ride boolean not null default false,
  seats_open int check (seats_open between 0 and 20),
  meetup_index int not null default 0 check (meetup_index in (0, 1)),
  rsvp text not null default 'in' check (rsvp in ('in', 'maybe', 'out')),
  source text not null default 'web' check (source in ('web', 'organizer', 'app')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.event_people enable row level security;
create unique index event_people_user_key on public.event_people (event_id, user_id) where user_id is not null;
create index event_people_event_idx on public.event_people (event_id);
create index event_people_user_idx on public.event_people (user_id);
create index event_people_rides_with_idx on public.event_people (rides_with);

-- Organizers and co-organizers of an event.
create function public.is_event_organizer(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_organizers o where o.event_id = eid and o.user_id = (select auth.uid()))
      or exists (select 1 from public.events e where e.id = eid and e.organizer_id = (select auth.uid()));
$$;
revoke execute on function public.is_event_organizer(uuid) from public, anon;
grant execute on function public.is_event_organizer(uuid) to authenticated;

-- The person who created the event (only they add or remove co-organizers).
create function private.is_event_owner(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e where e.id = eid and e.organizer_id = (select auth.uid()));
$$;
create function private.is_on_event_roster(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_people p where p.event_id = eid and p.user_id = (select auth.uid()));
$$;
-- Sign-ups: published and not closed. Changing or leaving: published.
create function private.event_accepts_signups(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e where e.id = eid and e.status = 'published' and not e.signups_closed);
$$;
create function private.event_is_published(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e where e.id = eid and e.status = 'published');
$$;
revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- New events get a code, the route record and a title; after that the organizer, code, route and
-- creation time can't change.
create function public.events_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
begin
  if tg_op = 'INSERT' then
    if new.route_snapshot is null then
      select r.data into new.route_snapshot from public.routes r
      where r.id = new.route_id and (r.is_public or r.owner_id = new.organizer_id);
    end if;
    if new.title is null or btrim(new.title) = '' then
      new.title := left(coalesce(new.route_snapshot ->> 'name', 'Drive'), 120);
    end if;
    loop
      c := '';
      for i in 1..6 loop c := c || substr(alphabet, 1 + floor(random() * 31)::int, 1); end loop;
      exit when not exists (select 1 from public.events e where e.code = c);
    end loop;
    new.code := c;
    new.created_at := now();
  else
    new.organizer_id := old.organizer_id; new.code := old.code;
    new.route_id := old.route_id; new.created_at := old.created_at;
  end if;
  perform now() at time zone new.time_zone;   -- rejects an unknown time zone
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.events_before_write() from public, anon, authenticated;
create trigger events_before_write before insert or update on public.events
  for each row execute function public.events_before_write();

create function public.events_add_organizer() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.event_organizers (event_id, user_id, role) values (new.id, new.organizer_id, 'organizer')
  on conflict do nothing;
  return new;
end $$;
revoke execute on function public.events_add_organizer() from public, anon, authenticated;
create trigger events_add_organizer after insert on public.events
  for each row execute function public.events_add_organizer();

-- Roster rows: drivers don't ride with anyone, passengers have no car, the car has to be on the same
-- drive, and a row can't move to another event or person.
create function public.event_people_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.event_id := old.event_id; new.user_id := old.user_id;
    new.source := old.source; new.created_at := old.created_at;
  end if;
  if new.role = 'passenger' then
    new.car := null; new.extra_people := 0; new.seats_open := null;
    if new.rides_with is not null then new.needs_ride := false; end if;
  else
    new.rides_with := null; new.needs_ride := false;
  end if;
  if new.rides_with is not null and not exists (
    select 1 from public.event_people d
    where d.id = new.rides_with and d.event_id = new.event_id and d.role = 'driver' and d.id <> new.id) then
    raise exception 'That car isn''t on this drive.' using errcode = '23514';
  end if;
  if new.meetup_index >= (select jsonb_array_length(e.meetups) from public.events e where e.id = new.event_id) then
    raise exception 'This drive has only one meetup point.' using errcode = '23514';
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.event_people_before_write() from public, anon, authenticated;
create trigger event_people_before_write before insert or update on public.event_people
  for each row execute function public.event_people_before_write();

-- Policies: events
create policy "Organizers and people on the roster read the event"
  on public.events for select to authenticated
  using (organizer_id = (select auth.uid()) or public.is_event_organizer(id) or private.is_on_event_roster(id));
create policy "People plan drives on public routes and their own"
  on public.events for insert to authenticated
  with check (organizer_id = (select auth.uid()) and exists (
    select 1 from public.routes r where r.id = route_id and (r.is_public or r.owner_id = (select auth.uid()))));
create policy "Organizers edit their events"
  on public.events for update to authenticated
  using (public.is_event_organizer(id)) with check (public.is_event_organizer(id));
create policy "Only admins delete events"
  on public.events for delete to authenticated using ((select public.is_admin()));

-- Policies: co-organizers
create policy "Organizers see who organizes"
  on public.event_organizers for select to authenticated
  using (user_id = (select auth.uid()) or public.is_event_organizer(event_id));
create policy "The organizer adds co-organizers"
  on public.event_organizers for insert to authenticated
  with check (role = 'co' and private.is_event_owner(event_id));
create policy "The organizer removes co-organizers, or they step down"
  on public.event_organizers for delete to authenticated
  using (role = 'co' and (user_id = (select auth.uid()) or private.is_event_owner(event_id)));

-- Policies: roster. People manage their own row on published events; organizers manage every row,
-- but can only add themselves or people without an account.
create policy "Your own roster row, and organizers, can be read"
  on public.event_people for select to authenticated
  using (user_id = (select auth.uid()) or public.is_event_organizer(event_id));
create policy "People join published drives; organizers add people"
  on public.event_people for insert to authenticated
  with check (
    (user_id = (select auth.uid()) and source <> 'organizer' and private.event_accepts_signups(event_id))
    or (public.is_event_organizer(event_id) and (user_id is null or user_id = (select auth.uid()))));
create policy "People change their own row; organizers change any"
  on public.event_people for update to authenticated
  using ((user_id = (select auth.uid()) and private.event_is_published(event_id)) or public.is_event_organizer(event_id))
  with check ((user_id = (select auth.uid()) and private.event_is_published(event_id)) or public.is_event_organizer(event_id));
create policy "People leave; organizers remove anyone"
  on public.event_people for delete to authenticated
  using ((user_id = (select auth.uid()) and private.event_is_published(event_id)) or public.is_event_organizer(event_id));

-- The one place cars and people are counted, for the website and the app.
-- cars = drivers who are in; people = those drivers + their extra people + passengers who are in
-- and either ride with someone or need a ride. Drafts are counted only for their organizers.
create function public.event_counts(eid uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n int;
  st text;
  result jsonb;
begin
  select coalesce(jsonb_array_length(e.meetups), 1), e.status into n, st from public.events e where e.id = eid;
  if not found or (st = 'draft' and not public.is_event_organizer(eid)) then return null; end if;
  with p as (
    select x.role, x.extra_people, least(x.meetup_index, n - 1) as m,
           (x.role = 'driver') as is_car,
           case when x.role = 'driver' then 1 + x.extra_people
                when x.rides_with is not null or x.needs_ride then 1 else 0 end as heads
    from public.event_people x where x.event_id = eid and x.rsvp = 'in'
  ), per as (
    select i, count(*) filter (where p.is_car) as cars, coalesce(sum(p.heads), 0) as people
    from generate_series(0, n - 1) i left join p on p.m = i
    group by i
  )
  select jsonb_build_object(
    'cars', coalesce(sum(per.cars), 0)::int,
    'people', coalesce(sum(per.people), 0)::int,
    'by_meetup', jsonb_agg(jsonb_build_object('cars', per.cars::int, 'people', per.people::int) order by per.i))
  into result from per;
  return result;
end $$;
revoke execute on function public.event_counts(uuid) from public, anon;
grant execute on function public.event_counts(uuid) to authenticated;

-- What the invite link shows. Drafts only to their organizers. Organizer notes only once finished.
-- Signed out: counts only. Signed in: first names and cars too. Never phone numbers.
create function public.event_by_code(code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  e public.events;
  uid uuid := (select auth.uid());
  org boolean;
begin
  select * into e from public.events ev where ev.code = public.normalize_event_code(event_by_code.code);
  if not found then return null; end if;
  org := uid is not null and public.is_event_organizer(e.id);
  if e.status = 'draft' and not org then return null; end if;
  return (to_jsonb(e) - 'organizer_notes') || jsonb_build_object(
    'organizer_notes', case when e.status = 'finished' or org then e.organizer_notes end,
    'organizer_name', (select pr.display_name from public.profiles pr where pr.id = e.organizer_id),
    'counts', public.event_counts(e.id),
    'viewer', jsonb_build_object('signed_in', uid is not null, 'is_organizer', org, 'is_owner', e.organizer_id = uid),
    'roster', case when uid is null then null else (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', split_part(btrim(p.display_name), ' ', 1), 'role', p.role, 'car', p.car,
        'extra_people', p.extra_people, 'seats_open', p.seats_open, 'rides_with', p.rides_with,
        'needs_ride', p.needs_ride, 'meetup_index', p.meetup_index, 'rsvp', p.rsvp,
        'is_me', p.user_id is not distinct from uid) order by p.created_at), '[]'::jsonb)
      from public.event_people p where p.event_id = e.id and p.rsvp <> 'out') end);
end $$;
grant execute on function public.event_by_code(text) to anon, authenticated;

-- Previous drives on a route: how many were finished, and for drives the viewer organized or
-- joined, the date, counts, planned and actual time, and notes. No names.
create function public.route_drive_history(route_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'total', (select count(*) from public.events e
              where e.route_id = route_drive_history.route_id and e.status = 'finished'),
    'drives', coalesce((
      select jsonb_agg(jsonb_build_object(
        'starts_at', e.starts_at, 'time_zone', e.time_zone, 'title', e.title,
        'cars', c.v -> 'cars', 'people', c.v -> 'people',
        'planned_minutes', (select round(sum((s ->> 'duration')::numeric) / 60)
                            from jsonb_array_elements(e.route_snapshot -> 'segments') s
                            where jsonb_typeof(s) = 'object'),
        'actual_minutes', e.actual_minutes, 'notes', e.organizer_notes) order by e.starts_at desc)
      from public.events e
      cross join lateral (select public.event_counts(e.id) as v) c
      where e.route_id = route_drive_history.route_id and e.status = 'finished'
        and (public.is_event_organizer(e.id)
             or exists (select 1 from public.event_people p where p.event_id = e.id and p.user_id = (select auth.uid())))
    ), '[]'::jsonb));
$$;
grant execute on function public.route_drive_history(uuid) to anon, authenticated;

-- Co-organizers are added by the email of an existing account.
-- Returns {found:false} when nobody has signed in with that email yet.
create function public.add_co_organizer(eid uuid, email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  u uuid;
begin
  if not private.is_event_owner(eid) then
    raise exception 'Only the organizer can add co-organizers.' using errcode = '42501';
  end if;
  select au.id into u from auth.users au where lower(au.email) = lower(btrim(add_co_organizer.email)) limit 1;
  if u is null then return jsonb_build_object('found', false); end if;
  insert into public.event_organizers (event_id, user_id, role) values (eid, u, 'co') on conflict do nothing;
  return jsonb_build_object('found', true, 'user_id', u,
    'display_name', (select pr.display_name from public.profiles pr where pr.id = u));
end $$;
revoke execute on function public.add_co_organizer(uuid, text) from public, anon;
grant execute on function public.add_co_organizer(uuid, text) to authenticated;
