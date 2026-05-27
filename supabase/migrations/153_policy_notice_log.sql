-- ============================================================
-- 153_policy_notice_log.sql
-- 2026-05-27
--
-- 목적:
--   약관 통지 메일 발송기 (notify-policy-change Edge Function) 의
--   발송 run 로그·인플별 발송 결과 테이블 2종 신설.
--   139_campaign_promo_digest_tables.sql 의 runs/sent 구조를 미러링.
--
-- 신설 테이블:
--   1. policy_notice_runs   — 통지 발송 run 로그 (notice_key UNIQUE → mutex)
--   2. policy_notice_sent   — 인플별 발송 결과 (influencer_id, notice_key UNIQUE → 멱등)
--
-- digest_date(날짜 기준) 와 달리 통지는 사건 단위이므로
-- notice_key text 를 식별자로 사용 (예: 'message_feature_2026').
--
-- 행 단위 보안 정책 (양 테이블):
--   SELECT  is_admin() 한정
--   INSERT/UPDATE/DELETE 정책 없음 → Edge Function service_role 만 우회
--   (139 campaign_promo_digest_runs/sent 패턴 동일)
--
-- 동시성 패턴 (139 미러):
--   1. status='failed' 로 policy_notice_runs INSERT 시도
--      (notice_key UNIQUE 가 mutex — 23505 발생 시 중복 호출 차단)
--   2. 인플별 발송 결과는 policy_notice_sent 에 ON CONFLICT DO NOTHING 으로 INSERT
--      (이미 sent 행이 있으면 재발송 스킵)
--   3. 완료 후 policy_notice_runs 를 UPDATE 로 status/count 갱신
--
-- 운영 데이터 영향:
--   신규 테이블 추가만. 기존 데이터 수정 없음.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 테이블 존재 확인
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행 + 테이블 존재 확인
--
-- 롤백:
--   DROP TABLE IF EXISTS public.policy_notice_sent;
--   DROP TABLE IF EXISTS public.policy_notice_runs;
-- ============================================================

BEGIN;


-- ============================================================
-- 1. policy_notice_runs — 통지 발송 run 로그 (mutex)
--    notice_key UNIQUE 가 mutex 역할:
--    같은 notice_key 로 INSERT 시도하면 23505 → 중복 발송 차단
-- ============================================================
CREATE TABLE IF NOT EXISTS public.policy_notice_runs (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 통지 식별자 (예: 'message_feature_2026', 'privacy_update_2026q3').
  -- UNIQUE 제약이 cron/수동 중복 호출을 차단하는 mutex 역할.
  notice_key              text        NOT NULL UNIQUE,

  started_at              timestamptz NOT NULL DEFAULT now(),
  -- chained 배치 중간은 NULL 유지, 마지막 배치 완료 시 기록.
  finished_at             timestamptz,

  status                  text        NOT NULL
    CHECK (status IN ('sent', 'partial', 'skipped_no_data', 'failed')),
    -- sent         : 전원 발송 성공
    -- partial      : 일부 실패
    -- skipped_no_data : 대상 인플 0건
    -- failed       : 전체 실패 또는 in-flight 크래시

  target_influencer_count integer     NOT NULL DEFAULT 0,
  sent_count              integer     NOT NULL DEFAULT 0,
  skipped_count           integer     NOT NULL DEFAULT 0,
  failed_count            integer     NOT NULL DEFAULT 0,

  error_message           text,

  -- 운영자 수동 트리거 대비. NULL 이면 자동(cron/함수 직접 호출).
  triggered_by            uuid        REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.policy_notice_runs IS
  '[153] 약관 통지 메일 발송 run 로그. notice_key UNIQUE 가 mutex 역할 (139 campaign_promo_digest_runs 패턴 미러). 같은 notice_key 로 INSERT 시 23505 발생 → 중복 발송 차단.';
COMMENT ON COLUMN public.policy_notice_runs.notice_key IS
  '통지 식별자 (예: ''message_feature_2026''). UNIQUE — 동일 통지 중복 발송 차단.';
COMMENT ON COLUMN public.policy_notice_runs.status IS
  'sent(전원 성공) / partial(일부 실패) / skipped_no_data(대상 0건) / failed(전체 실패·in-flight 크래시).';
COMMENT ON COLUMN public.policy_notice_runs.finished_at IS
  'chained 배치 중간 호출은 NULL 유지. 마지막 배치 완료(또는 즉시 종료) 시점에만 기록.';
COMMENT ON COLUMN public.policy_notice_runs.triggered_by IS
  'NULL=자동 실행. 운영자 수동 트리거 시 auth.uid() 기록.';


-- ============================================================
-- 2. policy_notice_sent — 인플별 발송 결과 (멱등)
--    (influencer_id, notice_key) UNIQUE 로 1통/통지 보장.
--    재호출·chained 배치에서 이미 발송된 인플은 ON CONFLICT DO NOTHING 으로 안전 스킵.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.policy_notice_sent (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  influencer_id uuid        NOT NULL
    REFERENCES public.influencers(id) ON DELETE CASCADE,
    -- influencers.id = auth.users.id (메모: project_influencer_join_key)

  notice_key    text        NOT NULL,

  status        text        NOT NULL
    CHECK (status IN ('sent', 'skipped', 'failed')),
    -- sent    : 발송 성공
    -- skipped : 발송 제외 (skip_reason 참조)
    -- failed  : 발송 실패

  -- skipped 사유 코드 (status='skipped' 일 때 기록)
  -- 'no_email'    : 이메일 주소 없음
  -- 'opt_out'     : 수신 거부 (marketing_opt_in=false 등)
  -- 'already_sent': 이전 배치에서 이미 발송됨 (chained 재진입 시)
  skip_reason   text,

  created_at    timestamptz NOT NULL DEFAULT now(),

  UNIQUE (influencer_id, notice_key)  -- 인플당 통지 1통 멱등 보장
);

CREATE INDEX ON public.policy_notice_sent (notice_key, status);
  -- Edge Function 이 notice_key 기준으로 발송 현황을 집계할 때 사용
CREATE INDEX ON public.policy_notice_sent (influencer_id, created_at DESC);
  -- 인플루언서별 수신 이력 조회 대비

COMMENT ON TABLE public.policy_notice_sent IS
  '[153] 약관 통지 메일 인플루언서별 발송 결과. (influencer_id, notice_key) UNIQUE 로 1통/통지 멱등 보장. 139 campaign_promo_digest_sent 패턴 미러.';
COMMENT ON COLUMN public.policy_notice_sent.influencer_id IS
  'influencers.id = auth.users.id. auth_id 컬럼 없음 주의.';
COMMENT ON COLUMN public.policy_notice_sent.notice_key IS
  'policy_notice_runs.notice_key 와 동일 값으로 연결. FK 제약 없음 (배치 중간 상태 허용).';
COMMENT ON COLUMN public.policy_notice_sent.skip_reason IS
  'no_email=이메일 없음, opt_out=수신 거부, already_sent=중복 호출.';


-- ============================================================
-- 3. 행 단위 보안 정책 (RLS)
--    공통: SELECT 는 is_admin() 관리자 한정
--          INSERT/UPDATE/DELETE 정책 없음 → Edge Function service_role 만 우회
--    (139 campaign_promo_digest_runs/sent 패턴 동일)
-- ============================================================

-- 3-1. policy_notice_runs
ALTER TABLE public.policy_notice_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS policy_notice_runs_select ON public.policy_notice_runs;
CREATE POLICY policy_notice_runs_select
  ON public.policy_notice_runs FOR SELECT
  USING (is_admin());

-- 3-2. policy_notice_sent
ALTER TABLE public.policy_notice_sent ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS policy_notice_sent_select ON public.policy_notice_sent;
CREATE POLICY policy_notice_sent_select
  ON public.policy_notice_sent FOR SELECT
  USING (is_admin());


COMMIT;
