-- Post-cleanup validation checks for 2026-06-01 migration path.
-- Run after steps 5 and 6 complete.

with checks as (
  -- 1) Legacy location processor columns should be gone.
  select
    'legacy_location_columns_remaining'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    coalesce(string_agg(column_name, ', ' order by column_name), '') as details
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'locations'
    and column_name in (
      'legacy_gateway_api_login_id',
      'legacy_gateway_transaction_key',
      'processor_provider',
      'processor_environment',
      'processor_mode',
      'payment_processor',
      'gateway_environment',
      'epn_api_login_id',
      'epn_login_id',
      'epn_user_id',
      'epn_userid',
      'epn_password',
      'epn_pass',
      'epn_restrict_key',
      'epn_restriction_key'
    )

  union all

  -- 2) Required terminal fields should exist.
  select
    'required_terminal_columns_missing'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    coalesce(string_agg(req.col, ', ' order by req.col), '') as details
  from (
    values
      ('application_type'),
      ('spin_tpn'),
      ('spin_auth_key'),
      ('card_reader_type'),
      ('card_reader_hpp_auth_token'),
      ('is_active'),
      ('registered_device_id'),
      ('registered_device_label')
  ) as req(col)
  left join information_schema.columns c
    on c.table_schema = 'public'
   and c.table_name = 'terminals'
   and c.column_name = req.col
  where c.column_name is null

  union all

  -- 3) Critical RPCs should exist.
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

  -- 4) Activation reset assertions (expected after step 6).
  select
    'active_terminals_after_reset'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    ''::text as details
  from public.terminals
  where coalesce(is_active, true) = true

  union all

  select
    'device_bound_terminals_after_reset'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    ''::text as details
  from public.terminals
  where registered_device_id is not null
     or registered_device_label is not null

  union all

  select
    'locations_nonzero_terminals_active'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    ''::text as details
  from public.locations
  where coalesce(terminals_active, 0) <> 0

  union all

  -- 5) Optional consistency check (keep for later re-activation runs).
  select
    'locations_terminals_active_mismatch'::text as check_name,
    case when count(*)::int = 0 then 'ok' else 'fail' end as status,
    count(*)::int as actual_value,
    0::int as expected_value,
    ''::text as details
  from public.locations l
  left join (
    select location_id, count(*)::int as active_count
    from public.terminals
    where coalesce(is_active, true) = true
    group by location_id
  ) t on t.location_id = l.id
  where coalesce(l.terminals_active, 0) <> coalesce(t.active_count, 0)
)
select
  check_name,
  status,
  actual_value,
  expected_value,
  details
from checks
order by check_name;
