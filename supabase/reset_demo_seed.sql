-- Reset only demo seed data created by seed_multi_tenant_demo.sql
-- Safe to run multiple times.

-- Remove seed transactions first (dependent on organization/location scope)
delete from public.transactions
where message in (
  'Seed cash txn Org A Loc 1',
  'Seed card txn Org A Loc 2',
  'Seed cash txn Org B Loc 1'
);

-- Remove memberships for demo users
delete from public.user_memberships
where user_id in (
  '11111111-1111-1111-1111-111111111111'::uuid,
  '22222222-2222-2222-2222-222222222222'::uuid,
  '33333333-3333-3333-3333-333333333333'::uuid
);

-- Remove demo staff
delete from public.staff
where email in (
  'cashier1@orga.test',
  'manager1@orga.test',
  'cashier1@orgb.test'
);

-- Remove demo terminals
delete from public.terminals
where (organization_number = '123456' and terminal_number in ('0001', '0002'))
   or (organization_number = '654321' and terminal_number = '0001');

-- Remove demo locations
delete from public.locations
where name in ('Org A - Downtown', 'Org A - Uptown', 'Org B - Central');

-- Remove demo organizations
delete from public.organizations
where organization_number in ('123456', '654321')
   or name in ('Org A', 'Org B');
