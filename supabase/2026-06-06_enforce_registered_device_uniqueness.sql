-- Enforce one physical device binding per terminal across all locations.
-- This does NOT block reactivating the same terminal at the same location.
-- It prevents a single registered_device_id from being bound to multiple terminals.

do $$
begin
  -- Skip safely if the column does not exist in this environment.
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'terminals'
      and column_name = 'registered_device_id'
  ) then
    raise notice 'public.terminals.registered_device_id not found; skipping uniqueness enforcement.';
    return;
  end if;

  -- Abort with a clear message if duplicates already exist.
  if exists (
    select 1
    from public.terminals t
    where nullif(btrim(coalesce(t.registered_device_id, '')), '') is not null
    group by btrim(t.registered_device_id)
    having count(*) > 1
  ) then
    raise exception using
      message = 'Cannot enforce unique device binding: duplicate registered_device_id values exist in public.terminals.',
      hint = 'Run a duplicate cleanup query first, then re-run this migration.';
  end if;
end
$$;

create unique index if not exists idx_terminals_registered_device_id_unique
  on public.terminals (registered_device_id)
  where nullif(btrim(coalesce(registered_device_id, '')), '') is not null;
