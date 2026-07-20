-- ============================================================
-- 245_invite_admin_preserve_password.sql
-- 2026-07-20
--
-- 목적:
--   관리자 초대(사양서 PR 4, docs/specs/2026-07-20-admin-invite-mail-and-setpw.md §D-6 ②)
--   시 기존 auth.users 계정(= 이미 인플루언서로 가입한 사람을 관리자로 승격하는 경우)의
--   비밀번호를 더 이상 임시 랜덤 값으로 덮어쓰지 않는다.
--
--   기존 문제(031_admin_invite_and_delete.sql:32-40): 승격 분기가 신규 생성 분기와 같은
--   코드에 뭉쳐 있어, 이미 그 사람이 쓰고 있던 유효한 비밀번호를 초대 시점에 즉시 무효화
--   했다. 초대 메일이 스팸함으로 가거나 늦게 열리면 그 사이 본인은 이유도 모른 채
--   인플루언서 로그인이 막힌다(응모이력·정산을 가진 실사용자·감사용 계정 is_audit 도 동일하게
--   영향받음). 승격 케이스에서 비밀번호를 덮어쓸 기술적 필요는 없다 — 이미 유효한 값을
--   본인이 쓰고 있다.
--
-- 변경:
--   1. invite_admin(text, text, text) 를 CREATE OR REPLACE — 함수 인자 시그니처는 그대로라
--      실행권한(GRANT)이 보존된다(재부여는 방어적으로 명시 재실행).
--        - 승격 분기(기존 auth.users 행 있음): encrypted_password UPDATE 를 제거.
--          로그인 차단 방지용 메타데이터 보정(email_confirmed_at·email_change·
--          raw_app_meta_data 의 COALESCE)은 그대로 유지 — 미확인 상태로 남아있던 계정을
--          관리자로 승격할 때 이 보정이 없으면 email_confirmed_at 이 NULL인 채로 남아
--          "email_confirmed_at = now() 필수(NULL이면 로그인 차단)" 규칙(supabase.md)에
--          걸려 그 계정이 영구히 로그인 불가능해진다. 비밀번호와 달리 이 보정은 기존 값을
--          덮어쓰지 않는 COALESCE 라 부작용이 없다.
--        - 신규 생성 분기(auth.users 행 없음): 기존과 완전히 동일 — 임시 32자 랜덤 비밀번호
--          (bcrypt round 10) + auth.identities 행 생성.
--        - 반환값(uuid)·가드(super_admin 확인, 이메일 중복 admins 행 차단)는 변경 없음.
--   2. admins 에 컬럼 1개 추가: promoted_at timestamptz NULL
--        승격 분기를 탄 경우에만 now() 로 채움(신규 생성 분기는 NULL로 남김). 아래
--        "메일 문구 어긋남" 판단·제안 참고.
--
-- ────────────────────────────────────────────────────────────
-- "승격된 사람은 안 바꿔도 기존 비밀번호로 로그인된다" — 초대 메일 문구와 어긋나는가
-- ────────────────────────────────────────────────────────────
--   어긋난다. docs/email-templates/admin-invite.html 은 "사용하실 비밀번호를 설정해
--   주세요"라고 안내하는데, 승격된 사람은 이 링크를 아예 클릭하지 않아도 기존 비밀번호로
--   즉시 로그인이 된다. 이 자체가 기능적 오류는 아니다(비밀번호를 보존하는 것이 이번
--   변경의 목적이므로) — 다만 문구가 "반드시 새로 정해야 하는 것"처럼 읽혀 혼란을 준다.
--   더 나쁜 경우: 신규 생성된 계정은 이 링크를 거치지 않으면 로그인 자체가 불가능(임시
--   랜덤 비밀번호를 아무도 모름)한데, 승격 계정은 그렇지 않다는 차이를 문구가 구분하지
--   않는다.
--
--   해결은 이 마이그레이션(DB)의 책임 범위를 넘는다 — 메일 문구 분기는 Edge Function
--   notify-admin-invite(PR 2)·템플릿(docs/email-templates/admin-invite.html) 쪽 작업이다.
--   다만 그 분기가 "이번이 승격인지 신규 생성인지"를 판단할 근거가 DB에 있어야 하므로,
--   이 마이그레이션에서 admins.promoted_at 컬럼을 추가해 그 근거를 준비해 둔다.
--
--   제안(구현은 화면/Edge Function 쪽 몫):
--     - notify-admin-invite 가 메일 발송 전 admins.promoted_at 을 함께 조회해, NOT NULL
--       이면 문구를 "REVERB JP 관리자 권한이 추가되었습니다. 기존에 사용하시던
--       비밀번호로 그대로 로그인하실 수 있습니다. 비밀번호를 변경하고 싶으시면 아래
--       버튼을 눌러주세요." 계열로 바꾸고, 버튼 문구도 "비밀번호 설정하기"보다
--       "비밀번호 변경하기"(선택 사항)에 가깝게 조정하는 것을 권한다.
--     - 신규 생성(promoted_at IS NULL)은 기존 문구("사용하실 비밀번호를 설정해
--       주세요")를 그대로 유지 — 이 경우는 링크 클릭이 로그인의 유일한 경로이므로
--       "설정"이 정확한 표현이다.
--     - 템플릿을 물리적으로 2개(admin-invite.html / admin-invite-promoted.html)로
--       나눌지, 1개 템플릿 안에서 {{is_promotion}} 조건부 블록으로 처리할지는 구현
--       세션 판단. 이 마이그레이션은 어느 쪽을 택하든 필요한 근거 컬럼만 제공한다.
--
-- 행 단위 보안 정책(RLS) 검토:
--   promoted_at 은 244 의 3개 컬럼과 동일하게 admins 기존 정책(admins_select·
--   admins_update)을 그대로 상속한다. 신규 정책 불필요. invite_admin() 은
--   SECURITY DEFINER 라 RLS 를 우회해 이 컬럼을 직접 쓴다(기존 admins INSERT 와 동일 경로).
--
-- 운영 데이터 영향:
--   - promoted_at 컬럼은 NULL 허용, 기존 행은 NULL로 시작(과거 이력 역산 안 함 — 이
--     함수 교체 이전에 일어난 승격은 "몰랐던 일"이 아니라 "이 컬럼이 없던 시절의 일"이므로
--     굳이 백필하지 않는다. 필요해지면 별도 판단).
--   - 함수 교체는 **앞으로의 초대 호출부터** 적용된다. 기존 관리자 세션·이미 발급된
--     비밀번호에는 영향 없음(supabase.md "관리자 추가" 절차·`invite_admin` 호출부인
--     dev/js/admin-accounts.js 는 이번 마이그레이션에서 변경하지 않음).
--
-- 롤백:
--   ALTER TABLE public.admins DROP COLUMN IF EXISTS promoted_at;
--   -- invite_admin() 함수 자체를 031 원본 동작으로 되돌리려면 031_admin_invite_and_delete.sql
--   -- 의 CREATE OR REPLACE 블록을 다시 실행할 것(승격 시 비밀번호를 다시 덮어쓰는 옛 동작으로
--   -- 복귀 — 이 변경의 목적을 되돌리는 것이므로 신중히 판단할 것).
-- ============================================================

BEGIN;

ALTER TABLE public.admins
  ADD COLUMN IF NOT EXISTS promoted_at timestamptz;

COMMENT ON COLUMN public.admins.promoted_at IS
  '[245] 이 관리자가 기존 auth.users 계정(주로 인플루언서로 먼저 가입한 사람)을 승격해 '
  '생성됐다면 그 시각. 신규로 생성된 관리자 계정은 NULL. invite_admin() 이 채움. '
  '초대 메일 문구를 승격/신규로 분기하려는 Edge Function notify-admin-invite 가 참조 가능.';

COMMIT;

CREATE OR REPLACE FUNCTION invite_admin(admin_email text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  existing_user_id uuid;
  new_user_id       uuid;
  target_user_id    uuid;
  temp_password     text;
  is_promotion      boolean := false;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;

  IF EXISTS (SELECT 1 FROM public.admins WHERE email = admin_email) THEN
    RAISE EXCEPTION 'Admin with this email already exists';
  END IF;

  SELECT id INTO existing_user_id FROM auth.users WHERE email = admin_email LIMIT 1;

  IF existing_user_id IS NOT NULL THEN
    -- ────────────────────────────────────────────────────────
    -- 승격: 기존 계정(주로 인플루언서)을 관리자로 올린다.
    -- [245] 비밀번호는 절대 건드리지 않는다 — 이미 본인이 쓰고 있는 유효한 비밀번호를
    -- 덮어쓸 기술적 필요가 없다(031 원본은 여기서 encrypted_password 를 임시 랜덤값으로
    -- 덮어써 그 사람의 기존 로그인을 즉시 끊었다).
    -- 로그인 차단 방지용 메타데이터 보정만 유지 — 전부 COALESCE 라 기존 값이 있으면
    -- 그대로 두고, 비어 있던 값만 채운다(부작용 없음).
    -- ────────────────────────────────────────────────────────
    is_promotion := true;

    UPDATE auth.users
       SET email_confirmed_at = COALESCE(email_confirmed_at, now()),
           email_change       = COALESCE(email_change, ''),
           raw_app_meta_data  = COALESCE(raw_app_meta_data, jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')))
     WHERE id = existing_user_id;

    target_user_id := existing_user_id;
  ELSE
    -- 신규 생성: 기존 031 동작과 완전히 동일. 임시 32자 랜덤 비밀번호(받는 사람은
    -- 초대 메일 링크로만 로그인 가능 — 이 경로가 유일한 로그인 수단이므로 여기서만
    -- temp_password 를 생성한다).
    temp_password := encode(extensions.gen_random_bytes(24), 'base64');

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

  INSERT INTO public.admins (auth_id, email, name, role, promoted_at)
  VALUES (target_user_id, admin_email, admin_name, admin_role, CASE WHEN is_promotion THEN now() ELSE NULL END);

  RETURN target_user_id;
END;
$$;

-- 시그니처(text, text, text) 가 031 원본과 동일 — CREATE OR REPLACE 는 기존 실행권한을
-- 보존하지만, 방어적으로 재실행해 둔다(무해·멱등).
GRANT EXECUTE ON FUNCTION public.invite_admin(text, text, text) TO authenticated;

COMMENT ON FUNCTION public.invite_admin(text, text, text) IS
  '[245] 관리자 초대. 기존 auth.users 계정 승격 시 비밀번호를 덮어쓰지 않음(031 원본은 '
  '임시 랜덤값으로 덮어써 기존 로그인을 끊었음). 승격 여부는 admins.promoted_at 에 기록. '
  '신규 생성 분기는 031 원본과 동일(임시 랜덤 비밀번호 + auth.identities 생성).';

-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor 에서 실행, 1단계씩 진행)
-- ============================================================

-- [1단계] 컬럼·함수 교체 확인
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='admins' AND column_name='promoted_at';
-- SELECT prosecdef FROM pg_proc WHERE proname='invite_admin' AND pronamespace='public'::regnamespace;
-- 기대: 컬럼 1행 / prosecdef = true

-- [2단계] 실행권한 보존 확인
-- SELECT grantee, privilege_type FROM information_schema.routine_privileges
--  WHERE routine_name = 'invite_admin';
-- 기대: authenticated 에 EXECUTE 있음

-- [3단계] 승격 시나리오 수동 검증(개발서버, 실제 초대 대신 SQL로 사전 확인 — 함수 자체는
--          super_admin 세션에서만 호출 가능하므로 화면/Edge Function 붙인 뒤 실제 확인 권장)
-- ⚠️ 아래는 함수 로직 확인용 참고이며 실제로는 반드시 관리자 계정 관리 화면에서 호출할 것.
-- 사전) 테스트 인플루언서 계정의 auth.users.encrypted_password 값을 기록해 둔다.
-- 사후) 같은 이메일로 초대 실행 후 auth.users.encrypted_password 가 사전 값과 동일한지 확인:
--   SELECT encrypted_password FROM auth.users WHERE email = '<테스트 이메일>';
-- 기대: 사전·사후 값이 완전히 동일(비밀번호가 안 바뀜) + admins.promoted_at 이 NOT NULL

-- [4단계] 신규 생성 시나리오 — auth.users 에 없던 새 이메일로 초대
-- SELECT promoted_at FROM public.admins WHERE email = '<신규 이메일>';
-- 기대: NULL (승격이 아니므로)
