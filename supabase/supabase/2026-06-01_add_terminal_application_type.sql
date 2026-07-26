-- Adds application_type to terminals for startup/application routing.
-- Safe to run multiple times.

begin;

alter table public.terminals
  add column if not exists application_type text;

update public.terminals
set application_type = 'register'
where coalesce(trim(application_type), '') = '';

alter table public.terminals
  alter column application_type set default 'register';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'terminals_application_type_chk'
      and conrelid = 'public.terminals'::regclass
  ) then
    alter table public.terminals
      add constraint terminals_application_type_chk
      check (
        lower(coalesce(trim(application_type), 'register')) in
        ('register', 'kiosk', 'mobile', 'backoffice')
      );
  end if;
end;
$$;

create index if not exists idx_terminals_application_type
  on public.terminals (application_type);

commit;
