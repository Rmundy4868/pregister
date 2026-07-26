-- =============================================================================
-- 2026-04-27  Clear Transaction + Batch Test Data
-- =============================================================================
-- Purpose:
--   Reset transaction-related data for clean POS testing after schema changes.
--
-- Scope:
--   Clears only transaction and batch/report tables used by register flows.
--   Does NOT remove organizations, locations, terminals, staff, or memberships.
--
-- Run in Supabase SQL Editor as a privileged role.
-- =============================================================================

begin;

-- Truncate all transaction-related tables together for FK safety.
-- If payment_receipts exists, include it in the same statement.
do $$
begin
	if to_regclass('public.payment_receipts') is not null then
		execute 'truncate table
			public.payment_receipts,
			public.screen_receipts,
			public.transactions,
			public.card_batch_details,
			public.card_batch_headers,
			public.transaction_details,
			public.transaction_headers
			restart identity';
	else
		execute 'truncate table
			public.screen_receipts,
			public.transactions,
			public.card_batch_details,
			public.card_batch_headers,
			public.transaction_details,
			public.transaction_headers
			restart identity';
	end if;
end $$;

commit;

-- Post-reset sanity checks (all should be 0)
select table_name, row_count
from (
	select 'payment_receipts' as table_name,
			   case
				   when to_regclass('public.payment_receipts') is null then 0
				   else (select count(*)::bigint from public.payment_receipts)
			   end as row_count
	union all
	select 'screen_receipts' as table_name, count(*)::bigint as row_count from public.screen_receipts
	union all
	select 'transactions' as table_name, count(*)::bigint as row_count from public.transactions
	union all
	select 'card_batch_details' as table_name, count(*)::bigint as row_count from public.card_batch_details
	union all
	select 'card_batch_headers' as table_name, count(*)::bigint as row_count from public.card_batch_headers
	union all
	select 'transaction_details' as table_name, count(*)::bigint as row_count from public.transaction_details
	union all
	select 'transaction_headers' as table_name, count(*)::bigint as row_count from public.transaction_headers
) t
order by table_name;
