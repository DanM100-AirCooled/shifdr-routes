-- Shifdr Routes: accounts and the route library.
-- Anyone can read public routes. Only the owner can read their private routes or change anything.

create extension if not exists postgis with schema extensions;

-- One profile per account; the display name shows on public routes.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 60),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "Profiles are readable by everyone"
  on public.profiles for select to anon, authenticated using (true);
create policy "People update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- New accounts get a profile named after the start of their email.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(split_part(coalesce(new.email, 'Driver'), '@', 1), 60));
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Routes. `data` is the full shifdr.route/v1 record the builder saves and reopens;
-- the other columns are copies used for listing, searching and the map.
create table public.routes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  description text check (char_length(description) <= 2000),
  is_public boolean not null default false,
  distance_m integer not null default 0 check (distance_m >= 0),
  duration_s integer not null default 0 check (duration_s >= 0),
  is_loop boolean not null default false,
  start_name text,
  finish_name text,
  roads text[] not null default '{}',
  stops jsonb not null default '[]',
  data jsonb not null check (octet_length(data::text) < 5000000),
  geom extensions.geometry(MultiLineString, 4326),
  preview extensions.geometry(MultiLineString, 4326),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.routes enable row level security;

create index routes_geom_idx on public.routes using gist (geom);
create index routes_public_idx on public.routes (is_public) where is_public;
create index routes_owner_idx on public.routes (owner_id, updated_at desc);

create policy "Public routes, and your own, are readable"
  on public.routes for select to anon, authenticated
  using (is_public or owner_id = (select auth.uid()));
create policy "People add their own routes"
  on public.routes for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "People edit their own routes"
  on public.routes for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "People delete their own routes"
  on public.routes for delete to authenticated
  using (owner_id = (select auth.uid()));

-- Geometry comes from the saved record, so the map can find routes by area.
create function public.routes_set_geometry() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.geom := extensions.st_multi(extensions.st_setsrid(extensions.st_geomfromgeojson((new.data -> 'geometry')::text), 4326));
  new.preview := extensions.st_multi(extensions.st_simplifypreservetopology(new.geom, 0.0003));
  new.updated_at := now();
  if tg_op = 'UPDATE' then new.owner_id := old.owner_id; new.created_at := old.created_at; end if;
  return new;
end $$;
create trigger routes_geometry before insert or update on public.routes
  for each row execute function public.routes_set_geometry();

-- Public routes that cross the map view, with a simplified line for drawing.
create function public.routes_in_view(min_lng float8, min_lat float8, max_lng float8, max_lat float8, max_rows int default 200)
returns table (id uuid, name text, distance_m int, duration_s int, is_loop boolean, start_name text,
               roads text[], author text, created_at timestamptz, preview jsonb)
language sql stable security invoker set search_path = '' as $$
  select r.id, r.name, r.distance_m, r.duration_s, r.is_loop, r.start_name, r.roads,
         p.display_name, r.created_at, extensions.st_asgeojson(r.preview, 5)::jsonb
  from public.routes r
  left join public.profiles p on p.id = r.owner_id
  where r.is_public
    and r.geom operator(extensions.&&) extensions.st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)
  order by r.created_at desc
  limit least(greatest(max_rows, 1), 500);
$$;
grant execute on function public.routes_in_view(float8, float8, float8, float8, int) to anon, authenticated;
