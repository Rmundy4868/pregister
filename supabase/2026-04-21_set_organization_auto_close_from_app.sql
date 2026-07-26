-- =============================================================================
-- 2026-04-21  set_organization_auto_close_from_app RPC
-- =============================================================================
-- Allows app clients (anon/authenticated) to update organization-level
-- auto-close settings via SECURITY DEFINER when direct table updates are blocked
-- by RLS or role permissions.
-- =============================================================================

drop function if exists public.set_organization_auto_close_from_app(text, boolean, time);
drop function if exists public.set_organization_auto_close_from_app(text, boolean, text);
drop function if exists public.set_organization_auto_close_from_app(text, boolean, timetz);

create or replace function public.set_organization_auto_close_from_app(
  p_organization_number text,
  p_auto_close_batch_enabled boolean,
  p_auto_close_batch_time text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_number text;
  v_time_text text;
  v_time_value time;
begin
  v_org_number := nullif(trim(coalesce(p_organization_number, '')), '');
  if v_org_number is null then
    raise exception 'Organization number is required';
  end if;

  v_time_text := nullif(trim(coalesce(p_auto_close_batch_time, '')), '');
  if coalesce(p_auto_close_batch_enabled, false) then
    if v_time_text is null then
      raise exception 'Auto-close time is required when auto-close is enabled';
    end if;

    begin
      v_time_value := v_time_text::time;
    exception
      when others then
        raise exception 'Invalid auto-close time format. Use HH:mm or HH:mm:ss (24-hour).';
    end;
  else
    v_time_value := null;
  end if;

  update public.organizations
  set auto_close_batch_enabled = coalesce(p_auto_close_batch_enabled, false),
      auto_close_batch_time = case
        when coalesce(p_auto_close_batch_enabled, false) then v_time_value
        else null
      end
  where organization_number = v_org_number;

  if not found then
    raise exception 'Organization not found for organization_number %', v_org_number;
  end if;
end;
$$;

revoke all on function public.set_organization_auto_close_from_app(text, boolean, text) from public;
grant execute on function public.set_organization_auto_close_from_app(text, boolean, text) to anon, authenticated;
