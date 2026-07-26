-- Returns location names for a batch of location IDs.
-- SECURITY DEFINER so terminal sessions (anon key) can resolve names
-- without needing direct RLS access to the locations table.
-- Safe to run multiple times.

drop function if exists public.get_location_names_by_ids(uuid[]);

create or replace function public.get_location_names_by_ids(p_location_ids uuid[])
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
  select
    l.id,
    coalesce(
      nullif(trim(l.name), ''),
      l.id::text
    ) as name
  from public.locations l
  where l.id = any(p_location_ids);
$$;
