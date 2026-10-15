-- ============================================================
-- 496_signup_codes_retention.sql
-- 회원가입 이메일 인증번호 — 조각 D4 「번호 기록 정기 삭제 + 예약」
--   선행: 493(설정 표) · 494(번호 표)
--
-- 하는 일
--   signup_email_codes 에서 created_at 이 code_retention_days(493 설정 표, 시작값 30일)보다
--   오래된 행을 지운다. 원문 이메일·번호가 없고 해시뿐이지만 개인정보처리방침에 보관 기간이 적힌다 —
--   🔴 그 일수를 바꾸려면 방침 개정 → 시행 7일 전 공지 → 시행일 뒤에 설정 값 변경.
--   설정 표를 못 읽으면(행 없음) 보관 기간 시작값 30일로 대신한다 — 지우는 쪽이라 늦추는 것보다 안전하다.
--
-- 예약: signup-email-codes-retention-daily — 매일 UTC 18:15(= 도쿄 03:15).
--   작업표 선결 9 — 양쪽 서버 cron.job 조회로 빈 자리 확인(18:15 사용 안 함).
--   ⚠️ 개발·운영 **양쪽**에 등록한다(메일을 안 보내는 정리라 개발에도 건다).
--
-- 롤백
--   SELECT cron.unschedule('signup-email-codes-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_old_signup_email_codes();
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_old_signup_email_codes()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_days    integer;
  v_cutoff  timestamptz;
  v_deleted integer;
BEGIN
  SELECT code_retention_days INTO v_days FROM public.signup_code_settings WHERE id = 1;
  v_days   := coalesce(v_days, 30);
  v_cutoff := now() - make_interval(days => v_days);

  DELETE FROM public.signup_email_codes WHERE created_at < v_cutoff;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_old_signup_email_codes] cutoff=% deleted=% rows', v_cutoff, v_deleted;
  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.purge_old_signup_email_codes() IS
  '[496] 인증번호 기록 정기 삭제 — created_at 이 설정 표 code_retention_days(시작 30일)보다 오래된 행 삭제. '
  'postgres(예약 실행) 전용. 삭제 건수 반환. pg_cron: signup-email-codes-retention-daily (매일 UTC 18:15 = 도쿄 03:15).';

-- postgres 만(243·166 방식 + 369 의 두 방향 회수)
GRANT  EXECUTE ON FUNCTION public.purge_old_signup_email_codes() TO postgres;
REVOKE EXECUTE ON FUNCTION public.purge_old_signup_email_codes() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_old_signup_email_codes() FROM anon, authenticated, service_role;

-- 중복 등록 방지: 같은 이름이 있으면 먼저 해제 후 재등록(166 방식)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'signup-email-codes-retention-daily';

SELECT cron.schedule(
  'signup-email-codes-retention-daily',
  '15 18 * * *',                         -- 매일 UTC 18:15 (= 도쿄 03:15)
  $$
  SELECT public.purge_old_signup_email_codes();
  $$
);

-- ------------------------------------------------------------
-- 검증 (1단계씩)
-- ------------------------------------------------------------
-- [1] 예약 등록 — 1건, schedule = '15 18 * * *', active = true
-- SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'signup-email-codes-retention-daily';
-- [2] 다른 예약과 시각이 겹치지 않는지
-- SELECT jobname, schedule FROM cron.job ORDER BY schedule;
-- [3] 수동 실행 — 정수(30일 지난 행이 없으면 0)
-- SELECT public.purge_old_signup_email_codes();
