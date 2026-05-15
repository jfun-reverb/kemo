-- ============================================================
-- migration: 128
-- title: receipt required fields (order_number) + edit history + admin RPC
-- date: 2026-05-15
-- spec: docs/specs/2026-05-14-receipt-required-fields.md
-- decisions:
--   - target table: deliverables (not receipts) — receipts is dead code, dual-write preserved
--   - edit permission: campaign_admin and above (campaign_manager read-only)
--   - history select: all admins (is_admin() — campaign_manager included)
--   - purchase_amount validation: >= 0 (spec original was > 0, relaxed by user)
--   - existing rows: order_number NULL allowed, no backfill
--   - order_number: reject empty/whitespace-only, max 200 chars
--
-- rollback:
--   DROP FUNCTION IF EXISTS public.update_receipt_admin(uuid, text, date, numeric);
--   DROP TABLE IF EXISTS public.receipt_edit_history;
--   ALTER TABLE public.deliverables DROP COLUMN IF EXISTS order_number;
-- ============================================================

BEGIN;

-- ============================================================
-- 1. order_number 컬럼 추가 (deliverables)
--    kind='receipt' 행에서만 사용. 기존 행은 NULL 허용 (마이그레이션 시 백필 없음).
-- ============================================================
ALTER TABLE public.deliverables
  ADD COLUMN IF NOT EXISTS order_number text NULL;

COMMENT ON COLUMN public.deliverables.order_number IS
  '리뷰어 영수증 주문번호 (kind=receipt 행에서만 사용). 2026-05-15 추가, 마이그레이션 128. 기존 행은 NULL 허용';


-- ============================================================
-- 2. receipt_edit_history 테이블 (관리자 영수증 수정 이력 감사 테이블)
--    deliverable_id FK: deliverables(id) ON DELETE CASCADE
--    → delete_admin_completely 가 applications cascade → deliverables cascade → 이 테이블 자동 정리됨
-- ============================================================
CREATE TABLE IF NOT EXISTS public.receipt_edit_history (
  id                    bigserial     PRIMARY KEY,

  -- deliverables 참조 (kind='receipt' 행)
  deliverable_id        uuid          NOT NULL
                          REFERENCES public.deliverables(id) ON DELETE CASCADE,

  -- 수정자 정보
  changed_by            uuid          NOT NULL,   -- auth.uid() 스냅샷 (admins 삭제 후도 이력 보존 위해 FK 미설정)
  changed_by_name       text          NOT NULL,   -- admins.name 스냅샷

  changed_at            timestamptz   NOT NULL DEFAULT now(),

  -- 변경 전/후 값 스냅샷 (3개 필드 일괄)
  order_number_prev     text,
  order_number_next     text,
  purchase_date_prev    date,
  purchase_date_next    date,
  purchase_amount_prev  numeric,
  purchase_amount_next  numeric,

  -- 수정 출처 (현재는 admin_edit 단일값. 추후 확장 여지)
  source                text          NOT NULL DEFAULT 'admin_edit'
                          CHECK (source IN ('admin_edit'))
);

COMMENT ON TABLE  public.receipt_edit_history IS
  '관리자가 deliverables(kind=receipt) 영수증 주문번호·구매일·구매금액을 수정한 이력. SECURITY DEFINER RPC(update_receipt_admin)만 INSERT 가능. 128.';
COMMENT ON COLUMN public.receipt_edit_history.changed_by      IS '수정자 auth.uid(). admins 행 삭제 후도 이력 보존하기 위해 FK 미설정.';
COMMENT ON COLUMN public.receipt_edit_history.changed_by_name IS '수정 시점 admins.name 스냅샷. 추후 admins 행이 사라져도 라벨 유지.';
COMMENT ON COLUMN public.receipt_edit_history.source          IS '수정 출처. 현재는 admin_edit 고정 (관리자 수동 수정).';

-- 인덱스: 결과물 단위 타임라인 조회용
CREATE INDEX IF NOT EXISTS idx_receipt_edit_history_deliverable_changed_at
  ON public.receipt_edit_history (deliverable_id, changed_at DESC);


-- ============================================================
-- 3. receipt_edit_history RLS
--    SELECT: is_admin() — 모든 관리자 (campaign_manager 포함)
--    INSERT/UPDATE/DELETE: 정책 미정의 → 클라이언트 직접 조작 차단
--                          update_receipt_admin() SECURITY DEFINER RPC만 INSERT 가능
-- ============================================================
ALTER TABLE public.receipt_edit_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "receipt_edit_history_select_admin" ON public.receipt_edit_history;
CREATE POLICY "receipt_edit_history_select_admin"
  ON public.receipt_edit_history FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 정책은 의도적으로 정의하지 않음
-- → SECURITY DEFINER RPC(update_receipt_admin)만 BYPASSRLS로 INSERT 가능


-- ============================================================
-- 4. update_receipt_admin RPC
--    관리자가 deliverables(kind=receipt) 의 영수증 주문번호·구매일·구매금액을 직접 수정
--
--    권한: campaign_admin 이상 (is_campaign_admin())
--    입력 검증:
--      - order_number: NULL·공백만 → 에러, 200자 초과 → 에러
--      - purchase_date: NULL → 에러
--      - purchase_amount: NULL → 에러, < 0 → 에러 (0원 허용)
--    대상 검증:
--      - 존재하지 않는 deliverable_id → 에러
--      - kind != 'receipt' → 에러
--    no-op:
--      - 3종 값이 모두 현재값과 동일 → RETURN (이력 미기록)
--    부수 효과:
--      - deliverables UPDATE (updated_at은 trg_deliverables_updated_at 트리거가 자동 갱신)
--      - receipt_edit_history INSERT (prev/next 스냅샷)
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
BEGIN
  -- ── 권한 가드: campaign_admin 이상 ──────────────────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 검증: order_number ───────────────────────────────
  -- NULL 또는 공백만인 경우 차단 (0자 빈값 포함)
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  IF v_trimmed_order = '' THEN
    RAISE EXCEPTION '주문번호는 빈값일 수 없습니다' USING ERRCODE = '22023';
  END IF;
  -- 길이 상한: 200자
  IF length(v_trimmed_order) > 200 THEN
    RAISE EXCEPTION '주문번호는 200자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 입력 검증: purchase_date ──────────────────────────────
  IF p_purchase_date IS NULL THEN
    RAISE EXCEPTION '구매일은 빈값일 수 없습니다' USING ERRCODE = '22023';
  END IF;

  -- ── 입력 검증: purchase_amount ────────────────────────────
  IF p_purchase_amount IS NULL THEN
    RAISE EXCEPTION '구매금액은 빈값일 수 없습니다' USING ERRCODE = '22023';
  END IF;
  IF p_purchase_amount < 0 THEN
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

  -- ── no-op 체크: 3종 모두 기존값과 동일하면 이력 미기록 후 반환 ──
  IF v_prev.order_number    IS NOT DISTINCT FROM v_trimmed_order
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
  -- updated_at은 trg_deliverables_updated_at BEFORE UPDATE 트리거가 자동 갱신
  UPDATE public.deliverables
     SET order_number    = v_trimmed_order,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT ───────────────────────────
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
    v_trimmed_order,
    v_prev.purchase_date,
    p_purchase_date,
    v_prev.purchase_amount,
    p_purchase_amount,
    'admin_edit'
  );
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '관리자가 deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 128.';

-- 권한 부여: 클라이언트(authenticated)에서 호출 가능
REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;


-- ============================================================
-- 적용 확인용 코멘트 (실행 후 SQL Editor에서 확인)
-- ============================================================
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'deliverables'
--    AND column_name  = 'order_number';
--
-- SELECT relname, relrowsecurity
--   FROM pg_class
--  WHERE relname = 'receipt_edit_history';
--
-- SELECT routine_name
--   FROM information_schema.routines
--  WHERE routine_schema = 'public'
--    AND routine_name   = 'update_receipt_admin';

COMMIT;
