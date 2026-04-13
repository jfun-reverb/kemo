-- Supabase Security Advisor: Function Search Path Mutable 경고 해소
-- 함수 호출 시 search_path를 명시적으로 고정하여 권한 상승 공격(privilege escalation) 차단
-- 참고: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable

-- reset_admin_password (오버로드 2개)
ALTER FUNCTION public.reset_admin_password(target_email text, new_password text)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.reset_admin_password(target_auth_id uuid, new_password text)
  SET search_path = public, pg_temp;

-- create_admin (관리자 계정 생성 함수)
ALTER FUNCTION public.create_admin(admin_email text, admin_password text, admin_name text, admin_role text)
  SET search_path = public, pg_temp;

-- is_admin / is_super_admin (RLS 정책에서 사용)
ALTER FUNCTION public.is_admin()
  SET search_path = public, pg_temp;

ALTER FUNCTION public.is_super_admin()
  SET search_path = public, pg_temp;

-- 향후 신규 함수 작성 시에도 다음 형식 권장:
--   CREATE OR REPLACE FUNCTION public.xxx(...) RETURNS ...
--   LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$ ... $$;
