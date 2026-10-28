-- Test drives for tests/events.test.mjs. Run it in the Supabase SQL editor (or execute_sql), pass the
-- codes it returns to the test as EVENT_CODES, then run tests/cleanup.sql. Every title starts with
-- "[test]" so cleanup can find them. The organizer is the route's owner; the route itself is untouched.
with r as (
  select id, owner_id, data,
         data -> 'stops' -> (select (i - 1)::int from jsonb_array_elements(data -> 'stops') with ordinality s(v, i) where v ->> 'type' = 'pit' limit 1) pit,
         (data -> 'segments' -> 0 ->> 'distance')::numeric / 1609.344 m1,
         data -> 'segments' -> 1 -> 'coords' -> 0 ll1
  from public.routes where is_public and data -> 'stops' @> '[{"type":"pit"}]' order by created_at limit 1
), base as (
  select r.*, date_trunc('day', now() + interval '14 days') + interval '14 hours 30 minutes' t0 from r   -- 8:30 AM in Central standard time
), ins as (
  insert into public.events (route_id, organizer_id, title, starts_at, time_zone, status, signups_closed, cancel_reason, meetups, meal)
  select b.id, b.owner_id, '[test] ' || k.t, b.t0, 'America/Chicago', k.status, k.closed, k.reason,
         jsonb_build_array(jsonb_build_object('name', 'Test meetup 1', 'll', b.data -> 'geometry' -> 'coordinates' -> 0 -> 0, 'mile', 0),
                           jsonb_build_object('name', 'Test meetup 2', 'll', b.ll1, 'mile', round(b.m1, 1),
                                              'depart_at', to_char(b.t0 + interval '30 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
         jsonb_build_object('name', b.pit ->> 'name', 'll', b.pit -> 'll', 'mile', round((b.pit ->> 'mile')::numeric, 1),
                            'last_seating_at', to_char(b.t0 + interval '3 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  from base b, (values ('open', 'Open drive', 'published', false, null),
                       ('closed', 'Closed drive', 'published', true, null),
                       ('cancelled', 'Cancelled drive', 'cancelled', false, 'Test reason'),
                       ('draft', 'Draft drive', 'draft', false, null)) k(name, t, status, closed, reason)
  returning code, title
)
select jsonb_object_agg(lower(split_part(title, ' ', 2)), code) codes, (select id from r) route_id from ins;
