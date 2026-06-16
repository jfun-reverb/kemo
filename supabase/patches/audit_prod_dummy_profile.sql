-- ============================================================
-- 감사용 인플루언서 계정 더미 프로필 시드 (개발서버 전용)
-- ============================================================
-- 목적:
--   운영팀이 인플루언서 동선을 시뮬레이션할 때 쓰는 감사용 계정
--   (influencers.is_audit = true, 마이그레이션 179 에서 시드)에
--   프로필이 비어 있어 응모 테스트마다 필수 정보를 손으로 채워야 했다.
--   이 시드는 그 빈 프로필을 응모 시뮬레이션에 필요한 더미 값으로 한 번에 채운다.
--
-- 대상 계정: mtact@jfun.co.kr (개발서버 전용 — 마이그레이션 179 시드 계정)
--
-- 멱등성: UPDATE 라 여러 번 실행해도 안전. 계정이 없으면 0행 갱신(에러 아님).
--
-- 생년월일·성별은 건드리지 않는다:
--   감사용 계정은 이미 birthdate(만 18세 이상)·gender 가 채워져 있다(응모 게이트 테스트 시 입력됨).
--   생년월일 잠금 트리거(180-G)는 값→다른값 변경을 P0003 으로 차단하고,
--   SQL Editor 실행은 auth.uid() 가 비어 관리자로 인식되지 않으므로 birthdate 를 바꿀 수 없다.
--   이미 응모에 적합한 값이라 교체할 이유도 없어, 이 시드는 birthdate/gender 를 제외한다.
--
-- 주의: 운영서버에는 감사용 계정 이메일이 다르므로 이 파일을 그대로 쓰지 말 것
--       (운영 적용은 별도 결정 — 이메일·값 확인 후 진행).
-- ============================================================

UPDATE public.influencers SET
  -- 이름: 감사용 식별을 위해 「監査用」 유지
  name        = '監査用',
  name_kanji  = '監査用',
  name_kana   = 'かんさよう',
  -- 4채널 SNS 계정 + 팔로워 (모든 채널 캠페인에 응모 가능하도록 전부 채움)
  ig          = 'reverb_audit',     ig_followers      = 8000,
  x           = 'reverb_audit_x',   x_followers       = 3000,
  tiktok      = 'reverb_audit_tt',  tiktok_followers  = 5000,
  youtube     = 'reverb_audit_yt',  youtube_followers = 2000,
  line_id     = 'reverb_audit_line',
  -- 대표 SNS·카테고리·소개
  primary_sns = 'instagram',
  category    = 'beauty',
  bio         = '監査用アカウント（運営シミュレーション）',
  -- 배송지 (우편번호·도도부현·시·건물·전화 — 응모 필수정보)
  zip         = '150-0001',
  prefecture  = '東京都',
  city        = '渋谷区神宮前1-1-1',
  building    = '監査ビル 101',
  phone       = '090-0000-0000',
  -- PayPal (응모 필수정보)
  paypal_email = 'audit.paypal@example.com',
  -- 생년월일·성별은 이미 채워져 있어 제외 (잠금 트리거 180-G 로 변경 불가 + 교체 불필요)
  -- 약관·개인정보 동의 시각 (응모 진행에 필요)
  terms_agreed_at   = COALESCE(terms_agreed_at, now()),
  privacy_agreed_at = COALESCE(privacy_agreed_at, now())
WHERE email = 'mtact@jfun.co.kr';

-- 검증: 1행 갱신되었는지 + 채워진 값 확인
-- SELECT email, name_kanji, ig, ig_followers, prefecture, paypal_email,
--        birthdate, gender, is_audit
--   FROM public.influencers WHERE email = 'mtact@jfun.co.kr';
