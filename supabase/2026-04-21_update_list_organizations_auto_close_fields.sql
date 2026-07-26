-- =============================================================================
-- 2026-04-21  list_organizations_from_app includes auto-close fields
-- =============================================================================
-- Ensures Organization Setup edit dialogs can recall auto-close toggle/time
-- through RPC paths when direct table select is restricted by RLS.
-- =============================================================================

drop function if exists public.list_organizations_from_app();

create or replace function public.list_organizations_from_app()
returns table (
  id uuid,
  organization_number text,
  name text,
  license_key text,
  auto_close_batch_enabled boolean,
  auto_close_batch_time time
)
language plpgsql
security definer
set search_path = public
as $$
declare
  has_license_key boolean;
  has_auto_close_enabled boolean;
  has_auto_close_time boolean;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'organizations'
      and column_name = 'license_key'
  ) into has_license_key;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'organizations'
      and column_name = 'auto_close_batch_enabled'
  ) into has_auto_close_enabled;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'organizations'
      and column_name = 'auto_close_batch_time'
  ) into has_auto_close_time;

  if has_license_key and has_auto_close_enabled and has_auto_close_time then
    return query
    select
      o.id,
      o.organization_number,
      o.name,
      o.license_key,
      coalesce(o.auto_close_batch_enabled, false) as auto_close_batch_enabled,
      o.auto_close_batch_time
    from public.organizations o
    order by o.organization_number;
  elsif has_license_key then
    return query
    select
      o.id,
      o.organization_number,
      o.name,
      o.license_key,
      false as auto_close_batch_enabled,
      null::time as auto_close_batch_time
    from public.organizations o
    order by o.organization_number;
  else
    return query
    select
      o.id,
      o.organization_number,
      o.name,
      null::text as license_key,
      false as auto_close_batch_enabled,
      null::time as auto_close_batch_time
    from public.organizations o
    order by o.organization_number;
  end if;
end;
$$;

revoke all on function public.list_organizations_from_app() from public;
grant execute on function public.list_organizations_from_app() to anon, authenticated;
