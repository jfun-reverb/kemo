-- ============================================================
-- 048_monitor_slots_guard.sql
-- 리뷰어(monitor) 캠페인: 신청수 >= 모집인원(slots) 시
-- DB 레벨에서 INSERT 차단 (레이스 컨디션 방어)
--
-- 기프팅/방문형은 기존대로 초과 응모 허용.
-- 클라이언트 체크는 UX 보조로 유지, 이 트리거가 최종 방어선.
--
-- rollback:
--   DROP TRIGGER IF EXISTS trg_monitor_slots_guard ON applications;
--   DROP FUNCTION IF EXISTS check_monitor_slots();
-- ============================================================

-- 트리거 함수
CREATE OR REPLACE FUNCTION check_monitor_slots()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type text;
  v_slots        int;
  v_current      int;
BEGIN
  -- FOR UPDATE: 동시 INSERT 시 campaigns 행에 row lock → 레이스 컨디션 방어
  SELECT c.recruit_type, c.slots
    INTO v_recruit_type, v_slots
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id
     FOR UPDATE;

  -- 리뷰어(monitor)가 아니거나 slots 미설정이면 통과
  IF v_recruit_type IS DISTINCT FROM 'monitor' OR COALESCE(v_slots, 0) <= 0 THEN
    RETURN NEW;
  END IF;

  -- 현재 신청수 카운트 (pending + approved — rejected 제외)
  SELECT COUNT(*)
    INTO v_current
    FROM public.applications a
   WHERE a.campaign_id = NEW.campaign_id
     AND a.status IN ('pending', 'approved');

  IF v_current >= v_slots THEN
    RAISE EXCEPTION '모집 정원이 마감되었습니다 (slots: %, current: %)', v_slots, v_current
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- 트리거 (INSERT 전에만 실행)
DROP TRIGGER IF EXISTS trg_monitor_slots_guard ON applications;
CREATE TRIGGER trg_monitor_slots_guard
  BEFORE INSERT ON applications
  FOR EACH ROW
  EXECUTE FUNCTION check_monitor_slots();
