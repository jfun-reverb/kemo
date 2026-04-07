-- ============================================
-- REVERB JP — 관리자 계정 관리 테이블
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- ══════════════════════════════════════
-- 1. admins 테이블 생성
-- ══════════════════════════════════════
CREATE TABLE IF NOT EXISTS admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL UNIQUE,
  name text NOT NULL DEFAULT '',
  role text NOT NULL DEFAULT 'campaign_admin' CHECK (role IN ('super_admin','campaign_admin')),
  created_at timestamptz DEFAULT now()
);

ALTER TABLE admins ENABLE ROW LEVEL SECURITY;

-- ══════════════════════════════════════
-- 2. RLS 정책
-- ══════════════════════════════════════

-- 관리자만 조회 가능
CREATE POLICY "admins_select" ON admins FOR SELECT
  USING (is_admin());

-- 슈퍼관리자만 추가/수정/삭제 가능
CREATE POLICY "admins_insert" ON admins FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM admins WHERE auth_id = auth.uid() AND role = 'super_admin')
    OR NOT EXISTS (SELECT 1 FROM admins)
  );

CREATE POLICY "admins_update" ON admins FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM admins WHERE auth_id = auth.uid() AND role = 'super_admin')
    OR auth_id = auth.uid()
  );

CREATE POLICY "admins_delete" ON admins FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM admins WHERE auth_id = auth.uid() AND role = 'super_admin')
  );

-- ══════════════════════════════════════
-- 3. is_admin() 함수 업데이트 — admins 테이블 기반
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins WHERE auth_id = auth.uid()
  );
$$;

-- 슈퍼관리자 여부 확인 함수
CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin'
  );
$$;

-- ══════════════════════════════════════
-- 4. 관리자 비밀번호 초기화 함수
--    (슈퍼관리자가 다른 관리자의 비밀번호를 재설정)
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION reset_admin_password(target_auth_id uuid, new_password text)
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
  -- 비밀번호 업데이트
  UPDATE auth.users SET encrypted_password = crypt(new_password, gen_salt('bf'))
  WHERE id = target_auth_id;
  RETURN true;
END;
$$;

-- ══════════════════════════════════════
-- 5. 관리자 등록 함수
--    (Supabase Auth 계정 생성 + admins 테이블 등록)
-- ══════════════════════════════════════
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

  -- Auth 계정 생성 (이메일 인증 불필요)
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

  -- admins 테이블에 등록
  INSERT INTO public.admins (auth_id, email, name, role)
  VALUES (new_user_id, admin_email, admin_name, admin_role);

  RETURN new_user_id;
END;
$$;

-- ══════════════════════════════════════
-- 6. 기존 admin@kemo.jp를 슈퍼관리자로 등록
-- ══════════════════════════════════════
INSERT INTO admins (auth_id, email, name, role)
SELECT id, email, 'Admin', 'super_admin'
FROM auth.users
WHERE email = 'admin@kemo.jp'
ON CONFLICT (email) DO NOTHING;
