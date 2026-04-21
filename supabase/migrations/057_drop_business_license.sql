-- ============================================================
-- Migration 057: 사업자등록증 기능 완전 제거
-- ============================================================
-- 목적: reviewer 폼의 사업자등록증 업로드 기능을 DB·Storage·RPC에서 제거.
--       UI 제거는 클라이언트 코드(sales/reviewer.html, admin.js, storage.js) 별도 작업.
--
-- 변경 내용:
--   1. submit_brand_application() RPC 재정의
--      - p_business_license_path 파라미터 유지 (하위 호환) + 컬럼에 쓰지 않음
--      - 기존 클라이언트가 파라미터를 넘겨도 안전하게 무시됨
--   2. brand_applications.business_license_path 컬럼 DROP
--   3. Storage brand-docs 버킷 정책(RLS) 제거
--      - brand-docs 버킷 안의 object 삭제 및 버킷 자체 삭제는 수동 작업 필요
--        → 이 SQL 실행 전에 Dashboard → Storage → brand-docs에서 파일 전체 삭제 후
--          버킷 삭제, 또는 아래 Step 0 쿼리로 DB object 레코드 삭제 + 버킷 삭제
--
-- 적용 순서:
--   개발서버(qysmxtipobomefudyixw) 먼저 → 검증 → 운영서버(twofagomeizrtkwlhsuv)
--
-- 주의: 컬럼 DROP 전에 RPC가 먼저 재정의되어야 함 (아래 순서 준수)
-- ============================================================


-- ============================================================
-- Step 0: Storage 파일 및 버킷 정리 (SQL로 처리 가능한 부분)
-- ============================================================
-- storage.objects 레코드 삭제 (brand-docs 버킷 내 모든 파일)
-- 주의: 이 쿼리는 DB 레코드만 삭제. 실제 S3 오브젝트는 Supabase 내부에서
--       storage.objects 삭제 시 자동으로 연동하여 제거된다.
--       (Supabase Storage가 DB-S3 연동 관리)
-- idempotent: brand-docs 버킷이 없어도 오류 없음
DELETE FROM storage.objects
WHERE bucket_id = 'brand-docs';

-- brand-docs 버킷 삭제
-- 주의: 버킷 안에 오브젝트가 남아 있으면 삭제 실패 (위 DELETE가 먼저 실행되어야 함)
DELETE FROM storage.buckets
WHERE id = 'brand-docs';


-- ============================================================
-- Step 1: Storage RLS 정책 제거 (brand-docs 버킷용 4개)
-- ============================================================
-- idempotent: IF EXISTS
DROP POLICY IF EXISTS "brand_docs_insert" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_select" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_update" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_delete" ON storage.objects;


-- ============================================================
-- Step 2: submit_brand_application() RPC 재정의
--   - p_business_license_path 파라미터는 유지 (DEFAULT NULL, 하위 호환)
--   - INSERT 컬럼 목록에서 business_license_path 제거
--   - 기존 함수 시그니처(text, text, text, text, text, jsonb, text, text)와
--     동일하므로 REVOKE/GRANT 불필요
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL   -- 유지(하위 호환), 값은 무시됨
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_no text;
BEGIN
  -- 입력 검증 (trigger 진입 전 빠른 피드백)
  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RAISE EXCEPTION '[submit_brand_application] invalid form_type: %', p_form_type
      USING ERRCODE = '22023';
  END IF;

  IF COALESCE(p_brand_name, '') = ''
     OR COALESCE(p_contact_name, '') = ''
     OR COALESCE(p_phone, '') = ''
     OR COALESCE(p_email, '') = '' THEN
    RAISE EXCEPTION '[submit_brand_application] missing required field'
      USING ERRCODE = '22023';
  END IF;

  IF p_products IS NULL
     OR jsonb_typeof(p_products) <> 'array'
     OR jsonb_array_length(p_products) < 1
     OR jsonb_array_length(p_products) > 50 THEN
    RAISE EXCEPTION '[submit_brand_application] invalid products array'
      USING ERRCODE = '22023';
  END IF;

  -- business_license_path 컬럼 제거됨 → INSERT 컬럼 목록에서 제외
  -- p_business_license_path 파라미터는 하위 호환을 위해 유지하되 값을 무시
  INSERT INTO public.brand_applications (
    application_no,
    form_type,
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    products
  ) VALUES (
    '',              -- 채번 트리거가 JFUN-{Q|N}-YYYYMMDD-NNN 생성
    p_form_type,
    p_brand_name,
    p_contact_name,
    p_phone,
    p_email,
    p_billing_email,
    p_products
  )
  RETURNING application_no INTO v_no;

  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[057] 광고주 신청 폼 제출 RPC. anon/authenticated INSERT+RETURNING 42501 우회. SECURITY DEFINER + postgres owner(BYPASSRLS). application_no 반환. business_license_path 파라미터는 하위 호환 유지용이며 무시됨 (컬럼 DROP됨).';

-- 기존 GRANT 재확인 (CREATE OR REPLACE이므로 GRANT는 자동 유지되지만 명시적 보장)
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text
) TO anon, authenticated;


-- ============================================================
-- Step 3: brand_applications.business_license_path 컬럼 DROP
--   - Step 2(RPC 재정의) 완료 후에 실행해야 함 (함수가 컬럼을 참조 중인 상태에서 DROP하면 오류)
--   - idempotent: IF EXISTS
-- ============================================================
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS business_license_path;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. 컬럼 제거 확인 (결과에 business_license_path가 없어야 함)
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name = 'brand_applications'
-- ORDER BY ordinal_position;

-- 2. Storage 정책 제거 확인 (0건이어야 함)
-- SELECT policyname FROM pg_policies
-- WHERE schemaname = 'storage'
--   AND tablename = 'objects'
--   AND policyname LIKE 'brand_docs_%';

-- 3. 버킷 삭제 확인 (0건이어야 함)
-- SELECT id FROM storage.buckets WHERE id = 'brand-docs';

-- 4. RPC 정상 동작 확인 (p_business_license_path 전달해도 오류 없이 무시)
-- SELECT public.submit_brand_application(
--   'seeding', '테스트브랜드', '홍길동', '090-0000-0000', 'test@example.com',
--   '[{"name":"상품A","price":1000,"qty":1}]'::jsonb,
--   NULL, NULL
-- );
-- -- 기대값: 'JFUN-N-YYYYMMDD-NNN' 형식 텍스트 반환

-- 5. INSERT에도 business_license_path 컬럼이 없어야 함 (컬럼 존재 시 SQLSTATE 42703)
-- INSERT INTO public.brand_applications (
--   application_no, form_type, brand_name, contact_name, phone, email, products
-- ) VALUES (
--   '', 'seeding', '검증브랜드', '김철수', '080-0000-0000', 'verify@example.com',
--   '[{"name":"검증상품","price":500,"qty":2}]'
-- ) RETURNING application_no, total_jpy, estimated_krw;
-- -- 실행 후 롤백: ROLLBACK;


-- ============================================================
-- 롤백 방법 (필요 시)
-- ============================================================
-- 1. 컬럼 복원
-- ALTER TABLE public.brand_applications
--   ADD COLUMN IF NOT EXISTS business_license_path text;

-- 2. RPC 이전 버전으로 복원 (056_submit_brand_application_rpc.sql 내용 재실행)

-- 3. Storage 버킷 및 정책 복원 (053_brand_docs_storage.sql 내용 재실행)
--    주의: 기존 파일은 복원 불가 (S3 오브젝트가 Step 0에서 영구 삭제됨)
