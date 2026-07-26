-- Restores/updates the location upsert RPC to match the current app call shape.
-- Safe to run multiple times.

begin;

drop function if exists public.upsert_location_from_app(text, text, text, text, text, text, text, text);
drop function if exists public.upsert_location_from_app(text, text, uuid, text, text, text, text, text, text);
drop function if exists public.upsert_location_from_app(text, text, uuid, text, text, text, text, text, text, text, text);
drop function if exists public.upsert_location_from_app(text, uuid, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, boolean, text);

create or replace function public.upsert_location_from_app(
  p_license_key text,
  p_location_id uuid default null,
  p_location_name text default null,
  p_address text default null,
  p_address_2 text default null,
  p_city text default null,
  p_state text default null,
  p_zip text default null,
  p_phone text default null,
  p_terminal_licenses integer default null,
  p_terminals_active integer default null,
  p_processor_provider text default null,
  p_processor_environment text default null,
  p_processor_mode text default null,
  p_epn_api_login_id text default null,
  p_epn_user_id text default null,
  p_epn_password text default null,
  p_epn_restrict_key text default null,
  p_allow_tip_adjustments boolean default false,
  p_receipt_reply_to_email text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_license_key text;
  v_location_name text;
  v_location_id uuid;
  has_name boolean;
  has_address boolean;
  has_address_2 boolean;
  has_city boolean;
  has_state boolean;
  has_zip boolean;
  has_phone boolean;
  has_terminal_licenses boolean;
  has_terminals_active boolean;
  has_allow_tip_adjustments boolean;
  has_receipt_reply_to_email boolean;
  has_processor_provider boolean;
  has_processor_environment boolean;
  has_processor_mode boolean;
  has_epn_api_login_id boolean;
  has_epn_user_id boolean;
  has_epn_password boolean;
  has_epn_restrict_key boolean;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');

  if v_license_key is null then
    raise exception 'License key is required';
  end if;

  if v_location_name is null then
    raise exception 'Location name is required';
  end if;

  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = v_license_key
     or o.organization_number = v_license_key
  limit 1;

  if v_org_id is null and v_license_key like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(v_license_key, 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  if p_location_id is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.id = p_location_id
      and l.organization_id = v_org_id
    limit 1;
  end if;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'name'
  ) into has_name;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'address'
  ) into has_address;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'address_2'
  ) into has_address_2;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'city'
  ) into has_city;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'state'
  ) into has_state;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'zip'
  ) into has_zip;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'phone'
  ) into has_phone;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'terminal_licenses'
  ) into has_terminal_licenses;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'terminals_active'
  ) into has_terminals_active;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'allow_tip_adjustments'
  ) into has_allow_tip_adjustments;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'receipt_reply_to_email'
  ) into has_receipt_reply_to_email;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'processor_provider'
  ) into has_processor_provider;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'processor_environment'
  ) into has_processor_environment;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'processor_mode'
  ) into has_processor_mode;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'epn_api_login_id'
  ) into has_epn_api_login_id;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'epn_user_id'
  ) into has_epn_user_id;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'epn_password'
  ) into has_epn_password;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'epn_restrict_key'
  ) into has_epn_restrict_key;

  if v_location_id is null and has_name then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(v_location_name)
    limit 1;
  end if;

  if v_location_id is null then
    if has_name then
      insert into public.locations (organization_id, name)
      values (v_org_id, v_location_name)
      returning id into v_location_id;
    else
      insert into public.locations (organization_id)
      values (v_org_id)
      returning id into v_location_id;
    end if;
  end if;

  if has_name then
    update public.locations
    set name = coalesce(nullif(trim(coalesce(p_location_name, '')), ''), name)
    where id = v_location_id;
  end if;
  if has_address then
    update public.locations
    set address = coalesce(nullif(trim(coalesce(p_address, '')), ''), address)
    where id = v_location_id;
  end if;
  if has_address_2 then
    update public.locations
    set address_2 = coalesce(nullif(trim(coalesce(p_address_2, '')), ''), address_2)
    where id = v_location_id;
  end if;
  if has_city then
    update public.locations
    set city = coalesce(nullif(trim(coalesce(p_city, '')), ''), city)
    where id = v_location_id;
  end if;
  if has_state then
    update public.locations
    set state = coalesce(nullif(trim(coalesce(p_state, '')), ''), state)
    where id = v_location_id;
  end if;
  if has_zip then
    update public.locations
    set zip = coalesce(nullif(trim(coalesce(p_zip, '')), ''), zip)
    where id = v_location_id;
  end if;
  if has_phone then
    update public.locations
    set phone = coalesce(nullif(trim(coalesce(p_phone, '')), ''), phone)
    where id = v_location_id;
  end if;
  if has_terminal_licenses then
    update public.locations
    set terminal_licenses = coalesce(p_terminal_licenses, terminal_licenses)
    where id = v_location_id;
  end if;
  if has_terminals_active then
    update public.locations
    set terminals_active = coalesce(p_terminals_active, terminals_active)
    where id = v_location_id;
  end if;
  if has_allow_tip_adjustments then
    update public.locations
    set allow_tip_adjustments = coalesce(p_allow_tip_adjustments, allow_tip_adjustments)
    where id = v_location_id;
  end if;
  if has_receipt_reply_to_email then
    update public.locations
    set receipt_reply_to_email = nullif(trim(coalesce(p_receipt_reply_to_email, '')), '')
    where id = v_location_id;
  end if;
  if has_processor_provider then
    update public.locations
    set processor_provider = coalesce(nullif(trim(coalesce(p_processor_provider, '')), ''), processor_provider)
    where id = v_location_id;
  end if;
  if has_processor_environment then
    update public.locations
    set processor_environment = coalesce(nullif(trim(coalesce(p_processor_environment, '')), ''), processor_environment)
    where id = v_location_id;
  end if;
  if has_processor_mode then
    update public.locations
    set processor_mode = coalesce(nullif(trim(coalesce(p_processor_mode, '')), ''), processor_mode)
    where id = v_location_id;
  end if;
  if has_epn_api_login_id then
    update public.locations
    set epn_api_login_id = coalesce(nullif(trim(coalesce(p_epn_api_login_id, '')), ''), epn_api_login_id)
    where id = v_location_id;
  end if;
  if has_epn_user_id then
    update public.locations
    set epn_user_id = coalesce(nullif(trim(coalesce(p_epn_user_id, '')), ''), epn_user_id)
    where id = v_location_id;
  end if;
  if has_epn_password then
    update public.locations
    set epn_password = coalesce(nullif(trim(coalesce(p_epn_password, '')), ''), epn_password)
    where id = v_location_id;
  end if;
  if has_epn_restrict_key then
    update public.locations
    set epn_restrict_key = coalesce(nullif(trim(coalesce(p_epn_restrict_key, '')), ''), epn_restrict_key)
    where id = v_location_id;
  end if;

  return v_location_id;
end;
$$;

revoke all on function public.upsert_location_from_app(text, uuid, text, text, text, text, text, text, text, integer, integer, text, text, text, text, text, text, text, boolean, text) from public;
grant execute on function public.upsert_location_from_app(text, uuid, text, text, text, text, text, text, text, integer, integer, text, text, text, text, text, text, text, boolean, text) to anon, authenticated;

commit;
