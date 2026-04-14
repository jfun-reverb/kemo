-- ============================================
-- 개발서버(staging) 테스트 인플루언서 3명 생성
-- 비밀번호: 모두 test1234
-- 이메일: 모두 이메일 확인 완료 처리
-- 주의: staging 전용 — 운영서버에 실행 금지
-- ============================================

-- ── 1. 사쿠라 (뷰티/Instagram 메인) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'sakura.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

UPDATE influencers SET
  name = '佐藤さくら',
  name_kanji = '佐藤さくら',
  name_kana = 'さとうさくら',
  ig = 'sakura_beauty', ig_followers = 12500,
  x = 'sakura_x', x_followers = 3200,
  tiktok = 'sakura_tt', tiktok_followers = 8900,
  category = 'beauty',
  primary_sns = 'instagram',
  bio = 'K-Beautyが大好き！毎日のスキンケアを発信中 🌸',
  line_id = 'sakura_line',
  zip = '150-0001', prefecture = '東京都', city = '渋谷区神宮前3-15-8', building = 'サクラマンション 301',
  phone = '090-1234-5678',
  paypal_email = 'sakura.paypal@example.com',
  terms_agreed_at = now(),
  privacy_agreed_at = now(),
  marketing_opt_in = true,
  marketing_agreed_at = now()
WHERE email = 'sakura.test@reverb.jp';

-- ── 2. 유이 (푸드/TikTok 메인) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'yui.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

UPDATE influencers SET
  name = '田中ゆい',
  name_kanji = '田中ゆい',
  name_kana = 'たなかゆい',
  ig = 'yui_foodie', ig_followers = 8300,
  tiktok = 'yui_tiktok', tiktok_followers = 45000,
  youtube = 'yui_yt', youtube_followers = 2100,
  category = 'food',
  primary_sns = 'tiktok',
  bio = '韓国料理とK-Foodのレビュー🍜 TikTokメイン',
  line_id = 'yui_line',
  zip = '530-0001', prefecture = '大阪府', city = '大阪市北区梅田1-2-3', building = 'グランフロント 1205',
  phone = '080-9876-5432',
  paypal_email = 'yui.paypal@example.com',
  terms_agreed_at = now(),
  privacy_agreed_at = now(),
  marketing_opt_in = false
WHERE email = 'yui.test@reverb.jp';

-- ── 3. 하루카 (패션/Instagram+X) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'haruka.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

UPDATE influencers SET
  name = '鈴木はるか',
  name_kanji = '鈴木はるか',
  name_kana = 'すずきはるか',
  ig = 'haruka_style', ig_followers = 22000,
  x = 'haruka_fashion', x_followers = 15000,
  category = 'fashion',
  primary_sns = 'instagram',
  bio = 'K-Fashionコーデを毎日投稿👗 Instagram+X',
  line_id = 'haruka_line',
  zip = '460-0008', prefecture = '愛知県', city = '名古屋市中区栄4-5-6', building = '',
  phone = '070-5555-1234',
  paypal_email = 'haruka.paypal@example.com',
  terms_agreed_at = now(),
  privacy_agreed_at = now(),
  marketing_opt_in = true,
  marketing_agreed_at = now()
WHERE email = 'haruka.test@reverb.jp';

-- 결과 확인
SELECT email, name, primary_sns, category, ig_followers, tiktok_followers FROM influencers WHERE email LIKE '%.test@reverb.jp' ORDER BY email;
