-- ============================================
-- create_admin 전면 수정: auth.identities + metadata 완비
-- 작성일: 2026-04-14
-- 배경: 기존 함수가 auth.identities와 raw_app_meta_data/raw_user_meta_data를
--       설정하지 않아 생성된 관리자 계정이 로그인 불가한 상태였음
-- ============================================

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

  new_user_id := gen_random_uuid();

  -- Auth 계정 생성 (완전한 Supabase Auth 스펙)
  INSERT INTO auth.users (
    instance_id, id, aud, role, email,
    encrypted_password, email_confirmed_at,
    created_at, updated_at,
    confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token,
    raw_app_meta_data, raw_user_meta_data
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    new_user_id, 'authenticated', 'authenticated', admin_email,
    extensions.crypt(admin_password, extensions.gen_salt('bf', 10)),
    now(),
    now(), now(),
    '', '', '', '', '', '',
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object(
      'sub', new_user_id::text,
      'email', admin_email,
      'email_verified', true,
      'phone_verified', false
    )
  );

  -- auth.identities 생성 (로그인에 필수)
  INSERT INTO auth.identities (
    id, user_id, identity_data, provider, provider_id, created_at, updated_at
  ) VALUES (
    gen_random_uuid(),
    new_user_id,
    jsonb_build_object(
      'sub', new_user_id::text,
      'email', admin_email,
      'email_verified', true
    ),
    'email',
    new_user_id::text,
    now(), now()
  );

  -- admins 테이블 등록
  INSERT INTO public.admins (auth_id, email, name, role)
  VALUES (new_user_id, admin_email, admin_name, admin_role);

  RETURN new_user_id;
END;
$$;

-- ============================================
-- 기존 관리자 중 누락된 필드 일괄 보정
-- ============================================

-- raw_app_meta_data / raw_user_meta_data 누락분 채우기
UPDATE auth.users u
   SET
     raw_app_meta_data = COALESCE(raw_app_meta_data, jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'))),
     raw_user_meta_data = COALESCE(raw_user_meta_data, jsonb_build_object(
       'sub', u.id::text,
       'email', u.email,
       'email_verified', true,
       'phone_verified', false
     )),
     recovery_token = COALESCE(recovery_token, ''),
     email_change_token_new = COALESCE(email_change_token_new, ''),
     email_change_token_current = COALESCE(email_change_token_current, ''),
     phone_change_token = COALESCE(phone_change_token, ''),
     reauthentication_token = COALESCE(reauthentication_token, ''),
     email_change = COALESCE(email_change, ''),
     phone_change = COALESCE(phone_change, '')
  FROM public.admins a
 WHERE a.auth_id = u.id;

-- auth.identities 누락분 채우기
INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
SELECT
  gen_random_uuid(),
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email',
  u.id::text,
  now(), now()
FROM auth.users u
JOIN public.admins a ON a.auth_id = u.id
LEFT JOIN auth.identities i ON i.user_id = u.id AND i.provider = 'email'
WHERE i.id IS NULL;

-- ============================================
-- 검증
-- ============================================
SELECT
  a.email,
  a.role,
  CASE WHEN u.raw_app_meta_data IS NOT NULL THEN '✓' ELSE '✗' END AS app_meta,
  CASE WHEN u.raw_user_meta_data IS NOT NULL THEN '✓' ELSE '✗' END AS user_meta,
  CASE WHEN EXISTS (SELECT 1 FROM auth.identities i WHERE i.user_id = u.id AND i.provider = 'email') THEN '✓' ELSE '✗' END AS has_identity
FROM public.admins a
JOIN auth.users u ON u.id = a.auth_id
ORDER BY a.email;
