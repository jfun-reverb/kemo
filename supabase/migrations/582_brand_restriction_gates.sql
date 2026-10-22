-- ============================================================
-- 582_brand_restriction_gates.sql
-- 브랜드 계정 이용 제한 · 결과물 열람 정지 — 제한 2: 관문 재정의 (사양서 4-2 · 5-2 · 작업표 stale 1·3·5·10 · 기본값 1)
-- 사양서: docs/specs/2026-10-21-brand-account-restriction.md · 작업표 docs/specs/2026-10-21-brand-account-restriction-breakdown.md 「제한 2」
--
-- 왜: 이용 제한(581 표)이 걸린 브랜드 계정이 연결된 **모든 브랜드**에서 브랜드 데이터에 닿지 못하게 한다(F1·R2 — 건 즉시 서버가 막는다).
--   🔴 제한 줄이 0건인 동안은 결과가 지금과 같다(관리자 쓰기 함수는 제한 4 — 그 전에는 줄이 생기지 않는다).
--
-- 거부 방식(작업표 기본값 1)
--   · 브랜드 로그인 사용자 경로(조회·저장·수락) → 오류 `account_restricted`(P0001) — 함수마다 거부 모양이 달라 화면 공통 입구가 이 글자 하나만 본다(4-2·4-3)
--   · 서비스 키 경로(service_*)·관리자 함수·내부 본체 → 결과 값 `account_restricted`
--
-- 고치는 함수(전부 CREATE OR REPLACE — 이름·인자·반환형 그대로라 실행 권한 보존) · 괄호 = 베이스(마지막 CREATE)
--   1) my_brand_role(uuid)(530) — 로그인 사용자가 제한이면 오류. 🔴 언어 sql → plpgsql(오류를 내려고). 정의자 권한 함수라 원래 펼침(인라인) 대상이 아니어서 속도 변화는 판정 한 번(색인 조회)뿐.
--      is_my_brand(530)는 본문이 my_brand_role 을 부르므로 **고치지 않아도** 함께 막힌다(저장소 정책 orient_images_account_insert 포함).
--   2) _brand_caller_link_role(uuid)(531) — 같은 오류(언어 sql → plpgsql). 부르는 자리 6곳(577 초대 넷 · 531 대표 넘기기·멤버 해제)이 함께 막힌다
--   3) orient_lookup_gate_account(uuid, uuid)(541) — 받은 계정이 제한이면 false(이 함수의 「통과 안 됨」 값)
--   4) get_my_brand_login_state()(532) — 「브랜드 계정이 아님」 두 갈래 바로 뒤, 초대 계산(_brand_acceptable_invites_for) **전**에 state 'restricted'
--      (사유·기간 싣지 않음 — 다른 칸은 빈 값). 연결이 없거나 설정 전이어도 제한이면 restricted(4-2)
--   5) respond_brand_invite(uuid, uuid, text, text)(579) — 수락이고 호출자가 제한이면 오류(거절은 허용 — A5). 🔴 4인자 그대로
--   6) _brand_accept_owner_link(uuid, uuid, text)(579) — 받는 계정이 제한이면 'account_restricted'(줄 재독·수락 가능 판정 뒤)
--   7) _brand_transfer_owner(uuid, uuid)(531) — 새 대표가 제한이면 'account_restricted'(A6 — 옛 대표가 제한이어도 멤버 줄은 지금처럼).
--      받는 두 호출자(531 transfer_brand_ownership · 533 admin_change_brand_owner)는 결과를 그대로 돌려준다(확인함 — 고치지 않는다)
--   8) service_brand_link_request_setpw(uuid, text)·service_brand_link_request_finalize(uuid, text)(580) — 받는 계정이 제한이면 {result:'account_restricted'}
--      (setpw 는 비밀번호 저장 **전**에 걸러 인증 서비스에 쓰지 않게 — stale 5. finalize 는 본체 결과 account_restricted 도 그대로 넘긴다)
--   9) _brand_mailable_accounts(uuid)(557) — 제한 계정을 뺀다(R4). 부르는 자리 셋(561 배송 메일 선점 · 557 관리자 배송 조회·전달)이 따라온다
--  10) 새 service_brand_mailable_accounts(uuid) → jsonb — 위 결과를 서비스 키에(stale 3). 🔴 「연결 계정 전원」 받는 사람 규칙의 **단일 출처**가 된다 —
--      notify-orient-sheet 는 제한 5 에서 이것을 부르게 바뀌어 사본이 사라진다(557 머리말의 「notify-orient-sheet 의 사본」 서술은 이 파일 이후 옛말)
--  11) admin_check_brand_account_email(uuid, text)(573) — 칸 restricted(늘 실음) + 제한이면 restriction_id·linked_brands:[{id,name}](활성 연결만, 0개면 [])
--  12) admin_request_brand_owner_link(uuid, text)(578) — 받을 계정이 제한이면 {result:'account_restricted'}(계정·줄 안 만듦 · 같은 이메일 다시 발급도 거부)
--
-- 넣지 않는 자리(사양서 4-2): 새 이메일 초대 수락(brand-invite-accept — 새 계정 전용) · service_record_brand_provision(547 이 먼저 막는다) ·
--   자기 정보 함수(A14 — mark_mypage_seen·update_my_brand_profile·비밀번호 바꿈 표시·get_my_brand_invites 는 관문 함수를 안 부른다, 확인함) ·
--   비밀번호 찾기·설정 메일(보낸다) · get_brand_link_state · 초대 메일
-- ⚠️ 의도된 연쇄 거부: my_brand_role 을 부르는 함수는 모두 제한 계정에서 not_linked·not_found 대신 오류 account_restricted 가 된다 —
--   마지막 접속 기록 touch_my_brand_activity·set_my_brand_last_viewed(532)도 포함(자기 정보지만 브랜드 번호를 받는 함수라 A14 밖).
--   화면 공통 입구(제한 7)가 이 오류를 받아 bw01-13 으로 보낸다. 대표 넘기기 결과 account_restricted 는 관리자·대표 화면이 새 값으로 다룬다(화면 몫)
--
-- 🔴 연결 표(brand_account_links)를 직접 읽는 함수를 **새로 만들면** 이 제한 판정(_brand_account_restricted)을 넣는다.
--   전수(2026-10-22, 함수마다 마지막 CREATE 본문에서 brand_account_links 검색 — 578 이 지운 admin_link_brand_owner_account 제외) 데이터베이스 29 · 서버 함수 5:
--   528 delete_brand·merge_brands / 530 my_brand_role / 531 _brand_caller_link_role·_brand_transfer_owner·release_brand_member·transfer_brand_ownership /
--   532 get_brand_link_state·get_my_brand_login_state·service_issue_brand_account_link·touch_my_brand_activity /
--   533 admin_change_brand_owner·admin_release_brand_account / 541 orient_lookup_gate_account / 552 service_record_brand_provision /
--   557 _brand_mailable_accounts / 573 admin_check_brand_account_email / 574 admin_save_brand_contact /
--   577 _brand_seat_usage·create_brand_invite·get_brand_members·service_brand_invite_finalize /
--   578 _brand_contacts_locked·admin_get_brand_account_status·admin_request_brand_owner_link·admin_upsert_brand_owner_account /
--   579 _brand_accept_owner_link·respond_brand_invite / 580 service_brand_link_request_setpw
--   서버 함수: brand-invite-accept·brand-password-reset-request·notify-brand-account-setup·notify-brand-invite·notify-orient-sheet
--   (이 파일 뒤로는 service_brand_mailable_accounts 가 하나 더 — 판정이 들어 있다)
--
-- 🔴 개발서버 적용 → 제한 5 서버 함수 셋 배포(kemo-af) → 제한 7 브랜드 화면 병합(kemo-45)을 같은 날.
--    특히 notify-orient-sheet 는 이 파일의 service_brand_mailable_accounts 가 없으면 발급 메일이 전부 실패한다 — 이 파일 먼저.
-- 🔴 다음 재정의 베이스: 위 12개 모두 이 파일.
-- 편집기 경고: 안 뜸(DROP 없음).
-- 롤백(제한 5 의 notify-orient-sheet 를 먼저 되돌린다): 각 함수 베이스 블록 재실행(530 my_brand_role · 531 _brand_caller_link_role·_brand_transfer_owner ·
--   541 · 532 get_my_brand_login_state · 579 respond_brand_invite·_brand_accept_owner_link · 580 두 서비스 함수 · 557 _brand_mailable_accounts ·
--   573 · 578 admin_request_brand_owner_link) → DROP FUNCTION public.service_brand_mailable_accounts(uuid).
--   ⚠️ 530·531 블록은 언어가 sql 이라 그대로 되돌아간다(CREATE OR REPLACE 로 언어를 바꿀 수 있다).
-- ============================================================
BEGIN;

-- ── 1. my_brand_role — 브랜드 데이터 관문 (베이스 530) ─────────────────
CREATE OR REPLACE FUNCTION public.my_brand_role(p_brand_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  -- 582: 이용 제한 계정이면 어느 브랜드든 오류(화면 공통 입구가 이 글자 하나로 bw01-13 으로 보낸다)
  IF v_uid IS NOT NULL AND public._brand_account_restricted(v_uid) THEN
    RAISE EXCEPTION 'account_restricted' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.role INTO v_role
    FROM public.brand_account_links l
    JOIN public.brands b ON b.id = l.brand_id
   WHERE l.auth_id = v_uid
     AND l.brand_id = p_brand_id
     AND l.status = 'active'
     AND b.status = 'active'
   LIMIT 1;
  RETURN v_role;
END;
$$;

COMMENT ON FUNCTION public.my_brand_role(uuid) IS
  '[582] (530 재정의 — 이용 제한 계정이면 오류 account_restricted, 언어 sql → plpgsql) 로그인 사용자의 이 브랜드 역할(owner/member/NULL). 활성 연결 + 활성 브랜드. is_my_brand 가 감싼다. 브랜드 데이터 관문.';

-- ── 2. _brand_caller_link_role — 대표 함수 관문 (베이스 531) ────────────
CREATE OR REPLACE FUNCTION public._brand_caller_link_role(p_brand_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  -- 582: 이용 제한 계정이면 오류(my_brand_role 과 같은 글자)
  IF v_uid IS NOT NULL AND public._brand_account_restricted(v_uid) THEN
    RAISE EXCEPTION 'account_restricted' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.role INTO v_role
    FROM public.brand_account_links l
   WHERE l.auth_id = v_uid
     AND l.brand_id = p_brand_id
     AND l.status = 'active'
   LIMIT 1;
  RETURN v_role;
END;
$$;

COMMENT ON FUNCTION public._brand_caller_link_role(uuid) IS '[582] (531 재정의 — 이용 제한 계정이면 오류 account_restricted, 언어 sql → plpgsql) 내부 도우미. 로그인 사용자의 이 브랜드 활성 연결 역할(owner/member/NULL). 브랜드 활성 여부는 안 본다. 호출 불가(안쪽 전용).';

-- ── 3. orient_lookup_gate_account — 큐텐 불러오기 계정 관문 (베이스 541) ──────
CREATE OR REPLACE FUNCTION public.orient_lookup_gate_account(p_auth_id uuid, p_sheet_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recent integer;
BEGIN
  IF p_auth_id IS NULL OR p_sheet_id IS NULL THEN
    RETURN false;
  END IF;

  -- 582: 이용 제한 계정은 통과 안 됨(530 my_brand_role 식의 사본이라 같은 판정을 여기에도)
  IF public._brand_account_restricted(p_auth_id) THEN
    RETURN false;
  END IF;

  -- ①②  계정이 시트 브랜드에 활성 연결 + 브랜드 활성(530 my_brand_role 과 같은 식) + 시트 작성 가능
  --     (draft·submitted 만 = consumed·expired 제외, 기한 안 — NULL 은 기한 없음)
  IF NOT EXISTS (
    SELECT 1
      FROM public.orient_sheets s
      JOIN public.brands b ON b.id = s.brand_id
      JOIN public.brand_account_links l ON l.brand_id = s.brand_id
     WHERE s.id = p_sheet_id
       AND s.status IN ('draft', 'submitted')
       AND (s.token_expires_at IS NULL OR s.token_expires_at > now())
       AND b.status = 'active'
       AND l.auth_id = p_auth_id
       AND l.status = 'active'
  ) THEN
    RETURN false;
  END IF;

  -- 지나간 기록 정리(1시간 넘은 것 — 428 과 같은 관례)
  DELETE FROM public.orient_lookup_hits WHERE hit_at < now() - interval '1 hour';

  -- ③ 계정 단위 최근 60초 5회 — 같은 계정의 동시 호출이 겹치지 않게 계정 단위로 잠근 뒤 센다(시트를 바꿔도 합산)
  PERFORM pg_advisory_xact_lock(hashtext('orient_lookup_gate_account'), hashtext(p_auth_id::text));
  SELECT count(*) INTO v_recent
    FROM public.orient_lookup_hits
   WHERE auth_id = p_auth_id AND hit_at >= now() - interval '60 seconds';
  IF v_recent >= 5 THEN
    RETURN false;
  END IF;

  INSERT INTO public.orient_lookup_hits (auth_id) VALUES (p_auth_id);
  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.orient_lookup_gate_account(uuid, uuid) IS
  '[582] (541 재정의 — 이용 제한 계정이면 false) 서비스 키 전용. 큐텐 불러오기 계정 관문: 계정이 시트 브랜드에 활성 연결 + 브랜드 활성 + 시트 작성 가능 + 계정 단위 60초 5회. 활성 연결·활성 브랜드 식은 my_brand_role 의 사본.';

-- ── 4. get_my_brand_login_state — restricted 갈래 (베이스 532) ──────────
CREATE OR REPLACE FUNCTION public.get_my_brand_login_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_acct       public.brand_accounts%ROWTYPE;
  v_brands     jsonb;
  v_has_invite boolean;
  v_dot        boolean;
  v_last       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', false, 'new_invite_dot', false, 'password_changed_at', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', false, 'new_invite_dot', false, 'password_changed_at', NULL);
  END IF;

  -- 582: 이용 제한 — 「브랜드 계정이 아님」 두 갈래 바로 뒤, 나머지 갈래보다 먼저(4-2). 사유·기간·이름은 싣지 않는다(bw01-13 은 안내만)
  IF public._brand_account_restricted(v_uid) THEN
    RETURN jsonb_build_object('state', 'restricted', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', false, 'new_invite_dot', false, 'password_changed_at', NULL);
  END IF;

  -- 수락 가능한 대기 초대 · 새 초대 표시
  SELECT count(*) > 0,
         COALESCE(bool_or(v_acct.mypage_seen_at IS NULL OR i.issued_at > v_acct.mypage_seen_at), false)
    INTO v_has_invite, v_dot
    FROM public._brand_acceptable_invites_for(v_uid) i;

  IF v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('state', 'setup_incomplete', 'name', v_acct.name, 'email', v_acct.email, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', v_has_invite, 'new_invite_dot', v_dot,
                              'password_changed_at', v_acct.password_changed_at);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'role', l.role)
                            ORDER BY (l.role = 'owner') DESC, b.name), '[]'::jsonb)
    INTO v_brands
    FROM public.brand_account_links l
    JOIN public.brands b ON b.id = l.brand_id
   WHERE l.auth_id = v_uid AND l.status = 'active' AND b.status = 'active';

  -- 마지막 브랜드는 지금 활성 연결 목록에 있을 때만
  v_last := CASE WHEN v_acct.last_brand_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_brands) e WHERE e->>'id' = v_acct.last_brand_id::text)
                 THEN v_acct.last_brand_id END;

  RETURN jsonb_build_object(
    'state',               CASE WHEN jsonb_array_length(v_brands) = 0 THEN 'no_active_brand' ELSE 'ok' END,
    'name',                v_acct.name,
    'email',               v_acct.email,
    'brands',              v_brands,
    'last_brand_id',       v_last,
    'has_pending_invite',  v_has_invite,
    'new_invite_dot',      v_dot,
    'password_changed_at', v_acct.password_changed_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_login_state() IS
  '[582] (532 재정의 — 갈래 restricted) 브랜드 화면 로그인 판정. state: not_brand(로그인 안 함·계정 줄 없음) → restricted(이용 제한 — 다른 칸 빈 값) → setup_incomplete → no_active_brand | ok. 칸 name·email·brands[{id,name,role}]·last_brand_id·has_pending_invite·new_invite_dot·password_changed_at.';

-- ── 5. respond_brand_invite — 수락 거부 (베이스 579, 4인자 그대로) ──────────
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

  -- 582: 이용 제한 계정은 수락(멤버 초대·연결 요청 모두)을 못 한다(A5). 거절은 허용. 잠금 전에 — 줄을 건드리지 않는다
  IF p_action = 'accept' AND public._brand_account_restricted(v_uid) THEN
    RAISE EXCEPTION 'account_restricted' USING ERRCODE = 'P0001';
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
  '[582] (579 재정의 — 수락이고 호출자가 이용 제한이면 오류 account_restricted, 거절은 허용) 받은 초대·연결 요청에 답한다(로그인 계정). 반환 {result: ok|not_brand|invalid|terms_version_required|already_member|setup_incomplete|owner_exists, brand_id}. 연결 요청 수락은 본체 _brand_accept_owner_link. 수락은 약관 버전 필수.';

-- ── 6. _brand_accept_owner_link — 연결 요청 수락 본체 (베이스 579) ──────────
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

  -- 582: 받는 계정이 이용 제한이면 거부(A5·A7 — 제한 중 새 브랜드 연결이 생기지 않게)
  IF public._brand_account_restricted(p_auth_id) THEN
    RETURN 'account_restricted';
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
  '[582] (579 재정의 — 받는 계정이 이용 제한이면 account_restricted) 연결 요청 수락 공용 본체(로그인 수락 respond_brand_invite · 비밀번호 정하며 수락 580 finalize). 반환 ok|invalid|account_restricted|owner_exists|already_member|setup_incomplete. 내부 전용.';

-- ── 7. _brand_transfer_owner — 대표 넘기기 본체 (베이스 531) ────────────
CREATE OR REPLACE FUNCTION public._brand_transfer_owner(p_brand_id uuid, p_new_owner_auth_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old public.brand_account_links%ROWTYPE;
  v_new public.brand_account_links%ROWTYPE;
BEGIN
  -- 같은 트랜잭션에서 이미 잡았으면 재진입(호출하는 쪽이 잡아도 안전)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT l.* INTO v_new
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.auth_id = p_new_owner_auth_id AND l.status = 'active'
   FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_member'; END IF;
  IF v_new.role = 'owner' THEN RETURN 'ok'; END IF;     -- 이미 대표 — 바꿀 것 없음

  -- 582: 이용 제한 중인 계정을 새 대표로 넘기지 않는다(A6). 옛 대표가 제한 중이어도 아래 멤버 줄은 지금처럼 넣는다
  IF public._brand_account_restricted(p_new_owner_auth_id) THEN
    RETURN 'account_restricted';
  END IF;

  SELECT l.* INTO v_old
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active'
   FOR UPDATE;

  -- 해제를 먼저(브랜드당 활성 대표 1명 · (계정,브랜드) 활성 1개 부분 유일 색인)
  UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_new.id;
  IF v_old.id IS NOT NULL THEN
    UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_old.id;
  END IF;

  -- 새 연결 — 각자 옛 연결의 last_active_at·source_contact_id 를 이어받는다
  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id, last_active_at)
  VALUES (v_new.auth_id, p_brand_id, 'owner', 'active', v_new.source_contact_id, v_new.last_active_at);
  IF v_old.id IS NOT NULL THEN
    INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id, last_active_at)
    VALUES (v_old.auth_id, p_brand_id, 'member', 'active', v_old.source_contact_id, v_old.last_active_at);
  END IF;

  PERFORM public._brand_contacts_mark_primary(p_brand_id, p_new_owner_auth_id);
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public._brand_transfer_owner(uuid, uuid) IS
  '[582] (531 재정의 — 새 대표가 이용 제한이면 account_restricted) 대표 넘기기 본체: 새 대표·옛 대표 연결을 해제하고 새 줄(새 대표 owner, 옛 대표 member)을 넣는다. 반환 ok|not_member|account_restricted. 부르는 쪽 transfer_brand_ownership(531)·admin_change_brand_owner(533)는 결과를 그대로 돌려준다. 내부 전용.';

-- ── 8. 연결 요청 비밀번호 정하며 수락 — 서비스 함수 둘 (베이스 580) ─────────
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

  -- 582: 받는 계정이 이용 제한이면 비밀번호 저장 **전**에 거부(인증 서비스에 쓰지 않게 — stale 5)
  IF public._brand_account_restricted(v_inv.sent_owner_auth_id) THEN
    RETURN jsonb_build_object('result', 'account_restricted', 'auth_id', NULL);
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
  '[582] (580 재정의 — 받는 계정이 이용 제한이면 account_restricted) 서비스 키 전용(연결 7 공개 함수). 연결 요청 「비밀번호 정하며 수락」 — 비밀번호 저장 전 검사만(쓰지 않음). 약관 버전 → 줄(대기·연결 요청) → _brand_invite_acceptable → 이용 제한 아님 → 활성 대표 없음 → 이미 연결 아님 → 받는 계정 비밀번호 미설정. 반환 {result: ok|terms_version_required|invalid_link|account_restricted|owner_exists|already_member|password_already_set, auth_id}.';

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
  -- 582: 이용 제한도 본체가 거부한다(account_restricted) — setpw 에서 이미 걸렀지만 그사이 제한이 걸린 경우
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
  -- 582: account_restricted 는 그대로 넘긴다(「링크 무효」로 바꾸지 않는다 — 사양서 4-2)
  RETURN jsonb_build_object('result', CASE WHEN v_res IN ('owner_exists', 'already_member', 'account_restricted') THEN v_res ELSE 'invalid_link' END,
                            'brand_id', CASE WHEN v_res IN ('owner_exists', 'already_member', 'account_restricted') THEN v_inv.brand_id ELSE NULL END,
                            'email', NULL);
END;
$$;

COMMENT ON FUNCTION public.service_brand_link_request_finalize(uuid, text) IS
  '[582] (580 재정의 — 본체 결과 account_restricted 를 그대로 넘김) 서비스 키 전용(연결 7 공개 함수). 연결 요청 「비밀번호 정하며 수락」 마무리(비밀번호 저장 뒤) — 브랜드→이메일 잠금 → 줄 재독 → 받는 계정 비밀번호 기록 전이었는지 → auth 비밀번호 실재 → password_set_at·password_changed_at·setup_link_id=NULL → _brand_accept_owner_link(거부면 비밀번호 기록도 되감음). 반환 {result: ok|terms_version_required|invalid_link|account_restricted|owner_exists|already_member|password_already_set|password_not_set, brand_id, email(성공 때만)}.';

-- ── 9. _brand_mailable_accounts — 「연결 계정 전원」 받는 사람 (베이스 557) ─────
CREATE OR REPLACE FUNCTION public._brand_mailable_accounts(p_brand_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('auth_id', t.auth_id, 'email', t.email, 'name', t.name, 'role', t.role)
                            ORDER BY t.ord), '[]'::jsonb)
    FROM (
      SELECT DISTINCT ON (lower(btrim(ba.email)))
             ba.auth_id, lower(btrim(ba.email)) AS email, NULLIF(btrim(ba.name), '') AS name, l.role,
             row_number() OVER (ORDER BY (l.role <> 'owner'), l.created_at) AS ord
        FROM public.brand_account_links l
        JOIN public.brands b          ON b.id = l.brand_id AND b.status = 'active'
        JOIN public.brand_accounts ba ON ba.auth_id = l.auth_id
       WHERE l.brand_id = p_brand_id
         AND l.status = 'active'
         AND ba.password_set_at IS NOT NULL
         AND NULLIF(btrim(ba.email), '') IS NOT NULL
         AND NOT public._brand_account_restricted(ba.auth_id)   -- 582: 이용 제한 계정은 받는 사람에서 뺀다(R4)
       ORDER BY lower(btrim(ba.email)), (l.role <> 'owner'), l.created_at
    ) t;
$$;

COMMENT ON FUNCTION public._brand_mailable_accounts(uuid) IS
  '[582] (557 재정의 — 이용 제한 계정 제외) 「연결 계정 전원」 받는 사람 규칙의 단일 출처: 활성 브랜드 + 활성 연결 + 비밀번호 정함 + 이메일 있음 + 이용 제한 아님, 이메일 중복 제거, 대표 먼저. [{auth_id,email,name,role}]. 부르는 곳 561 배송 메일 선점·557 관리자 배송 조회·전달·제한 4 메일 선점, 서비스 키는 service_brand_mailable_accounts(notify-orient-sheet). 실행 권한 postgres 만.';

-- ── 10. service_brand_mailable_accounts — 서비스 키 감싸개 (신설) ───────────
CREATE OR REPLACE FUNCTION public.service_brand_mailable_accounts(p_brand_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public._brand_mailable_accounts(p_brand_id);
$$;

COMMENT ON FUNCTION public.service_brand_mailable_accounts(uuid) IS
  '[582] 서비스 키 전용. _brand_mailable_accounts 결과 그대로([{auth_id,email,name,role}] — 활성 브랜드만, 이용 제한 계정 제외). notify-orient-sheet 받는 사람(제한 5)·제한 6 메일 함수가 부른다 — 서버 함수에 받는 사람 규칙 사본을 두지 않는다(stale 3).';

GRANT  EXECUTE ON FUNCTION public.service_brand_mailable_accounts(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_brand_mailable_accounts(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_brand_mailable_accounts(uuid) FROM anon, authenticated;

-- ── 11. admin_check_brand_account_email — 겹침 확인에 제한 표시 (베이스 573) ──────
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
  v_rid    uuid;                -- 582
  v_lbr    jsonb := '[]'::jsonb; -- 582
  v_result jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'email_kind', NULL, 'name', NULL,
                              'linked_brand_count', 0, 'released_from_this_brand', false, 'restricted', false);
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
    -- 582: 이용 제한 중이면 줄 번호 + 활성 연결 브랜드(A12 — 확인 모달 문구·「제한 해제」). 연결 수 세기와 같은 조건
    v_rid := public._brand_active_restriction_id(v_id);
    IF v_rid IS NOT NULL THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) ORDER BY b.name), '[]'::jsonb) INTO v_lbr
        FROM public.brand_account_links l
        JOIN public.brands b ON b.id = l.brand_id
       WHERE l.auth_id = v_id AND l.status = 'active';
    END IF;
  -- 573: 인플루언서·관리자 이메일이면 이름을 돌려주지 않는다(사양서 5-4 · D6 — 어느 계정인지 알리지 않는다). 종류만.
  END IF;

  v_result := jsonb_build_object(
    'result',                  'ok',
    'email_kind',              v_kind,
    'name',                    v_name,
    'linked_brand_count',      v_linked,
    'released_from_this_brand', v_rel,
    'restricted',              v_rid IS NOT NULL   -- 582
  );
  IF v_rid IS NOT NULL THEN
    v_result := v_result || jsonb_build_object('restriction_id', v_rid, 'linked_brands', v_lbr);
  END IF;
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.admin_check_brand_account_email(uuid, text) IS
  '[582] (573 재정의 — restricted 칸, 제한이면 restriction_id·linked_brands[{id,name}]) 관리자 「계정 만들기」·「브랜드 연결 추가」 겹침 확인. 반환 {result: ok|invalid_email, email_kind, name(브랜드 계정만), linked_brand_count, released_from_this_brand, restricted}. 가드 is_admin(아니면 42501).';

-- ── 12. admin_request_brand_owner_link — 제한 계정에 연결 요청 거부 (베이스 578) ────
CREATE OR REPLACE FUNCTION public.admin_request_brand_owner_link(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_email  text := lower(btrim(COALESCE(p_email, '')));
  v_status text;
  v_owner  jsonb;
  v_kind   text;
  v_auth   uuid;
  v_req    public.brand_invites%ROWTYPE;
  v_now    timestamptz := now();
  v_id     uuid;
  v_exp    timestamptz;
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;

  -- 브랜드 → 이메일 순서(527·531·533 과 같은 열쇠)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;
  IF v_status <> 'active' THEN
    RETURN jsonb_build_object('result', 'brand_archived', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'owner_exists', 'request_id', NULL, 'email_kind', NULL, 'expires_at', NULL);
  END IF;

  v_owner := public._brand_email_owner(v_email, NULL);
  v_kind  := v_owner->>'kind';
  v_auth  := NULLIF(v_owner->>'auth_id', '')::uuid;
  IF v_kind <> 'brand' OR v_auth IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.brand_accounts a WHERE a.auth_id = v_auth) THEN
    RETURN jsonb_build_object('result', 'not_brand_account', 'request_id', NULL,
                              'email_kind', CASE WHEN v_kind = 'brand' THEN 'none' ELSE v_kind END, 'expires_at', NULL);
  END IF;

  -- 대표 없는 브랜드에 그 계정의 활성 연결(멤버) — 정상 경로로는 안 생긴다(L2). 방어
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = p_brand_id AND l.auth_id = v_auth AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'already_linked', 'request_id', NULL, 'email_kind', 'brand', 'expires_at', NULL);
  END IF;

  -- 582: 이용 제한 계정에는 연결 요청을 보내지 않는다(A12 — 같은 이메일 다시 발급도). 계정·줄을 만들지 않는다
  IF public._brand_account_restricted(v_auth) THEN
    RETURN jsonb_build_object('result', 'account_restricted', 'request_id', NULL, 'email_kind', 'brand', 'expires_at', NULL);
  END IF;

  -- 대기 연결 요청(B1)
  SELECT i.* INTO v_req
    FROM public.brand_invites i
   WHERE i.brand_id = p_brand_id AND i.invite_kind = 'owner_link' AND i.status = 'pending'
   FOR UPDATE;
  IF FOUND THEN
    IF v_req.email = v_email THEN
      -- 같은 이메일 — 같은 줄을 다시 발급(새 링크·24시간, 발송 기록 비움 · 577 _brand_invite_reissue 가 inviter_name 을 지킨다)
      PERFORM public._brand_invite_reissue(v_req.id, v_uid);
      SELECT i.expires_at INTO v_exp FROM public.brand_invites i WHERE i.id = v_req.id;
      RETURN jsonb_build_object('result', 'ok', 'request_id', v_req.id, 'email_kind', 'brand', 'expires_at', v_exp);
    ELSIF v_req.expires_at > v_now THEN
      RETURN jsonb_build_object('result', 'request_exists', 'request_id', v_req.id, 'email_kind', 'brand', 'expires_at', v_req.expires_at);
    ELSE
      UPDATE public.brand_invites SET status = 'cancelled', cancelled_at = v_now WHERE id = v_req.id;
    END IF;
  END IF;

  v_exp := public._brand_invite_expires_at(v_now);
  INSERT INTO public.brand_invites
    (brand_id, email, invited_by, inviter_name, status, recipient_kind, sent_owner_auth_id, issued_at, expires_at, invite_kind)
  VALUES
    (p_brand_id, v_email, v_uid, 'REVERB 운영팀', 'pending', 'brand', v_auth, v_now, v_exp, 'owner_link')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('result', 'ok', 'request_id', v_id, 'email_kind', 'brand', 'expires_at', v_exp);
END;
$$;

COMMENT ON FUNCTION public.admin_request_brand_owner_link(uuid, text) IS
  '[582] (578 재정의 — 받을 계정이 이용 제한이면 account_restricted) 관리자 「연결 요청」: 대표 없는 브랜드에 기존 브랜드 계정을 대표로 이으라고 요청한다(그 계정이 수락해야 연결). 반환 {result: ok|forbidden|brand_not_found|brand_archived|invalid_email|owner_exists|not_brand_account|already_linked|account_restricted|request_exists, request_id, email_kind, expires_at}. 가드 has_permission(brand.account_manage, write).';

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '582', '582_brand_restriction_gates.sql');
COMMIT;
