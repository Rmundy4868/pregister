-- Adds explicit staff authorization model for production scaling.
-- Safe to run multiple times.

begin;

alter table public.staff
  add column if not exists security_level smallint,
  add column if not exists security_designation text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'staff_security_level_chk'
  ) then
    alter table public.staff
      add constraint staff_security_level_chk
      check (security_level is null or security_level between 1 and 10);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'staff_security_designation_chk'
  ) then
    alter table public.staff
      add constraint staff_security_designation_chk
      check (
        security_designation is null
        or security_designation in (
          'operator',
          'supervisor',
          'manager_level_1',
          'manager_level_2',
          'general_manager'
        )
      );
  end if;
end
$$;

create index if not exists idx_staff_security_level
  on public.staff (security_level)
  where security_level is not null;

-- Backfill security_level from legacy role values where possible.
update public.staff
set security_level = case lower(coalesce(role, ''))
  when 'cashier' then 1
  when 'staff' then 2
  when 'manager' then 6
  when 'admin' then 8
  when 'owner' then 10
  else security_level
end
where security_level is null;

-- Backfill designation from security_level if not present.
update public.staff
set security_designation = case
  when security_level between 1 and 2 then 'operator'
  when security_level between 3 and 4 then 'supervisor'
  when security_level between 5 and 6 then 'manager_level_1'
  when security_level between 7 and 8 then 'manager_level_2'
  when security_level between 9 and 10 then 'general_manager'
  else security_designation
end
where coalesce(trim(security_designation), '') = '';

commit;
