-- ============================================================
-- 050_unique_application_per_campaign.sql
-- 같은 캠페인에 동일 사용자가 중복 신청 방지 (DB 레벨 강제)
--
-- 1. 기존 중복 데이터 정리: 최초 신청 1건만 남기고 나머지 삭제
-- 2. UNIQUE 제약 추가: (user_id, campaign_id)
--
-- rollback:
--   ALTER TABLE applications DROP CONSTRAINT IF EXISTS uidx_applications_user_campaign;
-- ============================================================

BEGIN;

-- 1. 기존 중복 확인 및 정리
-- 각 (user_id, campaign_id) 조합에서 가장 오래된 1건(created_at ASC)만 남기고 삭제
DELETE FROM applications
 WHERE id NOT IN (
   SELECT DISTINCT ON (user_id, campaign_id) id
     FROM applications
    ORDER BY user_id, campaign_id, created_at ASC
 );

-- 2. UNIQUE 제약 추가
ALTER TABLE applications
  ADD CONSTRAINT uidx_applications_user_campaign
  UNIQUE (user_id, campaign_id);

COMMIT;

-- 검증 쿼리:
--   SELECT user_id, campaign_id, COUNT(*)
--     FROM applications
--    GROUP BY user_id, campaign_id
--   HAVING COUNT(*) > 1;
-- → 0건이면 정상
