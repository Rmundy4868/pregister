# Activation-First Admin Rebuild Plan

This plan starts from a clean activation baseline and adds the minimum production admin foundation first.

## 0) Pre-check

- Confirm full backup exists before any reset.
- Confirm all operator sessions are disconnected.

## 1) Optional hard reset (fresh rebuild)

- Run: `supabase/2026-06-03_fresh_rebuild_full_reset.sql`
- This is destructive and guarded by a required confirmation flag.

## 2) Core baseline (if reset was used)

- Run your baseline schema/migrations in chronological order.
- Ensure these remain present:
  - `activate_install_license(...)`
  - `upsert_terminal_from_app(...)`

## 3) Activation cleanup stack

Run these in order:

1. `supabase/2026-06-01_add_terminal_application_type.sql`
2. `supabase/2026-06-01_rebuild_activate_license_rpc_without_legacy_gateway.sql`
3. `supabase/2026-06-01_remove_legacy_location_processor_fields.sql`
4. `supabase/2026-06-01_post_cleanup_validation.sql`

## 4) Admin foundation

Run these in order:

1. `supabase/2026-06-03_partner_console_foundation.sql`
2. `supabase/2026-06-03_add_staff_security_model.sql`

## 5) Device-first bootstrap hardening

- Run: `supabase/2026-06-04_device_first_bootstrap.sql`
- This keeps existing terminal device registration and adds a dedicated
  bootstrap lookup path by device identity.

## 6) Seed initial admin identities

Example SQL:

```sql
select public.upsert_master_console_user('masteradmin', 'ChangeMeNow!', 'Master Admin');

select public.upsert_distribution_partner(
  p_partner_id => '100001',
  p_company_name => 'Demo Partner LLC',
  p_contact_first_name => 'Alex',
  p_contact_last_name => 'Smith',
  p_email => 'alex@demopartner.test',
  p_username => 'partner100001',
  p_password => 'ChangeMeNow!'
);
```

## 7) Validate

- Validate partner/master login RPC:
  - `select * from public.console_login('masteradmin', 'ChangeMeNow!');`
  - `select * from public.console_login('partner100001', 'ChangeMeNow!');`
- Validate device bootstrap RPC:
  - `select * from public.bootstrap_terminal_by_device('your-device-id', 'Front Register', 'windows', '11', null, null);`
- Validate staff security fields:
  - `select security_level, security_designation, count(*) from public.staff group by 1,2 order by 1,2;`
- Run full phase-1 validator:
  - `supabase/2026-06-03_phase1_foundation_validation.sql`

## 8) Next implementation slices

1. Build Master Console web app screens: Partners list, create/edit partner, map orgs to partner.
2. Build Partner Portal screens: login, org list, location list, editable fields.
3. Add row-level policies for partner data visibility.
4. Add audit tables for partner/admin mutations.
