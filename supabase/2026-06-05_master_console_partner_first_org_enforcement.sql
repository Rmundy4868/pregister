-- Master Console: partner-first organization creation
-- - Adds auto-increment partner_id generation for partner creation
-- - Adds partner creation/list RPCs for console UI
-- - Requires partner_id on new organization creation
-- Safe to run multiple times.

begin;

create sequence if not exists public.distribution_partner_id_seq
  as bigint
  start with 100001
  increment by 1
  minvalue 100001;

-- Ensure sequence starts after current max partner_id (6-digit numeric text).
do $$
declare
  v_max_existing bigint;
begin
  select max(partner_id::bigint)
  into v_max_existing
  from public.distribution_partners
  where partner_id ~ '^[0-9]{6}$';

  if v_max_existing is null then
    -- Empty table: nextval() should return 100001.
    perform setval('public.distribution_partner_id_seq', 100001, false);
  else
    -- Existing table: nextval() should return max + 1.
    perform setval('public.distribution_partner_id_seq', greatest(v_max_existing, 100001), true);
  end if;
end;
$$;

create or replace function public.next_distribution_partner_id()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next bigint;
begin
  v_next := nextval('public.distribution_partner_id_seq');
  if v_next > 999999 then
    raise exception 'distribution partner id sequence exhausted (max 999999)';
  end if;

  return lpad(v_next::text, 6, '0');
end;
$$;

revoke all on function public.next_distribution_partner_id() from public;
grant execute on function public.next_distribution_partner_id() to anon, authenticated;

drop function if exists public.create_distribution_partner_console_from_app(text, text, text, text, text, text, text, text, text, text, text, text, text, boolean);
create or replace function public.create_distribution_partner_console_from_app(
  p_company_name text,
  p_contact_first_name text default null,
  p_contact_last_name text default null,
  p_email text default null,
  p_phone text default null,
  p_address_line_1 text default null,
  p_address_line_2 text default null,
  p_city text default null,
  p_state text default null,
  p_postal_code text default null,
  p_country text default 'US',
  p_username text default null,
  p_password text default null,
  p_is_active boolean default true
)
returns table (
  id uuid,
  partner_id text,
  company_name text,
  contact_first_name text,
  contact_last_name text,
  email text,
  phone text,
  address_line_1 text,
  address_line_2 text,
  city text,
  state text,
  postal_code text,
  country text,
  username text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id text;
  v_company_name text := nullif(trim(coalesce(p_company_name, '')), '');
  v_username text;
  v_password text;
  v_row public.distribution_partners;
begin
  if v_company_name is null then
    raise exception 'company_name is required';
  end if;

  -- Partner credentials are always deterministic for first-login reset flow.
  v_partner_id := public.next_distribution_partner_id();
  v_username := 'partner_' || v_partner_id;
  v_password := 'Partner!' || v_partner_id || '!';

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
  returning * into v_row;

  return query
  select
    v_row.id,
    v_row.partner_id,
    v_row.company_name,
    coalesce(v_row.contact_first_name, ''),
    coalesce(v_row.contact_last_name, ''),
    coalesce(v_row.email, ''),
    coalesce(v_row.phone, ''),
    coalesce(v_row.address_line_1, ''),
    coalesce(v_row.address_line_2, ''),
    coalesce(v_row.city, ''),
    coalesce(v_row.state, ''),
    coalesce(v_row.postal_code, ''),
    coalesce(v_row.country, ''),
    v_row.username,
    coalesce(v_row.is_active, true),
    v_row.created_at;
end;
$$;

revoke all on function public.create_distribution_partner_console_from_app(text, text, text, text, text, text, text, text, text, text, text, text, text, boolean) from public;
grant execute on function public.create_distribution_partner_console_from_app(text, text, text, text, text, text, text, text, text, text, text, text, text, boolean) to anon, authenticated;

drop function if exists public.list_distribution_partners_console_from_app();
create or replace function public.list_distribution_partners_console_from_app()
returns table (
  id uuid,
  partner_id text,
  company_name text,
  contact_first_name text,
  contact_last_name text,
  email text,
  phone text,
  address_line_1 text,
  address_line_2 text,
  city text,
  state text,
  postal_code text,
  country text,
  username text,
  is_active boolean,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    p.id,
    p.partner_id,
    p.company_name,
    coalesce(p.contact_first_name, '') as contact_first_name,
    coalesce(p.contact_last_name, '') as contact_last_name,
    coalesce(p.email, '') as email,
    coalesce(p.phone, '') as phone,
    coalesce(p.address_line_1, '') as address_line_1,
    coalesce(p.address_line_2, '') as address_line_2,
    coalesce(p.city, '') as city,
    coalesce(p.state, '') as state,
    coalesce(p.postal_code, '') as postal_code,
    coalesce(p.country, '') as country,
    p.username,
    coalesce(p.is_active, true) as is_active,
    p.created_at
  from public.distribution_partners p
  order by p.partner_id;
$$;

revoke all on function public.list_distribution_partners_console_from_app() from public;
grant execute on function public.list_distribution_partners_console_from_app() to anon, authenticated;

drop function if exists public.upsert_organization_console_from_app(uuid, text, text, text, text, text, text);
create or replace function public.upsert_organization_console_from_app(
  p_id uuid default null,
  p_organization_number text default null,
  p_name text default null,
  p_license_key text default null,
  p_contact_name text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_partner_id text default null
)
returns table (
  id uuid,
  organization_number text,
  name text,
  license_key text,
  is_active boolean,
  contact_name text,
  contact_email text,
  contact_phone text,
  partner_id text,
  partner_company_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_org_number text := nullif(trim(coalesce(p_organization_number, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_license_key text := nullif(trim(coalesce(p_license_key, '')), '');
  v_contact_name text := nullif(trim(coalesce(p_contact_name, '')), '');
  v_contact_email text := nullif(trim(coalesce(p_contact_email, '')), '');
  v_contact_phone text := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_partner_id text := nullif(trim(coalesce(p_partner_id, '')), '');
  v_is_active boolean := v_license_key is not null;
begin
  if v_org_number is null or v_name is null then
    raise exception 'Organization number and name are required';
  end if;

  if v_org_number !~ '^[0-9]{6}$' then
    raise exception 'Organization number must be exactly 6 digits';
  end if;

  if p_id is null then
    if v_partner_id is null then
      raise exception 'Partner is required before creating an organization';
    end if;
  end if;

  if v_partner_id is not null and not exists (
    select 1
    from public.distribution_partners p
    where p.partner_id = v_partner_id
  ) then
    raise exception 'Partner % was not found', v_partner_id;
  end if;

  if p_id is not null then
    update public.organizations
    set organization_number = v_org_number,
        name = v_name,
        license_key = v_license_key,
        is_active = v_is_active,
        contact_name = v_contact_name,
        contact_email = v_contact_email,
        contact_phone = v_contact_phone,
        partner_id = coalesce(v_partner_id, organizations.partner_id)
    where organizations.id = p_id
    returning organizations.id into v_id;

    if v_id is null then
      raise exception 'Organization with id % was not found', p_id;
    end if;
  else
    if exists (
      select 1
      from public.organizations o
      where o.organization_number = v_org_number
    ) then
      raise exception 'Organization number % already exists. Use Edit Organization to change it.', v_org_number;
    end if;

    begin
      insert into public.organizations (
        organization_number,
        name,
        license_key,
        is_active,
        contact_name,
        contact_email,
        contact_phone,
        partner_id
      )
      values (
        v_org_number,
        v_name,
        v_license_key,
        v_is_active,
        v_contact_name,
        v_contact_email,
        v_contact_phone,
        v_partner_id
      )
      returning organizations.id into v_id;
    exception
      when unique_violation then
        raise exception 'Organization number % already exists. Use Edit Organization to change it.', v_org_number;
    end;
  end if;

  return query
  select
    o.id,
    o.organization_number,
    o.name,
    coalesce(o.license_key, ''),
    coalesce(o.is_active, true),
    coalesce(o.contact_name, ''),
    coalesce(o.contact_email, ''),
    coalesce(o.contact_phone, ''),
    coalesce(o.partner_id, ''),
    coalesce(p.company_name, '')
  from public.organizations o
  left join public.distribution_partners p on p.partner_id = o.partner_id
  where o.id = v_id
  limit 1;
end;
$$;

revoke all on function public.upsert_organization_console_from_app(uuid, text, text, text, text, text, text, text) from public;
grant execute on function public.upsert_organization_console_from_app(uuid, text, text, text, text, text, text, text) to anon, authenticated;

drop function if exists public.list_organizations_console_from_app();

create or replace function public.list_organizations_console_from_app()
returns table (
  id uuid,
  organization_number text,
  name text,
  license_key text,
  is_active boolean,
  contact_name text,
  contact_email text,
  contact_phone text,
  partner_id text,
  partner_company_name text
)
language sql
security definer
set search_path = public
as $$
  select
    o.id,
    o.organization_number,
    o.name,
    coalesce(o.license_key, '') as license_key,
    coalesce(o.is_active, true) as is_active,
    coalesce(o.contact_name, '') as contact_name,
    coalesce(o.contact_email, '') as contact_email,
    coalesce(o.contact_phone, '') as contact_phone,
    coalesce(o.partner_id, '') as partner_id,
    coalesce(p.company_name, '') as partner_company_name
  from public.organizations o
  left join public.distribution_partners p on p.partner_id = o.partner_id
  order by o.organization_number;
$$;

revoke all on function public.list_organizations_console_from_app() from public;
grant execute on function public.list_organizations_console_from_app() to anon, authenticated;

create or replace function public.upsert_organization_from_app(
  p_id uuid default null,
  p_organization_number text default null,
  p_name text default null,
  p_license_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
begin
  select * into v_row
  from public.upsert_organization_console_from_app(
    p_id,
    p_organization_number,
    p_name,
    p_license_key,
    null,
    null,
    null,
    null
  )
  limit 1;

  return v_row.id;
end;
$$;

revoke all on function public.upsert_organization_from_app(uuid, text, text, text) from public;
grant execute on function public.upsert_organization_from_app(uuid, text, text, text) to anon, authenticated;

commit;
