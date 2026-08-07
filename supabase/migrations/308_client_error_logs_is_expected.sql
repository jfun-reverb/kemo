-- ============================================================
-- 308_client_error_logs_is_expected.sql
-- 오류 로그 — 「예상된 업무 거부」 vs 「예상 못 한 오류」 구분
--
-- 왜 필요한가:
--   응모 취소 원격 호출 함수가 3개월간 죽어 있었는데(2026-05-12~08, 마이그306)
--   오류 로그에 흔적이 0건이었다. 수집 자리를 92곳으로 넓히면 마감 지남·정원
--   초과·중복 응모 같은 「정상 거부」가 대량 유입돼 진짜 결함이 그 안에 묻힌다.
--   사용자 결정 = 「전부 쌓되 화면에서 구분」(2026-08-07). 이 마이그레이션은
--   그 구분 값을 저장하는 칸과, 호출부가 그 값을 넘길 수 있는 인자만 추가한다.
--   실제 92곳에서 어디를 true 로 부를지는 화면·클라이언트 쪽 후속 작업.
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -rn "report_client_error" supabase/migrations/*.sql supabase/patches/*.sql
--     → 정의가 있는 파일은 165(원본) · 279(CREATE OR REPLACE) 단 2곳.
--   ⚠️ 작업 지시서는 "165 를 그대로 옮기라" 였으나, **279 가 165 이후의 최신 정의**다
--   (인증 토큰 마스킹 (f) 단락을 추가한 CREATE OR REPLACE). 165 를 베이스로 삼으면
--   279 가 고친 토큰 마스킹 규칙이 통째로 사라진다 — 이 파일은 **279 본문을 그대로
--   베이스로** 쓰고 p_is_expected 인자 + is_expected 저장 한 줄만 더한다.
--   (a)~(f) 마스킹 6단락·빈값 가드·범위 가드·길이 제한·UPSERT 구조는 279 와 100% 동일.
--
-- 대상: 개발서버 + 운영서버
-- 위험도: 낮음 — 기존 칸·정책·트리거 무변경. 함수는 인자 1개 추가(기본값 있어 하위 호환)
-- 의존: 165(테이블·함수 원본) · 279(함수 최신 정의, 이 파일의 베이스)
--
-- 롤백 방법:
--   -- 함수를 279 정의로 되돌림 (해당 파일의 CREATE OR REPLACE 블록 그대로 재실행) 후:
--   DROP FUNCTION IF EXISTS public.report_client_error(text, text, text, text, text, text, text, text, text, boolean);
--   -- (279 의 9인자 CREATE OR REPLACE 를 다시 실행하면 함수가 되살아난다)
--   ALTER TABLE public.client_error_logs DROP COLUMN IF EXISTS is_expected;
-- ============================================================

BEGIN;

-- ── 1. 칸 추가 ──────────────────────────────────────────────────────────────
-- 기존 행은 백필하지 않는다(전부 false 가 맞다 — 지금까지 구분 없이 쌓였고,
-- 옛 행을 소급 분류할 근거가 없다. DEFAULT false 로 자연히 그렇게 채워진다).
ALTER TABLE public.client_error_logs
  ADD COLUMN IF NOT EXISTS is_expected boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.client_error_logs.is_expected IS
  '[308] true = 미리 정의된 업무 거부(마감 지남·정원 초과·중복 응모 등 "정상" 거부).
   false(기본) = 예상 못 한 오류. report_client_error() 의 신설 인자 p_is_expected 로
   기록되며, 최초 INSERT 시점에만 값이 정해지고 이후 재발(occurrence_count 증가)에는
   갱신되지 않는다 — 같은 fingerprint 는 같은 호출 지점이라 값이 바뀔 이유가 없다는
   전제. 기존(마이그308 이전) 행은 전부 false — 소급 분류 근거가 없어 백필하지 않았다.';

-- ── 2. report_client_error 재정의 (279 베이스 그대로 + p_is_expected 인자 추가) ──
-- 279 의 (a)~(f) 마스킹·빈값 가드·범위 가드·길이 제한·UPSERT 구조를 한 글자도
-- 바꾸지 않고 그대로 옮긴다. 다른 점은 ①인자 목록 끝에 p_is_expected 추가
-- ②INSERT 컬럼 목록에 is_expected 한 칸 추가 뿐.
--
-- 인자를 추가하면 함수 시그니처(입력 타입 목록)가 달라지므로 CREATE OR REPLACE 로는
-- "교체"가 아니라 새 오버로드가 생긴다 → 옛 9인자 함수를 명시적으로 DROP 해야
-- 운영에 두 버전이 공존하는 것을 막는다(165·279 와 동일한 패턴).
DROP FUNCTION IF EXISTS public.report_client_error(text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.report_client_error(
  p_fingerprint  text,
  p_source       text    DEFAULT 'influencer',
  p_kind         text    DEFAULT 'unhandled',
  p_message      text    DEFAULT '',
  p_error_code   text    DEFAULT NULL,
  p_stack        text    DEFAULT NULL,
  p_page_hash    text    DEFAULT NULL,
  p_context      text    DEFAULT NULL,
  p_user_agent   text    DEFAULT NULL,
  p_is_expected  boolean DEFAULT false
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
  -- ── 1. 빈값 가드 (279/165 와 동일) ────────────────────────────────────────
  IF coalesce(trim(p_fingerprint), '') = '' OR coalesce(trim(p_message), '') = '' THEN
    RETURN;
  END IF;

  IF p_source NOT IN ('influencer', 'admin') THEN
    RETURN;
  END IF;
  IF p_kind NOT IN ('unhandled', 'rejection', 'handled') THEN
    RETURN;
  END IF;

  -- ── 2. 길이 제한 (279/165 와 동일) ───────────────────────────────────────
  v_message  := left(p_message,  1000);
  v_stack    := left(p_stack,    4000);
  v_pagehash := left(p_page_hash, 512);

  -- ── 3. 서버측 2차 마스킹 (279/165 와 동일, (a)~(f) 6단락 전부 유지) ────────
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

  -- (f) 279 신설 — 주소에 실려 오는 인증 토큰. 값만 가리고 키 이름은 남긴다.
  --     \y(단어 경계, PostgreSQL ARE) 로 error_code=·status_code= 같은 복합
  --     식별자는 보존한다 (\b 는 이 방언에서 백스페이스 문자로 해석되므로 금지).
  v_message  := regexp_replace(v_message,  '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');
  v_stack    := regexp_replace(v_stack,    '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');
  v_pagehash := regexp_replace(v_pagehash, '\y((token_hash|access_token|refresh_token|code)=)[^&\s"'']+', '\1[token]', 'gi');

  -- ── 4. open fingerprint 가 있으면 카운트 증가, 없으면 신규 INSERT (279/165 와 동일 구조) ──
  -- ⚠️ is_expected 는 이 UPDATE 분기에서 건드리지 않는다 — 같은 fingerprint 는 같은
  -- 호출 지점이라 값이 최초 기록 이후로 바뀔 이유가 없다는 전제(마이그레이션 상단 설명).
  UPDATE public.client_error_logs
     SET occurrence_count = occurrence_count + 1,
         last_seen_at     = now()
   WHERE fingerprint = p_fingerprint
     AND status      = 'open';

  IF NOT FOUND THEN
    INSERT INTO public.client_error_logs
      (fingerprint, source, kind, message, error_code,
       stack, page_hash, context, user_agent, user_id, is_expected)
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
       v_uid,
       coalesce(p_is_expected, false))
    -- ON CONFLICT DO UPDATE 는 명시한 컬럼(occurrence_count·last_seen_at)만 갱신한다.
    -- is_expected 는 여기서도 손대지 않는다 — 먼저 들어온 행의 값이 유지된다.
    ON CONFLICT (fingerprint, status) DO UPDATE
      SET occurrence_count = public.client_error_logs.occurrence_count + 1,
          last_seen_at     = now();
  END IF;

END;
$$;

COMMENT ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text, boolean) IS
  '[308] 사용자 앱 오류 수집 (anon 호출 가능). 279 정의(165 원본 + 인증 토큰 마스킹 (f))에
   p_is_expected boolean DEFAULT false 인자를 추가 — 「예상된 업무 거부」와 「예상 못 한
   오류」를 최초 INSERT 시점에만 구분 저장한다(재발 시 갱신 안 함). 기존 9인자 호출
   (p_is_expected 미지정)은 기본값 false 로 그대로 동작 — 하위 호환.';

-- anon(비로그인)과 인증 사용자 모두 호출 가능 (279/165 와 동일 — CREATE OR REPLACE 는
-- 권한을 보존하지만, 새 시그니처는 DROP 으로 옛 함수가 사라지므로 명시적으로 재부여)
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text, boolean)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL Editor — 1단계씩. 사용자 확인 후 개발서버부터 적용)
-- ============================================================
--
-- 1단계 — 칸이 실제로 생겼는지 확인:
--   SELECT column_name, data_type, column_default, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'client_error_logs'
--      AND column_name = 'is_expected';
--   → boolean / DEFAULT false / NOT NULL
--
-- 2단계 — 함수 시그니처·권한 확인 (옛 9인자는 사라지고 10인자만 남아야 함):
--   SELECT p.oid::regprocedure AS signature
--     FROM pg_proc p
--    WHERE p.proname = 'report_client_error' AND p.pronamespace = 'public'::regnamespace;
--   → public.report_client_error(text, text, text, text, text, text, text, text, text, boolean) 1행만
--
--   SELECT grantee, privilege_type
--     FROM information_schema.routine_privileges
--    WHERE routine_name = 'report_client_error';
--   → anon, authenticated 모두 EXECUTE 보유
--
-- 3단계 — 하위 호환: 옛 클라이언트처럼 9개 키만 보내는 호출 (is_expected 생략) —
--   지금 운영에 배포된 error-report.js 가 실제로 이렇게 호출한다. 이게 막히면
--   전체 인플루언서 앱 오류 수집이 무음으로 죽는다(throw 는 안 하지만 행이 안 쌓임):
--   SELECT public.report_client_error(
--     'fp_308_legacy_call', 'influencer', 'handled', 'legacy 9-arg smoke test');
--   SELECT fingerprint, is_expected, message FROM public.client_error_logs
--    WHERE fingerprint = 'fp_308_legacy_call';
--   → is_expected = false (기본값), 행 1건 생성 확인
--   DELETE FROM public.client_error_logs WHERE fingerprint = 'fp_308_legacy_call';
--
-- 4단계 — is_expected=true 로 1건 기록해 보는 스모크 호출:
--   SELECT public.report_client_error(
--     'fp_308_expected_test', 'influencer', 'handled', 'expected rejection smoke test',
--     NULL, NULL, NULL, 'test_context', NULL, true);
--   SELECT fingerprint, is_expected, occurrence_count FROM public.client_error_logs
--    WHERE fingerprint = 'fp_308_expected_test';
--   → is_expected = true, occurrence_count = 1
--
--   -- 같은 fingerprint 로 한 번 더 호출(재발 시뮬레이션) — is_expected 는 안 바뀌는지 확인:
--   SELECT public.report_client_error(
--     'fp_308_expected_test', 'influencer', 'handled', 'expected rejection smoke test',
--     NULL, NULL, NULL, 'test_context', NULL, false);  -- 일부러 false 로 다르게 호출
--   SELECT fingerprint, is_expected, occurrence_count FROM public.client_error_logs
--    WHERE fingerprint = 'fp_308_expected_test';
--   → is_expected 는 여전히 true (최초 값 유지), occurrence_count = 2
--
-- 5단계 — 스모크 행 정리:
--   DELETE FROM public.client_error_logs
--    WHERE fingerprint IN ('fp_308_legacy_call', 'fp_308_expected_test');
-- ============================================================
--
-- 롤백 절차:
--   1) 279_report_client_error_mask_auth_token.sql 의 CREATE OR REPLACE FUNCTION
--      블록(9인자, (a)~(f) 마스킹 포함)을 그대로 재실행 → 함수가 279 상태로 복구.
--   2) DROP FUNCTION IF EXISTS
--        public.report_client_error(text, text, text, text, text, text, text, text, text, boolean);
--      (1번에서 새 9인자 CREATE OR REPLACE 가 이미 별도 오버로드로 남으므로,
--       10인자 버전을 명시적으로 제거해야 두 버전이 공존하지 않는다)
--   3) ALTER TABLE public.client_error_logs DROP COLUMN IF EXISTS is_expected;
--   ⚠️ 운영에 이미 is_expected=true 로 기록된 행이 있다면 3번 실행 시 그 구분 정보가
--      영구히 사라진다(컬럼 자체가 없어짐) — 롤백 전 필요하면 백업.
-- ============================================================
