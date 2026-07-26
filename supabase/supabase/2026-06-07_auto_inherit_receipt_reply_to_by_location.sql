-- Auto-inherit receipt_reply_to_email by location when terminal value is blank.
-- This reduces per-terminal setup by allowing one location-level value to fan out.

begin;

-- 1) Backfill existing blank terminal rows from another terminal in the same location.
with location_defaults as (
  select distinct on (organization_id, location_id)
    organization_id,
    location_id,
    trim(receipt_reply_to_email) as reply_to
  from public.terminal_transaction_parameters
  where trim(coalesce(receipt_reply_to_email, '')) <> ''
  order by organization_id, location_id, updated_at desc nulls last, terminal_id
)
update public.terminal_transaction_parameters t
set receipt_reply_to_email = d.reply_to
from location_defaults d
where t.organization_id = d.organization_id
  and t.location_id = d.location_id
  and trim(coalesce(t.receipt_reply_to_email, '')) = '';

-- 2) Recreate setter RPC so blank input inherits from location default.
create or replace function public.set_terminal_transaction_parameters_from_app(
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
  p_receipt_reply_to_email text default '',
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
  v_inherited_reply_to text := '';
  v_effective_reply_to text := '';
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

  if trim(coalesce(p_receipt_reply_to_email, '')) = '' then
    select coalesce(trim(tp.receipt_reply_to_email), '')
    into v_inherited_reply_to
    from public.terminal_transaction_parameters tp
    where tp.organization_id = v_org_id
      and tp.location_id = v_loc_id
      and trim(coalesce(tp.receipt_reply_to_email, '')) <> ''
    order by tp.updated_at desc nulls last, tp.terminal_id
    limit 1;
  end if;

  v_effective_reply_to := case
    when trim(coalesce(p_receipt_reply_to_email, '')) <> ''
      then trim(p_receipt_reply_to_email)
    else coalesce(v_inherited_reply_to, '')
  end;

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
    receipt_reply_to_email,
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
    v_effective_reply_to,
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
    receipt_reply_to_email = excluded.receipt_reply_to_email,
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
    'receipt_reply_to_email', coalesce(trim(v_out.receipt_reply_to_email), ''),
    'customer_field_modes', coalesce(v_out.customer_field_modes, '{}'::jsonb),
    'updated_at', v_out.updated_at
  );
end;
$$;

grant execute on function public.set_terminal_transaction_parameters_from_app(text, uuid, text, text, boolean, boolean, boolean, integer, boolean, integer, boolean, integer, text, jsonb)
  to anon, authenticated;

commit;
