-- ============================================================
-- migration: 043_add_winner_announce
-- purpose  : 캠페인별 "당선 발표" 문구를 DB에서 관리
--            기본값: 기존 하드코딩 일본어 문구
--            관리자 폼에서 수정 가능
--
-- rollback:
--   ALTER TABLE campaigns DROP COLUMN winner_announce;
-- ============================================================

ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS winner_announce text
  DEFAULT '選考後、LINEにてご連絡';

COMMENT ON COLUMN campaigns.winner_announce IS
  '당선 발표 안내 문구. 관리자 폼에서 캠페인별로 커스터마이즈 가능. 기본값: 선정 후 LINE 연락';
