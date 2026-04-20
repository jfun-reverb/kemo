-- ============================================================
-- Migration 056: submit_brand_application RPC
-- ============================================================
-- 목적: anon/authenticated가 brand_applications 에 INSERT 시
--       RLS WITH CHECK / RETURNING SELECT 제약으로 42501 에러 발생.
--       SECURITY DEFINER 함수로 감싸 postgres(BYPASSRLS) 권한으로 실행.
--
-- 원인:
--   - 클라이언트가 .insert(...).select('application_no') 로 Prefer: return=representation
--     을 보내면 PostgREST 가 INSERT 후 SELECT 로 row 반환 시도
--   - brand_applications.SELECT 정책은 is_admin() 전용 → anon 은 방금 만든 row 도 못 읽음
--   - INSERT 자체도 anon 컨텍스트에서 RLS WITH CHECK 평가 — 운영 DB 에서 거부됨
--
-- 해결:
--   - SECURITY DEFINER + postgres owner = BYPASSRLS 로 실행
--   - 함수가 application_no 만 반환 → SELECT 정책 영향 없음
--   - 기존 INSERT 정책은 유지 (관리자 직접 INSERT 경로 보존)
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL
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
      USING ERRCODE = '22023';  -- invalid_parameter_value
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

  INSERT INTO public.brand_applications (
    application_no,
    form_type,
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    products,
    business_license_path
  ) VALUES (
    '',              -- 채번 트리거가 JFUN-{Q|N}-YYYYMMDD-NNN 생성
    p_form_type,
    p_brand_name,
    p_contact_name,
    p_phone,
    p_email,
    p_billing_email,
    p_products,
    p_business_license_path
  )
  RETURNING application_no INTO v_no;

  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[056] 광고주 신청 폼 제출 RPC. anon/authenticated INSERT+RETURNING 42501 우회. SECURITY DEFINER + postgres owner(BYPASSRLS)로 실행. application_no 반환.';

-- anon·authenticated 가 RPC 호출 가능하도록 EXECUTE 권한 부여
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text
) TO anon, authenticated;

-- ============================================================
-- 사용 예시 (supabase-js v2):
-- ============================================================
-- const { data: applicationNo, error } = await sb.rpc('submit_brand_application', {
--   p_form_type: 'seeding',
--   p_brand_name: '테스트브랜드',
--   p_contact_name: '홍길동',
--   p_phone: '010-0000-0000',
--   p_email: 'test@example.com',
--   p_products: [{ name: '상품A', url: 'https://...', price: 1000, qty: 5 }]
-- });
-- // data = 'JFUN-N-20260420-001' (text)
-- ============================================================

-- ============================================================
-- 롤백 (필요 시):
-- DROP FUNCTION IF EXISTS public.submit_brand_application(
--   text, text, text, text, text, jsonb, text, text
-- );
-- ============================================================
