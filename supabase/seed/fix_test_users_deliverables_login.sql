-- ============================================
-- deliv.*@reverb.jp 계정 로그인 복구
-- 원인: auth.identities 누락 + email_change/phone_change/token 필드 NULL
-- 적용: 개발서버 SQL Editor에서 1회 실행
-- ============================================

-- 1) auth.users 누락 필드 채우기
UPDATE auth.users
SET
  email_change          = COALESCE(email_change, ''),
  email_change_token_new = COALESCE(email_change_token_new, ''),
  email_change_token_current = COALESCE(email_change_token_current, ''),
  phone_change          = COALESCE(phone_change, ''),
  phone_change_token    = COALESCE(phone_change_token, ''),
  recovery_token        = COALESCE(recovery_token, ''),
  reauthentication_token = COALESCE(reauthentication_token, ''),
  confirmation_token    = COALESCE(confirmation_token, ''),
  raw_app_meta_data     = COALESCE(raw_app_meta_data, '{"provider":"email","providers":["email"]}'::jsonb),
  raw_user_meta_data    = COALESCE(raw_user_meta_data, jsonb_build_object('email', email, 'email_verified', true))
WHERE email LIKE 'deliv.%@reverb.jp';

-- 2) auth.identities 행 생성 (이미 있으면 skip)
INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
SELECT
  gen_random_uuid(),
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email',
  u.id::text,
  now(), now(), now()
FROM auth.users u
WHERE u.email LIKE 'deliv.%@reverb.jp'
  AND NOT EXISTS (
    SELECT 1 FROM auth.identities i WHERE i.user_id = u.id AND i.provider = 'email'
  );

-- 3) 결과 확인
SELECT u.email,
       (i.id IS NOT NULL) AS has_identity,
       u.email_confirmed_at IS NOT NULL AS confirmed
  FROM auth.users u
  LEFT JOIN auth.identities i ON i.user_id = u.id AND i.provider = 'email'
 WHERE u.email LIKE 'deliv.%@reverb.jp'
 ORDER BY u.email;
