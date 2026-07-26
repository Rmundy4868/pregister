-- =============================================================================
-- 2026-05-16: Finalize Receipt ID cleanup (remove legacy operator naming)
-- =============================================================================
-- Purpose:
-- - Keep only receipt_id in transaction headers/details
-- - Remove legacy alias triggers/functions/indexes
-- - Remove legacy operator_txn_id columns after data copy
--
-- Safe to run multiple times.

begin;

-- 1) Ensure canonical receipt_id columns exist.
alter table public.transaction_headers
  add column if not exists receipt_id text;

alter table public.transaction_details
  add column if not exists receipt_id text;

-- 2) Backfill receipt_id from legacy column if still present.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'transaction_headers'
      and column_name = 'operator_txn_id'
  ) then
    execute $sql$
      update public.transaction_headers
      set receipt_id = operator_txn_id
      where coalesce(receipt_id, '') = ''
        and coalesce(operator_txn_id, '') <> ''
    $sql$;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'transaction_details'
      and column_name = 'operator_txn_id'
  ) then
    execute $sql$
      update public.transaction_details
      set receipt_id = operator_txn_id
      where coalesce(receipt_id, '') = ''
        and coalesce(operator_txn_id, '') <> ''
    $sql$;
  end if;
end;
$$;

-- 3) Drop legacy/bridge triggers and functions.
drop trigger if exists trg_sync_receipt_id_alias_header
  on public.transaction_headers;
drop trigger if exists trg_sync_receipt_id_alias_detail
  on public.transaction_details;

drop trigger if exists trg_assign_operator_txn_id_before_insert
  on public.transaction_headers;
drop trigger if exists trg_sync_detail_operator_txn_id
  on public.transaction_details;

drop function if exists public.sync_receipt_id_alias_header();
drop function if exists public.sync_receipt_id_alias_detail();
drop function if exists public.assign_operator_txn_id_before_insert();
drop function if exists public.sync_detail_operator_txn_id();

-- 4) Drop legacy indexes (if they exist).
drop index if exists public.idx_txn_headers_operator_scope_unique;
drop index if exists public.idx_txn_headers_operator_txn_id_unique;
drop index if exists public.idx_txn_headers_operator_txn_id;
drop index if exists public.idx_txn_details_operator_txn_id;

-- 5) Ensure receipt_id indexes exist.
create unique index if not exists idx_txn_headers_receipt_id_unique
  on public.transaction_headers (organization_id, location_id, receipt_id)
  where nullif(trim(receipt_id), '') is not null;

create index if not exists idx_txn_headers_receipt_id
  on public.transaction_headers (receipt_id)
  where receipt_id is not null;

create index if not exists idx_txn_details_receipt_id
  on public.transaction_details (receipt_id)
  where receipt_id is not null;

-- 6) Remove legacy columns.
alter table public.transaction_headers
  drop column if exists operator_txn_id;

alter table public.transaction_details
  drop column if exists operator_txn_id;

-- 7) Receipt-only column comments.
comment on column public.transaction_headers.receipt_id is
  'Human-readable receipt identifier (batch-terminal-seq).';

comment on column public.transaction_details.receipt_id is
  'Denormalized receipt identifier copied from transaction_headers.receipt_id.';

commit;
