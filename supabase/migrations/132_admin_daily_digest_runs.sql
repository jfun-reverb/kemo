-- ============================================================
-- 132_admin_daily_digest_runs.sql
-- 2026-05-18
--
-- 목적:
--   관리자 일일 통합 다이제스트(notify-admin-daily-digest, PR 2) 의
--   발송 로그 테이블 신설. digest_date UNIQUE 로 cron 중복 호출 차단 +
--   INSERT 선행 동시성 패턴 (mutex 역할) 의 핵심 인프라.
--
-- 사양서:
--   docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§14 (확정)
--   docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §5-3
--
-- 컬럼 명명 (supabase-expert 검증 반영):
--   - status='failed' (기존 cancel 113 / received 130 패턴 승계, 'error' 아님)
--   - run_at (130 패턴, ran_at 아님)
--   - recipients_count NOT NULL DEFAULT 0 (신규 cancel 113 패턴 일치 — 130 의 recipient_count 단수 표기와 다름)
--
-- 동시성 패턴 (Edge Function 구현):
--   1. status='failed' 로 INSERT 시도 (digest_date UNIQUE 가 mutex)
--   2. 23505 = 이미 처리됨 → 즉시 종료 (메일 중복 발송 차단)
--   3. INSERT 성공 → 데이터 조회 + 메일 발송
--   4. UPDATE 로 status='sent' + sections_summary + recipients_count 갱신
--   5. 메일 발송 실패 시 status='failed' 유지 + error_message UPDATE
--
-- sections_summary jsonb 구조:
--   {"received": N, "cancelled": N, "submitted": N, "reprocessed": N}
--   4섹션 모두 0 이면 메일 미발송 + status='skipped_no_data'
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 테이블 존재
--   SELECT to_regclass('public.admin_daily_digest_runs');
--   -- 기대값: admin_daily_digest_runs
--
--   -- [2] UNIQUE 제약 + CHECK 제약 확인
--   SELECT conname, contype, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.admin_daily_digest_runs'::regclass;
--   -- 기대값: 4행 (PK + UNIQUE(digest_date) + CHECK(status) + (NOT NULL 제약 4종은 attnotnull 별도 확인))
--
--   -- [3] 행 단위 보안 정책
--   SELECT polname, polcmd
--     FROM pg_policy
--    WHERE polrelid = 'public.admin_daily_digest_runs'::regclass;
--   -- 기대값: admin_daily_digest_runs_select / r (SELECT)
--
-- 롤백:
--   DROP TABLE IF EXISTS public.admin_daily_digest_runs;
-- ============================================================


-- ============================================================
-- 1. admin_daily_digest_runs 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_daily_digest_runs (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date      date        NOT NULL UNIQUE,
  status           text        NOT NULL CHECK (status IN ('sent', 'skipped_no_data', 'failed')),
  sections_summary jsonb,
  recipients_count integer     NOT NULL DEFAULT 0,
  error_message    text,
  run_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.admin_daily_digest_runs IS
  '관리자 일일 통합 다이제스트(notify-admin-daily-digest, PR 2) 발송 로그. digest_date UNIQUE 로 cron 중복 호출 차단 + INSERT 선행 mutex.';
COMMENT ON COLUMN public.admin_daily_digest_runs.digest_date IS
  '집계 대상 한국시간(KST) 날짜 (어제). UNIQUE — cron 중복 호출 자동 차단.';
COMMENT ON COLUMN public.admin_daily_digest_runs.status IS
  'sent (정상 발송) / skipped_no_data (4섹션 모두 0건) / failed (오류 또는 in-flight 크래시).';
COMMENT ON COLUMN public.admin_daily_digest_runs.sections_summary IS
  '4섹션 건수 {"received": N, "cancelled": N, "submitted": N, "reprocessed": N}';
COMMENT ON COLUMN public.admin_daily_digest_runs.recipients_count IS
  '메일 발송 대상 관리자 수 (구독자 합집합 + env 외부 수신자).';


-- ============================================================
-- 2. 행 단위 보안 정책 (RLS) — SELECT 만 관리자
--    INSERT/UPDATE/DELETE 는 Edge Function 의 service_role 키만 (RLS 우회)
-- ============================================================
ALTER TABLE public.admin_daily_digest_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_daily_digest_runs_select ON public.admin_daily_digest_runs;
CREATE POLICY admin_daily_digest_runs_select
  ON public.admin_daily_digest_runs FOR SELECT
  USING (is_admin());
