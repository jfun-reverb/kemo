-- ============================================================
-- migration: 178
-- title: relax update_receipt_admin — 3종 필수 → 최소 1개
-- date: 2026-06-09
-- 128 대비 변경:
--   [변경] 주문번호·구매일·구매금액 3종 모두 필수 → 최소 1개 있으면 저장 허용
--   [신규] 3종 모두 빈값/NULL 인 경우 ERRCODE 22023 으로 차단
--   [변경] order_number: 빈값(공백만) 차단 제거 → 빈값은 NULL 로 통일(NULLIF)
--   [유지] order_number 값이 있을 때만 200자 초과 검증
--   [유지] purchase_amount 값이 있을 때만(IS NOT NULL) < 0 검증
--   [유지] 권한 가드(is_campaign_admin), FOR UPDATE 행 잠금, no-op 체크, 이력 기록
-- 관리자 전용 함수(is_campaign_admin) — 인플루언서 제출 경로 무관
--
-- rollback (128 버전으로 되돌리기):
--   supabase/migrations/128_receipt_required_fields.sql 의 4번 섹션(update_receipt_admin)을
--   SQL Editor 에서 다시 실행하면 CREATE OR REPLACE 로 함수가 128 버전으로 교체됨.
--   데이터·테이블·인덱스는 이 마이그레이션과 무관하므로 함수 교체만으로 완전 롤백됨.
-- ============================================================

BEGIN;

-- ============================================================
-- update_receipt_admin RPC (128 버전 교체)
--
-- 권한: campaign_admin 이상 (is_campaign_admin())
-- 입력 검증:
--   - 최소 1개 필수: order_number(공백 제거 후 비어있지 않음) / purchase_date / purchase_amount
--     셋 모두 없으면 22023
--   - order_number: 값이 있을 때만 200자 초과 검증. 빈값은 NULL 저장(NULLIF)
--   - purchase_date: NULL 허용 (그대로 저장)
--   - purchase_amount: NULL 허용. 값이 있을 때만 < 0 검증 (0원 허용)
-- 대상 검증:
--   - 존재하지 않는 deliverable_id → 에러
--   - kind != 'receipt' → 에러
-- no-op:
--   - 저장값(order_number=NULLIF(trimmed,''), purchase_date, purchase_amount) 이
--     기존값과 IS NOT DISTINCT FROM 모두 동일 → RETURN (이력 미기록)
-- 부수 효과:
--   - deliverables UPDATE
--   - receipt_edit_history INSERT (prev/next 스냅샷)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_receipt_admin(
  p_deliverable_id  uuid,
  p_order_number    text,
  p_purchase_date   date,
  p_purchase_amount numeric
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_prev          record;
  v_admin_name    text;
  v_trimmed_order text;
  v_order_to_save text;  -- NULLIF(v_trimmed_order, '') — 저장에 사용할 최종값
BEGIN
  -- ── 권한 가드: campaign_admin 이상 ──────────────────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 정규화 ───────────────────────────────────────────
  -- order_number 는 앞뒤 공백 제거 후 비교. NULL 과 빈값은 동일 처리
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  -- 저장할 최종값: 빈 문자열이면 NULL 로 통일
  v_order_to_save := NULLIF(v_trimmed_order, '');

  -- ── 입력 검증: 최소 1개 필수 ─────────────────────────────
  -- 3종 모두 빈값/NULL 이면 의미 없는 호출 — 차단
  IF v_order_to_save IS NULL
     AND p_purchase_date   IS NULL
     AND p_purchase_amount IS NULL
  THEN
    RAISE EXCEPTION '주문번호·구매일·구매금액 중 최소 1개는 입력해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── 입력 검증: order_number — 값이 있을 때만 길이 검사 ────
  IF v_order_to_save IS NOT NULL AND length(v_order_to_save) > 200 THEN
    RAISE EXCEPTION '주문번호는 200자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 입력 검증: purchase_amount — 값이 있을 때만 음수 검사 ─
  IF p_purchase_amount IS NOT NULL AND p_purchase_amount < 0 THEN
    RAISE EXCEPTION '구매금액은 0 이상이어야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 조회 ──────────────────────────────────────────
  SELECT order_number, purchase_date, purchase_amount, kind
    INTO v_prev
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;  -- 동시 수정 충돌 방지를 위한 행 잠금

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다 (id: %)', p_deliverable_id USING ERRCODE = '02000';
  END IF;

  IF v_prev.kind != 'receipt' THEN
    RAISE EXCEPTION '영수증 결과물만 수정 가능합니다 (kind=receipt 필요, 실제: %)', v_prev.kind
      USING ERRCODE = '22023';
  END IF;

  -- ── no-op 체크: 저장값 기준으로 기존값과 모두 동일하면 이력 미기록 후 반환 ──
  -- v_order_to_save: NULLIF 적용 후 값 (빈 문자열 → NULL 통일)
  IF v_prev.order_number    IS NOT DISTINCT FROM v_order_to_save
     AND v_prev.purchase_date   IS NOT DISTINCT FROM p_purchase_date
     AND v_prev.purchase_amount IS NOT DISTINCT FROM p_purchase_amount
  THEN
    RETURN;
  END IF;

  -- ── 관리자 이름 스냅샷 ────────────────────────────────────
  SELECT name INTO v_admin_name
    FROM public.admins
   WHERE auth_id = auth.uid()
   LIMIT 1;

  -- ── deliverables UPDATE ───────────────────────────────────
  -- updated_at 은 trg_deliverables_updated_at BEFORE UPDATE 트리거가 자동 갱신
  UPDATE public.deliverables
     SET order_number    = v_order_to_save,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT ───────────────────────────
  -- next 값은 저장값(v_order_to_save, p_purchase_date, p_purchase_amount) 기준으로 기록
  INSERT INTO public.receipt_edit_history (
    deliverable_id,
    changed_by,
    changed_by_name,
    order_number_prev,
    order_number_next,
    purchase_date_prev,
    purchase_date_next,
    purchase_amount_prev,
    purchase_amount_next,
    source
  ) VALUES (
    p_deliverable_id,
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    v_prev.order_number,
    v_order_to_save,
    v_prev.purchase_date,
    p_purchase_date,
    v_prev.purchase_amount,
    p_purchase_amount,
    'admin_edit'
  );
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '관리자가 deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 128에서 178로 완화: 3종 모두 필수 → 최소 1개 입력. 178.';

-- 권한 부여: 클라이언트(authenticated)에서 호출 가능 (128 과 동일)
REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;

COMMIT;
