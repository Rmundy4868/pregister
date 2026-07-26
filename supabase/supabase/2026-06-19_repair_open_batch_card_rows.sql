-- Repair script for open-batch card detail visibility issues.
--
-- Purpose:
-- 1) Backfill missing batch_status on card rows to 'o' so open-batch queries can see them.
-- 2) Normalize subtype casing/spacing used by UI dedup logic.
-- 3) Ensure originals referenced by void rows are marked voided.
--
-- Safe behavior:
-- - Does NOT reopen already closed rows (batch_status = 'c' is untouched).
-- - Only fills missing/blank values.

begin;

-- 1) Card rows missing batch_status were invisible to open-batch filters.
update public.transaction_details
set batch_status = 'o'
where payment_type = 'd'
  and coalesce(trim(batch_status), '') = '';

-- 2) Normalize subtype values to lowercase trimmed canonical values.
update public.transaction_details
set subtype = lower(trim(subtype))
where subtype is not null
  and subtype <> lower(trim(subtype));

-- 3) If a void row points to an original sale, enforce original status='voided'.
update public.transaction_details as original_row
set status = 'voided'
from public.transaction_details as void_row
where lower(coalesce(void_row.subtype, '')) = 'v'
  and void_row.original_detail_id is not null
  and void_row.original_detail_id = original_row.id
  and coalesce(original_row.status, '') <> 'voided';

commit;

-- Optional verification queries
-- select batch_status, count(*)
-- from public.transaction_details
-- where payment_type = 'd'
-- group by batch_status
-- order by batch_status;
--
-- select subtype, status, count(*)
-- from public.transaction_details
-- where payment_type = 'd'
-- group by subtype, status
-- order by subtype, status;
