-- ============================================================
-- 495_signup_code_functions.sql
-- 회원가입 이메일 인증번호 — 조각 D3 「서버 전용 도우미(발급·취소·대조)」
--   선행: 493(설정 표) · 494(번호 표). 해시 규격은 494 머리말.
--
-- 함수 5개 (전부 SECURITY DEFINER + SET search_path = '')
--   signup_code_issue(p_email_hash, p_code_hash)                      → jsonb  (발급·요청 제한 판정)
--   signup_code_cancel(p_code_id)                                      → void   (메일 발송 실패 시 무효 표시)
--   signup_code_verify(p_email_hash, p_code_hash, p_ticket_hash, p_email) → jsonb (번호 대조 + 옛 미인증 계정 정리 + 확인증 저장)
--   _signup_unverified_has_records(p_user_id)                          → boolean (「다른 기록」 판정 — 498 이 같은 것을 쓴다)
--
-- 실행 권한: postgres·service_role 에만(발송·확인 Edge Function 이 서비스 키로 부른다).
--   375 순서 — **부여 먼저, 회수 나중**(PUBLIC → anon·authenticated). 회수만 넣으면 안 된다.
--
-- 🔴 수치(번호 유효시간·재발송 대기·틀린 횟수·시간당 상한 등)는 **매 호출마다 493 설정 표에서 읽는다**.
--    코드에 박지 않는다(완료 기준 4-2: 배포 없이 SQL 로 바꾸면 바로 반영).
-- 🔴 원문 이메일은 인증 계정을 찾을 때(verify)만 잠깐 쓰고 **어디에도 저장하지 않는다**.
--
-- 「다른 기록」 판정에 쓴 표와 칸 (각 표의 마이그레이션을 읽어 확인한 값)
--   applications.user_id          (002)
--   deliverables.user_id          (035)
--   settlements.influencer_id     (217)
--   event_tickets.influencer_id   (282)
--   withdrawal_requests.influencer_id (345)
--   influencer_flags.influencer_id    (059)
--   application_messages.sender_id    (144 — 본인이 보낸 메시지)
--   application_messages.influencer_id(475 — 일반 문의 행. ⚠️ **운영에는 475 가 아직 없을 수 있다**(창구 10/6 운영 반영) →
--        칸이 있을 때만 동적으로 본다. 정적으로 쓰면 운영에서 함수가 실행 때마다 실패한다)
--   ❌ policy_notice_log 는 넣지 않는다 — 연쇄 삭제되며 함께 지우기로 사용자가 결정(2026-10-01)
--   ⚠️ 응모(applications)가 없으면 그 응모에 달린 결과물·정산·메시지·행사 예약은 원래 없다.
--      그래도 사양서 작업표 목록대로 전부 직접 본다(응모 없이 생긴 행이 있어도 놓치지 않게).
--
-- 롤백
--   DROP FUNCTION IF EXISTS public.signup_code_verify(text, text, text, text);
--   DROP FUNCTION IF EXISTS public.signup_code_cancel(uuid);
--   DROP FUNCTION IF EXISTS public.signup_code_issue(text, text);
--   DROP FUNCTION IF EXISTS public._signup_unverified_has_records(uuid);
--   (498 이 적용돼 있으면 498 을 먼저 — 그 함수가 도우미를 부른다)
-- ============================================================

BEGIN;

-- ── 공용 도우미: 이 회원 id 에 「다른 기록」이 있나 ───────────────────
CREATE OR REPLACE FUNCTION public._signup_unverified_has_records(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_has_col boolean;
  v_found   boolean := false;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  IF EXISTS (SELECT 1 FROM public.applications         WHERE user_id       = p_user_id)
  OR EXISTS (SELECT 1 FROM public.deliverables         WHERE user_id       = p_user_id)
  OR EXISTS (SELECT 1 FROM public.settlements          WHERE influencer_id = p_user_id)
  OR EXISTS (SELECT 1 FROM public.event_tickets        WHERE influencer_id = p_user_id)
  OR EXISTS (SELECT 1 FROM public.withdrawal_requests  WHERE influencer_id = p_user_id)
  OR EXISTS (SELECT 1 FROM public.influencer_flags     WHERE influencer_id = p_user_id)
  OR EXISTS (SELECT 1 FROM public.application_messages WHERE sender_id     = p_user_id)
  THEN
    RETURN true;
  END IF;

  -- 일반 문의 행(475). 칸이 없는 환경(운영 — 창구 반영 전)에서는 건너뛴다.
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'application_messages'
       AND column_name = 'influencer_id'
  ) INTO v_has_col;
  IF v_has_col THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.application_messages WHERE influencer_id = $1)'
      INTO v_found USING p_user_id;
    IF v_found THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public._signup_unverified_has_records(uuid) IS
  '[495] 미인증 계정 삭제 전 「다른 기록」 판정 — 응모·결과물·정산·행사 예약·탈퇴 신청·위반/인증 이력·메시지 중 하나라도 있으면 true. '
  'policy_notice_log 는 포함하지 않는다(연쇄 삭제 — 사용자 결정). 신규 환경에서 칸이 없는 application_messages.influencer_id(475)는 있을 때만 본다. '
  'signup_code_verify(495)와 purge_unverified_accounts(498)가 함께 쓴다 — 표를 더하면 이 함수 한 곳만 고친다.';

-- ── 발급 ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.signup_code_issue(p_email_hash text, p_code_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_s            public.signup_code_settings%ROWTYPE;
  v_now          timestamptz := now();
  v_avail        timestamptz := v_now;
  v_latest       timestamptz;
  v_cnt          integer;
  v_edge         timestamptz;
  v_id           uuid;
  v_expires      timestamptz;
  v_resend       timestamptz;
BEGIN
  IF p_email_hash IS NULL OR p_email_hash !~ '^[0-9a-f]{64}$'
     OR p_code_hash IS NULL OR p_code_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_hash';
  END IF;

  -- 같은 주소의 동시 요청 직렬화(243 방식). 전역 상한은 주소가 달라 느슨하게 센다 —
  -- 동시에 몰린 몇 건이 상한을 조금 넘을 수 있으나 발송 폭주 방어가 목적이라 수용한다.
  PERFORM pg_advisory_xact_lock(hashtext('signup_code:' || p_email_hash));

  SELECT * INTO v_s FROM public.signup_code_settings WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settings_missing';
  END IF;

  -- ① 재발송 대기 — 이 주소의 가장 최근 발급 시각 기준(무효 처리된 행도 센다 —
  --    ⚠️ 메일 발송 실패로 취소된 행도 대기에 든다. 폭주 방어를 우선한 결정)
  SELECT max(created_at) INTO v_latest
    FROM public.signup_email_codes WHERE email_hash = p_email_hash;
  IF v_latest IS NOT NULL
     AND v_latest + make_interval(secs => v_s.resend_cooldown_seconds) > v_now THEN
    v_avail := greatest(v_avail, v_latest + make_interval(secs => v_s.resend_cooldown_seconds));
  END IF;

  -- ② 주소별 시간당 상한 — 한도 번째로 최근인 행이 1시간 창에서 빠지는 시각
  SELECT count(*) INTO v_cnt
    FROM public.signup_email_codes
   WHERE email_hash = p_email_hash AND created_at > v_now - interval '1 hour';
  IF v_cnt >= v_s.per_email_hourly_limit THEN
    SELECT created_at INTO v_edge
      FROM public.signup_email_codes
     WHERE email_hash = p_email_hash AND created_at > v_now - interval '1 hour'
     ORDER BY created_at DESC
     OFFSET (v_s.per_email_hourly_limit - 1) LIMIT 1;
    v_avail := greatest(v_avail, v_edge + interval '1 hour');
  END IF;

  -- ③ 전역 시간당 상한(Brevo 직접 발송 보호 — 인증 서비스 발송 한도의 보호가 없다)
  SELECT count(*) INTO v_cnt
    FROM public.signup_email_codes WHERE created_at > v_now - interval '1 hour';
  IF v_cnt >= v_s.global_hourly_limit THEN
    SELECT created_at INTO v_edge
      FROM public.signup_email_codes
     WHERE created_at > v_now - interval '1 hour'
     ORDER BY created_at DESC
     OFFSET (v_s.global_hourly_limit - 1) LIMIT 1;
    v_avail := greatest(v_avail, v_edge + interval '1 hour');
  END IF;

  IF v_avail > v_now THEN
    -- 행을 만들지 않는다. 가입 여부와 무관한 판정이라 알려도 존재가 드러나지 않는다.
    RETURN jsonb_build_object('status', 'rate_limited', 'resend_available_at', v_avail);
  END IF;

  -- 이전 살아 있는 행 무효(덮어쓰지 않음 — 재발송을 세려면 행이 남아야 한다)
  UPDATE public.signup_email_codes
     SET invalidated_at = v_now
   WHERE email_hash = p_email_hash AND invalidated_at IS NULL;

  v_expires := v_now + make_interval(secs => v_s.code_ttl_seconds);
  v_resend  := v_now + make_interval(secs => v_s.resend_cooldown_seconds);

  INSERT INTO public.signup_email_codes (email_hash, code_hash, expires_at, created_at)
  VALUES (p_email_hash, p_code_hash, v_expires, v_now)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'status', 'sent',
    'code_id', v_id,
    'code_expires_at', v_expires,
    'resend_available_at', v_resend
  );
END;
$$;

COMMENT ON FUNCTION public.signup_code_issue(text, text) IS
  '[495] 인증번호 발급 + 요청 제한(재발송 대기·주소별·전역 시간당). 제한이면 {status:rate_limited, resend_available_at} 행 안 만듦, '
  '아니면 이전 살아 있는 행 무효 + 새 행 → {status:sent, code_id, code_expires_at, resend_available_at}. 수치는 매번 493 설정 표에서. service_role 전용.';

-- ── 취소(메일 발송 실패) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.signup_code_cancel(p_code_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.signup_email_codes
     SET invalidated_at = now()
   WHERE id = p_code_id AND invalidated_at IS NULL;
$$;

COMMENT ON FUNCTION public.signup_code_cancel(uuid) IS
  '[495] 메일 발송 실패 시 방금 발급한 번호를 무효로 표시. service_role 전용.';

-- ── 확인(번호 대조 + 옛 미인증 계정 정리 + 확인증 저장) ──────────────
CREATE OR REPLACE FUNCTION public.signup_code_verify(
  p_email_hash  text,
  p_code_hash   text,
  p_ticket_hash text,
  p_email       text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_s        public.signup_code_settings%ROWTYPE;
  v_row      public.signup_email_codes%ROWTYPE;
  v_norm     text;
  v_ids      uuid[];
  v_id       uuid;
  v_attempts integer;
  v_ticket_exp timestamptz;
BEGIN
  IF p_email_hash IS NULL OR p_email_hash !~ '^[0-9a-f]{64}$'
     OR p_code_hash IS NULL OR p_code_hash !~ '^[0-9a-f]{64}$'
     OR p_ticket_hash IS NULL OR p_ticket_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_hash';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('signup_code:' || p_email_hash));

  SELECT * INTO v_s FROM public.signup_code_settings WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settings_missing';
  END IF;

  -- 해시와 원문 이메일이 같은 주소인지 — 어긋나면 번호를 소비하지 않고 no_code
  v_norm := lower(btrim(coalesce(p_email, '')));
  IF encode(extensions.digest(v_norm, 'sha256'), 'hex') <> p_email_hash THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_code');
  END IF;

  -- 이 주소의 가장 최근 「살아 있는」 번호(무효·확인 완료 제외)
  SELECT * INTO v_row
    FROM public.signup_email_codes
   WHERE email_hash = p_email_hash AND invalidated_at IS NULL AND verified_at IS NULL
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_code');
  END IF;

  IF v_row.expires_at <= now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'expired');
  END IF;

  IF v_row.attempts >= v_s.max_attempts THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;

  -- 번호 불일치 — 횟수 +1, 상한에 닿으면 이 번호 무효(재발송 필요)
  IF v_row.code_hash <> p_code_hash THEN
    v_attempts := v_row.attempts + 1;
    UPDATE public.signup_email_codes
       SET attempts = v_attempts,
           invalidated_at = CASE WHEN v_attempts >= v_s.max_attempts THEN now() ELSE invalidated_at END
     WHERE id = v_row.id;
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'mismatch',
      'attempts_left', greatest(v_s.max_attempts - v_attempts, 0)
    );
  END IF;

  -- ── 번호 일치 ── 같은 주소의 옛 미인증 계정 정리(경우의 수 12-②) ──
  SELECT coalesce(array_agg(u.id), '{}') INTO v_ids
    FROM auth.users u
   WHERE lower(btrim(u.email)) = v_norm
     AND u.email_confirmed_at IS NULL;

  -- ① 먼저 전부 검사 — 하나라도 다른 기록이 있거나 관리자 계정이면 아무것도 지우지 않고 확인증도 안 준다
  FOREACH v_id IN ARRAY v_ids LOOP
    IF public._signup_unverified_has_records(v_id)
       OR EXISTS (SELECT 1 FROM public.admins WHERE auth_id = v_id)
       OR EXISTS (SELECT 1 FROM public.influencers WHERE id = v_id AND is_audit) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'contact_support');
    END IF;
  END LOOP;

  -- ② 지운다 — 인증 계정을 지워도 회원 행은 연쇄로 안 지워진다(실측) → 회원 행 → 신원 → 계정 순(253)
  --    하위 블록: 어떤 오류든 이 삭제 전체를 되돌리고 「문의」 안내로 닫는다(확인증은 안 줌).
  IF array_length(v_ids, 1) IS NOT NULL THEN
    BEGIN
      FOREACH v_id IN ARRAY v_ids LOOP
        DELETE FROM public.influencers WHERE id = v_id;
        DELETE FROM auth.identities    WHERE user_id = v_id;
        DELETE FROM auth.users         WHERE id = v_id;
      END LOOP;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'contact_support');
    END;
  END IF;

  v_ticket_exp := now() + make_interval(secs => v_s.ticket_ttl_seconds);
  UPDATE public.signup_email_codes
     SET verified_at = now(),
         ticket_hash = p_ticket_hash,
         ticket_expires_at = v_ticket_exp
   WHERE id = v_row.id;

  RETURN jsonb_build_object('ok', true, 'ticket_expires_at', v_ticket_exp);
END;
$$;

COMMENT ON FUNCTION public.signup_code_verify(text, text, text, text) IS
  '[495] 인증번호 확인. 살아 있는 최신 번호 대조(no_code/expired/locked/mismatch+attempts_left). 일치하면 같은 주소의 옛 미인증 계정을 '
  '회원 행→신원→계정 순으로 삭제(다른 기록·관리자 계정이 있으면 아무것도 안 지우고 contact_support, 확인증 미발급) 후 확인증 해시 저장. '
  '번호가 상한에 닿으면 그 행은 무효가 되어 이후 호출은 no_code. 원문 이메일 미저장. service_role 전용.';

-- ── 실행 권한 (375 순서: 부여 먼저 → PUBLIC 회수 → anon·authenticated 회수) ──
GRANT EXECUTE ON FUNCTION public._signup_unverified_has_records(uuid)              TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.signup_code_issue(text, text)                     TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.signup_code_cancel(uuid)                          TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.signup_code_verify(text, text, text, text)        TO postgres, service_role;

REVOKE EXECUTE ON FUNCTION public._signup_unverified_has_records(uuid)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._signup_unverified_has_records(uuid)             FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.signup_code_issue(text, text)                    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.signup_code_issue(text, text)                    FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.signup_code_cancel(uuid)                         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.signup_code_cancel(uuid)                         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.signup_code_verify(text, text, text, text)       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.signup_code_verify(text, text, text, text)       FROM anon, authenticated;

COMMIT;

-- ------------------------------------------------------------
-- 검증 (개발서버 — 편집기는 postgres 라 호출 가능. 메일은 안 나간다. 1단계씩)
-- ------------------------------------------------------------
-- [1] 권한: 맨 앞 `=X/`(PUBLIC) 이 없고 anon·authenticated 가 없어야 한다
-- SELECT proname, prosecdef, proconfig, proacl::text FROM pg_proc
--  WHERE pronamespace = 'public'::regnamespace
--    AND proname IN ('signup_code_issue','signup_code_cancel','signup_code_verify','_signup_unverified_has_records');
-- [2] 발급 두 번 — 첫째 sent, 곧바로 둘째 rate_limited (해시는 시험값)
-- SELECT public.signup_code_issue(repeat('a',64), repeat('b',64));
-- SELECT public.signup_code_issue(repeat('a',64), repeat('b',64));
-- [3] 틀린 번호 5회 → mismatch attempts_left 4,3,2,1,0 → 이후 no_code
-- SELECT public.signup_code_verify(encode(extensions.digest('t@example.com','sha256'),'hex'), repeat('c',64), repeat('d',64), 't@example.com');
--   (위 [2] 를 t@example.com 의 해시로 발급한 뒤에 한다)
-- [4] 시험 행 정리
-- DELETE FROM public.signup_email_codes WHERE email_hash IN (repeat('a',64), encode(extensions.digest('t@example.com','sha256'),'hex'));
-- [5] 옛 미인증 계정 삭제/문의 갈래는 시험 계정 2개(하나는 응모 붙임)를 만들어 확인 — 작업표 D3 완료 정의
