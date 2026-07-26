-- Master Console: location creation flow under organization context.
-- - Adds location list/upsert RPCs for Master Console
-- - Exposes read-only org identity fields (id/number/license) in results
-- - Sets default receipt_card_signature_message for newly created locations
-- Safe to run multiple times.

begin;

alter table public.locations
  add column if not exists location_name text,
  add column if not exists email text,
  add column if not exists phone text,
  add column if not exists address text,
  add column if not exists address_1 text,
  add column if not exists address_2 text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists zip text,
  add column if not exists terminal_licenses integer not null default 1,
  add column if not exists terminals_active integer not null default 0,
  add column if not exists receipt_card_signature_message text;

drop function if exists public.list_locations_console_from_app(uuid);

create or replace function public.list_locations_console_from_app(
  p_organization_id uuid
)
returns table (
  id uuid,
  organization_id uuid,
  organization_number text,
  organization_license_key text,
  name text,
  email text,
  phone text,
  address text,
  address_2 text,
  city text,
  state text,
  zip text,
  terminal_licenses integer,
  terminals_active integer,
  receipt_card_signature_message text
)
language sql
security definer
set search_path = public
as $$
  select
    l.id,
    l.organization_id,
    coalesce(o.organization_number, ''),
    coalesce(o.license_key, ''),
    coalesce(nullif(trim(coalesce(l.name, '')), ''), nullif(trim(coalesce(l.location_name, '')), ''), ''),
    coalesce(l.email, ''),
    coalesce(l.phone, ''),
    coalesce(l.address, coalesce(l.address_1, '')),
    coalesce(l.address_2, ''),
    coalesce(l.city, ''),
    coalesce(l.state, ''),
    coalesce(l.zip, ''),
    coalesce(l.terminal_licenses, 1),
    coalesce(l.terminals_active, 0),
    coalesce(
      nullif(trim(coalesce(l.receipt_card_signature_message, '')), ''),
      'I agree with the charges listed above in accordance with cardholder agreement'
    )
  from public.locations l
  left join public.organizations o on o.id = l.organization_id
  where l.organization_id = p_organization_id
  order by coalesce(l.name, l.location_name, ''), l.id;
$$;

revoke all on function public.list_locations_console_from_app(uuid) from public;
grant execute on function public.list_locations_console_from_app(uuid) to anon, authenticated;

drop function if exists public.upsert_location_console_from_app(uuid, uuid, text, text, text, text, text, text, text, text, integer);

create or replace function public.upsert_location_console_from_app(
  p_id uuid default null,
  p_organization_id uuid default null,
  p_name text default null,
  p_email text default null,
  p_phone text default null,
  p_address text default null,
  p_address_2 text default null,
  p_city text default null,
  p_state text default null,
  p_zip text default null,
  p_terminal_licenses integer default 1
)
returns table (
  id uuid,
  organization_id uuid,
  organization_number text,
  organization_license_key text,
  name text,
  email text,
  phone text,
  address text,
  address_2 text,
  city text,
  state text,
  zip text,
  terminal_licenses integer,
  terminals_active integer,
  receipt_card_signature_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_location_id uuid;
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_email text := nullif(trim(coalesce(p_email, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_address_2 text := nullif(trim(coalesce(p_address_2, '')), '');
  v_city text := nullif(trim(coalesce(p_city, '')), '');
  v_state text := nullif(trim(coalesce(p_state, '')), '');
  v_zip text := nullif(trim(coalesce(p_zip, '')), '');
  v_terminal_licenses integer := greatest(coalesce(p_terminal_licenses, 1), 0);
begin
  if p_organization_id is null then
    raise exception 'Organization id is required';
  end if;

  if not exists (
    select 1
    from public.organizations o
    where o.id = p_organization_id
  ) then
    raise exception 'Organization was not found';
  end if;

  if v_name is null then
    raise exception 'Location name is required';
  end if;

  if p_id is null then
    insert into public.locations (
      organization_id,
      name,
      location_name,
      email,
      phone,
      address,
      address_1,
      address_2,
      city,
      state,
      zip,
      terminal_licenses,
      receipt_card_signature_message
    )
    values (
      p_organization_id,
      v_name,
      v_name,
      v_email,
      v_phone,
      v_address,
      v_address,
      v_address_2,
      v_city,
      v_state,
      v_zip,
      v_terminal_licenses,
      'I agree with the charges listed above in accordance with cardholder agreement'
    )
    returning locations.id into v_location_id;
  else
    select l.id
    into v_location_id
    from public.locations l
    where l.id = p_id
      and l.organization_id = p_organization_id
    limit 1;

    if v_location_id is null then
      raise exception 'Location with id % was not found for this organization', p_id;
    end if;

    update public.locations
    set name = v_name,
        location_name = v_name,
        email = v_email,
        phone = v_phone,
        address = v_address,
        address_1 = v_address,
        address_2 = v_address_2,
        city = v_city,
        state = v_state,
        zip = v_zip,
        terminal_licenses = v_terminal_licenses
    where locations.id = v_location_id;
  end if;

  return query
  select r.id, r.organization_id, r.organization_number, r.organization_license_key,
         r.name, r.email, r.phone, r.address, r.address_2, r.city, r.state, r.zip,
         r.terminal_licenses, r.terminals_active, r.receipt_card_signature_message
  from public.list_locations_console_from_app(p_organization_id) r
  where r.id = v_location_id
  limit 1;
end;
$$;

revoke all on function public.upsert_location_console_from_app(uuid, uuid, text, text, text, text, text, text, text, text, integer) from public;
grant execute on function public.upsert_location_console_from_app(uuid, uuid, text, text, text, text, text, text, text, text, integer) to anon, authenticated;

commit;
