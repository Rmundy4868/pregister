create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  organization_number text,
  name text not null,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.locations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  name text not null,
  address text,
  terminal_licenses integer not null default 1,
  terminals_active integer not null default 0,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.terminals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  organization_number text,
  location_id uuid not null,
  terminal_number text,
  name text not null,
  code text,
  is_active boolean not null default true,
  registered_device_id text,
  registered_device_label text,
  registered_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  location_id uuid not null,
  first_name text not null,
  last_name text,
  email text,
  phone text,
  role text,
  is_active boolean not null default true,
  full_name text,
  pin varchar(6) check (pin is null or pin ~ '^[0-9]{1,6}$'),
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.user_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  organization_id uuid not null,
  location_id uuid,
  role text not null check (role in ('owner', 'admin', 'manager', 'staff', 'cashier')),
  created_at timestamptz not null default timezone('utc', now())
);

alter table public.locations
  add column if not exists organization_id uuid,
  add column if not exists terminal_licenses integer not null default 1,
  add column if not exists terminals_active integer not null default 0,
  add column if not exists created_at timestamptz not null default timezone('utc', now());

alter table public.terminals
  add column if not exists organization_id uuid,
  add column if not exists organization_number text,
  add column if not exists location_id uuid,
  add column if not exists name text,
  add column if not exists code text,
  add column if not exists terminal_number text,
  add column if not exists is_active boolean not null default true,
  add column if not exists registered_device_id text,
  add column if not exists registered_device_label text,
  add column if not exists registered_at timestamptz,
  add column if not exists last_seen_at timestamptz,
  add column if not exists created_at timestamptz not null default timezone('utc', now());

alter table public.organizations
  add column if not exists organization_number text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'organizations_organization_number_chk'
  ) then
    alter table public.organizations
      add constraint organizations_organization_number_chk
      check (
        organization_number is null
        or organization_number ~ '^[0-9]{6}$'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'locations_terminal_licenses_chk'
  ) then
    alter table public.locations
      add constraint locations_terminal_licenses_chk
      check (terminal_licenses >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'locations_terminals_active_chk'
  ) then
    alter table public.locations
      add constraint locations_terminals_active_chk
      check (terminals_active >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'terminals_terminal_number_chk'
  ) then
    alter table public.terminals
      add constraint terminals_terminal_number_chk
      check (
        terminal_number is null
        or terminal_number ~ '^[0-9]{4}$'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'terminals_organization_number_chk'
  ) then
    alter table public.terminals
      add constraint terminals_organization_number_chk
      check (
        organization_number is null
        or organization_number ~ '^[0-9]{6}$'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'staff_pin_numeric_check'
  ) then
    alter table public.staff
      add constraint staff_pin_numeric_check
      check (
        pin is null
        or pin ~ '^[0-9]{1,6}$'
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'staff_role_chk'
  ) then
    alter table public.staff
      add constraint staff_role_chk
      check (
        role is null
        or role in ('owner', 'admin', 'manager', 'staff', 'cashier')
      );
  end if;
end $$;

create unique index if not exists idx_organizations_organization_number_unique
  on public.organizations (organization_number)
  where organization_number is not null;

create unique index if not exists idx_terminals_org_terminal_number_unique
  on public.terminals (organization_id, terminal_number)
  where terminal_number is not null;

create unique index if not exists idx_terminals_registered_device_id_unique
  on public.terminals (registered_device_id)
  where registered_device_id is not null;

create or replace function public.sync_terminal_organization_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  org_num text;
begin
  select o.organization_number
  into org_num
  from public.organizations o
  where o.id = new.organization_id;

  if org_num is not null and org_num <> '' then
    new.organization_number := org_num;
  end if;

  return new;
end;
$$;

create or replace function public.recompute_location_terminals_active(p_location_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_location_id is null then
    return;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'terminals_active'
  ) then
    update public.locations l
    set terminals_active = (
      select count(*)::integer
      from public.terminals t
      where t.location_id = p_location_id
        and coalesce(t.is_active, true) = true
    )
    where l.id = p_location_id;
  end if;
end;
$$;

create or replace function public.trg_sync_location_terminals_active()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recompute_location_terminals_active(
    case when tg_op = 'DELETE' then old.location_id else new.location_id end
  );

  if tg_op = 'UPDATE' and old.location_id is distinct from new.location_id then
    perform public.recompute_location_terminals_active(old.location_id);
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists trg_sync_terminal_org_number on public.terminals;
create trigger trg_sync_terminal_org_number
  before insert or update on public.terminals
  for each row
  execute function public.sync_terminal_organization_number();

drop trigger if exists trg_sync_location_terminals_active on public.terminals;
create trigger trg_sync_location_terminals_active
  after insert or update or delete on public.terminals
  for each row
  execute function public.trg_sync_location_terminals_active();

alter table public.staff
  add column if not exists organization_id uuid,
  add column if not exists location_id uuid,
  add column if not exists first_name text,
  add column if not exists last_name text,
  add column if not exists email text,
  add column if not exists phone text,
  add column if not exists role text,
  add column if not exists is_active boolean not null default true,
  add column if not exists full_name text,
  add column if not exists pin varchar(6),
  add column if not exists created_at timestamptz not null default timezone('utc', now());

alter table public.staff
  alter column full_name drop not null;

update public.staff
set full_name = trim(concat(coalesce(first_name, ''), ' ', coalesce(last_name, '')))
where coalesce(trim(full_name), '') = ''
  and (coalesce(trim(first_name), '') <> '' or coalesce(trim(last_name), '') <> '');

update public.staff
set first_name = split_part(coalesce(full_name, ''), ' ', 1)
where coalesce(trim(first_name), '') = ''
  and coalesce(trim(full_name), '') <> '';

update public.staff
set first_name = 'Staff'
where coalesce(trim(first_name), '') = '';

alter table public.staff
  alter column first_name set not null;

create unique index if not exists idx_locations_org_id_id_unique
  on public.locations (organization_id, id);

create unique index if not exists idx_user_memberships_user_org_location_unique
  on public.user_memberships (user_id, organization_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid));

create index if not exists idx_locations_org
  on public.locations (organization_id);

create index if not exists idx_terminals_org_location
  on public.terminals (organization_id, location_id);

create index if not exists idx_staff_org_location
  on public.staff (organization_id, location_id);

create index if not exists idx_memberships_user_org_location
  on public.user_memberships (user_id, organization_id, location_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'locations_organization_id_fkey'
  ) then
    alter table public.locations
      add constraint locations_organization_id_fkey
      foreign key (organization_id) references public.organizations (id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'terminals_org_location_fkey'
  ) then
    alter table public.terminals
      add constraint terminals_org_location_fkey
      foreign key (organization_id, location_id)
      references public.locations (organization_id, id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'staff_org_location_fkey'
  ) then
    alter table public.staff
      add constraint staff_org_location_fkey
      foreign key (organization_id, location_id)
      references public.locations (organization_id, id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'memberships_organization_id_fkey'
  ) then
    alter table public.user_memberships
      add constraint memberships_organization_id_fkey
      foreign key (organization_id) references public.organizations (id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'memberships_location_id_fkey'
  ) then
    alter table public.user_memberships
      add constraint memberships_location_id_fkey
      foreign key (location_id) references public.locations (id)
      on delete cascade;
  end if;
end $$;

alter table public.organizations enable row level security;
alter table public.user_memberships enable row level security;

grant usage on schema public to anon, authenticated;
grant select on table public.organizations to authenticated;
grant select on table public.user_memberships to authenticated;

drop policy if exists "Membership users can view own memberships" on public.user_memberships;
create policy "Membership users can view own memberships"
  on public.user_memberships
  for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "Organizations visible through membership" on public.organizations;
create policy "Organizations visible through membership"
  on public.organizations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = organizations.id
    )
  );
