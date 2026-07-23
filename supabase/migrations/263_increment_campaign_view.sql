-- 263_increment_campaign_view.sql
-- 캠페인 조회수(view_count) 집계 정상화 + 기존 오염 수치 초기화
--
-- 배경 (2026-07-23 발견):
--   조회수 증가를 브라우저가 campaigns 테이블을 직접 UPDATE 하는 방식으로 처리했는데
--   (dev/lib/storage.js incrementViewCount), campaigns 의 UPDATE 정책은
--   campaigns_update_admin = is_admin() 한정(마이그레이션 001)이다.
--   → 인플루언서·비로그인 방문은 행 단위 보안 정책에 막혀 한 건도 기록되지 않았다.
--     .select() 를 붙이지 않은 UPDATE 라 오류조차 나지 않아(0행 처리) 조용히 실패.
--   → 결과적으로 view_count 는 "관리자가 인플루언서 화면에서 캠페인을 연 횟수"만 누적.
--   운영 실측: 캠페인 139개 중 57개가 view_count < applied_count
--             (신청하려면 반드시 상세를 열어야 하므로 논리적으로 불가능),
--             조회수 합계 1595 < 신청 합계 1831, 조회수 0인 캠페인 22개.
--
-- 조치:
--   1. 조회수만 원자적으로 1 올리는 전용 함수 신설 → anon·authenticated 실행 허용.
--      campaigns 테이블의 UPDATE 정책은 그대로 관리자 한정으로 유지(다른 컬럼 보호).
--   2. 집계 대상에서 제외: 관리자(운영 확인용 열람은 방문 지표가 아님) +
--      감사용 계정(is_audit — 마이그레이션 179·181 통계 격리 정책과 동일).
--   3. 기존 오염 수치 전부 0 초기화(사용자 결정 2026-07-23).
--
-- 안전성 메모:
--   - campaigns 의 updated_at 은 트리거가 아니라 updateCampaign() 클라이언트 헬퍼가
--     세팅한다(마이그레이션 066 주석). 따라서 조회수 UPDATE·초기화 UPDATE 모두
--     캠페인 수정일을 오염시키지 않는다.
--   - campaigns 의 BEFORE UPDATE 트리거(trg_block_closed_caution_participation)는
--     주의사항·참여방법·NG 컬럼이 실제로 바뀔 때만 예외를 던지므로 view_count 단독
--     변경은 통과한다. status 관련 트리거 2종은 UPDATE OF status 라 미발화.
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.increment_campaign_view(uuid);
--   (초기화된 view_count 는 복원 불가 — 오염 데이터라 복원 가치 없음)

BEGIN;

-- ══════════════════════════════════════
-- 1) 조회수 증가 전용 함수
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION public.increment_campaign_view(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF p_campaign_id IS NULL THEN
    RETURN;
  END IF;

  IF v_uid IS NOT NULL THEN
    -- 관리자 열람 제외 (운영자가 확인차 여는 것은 방문 지표가 아님)
    IF EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = v_uid) THEN
      RETURN;
    END IF;
    -- 감사용 계정 제외 (운영팀 시뮬레이션 계정 — 179·181 통계 격리와 동일 기준)
    IF EXISTS (
      SELECT 1 FROM public.influencers i
       WHERE i.id = v_uid AND i.is_audit = true
    ) THEN
      RETURN;
    END IF;
  END IF;

  -- 원자적 증가 (읽고→더하고→쓰기 방식의 동시 조회 누락 해소)
  UPDATE public.campaigns
     SET view_count = COALESCE(view_count, 0) + 1
   WHERE id = p_campaign_id
     AND deleted_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.increment_campaign_view(uuid) IS
  '캠페인 상세 조회수 +1. 비로그인·인플루언서가 호출(campaigns UPDATE 정책은 관리자 한정 유지). 관리자·감사용 계정 열람은 집계 제외. 같은 사람의 하루 1회 제한은 클라이언트(storage.js)가 담당.';

REVOKE ALL ON FUNCTION public.increment_campaign_view(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_campaign_view(uuid) TO anon, authenticated;

-- ══════════════════════════════════════
-- 2) 기존 오염 수치 초기화
-- ══════════════════════════════════════
-- 보관 삭제(deleted_at) 된 캠페인 포함 전건 0 으로. 복구 시에도 새 기준으로 집계.
UPDATE public.campaigns
   SET view_count = 0
 WHERE COALESCE(view_count, 0) <> 0;

-- PostgREST schema cache 즉시 재로드 (신규 함수 노출)
NOTIFY pgrst, 'reload schema';

COMMIT;
