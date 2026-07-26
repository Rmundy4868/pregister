-- ============================================================================
-- 2026-05-16: Reset transaction data for clean test environment
-- ============================================================================
-- Use in Supabase SQL editor when you want a full transaction reset.
-- This clears all transaction posting and batch-close artifacts.

begin;

truncate table
  public.card_batch_details,
  public.card_batch_headers,
  public.transaction_details,
  public.transaction_headers,
  public.transactions,
  public.screen_receipts
restart identity cascade;

-- If the receipt sequence counter table exists, clear it too.
do $$
begin
  if to_regclass('public.transaction_header_seq_counters') is not null then
    execute 'truncate table public.transaction_header_seq_counters restart identity';
  end if;
end;
$$;

commit;

-- Quick verification (should all be 0 rows):
-- select 'card_batch_details' as table_name, count(*) from public.card_batch_details
-- union all select 'card_batch_headers', count(*) from public.card_batch_headers
-- union all select 'transaction_details', count(*) from public.transaction_details
-- union all select 'transaction_headers', count(*) from public.transaction_headers
-- union all select 'transactions', count(*) from public.transactions
-- union all select 'screen_receipts', count(*) from public.screen_receipts;
