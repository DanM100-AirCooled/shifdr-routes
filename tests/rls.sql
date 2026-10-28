-- Row-level security checks for events (spec §9, items 1–5). Run it in the Supabase SQL editor or
-- with execute_sql. Three throwaway users act in turn (set_config role + JWT claims), and the whole
-- block ends with an exception, so nothing it writes is kept. Read the result from the error text:
-- every line starts PASS or FAIL.
do $t$
declare
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  rid uuid; eid uuid; ecode text; pb uuid; pc uuid; post uuid; j jsonb; n int; s text;
  out text := E'\n';
begin
  insert into auth.users (id, email, aud, role) values
    (ua, 'events-test-a@example.invalid', 'authenticated', 'authenticated'),
    (ub, 'events-test-b@example.invalid', 'authenticated', 'authenticated'),
    (uc, 'events-test-c@example.invalid', 'authenticated', 'authenticated');
  select r.id into rid from public.routes r where r.is_public order by r.created_at limit 1;

  -- 1. A creates a draft: 6-character code from the allowed set
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  insert into public.events (route_id, starts_at, meetups)
    values (rid, now() + interval '10 days', '[{"name":"Meet","ll":[-95.8,29.78]}]') returning id, code into eid, ecode;
  out := out || (case when ecode ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then 'PASS' else 'FAIL' end) || ' 1 code ' || ecode || E'\n';
  out := out || (case when public.event_by_code(ecode) -> 'viewer' ->> 'is_organizer' = 'true' then 'PASS' else 'FAIL' end) || ' 2 organizer opens own draft' || E'\n';
  update public.events set code = 'AAAAAA', organizer_id = ub where id = eid;
  out := out || (case when (select e.code = ecode and e.organizer_id = ua from public.events e where e.id = eid) then 'PASS' else 'FAIL' end) || ' 5 code and organizer cannot change' || E'\n';

  -- 2. drafts are hidden from everyone else
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  out := out || (case when public.event_by_code(ecode) is null then 'PASS' else 'FAIL' end) || ' 2 draft code returns nothing to another user' || E'\n';
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  out := out || (case when public.event_by_code(ecode) is null then 'PASS' else 'FAIL' end) || ' 2 draft code returns nothing to anon' || E'\n';

  -- A publishes
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  update public.events set status = 'published' where id = eid;

  -- 3. B joins as a driver with 1 extra person; C rides in B's car
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  insert into public.event_people (event_id, user_id, display_name, phone, role, car, extra_people, seats_open)
    values (eid, ub, 'Bob Tester', '555-0101', 'driver', '{"year":1973,"make":"Porsche","model":"911T"}', 1, 1) returning id into pb;
  perform set_config('request.jwt.claims', json_build_object('sub', uc, 'role', 'authenticated')::text, true);
  insert into public.event_people (event_id, user_id, display_name, phone, role, rides_with)
    values (eid, uc, 'Cat Tester', '555-0102', 'passenger', pb) returning id into pc;
  j := public.event_by_code(ecode) -> 'counts';
  out := out || (case when (j ->> 'cars')::int = 1 and (j ->> 'people')::int = 3 then 'PASS' else 'FAIL' end) || ' 3 counts 1 car, 3 people: ' || j::text || E'\n';

  -- updates: A posts one for everyone and one for the roster; C (on the roster) reads both, can't write
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  insert into public.event_posts (event_id, body) values (eid, '  Meetup moved to the Shell.  ') returning id into post;
  insert into public.event_posts (event_id, body, audience) values (eid, 'Lead car is the red 911', 'roster');
  out := out || (case when (select p.author_id = ua and p.body = 'Meetup moved to the Shell.' from public.event_posts p where p.id = post) then 'PASS' else 'FAIL' end) || ' 6 organizer posts an update (author set, trimmed)' || E'\n';
  perform set_config('request.jwt.claims', json_build_object('sub', uc, 'role', 'authenticated')::text, true);
  out := out || (case when jsonb_array_length(public.event_by_code(ecode) -> 'posts') = 2 then 'PASS' else 'FAIL' end) || ' 6 roster member sees both updates' || E'\n';
  begin
    insert into public.event_posts (event_id, body) values (eid, 'Fake update');
    out := out || 'FAIL 6 non-organizer posted' || E'\n';
  exception when others then out := out || 'PASS 6 non-organizer cannot post' || E'\n'; end;
  update public.event_posts set body = 'hacked' where id = post;
  get diagnostics n = row_count;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 6 non-organizer cannot edit an update' || E'\n';

  -- 5. C is not an organizer: no phones, no edits
  j := public.event_by_code(ecode);
  out := out || (case when j::text not like '%555-01%' then 'PASS' else 'FAIL' end) || ' 5 non-organizer gets no phones' || E'\n';
  select count(*) into n from public.event_people p where p.id = pb;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 5 non-organizer cannot read other roster rows' || E'\n';
  update public.events set title = 'hacked' where id = eid;
  get diagnostics n = row_count;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 5 non-organizer cannot edit the event' || E'\n';
  update public.event_people set extra_people = 9 where id = pb;
  get diagnostics n = row_count;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 5 non-organizer cannot edit someone else' || E'\n';
  begin
    insert into public.event_people (event_id, display_name, source) values (eid, 'Fake', 'organizer');
    out := out || 'FAIL 5 non-organizer added a person' || E'\n';
  exception when others then out := out || 'PASS 5 non-organizer cannot add people' || E'\n'; end;
  begin
    perform phone from public.profiles limit 1;
    out := out || 'FAIL 5 profiles.phone readable' || E'\n';
  exception when insufficient_privilege then out := out || 'PASS 5 profiles.phone hidden' || E'\n'; end;

  -- 2. anon: counts only
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select count(*) into n from public.events;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 2 anon select events: ' || n || ' rows' || E'\n';
  j := public.event_by_code(ecode);
  out := out || (case when j -> 'counts' is not null and j::text not like '%Tester%' and j::text not like '%555-01%' then 'PASS' else 'FAIL' end)
    || ' 2 anon by code: counts, no names or phones' || E'\n';
  select count(*) into n from public.event_posts;
  out := out || (case when n = 0 and jsonb_array_length(j -> 'posts') = 1 and j::text not like '%Lead car%' then 'PASS' else 'FAIL' end)
    || ' 6 anon: no table reads, only the everyone update by code' || E'\n';
  out := out || (case when public.event_by_code('ZZZZZZ') is null then 'PASS' else 'FAIL' end) || ' 2 invalid code returns nothing' || E'\n';

  -- 4. organizer: sees phones, adds a person, closes sign-ups, cancels
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  select string_agg(p.phone, ',' order by p.created_at) into s from public.event_people p where p.event_id = eid;
  out := out || (case when s = '555-0101,555-0102' then 'PASS' else 'FAIL' end) || ' 4 organizer sees phones' || E'\n';
  insert into public.event_people (event_id, display_name, phone, role, needs_ride, source) values (eid, 'Hand Added', '555-0199', 'passenger', true, 'organizer');
  out := out || (case when (public.event_counts(eid) ->> 'people')::int = 4 then 'PASS' else 'FAIL' end) || ' 4 organizer adds a person by hand' || E'\n';
  update public.events set signups_closed = true where id = eid;

  -- 3. C can't make it: dropped from the counts; can't rejoin once closed
  perform set_config('request.jwt.claims', json_build_object('sub', uc, 'role', 'authenticated')::text, true);
  update public.event_people set rsvp = 'out' where id = pc;
  j := public.event_by_code(ecode) -> 'counts';
  out := out || (case when (j ->> 'people')::int = 3 then 'PASS' else 'FAIL' end) || ' 3 "I can''t make it" drops them: ' || j::text || E'\n';
  delete from public.event_people where id = pc;
  begin
    insert into public.event_people (event_id, user_id, display_name) values (eid, uc, 'Cat');
    out := out || 'FAIL 4 joined after sign-ups closed' || E'\n';
  exception when others then out := out || 'PASS 4 join blocked after sign-ups close' || E'\n'; end;

  -- removing a driver: their passengers now need a ride
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  update public.event_people set role = 'passenger', rides_with = pb where event_id = eid and display_name = 'Hand Added';
  delete from public.event_people where id = pb;
  out := out || (case when (select needs_ride from public.event_people where event_id = eid and display_name = 'Hand Added') then 'PASS' else 'FAIL' end)
    || ' 4 removed driver''s passenger needs a ride' || E'\n';

  update public.events set status = 'cancelled', cancel_reason = 'Rain' where id = eid;
  out := out || (case when public.event_by_code(ecode) ->> 'status' = 'cancelled' then 'PASS' else 'FAIL' end) || ' 4 cancelled' || E'\n';
  delete from public.events where id = eid;
  get diagnostics n = row_count;
  out := out || (case when n = 0 then 'PASS' else 'FAIL' end) || ' 4 only admins delete events' || E'\n';

  reset role;
  raise exception 'TEST REPORT (rolled back):%', out;
end $t$;
