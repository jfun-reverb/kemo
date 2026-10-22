-- ============================================================
-- 585_orient_sheet_mail_recipients.sql
-- 오리엔시트 발급 메일(브랜드 계정 모드) — 「아직 못 받은 계정에게만」 보내기 (계정별 발송 기록 + 선점)
--
-- 왜: 지금 서버 함수 notify-orient-sheet 의 계정 갈래는 시트 하나에 발송 기록이 「마지막 보낸 시각·주소들」(orient_sheets.mail_sent_at·
--   mail_sent_to, 201) 한 칸뿐이라 ①계정이 나중에 추가돼도 그 계정만 골라 보낼 수 없고 ②같은 시트에 동시 클릭·재시도가 겹치면 같은 계정에
--   두 번 나갈 수 있다. 계정마다 한 줄(받음/보내는 중/실패)을 두고, 561(배송 알림 메일)과 같은 「선점 → 발송 → 결과 보고」 패턴으로 바꾼다.
--   사용자 결정: 이미 받은 계정에는 두 번 안 간다(강제 재발송 없음). 이용 제한이 풀린 계정은 기록이 없으면 그대로 「못 받음」(Q2).
--   옛 방식으로 보낸 시트도 계정 기준으로는 「못 받음」이면 다시 보낼 수 있다(Q3).
--
-- 하는 일
--   1) 표 orient_sheet_mail_recipients — 기본 키 (sheet_id, auth_id). 이메일은 저장하지 않는다(받는 순간 계정 표에서 읽는다).
--        sheet_id → orient_sheets(id) ON DELETE CASCADE(시트를 지우면 함께).
--        auth_id 는 외래 키를 안 건다(판단) — 계정이 지워져도 「이 시트에 이 계정이 받았다」는 기록은 남기고(581·552 와 같은 방식),
--        받는 사람 판정은 늘 _brand_mailable_accounts 가 현재 계정으로 하므로 고아 줄은 아무 영향이 없다.
--        행 단위 보안 켬 · 정책 없음 · 표 권한 전부 회수(anon·authenticated·service_role 포함) — 읽기·쓰기는 아래 함수로만.
--   2) service_claim_orient_sheet_mail(p_sheet_id, p_caller) — 서비스 키 전용. 호출자 확인 → 시트 상태 확인 → 받을 계정(582 판정을 부르기만 함)
--        → 한 문장으로 계정마다 선점. 선점 조건과 바꾸는 값이 같은 칸(claimed_at) — 561 과 같은 안전 규칙.
--   3) service_mark_orient_sheet_mail_sent(p_sheet_id, p_auth_id, p_claimed_at, p_ok) — 서비스 키 전용, 한 명마다 결과 보고(선점 시각 대조).
--   4) admin_get_orient_mail_recipients(p_brand_id, p_sheet_id) — 관리자 화면용 조회. 받을 계정 수·목록이 2)와 같은 판정(582)에서 나온다.
--        ⚠️ 0명일 때의 「까닭」(empty_reason) 갈래만은 582 조건의 일부 사본 — 582 를 고치면 함께 본다.
--   5) 옛 기록 옮기기(파일 끝) — mail_sent_to 의 주소가 그 시트 브랜드의 활성 연결 계정 이메일과 맞으면 「받음」 줄로 옮긴다.
--
-- 🔴 작성 기한 확인(540·542 대조): 브랜드 계정 모드의 작성 기한은 지금도 orient_sheets.token_expires_at 이다
--   (540 get_my_orient_sheet(s) 가 deadline_at = token_expires_at, 539 _orient_brand_view_status 가 p_deadline < now() 이면 expired).
--   542 는 토큰 링크 폼만 닫고 기한 칸을 안 바꿨다. 그래서 이 파일도 token_expires_at <= now() 를 만료로 본다.
--   ⚠️ 539 의 화면 상태 「등록됨(registered)」(캠페인이 등록된 카드가 있는 시트)은 여기서 막지 않는다 — 사용자 지정 거부는 consumed·expired 둘뿐.
--
-- 선행: 201(mail_sent_at·mail_sent_to) · 526(brand_accounts·brand_account_links) · 581(_brand_account_restricted) · 582(_brand_mailable_accounts)
-- 🔴 운영 반영 순서: 브랜드 묶음(526 → … → 582) 뒤에 이 파일 → 그다음에 서버 함수 notify-orient-sheet(계정 갈래가 아래 두 서비스 함수를 부르는 판).
--   🔴 이 파일은 브랜드 묶음보다 먼저 운영에 넣을 수 없다 — 5절 옮기기가 brand_accounts·brand_account_links(526)를 바로 읽어
--   「relation does not exist」로 파일 전체가 되돌아간다(582·581 도 운영에 없다). (2026-10-22 정정 — 처음 판은 「먼저 들어가도 그대로」라 적었다)
--   함수보다 이 파일이 먼저 — 반대면 서버 함수가 없는 함수를 불러 계정 갈래 발급 메일이 전부 실패한다. 운영의 옛 갈래(신청서 이메일·대표 담당자)는
--   이 함수들을 부르지 않는다. 지금은 개발서버만 적용(브랜드 묶음 출시 전).
--
-- 거부 코드
--   claim  : {result:'error', reason} — forbidden(호출자가 admins 에 없음) · not_found(시트 없음) · consumed · expired
--   admin  : 예외 42501(관리자 아님) · P0001 메시지 not_found(시트 없음) · brand_mismatch(시트의 브랜드와 p_brand_id 가 다름)
--
-- 편집기 경고: DELETE/DROP 구문 없음(옮기기는 INSERT 만, 롤백 주석에만 DROP 이 적혀 있다).
-- 롤백(서버 함수부터 되돌린다):
--   DROP FUNCTION IF EXISTS public.admin_get_orient_mail_recipients(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.service_mark_orient_sheet_mail_sent(uuid, uuid, timestamptz, boolean);
--   DROP FUNCTION IF EXISTS public.service_claim_orient_sheet_mail(uuid, uuid);
--   DROP TABLE IF EXISTS public.orient_sheet_mail_recipients;   -- 계정별 발송 기록을 잃는다(orient_sheets.mail_sent_* 는 남아 있다)
-- ============================================================
BEGIN;

-- ── 1. 표 ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.orient_sheet_mail_recipients (
  sheet_id       uuid        NOT NULL REFERENCES public.orient_sheets(id) ON DELETE CASCADE,
  auth_id        uuid        NOT NULL,   -- 브랜드 계정(auth.users.id) — 외래 키 없음(위 머리말 판단)
  claimed_at     timestamptz,            -- 보내는 중(선점) 시각. NULL = 선점 없음(처음이거나 실패해서 풀림)
  claimed_by     uuid,                   -- 선점한 관리자(auth.uid) — 외래 키 없음
  sent_at        timestamptz,            -- 발송 성공 시각. 값이 있으면 이 계정에는 더 보내지 않는다
  last_failed_at timestamptz,            -- 마지막 발송 실패 시각(참고용 — 성공해도 지우지 않는다)
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sheet_id, auth_id)
);

COMMENT ON TABLE public.orient_sheet_mail_recipients IS
  '[585] 오리엔시트 발급 메일의 계정별 발송 기록(시트 × 브랜드 계정 한 줄). sent_at 있으면 받음 · claimed_at 이 15분 안이면 보내는 중 · 그 밖은 못 받음. 이메일은 저장하지 않는다(받는 순간 계정 표에서). 읽기·쓰기는 service_claim_orient_sheet_mail·service_mark_orient_sheet_mail_sent·admin_get_orient_mail_recipients 만.';

ALTER TABLE public.orient_sheet_mail_recipients ENABLE ROW LEVEL SECURITY;   -- 정책 없음 = 함수로만
REVOKE ALL ON TABLE public.orient_sheet_mail_recipients FROM PUBLIC;
REVOKE ALL ON TABLE public.orient_sheet_mail_recipients FROM anon, authenticated, service_role;

-- ── 2. 선점 — 서비스 키 전용 ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.service_claim_orient_sheet_mail(p_sheet_id uuid, p_caller uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s            public.orient_sheets%ROWTYPE;
  v_brand_name text;
  v_list       jsonb;
  v_now        timestamptz := clock_timestamp();   -- 이번 선점 시각(한 번만 만들어 모든 계정에 같은 값 — 결과 보고 때 그대로 돌려받는다)
  v_rec        jsonb;
  v_mailable   integer;
  v_sent       integer;
  v_inflight   integer;
  v_reason     text;
BEGIN
  -- ① 호출자 — 지금 서버 함수와 같은 판정(admins 에 auth_id 가 있는가)
  IF p_caller IS NULL OR NOT EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = p_caller) THEN
    RETURN jsonb_build_object('result', 'error', 'reason', 'forbidden');
  END IF;

  -- ② 시트
  SELECT * INTO s FROM public.orient_sheets WHERE id = p_sheet_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'error', 'reason', 'not_found');
  END IF;
  IF s.status = 'consumed' THEN
    RETURN jsonb_build_object('result', 'error', 'reason', 'consumed');
  END IF;
  IF s.status = 'expired' OR (s.token_expires_at IS NOT NULL AND s.token_expires_at <= now()) THEN
    RETURN jsonb_build_object('result', 'error', 'reason', 'expired');
  END IF;

  SELECT b.name INTO v_brand_name FROM public.brands b WHERE b.id = s.brand_id;

  -- ③ 받을 계정 — 🔴 판정은 582 한 곳. 여기서 다시 쓰지 않는다
  v_list := public._brand_mailable_accounts(s.brand_id);

  -- ④ 계정마다 선점 — 한 문장. 줄이 없으면 넣고, 있으면 「아직 안 받았고 선점이 없거나 15분 지남」일 때만 선점 시각을 바꾼다
  --    (조건 칸과 바꾸는 칸이 같은 claimed_at — 동시에 두 실행이 와도 한쪽만 이 줄을 잡는다)
  WITH m AS (
    SELECT (e.obj ->> 'auth_id')::uuid AS auth_id,
           e.obj ->> 'email'           AS email,
           e.obj ->> 'name'            AS name,
           e.ord
      FROM jsonb_array_elements(v_list) WITH ORDINALITY AS e(obj, ord)
  ), c AS (
    INSERT INTO public.orient_sheet_mail_recipients AS r (sheet_id, auth_id, claimed_at, claimed_by)
    SELECT p_sheet_id, m.auth_id, v_now, p_caller FROM m
    ON CONFLICT (sheet_id, auth_id) DO UPDATE
       SET claimed_at = v_now, claimed_by = p_caller
     WHERE r.sent_at IS NULL
       AND (r.claimed_at IS NULL OR r.claimed_at < now() - interval '15 minutes')
    RETURNING r.auth_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('auth_id', m.auth_id, 'email', m.email, 'name', m.name) ORDER BY m.ord), '[]'::jsonb)
    INTO v_rec
    FROM c JOIN m ON m.auth_id = c.auth_id;

  -- 숫자(선점 뒤 상태 기준) — 받을 수 있는 계정 중 이미 받음 / 다른 실행이 보내는 중(이번에 내가 잡은 것은 제외)
  v_mailable := jsonb_array_length(v_list);
  SELECT count(*) FILTER (WHERE r.sent_at IS NOT NULL),
         count(*) FILTER (WHERE r.sent_at IS NULL AND r.claimed_at IS NOT NULL
                            AND r.claimed_at >= now() - interval '15 minutes' AND r.claimed_at <> v_now)
    INTO v_sent, v_inflight
    FROM public.orient_sheet_mail_recipients r
   WHERE r.sheet_id = p_sheet_id
     AND r.auth_id IN (SELECT (e ->> 'auth_id')::uuid FROM jsonb_array_elements(v_list) e);

  IF jsonb_array_length(v_rec) = 0 THEN
    v_reason := CASE WHEN v_mailable = 0 THEN 'no_account'
                     WHEN v_sent = v_mailable THEN 'all_sent'
                     ELSE 'in_flight' END;
    RETURN jsonb_build_object('result', 'nothing_to_send', 'reason', v_reason,
                              'mailable_count', v_mailable, 'already_sent_count', v_sent, 'in_flight_count', v_inflight,
                              'brand_name', v_brand_name, 'token_expires_at', s.token_expires_at, 'application_id', s.application_id);
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'claimed_at', v_now, 'recipients', v_rec,
                            'mailable_count', v_mailable, 'already_sent_count', v_sent, 'in_flight_count', v_inflight,
                            'brand_name', v_brand_name, 'token_expires_at', s.token_expires_at, 'application_id', s.application_id);
END;
$$;

COMMENT ON FUNCTION public.service_claim_orient_sheet_mail(uuid, uuid) IS
  '[585] 서비스 키 전용. 오리엔시트 발급 메일 선점 — 호출자(admins)·시트 상태 확인 후 _brand_mailable_accounts(582) 계정 중 「아직 못 받았고 선점이 없거나 15분 지난」 계정만 한 문장으로 선점. 반환 {result:ok, claimed_at, recipients:[{auth_id,email,name}], mailable_count, already_sent_count, in_flight_count, brand_name, token_expires_at, application_id} | {result:nothing_to_send, reason:no_account|all_sent|in_flight, …숫자} | {result:error, reason:forbidden|not_found|consumed|expired}. claimed_at 은 결과 보고에 문자열 그대로(밀리초로 줄이면 대조 실패).';

GRANT  EXECUTE ON FUNCTION public.service_claim_orient_sheet_mail(uuid, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_claim_orient_sheet_mail(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_claim_orient_sheet_mail(uuid, uuid) FROM anon, authenticated;

-- ── 3. 결과 보고 — 서비스 키 전용, 한 명마다 ─────────────────────
CREATE OR REPLACE FUNCTION public.service_mark_orient_sheet_mail_sent(
  p_sheet_id uuid, p_auth_id uuid, p_claimed_at timestamptz, p_ok boolean)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  IF COALESCE(p_ok, false) THEN
    -- 성공 — 내 선점(시각이 같고 아직 안 보냄)일 때만
    UPDATE public.orient_sheet_mail_recipients
       SET sent_at = now()
     WHERE sheet_id = p_sheet_id AND auth_id = p_auth_id
       AND sent_at IS NULL AND claimed_at = p_claimed_at;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      -- 같은 거래에서 시트 쪽 옛 기록도 맞춘다 — 처음 보낸 시각은 유지(비어 있을 때만, 사용자 결정),
      --   받은 주소는 기존 값 뒤에 **이어 붙인다**(덮어쓰지 않는다 — 옛 방식으로 보낸 주소(신청서·대표 담당자)가 남아야
      --   관리자 조회의 legacy_sent 「옛 방식으로 ○○에게 보냄」 안내가 사라지지 않는다). 같은 주소는 한 번(소문자·공백 제거로 비교)
      UPDATE public.orient_sheets os
         SET mail_sent_at = COALESCE(os.mail_sent_at, now()),
             mail_sent_to = COALESCE((
               SELECT string_agg(z.addr, ', ' ORDER BY z.ord)
                 FROM (
                   SELECT t.addr, min(t.ord) AS ord
                     FROM (
                       SELECT lower(btrim(u.x)) AS addr, u.o AS ord
                         FROM unnest(string_to_array(COALESCE(os.mail_sent_to, ''), ',')) WITH ORDINALITY AS u(x, o)
                        WHERE btrim(u.x) <> ''
                       UNION ALL
                       SELECT lower(btrim(ba.email)), 1000000 + row_number() OVER (ORDER BY r.sent_at, ba.email)
                         FROM public.orient_sheet_mail_recipients r
                         JOIN public.brand_accounts ba ON ba.auth_id = r.auth_id
                        WHERE r.sheet_id = p_sheet_id AND r.sent_at IS NOT NULL AND btrim(COALESCE(ba.email, '')) <> ''
                     ) t
                    GROUP BY t.addr
                 ) z), os.mail_sent_to)
       WHERE os.id = p_sheet_id;
    END IF;
  ELSE
    -- 실패 — 내 선점만 풀어 다시 시도할 수 있게 하고 실패 시각을 남긴다
    UPDATE public.orient_sheet_mail_recipients
       SET claimed_at = NULL, last_failed_at = now()
     WHERE sheet_id = p_sheet_id AND auth_id = p_auth_id
       AND sent_at IS NULL AND claimed_at = p_claimed_at;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  RETURN v_n > 0;   -- false = 내 선점이 아니다(다른 실행이 다시 잡았거나 이미 보냄)
END;
$$;

COMMENT ON FUNCTION public.service_mark_orient_sheet_mail_sent(uuid, uuid, timestamptz, boolean) IS
  '[585] 서비스 키 전용. 계정 한 명의 발송 결과 보고 — 선점 시각(p_claimed_at)이 같고 아직 안 보냈을 때만: 성공이면 sent_at(+ 같은 거래에서 orient_sheets.mail_sent_at 은 비었을 때만, mail_sent_to 는 받은 계정 이메일들로 다시 이어 씀), 실패면 선점 풀기 + last_failed_at. 적었으면 true, 내 선점이 아니면 false.';

GRANT  EXECUTE ON FUNCTION public.service_mark_orient_sheet_mail_sent(uuid, uuid, timestamptz, boolean) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_mark_orient_sheet_mail_sent(uuid, uuid, timestamptz, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_orient_sheet_mail_sent(uuid, uuid, timestamptz, boolean) FROM anon, authenticated;

-- ── 4. 관리자 화면용 조회 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_orient_mail_recipients(p_brand_id uuid, p_sheet_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s            public.orient_sheets%ROWTYPE;
  v_brand_id   uuid := p_brand_id;
  v_list       jsonb;
  v_rows       jsonb;
  v_mailable   integer;
  v_sent       integer;
  v_inflight   integer;
  v_empty      text;
  v_sendable   boolean := true;
  v_blocked    text;
  v_legacy     jsonb;
  v_unmatched  text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_sheet_id IS NOT NULL THEN
    SELECT * INTO s FROM public.orient_sheets WHERE id = p_sheet_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    IF s.brand_id IS DISTINCT FROM p_brand_id THEN
      RAISE EXCEPTION 'brand_mismatch' USING ERRCODE = 'P0001';
    END IF;
    v_brand_id := s.brand_id;
    IF s.status = 'consumed' THEN
      v_sendable := false; v_blocked := 'consumed';
    ELSIF s.status = 'expired' OR (s.token_expires_at IS NOT NULL AND s.token_expires_at <= now()) THEN
      v_sendable := false; v_blocked := 'expired';
    END IF;
  END IF;

  -- 받을 계정 — 선점 함수와 같은 판정(582)
  v_list := public._brand_mailable_accounts(v_brand_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'auth_id',        (e.obj ->> 'auth_id')::uuid,
           'email',          e.obj ->> 'email',
           'name',           e.obj ->> 'name',
           'role',           e.obj ->> 'role',
           'sent_at',        r.sent_at,
           'in_flight',      (r.sent_at IS NULL AND r.claimed_at IS NOT NULL AND r.claimed_at >= now() - interval '15 minutes'),
           'last_failed_at', r.last_failed_at) ORDER BY e.ord), '[]'::jsonb),
         count(*) FILTER (WHERE r.sent_at IS NOT NULL),
         count(*) FILTER (WHERE r.sent_at IS NULL AND r.claimed_at IS NOT NULL AND r.claimed_at >= now() - interval '15 minutes')
    INTO v_rows, v_sent, v_inflight
    FROM jsonb_array_elements(v_list) WITH ORDINALITY AS e(obj, ord)
    LEFT JOIN public.orient_sheet_mail_recipients r
           ON p_sheet_id IS NOT NULL AND r.sheet_id = p_sheet_id AND r.auth_id = (e.obj ->> 'auth_id')::uuid;

  v_mailable := jsonb_array_length(v_list);

  -- 받을 계정이 0명인 까닭 — 「0명인지」는 582(_brand_mailable_accounts)가 정하고, 여기서는 **까닭 표시만** 가른다.
  --   ⚠️ 이 갈래는 582 조건의 **일부 사본**이다(브랜드 활성 · 연결 활성 · 비밀번호 정함 — 이용 제한만 581 함수를 부른다).
  --   582 의 받는 사람 규칙이 바뀌면 여기 까닭 표시도 함께 본다(받는 사람 자체는 안 틀린다 — 표시만 어긋난다)
  IF v_mailable = 0 THEN
    IF NOT EXISTS (SELECT 1 FROM public.brands b WHERE b.id = v_brand_id AND b.status = 'active') THEN
      v_empty := 'brand_archived';
    ELSIF NOT EXISTS (SELECT 1 FROM public.brand_account_links l WHERE l.brand_id = v_brand_id AND l.status = 'active') THEN
      v_empty := 'no_account';
    ELSIF NOT EXISTS (SELECT 1 FROM public.brand_account_links l
                        JOIN public.brand_accounts ba ON ba.auth_id = l.auth_id
                       WHERE l.brand_id = v_brand_id AND l.status = 'active' AND ba.password_set_at IS NOT NULL) THEN
      v_empty := 'password_not_set';
    ELSIF NOT EXISTS (SELECT 1 FROM public.brand_account_links l
                        JOIN public.brand_accounts ba ON ba.auth_id = l.auth_id
                       WHERE l.brand_id = v_brand_id AND l.status = 'active' AND ba.password_set_at IS NOT NULL
                         AND NOT public._brand_account_restricted(l.auth_id)) THEN
      v_empty := 'all_restricted';
    ELSE
      v_empty := 'no_account';   -- 남는 드문 경우(이메일이 빈 계정만 남음 등) — 받을 계정이 없다는 점은 같다
    END IF;
  END IF;

  -- 옛 방식 발송 — 시트의 mail_sent_to 중 「받음」 줄 계정 이메일과 맞지 않는 주소가 있거나, 주소 기록이 없는데 발송 시각만 있는 경우
  IF p_sheet_id IS NOT NULL AND s.mail_sent_at IS NOT NULL THEN
    SELECT string_agg(t.addr, ', ' ORDER BY t.n)
      INTO v_unmatched
      FROM (SELECT lower(btrim(x.a)) AS addr, x.n
              FROM regexp_split_to_table(COALESCE(s.mail_sent_to, ''), ',') WITH ORDINALITY AS x(a, n)
             WHERE btrim(x.a) <> '') t
     WHERE NOT EXISTS (
             SELECT 1 FROM public.orient_sheet_mail_recipients r
               JOIN public.brand_accounts ba ON ba.auth_id = r.auth_id
              WHERE r.sheet_id = p_sheet_id AND r.sent_at IS NOT NULL AND lower(btrim(ba.email)) = t.addr);
    IF v_unmatched IS NOT NULL OR btrim(COALESCE(s.mail_sent_to, '')) = '' THEN
      v_legacy := jsonb_build_object('at', s.mail_sent_at, 'to', v_unmatched);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'recipients',     v_rows,
    'counts',         jsonb_build_object('mailable', v_mailable, 'sent', v_sent,
                                         'unsent', v_mailable - v_sent - v_inflight, 'in_flight', v_inflight),
    'empty_reason',   v_empty,
    'sendable',       v_sendable,
    'blocked_reason', v_blocked,
    'legacy_sent',    v_legacy);
END;
$$;

COMMENT ON FUNCTION public.admin_get_orient_mail_recipients(uuid, uuid) IS
  '[585] 관리자 전용(is_admin, 아니면 42501). 오리엔시트 발급 메일 받을 계정 현황 — recipients 는 _brand_mailable_accounts(582) 결과 + 이 시트의 발송 기록, counts.unsent = 지금 누르면 보낼 수 있는 계정(mailable − sent − in_flight), empty_reason(받을 계정 0명일 때 brand_archived|no_account|password_not_set|all_restricted), sendable(시트 줄 때 consumed·expired 면 false)+blocked_reason, legacy_sent{at,to}(계정 기록과 맞지 않는 옛 방식 발송). 시트가 다른 브랜드면 P0001 brand_mismatch. SQL 편집기에서는 is_admin 이 안 돌아 로그인한 브라우저 콘솔로만 확인.';

GRANT  EXECUTE ON FUNCTION public.admin_get_orient_mail_recipients(uuid, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_get_orient_mail_recipients(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_orient_mail_recipients(uuid, uuid) FROM anon;

-- ── 5. 옛 기록 옮기기 ───────────────────────────────────────────
-- mail_sent_at 이 있는 시트의 mail_sent_to 를 「,」로 나눠, 주소(소문자·공백 제거)가 그 시트 브랜드에 활성 연결된 브랜드 계정 이메일과 맞으면
-- 「받음」 줄(sent_at = mail_sent_at)로 넣는다. 맞지 않는 주소(옛 갈래의 신청서 이메일·대표 담당자 주소 등)는 옮기지 않는다 —
-- 그 시트는 화면에서 「옛 방식으로 ○○에게 보냄」 한 줄(legacy_sent)로 보이고, 계정 기준으로는 「못 받음」이라 다시 보낼 수 있다(Q3).
INSERT INTO public.orient_sheet_mail_recipients (sheet_id, auth_id, sent_at)
SELECT DISTINCT s.id, ba.auth_id, s.mail_sent_at
  FROM public.orient_sheets s
 CROSS JOIN LATERAL regexp_split_to_table(COALESCE(s.mail_sent_to, ''), ',') AS tok
  JOIN public.brand_accounts ba ON lower(btrim(ba.email)) = lower(btrim(tok))
  JOIN public.brand_account_links l ON l.auth_id = ba.auth_id AND l.brand_id = s.brand_id AND l.status = 'active'
 WHERE s.mail_sent_at IS NOT NULL
   AND btrim(tok) <> ''
ON CONFLICT (sheet_id, auth_id) DO NOTHING;

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '585', '585_orient_sheet_mail_recipients.sql');
COMMIT;

-- ============================================================
-- 검증 조회 (주석 — 개발서버 SQL 편집기에서 1단계씩 실행, 결과를 보고 다음으로. 메일은 나가지 않는다: 이 함수들은 기록만 한다)
--   준비: 시험할 시트와 관리자를 정한다.
--     SELECT auth_id FROM public.admins LIMIT 1;                                   -- → :admin
--     SELECT s.id, s.brand_id, s.status, s.token_expires_at,
--            jsonb_array_length(public._brand_mailable_accounts(s.brand_id)) AS mailable
--       FROM public.orient_sheets s
--      WHERE s.status IN ('draft','submitted') AND s.token_expires_at > now()
--        AND jsonb_array_length(public._brand_mailable_accounts(s.brand_id)) > 0 LIMIT 5;   -- → :sheet (받을 계정 1명 이상)
--
--   [V1] 첫 선점: 받을 계정 전원이 recipients 로 오고 claimed_at 이 나온다 (result=ok)
--     SELECT public.service_claim_orient_sheet_mail(':sheet'::uuid, ':admin'::uuid);
--   [V2] 바로 다시 선점: 0명 — result=nothing_to_send, reason=in_flight (내가 방금 잡은 줄은 「보내는 중」)
--     SELECT public.service_claim_orient_sheet_mail(':sheet'::uuid, ':admin'::uuid);
--   [V3] 남의 시각으로 보고: false (기록 안 바뀜) — 1단계 claimed_at 이 아닌 값
--     SELECT public.service_mark_orient_sheet_mail_sent(':sheet'::uuid, ':auth_id'::uuid, now() - interval '1 hour', false);
--   [V4] 내 시각으로 실패 보고: true → 선점 풀림 + last_failed_at. 이어서 다시 선점하면 그 계정이 다시 잡힌다
--     SELECT public.service_mark_orient_sheet_mail_sent(':sheet'::uuid, ':auth_id'::uuid, ':claimed_at(1단계 문자열 그대로)'::timestamptz, false);
--     SELECT public.service_claim_orient_sheet_mail(':sheet'::uuid, ':admin'::uuid);          -- 새 claimed_at 을 받는다
--   [V5] 성공 보고: true → sent_at 기록 + orient_sheets.mail_sent_at(처음 시각 유지)·mail_sent_to 갱신. 그 뒤 선점은 그 계정을 안 잡는다
--     SELECT public.service_mark_orient_sheet_mail_sent(':sheet'::uuid, ':auth_id'::uuid, ':새 claimed_at'::timestamptz, true);
--     SELECT sheet_id, auth_id, claimed_at, sent_at, last_failed_at FROM public.orient_sheet_mail_recipients WHERE sheet_id = ':sheet';
--     SELECT mail_sent_at, mail_sent_to FROM public.orient_sheets WHERE id = ':sheet';
--     SELECT public.service_claim_orient_sheet_mail(':sheet'::uuid, ':admin'::uuid);          -- 받을 계정이 전부 받았으면 nothing_to_send / all_sent
--     (받을 계정이 2명 이상이면) 둘째 계정도 성공 보고 → mail_sent_at 이 첫 보고 때 시각 그대로인지(처음 보낸 시각 유지), mail_sent_to 에 두 주소가 다 있고 옛 주소가 남는지
--   [V6] 거부: 관리자가 아닌 번호 → reason=forbidden · 없는 시트 → not_found
--     SELECT public.service_claim_orient_sheet_mail(':sheet'::uuid, gen_random_uuid());
--     SELECT public.service_claim_orient_sheet_mail(gen_random_uuid(), ':admin'::uuid);
--     발행 끝난 시트 → consumed · 기한 지난 시트 → expired:
--     SELECT id, status, token_expires_at FROM public.orient_sheets WHERE status = 'consumed' OR token_expires_at <= now() LIMIT 3;   -- → :old
--     SELECT public.service_claim_orient_sheet_mail(':old'::uuid, ':admin'::uuid);
--   [V7] 권한: 서비스 두 함수는 anon·authenticated 가 부를 수 없어야 한다 (PUBLIC 방향 맨 앞 =X/ 가 없어야 함 — 두 방향 모두)
--     SELECT p.proname, p.proacl::text, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth, has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND p.proname IN ('service_claim_orient_sheet_mail','service_mark_orient_sheet_mail_sent','admin_get_orient_mail_recipients');
--     기대: 서비스 두 개 anon=false · auth=false · svc=true / 관리자 조회 anon=false · auth=true
--   [V8] 옮기기 확인: 옛 기록이 있던 시트의 줄 수
--     SELECT s.id, s.mail_sent_to, (SELECT count(*) FROM public.orient_sheet_mail_recipients r WHERE r.sheet_id = s.id) AS moved
--       FROM public.orient_sheets s WHERE s.mail_sent_at IS NOT NULL;
--   [V9] 기록 표: SELECT * FROM public.migration_ledger WHERE key = '585' ORDER BY id DESC LIMIT 3;
--
--   ⚠️ admin_get_orient_mail_recipients 는 SQL 편집기에서 is_admin() 이 서비스 키라 항상 거짓이 되어 42501 로 끝난다(분기가 안 돈다) —
--     로그인한 관리자 브라우저 콘솔에서 확인:
--       await db.rpc('admin_get_orient_mail_recipients', { p_brand_id: '<브랜드 번호>', p_sheet_id: '<시트 번호>' })
--     기대: recipients 길이 = counts.mailable = V1 recipients 길이 · 받은 계정은 sent_at 값 · 시트 다른 브랜드 번호를 주면 brand_mismatch.
--     (p_sheet_id 생략 = 시트 기록 없이 받을 계정만. empty_reason 은 받을 계정 0명인 브랜드로 한 번 더 확인)
-- ============================================================
