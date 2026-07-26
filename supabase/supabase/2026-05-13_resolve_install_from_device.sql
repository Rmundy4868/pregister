-- Resolve startup context using only a previously registered device id.
-- This allows clean code restores to recover terminal/license context from Supabase
-- even when local app license cache is missing.

create or replace function public.resolve_install_from_device(
  p_device_id text,
  p_device_label text default null
)
returns table (
  organization_id uuid,
  organization_number text,
  organization_name text,
  location_id uuid,
  location_name text,
  name text,
  terminal_id uuid,
  terminal_number text,
  terminal_name text,
  license_key text,
  terminal_licenses integer,
  terminals_active integer,
  spin_tpn text,
  spin_auth_key text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device_id text;
  has_terminal_registered_device_id boolean;
  has_terminal_registered_device_label boolean;
begin
  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  if v_device_id is null then
    return;
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'registered_device_id'
  ) into has_terminal_registered_device_id;

  if not has_terminal_registered_device_id then
    return;
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'registered_device_label'
  ) into has_terminal_registered_device_label;

  if has_terminal_registered_device_label and nullif(trim(coalesce(p_device_label, '')), '') is not null then
    update public.terminals t
    set registered_device_label = trim(p_device_label)
    where t.registered_device_id = v_device_id
      and coalesce(t.is_active, true) = true;
  end if;

  return query
  select
    t.organization_id,
    coalesce(o.organization_number, ''),
    coalesce(o.name, ''),
    t.location_id,
    coalesce(l.name, ''),
    coalesce(l.name, ''),
    t.id,
    coalesce(t.terminal_number, ''),
    coalesce(t.terminal_name, t.name, t.code, 'Terminal ' || coalesce(t.terminal_number, '0001')),
    coalesce(o.license_key, ''),
    coalesce(l.terminal_licenses, 0),
    coalesce(l.terminals_active, 0),
    coalesce(t.spin_tpn, ''),
    coalesce(t.spin_auth_key, '')
  from public.terminals t
  left join public.organizations o on o.id = t.organization_id
  left join public.locations l on l.id = t.location_id
  where t.registered_device_id = v_device_id
    and coalesce(t.is_active, true) = true
  limit 1;
end;
$$;

revoke all on function public.resolve_install_from_device(text, text) from public;
grant execute on function public.resolve_install_from_device(text, text) to anon, authenticated;
