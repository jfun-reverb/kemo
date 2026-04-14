-- Wipe all influencer accounts from PRODUCTION (keep admins).
-- Run in Supabase SQL Editor against PROD (twofagomeizrtkwlhsuv).
-- PREREQ: take a pg_dump backup before executing.
--
-- Scope:
--   - Deletes every auth.users row whose id is NOT in public.admins.auth_id
--   - Cascades: applications, receipts, influencers, auth.identities
--   - Storage files (receipt images, etc.) are NOT touched here; clean via
--     Storage dashboard or a separate script if desired.

BEGIN;

-- 0) Safety preview — uncomment to dry-run first
-- SELECT count(*) AS to_delete
-- FROM auth.users u
-- WHERE u.id NOT IN (SELECT auth_id FROM public.admins WHERE auth_id IS NOT NULL);

WITH victims AS (
  SELECT u.id
  FROM auth.users u
  WHERE u.id NOT IN (
    SELECT auth_id FROM public.admins WHERE auth_id IS NOT NULL
  )
)
, d_apps AS (
  DELETE FROM public.applications
  WHERE user_id IN (SELECT id FROM victims)
  RETURNING 1
)
, d_receipts AS (
  DELETE FROM public.receipts
  WHERE user_id IN (SELECT id FROM victims)
  RETURNING 1
)
, d_inf AS (
  DELETE FROM public.influencers
  WHERE id IN (SELECT id FROM victims)
  RETURNING 1
)
, d_ident AS (
  DELETE FROM auth.identities
  WHERE user_id IN (SELECT id FROM victims)
  RETURNING 1
)
, d_users AS (
  DELETE FROM auth.users
  WHERE id IN (SELECT id FROM victims)
  RETURNING 1
)
SELECT
  (SELECT count(*) FROM d_apps)     AS applications_deleted,
  (SELECT count(*) FROM d_receipts) AS receipts_deleted,
  (SELECT count(*) FROM d_inf)      AS influencers_deleted,
  (SELECT count(*) FROM d_ident)    AS identities_deleted,
  (SELECT count(*) FROM d_users)    AS auth_users_deleted;

-- Verify admins untouched:
-- SELECT count(*) FROM public.admins;
-- SELECT count(*) FROM auth.users;  -- should equal admin count

COMMIT;
