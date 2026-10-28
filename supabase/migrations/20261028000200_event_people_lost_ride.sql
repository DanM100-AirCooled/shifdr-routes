-- Events, part 3: when a driver is taken off the roster, the people riding with them lose their
-- car (rides_with is set to null by the foreign key). They now show as needing a ride instead of
-- dropping out of the headcount. Same trigger as before, plus that one rule.

create or replace function public.event_people_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.event_id := old.event_id; new.user_id := old.user_id;
    new.source := old.source; new.created_at := old.created_at;
  end if;
  if new.role = 'passenger' then
    new.car := null; new.extra_people := 0; new.seats_open := null;
    if new.rides_with is not null then new.needs_ride := false; end if;
    if tg_op = 'UPDATE' and new.rides_with is null and old.rides_with is not null then new.needs_ride := true; end if;
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
