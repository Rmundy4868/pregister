-- =============================================================================
-- 2026-05-09  Add invoice/reference field to transaction headers
-- =============================================================================
-- Purpose:
--   Keep customer-entered invoice/reference separate from processor reference_id.
--
-- Notes:
--   - Processor reference_id remains on transaction_details.reference_id.
--   - This column stores the customer-facing invoice/reference value entered
--     in the Customer / Transaction Info dialog.
-- =============================================================================

alter table public.transaction_headers
  add column if not exists invoice_reference text;

create index if not exists idx_transaction_headers_invoice_reference
  on public.transaction_headers (organization_id, location_id, invoice_reference)
  where invoice_reference is not null;
