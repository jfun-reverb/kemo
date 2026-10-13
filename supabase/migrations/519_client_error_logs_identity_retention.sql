-- ============================================================
-- 519_client_error_logs_identity_retention.sql
-- 오류 로그의 브라우저 정보·회원 아이디를 3개월 뒤 지운다(개인정보처리방침에 맞춤)
--
-- 근거: 개인정보처리방침 수집 항목 「자동 수집 — 접속 IP·접속 일시·브라우저 정보·쿠키·세션 토큰 → 3개월」
--   (docs/PRIVACY_kr.md·_ja.md 40줄, 보관 기간 표 「접속 로그 3개월」). 오류 로그는 지금까지 기한 없이 남았다.
--   2026-10-13 사용자 결정 — 방침을 고치지 않고 방침에 맞춘다.
--
-- 하는 일
--   client_error_logs 에서 first_seen_at 이 3개월보다 오래된 행의 user_agent·user_id 를 NULL 로 바꾼다.
--   행 자체와 오류 문구·스택·화면 주소·기능 이름(context)·횟수·처리 정보는 남긴다
--   (문구·주소는 저장 때 이메일·전화 등을 가린다 — 165·279).
--
-- ⚠️ 기준 시각이 last_seen_at 이 아니라 first_seen_at 인 이유
--   수집 함수(308)의 ON CONFLICT 는 횟수·마지막 발생만 고친다 — user_agent·user_id 는 **첫 발생 때 값**이다.
--   last_seen_at 으로 재면 계속 재발하는 오류는 첫 발생 때 브라우저·회원이 영영 안 지워진다.
--   재발 합치기(518)는 더 최근 행의 값을 가져가는데 first_seen_at 은 이른 쪽이라 **일찍 지워질 뿐**(안전 쪽).
--   지운 뒤 같은 묶음이 재발해도 308 이 그 두 칸을 다시 채우지 않는다.
--   🔴 오류 환경 분포 사양(docs/specs/2026-10-12-error-log-env-distribution.md)이 308 을 다시 정의해
--      user_agent 를 「최근 값」으로 갱신하게 되면, 이 함수도 함께 고쳐 **user_agent 만 last_seen_at 기준**으로
--      갈라야 한다(안 고치면 매일 어젯밤 들어온 브라우저 정보까지 지운다). user_id 는 그대로 first_seen_at.
--
-- 적용: 2026-10-13 개발(비운 1건)·운영(비운 5건, 전체 95건) — 예약 등록·실행 권한 postgres 만 확인
-- 예약: client-error-logs-identity-retention-daily — 매일 UTC 18:30(= 도쿄 03:30). 개발·운영 **양쪽**.
-- 편집기 경고: 안 뜸(DROP·DELETE·TRUNCATE 없음. WHERE 있는 UPDATE).
--
-- 롤백(지운 값은 되돌릴 수 없다 — 예약만 멈춘다)
--   SELECT cron.unschedule('client-error-logs-identity-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_old_client_error_identity();
-- ============================================================

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
   WHERE first_seen_at < v_cutoff
     AND (user_agent IS NOT NULL OR user_id IS NOT NULL);
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  RAISE NOTICE '[purge_old_client_error_identity] cutoff=% cleared=% rows', v_cutoff, v_cleared;
  RETURN v_cleared;
END;
$$;

COMMENT ON FUNCTION public.purge_old_client_error_identity() IS
  '[519] 오류 로그 브라우저 정보·회원 아이디 3개월 파기(개인정보처리방침 자동 수집 3개월) — first_seen_at 기준, 행은 남김. '
  'postgres(예약 실행) 전용. 비운 건수 반환. pg_cron: client-error-logs-identity-retention-daily (매일 UTC 18:30 = 도쿄 03:30).';

-- postgres 만(496 방식 + 369 의 두 방향 회수)
GRANT  EXECUTE ON FUNCTION public.purge_old_client_error_identity() TO postgres;
REVOKE EXECUTE ON FUNCTION public.purge_old_client_error_identity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_old_client_error_identity() FROM anon, authenticated, service_role;

-- 중복 등록 방지: 같은 이름이 있으면 먼저 해제 후 재등록(166 방식)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'client-error-logs-identity-retention-daily';

SELECT cron.schedule(
  'client-error-logs-identity-retention-daily',
  '30 18 * * *',                         -- 매일 UTC 18:30 (= 도쿄 03:30)
  $$
  SELECT public.purge_old_client_error_identity();
  $$
);

-- ------------------------------------------------------------
-- 검증 (1단계씩)
-- ------------------------------------------------------------
-- [0] 적용 전 대상 건수
-- SELECT count(*) FROM public.client_error_logs
--  WHERE first_seen_at < now() - interval '3 months' AND (user_agent IS NOT NULL OR user_id IS NOT NULL);
-- [1] 예약 등록 — 1건, schedule = '30 18 * * *', active = true
-- SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'client-error-logs-identity-retention-daily';
-- [2] 수동 1회 — [0] 과 같은 수
-- SELECT public.purge_old_client_error_identity();
-- [3] 다시 [0] → 0
