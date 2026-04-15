-- ============================================
-- 패치: reset_admin_password 함수 pgcrypto 한정자 수정
-- 대상: 개발서버(qysmxtipobomefudyixw) → 검증 후 운영서버(twofagomeizrtkwlhsuv)
-- 작성일: 2026-04-15
-- 원인: 008_create_admins.sql에서 SET search_path = '' 상태로
--       crypt/gen_salt를 스키마 한정자 없이 호출 → 42883 undefined_function
--       023_fix_function_search_path.sql이 search_path를 public,pg_temp로
--       변경했지만 pgcrypto 함수는 extensions 스키마에 있어 여전히 미해소.
-- 수정: extensions.crypt(), extensions.gen_salt() 명시적 한정자 사용
--       (031_admin_invite_and_delete.sql의 invite_admin 함수와 동일 패턴)
-- ============================================

-- 롤백: 이 패치 전 상태로 되돌리려면 아래 주석 블록 실행
-- CREATE OR REPLACE FUNCTION public.reset_admin_password(target_auth_id uuid, new_password text)
-- RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
-- BEGIN
--   IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
--     RAISE EXCEPTION 'Permission denied: super_admin only';
--   END IF;
--   IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = target_auth_id) THEN
--     RAISE EXCEPTION 'Target is not an admin';
--   END IF;
--   UPDATE auth.users SET encrypted_password = crypt(new_password, gen_salt('bf'))
--   WHERE id = target_auth_id;
--   RETURN true;
-- END;
-- $$;

-- ============================================
-- 기존 시그니처 DROP (반환 타입 변경 또는 본문 갱신을 위해 필요)
-- ============================================
DROP FUNCTION IF EXISTS public.reset_admin_password(text, text);
DROP FUNCTION IF EXISTS public.reset_admin_password(uuid, text);

-- ============================================
-- text/text 오버로드 (이메일 기반)
-- ============================================
CREATE FUNCTION public.reset_admin_password(target_email text, new_password text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE email = target_email) THEN
    RAISE EXCEPTION 'Target is not an admin';
  END IF;
  UPDATE auth.users
     SET encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf', 10))
   WHERE email = target_email;
  RETURN true;
END;
$$;

-- ============================================
-- uuid/text 시그니처 — 클라이언트가 실제 호출하는 함수
-- ============================================
CREATE FUNCTION public.reset_admin_password(target_auth_id uuid, new_password text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 슈퍼관리자만 실행 가능
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;
  -- 대상이 관리자인지 확인
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = target_auth_id) THEN
    RAISE EXCEPTION 'Target is not an admin';
  END IF;
  -- 비밀번호 업데이트 (extensions 스키마 명시 — search_path='' 환경 필수)
  UPDATE auth.users
     SET encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf', 10))
   WHERE id = target_auth_id;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reset_admin_password(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_admin_password(text, text) TO authenticated;

-- ============================================
-- 검증 쿼리 (적용 후 SQL Editor에서 실행)
-- ============================================
-- 1. 함수 시그니처 확인
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--        p.prosrc LIKE '%extensions.crypt%' AS uses_extensions_crypt
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'reset_admin_password';
--
-- 2. pgcrypto extension 위치 확인
-- SELECT extname, nspname
-- FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
-- WHERE extname = 'pgcrypto';
--
-- 3. 함수 호출 테스트 (super_admin으로 로그인된 세션에서)
-- SELECT reset_admin_password('<target-uuid>', 'TestPassword123!');
