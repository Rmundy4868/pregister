-- =============================================================================
-- 2026-04-21  Organization auto-close batch settings
-- =============================================================================
-- Adds org-level controls for automatic batch settlement.
--
-- auto_close_batch_enabled: when true, terminals may auto-close at configured time
-- auto_close_batch_time: 24-hour time (HH:MM[:SS]) for daily auto-close trigger
-- =============================================================================

alter table public.organizations
  add column if not exists auto_close_batch_enabled boolean not null default false,
  add column if not exists auto_close_batch_time time;

create index if not exists idx_organizations_auto_close_enabled
  on public.organizations (auto_close_batch_enabled)
  where auto_close_batch_enabled = true;
