-- ============================================================
-- patch   : 2026-04-22_delete_brand_application_test_data_prod
-- purpose : 운영 DB의 테스트 광고주 신청 2건 삭제
-- env     : 운영서버 ONLY (twofagomeizrtkwlhsuv.supabase.co, Sydney ap-southeast-2)
--           ※ 개발서버(qysmxtipobomefudyixw)에는 실행 금지
-- targets :
--   - wnsgud1124@daum.net
--   - semia670@gamil.com  (오타 포함 원본 이메일 그대로)
-- author  : jfun@jfun.co.kr
-- date    : 2026-04-22
--
-- 주의:
--   Migration 057 적용으로 brand_applications.business_license_path 컬럼 및
--   brand-docs Storage 버킷이 제거됨. 따라서 Storage 고아 파일 정리 불필요.
--
-- FK 관계 확인:
--   - brand_applications.reviewed_by → auth.users(id) ON DELETE SET NULL
--     (역방향 FK 없음 — 다른 테이블이 brand_applications를 참조하지 않음)
--   - brand_app_daily_counter 는 독립 채번 카운터, FK 관계 없음
--   → CASCADE 삭제 대상 없음. brand_applications 단독 DELETE 가능.
-- ============================================================


-- ============================================================
-- STEP 1 — 삭제 대상 사전 확인
--
-- 실행 후 결과를 육안으로 확인:
--   - 삭제할 이메일 2건만 조회되는지 확인
-- ============================================================
SELECT
  id,
  application_no,
  form_type,
  brand_name,
  contact_name,
  email,
  status,
  created_at
FROM public.brand_applications
WHERE email IN (
  'wnsgud1124@daum.net',
  'semia670@gamil.com'
)
ORDER BY created_at;


-- ============================================================
-- STEP 2 — DB 행 삭제 (STEP 1 육안 확인 완료 후 실행)
-- ============================================================
BEGIN;

-- 삭제 실행
DELETE FROM public.brand_applications
WHERE email IN (
  'wnsgud1124@daum.net',
  'semia670@gamil.com'
);

-- 삭제 후 검증: 0이어야 정상
SELECT count(*) AS remaining_rows
FROM public.brand_applications
WHERE email IN (
  'wnsgud1124@daum.net',
  'semia670@gamil.com'
);
-- 기대값: remaining_rows = 0

COMMIT;

-- ============================================================
-- ROLLBACK (실수로 잘못 삭제한 경우)
-- SQL Editor는 자동 커밋이므로 COMMIT 이후에는 되돌릴 수 없음.
-- 필요 시 Supabase Dashboard → Database → Backups 에서 Point-in-Time Recovery 사용.
-- ============================================================
