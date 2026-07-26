-- Seed data for multi-tenant testing.
-- Run AFTER:
-- 1) organization_structure_setup.sql
-- 2) settings_tables_policies.sql
-- 3) transactions_setup.sql

-- Replace these auth user IDs with real IDs from auth.users in your Supabase project.
-- Example query in Supabase SQL editor:
-- select id, email from auth.users order by created_at desc;

do $$
declare
  org_a uuid;
  org_b uuid;

  loc_a_1 uuid;
  loc_a_2 uuid;
  loc_b_1 uuid;

  term_a_1 uuid;
  term_a_2 uuid;
  term_b_1 uuid;

  staff_a_1 uuid;
  staff_a_2 uuid;
  staff_b_1 uuid;

  has_terminal_name boolean;
  has_terminal_code boolean;
  has_terminal_name_field boolean;
  has_staff_full_name boolean;
  has_staff_name boolean;
  has_staff_role boolean;
  has_staff_first_name boolean;
  has_staff_last_name boolean;

  user_owner_a uuid := '11111111-1111-1111-1111-111111111111'::uuid;
  user_manager_a_loc1 uuid := '22222222-2222-2222-2222-222222222222'::uuid;
  user_cashier_b_loc1 uuid := '33333333-3333-3333-3333-333333333333'::uuid;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'name'
  ) into has_terminal_name;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'code'
  ) into has_terminal_code;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'terminal_name'
  ) into has_terminal_name_field;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff'
      and column_name = 'full_name'
  ) into has_staff_full_name;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff'
      and column_name = 'name'
  ) into has_staff_name;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff'
      and column_name = 'role'
  ) into has_staff_role;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff'
      and column_name = 'first_name'
  ) into has_staff_first_name;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff'
      and column_name = 'last_name'
  ) into has_staff_last_name;

  -- Organizations (idempotent)
  select id into org_a
  from public.organizations
  where organization_number = '123456'
  limit 1;

  if org_a is null then
    insert into public.organizations (name, organization_number)
    values ('Org A', '123456')
    returning id into org_a;
  end if;

  select id into org_b
  from public.organizations
  where organization_number = '654321'
  limit 1;

  if org_b is null then
    insert into public.organizations (name, organization_number)
    values ('Org B', '654321')
    returning id into org_b;
  end if;

  -- Locations (idempotent by org + name)
  select id into loc_a_1
  from public.locations
  where organization_id = org_a and name = 'Org A - Downtown'
  limit 1;

  if loc_a_1 is null then
    insert into public.locations (organization_id, name, address)
    values (org_a, 'Org A - Downtown', '100 Main St')
    returning id into loc_a_1;
  end if;

  select id into loc_a_2
  from public.locations
  where organization_id = org_a and name = 'Org A - Uptown'
  limit 1;

  if loc_a_2 is null then
    insert into public.locations (organization_id, name, address)
    values (org_a, 'Org A - Uptown', '200 State Ave')
    returning id into loc_a_2;
  end if;

  select id into loc_b_1
  from public.locations
  where organization_id = org_b and name = 'Org B - Central'
  limit 1;

  if loc_b_1 is null then
    insert into public.locations (organization_id, name, address)
    values (org_b, 'Org B - Central', '300 Market Rd')
    returning id into loc_b_1;
  end if;

  -- Terminals (idempotent by org + terminal_number)
  select id into term_a_1
  from public.terminals
  where organization_id = org_a and terminal_number = '0001'
  limit 1;

  if term_a_1 is null then
    if has_terminal_name_field and has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, terminal_name, name, code, terminal_number)
      values (org_a, loc_a_1, 'A-Downtown-Register-1', 'A-Downtown-Register-1', 'A-DT-1', '0001')
      returning id into term_a_1;
    elsif has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, name, code, terminal_number)
      values (org_a, loc_a_1, 'A-Downtown-Register-1', 'A-DT-1', '0001')
      returning id into term_a_1;
    elsif has_terminal_name_field then
      insert into public.terminals (organization_id, location_id, terminal_name, terminal_number)
      values (org_a, loc_a_1, 'A-Downtown-Register-1', '0001')
      returning id into term_a_1;
    else
      insert into public.terminals (organization_id, location_id, terminal_number)
      values (org_a, loc_a_1, '0001')
      returning id into term_a_1;
    end if;
  end if;

  select id into term_a_2
  from public.terminals
  where organization_id = org_a and terminal_number = '0002'
  limit 1;

  if term_a_2 is null then
    if has_terminal_name_field and has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, terminal_name, name, code, terminal_number)
      values (org_a, loc_a_2, 'A-Uptown-Register-1', 'A-Uptown-Register-1', 'A-UP-1', '0002')
      returning id into term_a_2;
    elsif has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, name, code, terminal_number)
      values (org_a, loc_a_2, 'A-Uptown-Register-1', 'A-UP-1', '0002')
      returning id into term_a_2;
    elsif has_terminal_name_field then
      insert into public.terminals (organization_id, location_id, terminal_name, terminal_number)
      values (org_a, loc_a_2, 'A-Uptown-Register-1', '0002')
      returning id into term_a_2;
    else
      insert into public.terminals (organization_id, location_id, terminal_number)
      values (org_a, loc_a_2, '0002')
      returning id into term_a_2;
    end if;
  end if;

  select id into term_b_1
  from public.terminals
  where organization_id = org_b and terminal_number = '0001'
  limit 1;

  if term_b_1 is null then
    if has_terminal_name_field and has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, terminal_name, name, code, terminal_number)
      values (org_b, loc_b_1, 'B-Central-Register-1', 'B-Central-Register-1', 'B-CT-1', '0001')
      returning id into term_b_1;
    elsif has_terminal_name and has_terminal_code then
      insert into public.terminals (organization_id, location_id, name, code, terminal_number)
      values (org_b, loc_b_1, 'B-Central-Register-1', 'B-CT-1', '0001')
      returning id into term_b_1;
    elsif has_terminal_name_field then
      insert into public.terminals (organization_id, location_id, terminal_name, terminal_number)
      values (org_b, loc_b_1, 'B-Central-Register-1', '0001')
      returning id into term_b_1;
    else
      insert into public.terminals (organization_id, location_id, terminal_number)
      values (org_b, loc_b_1, '0001')
      returning id into term_b_1;
    end if;
  end if;

  -- Staff (idempotent by email)
  select id into staff_a_1
  from public.staff
  where email = 'cashier1@orga.test'
  limit 1;

  if staff_a_1 is null then
    if has_staff_first_name and has_staff_last_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, first_name, last_name, role)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A', 'Cashier 1', 'cashier')
      returning id into staff_a_1;
    elsif has_staff_first_name and has_staff_last_name then
      insert into public.staff (organization_id, location_id, email, first_name, last_name)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A', 'Cashier 1')
      returning id into staff_a_1;
    elsif has_staff_full_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, full_name, role)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A Cashier 1', 'cashier')
      returning id into staff_a_1;
    elsif has_staff_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, name, role)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A Cashier 1', 'cashier')
      returning id into staff_a_1;
    elsif has_staff_full_name then
      insert into public.staff (organization_id, location_id, email, full_name)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A Cashier 1')
      returning id into staff_a_1;
    elsif has_staff_name then
      insert into public.staff (organization_id, location_id, email, name)
      values (org_a, loc_a_1, 'cashier1@orga.test', 'Org A Cashier 1')
      returning id into staff_a_1;
    else
      insert into public.staff (organization_id, location_id, email)
      values (org_a, loc_a_1, 'cashier1@orga.test')
      returning id into staff_a_1;
    end if;
  end if;

  select id into staff_a_2
  from public.staff
  where email = 'manager1@orga.test'
  limit 1;

  if staff_a_2 is null then
    if has_staff_first_name and has_staff_last_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, first_name, last_name, role)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A', 'Manager 1', 'manager')
      returning id into staff_a_2;
    elsif has_staff_first_name and has_staff_last_name then
      insert into public.staff (organization_id, location_id, email, first_name, last_name)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A', 'Manager 1')
      returning id into staff_a_2;
    elsif has_staff_full_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, full_name, role)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A Manager 1', 'manager')
      returning id into staff_a_2;
    elsif has_staff_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, name, role)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A Manager 1', 'manager')
      returning id into staff_a_2;
    elsif has_staff_full_name then
      insert into public.staff (organization_id, location_id, email, full_name)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A Manager 1')
      returning id into staff_a_2;
    elsif has_staff_name then
      insert into public.staff (organization_id, location_id, email, name)
      values (org_a, loc_a_2, 'manager1@orga.test', 'Org A Manager 1')
      returning id into staff_a_2;
    else
      insert into public.staff (organization_id, location_id, email)
      values (org_a, loc_a_2, 'manager1@orga.test')
      returning id into staff_a_2;
    end if;
  end if;

  select id into staff_b_1
  from public.staff
  where email = 'cashier1@orgb.test'
  limit 1;

  if staff_b_1 is null then
    if has_staff_first_name and has_staff_last_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, first_name, last_name, role)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B', 'Cashier 1', 'cashier')
      returning id into staff_b_1;
    elsif has_staff_first_name and has_staff_last_name then
      insert into public.staff (organization_id, location_id, email, first_name, last_name)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B', 'Cashier 1')
      returning id into staff_b_1;
    elsif has_staff_full_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, full_name, role)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B Cashier 1', 'cashier')
      returning id into staff_b_1;
    elsif has_staff_name and has_staff_role then
      insert into public.staff (organization_id, location_id, email, name, role)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B Cashier 1', 'cashier')
      returning id into staff_b_1;
    elsif has_staff_full_name then
      insert into public.staff (organization_id, location_id, email, full_name)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B Cashier 1')
      returning id into staff_b_1;
    elsif has_staff_name then
      insert into public.staff (organization_id, location_id, email, name)
      values (org_b, loc_b_1, 'cashier1@orgb.test', 'Org B Cashier 1')
      returning id into staff_b_1;
    else
      insert into public.staff (organization_id, location_id, email)
      values (org_b, loc_b_1, 'cashier1@orgb.test')
      returning id into staff_b_1;
    end if;
  end if;

  -- Memberships (idempotent by user + org + location)
  if not exists (
    select 1 from public.user_memberships
    where user_id = user_owner_a
      and organization_id = org_a
      and location_id is null
  ) then
    insert into public.user_memberships (user_id, organization_id, location_id, role)
    values (user_owner_a, org_a, null, 'owner');
  end if;

  if not exists (
    select 1 from public.user_memberships
    where user_id = user_manager_a_loc1
      and organization_id = org_a
      and location_id = loc_a_1
  ) then
    insert into public.user_memberships (user_id, organization_id, location_id, role)
    values (user_manager_a_loc1, org_a, loc_a_1, 'manager');
  end if;

  if not exists (
    select 1 from public.user_memberships
    where user_id = user_cashier_b_loc1
      and organization_id = org_b
      and location_id = loc_b_1
  ) then
    insert into public.user_memberships (user_id, organization_id, location_id, role)
    values (user_cashier_b_loc1, org_b, loc_b_1, 'cashier');
  end if;

  -- Transactions for testing scoped reads (idempotent by message)
  if not exists (
    select 1 from public.transactions where message = 'Seed cash txn Org A Loc 1'
  ) then
    insert into public.transactions (organization_id, location_id, organization_number, terminal_number, payment_type, amount, success, message)
    values (org_a, loc_a_1, '123456', '0001', 'cash', 12.50, true, 'Seed cash txn Org A Loc 1');
  end if;

  if not exists (
    select 1 from public.transactions where message = 'Seed card txn Org A Loc 2'
  ) then
    insert into public.transactions (organization_id, location_id, organization_number, terminal_number, payment_type, amount, success, message)
    values (org_a, loc_a_2, '123456', '0002', 'card', 25.00, true, 'Seed card txn Org A Loc 2');
  end if;

  if not exists (
    select 1 from public.transactions where message = 'Seed cash txn Org B Loc 1'
  ) then
    insert into public.transactions (organization_id, location_id, organization_number, terminal_number, payment_type, amount, success, message)
    values (org_b, loc_b_1, '654321', '0001', 'cash', 8.25, true, 'Seed cash txn Org B Loc 1');
  end if;

  raise notice 'Seed complete. Org A: %, Org B: %', org_a, org_b;
  raise notice 'Locations -> A1: %, A2: %, B1: %', loc_a_1, loc_a_2, loc_b_1;
  raise notice 'Terminals -> A1: %, A2: %, B1: %', term_a_1, term_a_2, term_b_1;
  raise notice 'Staff -> A1: %, A2: %, B1: %', staff_a_1, staff_a_2, staff_b_1;
end $$;

-- Optional: clean up seeded demo rows (manual run when needed)
-- delete from public.transactions where message like 'Seed %';
-- delete from public.user_memberships where user_id in (
--   '11111111-1111-1111-1111-111111111111'::uuid,
--   '22222222-2222-2222-2222-222222222222'::uuid,
--   '33333333-3333-3333-3333-333333333333'::uuid
-- );
-- delete from public.staff where email like '%@orga.test' or email like '%@orgb.test';
-- delete from public.terminals where code in ('A-DT-1', 'A-UP-1', 'B-CT-1');
-- delete from public.locations where name in ('Org A - Downtown', 'Org A - Uptown', 'Org B - Central');
-- delete from public.organizations where name in ('Org A', 'Org B');
