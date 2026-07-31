-- ============================================================
-- 279_report_client_error_mask_auth_token.sql
-- 오류 수집 서버 마스킹에 **인증 토큰 규칙** 추가
-- 사양서: docs/specs/2026-07-31-duplicate-submit-guard-and-error-log-noise.md §3 단계 2-2
--          (§4 확정된 결정 1 — 「화면·서버 둘 다」)
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -rln "FUNCTION public.report_client_error" supabase/migrations/*.sql
--     → 165_client_error_logs.sql 단 1곳. 165 가 "가장 큰 번호의 정의" == "유일한 정의".
--   이 파일은 **165 본문을 그대로 베이스로** CREATE OR REPLACE 하며, 마스킹 (f) 한 단락만
--   더한다. 그 외(빈값 가드·범위 가드·길이 제한·(a)~(e) 마스킹·UPSERT·GRANT)는 165 와 동일.
--
-- ▶ 왜 필요한가 — 실측 증거
--   운영 오류 로그의 발생 화면에 `#reset-pw?token_hash=dd#ac#edcfefc#...` 가 기록돼 있었다.
--   숫자가 # 로 치환된 건 화면 코드가 **발생 화면(p_page_hash)에만** 자릿수 치환을 걸기
--   때문이고, **메시지·스택에는 그 치환이 없다.** 즉 토큰이 메시지나 스택 쪽에 실리는
--   경로가 생기면 **원문 그대로 저장된다.** 이번 4건에서는 실제로 그런 경우가 없었지만
--   규칙 부재는 그대로였다.
--
-- ▶ 왜 화면만 고치면 안 되는가
--   화면 마스킹은 우회 가능하다(다른 클라이언트·직접 호출). 기존 사양서
--   2026-06-02-client-error-reporting.md 가 이미 **클라이언트 1차 + 서버 2차 이중 방어**를
--   설계로 정하고 있고, (a)~(e) 다섯 규칙이 그렇게 양쪽에 들어가 있다. 토큰 규칙만
--   화면에 두면 그 설계가 깨진다.
--
-- ▶ 가리는 대상 — 값만, 키 이름은 남긴다
--   `token_hash=...` → `token_hash=[token]`. 어떤 종류의 토큰이었는지는 남아야 운영자가
--   원인을 좁힐 수 있고, 값 자체는 그 자체로 인증 수단이라 남으면 안 된다.
--   대상 키 = token_hash · access_token · refresh_token · code
--   (`code` 는 PKCE 인증 코드 교환에 쓰이는 값. 비밀번호 재설정·소셜 로그인 링크에 실린다.)
--
--   ⚠️ `code` 는 흔한 단어라 단어 경계(`\y`) 없이 매칭하면 `error_code=42501`·
--   `status_code=500` 같은 **PostgreSQL 오류 코드**(로그 판독 근거)까지 가려버린다
--   (리뷰에서 실제 재현). `\y` 로 "code" 앞이 단어 경계일 때만(공백·`?`·`&`·문자열
--   시작 등, `_` 뒤는 제외) 매칭하게 좁혔다 — 상세 근거는 (f) 코드 주석.
-- ▶ 이미 쌓인 행은 고치지 않는다
--   이 함수는 **새로 들어오는** 로그에만 적용된다. 기존 4건에 토큰이 남아 있지 않음을
--   확인했고(발생 화면의 자릿수 치환으로 값이 이미 깨져 있음), 과거 행 일괄 수정은
--   되돌릴 수 없어 하지 않는다.
--
-- ▶ 롤백
--   165 파일의 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.report_client_error(
  p_fingerprint  text,
  p_source       text    DEFAULT 'influencer',
  p_kind         text    DEFAULT 'unhandled',
  p_message      text    DEFAULT '',
  p_error_code   text    DEFAULT NULL,
  p_stack        text    DEFAULT NULL,
  p_page_hash    text    DEFAULT NULL,
  p_context      text    DEFAULT NULL,
  p_user_agent   text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();  -- 로그인 사용자이면 채워짐, anon이면 NULL
  v_message  text;
  v_stack    text;
  v_pagehash text;
BEGIN
  -- ── 1. 빈값 가드 (165 와 동일) ────────────────────────────────────────────
  IF coalesce(trim(p_fingerprint), '') = '' OR coalesce(trim(p_message), '') = '' THEN
    RETURN;
  END IF;

  IF p_source NOT IN ('influencer', 'admin') THEN
    RETURN;
  END IF;
  IF p_kind NOT IN ('unhandled', 'rejection', 'handled') THEN
    RETURN;
  END IF;

  -- ── 2. 길이 제한 (165 와 동일) ───────────────────────────────────────────
  v_message  := left(p_message,  1000);
  v_stack    := left(p_stack,    4000);
  v_pagehash := left(p_page_hash, 512);

  -- ── 3. 서버측 2차 마스킹 ─────────────────────────────────────────────────
  -- (a) 이메일
  v_message  := regexp_replace(v_message,  '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');
  v_stack    := regexp_replace(v_stack,    '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');

  -- (b) 전화번호
  v_message  := regexp_replace(v_message,  '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');
  v_stack    := regexp_replace(v_stack,    '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');

  -- (c) 우편번호 (하이픈 필수 — 7자리 ID 과마스킹 방지)
  v_message  := regexp_replace(v_message,  '\d{3}-\d{4}', '[zip]', 'g');
  v_stack    := regexp_replace(v_stack,    '\d{3}-\d{4}', '[zip]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '\d{3}-\d{4}', '[zip]', 'g');

  -- (d) Bearer 토큰
  v_message  := regexp_replace(v_message,  'Bearer\s+\S+', 'Bearer [token]', 'g');
  v_stack    := regexp_replace(v_stack,    'Bearer\s+\S+', 'Bearer [token]', 'g');
  v_pagehash := regexp_replace(v_pagehash, 'Bearer\s+\S+', 'Bearer [token]', 'g');

  -- (e) PostgreSQL 상세 오류값: (column)=(value)
  v_message  := regexp_replace(v_message,  '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');
  v_stack    := regexp_replace(v_stack,    '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');

  -- ★ (f) 279 신설 — 주소에 실려 오는 인증 토큰. **값만** 가리고 키 이름은 남긴다.
  --     키를 남겨야 운영자가 어떤 종류였는지 보고 원인을 좁힐 수 있다.
  --     끊는 문자에 & 와 공백뿐 아니라 " ' 도 넣는다 — 스택·메시지 안에서는 따옴표로
  --     감싸인 채 등장할 수 있어, 안 끊으면 뒤 문자열까지 통째로 삼킨다.
  --
  --     ⚠️ 단어 경계 `\y` 가 없으면 `error_code=42501`·`status_code=500` 안의 `code=`
  --     까지 잡아 「error_code=[token]」으로 뭉갠다(리뷰에서 실제 재현 — 이 프로젝트는
  --     PostgreSQL 오류 코드를 로그 판독 근거로 쓰므로 가리면 안 된다). `_` 는 단어
  --     문자라 `error_code=` 앞에는 경계가 안 서고 `code=`·`?code=` 단독만 잡힌다.
  --
  --     ⚠️ 여기서 쓸 이스케이프는 자바스크립트의 `\b`(단어 경계)가 **아니라** `\y` 다.
  --     PostgreSQL 정규식(ARE)에서 `\b` 는 C 언어와 같은 **백스페이스 문자**(0x08,
  --     "Character-Entry Escapes")로 해석되어 조용히 죽은 규칙이 된다(구문 오류는 안
  --     나서 리뷰로만 걸러진다). 단어 경계는 별도 분류인 "Constraint Escapes" 의
  --     `\y`("matches only at the beginning or end of a word")를 쓴다. 화면 쪽
  --     `dev/js/error-report.js` 의 `_mask`(자바스크립트, `\b` 사용)와 **표기만 다르고
  --     동작은 동일**하다.
  v_message  := regexp_replace(v_message,  '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');
  v_stack    := regexp_replace(v_stack,    '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');
  v_pagehash := regexp_replace(v_pagehash, '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');

  -- ── 4. open fingerprint 가 있으면 카운트 증가, 없으면 신규 INSERT (165 와 동일) ──
  UPDATE public.client_error_logs
     SET occurrence_count = occurrence_count + 1,
         last_seen_at     = now()
   WHERE fingerprint = p_fingerprint
     AND status      = 'open';

  IF NOT FOUND THEN
    INSERT INTO public.client_error_logs
      (fingerprint, source, kind, message, error_code,
       stack, page_hash, context, user_agent, user_id)
    VALUES
      (p_fingerprint,
       p_source,
       p_kind,
       v_message,
       p_error_code,
       v_stack,
       v_pagehash,
       left(p_context,    200),
       left(p_user_agent, 512),
       v_uid)
    ON CONFLICT (fingerprint, status) DO UPDATE
      SET occurrence_count = public.client_error_logs.occurrence_count + 1,
          last_seen_at     = now();
  END IF;

END;
$$;

COMMENT ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text) IS
  '[279] 사용자 앱 오류 수집 (anon 호출 가능). 165 정의 + 인증 토큰 마스킹 (f) 추가 —
   token_hash·access_token·refresh_token·code 의 **값만** [token] 으로 가리고 키 이름은 남긴다.
   \y(단어 경계, PostgreSQL ARE) 로 error_code=·status_code= 같은 복합 식별자는 보존한다.
   화면(error-report.js _mask, 자바스크립트 \b 사용 — 표기만 다르고 동작은 동일)과 짝을
   이루는 서버 2차 방어. 새로 들어오는 로그에만 적용된다.
   사양서 docs/specs/2026-07-31-duplicate-submit-guard-and-error-log-noise.md §3 단계 2-2.';

-- anon(비로그인)과 인증 사용자 모두 호출 가능 (165 와 동일 — CREATE OR REPLACE 는 권한을
--   보존하지만, 재실행 시 이전 상태에 의존하지 않도록 명시적으로 다시 부여한다)
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL Editor — 1단계씩)
-- ============================================================
--
-- 1단계 — 정의 갱신 확인:
--   SELECT obj_description(p.oid) LIKE '%[279]%' AS "279_적용됨"
--     FROM pg_proc p
--    WHERE p.proname = 'report_client_error' AND p.pronamespace = 'public'::regnamespace;
--   → true
--
-- 2단계 — 마스킹 동작 확인 (실제 행이 1건 생긴다. 확인 후 지울 것):
--   SELECT public.report_client_error(
--     'fp_mask_test_279', 'influencer', 'handled',
--     'PGRST error: error_code=42501 permission denied. test token_hash=abcdef123456 and access_token=xyz789 end',
--     NULL, NULL, '#reset-pw?token_hash=abcdef123456', NULL, NULL);
--
--   SELECT message, page_hash FROM public.client_error_logs WHERE fingerprint = 'fp_mask_test_279';
--   → message   = 'PGRST error: error_code=42501 permission denied. test token_hash=[token] and access_token=[token] end'
--                  (★ error_code=42501 은 그대로 보존돼야 함 — \y 단어 경계 검증)
--   → page_hash = '#reset-pw?token_hash=[token]'
--
-- 3단계 — 시험 행 정리:
--   DELETE FROM public.client_error_logs WHERE fingerprint = 'fp_mask_test_279';
-- ============================================================
