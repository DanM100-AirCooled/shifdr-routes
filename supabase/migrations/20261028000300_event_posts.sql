-- Events, part 4: updates organizers post on a drive. They show on the drive page, newest first,
-- pinned ones on top. 'all' posts show to anyone with the code; 'roster' posts only to organizers
-- and people on the roster. The Shifdr app will read the same rows to send alerts.

create table public.event_posts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(body) between 1 and 2000),
  audience text not null default 'all' check (audience in ('all', 'roster')),
  pinned boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.event_posts enable row level security;
create index event_posts_event_idx on public.event_posts (event_id, created_at desc);
create index event_posts_author_idx on public.event_posts (author_id);

-- The author is whoever posts it; a post can't move to another drive or change author.
create function public.event_posts_before_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.event_id := old.event_id; new.author_id := old.author_id; new.created_at := old.created_at;
  else
    new.author_id := coalesce((select auth.uid()), new.author_id);
    new.created_at := now();
  end if;
  new.body := btrim(new.body);
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.event_posts_before_write() from public, anon, authenticated;
create trigger event_posts_before_write before insert or update on public.event_posts
  for each row execute function public.event_posts_before_write();

-- Organizers write; organizers and people on the roster read the table. Everyone else with the
-- code reads 'all' posts through event_by_code.
create policy "Organizers and people on the roster read updates"
  on public.event_posts for select to authenticated
  using (public.is_event_organizer(event_id) or private.is_on_event_roster(event_id));
create policy "Organizers post updates"
  on public.event_posts for insert to authenticated with check (public.is_event_organizer(event_id));
create policy "Organizers edit updates"
  on public.event_posts for update to authenticated
  using (public.is_event_organizer(event_id)) with check (public.is_event_organizer(event_id));
create policy "Organizers delete updates"
  on public.event_posts for delete to authenticated using (public.is_event_organizer(event_id));

-- event_by_code gains 'posts'. Everything else is as before.
create or replace function private.event_by_code(code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  e public.events;
  uid uuid := (select auth.uid());
  org boolean;
  onlist boolean;
begin
  select * into e from public.events ev where ev.code = public.normalize_event_code(event_by_code.code);
  if not found then return null; end if;
  org := uid is not null and private.is_event_organizer(e.id);
  if e.status = 'draft' and not org then return null; end if;
  onlist := uid is not null and exists (select 1 from public.event_people p where p.event_id = e.id and p.user_id = uid);
  return (to_jsonb(e) - 'organizer_notes') || jsonb_build_object(
    'organizer_notes', case when e.status = 'finished' or org then e.organizer_notes end,
    'organizer_name', (select pr.display_name from public.profiles pr where pr.id = e.organizer_id),
    'counts', private.event_counts(e.id),
    'viewer', jsonb_build_object('signed_in', uid is not null, 'is_organizer', org, 'is_owner', e.organizer_id = uid),
    'roster', case when uid is null then null else (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', split_part(btrim(p.display_name), ' ', 1), 'role', p.role, 'car', p.car,
        'extra_people', p.extra_people, 'seats_open', p.seats_open, 'rides_with', p.rides_with,
        'needs_ride', p.needs_ride, 'meetup_index', p.meetup_index, 'rsvp', p.rsvp,
        'is_me', p.user_id is not distinct from uid) order by p.created_at), '[]'::jsonb)
      from public.event_people p where p.event_id = e.id and p.rsvp <> 'out') end,
    'posts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'body', x.body, 'audience', x.audience, 'pinned', x.pinned,
        'created_at', x.created_at, 'updated_at', x.updated_at,
        'author_name', (select pr.display_name from public.profiles pr where pr.id = x.author_id))
        order by x.pinned desc, x.created_at desc), '[]'::jsonb)
      from (select * from public.event_posts ps
            where ps.event_id = e.id and (ps.audience = 'all' or org or onlist)
            order by ps.pinned desc, ps.created_at desc limit 100) x));
end $$;
