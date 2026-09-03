-- ============================================================
-- 402. 캠페인 리포트 — 본체·캠페인 연결 표
-- ============================================================
-- 사양서   : docs/specs/2026-09-03-campaign-report-builder.md
-- 작업표   : docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 1」
--
-- 관리자가 캠페인을 여럿 골라 하나의 리포트로 묶는다. 1-A 단계는 **REVERB 결과물만**
-- 담고, 외부 파일(포인테일)·공유 링크는 뒤 단계에서 붙인다.
--
-- 🔴 `campaign_id` 를 `CASCADE` 로 두지 않는다 — 캠페인을 완전 삭제하면
--    **리포트가 통째로 사라진다.** 리포트는 지난 일의 기록이라 캠페인보다 오래 산다.
--    대신 `SET NULL` 로 두고, 캠페인 번호·제목을 **글자로도 함께 보관**해
--    원본이 사라져도 무엇을 담았던 리포트인지 남게 한다.
--
-- ⚠️ `include_audit` 를 **저장한다** — 만들 때 감사용 계정을 포함했는지가
--    나중에 숫자를 다시 셀 때 필요하다. 안 남기면 같은 리포트를 다시 열었을 때
--    수가 달라지고 왜 달라졌는지 알 수 없다.
--
-- ⚠️ `brand_id` 는 **지금 비워 둔다**(4단계 브랜드 포털 대비). 칸만 만들어 둔다.
--
-- ⚠️ 쓰기 정책을 만들지 않는다 — 넣고 지우는 것은 403 의 함수만 한다.
--    조회만 `has_permission('menu.reports','read')` 로 연다.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.campaign_reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title         text NOT NULL,
  created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  include_audit boolean NOT NULL DEFAULT false,
  version       integer NOT NULL DEFAULT 1,
  brand_id      uuid REFERENCES public.brands(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.campaign_reports IS
  '[402] 캠페인 리포트 본체. 1-A 는 REVERB 결과물만. brand_id 는 4단계 대비 예약.';
COMMENT ON COLUMN public.campaign_reports.include_audit IS
  '[402] 만들 때 감사용 계정을 포함했는지. 나중에 다시 셀 때 수가 달라지지 않게 저장한다.';
COMMENT ON COLUMN public.campaign_reports.version IS
  '[402] 낙관적 잠금. 2단계 구성 변경에서 쓴다.';

CREATE TABLE IF NOT EXISTS public.campaign_report_campaigns (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id       uuid NOT NULL REFERENCES public.campaign_reports(id) ON DELETE CASCADE,
  campaign_id     uuid REFERENCES public.campaigns(id) ON DELETE SET NULL,
  campaign_no     text,
  campaign_title  text,
  sort_order      integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.campaign_report_campaigns IS
  '[402] 리포트가 담은 캠페인. 🔴 campaign_id 는 SET NULL — 캠페인을 지워도 리포트는 남는다. '
  'campaign_no·campaign_title 을 글자로 보관해 원본이 사라져도 무엇이었는지 남는다.';

CREATE INDEX IF NOT EXISTS idx_campaign_report_campaigns_report
  ON public.campaign_report_campaigns(report_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_campaign_report_campaigns_campaign
  ON public.campaign_report_campaigns(campaign_id)
  WHERE campaign_id IS NOT NULL;

-- ------------------------------------------------------------
-- 행 단위 보안 정책 — 조회만. 쓰기는 403 의 함수만(SECURITY DEFINER).
-- ------------------------------------------------------------
ALTER TABLE public.campaign_reports            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_report_campaigns   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_reports_select ON public.campaign_reports;
CREATE POLICY campaign_reports_select ON public.campaign_reports
  FOR SELECT USING (public.has_permission('menu.reports', 'read'));

DROP POLICY IF EXISTS campaign_report_campaigns_select ON public.campaign_report_campaigns;
CREATE POLICY campaign_report_campaigns_select ON public.campaign_report_campaigns
  FOR SELECT USING (public.has_permission('menu.reports', 'read'));

-- updated_at 자동 갱신
CREATE OR REPLACE FUNCTION public.touch_campaign_report_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_campaign_reports_touch ON public.campaign_reports;
CREATE TRIGGER trg_campaign_reports_touch
  BEFORE UPDATE ON public.campaign_reports
  FOR EACH ROW EXECUTE FUNCTION public.touch_campaign_report_updated_at();


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 표 2개와 정책이 생겼는가
SELECT tablename, rowsecurity FROM pg_tables
 WHERE schemaname='public' AND tablename IN ('campaign_reports','campaign_report_campaigns');
SELECT tablename, policyname, cmd FROM pg_policies
 WHERE tablename IN ('campaign_reports','campaign_report_campaigns');
-- 기대: 표 2개 rowsecurity=true · 정책 2개 SELECT

-- [V2] 🔴 campaign_id 가 SET NULL 인가 (CASCADE 면 캠페인 삭제가 리포트를 지운다)
SELECT c.conname, c.confdeltype   -- 'n'=SET NULL, 'c'=CASCADE
  FROM pg_constraint c
 WHERE c.conrelid = 'public.campaign_report_campaigns'::regclass AND c.contype='f';
-- 기대: report_id → 'c'(CASCADE) · campaign_id → 'n'(SET NULL)

-- [V3] 🔴 인플루언서 세션에서 0행인가
--      ⚠️ SQL 편집기로는 재현되지 않는다(서비스 키는 정책을 우회한다).
--         로그인한 회원 브라우저 콘솔에서:
--         (await db.from('campaign_reports').select('id')).data  →  []

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DROP TABLE IF EXISTS public.campaign_report_campaigns;
-- DROP TABLE IF EXISTS public.campaign_reports;
-- DROP FUNCTION IF EXISTS public.touch_campaign_report_updated_at();
