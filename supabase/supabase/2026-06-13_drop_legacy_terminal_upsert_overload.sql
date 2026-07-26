-- Remove legacy overload that conflicts with the auto-close aware terminal upsert RPC.
-- Safe to run multiple times.

begin;

drop function if exists public.upsert_terminal_from_app(
  text,
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  boolean,
  text
);

commit;
