-- ============================================
-- create_admin 레거시 함수 deprecate
-- 작성일: 2026-04-14
-- 대체: invite_admin (migration 031)
-- ============================================
-- 즉시 삭제 대신 예외만 발생시켜 이관 시간 확보. 이후 완전 삭제 가능.

CREATE OR REPLACE FUNCTION create_admin(admin_email text, admin_password text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'create_admin is deprecated. Use invite_admin(admin_email, admin_name, admin_role) + resetPasswordForEmail flow instead.';
END;
$$;
