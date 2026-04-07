-- ============================================
-- REVERB JP — 컬럼 타입 최적화
-- 팔로워: integer, 가격: bigint, 날짜: date/timestamptz
-- Supabase SQL Editor에서 실행하세요
-- ============================================


-- ══════════════════════════════════════
-- 1. campaigns — 가격 필드 integer → bigint
-- ══════════════════════════════════════
ALTER TABLE campaigns
  ALTER COLUMN reward TYPE bigint,
  ALTER COLUMN product_price TYPE bigint;

-- ══════════════════════════════════════
-- 2. campaigns — 날짜 필드 text → date
-- ══════════════════════════════════════
-- deadline은 이미 date 타입이므로 생략
ALTER TABLE campaigns
  ALTER COLUMN post_deadline TYPE date USING post_deadline::date;

-- ══════════════════════════════════════
-- 3. influencers — 팔로워 수 integer 유지 확인
-- ══════════════════════════════════════
-- ig_followers, x_followers, tiktok_followers, youtube_followers, followers
-- integer (최대 ~21억) — 팔로워 수로 충분하므로 유지

-- ══════════════════════════════════════
-- 4. applications — user_followers integer 유지 확인
-- ══════════════════════════════════════
-- integer — 충분하므로 유지


-- ══════════════════════════════════════
-- 최종 스키마 정리
-- ══════════════════════════════════════
--
-- campaigns:
--   id            uuid (PK, 자동생성)
--   title         text (NOT NULL)
--   brand         text
--   product       text
--   product_url   text
--   product_price bigint (기본값 0)        ← 수정됨
--   type          text (기본값 'nano')
--   channel       text (기본값 'instagram')
--   category      text (기본값 'beauty')
--   recruit_type  text (기본값 'monitor')
--   content_types text
--   emoji         text (기본값 '📦')
--   reward        bigint (기본값 0)         ← 수정됨
--   slots         integer (기본값 20)
--   applied_count integer (기본값 0)
--   deadline      date
--   post_deadline date                     ← 수정됨 (text → date)
--   post_days     integer (기본값 7)
--   order_index   integer
--   image_url     text
--   img1~img8     text
--   description   text
--   hashtags      text
--   mentions      text
--   appeal        text
--   guide         text
--   ng            text
--   status        text (기본값 'active')
--   created_at    timestamptz (기본값 now())
--
-- influencers:
--   id                uuid (PK)
--   email             text (NOT NULL)
--   name              text
--   name_kanji        text
--   name_kana         text
--   ig                text
--   ig_followers      integer (기본값 0)
--   x                 text
--   x_followers       integer (기본값 0)
--   tiktok            text
--   tiktok_followers  integer (기본값 0)
--   youtube           text
--   youtube_followers integer (기본값 0)
--   followers         integer (기본값 0)     ← 전체 합계
--   line_id           text
--   category          text
--   bio               text
--   zip               text
--   prefecture        text
--   city              text
--   building          text
--   address           text                  ← 조합 주소
--   phone             text
--   bank_name         text
--   bank_branch       text
--   bank_type         text (기본값 '普通')
--   bank_number       text
--   bank_holder       text
--   created_at        timestamptz (기본값 now())
--
-- applications:
--   id             uuid (PK, 자동생성)
--   user_id        uuid
--   user_email     text
--   user_name      text
--   user_ig        text
--   ig_id          text
--   user_followers integer (기본값 0)
--   campaign_id    uuid
--   message        text
--   address        text
--   status         text (기본값 'pending')
--   created_at     timestamptz (기본값 now())
