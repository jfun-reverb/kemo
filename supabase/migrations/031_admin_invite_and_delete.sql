-- ============================================
-- 관리자 초대 방식 + 삭제 옵션 2종
-- 작성일: 2026-04-14
-- ============================================

-- 1) invite_admin: 이메일+이름+역할만 받고 랜덤 임시비번 생성. 호출 후 클라이언트가 resetPasswordForEmail로 초대 메일 발송.
CREATE OR REPLACE FUNCTION invite_admin(admin_email text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  existing_user_id uuid;
  new_user_id uuid;
  target_user_id uuid;
  temp_password text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;

  IF EXISTS (SELECT 1 FROM public.admins WHERE email = admin_email) THEN
    RAISE EXCEPTION 'Admin with this email already exists';
  END IF;

  -- 임시 32자 랜덤 비번 (받는 사람은 메일 링크로만 로그인 가능)
  temp_password := encode(extensions.gen_random_bytes(24), 'base64');

  SELECT id INTO existing_user_id FROM auth.users WHERE email = admin_email LIMIT 1;

  IF existing_user_id IS NOT NULL THEN
    -- 기존 인플루언서 계정을 관리자로 승격. 비번은 덮어쓰기(재설정 메일 필수).
    UPDATE auth.users
       SET encrypted_password = extensions.crypt(temp_password, extensions.gen_salt('bf', 10)),
           email_confirmed_at = COALESCE(email_confirmed_at, now()),
           email_change = COALESCE(email_change, ''),
           raw_app_meta_data = COALESCE(raw_app_meta_data, jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')))
     WHERE id = existing_user_id;
    target_user_id := existing_user_id;
  ELSE
    new_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email,
      encrypted_password, email_confirmed_at,
      created_at, updated_at,
      confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token,
      raw_app_meta_data, raw_user_meta_data
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      new_user_id, 'authenticated', 'authenticated', admin_email,
      extensions.crypt(temp_password, extensions.gen_salt('bf', 10)),
      now(), now(), now(),
      '', '', '', '', '', '', '', '',
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true, 'phone_verified', false)
    );
    INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
    VALUES (
      gen_random_uuid(), new_user_id,
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true),
      'email', new_user_id::text, now(), now()
    );
    target_user_id := new_user_id;
  END IF;

  INSERT INTO public.admins (auth_id, email, name, role)
  VALUES (target_user_id, admin_email, admin_name, admin_role);

  RETURN target_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.invite_admin(text, text, text) TO authenticated;

-- 2) 관리자 권한만 해제
CREATE OR REPLACE FUNCTION remove_admin_role(target_auth_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;
  IF target_auth_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot remove own admin role';
  END IF;
  DELETE FROM public.admins WHERE auth_id = target_auth_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.remove_admin_role(uuid) TO authenticated;

-- 3) 계정 완전 삭제
CREATE OR REPLACE FUNCTION delete_admin_completely(target_auth_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;
  IF target_auth_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot delete own account';
  END IF;

  DELETE FROM public.applications WHERE user_id = target_auth_id;
  DELETE FROM public.receipts WHERE user_id = target_auth_id;
  DELETE FROM public.admins WHERE auth_id = target_auth_id;
  DELETE FROM public.influencers WHERE id = target_auth_id;
  DELETE FROM auth.identities WHERE user_id = target_auth_id;
  DELETE FROM auth.users WHERE id = target_auth_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.delete_admin_completely(uuid) TO authenticated;
