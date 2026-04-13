-- ============================================
-- 테스트 유저 수정 — 잘못 생성된 auth.users 삭제 후 재생성
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- 기존 잘못된 데이터 삭제
DELETE FROM influencers WHERE email IN ('sakura.test@reverb.jp','yui.test@reverb.jp','haruka.test@reverb.jp');
DELETE FROM auth.users WHERE email IN ('sakura.test@reverb.jp','yui.test@reverb.jp','haruka.test@reverb.jp');

-- Supabase Auth 호환 형식으로 재생성
-- identity 테이블도 함께 생성해야 로그인 가능

DO $$
DECLARE
  uid1 uuid := gen_random_uuid();
  uid2 uuid := gen_random_uuid();
  uid3 uuid := gen_random_uuid();
BEGIN
  -- 사쿠라
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, confirmation_token, recovery_token, email_change_token_new)
  VALUES ('00000000-0000-0000-0000-000000000000', uid1, 'authenticated', 'authenticated', 'sakura.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, '', '', '');
  INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, created_at, updated_at)
  VALUES (gen_random_uuid(), uid1::text, uid1, jsonb_build_object('sub', uid1::text, 'email', 'sakura.test@reverb.jp'), 'email', now(), now());

  INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, x, x_followers, tiktok, tiktok_followers, category, bio, line_id, zip, prefecture, city, building, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
  VALUES (uid1, 'sakura.test@reverb.jp', '佐藤さくら', '佐藤さくら', 'さとうさくら', 'sakura_beauty', 12500, 'sakura_x', 3200, 'sakura_tt', 8900, 'beauty', 'K-Beautyが大好き！毎日のスキンケアを発信中 🌸', 'sakura_line', '150-0001', '東京都', '渋谷区神宮前3-15-8', 'サクラマンション 301', '〒150-0001 東京都渋谷区神宮前3-15-8 サクラマンション 301', '090-1234-5678', 'みずほ銀行', '渋谷支店', '普通', '1234567', 'サトウ サクラ');

  -- 유이
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, confirmation_token, recovery_token, email_change_token_new)
  VALUES ('00000000-0000-0000-0000-000000000000', uid2, 'authenticated', 'authenticated', 'yui.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, '', '', '');
  INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, created_at, updated_at)
  VALUES (gen_random_uuid(), uid2::text, uid2, jsonb_build_object('sub', uid2::text, 'email', 'yui.test@reverb.jp'), 'email', now(), now());

  INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, tiktok, tiktok_followers, youtube, youtube_followers, category, bio, line_id, zip, prefecture, city, building, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
  VALUES (uid2, 'yui.test@reverb.jp', '田中ゆい', '田中ゆい', 'たなかゆい', 'yui_foodie', 8300, 'yui_tiktok', 45000, 'yui_yt', 2100, 'food', '韓国料理とK-Foodのレビュー🍜 TikTokメイン', 'yui_line', '530-0001', '大阪府', '大阪市北区梅田1-2-3', 'グランフロント 1205', '〒530-0001 大阪府大阪市北区梅田1-2-3 グランフロント 1205', '080-9876-5432', '三菱UFJ銀行', '梅田支店', '普通', '7654321', 'タナカ ユイ');

  -- 하루카
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, confirmation_token, recovery_token, email_change_token_new)
  VALUES ('00000000-0000-0000-0000-000000000000', uid3, 'authenticated', 'authenticated', 'haruka.test@reverb.jp', crypt('test1234', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, '', '', '');
  INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, created_at, updated_at)
  VALUES (gen_random_uuid(), uid3::text, uid3, jsonb_build_object('sub', uid3::text, 'email', 'haruka.test@reverb.jp'), 'email', now(), now());

  INSERT INTO influencers (id, email, name, name_kanji, name_kana, ig, ig_followers, x, x_followers, category, bio, line_id, zip, prefecture, city, address, phone, bank_name, bank_branch, bank_type, bank_number, bank_holder)
  VALUES (uid3, 'haruka.test@reverb.jp', '鈴木はるか', '鈴木はるか', 'すずきはるか', 'haruka_style', 22000, 'haruka_fashion', 15000, 'fashion', 'K-Fashionコーデを毎日投稿👗 Instagram+X', 'haruka_line', '460-0008', '愛知県', '名古屋市中区栄4-5-6', '〒460-0008 愛知県名古屋市中区栄4-5-6', '070-5555-1234', '三井住友銀行', '栄支店', '普通', '9876543', 'スズキ ハルカ');
END $$;

-- 확인
SELECT email, name, ig, ig_followers, category FROM influencers WHERE email LIKE '%.test@reverb.jp';
