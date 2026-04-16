-- ============================================================
-- migration: 041_add_image_crops
-- purpose  : 캠페인 이미지 크롭 정보를 좌표만 저장 (비파괴)
--            원본 이미지는 그대로 Supabase Storage에 유지
--            image_crops = {img1: {x,y,w,h}, img2: {x,y,w,h}, ...}
--            x/y/w/h 는 원본 대비 0~1 정규화 값
--
-- rollback:
--   ALTER TABLE campaigns DROP COLUMN image_crops;
-- ============================================================

ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS image_crops jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN campaigns.image_crops IS
  '이미지별 크롭 영역(0~1 정규화). 예: {"img1": {"x":0.1,"y":0,"w":0.8,"h":1}}. 비파괴 — 원본 이미지는 유지.';
