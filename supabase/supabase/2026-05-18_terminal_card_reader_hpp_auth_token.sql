begin;

-- Add card_reader_hpp_auth_token column to terminals table
alter table public.terminals
  add column if not exists card_reader_hpp_auth_token text;

-- Alter the upsert_terminal_from_app RPC to accept HPP auth token
drop function if exists public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, text, boolean);

create or replace function public.upsert_terminal_from_app(
  p_license_key text,
  p_location_id uuid,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_name text default null,
  p_code text default null,
  p_card_reader_type text default 'dejavoo_p12',
  p_card_reader_hpp_auth_token text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_terminal_id uuid;
  v_terminal_number text;
  v_name text;
  v_code text;
  v_card_reader_type text;
  v_card_reader_hpp_auth_token text;
  v_existing_is_active boolean := false;
  v_location_terminal_licenses integer := 0;
  v_location_active_count integer := 0;
begin
  v_terminal_number := coalesce(nullif(trim(coalesce(p_terminal_number, '')), ''), '0001');
  v_name := coalesce(nullif(trim(coalesce(p_name, '')), ''), 'Terminal ' || v_terminal_number);
  v_code := nullif(trim(coalesce(p_code, '')), '');
  v_card_reader_type := lower(coalesce(nullif(trim(coalesce(p_card_reader_type, '')), ''), 'dejavoo_p12'));
  v_card_reader_hpp_auth_token := nullif(trim(coalesce(p_card_reader_hpp_auth_token, '')), '');

  if v_card_reader_type not in ('none', 'dejavoo_p12') then
    raise exception 'Unsupported card reader type';
  end if;

  if v_terminal_number !~ '^[0-9]{4}$' then
    raise exception 'Terminal number must be exactly 4 digits';
  end if;

  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = nullif(trim(coalesce(p_license_key, '')), '')
     or o.organization_number = nullif(trim(coalesce(p_license_key, '')), '')
  limit 1;

  if v_org_id is null and trim(coalesce(p_license_key, '')) like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(trim(coalesce(p_license_key, '')), 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  select l.id
  into v_location_id
  from public.locations l
  where l.id = p_location_id
    and l.organization_id = v_org_id
  limit 1;

  if v_location_id is null then
    raise exception 'Location not found for licensed organization';
  end if;

  if p_terminal_id is not null then
    select t.id
    into v_terminal_id
    from public.terminals t
    where t.id = p_terminal_id
      and t.organization_id = v_org_id
    limit 1;
  end if;

  if v_terminal_id is null then
    select t.id
    into v_terminal_id
    from public.terminals t
    where t.organization_id = v_org_id
      and t.location_id = v_location_id
      and t.terminal_number = v_terminal_number
    limit 1;
  end if;

  if v_terminal_id is null then
    select coalesce(l.terminal_licenses, 0)
    into v_location_terminal_licenses
    from public.locations l
    where l.id = v_location_id
    limit 1;

    select count(*)::integer
    into v_location_active_count
    from public.terminals t
    where t.location_id = v_location_id
      and coalesce(t.is_active, true) = true;

    if coalesce(p_is_active, true) = true and
       v_location_terminal_licenses > 0 and
       v_location_active_count >= v_location_terminal_licenses then
      raise exception 'Terminal license limit reached for this location';
    end if;

    insert into public.terminals (
      organization_id,
      organization_number,
      location_id,
      terminal_number,
      name,
      code,
      card_reader_type,
      card_reader_hpp_auth_token,
      is_active
    )
    values (
      v_org_id,
      (select organization_number from public.organizations where id = v_org_id),
      v_location_id,
      v_terminal_number,
      v_name,
      coalesce(v_code, v_terminal_number),
      v_card_reader_type,
      v_card_reader_hpp_auth_token,
      coalesce(p_is_active, true)
    )
    returning id into v_terminal_id;
  else
    select coalesce(t.is_active, true)
    into v_existing_is_active
    from public.terminals t
    where t.id = v_terminal_id
    limit 1;

    if coalesce(p_is_active, true) = true and not coalesce(v_existing_is_active, false) then
      select coalesce(l.terminal_licenses, 0)
      into v_location_terminal_licenses
      from public.locations l
      where l.id = v_location_id
      limit 1;

      select count(*)::integer
      into v_location_active_count
      from public.terminals t
      where t.location_id = v_location_id
        and coalesce(t.is_active, true) = true
        and t.id <> v_terminal_id;

      if v_location_terminal_licenses > 0 and
         v_location_active_count >= v_location_terminal_licenses then
        raise exception 'Terminal license limit reached for this location';
      end if;
    end if;

    update public.terminals
    set location_id = v_location_id,
        terminal_number = v_terminal_number,
        name = v_name,
        code = coalesce(v_code, code, v_terminal_number),
        card_reader_type = v_card_reader_type,
        card_reader_hpp_auth_token = coalesce(v_card_reader_hpp_auth_token, card_reader_hpp_auth_token),
        is_active = coalesce(p_is_active, true)
    where id = v_terminal_id;
  end if;

  if coalesce(p_is_active, true) = false then
    update public.terminals
    set registered_device_id = null,
        registered_device_label = null
    where id = v_terminal_id;
  end if;

  update public.locations l
  set terminals_active = (
    select count(*)::integer
    from public.terminals t
    where t.location_id = l.id
      and coalesce(t.is_active, true) = true
  )
  where l.id = v_location_id;

  return v_terminal_id;
end;
$$;

revoke all on function public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, text, text, boolean) from public;
grant execute on function public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, text, text, boolean) to anon, authenticated;

commit;
