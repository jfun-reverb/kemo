-- ============================================================
-- 573_brand_owner_account_lock_and_check_name.sql
-- 관리자 브랜드 상세 탭 재구성 — 작업 1(533 함수 둘 손보기 · 사양서 5-3·5-4)
-- 사양서: docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md
--
-- 🔴 다음에 이 두 함수를 다시 정의할 때 베이스는 **이 파일**이다(533·527 을 베이스로 잡으면 아래 셋이 사라진다).
--
-- 바꾸는 것 (나머지 본문은 533 과 글자 그대로 — 이름·인자·반환형·실행 권한 그대로, CREATE OR REPLACE)
--   1) admin_upsert_brand_owner_account
--      ① 활성 대표가 있고 비밀번호 설정 전인데 대표 줄 이메일이 바뀐 갈래(533 갈래 ④)
--         → 계정·인증 정보·연결을 아무것도 안 바꾸고 result = 'email_change_locked'(needs_mail false).
--         계정이 있는 동안 대표 이메일은 잠긴다(D9). 바꾸려면 해제 → 담당자 이메일 고치기 → 계정 만들기.
--         (그 결과 'email_replaced' 는 더 나오지 않는다)
--      ② 활성 대표가 없는데 대표 줄 이메일이 이미 있는 브랜드 계정의 것이면(533 갈래 (1)의 brand)
--         → 해제된 계정이어도 연결을 만들지 않고 'conflict_brand'. 본인 수락 없는 연결을 막는다(§16-8 —
--         수락 길인 「연결 요청」은 별도 작업표, 작업표 결정 S1=A).
--   2) admin_check_brand_account_email
--      ③ email_kind 가 influencer·admin 이면 name = NULL(D6 — 관리자 화면에도 어느 계정인지 알리지 않는다).
--         brand 일 때의 이름·연결 수·해제 이력은 그대로(연결 요청 창 a03-01c 가 쓴다).
--
-- 화면 영향: 옛 관리자 브랜드 상세(_brandAccountResultMessage, admin-brand.js)는 'email_change_locked' 를 모른다 →
--   개발서버에서 설정 전 대표 이메일을 바꿔 저장하면 「결과를 알 수 없습니다 [email_change_locked]」가 뜬다.
--   운영은 계정 기능이 꺼져 이 함수를 부르지 않는다. 새 페이지(작업 5·11)가 대신하므로 옛 화면은 고치지 않는다.
--
-- 편집기 경고: 안 뜸(2026-10-21 개발서버 적용 — 기록 표 줄 12:13 JST)
-- 개발서버 실제 호출(2026-10-21, 로그인 관리자 콘솔 · 시험 브랜드 「시험브랜드0923…」, 끝난 뒤 담당자 원래 값으로 되돌림·연결 해제):
--   ① 해제된 브랜드 계정 이메일을 대표로 → conflict_brand, 그 계정 연결 줄 2 → 2(새 줄 없음)
--   ② 새 이메일로 계정 만들기(created, 설정 전) 뒤 대표 이메일 변경 → email_change_locked, 로그인 이메일 그대로
--   ③ 겹침 확인: 인플루언서·관리자 이메일 name null / 브랜드 계정 이메일은 이름·연결 수 그대로
--   (②에서 만든 로그인 계정 zz-573-owner@example.com 은 지울 함수가 없어 남는다 — 연결 없음)
-- 롤백: 533 의 두 함수 블록(388~639줄 · 725~784줄)을 그대로 다시 실행.
-- ============================================================
BEGIN;

-- ── 1. admin_upsert_brand_owner_account (재정의 — 베이스 533) ─────────────
CREATE OR REPLACE FUNCTION public.admin_upsert_brand_owner_account(
  p_brand_id        uuid,
  p_prev_contact_id text,
  p_prev_email      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status     text;
  v_contacts   jsonb;
  v_prim       jsonb;
  v_cur_id     text;
  v_email      text;
  v_prev_email text;
  v_name       text;
  v_phone      text;
  v_link       public.brand_account_links%ROWTYPE;
  v_acct       public.brand_accounts%ROWTYPE;
  v_owner      jsonb;
  v_kind       text;
  v_owner_id   uuid;
  v_new_id     uuid;
  v_result     text;
  v_needs      boolean := false;
  v_auth       uuid;
  v_acct_email text;
  v_moved      boolean;
  v_cname      text;
BEGIN
  -- (0) 가드·입력 검사 -------------------------------------------------
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'needs_mail', false);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'needs_mail', false);
  END IF;

  -- 브랜드 단위 직렬화(같은 브랜드를 두 관리자가 동시에 저장해도 연결이 둘 생기지 않게)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT b.status, COALESCE(b.contacts, '[]'::jsonb)
    INTO v_status, v_contacts
    FROM public.brands b
   WHERE b.id = p_brand_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'needs_mail', false);
  END IF;
  IF v_status <> 'active' THEN
    RETURN jsonb_build_object('result', 'brand_archived', 'needs_mail', false, 'brand_id', p_brand_id);
  END IF;

  -- 대표 줄 = contacts 의 is_primary 줄(여럿이면 앞선 것)
  IF jsonb_typeof(v_contacts) = 'array' THEN
    SELECT e.elem INTO v_prim
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
     WHERE e.elem->>'is_primary' = 'true'
     ORDER BY e.ord
     LIMIT 1;
  END IF;

  v_email := lower(btrim(COALESCE(v_prim->>'email', '')));
  IF v_prim IS NULL OR v_email = '' THEN
    RETURN jsonb_build_object('result', 'no_primary_email', 'needs_mail', false, 'brand_id', p_brand_id);
  END IF;
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
  END IF;

  v_cur_id     := NULLIF(btrim(COALESCE(v_prim->>'id', '')), '');
  v_name       := NULLIF(btrim(COALESCE(v_prim->>'name', '')), '');
  v_phone      := NULLIF(btrim(COALESCE(v_prim->>'phone', '')), '');
  v_prev_email := lower(btrim(COALESCE(p_prev_email, '')));
  v_moved      := p_prev_contact_id IS NOT NULL AND v_cur_id IS NOT NULL AND p_prev_contact_id <> v_cur_id;

  -- 같은 이메일을 두고 다투는 호출(서로 다른 브랜드)도 직렬화한다
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  SELECT l.* INTO v_link
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active';

  IF NOT FOUND THEN
    -- (1) 활성 대표 연결 없음 — 이전 값은 보지 않는다(P-2) ----------------
    v_owner    := public._brand_email_owner(v_email, NULL);
    v_kind     := v_owner->>'kind';
    v_owner_id := NULLIF(v_owner->>'auth_id', '')::uuid;

    IF v_kind = 'admin' THEN
      RETURN jsonb_build_object('result', 'conflict_admin', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    ELSIF v_kind = 'influencer' THEN
      RETURN jsonb_build_object('result', 'conflict_influencer', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    ELSIF v_kind = 'brand' THEN
      -- 573: 이미 있는 브랜드 계정은 본인 수락 없이 잇지 않는다(사양서 §16-8 「연결 요청」 — 별도 작업표).
      --   다른 브랜드에 연결돼 있든 해제된 계정이든 연결을 만들지 않고 거부만 한다.
      RETURN jsonb_build_object('result', 'conflict_brand', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    ELSE
      -- 아무도 안 쓰는 이메일 — 계정 새로 만들기(417 방식 직접 삽입)
      v_new_id := gen_random_uuid();
      BEGIN
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
          v_new_id, 'authenticated', 'authenticated', v_email,
          '',                      -- 비밀번호 미설정 — 로그인 불가 상태(설정 링크로만 정해진다)
          now(), now(), now(),
          '', '', '', '', '', '', '', '',
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'account_kind', 'brand'),
          jsonb_build_object('sub', v_new_id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false)
        );
        INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
        VALUES (
          gen_random_uuid(), v_new_id,
          jsonb_build_object('sub', v_new_id::text, 'email', v_email, 'email_verified', true),
          'email', v_new_id::text, now(), now()
        );
        INSERT INTO public.brand_accounts (auth_id, email, name, phone, created_by)
        VALUES (v_new_id, v_email, v_name, v_phone, auth.uid());
        INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id)
        VALUES (v_new_id, p_brand_id, 'owner', 'active', v_cur_id);
      EXCEPTION WHEN unique_violation THEN
        -- 부분 삽입은 이 블록 안에서 되돌려진다. 동시에 같은 이메일로 다른 경로가 계정을 만든 드문 경우.
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        RETURN jsonb_build_object(
          'result', CASE WHEN v_cname LIKE 'brand_account%' THEN 'conflict_brand' ELSE 'conflict_influencer' END,
          'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
      END;
      v_result     := 'created';
      v_needs      := true;
      v_auth       := v_new_id;
      v_acct_email := v_email;
    END IF;

  ELSE
    -- (2) 활성 대표 연결 있음(계정 A) ------------------------------------
    SELECT ba.* INTO v_acct FROM public.brand_accounts ba WHERE ba.auth_id = v_link.auth_id FOR UPDATE;
    v_auth       := v_acct.auth_id;
    v_acct_email := v_acct.email;

    IF v_email = v_acct.email OR v_email = v_prev_email THEN
      -- ① 로그인 이메일과 같음 / ② 이번 저장에서 이메일이 안 바뀜
      v_result := 'noop';
      IF v_email = v_acct.email THEN
        -- 이 줄이 A 의 대표 줄이다 — 근거 줄 id·이름·전화를 현재 값으로 맞춘다(메일은 없음)
        IF v_link.source_contact_id IS DISTINCT FROM v_cur_id THEN
          UPDATE public.brand_account_links SET source_contact_id = v_cur_id WHERE id = v_link.id;
        END IF;
        IF v_acct.name IS DISTINCT FROM v_name OR v_acct.phone IS DISTINCT FROM v_phone THEN
          UPDATE public.brand_accounts SET name = v_name, phone = v_phone WHERE auth_id = v_acct.auth_id;
        END IF;
      END IF;

    ELSIF v_moved THEN
      -- ③ 대표 표시가 다른 줄로 옮겨짐 — 옛 계정 유지, 메일 없음
      v_result := 'primary_moved';

    ELSIF v_acct.password_set_at IS NULL THEN
      -- ④ 설정 전 이메일 수정 — 573: 계정 이메일을 바꾸지 않고 거부한다(사양서 5-3 · D9 — 계정이 있는 동안 대표 이메일 잠금).
      --   바꾸려면 「해제 → 담당자 이메일 고치기 → 계정 만들기」. 다른 칸은 지금 값 그대로 돌려준다.
      RETURN jsonb_build_object('result', 'email_change_locked', 'needs_mail', false, 'email', v_email,
                                'auth_id', v_auth, 'account_email', v_acct.email, 'brand_id', p_brand_id);

    ELSE
      -- ⑤ 설정 뒤 이메일 수정 — 로그인 이메일 유지
      v_result := 'password_already_set';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'result',        v_result,
    'needs_mail',    v_needs,
    'email',         v_email,
    'auth_id',       v_auth,
    'account_email', v_acct_email,
    'brand_id',      p_brand_id
  );
END;
$$;

COMMENT ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) IS
  '[573] (533 재정의: 갈래 ④ 설정 전 이메일 교체 → email_change_locked 거부 · 활성 대표 없을 때 이메일이 브랜드 계정이면 연결 없이 conflict_brand) 브랜드 대표 담당자 계정 만들기(안쪽 재확인). 판정 규칙은 527 머리말 B 표 + 573 머리말. 반환 jsonb: result·needs_mail·email·auth_id·account_email·brand_id.
   result = created·noop·email_change_locked·password_already_set·primary_moved·conflict_influencer·conflict_admin·conflict_brand·no_primary_email·invalid_email·brand_not_found·brand_archived·forbidden. (email_replaced 는 573 부터 나오지 않는다)';

GRANT  EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM anon;

-- ── 2. admin_check_brand_account_email (재정의 — 베이스 533) ─────────────
CREATE OR REPLACE FUNCTION public.admin_check_brand_account_email(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email  text := lower(btrim(COALESCE(p_email, '')));
  v_owner  jsonb;
  v_kind   text;
  v_id     uuid;
  v_name   text;
  v_linked integer := 0;
  v_rel    boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'email_kind', NULL, 'name', NULL,
                              'linked_brand_count', 0, 'released_from_this_brand', false);
  END IF;

  v_owner := public._brand_email_owner(v_email, NULL);
  v_kind  := v_owner->>'kind';
  v_id    := NULLIF(v_owner->>'auth_id', '')::uuid;

  IF v_kind = 'brand' THEN
    SELECT a.name INTO v_name FROM public.brand_accounts a WHERE a.auth_id = v_id;
    SELECT count(*)::int INTO v_linked
      FROM public.brand_account_links l
      JOIN public.brands b ON b.id = l.brand_id
     WHERE l.auth_id = v_id AND l.status = 'active';
    v_rel := p_brand_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.brand_account_links l
       WHERE l.auth_id = v_id AND l.brand_id = p_brand_id AND l.status = 'released');
  -- 573: 인플루언서·관리자 이메일이면 이름을 돌려주지 않는다(사양서 5-4 · D6 — 어느 계정인지 알리지 않는다). 종류만.
  END IF;

  RETURN jsonb_build_object(
    'result',                  'ok',
    'email_kind',              v_kind,
    'name',                    v_name,
    'linked_brand_count',      v_linked,
    'released_from_this_brand', v_rel
  );
END;
$$;

COMMENT ON FUNCTION public.admin_check_brand_account_email(uuid, text) IS
  '[573] (533 재정의: influencer·admin 이면 name 을 NULL 로) 계정 만들기 전 겹침 확인 조회(관리자 전원, 아니면 42501). 반환 {result: ok|invalid_email, email_kind: none|brand|influencer|admin, name(brand 일 때만 — 브랜드 계정 이름), linked_brand_count(활성 연결 수 — brand 만), released_from_this_brand(이 브랜드에서 해제된 연결 이력 — brand 만)}.';

GRANT  EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) FROM anon;

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '573', '573_brand_owner_account_lock_and_check_name.sql');
COMMIT;
