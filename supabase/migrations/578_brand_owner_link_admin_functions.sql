-- ============================================================
-- 578_brand_owner_link_admin_functions.sql
-- 브랜드 「연결 요청」 — 연결 2: 관리자 쪽 서버 함수 (사양서 4-2 「새 함수(관리자)」·「고치는 함수」 관리자 줄 · B1·B3·L2·L7)
-- 사양서: docs/specs/2026-10-21-brand-link-request.md · 작업표 docs/specs/2026-10-21-brand-link-request-breakdown.md 「연결 2」
--
-- 만드는 것
--   1) admin_request_brand_owner_link(p_brand_id uuid, p_email text) → jsonb {result, request_id, email_kind, expires_at}
--      · result: ok · forbidden · owner_exists · request_exists · already_linked · not_brand_account(+email_kind none|influencer|admin)
--        · brand_archived · brand_not_found · invalid_email
--      · 가드 has_permission('brand.account_manage','write') → 잠금 브랜드(brand_account_upsert:) → 이메일(brand_account_email:) — 533 과 같은 순서
--      · 검사 순서: 브랜드 있음·활성 → 이메일 형식 → 활성 대표 → 브랜드 계정인가 → 이미 이 브랜드에 활성 연결(already_linked — 정상 경로로는
--        안 생긴다, 방어) → 대기 연결 요청(B1: 같은 이메일 = 같은 줄 다시 발급 / 다른 이메일 = 만료 전 request_exists, 만료 뒤 옛 줄 cancelled + 새 줄)
--      · 새 줄: invite_kind='owner_link' · recipient_kind='brand' · sent_owner_auth_id=그 계정 · invited_by=호출 관리자 · inviter_name='REVERB 운영팀'
--        · expires_at=_brand_invite_expires_at(now()). 메일은 안 보낸다(화면이 notify-brand-invite 를 부른다 — 연결 5)
--      · 다른 브랜드에 연결된 계정도 받는다(본인이 수락해야 이어진다 — 533 즉시 연결과 같은 범위, 즉시가 아닐 뿐)
--   2) admin_cancel_brand_owner_link(p_brand_id uuid, p_request_id uuid) → jsonb {result: ok|forbidden|not_pending}
--      · 이 브랜드의 연결 요청 줄이고 대기(만료 포함)일 때만 cancelled
--   3) admin_get_brand_account_status(베이스 533) — 칸 owner_link_request 추가 + 대기 숫자 둘은 멤버 초대만
--   4) admin_upsert_brand_owner_account(베이스 573) — 활성 대표 없는 갈래에서 만료 전 대기 연결 요청이면 request_exists,
--      만료 줄은 계정을 만드는 같은 거래에서 cancelled. 나머지는 573 글자 그대로
--   5) _brand_contacts_locked(베이스 574) — 「활성 대표 또는 만료 전 대기 연결 요청」 → 574 담당자 저장·삭제가 그동안 대표 줄을 잠근다
--   6) DROP admin_link_brand_owner_account(uuid, text)(533) — 약관을 건너뛰는 즉시 연결 길. 화면 호출 0건
--
-- 🔴 이 파일이 들어간 뒤 연결 3 전까지 받는 사람 링크는 「쓸 수 없는 링크」다(577 임시 막음 — 개발서버만의 중간 상태, 기본값 1).
-- 🔴 다음 재정의 베이스: admin_get_brand_account_status·admin_upsert_brand_owner_account·_brand_contacts_locked 는 이 파일(533·573·574 베이스 금지).
-- 🔴 운영 순서: 577 뒤, 579·580 과 함께(브랜드 페이지 묶음 — 사양서 7절).
-- 편집기 경고: 뜸 — 「destructive operations」(DROP FUNCTION admin_link_brand_owner_account). 「Run query」.
--   2026-10-21 개발서버 적용(기록 표 578 줄 15:02:10 JST) · 새 함수 둘 권한 postgres·authenticated·service_role(맨 앞 =X/·anon 없음) · 옛 함수 to_regprocedure NULL
-- 개발서버 실제 호출(2026-10-21, 최고 관리자 콘솔 · 시험 브랜드 「시험브랜드0923…」 · 비밀번호 정한 브랜드 계정 zz-b2-second):
--   요청 ok · 다른 브랜드 계정 이메일 request_exists · 같은 이메일(대소문자·공백 섞음) 다시 → ok·같은 request_id·새 기한 · 상태 pending ·
--   요청 중 대표 줄 이메일 변경 primary_locked(이름만은 ok) · 계정 만들기 request_exists(계정·연결 안 생김) · 취소 ok → 다시 not_pending · 상태 cancelled ·
--   (만료 꾸밈) 상태 expired → 계정 만들기 created + 요청 cancelled + owner_link_request null(그 계정 해제 뒤에도 null) · 만료 뒤 다른 이메일 요청 = 옛 줄 취소 + 새 줄 ·
--   대표 있는 「가나다 시험」 owner_exists · 인플루언서 not_brand_account(influencer) · 관리자 email_kind admin · 형식 invalid_email ·
--   캠페인 매니저 요청·취소 forbidden. 남은 시험 흔적: 계정 zz-578-owner@example.com(해제됨)·시험 브랜드 해제 이력 1건·취소된 연결 요청 줄들
--   롤백 보충: 577 롤백은 이 파일 롤백 뒤에만(이 파일이 invite_kind 칸을 쓴다). 되살린 admin_link_brand_owner_account 는 533 의 GRANT/REVOKE 줄까지 다시
-- 롤백: DROP FUNCTION admin_request_brand_owner_link(uuid,text), admin_cancel_brand_owner_link(uuid,uuid)
--   → 533 의 admin_get_brand_account_status 블록·admin_link_brand_owner_account 블록(권한 줄 포함), 573 의 admin_upsert_brand_owner_account 블록,
--     574 의 _brand_contacts_locked 블록 재실행. (연결 요청 줄이 남아 있으면 먼저 cancelled 로)
-- ============================================================
BEGIN;

-- ── 1. 연결 요청 만들기 ─────────────────────────────────────────
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
  '[578] 관리자 「연결 요청」 — 대표 없는 활성 브랜드에 이미 있는 브랜드 계정을 대표로 잇자는 요청(본인 24시간 수락). brand.account_manage 쓰기. 반환 {result: ok|forbidden|owner_exists|request_exists|already_linked|not_brand_account|brand_archived|brand_not_found|invalid_email, request_id, email_kind, expires_at}. 같은 이메일 대기 줄은 다시 발급, 다른 이메일은 만료 전이면 request_exists·만료 뒤면 옛 줄 취소 후 새 줄. 메일은 안 보낸다(notify-brand-invite).';

GRANT  EXECUTE ON FUNCTION public.admin_request_brand_owner_link(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_request_brand_owner_link(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_request_brand_owner_link(uuid, text) FROM anon;

-- ── 1-2. 연결 요청 취소 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_cancel_brand_owner_link(p_brand_id uuid, p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req public.brand_invites%ROWTYPE;
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  IF p_brand_id IS NULL OR p_request_id IS NULL THEN
    RETURN jsonb_build_object('result', 'not_pending');
  END IF;

  -- 수락과 같은 브랜드 열쇠 — 「취소가 먼저면 수락 거절 · 수락이 먼저면 취소 not_pending」
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT i.* INTO v_req
    FROM public.brand_invites i
   WHERE i.id = p_request_id AND i.brand_id = p_brand_id AND i.invite_kind = 'owner_link'
   FOR UPDATE;
  IF NOT FOUND OR v_req.status <> 'pending' THEN
    RETURN jsonb_build_object('result', 'not_pending');
  END IF;

  UPDATE public.brand_invites SET status = 'cancelled', cancelled_at = now() WHERE id = v_req.id;
  RETURN jsonb_build_object('result', 'ok');
END;
$$;

COMMENT ON FUNCTION public.admin_cancel_brand_owner_link(uuid, uuid) IS
  '[578] 관리자 연결 요청 취소. brand.account_manage 쓰기. 이 브랜드의 연결 요청 줄이고 대기(만료 포함)일 때만 cancelled. 반환 {result: ok|forbidden|not_pending}.';

GRANT  EXECUTE ON FUNCTION public.admin_cancel_brand_owner_link(uuid, uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_cancel_brand_owner_link(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_cancel_brand_owner_link(uuid, uuid) FROM anon;

-- ── 2. 고치는 함수 (베이스 글자 그대로 + 「-- 578」 줄 · CREATE OR REPLACE 라 실행 권한 그대로) ──

-- ── 2-1. 계정 상태 — 연결 요청 칸 + 대기 숫자는 멤버 초대만 (베이스 533) ──
CREATE OR REPLACE FUNCTION public.admin_get_brand_account_status(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_acct    public.brand_accounts%ROWTYPE;
  v_owner   uuid;
  v_status  text;
  v_members jsonb;
  v_req     public.brand_invites%ROWTYPE;   -- 578
  v_req_j   jsonb;                          -- 578: owner_link_request
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT a.* INTO v_acct
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active'
   LIMIT 1;

  IF FOUND THEN
    v_owner  := v_acct.auth_id;
    v_status := CASE
                  WHEN v_acct.password_set_at IS NOT NULL THEN 'active'
                  WHEN v_acct.setup_mail_sent_at IS NOT NULL THEN 'mail_sent'
                  ELSE 'mail_pending'
                END;
  ELSE
    v_owner  := NULL;
    v_status := 'none';
  END IF;

  -- 활성 연결 전원(대표 먼저). 비밀번호를 아직 안 정한 계정의 마지막 접속은 가린다(대표 줄은 「설정 완료」일 때만 값이 있다 — 16-4)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'auth_id',         a.auth_id,
           'role',            l.role,
           'name',            a.name,
           'email',           a.email,
           'phone',           a.phone,
           'last_active_at',  CASE WHEN a.password_set_at IS NOT NULL THEN l.last_active_at ELSE NULL END,
           'password_set_at', a.password_set_at
         ) ORDER BY (l.role = 'owner') DESC, l.created_at, l.id), '[]'::jsonb)
    INTO v_members
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
   WHERE l.brand_id = p_brand_id AND l.status = 'active';

  -- 578: 가장 최근 연결 요청 하나. 활성 대표가 있거나, 그 요청 발급 뒤에 대표 연결이 생긴 적이 있으면 null
  --   (수락·계정 만들기·대표 바꾸기 어느 길이든 — 그 대표를 해제한 뒤에도 옛 요청 칩을 그리지 않게)
  IF v_owner IS NULL THEN
    SELECT i.* INTO v_req
      FROM public.brand_invites i
     WHERE i.brand_id = p_brand_id AND i.invite_kind = 'owner_link'
     ORDER BY i.issued_at DESC, i.id DESC
     LIMIT 1;
    IF FOUND AND v_req.status <> 'accepted'   -- 수락된 요청은 대표 연결로 보인다(칩 없음)
       AND NOT EXISTS (SELECT 1 FROM public.brand_account_links l
                              WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.created_at > v_req.issued_at) THEN
      v_req_j := jsonb_build_object(
        'request_id', v_req.id,
        'status',     CASE WHEN v_req.status = 'pending' AND v_req.expires_at > now() THEN 'pending'
                           WHEN v_req.status = 'pending' THEN 'expired'
                           ELSE v_req.status END,
        'email',      v_req.email,
        'sent_at',    v_req.issued_at,
        'expires_at', v_req.expires_at);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status',               v_status,
    'email',                CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.email END,
    'setup_mail_sent_at',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_at END,
    'password_set_at',      CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.password_set_at END,
    'setup_mail_sent_by',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_by END,
    'owner_auth_id',        v_owner,
    'members',              v_members,
    'pending_invite_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending' AND i.expires_at > now()
                                AND i.invite_kind = 'member'),   -- 578: 멤버 초대만
    'release_cancel_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending'
                                AND i.invite_kind = 'member'),   -- 578: 멤버 초대만
    'seat_used',            public._brand_seat_usage(p_brand_id),
    'member_limit',         public._brand_member_limit(p_brand_id),
    'can_manage',           public.has_permission('brand.account_manage', 'write'),
    'owner_link_request',   v_req_j          -- 578: {request_id, status: pending|expired|declined|cancelled, email, sent_at, expires_at} | null
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_account_status(uuid) IS
  '[578] (533 재정의 — owner_link_request 칸 · 대기 숫자 둘은 멤버 초대만 · 연결 요청 이메일은 싣는다)  관리자 화면 계정 줄 상태(관리자 전원, 아니면 42501). 527 칸 유지(status none/mail_pending/mail_sent/active · email · setup_mail_sent_at · password_set_at) + setup_mail_sent_by · owner_auth_id · members[](활성 연결 전원, 대표 먼저: auth_id·role·name·email·phone·last_active_at[비밀번호 미설정 계정은 null]·password_set_at) · pending_invite_count(만료 전 대기) · release_cancel_count(상태가 대기인 초대 전부) · seat_used · member_limit · can_manage(brand.account_manage 쓰기). 멤버 초대 줄·이메일은 싣지 않는다(연결 요청은 owner_link_request 에 이메일까지 — 관리자가 보낸 요청).';

-- ── 2-2. 계정 만들기 — 대기 연결 요청이 있으면 request_exists (베이스 573) ──
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
    -- 578: 만료 전 대기 연결 요청이 있으면 계정·연결을 만들지 않는다(B3). 만료 줄은 아래에서 계정을 만들 때 같은 거래에서 취소
    IF EXISTS (SELECT 1 FROM public.brand_invites i
                WHERE i.brand_id = p_brand_id AND i.invite_kind = 'owner_link'
                  AND i.status = 'pending' AND i.expires_at > now()) THEN
      RETURN jsonb_build_object('result', 'request_exists', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    END IF;
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
      -- 578: 남은 대기 연결 요청(위에서 만료 전은 거부했으니 만료 줄뿐)을 같은 거래에서 취소
      UPDATE public.brand_invites
         SET status = 'cancelled', cancelled_at = now()
       WHERE brand_id = p_brand_id AND invite_kind = 'owner_link' AND status = 'pending';
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
  '[578] (573 재정의 — 활성 대표 없는 갈래에서 만료 전 대기 연결 요청 → request_exists, 만료 줄은 계정 생성과 함께 cancelled)  (533 재정의: 갈래 ④ 설정 전 이메일 교체 → email_change_locked 거부 · 활성 대표 없을 때 이메일이 브랜드 계정이면 연결 없이 conflict_brand) 브랜드 대표 담당자 계정 만들기(안쪽 재확인). 판정 규칙은 527 머리말 B 표 + 573 머리말. 반환 jsonb: result·needs_mail·email·auth_id·account_email·brand_id.
   result = created·noop·email_change_locked·password_already_set·primary_moved·conflict_influencer·conflict_admin·conflict_brand·no_primary_email·invalid_email·brand_not_found·brand_archived·forbidden. (email_replaced 는 573 부터 나오지 않는다)';

-- ── 2-3. 담당자 대표 줄 잠김 — 활성 대표 또는 만료 전 대기 연결 요청 (베이스 574) ──
CREATE OR REPLACE FUNCTION public._brand_contacts_locked(p_brand_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.brand_account_links l
     WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active')
  OR EXISTS (   -- 578: 만료 전 대기 연결 요청 — 수락되면 그 계정이 대표가 되므로 그동안 대표 줄을 계정 있는 동안과 같이 잠근다
    SELECT 1 FROM public.brand_invites i
     WHERE i.brand_id = p_brand_id AND i.invite_kind = 'owner_link'
       AND i.status = 'pending' AND i.expires_at > now());
$$;

COMMENT ON FUNCTION public._brand_contacts_locked(uuid) IS
  '[578] (574 재정의 — 활성 대표 또는 만료 전 대기 연결 요청)  내부 판정. 브랜드 담당자 대표 줄이 잠기는 동안인가 — 지금은 활성 대표 연결 있음. 연결 요청(별도 작업표)이 살아 있는 요청을 OR 로 더해 재정의한다. 화면(bdOwnerLocked)은 상태 조회 값을 읽기만. 호출 불가(안쪽 전용).';

-- ── 3. 즉시 연결 함수 삭제 (533) — 약관·본인 수락을 건너뛰는 길 ──────────────
DROP FUNCTION IF EXISTS public.admin_link_brand_owner_account(uuid, text);

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '578', '578_brand_owner_link_admin_functions.sql');
COMMIT;
