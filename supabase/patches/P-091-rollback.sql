-- ============================================================
-- P-091-rollback.sql
-- admin_create_brand_application RPC 롤백
--
-- 용도: 패치 (one-off) — 091 적용 후 문제 발생 시 복구
-- 실행 환경: 운영서버 또는 개발서버 SQL Editor
--
-- 영향 범위:
--   - admin_create_brand_application 함수 DROP 만 수행
--   - brands / brand_applications 데이터 영향 없음
--   - 해당 RPC로 이미 생성된 brand_applications 행은 그대로 유지됨
--     (롤백 후에도 관리자 페인에서 정상 조회 가능)
--
-- 전제:
--   - 082/085/088/090 마이그레이션은 이 롤백 대상이 아님
--   - 091 이후 마이그레이션이 없어야 함
--     (있을 경우 해당 마이그레이션을 먼저 롤백)
--
-- 실행 후 검증:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name = 'admin_create_brand_application';
--   → 결과 없어야 함 (0행)
--
-- 작성일: 2026-05-04
-- ============================================================


-- STEP 1. RPC 제거
--   파라미터 시그니처를 정확히 지정하여 오버로딩된 함수만 제거
-- 시그니처 v1 (10 파라미터, 091 최초 버전)
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
);
-- 시그니처 v2 (12 파라미터, name_ja + business_no 추가)
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, jsonb, text, boolean
);
-- 시그니처 v3 (13 파라미터, company_name 추가)
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text,    -- p_form_type
  uuid,    -- p_brand_id
  text,    -- p_company_name
  text,    -- p_brand_name
  text,    -- p_brand_name_ja
  text,    -- p_business_no
  text,    -- p_contact_name
  text,    -- p_phone
  text,    -- p_email
  text,    -- p_billing_email
  jsonb,   -- p_products
  text,    -- p_request_note
  boolean  -- p_brand_sync
);


-- STEP 2. PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 (DROP 직후 실행)
-- ============================================================

-- [V1] 함수가 제거됐는지 확인
SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'admin_create_brand_application';
-- 0행 반환되어야 함

-- [V2] 기존 manual_admin 신청 건 보존 확인
SELECT count(*) AS manual_admin_apps
FROM public.brand_applications
WHERE source = 'manual_admin';
-- 0 이상 반환 (데이터 영향 없음)


-- ============================================================
-- 재적용 방법 (롤백 취소)
--   supabase/migrations/091_admin_create_brand_application.sql 을
--   SQL Editor에 전체 붙여 넣어 실행
-- ============================================================
