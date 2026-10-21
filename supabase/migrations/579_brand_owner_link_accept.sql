-- ============================================================
-- 579_brand_owner_link_accept.sql
-- 브랜드 「연결 요청」 — 연결 3: 받는 쪽 수락 + 약관 기록 (사양서 4-2 받는 쪽 · L3·B4·B5·B6 · 작업표 기본값 4·8 · 결정 Q1)
-- 사양서: docs/specs/2026-10-21-brand-link-request.md · 작업표 docs/specs/2026-10-21-brand-link-request-breakdown.md 「연결 3」
--
-- 만드는 것
--   1) _brand_accept_owner_link(p_invite_id uuid, p_auth_id uuid, p_terms_version text) → text (기본값 8)
--      · 연결 요청 수락의 유일한 본체 — respond_brand_invite(수락 갈래)와 연결 4 의 service_brand_link_request_finalize 가 부른다(사본 금지)
--      · 결과: ok · invalid · owner_exists · already_member · setup_incomplete
--      · 잠금 브랜드(brand_account_upsert:) → 이메일(brand_account_email:) — 부르는 쪽이 이미 잡았어도 같은 열쇠로 다시 잡는다(같은 거래 안 재진입은 안전)
--      · 순서: ①줄 재독(FOR UPDATE) — pending · owner_link · sent_owner_auth_id = p_auth_id 아니면 invalid(두 번 누르기·취소된 줄·다른 계정)
--        ②_brand_invite_acceptable(줄, 계정, false) — 만료·브랜드 활성·계정 이메일 일치·보낼 때 계정 그대로 아니면 invalid
--        ③활성 대표 있으면 owner_exists(B4 — 줄은 그대로) · 그 계정이 이미 이 브랜드에 활성 연결이면 already_member
--        ④계정 비밀번호 미설정이면 setup_incomplete(연결 4 는 비밀번호를 먼저 기록하고 부른다)
--        ⑤대표 연결 새 줄(해제된 옛 연결이 있어도 새 줄) → _brand_contacts_mark_primary(574 — 담당자 대표 표시·옛 대표 칸 셋, 없으면 줄을 더한다)
--          → 대표 줄 아이디를 연결의 source_contact_id 로(533 즉시 연결과 같은 처리 — 573 다음 저장이 noop 으로 알아본다)
--          → 약관 셋 기록(Q1 — 지금 칸에 덮어쓰기) → 줄 accepted
--      · 🔴 호출자 검사가 없다(받는 계정 아이디를 인자로 받는다) — 실행 권한 postgres·service_role 만. 실행 권한이 유일한 방어선
--      · 약관 버전이 비면 invalid(부르는 쪽이 terms_version_required 를 먼저 돌려준다 — 방어)
--   2) respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text, p_terms_version text DEFAULT NULL) — 옛 3인자 판 DROP 뒤 생성
--      · 수락이고 약관 버전이 비면 맨 앞에서 terms_version_required(결과 값 — 532 complete_brand_account_setup 은 예외를 던진다. 다르다: 기본값 4)
--      · 잠금 안 줄 재독 직후 연결 요청 줄 수락이면 곧바로 본체 결과를 {result, brand_id} 로(invalid 면 brand_id NULL)
--      · 멤버 초대 수락은 532 순서 그대로 + 성공 때 같은 거래에서 약관 셋 기록. 거절은 종류 무관 532 그대로(상태만)
--      · 결과: ok · already_member · invalid · not_brand · setup_incomplete + owner_exists · terms_version_required
--      · 화면은 이름 붙인 인자로 부르므로 옛 화면(약관 없이 3인자)도 새 판을 찾는다 — 수락은 terms_version_required 로 막힌다(연결 8 이 같은 날 병합)
--   3) 577 임시 막음 해제: _brand_acceptable_invites_for(532 본문으로) · get_brand_invite_link_state(+ invite_kind 칸, 두 갈래 모두)
--   4) get_my_brand_invites(베이스 532) — 줄마다 invite_kind
--   · existing_setpw 갈래(비밀번호 안 정한 계정의 연결 요청 링크)는 연결 4. 그 전에는 그 계정이 링크에서 existing 으로 보여 로그인 화면에 막힌다(작업표 의심 3 — 짧게)
--
-- 🔴 개발서버 적용은 세션 C 의 연결 8(브랜드 화면 ①) 병합 요청이 리뷰를 통과한 날, 적용 직후 연결 8 병합(조율 세션의 「적용해」 신호).
-- 🔴 다음 재정의 베이스: respond_brand_invite·_brand_acceptable_invites_for·get_brand_invite_link_state·get_my_brand_invites 는 이 파일(532·534·577 베이스 금지).
-- 🔴 수락 본체는 정의자 권한 함수 안에서 담당자 목록을 고친다 — 576 직접 고치기 막기 트리거(current_user='authenticated' 판정)를 통과해야 한다(작업표 의심 9).
-- 편집기 경고: 뜸 — 「destructive operations」(DROP FUNCTION respond_brand_invite 3인자). 「Run query」.
--   2026-10-21 개발서버 적용(기록 표 579 줄 15:10:53 JST — 연결 8 화면 #2258 리뷰 통과 신호 뒤) · respond_brand_invite 4인자 한 벌 · 본체 권한 postgres·service_role 만
--   실제 수락 시험(2026-10-21, 연결 8 병합 뒤 · zz-b2-second 로그인 · 시험브랜드0923): 약관 없이 terms_version_required ·
--   마이페이지 카드 약관 체크 + 「수락」 → 대표 연결 active·source_contact_id=새 대표 담당자 줄 · 담당자·대표 칸 셋(576 트리거 통과) ·
--   약관 칸 셋 기록 · 관리자 상태 active·owner_link_request null. 정리: 관리자 해제 + 담당자 삭제
-- 롤백(연결 8 을 먼저 되돌린다): DROP FUNCTION respond_brand_invite(uuid,uuid,text,text) → 577 의 respond_brand_invite 블록(3인자) 재실행 +
--   GRANT postgres·authenticated·service_role / REVOKE PUBLIC·anon → 577 의 _brand_acceptable_invites_for·get_brand_invite_link_state 블록 재실행 →
--   532 의 get_my_brand_invites 블록 재실행 → DROP FUNCTION _brand_accept_owner_link(uuid,uuid,text)
-- ============================================================
BEGIN;

-- ── 1. 연결 요청 수락 본체 (내부 전용) ─────────────────────────────
CREATE OR REPLACE FUNCTION public._brand_accept_owner_link(p_invite_id uuid, p_auth_id uuid, p_terms_version text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terms   text := NULLIF(btrim(COALESCE(p_terms_version, '')), '');
  v_pre     public.brand_invites%ROWTYPE;
  v_inv     public.brand_invites%ROWTYPE;
  v_acct    public.brand_accounts%ROWTYPE;
  v_prim_id text;
BEGIN
  IF p_invite_id IS NULL OR p_auth_id IS NULL OR v_terms IS NULL THEN
    RETURN 'invalid';
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF NOT FOUND THEN RETURN 'invalid'; END IF;

  -- 브랜드 → 이메일 (527·531·532·533·578 과 같은 열쇠·순서)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  -- ① 줄 재독
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR v_inv.status <> 'pending' OR v_inv.invite_kind <> 'owner_link'
     OR v_inv.sent_owner_auth_id IS DISTINCT FROM p_auth_id THEN
    RETURN 'invalid';
  END IF;

  -- ② 수락 가능(만료·브랜드 활성·계정 이메일 = 요청 이메일·보낼 때 계정 그대로)
  IF NOT public._brand_invite_acceptable(v_inv.id, p_auth_id, false) THEN
    RETURN 'invalid';
  END IF;

  -- ③ 대표·연결
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = v_inv.brand_id AND l.role = 'owner' AND l.status = 'active') THEN
    RETURN 'owner_exists';
  END IF;
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = v_inv.brand_id AND l.auth_id = p_auth_id AND l.status = 'active') THEN
    RETURN 'already_member';
  END IF;

  -- ④ 비밀번호
  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = p_auth_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'invalid'; END IF;
  IF v_acct.password_set_at IS NULL THEN
    RETURN 'setup_incomplete';
  END IF;

  -- ⑤ 대표로 넣기
  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
  VALUES (p_auth_id, v_inv.brand_id, 'owner', 'active');
  PERFORM public._brand_contacts_mark_primary(v_inv.brand_id, p_auth_id);

  SELECT NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') INTO v_prim_id
    FROM public.brands b,
         jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts) = 'array' THEN b.contacts ELSE '[]'::jsonb END) WITH ORDINALITY AS e(elem, ord)
   WHERE b.id = v_inv.brand_id AND e.elem->>'is_primary' = 'true'
   ORDER BY e.ord
   LIMIT 1;
  IF v_prim_id IS NOT NULL THEN
    UPDATE public.brand_account_links SET source_contact_id = v_prim_id
     WHERE brand_id = v_inv.brand_id AND auth_id = p_auth_id AND status = 'active';
  END IF;

  UPDATE public.brand_accounts
     SET terms_agreed_at = now(), privacy_agreed_at = now(), terms_version = v_terms
   WHERE auth_id = p_auth_id;

  UPDATE public.brand_invites
     SET status = 'accepted', accepted_at = now(), accepted_auth_id = p_auth_id
   WHERE id = v_inv.id;

  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public._brand_accept_owner_link(uuid, uuid, text) IS
  '[579] 내부 전용. 연결 요청 수락의 유일한 본체(respond_brand_invite 수락 갈래 · service_brand_link_request_finalize). 브랜드→이메일 잠금 → 줄 재독(pending·owner_link·받는 계정) → _brand_invite_acceptable → 활성 대표면 owner_exists · 이미 연결이면 already_member → 비밀번호 미설정이면 setup_incomplete → 대표 연결 + 담당자 대표 표시(574) + source_contact_id + 약관 셋 기록 + 줄 accepted. 반환 ok|invalid|owner_exists|already_member|setup_incomplete. 호출자 검사 없음 — postgres·service_role 만 실행.';

GRANT  EXECUTE ON FUNCTION public._brand_accept_owner_link(uuid, uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_accept_owner_link(uuid, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_accept_owner_link(uuid, uuid, text) FROM anon, authenticated;

-- ── 2. 수락·거절 — 넷째 인자(약관 버전), 옛 3인자 판 삭제 (베이스 577) ───────────
DROP FUNCTION IF EXISTS public.respond_brand_invite(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text, p_terms_version text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_acct public.brand_accounts%ROWTYPE;
  v_pre  public.brand_invites%ROWTYPE;
  v_inv  public.brand_invites%ROWTYPE;
  v_terms text := NULLIF(btrim(COALESCE(p_terms_version, '')), '');   -- 579
  v_res  text;                                                        -- 579
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('result', 'not_brand', 'brand_id', NULL);
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('accept', 'decline') THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;
  -- 579: 수락은 약관 버전이 있어야 한다(L3 — 종류 무관, 맨 앞). 결과 값으로 돌려준다(532 설정 완료처럼 예외를 던지지 않는다 — 기본값 4)
  IF p_action = 'accept' AND v_terms IS NULL THEN
    RETURN jsonb_build_object('result', 'terms_version_required', 'brand_id', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_brand', 'brand_id', NULL);
  END IF;

  -- 줄 지목 — 잠금을 잡을 브랜드·이메일을 알기 위해 잠금 전에 한 번 읽는다
  IF p_link_id IS NOT NULL THEN
    SELECT i.* INTO v_pre FROM public.brand_invites i
     WHERE i.link_id = p_link_id AND (p_invite_id IS NULL OR i.id = p_invite_id);
  ELSIF p_invite_id IS NOT NULL THEN
    SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.id = p_invite_id;
  ELSE
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  -- 브랜드 → 이메일 (527 과 같은 순서)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  -- 잠금 안에서 줄을 다시 읽는다 — 그사이 다시 보내기(링크 교체)·취소·해제가 있었을 수 있다
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR (p_link_id IS NOT NULL AND v_inv.link_id <> p_link_id) THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  -- 579: 연결 요청 줄의 수락은 곧바로 공용 본체로(아래 수락 가능·already_member·비밀번호 검사는 본체가 같은 순서로 한다). 거절은 아래 그대로
  IF v_inv.invite_kind = 'owner_link' AND p_action = 'accept' THEN
    v_res := public._brand_accept_owner_link(v_inv.id, v_uid, v_terms);
    RETURN jsonb_build_object('result', v_res, 'brand_id', CASE WHEN v_res = 'invalid' THEN NULL ELSE v_inv.brand_id END);
  END IF;

  -- 수락 가능 판정 + 「이 계정의 이메일 = 초대 이메일」 (둘 다 도우미 한 곳)
  IF NOT public._brand_invite_acceptable(v_inv.id, v_uid, false) THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  IF p_action = 'decline' THEN
    UPDATE public.brand_invites SET status = 'declined', declined_at = now() WHERE id = v_inv.id;
    RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id);
  END IF;

  -- 수락
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.auth_id = v_uid AND l.brand_id = v_inv.brand_id AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'already_member', 'brand_id', v_inv.brand_id);
  END IF;
  IF v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('result', 'setup_incomplete', 'brand_id', v_inv.brand_id);
  END IF;

  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
  VALUES (v_uid, v_inv.brand_id, 'member', 'active');
  UPDATE public.brand_invites
     SET status = 'accepted', accepted_at = now(), accepted_auth_id = v_uid
   WHERE id = v_inv.id;
  -- 579: 약관 동의 기록(L3 · Q1 — 계정의 지금 칸에 덮어쓰기, 이력 표 없음)
  UPDATE public.brand_accounts
     SET terms_agreed_at = now(), privacy_agreed_at = now(), terms_version = v_terms
   WHERE auth_id = v_uid;

  RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id);
END;
$$;
COMMENT ON FUNCTION public.respond_brand_invite(uuid, uuid, text, text) IS
  '[579] (577 재정의 — 넷째 인자 p_terms_version, 옛 3인자 판 삭제) 초대·연결 요청 수락·거절(메일 링크=p_link_id, 마이페이지=p_invite_id). p_action = accept | decline. 수락은 약관 버전 필요(없으면 terms_version_required — 결과 값). 연결 요청 수락은 _brand_accept_owner_link 로. 멤버 초대 수락은 성공 때 약관 셋 기록. 결과 {result, brand_id} — ok·already_member·invalid·not_brand·setup_incomplete·owner_exists·terms_version_required. authenticated 전용.';

GRANT  EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text, text) FROM anon;

-- ── 3. 임시 막음 해제 · 목록·링크 판정에 종류 (CREATE OR REPLACE — 권한 그대로) ──────────

CREATE OR REPLACE FUNCTION public._brand_acceptable_invites_for(p_auth_id uuid)
RETURNS SETOF public.brand_invites
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT i.*
    FROM public.brand_accounts a
    JOIN public.brand_invites i ON i.email = lower(btrim(a.email))
   WHERE a.auth_id = p_auth_id
     AND i.status = 'pending'
     AND i.expires_at > now()
     AND public._brand_invite_acceptable(i.id, p_auth_id, false);
$$;

COMMENT ON FUNCTION public._brand_acceptable_invites_for(uuid) IS
  '[579] (577 임시 막음 해제 — 532 본문으로 복귀, 종류 무관)  내부 도우미. 이 계정이 지금 수락할 수 있는 대기 초대(만료 전 + _brand_invite_acceptable(id, 계정, false) 통과). 로그인 판정·받은 초대 목록·527 링크 판정이 함께 쓴다. 호출 불가(안쪽 전용).';

CREATE OR REPLACE FUNCTION public.get_my_brand_invites()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'invite_id',    i.id,
           'invite_kind',  i.invite_kind,   -- 579: member | owner_link
           'brand_id',     i.brand_id,
           'brand_name',   b.name,
           'inviter_name', i.inviter_name,
           'issued_at',    i.issued_at,
           'expires_at',   i.expires_at
         ) ORDER BY i.issued_at DESC, i.id), '[]'::jsonb)
    INTO v_rows
    FROM public._brand_acceptable_invites_for(v_uid) i
    JOIN public.brands b ON b.id = i.brand_id;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_invites() IS
  '[579] (532 재정의 — 줄마다 invite_kind) 로그인한 브랜드 계정이 지금 수락할 수 있는 초대 목록 [{invite_id, brand_id, brand_name, inviter_name, issued_at, expires_at}] (최근 발급순). 비로그인·브랜드 계정이 아니면 빈 배열. authenticated 전용.';

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
  IF v_recipient = 'new' THEN
    v_result := v_result || jsonb_build_object('email', v_inv.email);
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_brand_invite_link_state(uuid) IS
  '[579] (577 임시 막음 해제 + invite_kind 칸 — 베이스 534)  초대 메일 링크 판정(비로그인 가능). 수락 가능이면 {state:valid, recipient:new|existing, brand_name, inviter_name, issued_at, expires_at} + recipient=new 일 때만 email, 아니면 {state:invalid} 한 칸. 판정은 _brand_invite_acceptable(id, NULL, true). 링크 소지자에게 브랜드·보낸 사람 이름을 주는 것은 의도된 예외(작업표 어긋남 3번). 링크 소지자에게 새 이메일 초대의 이메일을 주는 것은 사용자 결정(피그마 w01-02b 읽기 전용 이메일 칸 — 작업표 S0-2, 2026-10-15). 전달받은 사람에게도 보인다. 베이스 532.';
-- 링크 판정은 비로그인 실행 권한 유지(534 와 같은 상태를 다시 적는다 — 멱등)
GRANT  EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '579', '579_brand_owner_link_accept.sql');
COMMIT;
