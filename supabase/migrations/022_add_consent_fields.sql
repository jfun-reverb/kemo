-- 회원가입 시 동의 항목 기록
-- 利用規約 / 個人情報処理方針 / 마케팅 정보 수신 동의 시점을 영구 보관

ALTER TABLE influencers
  ADD COLUMN IF NOT EXISTS terms_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS privacy_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS marketing_opt_in BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS marketing_agreed_at TIMESTAMPTZ;

COMMENT ON COLUMN influencers.terms_agreed_at IS '서비스 이용약관 동의 시점';
COMMENT ON COLUMN influencers.privacy_agreed_at IS '개인정보 처리방침 동의 시점';
COMMENT ON COLUMN influencers.marketing_opt_in IS '마케팅 정보 수신 동의 여부 (선택)';
COMMENT ON COLUMN influencers.marketing_agreed_at IS '마케팅 정보 수신 동의 시점 (opt-in 시 기록)';
