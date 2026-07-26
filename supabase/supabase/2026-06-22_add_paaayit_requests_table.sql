-- =============================================================================
-- 2026-06-22  PaaayIT Request table (additive only)
-- =============================================================================
-- Purpose:
--   Create a first-class ledger for hosted payment requests/invoices named
--   "PaaayIT Request" without changing existing checkout/transaction flows.
--
-- Safety:
--   - Additive migration only (new table, indexes, policies).
--   - No changes to existing transaction tables or constraints.
-- =============================================================================

create extension if not exists pgcrypto;

create table if not exists public.paaayit_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  terminal_id uuid,

  request_number text not null,
  request_title text not null default 'PaaayIT Request',

  status text not null default 'draft'
    check (status in (
      'draft',
      'pending',
      'sent',
      'viewed',
      'paid',
      'expired',
      'cancelled',
      'failed',
      'reconciled'
    )),

  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'USD',

  customer_name text not null default '',
  customer_email text not null default '',
  customer_mobile text not null default '',
  description text not null default '',

  -- Hosted payment provider correlation keys.
  hpp_transaction_reference_id text,
  hpp_payment_url text,
  hpp_payment_id text,

  -- Reconciliation against iPOS Pays batch/charge exports.
  reconciliation_reference_id text,

  expires_at timestamptz not null default (timezone('utc', now()) + interval '72 hours'),
  sent_at timestamptz,
  viewed_at timestamptz,
  paid_at timestamptz,
  expired_at timestamptz,
  cancelled_at timestamptz,

  request_payload jsonb not null default '{}'::jsonb,
  provider_response_payload jsonb,

  created_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),

  constraint paaayit_requests_request_number_not_blank
    check (char_length(trim(request_number)) > 0),
  constraint paaayit_requests_request_title_not_blank
    check (char_length(trim(request_title)) > 0),
  constraint paaayit_requests_expires_after_create
    check (expires_at > created_at)
);

comment on table public.paaayit_requests is
  'Hosted payment request/invoice ledger for PaaayIT Request flow.';

comment on column public.paaayit_requests.hpp_transaction_reference_id is
  'Unique transaction reference sent to external-payment-transaction API.';

comment on column public.paaayit_requests.reconciliation_reference_id is
  'Reference used to match settled charges in iPOS Pays batch reports.';

create unique index if not exists idx_paaayit_requests_org_request_number
  on public.paaayit_requests (organization_id, request_number);

create unique index if not exists idx_paaayit_requests_hpp_tx_reference
  on public.paaayit_requests (hpp_transaction_reference_id)
  where hpp_transaction_reference_id is not null;

create index if not exists idx_paaayit_requests_org_loc_status_expires
  on public.paaayit_requests (organization_id, location_id, status, expires_at);

create index if not exists idx_paaayit_requests_created_at
  on public.paaayit_requests (created_at desc);

create index if not exists idx_paaayit_requests_paid_at
  on public.paaayit_requests (paid_at desc)
  where paid_at is not null;

-- Optional FK when terminals table exists.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'paaayit_requests_terminal_id_fkey'
  ) then
    alter table public.paaayit_requests
      add constraint paaayit_requests_terminal_id_fkey
      foreign key (terminal_id)
      references public.terminals (id)
      on delete set null;
  end if;
end $$;

create or replace function public.touch_paaayit_requests_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists trg_touch_paaayit_requests_updated_at on public.paaayit_requests;
create trigger trg_touch_paaayit_requests_updated_at
  before update on public.paaayit_requests
  for each row
  execute function public.touch_paaayit_requests_updated_at();

-- RLS ------------------------------------------------------------------------
alter table public.paaayit_requests enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update on table public.paaayit_requests to authenticated;

drop policy if exists "PaaayITRequests read by scoped memberships" on public.paaayit_requests;
create policy "PaaayITRequests read by scoped memberships"
  on public.paaayit_requests
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = paaayit_requests.organization_id
        and (m.location_id is null or m.location_id = paaayit_requests.location_id)
    )
  );

drop policy if exists "PaaayITRequests insert by scoped memberships" on public.paaayit_requests;
create policy "PaaayITRequests insert by scoped memberships"
  on public.paaayit_requests
  for insert
  to authenticated
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = paaayit_requests.organization_id
        and (m.location_id is null or m.location_id = paaayit_requests.location_id)
        and m.role in ('owner', 'admin', 'manager', 'cashier', 'staff')
    )
  );

drop policy if exists "PaaayITRequests update by scoped memberships" on public.paaayit_requests;
create policy "PaaayITRequests update by scoped memberships"
  on public.paaayit_requests
  for update
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = paaayit_requests.organization_id
        and (m.location_id is null or m.location_id = paaayit_requests.location_id)
        and m.role in ('owner', 'admin', 'manager', 'cashier', 'staff')
    )
  )
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = paaayit_requests.organization_id
        and (m.location_id is null or m.location_id = paaayit_requests.location_id)
        and m.role in ('owner', 'admin', 'manager', 'cashier', 'staff')
    )
  );
