-- Adds per-location legacy gateway credential fields used by Settings > Locations.
-- Safe to run multiple times.

alter table public.locations
  add column if not exists legacy_gateway_api_login_id text,
  add column if not exists legacy_gateway_transaction_key text;
