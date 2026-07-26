-- =============================================================================
-- 2026-05-16  Draft: Receipt ID Scheme (Batch-Terminal-Seq)
-- =============================================================================
-- Format (no prefixes):
--   <batch_number>-<terminal_number>-<seq>
-- Example:
--   001845-003-000412
--
-- Uniqueness scope:
--   organization_id + location_id + batch_number + terminal_number + txn_seq
--
-- Notes:
-- - Keep transaction_headers.id (uuid) as canonical internal ID.
-- - This draft assumes the app will provide NEW.batch_number when creating
--   transaction_headers. If batch_number is missing, trigger raises error.
-- - terminal_number is snapshotted on header at creation time.
-- =============================================================================

-- 1) Header fields ------------------------------------------------------------
alter table public.transaction_headers
  add column if not exists terminal_number text not null default '',
  add column if not exists batch_number bigint,
  add column if not exists txn_seq integer,
  add column if not exists receipt_id text;

-- 2) Optional denormalized copy on details for quick filtering/export ---------
alter table public.transaction_details
  add column if not exists receipt_id text;

-- 3) Sequence counter table keyed by org/location/terminal/batch -------------
create table if not exists public.transaction_header_seq_counters (
  organization_id uuid not null,
  location_id uuid not null,
  terminal_id uuid,
  terminal_number text not null,
  batch_number bigint not null,
  last_seq integer not null default 0,
  updated_at timestamptz not null default timezone('utc', now()),
  primary key (organization_id, location_id, terminal_number, batch_number)
);

create index if not exists idx_txn_seq_counter_org_loc_terminal_batch
  on public.transaction_header_seq_counters (
    organization_id, location_id, terminal_number, batch_number
  );

-- 4) Atomic next-sequence function -------------------------------------------
create or replace function public.next_transaction_header_seq(
  p_organization_id uuid,
  p_location_id uuid,
  p_terminal_id uuid,
  p_terminal_number text,
  p_batch_number bigint
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next integer;
begin
  insert into public.transaction_header_seq_counters (
    organization_id,
    location_id,
    terminal_id,
    terminal_number,
    batch_number,
    last_seq,
    updated_at
  )
  values (
    p_organization_id,
    p_location_id,
    p_terminal_id,
    p_terminal_number,
    p_batch_number,
    1,
    timezone('utc', now())
  )
  on conflict (organization_id, location_id, terminal_number, batch_number)
  do update
  set
    last_seq = public.transaction_header_seq_counters.last_seq + 1,
    terminal_id = coalesce(excluded.terminal_id, public.transaction_header_seq_counters.terminal_id),
    updated_at = timezone('utc', now())
  returning last_seq into v_next;

  return v_next;
end;
$$;

-- 5) Header trigger: assign txn_seq + receipt_id -----------------------------
create or replace function public.assign_receipt_id_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_terminal_number text;
  v_terminal_digits text;
  v_seq integer;
begin
  -- Respect explicit value if caller already provided a valid receipt_id.
  if coalesce(new.receipt_id, '') <> '' then
    return new;
  end if;

  -- Snapshot terminal_number from input or terminal_id lookup.
  v_terminal_number := nullif(trim(coalesce(new.terminal_number, '')), '');

  if v_terminal_number is null and new.terminal_id is not null then
    select nullif(trim(coalesce(t.terminal_number, '')), '')
    into v_terminal_number
    from public.terminals t
    where t.id = new.terminal_id
    limit 1;
  end if;

  if v_terminal_number is null then
    raise exception
      'transaction_headers.terminal_number is required to generate receipt_id';
  end if;

  if new.batch_number is null or new.batch_number <= 0 then
    raise exception
      'transaction_headers.batch_number must be provided (> 0) to generate receipt_id';
  end if;

  v_terminal_digits := regexp_replace(v_terminal_number, '[^0-9]', '', 'g');
  if v_terminal_digits = '' then
    -- fallback: preserve original text in sequence key, but display as 000
    v_terminal_digits := '000';
  end if;

  if new.txn_seq is null or new.txn_seq <= 0 then
    v_seq := public.next_transaction_header_seq(
      new.organization_id,
      new.location_id,
      new.terminal_id,
      v_terminal_number,
      new.batch_number
    );
    new.txn_seq := v_seq;
  else
    v_seq := new.txn_seq;
  end if;

  new.terminal_number := v_terminal_number;

  new.receipt_id :=
      lpad(new.batch_number::text, 6, '0')
      || '-'
      || lpad(right(v_terminal_digits, 3), 3, '0')
      || '-'
      || lpad(v_seq::text, 6, '0');

  return new;
end;
$$;

drop trigger if exists trg_assign_receipt_id_before_insert
  on public.transaction_headers;

create trigger trg_assign_receipt_id_before_insert
before insert on public.transaction_headers
for each row
execute function public.assign_receipt_id_before_insert();

-- 6) Keep details.receipt_id synced from header ------------------------------
create or replace function public.sync_detail_receipt_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.receipt_id, '') = '' then
    select h.receipt_id
    into new.receipt_id
    from public.transaction_headers h
    where h.id = new.transaction_header_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_detail_receipt_id
  on public.transaction_details;

create trigger trg_sync_detail_receipt_id
before insert on public.transaction_details
for each row
execute function public.sync_detail_receipt_id();

-- 7) Constraints / indexes ----------------------------------------------------
create unique index if not exists idx_txn_headers_receipt_scope_unique
  on public.transaction_headers (
    organization_id,
    location_id,
    batch_number,
    terminal_number,
    txn_seq
  )
  where batch_number is not null
    and nullif(trim(terminal_number), '') is not null
    and txn_seq is not null;

create unique index if not exists idx_txn_headers_receipt_id_unique
  on public.transaction_headers (organization_id, location_id, receipt_id)
  where nullif(trim(receipt_id), '') is not null;

create index if not exists idx_txn_headers_receipt_id
  on public.transaction_headers (receipt_id)
  where receipt_id is not null;

create index if not exists idx_txn_details_receipt_id
  on public.transaction_details (receipt_id)
  where receipt_id is not null;

-- 8) Backfill helper (run in controlled batches, optional) --------------------
-- NOTE: this is intentionally NOT auto-run in migration.
-- If using a clean restart (truncate transaction tables first), no backfill is needed.
-- Otherwise, TODO:
--   1) Decide source for batch_number on historical rows.
--   2) Populate terminal_number from terminals table where missing.
--   3) Backfill txn_seq/receipt_id in deterministic order per
--      (org, location, terminal_number, batch_number).

-- =============================================================================
-- End Draft
-- =============================================================================
