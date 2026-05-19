-- ============================================================
-- 139_campaign_promo_digest_tables.sql
-- 2026-05-19
--
-- 목적:
--   캠페인 홍보 메일 (주 2회 다이제스트) PR 1 — DB 인프라.
--   발송 run 로그·인플별 발송 로그·노출 기록·클릭 추적 테이블 4종 신설.
--
-- 사양서:
--   docs/specs/2026-05-19-campaign-promo-email.md §3-1, §17-4
--
-- 신설 테이블:
--   1. campaign_promo_digest_runs   — 다이제스트 run 로그 (mutex 역할)
--   2. campaign_promo_digest_sent   — 인플별 발송 결과 (멱등·감사)
--   3. campaign_promo_exposure      — 캠페인×인플×종류별 노출 기록 (최대 2회 보장)
--   4. campaign_promo_email_clicks  — CTA 클릭 추적 (다음 다이제스트 매칭 제외)
--
-- 행 단위 보안 정책 (모든 테이블):
--   SELECT  is_admin() 한정
--   INSERT/UPDATE/DELETE 정책 없음 → Edge Function service_role 만 우회
--
-- 동시성 패턴 (admin_daily_digest_runs 미러):
--   1. status='failed' 로 INSERT 시도 (digest_date UNIQUE 가 mutex)
--   2. 23505 발생 → 중복 호출 차단, 즉시 종료
--   3. 성공 → 데이터 조회 + 메일 발송
--   4. UPDATE 로 status='sent'/'partial'/'skipped_no_data' 갱신
--
-- 운영 데이터 영향:
--   신규 테이블 추가만. 기존 데이터 수정 없음.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리:
--   [1단계] 테이블 4개 존재 확인 — 아래 별도 안내
--
-- 롤백:
--   DROP TABLE IF EXISTS public.campaign_promo_email_clicks;
--   DROP TABLE IF EXISTS public.campaign_promo_exposure;
--   DROP TABLE IF EXISTS public.campaign_promo_digest_sent;
--   DROP TABLE IF EXISTS public.campaign_promo_digest_runs;
-- ============================================================

BEGIN;


-- ============================================================
-- 1. campaign_promo_digest_runs — run 로그 (mutex)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.campaign_promo_digest_runs (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date             date        NOT NULL UNIQUE,    -- UNIQUE = cron 중복 호출 차단 mutex
  started_at              timestamptz NOT NULL DEFAULT now(),
  finished_at             timestamptz,
  status                  text        NOT NULL
    CHECK (status IN ('sent', 'skipped_no_data', 'failed', 'partial')),
  included_campaign_ids   uuid[]      NOT NULL DEFAULT '{}',
  target_influencer_count integer     NOT NULL DEFAULT 0,
  sent_count              integer     NOT NULL DEFAULT 0,
  skipped_count           integer     NOT NULL DEFAULT 0,
  failed_count            integer     NOT NULL DEFAULT 0,
  error_message           text,
  triggered_by            uuid        REFERENCES auth.users(id) ON DELETE SET NULL
    -- 향후 운영자 수동 트리거 대비 — NULL 이면 cron 자동 실행
);

COMMENT ON TABLE public.campaign_promo_digest_runs IS
  '[139] 캠페인 홍보 메일 주 2회 다이제스트 run 로그. digest_date UNIQUE 가 mutex 역할 (admin_daily_digest_runs 패턴 미러).';
COMMENT ON COLUMN public.campaign_promo_digest_runs.digest_date IS
  'cron 호출 날짜 (KST). UNIQUE — 동일 날짜 중복 호출 차단.';
COMMENT ON COLUMN public.campaign_promo_digest_runs.status IS
  'sent(정상) / partial(일부 실패) / skipped_no_data(대상 0건) / failed(전체 실패·in-flight 크래시).';
COMMENT ON COLUMN public.campaign_promo_digest_runs.included_campaign_ids IS
  '이번 다이제스트에 포함된 신규+D-1 캠페인 ID 배열.';
COMMENT ON COLUMN public.campaign_promo_digest_runs.triggered_by IS
  'NULL=cron 자동 실행. 운영자 수동 트리거 시 auth.uid() 기록.';


-- ============================================================
-- 2. campaign_promo_digest_sent — 인플별 발송 결과
--    (influencer_id, digest_date) UNIQUE 로 인플당 1통/cron 보장
-- ============================================================
CREATE TABLE IF NOT EXISTS public.campaign_promo_digest_sent (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id         uuid        NOT NULL
    REFERENCES public.influencers(id) ON DELETE CASCADE,
  digest_date           date        NOT NULL,
  sent_at               timestamptz NOT NULL DEFAULT now(),
  status                text        NOT NULL
    CHECK (status IN ('sent', 'skipped', 'failed')),
  skip_reason           text,
    -- 'opt_out' / 'no_email' / 'no_matched_campaign' / 'already_sent'
  error_message         text,
  included_campaign_ids uuid[]      NOT NULL DEFAULT '{}',
  UNIQUE (influencer_id, digest_date)  -- 인플당 cron 1회 1통 멱등 보장
);

CREATE INDEX ON public.campaign_promo_digest_sent (digest_date, status);
CREATE INDEX ON public.campaign_promo_digest_sent (influencer_id, sent_at DESC);

COMMENT ON TABLE public.campaign_promo_digest_sent IS
  '[139] 캠페인 홍보 메일 인플루언서별 발송 결과. (influencer_id, digest_date) UNIQUE 로 1통/cron 멱등 보장.';
COMMENT ON COLUMN public.campaign_promo_digest_sent.skip_reason IS
  'opt_out=수신거부, no_email=이메일 없음, no_matched_campaign=매칭 캠페인 0건, already_sent=중복 호출.';
COMMENT ON COLUMN public.campaign_promo_digest_sent.included_campaign_ids IS
  '이 인플에게 실제 발송된 캠페인 ID 배열 (신규+D-1 합산).';


-- ============================================================
-- 3. campaign_promo_exposure — 노출 기록
--    (campaign_id, influencer_id, kind) UNIQUE 로 인플당 캠페인당 최대 2회 보장
--    kind: 'new' = 신규 안내 1회, 'deadline_d1' = D-1 임박 1회
-- ============================================================
CREATE TABLE IF NOT EXISTS public.campaign_promo_exposure (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   uuid        NOT NULL
    REFERENCES public.campaigns(id) ON DELETE CASCADE,
  influencer_id uuid        NOT NULL
    REFERENCES public.influencers(id) ON DELETE CASCADE,
  kind          text        NOT NULL
    CHECK (kind IN ('new', 'deadline_d1')),
  sent_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, influencer_id, kind)  -- 같은 (캠페인, 인플, 종류) 중복 노출 차단
);

CREATE INDEX ON public.campaign_promo_exposure (influencer_id, sent_at DESC);
CREATE INDEX ON public.campaign_promo_exposure (campaign_id, kind);

COMMENT ON TABLE public.campaign_promo_exposure IS
  '[139] 캠페인×인플×종류별 노출 기록. (campaign_id, influencer_id, kind) UNIQUE 로 인플당 캠페인당 new+D-1 최대 2회 노출 보장.';
COMMENT ON COLUMN public.campaign_promo_exposure.kind IS
  'new=신규 캠페인 안내(1회), deadline_d1=마감 D-1 임박 알림(1회). 인플당 캠페인당 최대 2행.';


-- ============================================================
-- 4. campaign_promo_email_clicks — CTA 클릭 추적
--    클릭된 (campaign_id, influencer_id) 페어는 이후 다이제스트 매칭에서 자동 제외
--    (인플이 캠페인을 확인했으면 더 이상 안내 불필요)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.campaign_promo_email_clicks (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id     uuid        NOT NULL
    REFERENCES public.campaigns(id) ON DELETE CASCADE,
  influencer_id   uuid        NOT NULL
    REFERENCES public.influencers(id) ON DELETE CASCADE,
  first_clicked_at timestamptz NOT NULL DEFAULT now(),
  click_count     integer     NOT NULL DEFAULT 1,
  last_clicked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, influencer_id)  -- 페어당 1행, 재클릭 시 UPDATE
);

CREATE INDEX ON public.campaign_promo_email_clicks (influencer_id, first_clicked_at DESC);
-- campaign_id 단독 인덱스: 캠페인 삭제 시 CASCADE 성능 보조
CREATE INDEX ON public.campaign_promo_email_clicks (campaign_id);

COMMENT ON TABLE public.campaign_promo_email_clicks IS
  '[139] 홍보 메일 캠페인 CTA 클릭 추적. 클릭된 (campaign_id, influencer_id) 페어는 다음 다이제스트 매칭에서 자동 제외.';
COMMENT ON COLUMN public.campaign_promo_email_clicks.click_count IS
  '동일 페어 재클릭 시 last_clicked_at 갱신 + click_count 누적 (ON CONFLICT DO UPDATE).';


-- ============================================================
-- 5. 행 단위 보안 정책 (RLS)
--    공통: SELECT 는 is_admin() 관리자 한정
--          INSERT/UPDATE/DELETE 정책 없음 → Edge Function service_role 만 우회
--    (admin_daily_digest_runs 패턴 미러)
-- ============================================================

-- 5-1. campaign_promo_digest_runs
ALTER TABLE public.campaign_promo_digest_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_promo_digest_runs_select ON public.campaign_promo_digest_runs;
CREATE POLICY campaign_promo_digest_runs_select
  ON public.campaign_promo_digest_runs FOR SELECT
  USING (is_admin());

-- 5-2. campaign_promo_digest_sent
ALTER TABLE public.campaign_promo_digest_sent ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_promo_digest_sent_select ON public.campaign_promo_digest_sent;
CREATE POLICY campaign_promo_digest_sent_select
  ON public.campaign_promo_digest_sent FOR SELECT
  USING (is_admin());

-- 5-3. campaign_promo_exposure
ALTER TABLE public.campaign_promo_exposure ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_promo_exposure_select ON public.campaign_promo_exposure;
CREATE POLICY campaign_promo_exposure_select
  ON public.campaign_promo_exposure FOR SELECT
  USING (is_admin());

-- 5-4. campaign_promo_email_clicks
ALTER TABLE public.campaign_promo_email_clicks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_promo_email_clicks_select ON public.campaign_promo_email_clicks;
CREATE POLICY campaign_promo_email_clicks_select
  ON public.campaign_promo_email_clicks FOR SELECT
  USING (is_admin());


COMMIT;
