-- ============================================
-- create_admin 함수 강화: 이메일 인증 보장
-- 작성일: 2026-04-14
-- 배경: 과거 create_admin으로 생성된 관리자 중 일부 email_confirmed_at NULL 사례 발견
-- ============================================

-- 1. 함수 재정의 — INSERT 후 email_confirmed_at 강제 확인 처리
CREATE OR REPLACE FUNCTION create_admin(admin_email text, admin_password text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_user_id uuid;
BEGIN
  -- 슈퍼관리자만 실행 가능
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;

  -- Auth 계정 생성 (이메일 인증 완료 상태)
  INSERT INTO auth.users (
    instance_id, id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at, confirmation_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(), 'authenticated', 'authenticated', admin_email,
    crypt(admin_password, gen_salt('bf')), now(),
    now(), now(), ''
  ) RETURNING id INTO new_user_id;

  -- 안전망: 혹시라도 email_confirmed_at 누락된 경우 보정
  UPDATE auth.users
     SET email_confirmed_at = COALESCE(email_confirmed_at, now())
   WHERE id = new_user_id;

  -- admins 테이블에 등록
  INSERT INTO public.admins (auth_id, email, name, role)
  VALUES (new_user_id, admin_email, admin_name, admin_role);

  RETURN new_user_id;
END;
$$;

-- 2. 기존 관리자 중 email_confirmed_at NULL인 경우 일괄 보정
UPDATE auth.users u
   SET email_confirmed_at = now()
  FROM public.admins a
 WHERE u.id = a.auth_id
   AND u.email_confirmed_at IS NULL;

-- 3. 검증
SELECT
  a.email,
  a.role,
  u.email_confirmed_at,
  CASE WHEN u.email_confirmed_at IS NOT NULL THEN '✓' ELSE '✗' END AS confirmed
FROM public.admins a
JOIN auth.users u ON u.id = a.auth_id
ORDER BY u.email_confirmed_at NULLS FIRST;
