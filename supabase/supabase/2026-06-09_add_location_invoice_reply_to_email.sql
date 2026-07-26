-- Prepare dual location-level email directives:
-- 1) receipt_reply_to_email
-- 2) invoice_reply_to_email

begin;

alter table if exists public.locations
  add column if not exists invoice_reply_to_email text;

-- Backfill invoice reply-to from existing receipt reply-to when blank.
-- If receipt alias starts with receipts+, convert to invoices+.
update public.locations
set invoice_reply_to_email =
  case
    when trim(coalesce(receipt_reply_to_email, '')) = '' then null
    when lower(split_part(trim(receipt_reply_to_email), '@', 1)) like 'receipts+%'
      then regexp_replace(trim(receipt_reply_to_email), '^[Rr][Ee][Cc][Ee][Ii][Pp][Tt][Ss]\+', 'invoices+')
    when lower(split_part(trim(receipt_reply_to_email), '@', 1)) like 'mail+%'
      then regexp_replace(trim(receipt_reply_to_email), '^[Mm][Aa][Ii][Ll]\+', 'invoices+')
    else trim(receipt_reply_to_email)
  end
where trim(coalesce(invoice_reply_to_email, '')) = '';

create index if not exists idx_locations_invoice_reply_to_email
  on public.locations (invoice_reply_to_email);

commit;
