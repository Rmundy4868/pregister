-- =============================================================================
-- 2026-04-16  Transaction Ledger Schema
-- =============================================================================
-- Adds:
--   1. transaction_headers  — master transaction record with totals & status
--   2. transaction_details  — append-only payment/adjustment ledger
--   3. Alters transactions  — adds fk to transaction_headers (backward-compat)
--   4. Alters screen_receipts — ensures transaction_header_id FK column exists
--   5. RLS policies for both new tables
--   6. DB function: recalculate_transaction_header() — keeps header totals in sync
--   7. Trigger: fires after insert on transaction_details
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. TRANSACTION HEADERS
-- ---------------------------------------------------------------------------
create table if not exists public.transaction_headers (
  id                  uuid        primary key default gen_random_uuid(),
  organization_id     uuid        not null,
  location_id         uuid        not null,
  staff_id            uuid,                              -- FK → staff.id (nullable: anonymous/kiosk)
  staff_name          text        not null default '',   -- snapshot at time of sale
  terminal_id         uuid,
  terminal_name       text        not null default '',   -- snapshot at time of sale
  customer_id         uuid,                              -- nullable FK → customers
  customer_snapshot   jsonb,                             -- name/address/phone at time of sale
  subtotal            numeric(12,2) not null default 0,  -- items before tax
  tax                 numeric(12,2) not null default 0,
  total               numeric(12,2) not null default 0,  -- subtotal + tax
  amount_paid         numeric(12,2) not null default 0,  -- SUM of approved detail amounts
  amount_due          numeric(12,2) not null default 0,  -- total - amount_paid
  status              text        not null default 'open'
                        check (status in ('open','closed','voided')),
  created_at          timestamptz not null default timezone('utc', now()),
  closed_at           timestamptz,
  voided_at           timestamptz
);

-- Ensure new columns exist if table was already created:
alter table public.transaction_headers
  add column if not exists staff_id          uuid,
  add column if not exists staff_name        text        not null default '',
  add column if not exists terminal_id       uuid,
  add column if not exists terminal_name     text        not null default '',
  add column if not exists customer_id       uuid,
  add column if not exists customer_snapshot jsonb,
  add column if not exists subtotal          numeric(12,2) not null default 0,
  add column if not exists tax               numeric(12,2) not null default 0,
  add column if not exists total             numeric(12,2) not null default 0,
  add column if not exists amount_paid       numeric(12,2) not null default 0,
  add column if not exists amount_due        numeric(12,2) not null default 0,
  add column if not exists closed_at         timestamptz,
  add column if not exists voided_at         timestamptz;

create index if not exists idx_txn_headers_org_loc_created
  on public.transaction_headers (organization_id, location_id, created_at desc);

create index if not exists idx_txn_headers_staff_id
  on public.transaction_headers (staff_id);

create index if not exists idx_txn_headers_status
  on public.transaction_headers (status);

-- FK: org+location must exist  
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'txn_headers_org_location_fkey'
  ) then
    alter table public.transaction_headers
      add constraint txn_headers_org_location_fkey
      foreign key (organization_id, location_id)
      references public.locations (organization_id, id)
      on delete restrict;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. TRANSACTION DETAILS  (append-only ledger)
-- ---------------------------------------------------------------------------
create table if not exists public.transaction_details (
  id                        uuid        primary key default gen_random_uuid(),
  transaction_header_id     uuid        not null
                              references public.transaction_headers (id) on delete cascade,
  organization_id           uuid        not null,   -- denormalized for RLS
  location_id               uuid        not null,   -- denormalized for RLS
  -- Payment classification
  payment_type              char(1)     not null
                              check (payment_type in ('c','d','g','k','e','x')),
                              -- c=cash  d=card(debit/credit)  g=gift_card
                              -- k=check  e=ebt/snap  x=comp/writeoff
  subtype                   char(1)     not null default 's'
                              check (subtype in ('s','r','v','a')),
                              -- s=sale  r=refund  v=void  a=adjustment(tip/amount)
  amount                    numeric(12,2) not null,
                              -- positive = charge/sale, negative = refund/void credit
  status                    text        not null default 'pending'
                              check (status in ('pending','approved','declined','voided')),
  -- Reference & gateway
  reference_id              text,                   -- app-generated POS-{timestamp}
  gateway_provider          text,                   -- dejavoo | epn | stripe | square
  gateway_token             text,                   -- token for void/refund/tip-adjust
  auth_code                 text,
  -- Card-specific
  card_last4                text,
  card_type                 text,                   -- Visa | MC | Amex | Discover | Debit
  -- Cash-specific
  cash_tendered             numeric(12,2),
  cash_change               numeric(12,2),
  -- Gift card specific
  gift_card_number          text,
  gift_card_balance_before  numeric(12,2),
  gift_card_balance_after   numeric(12,2),
  -- Adjustment linkage
  original_detail_id        uuid
                              references public.transaction_details (id) on delete restrict,
                              -- NULL on subtype='s'; points to original row for r/v/a
  -- Full gateway response blob
  gateway_raw               jsonb,
  created_at                timestamptz not null default timezone('utc', now())
);

-- Ensure new columns exist if table was already created:
alter table public.transaction_details
  add column if not exists gateway_token             text,
  add column if not exists card_last4                text,
  add column if not exists card_type                 text,
  add column if not exists cash_tendered             numeric(12,2),
  add column if not exists cash_change               numeric(12,2),
  add column if not exists gift_card_number          text,
  add column if not exists gift_card_balance_before  numeric(12,2),
  add column if not exists gift_card_balance_after   numeric(12,2),
  add column if not exists original_detail_id        uuid
                              references public.transaction_details (id) on delete restrict,
  add column if not exists gateway_raw               jsonb;

create index if not exists idx_txn_details_header_id
  on public.transaction_details (transaction_header_id);

create index if not exists idx_txn_details_org_loc
  on public.transaction_details (organization_id, location_id, created_at desc);

create index if not exists idx_txn_details_gateway_token
  on public.transaction_details (gateway_token)
  where gateway_token is not null;

create index if not exists idx_txn_details_original_detail
  on public.transaction_details (original_detail_id)
  where original_detail_id is not null;

-- ---------------------------------------------------------------------------
-- 3. ALTER EXISTING transactions TABLE  (backward-compat bridge)
--    Add transaction_header_id so old rows can be linked to a header if needed.
-- ---------------------------------------------------------------------------
alter table public.transactions
  add column if not exists transaction_header_id uuid
    references public.transaction_headers (id) on delete set null;

create index if not exists idx_transactions_header_id
  on public.transactions (transaction_header_id)
  where transaction_header_id is not null;

-- ---------------------------------------------------------------------------
-- 4. ALTER screen_receipts — ensure transaction_header_id column exists
-- ---------------------------------------------------------------------------
alter table public.screen_receipts
  add column if not exists transaction_header_id uuid
    references public.transaction_headers (id) on delete set null;

create index if not exists idx_screen_receipts_header_id
  on public.screen_receipts (transaction_header_id)
  where transaction_header_id is not null;

-- ---------------------------------------------------------------------------
-- 5. FUNCTION: recalculate_transaction_header
--    Recomputes amount_paid and amount_due from approved detail rows.
--    Called after every insert into transaction_details.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_transaction_header()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid    numeric(12,2);
  v_total   numeric(12,2);
  v_due     numeric(12,2);
  v_status  text;
begin
  -- Sum all approved detail amounts for this header.
  -- Refunds/voids insert negative amounts, so they naturally reduce paid.
  select coalesce(sum(d.amount), 0)
  into v_paid
  from public.transaction_details d
  where d.transaction_header_id = new.transaction_header_id
    and d.status = 'approved';

  select h.total
  into v_total
  from public.transaction_headers h
  where h.id = new.transaction_header_id;

  v_due := greatest(v_total - v_paid, 0);

  -- Determine header status
  if v_due <= 0.001 then
    v_status := 'closed';
  else
    v_status := 'open';
  end if;

  -- If a void row just landed, mark voided
  if new.subtype = 'v' and new.status = 'approved' then
    v_status := 'voided';
  end if;

  update public.transaction_headers
  set
    amount_paid = v_paid,
    amount_due  = v_due,
    status      = v_status,
    closed_at   = case
                    when v_status = 'closed'  and closed_at is null
                    then timezone('utc', now())
                    else closed_at
                  end,
    voided_at   = case
                    when v_status = 'voided' and voided_at is null
                    then timezone('utc', now())
                    else voided_at
                  end
  where id = new.transaction_header_id;

  return new;
end;
$$;

drop trigger if exists trg_recalculate_header on public.transaction_details;
create trigger trg_recalculate_header
  after insert on public.transaction_details
  for each row
  execute function public.recalculate_transaction_header();

-- ---------------------------------------------------------------------------
-- 6. RLS — transaction_headers
-- ---------------------------------------------------------------------------
alter table public.transaction_headers enable row level security;

grant usage on schema public to anon, authenticated;
grant select, insert, update on table public.transaction_headers to authenticated;
grant insert on table public.transaction_headers to anon;

drop policy if exists "TxnHeaders insert authenticated" on public.transaction_headers;
create policy "TxnHeaders insert authenticated"
  on public.transaction_headers
  for insert
  to authenticated
  with check (
    organization_id is not null
    and location_id is not null
    and exists (
      select 1 from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transaction_headers.organization_id
        and (m.location_id is null or m.location_id = transaction_headers.location_id)
        and m.role in ('owner','admin','manager','cashier','staff')
    )
  );

drop policy if exists "TxnHeaders insert anon" on public.transaction_headers;
create policy "TxnHeaders insert anon"
  on public.transaction_headers
  for insert
  to anon
  with check (
    organization_id is not null
    and location_id is not null
    and public.is_valid_location_scope(transaction_headers.organization_id, transaction_headers.location_id)
  );

drop policy if exists "TxnHeaders update authenticated" on public.transaction_headers;
create policy "TxnHeaders update authenticated"
  on public.transaction_headers
  for update
  to authenticated
  using (
    exists (
      select 1 from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transaction_headers.organization_id
        and (m.location_id is null or m.location_id = transaction_headers.location_id)
    )
  );

-- Allow the security definer trigger function to update headers from anon context
drop policy if exists "TxnHeaders update anon" on public.transaction_headers;
create policy "TxnHeaders update anon"
  on public.transaction_headers
  for update
  to anon
  using (true)
  with check (true);

drop policy if exists "TxnHeaders read authenticated" on public.transaction_headers;
create policy "TxnHeaders read authenticated"
  on public.transaction_headers
  for select
  to authenticated
  using (
    exists (
      select 1 from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transaction_headers.organization_id
        and (m.location_id is null or m.location_id = transaction_headers.location_id)
    )
  );

-- Allow anon to SELECT headers they just inserted (required for .insert().select('id').single())
drop policy if exists "TxnHeaders read anon" on public.transaction_headers;
create policy "TxnHeaders read anon"
  on public.transaction_headers
  for select
  to anon
  using (
    public.is_valid_location_scope(transaction_headers.organization_id, transaction_headers.location_id)
  );

-- ---------------------------------------------------------------------------
-- 7. RLS — transaction_details
-- ---------------------------------------------------------------------------
alter table public.transaction_details enable row level security;

grant select, insert on table public.transaction_details to authenticated;
grant select, insert on table public.transaction_details to anon;

drop policy if exists "TxnDetails insert authenticated" on public.transaction_details;
create policy "TxnDetails insert authenticated"
  on public.transaction_details
  for insert
  to authenticated
  with check (
    organization_id is not null
    and location_id is not null
    and exists (
      select 1 from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transaction_details.organization_id
        and (m.location_id is null or m.location_id = transaction_details.location_id)
        and m.role in ('owner','admin','manager','cashier','staff')
    )
  );

drop policy if exists "TxnDetails insert anon" on public.transaction_details;
create policy "TxnDetails insert anon"
  on public.transaction_details
  for insert
  to anon
  with check (
    organization_id is not null
    and location_id is not null
    and public.is_valid_location_scope(transaction_details.organization_id, transaction_details.location_id)
  );

drop policy if exists "TxnDetails read authenticated" on public.transaction_details;
create policy "TxnDetails read authenticated"
  on public.transaction_details
  for select
  to authenticated
  using (
    exists (
      select 1 from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transaction_details.organization_id
        and (m.location_id is null or m.location_id = transaction_details.location_id)
    )
  );

-- Allow anon to SELECT details they just inserted (required for .insert().select('id').single())
drop policy if exists "TxnDetails read anon" on public.transaction_details;
create policy "TxnDetails read anon"
  on public.transaction_details
  for select
  to anon
  using (
    public.is_valid_location_scope(transaction_details.organization_id, transaction_details.location_id)
  );

-- =============================================================================
-- END
-- =============================================================================
