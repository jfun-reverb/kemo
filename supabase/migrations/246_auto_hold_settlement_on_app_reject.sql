-- ============================================================
-- 246_auto_hold_settlement_on_app_reject.sql
-- 반려·취소된 신청의 결과물 검수 자동 제외 + 정산 자동 보류 — PR 2 (1/2, 자동 보류 트리거)
-- 사양서: docs/specs/2026-07-21-rejected-application-deliverable-and-settlement.md §설계 PR 2
--
-- 목적:
--   승인(approved) 됐던 신청이 관리자에 의해 반려(rejected) 되거나 인플루언서 본인이
--   취소(cancelled) 하면, 그 신청에 연결된 정산(settlements) 이 있을 경우
--   status='pending' 인 것만 자동으로 status='on_hold' 로 보류시킨다.
--
-- 발동 조건 (트리거 WHEN 절):
--   OLD.status = 'approved' AND NEW.status IN ('rejected', 'cancelled')
--   — 관리자 미승인(updateAppStatus)·본인 취소(cancel_application RPC)·향후 추가될
--     모든 반려/취소 경로가 applications.status 를 UPDATE 하는 한 이 트리거가
--     자동으로 커버한다(신청 status 변경 트리거로 걸었기 때문).
--   — 기존 trg_application_status_event(마이그레이션 131, AFTER UPDATE OF status)는
--     별개 트리거로 그대로 둔다. 이 트리거는 그 트리거와 독립적으로 병행 실행된다
--     (PostgreSQL은 같은 이벤트에 걸린 여러 AFTER 트리거를 트리거명 알파벳순으로
--     모두 실행 — 서로 다른 목적의 부수효과라 순서 의존성 없음).
--
-- 처리 대상(정산 status 별 분기):
--   pending    → on_hold 로 전이. version+1. memo 는 고정 문구
--                '신청 반려로 자동 보류' 로 덮어쓴다(기존 memo 유실 감수 —
--                자동 보류 사유를 명확히 하는 것이 더 중요하다는 사용자 결정).
--                settlement_events 에 action='hold' 로 감사 이력 1행 INSERT.
--   paid       → 절대 건드리지 않는다(자동 환수 금지 — 이미 송금 완료된 돈을
--                시스템이 자동으로 뒤집지 않는다). 이 상태의 신청은 마이그레이션 247
--                (BEFORE UPDATE 가드 트리거)이 반려 자체를 막으므로, 정상 경로로는
--                이 함수까지 도달하지 않는다. 혹시라도 247 가드를 우회해 도달하더라도
--                이 함수 자체가 paid 를 no-op 처리하므로 이중 방어된다.
--   on_hold    → no-op (이미 보류 상태 — 멱등)
--   cancelled  → no-op (이미 정산 자체가 취소됨)
--   정산 행 없음 → no-op (settlements.application_id UNIQUE, 대응 행 0~1건)
--
-- 인플루언서 노출 정합:
--   notifications INSERT 없음. settlement_events RLS SELECT 는 관리자 전용
--   (has_permission('settlement.view','read')). settlements 본인 조회는
--   influencer_visible=false(마이그레이션 240, 현재 잠금 상태) 라 본인도 조회 0건.
--   → 이 트리거가 발동해도 인플루언서에게 새는 경로 0 (사양서 §의심 3 확인 완료).
--
-- 멱등성:
--   같은 신청이 다시 approved→rejected 로 전이되는 일은 구조상 없다(한 번 rejected/
--   cancelled 가 된 신청이 다시 approved 를 거치지 않고 또 rejected 로 가려면 먼저
--   approved 를 거쳐야 하므로, 매번 이 함수가 재평가된다). pending 조건 WHERE 절
--   덕분에 이미 on_hold/cancelled 인 정산은 재실행돼도 상태 변화 없음(안전).
--
-- RPC 대신 트리거에서 직접 UPDATE+INSERT 하는 이유:
--   기존 mark_settlement_hold RPC(마이그레이션 223)는 has_permission 가드 +
--   낙관적 락 version 인자를 요구한다. 이 트리거는 "신청 상태가 바뀌는 그 순간"
--   자동으로 실행되며 호출 주체(actor)가 관리자일 수도, 본인 취소라면 인플루언서
--   auth.uid() 일 수도 있다 — RPC의 명시적 관리자 권한 게이트와 문맥이 다르다.
--   트리거 자체가 SECURITY DEFINER 라 이미 RLS를 우회하므로, 트리거 함수가
--   직접 UPDATE + INSERT 로 반영한다.
--
-- 감사 구분(사용자 확정 — 데이터베이스 제약 확장 안 함):
--   settlement_events.action CHECK 는 기존 'hold' 값을 그대로 재사용한다
--   (마이그레이션 217에서 이미 CHECK (action IN ('create','pay','hold','cancel','revert'))
--   로 정의돼 있어 확장 불필요). 자동 보류인지 관리자 수동 보류인지는
--   고정 memo 문구 '신청 반려로 자동 보류' 로 구분한다(정산 화면이
--   memo LIKE '%자동 보류%' 로 필터링해 "복원 안내 버튼"을 보여줄 근거로 사용).
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 함수·트리거 생성 확인
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid = 'public.applications'::regclass
--      AND tgname = 'trg_auto_hold_settlement_on_app_reject';
--   -- 기대값: 1 row
--
--   -- [2] 기능 검증 — pending 정산이 걸린 approved 신청을 rejected 로 전이
--   --     UPDATE applications SET status='rejected' WHERE id='<테스트 신청 id>';
--   --     이후 아래 조회:
--   SELECT status, version, memo FROM public.settlements WHERE application_id='<테스트 신청 id>';
--   -- 기대값: status='on_hold', memo='신청 반려로 자동 보류'
--
--   SELECT action, prev_status, next_status, memo FROM public.settlement_events
--    WHERE settlement_id = (SELECT id FROM public.settlements WHERE application_id='<테스트 신청 id>')
--    ORDER BY at DESC LIMIT 1;
--   -- 기대값: action='hold', prev_status='pending', next_status='on_hold'
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_auto_hold_settlement_on_app_reject ON public.applications;
--   DROP FUNCTION IF EXISTS public.auto_hold_settlement_on_app_reject();
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_hold_settlement_on_app_reject()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_settlement record;
BEGIN
  -- 발동 조건 재확인 (WHEN 절과 이중 방어 — 함수가 단독으로 호출돼도 안전)
  IF OLD.status <> 'approved' OR NEW.status NOT IN ('rejected', 'cancelled') THEN
    RETURN NEW;
  END IF;

  SELECT id, status, version
    INTO v_settlement
    FROM public.settlements
   WHERE application_id = NEW.id
   FOR UPDATE;

  -- 정산 행 자체가 없으면 아무 것도 하지 않음(no-op)
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- pending 만 자동 보류. paid/on_hold/cancelled 는 건드리지 않음(파일 상단 설명 참고)
  IF v_settlement.status = 'pending' THEN
    UPDATE public.settlements
       SET status  = 'on_hold',
           memo    = '신청 반려로 자동 보류',
           version = version + 1
     WHERE id = v_settlement.id;

    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(), '신청 반려로 자동 보류');
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.auto_hold_settlement_on_app_reject() IS
  '[246] applications.status 가 approved→rejected/cancelled 로 바뀔 때, 연결된 '
  'settlements(정산) 이 pending 이면 on_hold 로 자동 보류한다. paid 는 절대 건드리지 '
  '않음(자동 환수 금지 — 마이그레이션 247 가드가 그 경로 자체를 막음). 인플루언서 '
  '알림 없음(잠금 상태 정합). SECURITY DEFINER — 트리거 전용.';

DROP TRIGGER IF EXISTS trg_auto_hold_settlement_on_app_reject ON public.applications;
CREATE TRIGGER trg_auto_hold_settlement_on_app_reject
  AFTER UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (OLD.status = 'approved' AND NEW.status IN ('rejected', 'cancelled'))
  EXECUTE FUNCTION public.auto_hold_settlement_on_app_reject();
