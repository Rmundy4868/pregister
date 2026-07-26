-- =============================================================================
-- 2026-05-05  Terminal transaction flow parameters (centralized)
-- =============================================================================
-- Stores transaction-flow settings per terminal so each terminal can have
-- different runtime behavior at enterprise scale.
--
-- Includes:
--   - staff_tracking_enabled
--   - customer_tracking_enabled
--   - customer_field_modes JSONB (required/optional/hide per field)
--
-- Access pattern for app clients uses SECURITY DEFINER RPCs so anon-key clients
-- can read/write scoped terminal settings using license + terminal context.
-- =============================================================================

create table if not exists public.terminal_transaction_parameters (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  terminal_id uuid not null references public.terminals(id) on delete cascade,
  staff_tracking_enabled boolean not null default false,
  customer_tracking_enabled boolean not null default false,
  customer_field_modes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (terminal_id)
);

create index if not exists idx_terminal_tx_params_terminal_id
  on public.terminal_transaction_parameters (terminal_id);

create index if not exists idx_terminal_tx_params_org_location
  on public.terminal_transaction_parameters (organization_id, location_id);

create or replace function public.touch_terminal_tx_params_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists trg_touch_terminal_tx_params_updated_at
  on public.terminal_transaction_parameters;

create trigger trg_touch_terminal_tx_params_updated_at
before update on public.terminal_transaction_parameters
for each row
execute function public.touch_terminal_tx_params_updated_at();

alter table public.terminal_transaction_parameters enable row level security;

drop policy if exists "Terminal tx params read by authenticated"
  on public.terminal_transaction_parameters;

create policy "Terminal tx params read by authenticated"
  on public.terminal_transaction_parameters
  for select
  to authenticated
  using (true);

drop policy if exists "Terminal tx params write by authenticated"
  on public.terminal_transaction_parameters;

create policy "Terminal tx params write by authenticated"
  on public.terminal_transaction_parameters
  for all
  to authenticated
  using (true)
  with check (true);

create or replace function public.resolve_terminal_from_license(
  p_license_key text,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_location_name text default null
)
returns table (
  organization_id uuid,
  location_id uuid,
  terminal_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lookup text := trim(coalesce(p_license_key, ''));
begin
  if p_terminal_id is not null then
    return query
    select t.organization_id, t.location_id, t.id
    from public.terminals t
    join public.organizations o on o.id = t.organization_id
    where t.id = p_terminal_id
      and (
        o.license_key = nullif(v_lookup, '')
        or o.organization_number = nullif(v_lookup, '')
      )
    limit 1;

    if found then
      return;
    end if;
  end if;

  return query
  select t.organization_id, t.location_id, t.id
  from public.terminals t
  join public.organizations o on o.id = t.organization_id
  join public.locations l on l.id = t.location_id
  where (
      o.license_key = nullif(v_lookup, '')
      or o.organization_number = nullif(v_lookup, '')
    )
    and (
      nullif(trim(coalesce(p_terminal_number, '')), '') is null
      or t.terminal_number = trim(coalesce(p_terminal_number, ''))
    )
    and (
      nullif(trim(coalesce(p_location_name, '')), '') is null
      or l.name = trim(coalesce(p_location_name, ''))
    )
  order by t.created_at asc
  limit 1;
end;
$$;

create or replace function public.get_terminal_transaction_parameters_from_app(
  p_license_key text,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_location_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_loc_id uuid;
  v_term_id uuid;
  v_row record;
begin
  select r.organization_id, r.location_id, r.terminal_id
  into v_org_id, v_loc_id, v_term_id
  from public.resolve_terminal_from_license(
    p_license_key,
    p_terminal_id,
    p_terminal_number,
    p_location_name
  ) as r
  limit 1;

  if v_term_id is null then
    return null;
  end if;

  select *
  into v_row
  from public.terminal_transaction_parameters p
  where p.terminal_id = v_term_id
  limit 1;

  if v_row is null then
    return jsonb_build_object(
      'organization_id', v_org_id,
      'location_id', v_loc_id,
      'terminal_id', v_term_id,
      'staff_tracking_enabled', false,
      'customer_tracking_enabled', false,
      'customer_field_modes', jsonb_build_object()
    );
  end if;

  return jsonb_build_object(
    'organization_id', v_row.organization_id,
    'location_id', v_row.location_id,
    'terminal_id', v_row.terminal_id,
    'staff_tracking_enabled', v_row.staff_tracking_enabled,
    'customer_tracking_enabled', v_row.customer_tracking_enabled,
    'customer_field_modes', coalesce(v_row.customer_field_modes, '{}'::jsonb)
  );
end;
$$;

create or replace function public.set_terminal_transaction_parameters_from_app(
  p_license_key text,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_location_name text default null,
  p_staff_tracking_enabled boolean default false,
  p_customer_tracking_enabled boolean default false,
  p_customer_field_modes jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_loc_id uuid;
  v_term_id uuid;
  v_out public.terminal_transaction_parameters%rowtype;
begin
  select r.organization_id, r.location_id, r.terminal_id
  into v_org_id, v_loc_id, v_term_id
  from public.resolve_terminal_from_license(
    p_license_key,
    p_terminal_id,
    p_terminal_number,
    p_location_name
  ) as r
  limit 1;

  if v_term_id is null then
    raise exception 'Terminal not found for provided license/terminal context';
  end if;

  insert into public.terminal_transaction_parameters (
    organization_id,
    location_id,
    terminal_id,
    staff_tracking_enabled,
    customer_tracking_enabled,
    customer_field_modes
  ) values (
    v_org_id,
    v_loc_id,
    v_term_id,
    coalesce(p_staff_tracking_enabled, false),
    coalesce(p_customer_tracking_enabled, false),
    coalesce(p_customer_field_modes, '{}'::jsonb)
  )
  on conflict (terminal_id)
  do update set
    staff_tracking_enabled = excluded.staff_tracking_enabled,
    customer_tracking_enabled = excluded.customer_tracking_enabled,
    customer_field_modes = excluded.customer_field_modes,
    updated_at = timezone('utc', now())
  returning * into v_out;

  return jsonb_build_object(
    'organization_id', v_out.organization_id,
    'location_id', v_out.location_id,
    'terminal_id', v_out.terminal_id,
    'staff_tracking_enabled', v_out.staff_tracking_enabled,
    'customer_tracking_enabled', v_out.customer_tracking_enabled,
    'customer_field_modes', coalesce(v_out.customer_field_modes, '{}'::jsonb),
    'updated_at', v_out.updated_at
  );
end;
$$;

grant execute on function public.resolve_terminal_from_license(text, uuid, text, text)
  to anon, authenticated;
grant execute on function public.get_terminal_transaction_parameters_from_app(text, uuid, text, text)
  to anon, authenticated;
grant execute on function public.set_terminal_transaction_parameters_from_app(text, uuid, text, text, boolean, boolean, jsonb)
  to anon, authenticated;
