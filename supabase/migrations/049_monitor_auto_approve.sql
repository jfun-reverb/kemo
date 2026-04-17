-- ============================================================
-- 049_monitor_auto_approve.sql
-- 리뷰어(monitor) 캠페인: 신청 시 자동 승인 (status='approved')
--
-- 비즈니스 정책: 리뷰어 캠페인은 신청 심사 불필요.
-- 모집인원 내 신청 → 즉시 승인 → 결과물 제출 → 검수만 수행.
-- 기프팅/방문형은 기존대로 pending → 관리자 수동 심사.
--
-- 트리거 실행 순서 (BEFORE INSERT, 이름 알파벳순):
--   1. trg_monitor_auto_approve (이 트리거) — status를 'approved'로 변경
--   2. trg_monitor_slots_guard  (048) — 정원 초과 시 INSERT 차단
--
-- rollback:
--   DROP TRIGGER IF EXISTS trg_monitor_auto_approve ON applications;
--   DROP FUNCTION IF EXISTS auto_approve_monitor();
-- ============================================================

CREATE OR REPLACE FUNCTION auto_approve_monitor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type text;
BEGIN
  SELECT recruit_type INTO v_recruit_type
    FROM public.campaigns
   WHERE id = NEW.campaign_id;

  IF v_recruit_type = 'monitor' THEN
    NEW.status := 'approved';
    NEW.reviewed_by := '自動承認';
    NEW.reviewed_at := now();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_monitor_auto_approve ON applications;
CREATE TRIGGER trg_monitor_auto_approve
  BEFORE INSERT ON applications
  FOR EACH ROW
  EXECUTE FUNCTION auto_approve_monitor();
