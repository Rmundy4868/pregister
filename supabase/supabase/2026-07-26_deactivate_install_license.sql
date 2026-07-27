-- Release an activated install so uninstall/reinstall can reuse the slot.
-- Safe to run multiple times.

begin;

drop function if exists public.deactivate_install_license(text, text, text, text, boolean);
drop function if exists public.deactivate_install_license(text, text, text, text);
drop function if exists public.deactivate_install_license(text, text, text);
drop function if exists public.deactivate_install_license(text, text);
drop function if exists public.deactivate_install_license(text);

create or replace function public.deactivate_install_license(
  p_license_key text,
  p_terminal_number text default null,
  p_location_name text default null,
  p_device_id text default null,
  p_deactivate_terminal boolean default true
)
returns table (
  terminal_id uuid,
  location_id uuid,
  terminal_number text,
  released boolean,
  deactivated boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_license_key text := nullif(trim(coalesce(p_license_key, '')), '');
  v_terminal_number_input text := nullif(trim(coalesce(p_terminal_number, '')), '');
  v_location_name text := nullif(trim(coalesce(p_location_name, '')), '');
  v_device_id text := nullif(trim(coalesce(p_device_id, '')), '');
  v_org_id uuid;
  v_terminal_id uuid;
  v_location_id uuid;
  v_terminal_number text := coalesce(v_terminal_number_input, '');
  has_location_name boolean;
  has_location_terminals_active boolean;
  has_terminal_number boolean;
  has_terminal_is_active boolean;
  has_terminal_registered_device_id boolean;
  has_terminal_registered_device_label boolean;
begin
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

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'name'
  ) into has_location_name;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'terminals_active'
  ) into has_location_terminals_active;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'terminal_number'
  ) into has_terminal_number;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'is_active'
  ) into has_terminal_is_active;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'registered_device_id'
  ) into has_terminal_registered_device_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'registered_device_label'
  ) into has_terminal_registered_device_label;

  if has_terminal_registered_device_id and v_device_id is not null then
    if has_location_name and v_location_name is not null then
      select t.id, t.location_id, coalesce(t.terminal_number, v_terminal_number_input, '0001')
      into v_terminal_id, v_location_id, v_terminal_number
      from public.terminals t
      left join public.locations l on l.id = t.location_id
      where t.organization_id = v_org_id
        and t.registered_device_id = v_device_id
        and lower(coalesce(l.name, '')) = lower(v_location_name)
      order by t.id
      limit 1;
    end if;

    if v_terminal_id is null then
      select t.id, t.location_id, coalesce(t.terminal_number, v_terminal_number_input, '0001')
      into v_terminal_id, v_location_id, v_terminal_number
      from public.terminals t
      where t.organization_id = v_org_id
        and t.registered_device_id = v_device_id
        and (v_terminal_number_input is null or not has_terminal_number or coalesce(t.terminal_number, '') = v_terminal_number_input)
      order by t.id
      limit 1;
    end if;
  end if;

  if v_terminal_id is null and v_terminal_number_input is not null then
    if has_location_name and v_location_name is not null then
      select t.id, t.location_id, coalesce(t.terminal_number, v_terminal_number_input)
      into v_terminal_id, v_location_id, v_terminal_number
      from public.terminals t
      left join public.locations l on l.id = t.location_id
      where t.organization_id = v_org_id
        and (not has_terminal_number or coalesce(t.terminal_number, '') = v_terminal_number_input)
        and lower(coalesce(l.name, '')) = lower(v_location_name)
      order by t.id
      limit 1;
    end if;

    if v_terminal_id is null then
      select t.id, t.location_id, coalesce(t.terminal_number, v_terminal_number_input)
      into v_terminal_id, v_location_id, v_terminal_number
      from public.terminals t
      where t.organization_id = v_org_id
        and (not has_terminal_number or coalesce(t.terminal_number, '') = v_terminal_number_input)
      order by t.id
      limit 1;
    end if;
  end if;

  if v_terminal_id is null then
    raise exception 'No terminal matched the provided activation context';
  end if;

  update public.terminals t
  set registered_device_id = case
        when has_terminal_registered_device_id then null
        else t.registered_device_id
      end,
      registered_device_label = case
        when has_terminal_registered_device_label then null
        else t.registered_device_label
      end,
      is_active = case
        when has_terminal_is_active and coalesce(p_deactivate_terminal, true) then false
        else t.is_active
      end
  where t.id = v_terminal_id;

  if has_location_terminals_active and has_terminal_is_active and v_location_id is not null then
    update public.locations l
    set terminals_active = (
      select count(*)::integer
      from public.terminals t
      where t.location_id = l.id
        and coalesce(t.is_active, true) = true
    )
    where l.id = v_location_id;
  end if;

  return query
  select
    v_terminal_id,
    v_location_id,
    coalesce(nullif(v_terminal_number, ''), coalesce(v_terminal_number_input, '0001')),
    true,
    coalesce(p_deactivate_terminal, true);
end;
$$;

revoke all on function public.deactivate_install_license(text, text, text, text, boolean) from public;
grant execute on function public.deactivate_install_license(text, text, text, text, boolean) to anon, authenticated;

commit;