-- Device-first bootstrap hardening.
-- Keeps existing registered_device_id flow, adds stronger identity metadata,
-- and enables startup lookup by device identity without local license storage.

begin;

alter table public.terminals
  add column if not exists device_public_key text,
  add column if not exists device_platform text,
  add column if not exists device_os_version text,
  add column if not exists device_fingerprint_hash text,
  add column if not exists device_trust_status text not null default 'trusted',
  add column if not exists device_trust_reason text,
  add column if not exists last_attested_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'terminals_device_trust_status_chk'
  ) then
    alter table public.terminals
      add constraint terminals_device_trust_status_chk
      check (device_trust_status in ('trusted', 'pending', 'revoked'));
  end if;
end
$$;

create index if not exists idx_terminals_device_trust_status
  on public.terminals (device_trust_status);

create index if not exists idx_terminals_device_platform
  on public.terminals (device_platform)
  where device_platform is not null;

create index if not exists idx_terminals_last_attested_at
  on public.terminals (last_attested_at)
  where last_attested_at is not null;

create or replace function public.bootstrap_terminal_by_device(
  p_device_id text,
  p_device_label text default null,
  p_device_platform text default null,
  p_device_os_version text default null,
  p_device_fingerprint_hash text default null,
  p_device_public_key text default null
)
returns table (
  organization_id uuid,
  organization_number text,
  organization_name text,
  location_id uuid,
  location_name text,
  terminal_id uuid,
  terminal_number text,
  terminal_name text,
  application_license_number text,
  registered_device_id text,
  registered_device_label text,
  device_trust_status text,
  terminal_is_active boolean,
  boot_allowed boolean,
  message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device_id text := nullif(trim(coalesce(p_device_id, '')), '');
  v_device_label text := nullif(trim(coalesce(p_device_label, '')), '');
  v_device_platform text := nullif(trim(coalesce(p_device_platform, '')), '');
  v_device_os_version text := nullif(trim(coalesce(p_device_os_version, '')), '');
  v_device_fingerprint_hash text := nullif(trim(coalesce(p_device_fingerprint_hash, '')), '');
  v_device_public_key text := nullif(trim(coalesce(p_device_public_key, '')), '');
begin
  if v_device_id is null then
    return query
    select
      null::uuid,
      null::text,
      null::text,
      null::uuid,
      null::text,
      null::uuid,
      null::text,
      null::text,
      null::text,
      null::text,
      null::text,
      null::text,
      false,
      false,
      'device_id is required'::text;
    return;
  end if;

  update public.terminals t
  set
    registered_device_label = coalesce(v_device_label, t.registered_device_label),
    device_platform = coalesce(v_device_platform, t.device_platform),
    device_os_version = coalesce(v_device_os_version, t.device_os_version),
    device_fingerprint_hash = coalesce(v_device_fingerprint_hash, t.device_fingerprint_hash),
    device_public_key = coalesce(v_device_public_key, t.device_public_key),
    last_seen_at = timezone('utc', now()),
    last_attested_at = timezone('utc', now())
  where t.registered_device_id = v_device_id;

  return query
  select
    o.id,
    o.organization_number,
    coalesce(o.name, ''),
    l.id,
    coalesce(l.name, ''),
    t.id,
    coalesce(t.terminal_number, '0001'),
    coalesce(t.name, t.code, 'Terminal ' || coalesce(t.terminal_number, '0001')),
    t.application_license_number,
    t.registered_device_id,
    t.registered_device_label,
    coalesce(t.device_trust_status, 'trusted'),
    coalesce(t.is_active, true),
    case
      when coalesce(t.is_active, true) = false then false
      when coalesce(t.device_trust_status, 'trusted') = 'revoked' then false
      else true
    end as boot_allowed,
    case
      when coalesce(t.is_active, true) = false then 'Terminal is inactive'
      when coalesce(t.device_trust_status, 'trusted') = 'revoked' then 'Device trust revoked'
      else 'Device bootstrap successful'
    end as message
  from public.terminals t
  join public.organizations o on o.id = t.organization_id
  left join public.locations l on l.id = t.location_id
  where t.registered_device_id = v_device_id
  limit 1;

  if not found then
    return query
    select
      null::uuid,
      null::text,
      null::text,
      null::uuid,
      null::text,
      null::uuid,
      null::text,
      null::text,
      null::text,
      v_device_id,
      v_device_label,
      null::text,
      false,
      false,
      'No terminal is registered to this device'::text;
  end if;
end;
$$;

revoke all on function public.bootstrap_terminal_by_device(text, text, text, text, text, text) from public;
grant execute on function public.bootstrap_terminal_by_device(text, text, text, text, text, text) to anon, authenticated;

commit;
