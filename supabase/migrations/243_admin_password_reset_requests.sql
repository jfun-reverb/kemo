-- ============================================================
-- 243_admin_password_reset_requests.sql
-- 2026-07-20
--
-- 목적:
--   관리자 전용 「비밀번호 찾기」(사양서 PR 5-B, docs/specs/2026-07-20-admin-invite-mail-and-setpw.md
--   §D-9 계정 존재 여부 노출 차단 / §D-10 초대·찾기 통합 범위 / §D-11 악용 방지) 요청을 기록하고,
--   계정 열거(입력한 이메일이 실제 관리자인지 노출) 및 악용(메일 폭탄·Brevo 월간 발송 한도 소진)을
--   막기 위한 요청 제한(rate limit) 판정을 서버(SECURITY DEFINER 함수)에서 원자적으로 수행한다.
--
--   이 테이블·함수는 신규 Edge Function `admin-password-reset-request`(익명 호출 허용) 가
--   service_role 로만 호출한다. 신규 익명(anon) 실행권한 함수는 0개 — 사양서 §D-6 설계 그대로
--   (판정·발급·발송은 전부 service_role 이 수행하고, 브라우저는 이메일 문자열만 보낸다).
--
-- 변경 사항:
--   1. public.admin_password_reset_requests 테이블 신규
--      - 원문 이메일 저장 안 함 — sha256 해시(소문자·공백 제거 정규화 후, 64자리 16진수)만 저장
--        (테이블이 유출돼도 관리자 이메일 명단이 되지 않게 하기 위함 — 이 테이블은 "요청만 하면
--        행이 쌓이는" 공개 경로라 admins 테이블보다 유출 시 파급력이 큼)
--      - RLS: SELECT 는 is_super_admin() 만, INSERT/UPDATE/DELETE 는 정책 없음(service_role 전용)
--   2. public.check_admin_password_reset_rate_limit(text, boolean) 함수 신규
--      - 요청 제한 3층(사양서 §D-11) 중 ①이메일별 ②전역 을 이 함수가 원자적으로 판정 + 기록한다.
--        (③ 이메일 형식·길이 검사는 DB 를 아예 타지 않도록 Edge Function 코드 단에서 먼저 걸러낸다)
--      - pg_advisory_xact_lock 으로 "동시에 도착한 같은 이메일 2건" 같은 경쟁 조건을 차단한다.
--      - SECURITY DEFINER + SET search_path = '' (권한 탈취 방어) + service_role 전용 실행권한
--   3. public.purge_old_admin_password_reset_requests() 함수 신규 + pg_cron 등록
--      - requested_at 기준 30일 경과 행 자동 삭제
--      - 선례를 그대로 따름: 166_influencer_flags_retention.sql (purge_old_influencer_flags 와
--        동일한 구조 — SECURITY DEFINER, search_path='', RETURN integer + RAISE NOTICE, postgres
--        role 전용 EXECUTE, cron.unschedule 후 재등록으로 멱등 처리)
--
-- 설계 결정 — 요청 기록(INSERT) 시점: 판정 전이 아니라 "판정과 무관하게 항상"
--   판정(허용 여부)은 "이번 요청 이전에 이미 존재하는 행"만으로 계산한다 — 이번 요청 자체를
--   셀프 카운트하지 않는다(그래야 "5분에 1회 허용"이 정확히 5분에 1행이 된다).
--   기록(INSERT)은 허용됐든 차단됐든 이 함수가 호출된 이상 항상 수행한다. 이유:
--     - 전역 제한(②)은 사양서가 "매칭·미매칭 무관하게" 세도록 명시했다. 이메일별 제한(①)에
--       걸려 차단된 요청도 "요청이 실제로 있었다"는 사실 자체는 전역 집계에 반영돼야, 서로 다른
--       이메일을 대량으로 돌려가며 두드리는 무작위 이메일 난사 공격에서 전역 상한이 유효하게 작동한다.
--     - 만약 차단된 요청을 기록에서 빼면, 같은 이메일을 계속 두드려도 그 이메일의 카운트가 5에서
--       멈춰버려(차단분은 안 늘어나므로) 24시간 창이 지나 5건 중 1건이 빠져나가는 순간 다시 1건
--       허용되는 정상적인 "슬라이딩 윈도" 동작이 깨지지 않는다는 장점도 있다.
--   잔여 위험(수용): 같은 이메일을 초당 수천 번 두드리는 순수 소음성 공격은 매 시도가 전부
--   기록되므로 테이블 행이 짧은 시간에 크게 늘 수 있다. 사양서 §D-11 이 IP 단위 제한을 "현시점
--   과잉"으로 명시 수용한 것과 같은 태도로 이번에도 수용하고, 30일 보존 정리가 장기 누적 상한을
--   만든다. 형식이 애초에 유효하지 않은 입력(③, 예: "abc" 같은 비-이메일 문자열)은 Edge Function
--   이 이메일 해시조차 계산하지 않고 걸러내 이 함수·테이블을 아예 타지 않는다 — 그 계층 소음은
--   DB 까지 도달하지 않는다.
--
-- 주의:
--   - 이 함수는 판정("허용/차단")만 하고, 실제 auth.admin.generateLink 발급·Brevo 메일 발송은
--     호출자인 Edge Function 이 담당한다. 이 함수는 메일을 보낼지 여부를 전혀 모른다 —
--     허용됐다고 반드시 발송되는 것도 아니다(매칭 안 되면 Edge Function 이 아무것도 안 함).
--   - 클라이언트(브라우저)에는 이 함수의 반환값이 절대 그대로 노출되지 않는다. Edge Function 은
--     이 함수의 결과와 무관하게 항상 동일한 { ok: true } 를 고정된 하한 대기 시간 이후 반환한다
--     (사양서 §D-9). 이 성질은 이 마이그레이션이 아니라 Edge Function 구현이 책임진다.
--
-- 롤백:
--   SELECT cron.unschedule('admin-password-reset-requests-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_old_admin_password_reset_requests();
--   DROP FUNCTION IF EXISTS public.check_admin_password_reset_rate_limit(text, boolean);
--   DROP TABLE IF EXISTS public.admin_password_reset_requests;
-- ============================================================


-- ============================================================
-- Step 1: 테이블 생성
-- ============================================================

CREATE TABLE public.admin_password_reset_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 원문 이메일 저장 금지. sha256(소문자·공백 제거 정규화 후) 결과를 16진수 64자로 저장.
  -- 정규화·해시 계산은 Edge Function 이 수행해 이미 해시된 값을 넘긴다(이 테이블·함수는
  -- 원문 이메일을 아예 받지 않는다).
  email_hash   text NOT NULL CHECK (email_hash ~ '^[0-9a-f]{64}$'),
  requested_at timestamptz NOT NULL DEFAULT now(),
  -- 매칭 여부(요청한 이메일이 실제 admins 행이었는지) — 내부 통계용. 클라이언트에는 절대 노출 안 함.
  matched      boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.admin_password_reset_requests IS
  '[243] 관리자 비밀번호 찾기 요청 기록. 원문 이메일 미저장(sha256 해시만). '
  '요청 제한(rate limit) 판정용 + 30일 후 자동 삭제. 쓰기는 service_role 전용(RLS 정책 없음).';

-- 이메일별 5분/24시간 판정용 — email_hash 로 좁힌 뒤 requested_at 범위 스캔
CREATE INDEX idx_admin_pw_reset_email_hash_at
  ON public.admin_password_reset_requests (email_hash, requested_at DESC);

-- 전역 시간당 판정 + 30일 보존 정리 공용 — requested_at 단독 범위 스캔
CREATE INDEX idx_admin_pw_reset_requested_at
  ON public.admin_password_reset_requests (requested_at DESC);

ALTER TABLE public.admin_password_reset_requests ENABLE ROW LEVEL SECURITY;

-- SELECT: 최고관리자만(내부 통계 확인용). INSERT/UPDATE/DELETE 정책은 만들지 않는다.
-- service_role 은 RLS 를 우회하므로 정책이 없어도 쓸 수 있고, anon/authenticated 는
-- 허용 정책이 없으므로 어떤 쓰기도 불가능하다(RLS 활성화 + 정책 없음 = 차단, supabase.md 원칙).
CREATE POLICY "admin_pw_reset_requests_select_super"
  ON public.admin_password_reset_requests
  FOR SELECT
  USING (is_super_admin());


-- ============================================================
-- Step 2: 요청 제한(rate limit) 원자적 판정 + 기록 함수
--   3층 방어(사양서 §D-11) 중 ①이메일별 ②전역 을 이 함수가 담당한다.
--   (③ 이메일 형식·길이 검사는 이 함수 호출 전 Edge Function 코드 단에서 이미 걸러진 상태로 가정)
--
--   동시 요청(같은 이메일 2건이 거의 동시 도착) 경쟁 조건 차단:
--   pg_advisory_xact_lock 으로 이 함수의 모든 호출을 단일 락 키로 직렬화한다. 이 엔드포인트는
--   공개 「비밀번호 찾기」 폼이라 트래픽이 낮고(전역 상한 자체가 시간당 30건), 함수 본문이
--   가벼운 COUNT 2~3회 + INSERT 1회뿐이라 전체 직렬화 비용이 무시할 수준이다. 서로 다른
--   이메일끼리도 함께 직렬화되지만, 이는 "전역 카운트"를 정확하게 세기 위해 오히려 필요하다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_admin_password_reset_rate_limit(
  p_email_hash text,
  p_matched    boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_short_count  integer;
  v_day_count    integer;
  v_global_count integer;
  v_allowed      boolean := true;
BEGIN
  -- 트랜잭션 종료 시 자동 해제되는 advisory lock. 이 함수를 부르는 모든 호출을 하나의 키로
  -- 직렬화해 "거의 동시에 도착한 같은 이메일 2건"이 서로의 COUNT 를 못 보고 둘 다 허용되는
  -- 경쟁 조건을 막는다.
  PERFORM pg_advisory_xact_lock(hashtext('admin_password_reset_rate_limit'));

  -- ① 이메일별 5분 1회 — 이번 요청 이전에 5분 이내 행이 하나라도 있으면 차단
  SELECT count(*) INTO v_short_count
  FROM public.admin_password_reset_requests
  WHERE email_hash = p_email_hash
    AND requested_at > now() - interval '5 minutes';
  IF v_short_count > 0 THEN
    v_allowed := false;
  END IF;

  -- ① 이메일별 24시간 5회
  IF v_allowed THEN
    SELECT count(*) INTO v_day_count
    FROM public.admin_password_reset_requests
    WHERE email_hash = p_email_hash
      AND requested_at > now() - interval '24 hours';
    IF v_day_count >= 5 THEN
      v_allowed := false;
    END IF;
  END IF;

  -- ② 전역 시간당 30건 (매칭·미매칭 무관 — Brevo 월간 발송 한도 방어가 목적)
  IF v_allowed THEN
    SELECT count(*) INTO v_global_count
    FROM public.admin_password_reset_requests
    WHERE requested_at > now() - interval '1 hour';
    IF v_global_count >= 30 THEN
      v_allowed := false;
      RAISE WARNING '[check_admin_password_reset_rate_limit] global rate limit exceeded (count=%)', v_global_count;
    END IF;
  END IF;

  -- 판정 결과(허용/차단)와 무관하게 항상 기록한다 — 파일 상단 "설계 결정" 주석 참고.
  INSERT INTO public.admin_password_reset_requests (email_hash, matched, requested_at)
  VALUES (p_email_hash, p_matched, now());

  RETURN v_allowed;
END;
$$;

-- 익명(anon)·로그인 사용자(authenticated) 모두 직접 호출 금지 — service_role(Edge Function)
-- 전용. 이 함수가 anon 에게 열려 있으면 브라우저가 임의 이메일 해시로 직접 두드려 다른 사람의
-- 요청 제한(rate limit)을 미리 소진시키는 것이 가능해진다(사양서 §D-6 "신규 익명 실행권한
-- 함수 0개" 설계를 이 REVOKE 로 실제로 강제한다).
REVOKE ALL ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) TO service_role;

COMMENT ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) IS
  '[243] 관리자 비밀번호 찾기 요청 제한 판정. 이메일별(5분1회·24시간5회) + 전역(시간당30건, '
  '매칭무관) 을 pg_advisory_xact_lock 으로 원자적 판정 후 결과와 무관하게 항상 기록. '
  'service_role 전용(anon/authenticated 실행권한 없음). '
  'Edge Function admin-password-reset-request 가 호출.';


-- ============================================================
-- Step 3: 30일 보존 정리 함수 + pg_cron 등록
--   선례: 166_influencer_flags_retention.sql (purge_old_influencer_flags) 와 동일한 구조.
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_old_admin_password_reset_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff  timestamptz;
  v_deleted integer;
BEGIN
  -- 30일 이전 기준 시각. 이 테이블은 요청 제한 판정용 임시 기록이라 개인정보처리방침의
  -- "부정이용·위반 기록 3년 보관"(influencer_flags 36개월)과는 성격이 다르다 — 요청 제한
  -- 창이 최대 24시간이므로, 30일이면 이상 탐지·감사 목적으로 충분히 여유 있게 남긴 뒤 삭제한다.
  v_cutoff := now() - interval '30 days';

  DELETE FROM public.admin_password_reset_requests
  WHERE requested_at < v_cutoff;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_old_admin_password_reset_requests] cutoff=% deleted=% rows', v_cutoff, v_deleted;

  RETURN v_deleted;
END;
$$;

-- 모든 사용자 권한 박탈 후 postgres role 만 허용 (pg_cron 은 postgres role 로 SQL 실행)
REVOKE ALL ON FUNCTION public.purge_old_admin_password_reset_requests() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_old_admin_password_reset_requests() TO postgres;

-- 중복 등록 방지: 이미 등록된 동명 job 이 있으면 먼저 해제 후 재등록 (멱등 처리)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'admin-password-reset-requests-retention-daily';

-- 매일 UTC 19:15 (= KST 04:15) — 기존 influencer-flags-retention-daily(UTC 19:00 = KST 04:00)
-- 와 15분 간격을 둬 pg_cron worker 경합을 피한다. 같은 트래픽 최저 시간대를 그대로 유지.
SELECT cron.schedule(
  'admin-password-reset-requests-retention-daily',   -- job 이름 (고유 식별자)
  '15 19 * * *',                                     -- 매일 UTC 19:15 (= KST 04:15)
  $$
  SELECT public.purge_old_admin_password_reset_requests();
  $$
);

COMMENT ON FUNCTION public.purge_old_admin_password_reset_requests() IS
  '[243] 관리자 비밀번호 찾기 요청 기록 30일 보존 정리. requested_at 기준 30일 경과 행 삭제. '
  'SECURITY DEFINER, cron/postgres 전용. 삭제 건수 반환 + RAISE NOTICE. '
  'pg_cron job: admin-password-reset-requests-retention-daily (매일 KST 04:15 = UTC 19:15).';


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor 에서 실행, 1단계씩 진행)
-- ============================================================

-- [1단계] 테이블·인덱스·RLS 정책 확인
-- SELECT indexname FROM pg_indexes WHERE tablename = 'admin_password_reset_requests';
-- SELECT policyname, cmd FROM pg_policies WHERE tablename = 'admin_password_reset_requests';
-- 기대: 인덱스 3개(PK 포함) / 정책 1개(SELECT, admin_pw_reset_requests_select_super)

-- [2단계] 함수 존재 + SECURITY DEFINER + 실행권한 확인
-- SELECT proname, prosecdef FROM pg_proc
--  WHERE proname IN ('check_admin_password_reset_rate_limit','purge_old_admin_password_reset_requests')
--    AND pronamespace = 'public'::regnamespace;
-- SELECT grantee, privilege_type FROM information_schema.routine_privileges
--  WHERE routine_name = 'check_admin_password_reset_rate_limit';
-- 기대: prosecdef = true 2건 / grantee 목록에 anon·authenticated 없이 service_role 만 있어야 함

-- [3단계] 함수 수동 호출 테스트 (SQL Editor 는 postgres role 로 실행 — service_role 전용 실행권한과는
--          별개로 postgres 는 함수 소유자라 항상 호출 가능. 로직 자체만 여기서 확인)
-- SELECT public.check_admin_password_reset_rate_limit(
--   encode(extensions.digest('test@example.com', 'sha256'), 'hex'), false
-- );
-- 첫 호출 결과 true 기대. 5분 이내 같은 인자로 다시 호출하면 false 기대(이메일별 5분 제한 작동 확인).
-- 확인 후 테스트 행 정리:
-- DELETE FROM public.admin_password_reset_requests
--  WHERE email_hash = encode(extensions.digest('test@example.com', 'sha256'), 'hex');

-- [4단계] cron job 등록 확인
-- SELECT jobid, jobname, schedule, active FROM cron.job
--  WHERE jobname = 'admin-password-reset-requests-retention-daily';
-- 기대: 1건, schedule = '15 19 * * *', active = true

-- [5단계] 정리 함수 수동 실행 테스트
-- SELECT public.purge_old_admin_password_reset_requests();
-- 기대: 정수 반환 (아직 30일 지난 행이 없으면 0)


-- ============================================================
-- 롤백 방법
-- ============================================================
-- 1. cron job 해제
--    SELECT cron.unschedule('admin-password-reset-requests-retention-daily');
--
-- 2. 함수 제거
--    DROP FUNCTION IF EXISTS public.purge_old_admin_password_reset_requests();
--    DROP FUNCTION IF EXISTS public.check_admin_password_reset_rate_limit(text, boolean);
--
-- 3. 테이블 제거 (RLS 정책·인덱스는 테이블과 함께 자동 삭제됨)
--    DROP TABLE IF EXISTS public.admin_password_reset_requests;
