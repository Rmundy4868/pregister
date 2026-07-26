# Supabase Cleanup Execution Order (2026-06-01)

Run these in Supabase SQL Editor in this exact order.

## 0) Optional fresh organization reset (destructive)

If you want a clean end-to-end startup, run this first:

- `select set_config('app.confirm_delete_organizations', 'YES_DELETE_ORGS', false);`
- `supabase/2026-06-05_delete_existing_organizations_for_fresh_start.sql`

This deletes existing organizations and dependent records (locations, terminals, staff, memberships, and transaction hierarchy).
It does not delete distribution partners or master console users.

## 1) Clear transaction tables

- supabase/2026-04-27_clear_transaction_data.sql

## 2) Finalize receipt id cleanup

- supabase/2026-05-16_finalize_receipt_id_cleanup.sql

## 3) Ensure terminal upsert supports SPIn + reader/printer

- supabase/2026-05-29_terminal_spin_upsert_rpc.sql

## 4) Add terminal application type

- supabase/2026-06-01_add_terminal_application_type.sql

## 5) Rebuild activation RPC without legacy gateway credential fields

- supabase/2026-06-01_rebuild_activate_license_rpc_without_legacy_gateway.sql

## 6) Remove legacy location processor fields

- supabase/2026-06-01_remove_legacy_location_processor_fields.sql

This step also resets activation state for a clean rollout:

- Sets public.terminals.is_active = false
- Clears terminal device bindings (registered_device_id/registered_device_label)
- Sets public.locations.terminals_active = 0

## 7) Optional quick validation queries

- Verify dropped columns are gone:

  select column_name
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'locations'
    and column_name in (
      'legacy_gateway_api_login_id',
      'legacy_gateway_transaction_key',
      'processor_provider',
      'processor_environment',
      'processor_mode',
      'payment_processor',
      'gateway_environment',
      'epn_api_login_id',
      'epn_login_id',
      'epn_user_id',
      'epn_userid',
      'epn_password',
      'epn_pass',
      'epn_restrict_key',
      'epn_restriction_key'
    );

- Verify activation RPC still exists:

  select routine_name
  from information_schema.routines
  where routine_schema = 'public'
    and routine_name = 'activate_install_license';

- Verify terminal application_type exists:

  select column_name
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'terminals'
    and column_name = 'application_type';

## 8) Partner-first org creation enforcement (master console)

- `supabase/2026-06-05_master_console_partner_first_org_enforcement.sql`

This adds auto-generated numeric `partner_id` creation and enforces selecting/creating a distribution partner before creating a new organization.

## Approved Scrub Exception

- Active source text scrub is clean for legacy gateway/Auth.Net residue.
- One binary runtime dependency is intentionally retained:
  - connector/sdk-runtime/AuthorizeNet.dll
- This is an approved exception for connector runtime compatibility and is not used as editable source code.
