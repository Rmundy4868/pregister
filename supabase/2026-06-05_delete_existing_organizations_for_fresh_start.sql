-- DANGER: Deletes existing organizations for a fresh end-to-end startup.
--
-- Safety lock:
--   You MUST set the confirmation flag in the same SQL editor session before running:
--     select set_config('app.confirm_delete_organizations', 'YES_DELETE_ORGS', false);
--
-- This reset removes organization hierarchy and related operational rows.
-- It does NOT delete distribution partners or master console users.

begin;

do $$
declare
  v_confirm text;
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
    'public.organizations'
  ];
  v_existing text[] := array[]::text[];
  v_table text;
begin
  v_confirm := current_setting('app.confirm_delete_organizations', true);
  if coalesce(v_confirm, '') <> 'YES_DELETE_ORGS' then
    raise exception
      'Delete cancelled. Set app.confirm_delete_organizations = YES_DELETE_ORGS before running this script.';
  end if;

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

commit;

-- Post-check (all should be 0)
-- select 'organizations' as table_name, count(*)::bigint from public.organizations
-- union all select 'locations', count(*)::bigint from public.locations
-- union all select 'terminals', count(*)::bigint from public.terminals
-- union all select 'staff', count(*)::bigint from public.staff
-- union all select 'transactions', count(*)::bigint from public.transactions
-- union all select 'transaction_headers', count(*)::bigint from public.transaction_headers
-- union all select 'transaction_details', count(*)::bigint from public.transaction_details
-- order by table_name;
