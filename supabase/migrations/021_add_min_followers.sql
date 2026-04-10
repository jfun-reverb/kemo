-- ============================================
-- campaigns 테이블에 최소 팔로워수 컬럼 추가
-- Supabase SQL Editor에서 실행하세요
-- ============================================

ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS min_followers integer DEFAULT 0;
