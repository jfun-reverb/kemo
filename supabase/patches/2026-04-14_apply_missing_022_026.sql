-- ============================================
-- 누락된 마이그레이션 022, 026 복구 적용
-- 대상: production DB
-- 작성일: 2026-04-14
-- 안전성: 모든 컬럼이 IF NOT EXISTS로 작성되어 재실행 안전
-- ============================================

-- ---- 022_add_consent_fields ----
ALTER TABLE influencers
  ADD COLUMN IF NOT EXISTS terms_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS privacy_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS marketing_opt_in BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS marketing_agreed_at TIMESTAMPTZ;

COMMENT ON COLUMN influencers.terms_agreed_at IS '서비스 이용약관 동의 시점';
COMMENT ON COLUMN influencers.privacy_agreed_at IS '개인정보 처리방침 동의 시점';
COMMENT ON COLUMN influencers.marketing_opt_in IS '마케팅 정보 수신 동의 여부 (선택)';
COMMENT ON COLUMN influencers.marketing_agreed_at IS '마케팅 정보 수신 동의 시점 (opt-in 시 기록)';

-- ---- 026_campaigns_primary_channel ----
ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS primary_channel text;

COMMENT ON COLUMN campaigns.primary_channel IS
  '최소 팔로워수 검증 기준 채널 코드 (channel 컬럼에 포함된 값 중 하나). NULL이면 첫 번째 채널로 폴백';

-- 기존 캠페인: min_followers > 0 인 경우 첫 번째 채널을 기준으로 자동 지정
UPDATE campaigns
   SET primary_channel = split_part(channel, ',', 1)
 WHERE primary_channel IS NULL
   AND channel IS NOT NULL
   AND channel <> ''
   AND COALESCE(min_followers, 0) > 0;

-- ============================================
-- 검증: 아래 쿼리로 결과 확인
-- ============================================
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema='public'
--   AND ((table_name='influencers' AND column_name IN ('terms_agreed_at','privacy_agreed_at','marketing_opt_in','marketing_agreed_at'))
--     OR (table_name='campaigns' AND column_name='primary_channel'));
