-- =============================================================================
-- 2026-04-21  Auto-close batch core changes (1-5)
-- =============================================================================
-- Purpose:
--   Centralize batch policy at organization level and ensure batch rows are
--   terminal-specific for settlement/printing/close workflows.
--
-- Changes included:
--   1) Organization auto-close fields
--   2) Organization auto-close validation constraint
--   3) Ensure transaction_headers has terminal_id
--   4) Header index for terminal-specific open/close workflows
--   5) Detail index for open approved card rows used by settlement
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Organization auto-close fields
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column if not exists auto_close_batch_enabled boolean not null default false,
  add column if not exists auto_close_batch_time time;

create index if not exists idx_organizations_auto_close_enabled
  on public.organizations (auto_close_batch_enabled)
  where auto_close_batch_enabled = true;

-- -----------------------------------------------------------------------------
-- 2) Organization auto-close validation
--    If enabled, a trigger time must be provided.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'organizations_auto_close_requires_time_ck'
      and conrelid = 'public.organizations'::regclass
  ) then
    alter table public.organizations
      add constraint organizations_auto_close_requires_time_ck
      check (
        auto_close_batch_enabled = false
        or auto_close_batch_time is not null
      );
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 3) Ensure transaction_headers has terminal_id
-- -----------------------------------------------------------------------------
alter table public.transaction_headers
  add column if not exists terminal_id uuid;

-- Optional FK (safe add if missing)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'transaction_headers_terminal_id_fkey'
  ) then
    alter table public.transaction_headers
      add constraint transaction_headers_terminal_id_fkey
      foreign key (terminal_id)
      references public.terminals (id)
      on delete set null;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4) Header index for terminal-specific open/close lookup
-- -----------------------------------------------------------------------------
create index if not exists idx_txn_headers_org_loc_term_status_created
  on public.transaction_headers (organization_id, location_id, terminal_id, status, created_at desc);

-- -----------------------------------------------------------------------------
-- 5) Detail index for open approved card rows used by batch settlement
-- -----------------------------------------------------------------------------
create index if not exists idx_txn_details_open_approved_card
  on public.transaction_details (organization_id, location_id, payment_type, batch_status, status, created_at desc)
  where payment_type = 'd' and batch_status = 'o' and status = 'approved';
