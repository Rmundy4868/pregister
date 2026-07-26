-- Adds extended location profile fields used by Organization Setup > Locations.
-- Safe to run multiple times.

alter table public.locations
  add column if not exists address_2 text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists zip text,
  add column if not exists phone text,
  add column if not exists legacy_gateway_api_login_id text,
  add column if not exists legacy_gateway_transaction_key text;
