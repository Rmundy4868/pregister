-- Master Console bootstrap seed
-- Run this in Supabase SQL Editor after partner console foundation migration.
-- If you see gen_salt/crypt missing errors, run:
-- supabase/2026-06-04_pgcrypto_resolution_hotfix.sql

select public.upsert_master_console_user(
  'masteradmin',
  'ChangeMeNow!',
  'Master Admin',
  true
);

-- Immediate validation for UI login flow.
select *
from public.console_login('masteradmin', 'ChangeMeNow!');
