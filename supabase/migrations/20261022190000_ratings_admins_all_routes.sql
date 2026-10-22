-- Ratings, admin-only deletes, and a list of all public routes.

-- Admins: the only people who can delete routes.
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
create policy "People can see whether they are an admin"
  on public.admins for select to authenticated using (user_id = (select auth.uid()));

create function public.is_admin() returns boolean
language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()));
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- Owners keep editing their routes, but only admins can delete one.
alter policy "People delete their own routes" on public.routes using ((select public.is_admin()));
alter policy "People delete their own routes" on public.routes rename to "Only admins delete routes";

-- Ratings: one 1-5 star rating per person per route; not on your own route, only on public ones.
create table public.route_ratings (
  route_id uuid not null references public.routes (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  stars smallint not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (route_id, user_id)
);
alter table public.route_ratings enable row level security;
create index route_ratings_route_idx on public.route_ratings (route_id);
create index route_ratings_user_idx on public.route_ratings (user_id);

create policy "Ratings are readable by everyone"
  on public.route_ratings for select to anon, authenticated using (true);
create policy "People rate other people's public routes"
  on public.route_ratings for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (
    select 1 from public.routes r where r.id = route_id and r.is_public and r.owner_id <> (select auth.uid())));
create policy "People change their own rating"
  on public.route_ratings for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and exists (
    select 1 from public.routes r where r.id = route_id and r.is_public and r.owner_id <> (select auth.uid())));
create policy "People remove their own rating"
  on public.route_ratings for delete to authenticated using (user_id = (select auth.uid()));

-- Public routes for Discover: everything, or only those crossing a map area.
-- Includes a short description and the average rating.
-- (routes_in_view from the first migration is left in place; the app now uses routes_list.)
create function public.routes_list(min_lng float8 default null, min_lat float8 default null,
                                   max_lng float8 default null, max_lat float8 default null, max_rows int default 500)
returns table (id uuid, name text, summary text, distance_m int, duration_s int, is_loop boolean, start_name text,
               roads text[], author text, created_at timestamptz, rating numeric, rating_count int, preview jsonb)
language sql stable security invoker set search_path = '' as $$
  select r.id, r.name,
         case when char_length(r.description) > 160 then left(r.description, 157) || '…' else r.description end,
         r.distance_m, r.duration_s, r.is_loop, r.start_name, r.roads, p.display_name, r.created_at,
         round(rt.avg_stars, 1), coalesce(rt.n, 0)::int,
         extensions.st_asgeojson(r.preview, 5)::jsonb
  from public.routes r
  left join public.profiles p on p.id = r.owner_id
  left join lateral (select avg(x.stars) as avg_stars, count(*) as n from public.route_ratings x where x.route_id = r.id) rt on true
  where r.is_public
    and (min_lng is null
         or r.geom operator(extensions.&&) extensions.st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326))
  order by r.created_at desc
  limit least(greatest(max_rows, 1), 1000);
$$;
grant execute on function public.routes_list(float8, float8, float8, float8, int) to anon, authenticated;

-- Admins are added directly in the database (not in this public repo):
--   insert into public.admins (user_id) values ('<user id>');
