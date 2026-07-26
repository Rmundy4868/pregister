-- Resolve active staff by PIN under a licensed organization/location context.
-- This function is intended for terminal PIN login and avoids client-side RLS
-- lookup failures by running under SECURITY DEFINER.

create or replace function public.resolve_staff_pin_from_license(
  p_license_key text,
  p_pin text,
  p_location_id uuid default null
)
returns table (
  id uuid,
  organization_id uuid,
  location_id uuid,
  first_name text,
  last_name text,
  full_name text,
  name text,
  email text,
  role text,
  pin text,
  is_active boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_license_key text;
  v_pin text;
  v_org_id uuid;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_pin := nullif(regexp_replace(coalesce(p_pin, ''), '\D', '', 'g'), '');

  if v_license_key is null then
    return;
  end if;

  if v_pin is null or v_pin !~ '^[0-9]{1,6}$' then
    return;
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
    return;
  end if;

  return query
  select
    s.id,
    s.organization_id,
    s.location_id,
    s.first_name,
    s.last_name,
    s.full_name,
    null::text,
    s.email,
    s.role,
    s.pin::text,
    coalesce(s.is_active, true)
  from public.staff s
  where s.organization_id = v_org_id
    and (p_location_id is null or s.location_id = p_location_id)
    and s.pin = v_pin
    and coalesce(s.is_active, true) = true
  order by
    case when p_location_id is not null and s.location_id = p_location_id then 0 else 1 end,
    s.id
  limit 50;
end;
$$;

revoke all on function public.resolve_staff_pin_from_license(text, text, uuid) from public;
grant execute on function public.resolve_staff_pin_from_license(text, text, uuid) to anon, authenticated;
