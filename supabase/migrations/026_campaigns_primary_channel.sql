-- ============================================
-- campaigns.primary_channel — 최소 팔로워수 기준 채널 (단일)
-- ============================================
-- 기존 OR 방식(선택 채널 중 1개라도 충족) → 기준 채널 단일 방식으로 변경
-- 캠페인에 선택된 채널 중 1개를 "팔로워수 검증 기준 채널"로 지정

ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS primary_channel text;

COMMENT ON COLUMN campaigns.primary_channel IS
  '최소 팔로워수 검증 기준 채널 코드 (channel 컬럼에 포함된 값 중 하나). NULL이면 첫 번째 채널로 폴백';

-- 기존 캠페인 마이그레이션: min_followers > 0 인 캠페인은 첫 번째 채널을 기준으로 지정
UPDATE campaigns
   SET primary_channel = split_part(channel, ',', 1)
 WHERE primary_channel IS NULL
   AND channel IS NOT NULL
   AND channel <> ''
   AND COALESCE(min_followers, 0) > 0;
