-- =============================================================================
-- 2026-04-20  Add batch_status to transaction_details
-- =============================================================================
-- batch_status tracks whether a card transaction has been settled with the
-- card processor via a batch close.
--
--   'o' = open  (unsettled — can be voided via gateway)
--   'c' = closed (settled — can only be credited/refunded, not voided)
--
-- Only meaningful for payment_type = 'd' (card), but the column lives on all
-- rows harmlessly (cash/check rows keep the default 'o').
-- =============================================================================

alter table public.transaction_details
  add column if not exists batch_status char(1) not null default 'o'
    check (batch_status in ('o', 'c'));

-- Index to make the open-batch card query fast.
create index if not exists idx_txn_details_batch_open
  on public.transaction_details (organization_id, location_id, batch_status)
  where batch_status = 'o';
