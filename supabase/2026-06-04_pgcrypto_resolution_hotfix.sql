-- Hotfix: resolve pgcrypto function lookup for auth RPCs on Supabase.
-- Run this once in SQL Editor.

begin;

create extension if not exists pgcrypto with schema extensions;

create or replace function public.upsert_master_console_user(
  p_username text,
  p_password text,
  p_display_name text default null,
  p_is_active boolean default true
)
returns public.master_console_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_password text := nullif(trim(coalesce(p_password, '')), '');
  v_user public.master_console_users;
begin
  if v_username is null then
    raise exception 'username is required';
  end if;

  if v_password is null then
    raise exception 'password is required';
  end if;

  insert into public.master_console_users (
    username,
    password_hash,
    display_name,
    is_active
  )
  values (
    v_username,
    extensions.crypt(v_password, extensions.gen_salt('bf')),
    nullif(trim(coalesce(p_display_name, '')), ''),
    coalesce(p_is_active, true)
  )
  on conflict ((lower(username))) do update
    set password_hash = excluded.password_hash,
        display_name = excluded.display_name,
        is_active = excluded.is_active
  returning * into v_user;

  return v_user;
end;
$$;

create or replace function public.console_login(
  p_username text,
  p_password text
)
returns table (
  authenticated boolean,
  principal_type text,
  user_id uuid,
  partner_id text,
  company_name text,
  message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_password text := nullif(trim(coalesce(p_password, '')), '');
  v_master public.master_console_users;
  v_partner public.distribution_partners;
begin
  if v_username is null or v_password is null then
    return query select false, 'none'::text, null::uuid, null::text, null::text, 'Username and password are required'::text;
    return;
  end if;

  select * into v_master
  from public.master_console_users m
  where lower(m.username) = lower(v_username)
    and m.is_active = true
  limit 1;

  if v_master.id is not null and v_master.password_hash = extensions.crypt(v_password, v_master.password_hash) then
    update public.master_console_users
    set last_login_at = timezone('utc', now())
    where id = v_master.id;

    return query select true, 'master'::text, v_master.id, null::text, null::text, 'Login successful'::text;
    return;
  end if;

  select * into v_partner
  from public.distribution_partners p
  where lower(p.username) = lower(v_username)
    and p.is_active = true
  limit 1;

  if v_partner.id is not null and v_partner.password_hash = extensions.crypt(v_password, v_partner.password_hash) then
    update public.distribution_partners
    set last_login_at = timezone('utc', now())
    where id = v_partner.id;

    return query select true, 'partner'::text, v_partner.id, v_partner.partner_id, v_partner.company_name, 'Login successful'::text;
    return;
  end if;

  return query select false, 'none'::text, null::uuid, null::text, null::text, 'Invalid username or password'::text;
end;
$$;

commit;

-- Quick validation:
-- select public.upsert_master_console_user('masteradmin', 'ChangeMeNow!', 'Master Admin', true);
-- select * from public.console_login('masteradmin', 'ChangeMeNow!');
