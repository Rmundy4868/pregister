-- Phase 1 foundation for Master Console + Partner Portal.
-- Adds partner and master-console identities plus shared login RPC.
-- Safe to run multiple times.

begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.distribution_partners (
  id uuid primary key default gen_random_uuid(),
  partner_id text not null,
  company_name text not null,
  contact_first_name text,
  contact_last_name text,
  email text,
  username text not null,
  password_hash text not null,
  phone text,
  address_line_1 text,
  address_line_2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  last_login_at timestamptz
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'distribution_partners_partner_id_format_chk'
  ) then
    alter table public.distribution_partners
      add constraint distribution_partners_partner_id_format_chk
      check (partner_id ~ '^[0-9]{6}$') not valid;

    alter table public.distribution_partners
      validate constraint distribution_partners_partner_id_format_chk;
  end if;
end
$$;

create unique index if not exists idx_distribution_partners_partner_id
  on public.distribution_partners (partner_id);

create unique index if not exists idx_distribution_partners_username
  on public.distribution_partners (lower(username));

create unique index if not exists idx_distribution_partners_email
  on public.distribution_partners (lower(email))
  where email is not null;

create table if not exists public.master_console_users (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  password_hash text not null,
  display_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  last_login_at timestamptz
);

create unique index if not exists idx_master_console_users_username
  on public.master_console_users (lower(username));

alter table public.organizations
  add column if not exists partner_id text;

create index if not exists idx_organizations_partner_id
  on public.organizations (partner_id)
  where partner_id is not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'organizations_partner_id_fkey'
  ) then
    alter table public.organizations
      add constraint organizations_partner_id_fkey
      foreign key (partner_id)
      references public.distribution_partners (partner_id)
      on update cascade
      on delete set null;
  end if;
end
$$;

create or replace function public.trg_set_updated_at()
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

drop trigger if exists trg_distribution_partners_set_updated_at on public.distribution_partners;
create trigger trg_distribution_partners_set_updated_at
  before update on public.distribution_partners
  for each row
  execute function public.trg_set_updated_at();

drop trigger if exists trg_master_console_users_set_updated_at on public.master_console_users;
create trigger trg_master_console_users_set_updated_at
  before update on public.master_console_users
  for each row
  execute function public.trg_set_updated_at();

create or replace function public.upsert_distribution_partner(
  p_partner_id text,
  p_company_name text,
  p_contact_first_name text default null,
  p_contact_last_name text default null,
  p_email text default null,
  p_username text default null,
  p_password text default null,
  p_phone text default null,
  p_address_line_1 text default null,
  p_address_line_2 text default null,
  p_city text default null,
  p_state text default null,
  p_postal_code text default null,
  p_country text default 'US',
  p_is_active boolean default true
)
returns public.distribution_partners
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id text := nullif(trim(coalesce(p_partner_id, '')), '');
  v_company_name text := nullif(trim(coalesce(p_company_name, '')), '');
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_password text := nullif(trim(coalesce(p_password, '')), '');
  v_existing public.distribution_partners;
begin
  if v_partner_id is null or v_partner_id !~ '^[0-9]{6}$' then
    raise exception 'partner_id must be exactly 6 digits';
  end if;

  if v_company_name is null then
    raise exception 'company_name is required';
  end if;

  if v_username is null then
    v_username := 'partner_' || v_partner_id;
  end if;

  select *
  into v_existing
  from public.distribution_partners
  where partner_id = v_partner_id;

  if v_existing.id is null then
    if v_password is null then
      raise exception 'password is required when creating a partner';
    end if;

    insert into public.distribution_partners (
      partner_id,
      company_name,
      contact_first_name,
      contact_last_name,
      email,
      username,
      password_hash,
      phone,
      address_line_1,
      address_line_2,
      city,
      state,
      postal_code,
      country,
      is_active
    )
    values (
      v_partner_id,
      v_company_name,
      nullif(trim(coalesce(p_contact_first_name, '')), ''),
      nullif(trim(coalesce(p_contact_last_name, '')), ''),
      nullif(trim(coalesce(p_email, '')), ''),
      v_username,
      extensions.crypt(v_password, extensions.gen_salt('bf')),
      nullif(trim(coalesce(p_phone, '')), ''),
      nullif(trim(coalesce(p_address_line_1, '')), ''),
      nullif(trim(coalesce(p_address_line_2, '')), ''),
      nullif(trim(coalesce(p_city, '')), ''),
      nullif(trim(coalesce(p_state, '')), ''),
      nullif(trim(coalesce(p_postal_code, '')), ''),
      coalesce(nullif(trim(coalesce(p_country, '')), ''), 'US'),
      coalesce(p_is_active, true)
    )
    returning * into v_existing;

    return v_existing;
  end if;

  update public.distribution_partners p
  set company_name = v_company_name,
      contact_first_name = nullif(trim(coalesce(p_contact_first_name, '')), ''),
      contact_last_name = nullif(trim(coalesce(p_contact_last_name, '')), ''),
      email = nullif(trim(coalesce(p_email, '')), ''),
      username = v_username,
      password_hash = case
        when v_password is null then p.password_hash
        else extensions.crypt(v_password, extensions.gen_salt('bf'))
      end,
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      address_line_1 = nullif(trim(coalesce(p_address_line_1, '')), ''),
      address_line_2 = nullif(trim(coalesce(p_address_line_2, '')), ''),
      city = nullif(trim(coalesce(p_city, '')), ''),
      state = nullif(trim(coalesce(p_state, '')), ''),
      postal_code = nullif(trim(coalesce(p_postal_code, '')), ''),
      country = coalesce(nullif(trim(coalesce(p_country, '')), ''), 'US'),
      is_active = coalesce(p_is_active, true)
  where p.partner_id = v_partner_id
  returning * into v_existing;

  return v_existing;
end;
$$;

create or replace function public.upsert_master_console_user(
  p_username text,
  p_password text,
  p_display_name text default null,
  p_is_active boolean default true
)
returns public.master_console_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_password text := nullif(trim(coalesce(p_password, '')), '');
  v_user public.master_console_users;
begin
  if v_username is null then
    raise exception 'username is required';
  end if;

  if v_password is null then
    raise exception 'password is required';
  end if;

  insert into public.master_console_users (
    username,
    password_hash,
    display_name,
    is_active
  )
  values (
    v_username,
    extensions.crypt(v_password, extensions.gen_salt('bf')),
    nullif(trim(coalesce(p_display_name, '')), ''),
    coalesce(p_is_active, true)
  )
  on conflict ((lower(username))) do update
    set password_hash = excluded.password_hash,
        display_name = excluded.display_name,
        is_active = excluded.is_active
  returning * into v_user;

  return v_user;
end;
$$;

drop function if exists public.console_login(text, text);
create or replace function public.console_login(
  p_username text,
  p_password text
)
returns table (
  authenticated boolean,
  principal_type text,
  user_id uuid,
  partner_id text,
  company_name text,
  message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_password text := nullif(trim(coalesce(p_password, '')), '');
  v_master public.master_console_users;
  v_partner public.distribution_partners;
begin
  if v_username is null or v_password is null then
    return query select false, 'none'::text, null::uuid, null::text, null::text, 'Username and password are required'::text;
    return;
  end if;

  select * into v_master
  from public.master_console_users m
  where lower(m.username) = lower(v_username)
    and m.is_active = true
  limit 1;

  if v_master.id is not null and v_master.password_hash = extensions.crypt(v_password, v_master.password_hash) then
    update public.master_console_users
    set last_login_at = timezone('utc', now())
    where id = v_master.id;

    return query select true, 'master'::text, v_master.id, null::text, null::text, 'Login successful'::text;
    return;
  end if;

  select * into v_partner
  from public.distribution_partners p
  where lower(p.username) = lower(v_username)
    and p.is_active = true
  limit 1;

  if v_partner.id is not null and v_partner.password_hash = extensions.crypt(v_password, v_partner.password_hash) then
    update public.distribution_partners
    set last_login_at = timezone('utc', now())
    where id = v_partner.id;

    return query select true, 'partner'::text, v_partner.id, v_partner.partner_id, v_partner.company_name, 'Login successful'::text;
    return;
  end if;

  return query select false, 'none'::text, null::uuid, null::text, null::text, 'Invalid username or password'::text;
end;
$$;

commit;

-- Example setup:
-- select public.upsert_master_console_user('masteradmin', 'ChangeMeNow!', 'Master Admin');
-- select public.upsert_distribution_partner(
--   p_partner_id => '100001',
--   p_company_name => 'Demo Partner LLC',
--   p_contact_first_name => 'Alex',
--   p_contact_last_name => 'Smith',
--   p_email => 'alex@demopartner.test',
--   p_username => 'partner100001',
--   p_password => 'ChangeMeNow!'
-- );
