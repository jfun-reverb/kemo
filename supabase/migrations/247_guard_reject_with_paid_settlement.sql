-- ============================================================
-- 247_guard_reject_with_paid_settlement.sql
-- 반려·취소된 신청의 결과물 검수 자동 제외 + 정산 자동 보류 — PR 2 (2/2, 송금완료 반려 차단 가드)
-- 사양서: docs/specs/2026-07-21-rejected-application-deliverable-and-settlement.md §설계 PR 2 가드(A)
--
-- 목적:
--   이미 송금완료(settlements.status='paid') 처리된 정산이 걸린 신청은, 관리자가
--   실수로 미승인(반려)·되돌리기 해도 절대 통과되지 않도록 데이터베이스 층에서
--   최종적으로 차단한다. 이미 지급된 돈을 시스템이 조용히 뒤집는 사고를 막는
--   최후 방어선(서버 층). 1차 방어(UI 경고 모달)는 dev/js/admin-applications.js
--   updateAppStatus() 에서 처리 — 이 트리거는 그 UI 층을 우회해 직접 SQL로
--   UPDATE 하는 경우까지 막는 2차 방어선이다.
--
-- 발동 조건 (트리거 WHEN 절):
--   OLD.status = 'approved' AND NEW.status IN ('rejected', 'cancelled', 'pending')
--   — 'rejected'  : 관리자 미승인
--   — 'pending'   : 관리자 되돌리기
--   — 'cancelled' : 관리자 UI에는 진입 버튼이 없지만(본인 취소 전용), 직접 SQL
--                   경로까지 막기 위해 방어적으로 포함(사양서 §현재 상태 확인:
--                   "관리자 UI에는 신청을 cancelled 로 만드는 버튼이 없다" —
--                   그래도 우회 SQL 대비 포함이 안전).
--   — 캠페인 종료 자동 낙첨(마이그레이션 176)은 WHERE status='pending' 인 신청만
--     대상이라 OLD.status='approved' 조건에 걸리지 않음 — 정상 동작에 영향 없음.
--
-- 처리:
--   위 조건에 해당하는 신청(NEW.id)에 status='paid' 인 settlements 행이 1건이라도
--   존재하면 RAISE EXCEPTION 으로 UPDATE 자체를 롤백시킨다(트랜잭션 전체 취소).
--   paid 정산이 없으면 그대로 통과(RETURN NEW).
--
-- BEFORE 트리거인 이유(마이그레이션 246과의 실행 순서):
--   이 트리거는 BEFORE UPDATE, 246(자동 보류)은 AFTER UPDATE. paid 정산이 걸린
--   신청은 이 BEFORE 트리거가 예외를 던져 UPDATE 문 자체가 실패(롤백)하므로,
--   246의 AFTER 트리거까지 도달하지 않는다 — paid 건은 246이 다루는 "pending→
--   on_hold 자동 보류" 로직과 애초에 마주칠 일이 없다(이중 안전).
--
-- 인플루언서 노출 정합:
--   이 트리거는 UPDATE 를 막을 뿐 어떤 테이블에도 INSERT 하지 않는다.
--   notifications 미발행. 인플루언서에게 새는 경로 없음.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 함수·트리거 생성 확인
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid = 'public.applications'::regclass
--      AND tgname = 'trg_guard_reject_with_paid_settlement';
--   -- 기대값: 1 row
--
--   -- [2] 기능 검증 — settlements.status='paid' 인 정산이 걸린 approved 신청을 반려 시도
--   --     UPDATE applications SET status='rejected' WHERE id='<paid 정산 걸린 신청 id>';
--   -- 기대값: ERROR — 'settlement_already_paid: 이미 송금 완료된 정산이 있어...' (트랜잭션 롤백)
--
--   -- [3] paid 정산이 없는 approved 신청은 정상 반려되는지 확인(회귀 없음)
--   --     UPDATE applications SET status='rejected' WHERE id='<paid 정산 없는 신청 id>';
--   -- 기대값: 정상 UPDATE 성공 + 마이그레이션 246 트리거가 pending 정산을 on_hold 로 전이(있다면)
--
--   -- [4] 자동 낙첨(마이그레이션 176, status='pending' 대상)은 영향 없는지 확인
--   --     OLD.status='approved' 조건에 안 걸리므로 정상 동작 — 별도 재현 불필요,
--   --     함수 WHEN 절 조건만 재확인하면 충분.
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_guard_reject_with_paid_settlement ON public.applications;
--   DROP FUNCTION IF EXISTS public.guard_reject_with_paid_settlement();
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_reject_with_paid_settlement()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_paid_count integer;
BEGIN
  -- 발동 조건 재확인 (WHEN 절과 이중 방어 — 함수가 단독으로 호출돼도 안전)
  IF OLD.status <> 'approved' OR NEW.status NOT IN ('rejected', 'cancelled', 'pending') THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_paid_count
    FROM public.settlements
   WHERE application_id = NEW.id
     AND status = 'paid';

  IF v_paid_count > 0 THEN
    RAISE EXCEPTION 'settlement_already_paid: 이미 송금 완료된 정산이 있어 이 신청을 미승인(반려)하거나 되돌릴 수 없습니다. 먼저 정산 관리 화면에서 보류(환수) 처리를 해야 합니다.'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_reject_with_paid_settlement() IS
  '[247] applications.status 가 approved→rejected/cancelled/pending 으로 바뀌려 할 때, '
  '연결된 settlements(정산) 이 paid(송금완료) 이면 UPDATE 자체를 차단(RAISE EXCEPTION). '
  '이미 송금된 돈의 자동 환수를 막는 최후 방어선(서버 층) — UI 층 1차 경고는 '
  'dev/js/admin-applications.js updateAppStatus() 에서 처리. BEFORE 트리거라 마이그레이션 246 '
  '(자동 보류, AFTER 트리거)보다 먼저 실행돼 paid 건은 246 도달 자체가 차단됨. SECURITY DEFINER — 트리거 전용.';

DROP TRIGGER IF EXISTS trg_guard_reject_with_paid_settlement ON public.applications;
CREATE TRIGGER trg_guard_reject_with_paid_settlement
  BEFORE UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (OLD.status = 'approved' AND NEW.status IN ('rejected', 'cancelled', 'pending'))
  EXECUTE FUNCTION public.guard_reject_with_paid_settlement();
