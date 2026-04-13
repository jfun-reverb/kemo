-- テストインフルエンサーのプロフィールを完成させる（キャンペーン応募に必要な情報）
-- Supabase SQL Editor で実行してください

-- 1) 現在の状態確認（先にこれだけ実行して確認してもOK）
-- SELECT email, name_kanji, ig, phone, zip, bank_name FROM influencers WHERE email IN ('sakura.test@reverb.jp','yui.test@reverb.jp','haruka.test@reverb.jp');

-- 2) sakura.test@reverb.jp — 佐藤さくら (Beauty / Instagram)
UPDATE influencers SET
  name = '佐藤さくら',
  name_kanji = '佐藤さくら',
  name_kana = 'さとうさくら',
  category = 'beauty',
  bio = 'K-Beauty大好き💄 毎日のスキンケアを発信中',
  line_id = 'sakura_line',
  ig = 'sakura_beauty',
  ig_followers = 12500,
  x = 'sakura_x',
  x_followers = 3200,
  tiktok = '',
  tiktok_followers = 0,
  youtube = '',
  youtube_followers = 0,
  followers = 15700,
  zip = '150-0001',
  prefecture = '東京都',
  city = '渋谷区神宮前3-15-8',
  building = 'パークハイツ 302',
  address = '〒150-0001 東京都渋谷区神宮前3-15-8 パークハイツ 302',
  phone = '090-1234-5678',
  bank_name = 'みずほ銀行',
  bank_branch = '渋谷支店',
  bank_type = '普通',
  bank_number = '1234567',
  bank_holder = 'サトウ サクラ'
WHERE email = 'sakura.test@reverb.jp';

-- 3) yui.test@reverb.jp — 田中ゆい (Food / TikTok)
UPDATE influencers SET
  name = '田中ゆい',
  name_kanji = '田中ゆい',
  name_kana = 'たなかゆい',
  category = 'food',
  bio = '韓国料理とK-Foodのレビュー🍜 TikTokメイン',
  line_id = 'yui_line',
  ig = 'yui_foodie',
  ig_followers = 8300,
  x = '',
  x_followers = 0,
  tiktok = 'yui_tiktok',
  tiktok_followers = 45000,
  youtube = 'yui_yt',
  youtube_followers = 2100,
  followers = 55400,
  zip = '530-0001',
  prefecture = '大阪府',
  city = '大阪市北区梅田1-2-3',
  building = 'グランフロント 1205',
  address = '〒530-0001 大阪府大阪市北区梅田1-2-3 グランフロント 1205',
  phone = '080-9876-5432',
  bank_name = '三菱UFJ銀行',
  bank_branch = '梅田支店',
  bank_type = '普通',
  bank_number = '7654321',
  bank_holder = 'タナカ ユイ'
WHERE email = 'yui.test@reverb.jp';

-- 4) haruka.test@reverb.jp — 鈴木はるか (Fashion / Instagram+X)
UPDATE influencers SET
  name = '鈴木はるか',
  name_kanji = '鈴木はるか',
  name_kana = 'すずきはるか',
  category = 'fashion',
  bio = 'ファッション×K-Beauty🇰🇷 Instagram & X で発信',
  line_id = 'haruka_line',
  ig = 'haruka_style',
  ig_followers = 15000,
  x = 'haruka_x',
  x_followers = 7000,
  tiktok = 'haruka_tk',
  tiktok_followers = 3500,
  youtube = '',
  youtube_followers = 0,
  followers = 25500,
  zip = '460-0008',
  prefecture = '愛知県',
  city = '名古屋市中区栄4-5-6',
  building = 'サカエタワー 801',
  address = '〒460-0008 愛知県名古屋市中区栄4-5-6 サカエタワー 801',
  phone = '070-5555-1234',
  bank_name = '三井住友銀行',
  bank_branch = '栄支店',
  bank_type = '普通',
  bank_number = '3456789',
  bank_holder = 'スズキ ハルカ'
WHERE email = 'haruka.test@reverb.jp';
