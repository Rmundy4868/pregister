# Register Transaction Lifecycle Tonight

Scope: Register app only (no VRegister changes).

## Decision Locked

Use existing fee columns (`fee_amount`) on header/detail/batch rows.

Why this is the right choice tonight:
- Existing write/read paths already use `fee_amount`.
- Integrity checks already verify header/detail/batch fee fields.
- Batch close tables already support fee fields.
- Adding a new payment type/subtype now would require schema + trigger + report + legacy table changes and increases regression risk.

Revisit later only if you need fee as a fully separate accounting line item.

## Tonight Success Criteria

1. Sale posting persists fee correctly.
2. Sale receipt shows fee when present.
3. Open batch and batch close data retain fee values.
4. Void/refund do not create phantom fee amounts.
5. Batch close report rows preserve fee values for reconciliation.

## Tracker

Mark each item Pass/Fail as you test.

- [x] 0. Transaction tables reset to empty
- [x] 1. Sale approved path verified
- [x] 2. Sale receipt fee visibility verified
- [ ] 3. Open batch contents verified
- [ ] 4. Void flow verified
- [ ] 5. Closed refund flow verified
- [ ] 6. Misc refund flow verified
- [ ] 7. Batch close accepted path verified
- [ ] 8. Batch-close ledger/detail fee values verified
- [ ] 9. End-of-night reconciliation spot checks verified

## Step 0: Reset Transaction Tables (Clean Start)

Use one of these existing scripts in this repo:
- `supabase/2026-05-16_reset_transaction_tables.sql` (recommended)
- `supabase/2026-04-27_clear_transaction_data.sql`

Run in Supabase SQL Editor as a privileged role.

Recommended reset SQL:
```sql
begin;

truncate table
  public.card_batch_details,
  public.card_batch_headers,
  public.transaction_details,
  public.transaction_headers,
  public.transactions,
  public.screen_receipts
restart identity cascade;

do $$
begin
  if to_regclass('public.transaction_header_seq_counters') is not null then
    execute 'truncate table public.transaction_header_seq_counters restart identity';
  end if;
end;
$$;

commit;
```

Verification SQL (all should return 0):
```sql
select 'card_batch_details' as table_name, count(*)::bigint as row_count from public.card_batch_details
union all
select 'card_batch_headers', count(*)::bigint from public.card_batch_headers
union all
select 'transaction_details', count(*)::bigint from public.transaction_details
union all
select 'transaction_headers', count(*)::bigint from public.transaction_headers
union all
select 'transactions', count(*)::bigint from public.transactions
union all
select 'screen_receipts', count(*)::bigint from public.screen_receipts
order by table_name;
```

Pass rule:
- Every reset table reports `0` rows before Step 1 begins.

## Step 1: Sale Approved Posting

Test action:
- Run one card sale where processor returns a fee.

Expected app behavior:
- Approval summary shows Amount and Fee.
- Receipt ID is generated.

Expected DB behavior:
- `transaction_headers.fee_amount = processor fee`.
- Sale detail row (`payment_type='d'`, `subtype='s'`) has same `fee_amount`.

SQL check:
```sql
select id, created_at, total, fee_amount, batch_number, terminal_number
from transaction_headers
order by created_at desc
limit 5;

select id, transaction_header_id, payment_type, subtype, amount, fee_amount, status, reference_id
from transaction_details
where payment_type = 'd'
order by created_at desc
limit 10;
```

Pass rule:
- Header fee and sale detail fee match processor fee.

## Step 2: Sale Receipt Fee Visibility

Test action:
- Print/preview sale receipt after Step 1.

Expected:
- Amount line appears.
- Fee line appears when fee > 0.

Notes:
- Terminal-only receipt fee line is now included in receipt rendering.

Pass rule:
- Receipt clearly shows fee when fee exists.

## Step 3: Open Batch Verification

Test action:
- Open Batch view after at least one approved sale.

Expected:
- Sale row present with correct reference/auth/card info.
- No duplicate phantom rows.

SQL check:
```sql
select id, transaction_header_id, payment_type, subtype, amount, fee_amount, status, batch_status, reference_id
from transaction_details
where payment_type = 'd' and batch_status = 'o'
order by created_at desc
limit 50;
```

Pass rule:
- Open rows match what UI shows.

## Step 4: Void Flow (Unsettled)

Test action:
- Void an approved open-batch sale.

Expected DB behavior:
- New void row inserted with `subtype='v'`, negative amount.
- Original sale status becomes `voided`.
- Void row stays batch-open until batch close.

SQL check:
```sql
select id, original_detail_id, subtype, amount, fee_amount, status, batch_status, created_at
from transaction_details
where payment_type = 'd' and subtype in ('s','v')
order by created_at desc
limit 20;
```

Pass rule:
- Void row exists and original row status updated.

## Step 5: Closed Refund Flow

Test action:
- Refund from closed transaction list.

Expected DB behavior:
- Refund row inserted with `subtype='r'`, negative amount.
- `original_detail_id` points to original sale detail.
- Refund row has `fee_amount = 0` unless explicitly designed otherwise.

SQL check:
```sql
select id, transaction_header_id, original_detail_id, subtype, amount, fee_amount, status, reference_id, created_at
from transaction_details
where payment_type = 'd' and subtype = 'r'
order by created_at desc
limit 20;
```

Pass rule:
- Refund row links correctly and amount is correct.

## Step 6: Misc Refund Flow

Test action:
- Run a misc refund (not tied to prior sale lookup).

Expected:
- New header created.
- Refund detail inserted.
- Return receipt generated.

Pass rule:
- Header/detail persist and receipt produced without integrity errors.

## Step 7: Batch Close Accepted Path

Test action:
- Close batch with approved rows present.

Expected:
- Processor close accepted.
- Open batch rows marked closed.
- Batch close report saved and printable.

Pass rule:
- No rows remain open for the closed set.

## Step 8: Batch-Close Ledger Fee Verification

Critical tonight:
- Batch close transaction payload now carries per-row `feeAmount` for Register path.

SQL check:
```sql
select id, batch_number, closed_at, accepted, total_amount, final_total, integrity_status
from card_batch_headers
order by closed_at desc
limit 5;

select card_batch_header_id, transaction_detail_id, amount, fee_amount, status, reference_id, created_at
from card_batch_details
order by created_at desc
limit 50;
```

Pass rule:
- `card_batch_details.fee_amount` is populated for fee-bearing sale rows.

## Step 9: End-of-Night Reconciliation

For the latest batch:
- Sum of sale row `amount` should align with expected base amounts.
- Sum of sale row `fee_amount` should align with processor fee totals.
- Voids/refunds should reconcile as negative amount rows.

Suggested quick SQL:
```sql
with latest_batch as (
  select id
  from card_batch_headers
  order by closed_at desc
  limit 1
)
select
  d.status,
  count(*) as row_count,
  round(sum(d.amount)::numeric, 2) as amount_sum,
  round(sum(coalesce(d.fee_amount, 0))::numeric, 2) as fee_sum
from card_batch_details d
join latest_batch b on b.id = d.card_batch_header_id
group by d.status
order by d.status;
```

Pass rule:
- Totals are explainable from sale/void/refund activity and processor close report.

## If Anything Fails

1. Capture transaction reference id, auth code, and batch number.
2. Save raw processor response text where available.
3. Record whether failure is UI-only, ledger-only, or processor-only.
4. Re-run only the failed step after fix (do not restart full flow blindly).

## Resume Tomorrow

Current stop point:

- Step 0 passed.
- Step 1 passed: surcharge now persists to `transaction_headers.fee_amount` and `transaction_details.fee_amount`.
- Step 2 passed: terminal-only receipt now shows `Amount`, `Surcharge`, and `Total` (`Amount + Surcharge`).
- Register user-facing terminology for this flow is now `Surcharge` instead of `Fee`.

Next step to run first:

- Step 3: Open Batch Verification.

Start tomorrow with this exact check:

```sql
select id, transaction_header_id, payment_type, subtype, amount, fee_amount, status, batch_status, reference_id
from transaction_details
where payment_type = 'd' and batch_status = 'o'
order by created_at desc
limit 50;
```

Expected tomorrow at resume:

- Open batch UI row matches DB row.
- Sale row still carries the captured surcharge.
- No duplicate or phantom detail rows.
