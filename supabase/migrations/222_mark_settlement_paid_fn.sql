-- ============================================================
-- 222_mark_settlement_paid_fn.sql
-- 인플루언서 정산 관리 PR2 — 2/3 (송금 완료 처리 RPC)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §5, §7-1
--
-- mark_settlement_paid(p_settlement_id, p_version, p_memo) — 관리자가 정산 화면에서
-- "송금 완료" 처리할 때 호출. dev/lib/storage.js 의 markSettlementPaid() 가 이미
-- PR1에서 이 시그니처(p_settlement_id/p_version/p_memo, RETURNS integer)로 미리
-- 정의돼 있다 — 반드시 그대로 맞출 것(화면 쪽 재수정 불필요가 PR1의 설계 의도).
--
-- 반환 규칙(결과물 검수 update_deliverable_status, 마이그레이션 035 컨벤션 그대로 계승):
--   - 정상 처리: 갱신 후 새 version(양의 정수) 반환
--   - 낙관적 락 충돌(다른 관리자가 먼저 처리): -1 반환 (예외 아님 — 클라이언트가
--     "다른 관리자가 이미 처리했습니다" 토스트 후 재조회하는 기존 패턴과 동일)
--   - 권한 없음/대상 없음/상태 전이 불가/PayPal 미등록: RAISE EXCEPTION (화면이 막아야
--     정상인 상황이라 -1 이 아닌 명시적 에러로 구분)
--
-- 상태 전이 매트릭스(PR2 전체, 마이그레이션 222/223 공통 — 하나의 표로 참고):
--   ┌─────────────┬───────────────────────────────┬──────────────────┐
--   │ 현재 status │ 허용되는 다음 status            │ 처리 RPC          │
--   ├─────────────┼───────────────────────────────┼──────────────────┤
--   │ pending     │ paid / on_hold / cancelled     │ 222 / 223 / 223  │
--   │ paid        │ on_hold                        │ 223(hold)        │
--   │ on_hold     │ cancelled                      │ 223(cancel)      │
--   │ cancelled   │ (없음 — 최종 상태)               │ —                │
--   └─────────────┴───────────────────────────────┴──────────────────┘
--   ※ paid → cancelled 직접 전이는 금지(먼저 on_hold 로 보내야 함, 223 참고).
--   ※ pending → pending 복귀(revert)는 PR2 범위 밖(settlement_events.action='revert' 는
--     이번에 실제로 INSERT 하는 경로가 없음 — 향후 PR 예약값).
--
-- 권한: has_permission('settlement.pay','write') — campaign_admin=write,
--   campaign_manager=hidden(마이그레이션 220 시드) 이므로 campaign_manager 호출은
--   42501 로 차단.
--
-- PayPal 최신값 재조회(중요): settlements.paypal_email 은 backfill_settlements() 생성
--   시점 스냅샷(217 주석)이라 이후 인플루언서가 PayPal 을 등록/변경했을 수 있다. 이
--   함수는 SECURITY DEFINER 라 influencers 마스킹 뷰(212/213)를 우회해 원본 테이블에서
--   송금 시점 최신값을 재조회 후 settlements.paypal_email 을 그 값으로 덮어써
--   저장한다(217 COMMENT "송금 처리 시 최신값으로 갱신 가능" 그대로 구현).
--
-- ⚠️ 스펙에 명시되지 않은 추가 안전장치(요청 범위를 벗어나므로 검토 필요 — 요약 참고):
--   재조회한 PayPal 이메일이 비어있으면 송금 처리 자체를 차단한다(RAISE EXCEPTION).
--   "송금할 주소가 없는데 상태만 paid 로 바뀌는" 감사 공백을 막기 위함이나, 화면의
--   송금 확인 모달(PayPal·금액·건수 표시)이 이미 이 상황을 걸러낼 수도 있어 중복
--   방어일 수 있다 — 메인 세션/사용자 확인 필요.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.mark_settlement_paid(
  p_settlement_id uuid,
  p_version       integer,
  p_memo          text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row          record;
  v_paypal_fresh text;
  v_new_version  integer;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──────────────────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, status, version, influencer_id
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) ─────────────────────────
  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  -- ── 상태 전이 검증: pending 만 송금 처리 가능 ───────────────────
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '정산 대기(pending) 상태만 송금 처리할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- ── PayPal 최신값 재조회(마스킹 뷰 우회 — DEFINER 원본 테이블 직접 조회) ──────
  SELECT NULLIF(btrim(paypal_email), '') INTO v_paypal_fresh
    FROM public.influencers
   WHERE id = v_row.influencer_id;

  IF v_paypal_fresh IS NULL THEN
    RAISE EXCEPTION 'PayPal 이메일이 등록되지 않아 송금 처리할 수 없습니다 (인플루언서: %)', v_row.influencer_id
      USING ERRCODE = '22023';
  END IF;

  -- ── settlements UPDATE ──────────────────────────────────────
  UPDATE public.settlements
     SET status       = 'paid',
         paid_at      = now(),
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  -- ── settlement_events 감사 이력 ─────────────────────────────
  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  -- ── 인플루언서 알림(일본어 — 초등학생 눈높이, ui.md 컨벤션) ─────────
  INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
  VALUES (
    v_row.influencer_id, 'settlement_paid', 'settlements', p_settlement_id,
    '報酬のお振込みが完了しました',
    'キャンペーンの報酬をPayPalにお振込みしました。マイページの「報酬・お支払い」からご確認ください。'
  );

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text) IS
  '[222] 관리자가 정산(settlements) 1건을 송금 완료 처리하는 RPC. SECURITY DEFINER, '
  'has_permission(''settlement.pay'',''write'') 게이트. pending→paid 만 허용, 낙관적 락 '
  '충돌 시 -1 반환(예외 아님). 송금 시점 influencers.paypal_email 최신값 재조회 후 갱신. '
  'settlement_events 감사 이력 + settlement_paid 알림 발행.';

REVOKE ALL ON FUNCTION public.mark_settlement_paid(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_paid(uuid, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'mark_settlement_paid';

-- [V1] 스모크 대상 1건 확보 (pending 상태 + 인플루언서 paypal_email 등록된 행)
SELECT s.id, s.status, s.version, s.influencer_id, i.paypal_email
FROM public.settlements s
JOIN public.influencers i ON i.id = s.influencer_id
WHERE s.status = 'pending' AND i.paypal_email IS NOT NULL AND btrim(i.paypal_email) <> ''
LIMIT 5;

-- [V2] 스모크 호출 (앱에서 campaign_admin 로그인 세션으로 — SQL Editor 직접 실행은
--   auth.uid() 가 NULL 이라 permission_denied 로 막힐 수 있음, 정상 동작)
-- SELECT public.mark_settlement_paid('<위 id>'::uuid, <위 version>, '스모크 테스트');

-- [V3] 처리 후 확인 — status='paid', settlement_events 1행(action='pay'), 알림 1건
SELECT status, paid_at, paid_by, paypal_email, memo, version FROM public.settlements WHERE id = '<위 id>';
SELECT * FROM public.settlement_events WHERE settlement_id = '<위 id>' ORDER BY at DESC;
SELECT * FROM public.notifications WHERE kind = 'settlement_paid' AND ref_id = '<위 id>';

-- [V4] 낙관적 락 충돌 확인 — 이미 처리된(version 바뀐) 건에 옛 version 으로 재호출 시 -1
-- SELECT public.mark_settlement_paid('<위 id>'::uuid, <옛 version>, null);  -- 기대: -1

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.mark_settlement_paid(uuid, integer, text);
