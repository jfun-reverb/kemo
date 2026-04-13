-- PayPal 이메일 컬럼 추가 (기존 은행정보 컬럼은 soft deprecate — 유지)
ALTER TABLE influencers
  ADD COLUMN IF NOT EXISTS paypal_email TEXT;

COMMENT ON COLUMN influencers.paypal_email IS 'PayPal 수취 이메일 주소 (리워드 송금용)';
