-- =============================================================================
-- 2026-05-09  Add server_id to transaction_headers
-- =============================================================================
-- Purpose:
--   Stores the numeric/alphanumeric employee identifier entered at the POS
--   (staff PIN / server number).  Used for tip reporting and tip adjustments
--   in this version.
--
-- Design note:
--   staff_id  (uuid FK) is reserved for the authenticated staff UUID that
--   will be populated by future login-gated flows.  server_id (text) is the
--   operator-entered short identifier — the two will be joined in a future
--   migration once PIN→UUID resolution is implemented.
-- =============================================================================

alter table public.transaction_headers
  add column if not exists server_id text;

comment on column public.transaction_headers.server_id is
  'Operator-entered employee/server identifier (PIN or short ID). '
  'Used for tip tracking and reporting. Will map to staff_id (uuid) in future versions.';

create index if not exists idx_transaction_headers_server_id
  on public.transaction_headers (organization_id, location_id, server_id)
  where server_id is not null;
