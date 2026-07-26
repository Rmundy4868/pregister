-- Adds terminal-backed receipt output parameters to terminal_transaction_parameters
-- so receipt preview/copy-count settings follow the terminal instead of the local device.

begin;

alter table if exists public.terminal_transaction_parameters
  add column if not exists sale_receipt_preview_enabled boolean not null default true,
  add column if not exists sale_receipt_copy_count integer not null default 2,
  add column if not exists void_receipt_preview_enabled boolean not null default true,
  add column if not exists void_receipt_copy_count integer not null default 2,
  add column if not exists return_receipt_preview_enabled boolean not null default true,
  add column if not exists return_receipt_copy_count integer not null default 2;

update public.terminal_transaction_parameters
set
  sale_receipt_preview_enabled = coalesce(sale_receipt_preview_enabled, true),
  sale_receipt_copy_count = greatest(0, least(coalesce(sale_receipt_copy_count, 2), 10)),
  void_receipt_preview_enabled = coalesce(void_receipt_preview_enabled, true),
  void_receipt_copy_count = greatest(0, least(coalesce(void_receipt_copy_count, 2), 10)),
  return_receipt_preview_enabled = coalesce(return_receipt_preview_enabled, true),
  return_receipt_copy_count = greatest(0, least(coalesce(return_receipt_copy_count, 2), 10));

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
      'sale_receipt_preview_enabled', true,
      'sale_receipt_copy_count', 2,
      'void_receipt_preview_enabled', true,
      'void_receipt_copy_count', 2,
      'return_receipt_preview_enabled', true,
      'return_receipt_copy_count', 2,
      'customer_field_modes', jsonb_build_object()
    );
  end if;

  return jsonb_build_object(
    'organization_id', v_row.organization_id,
    'location_id', v_row.location_id,
    'terminal_id', v_row.terminal_id,
    'staff_tracking_enabled', v_row.staff_tracking_enabled,
    'customer_tracking_enabled', v_row.customer_tracking_enabled,
    'sale_receipt_preview_enabled', coalesce(v_row.sale_receipt_preview_enabled, true),
    'sale_receipt_copy_count', greatest(0, least(coalesce(v_row.sale_receipt_copy_count, 2), 10)),
    'void_receipt_preview_enabled', coalesce(v_row.void_receipt_preview_enabled, true),
    'void_receipt_copy_count', greatest(0, least(coalesce(v_row.void_receipt_copy_count, 2), 10)),
    'return_receipt_preview_enabled', coalesce(v_row.return_receipt_preview_enabled, true),
    'return_receipt_copy_count', greatest(0, least(coalesce(v_row.return_receipt_copy_count, 2), 10)),
    'customer_field_modes', coalesce(v_row.customer_field_modes, '{}'::jsonb)
  );
end;
$$;

drop function if exists public.set_terminal_transaction_parameters_from_app(
  text,
  uuid,
  text,
  text,
  boolean,
  boolean,
  jsonb
);

drop function if exists public.set_terminal_transaction_parameters_from_app(
  text,
  uuid,
  text,
  text,
  boolean,
  boolean,
  boolean,
  integer,
  boolean,
  integer,
  boolean,
  integer,
  jsonb
);

create function public.set_terminal_transaction_parameters_from_app(
  p_license_key text,
  p_terminal_id uuid default null,
  p_terminal_number text default null,
  p_location_name text default null,
  p_staff_tracking_enabled boolean default false,
  p_customer_tracking_enabled boolean default false,
  p_sale_receipt_preview_enabled boolean default true,
  p_sale_receipt_copy_count integer default 2,
  p_void_receipt_preview_enabled boolean default true,
  p_void_receipt_copy_count integer default 2,
  p_return_receipt_preview_enabled boolean default true,
  p_return_receipt_copy_count integer default 2,
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
    sale_receipt_preview_enabled,
    sale_receipt_copy_count,
    void_receipt_preview_enabled,
    void_receipt_copy_count,
    return_receipt_preview_enabled,
    return_receipt_copy_count,
    customer_field_modes
  ) values (
    v_org_id,
    v_loc_id,
    v_term_id,
    coalesce(p_staff_tracking_enabled, false),
    coalesce(p_customer_tracking_enabled, false),
    coalesce(p_sale_receipt_preview_enabled, true),
    greatest(0, least(coalesce(p_sale_receipt_copy_count, 2), 10)),
    coalesce(p_void_receipt_preview_enabled, true),
    greatest(0, least(coalesce(p_void_receipt_copy_count, 2), 10)),
    coalesce(p_return_receipt_preview_enabled, true),
    greatest(0, least(coalesce(p_return_receipt_copy_count, 2), 10)),
    coalesce(p_customer_field_modes, '{}'::jsonb)
  )
  on conflict (terminal_id)
  do update set
    staff_tracking_enabled = excluded.staff_tracking_enabled,
    customer_tracking_enabled = excluded.customer_tracking_enabled,
    sale_receipt_preview_enabled = excluded.sale_receipt_preview_enabled,
    sale_receipt_copy_count = excluded.sale_receipt_copy_count,
    void_receipt_preview_enabled = excluded.void_receipt_preview_enabled,
    void_receipt_copy_count = excluded.void_receipt_copy_count,
    return_receipt_preview_enabled = excluded.return_receipt_preview_enabled,
    return_receipt_copy_count = excluded.return_receipt_copy_count,
    customer_field_modes = excluded.customer_field_modes,
    updated_at = timezone('utc', now())
  returning * into v_out;

  return jsonb_build_object(
    'organization_id', v_out.organization_id,
    'location_id', v_out.location_id,
    'terminal_id', v_out.terminal_id,
    'staff_tracking_enabled', v_out.staff_tracking_enabled,
    'customer_tracking_enabled', v_out.customer_tracking_enabled,
    'sale_receipt_preview_enabled', coalesce(v_out.sale_receipt_preview_enabled, true),
    'sale_receipt_copy_count', greatest(0, least(coalesce(v_out.sale_receipt_copy_count, 2), 10)),
    'void_receipt_preview_enabled', coalesce(v_out.void_receipt_preview_enabled, true),
    'void_receipt_copy_count', greatest(0, least(coalesce(v_out.void_receipt_copy_count, 2), 10)),
    'return_receipt_preview_enabled', coalesce(v_out.return_receipt_preview_enabled, true),
    'return_receipt_copy_count', greatest(0, least(coalesce(v_out.return_receipt_copy_count, 2), 10)),
    'customer_field_modes', coalesce(v_out.customer_field_modes, '{}'::jsonb),
    'updated_at', v_out.updated_at
  );
end;
$$;

grant execute on function public.get_terminal_transaction_parameters_from_app(text, uuid, text, text)
  to anon, authenticated;
grant execute on function public.set_terminal_transaction_parameters_from_app(text, uuid, text, text, boolean, boolean, boolean, integer, boolean, integer, boolean, integer, jsonb)
  to anon, authenticated;

commit;