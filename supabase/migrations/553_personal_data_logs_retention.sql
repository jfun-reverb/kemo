-- ============================================================
-- 553_personal_data_logs_retention.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1 — 552 바로 뒤)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 P2」
-- 사양서 docs/specs/2026-10-19-personal-data-access-records.md ② 결정 3(보관 기간)
--   선행: 552(표 brand_provision_logs · personal_data_access_logs)
--
-- 하는 일
--   ① purge_expired_personal_data_logs() — 보관 기간 지난 기록 줄을 지운다
--        brand_provision_logs      : at 이 3년보다 오래된 줄 (브랜드 제공 기록)
--        personal_data_access_logs : at 이 1년보다 오래된 줄 (관리자 접속 기록)
--      반환 {provision_deleted, access_deleted}.
--      지우는 것은 「기록 표의 오래된 줄」뿐이다 — 회원 정보·응모·결과물은 건드리지 않는다.
--   ② 예약 personal-data-logs-retention-daily — 매일 UTC 18:00(= 도쿄·서울 03:00)
--      ⚠️ 작업표 예시 03:45(UTC 18:45)는 423(digest-email-sent 정리)이 쓰고 있어 피했다.
--         저장소 예약 시각(UTC): 18:15·18:30·18:45·19:00·19:15·19:30(셋)·19:45·20:00·20:15·20:30·20:45·21:00·00:00 — 18:00 비어 있음.
--      ⚠️ 메일을 보내지 않는 정리라 개발·운영 **양쪽**에 등록한다(365·496 선례).
--
-- 기준 시각
--   at(기록이 생긴 시각) 하나. 552 의 30분 합치기(D16)는 at 을 바꾸지 않으므로(처음 본 시각 그대로)
--   합쳐진 줄도 처음 본 날부터 3년이다 — 늦게 덧붙인 사람이 그만큼 일찍 지워지는 쪽(최대 30분)이라 문제 삼지 않는다.
--   보관 「3년」·「1년」은 달력 기준 interval(윤년 포함). 🔴 숫자를 바꾸려면 개인정보처리방침이 먼저다(L1 방침 개정 조각).
--
-- 편집기 경고: 「destructive operation」 확인 창이 뜰 수 있다(DELETE 가 함수 본문에 있다 — 적용만으로는 아무것도 안 지운다).
--
-- 롤백(지운 줄은 되돌릴 수 없다 — 예약만 멈춘다)
--   SELECT cron.unschedule('personal-data-logs-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_expired_personal_data_logs();
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_expired_personal_data_logs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_provision_cutoff timestamptz := now() - interval '3 years';
  v_access_cutoff    timestamptz := now() - interval '1 year';
  v_provision        integer;
  v_access           integer;
BEGIN
  DELETE FROM public.brand_provision_logs WHERE at < v_provision_cutoff;
  GET DIAGNOSTICS v_provision = ROW_COUNT;

  DELETE FROM public.personal_data_access_logs WHERE at < v_access_cutoff;
  GET DIAGNOSTICS v_access = ROW_COUNT;

  RAISE NOTICE '[purge_expired_personal_data_logs] provision cutoff=% deleted=% / access cutoff=% deleted=%',
    v_provision_cutoff, v_provision, v_access_cutoff, v_access;
  RETURN jsonb_build_object('provision_deleted', v_provision, 'access_deleted', v_access);
END;
$$;

COMMENT ON FUNCTION public.purge_expired_personal_data_logs() IS
  '[553·P2] 개인정보 기록 보관 기간 파기 — brand_provision_logs 3년 · personal_data_access_logs 1년(at 기준). '
  'postgres(예약 실행) 전용. 반환 {provision_deleted, access_deleted}. pg_cron: personal-data-logs-retention-daily (매일 UTC 18:00 = 도쿄 03:00).';

-- postgres 만(496·519 방식 + 369 의 두 방향 회수)
GRANT  EXECUTE ON FUNCTION public.purge_expired_personal_data_logs() TO postgres;
REVOKE EXECUTE ON FUNCTION public.purge_expired_personal_data_logs() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_expired_personal_data_logs() FROM anon, authenticated, service_role;

-- 중복 등록 방지: 같은 이름이 있으면 먼저 해제 후 재등록(166 방식)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'personal-data-logs-retention-daily';

SELECT cron.schedule(
  'personal-data-logs-retention-daily',
  '0 18 * * *',                          -- 매일 UTC 18:00 (= 도쿄 03:00)
  $$
  SELECT public.purge_expired_personal_data_logs();
  $$
);

-- ------------------------------------------------------------
-- 검증 (1단계씩 — 개발서버에서 먼저)
-- ------------------------------------------------------------
-- [0] 적용 전: 18:00 을 쓰는 다른 예약이 없는지 (기대: 0행)
-- SELECT jobname, schedule FROM cron.job WHERE schedule = '0 18 * * *' AND jobname <> 'personal-data-logs-retention-daily';
-- [1] 예약 등록 — 1건, schedule = '0 18 * * *', active = true
-- SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'personal-data-logs-retention-daily';
-- [2] 실행 권한 — anon·authenticated·service_role 모두 false, acl 맨 앞에 `=X/` 없음
-- SELECT has_function_privilege('anon', p.oid, 'EXECUTE') a, has_function_privilege('authenticated', p.oid, 'EXECUTE') u,
--        has_function_privilege('service_role', p.oid, 'EXECUTE') s, p.proacl::text
--   FROM pg_proc p WHERE p.proname = 'purge_expired_personal_data_logs';
-- [3] 시험 줄 넷(기간 안·밖 × 두 표)을 넣고 한 번 부른다 — 기대 {provision_deleted:1, access_deleted:1}, 남은 시험 줄은 기간 안 둘
--     (시험 줄 표시: brand_provision_logs.campaign_no = 'ZZ-P2-TEST' · personal_data_access_logs.source = 'zz-p2-test')
-- INSERT INTO public.brand_provision_logs (at, campaign_no, actor_kind, actor_name, action)
--   VALUES (now() - interval '3 years 1 day', 'ZZ-P2-TEST', 'system', 'old', 'shipping_auto_add'),
--          (now() - interval '3 years' + interval '1 day', 'ZZ-P2-TEST', 'system', 'keep', 'shipping_auto_add');
-- INSERT INTO public.personal_data_access_logs (at, source, actor_name)
--   VALUES (now() - interval '1 year 1 day', 'zz-p2-test', 'old'),
--          (now() - interval '1 year' + interval '1 day', 'zz-p2-test', 'keep');
-- SELECT public.purge_expired_personal_data_logs();
-- SELECT 'p' t, actor_name FROM public.brand_provision_logs WHERE campaign_no = 'ZZ-P2-TEST'
-- UNION ALL SELECT 'a', actor_name FROM public.personal_data_access_logs WHERE source = 'zz-p2-test';   -- 기대: keep 둘
-- [4] 시험 줄 정리
-- DELETE FROM public.brand_provision_logs WHERE campaign_no = 'ZZ-P2-TEST';
-- DELETE FROM public.personal_data_access_logs WHERE source = 'zz-p2-test';
