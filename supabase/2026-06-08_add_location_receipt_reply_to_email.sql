-- Adds location-level receipt reply-to email support.
-- Safe to run multiple times.

begin;

alter table if exists public.locations
  add column if not exists receipt_reply_to_email text;

drop function if exists public.update_location_receipt_settings_from_app(text, uuid, text, boolean, numeric, numeric, numeric, text, text, text);

create or replace function public.update_location_receipt_settings_from_app(
  p_license_key text,
  p_location_id uuid default null,
  p_location_name text default null,
  p_print_tip_suggestions boolean default true,
  p_tip_suggestion_1_pct numeric default 18,
  p_tip_suggestion_2_pct numeric default 20,
  p_tip_suggestion_3_pct numeric default 25,
  p_tip_suggestion_base text default 'subtotal',
  p_receipt_card_signature_message text default null,
  p_receipt_misc_message text default null,
  p_receipt_reply_to_email text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_location_id uuid;
  v_license_key text;
  v_location_name text;
  has_print_tip_suggestions boolean;
  has_tip_suggestion_1_pct boolean;
  has_tip_suggestion_2_pct boolean;
  has_tip_suggestion_3_pct boolean;
  has_tip_suggestion_base boolean;
  has_receipt_card_signature_message boolean;
  has_receipt_misc_message boolean;
  has_receipt_reply_to_email boolean;
  v_tip_suggestion_base text;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');

  if v_license_key is null then
    raise exception 'License key is required';
  end if;

  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = v_license_key
     or o.organization_number = v_license_key
  limit 1;

  if v_org_id is null and v_license_key like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(v_license_key, 6)
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

  if v_location_id is null and v_location_name is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and lower(coalesce(l.name, '')) = lower(v_location_name)
    limit 1;
  end if;

  if v_location_id is null then
    raise exception 'Location not found for license context';
  end if;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'print_tip_suggestions'
  ) into has_print_tip_suggestions;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'tip_suggestion_1_pct'
  ) into has_tip_suggestion_1_pct;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'tip_suggestion_2_pct'
  ) into has_tip_suggestion_2_pct;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'tip_suggestion_3_pct'
  ) into has_tip_suggestion_3_pct;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'tip_suggestion_base'
  ) into has_tip_suggestion_base;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'receipt_card_signature_message'
  ) into has_receipt_card_signature_message;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'receipt_misc_message'
  ) into has_receipt_misc_message;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'locations'
      and column_name = 'receipt_reply_to_email'
  ) into has_receipt_reply_to_email;

  v_tip_suggestion_base := case
    when lower(coalesce(trim(p_tip_suggestion_base), 'subtotal')) = 'total' then 'total'
    else 'subtotal'
  end;

  if has_print_tip_suggestions and has_tip_suggestion_1_pct and has_tip_suggestion_2_pct and has_tip_suggestion_3_pct and has_tip_suggestion_base and has_receipt_card_signature_message and has_receipt_misc_message and has_receipt_reply_to_email then
    update public.locations
    set print_tip_suggestions = coalesce(p_print_tip_suggestions, true),
        tip_suggestion_1_pct = coalesce(p_tip_suggestion_1_pct, 18),
        tip_suggestion_2_pct = coalesce(p_tip_suggestion_2_pct, 20),
        tip_suggestion_3_pct = coalesce(p_tip_suggestion_3_pct, 25),
        tip_suggestion_base = v_tip_suggestion_base,
        receipt_card_signature_message = nullif(trim(coalesce(p_receipt_card_signature_message, '')), ''),
        receipt_misc_message = nullif(trim(coalesce(p_receipt_misc_message, '')), ''),
        receipt_reply_to_email = nullif(trim(coalesce(p_receipt_reply_to_email, '')), '')
    where id = v_location_id;
  end if;

  return v_location_id;
end;
$$;

drop function if exists public.get_location_profile_for_license(text, uuid, text);

create or replace function public.get_location_profile_for_license(
  p_license_key text,
  p_location_id uuid default null,
  p_location_name text default null
)
returns table (
  location_id uuid,
  location_name text,
  address_1 text,
  address_2 text,
  city text,
  state text,
  zip text,
  phone text,
  allow_tip_adjustments boolean,
  print_tip_suggestions boolean,
  tip_suggestion_1_pct numeric,
  tip_suggestion_2_pct numeric,
  tip_suggestion_3_pct numeric,
  tip_suggestion_base text,
  receipt_card_signature_message text,
  receipt_misc_message text,
  receipt_reply_to_email text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_license_key text;
  v_location_id uuid;
  v_location_name text;
begin
  v_license_key := nullif(trim(coalesce(p_license_key, '')), '');
  v_location_name := nullif(trim(coalesce(p_location_name, '')), '');

  if v_license_key is null then
    return;
  end if;

  select o.id
  into v_org_id
  from public.organizations o
  where o.license_key = v_license_key
     or o.organization_number = v_license_key
  limit 1;

  if v_org_id is null and v_license_key like 'DEMO-LICENSE-%' then
    select o.id
    into v_org_id
    from public.organizations o
    where o.organization_number = right(v_license_key, 6)
    limit 1;
  end if;

  if v_org_id is null then
    return;
  end if;

  if p_location_id is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and l.id = p_location_id
    limit 1;
  end if;

  if v_location_id is null and v_location_name is not null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
      and (
        lower(coalesce(to_jsonb(l)->>'name', '')) = lower(v_location_name)
        or lower(coalesce(to_jsonb(l)->>'location_name', '')) = lower(v_location_name)
      )
    limit 1;
  end if;

  if v_location_id is null then
    select l.id
    into v_location_id
    from public.locations l
    where l.organization_id = v_org_id
    order by l.id
    limit 1;
  end if;

  if v_location_id is null then
    return;
  end if;

  return query
  select
    l.id,
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'location_name', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'name', '')), ''),
      l.id::text
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'address_1', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'address1', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'address', '')), '')
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'address_2', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'address2', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'suite', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'unit', '')), '')
    ),
    nullif(trim(coalesce(to_jsonb(l)->>'city', '')), ''),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'state', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'province', '')), '')
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'zip', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'postal_code', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'postcode', '')), '')
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'phone', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'telephone', '')), ''),
      nullif(trim(coalesce(to_jsonb(l)->>'phone_number', '')), '')
    ),
    coalesce((to_jsonb(l)->>'allow_tip_adjustments')::boolean, false),
    coalesce((to_jsonb(l)->>'print_tip_suggestions')::boolean, true),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'tip_suggestion_1_pct', '')), '')::numeric,
      18
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'tip_suggestion_2_pct', '')), '')::numeric,
      20
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'tip_suggestion_3_pct', '')), '')::numeric,
      25
    ),
    coalesce(
      nullif(trim(coalesce(to_jsonb(l)->>'tip_suggestion_base', '')), ''),
      'subtotal'
    ),
    nullif(trim(coalesce(to_jsonb(l)->>'receipt_card_signature_message', '')), ''),
    nullif(trim(coalesce(to_jsonb(l)->>'receipt_misc_message', '')), ''),
    nullif(trim(coalesce(to_jsonb(l)->>'receipt_reply_to_email', '')), '')
  from public.locations l
  where l.organization_id = v_org_id
    and l.id = v_location_id
  limit 1;
end;
$$;

revoke all on function public.update_location_receipt_settings_from_app(text, uuid, text, boolean, numeric, numeric, numeric, text, text, text, text) from public;
grant execute on function public.update_location_receipt_settings_from_app(text, uuid, text, boolean, numeric, numeric, numeric, text, text, text, text) to anon, authenticated;

revoke all on function public.get_location_profile_for_license(text, uuid, text) from public;
grant execute on function public.get_location_profile_for_license(text, uuid, text) to anon, authenticated;

commit;
