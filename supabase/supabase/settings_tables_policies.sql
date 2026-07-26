grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on table public.organizations to authenticated;
grant select, insert, update, delete on table public.locations to authenticated;
grant select, insert, update, delete on table public.terminals to authenticated;
grant select, insert, update, delete on table public.staff to authenticated;

alter table public.organizations enable row level security;
alter table public.locations enable row level security;
alter table public.terminals enable row level security;
alter table public.staff enable row level security;

drop policy if exists "Organizations scoped by membership" on public.organizations;
create policy "Organizations scoped by membership"
  on public.organizations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = organizations.id
    )
  );

drop policy if exists "Organizations mutate by org admins" on public.organizations;
create policy "Organizations mutate by org admins"
  on public.organizations
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = organizations.id
        and m.location_id is null
        and m.role in ('owner', 'admin')
    )
  )
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = organizations.id
        and m.location_id is null
        and m.role in ('owner', 'admin')
    )
  );

drop policy if exists "Allow anon all on locations" on public.locations;
drop policy if exists "Locations scoped by membership" on public.locations;
create policy "Locations scoped by membership"
  on public.locations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = locations.organization_id
        and (m.location_id is null or m.location_id = locations.id)
    )
  );

drop policy if exists "Locations insert by org admins" on public.locations;
create policy "Locations insert by org admins"
  on public.locations
  for insert
  to authenticated
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = locations.organization_id
        and m.location_id is null
        and m.role in ('owner', 'admin')
    )
  );

drop policy if exists "Locations update by scoped managers" on public.locations;
create policy "Locations update by scoped managers"
  on public.locations
  for update
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = locations.organization_id
        and (
          (m.location_id is null and m.role in ('owner', 'admin'))
          or (m.location_id = locations.id and m.role in ('owner', 'admin', 'manager'))
        )
    )
  )
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = locations.organization_id
        and (
          (m.location_id is null and m.role in ('owner', 'admin'))
          or (m.location_id = locations.id and m.role in ('owner', 'admin', 'manager'))
        )
    )
  );

drop policy if exists "Locations delete by scoped managers" on public.locations;
create policy "Locations delete by scoped managers"
  on public.locations
  for delete
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = locations.organization_id
        and (
          (m.location_id is null and m.role in ('owner', 'admin'))
          or (m.location_id = locations.id and m.role in ('owner', 'admin', 'manager'))
        )
    )
  );

drop policy if exists "Allow anon all on terminals" on public.terminals;
drop policy if exists "Terminals scoped by membership" on public.terminals;
create policy "Terminals scoped by membership"
  on public.terminals
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = terminals.organization_id
        and (m.location_id is null or m.location_id = terminals.location_id)
    )
  );

drop policy if exists "Terminals mutate by scoped managers" on public.terminals;
create policy "Terminals mutate by scoped managers"
  on public.terminals
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = terminals.organization_id
        and (m.location_id is null or m.location_id = terminals.location_id)
        and m.role in ('owner', 'admin', 'manager')
    )
  )
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = terminals.organization_id
        and (m.location_id is null or m.location_id = terminals.location_id)
        and m.role in ('owner', 'admin', 'manager')
    )
  );

drop policy if exists "Allow anon all on staff" on public.staff;
drop policy if exists "Staff scoped by membership" on public.staff;
create policy "Staff scoped by membership"
  on public.staff
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = staff.organization_id
        and (m.location_id is null or m.location_id = staff.location_id)
    )
  );

drop policy if exists "Staff mutate by scoped managers" on public.staff;
create policy "Staff mutate by scoped managers"
  on public.staff
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = staff.organization_id
        and (m.location_id is null or m.location_id = staff.location_id)
        and m.role in ('owner', 'admin', 'manager')
    )
  )
  with check (
    exists (
      select 1
      from public.user_memberships m
      where m.user_id = auth.uid()
        and m.organization_id = staff.organization_id
        and (m.location_id is null or m.location_id = staff.location_id)
        and m.role in ('owner', 'admin', 'manager')
    )
  );
