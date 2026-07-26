create or replace function public.list_staff_from_app(
  p_license_key text,
  p_location_id uuid default null
)
returns table (
  id uuid,
  organization_id uuid,
  location_id uuid,
  first_name text,
  last_name text,
  full_name text,
  email text,
  phone text,
  role text,
  pin text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_license_key text;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');

  if v_license_key is null then
    raise exception 'License key is required';
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

  return query
  select
    s.id,
    s.organization_id,
    s.location_id,
    s.first_name,
    s.last_name,
    s.full_name,
    s.email,
    s.phone,
    s.role,
    s.pin,
    s.is_active,
    s.created_at,
    s.updated_at
  from public.staff s
  where s.organization_id = v_org_id
    and (p_location_id is null or s.location_id = p_location_id)
  order by lower(coalesce(s.full_name, trim(concat(coalesce(s.first_name, ''), ' ', coalesce(s.last_name, ''))))), s.created_at;
end;
$$;

revoke all on function public.list_staff_from_app(text, uuid) from public;
grant execute on function public.list_staff_from_app(text, uuid) to anon, authenticated;
