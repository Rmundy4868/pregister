-- Hard-stop cleanup before location creation.
-- Ensures legacy legacy gateway location credential fields and helper RPCs are removed.

begin;

alter table if exists public.locations
  drop column if exists legacy_gateway_api_login_id,
  drop column if exists legacy_gateway_transaction_key;

drop function if exists public.get_location_legacy_gateway_credentials_for_license(text);
drop function if exists public.get_location_legacy_gateway_credentials_for_license(text, uuid);
drop function if exists public.get_location_legacy_gateway_credentials_for_license(text, uuid, text);

commit;
