-- Events, part 2: the functions that read past row-level security move to the private schema,
-- which isn't part of the public API. The public names stay, as plain wrappers, so the website
-- and the app call the same RPCs as before. Who can call each one doesn't change.

grant usage on schema private to anon;

create function private.is_event_organizer(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_organizers o where o.event_id = eid and o.user_id = (select auth.uid()))
      or exists (select 1 from public.events e where e.id = eid and e.organizer_id = (select auth.uid()));
$$;

create function private.my_private_profile() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('phone', p.phone, 'car', p.car) from public.profiles p where p.id = (select auth.uid());
$$;

create function private.event_counts(eid uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n int;
  st text;
  result jsonb;
begin
  select coalesce(jsonb_array_length(e.meetups), 1), e.status into n, st from public.events e where e.id = eid;
  if not found or (st = 'draft' and not private.is_event_organizer(eid)) then return null; end if;
  with p as (
    select least(x.meetup_index, n - 1) as m,
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

create function private.event_by_code(code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  e public.events;
  uid uuid := (select auth.uid());
  org boolean;
begin
  select * into e from public.events ev where ev.code = public.normalize_event_code(event_by_code.code);
  if not found then return null; end if;
  org := uid is not null and private.is_event_organizer(e.id);
  if e.status = 'draft' and not org then return null; end if;
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
      from public.event_people p where p.event_id = e.id and p.rsvp <> 'out') end);
end $$;

create function private.route_drive_history(route_id uuid) returns jsonb
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
      cross join lateral (select private.event_counts(e.id) as v) c
      where e.route_id = route_drive_history.route_id and e.status = 'finished'
        and (private.is_event_organizer(e.id)
             or exists (select 1 from public.event_people p where p.event_id = e.id and p.user_id = (select auth.uid())))
    ), '[]'::jsonb));
$$;

create function private.add_co_organizer(eid uuid, email text) returns jsonb
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

-- New functions are executable by everyone by default; open each one only to who needs it.
revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
grant execute on function private.event_by_code(text), private.route_drive_history(uuid) to anon;

-- The public names become wrappers.
create or replace function public.is_event_organizer(eid uuid) returns boolean
language sql stable security invoker set search_path = '' as $$ select private.is_event_organizer(eid); $$;
create or replace function public.my_private_profile() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.my_private_profile(); $$;
create or replace function public.event_counts(eid uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.event_counts(eid); $$;
create or replace function public.event_by_code(code text) returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.event_by_code(code); $$;
create or replace function public.route_drive_history(route_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.route_drive_history(route_id); $$;
create or replace function public.add_co_organizer(eid uuid, email text) returns jsonb
language sql volatile security invoker set search_path = '' as $$ select private.add_co_organizer(eid, email); $$;
