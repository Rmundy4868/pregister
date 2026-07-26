-- Validation gate before location creation:
-- ensures no legacy gateway columns/routines remain in the live public schema.

-- 1) Location columns that must NOT exist.
select
  table_schema,
  table_name,
  column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'locations'
  and column_name in (
    'legacy_gateway_api_login_id',
    'legacy_gateway_transaction_key'
  )
order by column_name;

-- 2) Functions/routines that must NOT exist.
select
  routine_schema,
  routine_name
from information_schema.routines
where routine_schema = 'public'
  and (
    lower(routine_name) like '%legacy_gateway%'
  )
order by routine_name;

-- 3) Activation RPC contract should be gateway-agnostic and available.
select
  routine_name,
  data_type
from information_schema.routines
where routine_schema = 'public'
  and routine_name = 'activate_install_license';
