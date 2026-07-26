-- DANGER: Full environment reset for fresh rebuild.
-- This removes operational data and tenant hierarchy data.
--
-- Safety lock:
--   You MUST set the confirmation flag in the same editor run before executing this script.
--   Example first line to run before this script:
--     select set_config('app.confirm_fresh_rebuild_reset', 'YES_RESET', false);
--
-- Recommended run order for restart:
-- 1) Run this file (full reset)
-- 2) Re-run baseline schema files / dated migrations
-- 3) Run 2026-06-03_partner_console_foundation.sql
-- 4) Run 2026-06-03_add_staff_security_model.sql
-- 5) Seed master user + initial partner
-- 6) Start activation onboarding

begin;

do $$
declare
  v_confirm text;
begin
  v_confirm := current_setting('app.confirm_fresh_rebuild_reset', true);
  if coalesce(v_confirm, '') <> 'YES_RESET' then
    raise exception
      'Reset cancelled. Set app.confirm_fresh_rebuild_reset = YES_RESET before running this script.';
  end if;
end
$$;

-- Keep archive tables and migration scripts intact.
do $$
declare
  v_targets text[] := array[
    'public.card_batch_details',
    'public.card_batch_headers',
    'public.transaction_details',
    'public.transaction_headers',
    'public.transactions',
    'public.screen_receipts',
    'public.staff',
    'public.terminals',
    'public.locations',
    'public.user_memberships',
    'public.organizations',
    'public.distribution_partners',
    'public.master_console_users'
  ];
  v_existing text[] := array[]::text[];
  v_table text;
begin
  foreach v_table in array v_targets loop
    if to_regclass(v_table) is not null then
      v_existing := array_append(v_existing, v_table);
    end if;
  end loop;

  if array_length(v_existing, 1) is not null then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity cascade';
  end if;
end
$$;

-- Optional tables that may exist in some environments.
do $$
begin
  if to_regclass('public.transaction_header_seq_counters') is not null then
    execute 'truncate table public.transaction_header_seq_counters restart identity cascade';
  end if;

  if to_regclass('public.payment_receipts') is not null then
    execute 'truncate table public.payment_receipts restart identity cascade';
  end if;

  if to_regclass('public.terminal_transaction_parameters') is not null then
    execute 'truncate table public.terminal_transaction_parameters restart identity cascade';
  end if;
end
$$;

commit;

-- Post-check (all rows should be 0)
-- select 'organizations' as table_name, count(*)::bigint from public.organizations
-- union all select 'locations', count(*)::bigint from public.locations
-- union all select 'terminals', count(*)::bigint from public.terminals
-- union all select 'staff', count(*)::bigint from public.staff
-- union all select 'distribution_partners', count(*)::bigint from public.distribution_partners
-- union all select 'master_console_users', count(*)::bigint from public.master_console_users
-- union all select 'transactions', count(*)::bigint from public.transactions
-- union all select 'transaction_headers', count(*)::bigint from public.transaction_headers
-- union all select 'transaction_details', count(*)::bigint from public.transaction_details
-- order by table_name;
