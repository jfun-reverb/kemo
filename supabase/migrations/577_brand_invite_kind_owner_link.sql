-- ============================================================
-- 577_brand_invite_kind_owner_link.sql
-- 브랜드 「연결 요청」 — 연결 1: 초대 표에 종류 칸 + 지금 함수는 멤버 초대만 + 받는 쪽 임시 막음 (사양서 4-1 · 작업표 기본값 1·5)
-- 사양서: docs/specs/2026-10-21-brand-link-request.md · 작업표 docs/specs/2026-10-21-brand-link-request-breakdown.md 「연결 1」
--
-- 왜: 관리자가 대표 없는 브랜드에 이미 있는 브랜드 계정을 대표로 이을 때, 즉시 잇지 않고 본인이 24시간 안에 수락하게 한다(연결 요청).
--   연결 요청은 새 표가 아니라 brand_invites 에 종류 칸(invite_kind)을 더해 같은 표에 둔다 — 링크·만료·메일 기록·수락 판정을 그대로 쓴다.
--   이 파일은 표를 넓히고, 지금 함수들이 연결 요청 줄을 집거나 세지 않게만 한다. **지금 있는 줄·동작은 하나도 안 바뀐다**(모두 member).
--
-- 만드는 것
--   1) 칸 brand_invites.invite_kind text NOT NULL DEFAULT 'member' + 검사 제약 둘
--      · brand_invites_invite_kind_check : member | owner_link
--      · brand_invites_owner_link_recipient_check : 연결 요청 줄은 받는 갈래 brand + sent_owner_auth_id 있음
--   2) 대기 하나 색인 둘 — 옛 brand_invites_one_pending_per_email 을 같은 이름으로 「멤버 초대만」 다시 만들고,
--      새 brand_invites_one_pending_owner_link 「브랜드마다 대기 연결 요청 하나」
--   3) 멤버 초대만 보게: _brand_seat_usage(530) · _brand_invite_reissue · create_brand_invite · resend_brand_invite · cancel_brand_invite ·
--      hide_brand_invite · get_brand_members(531) · service_brand_invite_finalize(532)
--      · resend·cancel·hide 는 연결 요청 줄 번호를 받으면 없는 줄과 같은 결과(기본값 5 — 531 [E] 존재 비노출)
--      · _brand_invite_reissue 는 연결 요청 줄이면 inviter_name(「REVERB 운영팀」)을 그대로 둔다 — 연결 2 의 다시 발급이 부른다
--   4) 🔴 임시 막음 셋(기본값 1 · 작업표 의심 1): respond_brand_invite(3인자 그대로) · _brand_acceptable_invites_for · get_brand_invite_link_state
--      — 연결 요청 줄이면 invalid / 목록에서 뺌. 532 수락은 종류를 몰라 늘 'member' 로 넣는다 — 관리자 요청(연결 2)만 들어간 날
--      받는 사람이 링크를 열면 대표가 아니라 멤버가 된다. 그 틈을 막는다. **연결 3 이 이 셋을 푼다**(개발서버만의 중간 상태)
--
-- 바꾸지 않은 것: _brand_invite_acceptable(530 — 줄 번호로 판정, 종류 무관) · service_brand_invite_create_account(532 — 갈래 new 만 받아
--   연결 요청 줄(갈래 brand)은 이미 거부) · 533 admin_release_brand_account(대표 해제 때 대기 줄 전부 취소 — 대표가 있으면 연결 요청 줄이 없다) ·
--   533 admin_get_brand_account_status(대기 숫자 — 연결 2 가 고친다)
--
-- 함수는 모두 CREATE OR REPLACE(이름·인자·반환형 그대로) — 실행 권한이 그대로 남는다. 링크 판정만 534 관례대로 권한을 다시 적었다(멱등).
--   본문은 베이스 파일 글자 그대로이고, 끝에 「-- 577」 주석을 단 줄(종류 조건·CASE)만 다르다.
--
-- 🔴 다음 재정의 베이스는 이 파일이다(530·531·532·534 베이스 금지 — 종류 조건이 빠진다).
--    임시 막음 셋은 연결 3 이 다시 정의한다(그때 베이스도 이 파일).
-- 🔴 운영 순서: 브랜드 페이지 묶음(526~534 …) 뒤, 연결 2·3·4 와 함께(사양서 7절). 메일 함수 notify-brand-invite 의 invite_kind 조회(연결 5)는
--    이 파일 적용 뒤에 배포한다(먼저 배포하면 없는 칸을 조회해 멤버 초대 메일까지 죽는다 — 작업표 의심 2).
-- 편집기 경고: 뜸 — 「Potential issue detected · destructive operations」(색인·제약 지우고 다시 만들기). 데이터는 안 지운다 — 「Run query」.
--   2026-10-21 개발서버 적용(기록 표 577 줄 15:00:41 JST)
-- 개발서버 확인(2026-10-21): 기존 초대 16줄 모두 member · 색인 둘·제약 둘 · 되돌림 시험(항상 롤백되는 블록) — 받는 갈래 new 인 연결 요청 줄 23514,
--   올바른 연결 요청 줄도 링크 판정 {"state":"invalid"}·수락 가능 목록 0·자리 셈 0 · 대표(zz-b2-owner) 로그인 멤버 초대 회귀 — 만들기(자리 3→4)·목록 대기·
--   다시 보내기·취소(자리 3) 통과, 연결 요청 줄 번호로 대표가 취소·다시 보내기·지우기 → not_owner/not_found/not_owner(존재 비노출)
-- 롤백(연결 요청 줄이 0건일 때만): ① 바꾼 함수 11개를 베이스 블록(530·531·532·534)으로 재실행
--   ② DROP INDEX public.brand_invites_one_pending_owner_link; DROP INDEX public.brand_invites_one_pending_per_email;
--      CREATE UNIQUE INDEX brand_invites_one_pending_per_email ON public.brand_invites (brand_id, email) WHERE status = 'pending';
--   ③ ALTER TABLE public.brand_invites DROP CONSTRAINT brand_invites_owner_link_recipient_check, DROP CONSTRAINT brand_invites_invite_kind_check,
--      DROP COLUMN invite_kind;
-- ============================================================
BEGIN;

-- ── 1. 종류 칸 + 검사 제약 ─────────────────────────────────────
ALTER TABLE public.brand_invites
  ADD COLUMN IF NOT EXISTS invite_kind text NOT NULL DEFAULT 'member';

ALTER TABLE public.brand_invites DROP CONSTRAINT IF EXISTS brand_invites_invite_kind_check;
ALTER TABLE public.brand_invites
  ADD CONSTRAINT brand_invites_invite_kind_check CHECK (invite_kind IN ('member', 'owner_link'));

-- 연결 요청은 「이미 있는 브랜드 계정」에게만 — 받는 갈래 brand + 그 계정 아이디
ALTER TABLE public.brand_invites DROP CONSTRAINT IF EXISTS brand_invites_owner_link_recipient_check;
ALTER TABLE public.brand_invites
  ADD CONSTRAINT brand_invites_owner_link_recipient_check
  CHECK (invite_kind <> 'owner_link' OR (recipient_kind = 'brand' AND sent_owner_auth_id IS NOT NULL));

COMMENT ON COLUMN public.brand_invites.invite_kind IS
  '[577] member = 대표가 보낸 멤버 초대(530~) / owner_link = 관리자가 대표 없는 브랜드에 이미 있는 브랜드 계정을 대표로 잇자는 연결 요청(본인 24시간 수락). 연결 요청은 자리를 안 차지하고 대표 화면 목록에 안 보인다.';

-- ── 2. 대기 하나 색인 — 종류별로 나눈다 ───────────────────────────
DROP INDEX IF EXISTS public.brand_invites_one_pending_per_email;
CREATE UNIQUE INDEX brand_invites_one_pending_per_email
  ON public.brand_invites (brand_id, email)
  WHERE status = 'pending' AND invite_kind = 'member';

-- 한 브랜드에 대기 연결 요청은 하나(이메일이 달라도)
CREATE UNIQUE INDEX IF NOT EXISTS brand_invites_one_pending_owner_link
  ON public.brand_invites (brand_id)
  WHERE status = 'pending' AND invite_kind = 'owner_link';

-- ── 3·4. 함수 (베이스 글자 그대로 + 「-- 577」 줄) ─────────────────────────

-- ── 3-1. 자리 셈 — 대기 줄은 멤버 초대만 (베이스 530) ──
CREATE OR REPLACE FUNCTION public._brand_seat_usage(p_brand_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    (CASE WHEN EXISTS (SELECT 1 FROM public.brand_account_links l
                        WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active')
          THEN 1 ELSE 0 END)
    + (SELECT count(*) FROM public.brand_account_links l
        WHERE l.brand_id = p_brand_id AND l.role = 'member' AND l.status = 'active')::int
    + (SELECT count(*) FROM public.brand_invites i
        WHERE i.brand_id = p_brand_id AND i.status = 'pending' AND i.expires_at > now()
          AND i.invite_kind = 'member')::int;   -- 577: 연결 요청 줄은 자리를 안 차지한다
$$;

COMMENT ON FUNCTION public._brand_seat_usage(uuid) IS
  '[577] (530 재정의 — 대기 줄 셈에 invite_kind=member)  내부 도우미. 자리를 차지한 수 = (활성 대표 연결 있으면 1) + 활성 멤버 연결 수 + (대기이고 만료 전인 초대 수 — ⓒ·상태가 바뀐 초대도 센다). 만료·거절·취소·수락된 초대는 안 센다. 「수락 가능」 판정(_brand_invite_acceptable)과 다른 판정.';

-- ── 3-2. 줄 다시 보내기 — 연결 요청 줄은 보낸 사람 이름을 그대로 (베이스 531) ──
CREATE OR REPLACE FUNCTION public._brand_invite_reissue(p_invite_id uuid, p_inviter uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email text;
  v_info  jsonb;
BEGIN
  SELECT i.email INTO v_email FROM public.brand_invites i WHERE i.id = p_invite_id;
  v_info := public._brand_invite_recipient_info(v_email);

  UPDATE public.brand_invites
     SET link_id            = gen_random_uuid(),
         issued_at          = now(),
         expires_at         = public._brand_invite_expires_at(now()),
         recipient_kind     = v_info->>'recipient_kind',
         sent_owner_auth_id = NULLIF(v_info->>'sent_owner_auth_id', '')::uuid,
         mail_sent_at       = NULL,
         mail_sent_link_id  = NULL,
         invited_by         = p_inviter,
         -- 577: 연결 요청 줄은 「REVERB 운영팀」 그대로(관리자 이름을 brand_accounts 에서 찾지 않는다)
         inviter_name       = CASE WHEN invite_kind = 'owner_link' THEN inviter_name
                                   ELSE public._brand_invite_inviter_name(p_inviter) END,
         owner_hidden_at    = NULL
   WHERE id = p_invite_id;
END;
$$;

COMMENT ON FUNCTION public._brand_invite_reissue(uuid, uuid) IS
  '[577] (531 재정의 — 연결 요청 줄이면 inviter_name 유지)  내부 도우미. 대기 초대 줄을 다시 보낼 상태로: 새 link_id·issued_at·expires_at·갈래 재판정·mail_sent_* 비움·보낸 사람 갱신·owner_hidden_at 비움. 호출하는 쪽이 브랜드·이메일 잠금 안에서 부른다. 호출 불가(안쪽 전용).';

-- ── 3-3. 대표의 멤버 초대 만들기 — 같은 이메일 대기 줄은 멤버 초대만 (베이스 531) ──
CREATE OR REPLACE FUNCTION public.create_brand_invite(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_status text;
  v_email  text;
  v_inv    public.brand_invites%ROWTYPE;
  v_info   jsonb;
  v_now    timestamptz := now();
  v_new_id uuid;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;

  -- 브랜드 잠금 → 대표·브랜드 활성 다시 판정
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));
  IF public._brand_caller_link_role(p_brand_id) IS DISTINCT FROM 'owner' THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN
    RETURN public._brand_invite_result('brand_inactive', NULL, NULL, false);
  END IF;

  -- 이메일 정규화·형식
  v_email := lower(btrim(COALESCE(p_email, '')));
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN public._brand_invite_result('invalid_email', NULL, p_brand_id, true);
  END IF;

  -- 이메일 잠금(브랜드 → 이메일 순서 — 527 과 같다)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  -- 본인 이메일
  IF EXISTS (SELECT 1 FROM public.brand_accounts a WHERE a.auth_id = v_uid AND lower(btrim(a.email)) = v_email) THEN
    RETURN public._brand_invite_result('self_email', NULL, p_brand_id, true);
  END IF;

  -- 이미 이 브랜드의 활성 연결(대표·멤버)
  IF EXISTS (SELECT 1
               FROM public.brand_account_links l
               JOIN public.brand_accounts a ON a.auth_id = l.auth_id
              WHERE l.brand_id = p_brand_id AND l.status = 'active' AND lower(btrim(a.email)) = v_email) THEN
    RETURN public._brand_invite_result('already_member', NULL, p_brand_id, true);
  END IF;

  -- 같은 이메일의 대기 초대
  SELECT i.* INTO v_inv
    FROM public.brand_invites i
   WHERE i.brand_id = p_brand_id AND i.email = v_email AND i.status = 'pending'
     AND i.invite_kind = 'member'   -- 577: 연결 요청 줄은 대표 초대와 별개
   FOR UPDATE;
  IF FOUND THEN
    IF v_inv.expires_at <= v_now THEN
      -- 만료 줄 → 그 줄 다시 보내기(자리 검사 포함 — 만료 줄은 자리를 안 차지한다)
      IF public._brand_seat_usage(p_brand_id) >= public._brand_member_limit(p_brand_id) THEN
        RETURN public._brand_invite_result('seat_full', NULL, p_brand_id, true);
      END IF;
      PERFORM public._brand_invite_reissue(v_inv.id, v_uid);
      RETURN public._brand_invite_result('ok', v_inv.id, p_brand_id, true);
    ELSIF v_inv.mail_sent_link_id IS DISTINCT FROM v_inv.link_id THEN
      -- 만료 전 + 지금 링크로 발송 기록 없음 → 멱등 재시도(자리 검사 없음 — 이미 자리를 차지한 줄)
      PERFORM public._brand_invite_reissue(v_inv.id, v_uid);
      RETURN public._brand_invite_result('ok', v_inv.id, p_brand_id, true);
    ELSE
      RETURN public._brand_invite_result('already_pending', v_inv.id, p_brand_id, true);
    END IF;
  END IF;

  -- 새 줄 (거절·취소·수락된 줄은 재사용하지 않는다)
  IF public._brand_seat_usage(p_brand_id) >= public._brand_member_limit(p_brand_id) THEN
    RETURN public._brand_invite_result('seat_full', NULL, p_brand_id, true);
  END IF;

  v_info := public._brand_invite_recipient_info(v_email);
  INSERT INTO public.brand_invites
    (brand_id, email, invited_by, inviter_name, status, recipient_kind, sent_owner_auth_id, issued_at, expires_at)
  VALUES
    (p_brand_id, v_email, v_uid, public._brand_invite_inviter_name(v_uid), 'pending',
     v_info->>'recipient_kind', NULLIF(v_info->>'sent_owner_auth_id', '')::uuid, v_now, public._brand_invite_expires_at(v_now))
  RETURNING id INTO v_new_id;

  RETURN public._brand_invite_result('ok', v_new_id, p_brand_id, true);
END;
$$;

COMMENT ON FUNCTION public.create_brand_invite(uuid, text) IS
  '[577] (531 재정의 — 대기 줄 조회에 invite_kind=member)  대표가 멤버 초대를 만든다. 결과 ok/not_owner/brand_inactive/invalid_email/self_email/already_member/already_pending/seat_full. 응답 키 {result, invite_id, seat_used, member_limit} 는 늘 같고 갈래(ⓐⓑⓒ)를 짐작할 값이 없다. 만료 줄·발송 기록 없는 대기 줄은 같은 줄을 다시 보낸다(머리말 [F]). authenticated 전용.';

-- ── 3-4. 다시 보내기 — 연결 요청 줄은 없는 줄과 같다 (베이스 531, 기본값 5) ──
CREATE OR REPLACE FUNCTION public.resend_brand_invite(p_invite_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_role     text;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  -- 브랜드를 알기 위해 잠금 전에 한 번 읽는다
  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  -- 잠금 안에서 줄·역할을 다시 읽는다
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR v_inv.brand_id <> v_brand_id OR v_inv.invite_kind <> 'member' THEN   -- 577: 연결 요청 줄은 존재 비노출
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  v_role := public._brand_caller_link_role(v_brand_id);
  IF v_role IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);      -- 남의 브랜드 — 존재 비노출(머리말 [E])
  END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_role <> 'owner' OR v_status IS DISTINCT FROM 'active' THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN public._brand_invite_result('not_resendable', p_invite_id, v_brand_id, true);
  END IF;

  -- 이메일 잠금(갈래를 다시 판정하므로) — 브랜드 → 이메일 순서
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_inv.email));

  -- 만료 줄만 자리 검사(만료 전 대기 줄은 이미 자리를 차지 — 가득 차도 ok)
  IF v_inv.expires_at <= now()
     AND public._brand_seat_usage(v_brand_id) >= public._brand_member_limit(v_brand_id) THEN
    RETURN public._brand_invite_result('seat_full', p_invite_id, v_brand_id, true);
  END IF;

  PERFORM public._brand_invite_reissue(p_invite_id, v_uid);
  RETURN public._brand_invite_result('ok', p_invite_id, v_brand_id, true);
END;
$$;

COMMENT ON FUNCTION public.resend_brand_invite(uuid) IS
  '[577] (531 재정의 — 연결 요청 줄이면 not_found)  대표가 초대를 다시 보낸다 — 새 링크·시각·갈래, 발송 기록 비움, 보낸 사람을 지금 대표로. 결과 ok/not_owner/not_found/not_resendable/seat_full(만료 줄만). 남의 브랜드·없는 줄은 똑같이 not_found. authenticated 전용.';

-- ── 3-5. 취소 — 연결 요청 줄은 없는 줄과 같다 (베이스 531, 기본값 5) ──
CREATE OR REPLACE FUNCTION public.cancel_brand_invite(p_invite_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN RETURN 'not_owner'; END IF;

  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN RETURN 'not_owner'; END IF;          -- 줄이 없든 남의 것이든 같은 값(머리말 [E])

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR v_inv.invite_kind <> 'member' THEN RETURN 'not_owner'; END IF;   -- 577: 연결 요청 줄은 존재 비노출
  IF public._brand_caller_link_role(v_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 대기이고 만료 전인 줄만 — 만료 줄(저장 상태는 pending)도 거부(다시 보내기·삭제만)
  IF v_inv.status <> 'pending' OR v_inv.expires_at <= now() THEN RETURN 'not_pending'; END IF;

  UPDATE public.brand_invites SET status = 'cancelled', cancelled_at = now() WHERE id = p_invite_id;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.cancel_brand_invite(uuid) IS
  '[577] (531 재정의 — 연결 요청 줄이면 not_owner)  대표가 대기 초대(만료 전)를 취소한다. 결과 ok/not_owner(없는 줄·남의 줄 포함)/not_pending(만료·거절·취소·수락). authenticated 전용.';

-- ── 3-6. 목록에서 지우기 — 연결 요청 줄은 없는 줄과 같다 (베이스 531, 기본값 5) ──
CREATE OR REPLACE FUNCTION public.hide_brand_invite(p_invite_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN RETURN 'not_owner'; END IF;

  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN RETURN 'not_owner'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR v_inv.invite_kind <> 'member' THEN RETURN 'not_owner'; END IF;   -- 577: 연결 요청 줄은 존재 비노출
  IF public._brand_caller_link_role(v_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 만료(대기 + 기한 지남)·거절만 「삭제」
  IF NOT (v_inv.status = 'declined' OR (v_inv.status = 'pending' AND v_inv.expires_at <= now())) THEN
    RETURN 'not_hideable';
  END IF;

  UPDATE public.brand_invites SET owner_hidden_at = COALESCE(owner_hidden_at, now()) WHERE id = p_invite_id;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.hide_brand_invite(uuid) IS
  '[577] (531 재정의 — 연결 요청 줄이면 not_owner)  대표가 만료·거절 초대 줄을 목록에서 지운다(owner_hidden_at). 결과 ok/not_owner(없는 줄·남의 줄 포함)/not_hideable. 만료 줄에 같은 이메일을 다시 초대하면 되살아난다. authenticated 전용.';

-- ── 3-7. 멤버 관리 목록 — 초대 행은 멤버 초대만 (베이스 531) ──
CREATE OR REPLACE FUNCTION public.get_brand_members(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_rows jsonb;
BEGIN
  -- 활성 연결 + 활성 브랜드가 없으면 not_linked
  v_role := public.my_brand_role(p_brand_id);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  IF v_role = 'owner' THEN
    SELECT COALESCE(jsonb_agg(t.j ORDER BY t.grp, t.ord), '[]'::jsonb) INTO v_rows
      FROM (
        -- 계정 행: 대표(grp 0) → 멤버(grp 1, 연결 생성순)
        SELECT CASE l.role WHEN 'owner' THEN 0 ELSE 1 END AS grp, l.created_at AS ord,
               jsonb_build_object(
                 'kind', 'account', 'auth_id', l.auth_id, 'invite_id', NULL, 'name', a.name, 'email', a.email,
                 'role', l.role, 'status', 'active', 'issued_at', NULL, 'expires_at', NULL, 'declined_at', NULL,
                 'last_active_at', l.last_active_at) AS j
          FROM public.brand_account_links l
          JOIN public.brand_accounts a ON a.auth_id = l.auth_id
         WHERE l.brand_id = p_brand_id AND l.status = 'active'
        UNION ALL
        -- 초대 행(grp 2, 발급순): 대기·거절만, 취소·수락·숨김 제외. name 은 늘 NULL(겹침 비노출)
        SELECT 2 AS grp, i.issued_at AS ord,
               jsonb_build_object(
                 'kind', 'invite', 'auth_id', NULL, 'invite_id', i.id, 'name', NULL, 'email', i.email,
                 'role', 'member',
                 'status', CASE WHEN i.status = 'declined' THEN 'declined'
                                WHEN i.expires_at > now() THEN 'pending' ELSE 'expired' END,
                 'issued_at', i.issued_at, 'expires_at', i.expires_at, 'declined_at', i.declined_at,
                 'last_active_at', NULL) AS j
          FROM public.brand_invites i
         WHERE i.brand_id = p_brand_id AND i.status IN ('pending', 'declined') AND i.owner_hidden_at IS NULL
           AND i.invite_kind = 'member'   -- 577: 연결 요청 줄은 대표 목록에 안 보인다
      ) t;

    RETURN jsonb_build_object(
      'my_role',      v_role,
      'seat_used',    public._brand_seat_usage(p_brand_id),
      'member_limit', public._brand_member_limit(p_brand_id),
      'rows',         v_rows
    );
  END IF;

  -- 멤버 호출: 계정 행만 · auth_id 키 자체를 뺀다 · last_active_at 은 준다 · 자리 수는 대표와 같은 값(머리말 [L], 사양서 16-7)
  SELECT COALESCE(jsonb_agg(t.j ORDER BY t.grp, t.ord), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT CASE l.role WHEN 'owner' THEN 0 ELSE 1 END AS grp, l.created_at AS ord,
             jsonb_build_object(
               'kind', 'account', 'invite_id', NULL, 'name', a.name, 'email', a.email,
               'role', l.role, 'status', 'active', 'issued_at', NULL, 'expires_at', NULL, 'declined_at', NULL,
               'last_active_at', l.last_active_at) AS j
        FROM public.brand_account_links l
        JOIN public.brand_accounts a ON a.auth_id = l.auth_id
       WHERE l.brand_id = p_brand_id AND l.status = 'active'
    ) t;

  RETURN jsonb_build_object(
    'my_role',      v_role,
    'seat_used',    public._brand_seat_usage(p_brand_id),
    'member_limit', public._brand_member_limit(p_brand_id),
    'rows',         v_rows
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_members(uuid) IS
  '[577] (531 재정의 — 초대 행에 invite_kind=member)  멤버 관리 목록. 활성 연결이 없으면 {result:''not_linked''}. 대표: {my_role, seat_used, member_limit, rows[]} — 계정 행(auth_id 포함)+초대 행(대기·만료·거절, name 늘 NULL, 취소·수락·숨김 제외).
   멤버: 계정 행만, auth_id 키 없음, last_active_at 포함, seat_used·member_limit 는 대표와 같은 값(사양서 16-7). authenticated 전용.';

-- ── 3-8. 새 이메일 초대 마무리 — 연결 요청 줄이면 invalid_link (베이스 532) ──
CREATE OR REPLACE FUNCTION public.service_brand_invite_finalize(p_link_id uuid, p_auth_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pre public.brand_invites%ROWTYPE;
  v_inv public.brand_invites%ROWTYPE;
  v_pw  text;
BEGIN
  IF p_link_id IS NULL OR p_auth_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  -- 브랜드 → 이메일 (create_account 와 같은 열쇠·순서)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR v_inv.link_id <> p_link_id
     OR v_inv.invite_kind <> 'member'   -- 577: 연결 요청 줄은 이 경로가 아니다
     OR NOT public._brand_invite_acceptable(v_inv.id, p_auth_id, true) THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  PERFORM 1 FROM public.brand_accounts a WHERE a.auth_id = p_auth_id FOR UPDATE;

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.auth_id = p_auth_id AND l.brand_id = v_inv.brand_id AND l.status = 'active') THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', v_inv.brand_id, 'reason', 'already_member');
  END IF;

  -- 비밀번호가 실제로 정해졌는지
  SELECT u.encrypted_password INTO v_pw FROM auth.users u WHERE u.id = p_auth_id;
  IF v_pw IS NULL OR v_pw = '' THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', v_inv.brand_id, 'reason', 'password_not_set');
  END IF;

  UPDATE public.brand_accounts
     SET password_changed_at = CASE WHEN password_set_at IS NULL THEN now() ELSE password_changed_at END,
         password_set_at     = COALESCE(password_set_at, now())
   WHERE auth_id = p_auth_id;

  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
  VALUES (p_auth_id, v_inv.brand_id, 'member', 'active');
  UPDATE public.brand_invites
     SET status = 'accepted', accepted_at = now(), accepted_auth_id = p_auth_id
   WHERE id = v_inv.id;

  RETURN jsonb_build_object('ok', true, 'brand_id', v_inv.brand_id, 'reason', NULL);
END;
$$;

COMMENT ON FUNCTION public.service_brand_invite_finalize(uuid, uuid) IS
  '[577] (532 재정의 — 연결 요청 줄이면 invalid_link)  서비스 키 전용(조각 6). 새 이메일(ⓐ) 초대 수락 2단계(비밀번호 저장 뒤) — 브랜드→이메일 잠금 안에서 수락 가능(p_via_link=true, 계정 이메일 일치)을 다시 판정 → 비밀번호 실재 확인 → password_set_at·password_changed_at(비어 있을 때만) → 멤버 연결 → 초대 accepted. 반환 {ok, brand_id, reason} — reason: invalid_link·password_not_set·already_member. 계정 정리는 호출하는 서버 함수 몫.';

-- ── 4-1. 🔴 임시 막음 — 수락·거절: 연결 요청 줄이면 invalid (베이스 532, 3인자 그대로 · 연결 3 이 푼다) ──
CREATE OR REPLACE FUNCTION public.respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text)
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
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('result', 'not_brand', 'brand_id', NULL);
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('accept', 'decline') THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
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
  IF NOT FOUND OR (p_link_id IS NOT NULL AND v_inv.link_id <> p_link_id)
     OR v_inv.invite_kind <> 'member' THEN   -- 577 임시 막음: 연결 요청 줄을 멤버로 받지 않는다(연결 3 이 푼다)
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
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

  RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id);
END;
$$;

COMMENT ON FUNCTION public.respond_brand_invite(uuid, uuid, text) IS
  '[577] (532 재정의 — 임시 막음: 연결 요청 줄이면 invalid, 연결 3 이 푼다)  초대 수락·거절(메일 링크=p_link_id, 마이페이지=p_invite_id, 같은 함수). p_action = accept | decline. 결과 {result, brand_id} — ok·already_member·invalid·not_brand·setup_incomplete.
   브랜드 잠금(527 열쇠) → 이메일 잠금 → 줄 재독(링크 번호 재확인) → _brand_invite_acceptable(id, 로그인 계정, false). 수락은 비밀번호 설정을 마친 계정만, 자리는 다시 검사하지 않음. authenticated 전용.';

-- ── 4-2. 🔴 임시 막음 — 수락할 수 있는 초대: 멤버 초대만 (베이스 532 · 연결 3 이 푼다) ──
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
     AND i.invite_kind = 'member'   -- 577 임시 막음(연결 3 이 푼다)
     AND public._brand_invite_acceptable(i.id, p_auth_id, false);
$$;

COMMENT ON FUNCTION public._brand_acceptable_invites_for(uuid) IS
  '[577] (532 재정의 — 임시 막음: invite_kind=member, 연결 3 이 푼다)  내부 도우미. 이 계정이 지금 수락할 수 있는 대기 초대(만료 전 + _brand_invite_acceptable(id, 계정, false) 통과). 로그인 판정·받은 초대 목록·527 링크 판정이 함께 쓴다. 호출 불가(안쪽 전용).';

-- ── 4-3. 🔴 임시 막음 — 링크 판정: 연결 요청 줄이면 invalid (베이스 534 · CREATE OR REPLACE 로만 · 연결 3 이 푼다) ──
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
  IF NOT FOUND OR v_inv.invite_kind <> 'member'   -- 577 임시 막음(연결 3 이 푼다)
     OR NOT public._brand_invite_acceptable(v_inv.id, NULL, true) THEN
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
  '[577] (534 재정의 — 임시 막음: 연결 요청 줄이면 invalid, 연결 3 이 푼다)  초대 메일 링크 판정(비로그인 가능). 수락 가능이면 {state:valid, recipient:new|existing, brand_name, inviter_name, issued_at, expires_at} + recipient=new 일 때만 email, 아니면 {state:invalid} 한 칸. 판정은 _brand_invite_acceptable(id, NULL, true). 링크 소지자에게 브랜드·보낸 사람 이름을 주는 것은 의도된 예외(작업표 어긋남 3번). 링크 소지자에게 새 이메일 초대의 이메일을 주는 것은 사용자 결정(피그마 w01-02b 읽기 전용 이메일 칸 — 작업표 S0-2, 2026-10-15). 전달받은 사람에게도 보인다. 베이스 532.';

-- ── 5. 실행 권한 — 링크 판정만 534 와 같은 상태를 다시 적는다(멱등). 나머지는 CREATE OR REPLACE 라 그대로 ──
GRANT  EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '577', '577_brand_invite_kind_owner_link.sql');
COMMIT;
