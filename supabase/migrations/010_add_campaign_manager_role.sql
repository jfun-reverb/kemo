-- ============================================
-- REVERB JP — 관리자 권한 3단계 확장
-- campaign_manager (매니저) 추가
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- admins 테이블의 role CHECK 제약 조건 수정
ALTER TABLE admins DROP CONSTRAINT IF EXISTS admins_role_check;
ALTER TABLE admins ADD CONSTRAINT admins_role_check
  CHECK (role IN ('super_admin', 'campaign_admin', 'campaign_manager'));
