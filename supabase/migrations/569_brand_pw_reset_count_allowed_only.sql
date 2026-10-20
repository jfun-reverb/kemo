-- 569 브랜드 비밀번호 찾기 요청 제한 — 거절된 요청은 이메일별 창에 세지 않는다
--
-- 베이스: 527 check_brand_password_reset_rate_limit (527 이후 재정의 없음 — 현재 원본 527)
--
-- 문제(2026-10-20 개발서버 실발송 시험 9번):
--   527 은 판정 결과와 무관하게 요청을 항상 기록하고, 이메일별 창(5분 1회·24시간 5회)이 그 기록을 전부 센다.
--   그래서 「5분 뒤에 다시」로 거절된 요청도 다음 5분 창을 다시 연다(기다리는 시간이 계속 늘어난다),
--   5분 안에 5번 누르면 24시간 창이 5건으로 차서 하루 동안 잠긴다 — 실제로 메일은 1통만 나갔는데.
--
-- 바꾸는 것:
--   ① 기록 표에 allowed 칸(허용 여부)을 더한다. 기존 행은 기본값 true(보수적 — 30일 뒤 정리로 사라진다).
--   ② 이메일별 창 두 개는 allowed = true 인 행만 센다. 기록은 지금처럼 항상 남긴다(243 설계 — 감사용).
--   ③ 전역(시간당 30건) 창은 그대로 둔다 — 이번 결정 범위 밖.
--
-- 범위: 브랜드만(2026-10-20 사용자 결정). 관리자 쪽 243 은 같은 구조지만 건드리지 않는다.
-- 함수 이름·인자·반환이 같아 CREATE OR REPLACE 로 실행 권한이 보존된다. 서버 함수(brand-password-reset-request) 수정 불필요.
--
-- 적용: 🔴 개발서버만. 운영은 브랜드 묶음(526 → … 순서)과 함께 — 526·527 이 운영에 없으면 이 파일은 실패한다.

ALTER TABLE public.brand_password_reset_requests
  ADD COLUMN IF NOT EXISTS allowed boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.brand_password_reset_requests.allowed IS
  '[569] 이 요청이 허용(메일 발송 단계로 진행)됐는지. 이메일별 제한 창은 true 인 행만 센다 — 거절된 요청이 대기 시간을 늘리지 않게.';

CREATE OR REPLACE FUNCTION public.check_brand_password_reset_rate_limit(
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
  PERFORM pg_advisory_xact_lock(hashtext('brand_password_reset_rate_limit'));

  -- 이메일별 5분 1회 — 허용된 요청만 센다(569)
  SELECT count(*) INTO v_short_count
    FROM public.brand_password_reset_requests
   WHERE email_hash = p_email_hash
     AND allowed
     AND requested_at > now() - interval '5 minutes';
  IF v_short_count > 0 THEN
    v_allowed := false;
  END IF;

  -- 이메일별 24시간 5회 — 허용된 요청만 센다(569)
  IF v_allowed THEN
    SELECT count(*) INTO v_day_count
      FROM public.brand_password_reset_requests
     WHERE email_hash = p_email_hash
       AND allowed
       AND requested_at > now() - interval '24 hours';
    IF v_day_count >= 5 THEN
      v_allowed := false;
    END IF;
  END IF;

  -- 전역 시간당 30건 — 527 그대로(모든 요청)
  IF v_allowed THEN
    SELECT count(*) INTO v_global_count
      FROM public.brand_password_reset_requests
     WHERE requested_at > now() - interval '1 hour';
    IF v_global_count >= 30 THEN
      v_allowed := false;
      RAISE WARNING '[check_brand_password_reset_rate_limit] global rate limit exceeded (count=%)', v_global_count;
    END IF;
  END IF;

  INSERT INTO public.brand_password_reset_requests (email_hash, matched, requested_at, allowed)
  VALUES (p_email_hash, p_matched, now(), v_allowed);

  RETURN v_allowed;
END;
$$;

COMMENT ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) IS
  '[569 ← 527] 브랜드 비밀번호 찾기 요청 제한 판정. 이메일별 5분1회·24시간5회(허용된 요청만 셈) + 전역 시간당30건(모든 요청)을 원자적으로 판정하고, 결과와 함께 항상 기록. service_role 전용.';

-- 527 과 같은 권한(CREATE OR REPLACE 라 보존되지만 멱등으로 다시 건다)
GRANT  EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) FROM anon, authenticated;
