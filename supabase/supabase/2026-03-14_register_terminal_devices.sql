-- Register terminals to a persistent device id and allow terminal activation/deactivation.

alter table public.terminals
  add column if not exists is_active boolean not null default true,
  add column if not exists registered_device_id text,
  add column if not exists registered_device_label text,
  add column if not exists registered_at timestamptz,
  add column if not exists last_seen_at timestamptz;

alter table public.locations
  add column if not exists terminal_licenses integer not null default 1,
  add column if not exists terminals_active integer not null default 0;

update public.locations l
set terminals_active = counts.active_count
from (
  select t.location_id, count(*)::integer as active_count
  from public.terminals t
  where coalesce(t.is_active, true) = true
  group by t.location_id
) counts
where l.id = counts.location_id;

create unique index if not exists idx_terminals_registered_device_id_unique
  on public.terminals (registered_device_id)
  where registered_device_id is not null;

drop function if exists public.activate_install_license(text, text, text, text, text, boolean);
drop function if exists public.activate_install_license(text, text, text, text, text);
drop function if exists public.activate_install_license(text, text, text, text);
drop function if exists public.activate_install_license(text, text, text);
drop function if exists public.activate_install_license(text, text);
drop function if exists public.activate_install_license(text);

create or replace function public.activate_install_license(
  p_license_key text,
  p_terminal_number text default null,
  p_location_name text default null,
  p_device_id text default null,
  p_device_label text default null,
  p_allow_register boolean default false
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
  legacy_gateway_api_login_id text,
  legacy_gateway_transaction_key text,
  terminal_licenses integer,
  terminals_active integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_org_number text;
  v_org_name text;
  v_location_id uuid;
  v_location_display_name text;
  v_location_terminal_licenses integer := 0;
  v_location_terminals_active integer := 0;
  v_legacy_gateway_api_login_id text;
  v_legacy_gateway_transaction_key text;
  v_terminal_id uuid;
  v_terminal_number text;
  v_terminal_name text;
  v_license_key text;
  v_location_name text;
  v_device_id text;
  v_device_label text;
  v_terminal_is_active boolean := true;
  has_location_created_at boolean;
  has_location_name boolean;
  has_terminal_name_field boolean;
  has_terminal_name boolean;
  has_terminal_code boolean;
  has_terminal_number boolean;
  has_terminal_org_number boolean;
  has_terminal_is_active boolean;
  has_terminal_registered_device_id boolean;
  has_terminal_registered_device_label boolean;
  has_terminal_registered_at boolean;
  has_terminal_last_seen_at boolean;
  v_terminal_name_expr text;
  v_sql text;
begin
  v_license_key := nullif(trim(p_license_key), '');
  if v_license_key is null then
    raise exception 'License key is required';
  end if;

  select o.id, o.organization_number
  into v_org_id, v_org_number
  from public.organizations o
  where o.license_key = v_license_key
     or o.organization_number = v_license_key
  limit 1;

  if v_org_id is null and v_license_key like 'DEMO-LICENSE-%' then
    select o.id, o.organization_number
    into v_org_id, v_org_number
    from public.organizations o
    where o.organization_number = right(v_license_key, 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  if coalesce(v_org_number, '') = '' then
    raise exception 'Organization is missing organization_number';
  end if;

  select coalesce(o.name, '')
  into v_org_name
  from public.organizations o
  where o.id = v_org_id
  limit 1;

  v_terminal_number := coalesce(nullif(trim(p_terminal_number), ''), '0001');
  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');
  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  v_device_label := nullif(trim(coalesce(p_device_label, '')), '');

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'created_at'
  ) into has_location_created_at;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'locations' and column_name = 'name'
  ) into has_location_name;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'terminal_name'
  ) into has_terminal_name_field;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'name'
  ) into has_terminal_name;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'code'
  ) into has_terminal_code;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'terminal_number'
  ) into has_terminal_number;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'organization_number'
  ) into has_terminal_org_number;
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
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'registered_at'
  ) into has_terminal_registered_at;
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'last_seen_at'
  ) into has_terminal_last_seen_at;

  v_terminal_name_expr := 'coalesce(';
  if has_terminal_name_field then
    v_terminal_name_expr := v_terminal_name_expr || 't.terminal_name,';
  end if;
  if has_terminal_name then
    v_terminal_name_expr := v_terminal_name_expr || 't.name,';
  end if;
  if has_terminal_code then
    v_terminal_name_expr := v_terminal_name_expr || 't.code,';
  end if;
  v_terminal_name_expr := v_terminal_name_expr || quote_literal('Terminal ' || v_terminal_number) || ')';

  if v_device_id is not null and has_terminal_registered_device_id then
    v_sql :=
      'select t.id, t.location_id, ' || v_terminal_name_expr || ', ' ||
      case when has_terminal_is_active then 'coalesce(t.is_active, true)' else 'true' end ||
      ' from public.terminals t where t.organization_id = $1 and t.registered_device_id = $2 limit 1';
    execute v_sql into v_terminal_id, v_location_id, v_terminal_name, v_terminal_is_active using v_org_id, v_device_id;

    if v_terminal_id is not null and not coalesce(v_terminal_is_active, true) then
      if not coalesce(p_allow_register, false) then
        raise exception 'The terminal registered to this device is inactive';
      end if;

      select coalesce(l.terminal_licenses, 0)
      into v_location_terminal_licenses
      from public.locations l
      where l.id = v_location_id
      limit 1;

      select count(*)::integer
      into v_location_terminals_active
      from public.terminals t
      where t.location_id = v_location_id
        and coalesce(t.is_active, true) = true;

      if v_location_terminal_licenses > 0 and
         v_location_terminals_active >= v_location_terminal_licenses then
        raise exception 'Terminal license limit reached for this location';
      end if;

      if has_terminal_is_active then
        update public.terminals as t
        set is_active = true
        where t.id = v_terminal_id;
      end if;
      v_terminal_is_active := true;
    end if;
  end if;

  if v_terminal_id is null then
    if v_device_id is not null and not coalesce(p_allow_register, false) then
      raise exception 'No terminal is registered to this device';
    end if;

    if v_location_name is not null and has_location_name then
      if has_location_created_at then
        v_sql := 'select l.id from public.locations l where l.organization_id = $1 and lower(coalesce(l.name, '''')) = lower($2) order by l.created_at nulls last, l.id limit 1';
      else
        v_sql := 'select l.id from public.locations l where l.organization_id = $1 and lower(coalesce(l.name, '''')) = lower($2) order by l.id limit 1';
      end if;
      execute v_sql into v_location_id using v_org_id, v_location_name;
    end if;

    if v_location_id is null then
      if has_location_created_at then
        v_sql := 'select l.id from public.locations l where l.organization_id = $1 order by l.created_at nulls last, l.id limit 1';
      else
        v_sql := 'select l.id from public.locations l where l.organization_id = $1 order by l.id limit 1';
      end if;
      execute v_sql into v_location_id using v_org_id;
    end if;

    if v_location_id is null and v_location_name is not null then
      raise exception 'Location "%" not found for licensed organization', v_location_name;
    end if;

    if v_location_id is null then
      if has_location_name then
        insert into public.locations (organization_id, name)
        values (v_org_id, 'Primary Location')
        returning id into v_location_id;
      else
        insert into public.locations (organization_id)
        values (v_org_id)
        returning id into v_location_id;
      end if;
    end if;

    select
      coalesce(l.name, ''),
      coalesce(l.terminal_licenses, 0),
      coalesce(l.terminals_active, 0),
      coalesce(l.legacy_gateway_api_login_id, ''),
      coalesce(l.legacy_gateway_transaction_key, '')
    into
      v_location_display_name,
      v_location_terminal_licenses,
      v_location_terminals_active,
      v_legacy_gateway_api_login_id,
      v_legacy_gateway_transaction_key
    from public.locations l
    where l.id = v_location_id
    limit 1;

    select count(*)::integer
    into v_location_terminals_active
    from public.terminals t
    where t.location_id = v_location_id
      and coalesce(t.is_active, true) = true;

    v_sql :=
      'select t.id, ' || v_terminal_name_expr || ', ' ||
      case when has_terminal_is_active then 'coalesce(t.is_active, true)' else 'true' end ||
      ' from public.terminals t where t.organization_id = $1 and t.location_id = $2';
    if has_terminal_number then
      v_sql := v_sql || ' and t.terminal_number = $3';
    end if;
    v_sql := v_sql || ' limit 1';
    execute v_sql into v_terminal_id, v_terminal_name, v_terminal_is_active using v_org_id, v_location_id, v_terminal_number;

    if v_terminal_id is not null and not coalesce(v_terminal_is_active, true) then
      if not coalesce(p_allow_register, false) then
        raise exception 'Terminal % is inactive', v_terminal_number;
      end if;

      if v_location_terminal_licenses > 0 and
         v_location_terminals_active >= v_location_terminal_licenses then
        raise exception 'Terminal license limit reached for this location';
      end if;

      if has_terminal_is_active then
        update public.terminals as t
        set is_active = true
        where t.id = v_terminal_id;
      end if;
      v_terminal_is_active := true;
    end if;

    if v_terminal_id is null then
      if not coalesce(p_allow_register, false) then
        raise exception 'Terminal % is not registered for this device', v_terminal_number;
      end if;
      if v_location_terminal_licenses > 0 and
         v_location_terminals_active >= v_location_terminal_licenses then
        raise exception 'Terminal license limit reached for this location';
      end if;

      v_sql := 'insert into public.terminals (organization_id, location_id';
      if has_terminal_org_number then
        v_sql := v_sql || ', organization_number';
      end if;
      if has_terminal_number then
        v_sql := v_sql || ', terminal_number';
      end if;
      if has_terminal_name then
        v_sql := v_sql || ', name';
      end if;
      if has_terminal_code then
        v_sql := v_sql || ', code';
      end if;
      if has_terminal_name_field then
        v_sql := v_sql || ', terminal_name';
      end if;
      if has_terminal_is_active then
        v_sql := v_sql || ', is_active';
      end if;
      v_sql := v_sql || ') values (' ||
        quote_literal(v_org_id::text) || '::uuid, ' ||
        quote_literal(v_location_id::text) || '::uuid';
      if has_terminal_org_number then
        v_sql := v_sql || ', ' || quote_literal(v_org_number);
      end if;
      if has_terminal_number then
        v_sql := v_sql || ', ' || quote_literal(v_terminal_number);
      end if;
      if has_terminal_name then
        v_sql := v_sql || ', ' || quote_literal('Terminal ' || v_terminal_number);
      end if;
      if has_terminal_code then
        v_sql := v_sql || ', ' || quote_literal(v_terminal_number);
      end if;
      if has_terminal_name_field then
        v_sql := v_sql || ', ' || quote_literal('Terminal ' || v_terminal_number);
      end if;
      if has_terminal_is_active then
        v_sql := v_sql || ', true';
      end if;
      v_sql := v_sql || ') returning id';
      execute v_sql into v_terminal_id;

      v_sql := 'select ' || v_terminal_name_expr || ' from public.terminals t where t.id = $1';
      execute v_sql into v_terminal_name using v_terminal_id;
    end if;
  end if;

  if v_location_id is not null then
    select
      coalesce(l.name, ''),
      coalesce(l.terminal_licenses, 0),
      coalesce(l.terminals_active, 0),
      coalesce(l.legacy_gateway_api_login_id, ''),
      coalesce(l.legacy_gateway_transaction_key, '')
    into
      v_location_display_name,
      v_location_terminal_licenses,
      v_location_terminals_active,
      v_legacy_gateway_api_login_id,
      v_legacy_gateway_transaction_key
    from public.locations l
    where l.id = v_location_id
    limit 1;
  end if;

  if has_terminal_registered_device_id and v_device_id is not null then
    update public.terminals as t
    set registered_device_id = null,
        registered_device_label = null
    where t.organization_id = v_org_id
      and t.id <> v_terminal_id
      and t.registered_device_id = v_device_id;

    update public.terminals as t
    set registered_device_id = v_device_id,
        registered_device_label = coalesce(v_device_label, t.registered_device_label),
        registered_at = case when has_terminal_registered_at then coalesce(t.registered_at, timezone('utc', now())) else t.registered_at end,
        last_seen_at = case when has_terminal_last_seen_at then timezone('utc', now()) else t.last_seen_at end
    where t.id = v_terminal_id;
  elsif has_terminal_last_seen_at then
    update public.terminals as t
    set last_seen_at = timezone('utc', now())
    where t.id = v_terminal_id;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'application_license_number'
  ) then
    update public.terminals as t set application_license_number = v_license_key where t.id = v_terminal_id;
  elsif exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'license_number'
  ) then
    update public.terminals as t set license_number = v_license_key where t.id = v_terminal_id;
  elsif exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'terminals' and column_name = 'license_key'
  ) then
    update public.terminals as t set license_key = v_license_key where t.id = v_terminal_id;
  end if;

  select count(*)::integer
  into v_location_terminals_active
  from public.terminals t
  where t.location_id = v_location_id
    and coalesce(t.is_active, true) = true;

  update public.locations l
  set terminals_active = v_location_terminals_active
  where l.id = v_location_id;

  return query
  select
    v_org_id,
    v_org_number,
    v_org_name,
    v_location_id,
    v_location_display_name,
    coalesce(v_location_display_name, ''),
    v_terminal_id,
    v_terminal_number,
    v_terminal_name,
    v_legacy_gateway_api_login_id,
    v_legacy_gateway_transaction_key,
    v_location_terminal_licenses,
    v_location_terminals_active;
end;
$$;

revoke all on function public.activate_install_license(text, text, text, text, text, boolean) from public;
grant execute on function public.activate_install_license(text, text, text, text, text, boolean) to anon, authenticated;

drop function if exists public.list_terminals_for_license(text, text);

create or replace function public.list_terminals_for_license(
  p_license_key text,
  p_location_name text default null
)
returns table (
  terminal_number text,
  terminal_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_context record;
  has_terminal_name_field boolean;
  has_terminal_name boolean;
  has_terminal_code boolean;
  has_terminal_number boolean;
  has_terminal_is_active boolean;
  v_terminal_name_expr text;
  v_sql text;
begin
  select *
  into v_context
  from public.activate_install_license(
    p_license_key,
    '0001',
    nullif(trim(coalesce(p_location_name, '')), ''),
    null,
    null,
    true
  )
  limit 1;

  if v_context.organization_id is null or v_context.location_id is null then
    return;
  end if;

  select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'terminals' and column_name = 'terminal_name') into has_terminal_name_field;
  select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'terminals' and column_name = 'name') into has_terminal_name;
  select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'terminals' and column_name = 'code') into has_terminal_code;
  select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'terminals' and column_name = 'terminal_number') into has_terminal_number;
  select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'terminals' and column_name = 'is_active') into has_terminal_is_active;

  v_terminal_name_expr := 'coalesce(';
  if has_terminal_name_field then
    v_terminal_name_expr := v_terminal_name_expr || 't.terminal_name,';
  end if;
  if has_terminal_name then
    v_terminal_name_expr := v_terminal_name_expr || 't.name,';
  end if;
  if has_terminal_code then
    v_terminal_name_expr := v_terminal_name_expr || 't.code,';
  end if;
  v_terminal_name_expr := v_terminal_name_expr || quote_literal('Terminal 0001') || ')';

  if has_terminal_number then
    v_sql :=
      'select coalesce(t.terminal_number, ''0001'') as terminal_number, ' ||
      v_terminal_name_expr ||
      ' as terminal_name from public.terminals t where t.organization_id = $1 and t.location_id = $2';
  else
    v_sql :=
      'select ''0001'' as terminal_number, ' ||
      v_terminal_name_expr ||
      ' as terminal_name from public.terminals t where t.organization_id = $1 and t.location_id = $2';
  end if;

  if has_terminal_is_active then
    v_sql := v_sql || ' and coalesce(t.is_active, true) = true';
  end if;

  if has_terminal_number then
    v_sql := v_sql || ' order by t.terminal_number nulls last, t.id';
  else
    v_sql := v_sql || ' order by t.id';
  end if;

  return query execute v_sql using v_context.organization_id, v_context.location_id;
end;
$$;

revoke all on function public.list_terminals_for_license(text, text) from public;
grant execute on function public.list_terminals_for_license(text, text) to anon, authenticated;

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
  last_seen_at timestamptz
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
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(trim(coalesce(p_license_key, '')), 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');
  if v_location_name is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(v_location_name)
    limit 1;
  end if;

  if v_location_id is null then
    select l.id
    into v_location_id
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
    coalesce(t.name, t.code, 'Terminal ' || coalesce(t.terminal_number, '0001')),
    t.code,
    coalesce(t.is_active, true),
    t.registered_device_id,
    t.registered_device_label,
    t.last_seen_at
  from public.terminals t
  left join public.locations l on l.id = t.location_id
  where t.organization_id = v_org_id
    and (v_location_id is null or t.location_id = v_location_id)
  order by coalesce(t.terminal_number, '0001'), t.id;
end;
$$;

revoke all on function public.list_terminals_from_app(text, text) from public;
grant execute on function public.list_terminals_from_app(text, text) to anon, authenticated;

drop function if exists public.update_location_terminal_limits_from_app(text, uuid, text, integer, integer);

create or replace function public.update_location_terminal_limits_from_app(
  p_license_key text,
  p_location_id uuid default null,
  p_location_name text default null,
  p_terminal_licenses integer default null,
  p_terminals_active integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
begin
  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = nullif(trim(coalesce(p_license_key, '')), '')
     or o.organization_number = nullif(trim(coalesce(p_license_key, '')), '')
  limit 1;

  if v_org_id is null and trim(coalesce(p_license_key, '')) like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(trim(coalesce(p_license_key, '')), 6)
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

  if v_location_id is null and nullif(trim(coalesce(p_location_name, '')), '') is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(trim(coalesce(p_location_name, '')))
    limit 1;
  end if;

  if v_location_id is null then
    raise exception 'Location not found for licensed organization';
  end if;

  update public.locations l
  set terminal_licenses = coalesce(p_terminal_licenses, l.terminal_licenses),
      terminals_active = coalesce(p_terminals_active, l.terminals_active)
  where l.id = v_location_id;

  return v_location_id;
end;
$$;

revoke all on function public.update_location_terminal_limits_from_app(text, uuid, text, integer, integer) from public;
grant execute on function public.update_location_terminal_limits_from_app(text, uuid, text, integer, integer) to anon, authenticated;

drop function if exists public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, boolean);

create or replace function public.upsert_terminal_from_app(
  p_license_key text,
  p_location_id uuid,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_name text default null,
  p_code text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_terminal_id uuid;
  v_terminal_number text;
  v_name text;
  v_code text;
  v_existing_is_active boolean := false;
  v_location_terminal_licenses integer := 0;
  v_location_active_count integer := 0;
begin
  v_terminal_number := coalesce(nullif(trim(coalesce(p_terminal_number, '')), ''), '0001');
  v_name := coalesce(nullif(trim(coalesce(p_name, '')), ''), 'Terminal ' || v_terminal_number);
  v_code := nullif(trim(coalesce(p_code, '')), '');

  if v_terminal_number !~ '^[0-9]{4}$' then
    raise exception 'Terminal number must be exactly 4 digits';
  end if;

  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = nullif(trim(coalesce(p_license_key, '')), '')
     or o.organization_number = nullif(trim(coalesce(p_license_key, '')), '')
  limit 1;

  if v_org_id is null and trim(coalesce(p_license_key, '')) like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(trim(coalesce(p_license_key, '')), 6)
    limit 1;
  end if;

  if v_org_id is null then
    raise exception 'Invalid license key';
  end if;

  select l.id
  into v_location_id
  from public.locations l
  where l.id = p_location_id
    and l.organization_id = v_org_id
  limit 1;

  if v_location_id is null then
    raise exception 'Location not found for licensed organization';
  end if;

  if p_terminal_id is not null then
    select t.id
    into v_terminal_id
    from public.terminals t
    where t.id = p_terminal_id
      and t.organization_id = v_org_id
    limit 1;
  end if;

  if v_terminal_id is null then
    select t.id
    into v_terminal_id
    from public.terminals t
    where t.organization_id = v_org_id
      and t.location_id = v_location_id
      and t.terminal_number = v_terminal_number
    limit 1;
  end if;

  if v_terminal_id is null then
    select coalesce(l.terminal_licenses, 0)
    into v_location_terminal_licenses
    from public.locations l
    where l.id = v_location_id
    limit 1;

    select count(*)::integer
    into v_location_active_count
    from public.terminals t
    where t.location_id = v_location_id
      and coalesce(t.is_active, true) = true;

    if coalesce(p_is_active, true) = true and
       v_location_terminal_licenses > 0 and
       v_location_active_count >= v_location_terminal_licenses then
      raise exception 'Terminal license limit reached for this location';
    end if;

    insert into public.terminals (
      organization_id,
      organization_number,
      location_id,
      terminal_number,
      name,
      code,
      is_active
    )
    values (
      v_org_id,
      (select organization_number from public.organizations where id = v_org_id),
      v_location_id,
      v_terminal_number,
      v_name,
      coalesce(v_code, v_terminal_number),
      coalesce(p_is_active, true)
    )
    returning id into v_terminal_id;
  else
    select coalesce(t.is_active, true)
    into v_existing_is_active
    from public.terminals t
    where t.id = v_terminal_id
    limit 1;

    if coalesce(p_is_active, true) = true and not coalesce(v_existing_is_active, false) then
      select coalesce(l.terminal_licenses, 0)
      into v_location_terminal_licenses
      from public.locations l
      where l.id = v_location_id
      limit 1;

      select count(*)::integer
      into v_location_active_count
      from public.terminals t
      where t.location_id = v_location_id
        and coalesce(t.is_active, true) = true
        and t.id <> v_terminal_id;

      if v_location_terminal_licenses > 0 and
         v_location_active_count >= v_location_terminal_licenses then
        raise exception 'Terminal license limit reached for this location';
      end if;
    end if;

    update public.terminals
    set location_id = v_location_id,
        terminal_number = v_terminal_number,
        name = v_name,
        code = coalesce(v_code, code, v_terminal_number),
        is_active = coalesce(p_is_active, true)
    where id = v_terminal_id;
  end if;

  if coalesce(p_is_active, true) = false then
    update public.terminals
    set registered_device_id = null,
        registered_device_label = null
    where id = v_terminal_id;
  end if;

  update public.locations l
  set terminals_active = (
    select count(*)::integer
    from public.terminals t
    where t.location_id = l.id
      and coalesce(t.is_active, true) = true
  )
  where l.id = v_location_id;

  return v_terminal_id;
end;
$$;

revoke all on function public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, boolean) from public;
grant execute on function public.upsert_terminal_from_app(text, uuid, uuid, text, text, text, boolean) to anon, authenticated;
