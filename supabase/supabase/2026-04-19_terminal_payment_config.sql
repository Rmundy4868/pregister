-- ============================================================
-- Terminal Payment Configuration
-- 2026-04-19
--
-- Moves per-terminal payment credentials (SPIn TPN, auth key)
-- from dart-define build args into the terminals table.
-- The resolve_terminal_from_token RPC is updated to return
-- these fields so the app retrieves them at runtime.
-- ============================================================

-- 1. Add payment config columns to terminals (idempotent)
alter table public.terminals
  add column if not exists spin_tpn       text,
  add column if not exists spin_auth_key  text;

comment on column public.terminals.spin_tpn is
  'SPIn Terminal Parameter Number (TPN) from iPOSpays portal. '
  'Per-terminal — do not share between terminals.';

comment on column public.terminals.spin_auth_key is
  'SPIn authentication key from iPOSpays portal. '
  'Per-terminal credential — treat as a secret.';

-- 2. Update resolve_terminal_from_token to return payment config
drop function if exists public.resolve_terminal_from_token(text);

create or replace function public.resolve_terminal_from_token(p_token text)
returns table (
  terminal_id         uuid,
  terminal_number     text,
  terminal_name       text,
  location_id         uuid,
  location_name       text,
  organization_id     uuid,
  organization_number text,
  organization_name   text,
  license_key         text,
  spin_tpn            text,
  spin_auth_key       text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_token is null or trim(p_token) = '' then
    return;
  end if;

  return query
    select
      t.id                                                          as terminal_id,
      t.terminal_number                                             as terminal_number,
      coalesce(t.terminal_name, 'Terminal ' || t.terminal_number)  as terminal_name,
      t.location_id                                                 as location_id,
      coalesce(l.name, '')                                          as location_name,
      t.organization_id                                             as organization_id,
      coalesce(o.organization_number, '')                           as organization_number,
      coalesce(o.name, '')                                          as organization_name,
      coalesce(o.license_key, '')                                   as license_key,
      coalesce(t.spin_tpn, '')                                      as spin_tpn,
      coalesce(t.spin_auth_key, '')                                 as spin_auth_key
    from public.terminals t
    left join public.locations    l on l.id = t.location_id
    left join public.organizations o on o.id = t.organization_id
    where t.terminal_token = trim(p_token)
      and t.is_active = true
    limit 1;
end;
$$;

grant execute on function public.resolve_terminal_from_token(text) to anon;

-- 3. Seed demo terminal with SPIn credentials (update to your real values)
--    Run this after the migration; replace the token value with your terminal's token.
--
-- update public.terminals
--   set spin_tpn      = '220926696327',
--       spin_auth_key = '58txTAW8JN'
-- where terminal_token = '83bbe5bc-2dd2-433d-aa20-748d6bb7ab67';
