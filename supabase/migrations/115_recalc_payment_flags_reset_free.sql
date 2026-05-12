-- ════════════════════════════════════════════════════════════════════
-- migration 115: recalc_brand_app_payment_flags free 키도 false 로 리셋
-- ────────────────────────────────────────────────────────────────────
-- 사용자 결정 2026-05-12:
--   migration 114 의 RPC 는 free 키를 보존(무료모집 ON 유지)하도록 설계됐는데,
--   사용자가 새로고침 버튼 = "원래대로 돌아가기" 의도였음. 무료모집 ON 상태에서
--   새로고침해도 「무료모집」만 표시되는 게 의도와 어긋남.
--
-- 변경: recalc_brand_app_payment_flags 본문에서 free 보존 로직 제거.
--       calc_brand_app_payment_flags(products) 결과(free=false 포함)를 그대로
--       payment_flags 에 저장. 4종 모두 products 합계 기반으로 완전 초기화.
--
-- ROLLBACK:
--   migration 114 본문의 RPC 정의를 다시 CREATE OR REPLACE 실행.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.recalc_brand_app_payment_flags(p_application_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app       public.brand_applications%ROWTYPE;
  v_new_flags jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app FROM public.brand_applications WHERE id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  -- 4종 모두 products 합계 기반으로 재설정 (free 키도 false 로 리셋).
  -- 새로고침 = 완전 초기화 의도 (migration 114 의 free 보존 동작에서 변경).
  v_new_flags := public.calc_brand_app_payment_flags(v_app.products);

  UPDATE public.brand_applications
  SET payment_flags = v_new_flags
  WHERE id = p_application_id;

  RETURN v_new_flags;
END;
$$;

COMMENT ON FUNCTION public.recalc_brand_app_payment_flags(uuid) IS
  '신청 1건 입금여부 자동 갱신 — 관리자 새로고침 버튼 핸들러. '
  '4종 모두(recruit/product/transfer/free) products 합계 기반 재설정. '
  'is_admin() 가드. migration 115 에서 free 보존 → false 리셋으로 변경.';
