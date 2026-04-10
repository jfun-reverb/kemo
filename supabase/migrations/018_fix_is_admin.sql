-- ============================================
-- is_admin() 함수 개선
-- JWT email 하드코딩 → admins 테이블 조회
-- Supabase SQL Editor에서 실행하세요
-- ============================================

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins
    WHERE auth_id = auth.uid()
  );
$$;
