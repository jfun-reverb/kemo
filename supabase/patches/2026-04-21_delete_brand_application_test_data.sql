-- Delete brand_applications test rows submitted by younggeun.kim@jfun.co.kr
-- Run in Supabase SQL Editor against PROD (twofagomeizrtkwlhsuv) ONLY.
-- Target email: younggeun.kim@jfun.co.kr
--
-- NOTE: storage.objects has protect_delete() trigger blocking direct DELETE.
--       Storage files must be removed via Storage API / Dashboard, not SQL.
--
-- Two-step procedure:
--   STEP 1: Run the SELECT below to list business_license_path values,
--           then delete those files manually in Dashboard → Storage → brand-docs.
--   STEP 2: Run the DELETE block to remove the DB rows.

-- ============================================================
-- STEP 1 — Preview rows + gather storage paths to delete manually
-- ============================================================
SELECT id,
       application_no,
       form_type,
       brand_name,
       contact_name,
       email,
       status,
       business_license_path,
       created_at
FROM public.brand_applications
WHERE email = 'younggeun.kim@jfun.co.kr'
ORDER BY created_at;

-- → Copy every non-null business_license_path from the result above.
-- → Open https://supabase.com/dashboard/project/twofagomeizrtkwlhsuv/storage/buckets/brand-docs
-- → Delete each file at that path (right-click → Delete).
-- → Once all Storage files are gone, run STEP 2 below.


-- ============================================================
-- STEP 2 — Delete DB rows (run after Storage cleanup is done)
-- ============================================================
BEGIN;

DELETE FROM public.brand_applications
WHERE email = 'younggeun.kim@jfun.co.kr';

-- Verify
SELECT count(*) AS remaining_rows
FROM public.brand_applications
WHERE email = 'younggeun.kim@jfun.co.kr';

COMMIT;
