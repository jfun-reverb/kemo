-- ============================================================
-- 166_influencer_flags_retention.sql
-- 2026-06-02
--
-- 목적:
--   개인정보처리방침에 명시된 「부정이용·위반 기록(노쇼·블랙리스트·위반 마킹) 3년 보관」
--   정책을 실제로 집행하기 위한 자동 정리 함수 + pg_cron 등록.
--
--   현재 influencer_flags 테이블은 자동 삭제 로직이 없어 사실상 영구 보관 중.
--   방침 상 3년이 경과한 이력 행은 삭제해야 한다.
--
-- 변경 사항:
--   1. public.purge_old_influencer_flags() 함수 신규 생성
--      - set_at 기준 36개월(3년) 이전 행 DELETE
--      - SECURITY DEFINER + SET search_path = '' (권한 탈취 방어)
--      - 삭제 건수를 RETURN integer + RAISE NOTICE 로 기록
--      - 일반 사용자 EXECUTE 권한 부여 금지 (cron job 이 postgres role 로 실행)
--   2. pg_cron 등록
--      - job 이름: 'influencer-flags-retention-daily'
--      - 주기: 매일 UTC 19:00 (= KST 04:00)
--      - 중복 등록 방지: cron.unschedule 후 재등록
--
-- 실행 빈도 근거:
--   정확히 3년이 된 행을 당일에 삭제해야 할 강제 이유는 없음. 「매일 1회」이면
--   최대 24시간 오차가 발생하지만 개인정보보호법(PIPA/APPI) 이행에 충분한 정밀도.
--   새벽 04:00 KST(UTC 19:00)는 플랫폼 트래픽 최저점 — 삭제 IO가 서비스 응답에
--   미치는 영향 최소화. 기존 다이제스트 메일 cron (KST 09:00 UTC 00:00) 과
--   시간대 분산으로 cron worker 경합도 줄임.
--
-- 주의:
--   - pg_cron 은 이미 프로젝트에서 다이제스트 메일 등으로 가동 중 (extension 설치됨)
--   - cron.schedule() 의 job 이름이 같으면 이미 등록된 schedule 이 덮어써짐.
--     본 파일은 unschedule → schedule 명시적 재등록 방식으로 멱등 처리.
--   - influencer_flags 행이 삭제되면 ON DELETE CASCADE 없음 — FK 부모(influencers)는
--     영향 없음. 자식 테이블 참조 없음 (이 테이블이 이력 테이블 자체이므로).
--
-- 롤백:
--   SELECT cron.unschedule('influencer-flags-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_old_influencer_flags();
-- ============================================================


-- ============================================================
-- Step 1: 정리 함수 생성
--   - set_at 기준 36개월 이전 행 DELETE
--   - SECURITY DEFINER + SET search_path = '' 필수
--   - 삭제 건수 RETURN + RAISE NOTICE (cron 로그에서 확인 가능)
--   - EXECUTE 권한: postgres role 만 (cron job 전용). public/authenticated 부여 금지.
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_old_influencer_flags()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff    timestamptz;
  v_deleted   integer;
BEGIN
  -- 3년(36개월) 이전 기준 시각
  v_cutoff := now() - interval '36 months';

  DELETE FROM public.influencer_flags
  WHERE set_at < v_cutoff;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_old_influencer_flags] cutoff=% deleted=% rows', v_cutoff, v_deleted;

  RETURN v_deleted;
END;
$$;

-- 모든 사용자 권한 박탈 후 postgres role 만 허용
-- (pg_cron 은 postgres role 로 SQL 실행)
REVOKE ALL ON FUNCTION public.purge_old_influencer_flags() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_old_influencer_flags() TO postgres;


-- ============================================================
-- Step 2: pg_cron 등록
--   기존 동명 job 이 있으면 먼저 해제 후 재등록 (멱등 처리)
--   주기: '0 19 * * *' = 매일 UTC 19:00 = KST 04:00
-- ============================================================

-- 중복 등록 방지: 이미 등록된 동명 job 을 먼저 해제
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'influencer-flags-retention-daily';

SELECT cron.schedule(
  'influencer-flags-retention-daily',   -- job 이름 (고유 식별자)
  '0 19 * * *',                         -- 매일 UTC 19:00 (= KST 04:00)
  $$
  SELECT public.purge_old_influencer_flags();
  $$
);

COMMENT ON FUNCTION public.purge_old_influencer_flags() IS
  '[166] 개인정보처리방침 3년 보관 정책 집행. '
  'influencer_flags.set_at 기준 36개월 경과 행 삭제. '
  'SECURITY DEFINER, cron/postgres 전용. 삭제 건수 반환 + RAISE NOTICE. '
  'pg_cron job: influencer-flags-retention-daily (매일 KST 04:00 = UTC 19:00).';


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor 에서 실행, 1단계씩)
-- ============================================================

-- [1단계] 함수 존재 + SECURITY DEFINER 확인
-- SELECT proname, prosecdef, pronargs
--   FROM pg_proc
--  WHERE proname = 'purge_old_influencer_flags'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1건, prosecdef = true

-- [2단계] cron job 등록 확인
-- SELECT jobid, jobname, schedule, command, active
--   FROM cron.job
--  WHERE jobname = 'influencer-flags-retention-daily';
-- 기대: 1건, schedule = '0 19 * * *', active = true

-- [3단계] 함수 수동 호출 테스트 (postgres role 로 실행)
-- SELECT public.purge_old_influencer_flags();
-- 기대: 정수 반환 (현재 3년 이상 된 행이 없으면 0)
-- 동시에 Supabase 대시보드 Logs > Database 에서 NOTICE 확인 가능

-- ============================================================
-- 롤백 방법
-- ============================================================
-- 1. cron job 해제
--    SELECT cron.unschedule('influencer-flags-retention-daily');
--
-- 2. 함수 제거
--    DROP FUNCTION IF EXISTS public.purge_old_influencer_flags();
