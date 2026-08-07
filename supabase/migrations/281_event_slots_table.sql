-- ============================================================
-- 281_event_slots_table.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 2/4 (타임 표)
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ②
-- 선행: 280 (캠페인 컬럼 3개)
--
-- event_slots = 「날짜 + 시각 + 정원」 한 줄. 사양서 용어로 **타임**(시간대).
--   3일 합계 32줄이 들어간다(사양서 §2-9 — 첫날 구간형 3줄 / 이틀차 16줄 /
--   삼일차 13줄). 캠페인 표의 컬럼으로는 표현할 수 없어 별도 표로 만든다.
--
-- 조회 범위 — 로그인한 사람 전체 (사양서 §0 결정 16):
--   초대 전용 캠페인의 타임 줄도 포함된다. 타임 목록(날짜·시각·잔여)만으로는
--   어느 브랜드 행사인지 알 수 없고, 캠페인 내용은 상세 게이트가, 실제 예약은
--   서버 함수의 초대 번호 재검증이 막는다. 가입 전 방문객의 이탈(§2-8 U7)을
--   막는 쪽을 택한 결정이다.
--   ⚠️ 이 표에는 **개인정보가 없다**(누가 예약했는지는 event_tickets 소관).
--
-- 정원(capacity) 판정은 이 표의 값이 한다:
--   campaigns.slots 에는 타임 정원 합계를 넣지만 그건 **표시용**이고 자동 갱신도
--   하지 않는다(사양서 §0 결정 15). 실제 마감 판정은 예약 함수가 이 표의
--   capacity 를 행 잠금 후 세어서 한다(283).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.event_slots (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id    uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,

  slot_date      date NOT NULL,
  start_time     time NOT NULL,
  end_time       time,                    -- 구간형(11:00~13:00)이 아니면 NULL 허용

  capacity       integer NOT NULL CHECK (capacity >= 0),

  -- 대상 표기(인플루언서 / 일반 고객). 서포터즈·브랜드사는 이 시스템 대상 아님
  -- (사양서 §0 결정 7 — 현장 명단으로 운영).
  audience_label text,

  is_active      boolean NOT NULL DEFAULT true,
  sort_order     integer NOT NULL DEFAULT 0,

  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- 같은 캠페인에 같은 날짜·같은 시작시각 줄이 두 번 들어가는 것을 막는다.
  -- (관리자의 「하루치 일괄 생성」을 두 번 눌러도 중복이 안 생긴다)
  CONSTRAINT event_slots_campaign_date_start_uniq
    UNIQUE (campaign_id, slot_date, start_time),

  -- 구간형일 때 끝시각이 시작시각보다 앞서지 않도록
  CONSTRAINT event_slots_time_order_chk
    CHECK (end_time IS NULL OR end_time > start_time)
);

COMMENT ON TABLE public.event_slots IS
  '[281] 오프라인 행사 타임(시간대) — 날짜+시각+정원 한 줄. 사양서 '
  'docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ②.';
COMMENT ON COLUMN public.event_slots.capacity IS
  '[281] 이 타임의 정원. 실제 마감 판정은 예약 함수(283)가 행 잠금 후 이 값과 '
  '확정 티켓 수를 비교해서 한다. campaigns.slots 는 표시용 합계일 뿐 판정에 쓰지 않는다.';
COMMENT ON COLUMN public.event_slots.end_time IS
  '[281] 구간형 타임(11:00~13:00)의 끝시각. 30분 단위 단일 시각이면 NULL 가능.';
COMMENT ON COLUMN public.event_slots.audience_label IS
  '[281] 대상 표기(인플루언서 / 일반 고객). 화면 표시용 자유 문자열 — 권한 판정에 쓰지 않는다.';
COMMENT ON COLUMN public.event_slots.is_active IS
  '[281] false 면 방문객 화면 타임 목록에서 감춘다(줄을 지우지 않고 닫는 수단). '
  '이미 발급된 티켓에는 영향 없다.';

CREATE INDEX IF NOT EXISTS event_slots_campaign_idx
  ON public.event_slots(campaign_id, slot_date, start_time);

-- ── updated_at 자동 갱신 (226·217 컨벤션 미러) ──────────────
CREATE OR REPLACE FUNCTION public.touch_event_slots_updated_at()
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

COMMENT ON FUNCTION public.touch_event_slots_updated_at() IS
  '[281] event_slots.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_event_slots_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_event_slots_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_slots_updated_at ON public.event_slots;
CREATE TRIGGER trg_event_slots_updated_at
  BEFORE UPDATE ON public.event_slots
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_event_slots_updated_at();

-- ── 예약이 걸린 타임은 지우지 못하게 막는다 ──────────────────
-- 타임을 지우면 그 타임의 티켓이 연쇄 삭제로 **소리 없이** 사라진다. 짝이 되는
-- 신청 행은 그대로 남아, 방문객 화면에는 「당선」이라고 뜨는데 예약번호(QR)는
-- 존재하지 않는 상태가 된다 — 안내도 없이 벌어지므로 아예 막는다.
-- (정산 걸린 캠페인 삭제를 막는 마이그레이션 251 과 같은 패턴)
-- 타임을 닫고 싶으면 지우는 대신 is_active=false 로 내린다.
CREATE OR REPLACE FUNCTION public.block_delete_event_slot_with_tickets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cnt integer;
BEGIN
  -- 캠페인이 통째로 지워지는 중이면 통과시킨다.
  --   캠페인 삭제는 부모 행이 먼저 사라진 뒤 연쇄 삭제가 도는데, 연쇄가 타임을
  --   티켓보다 먼저 지울 수도 있다(연쇄 순서는 보장되지 않는다). 그때 이 가드가
  --   걸리면 **캠페인 완전 삭제 자체가 실패**한다. 부모가 이미 없으면 통과.
  IF NOT EXISTS (SELECT 1 FROM public.campaigns c WHERE c.id = OLD.campaign_id) THEN
    RETURN OLD;
  END IF;

  SELECT count(*) INTO v_cnt
    FROM public.event_tickets t
   WHERE t.slot_id = OLD.id
     AND t.status <> 'cancelled';

  IF v_cnt > 0 THEN
    RAISE EXCEPTION
      'event_slot_has_tickets: 이 타임에 예약 %건이 있어 삭제할 수 없습니다. 모집을 닫으려면 「사용 안 함」으로 내려 주세요.', v_cnt
      USING ERRCODE = '22023';
  END IF;

  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION public.block_delete_event_slot_with_tickets() IS
  '[281] 예약(취소 아닌 티켓)이 남은 타임의 삭제를 막는다. 연쇄 삭제로 티켓만 사라지고 '
  '신청 행은 남아 「당선인데 예약번호 없음」이 되는 것을 방지.';

REVOKE ALL ON FUNCTION public.block_delete_event_slot_with_tickets() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.block_delete_event_slot_with_tickets() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_block_delete_event_slot ON public.event_slots;
CREATE TRIGGER trg_block_delete_event_slot
  BEFORE DELETE ON public.event_slots
  FOR EACH ROW
  EXECUTE FUNCTION public.block_delete_event_slot_with_tickets();

-- ⚠️ 이 트리거는 캠페인 삭제 경로를 막지 않는다 — 위 함수 첫 블록의 탈출구 참고.
--    (보관 삭제는 applications 를 먼저 파기해 티켓이 이미 0건이 되고, 완전 삭제는
--     부모 캠페인 행이 먼저 사라져 탈출구로 빠진다)

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.event_slots ENABLE ROW LEVEL SECURITY;

-- SELECT: 로그인한 사람 전체 (사양서 §0 결정 16).
--   개인정보가 없는 표이고, 초대 전용 캠페인의 보호는 ①목록 제외 ②상세 게이트
--   ③예약 함수의 초대 번호 재검증 세 겹이 담당한다.
CREATE POLICY event_slots_select ON public.event_slots
  FOR SELECT TO authenticated
  USING (true);

-- CUD: 캠페인 관리 권한 이상(is_campaign_admin) — 기준데이터류 직접 정책.
--   금전 트랜잭션이 아니라 원격 호출 함수 강제까지는 필요 없다(226 선례와 같은 판단).
CREATE POLICY event_slots_insert ON public.event_slots
  FOR INSERT TO authenticated
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY event_slots_update ON public.event_slots
  FOR UPDATE TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY event_slots_delete ON public.event_slots
  FOR DELETE TO authenticated
  USING (public.is_campaign_admin());

COMMIT;

-- ============================================================
-- 검증
-- ============================================================
-- 1) 표·정책 생성 확인
-- SELECT relrowsecurity FROM pg_class WHERE oid = 'public.event_slots'::regclass;  -- t
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename='event_slots' ORDER BY policyname;
--   → event_slots_delete/insert/select/update 4개
--
-- 2) 중복 방지 제약이 도는지(같은 캠페인·같은 날짜·같은 시작시각 두 번)
--    두 번째 INSERT 가 23505 로 거부되어야 한다.
--
-- 3) 캠페인 삭제 시 타임 줄이 함께 사라지는지(ON DELETE CASCADE)
--    ⚠️ 실측 필수 — 작업표 stale 점검 7번. 개발 데이터베이스에서 테스트 캠페인 1건을
--       완전 삭제(purge_campaign)해 event_slots 행이 0이 되는지 눈으로 확인.
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_event_slots_updated_at ON public.event_slots;
-- DROP FUNCTION IF EXISTS public.touch_event_slots_updated_at();
-- DROP TABLE IF EXISTS public.event_slots;   -- 정책·인덱스 함께 소멸
-- COMMIT;
