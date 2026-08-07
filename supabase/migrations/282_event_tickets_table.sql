-- ============================================================
-- 282_event_tickets_table.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 3/4 (티켓 표)
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ③
-- 선행: 280 (캠페인 컬럼) · 281 (타임 표)
--
-- event_tickets = 방문객 1명의 예약 1건. 예약번호(ticket_code)가 QR 에 담기는 값.
--
-- ── 신청(applications) 행과의 관계 (설계의 핵심) ─────────────────
--   티켓 1건은 기존 신청 1건과 짝을 이룬다(사양서 §0 결정 14).
--     티켓 confirmed → 신청 approved   (응모 이력에 「당선」, 카드에서 티켓 화면으로)
--     티켓 waitlist  → 신청 pending    (「審査中」 — 확정이 아니므로 맞는 표기)
--     티켓 cancelled → 신청 cancelled  (「取消」)
--
--   ⚠️ 대기(waitlist)도 신청 행을 **미리 만들어 둔다**. 안 만들면 나중에 승격될 때
--      신청 행을 새로 INSERT 해야 하는데, 승격은 행사 직전(모집 마감 후)에도
--      일어나므로 마감 가드 트리거(272)에 막혀 승격 자체가 실패한다.
--      모집 기간 안에 만들어 두면 승격은 UPDATE 라 그 가드를 타지 않는다.
--
-- ── application_id 를 ON DELETE CASCADE 로 거는 이유 (개인정보 파기) ──
--   캠페인 보관 삭제(마이그레이션 255)는 캠페인 행만 30일 보관하고 신청·결과물은
--   **즉시 완전 파기**한다(개인정보 파기 원칙). 그 함수는 새 표를 모르므로,
--   신청 행에 연쇄 삭제를 걸어 두어야 입장 기록(개인정보)이 함께 파기된다.
--   → 작업표 stale 점검 7번의 해소책. 삭제 함수 자체는 고치지 않는다.
--   ⚠️ campaign_id·slot_id 에도 연쇄 삭제가 걸려 있어 완전 삭제 경로도 안전하다.
--
-- ── 취소해도 신청 행을 지우지 않는 이유 ──────────────────────────
--   신청 표에는 옛 유일 제약(uidx_applications_user_campaign, 마이그레이션 050)이
--   **아직 남아 있다** — 104 가 지우려던 이름이 실제 이름과 달라(자동 생성 이름을
--   적었다) IF EXISTS 가 조용히 통과했고, 그래서 「취소 후 재응모」가 도입 이래
--   막혀 있다. 이 결함을 플랫폼 전체에서 푸는 것은 「같은 사람·같은 캠페인 여러 줄」
--   이라는 새 데이터 모양을 목록·엑셀·집계 전반에 처음 만드는 일이라 이번 범위 밖이다.
--   → 행사에서는 **신청 행을 지우지 않고 cancelled 로 두었다가, 재예약 때 그 행을
--      되살린다**(283 의 reserve_event_ticket). 행이 하나뿐이라 옛 제약에 걸리지 않고,
--      취소 이력도 응모 이력에 남는다. 사용자 결정 2026-08-03: 「다시 예약할 수 있게」.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.event_tickets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  slot_id           uuid NOT NULL REFERENCES public.event_slots(id) ON DELETE CASCADE,
  -- 집계 편의를 위한 중복 보관(사양서 §4-2 ③). slot 을 통해서도 알 수 있지만
  -- 예약 현황·리포트가 캠페인 단위로 훑으므로 조인을 줄인다.
  campaign_id       uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  influencer_id     uuid NOT NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  -- 개인정보 파기 연쇄의 핵심 — 위 헤더 주석 참고.
  application_id    uuid REFERENCES public.applications(id) ON DELETE CASCADE,

  -- 예약번호 = QR 에 담는 값. 사람이 손으로도 입력할 수 있는 길이(8자리).
  -- QR 에는 이 번호만 담고 이름·이메일은 담지 않는다(사양서 §2-9 · §7-3).
  ticket_code       text NOT NULL UNIQUE
                      CHECK (ticket_code ~ '^[A-Z0-9]{8}$'),

  status            text NOT NULL DEFAULT 'confirmed'
                      CHECK (status IN ('confirmed','waitlist','cancelled')),
  waitlist_position integer,           -- 확정이면 NULL

  -- 첫 입장 시각(재확인해도 덮어쓰지 않는다) + 처리한 관리자
  entered_at        timestamptz,
  entered_by        uuid,
  entered_by_name   text,              -- 표시용 스냅샷(관리자 이름이 바뀌어도 기록 유지)
  scan_count        integer NOT NULL DEFAULT 0 CHECK (scan_count >= 0),

  version           integer NOT NULL DEFAULT 1,

  cancelled_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  -- 확정·대기는 waitlist_position 규칙이 반대다
  CONSTRAINT event_tickets_waitlist_pos_chk CHECK (
    (status = 'waitlist'  AND waitlist_position IS NOT NULL AND waitlist_position > 0)
    OR (status <> 'waitlist')
  )
);

-- 「한 캠페인에 1타임만」(사양서 §0 결정 4)을 서버에서 강제한다.
-- 취소된 티켓은 제외 — 취소 후 재예약을 허용하기 위함(사용자 결정 2026-08-03).
-- ⚠️ 신청 표의 유일 제약과는 별개다. 대기(waitlist)는 신청 행이 pending 이라
--    신청 쪽 제약만으로는 「대기 중에 또 대기 신청」을 막지 못하므로 여기서 막는다.
CREATE UNIQUE INDEX IF NOT EXISTS event_tickets_camp_influencer_active_uidx
  ON public.event_tickets(campaign_id, influencer_id)
  WHERE status <> 'cancelled';

CREATE INDEX IF NOT EXISTS event_tickets_slot_status_idx
  ON public.event_tickets(slot_id, status);
CREATE INDEX IF NOT EXISTS event_tickets_campaign_idx
  ON public.event_tickets(campaign_id);
CREATE INDEX IF NOT EXISTS event_tickets_influencer_idx
  ON public.event_tickets(influencer_id);

COMMENT ON TABLE public.event_tickets IS
  '[282] 오프라인 행사 예약 티켓 1건 = 방문객 1명의 예약. 사양서 '
  'docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ③. '
  '등록·수정은 SECURITY DEFINER 함수(283)로만 — 예약번호 위조·정원 우회 차단.';
COMMENT ON COLUMN public.event_tickets.ticket_code IS
  '[282] 예약번호(QR 에 담기는 값). 대문자 영숫자 8자리. 혼동하기 쉬운 글자'
  '(0 O 1 I L)는 생성 시 제외한다 — 현장에서 손으로 입력하기 때문(283 참고). '
  '개인정보를 담지 않는다: QR 사진이 SNS 에 올라가도 이름·이메일이 노출되지 않는다.';
COMMENT ON COLUMN public.event_tickets.application_id IS
  '[282] 짝이 되는 신청 1건. ON DELETE CASCADE — 캠페인 보관 삭제(255)가 신청을 '
  '즉시 파기할 때 입장 기록도 함께 파기되게 한다(개인정보 파기 원칙).';
COMMENT ON COLUMN public.event_tickets.entered_at IS
  '[282] 첫 입장 시각. 같은 QR 을 다시 확인해도 덮어쓰지 않는다(중복 감지는 scan_count).';
COMMENT ON COLUMN public.event_tickets.scan_count IS
  '[282] 입장 확인이 시도된 횟수. 2 이상이면 현장 화면이 「이미 입장 완료」로 표시한다. '
  '입장 자체를 막지는 않는다 — 재입장 판단은 사람이 한다(사양서 §2-8 U3).';
COMMENT ON COLUMN public.event_tickets.waitlist_position IS
  '[282] 대기 순번(1부터). 확정·취소면 NULL. 앞사람이 취소하면 283 이 다시 매긴다.';

-- ── updated_at 자동 갱신 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.touch_event_tickets_updated_at()
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

COMMENT ON FUNCTION public.touch_event_tickets_updated_at() IS
  '[282] event_tickets.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_event_tickets_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_event_tickets_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_tickets_updated_at ON public.event_tickets;
CREATE TRIGGER trg_event_tickets_updated_at
  BEFORE UPDATE ON public.event_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_event_tickets_updated_at();

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.event_tickets ENABLE ROW LEVEL SECURITY;

-- SELECT: 본인 티켓 또는 관리자 전체.
--   influencers.id = auth.users.id 이므로 influencer_id 를 auth.uid() 와 직접 비교한다.
--   (SELECT auth.uid()) 로 감싸는 것은 마이그레이션 137 의 InitPlan 최적화 패턴.
CREATE POLICY event_tickets_select_own ON public.event_tickets
  FOR SELECT TO authenticated
  USING (influencer_id = (SELECT auth.uid()));

CREATE POLICY event_tickets_select_admin ON public.event_tickets
  FOR SELECT TO authenticated
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 직접 정책은 두지 않는다.
--   예약번호 위조·정원 우회·입장 시각 조작을 막기 위해 쓰기는 전부
--   SECURITY DEFINER 함수(283)를 거친다(settlements 마이그레이션 217 과 같은 정신).

COMMIT;

-- ============================================================
-- 검증
-- ============================================================
-- 1) 표·정책 생성 확인
-- SELECT relrowsecurity FROM pg_class WHERE oid = 'public.event_tickets'::regclass;  -- t
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename='event_tickets' ORDER BY policyname;
--   → event_tickets_select_admin / event_tickets_select_own 2개(SELECT 만)
--
-- 2) 예약번호 형식 제약이 도는지
-- INSERT ... ticket_code = 'abc' → 23514 로 거부되어야 한다(소문자·길이 위반)
--
-- 3) 「한 캠페인에 1타임」 제약
--    같은 (campaign_id, influencer_id) 로 confirmed 티켓 2건 → 23505 거부.
--    앞 건을 cancelled 로 바꾸면 두 번째가 들어간다.
--
-- 4) ⚠️ 개인정보 파기 연쇄 실측 (작업표 stale 점검 7번 — 눈으로 확인 필수)
--    개발 데이터베이스에서 테스트 행사 캠페인 1건에 티켓을 만든 뒤
--      SELECT public.soft_delete_campaign('<campaign_id>');
--    실행 후
--      SELECT count(*) FROM public.event_tickets WHERE campaign_id = '<campaign_id>';
--    → 0 이어야 한다(신청 행이 파기되면서 연쇄 삭제).
--    0 이 아니면 개인정보 파기 원칙과 어긋나므로 즉시 보고.
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_event_tickets_updated_at ON public.event_tickets;
-- DROP FUNCTION IF EXISTS public.touch_event_tickets_updated_at();
-- DROP TABLE IF EXISTS public.event_tickets;   -- 정책·인덱스 함께 소멸
-- COMMIT;
