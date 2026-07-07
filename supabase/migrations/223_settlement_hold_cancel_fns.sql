-- ============================================================
-- 223_settlement_hold_cancel_fns.sql
-- 인플루언서 정산 관리 PR2 — 3/3 (보류·취소 처리 RPC 2종)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §5, §7-1
--
-- mark_settlement_hold(p_settlement_id, p_version, p_memo)   RETURNS integer
-- mark_settlement_cancel(p_settlement_id, p_version, p_memo) RETURNS integer
--
-- 반환·에러 컨벤션은 마이그레이션 222(mark_settlement_paid)와 동일:
--   정상 처리=새 version 반환 / 낙관적 락 충돌=-1 / 그 외는 RAISE EXCEPTION.
--
-- 상태 전이 매트릭스(마이그레이션 222 상단에 이미 기재한 표와 동일 — 재게재):
--   ┌─────────────┬───────────────────────────────┬──────────────────┐
--   │ 현재 status │ 허용되는 다음 status            │ 처리 RPC          │
--   ├─────────────┼───────────────────────────────┼──────────────────┤
--   │ pending     │ paid / on_hold / cancelled     │ 222 / 223 / 223  │
--   │ paid        │ on_hold                        │ 223(hold)        │
--   │ on_hold     │ cancelled                      │ 223(cancel)      │
--   │ cancelled   │ (없음 — 최종 상태)               │ —                │
--   └─────────────┴───────────────────────────────┴──────────────────┘
--   ※ paid → cancelled 직접 전이 금지 — 먼저 mark_settlement_hold 로 on_hold 로
--     보낸 뒤 mark_settlement_cancel 을 호출해야 한다(송금 후 취소는 반드시
--     "보류(환수 검토)" 단계를 거치게 강제 — 사고 방지 의도적 마찰).
--   ※ on_hold → pending 복귀(revert)는 PR2 범위 밖(사용자 확정: "보류·취소 버튼
--     PR2 포함" 에 revert 는 없음). settlement_events.action CHECK 에는 'revert' 값이
--     이미 217에서 예약돼 있으나 이번 파일에서 실제로 그 값을 INSERT 하는 경로는
--     만들지 않는다 — 향후 PR에서 필요해지면 별도 함수로 추가.
--     [224 추가] 이후 실제로 구멍이 확인되어 mark_settlement_revert(224) 로 on_hold →
--     pending 복귀 경로가 추가됨. 위 상태 전이표는 224 갱신 후 기준으로는 stale —
--     최신 표는 224 파일 상단 참고.
--
-- 권한: 두 함수 모두 has_permission('settlement.pay','write') — 송금 처리와 동일
--   권한 등급(campaign_admin=write, campaign_manager=hidden, 마이그레이션 220).
--   "보류·취소는 조회 권한(settlement.view)만 있어도 된다"는 별도 요청이 없었으므로
--   송금 처리와 같은 write 등급으로 통일(둘 다 상태를 바꾸는 쓰기 동작이라 일관).
--
-- 인플루언서 알림: 두 함수 모두 없음(요청 명시 — "관리자 내부 처리"). 인플루언서
--   마이페이지 「報酬・お支払い」 화면(PR3 예정)에서 상태 자체는 조회 가능하지만
--   실시간 알림은 발행하지 않는다.
--
-- 금전 필드 보존: mark_settlement_hold 는 paid_at/paid_by/paypal_email 을 건드리지
--   않는다(paid→on_hold 전이 시 "언제 얼마를 어디로 보냈었는지" 환수 근거 이력을
--   settlements 행 자체에도 남겨두기 위함 — settlement_events 감사 이력과 별개로
--   행 자체의 마지막 송금 스냅샷 보존).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- A. mark_settlement_hold — pending 또는 paid → on_hold
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_settlement_hold(
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
  v_row         record;
  v_new_version integer;
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 보류 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  SELECT id, status, version
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  IF v_row.status NOT IN ('pending', 'paid') THEN
    RAISE EXCEPTION '대기(pending) 또는 송금완료(paid) 상태만 보류할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- paid_at/paid_by/paypal_email 은 건드리지 않음 (파일 상단 "금전 필드 보존" 참고)
  UPDATE public.settlements
     SET status  = 'on_hold',
         memo    = p_memo,
         version = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'hold', v_row.status, 'on_hold', auth.uid(), p_memo);

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_hold(uuid, integer, text) IS
  '[223] 관리자가 정산(settlements) 1건을 보류 처리하는 RPC. pending 또는 paid → on_hold. '
  'SECURITY DEFINER, has_permission(''settlement.pay'',''write'') 게이트. 낙관적 락 충돌 시 -1. '
  'paid→on_hold 전이 시 paid_at/paid_by/paypal_email 은 보존(환수 이력). 인플루언서 알림 없음.';

REVOKE ALL ON FUNCTION public.mark_settlement_hold(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_hold(uuid, integer, text) TO authenticated;

-- ============================================================
-- B. mark_settlement_cancel — pending 또는 on_hold → cancelled
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_settlement_cancel(
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
  v_row         record;
  v_new_version integer;
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 취소 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  SELECT id, status, version
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  IF v_row.status NOT IN ('pending', 'on_hold') THEN
    RAISE EXCEPTION '대기(pending) 또는 보류(on_hold) 상태만 취소할 수 있습니다. 송금완료(paid) 건은 먼저 보류로 전환한 뒤 취소해야 합니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.settlements
     SET status  = 'cancelled',
         memo    = p_memo,
         version = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'cancel', v_row.status, 'cancelled', auth.uid(), p_memo);

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_cancel(uuid, integer, text) IS
  '[223] 관리자가 정산(settlements) 1건을 취소 처리하는 RPC. pending 또는 on_hold → cancelled '
  '(paid 는 직접 취소 불가 — 먼저 mark_settlement_hold 필요). SECURITY DEFINER, '
  'has_permission(''settlement.pay'',''write'') 게이트. 낙관적 락 충돌 시 -1. 인플루언서 알림 없음.';

REVOKE ALL ON FUNCTION public.mark_settlement_cancel(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_cancel(uuid, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인 (2개)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name IN ('mark_settlement_hold', 'mark_settlement_cancel');

-- [V1] 보류 스모크 대상 확보 (pending 또는 paid 1건)
SELECT id, status, version FROM public.settlements WHERE status IN ('pending', 'paid') LIMIT 5;

-- [V2] 보류 스모크 호출 (앱에서 campaign_admin 로그인 세션으로)
-- SELECT public.mark_settlement_hold('<위 id>'::uuid, <위 version>, '스모크 테스트 보류');
-- 기대: status='on_hold', settlement_events 1행(action='hold')

-- [V3] 취소 스모크 호출 (위에서 on_hold 된 건, 또는 별도 pending 건)
-- SELECT public.mark_settlement_cancel('<id>'::uuid, <version>, '스모크 테스트 취소');
-- 기대: status='cancelled', settlement_events 1행(action='cancel')

-- [V4] paid 건 직접 취소 차단 확인 (paid 상태 건에 cancel 호출 시 예외 발생 기대)
-- SELECT public.mark_settlement_cancel('<paid 상태 id>'::uuid, <version>, null);
-- 기대: ERROR — "대기(pending) 또는 보류(on_hold) 상태만 취소할 수 있습니다..."

-- [V5] 낙관적 락 충돌 확인 (옛 version 으로 재호출 시 -1)
-- SELECT public.mark_settlement_hold('<id>'::uuid, <옛 version>, null);  -- 기대: -1

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.mark_settlement_cancel(uuid, integer, text);
-- DROP FUNCTION IF EXISTS public.mark_settlement_hold(uuid, integer, text);
