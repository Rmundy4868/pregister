create extension if not exists pgcrypto;

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid,
  location_id uuid,
  organization_number text,
  terminal_number text,
  payment_type text not null check (payment_type in ('cash', 'card')),
  amount numeric(12,2) not null check (amount >= 0),
  success boolean not null,
  message text not null default '',
  created_at timestamptz not null default timezone('utc', now())
);

alter table public.transactions
  add column if not exists organization_id uuid,
  add column if not exists location_id uuid,
  add column if not exists organization_number text,
  add column if not exists terminal_number text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'transactions_organization_number_chk'
  ) then
    alter table public.transactions
      add constraint transactions_organization_number_chk
      check (
        organization_number is null
        or organization_number ~ '^[0-9]{6}$'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'transactions_terminal_number_chk'
  ) then
    alter table public.transactions
      add constraint transactions_terminal_number_chk
      check (
        terminal_number is null
        or terminal_number ~ '^[0-9]{4}$'
      );
  end if;
end $$;

create index if not exists idx_transactions_org_location
  on public.transactions (organization_id, location_id, created_at desc);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'transactions_org_location_fkey'
  ) then
    alter table public.transactions
      add constraint transactions_org_location_fkey
      foreign key (organization_id, location_id)
      references public.locations (organization_id, id)
      on delete cascade;
  end if;
end $$;

create or replace function public.set_transaction_scope_from_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  membership record;
begin
  if auth.uid() is null then
    return new;
  end if;

  select m.organization_id, m.location_id
  into membership
  from public.user_memberships m
  where m.user_id = auth.uid()
  order by case when m.location_id is null then 1 else 0 end, m.created_at asc
  limit 1;

  if new.organization_id is null then
    new.organization_id := membership.organization_id;
  end if;

  if new.location_id is null then
    new.location_id := membership.location_id;
  end if;

  return new;
end;
$$;

create or replace function public.set_transaction_scope_from_numbers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  matched_org_id uuid;
  matched_location_id uuid;
begin
  if new.organization_id is not null and new.location_id is not null then
    return new;
  end if;

  if new.organization_number is null or new.terminal_number is null then
    return new;
  end if;

  select t.organization_id, t.location_id
  into matched_org_id, matched_location_id
  from public.terminals t
  join public.organizations o on o.id = t.organization_id
  where o.organization_number = new.organization_number
    and t.terminal_number = new.terminal_number
  order by t.created_at asc
  limit 1;

  if new.organization_id is null then
    new.organization_id := matched_org_id;
  end if;

  if new.location_id is null then
    new.location_id := matched_location_id;
  end if;

  return new;
end;
$$;

create or replace function public.set_transaction_numbers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  org_num text;
  term_num text;
begin
  if new.organization_number is null and new.organization_id is not null then
    select o.organization_number
    into org_num
    from public.organizations o
    where o.id = new.organization_id;

    if org_num is not null and org_num <> '' then
      new.organization_number := org_num;
    end if;
  end if;

  if new.terminal_number is null and new.organization_id is not null and new.location_id is not null then
    select t.terminal_number
    into term_num
    from public.terminals t
    where t.organization_id = new.organization_id
      and t.location_id = new.location_id
      and t.terminal_number is not null
    order by t.created_at asc
    limit 1;

    if term_num is not null and term_num <> '' then
      new.terminal_number := term_num;
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.is_valid_location_scope(org_id uuid, loc_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.locations l
    where l.organization_id = org_id
      and l.id = loc_id
  );
$$;

create or replace function public.is_valid_terminal_scope(org_num text, term_num text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.terminals t
    join public.organizations o on o.id = t.organization_id
    where o.organization_number = org_num
      and t.terminal_number = term_num
  );
$$;

drop trigger if exists trg_set_transaction_scope on public.transactions;
create trigger trg_set_transaction_scope
  before insert on public.transactions
  for each row
  execute function public.set_transaction_scope_from_membership();

drop trigger if exists trg_set_transaction_scope_from_numbers on public.transactions;
create trigger trg_set_transaction_scope_from_numbers
  before insert on public.transactions
  for each row
  execute function public.set_transaction_scope_from_numbers();

drop trigger if exists trg_set_transaction_numbers on public.transactions;
create trigger trg_set_transaction_numbers
  before insert on public.transactions
  for each row
  execute function public.set_transaction_numbers();

create index if not exists idx_transactions_created_at
  on public.transactions (created_at desc);

alter table public.transactions enable row level security;

grant usage on schema public to anon, authenticated;
grant insert on table public.transactions to anon;
grant insert on table public.transactions to authenticated;
grant select on table public.transactions to authenticated;

drop policy if exists "Allow anon insert transactions" on public.transactions;
drop policy if exists "Transactions insert by scoped anon tenant" on public.transactions;
drop policy if exists "Transactions insert by scoped memberships" on public.transactions;
create policy "Transactions insert by scoped anon tenant"
  on public.transactions
  for insert
  to anon
  with check (
    (
      organization_id is not null
      and location_id is not null
      and public.is_valid_location_scope(transactions.organization_id, transactions.location_id)
    )
    or (
      organization_number is not null
      and terminal_number is not null
      and public.is_valid_terminal_scope(transactions.organization_number, transactions.terminal_number)
    )
  );

create policy "Transactions insert by scoped memberships"
  on public.transactions
  for insert
  to authenticated
  with check (
    organization_id is not null
    and location_id is not null
    and exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transactions.organization_id
        and (m.location_id is null or m.location_id = transactions.location_id)
        and m.role in ('owner', 'admin', 'manager', 'cashier', 'staff')
    )
  );

drop policy if exists "Allow anon read transactions" on public.transactions;
drop policy if exists "Transactions read by scoped memberships" on public.transactions;
create policy "Transactions read by scoped memberships"
  on public.transactions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = transactions.organization_id
        and (m.location_id is null or m.location_id = transactions.location_id)
    )
  );
