-- ════════════════════════════════════════════════════════════════════
-- migration 117: brand_applications.payment_flags → products[i].payment_flags
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-13-brand-app-product-payment-flags.md
--
-- 변경 내용:
--   기존: brand_applications.payment_flags jsonb (신청 전체 1세트 4플래그)
--   변경: products 배열 각 항목 안에 payment_flags 삽입 (제품별 4플래그)
--
--   제품별 플래그 구조:
--     { "recruit": bool, "product": bool, "transfer": bool, "free": bool }
--   free=true 면 클라이언트가 해당 제품에서 3종(recruit/product/transfer) 숨김.
--
-- 적용 순서 (트랜잭션):
--   1. 백필: products[i]에 신청 단위 payment_flags 그대로 복사
--   2. CREATE calc_brand_app_product_payment_flag (신규 제품 단위 헬퍼)
--   3. CREATE OR REPLACE auto_recalc_brand_app_payment_flags (트리거 함수 교체)
--   4. CREATE refresh_brand_app_product_payment_flags (신규 RPC)
--   5. DROP COLUMN payment_flags
--   6. DROP FUNCTION calc_brand_app_payment_flags (구 신청 단위 헬퍼)
--   7. DROP FUNCTION recalc_brand_app_payment_flags (구 신청 단위 RPC)
--
-- ROLLBACK:
--   pg_dump 백업에서 brand_applications 복원 후 migration 114/115/116 재적용.
--   클라이언트 코드는 PR revert.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. 백필: 기존 payment_flags 값을 모든 제품에 복사 ──
-- 운영자가 수동 토글해둔 플래그(free 포함)를 제품별로 그대로 보존.
-- 제품이 2개 이상인 신청은 모든 제품이 동일한 플래그로 시작 (이후 개별 조정 가능).
-- NOTE: 이 UPDATE 는 구 트리거(auto_recalc_brand_app_payment_flags)를 발동시키나
--       해당 트리거는 NEW.payment_flags(컬럼)만 변경하므로 NEW.products 는 그대로.
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(
    item || jsonb_build_object(
      'payment_flags',
      COALESCE(
        payment_flags,
        '{"recruit":false,"product":false,"transfer":false,"free":false}'::jsonb
      )
    )
    ORDER BY ord
  )
  FROM jsonb_array_elements(products) WITH ORDINALITY AS t(item, ord)
)
WHERE products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0;


-- ── 2. 신규 헬퍼: 제품 1개 플래그 계산 ──
-- item: products 배열의 단일 원소 (qty, price, recruit_fee_krw, transfer_fee_krw)
-- recruit  = qty * recruit_fee_krw > 0
-- product  = qty * price > 0
-- transfer = qty * transfer_fee_krw > 0
-- free     = 항상 false (호출처에서 보존 여부 결정)
CREATE OR REPLACE FUNCTION public.calc_brand_app_product_payment_flag(p_item jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_qty      numeric;
  v_recruit  numeric;
  v_product  numeric;
  v_transfer numeric;
BEGIN
  v_qty      := COALESCE(NULLIF(p_item->>'qty',              '')::numeric, 0);
  v_recruit  := COALESCE(NULLIF(p_item->>'recruit_fee_krw',  '')::numeric, 0);
  v_product  := COALESCE(NULLIF(p_item->>'price',            '')::numeric, 0);
  v_transfer := COALESCE(NULLIF(p_item->>'transfer_fee_krw', '')::numeric, 0);

  RETURN jsonb_build_object(
    'recruit',  (v_qty * v_recruit)  > 0,
    'product',  (v_qty * v_product)  > 0,
    'transfer', (v_qty * v_transfer) > 0,
    'free',     false
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('recruit', false, 'product', false, 'transfer', false, 'free', false);
END;
$$;

COMMENT ON FUNCTION public.calc_brand_app_product_payment_flag(jsonb) IS
  '제품 1개(products 배열 원소)의 fees 합계 기반 payment_flags 산출. '
  'recruit/product/transfer 는 qty × fee 양수 여부. free 는 항상 false.';


-- ── 3. 트리거 함수 교체: 제품별 payment_flags 자동 계산 ──
-- BEFORE INSERT OR UPDATE OF products 에서 발동.
-- INSERT: 모든 제품 free=false 로 초기화.
-- UPDATE: NEW.products[i].payment_flags.free 값 보존 (클라이언트 토글값 우선).
--         recruit/product/transfer 는 fees 기반 재계산.
CREATE OR REPLACE FUNCTION public.auto_recalc_brand_app_payment_flags()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.products IS NULL OR jsonb_typeof(NEW.products) <> 'array' THEN
    RETURN NEW;
  END IF;

  -- UPDATE: products 가 변경되지 않은 경우 건너뜀
  IF TG_OP = 'UPDATE' AND NEW.products IS NOT DISTINCT FROM OLD.products THEN
    RETURN NEW;
  END IF;

  SELECT jsonb_agg(
    elem.value || jsonb_build_object(
      'payment_flags',
      public.calc_brand_app_product_payment_flag(elem.value)
        || jsonb_build_object(
             'free',
             CASE
               WHEN TG_OP = 'INSERT' THEN false
               ELSE COALESCE((elem.value -> 'payment_flags' ->> 'free')::boolean, false)
             END
           )
    )
    ORDER BY elem.ordinality
  )
  INTO NEW.products
  FROM jsonb_array_elements(NEW.products) WITH ORDINALITY AS elem(value, ordinality);

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.auto_recalc_brand_app_payment_flags() IS
  'products 변경 시 제품별 payment_flags 자동 재계산 트리거 함수. '
  'recruit/product/transfer 는 합계 기반 자동. free 는 INSERT=false, UPDATE=NEW 값 보존.';

-- 트리거는 migration 116 에서 이미 생성됨 (BEFORE INSERT OR UPDATE OF products).
-- 함수만 교체 — 트리거 자체는 그대로.


-- ── 4. 신규 RPC: 신청 전체 새로고침 (관리자 새로고침 버튼용) ──
-- 4종(recruit/product/transfer/free) 완전 초기화 (free=false).
-- 반환: 갱신된 products 배열 jsonb.
CREATE OR REPLACE FUNCTION public.refresh_brand_app_product_payment_flags(p_application_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app      public.brand_applications%ROWTYPE;
  v_products jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app FROM public.brand_applications WHERE id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  IF v_app.products IS NULL OR jsonb_typeof(v_app.products) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;

  -- 모든 제품 4종 완전 초기화 (free=false 포함 — 새로고침=원래대로 의도)
  SELECT jsonb_agg(
    elem.value || jsonb_build_object(
      'payment_flags',
      public.calc_brand_app_product_payment_flag(elem.value)
    )
    ORDER BY elem.ordinality
  )
  INTO v_products
  FROM jsonb_array_elements(v_app.products) WITH ORDINALITY AS elem(value, ordinality);

  v_products := COALESCE(v_products, '[]'::jsonb);

  -- products UPDATE → 트리거 발동 → 재계산 (free=false 이미 반영됨)
  UPDATE public.brand_applications
  SET products = v_products
  WHERE id = p_application_id;

  RETURN v_products;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_brand_app_product_payment_flags(uuid) TO authenticated;

COMMENT ON FUNCTION public.refresh_brand_app_product_payment_flags(uuid) IS
  '신청 1건 모든 제품 payment_flags 완전 초기화. '
  '4종(recruit/product/transfer/free) 모두 products 합계 기반 재설정. '
  'is_admin() 가드. 갱신된 products 배열 반환.';


-- ── 5. payment_flags 컬럼 DROP ──
-- 트리거 함수가 이미 교체되어 NEW.payment_flags 참조 없음 — 안전하게 DROP 가능.
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS payment_flags;


-- ── 6. 구 헬퍼 함수 DROP ──
DROP FUNCTION IF EXISTS public.calc_brand_app_payment_flags(jsonb);


-- ── 7. 구 RPC DROP ──
DROP FUNCTION IF EXISTS public.recalc_brand_app_payment_flags(uuid);


COMMIT;
