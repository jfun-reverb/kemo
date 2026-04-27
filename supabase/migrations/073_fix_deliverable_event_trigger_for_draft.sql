-- ============================================================
-- 073_fix_deliverable_event_trigger_for_draft.sql
-- deliverables 상태 변경 트리거에서 draft↔pending 전이 정상 처리
-- 작성일: 2026-04-27
-- ============================================================
-- 배경:
--   migration 035 의 record_deliverable_status_event() 트리거는
--   다음 6개 전이만 분기 처리한다:
--     pending↔approved, pending↔rejected,
--     approved↔rejected, rejected→pending(resubmit)
--   migration 042 에서 draft 상태가 추가됐는데, 트리거의 CASE 문에
--   draft↔pending 분기가 없어 ELSE 'revert' 로 떨어진다. 이 결과
--   from_status='draft' 로 deliverable_events INSERT를 시도하지만
--   035 의 from_status_check CHECK 제약은 ('pending','approved','rejected')
--   만 허용 → CHECK 위반으로 UPDATE 자체가 ROLLBACK 된다.
--
--   현장 영향:
--   - 인플루언서가 활동관리에서 "管理者へ提出" 버튼 클릭 시
--     submitDrafts() 의 UPDATE 가 트리거에서 RAISE EXCEPTION
--     → 클라이언트는 0 row 반환으로 인지 → "提出する項目がありません"
--     토스트 → 인플루언서가 영원히 제출 불가 상태에 갇힘
--   - 운영자가 SQL Editor 에서 강제 UPDATE 시도 시도 동일 위반
--     ("violates check constraint deliverable_events_from_status_check")
--   - 결과물 5건이 draft 로 멈춰 있었음 (2026-04-27 운영 사고)
--
-- 정책:
--   draft 가 OLD 또는 NEW 어느 쪽이든 등장하면 트리거에서 events
--   기록을 건너뛴다. submit 이벤트는 기존대로 submit_deliverable()
--   RPC 가 별도 INSERT 한다 (035 #9).
--
-- 영향:
--   - record_deliverable_status_event() 함수 본문만 교체 (CREATE OR REPLACE)
--   - 트리거 자체(trg_deliverable_status_event) 재정의 없음
--   - deliverable_events CHECK 제약 변경 없음 (draft 는 events 에 안 들어감)
--   - submit_deliverable() RPC 변경 없음
--
-- 롤백:
--   035 의 원본 함수 정의로 되돌리려면 035 의 record_deliverable_status_event
--   본문 그대로 CREATE OR REPLACE.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.record_deliverable_status_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_action text;
BEGIN
  -- 상태가 변하지 않으면 이벤트 기록 안 함
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- draft 가 관련된 전이는 트리거에서 events 기록을 건너뜀.
  --   draft → pending (인플루언서 제출): submit_deliverable() RPC 가 별도로 'submit' 이벤트 INSERT
  --   draft → 그 외 또는 그 외 → draft : 운영상 발생 안 함 (042 RLS 가 status 전이 제한)
  -- 035 의 deliverable_events.from_status / to_status CHECK 제약이 'draft' 를 허용하지 않으므로
  -- 여기서 INSERT 시도하면 위반된다 → 분기 자체를 차단.
  IF OLD.status = 'draft' OR NEW.status = 'draft' THEN
    RETURN NEW;
  END IF;

  -- 액션 결정 (035 의 분기 그대로 보존)
  v_action := CASE
    WHEN OLD.status = 'pending'   AND NEW.status = 'approved'  THEN 'approve'
    WHEN OLD.status = 'pending'   AND NEW.status = 'rejected'  THEN 'reject'
    WHEN OLD.status = 'approved'  AND NEW.status = 'pending'   THEN 'revert'
    WHEN OLD.status = 'rejected'  AND NEW.status = 'pending'   THEN 'resubmit'
    WHEN OLD.status = 'approved'  AND NEW.status = 'rejected'  THEN 'reject'
    WHEN OLD.status = 'rejected'  AND NEW.status = 'approved'  THEN 'approve'
    ELSE 'revert'
  END;

  INSERT INTO public.deliverable_events (
    deliverable_id,
    actor_id,
    action,
    from_status,
    to_status,
    reason,
    metadata
  ) VALUES (
    NEW.id,
    auth.uid(),
    v_action,
    OLD.status,
    NEW.status,
    NEW.reject_reason,
    jsonb_build_object('version_before', OLD.version, 'version_after', NEW.version)
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_deliverable_status_event() IS
  '결과물 상태 변경 이벤트 자동 기록. draft↔pending 전이는 submit_deliverable RPC 가 별도 처리하므로 트리거에서 건너뜀 (073).';

COMMIT;

-- ============================================================
-- 검증 (적용 후)
-- ============================================================
-- [1] 함수 본문 확인 (draft 분기가 들어갔는지)
-- SELECT pg_get_functiondef('public.record_deliverable_status_event'::regproc);
--
-- [2] 시연 — draft 결과물 1건을 pending 으로 직접 UPDATE 가능해야 함
-- (사고 당시처럼 SQL Editor 에서 트리거 우회 없이 UPDATE 가 통과되어야 정상)
-- ============================================================
