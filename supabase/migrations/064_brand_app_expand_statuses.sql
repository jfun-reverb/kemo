-- 064_brand_app_expand_statuses.sql
-- 브랜드 서베이 상태값 확장: 일정전달(schedule_sent), 캠페인등록(campaign_registered) 2단계 추가
-- 기존 상태값(new, reviewing, quoted, paid, done, rejected)은 유지 — 기존 데이터 마이그레이션 불필요
-- 전이 순서: new → reviewing → schedule_sent → quoted → campaign_registered → paid → done / rejected

BEGIN;

ALTER TABLE brand_applications
  DROP CONSTRAINT IF EXISTS brand_applications_status_check;

ALTER TABLE brand_applications
  ADD CONSTRAINT brand_applications_status_check
  CHECK (status IN (
    'new',
    'reviewing',
    'schedule_sent',
    'quoted',
    'campaign_registered',
    'paid',
    'done',
    'rejected'
  ));

COMMIT;
