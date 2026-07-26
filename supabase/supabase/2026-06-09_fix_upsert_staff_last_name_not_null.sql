create or replace function public.upsert_staff_from_app(
  p_license_key text,
  p_location_id uuid,
  p_staff_id uuid default null,
  p_first_name text default null,
  p_last_name text default null,
  p_email text default null,
  p_phone text default null,
  p_role text default null,
  p_is_active boolean default true,
  p_pin text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_staff_id uuid;
  v_license_key text;
  v_first_name text;
  v_last_name text;
  v_email text;
  v_phone text;
  v_role text;
  v_pin text;
  v_full_name text;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_first_name := nullif(trim(coalesce(p_first_name, '')), '');
  v_last_name := trim(coalesce(p_last_name, ''));
  v_email := nullif(trim(coalesce(p_email, '')), '');
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_role := lower(nullif(trim(coalesce(p_role, '')), ''));
  v_pin := nullif(regexp_replace(coalesce(p_pin, ''), '\D', '', 'g'), '');

  if v_license_key is null then
    raise exception 'License key is required';
  end if;

  if p_location_id is null then
    raise exception 'Location ID is required';
  end if;

  if v_first_name is null then
    raise exception 'First name is required';
  end if;

  if v_pin is null or v_pin !~ '^[0-9]{1,6}$' then
    raise exception 'PIN must be numeric and no more than 6 digits';
  end if;

  if v_role = 'administrator' then
    v_role := 'admin';
  end if;

  if v_role is null then
    v_role := 'cashier';
  end if;

  if v_role not in ('owner', 'admin', 'manager', 'staff', 'cashier') then
    raise exception 'Invalid staff role';
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

  select l.id
  into v_location_id
  from public.locations l
  where l.id = p_location_id
    and l.organization_id = v_org_id
  limit 1;

  if v_location_id is null then
    raise exception 'Location not found for licensed organization';
  end if;

  v_full_name := trim(concat(v_first_name, ' ', v_last_name));

  if p_staff_id is not null then
    select s.id
    into v_staff_id
    from public.staff s
    where s.id = p_staff_id
      and s.organization_id = v_org_id
      and s.location_id = v_location_id
    limit 1;
  end if;

  if v_staff_id is null then
    insert into public.staff (
      organization_id,
      location_id,
      first_name,
      last_name,
      email,
      phone,
      role,
      is_active,
      full_name,
      pin
    )
    values (
      v_org_id,
      v_location_id,
      v_first_name,
      v_last_name,
      v_email,
      v_phone,
      v_role,
      coalesce(p_is_active, true),
      v_full_name,
      v_pin
    )
    returning id into v_staff_id;
  else
    update public.staff
    set first_name = v_first_name,
        last_name = v_last_name,
        email = v_email,
        phone = v_phone,
        role = v_role,
        is_active = coalesce(p_is_active, true),
        full_name = v_full_name,
        pin = v_pin
    where id = v_staff_id;
  end if;

  return v_staff_id;
end;
$$;

revoke all on function public.upsert_staff_from_app(text, uuid, uuid, text, text, text, text, text, boolean, text) from public;
grant execute on function public.upsert_staff_from_app(text, uuid, uuid, text, text, text, text, text, boolean, text) to anon, authenticated;
