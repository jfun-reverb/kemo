-- Supabase Security Advisor: Function Search Path Mutable 경고 해소
-- 함수 호출 시 search_path를 명시적으로 고정하여 권한 상승 공격(privilege escalation) 차단
-- 참고: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable

ALTER FUNCTION public.reset_admin_password
  SET search_path = public, pg_temp;

ALTER FUNCTION public.create_admin_password
  SET search_path = public, pg_temp;

-- 향후 신규 함수 작성 시에도 다음 형식 권장:
--   CREATE OR REPLACE FUNCTION public.xxx(...) RETURNS ...
--   LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$ ... $$;
