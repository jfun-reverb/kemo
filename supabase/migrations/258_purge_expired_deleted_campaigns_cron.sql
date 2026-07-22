-- ============================================================
-- 258_purge_expired_deleted_campaigns_cron.sql
-- 캠페인 삭제 복구(soft delete) PR 1 — 5/5 (자동 완전삭제 배치)
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md §설계 ⑤
--
-- purge_expired_deleted_campaigns() — 보관(삭제) 처리된 지 30일이 지난 캠페인을
-- 매일 자동으로 완전 삭제하는 배치 함수 + pg_cron 등록.
-- 마이그레이션 166(influencer_flags 3년 보관 정리)·243(관리자 비밀번호 찾기 요청
-- 30일 보관 정리)과 동일한 "SECURITY DEFINER 정리 함수 + postgres 전용 EXECUTE
-- + pg_cron 등록" 패턴.
--
-- 동작:
--   deleted_at < now() - interval '30 days' 인 campaigns 행을 DELETE.
--   반환값 = 삭제 건수(RAISE NOTICE 로도 기록 — Supabase Logs > Database 에서 확인 가능).
--
-- 정산 방어: purge_campaign(257) 과 동일 이유로 별도 재확인 로직 없음(트리거 위임,
--   257 파일 주석 참고). soft_delete_campaign(255) 을 이미 거친 행만 대상이므로
--   이 시점엔 연결된 settlements 가 존재할 수 없다.
--
-- 실행 시각 근거 (다른 보관 정리 cron 과 시간 분산):
--   influencer-flags-retention-daily            = UTC 19:00 (KST 04:00, 166)
--   admin-password-reset-requests-retention-daily = UTC 19:15 (KST 04:15, 243)
--   campaign-soft-delete-purge-daily(본 작업)     = UTC 19:30 (KST 04:30) ← 15분 간격 분산
--   정확히 30일 0시가 된 행을 당일에 지워야 할 강제 이유는 없음 — 매일 1회면
--   최대 24시간 오차가 생기지만 "30일 보관" 정책 이행에 충분한 정밀도.
--
-- 주의:
--   - cron.schedule() 은 job 이름이 같으면 기존 등록을 덮어씀. 본 파일은
--     unschedule → schedule 명시적 재등록으로 멱등 처리(166 패턴).
--   - EXECUTE 권한은 postgres role 에만 부여 — authenticated/anon 에게는 주지
--     않는다(관리자가 이 함수를 직접 호출해 30일을 건너뛰는 경로는 purge_campaign(257,
--     super_admin 전용)로 이미 별도 존재하므로, 이 배치 함수 자체를 앱에 노출할
--     이유가 없다).
--
-- 롤백:
--   SELECT cron.unschedule('campaign-soft-delete-purge-daily');
--   DROP FUNCTION IF EXISTS public.purge_expired_deleted_campaigns();
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_expired_deleted_campaigns()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff   timestamptz;
  v_deleted  integer;
BEGIN
  v_cutoff := now() - interval '30 days';

  DELETE FROM public.campaigns
   WHERE deleted_at IS NOT NULL
     AND deleted_at < v_cutoff;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_expired_deleted_campaigns] cutoff=% deleted=% rows', v_cutoff, v_deleted;

  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_expired_deleted_campaigns() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_expired_deleted_campaigns() TO postgres;

COMMENT ON FUNCTION public.purge_expired_deleted_campaigns() IS
  '[258] 보관 삭제(soft delete) 30일 경과 캠페인 자동 완전삭제. campaigns.deleted_at '
  '기준 30일 경과 행 DELETE. SECURITY DEFINER, cron/postgres 전용. 삭제 건수 반환 + '
  'RAISE NOTICE. pg_cron job: campaign-soft-delete-purge-daily (매일 KST 04:30 = UTC 19:30).';

-- ============================================================
-- pg_cron 등록 (중복 등록 방지: 기존 동명 job 먼저 해제 후 재등록)
-- ============================================================

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'campaign-soft-delete-purge-daily';

SELECT cron.schedule(
  'campaign-soft-delete-purge-daily',   -- job 이름 (고유 식별자)
  '30 19 * * *',                        -- 매일 UTC 19:30 (= KST 04:30)
  $$
  SELECT public.purge_expired_deleted_campaigns();
  $$
);

-- ============================================================
-- 검증 SQL (마이그레이션 후 SQL Editor 에서 실행, 1단계씩)
-- ============================================================

-- [1단계] 함수 존재 + SECURITY DEFINER 확인
-- SELECT proname, prosecdef, pronargs
--   FROM pg_proc
--  WHERE proname = 'purge_expired_deleted_campaigns'
--    AND pronamespace = 'public'::regnamespace;
-- 기대값: 1건, prosecdef = true

-- [2단계] cron job 등록 확인
-- SELECT jobid, jobname, schedule, command, active
--   FROM cron.job
--  WHERE jobname = 'campaign-soft-delete-purge-daily';
-- 기대값: 1건, schedule = '30 19 * * *', active = true

-- [3단계] 함수 수동 호출 테스트 (postgres role 로 SQL Editor 에서 직접 실행 가능 —
--   이 함수는 EXECUTE 권한이 postgres 뿐이라 SQL Editor 세션이 곧 그 role)
-- SELECT public.purge_expired_deleted_campaigns();
-- 기대값: 정수 반환 (현재 30일 이상 보관된 캠페인이 없으면 0)
-- 동시에 Supabase 대시보드 Logs > Database 에서 NOTICE 확인 가능

-- ============================================================
-- 롤백 방법
-- ============================================================
-- 1. cron job 해제
--    SELECT cron.unschedule('campaign-soft-delete-purge-daily');
--
-- 2. 함수 제거
--    DROP FUNCTION IF EXISTS public.purge_expired_deleted_campaigns();
