-- ════════════════════════════════════════════════════════════════════
-- migration 116: products 변경 시 payment_flags 자동 재계산 트리거
-- ────────────────────────────────────────────────────────────────────
-- 사용자 결정 2026-05-12:
--   상세 모달에서 모집비용/상품비/이체수수료 입력값을 수정해도 신청 목록
--   페인의 「입금여부」 칩이 자동 반영 안 되던 문제. 새로고침 버튼을
--   다시 눌러야 갱신되어 운영 흐름이 끊겼다.
--
-- 변경: brand_applications.products 변경 시 payment_flags 의 recruit/
--       product/transfer 3종을 자동 갱신. free 키는 OLD 값 보존
--       (관리자 명시적 토글이라 자동 동작이 덮어쓰지 않도록).
--
-- 트리거: BEFORE INSERT OR UPDATE OF products — payment_flags 만 따로
--         수정할 때(수동 칩 토글·새로고침 RPC)는 발화 안 함.
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS trg_brand_app_auto_recalc_payment_flags
--     ON public.brand_applications;
--   DROP FUNCTION IF EXISTS public.auto_recalc_brand_app_payment_flags();
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.auto_recalc_brand_app_payment_flags()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_new       jsonb;
  v_old_free  boolean;
BEGIN
  -- INSERT: 새 신청은 free=false 로 시작 (helper 반환값 그대로).
  IF TG_OP = 'INSERT' THEN
    NEW.payment_flags := public.calc_brand_app_payment_flags(NEW.products);
    RETURN NEW;
  END IF;

  -- UPDATE: products 변경 시만 발화. free 키는 OLD 값 보존.
  --   관리자가 명시적으로 free=true 토글해 둔 상태에서 products 만 살짝
  --   고쳐도 무료모집 해제되지 않도록.
  IF NEW.products IS DISTINCT FROM OLD.products THEN
    v_new      := public.calc_brand_app_payment_flags(NEW.products);
    v_old_free := COALESCE((OLD.payment_flags->>'free')::boolean, false);
    NEW.payment_flags := v_new || jsonb_build_object('free', v_old_free);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.auto_recalc_brand_app_payment_flags() IS
  'products 변경 시 payment_flags 자동 재계산 트리거 함수. recruit/product/transfer 는 '
  '합계 기반 자동, free 는 OLD 값 보존. 수동 칩 토글·새로고침 원격 호출 함수는 영향 없음.';

DROP TRIGGER IF EXISTS trg_brand_app_auto_recalc_payment_flags ON public.brand_applications;
CREATE TRIGGER trg_brand_app_auto_recalc_payment_flags
  BEFORE INSERT OR UPDATE OF products
  ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_recalc_brand_app_payment_flags();
