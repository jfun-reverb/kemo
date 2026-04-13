-- ============================================
-- REVERB JP — 테스트 인플루언서 3명 생성
-- Supabase SQL Editor에서 실행하세요
-- 비밀번호는 모두 test1234
-- ============================================

-- ── 1. 사쿠라 (뷰티 인플루언서, Instagram 메인) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'sakura.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, x, x_followers, tiktok, tiktok_followers, category, bio, line_id, zip, prefecture, city, building, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
SELECT id, 'sakura.test@reverb.jp', '佐藤さくら', '佐藤さくら', 'さとうさくら', 'sakura_beauty', 12500, 'sakura_x', 3200, 'sakura_tt', 8900, 'beauty', 'K-Beautyが大好き！毎日のスキンケアを発信中 🌸', 'sakura_line', '150-0001', '東京都', '渋谷区神宮前3-15-8', 'サクラマンション 301', '〒150-0001 東京都渋谷区神宮前3-15-8 サクラマンション 301', '090-1234-5678', 'みずほ銀行', '渋谷支店', '普通', '1234567', 'サトウ サクラ'
FROM auth.users WHERE email = 'sakura.test@reverb.jp';

-- ── 2. 유이 (푸드 인플루언서, TikTok 메인) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'yui.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, tiktok, tiktok_followers, youtube, youtube_followers, category, bio, line_id, zip, prefecture, city, building, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
SELECT id, 'yui.test@reverb.jp', '田中ゆい', '田中ゆい', 'たなかゆい', 'yui_foodie', 8300, 'yui_tiktok', 45000, 'yui_yt', 2100, 'food', '韓国料理とK-Foodのレビュー🍜 TikTokメイン', 'yui_line', '530-0001', '大阪府', '大阪市北区梅田1-2-3', 'グランフロント 1205', '〒530-0001 大阪府大阪市北区梅田1-2-3 グランフロント 1205', '080-9876-5432', '三菱UFJ銀行', '梅田支店', '普通', '7654321', 'タナカ ユイ'
FROM auth.users WHERE email = 'yui.test@reverb.jp';

-- ── 3. 하루카 (패션 인플루언서, Instagram+X) ──
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token)
VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  'haruka.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '');

INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, x, x_followers, category, bio, line_id, zip, prefecture, city, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
SELECT id, 'haruka.test@reverb.jp', '鈴木はるか', '鈴木はるか', 'すずきはるか', 'haruka_style', 22000, 'haruka_fashion', 15000, 'fashion', 'K-Fashionコーデを毎日投稿👗 Instagram+X', 'haruka_line', '460-0008', '愛知県', '名古屋市中区栄4-5-6', '〒460-0008 愛知県名古屋市中区栄4-5-6', '070-5555-1234', '三井住友銀行', '栄支店', '普通', '9876543', 'スズキ ハルカ'
FROM auth.users WHERE email = 'haruka.test@reverb.jp';

-- 결과 확인
SELECT email, name, ig, ig_followers, tiktok, tiktok_followers, category FROM influencers ORDER BY created_at DESC LIMIT 5;
