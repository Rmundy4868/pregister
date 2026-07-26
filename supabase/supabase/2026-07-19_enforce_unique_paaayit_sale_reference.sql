-- 2026-07-19
-- Enforce idempotent local posting for PaaayIT hosted card sales.
-- This protects against duplicate inserts across concurrent callback/webhook/temp-sync
-- paths and across horizontally scaled backend instances.

-- Fail fast if duplicate reference groups already exist so operators can review
-- and clean historical rows intentionally.
do $$
declare
  duplicate_group_count bigint;
begin
  select count(*)
    into duplicate_group_count
  from (
    select
      organization_id,
      location_id,
      reference_id,
      count(*) as row_count
    from public.transaction_details
    where payment_type = 'd'
      and subtype = 's'
      and gateway_provider = 'paaayit_online'
      and reference_id is not null
      and btrim(reference_id) <> ''
    group by organization_id, location_id, reference_id
    having count(*) > 1
  ) dup;

  if duplicate_group_count > 0 then
    raise exception using
      message = format(
        'Cannot create unique PaaayIT sale-reference index: found %s duplicate reference groups in transaction_details. Resolve duplicates first.',
        duplicate_group_count
      );
  end if;
end $$;

create unique index if not exists idx_txn_details_paaayit_sale_ref_unique
on public.transaction_details (organization_id, location_id, reference_id)
where payment_type = 'd'
  and subtype = 's'
  and gateway_provider = 'paaayit_online'
  and reference_id is not null
  and btrim(reference_id) <> '';
