-- ============================================================
-- 130_application_email_pipeline_infra.sql
-- 2026-05-18
--
-- 목적:
--   응모 단계별 메일 파이프라인 (인플루언서 통합 1통 + 관리자 접수 요약 1통)
--   인프라 구축. Edge Function 2개 (notify-influencer-daily-digest,
--   notify-application-received-admin-daily) 가 사용할 발송 로그·재발송
--   방지 테이블·lookup 시드·기본 구독 시드 일괄 포함.
--
-- 사양서: docs/specs/2026-05-18-application-email-pipeline.md
--          docs/specs/2026-05-18-HANDOFF-application-email-pipeline.md
--
-- ※ 사양서엔 마이그레이션 번호 129 로 적혀 있으나, 같은 날 129 는
--   post_deadline 제거(`129_remove_post_deadline.sql`) 마이그레이션에
--   먼저 사용되어 본 작업은 130 으로 발급.
--
-- 변경 내용:
--   [단계 1] 일별 다이제스트 발송 로그 테이블 2종 (digest_date UNIQUE)
--            - influencer_daily_digest_runs
--            - application_received_admin_digest_runs
--   [단계 2] 마감일 임박 메일 재발송 방지 로그
--            - deadline_reminder_email_sent
--              UNIQUE (influencer_id, campaign_id, kind, d_minus)
--   [단계 3] 3개 테이블 RLS — admin SELECT 만, INSERT/UPDATE 는 service_role 직접
--   [단계 4] lookup_values 시드: admin_email_kind = application_received
--   [단계 5] admin_email_subscriptions 기본 ON 시드 (전체 관리자)
--   [단계 6] 헬퍼 함수 _yesterday_kst_window() (옵션, Edge Function 안에서
--            JS 로도 계산 가능하므로 SQL 디버깅·테스트 편의용)
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 테이블 3개 부재 → 존재 확인
--   SELECT table_name FROM information_schema.tables
--    WHERE table_schema = 'public'
--      AND table_name IN ('influencer_daily_digest_runs',
--                         'application_received_admin_digest_runs',
--                         'deadline_reminder_email_sent');
--   -- 기대값: 3 row
--
--   -- [2] lookup 시드 확인
--   SELECT code, name_ko FROM public.lookup_values
--    WHERE kind = 'admin_email_kind' AND code = 'application_received';
--   -- 기대값: 1 row (application_received / 캠페인 신청 접수)
--
--   -- [3] 관리자 구독 시드 확인 (전체 관리자 수와 일치해야 함)
--   SELECT count(*) AS subscribed,
--          (SELECT count(*) FROM public.admins) AS total_admins
--     FROM public.admin_email_subscriptions
--    WHERE mail_kind = 'application_received';
--   -- 기대값: subscribed >= total_admins (기존 다른 시드와 같은 수)
--
--   -- [4] 헬퍼 함수 동작 확인
--   SELECT * FROM public._yesterday_kst_window();
--   -- 기대값: 1 row (어제 KST 윈도우 + 오늘 KST 날짜)
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;


-- ============================================================
-- 단계 1: 일별 다이제스트 발송 로그 2종
--   notify-application-cancelled-daily 의 application_cancel_digest_runs
--   동일 패턴.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.influencer_daily_digest_runs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date         date NOT NULL UNIQUE,
  run_at              timestamptz NOT NULL DEFAULT now(),
  status              text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed')),
  total_influencers   integer NOT NULL DEFAULT 0,
  total_emails        integer NOT NULL DEFAULT 0,
  error_message       text
);

COMMENT ON TABLE public.influencer_daily_digest_runs IS
  '[130] 인플루언서 일일 다이제스트 메일 발송 로그. digest_date UNIQUE 로 cron 중복 호출 차단';

CREATE TABLE IF NOT EXISTS public.application_received_admin_digest_runs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date         date NOT NULL UNIQUE,
  run_at              timestamptz NOT NULL DEFAULT now(),
  status              text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed')),
  total_applications  integer NOT NULL DEFAULT 0,
  recipient_count     integer NOT NULL DEFAULT 0,
  error_message       text
);

COMMENT ON TABLE public.application_received_admin_digest_runs IS
  '[130] 캠페인 신청 접수 관리자 일일 요약 메일 발송 로그. digest_date UNIQUE';


-- ============================================================
-- 단계 2: 마감일 임박 메일 재발송 방지 로그
--   UNIQUE (influencer_id, campaign_id, kind, d_minus) 로
--   같은 인플루언서·캠페인·종류·D-N 조합 중복 발송 차단.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.deadline_reminder_email_sent (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id   uuid NOT NULL,
  campaign_id     uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('receipt','post')),
  d_minus         integer NOT NULL CHECK (d_minus IN (5,1)),
  sent_at         timestamptz NOT NULL DEFAULT now(),
  deadline_date   date NOT NULL,
  UNIQUE (influencer_id, campaign_id, kind, d_minus)
);

COMMENT ON TABLE public.deadline_reminder_email_sent IS
  '[130] 영수증·결과물 마감 임박(D-5/D-1) 메일 재발송 방지 로그. UNIQUE 4-tuple';

-- influencer_id 는 auth.users(id) 를 가리키나, applications.user_id 도 동일
-- 외래 키. ON DELETE 정책 일관성을 위해 명시 외래 키 생략 (auth.users
-- 직접 참조 시 RLS·소유권 제약 복잡) — 대신 인플루언서 삭제 시 cascade
-- 는 applications/influencers 측에서 처리.

CREATE INDEX IF NOT EXISTS idx_deadline_reminder_email_lookup
  ON public.deadline_reminder_email_sent (campaign_id, kind);

CREATE INDEX IF NOT EXISTS idx_deadline_reminder_email_influencer
  ON public.deadline_reminder_email_sent (influencer_id);


-- ============================================================
-- 단계 3: RLS — 3개 테이블 모두 admin SELECT 만 허용
--   INSERT/UPDATE/DELETE 정책 미정의 → service_role 직접 INSERT 만
--   (Edge Function 가 service_role 키로 작동, RLS 우회).
-- ============================================================

ALTER TABLE public.influencer_daily_digest_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.application_received_admin_digest_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deadline_reminder_email_sent ENABLE ROW LEVEL SECURITY;

-- 멱등 정책 작성 — DROP 후 CREATE
DROP POLICY IF EXISTS infl_digest_runs_admin_select ON public.influencer_daily_digest_runs;
CREATE POLICY infl_digest_runs_admin_select ON public.influencer_daily_digest_runs
  FOR SELECT TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS app_recv_admin_digest_runs_admin_select ON public.application_received_admin_digest_runs;
CREATE POLICY app_recv_admin_digest_runs_admin_select ON public.application_received_admin_digest_runs
  FOR SELECT TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS deadline_reminder_admin_select ON public.deadline_reminder_email_sent;
CREATE POLICY deadline_reminder_admin_select ON public.deadline_reminder_email_sent
  FOR SELECT TO authenticated
  USING (public.is_admin());


-- ============================================================
-- 단계 4: lookup_values 시드 — admin_email_kind 에 application_received 추가
--   관리자 메일 수신 설정 모달에 「캠페인 신청 접수」 항목 자동 노출.
-- ============================================================

INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('admin_email_kind', 'application_received', '캠페인 신청 접수', 'キャンペーン応募受付', 30, true)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- 단계 5: 관리자 메일 기본 구독 시드 — 전체 관리자에게 application_received ON
--   사용자 결정: 「관리자 application_received 수신 기본값 = 전체 ON」.
-- ============================================================

-- admin_email_subscriptions.admin_id 는 admins.id (PK) 외래 키 — auth_id 아님 (migration 103 정의)
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind)
SELECT a.id, 'application_received'
FROM public.admins a
ON CONFLICT (admin_id, mail_kind) DO NOTHING;


-- ============================================================
-- 단계 6: 헬퍼 함수 — 어제 한국시간 윈도우 (디버깅·테스트용)
--   Edge Function 안에서는 JS 로 직접 계산하지만, SQL Editor 에서
--   쿼리 검증 시 같은 윈도우를 반환하는 함수가 있으면 편함.
--   STABLE 마킹 (같은 트랜잭션 안에서 동일 값 반환 보장).
-- ============================================================

CREATE OR REPLACE FUNCTION public._yesterday_kst_window()
RETURNS TABLE (window_start timestamptz, window_end timestamptz, digest_date date, today_date date)
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::timestamp AT TIME ZONE 'Asia/Seoul' AS window_start,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::timestamp     AT TIME ZONE 'Asia/Seoul' AS window_end,
    ((now() AT TIME ZONE 'Asia/Seoul')::date - 1)::date      AS digest_date,
    ((now() AT TIME ZONE 'Asia/Seoul')::date)::date          AS today_date;
$$;

COMMENT ON FUNCTION public._yesterday_kst_window() IS
  '[130] 어제 한국시간 윈도우(timestamptz 2개) + 어제·오늘 KST 날짜 반환. Edge Function 디버깅·테스트 편의용';


COMMIT;


-- ============================================================
-- 검증 NOTICE (트랜잭션 외부)
-- ============================================================
DO $$
DECLARE
  v_admin_count   integer;
  v_sub_count     integer;
BEGIN
  SELECT count(*) INTO v_admin_count FROM public.admins;
  SELECT count(*) INTO v_sub_count
    FROM public.admin_email_subscriptions
   WHERE mail_kind = 'application_received';
  RAISE NOTICE '[130] influencer_daily_digest_runs 생성 완료';
  RAISE NOTICE '[130] application_received_admin_digest_runs 생성 완료';
  RAISE NOTICE '[130] deadline_reminder_email_sent 생성 완료 (UNIQUE 4-tuple + 2개 인덱스)';
  RAISE NOTICE '[130] RLS 정책 3개 추가 (admin SELECT)';
  RAISE NOTICE '[130] lookup_values 시드 application_received 추가';
  RAISE NOTICE '[130] admin_email_subscriptions 기본 구독 시드 — 관리자 % 명 중 % 명 구독', v_admin_count, v_sub_count;
  RAISE NOTICE '[130] _yesterday_kst_window() 헬퍼 함수 등록';
END;
$$;


-- ============================================================
-- 롤백 (적용 취소 시 아래 실행)
-- ============================================================
/*

BEGIN;

-- [1] 헬퍼 함수
DROP FUNCTION IF EXISTS public._yesterday_kst_window();

-- [2] 관리자 구독 시드 제거 (다른 mail_kind 는 보존)
DELETE FROM public.admin_email_subscriptions WHERE mail_kind = 'application_received';

-- [3] lookup 시드 제거
DELETE FROM public.lookup_values WHERE kind = 'admin_email_kind' AND code = 'application_received';

-- [4] 발송 로그 테이블 3종 DROP (CASCADE — RLS 정책 자동 제거)
DROP TABLE IF EXISTS public.deadline_reminder_email_sent CASCADE;
DROP TABLE IF EXISTS public.application_received_admin_digest_runs CASCADE;
DROP TABLE IF EXISTS public.influencer_daily_digest_runs CASCADE;

COMMIT;

*/
