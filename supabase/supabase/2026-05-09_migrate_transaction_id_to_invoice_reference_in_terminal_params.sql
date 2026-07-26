-- =============================================================================
-- 2026-05-09  Migrate terminal parameter key: transaction_id -> invoice_reference
-- =============================================================================
-- Preserves existing required/optional/hidden settings when field key changed
-- in the app from transaction_id to invoice_reference.
-- =============================================================================

update public.terminal_transaction_parameters
set customer_field_modes =
  (customer_field_modes - 'transaction_id') ||
  jsonb_build_object(
    'invoice_reference',
    customer_field_modes -> 'transaction_id'
  )
where customer_field_modes ? 'transaction_id'
  and not (customer_field_modes ? 'invoice_reference');

update public.terminal_transaction_parameters
set customer_field_modes = customer_field_modes - 'transaction_id'
where customer_field_modes ? 'transaction_id'
  and customer_field_modes ? 'invoice_reference';
