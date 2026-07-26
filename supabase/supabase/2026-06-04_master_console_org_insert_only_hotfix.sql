-- Hotfix: prevent accidental overwrite when creating organizations from master console.
-- Behavior:
-- - p_id provided: update existing organization by id.
-- - p_id null: insert only; never update an existing organization_number.

begin;

create or replace function public.upsert_organization_console_from_app(
  p_id uuid default null,
  p_organization_number text default null,
  p_name text default null,
  p_license_key text default null,
  p_contact_name text default null,
  p_contact_email text default null,
  p_contact_phone text default null
)
returns table (
  id uuid,
  organization_number text,
  name text,
  license_key text,
  is_active boolean,
  contact_name text,
  contact_email text,
  contact_phone text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_org_number text := nullif(trim(coalesce(p_organization_number, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_license_key text := nullif(trim(coalesce(p_license_key, '')), '');
  v_contact_name text := nullif(trim(coalesce(p_contact_name, '')), '');
  v_contact_email text := nullif(trim(coalesce(p_contact_email, '')), '');
  v_contact_phone text := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_is_active boolean := v_license_key is not null;
begin
  if v_org_number is null or v_name is null then
    raise exception 'Organization number and name are required';
  end if;

  if v_org_number !~ '^[0-9]{6}$' then
    raise exception 'Organization number must be exactly 6 digits';
  end if;

  if p_id is not null then
    update public.organizations
    set organization_number = v_org_number,
        name = v_name,
        license_key = v_license_key,
        is_active = v_is_active,
        contact_name = v_contact_name,
        contact_email = v_contact_email,
        contact_phone = v_contact_phone
    where organizations.id = p_id
    returning organizations.id into v_id;

    if v_id is null then
      raise exception 'Organization with id % was not found', p_id;
    end if;
  else
    if exists (
      select 1
      from public.organizations o
      where o.organization_number = v_org_number
    ) then
      raise exception 'Organization number % already exists. Use Edit Organization to change it.', v_org_number;
    end if;

    begin
      insert into public.organizations (
        organization_number,
        name,
        license_key,
        is_active,
        contact_name,
        contact_email,
        contact_phone
      )
      values (
        v_org_number,
        v_name,
        v_license_key,
        v_is_active,
        v_contact_name,
        v_contact_email,
        v_contact_phone
      )
      returning organizations.id into v_id;
    exception
      when unique_violation then
        raise exception 'Organization number % already exists. Use Edit Organization to change it.', v_org_number;
    end;
  end if;

  return query
  select
    o.id,
    o.organization_number,
    o.name,
    coalesce(o.license_key, ''),
    coalesce(o.is_active, true),
    coalesce(o.contact_name, ''),
    coalesce(o.contact_email, ''),
    coalesce(o.contact_phone, '')
  from public.organizations o
  where o.id = v_id
  limit 1;
end;
$$;

revoke all on function public.upsert_organization_console_from_app(uuid, text, text, text, text, text, text) from public;
grant execute on function public.upsert_organization_console_from_app(uuid, text, text, text, text, text, text) to anon, authenticated;

commit;
