-- ============================================================
-- 058_applied_count_trigger.sql
-- campaigns.applied_count 자동 동기화 트리거
--
-- 배경:
--   applied_count는 수동 캐시로 운영되었으나, 클라이언트의 +1 UPDATE가
--   campaigns RLS(관리자 전용)에 의해 항상 조용히 실패 → 누적 불일치.
--   관리자 삭제/반려 처리 시에도 감소 반영 없었음.
--
-- 해결:
--   applications INSERT/UPDATE(status 변경)/DELETE 시 AFTER 트리거로
--   해당 campaign_id의 applied_count를 재계산(pending+approved 기준).
--   SECURITY DEFINER 함수가 RLS를 우회하여 UPDATE.
--
-- 기준: applied_count = COUNT(*) WHERE status IN ('pending','approved')
--   - rejected 제외 (048_monitor_slots_guard 와 동일 기준)
--   - 전 모집 타입 공통 (monitor 응모 차단 + 카드 표시 모두 이 값 참조)
--
-- rollback:
--   DROP TRIGGER IF EXISTS trg_sync_applied_count ON applications;
--   DROP FUNCTION IF EXISTS public.sync_campaign_applied_count();
--   DROP FUNCTION IF EXISTS public.recompute_campaign_applied_count(uuid);
-- ============================================================


-- ============================================================
-- Step 1: 재계산 헬퍼 함수
--   단일 campaign_id의 applied_count를 현재 applications 집계값으로 UPDATE.
--   SECURITY DEFINER + search_path 고정 (search_path 탈취 방어, 프로젝트 규칙).
-- ============================================================
CREATE OR REPLACE FUNCTION public.recompute_campaign_applied_count(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*)
    INTO v_count
    FROM public.applications
   WHERE campaign_id = p_campaign_id
     AND status IN ('pending', 'approved');

  UPDATE public.campaigns
     SET applied_count = v_count
   WHERE id = p_campaign_id;
END;
$$;

COMMENT ON FUNCTION public.recompute_campaign_applied_count(uuid) IS
  '[058] campaign_id 하나의 applied_count를 applications 집계(pending+approved)로 재계산. SECURITY DEFINER — 트리거 함수에서만 호출.';


-- ============================================================
-- Step 2: 트리거 함수
--   INSERT/UPDATE OF status/DELETE 세 이벤트 모두 처리.
--   UPDATE 시 campaign_id가 변경되는 엣지 케이스 방어:
--     OLD.campaign_id ≠ NEW.campaign_id이면 양쪽 모두 재계산.
--     (현재 UI에서 campaign_id 변경은 없지만 방어적으로 처리)
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_campaign_applied_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.recompute_campaign_applied_count(NEW.campaign_id);

  ELSIF TG_OP = 'UPDATE' THEN
    -- campaign_id가 바뀐 경우: 구 캠페인 + 신 캠페인 모두 재계산
    IF OLD.campaign_id IS DISTINCT FROM NEW.campaign_id THEN
      PERFORM public.recompute_campaign_applied_count(OLD.campaign_id);
    END IF;
    PERFORM public.recompute_campaign_applied_count(NEW.campaign_id);

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.recompute_campaign_applied_count(OLD.campaign_id);

  END IF;

  RETURN NULL; -- AFTER 트리거이므로 반환값 무시됨
END;
$$;

COMMENT ON FUNCTION public.sync_campaign_applied_count() IS
  '[058] applications 변경 시 campaigns.applied_count 자동 동기화 트리거 함수.';


-- ============================================================
-- Step 3: 트리거 등록
--   AFTER: DB 변경이 완료된 후 집계 (BEFORE는 본인 행 포함 여부가 불확실)
--   FOR EACH ROW: 행별 실행 (배치 UPDATE 시에도 각 행 처리)
--   UPDATE OF status: status 컬럼 변경 시에만 발동 (불필요한 재계산 방지)
-- ============================================================
DROP TRIGGER IF EXISTS trg_sync_applied_count ON public.applications;
CREATE TRIGGER trg_sync_applied_count
  AFTER INSERT OR UPDATE OF status OR DELETE
  ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_campaign_applied_count();


-- ============================================================
-- Step 4: 기존 데이터 일괄 보정
--   트리거 생성 후 즉시 전체 캠페인의 applied_count를 현재 applications
--   실제값으로 덮어씌움. 누적된 불일치를 한 번에 해소.
-- ============================================================
UPDATE public.campaigns c
   SET applied_count = (
     SELECT COUNT(*)
       FROM public.applications a
      WHERE a.campaign_id = c.id
        AND a.status IN ('pending', 'approved')
   );


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. 트리거 등록 확인
-- SELECT trigger_name, event_manipulation, action_timing, action_orientation
--   FROM information_schema.triggers
--  WHERE event_object_table = 'applications'
--    AND trigger_name = 'trg_sync_applied_count';
-- 기대: INSERT/UPDATE/DELETE 3건, AFTER, ROW

-- 2. 함수 존재 확인
-- SELECT proname, prosecdef FROM pg_proc
--  WHERE proname IN ('recompute_campaign_applied_count','sync_campaign_applied_count')
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 2건, prosecdef = true

-- 3. 보정 후 불일치 캠페인 수 확인 (0건이어야 정상)
-- SELECT c.id, c.title, c.applied_count AS cached,
--        COUNT(a.id) FILTER (WHERE a.status IN ('pending','approved')) AS actual
--   FROM public.campaigns c
--   LEFT JOIN public.applications a ON a.campaign_id = c.id
--  GROUP BY c.id, c.title, c.applied_count
-- HAVING c.applied_count IS DISTINCT FROM
--        COUNT(a.id) FILTER (WHERE a.status IN ('pending','approved'));

-- 4. 특정 캠페인 값 확인 (CAMP-2026-0030 등 문제 캠페인)
-- SELECT c.campaign_no, c.title, c.applied_count,
--        COUNT(a.id) FILTER (WHERE a.status IN ('pending','approved')) AS actual
--   FROM public.campaigns c
--   LEFT JOIN public.applications a ON a.campaign_id = c.id
--  WHERE c.campaign_no = 'CAMP-2026-0030'
--  GROUP BY c.id;


-- ============================================================
-- 롤백 방법 (필요 시)
-- ============================================================
-- 트리거 + 함수 제거
-- DROP TRIGGER IF EXISTS trg_sync_applied_count ON public.applications;
-- DROP FUNCTION IF EXISTS public.sync_campaign_applied_count();
-- DROP FUNCTION IF EXISTS public.recompute_campaign_applied_count(uuid);
--
-- 주의: 롤백 후 applied_count는 다시 수동 캐시 상태로 돌아감.
--       클라이언트 코드 롤백(+1 UPDATE 재도입)이 필요하면
--       dev/js/application.js:344-346 블록 복원.
