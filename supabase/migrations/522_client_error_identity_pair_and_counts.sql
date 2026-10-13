-- =============================================================================
-- 522_client_error_identity_pair_and_counts.sql
-- 오류 로그 — 「최근 발생자 정보」 한 쌍(브라우저 문자열 + 회원 아이디) · 날짜·환경별 횟수 연결 · 기간 조회
--
-- 사양서 : docs/specs/2026-10-12-error-log-env-distribution.md (설계 ②·④)
-- 작업표 : docs/specs/2026-10-12-error-log-env-distribution-breakdown.md 조각 D2
-- 선행   : 521 (client_error_daily 표 · _client_error_env_label 함수). 521 이 먼저 적용돼 있어야 한다.
-- 대상   : 개발서버 먼저 → 검증 → 운영서버 (운영은 521 → 522 순서, 화면 코드는 그 뒤)
-- 위험도 : 🔴 높음 — report_client_error 는 비로그인도 부르는 수집 경로다. 이 함수가 틀리면
--          오류 수집 전체가 오류 없이 조용히 멈춘다. 적용 직후 「멈춤 감시」(아래 검증 5단계)를 반드시 본다.
-- 편집기 경고: 뜸 — 무해 (①resolve_client_error 본문 안의 DELETE 단어 ②DROP POLICY IF EXISTS — 새 표라 지울 정책이 없다).
--             WHERE 없는 UPDATE 는 없다(채우기 UPDATE 에 WHERE identity_at IS NULL).
--
-- ── 이 파일이 한 트랜잭션으로 하는 일 (사양서 단계 1 — 따로 나가면 하루는 기준이 어긋난다) ──
--   1. 도입일 표 client_error_daily_settings (한 줄, 적용 순간의 일본 날짜 — 🔴 날짜를 파일에 상수로 박지 않았다)
--   2. client_error_logs.identity_at 칸 — user_agent·user_id 쌍을 「받은 시각」. 기존 줄은 first_seen_at 으로 채움
--   3. get_client_error_counts(p_from, p_to) — 기간별 횟수·환경 분포·도입일을 jsonb 하나로
--   4. report_client_error 재정의 (베이스 308, 인자 10개 그대로)
--   5. resolve_client_error 재정의 (베이스 518)
--   6. purge_old_client_error_identity 재정의 (베이스 519, 기준 identity_at)
--
-- ── 재정의 베이스 확인 (함수 재정의는 가장 나중 정의가 원본) ───────────────────────────
--   report_client_error : 정의가 있는 파일 165·279·308 (369 는 권한 주석만) → 현재 원본 308. 이 파일이 새 원본.
--   resolve_client_error: 정의 165·518 → 현재 원본 518.
--   purge_old_client_error_identity: 정의 519 하나.
--   각 함수의 본문은 위 원본에서 옮겼고, 바뀐 줄 목록은 아래 「바뀐 줄」 절에 있다.
--
-- ── 설계 요점 ─────────────────────────────────────────────────────────────────
--   · 쌍(user_agent, user_id, identity_at)은 발생을 기록할 때마다 한 문장에서 함께 갱신한다
--     (한쪽만 바꾸면 한 줄 안의 브라우저와 회원이 서로 다른 사람의 것이 된다 — 520 이 회원 아이디로 줄을 찾기 때문).
--   · 🔴 탈퇴 확정 계정이 부르면 쌍을 NULL 로 덮는다. 판정은 withdrawal_requests.status = 'done' (확정만) —
--     358 get_my_withdrawal_state() 의 login_blocked(= 확정 'done') 와 같은 뜻이다(2026-10-13 사용자 결정).
--     _withdrawal_account_blocked()(예정일 경과까지 포함하는 넓은 쓰기 차단 판정)는 쓰지 않는다 —
--     그 구간 회원은 탈퇴를 취소할 수 있어 아직 회원이다. 358 의 식이 바뀌면 이 파일의 판정도 함께 본다.
--   · 판정이 예외를 내면 EXCEPTION 으로 감싸 쌍 NULL (수집은 계속된다).
--   · user_id 는 influencers 외래 키 — influencers 에 행이 없는 로그인 계정이 부르면 UPDATE 자체가 실패하므로
--     없으면 user_id 만 NULL 로 한다(브라우저 문자열은 남김).
--   · 날짜별 +1 은 부모 줄 UPDATE/INSERT 뒤에 한 문장(ON CONFLICT DO UPDATE)으로. 같은 트랜잭션이라 부모 줄 잠금을
--     쥔 채 하므로 resolve_client_error(부모를 id 순서로 FOR UPDATE)와 교착하지 않고, 합치기와 겹쳐도 횟수가 사라지지 않는다.
--     날짜별 행 기록이 실패해도 오류 수집 자체는 살린다(서브 블록 EXCEPTION → WARNING). 그 경우 그 1회만 날짜·환경에서 빠지고
--     「도입 이전 N회」(누적 − 날짜별 합)에 섞여 보인다.
--   · 519 머리말의 「user_agent 만 last_seen_at 기준으로 갈라야 한다」는 제안은 폐기됐다 — 쌍을 한 문장으로 갱신하고
--     기준을 새 칸 identity_at 하나로 통일했다. 519 파일은 이력이라 고치지 않는다.
--   · 520(탈퇴 확정 파기)은 이 파일에서 건드리지 않는다. identity_at 도 안 비운다 — 규칙: 쌍이 비어 있으면
--     identity_at 은 어떤 경로로 비었든 무시한다(사양서 설계 ②).
--
-- ── 바뀐 줄 — 308(report_client_error) 대비 ──────────────────────────────────────
--   그대로(한 줄도 안 바꿈): 인자 10개의 이름·자료형·기본값 / RETURNS void / LANGUAGE·SECURITY DEFINER·search_path='' /
--     빈값 가드(fingerprint·message) / source·kind 허용값 가드 / 길이 제한 1000·4000·512 / 서버 2차 마스킹 (a)~(f) 6단락 /
--     left(p_context,200) · left(p_user_agent,512) / is_expected 는 최초 INSERT 에만(coalesce(p_is_expected,false)),
--     UPDATE·충돌 갱신에서는 손대지 않음 / ON CONFLICT (fingerprint, status).
--   바뀜:
--     ① DECLARE 에 v_log_id·v_ua·v_pair_uid·v_env·v_day 추가
--     ② 마스킹 뒤·UPDATE 앞에 「쌍 정하기」 블록 추가 (탈퇴 확정 → 쌍 NULL / influencers 없음 → user_id NULL / 판정 실패 → 쌍 NULL)
--     ③ 기존 줄 UPDATE: SET 에 user_agent·user_id·identity_at 추가, RETURNING id INTO v_log_id
--     ④ 새 줄 INSERT: 컬럼에 identity_at 추가, user_agent·user_id 값이 v_ua·v_pair_uid 로 바뀜(전: left(p_user_agent,512)·v_uid)
--     ⑤ ON CONFLICT DO UPDATE: SET 에 user_agent·user_id·identity_at 추가, RETURNING id INTO v_log_id
--     ⑥ 끝에 날짜별 행 +1 블록 추가
--     ⑦ COMMENT·GRANT 문구 (GRANT 는 308 과 같은 대상 anon, authenticated — 재진술)
--
-- ── 바뀐 줄 — 518(resolve_client_error) 대비 ──────────────────────────────────────
--   그대로: 인자 3개 / 관리자 가드 / status 허용값 가드 / 없는 행 거부 / 목표 상태 행이 없으면 상태만 바꾸는 갈래 /
--     두 행 id 순서 FOR UPDATE 와 재조회 / v_newer 선정 / 합친 횟수·first_seen_at LEAST·last_seen_at GREATEST /
--     source·kind·message·error_code·stack·page_hash·context·is_expected 를 v_newer 에서 가져오기 /
--     resolved_* · resolve_note 규칙 / 마지막 UPDATE 의 WHERE.
--   바뀜:
--     ① DELETE 앞에 「날짜별 행 옮겨 더하기」 INSERT … SELECT … ON CONFLICT DO UPDATE 추가 (순서: 옮기기 먼저, 삭제 나중)
--     ② 마지막 UPDATE 의 SET 에 identity_at = v_newer.identity_at 추가 (user_agent·user_id 는 518 에서 이미 v_newer 값)
--     ③ 머리 주석·COMMENT 문구
--
-- ── 바뀐 줄 — 519(purge_old_client_error_identity) 대비 ────────────────────────────
--   바뀜: 기준 first_seen_at → identity_at (3개월). 그 밖(DECLARE·UPDATE 대상 칸·IS NOT NULL 조건·NOTICE·RETURN)과
--   실행 권한(postgres 만)·예약(pg_cron client-error-logs-identity-retention-daily)은 그대로 — 예약은 다시 등록하지 않는다.
--
-- ── 롤백 ──────────────────────────────────────────────────────────────────────
--   1) 함수 셋을 옛 원본으로: 308 의 report_client_error 블록(CREATE OR REPLACE … 10인자) · 518 의 resolve_client_error 블록 ·
--      519 의 purge_old_client_error_identity 블록을 그대로 다시 실행. (DROP 하지 말 것 — 권한이 풀린다.)
--      ⚠️ 519 로 되돌리면 기준이 first_seen_at 이라 최근 받은 쌍까지 지워질 수 있다 — 되돌릴 때는 예약도 잠시 멈춘다:
--         SELECT cron.unschedule('client-error-logs-identity-retention-daily');  (되살릴 때는 519 의 schedule 블록)
--   2) DROP FUNCTION IF EXISTS public.get_client_error_counts(date, date);
--   3) 표·칸은 남겨도 무해하다. 지우려면:
--        DROP TABLE IF EXISTS public.client_error_daily_settings;
--        ALTER TABLE public.client_error_logs DROP COLUMN IF EXISTS identity_at;   -- 위 1) 을 먼저 해야 함수가 안 깨진다
--      (client_error_daily 표는 521 롤백 소관.)
-- =============================================================================

BEGIN;

-- ── 1. 도입일 표 (한 줄) ────────────────────────────────────────────────────────
-- 날짜별 행이 실제로 쌓이기 시작하는 순간이 곧 도입일이다 — 이 트랜잭션이 적용되는 순간의 일본 날짜를 기록한다.
-- 🔴 날짜 상수를 파일에 박지 않는다 (개발·운영 적용일이 달라 한쪽이 틀린다).
-- ⚠️ 「날짜별 표의 가장 이른 날」로 읽지 않는다 — 그건 적용 뒤 첫 오류가 난 날이고, 오래된 행이 지워지면 뒤로 밀린다.
CREATE TABLE IF NOT EXISTS public.client_error_daily_settings (
  id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  introduced_on date     NOT NULL
);

INSERT INTO public.client_error_daily_settings (id, introduced_on)
VALUES (1, (now() AT TIME ZONE 'Asia/Tokyo')::date)
ON CONFLICT (id) DO NOTHING;     -- 다시 실행해도 처음 적용일을 지키지 않고 덮어쓰지 않는다

COMMENT ON TABLE public.client_error_daily_settings IS
  '[522] 오류 로그 날짜별 횟수의 도입일(적용 순간의 일본 날짜) 한 줄. 화면은 직접 읽지 않고 get_client_error_counts() 가 함께 돌려준다. '
  '쓰기 정책 없음. 도입일 이전과 도입일 당일 일부 횟수는 날짜별 행에 없다.';

ALTER TABLE public.client_error_daily_settings ENABLE ROW LEVEL SECURITY;

-- 사용자 결정(2026-10-13): 막힌 표 감지(335·336)가 이 표를 「확인 안 됨」으로 잡지 않도록 관리자 조회 정책을 둔다.
DROP POLICY IF EXISTS cedset_select_admin ON public.client_error_daily_settings;
CREATE POLICY cedset_select_admin ON public.client_error_daily_settings
  FOR SELECT USING ((SELECT public.is_admin()));
-- 쓰기 정책 없음.

-- ── 2. identity_at — user_agent·user_id 쌍을 「받은 시각」 ──────────────────────────
ALTER TABLE public.client_error_logs
  ADD COLUMN IF NOT EXISTS identity_at timestamptz;

-- 기존 줄은 first_seen_at 으로 채운다. 518 로 합쳐진 줄은 쌍이 늦은 쪽 줄의 값인데 first_seen_at 은 이른 쪽(LEAST)이라
-- 채운 시각은 실제로 받은 시각과 같거나 이르다 → 더 일찍 비워지는 쪽(보수적, 3개월을 넘겨 남지 않는다).
-- WHERE 로 거른 UPDATE (다시 실행해도 이미 채운 값은 건드리지 않는다).
UPDATE public.client_error_logs
   SET identity_at = first_seen_at
 WHERE identity_at IS NULL;

ALTER TABLE public.client_error_logs
  ALTER COLUMN identity_at SET DEFAULT now();
ALTER TABLE public.client_error_logs
  ALTER COLUMN identity_at SET NOT NULL;     -- 비면 파기(519 대체 함수)에서 영원히 빠진다 → 비지 않게 못 박는다

COMMENT ON COLUMN public.client_error_logs.identity_at IS
  '[522] 지금 user_agent·user_id 쌍을 받은 시각. report_client_error 가 발생을 기록할 때마다 항상 now()(쌍을 NULL 로 덮는 경로 포함). '
  '🔴 쌍이 비어 있으면(user_agent·user_id 둘 다 NULL) 이 값은 어떤 경로로 비었든 무시한다. '
  'purge_old_client_error_identity 가 이 값 기준 3개월로 쌍을 함께 비운다. 기존 줄은 first_seen_at 으로 채움.';

-- ── 3. get_client_error_counts — 기간별 횟수·환경 분포·도입일 ─────────────────────────
-- 반환 jsonb: { introduced_on: 'YYYY-MM-DD' | null, rows: [ { id, period_count, envs: { "이름": 횟수 } } ] }
--   · 기간 안에 날짜별 행이 있는 오류 행만 rows 에 담긴다(상태 무관).
--   · 0건이어도 introduced_on 은 돌려준다(도입 이전 기간을 골라 0건일 때 안내 줄에 필요).
--   · p_from, p_to 둘 다 NULL = 「전체」. p_from 만 NULL = 하한 없음. p_to 가 NULL 이거나 미래면 오늘(일본)로 자른다.
--   · p_from > p_to(자른 뒤) 이면 rows 는 빈 배열.
-- 관리자 전용: is_admin() 가드 + 실행 권한 authenticated 만. SQL 편집기(서비스 키)는 가드가 거짓이라 부를 수 없다 — 관리자 브라우저에서 시험.
CREATE OR REPLACE FUNCTION public.get_client_error_counts(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_to     date;
  v_intro  date;
  v_rows   jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  v_to := LEAST(COALESCE(p_to, v_today), v_today);

  SELECT s.introduced_on INTO v_intro
    FROM public.client_error_daily_settings s
   WHERE s.id = 1;

  IF p_from IS NOT NULL AND p_from > v_to THEN
    v_rows := '[]'::jsonb;
  ELSE
    SELECT COALESCE(jsonb_agg(
             jsonb_build_object('id', l.error_log_id,
                                'period_count', l.period_count,
                                'envs', l.envs)), '[]'::jsonb)
      INTO v_rows
      FROM (
        SELECT e.error_log_id,
               sum(e.cnt)                      AS period_count,
               jsonb_object_agg(e.env, e.cnt)  AS envs
          FROM (
            SELECT d.error_log_id, d.env, sum(d.count)::bigint AS cnt
              FROM public.client_error_daily d
             WHERE (p_from IS NULL OR d.day >= p_from)
               AND d.day <= v_to
             GROUP BY d.error_log_id, d.env
          ) e
         GROUP BY e.error_log_id
      ) l;
  END IF;

  RETURN jsonb_build_object('introduced_on', v_intro, 'rows', v_rows);
END;
$$;

COMMENT ON FUNCTION public.get_client_error_counts(date, date) IS
  '[522] 오류 로그 기간별 횟수·환경 분포. 반환 {introduced_on, rows:[{id, period_count, envs}]}. 관리자 전용(is_admin). '
  '기간은 일본 표준시 날짜, 끝이 비거나 미래면 오늘로 자름, 시작이 비면 하한 없음. 0건이어도 introduced_on 은 돌려준다.';

-- 새 함수 — 두 방향 회수 뒤 authenticated 에만 부여(안쪽에 is_admin() 가드가 있어도 anon 이 부를 길은 닫는다)
REVOKE ALL ON FUNCTION public.get_client_error_counts(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_client_error_counts(date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_client_error_counts(date, date) TO authenticated;

-- ── 4. report_client_error — 308 본문 베이스 (인자 10개 그대로, CREATE OR REPLACE · DROP 금지) ──
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
  v_log_id   uuid;                                                   -- [522] 부모 줄 id
  v_ua       text;                                                   -- [522] 이번에 저장할 브라우저 문자열
  v_pair_uid uuid;                                                   -- [522] 이번에 저장할 회원 아이디
  v_env      text;                                                   -- [522] 환경 분류 이름
  v_day      date := (now() AT TIME ZONE 'Asia/Tokyo')::date;        -- [522] 일본 표준시 날짜
BEGIN
  -- ── 1. 빈값 가드 (308/279/165 와 동일) ───────────────────────────────────────
  IF coalesce(trim(p_fingerprint), '') = '' OR coalesce(trim(p_message), '') = '' THEN
    RETURN;
  END IF;

  IF p_source NOT IN ('influencer', 'admin') THEN
    RETURN;
  END IF;
  IF p_kind NOT IN ('unhandled', 'rejection', 'handled') THEN
    RETURN;
  END IF;

  -- ── 2. 길이 제한 (308/279/165 와 동일) ───────────────────────────────────────
  v_message  := left(p_message,  1000);
  v_stack    := left(p_stack,    4000);
  v_pagehash := left(p_page_hash, 512);

  -- ── 3. 서버측 2차 마스킹 (308/279/165 와 동일, (a)~(f) 6단락 전부 유지) ────────
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

  -- ── 3-B. [522] 이번에 저장할 「쌍」(브라우저 문자열 + 회원 아이디) 정하기 ─────────────
  --   기본 = 이번 발생자의 값. 비로그인이면 user_id 는 NULL(최근 발생자가 비로그인이라는 사실 그대로).
  --   · 탈퇴 확정(withdrawal_requests.status='done') 계정이면 쌍을 둘 다 NULL — 358 login_blocked 와 같은 뜻.
  --     _withdrawal_account_blocked()(예정일 경과까지 포함)는 쓰지 않는다. 탈퇴 확정 뒤에도 열린 세션은 같은 오류를 낼 수
  --     있고 520 은 확정 순간 한 번만 돌기 때문에 여기서 막는다. (308 도 새 줄을 넣을 때 같은 구멍이 있었다.)
  --   · influencers 에 행이 없는 로그인 계정이면 user_id 만 NULL (client_error_logs.user_id 외래 키 위반 방어).
  --   · 판정이 예외를 내도 수집은 계속 — 쌍 NULL.
  v_ua       := left(p_user_agent, 512);
  v_pair_uid := v_uid;
  IF v_uid IS NOT NULL THEN
    BEGIN
      IF EXISTS (SELECT 1 FROM public.withdrawal_requests w
                  WHERE w.influencer_id = v_uid AND w.status = 'done') THEN
        v_ua       := NULL;
        v_pair_uid := NULL;
      ELSIF NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = v_uid) THEN
        v_pair_uid := NULL;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_ua       := NULL;
      v_pair_uid := NULL;
    END;
  END IF;

  -- ── 4. open fingerprint 가 있으면 카운트 증가·쌍 갱신, 없으면 신규 INSERT (308/279/165 와 같은 구조) ──
  -- ⚠️ is_expected 는 이 UPDATE 분기에서 건드리지 않는다 — 같은 fingerprint 는 같은
  -- 호출 지점이라 값이 최초 기록 이후로 바뀔 이유가 없다는 전제(308).
  -- [522] user_agent·user_id·identity_at 은 한 문장에서 함께 갱신한다(한쪽만 바꾸지 않는다).
  UPDATE public.client_error_logs
     SET occurrence_count = occurrence_count + 1,
         last_seen_at     = now(),
         user_agent       = v_ua,
         user_id          = v_pair_uid,
         identity_at      = now()
   WHERE fingerprint = p_fingerprint
     AND status      = 'open'
  RETURNING id INTO v_log_id;

  IF NOT FOUND THEN
    INSERT INTO public.client_error_logs
      (fingerprint, source, kind, message, error_code,
       stack, page_hash, context, user_agent, user_id, is_expected, identity_at)
    VALUES
      (p_fingerprint,
       p_source,
       p_kind,
       v_message,
       p_error_code,
       v_stack,
       v_pagehash,
       left(p_context,    200),
       v_ua,
       v_pair_uid,
       coalesce(p_is_expected, false),
       now())
    -- ON CONFLICT DO UPDATE 는 명시한 컬럼만 갱신한다. is_expected 는 여기서도 손대지 않는다 —
    -- 먼저 들어온 행의 값이 유지된다. [522] 쌍 세 칸은 함께 갱신한다.
    ON CONFLICT (fingerprint, status) DO UPDATE
      SET occurrence_count = public.client_error_logs.occurrence_count + 1,
          last_seen_at     = now(),
          user_agent       = EXCLUDED.user_agent,
          user_id          = EXCLUDED.user_id,
          identity_at      = now()
    RETURNING id INTO v_log_id;
  END IF;

  -- ── 5. [522] 날짜·환경별 횟수 +1 — 부모 줄을 쓴 뒤, 같은 트랜잭션 안에서 한 문장으로 ────────
  --   환경 분류는 원래 브라우저 문자열로 한다(탈퇴 확정 계정이어도 개인과 이어지지 않는 합계로 센다 — 사양서 경우의 수 10).
  --   서브 블록으로 감싸 이 기록이 실패해도 오류 수집은 살린다(그 1회만 날짜·환경에서 빠진다).
  IF v_log_id IS NOT NULL THEN
    BEGIN
      v_env := public._client_error_env_label(left(p_user_agent, 512));
      INSERT INTO public.client_error_daily (error_log_id, day, env, count)
      VALUES (v_log_id, v_day, v_env, 1)
      ON CONFLICT (error_log_id, day, env) DO UPDATE
        SET count = public.client_error_daily.count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[report_client_error] daily count skipped: %', SQLERRM;
    END;
  END IF;

END;
$$;

COMMENT ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text, boolean) IS
  '[522, 베이스 308] 사용자 앱 오류 수집 (anon 호출 가능). 308 본문에 ①user_agent·user_id·identity_at 을 발생마다 한 쌍으로 갱신 '
  '②탈퇴 확정(withdrawal_requests.status=done) 계정이면 쌍 NULL ③influencers 에 없으면 user_id NULL ④일본 날짜·환경 이름별 횟수(client_error_daily) +1 을 더했다. '
  '인자 10개·마스킹·길이 가드·is_expected(최초 INSERT 에만)는 308 그대로.';

-- 308 과 같다 — anon(비로그인)과 인증 사용자 모두 호출 가능. CREATE OR REPLACE 는 권한을 보존하므로 재진술일 뿐이다.
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text, boolean)
  TO anon, authenticated;

-- ── 5. resolve_client_error — 518 본문 베이스 (인자 그대로, CREATE OR REPLACE · DROP 금지) ──
CREATE OR REPLACE FUNCTION public.resolve_client_error(
  p_id     uuid,
  p_status text,
  p_note   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cur    public.client_error_logs%ROWTYPE;
  v_tgt    public.client_error_logs%ROWTYPE;
  v_tgt_id uuid;
  v_newer  public.client_error_logs%ROWTYPE;
BEGIN
  -- 관리자 권한 가드
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  -- 허용 status 가드
  IF p_status NOT IN ('open', 'resolved', 'ignored') THEN
    RAISE EXCEPTION 'invalid status: %', p_status;
  END IF;

  SELECT * INTO v_cur FROM public.client_error_logs WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_error_log not found: %', p_id;
  END IF;

  -- 목표 상태의 같은 지문 행이 (다른 id 로) 없으면 165 와 똑같이 상태만 바꾼다
  SELECT t.id INTO v_tgt_id
    FROM public.client_error_logs t
   WHERE t.fingerprint = v_cur.fingerprint AND t.status = p_status AND t.id <> p_id;

  IF v_tgt_id IS NULL THEN
    UPDATE public.client_error_logs
       SET status       = p_status,
           resolved_by  = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
           resolved_at  = CASE WHEN p_status = 'open' THEN NULL ELSE now()      END,
           resolve_note = CASE WHEN p_status = 'open' THEN NULL ELSE p_note     END
     WHERE id = p_id;
    RETURN;
  END IF;

  -- ── 합치기: 두 행을 id 순서로 잠근 뒤 최신 값으로 다시 읽는다(교착 방지) ──
  PERFORM 1 FROM public.client_error_logs
   WHERE id IN (p_id, v_tgt_id) ORDER BY id FOR UPDATE;
  SELECT * INTO v_cur FROM public.client_error_logs WHERE id = p_id;
  SELECT * INTO v_tgt FROM public.client_error_logs WHERE id = v_tgt_id;
  IF v_cur.id IS NULL OR v_tgt.id IS NULL THEN
    RAISE EXCEPTION 'client_error_log changed concurrently: %', p_id;
  END IF;

  -- 원문·스택 등은 마지막 발생이 더 늦은 행의 값
  v_newer := CASE WHEN v_cur.last_seen_at > v_tgt.last_seen_at THEN v_cur ELSE v_tgt END;

  -- [522] 🔴 날짜별 횟수 옮기기 — 지울 줄(p_id)의 날짜별 행을 남길 줄(v_tgt_id)로 옮겨 더한다(같은 날·같은 환경은 합산).
  --   순서: 옮기기 먼저, 삭제 나중. 줄을 지우면 외래 키(ON DELETE CASCADE)로 그 줄의 날짜별 행이 함께 사라진다.
  INSERT INTO public.client_error_daily (error_log_id, day, env, count)
  SELECT v_tgt_id, d.day, d.env, d.count
    FROM public.client_error_daily d
   WHERE d.error_log_id = p_id
  ON CONFLICT (error_log_id, day, env) DO UPDATE
    SET count = public.client_error_daily.count + EXCLUDED.count;

  -- 지금 행을 먼저 지운다 — 목표 행은 이미 그 상태라 유일 제약과 무관하지만, 순서를 고정해 둔다
  DELETE FROM public.client_error_logs WHERE id = p_id;

  UPDATE public.client_error_logs t
     SET occurrence_count = v_tgt.occurrence_count + v_cur.occurrence_count,
         first_seen_at    = LEAST(v_tgt.first_seen_at, v_cur.first_seen_at),
         last_seen_at     = GREATEST(v_tgt.last_seen_at, v_cur.last_seen_at),
         source           = v_newer.source,
         kind             = v_newer.kind,
         message          = v_newer.message,
         error_code       = v_newer.error_code,
         stack            = v_newer.stack,
         page_hash        = v_newer.page_hash,
         context          = v_newer.context,
         user_agent       = v_newer.user_agent,
         user_id          = v_newer.user_id,
         identity_at      = v_newer.identity_at,   -- [522] 쌍(user_agent·user_id)과 받은 시각은 함께 옮긴다
         is_expected      = v_newer.is_expected,   -- 308 이 더한 칸(예상된 업무 거부 구분)
         resolved_by      = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
         resolved_at      = CASE WHEN p_status = 'open' THEN NULL ELSE now()      END,
         resolve_note     = CASE WHEN p_status = 'open' THEN NULL
                                 ELSE COALESCE(NULLIF(btrim(p_note), ''), v_tgt.resolve_note) END
   WHERE t.id = v_tgt_id;
END;
$$;

COMMENT ON FUNCTION public.resolve_client_error(uuid, text, text) IS
  '[522, 베이스 518] 오류 묶음 상태 변경(open/resolved/ignored, 관리자). 같은 지문·같은 목표 상태의 다른 행이 있으면 그 행으로 합친다(횟수 합·처음/마지막 발생·최근 원문). '
  '522 가 더한 것: 합칠 때 지울 줄의 날짜별 횟수(client_error_daily)를 남길 줄로 옮겨 더한 뒤 지우고, identity_at 을 쌍과 함께 옮긴다.';

GRANT EXECUTE ON FUNCTION public.resolve_client_error(uuid, text, text) TO authenticated;

-- ── 6. purge_old_client_error_identity — 519 베이스, 기준 first_seen_at → identity_at ──────
-- 519 머리말의 「user_agent 만 last_seen_at 기준으로 갈라야 한다」는 제안은 폐기됐다 — 쌍을 한 문장으로 갱신하고
-- 기준을 identity_at 하나로 통일했다. 예약(pg_cron)은 519 가 등록한 것을 그대로 쓴다(다시 등록하지 않는다).
-- identity_at 은 NOT NULL 이라 COALESCE 가 필요 없다. 쌍이 이미 비어 있으면 IS NOT NULL 조건에서 빠진다(identity_at 은 안 비운다).
CREATE OR REPLACE FUNCTION public.purge_old_client_error_identity()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff  timestamptz := now() - interval '3 months';
  v_cleared integer;
BEGIN
  UPDATE public.client_error_logs
     SET user_agent = NULL,
         user_id    = NULL
   WHERE identity_at < v_cutoff
     AND (user_agent IS NOT NULL OR user_id IS NOT NULL);
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  RAISE NOTICE '[purge_old_client_error_identity] cutoff=% cleared=% rows', v_cutoff, v_cleared;
  RETURN v_cleared;
END;
$$;

COMMENT ON FUNCTION public.purge_old_client_error_identity() IS
  '[522, 베이스 519] 오류 로그 브라우저 정보·회원 아이디 3개월 파기 — 기준은 쌍을 받은 시각 identity_at(519 의 first_seen_at 에서 변경). 행은 남김. '
  'postgres(예약 실행) 전용. 비운 건수 반환. pg_cron: client-error-logs-identity-retention-daily (매일 UTC 18:30 = 도쿄 03:30, 519 가 등록).';
-- 실행 권한(postgres 만)은 CREATE OR REPLACE 가 보존한다 — 아래 검증 2단계로 확인.

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL 편집기 — 1단계씩. 결과를 확인한 뒤 다음 단계로. 개발서버 먼저)
--   ⚠️ SQL 편집기는 서비스 키라 auth.uid() 가 NULL(비로그인 갈래만 돈다)이고 is_admin() 이 거짓이다.
--      로그인 갈래·관리자 가드·합치기는 관리자/회원 브라우저 콘솔에서 확인한다(5·6단계).
--   ⚠️ 적용 전에 먼저 2단계의 조회를 한 번 돌려 결과(acl 문자열)를 따로 적어 둔다 — 적용 뒤와 비교한다.
--
-- 1단계 — 칸·도입일 표:
--   SELECT column_name, is_nullable, column_default FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='client_error_logs' AND column_name='identity_at';
--   → timestamptz / NO / now()
--   SELECT id, introduced_on FROM public.client_error_daily_settings;
--   → 1행, introduced_on = 오늘(일본)
--   SELECT count(*) FILTER (WHERE identity_at IS NULL) AS null_cnt, count(*) AS total FROM public.client_error_logs;
--   → null_cnt = 0
--
-- 2단계 — 함수 시그니처와 실행 권한 (재정의 뒤에도 그대로인지. report 는 10인자 1행만):
--   SELECT p.oid::regprocedure AS fn, p.proacl::text AS acl
--     FROM pg_proc p
--    WHERE p.pronamespace = 'public'::regnamespace
--      AND p.proname IN ('report_client_error','resolve_client_error','purge_old_client_error_identity',
--                        'get_client_error_counts','_client_error_env_label')
--    ORDER BY p.proname;
--   → report_client_error : 1행(인자 10개), acl 에 anon=X · authenticated=X 포함 (적용 전과 같아야 한다 — 가장 중요)
--     resolve_client_error : authenticated 만 (맨 앞 '=X/' 없음)
--     purge_old_client_error_identity : postgres 만
--     get_client_error_counts : authenticated 만 (맨 앞 '=X/' 없음, anon 없음)
--     _client_error_env_label : 맨 앞 '=X/' 없음, anon·authenticated 없음 (521)
--
-- 3단계 — 수집 시험 (비로그인 갈래, 시험 줄은 5단계에서 지운다):
--   SELECT public.report_client_error('fp-522-test', 'influencer', 'handled', '522 smoke test', NULL, NULL, NULL, 'smoke',
--     'Mozilla/5.0 (iPhone; CPU iPhone OS 26_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/153.0.8010.24 Mobile/15E148 Safari/604.1');
--   SELECT l.occurrence_count, l.user_id, l.identity_at IS NOT NULL AS has_identity_at, d.day, d.env, d.count
--     FROM public.client_error_logs l JOIN public.client_error_daily d ON d.error_log_id = l.id
--    WHERE l.fingerprint = 'fp-522-test';
--   → occurrence_count 1, user_id NULL, has_identity_at true, day = 오늘, env = 'iOS · Chrome', count 1
--   같은 호출을 한 번 더 한 뒤 위 SELECT → occurrence_count 2, count 2 (줄은 여전히 1개)
--   다른 브라우저 문자열(예: 맥 크롬)로 한 번 더 → 날짜별 행이 2개(env 가 다름), user_agent 가 맥 크롬으로 바뀜:
--   SELECT user_agent FROM public.client_error_logs WHERE fingerprint = 'fp-522-test';
--
-- 4단계 — 파기 기준 시험 (⚠️ 이 함수는 개발 DB 의 3개월 지난 다른 줄도 정당하게 비운다):
--   UPDATE public.client_error_logs SET identity_at = now() - interval '4 months' WHERE fingerprint = 'fp-522-test';
--   SELECT public.purge_old_client_error_identity();    -- 비운 건수
--   SELECT user_agent, user_id, identity_at FROM public.client_error_logs WHERE fingerprint = 'fp-522-test';
--   → user_agent NULL, user_id NULL, identity_at 은 그대로 (쌍이 비면 identity_at 은 무시)
--   최근 줄(identity_at 이 3개월 안)은 쌍이 남는지도 아무 줄이나 하나 눈으로 확인.
--
-- 5단계 — 🔴 멈춤 감시 (양성 대조): 회원 앱(개발서버)에서 로그인 비밀번호를 일부러 틀린 직후
--   SELECT max(last_seen_at) FROM public.client_error_logs;                 -- 방금 시각으로 움직였나
--   SELECT max(day), sum(count) FROM public.client_error_daily;             -- 합이 늘었나
--   → 둘 다 움직이지 않으면 수집이 멈춘 것 — 즉시 308 블록(롤백 1)으로 되돌린다. 「Success」 말고 값으로 판단.
--   운영은 적용 직후와 몇 시간 뒤 두 번.
--
-- 6단계 — 관리자·회원 브라우저 콘솔 (개발서버):
--   (관리자) await db.rpc('get_client_error_counts', {p_from:null, p_to:null})
--     → { introduced_on:'오늘', rows:[… fp-522-test 줄 포함 …] }
--   (관리자) await db.rpc('get_client_error_counts', {p_from:'2000-01-01', p_to:'2000-01-02'})
--     → rows:[] 이고 introduced_on 은 그대로
--   (비로그인 콘솔 또는 회원) 같은 함수 호출 → 오류(permission denied 또는 권한 없음)
--   (회원 로그인) await db.rpc('report_client_error',{p_fingerprint:'fp-522-test',p_source:'influencer',p_kind:'handled',p_message:'522 login test',p_user_agent:navigator.userAgent})
--     → 그 줄의 user_id 가 그 회원, identity_at 방금
--   (관리자) 시험 줄을 「무시」 → 한 번 더 report → 다시 「무시」 : 합쳐진 줄의 날짜별 합 = 횟수 (아래 7단계로 확인)
--
-- 7단계 — 합치기 후 날짜별 합 확인 (시험 줄 하나):
--   SELECT l.occurrence_count, (SELECT sum(count) FROM public.client_error_daily d WHERE d.error_log_id = l.id) AS daily_sum
--     FROM public.client_error_logs l WHERE l.fingerprint = 'fp-522-test';
--   → 시험 줄은 522 적용 후에만 만들었으므로 occurrence_count = daily_sum
--
-- 8단계 — 시험 줄 정리 (날짜별 행은 함께 지워진다):
--   DELETE FROM public.client_error_logs WHERE fingerprint = 'fp-522-test';
--
-- 9단계 — 막힌 표 감지가 새 표를 「확인 안 됨」으로 안 잡는지: 관리자 화면 사이드바 오류 로그 아이콘·「못 읽는 표」 목록을 눈으로 본다.
-- ============================================================
