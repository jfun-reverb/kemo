-- ============================================================
-- 324_settlement_audit_fixes_h1_h3_h4_h5_h8.sql
-- 정산(settlements) 전수조사 후속 조치 — 묶음 H 중 데이터베이스 조각 5개(H-1·H-3·H-4·H-5·H-8)
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 H — 정산」
--
-- ── 이 파일에 없는 것 ──
--   H-2(정산대기 중 새 영수증 승인 시 재계산·표시), H-6(재계산 이력 한국어 라벨) —
--   이번 작업 범위 밖. H-7(정산 잠금 오류 문구 일본어)은 사양서에 "이미 해결됨"으로
--   확인됐다(dev/js/ui.js 에 이미 등록).
--
-- ⚠️ 이 파일은 정산 화면(dev/js/admin-settlements.js 등)을 전혀 건드리지 않는다 —
--   같은 시점에 다른 작업이 그 파일을 손대고 있어(H-6·H-7 확인), 파일 충돌을 피하기
--   위해 데이터베이스 함수만 바꾼다. 화면이 새 반환값(is_pre_cutoff·
--   skipped_no_paypal_count·cert_at)을 실제로 쓰려면 화면 쪽 후속 작업이 필요하다 —
--   각 절 하단에 "화면 변경 필요" 로 표시했다.
--
-- ⚠️ 정산은 지금 인플루언서에게 잠겨 있고(settlement_settings.influencer_visible=false)
--   도입일(cutoff_at)도 미설정이라 자동 생성 0건이다. 이 파일은 그 잠금·컷오프 스위치를
--   건드리지 않는다 — 급하지 않지만 가동 스위치를 켜기 전에 끝나 있어야 하는 조각이다.
--
-- ── 재정의 기준(전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   update_receipt_admin              → 128 → 178 → 302(현재 원본). 이 파일은 302 베이스.
--   backfill_settlements              → 218 → 231 → 242 → 262 → 300(현재 원본). 300 베이스.
--   get_past_unregistered_settlements → 232 → 262 → 300(현재 원본). 300 베이스.
--   register_past_settlements         → 233 → 262 → 300(현재 원본). 300 베이스.
--   _settlement_cert_candidates       → 232 → 262 → 264 → 300 → 318(현재 원본). 이 파일은
--     이 함수를 손대지 않는다(cert_at·is_success·amount_issue 계산은 이미 318 이 정확히
--     반환하고 있어, 그 값을 "누가 어떻게 저장·노출하는지"만 이번에 바꾼다).
--
-- 조각별 요약:
--   H-1 update_receipt_admin(302)      — 재계산을 리뷰어형(monitor)에만 적용
--   H-3 get_past_unregistered_settlements(300) — "금액 미확정 + 컷오프 이후" 구멍 노출
--   H-4 register_past_settlements(300) — 송금완료 일괄 등록에도 페이팔 확인
--   H-5 settlements 표 + backfill_settlements(300)·register_past_settlements(300)
--       — 인증 성공 시점(cert_at)을 정산 행에 저장
--   H-8 backfill_settlements(300)      — 페이팔 미등록 안내 알림 중복 발송 차단
--
-- 롤백: 각 절 하단 참고. 전체를 한꺼번에 되돌리려면 파일 맨 아래 "전체 롤백" 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. settlements 표 — cert_at 칸 추가 (H-5, 준비 단계)
-- ============================================================
ALTER TABLE public.settlements
  ADD COLUMN IF NOT EXISTS cert_at timestamptz;

COMMENT ON COLUMN public.settlements.cert_at IS
  '[324, H-5] 정산 생성 시점의 "인증 성공 시각"(_settlement_cert_candidates().cert_at) 스냅샷. '
  '이 칸이 생기기 전(324 적용 이전, 또는 324 적용 전에 만들어진 행)에는 NULL — 당시 그 값을 '
  '저장해 두지 않았으므로 사후 복구 불가. 화면은 NULL 을 "모름"으로 별도 표시할 것(정산등록일 '
  '로 대신 채우지 말 것 — 등록일과 인증성공일은 다른 시점이고, 이 칸을 만든 이유가 바로 그 '
  '혼동을 없애는 것이다). 324 이후 생성되는 행(backfill_settlements·register_past_settlements) '
  '부터 실제 값이 채워진다.';

-- 이 절 롤백: ALTER TABLE public.settlements DROP COLUMN IF EXISTS cert_at;
--   (아래 2·5절을 먼저 롤백한 뒤에 실행할 것 — 그 함수들이 이 칸에 INSERT 한다)


-- ============================================================
-- 1. update_receipt_admin 재정의 — 재계산을 리뷰어형(monitor)에만 적용 (H-1)
--    반환 타입 불변(302 와 동일 TABLE 4컬럼) — DROP 불필요, CREATE OR REPLACE 로 충분.
--
--    ── 무엇이 문제였나 ──
--    302 의 재계산 블록(그 파일 342~433행)은 "정산이 pending 이면" 이라는 조건만
--    보고 리뷰어형(monitor) 전용 계산식(영수증 결제 금액 vs 상시가 min)을 무조건
--    적용했다. 그런데 정산 대상은 리뷰어형만이 아니다 — 시딩(gifting)·방문형(visit)
--    도 정산 행을 갖고, 그쪽 금액 출처는 campaigns.reward 다(마이그레이션 264·300).
--    방문형은 "현장 사진"도 kind='receipt' 로 제출되므로(CLAUDE.md — "방문형은
--    게시물뿐 아니라 현장 사진도 배치 조회에 포함") 그 사진을 관리자가 사후 수정하면
--    이 함수가 호출되고, 정산이 pending 이면 "영수증 결제 금액이 없다"는 엉뚱한 사유로
--    on_hold 로 잠기거나(재계산 실패 자동 보류), 우연히 purchase_amount 값이 들어 있으면
--    그 값과 무관한 reward 기준 금액이 조용히 영수증 기준 금액으로 바뀌어 버렸다.
--
--    ── 이 절이 하는 일 ──
--    정산 조회 시 그 응모가 속한 캠페인의 recruit_type 을 함께 읽어, 재계산 블록은
--    recruit_type='monitor' 일 때만 진입한다. 시딩·방문형은 정산이 pending 이어도
--    금액을 그대로 둔다(재계산도 자동 보류도 하지 않음) — 애초에 영수증 금액이 그
--    정산 금액의 근거가 아니므로 손댈 이유가 없다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_receipt_admin(
  p_deliverable_id  uuid,
  p_order_number    text,
  p_purchase_date   date,
  p_purchase_amount numeric
)
RETURNS TABLE (
  settlement_status       text,
  settlement_recalculated boolean,
  settlement_amount_jpy   bigint,
  settlement_amount_issue text
)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_prev                  record;   -- 대상 영수증 행(order_number/purchase_date/purchase_amount/kind/application_id)
  v_admin_name             text;
  v_trimmed_order          text;
  v_order_to_save          text;    -- NULLIF(v_trimmed_order, '') — 저장에 사용할 최종값

  v_settlement             record;  -- 그 응모의 정산 행(있으면) + [324] 캠페인 recruit_type
  v_settlement_found       boolean; -- FOUND 함정 방지용 명시적 플래그(302 파일 경고 그대로 계승)

  v_latest_receipt_amount  numeric; -- 저장 직후 다시 읽은 "그 응모의 최신 영수증" 결제 금액
  v_cap                    bigint;  -- 다시 읽은 캠페인 상시가(product_price, 옛 스냅샷 재사용 금지)
  v_new_amount             bigint;  -- 재계산된 정산 금액
  v_new_receipt_snapshot   bigint;  -- 재계산된 감사용 칸 — 영수증 원금액(floor)
  v_new_cap_snapshot       bigint;  -- 재계산된 감사용 칸 — 적용 상한
  v_amount_issue           text;    -- 재계산 실패 사유(정상이면 NULL)
  v_recalculated           boolean := false;
  v_out_status             text;    -- 반환용: 처리 후 정산 상태
  v_out_amount             bigint;  -- 반환용: 처리 후 정산 금액
BEGIN
  -- ── 권한 가드: campaign_admin 이상(302 와 동일, 변경 없음) ──────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 정규화(302 와 동일) ─────────────────────────────────────────
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  v_order_to_save := NULLIF(v_trimmed_order, '');

  -- ── 입력 검증: 최소 1개 필수(302 와 동일) ──────────────────────────
  IF v_order_to_save IS NULL
     AND p_purchase_date   IS NULL
     AND p_purchase_amount IS NULL
  THEN
    RAISE EXCEPTION '주문번호·구매일·구매금액 중 최소 1개는 입력해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  IF v_order_to_save IS NOT NULL AND length(v_order_to_save) > 200 THEN
    RAISE EXCEPTION '주문번호는 200자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  IF p_purchase_amount IS NOT NULL AND p_purchase_amount < 0 THEN
    RAISE EXCEPTION '구매금액은 0 이상이어야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 조회(302 와 동일 + application_id 추가 조회) ───────────
  SELECT order_number, purchase_date, purchase_amount, kind, application_id
    INTO v_prev
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다 (id: %)', p_deliverable_id USING ERRCODE = '02000';
  END IF;

  IF v_prev.kind != 'receipt' THEN
    RAISE EXCEPTION '영수증 결과물만 수정 가능합니다 (kind=receipt 필요, 실제: %)', v_prev.kind
      USING ERRCODE = '22023';
  END IF;

  -- ── 그 응모의 정산 조회 + [324, H-1] 캠페인 모집 형식(recruit_type) 함께 조회 ──
  -- FOR UPDATE OF s 로 settlements 행만 잠근다(campaigns 행은 잠그지 않음 — 다른 캠페인
  -- 편집과 불필요하게 경합하지 않도록). settlements.application_id 는 UNIQUE(217) 이므로
  -- 최대 1행만 매칭된다.
  SELECT s.id, s.status, s.version, s.amount_jpy, s.campaign_id,
         s.receipt_amount_jpy, s.amount_cap_jpy, c.recruit_type
    INTO v_settlement
    FROM public.settlements s
    JOIN public.campaigns   c ON c.id = s.campaign_id
   WHERE s.application_id = v_prev.application_id
   FOR UPDATE OF s;
  v_settlement_found := FOUND;  -- 이후 문장이 FOUND 를 계속 덮어쓰므로 즉시 변수로 옮김

  -- 송금완료(paid)·보류(on_hold)·취소(cancelled) — 수정 자체를 차단.
  -- (302 그대로 — 모집 형식과 무관하게 확정된 금전 기록은 보호한다)
  IF v_settlement_found AND v_settlement.status IN ('paid', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'settlement_locked_receipt_edit: 이미 처리된 정산(송금완료·보류·취소)이 연결된 영수증은 수정할 수 없습니다. 정산 상태를 먼저 확인해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  -- ── no-op 체크(302 와 동일) ──────────────────────────────────────
  IF v_prev.order_number    IS NOT DISTINCT FROM v_order_to_save
     AND v_prev.purchase_date   IS NOT DISTINCT FROM p_purchase_date
     AND v_prev.purchase_amount IS NOT DISTINCT FROM p_purchase_amount
  THEN
    RETURN QUERY SELECT
      (CASE WHEN v_settlement_found THEN v_settlement.status ELSE NULL END),
      false,
      (CASE WHEN v_settlement_found THEN v_settlement.amount_jpy ELSE NULL END),
      NULL::text;
    RETURN;
  END IF;

  -- ── 관리자 이름 스냅샷(302 와 동일) ──────────────────────────────
  SELECT name INTO v_admin_name
    FROM public.admins
   WHERE auth_id = auth.uid()
   LIMIT 1;

  -- ── deliverables UPDATE(302 와 동일) ─────────────────────────────
  UPDATE public.deliverables
     SET order_number    = v_order_to_save,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT(302 와 동일) ─────────────────────
  INSERT INTO public.receipt_edit_history (
    deliverable_id, changed_by, changed_by_name,
    order_number_prev, order_number_next,
    purchase_date_prev, purchase_date_next,
    purchase_amount_prev, purchase_amount_next,
    source
  ) VALUES (
    p_deliverable_id, auth.uid(), COALESCE(v_admin_name, '(이름미상)'),
    v_prev.order_number, v_order_to_save,
    v_prev.purchase_date, p_purchase_date,
    v_prev.purchase_amount, p_purchase_amount,
    'admin_edit'
  );

  -- ── [324, H-1] 정산이 정산대기(pending)이고 리뷰어형(monitor)일 때만 재계산 ──
  -- 시딩(gifting)·방문형(visit)은 금액 출처가 campaigns.reward 라 영수증 수정과
  -- 무관하다 — 재계산도, "금액 미확정" 자동 보류도 하지 않고 그대로 둔다.
  IF v_settlement_found AND v_settlement.status = 'pending' AND v_settlement.recruit_type = 'monitor' THEN
    -- "최신 영수증" 재조회 — 300/318 의 receipt_latest 와 동일한 정렬 기준(draft 제외는
    -- 이 조회에 영향 없음 — 방금 이 함수가 UPDATE 한 행은 draft 가 아니라 기존 상태 그대로).
    SELECT purchase_amount
      INTO v_latest_receipt_amount
      FROM public.deliverables
     WHERE application_id = v_prev.application_id AND kind = 'receipt'
     ORDER BY submitted_at DESC, updated_at DESC
     LIMIT 1;

    -- 상한 재조회 — 저장된 옛 amount_cap_jpy 재사용 금지, campaigns 를 다시 읽는다.
    SELECT product_price
      INTO v_cap
      FROM public.campaigns
     WHERE id = v_settlement.campaign_id;

    -- amount_issue 판정 3종 — 300/318 과 완전히 동일한 조건.
    IF v_latest_receipt_amount IS NULL OR v_latest_receipt_amount <= 0 THEN
      v_amount_issue := '리뷰어형 영수증 결제 금액(purchase_amount) 값 없음 또는 0 이하';
    ELSIF v_cap IS NULL OR v_cap <= 0 THEN
      v_amount_issue := '리뷰어형 제품 가격(product_price, 지급 상한) 값 없음 또는 0 이하';
    ELSIF floor(LEAST(v_latest_receipt_amount, v_cap::numeric)) <= 0 THEN
      v_amount_issue := '리뷰어형 정산 금액이 소수점 절사 후 0 이하';
    ELSE
      v_amount_issue := NULL;
    END IF;

    IF v_amount_issue IS NOT NULL THEN
      -- ── 재계산 실패 → 자동 보류(302 결정 그대로 계승) ──
      -- ⚠️ memo 에 "자동 보류"라는 연속 문자열을 절대 쓰지 않는다(dev/js/admin-settlements.js
      -- 의 신청반려 배지 문자열 매칭과 충돌 — 302 파일 상단 경고 그대로 계승).
      UPDATE public.settlements
         SET status  = 'on_hold',
             memo    = '영수증 수정으로 금액을 확정할 수 없어 보류 처리됨 (' || v_amount_issue || ')',
             version = version + 1
       WHERE id = v_settlement.id;

      INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
      VALUES (
        v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(),
        '영수증 수정 후 정산 금액 재계산 불가로 보류 처리 (' || v_amount_issue || ')'
      );

      v_out_status := 'on_hold';
      v_out_amount := v_settlement.amount_jpy;  -- 예전 값 그대로(변경 없음)
      v_recalculated := false;
    ELSE
      -- ── 재계산 성공 — 300/318 과 완전히 동일한 계산식 ──
      v_new_amount           := NULLIF(GREATEST(floor(LEAST(v_latest_receipt_amount, v_cap::numeric)), 0), 0)::bigint;
      v_new_receipt_snapshot := floor(v_latest_receipt_amount)::bigint;
      v_new_cap_snapshot     := v_cap::bigint;

      IF v_new_amount           IS DISTINCT FROM v_settlement.amount_jpy
         OR v_new_receipt_snapshot IS DISTINCT FROM v_settlement.receipt_amount_jpy
         OR v_new_cap_snapshot     IS DISTINCT FROM v_settlement.amount_cap_jpy
      THEN
        UPDATE public.settlements
           SET amount_jpy         = v_new_amount,
               amount_source      = 'receipt_amount',
               receipt_amount_jpy = v_new_receipt_snapshot,
               amount_cap_jpy     = v_new_cap_snapshot,
               version            = version + 1
         WHERE id = v_settlement.id;

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (
          v_settlement.id, 'recalc', 'pending', 'pending', auth.uid(),
          '영수증 수정으로 정산 금액 재계산: ' || COALESCE(v_settlement.amount_jpy::text, '(없음)')
            || '엔 → ' || v_new_amount || '엔'
        );

        v_out_amount    := v_new_amount;
        v_recalculated  := true;
      ELSE
        v_out_amount := v_settlement.amount_jpy;  -- 재계산했지만 값이 같음 — no-op
      END IF;

      v_out_status := 'pending';  -- 재계산 성공 경로는 상태가 바뀌지 않는다
    END IF;
  ELSIF v_settlement_found AND v_settlement.status = 'pending' THEN
    -- ── [324, H-1] 시딩(gifting)·방문형(visit) — 정산은 그대로, 손대지 않는다 ──
    -- 이 정산의 금액 출처는 campaigns.reward 지 영수증이 아니다. 방문형의 "현장 사진"
    -- (kind='receipt') 수정이 이 지점에 도달할 수 있지만, 재계산·자동 보류 어느 쪽도
    -- 하지 않는다 — 애초에 영수증 값이 이 정산 금액의 근거가 아니기 때문이다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  ELSIF v_settlement_found THEN
    -- 이 지점은 이론상 도달 불가 — status IN ('paid','on_hold','cancelled') 는 이미
    -- 위에서 차단됐고, 남는 값은 'pending' 뿐이다(217 CHECK 로 status 는 4종만 존재).
    -- 방어적으로 기존 값을 그대로 반환한다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  END IF;

  RETURN QUERY SELECT v_out_status, v_recalculated, v_out_amount, v_amount_issue;
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '[324 재정의, 302 원본 대체(재계산을 recruit_type=monitor 로 한정)] 관리자가 '
  'deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 '
  '기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 그 응모에 정산(settlements)이 '
  '있으면: paid/on_hold/cancelled 는 수정 차단(RAISE EXCEPTION, 모집 형식 무관). pending 이고 '
  '캠페인 recruit_type=monitor(리뷰어형)이면 최신 영수증·현재 캠페인 상시가로 정산 금액을 '
  '재계산해 갱신(변경 시 settlement_events action=recalc 기록, 실패 시 on_hold 자동 전환). '
  'pending 이지만 시딩(gifting)·방문형(visit)이면 정산을 손대지 않는다(금액 출처가 '
  'campaigns.reward 라 영수증과 무관 — H-1: 방문형 "현장 사진" 수정이 엉뚱하게 리뷰어형 '
  '계산식을 타던 결함 수정). 정산 행이 없으면 302 이전과 동일 동작.';

REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;

-- 이 절 롤백: 302_update_receipt_admin_settlement_guard.sql 의
--   "2. update_receipt_admin 재정의" CREATE FUNCTION 블록(DROP FUNCTION 포함)을
--   그대로 SQL Editor 에서 재실행하면 recruit_type 구분 없는 302 동작으로 되돌아간다.


-- ============================================================
-- 2. backfill_settlements 재정의 — 인증 성공 시점 저장 + 알림 중복 발송 차단 (H-5·H-8)
--    반환 타입 불변(300 과 동일 TABLE(created_count, paypal_missing_count)) —
--    DROP 불필요, CREATE OR REPLACE 로 충분.
-- ============================================================
CREATE OR REPLACE FUNCTION public.backfill_settlements()
RETURNS TABLE(created_count integer, paypal_missing_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_created         integer := 0;
  v_paypal_missing  integer := 0;
  v_cutoff          timestamptz;
  v_notify          boolean;  -- [242→262→300 계승, 324 도 유지] 인플루언서 공개 스위치(240)
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read (300 과 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  -- ── [242→262→300 계승, 324 도 유지] 인플루언서 노출 잠금 조회 ──
  -- ⚠️ 절대 제거 금지 — 아래 notif_candidates CTE 안에서만 참조한다(자리를 옮겼을 뿐
  --    게이트 자체는 그대로다. 파일 상단 "이 게이트를 없애지 마라" 지시 참고).
  v_notify := public.is_settlement_public();

  WITH cert AS (
    SELECT * FROM public._settlement_cert_candidates()
  ),
  inserted AS (
    -- [324, H-5] cert_at 컬럼 추가 — 인증 성공 시점을 정산 생성 시점에 함께 저장한다.
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, cert_at, paypal_email
    )
    SELECT influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
           receipt_amount_jpy, amount_cap_jpy, cert_at,
           NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외(PR2로 이관)
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외(PR2 수동 처리)
      AND amount_issue IS NULL         -- 금액 미확정 건은 CHECK(amount_jpy>0) 위반으로 배치 전체가
                                        -- 실패하는 것을 막기 위해 저장 대상에서 제외
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_candidates AS (
    -- [324, H-8] 인플루언서당 최대 1건으로 미리 좁힌다. 이전(218/241/242/262/300)의
    -- "NOT EXISTS 미읽음" 조건은 지금 이 함수 호출 안에서 함께 생기는 다른 행은 보지
    -- 못한다 — 같은 인플루언서의 서로 다른 캠페인 정산이 같은 호출에서 한꺼번에
    -- 새로 생기면(예: 두 캠페인이 같은 시점에 인증 성공) 인플루언서 1명에게 알림이
    -- 여러 통 나가던 실제 원인이 이것이다("캠페인이 승인될 때마다 나간다"의 재현
    -- 조건). DISTINCT ON 으로 한 호출 안에서는 1인당 1건까지만 후보로 남긴다.
    SELECT DISTINCT ON (i.influencer_id)
      i.influencer_id, i.id AS settlement_id
    FROM inserted i
    WHERE v_notify AND i.paypal_email IS NULL
    ORDER BY i.influencer_id, i.id
  ),
  notif_ins AS (
    -- [324, H-8] 재발송 간격 14일(created_at 기준, 읽음 여부 무관).
    --   · "읽음 여부 무관"으로 바꾼 이유 — 예전 조건("미읽음이 없으면 보낸다")은
    --     인플루언서가 알림을 읽는 순간 방어막이 사라져, 바로 다음 정산 생성 때
    --     또 나갔다(같은 호출 안 중복과는 별개의 재발 경로).
    --   · 14일(2주)을 택한 이유 — 이 저장소에 이미 있는 정기 재발송 성격의 안내는
    --     캠페인 홍보 다이제스트(주 2회, 월·목)뿐이라 직접 참고할 "PayPal 미등록류"
    --     선례는 없다. 정산은 급전 성격이 아니라 "등록해 달라"는 배지·안내이므로
    --     그보다는 뜸해도 되지만, 미등록 상태가 한두 달 방치되며 지급이 계속
    --     묶이는 것도 바람직하지 않다 — 매주보다 뜸하고 한 달보다는 짧은 지점으로
    --     "2주"를 채택했다. 화면/운영 관찰 후 조정 가능(간격은 이 한 줄만 바꾸면 됨).
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    SELECT nc.influencer_id, 'settlement_paypal_required', 'settlements', nc.settlement_id,
           'PayPalメールアドレス未登録のお知らせ',
           '報酬のお振込みにはPayPalメールアドレスの登録が必要です。マイページから登録をお願いします。'
    FROM notif_candidates nc
    WHERE NOT EXISTS (
      SELECT 1 FROM public.notifications x
      WHERE x.user_id = nc.influencer_id
        AND x.kind    = 'settlement_paypal_required'
        AND x.created_at > now() - interval '14 days'
    )
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM inserted WHERE paypal_email IS NULL)
  INTO v_created, v_paypal_missing;

  RETURN QUERY SELECT v_created, v_paypal_missing;
END;
$$;

COMMENT ON FUNCTION public.backfill_settlements() IS
  '[324 재정의, 300 원본 대체] 금액을 _settlement_cert_candidates() 헬퍼가 계산한 값으로 저장, '
  '[324, H-5] cert_at(인증 성공 시점)도 함께 저장. amount_issue 가 있는 건은 저장 대상에서 제외해 '
  'CHECK(amount_jpy>0) 위반으로 배치 전체가 실패하는 것을 방지. [324, H-8] PayPal 미등록 안내 '
  '알림은 같은 호출 안에서 인플루언서당 1건으로 제한 + 14일 재발송 간격(읽음 여부 무관) — '
  '중복·즉시 재발송을 막되 장기 미등록자에게는 주기적으로 다시 안내. 컷오프·게이트'
  '(v_notify=is_settlement_public())·이력 기록은 300 그대로(변경 없음).';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

-- 이 절 롤백: 300_settlement_amount_receipt_basis.sql 의
--   "2. backfill_settlements() 재정의" CREATE OR REPLACE 블록을 그대로 재실행.
--   (cert_at 저장이 없어지고 알림 중복 방지 로직도 옛(unread 기반) 방식으로 돌아간다 —
--   0절[cert_at 칸]은 남아 있어도 무방, INSERT 대상에서만 빠질 뿐이다)


-- ============================================================
-- 3. get_past_unregistered_settlements 재정의 — "금액 미확정" 사각지대 노출 (H-3)
--    반환 컬럼 추가(is_pre_cutoff) — DROP 후 CREATE 필요.
--
--    ── 무엇이 문제였나(화면 코드에 이미 있던 메모, dev/js/admin-settlements.js
--       165~168행 부근 — 이 파일은 그 파일을 건드리지 않는다, 읽기만 함) ──
--    backfill_settlements() 는 "컷오프 이후(cert_at >= v_cutoff) + amount_issue 없음"
--    만 자동 등록한다. get_past_unregistered_settlements() 는 "컷오프 이전(또는 cert_at
--    NULL, 또는 컷오프 미설정)"만 보여준다. 그 결과 "컷오프 이후인데 amount_issue 가
--    있는" 건(예: 캠페인에 product_price 가 비어 리뷰어형 금액을 계산할 수 없는 경우)은
--    자동 등록 대상도 아니고 "과거 미등록" 목록에도 안 뜬다 — 관리자가 그 존재 자체를
--    알 방법이 없는 사각지대.
--
--    ── 이 절이 하는 일 ──
--    WHERE 절에 "amount_issue IS NOT NULL" 이면 컷오프와 무관하게 노출하는 조건을
--    추가한다. 이미 이 함수는 "amount_issue 가 있는 행도 걸러내지 않고 그대로
--    반환한다"(300 원본 주석)는 원칙이 있어 화면(체크박스 비활성·사유 표시)이 이미
--    그 값을 받아 처리할 수 있는 상태다 — 그래서 새 화면을 만들 필요 없이 노출
--    범위만 넓힌다. 반환에 is_pre_cutoff(불리언)을 추가해 "진짜 과거분(컷오프 이전)"
--    과 "이번에 새로 보이게 된 컷오프 이후 금액 미확정분"을 화면이 구분해 다른 안내
--    문구를 붙일 수 있게 한다(화면 쪽 반영은 후속 — 지금은 값만 내려준다).
--
--    ── register_past_settlements() 는 손대지 않아도 되는 이유 ──
--    새로 보이는 행은 amount_issue IS NOT NULL 인 동안은 register_past_settlements()
--    의 targets CTE 가 이미 "AND c.amount_issue IS NULL" 로 걸러내므로 선택해도
--    등록되지 않는다(화면의 체크박스 비활성과 정합 — 기존 과거분 amount_issue 행과
--    동일하게 동작). 관리자가 캠페인의 product_price 를 채워 amount_issue 가
--    저절로 사라지면, 다음 backfill_settlements() 호출 때 정상적으로 자동 등록된다
--    (컷오프 이후분이므로) — 별도 수동 등록 경로가 필요 없다.
-- ============================================================
DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();

CREATE FUNCTION public.get_past_unregistered_settlements()
RETURNS TABLE (
  application_id       uuid,
  influencer_id        uuid,
  influencer_name       text,
  influencer_name_kana  text,
  has_paypal            boolean,
  campaign_id           uuid,
  campaign_no           text,
  campaign_title        text,
  recruit_type          text,
  amount_jpy            bigint,
  amount_source          text,
  receipt_amount_jpy     bigint,
  amount_cap_jpy          bigint,
  amount_issue           text,
  cert_at               timestamptz,
  is_pre_cutoff          boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff timestamptz;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  RETURN QUERY
  SELECT
    c.application_id,
    c.influencer_id,
    c.influencer_name,
    c.influencer_name_kana,
    (c.paypal_email IS NOT NULL AND btrim(c.paypal_email) <> '') AS has_paypal,
    c.campaign_id,
    c.campaign_no,
    c.campaign_title,
    c.recruit_type,
    c.amount_jpy,
    c.amount_source,
    c.receipt_amount_jpy,
    c.amount_cap_jpy,
    c.amount_issue,
    c.cert_at,
    -- [324, H-3] true = 진짜 과거분(컷오프 이전·시각 불명·컷오프 미설정 — 300 원본과
    --   동일 판정). false = 컷오프 이후인데 amount_issue 때문에 새로 노출된 건(이번
    --   추가분) — 화면이 두 경우에 다른 안내 문구를 붙일 수 있도록 구분값만 내려준다.
    (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff) AS is_pre_cutoff
  FROM public._settlement_cert_candidates() c
  WHERE c.is_success
    AND (
      -- ── 300 원본 조건(진짜 과거분) ──
      v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff
      -- ── [324, H-3 신규] 컷오프 이후라도 금액이 확정 안 되면 노출 ──
      -- amount_issue 가 있는 한 backfill_settlements() 가 절대 자동 등록하지 못하므로
      -- (CHECK(amount_jpy>0) 보호), 관리자가 원인을 보고 캠페인을 고칠 수 있어야 한다.
      OR c.amount_issue IS NOT NULL
    );
    -- ⚠️ amount_issue 가 있는 행은 화면에서 체크박스 비활성화 대상으로 그대로 반환한다
    -- (300 원본 원칙 유지 — 숨기면 "왜 이 건이 안 보이지"라는 혼란만 남긴다).
END;
$$;

COMMENT ON FUNCTION public.get_past_unregistered_settlements() IS
  '[324 재정의, 300 원본 대체(반환 컬럼 1개 추가: is_pre_cutoff)] 과거 미등록 인증성공 응모 '
  '목록(정산 페인 「과거 미등록」 UI). [324, H-3] 컷오프 이전분(진짜 과거분)에 더해, 컷오프 '
  '이후인데 amount_issue(금액 미확정)가 있어 자동 백필도 이 목록도 놓치던 사각지대를 함께 '
  '노출(is_pre_cutoff=false 로 구분). register_past_settlements() 는 무변경 — amount_issue '
  '가 있는 동안은 어차피 등록되지 않고, 캠페인 금액이 채워지면 다음 backfill 때 자동 등록됨. '
  '필터·권한 게이트는 300 그대로.';

REVOKE ALL ON FUNCTION public.get_past_unregistered_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;

-- 이 절 롤백: DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
--   이어서 300_settlement_amount_receipt_basis.sql 의 "3. 과거 미등록 인증성공 조회
--   RPC 재생성" CREATE FUNCTION 블록을 그대로 재실행.


-- ============================================================
-- 4. register_past_settlements 재정의 — 일괄 송금완료에도 페이팔 확인 (H-4) +
--    cert_at 저장(H-5). 반환 컬럼 추가(skipped_no_paypal_count) — DROP 후 CREATE 필요.
--
--    ── 무엇이 문제였나 ──
--    단건 처리(mark_settlement_paid, 241)는 PayPal 이메일이 없으면 RAISE EXCEPTION 으로
--    막는다. 그런데 일괄 처리(register_past_settlements, "과거 미등록" 화면의 대량
--    "송금완료 기록" 버튼)는 그 검사가 아예 없어서, PayPal 미등록 인플루언서도
--    status='paid'(이미 송금 완료했다는 뜻)로 그대로 저장돼 버렸다 — "돈을 보냈다"는
--    기록이 남았는데 보낼 주소가 없었다는 모순.
--
--    ── 이 절이 하는 일 ──
--    p_target_status='paid' 로 일괄 등록할 때, 그 시점 PayPal 이메일이 없는 건은
--    이 배치에서 제외한다(등록 자체를 안 한다 — 절반만 pending 으로 만들지 않음,
--    이유는 "송금완료"라는 명시적 지시와 다른 상태로 조용히 바꿔치기하면 더 혼란
--    스럽기 때문). p_target_status='pending' 은 검사하지 않는다 — 아직 실제 송금이
--    일어나지 않았고, 나중에 단건 mark_settlement_paid 처리 시 그 함수가 같은 검사를
--    이미 하고 있다. 막힌 건수는 skipped_no_paypal_count 로 반환해 관리자가 "몇 건이
--    빠졌는지" 알 수 있게 한다 — 배치 전체를 실패시키지 않는다.
-- ============================================================
DROP FUNCTION IF EXISTS public.register_past_settlements(uuid[], text, text);

CREATE FUNCTION public.register_past_settlements(
  p_application_ids uuid[],
  p_target_status   text,
  p_memo            text
)
RETURNS TABLE (
  registered_count         integer,
  skipped_no_paypal_count  integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registered        integer := 0;
  v_skipped_no_paypal integer := 0;
  v_memo              text;
  v_cutoff            timestamptz;
BEGIN
  -- ── 권한 게이트: settlement.pay 최소 write (300 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 목표 상태 검증: paid | pending 만 허용 (300 과 동일) ──
  IF p_target_status NOT IN ('paid', 'pending') THEN
    RAISE EXCEPTION 'invalid_target_status: paid 또는 pending 만 허용됩니다 (입력값: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  IF p_application_ids IS NULL OR array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'empty_application_ids: 처리할 응모를 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  v_memo := COALESCE(NULLIF(btrim(p_memo), ''), '과거 이관 (수동 처리)');

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  WITH targets AS (
    -- ── 서버 재검증(300 원칙 유지) + [324, H-5] cert_at 함께 조회 ──
    SELECT c.application_id, c.influencer_id, c.campaign_id,
           c.amount_jpy, c.amount_source, c.reward_part_jpy,
           c.receipt_amount_jpy, c.amount_cap_jpy, c.cert_at, c.paypal_email,
           -- [324, H-4] 이 건의 페이팔 등록 여부 — 아래에서 paid 목표일 때만 사용.
           (NULLIF(btrim(c.paypal_email), '') IS NULL) AS no_paypal
    FROM public._settlement_cert_candidates() c
    WHERE c.application_id = ANY(p_application_ids)
      AND c.is_success
      AND c.amount_issue IS NULL
      -- 명시적 컷오프 필터(300 조회와 동일) — 컷오프 이후 신규건은 자동 백필 대상이라
      -- 수동 무알림 처리에서 제외.
      AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff)
  ),
  blocked AS (
    -- [324, H-4] "송금완료로 만드는데 페이팔이 없는" 건 — 이 배치에서 제외.
    SELECT * FROM targets WHERE p_target_status = 'paid' AND no_paypal
  ),
  eligible AS (
    -- pending 목표는 페이팔 유무와 무관하게 전부 통과(아직 실제 송금이 일어나지
    -- 않았으므로). paid 목표는 페이팔이 있는 건만 통과.
    SELECT * FROM targets WHERE NOT (p_target_status = 'paid' AND no_paypal)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, cert_at,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id,
      t.amount_jpy, t.amount_source, t.reward_part_jpy,
      t.receipt_amount_jpy, t.amount_cap_jpy, t.cert_at,
      p_target_status,
      NULLIF(t.paypal_email, ''),
      CASE WHEN p_target_status = 'paid' THEN now()      ELSE NULL END,
      CASE WHEN p_target_status = 'paid' THEN auth.uid() ELSE NULL END,
      v_memo
    FROM eligible t
    -- 동시 처리 경쟁 방지(이중 방어 — 300 과 동일).
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행.
    -- ⚠️ notifications INSERT 는 여기 없음(233 「알림 없음」 원칙 그대로 — 의도적).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, p_target_status, auth.uid(), v_memo
    FROM inserted
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM blocked)
  INTO v_registered, v_skipped_no_paypal;

  RETURN QUERY SELECT v_registered, v_skipped_no_paypal;
END;
$$;

COMMENT ON FUNCTION public.register_past_settlements(uuid[], text, text) IS
  '[324 재정의, 300 원본 대체(반환 컬럼 1개 추가: skipped_no_paypal_count, cert_at 저장 추가)] '
  '금액을 _settlement_cert_candidates() 헬퍼가 계산한 값으로 저장, [324, H-5] cert_at(인증 성공 '
  '시점)도 함께 저장. amount_issue 가 있는 건은 서버가 조용히 skip(예외 아님). [324, H-4] '
  'p_target_status=''paid'' 로 등록할 때 PayPal 이메일이 없는 건은 이 배치에서 제외하고 '
  'skipped_no_paypal_count 로 반환(부분 성공 — 배치 전체를 실패시키지 않음). '
  'p_target_status=''pending'' 은 PayPal 유무를 검사하지 않음(단건 mark_settlement_paid, 241 '
  '이 나중에 같은 검사를 함). settlement_paid/settlement_paypal_required 알림 둘 다 발행하지 '
  '않는 233 원칙 그대로 유지. 나머지(재검증·멱등·컷오프 필터·paid 분기 시 paid_at/paid_by·'
  '이력 기록·권한 게이트)는 300 그대로.';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text) TO authenticated;

-- 이 절 롤백: DROP FUNCTION IF EXISTS public.register_past_settlements(uuid[], text, text);
--   이어서 300_settlement_amount_receipt_basis.sql 의 "4. register_past_settlements()
--   재정의" CREATE OR REPLACE 블록을 CREATE FUNCTION 으로 바꿔 재실행
--   (300 원본은 반환 타입이 integer 라 OR REPLACE 가 안 먹으면 먼저 위 DROP 을 실행할 것).

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 조각별로 1단계씩 실행 — 결과 확인 후 다음으로)
--   ⚠️ SQL Editor 세션은 auth.uid() 가 NULL 이라 has_permission()/is_campaign_admin() 게이트가
--   있는 함수는 이 안내 그대로는 permission_denied 가 난다. 274/301/302 와 동일하게
--   "request.jwt.claims 로 관리자 계정을 흉내내는" 방식([V-ADMIN] 참고)을 먼저 실행해 둘 것.
-- ============================================================
/*

-- [V0] 함수·컬럼 재정의 확인 (5개 전부)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'update_receipt_admin', 'backfill_settlements',
    'get_past_unregistered_settlements', 'register_past_settlements'
  );

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'settlements' AND column_name = 'cert_at';


-- [V-ADMIN] 관리자 계정 하나 확보(이후 흉내낼 대상) — campaign_admin 이상
SELECT auth_id, name, role FROM public.admins
 WHERE role IN ('super_admin', 'campaign_admin') LIMIT 3;


-- ═══════════════ H-1 검증 (update_receipt_admin) ═══════════════

-- [V1-1] 방문형(visit) 또는 시딩(gifting) 정산이 pending 인 응모 + 그 응모의 영수증
--   ("현장 사진" 등, kind='receipt') 1건 확보.
SELECT s.id AS settlement_id, s.status, s.amount_jpy, s.amount_source, c.recruit_type,
       d.id AS deliverable_id, d.purchase_amount
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending' AND c.recruit_type IN ('gifting', 'visit')
 LIMIT 5;
-- 해당 건이 없으면(운영 실측상 흔치 않을 수 있음) 이 검증은 개발 DB에 시딩/방문형
-- receipt 행을 하나 임시로 만들어 두고 진행할 것(테스트 후 정리).

-- [V1-2] [V1-1] 의 deliverable_id 를 관리자 흉내내기로 수정 시도(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V1-1 의 deliverable_id>'::uuid, '현장확인', '2026-08-01'::date, null
  );
  -- 기대: settlement_status='pending'(그대로), settlement_recalculated=false,
  --       settlement_amount_jpy = [V1-1] 의 원래 amount_jpy 그대로,
  --       settlement_amount_issue=NULL (자동 보류로 잠기지 않아야 함)
ROLLBACK;

-- [V1-3] 리뷰어형(monitor) 회귀 확인 — 기존처럼 재계산이 그대로 되는지(302 때와 동일 기대값)
SELECT s.id AS settlement_id, s.status, s.amount_jpy, c.recruit_type,
       d.id AS deliverable_id, d.purchase_amount
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending' AND c.recruit_type = 'monitor'
 LIMIT 5;
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<위 deliverable_id>'::uuid, null, null, 1234
  );
  -- 기대: settlement_recalculated=true, settlement_amount_jpy=1234(또는 상한 이하)
ROLLBACK;


-- ═══════════════ H-3 검증 (get_past_unregistered_settlements) ═══════════════

-- [V3-1] 적용 전 스냅샷 — "컷오프 이후 + amount_issue 있음" 건이 실제로 있었는지
--   (postgres 소유자 role 로 실행 권장 — _settlement_cert_candidates 는 private)
SELECT count(*) AS gap_count
FROM public._settlement_cert_candidates() c
WHERE c.is_success AND c.amount_issue IS NOT NULL
  AND c.cert_at IS NOT NULL
  AND c.cert_at >= (SELECT cutoff_at FROM public.settlement_settings WHERE id = 1);
-- ⚠️ 운영은 cutoff_at 이 NULL 이라 이 쿼리 자체가 0건일 가능성이 높다(컷오프가 없으면
-- "컷오프 이후"라는 개념이 성립하지 않음 — is_pre_cutoff 계산에서도 컷오프 NULL 이면
-- 전부 true 로 취급). 개발 DB 에서 cutoff_at 을 임시로 과거 날짜로 세팅해 재현할 수 있다:
--   UPDATE public.settlement_settings SET cutoff_at = now() - interval '365 days' WHERE id=1;
-- (검증 후 반드시 원래 값으로 되돌릴 것 — 운영에 반영되는 값이 아니라 개발 DB 한정)

-- [V3-2] 이 마이그레이션 적용 전/후 "과거 미등록" 반환 건수 비교(H-3 의 요구사항 —
--   "건수로 확인"). 흉내내기 필요(has_permission 게이트).
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT count(*) AS total,
         count(*) FILTER (WHERE is_pre_cutoff) AS pre_cutoff_cnt,
         count(*) FILTER (WHERE NOT is_pre_cutoff) AS newly_exposed_by_324_cnt
  FROM public.get_past_unregistered_settlements();
  -- newly_exposed_by_324_cnt 가 이 마이그레이션이 "과거 미등록" 목록에 새로 추가한
  -- 건수다. [V3-1] 의 gap_count 와 같아야 한다.
ROLLBACK;  -- 조회만 하므로 실제로는 커밋해도 데이터 변경 없음, 습관적으로 ROLLBACK


-- ═══════════════ H-4 검증 (register_past_settlements) ═══════════════

-- [V4-1] PayPal 미등록인 "과거 미등록" 후보 확보
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT application_id, has_paypal, amount_issue
  FROM public.get_past_unregistered_settlements()
  WHERE has_paypal = false AND amount_issue IS NULL
  LIMIT 3;
ROLLBACK;

-- [V4-2] [V4-1] 의 application_id 로 'paid' 목표 일괄 등록 시도(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.register_past_settlements(
    ARRAY['<V4-1 의 application_id>']::uuid[], 'paid', '테스트'
  );
  -- 기대: registered_count=0, skipped_no_paypal_count=1
  SELECT count(*) FROM public.settlements WHERE application_id = '<V4-1 의 application_id>';
  -- 기대: 0 (등록되지 않았어야 함)
ROLLBACK;

-- [V4-3] 같은 건을 'pending' 목표로는 정상 등록되는지(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.register_past_settlements(
    ARRAY['<V4-1 의 application_id>']::uuid[], 'pending', '테스트'
  );
  -- 기대: registered_count=1, skipped_no_paypal_count=0
ROLLBACK;


-- ═══════════════ H-5 검증 (cert_at 저장) ═══════════════

-- [V5-1] register_past_settlements 로 실제 커밋 후 cert_at 이 채워지는지(신중 — 실제
--   반영, 필요 시에만 실행. 테스트용 application_id 로 진행 권장)
-- BEGIN;
--   SELECT set_config('request.jwt.claims', json_build_object('sub','<V-ADMIN 의 auth_id>')::text, true);
--   SELECT * FROM public.register_past_settlements(ARRAY['<application_id>']::uuid[], 'pending', '테스트');
-- COMMIT;
-- SELECT id, application_id, cert_at, created_at FROM public.settlements WHERE application_id = '<application_id>';
-- -- 기대: cert_at IS NOT NULL 이고 created_at 과 다른 시각(인증 성공 시점 ≠ 등록 시점)

-- [V5-2] 기존 행(324 적용 이전 생성)은 cert_at 이 NULL 로 남아 있는지(백필 안 함 확인)
SELECT count(*) AS total, count(*) FILTER (WHERE cert_at IS NULL) AS cert_at_null_cnt
FROM public.settlements;
-- 기대: cert_at_null_cnt > 0 (기존 행은 전부 NULL) — 이 마이그레이션은 과거 행을 건드리지 않는다


-- ═══════════════ H-8 검증 (알림 중복 발송 차단) ═══════════════

-- [V8-1] 정산 인플루언서 공개 스위치를 잠깐 켜서(개발 DB 한정 — 검증 후 반드시 원복)
--   실제 알림 INSERT 를 확인. 운영에서는 이 단계를 건너뛸 것(공개 전이므로 알림이
--   원래도 안 나간다 — v_notify=false 로 notif_candidates 자체가 0건).
-- UPDATE public.settlement_settings SET influencer_visible = true WHERE id = 1;  -- ⚠️개발 DB만

-- [V8-2] PayPal 미등록 인플루언서의 응모 2건을 같은 backfill 호출에서 함께 새로
--   등록되게 만들 수 있으면(예: 컷오프를 그 두 응모의 cert_at 이전으로 임시 조정)
--   backfill_settlements() 를 1회 호출한 뒤:
SELECT count(*) FROM public.notifications
WHERE kind = 'settlement_paypal_required'
  AND created_at > now() - interval '5 minutes';
-- -- 같은 인플루언서에게 2건이 아니라 1건만 나갔는지 user_id 기준으로 확인:
SELECT user_id, count(*) FROM public.notifications
WHERE kind = 'settlement_paypal_required' AND created_at > now() - interval '5 minutes'
GROUP BY user_id HAVING count(*) > 1;
-- 기대: 0 rows (같은 배치에서 인플루언서 1명당 여러 건이 나가면 안 됨)

-- [V8-3] 개발 DB 원복(⚠️ 운영에는 절대 실행 금지 — 정산 공개는 별도 결정 사항)
-- UPDATE public.settlement_settings SET influencer_visible = false WHERE id = 1;

*/

-- ============================================================
-- 전체 롤백(다섯 절을 한꺼번에 원복) — 역순으로 각 절 하단의 개별 롤백을 실행
-- ============================================================
-- 1) register_past_settlements: DROP 후 300 원본(CREATE FUNCTION 형태로) 재실행
-- 2) get_past_unregistered_settlements: DROP 후 300 원본 재실행
-- 3) backfill_settlements: 300 원본 CREATE OR REPLACE 재실행
-- 4) update_receipt_admin: 302 원본 CREATE FUNCTION(DROP 포함) 재실행
-- 5) ALTER TABLE public.settlements DROP COLUMN IF EXISTS cert_at;
-- 각 단계 SQL 원문은 파일 상단 각 절의 "이 절 롤백" 참고. 순서를 지킬 것
-- (함수 → 마지막에 컬럼, 함수가 그 컬럼을 참조하므로 역순으로 제거).
