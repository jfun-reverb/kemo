-- ============================================================
-- 497_signup_ticket_gates.sql
-- 회원가입 이메일 인증번호 — 조각 D5 「가입 관문 트리거(삽입·고쳐 쓰기) + 383 목록」
--   선행: 493(설정 표) · 494(번호 표). 사양서 설계 ②, 경우의 수 2·12, 완료 기준 6·13·14·15
--
-- ============================================================
-- 🔴🔴 이 파일은 가장 위험하다 — 틀리면 신규 가입 전체 또는 모든 로그인이 멈춘다
-- ============================================================
--   · 삽입 관문(trg_signup_ticket_gate, BEFORE INSERT ON auth.users)이 틀리면 **정상 가입이 막힌다**.
--   · 고쳐 쓰기 관문(trg_signup_resend_gate, BEFORE UPDATE ON auth.users)은 **로그인·토큰 갱신마다 도는 자리**다.
--     조건이 틀리면 스위치를 대기로 돌려도 안 풀린다 — **그 트리거를 끈다**(supabase/patches/2026-10-01-signup-*-gate-off.sql).
--   · SQL 편집기로는 인증 서비스 역할(supabase_auth_admin)을 재현할 수 없다 → **실제 가입·로그인으로 확인**(383 선례).
--   · 개발서버 적용 → 완료 기준 14·15 확인 → 그 뒤에 운영 적용(작업표 O1).
--
-- ▌두 관문의 공통 규칙
--   ① 트리거 함수는 **SECURITY INVOKER** — current_user 가 실제 접속 역할이어야 한다(492 와 같은 이유).
--      DEFINER 로 바꾸면 current_user 가 늘 소유자라 **아무것도 못 가르고 조용히 무력화**된다.
--   ② 검사 대상은 **인증 서비스가 넣는/고치는 행만**(current_user = 'supabase_auth_admin' — 단계 0 실측 확정).
--      관리자 초대(245·417 — postgres 로 직접 삽입, 인증 완료 시각을 스스로 now() 로 넣음)·감사용 계정(179)·SQL 편집기는 통과.
--   ③ 🔴 `auth.uid() IS NULL` 통과 조항을 **넣지 않는다**(362 관례) — 회원가입이 바로 그 상태다.
--   ④ 설정 표(493)는 RLS 로 막혀 있고 접속 역할이 supabase_auth_admin 이라 직접 못 읽는다 →
--      정의자 권한 도우미 _signup_read_mode()(이 역할에만 실행 권한)로 읽는다. 못 읽으면 **대기**로 본다.
--
-- ▌트리거 실행 순서 (같은 시점이면 이름 알파벳 순)
--   BEFORE INSERT : trg_signup_ticket_gate(s) → (362 가 나중에 적용되면) trg_withdrawal_signup_block(w).
--                   ⚠️ 362 는 미적용. 적용되면 BEFORE INSERT 트리거가 둘이 된다. 이 관문이 먼저 돌지만 서로 읽는 값이 달라 간섭 없음.
--   BEFORE UPDATE : on_auth_user_updated_strip_signup_meta(o, 383 — OF raw_user_meta_data) → trg_signup_resend_gate(t).
--                   고쳐 쓰기 관문은 메타데이터를 안 건드리고 칸 변화(confirmation_sent_at·recovery_sent_at)만 본다 → 간섭 없음.
--   AFTER INSERT  : on_auth_user_created(handle_new_user, 420 — **무변경**) 는 별개. 관문이 삽입 직전에
--                   raw_user_meta_data 에서 signup_ticket 만 뺀다(가입 폼 값은 건드리지 않아 420 이 그대로 읽는다).
--
-- ▌되돌리기
--   스위치로: UPDATE public.signup_code_settings SET mode='standby' WHERE id=1;   (두 관문이 통과로 바뀜)
--   트리거로(코드 오류): supabase/patches/2026-10-01-signup-{resend,ticket}-gate-off.sql
--   완전 제거:
--     DROP TRIGGER IF EXISTS trg_signup_resend_gate ON auth.users;
--     DROP TRIGGER IF EXISTS trg_signup_ticket_gate ON auth.users;
--     DROP FUNCTION IF EXISTS public._signup_resend_gate();
--     DROP FUNCTION IF EXISTS public._signup_ticket_gate();
--     DROP FUNCTION IF EXISTS public._signup_ticket_consume(text, text);
--     DROP FUNCTION IF EXISTS public._signup_read_mode();
--     (_strip_signup_meta 는 383 판으로 되돌린다 — 아래 함수의 열쇠말 하나(signup_ticket)를 빼고 CREATE OR REPLACE)
-- ============================================================

BEGIN;

-- 인증 서비스 역할이 public 의 함수를 부르려면 스키마 사용 권한이 필요하다(이미 있으면 변화 없음).
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;

-- ── 지우는 열쇠 목록: 383 판 + signup_ticket (열 개) ─────────────────
-- 🔴 383 의 함수를 베이스로 열쇠 하나만 더한다. 이 함수는 로그인 경로(strip_signup_meta_on_update)가 부른다 —
--    객체가 아닌 값은 그대로 통과시키는 CASE 를 **절대 빼지 말 것**(jsonb - text 는 객체가 아니면 오류 → 로그인 전체 차단).
-- ⚠️ 가입 트리거 420 안의 옛 사본 목록(420:149~154)은 맞추지 않는다 — 420 무변경. 어긋나면 이 함수가 이긴다(쓰기마다 돌기 때문).
-- ⚠️ CREATE OR REPLACE 라 383 이 걸어 둔 실행 권한 회수가 그대로 유지된다(DROP 후 CREATE 금지).
CREATE OR REPLACE FUNCTION public._strip_signup_meta(m jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN jsonb_typeof(m) <> 'object' THEN m
           ELSE m - 'name' - 'name_kanji' - 'name_kana'
                  - 'birthdate' - 'gender'
                  - 'terms_agreed_at' - 'privacy_agreed_at'
                  - 'marketing_opt_in' - 'marketing_agreed_at'
                  - 'signup_ticket'
         END;
$$;

-- ── 스위치 읽기(정의자 권한) — 읽을 수 없으면 'standby' ───────────────
-- 🔴 어떤 실패도 오류로 새지 않는다(설정 표 없음·행 없음·값 이상 → 대기 = 통과).
CREATE OR REPLACE FUNCTION public._signup_read_mode()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_mode text;
BEGIN
  SELECT mode INTO v_mode FROM public.signup_code_settings WHERE id = 1;
  IF v_mode = 'enforce' THEN
    RETURN 'enforce';
  END IF;
  RETURN 'standby';
EXCEPTION WHEN others THEN
  RETURN 'standby';
END;
$$;

COMMENT ON FUNCTION public._signup_read_mode() IS
  '[497] 가입 관문이 읽는 스위치. enforce 일 때만 enforce, 그 밖(대기·행 없음·오류)은 전부 standby. 오류를 던지지 않는다. '
  '실행 권한: supabase_auth_admin·postgres.';

-- ── 확인증 소비(정의자 권한) — 1회용, 원자적 ─────────────────────────
-- 해시는 494 규격: 확인증은 sha256(원문), 이메일은 sha256(lower(btrim)). 둘 다 비밀값 없음.
-- 한 번의 UPDATE 로 「맞는지 확인 + 사용 표시」를 함께 해 동시 사용을 막는다.
-- 이 UPDATE 는 가입 INSERT 와 같은 트랜잭션 — 가입이 실패하면 사용 표시도 함께 되돌아간다.
CREATE OR REPLACE FUNCTION public._signup_ticket_consume(p_ticket text, p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rows integer;
BEGIN
  IF p_ticket IS NULL OR btrim(p_ticket) = '' OR p_email IS NULL OR btrim(p_email) = '' THEN
    RETURN false;
  END IF;

  UPDATE public.signup_email_codes
     SET ticket_used_at = now()
   WHERE ticket_hash        = encode(extensions.digest(p_ticket, 'sha256'), 'hex')
     AND verified_at        IS NOT NULL
     AND ticket_used_at     IS NULL
     AND ticket_expires_at  > now()
     AND email_hash         = encode(extensions.digest(lower(btrim(p_email)), 'sha256'), 'hex');

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

COMMENT ON FUNCTION public._signup_ticket_consume(text, text) IS
  '[497] 확인증 원문 + 가입 이메일로 대조(해시 일치·확인 완료·미사용·미만료·같은 이메일)하고 맞으면 ticket_used_at 기록(1회용) 후 true. '
  '실행 권한: supabase_auth_admin·postgres 만(공개 키·로그인 회원·서비스 키 모두 불가).';

-- ── 삽입 관문 ────────────────────────────────────────────────
-- 🔴 SECURITY INVOKER 필수. 🔴 auth.uid() IS NULL 통과 조항 금지(362 — 가입이 그 상태).
CREATE OR REPLACE FUNCTION public._signup_ticket_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_ticket text;
  v_mode   text;
  v_ok     boolean := false;
BEGIN
  -- 인증 서비스가 넣는 행만 검사(관리자 초대·감사용·편집기는 통과)
  IF current_user <> 'supabase_auth_admin' THEN
    RETURN NEW;
  END IF;

  -- 확인증 열쇠를 꺼내고 **어느 경우에도** 계정 정보에서 지운다(이후 저장 때 되살아나는 것은 383 목록이 막는다)
  BEGIN
    IF jsonb_typeof(NEW.raw_user_meta_data) = 'object' THEN
      v_ticket := NEW.raw_user_meta_data ->> 'signup_ticket';
      NEW.raw_user_meta_data := NEW.raw_user_meta_data - 'signup_ticket';
    END IF;
  EXCEPTION WHEN others THEN
    v_ticket := NULL;
  END;

  -- 스위치 읽기 — 읽을 수 없으면 도우미가 'standby' 를 돌려준다(오류를 던지지 않음)
  -- 🔴 부르는 줄 자체도 감싼다 — 도우미가 없거나 실행 권한이 빠지면 이 줄이 오류를 내 대기 상태에서도 가입이 전부 막힌다
  BEGIN
    v_mode := public._signup_read_mode();
  EXCEPTION WHEN others THEN
    v_mode := 'standby';
  END;

  -- 대조: 맞으면 그 자리에서 인증 완료로 표시
  BEGIN
    IF v_ticket IS NOT NULL AND public._signup_ticket_consume(v_ticket, NEW.email) THEN
      NEW.email_confirmed_at := coalesce(NEW.email_confirmed_at, now());
      v_ok := true;
    END IF;
  EXCEPTION WHEN others THEN
    -- 대조 중 예외: 통과로 열지 않는다. 아래에서 대기면 통과, 강제면 거부.
    v_ok := false;
  END;

  IF v_ok THEN
    RETURN NEW;
  END IF;

  -- 확인증이 없거나 틀림(만료·사용됨·다른 주소 포함) 또는 대조 실패
  IF v_mode = 'enforce' THEN
    -- ⚠️ 이 메시지는 회원에게 안 보인다(인증 서비스가 일반 데이터베이스 오류로 덮는다) — 서버 로그 식별용 코드.
    RAISE EXCEPTION 'signup_ticket_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;   -- 대기: 옛 흐름 그대로(인증 완료 표시 없음 — 확인 메일 링크로 인증)
END;
$$;

COMMENT ON FUNCTION public._signup_ticket_gate() IS
  '[497] auth.users BEFORE INSERT 관문. supabase_auth_admin 이 넣은 행만 검사. signup_ticket 열쇠를 꺼내 지운 뒤 _signup_ticket_consume 으로 대조 — '
  '맞으면 email_confirmed_at 표시, 아니면 대기=통과 / 강제=signup_ticket_required 거부(대조 중 예외도 같음). 설정 표를 못 읽으면 대기. '
  '🔴 SECURITY INVOKER 필수, auth.uid() IS NULL 통과 조항 금지.';

-- ── 고쳐 쓰기 관문 ───────────────────────────────────────────
-- 🔴 로그인·토큰 갱신마다 도는 자리 — **첫 줄이 OLD.email_confirmed_at 검사**여야 한다(실제 회원 전부 여기서 통과, 아무것도 읽지 않음).
-- 검사 대상: 미인증 행 + 인증 서비스 역할 + 확인 메일 재발송(confirmation_sent_at 변경) 또는 재설정 메일 요청(recovery_sent_at 변경).
-- 판정 중 예외·설정 표를 못 읽음 → 강제여도 **통과**(로그인 보호가 우선 — 우회 위험은 미인증 행에 한정).
-- 거부(RAISE)는 판정 블록 **밖**에서 한다 — 안에서 던지면 아래 예외 처리가 삼켜 관문이 무력화된다.
CREATE OR REPLACE FUNCTION public._signup_resend_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_block boolean := false;
BEGIN
  -- 🔴 첫 줄 — 인증 완료 회원은 아무것도 보지 않고 통과
  IF OLD.email_confirmed_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF current_user <> 'supabase_auth_admin' THEN
    RETURN NEW;
  END IF;

  -- 판정 블록: 어떤 오류도 「막지 않음」으로 닫는다
  BEGIN
    IF NEW.confirmation_sent_at IS DISTINCT FROM OLD.confirmation_sent_at
       OR NEW.recovery_sent_at IS DISTINCT FROM OLD.recovery_sent_at THEN
      IF public._signup_read_mode() = 'enforce' THEN
        v_block := true;
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    v_block := false;
  END;

  -- 거부는 블록 밖에서
  IF v_block THEN
    RAISE EXCEPTION 'signup_resend_blocked' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._signup_resend_gate() IS
  '[497] auth.users BEFORE UPDATE 관문. 첫 줄에서 인증 완료 행은 통과(로그인 경로 보호). 미인증 행 + supabase_auth_admin + 확인 메일 재발송/재설정 메일 요청 '
  '(confirmation_sent_at·recovery_sent_at 변경)일 때 강제면 signup_resend_blocked 거부, 대기·설정 표 못 읽음·판정 예외는 통과. '
  '🔴 SECURITY INVOKER 필수. 🔴 첫 줄 검사 순서 변경 금지.';

-- ── 실행 권한 ────────────────────────────────────────────────
-- 접속 역할 supabase_auth_admin 이 도우미·트리거 함수를 실행할 수 있어야 한다(단계 0 실측에서도 명시 부여가 필요했다).
-- 부여 먼저 → 회수 나중(375). 도우미 둘은 다른 역할에 주지 않는다.
GRANT  EXECUTE ON FUNCTION public._signup_read_mode()                 TO postgres, supabase_auth_admin;
GRANT  EXECUTE ON FUNCTION public._signup_ticket_consume(text, text)  TO postgres, supabase_auth_admin;
GRANT  EXECUTE ON FUNCTION public._signup_ticket_gate()               TO postgres, supabase_auth_admin;
GRANT  EXECUTE ON FUNCTION public._signup_resend_gate()               TO postgres, supabase_auth_admin;

REVOKE EXECUTE ON FUNCTION public._signup_read_mode()                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._signup_read_mode()                 FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._signup_ticket_consume(text, text)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._signup_ticket_consume(text, text)  FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._signup_ticket_gate()               FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._signup_ticket_gate()               FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._signup_resend_gate()               FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._signup_resend_gate()               FROM anon, authenticated, service_role;

-- ── 트리거 (맨 마지막 — 위가 하나라도 실패하면 이 파일 전체가 되돌려져 트리거가 안 걸린다) ──
DROP TRIGGER IF EXISTS trg_signup_ticket_gate ON auth.users;
CREATE TRIGGER trg_signup_ticket_gate
  BEFORE INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public._signup_ticket_gate();

DROP TRIGGER IF EXISTS trg_signup_resend_gate ON auth.users;
CREATE TRIGGER trg_signup_resend_gate
  BEFORE UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public._signup_resend_gate();

COMMIT;

-- ============================================================
-- 적용 전·후 확인 (개발서버 먼저. 1단계씩 — 이상하면 즉시 멈추고 비상 SQL)
-- ============================================================
-- 🔴 SQL 편집기로는 인증 서비스 역할을 재현할 수 없다 — 아래 [V2] 이후는 실제 가입·로그인이 필요하다(383 선례).
--
-- [V0] 적용 전 — auth.users 에 이미 붙은 트리거 목록(이름 순서 간섭 확인)
-- SELECT t.tgname, t.tgtype, t.tgenabled, p.proname
--   FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
--   JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
--  WHERE n.nspname = 'auth' AND c.relname = 'users' AND NOT t.tgisinternal ORDER BY t.tgname;
--
-- [V1] 적용 후 — 트리거 둘이 'O'(활성)이고 함수가 INVOKER(prosecdef=false)인가
-- SELECT t.tgname, t.tgenabled, p.proname, p.prosecdef
--   FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
--   JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
--  WHERE n.nspname='auth' AND c.relname='users' AND t.tgname IN ('trg_signup_ticket_gate','trg_signup_resend_gate');
--   → prosecdef 둘 다 false 여야 한다.
--
-- [V1-2] 실행 권한 — 도우미·트리거 함수가 supabase_auth_admin·postgres 에만, 맨 앞 `=X/`(PUBLIC) 없음
-- SELECT proname, proacl::text FROM pg_proc WHERE pronamespace='public'::regnamespace
--    AND proname IN ('_signup_read_mode','_signup_ticket_consume','_signup_ticket_gate','_signup_resend_gate');
--
-- [V1-3] 383 목록 — signup_ticket 이 들어갔나
-- SELECT public._strip_signup_meta('{"name":"x","signup_ticket":"t","sub":"s"}'::jsonb);   -- {"sub":"s"}
-- SELECT public._strip_signup_meta('[1]'::jsonb), public._strip_signup_meta('"s"'::jsonb); -- 그대로(오류 없음)
--
-- [V1-4] 도우미 단독(편집기=postgres) — 스위치 읽기
-- SELECT public._signup_read_mode();   -- standby
--
-- [V2] 🔴 대기 상태 — 옛 화면으로 실제 가입 1회(개발서버 「확인 메일」 설정을 켠 상태에서도). 성공해야 한다.
--      관리자 초대·감사용 계정 생성·관리자 비밀번호 찾기·회원 비밀번호 재설정·로그인이 그대로인지.
--      가입한 계정의 raw_user_meta_data 에 signup_ticket 이 없어야 한다.
--
-- [V3] 확인증을 실은 가입(서비스 키로 발급·확인 → signUp options.data.signup_ticket) → email_confirmed_at 이 채워진 채로 생긴다.
--      같은 확인증을 두 번 쓰면 두 번째는 인증 완료 표시 없이(대기) / 거부(강제).
--
-- [V4] 강제 — UPDATE public.signup_code_settings SET mode='enforce' WHERE id=1;
--      확인증 없는 가입 거부 · 다른 주소의 확인증 거부 · 재사용 거부 · 초대·감사용·로그인 정상.
--      끝나면 대기로 되돌린다.
--
-- [V5] 완료 기준 14 — 설정 표를 못 읽는 상태에서 통과하는지(방법: 개발서버에서 정의자 도우미가 읽는 표 이름을 임시로 바꿔 보는 등
--      개발 담당이 정한다. 확인 뒤 반드시 되돌린다). 인증 완료 회원 로그인은 설정 표와 무관하게 되어야 한다.
--
-- [V6] 완료 기준 15 — 비상 끄기·켜기 SQL(supabase/patches/2026-10-01-signup-*-gate-{off,on}.sql)이 실제로 듣는지.
