-- ============================================
-- REVERB JP — 보안 경고 수정
-- Supabase Security Advisor 경고 해결
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- ══════════════════════════════════════
-- 1. is_admin() 함수에 search_path 고정
--    search_path를 빈 값으로 설정해서
--    다른 스키마의 함수로 속일 수 없게 함
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(auth.jwt() ->> 'email', '') = 'admin@kemo.jp';
$$;
