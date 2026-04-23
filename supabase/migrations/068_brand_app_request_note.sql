-- ============================================================
-- Migration 068: brand_applications.request_note 컬럼 추가
-- ============================================================
-- 목적:
--   광고주(브랜드) 신청 폼 reviewer/seeding 양쪽에 "기타·요청사항"
--   자유 입력(textarea) 필드를 추가. 신청자가 직접 입력하는 값이며
--   `admin_memo`(관리자 내부 메모)와 분리 보관한다.
--
-- 영향 범위:
--   - brand_applications 테이블에 nullable text 컬럼 추가 (기본 NULL)
--   - submit_brand_application RPC 시그니처 확장 (p_request_note 추가)
--   - 기존 데이터·기존 정책(RLS) 영향 없음
-- ============================================================

ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS request_note text NULL;

COMMENT ON COLUMN public.brand_applications.request_note IS
  '[068] 신청자 자유 입력 요청사항 (기타/ご要望). sales 폼 textarea. admin_memo와 분리 (신청자 vs 관리자).';

-- ============================================================
-- submit_brand_application RPC 확장
-- ============================================================
-- 시그니처가 바뀌므로 기존 함수 DROP 후 재생성.
-- 기존 파라미터 순서는 유지하고, p_request_note를 맨 끝에 추가.
-- 056 버전 대비 변경점: + p_request_note text DEFAULT NULL

DROP FUNCTION IF EXISTS public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text
);

CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL,
  p_request_note          text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_no   text;
  v_note text;
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

  -- 요청사항 정규화: 공백 trim + 1000자 컷 + 빈 문자열은 NULL 치환
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;

  INSERT INTO public.brand_applications (
    application_no,
    form_type,
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    products,
    -- business_license_path: 057에서 컬럼 DROP됨 — INSERT 목록에서 제외
    --   p_business_license_path 파라미터는 하위 호환 유지용이며 무시됨
    request_note
  ) VALUES (
    '',              -- 채번 트리거가 JFUN-{Q|N}-YYYYMMDD-NNN 생성
    p_form_type,
    p_brand_name,
    p_contact_name,
    p_phone,
    p_email,
    p_billing_email,
    p_products,
    v_note
  )
  RETURNING application_no INTO v_no;

  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[068] 광고주 신청 폼 제출 RPC. SECURITY DEFINER로 anon INSERT+RETURNING 42501 우회. p_request_note(1000자 컷)는 신청자 자유 입력 요청사항.';

GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

-- ============================================================
-- 롤백 (필요 시):
-- DROP FUNCTION IF EXISTS public.submit_brand_application(
--   text, text, text, text, text, jsonb, text, text, text
-- );
-- -- 057 버전 복구: supabase/migrations/057_drop_business_license.sql Step 2 재실행
-- ALTER TABLE public.brand_applications DROP COLUMN IF EXISTS request_note;
-- ============================================================
