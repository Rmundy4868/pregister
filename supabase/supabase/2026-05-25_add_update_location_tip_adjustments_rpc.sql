-- Adds RPC helper to persist allow_tip_adjustments in RLS fallback flows.
-- Safe to run multiple times.

drop function if exists public.update_location_tip_adjustments_from_app(text, uuid, text, boolean);

create or replace function public.update_location_tip_adjustments_from_app(
  p_license_key text,
  p_location_id uuid default null,
  p_location_name text default null,
  p_allow_tip_adjustments boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_license_key text;
  v_location_name text;
  has_allow_tip_adjustments boolean;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');

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

  if p_location_id is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.id = p_location_id
      and l.organization_id = v_org_id
    limit 1;
  end if;

  if v_location_id is null and v_location_name is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(v_location_name)
    limit 1;
  end if;

  if v_location_id is null then
    raise exception 'Location not found for license context';
  end if;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'allow_tip_adjustments'
  ) into has_allow_tip_adjustments;

  if has_allow_tip_adjustments then
    update public.locations
    set allow_tip_adjustments = coalesce(p_allow_tip_adjustments, false)
    where id = v_location_id;
  end if;

  return v_location_id;
end;
$$;

revoke all on function public.update_location_tip_adjustments_from_app(text, uuid, text, boolean) from public;
grant execute on function public.update_location_tip_adjustments_from_app(text, uuid, text, boolean) to anon, authenticated;
