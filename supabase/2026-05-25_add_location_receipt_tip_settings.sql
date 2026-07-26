-- Adds location-level receipt tip suggestion and footer message settings.
-- Safe to run multiple times.

alter table if exists public.locations
  add column if not exists print_tip_suggestions boolean not null default true,
  add column if not exists tip_suggestion_1_pct numeric(5,2) not null default 18,
  add column if not exists tip_suggestion_2_pct numeric(5,2) not null default 20,
  add column if not exists tip_suggestion_3_pct numeric(5,2) not null default 25,
  add column if not exists tip_suggestion_base text not null default 'subtotal',
  add column if not exists receipt_card_signature_message text,
  add column if not exists receipt_misc_message text;

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
  receipt_misc_message text
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
    nullif(trim(coalesce(to_jsonb(l)->>'receipt_misc_message', '')), '')
  from public.locations l
  where l.organization_id = v_org_id
    and l.id = v_location_id
  limit 1;
end;
$$;

revoke all on function public.get_location_profile_for_license(text, uuid, text) from public;
grant execute on function public.get_location_profile_for_license(text, uuid, text) to anon, authenticated;