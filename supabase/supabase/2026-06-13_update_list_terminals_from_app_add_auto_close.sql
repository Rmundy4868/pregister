-- Ensure list_terminals_from_app returns terminal auto-close fields.
-- This allows app screens to read auto-close values through the license-safe RPC path
-- even when direct terminals table reads are blocked by RLS/policies.
--
-- Prerequisite: run 2026-06-13_terminal_auto_close_batch_settings.sql first.

begin;

drop function if exists public.list_terminals_from_app(text, text);

create or replace function public.list_terminals_from_app(
  p_license_key text,
  p_location_name text default null
)
returns table (
  id uuid,
  organization_id uuid,
  location_id uuid,
  location_name text,
  terminal_number text,
  terminal_name text,
  code text,
  is_active boolean,
  registered_device_id text,
  registered_device_label text,
  last_seen_at timestamptz,
  spin_tpn text,
  spin_auth_key text,
  card_reader_type text,
  card_reader_hpp_auth_token text,
  receipt_printer_name text,
  auto_close_batch_enabled boolean,
  auto_close_batch_time text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_location_name text;
begin
  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = nullif(trim(coalesce(p_license_key, '')), '')
     or o.organization_number = nullif(trim(coalesce(p_license_key, '')), '')
  limit 1;

  if v_org_id is null and trim(coalesce(p_license_key, '')) like 'DEMO-LICENSE-%' then
    select o.id into v_org_id
    from public.organizations o
    where o.organization_number = right(trim(coalesce(p_license_key, '')), 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');
  if v_location_name is not null then
    select l.id into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(v_location_name)
    limit 1;
  end if;

  if v_location_id is null then
    select l.id into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
    order by l.created_at nulls last, l.id
    limit 1;
  end if;

  return query
  select
    t.id,
    t.organization_id,
    t.location_id,
    l.name,
    coalesce(t.terminal_number, '0001'),
    coalesce(t.terminal_name, t.name, t.code, 'Terminal ' || coalesce(t.terminal_number, '0001')),
    t.code,
    coalesce(t.is_active, true),
    t.registered_device_id,
    t.registered_device_label,
    t.last_seen_at,
    coalesce(t.spin_tpn, ''),
    coalesce(t.spin_auth_key, ''),
    coalesce(nullif(trim(t.card_reader_type), ''), 'dejavoo_p12'),
    coalesce(t.card_reader_hpp_auth_token, ''),
    coalesce(t.receipt_printer_name, ''),
    coalesce(t.auto_close_batch_enabled, false),
    coalesce(t.auto_close_batch_time, '')
  from public.terminals t
  left join public.locations l on l.id = t.location_id
  where t.organization_id = v_org_id
    and (v_location_id is null or t.location_id = v_location_id)
  order by coalesce(t.terminal_number, '0001'), t.id;
end;
$$;

revoke all on function public.list_terminals_from_app(text, text) from public;
grant execute on function public.list_terminals_from_app(text, text) to anon, authenticated;

commit;
