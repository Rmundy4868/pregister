-- Adds location-level tip-adjust enablement flag.
-- Safe to run multiple times.

alter table public.locations
  add column if not exists allow_tip_adjustments boolean not null default false;

comment on column public.locations.allow_tip_adjustments is
  'Enables/disables tip adjustment workflow for this location.';
