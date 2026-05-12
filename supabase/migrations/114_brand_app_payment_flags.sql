-- ════════════════════════════════════════════════════════════════════
-- migration 114: brand_applications.payment_flags jsonb (입금여부 4종)
-- ────────────────────────────────────────────────────────────────────
-- 사양: 2026-05-12 사용자 요구
--   브랜드 서베이 신청 목록 페인의 신규 「입금여부」 컬럼에 표시할
--   4종 체크 상태 저장. 모두 관리자가 직접 토글 가능 + 새로고침
--   아이콘으로 products 합계 기반 자동 재설정.
--
-- jsonb 키:
--   recruit  — 모집비용 체크 (true 면 칩 표시)
--   product  — 상품비용 체크
--   transfer — 이체수수료 체크
--   free     — 무료모집 체크 (true 면 다른 3종 시각 숨김)
--
-- 변경:
--   1. brand_applications.payment_flags jsonb NOT NULL DEFAULT '{}' 추가
--   2. calc_brand_app_payment_flags(products jsonb) 헬퍼 — products
--      합계 기반 recruit/product/transfer boolean 산출 (free 는 항상 false)
--   3. recalc_brand_app_payment_flags(application_id) 원격 호출 함수 —
--      새로고침 버튼 핸들러. free 키는 기존 값 보존, 나머지만 재계산
--   4. 기존 행 백필: products 합계로 자동 채움
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.recalc_brand_app_payment_flags(uuid);
--   DROP FUNCTION IF EXISTS public.calc_brand_app_payment_flags(jsonb);
--   ALTER TABLE public.brand_applications DROP COLUMN IF EXISTS payment_flags;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. payment_flags 컬럼 ──
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS payment_flags jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.brand_applications.payment_flags IS
  '입금여부 4종 체크 상태. 키: recruit(모집비용)·product(상품비용)·transfer(이체수수료)·free(무료모집). '
  '관리자가 수동 토글하거나 새로고침 버튼으로 products 합계 기반 자동 설정. '
  'free=true 면 클라이언트가 다른 3종 시각 숨김 (DB 값은 보존).';


-- ── 2. 헬퍼: products jsonb → payment_flags 자동 산출 ──
-- products 배열 안의 각 항목: {qty, price, recruit_fee_krw, transfer_fee_krw, ...}
-- qty * (price | recruit_fee_krw | transfer_fee_krw) 합계가 양수면 해당 키 true.
-- free 는 자동 계산 대상 아님 — 항상 false 반환. 호출자가 따로 보존.
CREATE OR REPLACE FUNCTION public.calc_brand_app_payment_flags(p_products jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_recruit  numeric := 0;
  v_product  numeric := 0;
  v_transfer numeric := 0;
  v_item     jsonb;
  v_qty      numeric;
BEGIN
  IF p_products IS NULL OR jsonb_typeof(p_products) <> 'array' THEN
    RETURN jsonb_build_object('recruit', false, 'product', false, 'transfer', false, 'free', false);
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_products) LOOP
    v_qty      := COALESCE(NULLIF(v_item->>'qty', '')::numeric, 0);
    v_recruit  := v_recruit  + COALESCE(NULLIF(v_item->>'recruit_fee_krw',  '')::numeric, 0) * v_qty;
    v_product  := v_product  + COALESCE(NULLIF(v_item->>'price',            '')::numeric, 0) * v_qty;
    v_transfer := v_transfer + COALESCE(NULLIF(v_item->>'transfer_fee_krw', '')::numeric, 0) * v_qty;
  END LOOP;

  RETURN jsonb_build_object(
    'recruit',  v_recruit  > 0,
    'product',  v_product  > 0,
    'transfer', v_transfer > 0,
    'free',     false
  );
EXCEPTION
  WHEN OTHERS THEN
    -- products 안에 'abc' 같은 비-숫자 문자열이 섞여 캐스팅 실패하는 사고
    -- (운영 데이터 정합성 결함) 가 발생해도 백필 트랜잭션 전체가 깨지지 않도록
    -- 안전 폴백 — 모두 false 반환. 호출자가 새로고침 버튼으로 재시도 가능.
    RETURN jsonb_build_object('recruit', false, 'product', false, 'transfer', false, 'free', false);
END;
$$;

COMMENT ON FUNCTION public.calc_brand_app_payment_flags(jsonb) IS
  'products jsonb 배열 합계 기반 payment_flags 산출 (recruit/product/transfer). free 는 항상 false 반환.';


-- ── 3. 원격 호출 함수: 단일 신청 행 새로고침 (관리자 새로고침 버튼용) ──
-- 클라이언트가 .rpc("recalc_brand_app_payment_flags", {p_application_id}) 호출.
-- free 키는 기존 값 보존, recruit/product/transfer 만 products 합계로 재설정.
CREATE OR REPLACE FUNCTION public.recalc_brand_app_payment_flags(p_application_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app       public.brand_applications%ROWTYPE;
  v_new_flags jsonb;
  v_free      boolean;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app FROM public.brand_applications WHERE id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  v_new_flags := public.calc_brand_app_payment_flags(v_app.products);
  v_free      := COALESCE((v_app.payment_flags->>'free')::boolean, false);
  v_new_flags := v_new_flags || jsonb_build_object('free', v_free);

  UPDATE public.brand_applications
  SET payment_flags = v_new_flags
  WHERE id = p_application_id;

  RETURN v_new_flags;
END;
$$;

GRANT EXECUTE ON FUNCTION public.recalc_brand_app_payment_flags(uuid) TO authenticated;

COMMENT ON FUNCTION public.recalc_brand_app_payment_flags(uuid) IS
  '신청 1건 입금여부 자동 갱신 — 관리자 새로고침 버튼 핸들러. '
  'recruit/product/transfer 는 products 합계 기준 재설정, free 는 기존 값 보존. '
  'is_admin() 가드.';


-- ── 4. 기존 행 백필 ──
-- 마이그레이션 시점에 기존 47건 (운영 기준) 신청의 payment_flags 를 자동 설정.
-- free 는 false (운영자가 필요 시 토글).
UPDATE public.brand_applications
SET payment_flags = public.calc_brand_app_payment_flags(products)
WHERE payment_flags = '{}'::jsonb OR payment_flags IS NULL;

COMMIT;
