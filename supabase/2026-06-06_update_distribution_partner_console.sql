-- Master Console: update distribution partner demographics.
-- Allows editing contact info and address; partner_id and credentials are immutable.
-- Safe to run multiple times.

begin;

drop function if exists public.update_distribution_partner_console_from_app(uuid, text, text, text, text, text, text, text, text, text, text, text);

create or replace function public.update_distribution_partner_console_from_app(
  p_id          uuid,
  p_company_name      text default null,
  p_contact_first_name  text default null,
  p_contact_last_name   text default null,
  p_email         text default null,
  p_phone         text default null,
  p_address_line_1    text default null,
  p_address_line_2    text default null,
  p_city          text default null,
  p_state         text default null,
  p_postal_code     text default null,
  p_country       text default null
)
returns table (
  id              uuid,
  partner_id          text,
  company_name        text,
  contact_first_name    text,
  contact_last_name   text,
  email           text,
  phone           text,
  address_line_1      text,
  address_line_2      text,
  city            text,
  state           text,
  postal_code       text,
  country         text,
  username        text,
  is_active       boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_name text := nullif(trim(coalesce(p_company_name, '')), '');
begin
  if p_id is null then
    raise exception 'Partner id is required';
  end if;

  if v_company_name is null then
    raise exception 'Company name is required';
  end if;

  if not exists (
    select 1 from public.distribution_partners dp where dp.id = p_id
  ) then
    raise exception 'Distribution partner not found';
  end if;

  update public.distribution_partners dp
  set
    company_name      = v_company_name,
    contact_first_name  = nullif(trim(coalesce(p_contact_first_name, '')), ''),
    contact_last_name   = nullif(trim(coalesce(p_contact_last_name, '')), ''),
    email         = nullif(trim(coalesce(p_email, '')), ''),
    phone         = nullif(trim(coalesce(p_phone, '')), ''),
    address_line_1    = nullif(trim(coalesce(p_address_line_1, '')), ''),
    address_line_2    = nullif(trim(coalesce(p_address_line_2, '')), ''),
    city          = nullif(trim(coalesce(p_city, '')), ''),
    state         = nullif(trim(coalesce(p_state, '')), ''),
    postal_code     = nullif(trim(coalesce(p_postal_code, '')), ''),
    country       = nullif(trim(coalesce(p_country, '')), '')
  where dp.id = p_id;

  return query
  select
    dp.id,
    coalesce(dp.partner_id, ''),
    coalesce(dp.company_name, ''),
    coalesce(dp.contact_first_name, ''),
    coalesce(dp.contact_last_name, ''),
    coalesce(dp.email, ''),
    coalesce(dp.phone, ''),
    coalesce(dp.address_line_1, ''),
    coalesce(dp.address_line_2, ''),
    coalesce(dp.city, ''),
    coalesce(dp.state, ''),
    coalesce(dp.postal_code, ''),
    coalesce(dp.country, 'US'),
    coalesce(dp.username, ''),
    coalesce(dp.is_active, false)
  from public.distribution_partners dp
  where dp.id = p_id
  limit 1;
end;
$$;

revoke all on function public.update_distribution_partner_console_from_app(uuid, text, text, text, text, text, text, text, text, text, text, text) from public;
grant execute on function public.update_distribution_partner_console_from_app(uuid, text, text, text, text, text, text, text, text, text, text, text) to anon, authenticated;

commit;
