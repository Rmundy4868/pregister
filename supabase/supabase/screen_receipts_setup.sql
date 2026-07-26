create extension if not exists pgcrypto;

create table if not exists public.screen_receipts (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid references public.transactions (id) on delete cascade,
  organization_id uuid,
  location_id uuid,
  item_sku numeric(12,2) not null default 0,
  item_cost numeric(12,2) not null default 0,
  ext_cost numeric(12,2) not null default 0,
  qty integer not null default 1 check (qty > 0),
  description text not null default '',
  discount_type text not null default 'None'
    check (discount_type in ('None', 'Percent', 'Amount')),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  total_tax numeric(12,2) not null default 0 check (total_tax >= 0),
  created_at timestamptz not null default timezone('utc', now())
);

-- Ensure new schema columns exist.
alter table public.screen_receipts
  add column if not exists transaction_id uuid references public.transactions (id) on delete cascade,
  add column if not exists organization_id uuid,
  add column if not exists location_id uuid,
  add column if not exists item_sku numeric(12,2) not null default 0,
  add column if not exists item_cost numeric(12,2) not null default 0,
  add column if not exists ext_cost numeric(12,2) not null default 0,
  add column if not exists qty integer not null default 1,
  add column if not exists description text not null default '',
  add column if not exists discount_type text not null default 'None',
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists total_tax numeric(12,2) not null default 0,
  add column if not exists created_at timestamptz not null default timezone('utc', now());

-- Rename legacy columns when present.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'subtotal'
  ) and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'item_cost'
  ) then
    execute 'alter table public.screen_receipts rename column subtotal to item_cost';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'total'
  ) and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'ext_cost'
  ) then
    execute 'alter table public.screen_receipts rename column total to ext_cost';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'item'
  ) and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'screen_receipts'
      and column_name = 'item_sku'
  ) then
    execute 'alter table public.screen_receipts rename column item to item_sku';
  end if;
end $$;

-- Backfill new columns from legacy columns if both exist.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'subtotal'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'item_cost'
  ) then
    execute 'update public.screen_receipts set item_cost = subtotal where (item_cost = 0 or item_cost is null) and subtotal is not null';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'total'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'ext_cost'
  ) then
    execute 'update public.screen_receipts set ext_cost = total where (ext_cost = 0 or ext_cost is null) and total is not null';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'item'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'screen_receipts' and column_name = 'item_sku'
  ) then
    execute 'update public.screen_receipts set item_sku = item where (item_sku = 0 or item_sku is null) and item is not null';
  end if;
end $$;

create index if not exists idx_screen_receipts_transaction_id
  on public.screen_receipts (transaction_id);

create index if not exists idx_screen_receipts_created_at
  on public.screen_receipts (created_at desc);

alter table public.screen_receipts enable row level security;

grant usage on schema public to anon, authenticated;
grant insert on table public.screen_receipts to anon, authenticated;
grant select on table public.screen_receipts to authenticated;

drop policy if exists "Screen receipts insert by scoped memberships" on public.screen_receipts;
create policy "Screen receipts insert by scoped memberships"
  on public.screen_receipts
  for insert
  to authenticated
  with check (
    organization_id is not null
    and location_id is not null
    and exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = screen_receipts.organization_id
        and (m.location_id is null or m.location_id = screen_receipts.location_id)
        and m.role in ('owner', 'admin', 'manager', 'cashier', 'staff')
    )
  );

drop policy if exists "Screen receipts read by scoped memberships" on public.screen_receipts;
create policy "Screen receipts read by scoped memberships"
  on public.screen_receipts
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = screen_receipts.organization_id
        and (m.location_id is null or m.location_id = screen_receipts.location_id)
    )
  );
