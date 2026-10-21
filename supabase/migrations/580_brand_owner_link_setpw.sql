-- ============================================================
-- 580_brand_owner_link_setpw.sql
-- 브랜드 「연결 요청」 — 연결 4: 비밀번호 정하며 수락 서버 함수 (사양서 4-2 「새 함수(L8)」 · 작업표 기본값 3 · 결정 Q2)
-- 사양서: docs/specs/2026-10-21-brand-link-request.md · 작업표 docs/specs/2026-10-21-brand-link-request-breakdown.md 「연결 4」
--
-- 왜: 연결 요청을 받은 계정이 아직 비밀번호를 안 정했으면(관리자가 「계정 만들기」만 하고 설정 전) 로그인해서 수락할 수 없다.
--   링크에서 비밀번호를 정하며 바로 수락하게 한다. 비밀번호 저장은 공개 서버 함수 brand-link-request-accept(연결 7)가 인증 서비스로 하고,
--   그 앞뒤를 이 두 함수가 맡는다(서비스 키 전용).
--
-- 만드는 것
--   1) service_brand_link_request_setpw(p_link_id uuid, p_terms_version text) → jsonb {result, auth_id}
--      · 비밀번호를 저장하기 **전** 검사만 — 아무것도 쓰지 않는다
--      · result: ok · terms_version_required · invalid_link · owner_exists · already_member · password_already_set
--      · 순서: 약관 버전 → 줄(대기·연결 요청) → _brand_invite_acceptable → 활성 대표 없음 → 이미 연결 아님 → 받는 계정 비밀번호가 **안 정해졌어야**
--        (공용 본체 579 _brand_accept_owner_link ①~③과 같은 판정, ④는 반대)
--   2) service_brand_link_request_finalize(p_link_id uuid, p_terms_version text) → jsonb {result, brand_id, email}
--      · 비밀번호 저장 **뒤** 부른다. result: ok · terms_version_required · invalid_link · owner_exists · already_member · password_already_set · password_not_set
--      · 잠금 브랜드 → 이메일 → 줄 재독 → 받는 계정 행 잠금 → password_set_at 이 이미 있으면 password_already_set(아무것도 안 씀)
--        → auth.users.encrypted_password 가 비면 password_not_set(532 마무리와 같은 확인)
--        → password_set_at·password_changed_at = now() · setup_link_id = NULL(옛 설정 링크 무효 — 남기면 「재설정」 종류로 유효 판정이 된다, 의심 7·기본값 3)
--        → 579 _brand_accept_owner_link(본체 invalid 는 invalid_link 로)
--      · 🔴 본체가 거부하면(owner_exists 등) 위 비밀번호 기록도 되돌린다 — 함수 안 하위 블록(저장점)에서 일부러 오류(BL001)를 내 되감는다.
--        인증 서비스 쪽 비밀번호는 저장된 채 남는다(사양서 5-7) — 그때 링크 판정은 existing_setpw 로 남아 처음부터 다시 된다
--      · 성공 응답의 email 은 화면이 새 비밀번호로 바로 로그인하는 데 쓴다(작업표 stale 9). brand_id 는 ok·owner_exists·already_member·password_already_set·
--        password_not_set 때 실리고 invalid_link·terms_version_required 면 NULL. 같은 링크로 두 번 제출하면 둘째는 invalid_link(줄이 이미 accepted)
--   3) get_brand_invite_link_state(베이스 579, CREATE OR REPLACE 로만 — 비로그인 권한 유지) — 연결 요청이고 받는 계정 password_set_at 이 비었으면
--      recipient='existing_setpw' + email(Q2 — 읽기 전용 이메일 칸). existing 갈래는 그대로 이메일 없음
--   · 두 함수 실행 권한 postgres·service_role 만(호출자 검사 없음 — 링크 번호만 받는다)
--
-- 🔴 개발서버 적용 → 연결 7 배포 → 연결 9 병합을 같은 날(조율 세션의 「적용해」 신호). 이 파일만 들어가고 화면이 옛것이면 비밀번호 없는 계정이
--    링크에서 갇힌다(작업표 의심 3).
-- 🔴 다음 재정의 베이스: get_brand_invite_link_state 는 이 파일.
-- 편집기 경고: 안 뜸(DROP 없음).
--   2026-10-21 개발서버 적용(기록 표 580 줄 15:15:09 JST — 연결 7·9 리뷰 통과 신호 뒤) · 두 함수 권한 postgres·service_role 만
--   비밀번호 정하며 수락 실제 흐름은 연결 7 공개 함수 배포 뒤 그 화면(연결 9)으로 확인
-- 롤백(연결 9·7 을 먼저 되돌린다): DROP FUNCTION service_brand_link_request_setpw(uuid,text), service_brand_link_request_finalize(uuid,text)
--   → 579 의 get_brand_invite_link_state 블록 재실행
-- ============================================================
BEGIN;

-- ── 1. 비밀번호 저장 전 검사 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.service_brand_link_request_setpw(p_link_id uuid, p_terms_version text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terms text := NULLIF(btrim(COALESCE(p_terms_version, '')), '');
  v_pre   public.brand_invites%ROWTYPE;
  v_inv   public.brand_invites%ROWTYPE;
  v_acct  public.brand_accounts%ROWTYPE;
BEGIN
  IF v_terms IS NULL THEN
    RETURN jsonb_build_object('result', 'terms_version_required', 'auth_id', NULL);
  END IF;
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'auth_id', NULL);
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'auth_id', NULL);
  END IF;

  -- 같은 열쇠로 읽는다(그사이 취소·수락·다시 발급과 겹치지 않게)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id;
  IF NOT FOUND OR v_inv.link_id <> p_link_id OR v_inv.status <> 'pending' OR v_inv.invite_kind <> 'owner_link'
     OR v_inv.sent_owner_auth_id IS NULL
     OR NOT public._brand_invite_acceptable(v_inv.id, v_inv.sent_owner_auth_id, true) THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'auth_id', NULL);
  END IF;

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = v_inv.brand_id AND l.role = 'owner' AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'owner_exists', 'auth_id', NULL);
  END IF;
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = v_inv.brand_id AND l.auth_id = v_inv.sent_owner_auth_id AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'already_member', 'auth_id', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_inv.sent_owner_auth_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'auth_id', NULL);
  END IF;
  IF v_acct.password_set_at IS NOT NULL THEN
    RETURN jsonb_build_object('result', 'password_already_set', 'auth_id', NULL);
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'auth_id', v_acct.auth_id);
END;
$$;

COMMENT ON FUNCTION public.service_brand_link_request_setpw(uuid, text) IS
  '[580] 서비스 키 전용(연결 7 공개 함수). 연결 요청 「비밀번호 정하며 수락」 — 비밀번호 저장 전 검사만(쓰지 않음). 약관 버전 → 줄(대기·연결 요청) → _brand_invite_acceptable → 활성 대표 없음 → 이미 연결 아님 → 받는 계정 비밀번호 미설정. 반환 {result: ok|terms_version_required|invalid_link|owner_exists|already_member|password_already_set, auth_id}.';

GRANT  EXECUTE ON FUNCTION public.service_brand_link_request_setpw(uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_brand_link_request_setpw(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_brand_link_request_setpw(uuid, text) FROM anon, authenticated;

-- ── 2. 비밀번호 저장 뒤 마무리 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.service_brand_link_request_finalize(p_link_id uuid, p_terms_version text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terms text := NULLIF(btrim(COALESCE(p_terms_version, '')), '');
  v_pre   public.brand_invites%ROWTYPE;
  v_inv   public.brand_invites%ROWTYPE;
  v_acct  public.brand_accounts%ROWTYPE;
  v_pw    text;
  v_res   text;
BEGIN
  IF v_terms IS NULL THEN
    RETURN jsonb_build_object('result', 'terms_version_required', 'brand_id', NULL, 'email', NULL);
  END IF;
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'brand_id', NULL, 'email', NULL);
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'brand_id', NULL, 'email', NULL);
  END IF;

  -- 브랜드 → 이메일 (본체와 같은 열쇠 — 본체가 다시 잡아도 같은 거래라 안전)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR v_inv.link_id <> p_link_id OR v_inv.status <> 'pending' OR v_inv.invite_kind <> 'owner_link'
     OR v_inv.sent_owner_auth_id IS NULL THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'brand_id', NULL, 'email', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_inv.sent_owner_auth_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid_link', 'brand_id', NULL, 'email', NULL);
  END IF;
  IF v_acct.password_set_at IS NOT NULL THEN
    RETURN jsonb_build_object('result', 'password_already_set', 'brand_id', v_inv.brand_id, 'email', NULL);
  END IF;

  -- 비밀번호가 실제로 정해졌는지(532 service_brand_invite_finalize 와 같은 확인)
  SELECT u.encrypted_password INTO v_pw FROM auth.users u WHERE u.id = v_acct.auth_id;
  IF v_pw IS NULL OR v_pw = '' THEN
    RETURN jsonb_build_object('result', 'password_not_set', 'brand_id', v_inv.brand_id, 'email', NULL);
  END IF;

  -- 비밀번호 기록 + 본체. 본체가 거부하면 저장점까지 되감아 비밀번호 기록도 없던 일로(v_res 는 남는다)
  BEGIN
    UPDATE public.brand_accounts
       SET password_set_at     = now(),
           password_changed_at = now(),
           setup_link_id       = NULL      -- 옛 설정 링크 무효(기본값 3)
     WHERE auth_id = v_acct.auth_id;

    v_res := public._brand_accept_owner_link(v_inv.id, v_acct.auth_id, v_terms);
    IF v_res IS DISTINCT FROM 'ok' THEN
      RAISE EXCEPTION 'owner_link_accept_rejected' USING ERRCODE = 'BL001';
    END IF;
  EXCEPTION WHEN SQLSTATE 'BL001' THEN
    NULL;   -- 되감김. v_res 로 결과를 돌려준다
  END;

  IF v_res = 'ok' THEN
    RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id, 'email', v_acct.email);
  END IF;
  -- 본체 invalid·setup_incomplete(이 경로에선 도달 불가 — 방금 비밀번호를 기록했다)는 invalid_link 로 묶는다
  RETURN jsonb_build_object('result', CASE WHEN v_res IN ('owner_exists', 'already_member') THEN v_res ELSE 'invalid_link' END,
                            'brand_id', CASE WHEN v_res IN ('owner_exists', 'already_member') THEN v_inv.brand_id ELSE NULL END,
                            'email', NULL);
END;
$$;

COMMENT ON FUNCTION public.service_brand_link_request_finalize(uuid, text) IS
  '[580] 서비스 키 전용(연결 7 공개 함수). 연결 요청 「비밀번호 정하며 수락」 마무리(비밀번호 저장 뒤) — 브랜드→이메일 잠금 → 줄 재독 → 받는 계정 비밀번호 기록 전이었는지 → auth 비밀번호 실재 → password_set_at·password_changed_at·setup_link_id=NULL → _brand_accept_owner_link(거부면 비밀번호 기록도 되감음). 반환 {result: ok|terms_version_required|invalid_link|owner_exists|already_member|password_already_set|password_not_set, brand_id, email(성공 때만)}.';

GRANT  EXECUTE ON FUNCTION public.service_brand_link_request_finalize(uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_brand_link_request_finalize(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_brand_link_request_finalize(uuid, text) FROM anon, authenticated;

-- ── 3. 링크 판정 — existing_setpw 갈래 (베이스 579 · CREATE OR REPLACE 로만) ──────────
CREATE OR REPLACE FUNCTION public.get_brand_invite_link_state(p_link_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv       public.brand_invites%ROWTYPE;
  v_acct      public.brand_accounts%ROWTYPE;
  v_owner     jsonb;
  v_recipient text;
  v_brand     text;
  v_result    jsonb;
BEGIN
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND OR NOT public._brand_invite_acceptable(v_inv.id, NULL, true) THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  IF v_inv.recipient_kind = 'brand' THEN
    v_recipient := 'existing';
  ELSE
    v_owner := public._brand_email_owner(v_inv.email, NULL);
    IF v_owner->>'kind' = 'none' THEN
      v_recipient := 'new';
    ELSE
      SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = NULLIF(v_owner->>'auth_id', '')::uuid;
      IF FOUND AND v_acct.created_via_invite_id = v_inv.id AND v_acct.password_set_at IS NULL THEN
        v_recipient := 'new';        -- 예외 1: 같은 초대의 재시도 — 새 이메일 경로를 이어간다
      ELSE
        v_recipient := 'existing';   -- 예외 2(S0-4): 비밀번호를 정한 브랜드 계정 — 로그인해서 수락
      END IF;
    END IF;
  END IF;

  -- 580: 연결 요청인데 받는 계정이 비밀번호를 아직 안 정했으면 「비밀번호 정하며 수락」 화면으로(L8)
  IF v_inv.invite_kind = 'owner_link' AND v_recipient = 'existing'
     AND EXISTS (SELECT 1 FROM public.brand_accounts a
                  WHERE a.auth_id = v_inv.sent_owner_auth_id AND a.password_set_at IS NULL) THEN
    v_recipient := 'existing_setpw';
  END IF;

  SELECT b.name INTO v_brand FROM public.brands b WHERE b.id = v_inv.brand_id;

  v_result := jsonb_build_object(
    'state',        'valid',
    'recipient',    v_recipient,
    'invite_kind',  v_inv.invite_kind,   -- 579: member | owner_link (두 갈래 모두)
    'brand_name',   v_brand,
    'inviter_name', v_inv.inviter_name,
    'issued_at',    v_inv.issued_at,      -- 534: w01-03 「받은 날」 (두 갈래 모두)
    'expires_at',   v_inv.expires_at
  );

  -- 534: 새 이메일 초대일 때만 초대 줄의 이메일을 싣는다(w01-02b 읽기 전용 칸). existing 에는 싣지 않는다.
  IF v_recipient IN ('new', 'existing_setpw') THEN   -- 580: existing_setpw 도 읽기 전용 이메일 칸(Q2)
    v_result := v_result || jsonb_build_object('email', v_inv.email);
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_brand_invite_link_state(uuid) IS
  '[580] (579 재정의 — 연결 요청 + 받는 계정 비밀번호 미설정이면 recipient=existing_setpw + email)  초대 메일 링크 판정(비로그인 가능). 수락 가능이면 {state:valid, recipient:new|existing, brand_name, inviter_name, issued_at, expires_at} + recipient=new 일 때만 email, 아니면 {state:invalid} 한 칸. 판정은 _brand_invite_acceptable(id, NULL, true). 링크 소지자에게 브랜드·보낸 사람 이름을 주는 것은 의도된 예외(작업표 어긋남 3번). 링크 소지자에게 새 이메일 초대의 이메일을 주는 것은 사용자 결정(피그마 w01-02b 읽기 전용 이메일 칸 — 작업표 S0-2, 2026-10-15). 전달받은 사람에게도 보인다. 베이스 532.';
GRANT  EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '580', '580_brand_owner_link_setpw.sql');
COMMIT;
