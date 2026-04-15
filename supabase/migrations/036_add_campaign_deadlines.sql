-- ============================================================
-- migration: 036_add_campaign_deadlines
-- purpose  : 결과물 관리 Stage 1 — 캠페인 타입별 기한 필드 추가
--            - monitor: purchase_start, purchase_end (구매 가능 기간)
--            - visit  : visit_start, visit_end (방문 가능 기간)
--            - all    : submission_end (결과물 제출 마감)
--
-- 기존 deadline(모집 마감)·post_deadline(게시 마감)은 유지.
-- submission_end는 결과물 제출 마감으로 새로 도입한다.
-- 클라이언트는 NULL일 때 post_deadline을 폴백으로 사용할 수 있다.
--
-- 적용 순서:
--   1. 개발 DB (qysmxtipobomefudyixw) 먼저
--   2. 운영 DB (twofagomeizrtkwlhsuv) 적용
--
-- rollback:
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS purchase_start;
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS purchase_end;
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS visit_start;
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS visit_end;
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS submission_end;
-- ============================================================

ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS purchase_start date;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS purchase_end   date;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS visit_start    date;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS visit_end      date;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS submission_end date;

COMMENT ON COLUMN campaigns.purchase_start IS '리뷰어 캠페인 구매 시작일 (monitor 타입 전용).';
COMMENT ON COLUMN campaigns.purchase_end   IS '리뷰어 캠페인 구매 마감일 (monitor 타입 전용).';
COMMENT ON COLUMN campaigns.visit_start    IS '방문형 캠페인 방문 시작일 (visit 타입 전용).';
COMMENT ON COLUMN campaigns.visit_end      IS '방문형 캠페인 방문 마감일 (visit 타입 전용).';
COMMENT ON COLUMN campaigns.submission_end IS '결과물 제출 마감일 (모든 타입 공통, Stage 3부터 필수).';

-- 기간 유효성 체크 (NULL 허용, 둘 다 값이 있을 때만 검증)
ALTER TABLE campaigns
  DROP CONSTRAINT IF EXISTS chk_campaigns_purchase_range;
ALTER TABLE campaigns
  ADD  CONSTRAINT chk_campaigns_purchase_range
       CHECK (purchase_start IS NULL OR purchase_end IS NULL OR purchase_start <= purchase_end);

ALTER TABLE campaigns
  DROP CONSTRAINT IF EXISTS chk_campaigns_visit_range;
ALTER TABLE campaigns
  ADD  CONSTRAINT chk_campaigns_visit_range
       CHECK (visit_start IS NULL OR visit_end IS NULL OR visit_start <= visit_end);
