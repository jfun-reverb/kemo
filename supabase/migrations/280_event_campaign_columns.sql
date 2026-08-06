-- ============================================================
-- 280_event_campaign_columns.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 1/4 (캠페인 표 컬럼 2개 + 초대 번호 표)
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ①
-- 작업표: docs/specs/2026-07-30-offline-popup-ticketing-breakdown.md 「작업 1」
--
-- 목적:
--   기존 방문형(visit) 캠페인에 「행사 모드」 표시값만 얹어, 신청 게이트·정원
--   판정·활동관리 화면이 티켓팅용으로 갈라지게 한다.
--   ⚠️ 모집 형식(recruit_type)에 새 값을 만들지 않는다 — 형식 분기가 화면·엑셀·
--      결과물·정산·자격검증에 넓게 퍼져 있어 새 값이 예측 못 한 분기로 떨어진다
--      (사양서 §3 권고).
--
-- 컬럼:
--   event_mode      행사(티켓) 캠페인 여부. 이 값 하나로만 분기한다(판정 단일 소스).
--   is_invite_only  비공개(초대 전용). true 면 인플루언서 목록에서 제외.
--
-- ⚠️ 사양서 §4-2 ①에서 벗어난 부분 — 초대 번호는 캠페인 컬럼이 아니라 별도 표다
--    (2026-08-03 구현 중 발견, 사양서 §10 「구현 결과」에 기록):
--      캠페인 표는 조회가 **공개**다(행 단위 보안 정책 — CLAUDE.md 「RLS 주의사항」).
--      인플루언서 앱의 fetchCampaigns() 는 select('*') 로 캠페인을 통째로 받아오므로,
--      초대 번호를 캠페인 컬럼에 두면 **브라우저 개발자 도구로 그대로 보인다.**
--      그러면 사양서 §2-6 이 「최종 방어선」이라 부른 예약 함수의 서버 재검증도
--      번호를 아는 사람에게는 통과되어, 초대 전용이 사실상 무의미해진다.
--      → 번호는 event_invites 표로 분리하고 관리자만 읽는다. 방문객 쪽에는
--        「맞나/틀리나」만 답하는 함수(283 verify_event_invite)를 준다.
--      → 화면 계약(초대 링크 형식 #detail-{id}?invite=CODE, 상세 게이트)은 그대로라
--        작업 2·5 의 산출 계약은 바뀌지 않는다.
--    ⚠️ 남는 위험(사용자 판단 필요): 초대 전용 캠페인의 **내용 자체**(제목·이미지)는
--      여전히 브라우저로 내려온다 — 목록 제외가 화면 단계 필터이기 때문이다.
--      사양서 §2-6 도 목록 제외·상세 게이트를 화면 단계로 규정했으므로 이번 범위는
--      그대로 두되, 내용까지 숨겨야 하면 캠페인 조회를 서버에서 거르는 별도 조각이 필요하다.
--
-- 마이그레이션 275(캠페인 동시 저장 방어)와의 관계 — 중요:
--   275 의 campaigns_bump_version() 트리거는 「제외 6개(version·updated_at·
--   view_count·applied_count·order_index·first_active_at)를 뺀 나머지가 실제로
--   바뀌면 version +1」이라 fail-closed 다. 따라서 이 두 컬럼은 **아무 조치 없이
--   자동으로 보호 대상**이 된다(의도한 방향 — 제외 목록에 넣지 않는다).
--   → 관리자 편집 저장은 updateCampaign(id, updates, expectedVersion) 으로
--     현재 버전을 반드시 함께 넘겨야 한다(작업 2 담당).
--
-- 마이그레이션 265·266(캠페인 전체 항목 변경 이력)과의 관계 — 의도적 제외:
--   변경 이력 화이트리스트는 **세 곳(265 CHECK · 266 v_fields · 266 트리거의
--   AFTER UPDATE OF 목록)이 항상 같은 집합**이어야 하고 어긋나면 CHECK 위반으로
--   캠페인 저장 자체가 통째로 실패한다. 행사 캠페인은 3건·기간 한정이라
--   이 두 컬럼을 화이트리스트에 **추가하지 않는다**(작업표 stale 점검 5번 권고).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 캠페인 컬럼 2개
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_mode     boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_invite_only boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.campaigns.event_mode IS
  '[280] 오프라인 행사(티켓) 캠페인 여부. true 면 신청 게이트·정원 판정·활동관리 '
  '화면이 티켓팅용으로 분기한다. 판정은 이 컬럼 하나로만(클라이언트 헬퍼 isEventCampaign).';
COMMENT ON COLUMN public.campaigns.is_invite_only IS
  '[280] 비공개(초대 전용) 캠페인 여부. true 면 인플루언서 목록·홈·건수에서 제외되고 '
  '상세는 초대 번호 확인 후에만 열린다. 번호 자체는 event_invites 표에 있다(공개 조회 차단). '
  '예약 함수(283)가 서버에서 다시 검증한다 — 이것이 실효 방어선이다.';

-- 행사 캠페인은 소수라 부분 인덱스로 충분.
CREATE INDEX IF NOT EXISTS campaigns_event_mode_idx
  ON public.campaigns(event_mode)
  WHERE event_mode = true;

-- 행사 모드는 방문형(visit)에만 켤 수 있다.
--   리뷰어형(monitor)에 켜지면 마이그레이션 049(자동 승인)가 예약 함수가 넣으려던
--   「심사중(대기)」을 INSERT 직전에 승인으로 덮어써서, **티켓은 대기인데 신청은 당선**인
--   모순 데이터가 만들어진다. 048(정원 가드)도 캠페인 인원 값을 기준으로 별도 판정을
--   해 타임별 정원과 어긋난다. 사양서 §3(형식을 새로 만들지 않고 방문형에 얹는다)의
--   전제를 데이터베이스에서 강제한다.
--   ⚠️ 기존 캠페인은 전부 event_mode=false 라 이 제약을 그냥 통과한다(도입 영향 0).
ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_event_mode_visit_chk;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_event_mode_visit_chk
  CHECK (NOT event_mode OR recruit_type = 'visit');

-- ============================================================
-- 2. 초대 번호 표 — 캠페인당 1줄
-- ============================================================
-- 캠페인 표에 두지 않는 이유는 파일 헤더의 ⚠️ 참고(공개 조회 → 번호 유출).
CREATE TABLE IF NOT EXISTS public.event_invites (
  campaign_id uuid PRIMARY KEY REFERENCES public.campaigns(id) ON DELETE CASCADE,
  code        text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{8}$'),
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.event_invites IS
  '[280] 초대 전용 캠페인의 초대 번호. 캠페인 표(공개 조회)에 두면 브라우저로 유출되므로 '
  '분리했다. 조회·수정은 캠페인 관리 권한 이상만. 방문객은 283 verify_event_invite 로 '
  '「맞나/틀리나」만 확인한다.';
COMMENT ON COLUMN public.event_invites.code IS
  '[280] 초대 번호(대문자 영숫자 8자리). 초대 링크(#detail-{campaignId}?invite=CODE)와 '
  '손입력이 같은 값을 검증한다. 예약번호(event_tickets.ticket_code)와는 다른 값이다.';

CREATE OR REPLACE FUNCTION public.touch_event_invites_updated_at()
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

COMMENT ON FUNCTION public.touch_event_invites_updated_at() IS
  '[280] event_invites.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_event_invites_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_event_invites_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_invites_updated_at ON public.event_invites;
CREATE TRIGGER trg_event_invites_updated_at
  BEFORE UPDATE ON public.event_invites
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_event_invites_updated_at();

ALTER TABLE public.event_invites ENABLE ROW LEVEL SECURITY;

-- 조회는 캠페인 관리 권한 이상만. 일반 관리자(campaign_manager)도 제외한다 —
-- 초대 번호는 첫날 비공개를 여는 열쇠라 발급 권한과 조회 권한을 같은 선에 둔다.
CREATE POLICY event_invites_select ON public.event_invites
  FOR SELECT TO authenticated
  USING (public.is_campaign_admin());

CREATE POLICY event_invites_insert ON public.event_invites
  FOR INSERT TO authenticated
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY event_invites_update ON public.event_invites
  FOR UPDATE TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY event_invites_delete ON public.event_invites
  FOR DELETE TO authenticated
  USING (public.is_campaign_admin());

COMMIT;

-- ============================================================
-- 검증
-- ============================================================
-- 1) 컬럼 2개 생성 확인
-- SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns'
--    AND column_name IN ('event_mode','is_invite_only')
--  ORDER BY column_name;
--   → 둘 다 boolean, NO, false
--
-- 2) 기존 캠페인이 전부 기본값인지(도입 즉시 동작 변화 0)
-- SELECT count(*) FILTER (WHERE event_mode)     AS event_on,
--        count(*) FILTER (WHERE is_invite_only) AS invite_on,
--        count(*)                               AS total
--   FROM public.campaigns;
--   → event_on=0, invite_on=0
--
-- 3) 275 낙관적 락이 새 컬럼을 보호하는지(제외 목록에 안 들어갔는지)
-- SELECT id, version FROM public.campaigns LIMIT 1;
-- UPDATE public.campaigns SET event_mode = true  WHERE id = '<위 id>';
-- SELECT version FROM public.campaigns WHERE id = '<위 id>';   -- +1 이어야 함
-- UPDATE public.campaigns SET event_mode = false WHERE id = '<위 id>';  -- 원복(+1 더)
--
-- 4) 초대 번호 표 정책 — ⚠️ 이 검증이 이 파일의 핵심
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename='event_invites' ORDER BY policyname;
--   → select/insert/update/delete 4개
--    브라우저에서 인플루언서 계정으로
--      await db.from('event_invites').select('*')
--    를 실행하면 **0건**이어야 한다(정책에 막혀 행이 안 보인다).
--    1건이라도 보이면 초대 전용이 뚫린 것이므로 즉시 보고.
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_event_invites_updated_at ON public.event_invites;
-- DROP FUNCTION IF EXISTS public.touch_event_invites_updated_at();
-- DROP TABLE IF EXISTS public.event_invites;   -- 정책 함께 소멸
-- DROP INDEX IF EXISTS public.campaigns_event_mode_idx;
-- ALTER TABLE public.campaigns
--   DROP COLUMN IF EXISTS is_invite_only,
--   DROP COLUMN IF EXISTS event_mode;
-- COMMIT;
