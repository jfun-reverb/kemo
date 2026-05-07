-- ============================================================
-- 098_seeding_transfer_fee_default.sql
-- form_type='seeding' 신청에 products[].transfer_fee_krw 기본값 0 자동 채움
--
-- 배경:
--   092 마이그레이션에서 fill_reviewer_transfer_fee() 트리거가 form_type='reviewer'일 때
--   products 각 원소에 transfer_fee_krw 기본값 2500을 채우도록 구현되었음.
--   그러나 form_type='seeding'은 분기에서 빠져 있어서 transfer_fee_krw 키가 없는
--   채로 INSERT되어 관리자 화면에서 "이체수수료(건)" 컬럼이 "—"로 표시됨.
--   운영팀 요청: 시딩 신청도 0원으로 자동 등록되어야 함.
--
-- 해결:
--   CREATE OR REPLACE FUNCTION으로 fill_reviewer_transfer_fee() 함수 본문만 갱신.
--   함수명·트리거명은 092에서 정의된 그대로 유지 (rename 불필요).
--   - reviewer → 기본값 2500 (변경 없음)
--   - seeding  → 기본값 0 (신규 추가)
--   - 그 외 폼 타입 → 손대지 않음
--   명시적으로 입력된 값(예: reviewer에 5000, seeding에 1000)은 보존됨.
--
--   기존 시딩 신청 행 중 transfer_fee_krw 키가 없거나 null인 원소를 0으로 채우는
--   backfill UPDATE도 함께 실행. reviewer 행은 절대 건드리지 않음.
--
-- 영향 분석:
--   ※ 주의: brand_applications에는 BEFORE UPDATE 트리거 trg_brand_app_touch(052)가
--     있어서 UPDATE 시 version 컬럼이 자동으로 +1 증가하고 updated_at도 갱신됨.
--     backfill UPDATE로 인해 시딩 대상 행의 version이 전부 +1 증가하므로,
--     관리자가 동시에 해당 행을 편집 중이라면 낙관적 락(version 불일치) 충돌이
--     발생할 수 있음.
--     → 운영 시간대(업무 시간 중)는 피하고 트래픽이 낮은 시간대에 실행 권장.
--     → 실행 전 관리자에게 "잠깐 편집 중지" 공유 후 진행 권장.
--
-- 작성일: 2026-05-07
-- ============================================================


-- ============================================================
-- 1. 함수 본문 갱신 (092에서 정의된 함수명 유지)
--    트리거 trg_fill_reviewer_transfer_fee는 이미 092에서 생성되어 있으므로
--    DROP TRIGGER / CREATE TRIGGER 없이 함수 본문만 갈아끼움.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fill_reviewer_transfer_fee()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_products jsonb;
  v_default_fee integer;
BEGIN
  -- reviewer + seeding 폼 타입이고 products 배열 1개 이상일 때만 동작
  IF NEW.form_type IN ('reviewer', 'seeding')
     AND NEW.products IS NOT NULL
     AND jsonb_typeof(NEW.products) = 'array'
     AND jsonb_array_length(NEW.products) > 0 THEN

    -- 폼 타입별 기본값 결정
    --   reviewer: ₩2,500 (리뷰어 1명당 이체수수료)
    --   seeding:  ₩0 (이체수수료 없음)
    IF NEW.form_type = 'reviewer' THEN
      v_default_fee := 2500;
    ELSE
      v_default_fee := 0;
    END IF;

    -- 각 원소에 transfer_fee_krw 키가 이미 있으면 보존, 없거나 null이면 기본값 채움
    SELECT jsonb_agg(
      CASE
        WHEN elem ? 'transfer_fee_krw'
          AND elem->'transfer_fee_krw' <> 'null'::jsonb
          AND (elem->>'transfer_fee_krw') IS NOT NULL
          AND (elem->>'transfer_fee_krw') <> ''
          THEN elem
        ELSE elem || jsonb_build_object('transfer_fee_krw', v_default_fee)
      END
    ) INTO v_products
    FROM jsonb_array_elements(NEW.products) AS elem;

    NEW.products := COALESCE(v_products, NEW.products);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fill_reviewer_transfer_fee IS
  '[098] reviewer→₩2,500 / seeding→₩0 자동 채움 (092에서 확장). 명시 입력값은 보존. 그 외 폼 타입은 미처리.';


-- ============================================================
-- 2. 트리거는 092에서 이미 BEFORE INSERT로 정의됨 — 손대지 않음
--    (DROP TRIGGER / CREATE TRIGGER 없음)
-- ============================================================


-- ============================================================
-- 3. 기존 시딩 신청 backfill UPDATE
--
--    form_type='seeding' 행 중 products 배열에 transfer_fee_krw 키가
--    없거나 null인 원소가 있는 행만 0으로 채움.
--    reviewer 행은 절대 건드리지 않음.
--    멱등성 보장: 재실행해도 이미 채워진 행은 WHERE 조건에서 제외됨.
--
--    ※ trg_brand_app_touch(052) BEFORE UPDATE 트리거로 인해
--      이 UPDATE로 version 컬럼이 +1 증가하고 updated_at이 갱신됨.
-- ============================================================
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(
    CASE
      WHEN elem ? 'transfer_fee_krw'
        AND elem->'transfer_fee_krw' <> 'null'::jsonb
        AND (elem->>'transfer_fee_krw') IS NOT NULL
        AND (elem->>'transfer_fee_krw') <> ''
        THEN elem
      ELSE elem || jsonb_build_object('transfer_fee_krw', 0)
    END
  )
  FROM jsonb_array_elements(products) AS elem
)
WHERE form_type = 'seeding'
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(products) e
    WHERE
      NOT (e ? 'transfer_fee_krw')
      OR e->'transfer_fee_krw' = 'null'::jsonb
      OR (e->>'transfer_fee_krw') IS NULL
      OR (e->>'transfer_fee_krw') = ''
  );


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 실행)
-- ============================================================
/*

-- [V0] 사전 영향 행 수 카운트 — backfill 실행 전에 실행하여 대상 건수 파악
SELECT COUNT(*) AS backfill_target_count
FROM public.brand_applications
WHERE form_type = 'seeding'
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(products) e
    WHERE
      NOT (e ? 'transfer_fee_krw')
      OR e->'transfer_fee_krw' = 'null'::jsonb
      OR (e->>'transfer_fee_krw') IS NULL
      OR (e->>'transfer_fee_krw') = ''
  );
-- 이 숫자만큼 행이 backfill UPDATE됨.
-- 0이면 이미 모두 채워진 상태(재실행 시)이거나 시딩 신청 자체가 없는 것.


-- [V1] 함수 본문 갱신 확인 — prosrc에 'seeding' 분기가 포함되어야 함
SELECT proname, prosecdef, prosrc
FROM pg_proc
WHERE proname = 'fill_reviewer_transfer_fee';
-- prosecdef = true, prosrc에 'seeding' 및 'v_default_fee' 문자열 포함 여부 확인


-- [V2] reviewer 신청 INSERT → 2500 자동 채움 확인 (반드시 ROLLBACK)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'reviewer',
  p_brand_name    := 'V2 검증 리뷰어',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v2-reviewer-check@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10},{"name":"P2","price":2000,"qty":5}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V2 검증'
);
SELECT products
FROM public.brand_applications
WHERE email = 'v2-reviewer-check@example.com';
-- 두 원소 모두 "transfer_fee_krw":2500 포함되어야 함
ROLLBACK;


-- [V3] seeding 신청 INSERT → 0 자동 채움 확인 (반드시 ROLLBACK)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'seeding',
  p_brand_name    := 'V3 검증 시딩',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v3-seeding-check@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V3 검증'
);
SELECT products
FROM public.brand_applications
WHERE email = 'v3-seeding-check@example.com';
-- "transfer_fee_krw":0 포함되어야 함
ROLLBACK;


-- [V4] reviewer + seeding 각각 명시 입력값(3000) 보존 확인 (반드시 ROLLBACK)
BEGIN;
SELECT * FROM public.submit_brand_application(
  p_form_type     := 'reviewer',
  p_brand_name    := 'V4 검증 명시입력',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v4-explicit-reviewer@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10,"transfer_fee_krw":3000}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V4 reviewer 명시'
);
SELECT products
FROM public.brand_applications
WHERE email = 'v4-explicit-reviewer@example.com';
-- transfer_fee_krw = 3000 보존되어야 함 (2500으로 덮어써지면 안 됨)

SELECT * FROM public.submit_brand_application(
  p_form_type     := 'seeding',
  p_brand_name    := 'V4 검증 명시입력',
  p_contact_name  := '담당',
  p_phone         := '010-0000-0000',
  p_email         := 'v4-explicit-seeding@example.com',
  p_products      := '[{"name":"P1","price":1000,"qty":10,"transfer_fee_krw":3000}]'::jsonb,
  p_billing_email := NULL,
  p_business_license_path := NULL,
  p_request_note  := 'V4 seeding 명시'
);
SELECT products
FROM public.brand_applications
WHERE email = 'v4-explicit-seeding@example.com';
-- transfer_fee_krw = 3000 보존되어야 함 (0으로 덮어써지면 안 됨)
ROLLBACK;


-- [V5] backfill 사후 검증 — 시딩 행 중 transfer_fee_krw NULL/누락 잔존 0건 확인
SELECT COUNT(*) AS remaining_null_count
FROM public.brand_applications,
     jsonb_array_elements(products) AS e
WHERE form_type = 'seeding'
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND (
    NOT (e ? 'transfer_fee_krw')
    OR e->'transfer_fee_krw' = 'null'::jsonb
    OR (e->>'transfer_fee_krw') IS NULL
    OR (e->>'transfer_fee_krw') = ''
  );
-- 0 이어야 함. 0이 아니면 backfill UPDATE가 실패한 행 존재 — 재실행 필요.

*/


-- ============================================================
-- 롤백 SQL (필요 시 SQL Editor에서 실행)
-- ============================================================
/*

  -- [롤백] 함수 본문을 092 내용으로 되돌리기
  --   트리거 trg_fill_reviewer_transfer_fee는 그대로 유지됨 (함수만 교체).

  CREATE OR REPLACE FUNCTION public.fill_reviewer_transfer_fee()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
  AS $func$
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
  $func$;

  COMMENT ON FUNCTION public.fill_reviewer_transfer_fee IS
    '[092] form_type=reviewer 신청 INSERT 시 products[].transfer_fee_krw 기본값 ₩2,500 자동 채움. 명시 입력값은 보존.';

  -- ※ backfill UPDATE(시딩 행에 채워진 transfer_fee_krw=0)는 audit 컬럼 없이
  --   직접 데이터를 수정한 것이므로 SQL 롤백으로 되돌릴 수 없음.
  --   098 적용 전 pg_dump 백업이 있다면 해당 백업에서 brand_applications만 복원.
  --   영향 범위: form_type='seeding' 행 중 transfer_fee_krw가 0으로 채워진 products 원소.
  --   (해당 행 version도 +1 증가된 상태이므로 수동 확인 후 처리 필요)

*/
