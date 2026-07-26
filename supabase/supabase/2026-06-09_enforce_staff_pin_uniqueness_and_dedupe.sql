-- Deduplicate staff PINs inside each org/location scope, then enforce uniqueness.
-- Keeps the highest-priority row per (organization_id, location_id, pin):
-- active first, then newest updated_at/created_at.
with ranked as (
  select
    s.id,
    row_number() over (
      partition by s.organization_id, s.location_id, s.pin
      order by
        coalesce(s.is_active, false) desc,
        s.updated_at desc nulls last,
        s.created_at desc nulls last,
        s.id desc
    ) as rn
  from public.staff s
  where s.pin is not null
    and btrim(s.pin) <> ''
),
removed as (
  delete from public.staff s
  using ranked r
  where s.id = r.id
    and r.rn > 1
  returning s.id, s.organization_id, s.location_id, s.pin
)
select count(*) as removed_duplicates
from removed;

-- Targeted visibility for your reported duplicate pin 4262 after cleanup.
select
  organization_id,
  location_id,
  pin,
  count(*) as pin_count
from public.staff
where pin = '4262'
group by organization_id, location_id, pin
order by organization_id, location_id;

create unique index if not exists idx_staff_org_location_pin_unique
on public.staff (organization_id, location_id, pin)
where pin is not null and btrim(pin) <> '';
