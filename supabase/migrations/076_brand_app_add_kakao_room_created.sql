-- 075_brand_app_add_kakao_room_created.sql
-- 2026-04-28
-- 브랜드 서베이 상태에 'kakao_room_created' (카톡방 생성) 추가
-- 파이프라인 순서: new → reviewing → schedule_sent → quoted → orient_sheet_sent
--                 → campaign_registered → paid → kakao_room_created → done / rejected
-- 기존 상태값은 그대로 유지 — 기존 데이터 마이그레이션 불필요

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
    'orient_sheet_sent',
    'campaign_registered',
    'paid',
    'kakao_room_created',
    'done',
    'rejected'
  ));

COMMIT;
