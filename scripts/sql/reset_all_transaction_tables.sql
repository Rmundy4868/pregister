-- Reset all transaction and batch ledger tables to a clean state.
-- Safe for repeated runs; does not use COUNT() verification to avoid editor copy/paste mistakes.

BEGIN;

TRUNCATE TABLE
  card_batch_details,
  card_batch_headers,
  transaction_details,
  transaction_headers,
  transactions
RESTART IDENTITY CASCADE;

COMMIT;

-- Verification (no COUNT): every table should report has_rows = false.
SELECT 'transaction_headers' AS table_name, EXISTS (SELECT 1 FROM transaction_headers LIMIT 1) AS has_rows
UNION ALL
SELECT 'transaction_details' AS table_name, EXISTS (SELECT 1 FROM transaction_details LIMIT 1) AS has_rows
UNION ALL
SELECT 'card_batch_headers' AS table_name, EXISTS (SELECT 1 FROM card_batch_headers LIMIT 1) AS has_rows
UNION ALL
SELECT 'card_batch_details' AS table_name, EXISTS (SELECT 1 FROM card_batch_details LIMIT 1) AS has_rows
UNION ALL
SELECT 'transactions' AS table_name, EXISTS (SELECT 1 FROM transactions LIMIT 1) AS has_rows;
