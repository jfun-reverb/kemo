-- ============================================================
-- 224_settlement_revert_fn.sql
-- 인플루언서 정산 관리 — 보류 해제(revert) RPC
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §5, §7-1
--
-- mark_settlement_revert(p_settlement_id, p_version, p_memo) RETURNS integer
--
-- 배경: 마이그레이션 222·223 의 상태 전이표에는 on_hold(보류) 에서 갈 수 있는 다음
--   상태가 cancelled(취소) 뿐이라, 보류한 건을 다시 정산 대상으로 되돌릴 경로가
--   없었다(223 상단 주석 "on_hold → pending 복귀(revert)는 PR2 범위 밖" 참고).
--   이번 파일이 그 구멍을 메운다. settlement_events.action CHECK 에는 'revert' 값이
--   217 에서 이미 예약돼 있었으므로 CHECK 제약 변경 없이 바로 사용 가능.
--
-- 반환·에러 컨벤션은 마이그레이션 222/223 과 완전히 동일:
--   - 정상 처리: 새 version(양의 정수) 반환
--   - 낙관적 락 충돌(다른 관리자가 먼저 처리): -1 반환 (예외 아님)
--   - 권한 없음/대상 없음/상태 전이 불가: RAISE EXCEPTION
--
-- 갱신된 상태 전이 매트릭스(마이그레이션 222·223 표를 이 파일 기준으로 갱신 — 향후
--   정산 관련 신규 마이그레이션은 이 표를 최신으로 참고할 것):
--   ┌─────────────┬───────────────────────────────┬──────────────────┐
--   │ 현재 status │ 허용되는 다음 status            │ 처리 RPC          │
--   ├─────────────┼───────────────────────────────┼──────────────────┤
--   │ pending     │ paid / on_hold / cancelled     │ 222 / 223 / 223  │
--   │ paid        │ on_hold                        │ 223(hold)        │
--   │ on_hold     │ pending(신규) / cancelled       │ 224(revert)/223  │
--   │ cancelled   │ (없음 — 최종 상태)               │ —                │
--   └─────────────┴───────────────────────────────┴──────────────────┘
--   ※ paid → cancelled 직접 전이는 여전히 금지(먼저 on_hold 로 보내야 함, 223 참고).
--   ※ on_hold → pending 복귀 후 다시 송금 완료(mark_settlement_paid, 222) 또는
--     취소(mark_settlement_cancel, 223)를 선택할 수 있다.
--
-- 권한: has_permission('settlement.pay','write') — 송금/보류/취소 처리와 동일 등급
--   (campaign_admin=write, campaign_manager=hidden, 마이그레이션 220). 보류 해제도
--   상태를 바꾸는 쓰기 동작이라 다른 3개 RPC 와 일관되게 write 로 통일.
--
-- 인플루언서 알림: 없음(요청 명시 — "관리자 내부 처리", 222/223 과 동일 정책).
--
-- 금전 필드 보존: paid_at/paid_by/paypal_email 은 건드리지 않는다. on_hold 가 원래
--   paid 에서 온 경우(마이그레이션 223 "paid→on_hold 전이 시 보존" 참고) pending 복귀
--   시에도 "언제 얼마를 어디로 보냈었는지" 마지막 송금 스냅샷을 유지한다. 이후 다시
--   송금 완료 처리(mark_settlement_paid)를 호출하면 그 함수가 paid_at 등을 새로
--   덮어쓴다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.mark_settlement_revert(
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
    RAISE EXCEPTION 'permission_denied: 정산 보류 해제 권한이 없습니다' USING ERRCODE = '42501';
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

  IF v_row.status <> 'on_hold' THEN
    RAISE EXCEPTION '보류(on_hold) 상태만 해제할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- paid_at/paid_by/paypal_email 은 건드리지 않음 (파일 상단 "금전 필드 보존" 참고)
  UPDATE public.settlements
     SET status  = 'pending',
         memo    = p_memo,
         version = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'revert', v_row.status, 'pending', auth.uid(), p_memo);

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_revert(uuid, integer, text) IS
  '[224] 관리자가 보류(on_hold) 처리된 정산(settlements) 1건을 정산 대기(pending) 로 '
  '되돌리는 RPC. SECURITY DEFINER, has_permission(''settlement.pay'',''write'') 게이트. '
  'on_hold→pending 만 허용, 낙관적 락 충돌 시 -1. paid_at/paid_by/paypal_email 보존. '
  '인플루언서 알림 없음.';

REVOKE ALL ON FUNCTION public.mark_settlement_revert(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_revert(uuid, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'mark_settlement_revert';

-- [V1] 보류 해제 스모크 대상 확보 (on_hold 1건, 없으면 mark_settlement_hold 로 먼저
--   더미 pending 건을 on_hold 로 만들어 둘 것)
SELECT id, status, version FROM public.settlements WHERE status = 'on_hold' LIMIT 5;

-- [V2] 보류 해제 스모크 호출 (앱에서 campaign_admin 로그인 세션으로)
-- SELECT public.mark_settlement_revert('<위 id>'::uuid, <위 version>, '스모크 테스트 보류 해제');
-- 기대: status='pending', settlement_events 1행(action='revert', prev_status='on_hold', next_status='pending')

-- [V3] pending/paid/cancelled 상태에서 호출 시 차단 확인 (on_hold 가 아닌 건에 호출)
-- SELECT public.mark_settlement_revert('<pending 상태 id>'::uuid, <version>, null);
-- 기대: ERROR — "보류(on_hold) 상태만 해제할 수 있습니다..."

-- [V4] 낙관적 락 충돌 확인 (옛 version 으로 재호출 시 -1)
-- SELECT public.mark_settlement_revert('<id>'::uuid, <옛 version>, null);  -- 기대: -1

-- [V5] 보류 해제 후 재송금·재취소 경로 확인 (선택)
-- SELECT public.mark_settlement_paid('<위 id>'::uuid, <V2 반환 version>, null);
-- 또는
-- SELECT public.mark_settlement_cancel('<위 id>'::uuid, <V2 반환 version>, null);

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.mark_settlement_revert(uuid, integer, text);
