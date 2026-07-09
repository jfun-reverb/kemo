-- ============================================================
-- 217_settlements_schema.sql
-- 인플루언서 정산 관리 PR1 — 1/4 (데이터 모델)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §4, §7-1
--
-- settlements: 응모(참여) 단위 1행 = 리워드 정산 1건.
--   인증 성공(computeCertStatus === 'success', dev/js/admin-deliverables.js 단일 소스) &&
--   campaigns.reward > 0 && influencers.is_audit = false 인 응모에 대해
--   backfill_settlements() RPC(마이그레이션 218)가 UPSERT 로 생성한다.
--   금액은 생성 시점 campaigns.reward 스냅샷(엔화) — 캠페인 리워드 사후 변경과 무관.
--
-- 권한: 동적 권한(role_permissions, 마이그레이션 207/209) 편입 — server_enforced.
--   feature_key 'settlement.view'/'settlement.pay' 시드는 마이그레이션 220.
--   이 파일의 RLS는 is_admin() 이 아니라 has_permission('settlement.view','read') 로
--   건다 — campaign_manager 는 이 기능이 'hidden' 이라 사이드바뿐 아니라
--   테이블 직접 조회(API)로도 막혀야 하기 때문(사용자 결정: "server_enforced 기능").
--
-- ⚠️ CASCADE 결정 (settlement_events, 매우 중요 — 개발자 지시 사항):
--   CLAUDE.md 에 deliverable_events.deliverable_id 가 ON DELETE CASCADE 라, 관리자가
--   대리 등록 결과물을 회수(DELETE)하면 그 감사 이력(admin_proxy_revoke)까지 함께
--   삭제되는 선례가 명시돼 있다("영구 감사 필요 시 별도 테이블 권장"). settlements 는
--   금전(실제 PayPal 송금) 기록이라 결과물보다 감사 요구 수준이 높다. 이 설계에서는
--   settlements 행 자체를 하드 삭제하는 UI/RPC 경로를 두지 않는다(취소는
--   status='cancelled' 소프트 상태로 표현 — §4). 따라서 settlement_events.settlement_id
--   는 ON DELETE RESTRICT 로 둔다: 실수로 누군가 settlements 행을 직접 DELETE 하려
--   해도, 이력이 남아있는 한 데이터베이스가 막아준다("삭제하려면 먼저 이력부터
--   지워라"라는 의도적 마찰). CASCADE 로 하면 결과물 사고와 똑같은 패턴(행 삭제 시
--   감사 유실)이 금전 테이블에서 반복된다 — 그래서 RESTRICT 채택.
--
--   (참고로 settlements.application_id/campaign_id/influencer_id 자체는 기존
--   deliverables 테이블 컨벤션과 동일하게 ON DELETE CASCADE 로 뒀다. 단, 이는
--   "캠페인을 하드 삭제하면 그 캠페인의 이미 지급 완료(paid)된 정산 기록까지
--   연쇄 삭제될 수 있다"는 별도 리스크를 내포한다 — 결과물(deliverables)도 이미
--   같은 방식으로 캐스케이드되므로 기존 컨벤션과의 일관성을 택했지만, 실제 운영에서
--   "지급 완료된 캠페인은 삭제 차단" 정책이 필요한지는 이 마이그레이션 범위 밖의
--   후속 판단 사항으로 남긴다.)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. settlements 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id  uuid NOT NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  application_id uuid NOT NULL UNIQUE REFERENCES public.applications(id) ON DELETE CASCADE,
  campaign_id    uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  amount_jpy     bigint NOT NULL CHECK (amount_jpy > 0),
  status         text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'paid', 'on_hold', 'cancelled')),
  paypal_email   text,
  paid_at        timestamptz,
  paid_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  memo           text,
  version        integer NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.settlements IS
  '[217] 인플루언서 리워드 정산. 1 응모(application) = 1행(application_id UNIQUE, 멱등). '
  'backfill_settlements() RPC(마이그레이션 218)가 인증 성공 응모를 UPSERT 생성. 화면 없음(PR1). '
  '금액은 생성 시점 campaigns.reward 스냅샷(엔화, amount_jpy) — 캠페인 리워드 사후 변경 무영향.';
COMMENT ON COLUMN public.settlements.amount_jpy IS
  '엔화(¥). 원천징수 없음·전액 지급(약관 제13조). 생성 시점 campaigns.reward 스냅샷.';
COMMENT ON COLUMN public.settlements.paypal_email IS
  '생성 시점 influencers.paypal_email 스냅샷(NULL 이면 미등록 — settlement_paypal_required 알림 대상). '
  '송금 처리 시 최신값으로 갱신 가능(PR2 mark_settlement_paid).';
COMMENT ON COLUMN public.settlements.status IS
  'pending(정산대기) | paid(송금완료) | on_hold(보류 — 인증 깨짐/환수 필요 등 사유는 memo) | cancelled(취소).';
COMMENT ON COLUMN public.settlements.version IS
  '낙관적 락. 송금 완료 처리(PR2 mark_settlement_paid RPC)가 동시 처리 충돌을 막는 데 사용.';

CREATE INDEX IF NOT EXISTS idx_settlements_status_pending
  ON public.settlements(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_settlements_influencer_id
  ON public.settlements(influencer_id);
CREATE INDEX IF NOT EXISTS idx_settlements_campaign_id
  ON public.settlements(campaign_id);

-- ── updated_at 자동 갱신 트리거 (기존 companies/deliverables 등과 동일 컨벤션) ──
CREATE OR REPLACE FUNCTION public.touch_settlements_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_settlements_updated_at() IS
  '[217] settlements.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_settlements_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_settlements_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_settlements_updated_at ON public.settlements;
CREATE TRIGGER trg_settlements_updated_at
  BEFORE UPDATE ON public.settlements
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_settlements_updated_at();

-- ============================================================
-- 2. settlements RLS
-- ============================================================
ALTER TABLE public.settlements ENABLE ROW LEVEL SECURITY;

-- 인플루언서: 본인 정산행만 조회 (settlements.influencer_id = influencers.id = auth.uid())
CREATE POLICY settlements_select_own ON public.settlements
  FOR SELECT TO authenticated
  USING (influencer_id = auth.uid());

-- 관리자: has_permission('settlement.view','read') 이상만 조회 (server_enforced — 사용자 결정).
--   is_admin() 이 아닌 has_permission() 을 쓰는 이유: campaign_manager 는 이 기능이
--   'hidden'(마이그레이션 220 시드)이라 화면뿐 아니라 API 직접 조회도 막혀야 함.
--   super_admin 은 has_permission() 내부에서 테이블 조회 없이 무조건 통과(잠금 방지).
CREATE POLICY settlements_select_admin ON public.settlements
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

-- INSERT/UPDATE: 직접 정책 없음 — backfill_settlements()·mark_settlement_paid()(PR2) 같은
--   SECURITY DEFINER 함수만 변경 가능. 정책 자체가 없으면 authenticated 의 직접
--   INSERT/UPDATE 는 RLS 기본 거부(permissive 정책 매칭 없음)로 원천 차단된다.

-- ============================================================
-- 3. settlement_events 테이블 (금전 감사, append-only)
--    settlement_id ON DELETE RESTRICT 근거는 파일 상단 CASCADE 결정 설명 참고.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_events (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  settlement_id  uuid NOT NULL REFERENCES public.settlements(id) ON DELETE RESTRICT,
  action         text NOT NULL CHECK (action IN ('create', 'pay', 'hold', 'cancel', 'revert')),
  prev_status    text CHECK (prev_status IN ('pending', 'paid', 'on_hold', 'cancelled')),
  next_status    text NOT NULL CHECK (next_status IN ('pending', 'paid', 'on_hold', 'cancelled')),
  actor          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  memo           text,
  at             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.settlement_events IS
  '[217] 정산 상태 변경 이력(금전 감사, append-only). settlement_id 는 ON DELETE RESTRICT '
  '(CASCADE 금지 — deliverable_events 가 CASCADE 라 대리 등록 회수 시 감사 유실된 선례를 '
  '반복하지 않기 위함, 파일 상단 설명 참고). INSERT 는 backfill_settlements() 등 '
  'SECURITY DEFINER 함수만(직접 INSERT 정책 없음 — application_events/receipt_edit_history 와 동일 컨벤션).';
COMMENT ON COLUMN public.settlement_events.actor IS
  '관리자(수동 처리) 또는 NULL(backfill_settlements 자동 생성 — auth.uid() 있으면 그 관리자, 없으면 NULL).';

CREATE INDEX IF NOT EXISTS idx_settlement_events_settlement_id
  ON public.settlement_events(settlement_id);
CREATE INDEX IF NOT EXISTS idx_settlement_events_at
  ON public.settlement_events(at DESC);

ALTER TABLE public.settlement_events ENABLE ROW LEVEL SECURITY;

-- 조회도 settlement.view 권한 게이트 (settlements 테이블과 동일 기준)
CREATE POLICY settlement_events_select_admin ON public.settlement_events
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

-- INSERT: 정책 없음 — SECURITY DEFINER 함수만 (application_events/receipt_edit_history 컨벤션 동일).

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 테이블·컬럼 생성 확인
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('settlements', 'settlement_events')
ORDER BY table_name, ordinal_position;

-- [V1] RLS 정책 확인
SELECT schemaname, tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('settlements', 'settlement_events')
ORDER BY tablename, policyname;

-- [V2] FK ON DELETE 규칙 확인 (settlement_events.settlement_id 가 RESTRICT 인지)
SELECT conname, confrelid::regclass AS references_table, confdeltype
FROM pg_constraint
WHERE conrelid = 'public.settlement_events'::regclass AND contype = 'f';
-- 기대: confdeltype = 'r' (RESTRICT). CASCADE 면 'c', SET NULL 이면 'n'.

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS settlement_events_select_admin ON public.settlement_events;
-- DROP TABLE IF EXISTS public.settlement_events;
-- DROP TRIGGER IF EXISTS trg_settlements_updated_at ON public.settlements;
-- DROP FUNCTION IF EXISTS public.touch_settlements_updated_at();
-- DROP POLICY IF EXISTS settlements_select_own ON public.settlements;
-- DROP POLICY IF EXISTS settlements_select_admin ON public.settlements;
-- DROP TABLE IF EXISTS public.settlements;
