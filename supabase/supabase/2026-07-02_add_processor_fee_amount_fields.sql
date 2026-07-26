-- Persist processor-returned surcharge/fee amounts without local fee calculation.
-- These fields default to 0 so existing flows continue when no fee is returned.

alter table if exists public.transaction_headers
  add column if not exists fee_amount numeric(12,2) not null default 0;

alter table if exists public.transaction_details
  add column if not exists fee_amount numeric(12,2) not null default 0;

alter table if exists public.card_batch_details
  add column if not exists fee_amount numeric(12,2) not null default 0;
