-- Phase-1 validation checks for activation/admin rebuild.
-- Run after:
--  - 2026-06-01 activation cleanup stack
--  - 2026-06-03 partner console foundation
--  - 2026-06-03 staff security model

with checks as (
  -- 1) Core activation RPCs still exist.
  select
    'activate_install_license_exists'::text as check_name,
    case
      when to_regprocedure('public.activate_install_license(text,text,text,text,text,boolean)') is not null then 'ok'
      else 'fail'
    end as status,
    case
      when to_regprocedure('public.activate_install_license(text,text,text,text,text,boolean)') is not null then 1
      else 0
    end as actual_value,
    1::int as expected_value,
    ''::text as details

  union all

  select
    'upsert_terminal_from_app_exists'::text as check_name,
    case
      when to_regprocedure('public.upsert_terminal_from_app(text,uuid,uuid,text,text,text,text,text,text,text,boolean,text)') is not null then 'ok'
      else 'fail'
    end as status,
    case
      when to_regprocedure('public.upsert_terminal_from_app(text,uuid,uuid,text,text,text,text,text,text,text,boolean,text)') is not null then 1
      else 0
    end as actual_value,
    1::int as expected_value,
    ''::text as details

  union all

  -- 2) New admin tables exist.
  select
    'admin_tables_missing'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    coalesce(string_agg(req.tbl, ', ' order by req.tbl), '') as details
  from (
    values
      ('distribution_partners'),
      ('master_console_users')
  ) as req(tbl)
  left join information_schema.tables t
    on t.table_schema = 'public'
   and t.table_name = req.tbl
  where t.table_name is null

  union all

  -- 3) Required organization/staff columns exist.
  select
    'required_new_columns_missing'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    coalesce(string_agg(req.table_name || '.' || req.column_name, ', ' order by req.table_name, req.column_name), '') as details
  from (
    values
      ('organizations', 'partner_id'),
      ('staff', 'security_level'),
      ('staff', 'security_designation')
  ) as req(table_name, column_name)
  left join information_schema.columns c
    on c.table_schema = 'public'
   and c.table_name = req.table_name
   and c.column_name = req.column_name
  where c.column_name is null

  union all

  -- 4) Shared login and helper RPCs exist.
  select
    'console_rpc_contract_missing'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    coalesce(string_agg(req.signature, ', ' order by req.signature), '') as details
  from (
    values
      ('public.console_login(text,text)'),
      ('public.upsert_distribution_partner(text,text,text,text,text,text,text,text,text,text,text,text,text,text,boolean)'),
      ('public.upsert_master_console_user(text,text,text,boolean)')
  ) as req(signature)
  where to_regprocedure(req.signature) is null

  union all

  -- 5) Partner/master seed status (informational, does not fail deployment).
  select
    'master_console_users_count_info'::text as check_name,
    'ok'::text as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    'Informational only: seed at least one master console user.'::text as details
  from public.master_console_users

  union all

  select
    'distribution_partners_count_info'::text as check_name,
    'ok'::text as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    'Informational only: seed at least one partner.'::text as details
  from public.distribution_partners
)
select
  check_name,
  status,
  actual_value,
  expected_value,
  details
from checks
order by check_name;
