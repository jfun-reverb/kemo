-- ============================================================
-- 203_brand_daily_digest.sql
-- 2026-06-30
--
-- 목적:
--   브랜드 일일 보고(notify-brand-daily-digest, PR 2) 인프라 구축.
--   사양서: docs/specs/2026-06-30-orient-submit-notification.md §4, §10 PR 2
--
-- 변경 2가지:
--   [1] brand_daily_digest_runs 테이블 — admin_daily_digest_runs(마이그레이션 132)
--       패턴 복제: digest_date UNIQUE(mutex) + status CHECK + sections_summary jsonb
--       + recipients_count + error_message + run_at.
--       RLS SELECT is_admin(), INSERT/UPDATE는 Edge Function service_role만 우회.
--
--   [2] lookup_values 시드 1행
--       kind='admin_email_kind', code='brand_digest', sort_order=50 (active)
--       → 관리자 「메일 받기 설정」 모달에 토글 자동 노출 (앱 코드 수정 불필요)
--       → Edge Function 수신자 조회: get_subscribed_admin_emails('brand_digest')
--
-- ⚠️ pg_cron 등록은 본 마이그레이션에 포함하지 않는다.
--    cron 등록은 수동 호출(curl) 안정성 검증 후 별도 단계.
--    사양서 §10 + supabase.md 「메일 발송 테스트 환경 정책」 참조.
--
-- 기존 sort_order 현황 (admin_email_kind):
--   10  brand_notify       브랜드 서베이 접수       (마이그레이션 103)
--   20  daily_digest       일일 통합 메일            (마이그레이션 164)
--   30  application_received 캠페인 신청 접수(비활성) (마이그레이션 130, 164에서 통합)
--   40  campaign_promo     캠페인 홍보 메일          (마이그레이션 152)
--   50  brand_digest       브랜드 일일 보고          ← 신규
--
-- 롤백:
--   DROP TABLE IF EXISTS public.brand_daily_digest_runs;
--   DELETE FROM public.lookup_values WHERE kind = 'admin_email_kind' AND code = 'brand_digest';
-- ============================================================


-- ============================================================
-- [1] brand_daily_digest_runs 테이블
--     admin_daily_digest_runs(마이그레이션 132) 와 동일 패턴
-- ============================================================
CREATE TABLE IF NOT EXISTS public.brand_daily_digest_runs (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date      date        NOT NULL UNIQUE,
  status           text        NOT NULL CHECK (status IN ('sent', 'skipped_no_data', 'failed')),
  sections_summary jsonb,
  recipients_count integer     NOT NULL DEFAULT 0,
  error_message    text,
  run_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.brand_daily_digest_runs IS
  '브랜드 일일 보고(notify-brand-daily-digest) 발송 로그. '
  'digest_date UNIQUE 로 cron 중복 호출 차단 + INSERT 선행 mutex. '
  'sections_summary: {"new_submitted": N, "resubmitted": N}. '
  '(마이그레이션 203, 2026-06-30)';
COMMENT ON COLUMN public.brand_daily_digest_runs.digest_date IS
  '집계 대상 한국시간(KST) 날짜 (어제). UNIQUE — cron 중복 호출 자동 차단.';
COMMENT ON COLUMN public.brand_daily_digest_runs.status IS
  'sent (정상 발송) / skipped_no_data (2섹션 모두 0건) / failed (오류 또는 in-flight 크래시).';
COMMENT ON COLUMN public.brand_daily_digest_runs.sections_summary IS
  '2섹션 건수 {"new_submitted": N, "resubmitted": N}';
COMMENT ON COLUMN public.brand_daily_digest_runs.recipients_count IS
  '메일 발송 대상 관리자 수 (구독자 합집합 + env 외부 수신자).';


-- ============================================================
-- [2] 행 단위 보안 정책 (RLS)
--     SELECT 만 관리자, INSERT/UPDATE/DELETE 는 Edge Function service_role 만(정책 없음=우회)
-- ============================================================
ALTER TABLE public.brand_daily_digest_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS brand_daily_digest_runs_select ON public.brand_daily_digest_runs;
CREATE POLICY brand_daily_digest_runs_select
  ON public.brand_daily_digest_runs FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- [3] lookup_values 시드 — admin_email_kind 에 brand_digest 추가
--
--   ON CONFLICT DO NOTHING: 재실행 안전 (멱등)
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES (
  'admin_email_kind',
  'brand_digest',
  '브랜드 일일 보고',
  'ブランド日次報告',
  50,
  true
)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- 검증 쿼리 (적용 후 실행):
--
-- [1] 테이블 존재 확인
-- SELECT to_regclass('public.brand_daily_digest_runs');
-- 기대값: brand_daily_digest_runs
--
-- [2] UNIQUE 제약 + CHECK 제약 확인
-- SELECT conname, contype, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid = 'public.brand_daily_digest_runs'::regclass;
-- 기대값: PK + UNIQUE(digest_date) + CHECK(status) 포함
--
-- [3] 행 단위 보안 정책 확인
-- SELECT polname, polcmd
--   FROM pg_policy
--  WHERE polrelid = 'public.brand_daily_digest_runs'::regclass;
-- 기대값: brand_daily_digest_runs_select / r (SELECT)
--
-- [4] lookup 신규 행 확인
-- SELECT code, name_ko, sort_order, active
--   FROM public.lookup_values
--  WHERE kind = 'admin_email_kind'
--  ORDER BY sort_order;
-- 기대값: brand_digest sort_order=50 active=true 포함 5행
-- ============================================================
