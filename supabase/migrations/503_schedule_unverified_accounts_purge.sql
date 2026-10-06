-- ============================================================
-- 503_schedule_unverified_accounts_purge.sql
-- 회원가입 이메일 인증번호 — 사양서 단계 3 「미인증 계정 정기 삭제 예약 켜기」
--   선행: 498(purge_unverified_accounts — 함수만, 예약 없음)
--   사양서 docs/specs/2026-10-01-signup-email-code-verification.md 설계 ⑤ · 단계 3
--
-- 왜 지금: 개인정보처리방침 개정(공고 2026-10-06 · 시행 2026-10-13)이
--   「인증 전 가입 신청은 7일 지나면 파기」를 약속한다 → 시행일부터 실제로 돌아야 한다.
--
-- 🔴 운영 적용 순서(단계 3 — 시행일 2026-10-13, 가입 화면 운영 반영 #1892 병합 뒤)
--   ① 스위치 강제:   UPDATE public.signup_code_settings SET mode = 'enforce' WHERE id = 1;
--   ② 운영 실제 가입 1회(새 화면) + 기존 회원 로그인 1회
--   ③ 아래 [V1] 대상 조회 — 지워질 계정 수·건너뛸 계정(다른 기록 있음) 수를 사람이 본다
--   ④ 수동 첫 실행:  SELECT public.purge_unverified_accounts();  → [V2] 실행 기록 확인
--      ⚠️ SQL 편집기 역할이 postgres 여야 한다(498 이 service_role 실행 권한을 회수했다)
--   ⑤ 직전 확인 [V0] — 같은 이름 예약 0행 · UTC 20:45 에 다른 예약 없음(저장소 밖 직접 등록 대비)
--   ⑥ 이 파일 실행(예약 등록) → [V3]
--   문제가 나면 스위치를 대기로 되돌려 가입을 살린 뒤 고친다(사양서 경우의 수 2)
--
-- 시각: 매일 UTC 20:45 = 도쿄 05:45(작업표 선결 9 — 양쪽 서버 cron.job 빈 자리 확인한 시각).
--   번호 기록 정리(496, UTC 18:15)와 겹치지 않는다.
--
-- 편집기 경고: 안 뜸(cron.unschedule·cron.schedule 은 경고 단어가 아니다).
--   단 예약이 돌면 실제로 계정을 지운다 — 그래서 ③·④를 먼저 한다.
--
-- 롤백(예약만 끈다 — 함수·지운 계정은 그대로)
--   SELECT cron.unschedule('unverified-accounts-purge-daily');
-- ============================================================

-- 중복 등록 방지: 같은 이름이 있으면 먼저 해제 후 재등록(166·496 방식)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'unverified-accounts-purge-daily';

SELECT cron.schedule(
  'unverified-accounts-purge-daily',
  '45 20 * * *',                         -- 매일 UTC 20:45 (= 도쿄 05:45)
  $$
  SELECT public.purge_unverified_accounts();
  $$
);

-- ------------------------------------------------------------
-- 검증 (1단계씩)
-- ------------------------------------------------------------
-- [V0] 적용 직전 — 둘 다 0행이어야 한다
-- SELECT jobname FROM cron.job WHERE jobname = 'unverified-accounts-purge-daily';
-- SELECT jobname, schedule FROM cron.job WHERE schedule LIKE '45 20 %';
--
-- [V1] 실행 전 대상 조회 — has_records = true 는 건너뛴다(지우지 않는다)
-- SELECT u.id, u.email, u.created_at, u.confirmation_sent_at,
--        public._signup_unverified_has_records(u.id) AS has_records
--   FROM auth.users u
--  WHERE u.email_confirmed_at IS NULL
--    AND coalesce(u.confirmation_sent_at, u.created_at)
--        < now() - make_interval(days => (SELECT unverified_purge_days FROM public.signup_code_settings WHERE id = 1))
--    AND NOT EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = u.id)
--    AND NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = u.id AND i.is_audit)
--  ORDER BY u.created_at;
--
-- [V2] 실행 기록 — 지운 건수·건너뛴 건수·오류
-- SELECT run_at, deleted_count, skipped_count, skipped_ids, error_message
--   FROM public.unverified_account_purge_runs ORDER BY run_at DESC LIMIT 5;
--
-- [V3] 예약 등록 — 1건, schedule = '45 20 * * *', active = true
-- SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'unverified-accounts-purge-daily';
--
-- [V4] 다음 날 아침 — 예약 실행 결과(성공 여부)
-- SELECT status, return_message, start_time FROM cron.job_run_details
--  WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'unverified-accounts-purge-daily')
--  ORDER BY start_time DESC LIMIT 3;
