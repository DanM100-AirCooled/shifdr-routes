-- Server-only settings (API keys for outside data sources).
-- Row-level security is on with no policies, so the public API can't read or write it;
-- only server code using the service role (the road-conditions function) can.
create table public.app_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;
-- The DriveTexas key is added directly in the database, never in this repo:
--   insert into public.app_settings (key, value) values ('drivetexas_key', '<key>');
