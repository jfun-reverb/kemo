-- ============================================
-- REVERB JP — 테이블 스키마 동기화
-- 프론트엔드에서 사용 중인 모든 필드를 Supabase에 반영
-- Supabase SQL Editor에서 실행하세요
-- ============================================


-- ══════════════════════════════════════
-- 1. influencers 테이블 — 누락 컬럼 추가
-- ══════════════════════════════════════
-- 현재: id, email, name, ig, x, followers, bio, address, category, created_at
-- 추가: 한자/카나 이름, 채널별 팔로워, 배송지 상세, 계좌 정보, 연락처

-- 이름 (한자/카나)
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS name_kanji text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS name_kana text;

-- SNS 채널별 팔로워 수
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS ig_followers integer DEFAULT 0;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS x_followers integer DEFAULT 0;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS tiktok text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS tiktok_followers integer DEFAULT 0;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS youtube text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS youtube_followers integer DEFAULT 0;

-- LINE ID
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS line_id text;

-- 배송지 주소 (상세 필드)
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS zip text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS prefecture text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS city text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS building text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS phone text;

-- 계좌 정보
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS bank_name text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS bank_branch text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS bank_type text DEFAULT '普通';
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS bank_number text;
ALTER TABLE influencers ADD COLUMN IF NOT EXISTS bank_holder text;


-- ══════════════════════════════════════
-- 2. campaigns 테이블 — 누락 컬럼 추가
-- ══════════════════════════════════════
-- 현재: id, title, brand, product, type, channel, category, emoji,
--       reward, slots, applied_count, deadline, post_days,
--       description, hashtags, mentions, appeal, guide, ng, status, created_at
-- 추가: 제품URL, 제품가격, 모집타입, 콘텐츠종류, 정렬순서,
--       게시마감일, 이미지URL(8장)

-- 제품/가격
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS product_url text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS product_price integer DEFAULT 0;

-- 모집 타입 (모니터 / 기프팅)
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS recruit_type text DEFAULT 'monitor';

-- 콘텐츠 종류 (쉼표 구분)
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS content_types text;

-- 표시 순서
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS order_index integer;

-- 게시 마감일
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS post_deadline text;

-- 제품 이미지 (메인URL + 8장 슬롯)
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS image_url text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img1 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img2 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img3 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img4 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img5 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img6 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img7 text;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS img8 text;


-- ══════════════════════════════════════
-- 3. applications 테이블 — 누락 컬럼 추가
-- ══════════════════════════════════════
-- 현재: id, user_id, user_email, user_name, user_followers,
--       campaign_id, message, address, status, created_at
-- 추가: Instagram ID

ALTER TABLE applications ADD COLUMN IF NOT EXISTS ig_id text;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS user_ig text;


-- ══════════════════════════════════════
-- 4. 인덱스 추가 (검색 성능 향상)
-- ══════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_campaigns_status ON campaigns(status);
CREATE INDEX IF NOT EXISTS idx_campaigns_recruit_type ON campaigns(recruit_type);
CREATE INDEX IF NOT EXISTS idx_campaigns_order_index ON campaigns(order_index);
CREATE INDEX IF NOT EXISTS idx_applications_campaign_id ON applications(campaign_id);
CREATE INDEX IF NOT EXISTS idx_applications_user_id ON applications(user_id);
CREATE INDEX IF NOT EXISTS idx_applications_status ON applications(status);
CREATE INDEX IF NOT EXISTS idx_influencers_email ON influencers(email);
