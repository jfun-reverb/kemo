-- ============================================================
-- 092_default_transfer_fee_reviewer.sql
-- form_type='reviewer' 신청에 products[].transfer_fee_krw 기본값 자동 채움
--
-- 배경:
--   sales/reviewer.html 광고주 신청 폼은 "리뷰어 1명당 ₩2,500" 이체수수료를
--   화면에서 명시적으로 안내하지만, INSERT되는 products jsonb에는 키가
--   누락되어 신청 목록에서 "이체수수료(건)" 컬럼이 '-'로 표시됨.
--
-- 해결:
--   BEFORE INSERT 트리거로 form_type='reviewer'일 때 products 각 원소에
--   transfer_fee_krw 키가 없거나 null이면 2500 채움.
--
--   트리거가 RPC와 독립적으로 동작하므로 sales 폼(submit_brand_application)
--   과 관리자 등록(admin_create_brand_application) 양쪽에 자동 적용.
--   기존 데이터(이미 INSERT된 신청)는 영향 없음 — 관리자가 인라인 편집으로 입력.
--
-- 영향 분석:
--   - trg_brand_app_recalc(052)는 price/qty 키만 읽어 estimated_krw 계산.
--     transfer_fee_krw 키 추가는 estimated 자동 계산 결과에 영향 없음.
--   - 관리자가 모달에서 transfer_fee_krw를 명시 입력하면 그 값 보존됨
--     (CASE WHEN elem ? 'transfer_fee_krw' THEN 분기).
--   - seeding은 영향 없음 (form_type 분기).
--
-- 작성일: 2026-05-06
-- ============================================================


CREATE OR REPLACE FUNCTION public.fill_reviewer_transfer_fee()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_products jsonb;
BEGIN
  -- reviewer 폼 + products 배열 1개 이상일 때만 동작
  IF NEW.form_type = 'reviewer'
     AND NEW.products IS NOT NULL
     AND jsonb_typeof(NEW.products) = 'array'
     AND jsonb_array_length(NEW.products) > 0 THEN

    -- 각 원소에 transfer_fee_krw 키가 이미 있으면 보존, 없거나 null이면 2500
    SELECT jsonb_agg(
      CASE
        WHEN elem ? 'transfer_fee_krw'
          AND elem->'transfer_fee_krw' <> 'null'::jsonb
          AND (elem->>'transfer_fee_krw') IS NOT NULL
          AND (elem->>'transfer_fee_krw') <> ''
          THEN elem
        ELSE elem || jsonb_build_object('transfer_fee_krw', 2500)
      END
    ) INTO v_products
    FROM jsonb_array_elements(NEW.products) AS elem;

    NEW.products := COALESCE(v_products, NEW.products);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fill_reviewer_transfer_fee IS
  '[092] form_type=reviewer 신청 INSERT 시 products[].transfer_fee_krw 기본값 ₩2,500 자동 채움. 명시 입력값은 보존.';


DROP TRIGGER IF EXISTS trg_fill_reviewer_transfer_fee ON public.brand_applications;
CREATE TRIGGER trg_fill_reviewer_transfer_fee
  BEFORE INSERT ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.fill_reviewer_transfer_fee();


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 실행)
-- ============================================================
/*
-- [V1] 함수 + 트리거 등록 확인
SELECT proname, prosecdef FROM pg_proc WHERE proname = 'fill_reviewer_transfer_fee';
-- 1행, prosecdef = true

SELECT tgname, tgrelid::regclass FROM pg_trigger
WHERE tgname = 'trg_fill_reviewer_transfer_fee';
-- 1행, brand_applications

-- [V2] reviewer 신청 INSERT — products에 transfer_fee_krw 자동 채움 확인 (ROLLBACK 필수)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'reviewer',
  p_brand_name    := 'V2 검증',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v2-check@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10},{"name":"P2","price":2000,"qty":5}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V2'
);
SELECT products FROM public.brand_applications WHERE email = 'v2-check@example.com';
-- 두 원소 모두 "transfer_fee_krw":2500 포함되어야 함
ROLLBACK;

-- [V3] seeding 신청 — transfer_fee_krw 채워지지 않아야 함 (ROLLBACK 필수)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'seeding',
  p_brand_name    := 'V3 검증',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v3-check@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V3'
);
SELECT products FROM public.brand_applications WHERE email = 'v3-check@example.com';
-- transfer_fee_krw 키 없어야 함
ROLLBACK;

-- [V4] 명시 입력 보존 확인 (ROLLBACK 필수)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'reviewer',
  p_brand_name    := 'V4 검증',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v4-check@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10,"transfer_fee_krw":3000}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V4'
);
SELECT products FROM public.brand_applications WHERE email = 'v4-check@example.com';
-- transfer_fee_krw=3000 보존되어야 함
ROLLBACK;
*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*
DROP TRIGGER IF EXISTS trg_fill_reviewer_transfer_fee ON public.brand_applications;
DROP FUNCTION IF EXISTS public.fill_reviewer_transfer_fee();
*/
