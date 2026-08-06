-- ═══════════════════════════════════════════════════════════════
-- 운영 배포 묶음 A — 오프라인 팝업 방문 예약 (마이그레이션 280~289, 291, 292)
-- 만든 날짜: 2026-08-06
--
-- ⚠️ 위에서부터 순서대로 한 번에 실행합니다. 파일마다 자체 트랜잭션이 있어
--    중간에서 실패하면 그 파일만 되돌아가고 앞의 것은 남습니다.
--    실패하면 어느 [파일 NNN] 구분선에서 멈췄는지 알려 주세요.
-- ⚠️ 291 과 292 는 반드시 함께 — 291 만 넣으면 행사 묶음 이름이
--    「REVERB팝업」과 「REVERB 팝업」을 다른 것으로 저장합니다.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- [파일 280] 280_event_campaign_columns.sql
-- ───────────────────────────────────────────────────────────────
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


-- ───────────────────────────────────────────────────────────────
-- [파일 281] 281_event_slots_table.sql
-- ───────────────────────────────────────────────────────────────
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


-- ───────────────────────────────────────────────────────────────
-- [파일 282] 282_event_tickets_table.sql
-- ───────────────────────────────────────────────────────────────
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


-- ───────────────────────────────────────────────────────────────
-- [파일 283] 283_event_ticket_functions.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 283_event_ticket_functions.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 4/4 (서버 함수 3개 + 승인 알림 행사 예외)
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-2 ④
-- 선행: 280 (캠페인 컬럼) · 281 (타임 표) · 282 (티켓 표)
--
-- 이 파일이 만드는 것:
--   1) reserve_event_ticket(slot, invite_code) — 자리를 잠그고 정원을 센 뒤 확정/대기
--   2) check_in_ticket(ticket_code)           — 현장 입장 확인(첫 입장 시각 보존)
--   3) cancel_event_ticket(ticket_id)         — 본인 취소 + 대기 1번 자동 승격
--   4) record_application_status_event() 재정의 — 행사 캠페인은 조기 반환
--      (로직은 154 와 동일하고 「행사 예외」 블록만 추가했다. 설명 주석 일부는
--       이 파일 길이를 줄이려 생략했으므로 154 원문과 글자 단위로 같지는 않다)
--   (+) notifications.kind 에 event_waitlist_promoted 추가 ★사양서에 없던 추가
--       (대기 → 확정 승격을 본인에게 알릴 방법이 없어 노쇼가 되는 문제.
--        사용자 확인 2026-08-03. 알림은 cancel_event_ticket 이 직접 넣는다 —
--        행사 캠페인은 상태 트리거가 조기 반환하므로 트리거로는 나가지 않는다)
--   (+) gen_event_ticket_code()   — 예약번호 생성(내부용)
--   (+) verify_event_invite()     — 초대 번호 일치 여부만 반환 ★사양서에 없던 추가
--   (+) get_event_slot_counts()   — 타임별 잔여 집계     ★사양서에 없던 추가
--
-- ★ 두 함수를 추가한 이유 (2026-08-03 구현 중 발견 — 사양서 §10 에 기록):
--    · verify_event_invite  — 초대 번호를 캠페인 표에서 event_invites 로 옮기면서
--      (280 헤더 ⚠️ 참고) 방문객이 번호를 확인할 경로가 필요해졌다. 번호를 돌려주지
--      않고 「맞나/틀리나」 한 비트만 답한다.
--    · get_event_slot_counts — 방문객은 남의 티켓 행을 볼 수 없어(282 행 단위 보안 정책)
--      브라우저에서 「잔여 N명」을 셀 수 없다. 작업표 계약에 fetchEventSlotCounts()
--      는 있었지만 그 숫자를 만들어 줄 서버 쪽이 빠져 있었다.
--
-- ⚠️ 4)를 함께 넣는 이유 (사양서 §4-2 ④ 「행사 모드 예외를 넣는다」):
--    ① 기존 승인 알림 문구가 「キャンペーンに当選しました。成果物の提出をお願いします。」
--       라서 결과물을 내지 않는 행사 방문객에게 부적합하다(사양서 §0 결정 14 —
--       예약 확정 안내는 화면이 대신한다).
--    ② 대기 승격은 **다른 방문객의 취소 트랜잭션 안에서** 일어난다. 그대로 두면
--       application_events 에 「approve — 처리자: 취소한 방문객」이라는 사실과 다른
--       감사 기록이 쌓인다. 행사 예약의 상태 이력은 event_tickets 가 갖는다.
--    → 그래서 알림만이 아니라 이 트리거 전체를 행사 캠페인에서 건너뛴다.
--      일반 캠페인 동작은 한 글자도 바뀌지 않는다.
--    ⚠️ 재정의 베이스는 **154**다(131 아님). record_application_status_event 의
--       정의를 가진 파일은 131·154 둘뿐이고 번호가 큰 154 가 현재 유효한 원본이다.
--
-- ── 신청 행 처리 규칙 (282 헤더 주석과 한 세트) ──────────────────
--   확정 → 신청 approved / 대기 → 신청 pending / 취소 → 신청 cancelled.
--   재예약은 **취소된 신청 행을 되살린다**(새 행을 만들지 않는다) — 신청 표에
--   아직 남아 있는 옛 유일 제약(050) 때문. 상세는 282 헤더 주석.
--
-- ⚠️ 연령·마감 검사를 이 함수 안에서도 명시적으로 하는 이유:
--    연령(180)·마감(272) 가드는 **BEFORE INSERT 전용** 트리거라, 되살리기(UPDATE)
--    경로에는 발동하지 않는다. 두 경로의 판정이 달라지면 안 되므로 함수가 먼저
--    한 번 검사하고, 트리거는 INSERT 경로의 최종 방어선으로 그대로 남긴다
--    (트리거를 고치지 않는다 — 다른 모든 캠페인이 쓰는 공유 지점).
--    통과 조항(관리자 예외)도 트리거와 똑같이 맞춘다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 0-a. 알림 종류 확장 — 대기 승격 안내
-- ============================================================
-- 앞사람이 취소해 대기자가 확정으로 올라가면, 본인이 앱에 들어와 보기 전까지
-- 그 사실을 모른다 → 그대로 안 오게 된다(노쇼). 사양서는 확정 안내 **메일**만
-- 2차로 미뤘고(§0 결정 11) 앱 알림은 언급이 없어, 사용자 확인(2026-08-03)을 거쳐
-- 앱 알림 1종을 1차 범위에 넣는다.
--   ⚠️ 현행 목록의 원본은 **273**이다(번호가 가장 큰 정의). 273 의 10종을 그대로
--      옮기고 마지막 1종만 더한다 — 하나라도 빠뜨리면 그 종류의 알림이 CHECK 위반으로
--      전부 실패한다.
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved',
    'deliverable_proxy_submitted',
    'settlement_paypal_required',
    'settlement_paid',
    'submission_deadline_changed',
    'event_waitlist_promoted'   -- 283 신규: 대기 → 확정 승격 안내
  ));

COMMENT ON COLUMN public.notifications.kind IS
  'deliverable_rejected | deliverable_changed | deliverable_approved | application_cancelled | '
  'message_received | application_approved | deliverable_proxy_submitted | '
  'settlement_paypal_required | settlement_paid | submission_deadline_changed | '
  'event_waitlist_promoted';

-- ============================================================
-- 0. 예약번호 생성 헬퍼
-- ============================================================
-- 현장에서 손으로 입력하는 번호라 혼동하기 쉬운 글자를 뺀다:
--   0/O · 1/I/L 제외 → 대문자 23자 + 숫자 8자 = 31자 집합.
--   8자리면 31^8 ≈ 8,527억 가지 — 3일 행사 규모에서 추측·도용은 실질 불가능하고,
--   확인 화면에 이름이 함께 떠서 운영진이 눈으로 대조한다(사양서 §8).
CREATE OR REPLACE FUNCTION public.gen_event_ticket_code()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code     text;
  v_try      integer := 0;
  i          integer;
BEGIN
  LOOP
    v_try := v_try + 1;
    v_code := '';
    FOR i IN 1..8 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    END LOOP;

    -- 이미 쓰인 번호면 다시 뽑는다(충돌 확률은 극히 낮지만 유일 제약이 있으므로 확인).
    IF NOT EXISTS (SELECT 1 FROM public.event_tickets t WHERE t.ticket_code = v_code) THEN
      RETURN v_code;
    END IF;

    IF v_try >= 20 THEN
      RAISE EXCEPTION 'ticket_code_generation_failed: 예약번호 생성에 실패했습니다'
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.gen_event_ticket_code() IS
  '[283] 예약번호(대문자 영숫자 8자리) 생성. 손입력 오류를 줄이려 0 O 1 I L 을 뺀 31자 집합 사용.';

REVOKE ALL ON FUNCTION public.gen_event_ticket_code() FROM PUBLIC;

-- ============================================================
-- 0-b. verify_event_invite — 초대 번호가 맞는지만 답한다
-- ============================================================
-- 상세 화면 게이트(작업 5)가 쓴다. 번호 자체는 절대 돌려주지 않는다 —
-- 「맞다/틀리다」 한 비트만 나간다. 비공개가 아닌 캠페인은 항상 true(게이트 없음).
CREATE OR REPLACE FUNCTION public.verify_event_invite(
  p_campaign_id uuid,
  p_code        text
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_invite_only boolean;
  v_code        text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT c.is_invite_only INTO v_invite_only
    FROM public.campaigns c
   WHERE c.id = p_campaign_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- 공개 캠페인은 초대 개념이 없다.
  IF NOT COALESCE(v_invite_only, false) THEN
    RETURN true;
  END IF;

  SELECT i.code INTO v_code
    FROM public.event_invites i
   WHERE i.campaign_id = p_campaign_id;

  -- 번호 미발급 비공개 캠페인은 아무도 통과하지 못한다(fail-closed).
  IF v_code IS NULL OR p_code IS NULL THEN
    RETURN false;
  END IF;

  RETURN upper(btrim(p_code)) = upper(btrim(v_code));
END;
$$;

COMMENT ON FUNCTION public.verify_event_invite(uuid, text) IS
  '[283] 초대 번호 일치 여부만 돌려준다(번호 자체는 노출하지 않는다). 화면 게이트 전용이며 '
  '실효 방어선은 reserve_event_ticket 의 재검증이다 — 이 함수를 우회해도 예약은 막힌다.';

REVOKE ALL ON FUNCTION public.verify_event_invite(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_event_invite(uuid, text) TO authenticated;

-- ============================================================
-- 0-c. get_event_slot_counts — 타임별 확정·대기 수
-- ============================================================
-- ⚠️ 작업표 계약에 fetchEventSlotCounts() 는 있었지만 서버 쪽이 없었다(2026-08-03 발견).
--    방문객은 남의 티켓을 볼 수 없으므로(event_tickets 행 단위 보안 정책) 브라우저에서
--    직접 셀 수 없다. 「잔여 N명 / 마감」을 그리려면 서버가 숫자만 내려줘야 한다.
--    개인정보는 한 건도 나가지 않는다 — 타임 식별자와 개수뿐이다.
CREATE OR REPLACE FUNCTION public.get_event_slot_counts(
  p_campaign_id uuid
) RETURNS TABLE (
  slot_id         uuid,
  capacity        integer,
  confirmed_count bigint,
  waitlist_count  bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    s.id,
    s.capacity,
    count(t.id) FILTER (WHERE t.status = 'confirmed') AS confirmed_count,
    count(t.id) FILTER (WHERE t.status = 'waitlist')  AS waitlist_count
  FROM public.event_slots s
  LEFT JOIN public.event_tickets t ON t.slot_id = s.id
  WHERE s.campaign_id = p_campaign_id
    AND auth.uid() IS NOT NULL
  GROUP BY s.id, s.capacity;
$$;

COMMENT ON FUNCTION public.get_event_slot_counts(uuid) IS
  '[283] 타임별 정원·확정 수·대기 수. 방문객 화면의 잔여 표시용 — 개인정보는 나가지 않는다. '
  '방문객은 남의 티켓 행을 볼 수 없어 브라우저에서 직접 셀 수 없으므로 서버가 숫자만 내려준다.';

REVOKE ALL ON FUNCTION public.get_event_slot_counts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_slot_counts(uuid) TO authenticated;

-- ============================================================
-- 1. reserve_event_ticket — 예약(확정 또는 대기)
-- ============================================================
CREATE OR REPLACE FUNCTION public.reserve_event_ticket(
  p_slot_id     uuid,
  p_invite_code text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := auth.uid();
  v_slot           public.event_slots%ROWTYPE;
  v_camp           public.campaigns%ROWTYPE;
  v_inf            public.influencers%ROWTYPE;
  v_today_jst      date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_is_admin       boolean;
  v_age            integer;
  v_age_effective  date;
  v_confirmed_cnt  integer;
  v_status         text;
  v_app_status     text;
  v_app_id         uuid;
  v_invite_code    text;
  v_ticket_id      uuid;
  v_code           text;
  v_position       integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  v_is_admin := public.is_admin();

  -- ── 타임 행 잠금 (동시 신청 직렬화) ───────────────────────────
  -- 마지막 한 자리를 여러 명이 동시에 눌러도 정원을 넘지 않게, 정원을 세기 전에
  -- 타임 행 자체를 잠근다. 같은 타임을 노리는 다른 트랜잭션은 여기서 대기한다.
  SELECT * INTO v_slot
    FROM public.event_slots
   WHERE id = p_slot_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF NOT v_slot.is_active THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  SELECT * INTO v_camp FROM public.campaigns WHERE id = v_slot.campaign_id;
  IF NOT FOUND OR NOT v_camp.event_mode THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 행사 모드는 방문형에만 켤 수 있다(280 의 CHECK 제약과 같은 판정).
  -- 리뷰어형이면 049(자동 승인)·048(정원 가드)이 끼어들어 티켓과 신청 상태가
  -- 어긋나므로, 제약이 어떤 이유로 우회되더라도 여기서 한 번 더 막는다.
  IF COALESCE(v_camp.recruit_type, '') <> 'visit' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_campaign_type');
  END IF;

  -- 보관 삭제된 캠페인은 예약을 받지 않는다.
  IF v_camp.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  -- ── 초대 전용 재검증 (최종 방어선) ────────────────────────────
  -- 화면 게이트(목록 제외·상세 게이트)를 우회해 이 함수를 직접 불러도 여기서 막힌다.
  -- 번호는 event_invites 표에서 읽는다 — 캠페인 표에 두면 공개 조회로 유출된다(280 헤더 ⚠️).
  IF v_camp.is_invite_only THEN
    SELECT i.code INTO v_invite_code
      FROM public.event_invites i
     WHERE i.campaign_id = v_camp.id;

    -- 번호가 아직 발급되지 않은 비공개 캠페인은 아무도 예약할 수 없다(fail-closed).
    IF v_invite_code IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF p_invite_code IS NULL OR btrim(p_invite_code) = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF upper(btrim(p_invite_code)) <> upper(btrim(v_invite_code)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_mismatch');
    END IF;
  END IF;

  -- ── 모집 마감 (272 트리거와 같은 판정·같은 예외) ──────────────
  IF NOT v_is_admin
     AND v_camp.deadline IS NOT NULL
     AND v_today_jst > v_camp.deadline THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'deadline_passed');
  END IF;

  -- ── 만 18세 (180 트리거와 같은 판정·같은 예외) ────────────────
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF NOT v_is_admin THEN
    SELECT effective_date INTO v_age_effective
      FROM public.age_policy_settings WHERE id = 1;

    IF v_age_effective IS NOT NULL AND v_today_jst >= v_age_effective THEN
      IF v_inf.birthdate IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'birthdate_required');
      END IF;
      v_age := public.calc_age_kst(v_inf.birthdate);
      IF v_age < 18 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'under_age');
      END IF;
    END IF;
  END IF;

  -- ── 한 캠페인에 1타임 (사양서 §0 결정 4) ──────────────────────
  IF EXISTS (
    SELECT 1 FROM public.event_tickets t
     WHERE t.campaign_id   = v_camp.id
       AND t.influencer_id = v_uid
       AND t.status <> 'cancelled'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_applied');
  END IF;

  -- ── 정원 판정 (잠근 상태에서 센다) ────────────────────────────
  SELECT count(*) INTO v_confirmed_cnt
    FROM public.event_tickets t
   WHERE t.slot_id = v_slot.id
     AND t.status  = 'confirmed';

  IF v_confirmed_cnt < v_slot.capacity THEN
    v_status     := 'confirmed';
    v_app_status := 'approved';
    v_position   := NULL;
  ELSE
    v_status     := 'waitlist';
    v_app_status := 'pending';
    SELECT COALESCE(max(t.waitlist_position), 0) + 1 INTO v_position
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot.id
       AND t.status  = 'waitlist';
  END IF;

  -- ── 신청 행 확보 ──────────────────────────────────────────────
  -- 기존 행이 있으면(= 취소 후 재예약) 되살리고, 없으면 새로 만든다.
  -- 새로 만드는 경로는 연령·마감 트리거가 한 번 더 확인한다(최종 방어선).
  SELECT id INTO v_app_id
    FROM public.applications
   WHERE user_id = v_uid AND campaign_id = v_camp.id
   FOR UPDATE;

  IF v_app_id IS NULL THEN
    INSERT INTO public.applications (
      user_id, user_email, user_name, user_followers, user_ig,
      campaign_id, message, address, status
    ) VALUES (
      v_uid,
      v_inf.email,
      COALESCE(NULLIF(btrim(COALESCE(v_inf.name_kanji, '')), ''), v_inf.name, v_inf.email),
      COALESCE(v_inf.followers, 0),
      COALESCE(v_inf.ig, ''),
      v_camp.id,
      '',   -- 행사 모드는 신청 이유를 받지 않는다(사양서 §4-3)
      '',   -- 행사 모드는 배송지를 받지 않는다(배송이 없다)
      v_app_status
    )
    RETURNING id INTO v_app_id;
  ELSE
    UPDATE public.applications
       SET status             = v_app_status,
           cancelled_at       = NULL,
           cancel_reason      = NULL,
           cancel_reason_code = NULL,
           cancel_phase       = NULL,
           previous_status    = NULL
     WHERE id = v_app_id;
  END IF;

  -- ── 티켓 발급 ─────────────────────────────────────────────────
  v_code := public.gen_event_ticket_code();

  INSERT INTO public.event_tickets (
    slot_id, campaign_id, influencer_id, application_id,
    ticket_code, status, waitlist_position
  ) VALUES (
    v_slot.id, v_camp.id, v_uid, v_app_id,
    v_code, v_status, v_position
  )
  RETURNING id INTO v_ticket_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'ticket_id',         v_ticket_id,
    'ticket_code',       v_code,
    'status',            v_status,
    'waitlist_position', v_position,
    'slot', jsonb_build_object(
      'slot_date',      v_slot.slot_date,
      'start_time',     v_slot.start_time,
      'end_time',       v_slot.end_time,
      'audience_label', v_slot.audience_label
    )
  );
END;
$$;

COMMENT ON FUNCTION public.reserve_event_ticket(uuid, text) IS
  '[283] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 대기로 등록하고 '
  '짝이 되는 신청 행까지 같은 트랜잭션에서 만든다. 실패는 예외가 아니라 '
  '{ok:false, reason:...} 로 돌려준다(화면이 사유별 안내 문구를 고른다).';

REVOKE ALL ON FUNCTION public.reserve_event_ticket(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_event_ticket(uuid, text) TO authenticated;

-- ============================================================
-- 2. check_in_ticket — 현장 입장 확인
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_in_ticket(
  p_ticket_code text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_ticket     public.event_tickets%ROWTYPE;
  v_slot       public.event_slots%ROWTYPE;
  v_inf        public.influencers%ROWTYPE;
  v_code       text;
  v_admin_name text;
  v_already    boolean;
  v_first_at   timestamptz;
BEGIN
  -- 현장 확인은 관리자만. 자립형 페이지(작업 7)도 관리자 로그인 상태로 호출한다.
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  v_code := upper(btrim(COALESCE(p_ticket_code, '')));
  IF v_code = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE ticket_code = v_code
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO v_slot FROM public.event_slots   WHERE id = v_ticket.slot_id;
  SELECT * INTO v_inf  FROM public.influencers   WHERE id = v_ticket.influencer_id;

  -- 취소·대기 티켓은 입장 대상이 아니다. 이름·타임은 함께 돌려준다 —
  -- 운영진이 「누구의 어떤 예약이 왜 안 되는지」를 그 자리에서 설명할 수 있어야 한다.
  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'cancelled',
      'name_kanji', v_inf.name_kanji, 'name_kana', v_inf.name_kana,
      'slot', jsonb_build_object('slot_date', v_slot.slot_date,
                                 'start_time', v_slot.start_time,
                                 'end_time', v_slot.end_time,
                                 'audience_label', v_slot.audience_label));
  END IF;

  IF v_ticket.status = 'waitlist' THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'waitlist_cannot_enter',
      'waitlist_position', v_ticket.waitlist_position,
      'name_kanji', v_inf.name_kanji, 'name_kana', v_inf.name_kana,
      'slot', jsonb_build_object('slot_date', v_slot.slot_date,
                                 'start_time', v_slot.start_time,
                                 'end_time', v_slot.end_time,
                                 'audience_label', v_slot.audience_label));
  END IF;

  -- ── 확정 티켓: 첫 입장 시각은 보존하고 확인 횟수만 올린다 ─────
  v_already  := (v_ticket.entered_at IS NOT NULL);
  v_first_at := v_ticket.entered_at;

  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  IF v_already THEN
    UPDATE public.event_tickets
       SET scan_count = scan_count + 1,
           version    = version + 1
     WHERE id = v_ticket.id;
  ELSE
    v_first_at := now();
    UPDATE public.event_tickets
       SET entered_at      = v_first_at,
           entered_by      = v_uid,
           entered_by_name = v_admin_name,
           scan_count      = scan_count + 1,
           version         = version + 1
     WHERE id = v_ticket.id;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'ticket_id',       v_ticket.id,
    'ticket_code',     v_ticket.ticket_code,
    'status',          v_ticket.status,
    'already_entered', v_already,
    'entered_at',      v_first_at,
    'scan_count',      v_ticket.scan_count + 1,
    'name_kanji',      v_inf.name_kanji,
    'name_kana',       v_inf.name_kana,
    'slot', jsonb_build_object(
      'slot_date',      v_slot.slot_date,
      'start_time',     v_slot.start_time,
      'end_time',       v_slot.end_time,
      'audience_label', v_slot.audience_label
    )
  );
END;
$$;

COMMENT ON FUNCTION public.check_in_ticket(text) IS
  '[283] 예약번호로 입장 확인. 첫 입장 시각은 재확인해도 덮어쓰지 않고 확인 횟수만 올린다. '
  '이미 입장한 티켓도 ok:true 로 돌려주되 already_entered=true 로 표시한다 — 입장을 막지 않고 '
  '재입장 판단은 사람이 한다(사양서 §2-8 U3). 관리자 화면의 「입장 처리」 버튼도 이 함수를 쓴다.';

REVOKE ALL ON FUNCTION public.check_in_ticket(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_in_ticket(text) TO authenticated;

-- ============================================================
-- 3. cancel_event_ticket — 본인 취소 + 대기 1번 승격
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_event_ticket(
  p_ticket_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_ticket       public.event_tickets%ROWTYPE;
  v_slot         public.event_slots%ROWTYPE;
  v_slot_start   timestamptz;
  v_promoted     public.event_tickets%ROWTYPE;
  v_promoted_id  uuid := NULL;
  v_camp_title   text;
  v_pos          integer := 0;
  r              record;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE id = p_ticket_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 본인 것만. 관리자라도 이 함수로는 남의 티켓을 취소할 수 없다(대리 취소 경로는 없다).
  IF v_ticket.influencer_id <> v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancelled');
  END IF;

  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- ── 송금 완료된 정산이 걸려 있으면 취소하지 않는다 ────────────
  -- 행사 캠페인은 리워드 0 이라 정산 후보에서 제외되지만(마이그레이션 264),
  -- 관리자가 리워드를 실수로 넣으면 정산이 생길 수 있다. 그 상태에서 신청을
  -- cancelled 로 바꾸면 마이그레이션 247 의 가드 트리거가 **예외**를 던져
  -- 트랜잭션 전체(취소·대기 승격)가 롤백되고, 그 예외 문구는 관리자용 한국어라
  -- 일본어 화면의 방문객에게 그대로 노출된다.
  -- → 예외가 나기 전에 여기서 표준 응답으로 돌려준다(이 함수의 계약 유지).
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- ── 취소 마감: 예약 타임 시작 2시간 전까지 (사양서 §0 결정 10) ──
  -- 기기 시각을 믿지 않는다 — 일본 시각 기준으로 서버가 판정한다.
  -- 타임 행도 잠근다(같은 타임의 다른 취소·예약과 순번 재정렬이 엉키지 않게).
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  v_slot_start := (v_slot.slot_date + v_slot.start_time) AT TIME ZONE 'Asia/Tokyo';

  IF now() > (v_slot_start - interval '2 hours') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancel_window_passed');
  END IF;

  -- ── 취소 처리 ─────────────────────────────────────────────────
  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    -- previous_status 는 **신청 표의 상태값**을 담는 칸이다(pending/approved).
    -- 티켓 상태(confirmed/waitlist)를 그대로 넣으면 응모 이력·통계가 읽지 못하는
    -- 값이 들어가므로 짝이 되는 신청 상태로 바꿔 넣는다.
    UPDATE public.applications
       SET status          = 'cancelled',
           previous_status  = CASE v_ticket.status
                                WHEN 'confirmed' THEN 'approved'
                                ELSE 'pending'
                              END,
           cancelled_at    = now(),
           cancel_phase    = 'other'
     WHERE id = v_ticket.application_id;
  END IF;

  -- ── 확정 자리가 빠졌으면 대기 1번을 승격 ──────────────────────
  IF v_ticket.status = 'confirmed' THEN
    SELECT * INTO v_promoted
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot.id
       AND t.status  = 'waitlist'
     ORDER BY t.waitlist_position NULLS LAST, t.created_at
     LIMIT 1
     FOR UPDATE;

    IF FOUND THEN
      UPDATE public.event_tickets
         SET status            = 'confirmed',
             waitlist_position = NULL,
             version           = version + 1
       WHERE id = v_promoted.id;

      -- 짝이 되는 신청도 심사중 → 당선으로.
      -- 이 UPDATE 는 트리거(154 재정의)를 발동시키지만 행사 캠페인은 조기 반환이라
      -- 알림도 감사 기록도 남지 않는다(파일 헤더 ⚠️ 참조).
      IF v_promoted.application_id IS NOT NULL THEN
        UPDATE public.applications
           SET status = 'approved'
         WHERE id = v_promoted.application_id;
      END IF;

      -- ── 승격된 사람에게 앱 알림 ──────────────────────────────
      -- 트리거가 아니라 여기서 직접 넣는다(행사 캠페인은 트리거가 조기 반환하므로).
      -- 인플루언서 대상이라 문구는 일본어. 링크는 티켓 화면으로 보낸다.
      --
      -- ⚠️ 알림 INSERT 만 예외를 삼킨다(이 프로젝트의 154 승인 알림과 다른 처리).
      --    이 함수의 본래 목적은 **빈 자리를 대기자에게 넘기는 것**이다. 알림이
      --    어떤 이유로든 실패했을 때(예: 나중에 누가 알림 종류 목록을 바꾸며 이
      --    종류를 빠뜨리면) 예외가 트랜잭션 전체를 되돌려 **취소도 승격도 무산**된다.
      --    「알림은 못 갔지만 자리는 넘어갔다」가 그 반대보다 낫다.
      --    154 는 관리자 액션이라 사람이 다시 누르면 되지만, 여기는 방문객 동작이다.
      BEGIN
        SELECT c.title INTO v_camp_title
          FROM public.campaigns c
         WHERE c.id = v_ticket.campaign_id;

        INSERT INTO public.notifications (
          user_id, kind, ref_table, ref_id, title, body
        ) VALUES (
          v_promoted.influencer_id,
          'event_waitlist_promoted',
          'event_tickets',
          v_promoted.id,
          'キャンセル待ちから予約が確定しました',
          COALESCE(v_camp_title, 'イベント')
            || 'のご予約が確定しました。'
            || to_char(v_slot.slot_date, 'MM月DD日')
            || ' ' || to_char(v_slot.start_time, 'HH24:MI')
            || ' にご来場ください。入場チケットからQRコードをご確認いただけます。'
        );
      EXCEPTION WHEN OTHERS THEN
        -- 알림 실패는 취소·승격을 막지 않는다. 승격 자체는 티켓·신청 상태로 남는다.
        NULL;
      END;

      v_promoted_id := v_promoted.id;
    END IF;
  END IF;

  -- ── 남은 대기자 순번 다시 매기기 ──────────────────────────────
  FOR r IN
    SELECT t.id
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot.id
       AND t.status  = 'waitlist'
     ORDER BY t.waitlist_position NULLS LAST, t.created_at
  LOOP
    v_pos := v_pos + 1;
    UPDATE public.event_tickets SET waitlist_position = v_pos WHERE id = r.id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                 true,
    'ticket_id',          v_ticket.id,
    'status',             'cancelled',
    'promoted_ticket_id', v_promoted_id
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_event_ticket(uuid) IS
  '[283] 본인 예약 취소. 예약 타임 시작 2시간 전까지만(일본 시각 기준 서버 판정). '
  '확정 자리가 빠지면 같은 타임 대기 1번을 자동 승격하고 남은 순번을 다시 매긴다. '
  '취소해도 신청 행은 지우지 않고 cancelled 로 남겨, 재예약 때 그 행을 되살린다.';

REVOKE ALL ON FUNCTION public.cancel_event_ticket(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_event_ticket(uuid) TO authenticated;

-- ============================================================
-- 4. record_application_status_event() 재정의 — 행사 캠페인 조기 반환
--    베이스 = 154 (현재 유효한 원본). 아래 「행사 예외」 블록 8줄만 추가하고
--    나머지는 154 와 한 글자도 다르지 않다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_application_status_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_action           text;
  v_admin_name       text;
  v_camp_title       text;
  v_already_notified boolean;
  v_event_mode       boolean;
BEGIN
  -- no-op (status 동일) 스킵
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ── [283 추가] 행사 캠페인 예외 ──────────────────────────────
  -- 행사(티켓) 캠페인의 신청 상태 변화는 예약 함수가 만들어 낸 부산물이고,
  -- 상태 이력은 event_tickets 가 갖는다. 여기서 조기 반환하는 이유 2가지:
  --   ① 승인 알림 문구가 결과물 제출을 요구해 방문객에게 부적합(사양서 §0 결정 14)
  --   ② 대기 승격은 다른 방문객의 취소 트랜잭션에서 일어나 changed_by 가
  --      「취소한 방문객」으로 찍힌다 — 사실과 다른 감사 기록이 쌓인다
  -- 일반 캠페인 동작은 바뀌지 않는다.
  SELECT c.event_mode INTO v_event_mode
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  IF COALESCE(v_event_mode, false) THEN
    RETURN NEW;
  END IF;
  -- ── [283 추가] 끝 ────────────────────────────────────────────

  -- ── 운영자 액션 매핑 ─────────────────────────────────────────
  v_action := CASE
    WHEN OLD.status = 'pending'                AND NEW.status = 'approved' THEN 'approve'
    WHEN OLD.status = 'pending'                AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status IN ('approved','rejected') AND NEW.status = 'pending'  THEN 'revert_to_pending'
    WHEN OLD.status = 'approved'               AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status = 'rejected'               AND NEW.status = 'approved' THEN 'approve'
    ELSE NULL
  END;

  IF v_action IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT a.name INTO v_admin_name
    FROM public.admins a
   WHERE a.auth_id = auth.uid();

  INSERT INTO public.application_events (
    application_id, action, from_status, to_status, changed_by, changed_by_name, memo
  ) VALUES (
    NEW.id, v_action, OLD.status, NEW.status, auth.uid(), v_admin_name, NULL
  );

  IF NEW.status = 'approved' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.notifications
       WHERE user_id   = NEW.user_id
         AND kind      = 'application_approved'
         AND ref_table = 'applications'
         AND ref_id    = NEW.id
         AND read_at   IS NULL
    ) INTO v_already_notified;

    IF NOT v_already_notified THEN
      SELECT title INTO v_camp_title
        FROM public.campaigns
       WHERE id = NEW.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        NEW.user_id,
        'application_approved',
        'applications',
        NEW.id,
        'キャンペーンに当選しました',
        COALESCE(v_camp_title, 'キャンペーン') || 'に当選しました。成果物の提出をお願いします。'
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_application_status_event() IS
  '[131+154+283] applications.status 변경 시 application_events 자동 INSERT '
  '+ approved 전이 시 승인 알림 INSERT. [283] 행사(event_mode) 캠페인은 조기 반환 — '
  '알림 문구가 방문객에게 부적합하고, 대기 승격이 다른 사람의 트랜잭션에서 일어나 '
  '감사 기록의 처리자가 사실과 달라지기 때문. 트리거 trg_application_status_event(131) 재사용.';

COMMIT;

-- 새 원격 호출 함수가 한꺼번에 여러 개 생기므로 API 계층 스키마 캐시를 새로 읽게 한다.
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 함수 4개 존재 확인
-- SELECT proname, pronargs FROM pg_proc
--  WHERE pronamespace = 'public'::regnamespace
--    AND proname IN ('reserve_event_ticket','check_in_ticket','cancel_event_ticket',
--                    'gen_event_ticket_code','record_application_status_event')
--  ORDER BY proname;
--
-- 2) 스모크 호출 (관리자 계정으로 SQL Editor 아님 — 아래 3) 참고)
--    SQL Editor 는 서비스 키라 auth.uid() 가 NULL 이다. 그래서 관리자 가드가 있는
--    check_in_ticket 은 SQL Editor 에서 permission_denied 를 돌려주는 것이 **정상**이다.
--    → 형식 확인만:
-- SELECT public.check_in_ticket('ZZZZZZZZ');
--    → {"ok": false, "reason": "permission_denied"}  (SQL Editor 기준)
--    관리자 브라우저 세션에서 같은 호출을 하면 {"ok": false, "reason": "not_found"} 가 나온다.
--
-- 3) ⚠️ reserve_event_ticket · cancel_event_ticket 은 여기서 검증하지 않는다.
--    「본인 계정만」 가드가 있어 서비스 키로 붙는 SQL Editor 로는 방문객 동작을
--    재현할 수 없다(사양서 §4-2 함정 — 마감 서버 강제에서 같은 함정을 겪었다).
--    정원 마감·대기 등록·취소·승격은 **방문객 화면(작업 3·4) 완성 후 테스트 계정
--    2개로 브라우저에서** 확인한다.
--
-- 4) 일반 캠페인 회귀 확인 (154 동작이 그대로인지)
--    행사가 아닌 캠페인의 신청 1건을 심사중 → 승인으로 바꾸고
-- SELECT count(*) FROM public.application_events WHERE application_id = '<id>';   -- +1
-- SELECT count(*) FROM public.notifications
--  WHERE ref_table='applications' AND ref_id='<id>' AND kind='application_approved';  -- +1
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.cancel_event_ticket(uuid);
-- DROP FUNCTION IF EXISTS public.check_in_ticket(text);
-- DROP FUNCTION IF EXISTS public.reserve_event_ticket(uuid, text);
-- DROP FUNCTION IF EXISTS public.get_event_slot_counts(uuid);
-- DROP FUNCTION IF EXISTS public.verify_event_invite(uuid, text);
-- DROP FUNCTION IF EXISTS public.gen_event_ticket_code();
-- -- record_application_status_event 는 154 정의로 되돌린다
-- --   (154 파일의 CREATE OR REPLACE 블록을 그대로 재실행하면 된다)
-- -- 알림 종류 목록은 273 의 10종으로 되돌린다
-- ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
-- ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--   'deliverable_rejected','deliverable_changed','deliverable_approved',
--   'application_cancelled','message_received','application_approved',
--   'deliverable_proxy_submitted','settlement_paypal_required','settlement_paid',
--   'submission_deadline_changed'
-- ));
-- --   ⚠️ 되돌리기 전에 event_waitlist_promoted 알림 행을 먼저 지워야 한다
-- --      (남아 있으면 CHECK 추가가 실패한다):
-- --   DELETE FROM public.notifications WHERE kind = 'event_waitlist_promoted';
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 284] 284_reserve_event_ticket_caution.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 284_reserve_event_ticket_caution.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 주의사항 동의 기록
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-3
-- 선행: 280 · 281 · 282 · 283
--
-- 왜 필요한가 (2026-08-03 리뷰 지적):
--   사양서 §4-3 은 행사 모드 신청 모달에서 **주의사항 동의만** 받는다고 정했고
--   화면도 그렇게 만들었다(체크 안 하면 제출 차단). 그런데 283 의
--   reserve_event_ticket 은 동의를 받을 인자가 아예 없어 applications INSERT 에
--   caution_agreed_at·caution_snapshot 이 빠져 있었다.
--   → **체크는 강제하는데 그 동의가 어디에도 남지 않는** 상태였다.
--   일반 캠페인은 이 두 값을 신청 행에 저장해 사후 분쟁의 근거로 쓴다
--   (마이그레이션 067 · CLAUDE.md 「주의사항 동의」). 행사만 예외일 이유가 없다.
--
-- 무엇을 바꾸나:
--   reserve_event_ticket 에 인자 2개(p_caution_agreed_at, p_caution_snapshot)를 더하고,
--   신청 행을 만들거나 되살릴 때 두 값을 함께 넣는다. 나머지 로직은 283 그대로다.
--
-- ⚠️ 인자가 늘어 시그니처가 바뀐다. 옛 2인자 함수를 **먼저 DROP** 한다 —
--    남겨 두면 같은 이름의 함수가 둘이 되어(오버로드) 호출이 어느 쪽으로 갈지
--    모호해지고, 인자를 안 넘긴 옛 호출이 조용히 동의 없이 예약을 만든다.
--
-- ⚠️ 재정의 베이스는 **283**(현재 유효한 유일한 정의)다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- 옛 2인자 정의 제거 (오버로드 방지)
DROP FUNCTION IF EXISTS public.reserve_event_ticket(uuid, text);

CREATE OR REPLACE FUNCTION public.reserve_event_ticket(
  p_slot_id            uuid,
  p_invite_code        text        DEFAULT NULL,
  p_caution_agreed_at  timestamptz DEFAULT NULL,
  p_caution_snapshot   jsonb       DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := auth.uid();
  v_slot           public.event_slots%ROWTYPE;
  v_camp           public.campaigns%ROWTYPE;
  v_inf            public.influencers%ROWTYPE;
  v_today_jst      date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_is_admin       boolean;
  v_age            integer;
  v_age_effective  date;
  v_confirmed_cnt  integer;
  v_status         text;
  v_app_status     text;
  v_app_id         uuid;
  v_invite_code    text;
  v_ticket_id      uuid;
  v_code           text;
  v_position       integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  v_is_admin := public.is_admin();

  -- ── 타임 행 잠금 (동시 신청 직렬화) ───────────────────────────
  SELECT * INTO v_slot
    FROM public.event_slots
   WHERE id = p_slot_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF NOT v_slot.is_active THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  SELECT * INTO v_camp FROM public.campaigns WHERE id = v_slot.campaign_id;
  IF NOT FOUND OR NOT v_camp.event_mode THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF COALESCE(v_camp.recruit_type, '') <> 'visit' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_campaign_type');
  END IF;

  IF v_camp.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  -- ── 초대 전용 재검증 (최종 방어선) ────────────────────────────
  IF v_camp.is_invite_only THEN
    SELECT i.code INTO v_invite_code
      FROM public.event_invites i
     WHERE i.campaign_id = v_camp.id;

    IF v_invite_code IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF p_invite_code IS NULL OR btrim(p_invite_code) = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF upper(btrim(p_invite_code)) <> upper(btrim(v_invite_code)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_mismatch');
    END IF;
  END IF;

  -- ── 모집 마감 (272 트리거와 같은 판정·같은 예외) ──────────────
  IF NOT v_is_admin
     AND v_camp.deadline IS NOT NULL
     AND v_today_jst > v_camp.deadline THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'deadline_passed');
  END IF;

  -- ── 만 18세 (180 트리거와 같은 판정·같은 예외) ────────────────
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF NOT v_is_admin THEN
    SELECT effective_date INTO v_age_effective
      FROM public.age_policy_settings WHERE id = 1;

    IF v_age_effective IS NOT NULL AND v_today_jst >= v_age_effective THEN
      IF v_inf.birthdate IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'birthdate_required');
      END IF;
      v_age := public.calc_age_kst(v_inf.birthdate);
      IF v_age < 18 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'under_age');
      END IF;
    END IF;
  END IF;

  -- ── 한 캠페인에 1타임 ─────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM public.event_tickets t
     WHERE t.campaign_id   = v_camp.id
       AND t.influencer_id = v_uid
       AND t.status <> 'cancelled'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_applied');
  END IF;

  -- ── 정원 판정 (잠근 상태에서 센다) ────────────────────────────
  SELECT count(*) INTO v_confirmed_cnt
    FROM public.event_tickets t
   WHERE t.slot_id = v_slot.id
     AND t.status  = 'confirmed';

  IF v_confirmed_cnt < v_slot.capacity THEN
    v_status     := 'confirmed';
    v_app_status := 'approved';
    v_position   := NULL;
  ELSE
    v_status     := 'waitlist';
    v_app_status := 'pending';
    SELECT COALESCE(max(t.waitlist_position), 0) + 1 INTO v_position
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot.id
       AND t.status  = 'waitlist';
  END IF;

  -- ── 신청 행 확보 ──────────────────────────────────────────────
  SELECT id INTO v_app_id
    FROM public.applications
   WHERE user_id = v_uid AND campaign_id = v_camp.id
   FOR UPDATE;

  IF v_app_id IS NULL THEN
    INSERT INTO public.applications (
      user_id, user_email, user_name, user_followers, user_ig,
      campaign_id, message, address, status,
      caution_agreed_at, caution_snapshot
    ) VALUES (
      v_uid,
      v_inf.email,
      COALESCE(NULLIF(btrim(COALESCE(v_inf.name_kanji, '')), ''), v_inf.name, v_inf.email),
      COALESCE(v_inf.followers, 0),
      COALESCE(v_inf.ig, ''),
      v_camp.id,
      '',   -- 행사 모드는 신청 이유를 받지 않는다(사양서 §4-3)
      '',   -- 행사 모드는 배송지를 받지 않는다(배송이 없다)
      v_app_status,
      p_caution_agreed_at,
      p_caution_snapshot
    )
    RETURNING id INTO v_app_id;
  ELSE
    -- 되살리기(취소 후 재예약). 동의는 **이번에 받은 값이 있을 때만** 덮어쓴다 —
    -- 없으면 지난 동의 기록을 지우지 않는다(증빙을 잃지 않기 위함).
    UPDATE public.applications
       SET status             = v_app_status,
           cancelled_at       = NULL,
           cancel_reason      = NULL,
           cancel_reason_code = NULL,
           cancel_phase       = NULL,
           previous_status    = NULL,
           caution_agreed_at  = COALESCE(p_caution_agreed_at, caution_agreed_at),
           caution_snapshot   = COALESCE(p_caution_snapshot,  caution_snapshot)
     WHERE id = v_app_id;
  END IF;

  -- ── 티켓 발급 ─────────────────────────────────────────────────
  v_code := public.gen_event_ticket_code();

  INSERT INTO public.event_tickets (
    slot_id, campaign_id, influencer_id, application_id,
    ticket_code, status, waitlist_position
  ) VALUES (
    v_slot.id, v_camp.id, v_uid, v_app_id,
    v_code, v_status, v_position
  )
  RETURNING id INTO v_ticket_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'ticket_id',         v_ticket_id,
    'ticket_code',       v_code,
    'status',            v_status,
    'waitlist_position', v_position,
    'slot', jsonb_build_object(
      'slot_date',      v_slot.slot_date,
      'start_time',     v_slot.start_time,
      'end_time',       v_slot.end_time,
      'audience_label', v_slot.audience_label
    )
  );
END;
$$;

COMMENT ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) IS
  '[283+284] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 대기로 등록하고 '
  '짝이 되는 신청 행까지 같은 트랜잭션에서 만든다. [284] 주의사항 동의 시각·스냅샷을 함께 저장 — '
  '화면이 동의를 강제하는데 기록이 남지 않던 문제를 해소. 실패는 예외가 아니라 {ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 같은 이름의 함수가 **하나만** 남았는지(오버로드가 생기지 않았는지)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'reserve_event_ticket';
--   → 4인자 정의 1건만 나와야 한다. 2건이면 DROP 이 실패한 것이므로 즉시 보고.
--
-- 2) ⚠️ 실제 예약 동작은 여기서 검증하지 않는다 — 「본인 계정만」 가드가 있어
--    관리자 도구(SQL 편집기)는 서비스 키로 붙으므로 방문객을 재현할 수 없다.
--    개발서버 브라우저에서 테스트 계정으로 예약한 뒤 아래로 확인한다:
-- SELECT a.caution_agreed_at, a.caution_snapshot->>'version' AS snap_version
--   FROM public.applications a
--   JOIN public.event_tickets t ON t.application_id = a.id
--  ORDER BY t.created_at DESC LIMIT 3;
--   → 주의사항이 있는 행사 캠페인이면 시각과 version=2 가 채워져야 한다.
--     주의사항이 없는 캠페인이면 둘 다 NULL 이 정상이다.
--
-- ============================================================
-- 롤백
-- ============================================================
-- 283 의 2인자 정의로 되돌린다(283 파일의 reserve_event_ticket 블록을 재실행).
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.reserve_event_ticket(uuid, text, timestamptz, jsonb);
-- -- 이어서 283 의 CREATE OR REPLACE FUNCTION public.reserve_event_ticket(uuid, text) 블록 실행
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 285] 285_campaign_event_place.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 285_campaign_event_place.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 행사장 안내 한 줄
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-3 · §9-1
-- 선행: 280~284
--
-- 왜 필요한가:
--   사양서 §4-3 은 티켓 화면에 「QR + 예약번호 + 이름 + 날짜·타임 + **장소**」를
--   넣으라고 했는데, 캠페인 표에 행사장을 담을 칸이 없었다. 어디로 가야 하는지
--   적히지 않은 티켓은 티켓 구실을 못 한다.
--   §9-1 이 「행사장 이름·주소는 아직 미정, 임시 문구로 만들고 나중에 교체」라고
--   한 것은 **내용**이 미정이라는 뜻이지 칸이 필요 없다는 뜻이 아니다.
--
-- 왜 새 칸인가 (기존 칸 재사용을 안 하는 이유):
--   설명·참가방법 같은 긴 글에 섞어 두면 티켓에 한 줄로 뽑아낼 수 없다.
--   방문형의 visit_start/visit_end 는 날짜라 장소와 무관하다.
--
-- 표시 대상: **인플루언서 화면**이라 일본어로 넣는다(관리자 폼 안내에 명시).
--   한 줄 요약용이라 상세 약도·주의사항은 기존 안내문에 쓴다.
--
-- 275(캠페인 동시 저장 방어)와의 관계: 제외 목록에 없으므로 이 칸도 자동으로
--   보호 대상이 된다(280 의 두 칸과 같다).
-- 265·266(변경 이력 화이트리스트)에는 **넣지 않는다** — 280 과 같은 판단.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_place text;

COMMENT ON COLUMN public.campaigns.event_place IS
  '[285] 오프라인 행사장 안내 한 줄(일본어). 입장 티켓 화면에 그대로 표시된다. '
  '행사 모드(event_mode) 캠페인에서만 쓴다. 비어 있으면 티켓에 「장소는 정해지는 대로 '
  '안내」라는 문구가 대신 나간다.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns' AND column_name='event_place';
--   → text, YES
--
-- 기존 캠페인은 전부 NULL 이라 동작 변화 0:
-- SELECT count(*) FROM public.campaigns WHERE event_place IS NOT NULL;   -- 0
--
-- ============================================================
-- 롤백
-- ============================================================
-- ALTER TABLE public.campaigns DROP COLUMN IF EXISTS event_place;


-- ───────────────────────────────────────────────────────────────
-- [파일 286] 286_event_ticket_retention.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 286_event_ticket_retention.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 예약·입장 기록 자동 파기
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §7-1
-- 선행: 280~285
--
-- 왜 필요한가 (2026-08-03 `/약관확인` 지적):
--   개인정보처리방침 개정분(§2.1 · §6.1)에 「행사 종료 후 6개월」이라고 적었는데,
--   그 시점에 실제로 지우는 장치가 **하나도 없었다.** 지금 티켓이 사라지는 경로는
--   회원 탈퇴·캠페인 삭제로 신청 행이 파기될 때의 연쇄 삭제뿐이고, 그 외에는 영구
--   보관된다. **방침에 적은 기간을 못 지키는 것 자체가 위반**이므로 장치를 만든다.
--   선례: 마이그레이션 166(부정 이용·위반 기록 3년) — 같은 구조를 그대로 따른다.
--
-- 「행사 종료」의 기준:
--   그 티켓이 속한 타임의 **날짜(event_slots.slot_date)** 를 행사일로 본다.
--   캠페인의 종료일(submission_end 등)은 행사와 무관한 값이라 쓰지 않는다.
--   타임이 이미 지워진 티켓(캠페인 삭제 도중 등)은 남을 이유가 없으므로 함께 지운다.
--
-- 지우는 것 / 안 지우는 것:
--   · 지운다 — event_tickets 행(예약·입장 기록 전부)
--   · 안 지운다 — event_slots(개인정보 없음, 캠페인 운영 이력) ·
--     applications(보유 기간이 별도로 정해져 있다 — 탈퇴 시 파기)
--   ⚠️ 티켓을 지워도 신청 행은 남는다. 신청 행은 「캠페인에 참가했다」는 기록이고
--      방침 §6.1 의 다른 줄이 이미 그 기간을 정하고 있어, 여기서 함께 지우면
--      두 기간이 충돌한다.
--
-- 실행 주기: 매일 KST 04:00(UTC 19:00). 166 과 같은 시각대를 피해 04:30 으로 둔다
--   (같은 분에 두 작업이 겹치면 새벽 입출력이 몰린다).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.purge_old_event_tickets()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  WITH doomed AS (
    SELECT t.id
      FROM public.event_tickets t
      LEFT JOIN public.event_slots s ON s.id = t.slot_id
     WHERE s.id IS NULL                                   -- 타임이 이미 사라진 고아 행
        OR s.slot_date < ((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '6 months')
  )
  DELETE FROM public.event_tickets t
   USING doomed d
   WHERE t.id = d.id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE '[purge_old_event_tickets] deleted % rows', v_deleted;
  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.purge_old_event_tickets() IS
  '[286] 행사일(event_slots.slot_date)로부터 6개월이 지난 예약·입장 기록을 파기한다. '
  '개인정보처리방침 §6.1 「오프라인 행사 방문 예약·입장 기록 — 행사 종료 후 6개월」의 집행 장치. '
  'pg_cron 전용 — 일반 사용자에게 실행 권한을 주지 않는다.';

-- cron 이 postgres 역할로 실행하므로 일반 사용자 권한은 주지 않는다(166 과 동일).
REVOKE ALL ON FUNCTION public.purge_old_event_tickets() FROM PUBLIC;
-- 실행 주체에게는 명시적으로 준다. 166 도 같은 줄을 두고 있고, 로컬에서 되는 이유가
-- 그 환경의 postgres 가 최상위 권한이기 때문일 수 있어 환경 차이에 기대지 않는다.
GRANT EXECUTE ON FUNCTION public.purge_old_event_tickets() TO postgres;

COMMIT;

-- ============================================================
-- pg_cron 등록 (트랜잭션 밖 — cron.schedule 은 자체 커밋)
--   같은 이름으로 다시 등록하면 덮어써지므로, 멱등을 위해 해제 후 등록한다.
-- ============================================================
SELECT cron.unschedule('event-tickets-retention-daily')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event-tickets-retention-daily');

SELECT cron.schedule(
  'event-tickets-retention-daily',
  '30 19 * * *',                        -- 매일 UTC 19:30 (= KST 04:30)
  $$SELECT public.purge_old_event_tickets();$$
);

-- ============================================================
-- 검증
-- ============================================================
-- 1) 함수·작업 등록 확인
-- SELECT proname FROM pg_proc
--  WHERE pronamespace='public'::regnamespace AND proname='purge_old_event_tickets';
-- SELECT jobname, schedule, active FROM cron.job WHERE jobname='event-tickets-retention-daily';
--
-- 2) 지금 지워질 대상이 몇 건인지 (실제로 지우지 않고 세어만 본다)
-- SELECT count(*)
--   FROM public.event_tickets t
--   LEFT JOIN public.event_slots s ON s.id = t.slot_id
--  WHERE s.id IS NULL
--     OR s.slot_date < ((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '6 months');
--   → 도입 직후에는 0 이어야 한다(행사가 2026-08-28~30 이라 첫 파기는 2027-03 경).
--
-- 3) 수동 1회 실행(스모크)
-- SELECT public.purge_old_event_tickets();   -- 0 이 반환되면 정상
--
-- ============================================================
-- 롤백
-- ============================================================
-- SELECT cron.unschedule('event-tickets-retention-daily');
-- DROP FUNCTION IF EXISTS public.purge_old_event_tickets();


-- ───────────────────────────────────────────────────────────────
-- [파일 287] 287_check_in_other_day_confirm.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 287_check_in_other_day_confirm.sql
-- 오프라인 팝업 방문 예약 — 다른 날 예약은 되묻고 나서 입장 처리
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-4
-- 선행: 280~286
--
-- 왜 필요한가 (2026-08-03 사용자 지적):
--   지금은 check_in_ticket 이 **먼저 입장을 기록하고** 화면이 그 뒤에 「오늘이
--   아닙니다」를 보여 준다. 운영진이 그 문구를 읽었을 때는 이미 기록이 끝나 있어
--   거를 기회가 없다. 화면에서만 되묻게 하면 **되묻기를 우회하면 그냥 기록된다**.
--   → 서버가 「다른 날이면 기록하지 않고 되돌려보내는」 쪽이 맞다.
--
-- 무엇을 바꾸나:
--   인자 p_confirm_other_day(기본 false) 추가.
--     · 예약 날짜 = 오늘(일본 시각)      → 지금까지와 같이 바로 기록
--     · 예약 날짜 ≠ 오늘 且 확인 안 받음 → **아무것도 기록하지 않고** reason='other_day'
--                                          + 이름·타임을 함께 돌려준다(운영진이 보고 판단)
--     · 예약 날짜 ≠ 오늘 且 확인 받음    → 기록
--   그 외 로직(관리자 가드·취소/대기 차단·첫 입장 시각 보존·중복 감지)은 286 이전 그대로.
--
-- ⚠️ 막지 않고 되묻는다. 사정이 있어 다른 날 오신 분을 들여보낼지는 입구에 있는
--    사람이 판단할 일이다(중복 입장을 막지 않고 알리기만 하는 것과 같은 정신 — §2-8 U3).
--
-- ⚠️ 인자가 늘어 시그니처가 바뀐다. 옛 1인자 정의를 **먼저 DROP** 한다 — 남기면
--    같은 이름의 함수가 둘이 되어 인자를 안 넘긴 호출이 옛 동작(바로 기록)으로 샌다.
--    (284 에서 reserve_event_ticket 에 같은 처리를 했다)
--
-- ⚠️ 재정의 베이스는 **283**(현재 유효한 유일한 정의).
--
-- 호출부 2곳이 함께 바뀌어야 한다:
--   · dev/event-scan.html      — 현장 확인 화면
--   · dev/js/admin-event.js    — 관리자 예약 현황의 「입장 처리」
--   둘 다 reason='other_day' 를 받으면 되묻고, 확인하면 두 번째 인자를 true 로 다시 부른다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.check_in_ticket(text);

CREATE OR REPLACE FUNCTION public.check_in_ticket(
  p_ticket_code       text,
  p_confirm_other_day boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_ticket     public.event_tickets%ROWTYPE;
  v_slot       public.event_slots%ROWTYPE;
  v_inf        public.influencers%ROWTYPE;
  v_code       text;
  v_admin_name text;
  v_already    boolean;
  v_first_at   timestamptz;
  v_today_jst  date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_slot_json  jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  v_code := upper(btrim(COALESCE(p_ticket_code, '')));
  IF v_code = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE ticket_code = v_code
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO v_slot FROM public.event_slots   WHERE id = v_ticket.slot_id;
  SELECT * INTO v_inf  FROM public.influencers   WHERE id = v_ticket.influencer_id;

  v_slot_json := jsonb_build_object(
    'slot_date',      v_slot.slot_date,
    'start_time',     v_slot.start_time,
    'end_time',       v_slot.end_time,
    'audience_label', v_slot.audience_label
  );

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'cancelled',
      'name_kanji', v_inf.name_kanji, 'name_kana', v_inf.name_kana, 'slot', v_slot_json);
  END IF;

  IF v_ticket.status = 'waitlist' THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'waitlist_cannot_enter',
      'waitlist_position', v_ticket.waitlist_position,
      'name_kanji', v_inf.name_kanji, 'name_kana', v_inf.name_kana, 'slot', v_slot_json);
  END IF;

  -- ── [287] 다른 날 예약이면 되묻는다 — 아직 아무것도 기록하지 않는다 ──
  --   이미 입장한 티켓은 되묻지 않는다. 그 경우는 「중복」 안내가 나가야 하고,
  --   되묻기를 끼우면 운영진이 확인을 눌러야 중복이라는 사실을 볼 수 있게 된다.
  IF v_slot.slot_date IS DISTINCT FROM v_today_jst
     AND v_ticket.entered_at IS NULL
     AND NOT COALESCE(p_confirm_other_day, false) THEN
    RETURN jsonb_build_object(
      'ok',          false,
      'reason',      'other_day',
      'ticket_id',   v_ticket.id,
      'ticket_code', v_ticket.ticket_code,
      'name_kanji',  v_inf.name_kanji,
      'name_kana',   v_inf.name_kana,
      'slot',        v_slot_json);
  END IF;

  -- ── 확정 티켓: 첫 입장 시각은 보존하고 확인 횟수만 올린다 ─────
  v_already  := (v_ticket.entered_at IS NOT NULL);
  v_first_at := v_ticket.entered_at;

  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  IF v_already THEN
    UPDATE public.event_tickets
       SET scan_count = scan_count + 1,
           version    = version + 1
     WHERE id = v_ticket.id;
  ELSE
    v_first_at := now();
    UPDATE public.event_tickets
       SET entered_at      = v_first_at,
           entered_by      = v_uid,
           entered_by_name = v_admin_name,
           scan_count      = scan_count + 1,
           version         = version + 1
     WHERE id = v_ticket.id;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'ticket_id',       v_ticket.id,
    'ticket_code',     v_ticket.ticket_code,
    'status',          v_ticket.status,
    'already_entered', v_already,
    'entered_at',      v_first_at,
    'scan_count',      v_ticket.scan_count + 1,
    'name_kanji',      v_inf.name_kanji,
    'name_kana',       v_inf.name_kana,
    'slot',            v_slot_json
  );
END;
$$;

COMMENT ON FUNCTION public.check_in_ticket(text, boolean) IS
  '[283+287] 예약번호로 입장 확인. 첫 입장 시각은 재확인해도 덮어쓰지 않고 확인 횟수만 올린다. '
  '[287] 예약 날짜가 오늘이 아니면 **아무것도 기록하지 않고** reason=other_day 로 되돌려보낸다 — '
  '운영진이 보고 판단한 뒤 두 번째 인자를 true 로 다시 부르면 기록한다. 막지 않고 되묻는다.';

REVOKE ALL ON FUNCTION public.check_in_ticket(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_in_ticket(text, boolean) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 같은 이름의 함수가 하나만 남았는지(오버로드가 안 생겼는지)
-- SELECT p.oid::regprocedure FROM pg_proc p
--  WHERE p.pronamespace='public'::regnamespace AND p.proname='check_in_ticket';
--   → 2인자 정의 1건만. 2건이면 DROP 이 실패한 것이므로 즉시 보고.
--
-- 2) 관리자 브라우저에서(SQL 편집기는 관리자 가드에 막힌다):
--    · 오늘 예약 번호   → {ok:true}
--    · 다른 날 예약 번호 → {ok:false, reason:'other_day'} 이고, 그 뒤
--      SELECT entered_at FROM event_tickets WHERE ticket_code='...' 가 **NULL 그대로**여야 한다
--      (되묻는 단계에서 기록되면 이 마이그레이션이 의미가 없다)
--    · 같은 번호를 확인 인자 true 로 다시 → {ok:true} 이고 entered_at 이 채워진다
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.check_in_ticket(text, boolean);
-- -- 이어서 283 의 check_in_ticket(text) 블록을 재실행
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 288] 288_cancel_event_ticket_admin.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 288_cancel_event_ticket_admin.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 관리자용 예약 취소 함수
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 선행: 280~287 (특히 282 티켓 표 · 283 예약/취소/입장 함수 · 284 주의사항 동의 ·
--       287 다른 날 입장 되묻기)
-- 다음 파일(289)과 반드시 이 순서로 적용한다 — 이유는 289 파일 헤더 참고.
--
-- 왜 필요한가:
--   관리자가 예약(입장 티켓)을 취소할 수단이 지금까지 하나도 없었다. 그래서
--   관리자는 「신청 미승인」으로 대신 처리해 왔는데, 그러면 신청만 반려되고
--   티켓은 확정으로 남아 — 입장 확인(check_in_ticket)이 신청 상태를 보지 않으므로
--   **반려된 사람이 현장에서 그대로 입장 처리될 수 있다.** 2026-08-04 확인 화면
--   경고(dev/js/admin-applications.js rejectApplication)는 「모르고 누르는 일」만
--   막을 뿐 근본 해결이 아니다. 이 파일이 실제 취소 수단을 만든다.
--
-- 이 파일이 만드는 것:
--   1) event_tickets 표에 취소 감사 컬럼 4개 추가
--      (cancelled_by · cancelled_by_role · cancelled_by_name · admin_cancel_note)
--   2) lookup_values 에 취소 사유 1건 추가(kind='cancel_reason', code='admin_cancelled')
--      — 기존 6종(schedule_unavailable·personal_reason·product_mismatch·delivery_issue·
--      account_change·other, 마이그레이션 104)과 겹치지 않음(사전 확인 완료,
--      .claude/rules/supabase.md 「기준 데이터 추가 시 중복 확인」).
--   3) public._promote_next_event_waitlist(slot_id) / public._renumber_event_waitlist(slot_id)
--      — 대기 1번 승격(+알림) / 남은 대기 순번 재정렬. 283 의 cancel_event_ticket
--      안에 있던 로직을 그대로 옮긴 것(함수를 둘로 나눈 이유는 §3 코드 주석 참고 —
--      재정렬은 승격 여부와 무관하게 항상 돌아야 한다). 본인 취소·관리자 취소
--      두 함수가 이 둘을 함께 쓴다(복사 금지 — 요청사항).
--   4) public.cancel_event_ticket(uuid) 재정의 — 로직은 283 과 완전히 같고,
--      승격 부분만 3)을 호출하도록 바꾸고, 취소 감사 컬럼을 채운다.
--      (시그니처 불변 — DROP 불필요)
--   5) public.reserve_event_ticket(uuid,text,timestamptz,jsonb) 재정의 — 284 와
--      로직은 완전히 같고, 다음 파일(289)이 읽을 표시(bypass 플래그)를 세우는
--      한 줄만 추가한다. (시그니처 불변 — DROP 불필요)
--   6) public.cancel_event_ticket_admin(ticket_id, reason_note) — 신규. 관리자 전용.
--
-- ── 본인 취소와 다른 점 3가지 (요청사항 — 판단과 근거) ──────────────
--
--   ① 본인 확인 대신 관리자 권한
--      cancel_event_ticket(283)은 `ticket.influencer_id = auth.uid()` 로 본인만
--      허용한다. 관리자 취소는 그 반대로 `public.is_admin()` 만 확인하고 티켓의
--      주인이 누구든 취소할 수 있다 — 그게 이 함수가 존재하는 이유다.
--
--   ② 시작 2시간 전 제한을 적용하지 **않는다**
--      본인 취소(283)는 「예약 타임 시작 2시간 전까지」만 허용해, 막판 취소가
--      대기자에게 넘어갈 시간을 확보한다(운영 목적의 제한). 관리자가 취소를
--      판단하는 상황은 이미 사람이 개입해 사정을 확인한 뒤이고, 무엇보다 이
--      함수를 만든 이유 자체가 「지금 당장 정리할 수단이 없다」였다 — 행사
--      당일에도 잘못 등록된 예약을 정리해야 할 수 있는데 시간 제한을 걸면
--      만들어 준 수단이 무용지물이 된다. → **관리자는 시간 제한 없이 취소 가능**.
--
--   ③ 취소 사유를 남긴다 — 단, 사용자에게 그대로 보이지 않는다
--      관리자가 남긴 자유 텍스트(p_reason_note)는 event_tickets.admin_cancel_note
--      에만 저장한다. applications.cancel_reason(자유 텍스트)에는 **넣지 않는다.**
--      이유: applications.cancel_reason 은 인플루언서 마이페이지의 취소 상세
--      모달(dev/js/mypage.js openCancelDetailModal)이 그대로 노출하는 칸이다.
--      관리자 화면은 한국어라 이 메모도 한국어로 쓰일 가능성이 높은데, 그 원문이
--      일본어 화면에 번역 없이 그대로 뜨면 사용자가 못 알아본다(이 프로젝트에
--      한국어→일본어 실시간 번역 장치가 없다 — 있는 건 응모건 메시지의 비동기
--      웹훅 번역뿐이고 이 함수 안에서 동기 호출할 수 없다). 대신
--      applications.cancel_reason_code = 'admin_cancelled' 는 채운다 — 이건
--      lookup_values 의 한국어/일본어 라벨 쌍이라 사용자에게는 자동으로
--      「運営によるキャンセル」로, 관리자 화면에는 「운영진 취소」로 보인다(안전).
--      즉 사용자는 "운영진이 취소했다"는 사실은 알지만 관리자의 내부 메모는
--      보지 못한다.
--
-- ── 대기자 자동 승격은 본인 취소와 같아야 한다 (요청사항) ────────────
--   확정 1자리가 비면 대기 1번이 올라가고 순번이 재정렬되며 알림이 나가는
--   로직은 두 취소 경로가 반드시 똑같아야 한다(따로 두면 한쪽만 고쳐진다).
--   → public._promote_next_event_waitlist(slot_id) 로 뽑아 공용화했다.
--
-- ── 짝이 되는 신청 행 (이 작업의 핵심) ────────────────────────────
--   관리자 취소도 283 의 「신청 행 처리 규칙」을 그대로 따른다 — 확정 티켓을
--   취소하면 신청도 cancelled 로, previous_status 에 취소 직전 신청 상태를
--   담는다. 취소해도 신청 행은 지우지 않는다(282 헤더 참고 — 옛 유일 제약 때문에
--   재예약은 행을 되살리는 방식이다).
--
-- ── 이미 입장한 티켓(entered_at 있음)을 취소할 수 있게 할지 (판단) ───
--   **막는다.** 본인 취소(283)와 같은 조건. 이미 입장했다는 사실 자체를
--   취소로 지울 이유가 없고, 취소하면 「신청은 취소인데 입장은 완료」인
--   모순 데이터가 남는다. 입장 이후 문제가 생겼다면(예: 위반 발견) 그건
--   이 함수의 몫이 아니라 다른 관리 조치(블랙리스트 등)의 영역이다.
--
-- ── 실패 반환 방식 ──────────────────────────────────────────────
--   283·284·287 과 같은 방식 — 예외가 아니라 {ok:false, reason:...}.
--
-- ── 다음 파일(289)과의 연결고리 ──────────────────────────────────
--   이 파일의 함수 3개(cancel_event_ticket · reserve_event_ticket ·
--   cancel_event_ticket_admin)는 applications.status 를 UPDATE 하기 직전에
--   `PERFORM set_config('reverb.event_ticket_bypass', 'on', true)` 를 세운다.
--   지금(289 적용 전)은 아무도 이 값을 읽지 않아 아무 효과가 없다 — 하지만
--   289 가 적용되면 이 표시가 있어야 그 함수들이 계속 신청 상태를 바꿀 수
--   있다. 순서를 바꿔 289 를 먼저 적용하면 그 사이 구간에는 티켓 함수조차
--   막혀 있을 것 같지만 그렇지 않다(289 파일이 아직 없으니 트리거 자체가
--   없다) — 그래도 지시받은 순서(이 파일 먼저) 그대로 둔다: 관리자가 예약을
--   정리할 수단이 먼저 존재해야, 나중에 "직접 수정 경로"를 막아도 안전하다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. event_tickets 취소 감사 컬럼 4개
-- ============================================================
ALTER TABLE public.event_tickets
  ADD COLUMN IF NOT EXISTS cancelled_by      uuid NULL,
  ADD COLUMN IF NOT EXISTS cancelled_by_role text NULL
    CHECK (cancelled_by_role IS NULL OR cancelled_by_role IN ('influencer','admin')),
  ADD COLUMN IF NOT EXISTS cancelled_by_name text NULL,
  ADD COLUMN IF NOT EXISTS admin_cancel_note text NULL;

COMMENT ON COLUMN public.event_tickets.cancelled_by IS
  '[288] 취소를 실행한 사람의 auth id. 본인 취소면 influencer_id 와 같은 값, '
  '관리자 취소면 관리자 auth_id.';
COMMENT ON COLUMN public.event_tickets.cancelled_by_role IS
  '[288] 취소 주체 — influencer(본인) | admin(관리자). NULL 은 288 이전에 취소된 옛 행.';
COMMENT ON COLUMN public.event_tickets.cancelled_by_name IS
  '[288] 관리자 취소일 때만 채운다(admins.name 스냅샷). 본인 취소는 role 만으로 '
  '충분해 이름을 채우지 않는다(자기 자신이므로).';
COMMENT ON COLUMN public.event_tickets.admin_cancel_note IS
  '[288] 관리자가 취소 시 남긴 내부 메모(선택, 최대 500자). 사용자에게 노출되지 '
  '않는다 — 이유는 파일 헤더 「③ 취소 사유를 남긴다」 참고. 인플루언서에게 보이는 '
  '건 applications.cancel_reason_code=''admin_cancelled'' 의 번역된 카테고리 라벨뿐이다.';

-- ============================================================
-- 2. lookup_values — 관리자 취소 사유 카테고리 1건
--    기존 cancel_reason 6종(마이그레이션 104)과 중복 확인 완료:
--    schedule_unavailable/personal_reason/product_mismatch/delivery_issue/
--    account_change/other — 겹치지 않는다.
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('cancel_reason', 'admin_cancelled', '운영진 취소', '運営によるキャンセル', 95, true)
ON CONFLICT (kind, code) DO NOTHING;

-- ============================================================
-- 3. 대기 승격 + 순번 재정렬 공용 함수 2개
--    cancel_event_ticket(283)에 있던 블록을 그대로 옮긴 것 — 단 **함수 하나로
--    합치지 않고 둘로 나눴다.** 283 원문은 「승격(조건부)」과 「순번 재정렬
--    (무조건)」이 별개 블록이다(재정렬은 IF status='confirmed' 바깥에 있어
--    대기 티켓이 직접 취소될 때도 항상 실행된다). 하나로 합쳐 승격 블록
--    안에서만 재정렬하면, **대기 중인 티켓이 직접 취소될 때 남은 대기자
--    순번에 구멍이 생기는 회귀**가 생긴다(승격은 확정 티켓이 취소될 때만
--    일어나므로, 그 조건 뒤에 재정렬을 두면 대기 티켓 취소는 재정렬을 건너뛴다
--    — 최초 초안에서 실제로 이 실수를 했다가 리뷰 중 발견해 둘로 나눴다).
-- ============================================================
CREATE OR REPLACE FUNCTION public._promote_next_event_waitlist(
  p_slot_id uuid
) RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_promoted   public.event_tickets%ROWTYPE;
  v_slot       public.event_slots%ROWTYPE;
  v_camp_title text;
BEGIN
  SELECT * INTO v_promoted
    FROM public.event_tickets t
   WHERE t.slot_id = p_slot_id
     AND t.status  = 'waitlist'
   ORDER BY t.waitlist_position NULLS LAST, t.created_at
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE public.event_tickets
     SET status            = 'confirmed',
         waitlist_position = NULL,
         version           = version + 1
   WHERE id = v_promoted.id;

  -- 짝이 되는 신청도 심사중 → 당선으로. 이 UPDATE 는 289 적용 후 차단 트리거를
  -- 지나가야 하므로, 호출부(cancel_event_ticket·cancel_event_ticket_admin)가
  -- 이 함수를 부르기 **전에** bypass 표시를 이미 세워 둔 상태여야 한다.
  IF v_promoted.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status = 'approved'
     WHERE id = v_promoted.application_id;
  END IF;

  -- 승격된 사람에게 앱 알림(일본어). 알림 실패가 승격 자체를 되돌리면 안 되므로
  -- 이 블록만 예외를 삼킨다(283 원문과 같은 판단 — 「알림은 못 갔지만 자리는
  -- 넘어갔다」가 반대 경우보다 낫다).
  BEGIN
    SELECT * INTO v_slot FROM public.event_slots WHERE id = p_slot_id;
    SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_promoted.campaign_id;

    INSERT INTO public.notifications (
      user_id, kind, ref_table, ref_id, title, body
    ) VALUES (
      v_promoted.influencer_id,
      'event_waitlist_promoted',
      'event_tickets',
      v_promoted.id,
      'キャンセル待ちから予約が確定しました',
      COALESCE(v_camp_title, 'イベント')
        || 'のご予約が確定しました。'
        || to_char(v_slot.slot_date, 'MM月DD日')
        || ' ' || to_char(v_slot.start_time, 'HH24:MI')
        || ' にご来場ください。入場チケットからQRコードをご確認いただけます。'
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_promoted.id;
END;
$$;

COMMENT ON FUNCTION public._promote_next_event_waitlist(uuid) IS
  '[288] 확정 자리가 빈 타임(p_slot_id)에서 대기 1번만 확정으로 올린다(순번 재정렬은 '
  '_renumber_event_waitlist() 가 별도로 담당 — 반드시 함께 호출할 것). 짝이 되는 신청을 '
  'approved 로, 승격 알림도 함께 처리. 반환값은 승격된 티켓 id(없으면 NULL). '
  'cancel_event_ticket(283)·cancel_event_ticket_admin(288) 둘 다 이 함수를 쓴다 — '
  '승격 로직을 두 곳에 복사하면 한쪽만 고쳐지는 사고를 막기 위함. 내부 전용 함수 '
  '(밑줄 접두어, _settlement_cert_candidates() 와 같은 명명 관례) — 호출부가 이미 '
  '슬롯 행을 잠근 상태에서 부르는 것을 전제로 한다.';

CREATE OR REPLACE FUNCTION public._renumber_event_waitlist(
  p_slot_id uuid
) RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pos integer := 0;
  r     record;
BEGIN
  FOR r IN
    SELECT t.id
      FROM public.event_tickets t
     WHERE t.slot_id = p_slot_id
       AND t.status  = 'waitlist'
     ORDER BY t.waitlist_position NULLS LAST, t.created_at
  LOOP
    v_pos := v_pos + 1;
    UPDATE public.event_tickets SET waitlist_position = v_pos WHERE id = r.id;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public._renumber_event_waitlist(uuid) IS
  '[288] 타임(p_slot_id)의 남은 대기(waitlist) 티켓 순번을 1부터 다시 매긴다. '
  '**취소 함수는 이 함수를 취소 종류(확정이었든 대기였든)와 무관하게 항상 호출해야 '
  '한다** — 대기 중인 티켓이 직접 취소될 때도 뒷사람 순번이 당겨져야 하기 때문(283 '
  '원문에서 이 재정렬 루프가 승격 조건문 바깥에 있던 이유와 같다). 내부 전용 함수.';

-- 내부 전용 — 283 gen_event_ticket_code() 와 같은 패턴. authenticated 에 GRANT 하지
-- 않는다. cancel_event_ticket·cancel_event_ticket_admin(둘 다 이 함수 소유자 권한으로
-- 실행되는 SECURITY DEFINER 함수) 안에서만 불린다.
REVOKE ALL ON FUNCTION public._promote_next_event_waitlist(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._renumber_event_waitlist(uuid) FROM PUBLIC;

-- ============================================================
-- 4. cancel_event_ticket(uuid) 재정의 — 283 과 로직 동일, 승격만 3)에 위임 +
--    취소 감사 컬럼 채움 + 289 를 위한 bypass 표시. 시그니처 불변(DROP 불필요).
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_event_ticket(
  p_ticket_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_ticket       public.event_tickets%ROWTYPE;
  v_slot         public.event_slots%ROWTYPE;
  v_slot_start   timestamptz;
  v_promoted_id  uuid := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE id = p_ticket_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 본인 것만. 관리자라도 이 함수로는 남의 티켓을 취소할 수 없다
  -- (대리 취소는 아래 5) cancel_event_ticket_admin 을 쓴다).
  IF v_ticket.influencer_id <> v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancelled');
  END IF;

  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- ── 송금 완료된 정산이 걸려 있으면 취소하지 않는다 (283 원문과 동일 이유) ──
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- ── 취소 마감: 예약 타임 시작 2시간 전까지 (본인 취소 전용 제한) ──
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  v_slot_start := (v_slot.slot_date + v_slot.start_time) AT TIME ZONE 'Asia/Tokyo';

  IF now() > (v_slot_start - interval '2 hours') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancel_window_passed');
  END IF;

  -- [288] 다음 마이그레이션(289)이 읽을 표시 — 「이 트랜잭션은 예약 함수가 낸
  --   변경」. 지금은 아무도 읽지 않는다(289 적용 전) — 파일 헤더 참고.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  -- ── 취소 처리 ─────────────────────────────────────────────────
  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = v_uid,
         cancelled_by_role = 'influencer',
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status          = 'cancelled',
           previous_status  = CASE v_ticket.status
                                WHEN 'confirmed' THEN 'approved'
                                ELSE 'pending'
                              END,
           cancelled_at    = now(),
           cancel_phase    = 'other'
     WHERE id = v_ticket.application_id;
  END IF;

  -- ── 확정 자리가 빠졌으면 대기 1번을 승격 ──────────────────────
  IF v_ticket.status = 'confirmed' THEN
    v_promoted_id := public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- ── 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행 ──────
  --   대기 중인 티켓이 직접 취소돼도(승격이 안 일어나도) 뒷사람 순번은
  --   당겨져야 한다(283 원문과 동일 — _renumber_event_waitlist() 주석 참고).
  PERFORM public._renumber_event_waitlist(v_slot.id);

  RETURN jsonb_build_object(
    'ok',                 true,
    'ticket_id',          v_ticket.id,
    'status',             'cancelled',
    'promoted_ticket_id', v_promoted_id
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_event_ticket(uuid) IS
  '[283+288] 본인 예약 취소. 예약 타임 시작 2시간 전까지만(일본 시각 기준 서버 판정). '
  '확정 자리가 빠지면 _promote_next_event_waitlist() 로 같은 타임 대기 1번을 자동 승격. '
  '취소해도 신청 행은 지우지 않고 cancelled 로 남겨, 재예약 때 그 행을 되살린다. '
  '[288] 승격 로직을 공용 함수로 분리 + 취소 감사 컬럼(cancelled_by 등) 채움 + '
  '289 신청 상태 변경 차단 트리거를 위한 bypass 표시.';

REVOKE ALL ON FUNCTION public.cancel_event_ticket(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_event_ticket(uuid) TO authenticated;

-- ============================================================
-- 5. reserve_event_ticket 재정의 — 284 와 로직 동일, bypass 표시 한 줄만 추가.
--    시그니처 불변(DROP 불필요).
-- ============================================================
CREATE OR REPLACE FUNCTION public.reserve_event_ticket(
  p_slot_id            uuid,
  p_invite_code        text        DEFAULT NULL,
  p_caution_agreed_at  timestamptz DEFAULT NULL,
  p_caution_snapshot   jsonb       DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := auth.uid();
  v_slot           public.event_slots%ROWTYPE;
  v_camp           public.campaigns%ROWTYPE;
  v_inf            public.influencers%ROWTYPE;
  v_today_jst      date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_is_admin       boolean;
  v_age            integer;
  v_age_effective  date;
  v_confirmed_cnt  integer;
  v_status         text;
  v_app_status     text;
  v_app_id         uuid;
  v_invite_code    text;
  v_ticket_id      uuid;
  v_code           text;
  v_position       integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  v_is_admin := public.is_admin();

  -- [288] 다음 마이그레이션(289)이 읽을 표시. 이 함수의 「되살리기」 분기(아래)는
  --   기존 신청 행을 UPDATE 하므로 289 가 적용되면 이 표시가 있어야 통과한다.
  --   신규 INSERT 분기에는 원래 필요 없지만, 함수 시작에서 한 번만 세워 두면
  --   모든 분기를 놓치지 않는다(트랜잭션 범위라 이후 어떤 UPDATE 든 적용됨).
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  -- ── 타임 행 잠금 (동시 신청 직렬화) ───────────────────────────
  SELECT * INTO v_slot
    FROM public.event_slots
   WHERE id = p_slot_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF NOT v_slot.is_active THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  SELECT * INTO v_camp FROM public.campaigns WHERE id = v_slot.campaign_id;
  IF NOT FOUND OR NOT v_camp.event_mode THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF COALESCE(v_camp.recruit_type, '') <> 'visit' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_campaign_type');
  END IF;

  IF v_camp.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'slot_closed');
  END IF;

  -- ── 초대 전용 재검증 (최종 방어선) ────────────────────────────
  IF v_camp.is_invite_only THEN
    SELECT i.code INTO v_invite_code
      FROM public.event_invites i
     WHERE i.campaign_id = v_camp.id;

    IF v_invite_code IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF p_invite_code IS NULL OR btrim(p_invite_code) = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_required');
    END IF;
    IF upper(btrim(p_invite_code)) <> upper(btrim(v_invite_code)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invite_mismatch');
    END IF;
  END IF;

  -- ── 모집 마감 (272 트리거와 같은 판정·같은 예외) ──────────────
  IF NOT v_is_admin
     AND v_camp.deadline IS NOT NULL
     AND v_today_jst > v_camp.deadline THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'deadline_passed');
  END IF;

  -- ── 만 18세 (180 트리거와 같은 판정·같은 예외) ────────────────
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF NOT v_is_admin THEN
    SELECT effective_date INTO v_age_effective
      FROM public.age_policy_settings WHERE id = 1;

    IF v_age_effective IS NOT NULL AND v_today_jst >= v_age_effective THEN
      IF v_inf.birthdate IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'birthdate_required');
      END IF;
      v_age := public.calc_age_kst(v_inf.birthdate);
      IF v_age < 18 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'under_age');
      END IF;
    END IF;
  END IF;

  -- ── 한 캠페인에 1타임 ─────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM public.event_tickets t
     WHERE t.campaign_id   = v_camp.id
       AND t.influencer_id = v_uid
       AND t.status <> 'cancelled'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_applied');
  END IF;

  -- ── 정원 판정 (잠근 상태에서 센다) ────────────────────────────
  SELECT count(*) INTO v_confirmed_cnt
    FROM public.event_tickets t
   WHERE t.slot_id = v_slot.id
     AND t.status  = 'confirmed';

  IF v_confirmed_cnt < v_slot.capacity THEN
    v_status     := 'confirmed';
    v_app_status := 'approved';
    v_position   := NULL;
  ELSE
    v_status     := 'waitlist';
    v_app_status := 'pending';
    SELECT COALESCE(max(t.waitlist_position), 0) + 1 INTO v_position
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot.id
       AND t.status  = 'waitlist';
  END IF;

  -- ── 신청 행 확보 ──────────────────────────────────────────────
  SELECT id INTO v_app_id
    FROM public.applications
   WHERE user_id = v_uid AND campaign_id = v_camp.id
   FOR UPDATE;

  IF v_app_id IS NULL THEN
    INSERT INTO public.applications (
      user_id, user_email, user_name, user_followers, user_ig,
      campaign_id, message, address, status,
      caution_agreed_at, caution_snapshot
    ) VALUES (
      v_uid,
      v_inf.email,
      COALESCE(NULLIF(btrim(COALESCE(v_inf.name_kanji, '')), ''), v_inf.name, v_inf.email),
      COALESCE(v_inf.followers, 0),
      COALESCE(v_inf.ig, ''),
      v_camp.id,
      '',
      '',
      v_app_status,
      p_caution_agreed_at,
      p_caution_snapshot
    )
    RETURNING id INTO v_app_id;
  ELSE
    -- 되살리기(취소 후 재예약). 289 적용 후에는 이 UPDATE 가 신청 상태 변경
    -- 차단 트리거를 지나가야 하므로, 함수 시작에서 이미 세워 둔 bypass 표시가
    -- 반드시 필요하다.
    UPDATE public.applications
       SET status             = v_app_status,
           cancelled_at       = NULL,
           cancel_reason      = NULL,
           cancel_reason_code = NULL,
           cancel_phase       = NULL,
           previous_status    = NULL,
           caution_agreed_at  = COALESCE(p_caution_agreed_at, caution_agreed_at),
           caution_snapshot   = COALESCE(p_caution_snapshot,  caution_snapshot)
     WHERE id = v_app_id;
  END IF;

  -- ── 티켓 발급 ─────────────────────────────────────────────────
  v_code := public.gen_event_ticket_code();

  INSERT INTO public.event_tickets (
    slot_id, campaign_id, influencer_id, application_id,
    ticket_code, status, waitlist_position
  ) VALUES (
    v_slot.id, v_camp.id, v_uid, v_app_id,
    v_code, v_status, v_position
  )
  RETURNING id INTO v_ticket_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'ticket_id',         v_ticket_id,
    'ticket_code',       v_code,
    'status',            v_status,
    'waitlist_position', v_position,
    'slot', jsonb_build_object(
      'slot_date',      v_slot.slot_date,
      'start_time',     v_slot.start_time,
      'end_time',       v_slot.end_time,
      'audience_label', v_slot.audience_label
    )
  );
END;
$$;

COMMENT ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) IS
  '[283+284+288] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 대기로 '
  '등록하고 짝이 되는 신청 행까지 같은 트랜잭션에서 만든다(또는 취소된 옛 신청 행을 되살린다). '
  '[288] 289 신청 상태 변경 차단 트리거를 위한 bypass 표시. 실패는 예외가 아니라 '
  '{ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) TO authenticated;

-- ============================================================
-- 6. cancel_event_ticket_admin — 신규. 관리자 전용 예약 취소.
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_event_ticket_admin(
  p_ticket_id   uuid,
  p_reason_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_ticket       public.event_tickets%ROWTYPE;
  v_slot         public.event_slots%ROWTYPE;
  v_admin_name   text;
  v_camp_title   text;
  v_promoted_id  uuid := NULL;
  v_note         text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE id = p_ticket_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancelled');
  END IF;

  -- ⚠️ 이미 입장한 티켓은 취소하지 않는다 — 판단 근거는 파일 헤더 참고.
  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- ── 송금 완료된 정산이 걸려 있으면 취소하지 않는다 (283 과 동일 이유) ──
  --   행사 캠페인은 리워드 0 고정이 원칙(admin-event.js applyEventModeFormLock)
  --   이라 정상적으로는 정산이 생기지 않지만, 관리자가 리워드를 수동으로 넣은
  --   예외 상황을 대비한 방어선이다.
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- ⚠️ 본인 취소(cancel_event_ticket)와 달리 「시작 2시간 전까지」 창을 두지
  --   않는다 — 판단 근거는 파일 헤더 「② 시작 2시간 전 제한을 적용하지 않는다」.
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  v_note := NULLIF(btrim(COALESCE(p_reason_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_note := left(v_note, 500);
  END IF;

  -- [289] 이어지는 마이그레이션이 읽을 표시 — 신청 상태 UPDATE 두 건(아래 +
  --   _promote_next_event_waitlist 내부의 승격 UPDATE) 모두 이 트랜잭션 안에서
  --   일어나므로 한 번만 세우면 전부 적용된다.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = v_uid,
         cancelled_by_role = 'admin',
         cancelled_by_name = v_admin_name,
         admin_cancel_note = v_note,
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status             = 'cancelled',
           previous_status    = CASE v_ticket.status
                                  WHEN 'confirmed' THEN 'approved'
                                  ELSE 'pending'
                                END,
           cancelled_at       = now(),
           cancel_phase       = 'other',
           cancel_reason_code = 'admin_cancelled'
           -- cancel_reason(자유 텍스트)은 일부러 채우지 않는다 — 파일 헤더
           -- 「③ 취소 사유를 남긴다」 참고. 관리자 메모는 admin_cancel_note 에만.
     WHERE id = v_ticket.application_id;
  END IF;

  -- ── 확정 자리가 빠졌으면 대기 1번을 승격 (본인 취소와 같은 공용 함수) ──
  IF v_ticket.status = 'confirmed' THEN
    v_promoted_id := public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- ── 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행 ──────
  --   관리자가 대기 중인 티켓을 직접 취소해도(승격이 안 일어나도) 뒷사람
  --   순번은 당겨져야 한다.
  PERFORM public._renumber_event_waitlist(v_slot.id);

  -- ── 취소당한 사람에게 알린다 ─────────────────────────────────
  --   본인이 요청한 취소가 아니라 운영진이 취소한 것이므로, cancel_event_ticket
  --   (본인 취소)과 달리 반드시 알려야 한다. kind='application_cancelled' 는
  --   이미 있는 알림 종류(마이그레이션 105)이고, 인플루언서 앱이 이 kind 를
  --   누르면 응모이력으로 이동하도록 이미 구현돼 있다(신규 클라이언트 코드 불필요).
  BEGIN
    IF v_ticket.application_id IS NOT NULL THEN
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'application_cancelled',
        'applications',
        v_ticket.application_id,
        'ご予約がキャンセルされました',
        COALESCE(v_camp_title, 'イベント')
          || 'のご予約が運営によりキャンセルされました。ご不明な点がございましたら運営までお問い合わせください。'
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 알림 실패가 취소·승격을 되돌리면 안 된다(283 원문과 같은 판단).
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok',                 true,
    'ticket_id',          v_ticket.id,
    'status',             'cancelled',
    'promoted_ticket_id', v_promoted_id
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_event_ticket_admin(uuid, text) IS
  '[288] 관리자 전용 예약 취소. 본인 취소(cancel_event_ticket)와 달리 티켓 소유자 '
  '확인 대신 is_admin() 을 확인하고, 시작 2시간 전 제한이 없다(관리자 판단에 맡김). '
  '이미 입장한 티켓·송금완료 정산이 걸린 티켓은 취소하지 않는다. 대기 승격은 '
  '_promote_next_event_waitlist() 공용 함수로 본인 취소와 동일하게 처리. 취소 사유는 '
  'event_tickets.admin_cancel_note 에만 남기고 사용자에게는 번역된 카테고리 라벨만 노출. '
  '실패는 예외가 아니라 {ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.cancel_event_ticket_admin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_event_ticket_admin(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 함수 존재 확인 (새 함수 2개 + 재정의 3개)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('cancel_event_ticket_admin', '_promote_next_event_waitlist',
--                       '_renumber_event_waitlist', 'cancel_event_ticket', 'reserve_event_ticket')
--  ORDER BY p.proname;
--   → cancel_event_ticket(uuid) 1건 · cancel_event_ticket_admin(uuid,text) 1건 ·
--     _promote_next_event_waitlist(uuid) 1건 · _renumber_event_waitlist(uuid) 1건 ·
--     reserve_event_ticket(uuid,text,timestamptz,jsonb) 1건
--     (오버로드가 생기면 안 된다 — 각 이름당 2건 이상이면 즉시 보고)
--
-- 2) event_tickets 새 컬럼 확인
-- SELECT column_name, data_type FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='event_tickets'
--    AND column_name IN ('cancelled_by','cancelled_by_role','cancelled_by_name','admin_cancel_note')
--  ORDER BY column_name;
--   → 4행
--
-- 3) lookup_values 시드 확인 + 중복 없는지
-- SELECT code, name_ko, name_ja, sort_order, active FROM public.lookup_values
--  WHERE kind = 'cancel_reason' ORDER BY sort_order;
--   → 7행(기존 6 + admin_cancelled). name_ko 가 서로 다른 문구인지 눈으로 확인.
--
-- 4) 형식 확인 (SQL Editor 는 서비스 키라 auth.uid() 가 NULL — is_admin() 가드에
--    막혀 permission_denied 가 나오는 것이 정상. 실제 취소 동작은 방문객·관리자
--    테스트 계정으로 브라우저에서 확인해야 한다 — 283 파일의 같은 함정 참고)
-- SELECT public.cancel_event_ticket_admin('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- 5) ⚠️ 실제 취소·승격·짝이 되는 신청 상태 동기화는 여기서 검증하지 않는다.
--    관리자 로그인 브라우저 세션에서 테스트 계정 3개(확정 1 + 대기 2)로:
--      a. 확정 티켓을 cancel_event_ticket_admin 으로 취소
--      b. 대기 1번 티켓이 confirmed 로 바뀌었는지, 짝이 되는 신청이 approved 로
--         바뀌었는지, event_waitlist_promoted 알림이 갔는지 확인
--      c. 남은 대기 2번 티켓의 waitlist_position 이 1로 당겨졌는지 확인
--      d. 취소된 사람의 응모이력이 「取消」로 보이는지, 취소 상세 모달에
--         「運営によるキャンセル」 카테고리만 보이고 관리자 메모는 안 보이는지 확인
--      e. ⚠️ 별도로: 대기 중인 티켓(확정 아님)을 직접 취소해도 남은 대기자
--         순번이 당겨지는지 확인 — 이 경로는 승격이 안 일어나므로 순번 재정렬만
--         단독으로 도는지가 핵심(초안에서 이 경로만 재정렬이 빠지는 회귀가
--         있었다 — 리뷰 중 발견해 수정, 코드 주석 §3 참고)
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.cancel_event_ticket_admin(uuid, text);
-- -- cancel_event_ticket · reserve_event_ticket 은 각각 283 · 284 정의로 되돌린다
-- --   (해당 파일의 CREATE OR REPLACE 블록을 그대로 재실행)
-- DROP FUNCTION IF EXISTS public._promote_next_event_waitlist(uuid);
-- DROP FUNCTION IF EXISTS public._renumber_event_waitlist(uuid);
-- DELETE FROM public.lookup_values WHERE kind='cancel_reason' AND code='admin_cancelled';
-- ALTER TABLE public.event_tickets
--   DROP COLUMN IF EXISTS admin_cancel_note,
--   DROP COLUMN IF EXISTS cancelled_by_name,
--   DROP COLUMN IF EXISTS cancelled_by_role,
--   DROP COLUMN IF EXISTS cancelled_by;
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 289] 289_event_application_status_change_guard.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 289_event_application_status_change_guard.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 행사 캠페인의 신청 상태 직접 변경 차단
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 선행: 280~288 (반드시 288 다음에 적용 — 이유는 아래 「왜 이 순서인가」)
--
-- 왜 필요한가:
--   관리자 화면(dev/js/admin-applications.js updateAppStatus)은 신청 상태를
--   원격 호출 함수(RPC) 없이 `db.from('applications').update({status:...})` 로
--   **직접** 바꾼다(RLS 정책 applications_update_admin 이 허용). 행사(티켓) 캠페인은
--   신청 상태가 event_tickets 와 짝을 이루는 파생값이라, 이 직접 수정 경로로
--   신청만 바뀌면 티켓은 그대로 남아 어긋난다 — 288 파일 헤더가 설명한 바로 그
--   사고(반려된 사람이 현장에서 입장 처리됨)의 근본 원인이다. 288 이 「수단」을
--   만들었으니, 이 파일이 「잘못된 길」을 막는다.
--
-- 왜 이 순서인가 (288 → 289):
--   순서를 뒤집으면(289 를 먼저 적용) 관리자가 예약을 정리할 수단이 하나도
--   없는 채로 직접 수정 경로만 막히는 구간이 생긴다 — 그 사이엔 행사 캠페인의
--   신청 상태를 **아무도** 바꿀 수 없다(사용자 요청 원문 그대로).
--
-- 이 파일이 만드는 것:
--   1) public.guard_event_application_status_change() — BEFORE UPDATE OF status
--      트리거 함수. applications.campaign_id 가 가리키는 캠페인이 event_mode 면
--      막는다. 단, 288 의 예약 함수 3종이 세워 둔 bypass 표시가 있으면 통과시킨다.
--   2) 트리거 trg_guard_event_application_status_change 등록.
--   3) public.reject_pending_on_campaign_end() 재정의(마이그레이션 176 원본에
--      조건 한 줄 추가) — 이유는 아래 「막으면 안 되는 경로」③ 참고.
--
-- ── 막으면 안 되는 경로 (요청사항 — 반드시 통과해야 하는 것) ────────
--
--   ① 예약 함수가 신청 행을 만들고 되살리는 경로 — reserve_event_ticket(288)
--      의 「되살리기(취소 후 재예약)」 UPDATE. 288 에서 이 함수 시작에 bypass
--      표시를 세워 두었으므로 통과한다.
--
--   ② 취소 함수가 cancelled 로 바꾸는 경로 — cancel_event_ticket(본인, 283+288)·
--      cancel_event_ticket_admin(관리자, 288) 이 신청을 cancelled 로 바꾸는
--      UPDATE. 두 함수 모두 bypass 표시를 세운 뒤 UPDATE 하므로 통과한다.
--
--   ③ 대기 → 확정 승격 시 pending → approved 경로 — 위 두 취소 함수가 호출하는
--      _promote_next_event_waitlist(288) 안의 UPDATE. 호출부가 이미 bypass 표시를
--      세운 같은 트랜잭션 안에서 실행되므로 통과한다(트랜잭션 범위 표시라 별도로
--      또 세울 필요 없음).
--
--   ④ (요청사항엔 없었지만 검토 중 발견 — 반드시 함께 막아야 실제로 안전하다)
--      캠페인 종료 자동 낙첨 — 마이그레이션 176 의 reject_pending_on_campaign_end()
--      가 campaigns.status 가 ended/expired 로 바뀔 때 그 캠페인의 pending 신청을
--      **일괄** rejected 로 바꾼다. 행사 캠페인에 대기(waitlist) 티켓이 하나라도
--      있으면 그 신청도 pending 이라 이 일괄 UPDATE 에 걸리는데, 이 UPDATE 는
--      288 의 bypass 표시 없이 들어오므로 위 트리거 1)에 막혀 예외가 던져진다.
--      행 단위 트리거의 예외는 그 UPDATE 문 전체를 롤백시키므로 — **캠페인 자체의
--      ended/expired 전이(campaigns.status UPDATE)까지 함께 실패한다.** 즉 대기
--      티켓이 하나라도 있는 행사 캠페인은 자동 종료가 영영 안 되는 사고가 난다.
--      → reject_pending_on_campaign_end() 에 `AND NOT event_mode` 조건을 추가해
--        행사 캠페인을 이 일괄 처리에서 아예 제외한다(3번 항목). 행사의 대기
--        티켓은 이 자동 낙첨의 대상이 아니다 — event_tickets 로만 정리한다
--        (행사가 끝나도 데이터 정리가 급하지 않으면 waitlist 로 남아 있어도
--        무해하고, 관리자가 288 의 cancel_event_ticket_admin 으로 정리할 수 있다).
--
-- ── 차단 메시지 ─────────────────────────────────────────────────
--   'event_status_change_blocked: 오프라인 행사 신청은 이 화면에서 상태를
--   바꿀 수 없습니다. 캠페인의 「진행현황 → 예약 현황」 탭에서 예약을
--   취소해 주세요.' — dev/js/admin-core.js 의 friendlyError() 가 한글 포함
--   메시지를 그대로 보여주므로(128행 「DB 트리거·함수(RAISE)가 한글 안내
--   메시지를 던지면 그대로 보여준다」), 이 문구가 관리자 화면 토스트에
--   그대로 뜬다 — 별도 클라이언트 수정 없이 무엇을 해야 하는지 안내된다.
--
-- ── 기존 트리거와의 실행 순서 확인 ─────────────────────────────────
--   applications 표의 기존 BEFORE UPDATE OF status 트리거는 1개뿐이다:
--     trg_guard_reject_with_paid_settlement (마이그레이션 247).
--   Postgres 는 같은 타이밍(BEFORE)·같은 이벤트의 트리거를 **트리거 이름
--   알파벳순**으로 실행한다. 이름 비교:
--     trg_guard_event_application_status_change   (이 파일)
--     trg_guard_reject_with_paid_settlement        (247)
--   'e' < 'r' 이므로 이 파일의 트리거가 **먼저** 실행된다.
--     · bypass 있음(288 의 함수들) → 즉시 통과 → 247 로 넘어감(정상, 247 은
--       OLD.status='approved' 이고 paid 정산이 있을 때만 반응하므로 이 파일과
--       독립적으로 동작).
--     · bypass 없음 + event_mode → 이 파일이 먼저 예외를 던져 247 까지 도달
--       하지 않는다. 어차피 막힐 UPDATE 이므로 어느 트리거가 먼저 막든 결과는
--       같다(메시지만 다르다).
--   AFTER 트리거(131/154 record_application_status_event · 246 자동 보류)는
--   이 파일과 타이밍이 달라 순서 경쟁이 없다 — 283 이 event_mode 캠페인에서
--   131/154 를 조기 반환하도록 이미 재정의해 두었다(무변경).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 차단 트리거 함수
-- ============================================================
CREATE OR REPLACE FUNCTION public.guard_event_application_status_change()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_event_mode boolean;
BEGIN
  -- 값이 실제로 안 바뀌는 UPDATE(다른 컬럼만 바뀌며 status 를 같은 값으로
  -- 다시 적는 경우)는 통과시킨다. WHEN 절과 같은 조건을 함수 안에도 한 번 더
  -- 두는 것은 247 의 관례(이중 방어 — 함수가 단독으로 호출돼도 안전).
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- 288 의 예약 함수 3종(reserve_event_ticket · cancel_event_ticket ·
  -- cancel_event_ticket_admin)이 세워 둔 표시. 있으면 이 트랜잭션은 그
  -- 함수들이 낸 변경이라는 뜻이므로 통과시킨다.
  IF COALESCE(current_setting('reverb.event_ticket_bypass', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  -- 캠페인을 찾지 못하면(데이터 정합 문제로 campaign_id 가 고아인 경우 등)
  -- 이 트리거의 책임 범위 밖이므로 막지 않는다(fail-open) — 이 트리거는 행사
  -- 캠페인 전용 보호 장치이지 일반 데이터 무결성 검사기가 아니다.
  SELECT c.event_mode INTO v_event_mode
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  IF COALESCE(v_event_mode, false) THEN
    RAISE EXCEPTION 'event_status_change_blocked: 오프라인 행사 신청은 이 화면에서 상태를 바꿀 수 없습니다. 캠페인의 「진행현황 → 예약 현황」 탭에서 예약을 취소해 주세요.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_event_application_status_change() IS
  '[289] 오프라인 행사(event_mode) 캠페인의 신청 상태를 관리자 화면 등에서 직접 '
  'UPDATE 하는 것을 차단한다. 신청 상태는 반드시 event_tickets 예약 함수(288 '
  'reserve_event_ticket·cancel_event_ticket·cancel_event_ticket_admin)를 거쳐야 '
  '티켓과 어긋나지 않는다. 그 함수들은 set_config(''reverb.event_ticket_bypass'', '
  '''on'', true) 로 자신을 표시하고 이 트리거는 그 표시가 없을 때만 막는다.';

DROP TRIGGER IF EXISTS trg_guard_event_application_status_change ON public.applications;
CREATE TRIGGER trg_guard_event_application_status_change
  BEFORE UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.guard_event_application_status_change();

COMMENT ON TRIGGER trg_guard_event_application_status_change ON public.applications IS
  '[289] 행사 캠페인 신청 상태 직접 변경 차단. 288 예약 함수가 세운 bypass 표시가 '
  '있으면 통과. 기존 trg_guard_reject_with_paid_settlement(247)보다 이름 알파벳순으로 '
  '먼저 실행됨(e < r) — 상세는 파일 헤더 참고.';

-- ============================================================
-- 2. reject_pending_on_campaign_end() 재정의 — 행사 캠페인 제외
--    (마이그레이션 176 원본 + 조건 한 줄. 트리거 자체는 이미 등록돼 있어
--    재등록 불필요 — 함수 본문만 CREATE OR REPLACE)
-- ============================================================
CREATE OR REPLACE FUNCTION public.reject_pending_on_campaign_end()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  -- ended 또는 expired 로 새로 전환된 경우에만 처리.
  -- COALESCE(OLD.status,'') 로 OLD.status 가 NULL 인 엣지케이스도 안전하게 처리.
  -- [289] 행사(event_mode) 캠페인은 이 일괄 처리에서 제외한다 — 이유는 이
  -- 파일 헤더 「막으면 안 되는 경로 ④」 참고. NEW 는 campaigns 행 자체이므로
  -- 조인 없이 NEW.event_mode 로 바로 판정한다.
  IF NEW.status IN ('ended', 'expired')
     AND COALESCE(OLD.status, '') NOT IN ('ended', 'expired')
     AND NOT COALESCE(NEW.event_mode, false)
  THEN
    UPDATE public.applications
      SET status             = 'rejected',
          auto_reject_reason = CASE NEW.status
                                 WHEN 'ended'   THEN 'campaign_ended'
                                 ELSE                'campaign_expired'
                               END,
          reviewed_by        = '시스템(캠페인 종료)',
          -- reviewed_at = NULL: 어제KST 비교 조건에서 자동 제외 → 다이제스트 메일 미발송.
          reviewed_at        = NULL
      WHERE campaign_id = NEW.id
        AND status      = 'pending';
        -- approved / rejected / cancelled 는 WHERE 조건으로 완전 보호.
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.reject_pending_on_campaign_end() IS
  '[176+289] campaigns.status 가 ended/expired 로 전환될 때 해당 캠페인의 pending '
  '신청을 자동으로 rejected 처리. [289] 행사(event_mode) 캠페인은 제외 — 이 일괄 '
  'UPDATE 가 대기(waitlist) 티켓의 신청까지 rejected 로 바꾸려 하면 289 의 차단 '
  '트리거에 막혀 UPDATE 문 전체(=캠페인 상태 전환 자체)가 롤백된다. 행사의 대기 '
  '티켓은 event_tickets 로만 정리한다(288 cancel_event_ticket_admin). reviewed_at=NULL '
  '로 인플루언서 다이제스트 메일 제외. SECURITY DEFINER — 트리거에서만 호출.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- ============================================================
-- [1] 트리거·함수 생성 확인
-- SELECT tgname, tgenabled FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND tgname = 'trg_guard_event_application_status_change';
--   → 1행, tgenabled='O'
--
-- [2] 실행 순서 확인 — applications 의 트리거 전체와 정의를 눈으로 확인
--     (이름 알파벳순으로 이 파일 트리거가 247 보다 먼저 오는지)
-- SELECT tgname, pg_get_triggerdef(oid) AS def
--   FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND NOT tgisinternal
--  ORDER BY tgname;
--   → trg_guard_event_application_status_change 가 trg_guard_reject_with_paid_settlement
--     보다 이름순으로 앞서 나오는지 확인. 각 def 에 BEFORE/AFTER, UPDATE OF status 가
--     기대대로 찍혀 있는지도 함께 확인.
--
-- [3] 차단 동작 확인 — 행사 캠페인의 pending 신청 하나를 관리자 직접 UPDATE 로 승인 시도
--     (SQL Editor 는 관리자 로그인 세션이 아니라 RLS 를 우회하는 서비스 키다 —
--      applications_update_admin 정책과 무관하게 UPDATE 자체는 되지만, 이 트리거는
--      역할과 무관하게 항상 발동하므로 SQL Editor 로도 재현 가능하다. 272 마감 트리거와는
--      다른 특성 — 그쪽은 auth.uid() 를 보는 INSERT 트리거라 SQL Editor 로 재현 안 됐다.)
--     UPDATE public.applications SET status='approved' WHERE id='<행사 캠페인의 pending 신청 id>';
--   → ERROR: event_status_change_blocked: 오프라인 행사 신청은... (트랜잭션 롤백, 상태 안 바뀜)
--
-- [4] 통과 경로 확인 — 288 의 관리자 취소 함수는 여전히 동작하는지
--     (관리자 브라우저 세션에서) cancel_event_ticket_admin 호출 → {"ok":true, ...}
--     여기서 실패하면 289 가 288 의 정상 경로까지 막은 것이므로 즉시 원인 파악.
--
-- [5] 일반(비-행사) 캠페인 회귀 확인 — 지금까지와 동일하게 동작하는지
--     일반 캠페인의 pending 신청 하나를 관리자 화면에서 승인
--   → 정상 승인 + application_events 'approve' 감사 기록 +
--     notifications 'application_approved' 알림 (기존 154 동작 그대로)
--
-- [6] 행사 캠페인 자동 종료 회귀 확인 — 대기 티켓이 있는 행사 캠페인의
--     campaigns.status 를 ended 로 전이시켜도 실패하지 않는지
--     UPDATE public.campaigns SET status='ended' WHERE id='<대기 티켓 있는 행사 캠페인 id>';
--   → 정상 UPDATE 성공. 그 뒤
--     SELECT status FROM public.applications WHERE campaign_id='<위 id>' AND status='pending';
--   → 대기(waitlist) 신청은 그대로 pending 으로 남아 있어야 한다(자동 낙첨 제외 확인).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_guard_event_application_status_change ON public.applications;
-- DROP FUNCTION IF EXISTS public.guard_event_application_status_change();
-- -- reject_pending_on_campaign_end() 는 176 원본 정의로 되돌린다
-- --   (176 파일의 CREATE OR REPLACE 블록을 그대로 재실행)
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 291] 291_event_groups_table.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 291_event_groups_table.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 같은 행사를 여러 캠페인으로 나눈 경우
-- 하나로 묶는 「행사 묶음」 표
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md (선행 280~290)
-- 관련 문서: 이번 팝업(2026-08-28~30)이 8/28(초대 전용)·8/29~30(일반 공개)
--   2개 캠페인으로 나뉘면서, 현장 입장 확인 페이지(dev/event-scan.html)를
--   캠페인 1개 고정에서 캠페인 목록 조회로 바꾸기로 함에 따라 발생.
--
-- 왜 필요한가:
--   부스 단말이 캠페인 하나에 고정되면 8/29 아침에는 8/28 캠페인만 보고 있어
--   빈 명단을 보게 된다. 「같은 행사」로 묶어 사흘 내내 같은 화면으로 운영하면서
--   다른 팝업 행사와는 안 섞이게 한다.
--
-- 왜 자유 문자열이 아니라 별도 표인가 (사용자 결정):
--   자유 입력 칸이면 「REVERB팝업」과 「REVERB 팝업」처럼 띄어쓰기 하나로 두
--   행사가 조용히 갈라진다. 목록에서 골라서만 넣게 하면(캠페인 편집 화면의
--   드롭다운 — dev/ 구현은 후속) 이 오타 분기 자체가 구조적으로 불가능해진다.
--   그래도 표 안에서 이름이 또 오타로 갈리는 걸 막기 위해 정규화 이름에
--   유일 제약을 건다(아래).
--
-- 정규화 이름 유일 제약 — companies(마이그레이션 118·119) 패턴 그대로 미러링:
--   118 원본 함수는 lower(trim(name)) 뿐이라 다중 공백을 못 잡는다.
--   119 가 그 함정을 발견하고 lower(trim(regexp_replace(name,'\s+',' ','g')))
--   로 공백을 압축하는 최종 패턴으로 바꿨다. 이번 요구의 핵심이 정확히
--   「REVERB팝업」 vs 「REVERB 팝업」(공백 개수 차이)이므로, 이 표는 처음부터
--   118 원본이 아니라 119 최종 패턴을 베이스로 만든다(118→119 순서를
--   되풀이하지 않는다).
--
-- 캠페인 연결 — 브랜드↔회사(brands.company_id)와 동일한 방식:
--   campaigns.event_group_id 를 ON DELETE SET NULL 로 건다. 묶음을 지워도
--   그 묶음을 참조하던 캠페인의 저장·조회가 막히지 않고 연결만 끊어진다.
--   막는 방식(RESTRICT)으로 걸면 행사 종료 후 묶음 정리 한 번이 그 캠페인의
--   이후 모든 저장을 막게 된다.
--
--   ⚠️ 의도적으로 걸지 않은 제약 2가지:
--   ① 「같은 브랜드끼리만 묶을 수 있다」— 합동 팝업은 브랜드가 서로 다른
--      캠페인을 묶어야 하므로 브랜드 일치 검증을 걸면 그 사용 사례 자체가
--      막힌다.
--   ② 「행사 모드(event_mode=true) 캠페인만 묶을 수 있다」를 데이터베이스
--      CHECK/트리거로 강제 — 지금은 화면(관리자 편집 폼)이 행사 모드일 때만
--      묶음 칸을 보여주고, 현장 확인 페이지(event-scan.html)도 행사 모드
--      캠페인만 읽는 것으로 계획돼 있어 사실상 그렇게 쓰이지만, 이건 화면
--      쪽 계약이다. 데이터베이스에 강제로 박아 두면 나중에 모집 형식·행사
--      운영 방식이 바뀔 때(예: 리뷰어형에도 행사 모드를 허용하기로 결정)
--      이 표까지 함께 마이그레이션해야 저장이 풀린다. 캠페인 표 210행
--      CLAUDE.md 「event_mode」 항목이 이미 이 함정(리뷰어형에 event_mode
--      를 켜면 049 자동승인 트리거와 충돌)을 다루고 있어, 묶음 표까지
--      같은 위험을 겹쳐 지지 않는다.
--
-- 접근 권한:
--   조회 = 관리자 전체(is_admin()) — 현장 확인 페이지가 관리자 로그인을
--   요구하므로 그대로 읽힌다.
--   만들기·고치기·지우기 = is_campaign_admin() 이상(companies 118 과 동일 등급).
--
-- 마이그레이션 275(캠페인 동시 저장 방어)와의 관계:
--   새 칸 campaigns.event_group_id 는 275 의 제외 목록(version·updated_at·
--   view_count·applied_count·order_index·first_active_at) 에 없으므로
--   **자동으로 낙관적 락 보호 대상**이 된다(280 의 두 칸·285 의 한 칸과 같은
--   판단). 별도 조치 불필요 — 관리자 편집 저장은 기존과 동일하게
--   updateCampaign(id, updates, expectedVersion) 으로 현재 버전을 함께
--   넘기면 된다.
--
-- 마이그레이션 265·266(캠페인 전체 항목 변경 이력)과의 관계 — 의도적 제외:
--   이 칸을 화이트리스트에 넣지 않는다. 앞선 행사 관련 칸 3개(280 의
--   event_mode·is_invite_only, 285 의 event_place)가 전부 같은 판단으로
--   빠져 있다. 화이트리스트는 세 곳(265 의 CHECK 제약 조건 · 266 의 v_fields
--   항목 배열 · 266 트리거의 AFTER UPDATE OF 감시 컬럼 목록)이 항상 같은
--   집합이어야 하고, 어긋나면 CHECK 위반으로 캠페인 저장 트랜잭션 전체가
--   실패한다. 행사 캠페인은 소수·기간 한정이라 이 위험을 새로 지지 않는다.
--
-- 적용 순서 — 반드시 데이터베이스가 코드보다 먼저:
--   275 적용 때와 같은 순서다. 이 마이그레이션(데이터베이스)을 먼저 개발·운영
--   순서로 적용한 뒤에 dev/ 쪽 코드(관리자 편집 폼의 묶음 드롭다운, 현장 확인
--   페이지의 캠페인 목록 조회)를 배포한다. 순서가 바뀌면 아직 없는 칸
--   (event_group_id)·아직 없는 표(event_groups)를 화면이 먼저 참조하게 돼
--   캠페인 저장 자체가 실패한다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 행사 묶음 표
-- ============================================================
CREATE TABLE IF NOT EXISTS public.event_groups (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text        NOT NULL,
  name_normalized  text        UNIQUE NOT NULL,
  status           text        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'archived')),
  memo             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.event_groups IS
  '[291] 오프라인 행사 묶음 — 같은 행사가 캠페인 여러 개로 나뉠 때(초대 전용/일반
  공개 등) 하나로 묶는다. 목록에서 골라서만 연결(자유 문자열 금지 — 띄어쓰기
  오타로 같은 행사가 갈라지는 것을 막기 위한 사용자 결정).';
COMMENT ON COLUMN public.event_groups.name_normalized IS
  '[291] 중복 차단용 정규화 키. lower(trim(regexp_replace(name,''\s+'','' '',''g''))).
  companies(마이그레이션 118→119 최종 패턴) 미러링 — 공백 개수 차이도 중복으로 본다.
  직접 입력 불가, 트리거가 자동 계산.';
COMMENT ON COLUMN public.event_groups.status IS
  '[291] active=사용중, archived=보관. 지워도 캠페인 연결은 끊어질 뿐 저장이
  막히지 않으므로(event_group_id ON DELETE SET NULL), 재사용 여지가 있으면
  삭제 대신 archived 권장.';

CREATE INDEX IF NOT EXISTS event_groups_status_idx ON public.event_groups (status);

-- ── 정규화 이름 자동 계산 트리거 (119 최종 패턴 그대로) ──
CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.name_normalized := lower(trim(regexp_replace(coalesce(NEW.name, ''), '\s+', ' ', 'g')));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_event_group_name_normalized() IS
  '[291] event_groups.name_normalized 자동 계산 — lower+trim+다중 공백 단일 압축.
  companies.set_company_name_normalized(마이그레이션 119 최종 버전) 패턴 미러링.';

REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
CREATE TRIGGER trg_event_groups_name_normalized
  BEFORE INSERT OR UPDATE OF name ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.set_event_group_name_normalized();

-- ── updated_at 자동 갱신 트리거 ──
CREATE OR REPLACE FUNCTION public.touch_event_groups_updated_at()
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

COMMENT ON FUNCTION public.touch_event_groups_updated_at() IS
  '[291] event_groups.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM anon;
GRANT EXECUTE ON FUNCTION public.touch_event_groups_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_groups_updated_at ON public.event_groups;
CREATE TRIGGER trg_event_groups_updated_at
  BEFORE UPDATE ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_event_groups_updated_at();

-- ── 행 단위 보안 정책 — 조회는 관리자 전체, 쓰기는 campaign_admin 이상(companies 118 미러링) ──
ALTER TABLE public.event_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_groups_select_admin ON public.event_groups;
CREATE POLICY event_groups_select_admin
  ON public.event_groups
  FOR SELECT
  USING (public.is_admin());

DROP POLICY IF EXISTS event_groups_insert_admin ON public.event_groups;
CREATE POLICY event_groups_insert_admin
  ON public.event_groups
  FOR INSERT
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS event_groups_update_admin ON public.event_groups;
CREATE POLICY event_groups_update_admin
  ON public.event_groups
  FOR UPDATE
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS event_groups_delete_admin ON public.event_groups;
CREATE POLICY event_groups_delete_admin
  ON public.event_groups
  FOR DELETE
  USING (public.is_campaign_admin());

-- ============================================================
-- 2. 캠페인 연결 칸 — ON DELETE SET NULL (brands.company_id 와 동일한 방식)
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_group_id uuid
    REFERENCES public.event_groups(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.campaigns.event_group_id IS
  '[291] 소속 행사 묶음(event_groups) 외래 키. NULL 허용 — 묶음을 지워도 이 칸만
  NULL 로 끊어지고 캠페인 저장은 막히지 않는다(brands.company_id 패턴 미러링).
  브랜드 일치·행사 모드(event_mode) 여부를 데이터베이스에서 강제하지 않는다
  (합동 팝업·향후 형식 변경 대비 — 파일 헤더 참고). 목록에서 골라서만 넣는
  UI 는 후속 구현(dev/ 미포함, 이 마이그레이션은 데이터베이스만).';

CREATE INDEX IF NOT EXISTS campaigns_event_group_id_idx ON public.campaigns (event_group_id);

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL Editor에서 1단계씩 순서대로 — 중간에 오류가 나면 즉시 멈추고 원인 확인)
-- ============================================================
-- [1] 표·컬럼 생성 확인
-- SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='event_groups'
--  ORDER BY ordinal_position;
--
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns' AND column_name='event_group_id';
--   → uuid, YES
--
-- [2] 기존 캠페인은 전부 NULL (도입 즉시 동작 변화 0)
-- SELECT count(*) FROM public.campaigns WHERE event_group_id IS NOT NULL;   -- 0
--
-- [3] ⛔ 이 블록은 **돌리지 마세요 — 292 로 대체됐습니다.**
--   아래 「실패해야 정상」이라는 서술 자체가 틀렸습니다(2026-08-05 개발 실측).
--   이 파일의 정규화는 공백을 **압축**만 하고 제거하지 않아 「REVERB팝업」과
--   「REVERB 팝업」이 **둘 다 저장됩니다.** 291 만 적용한 상태에서 이걸 돌리면
--   통과하지 않는 게 정상인데 「고장 났다」로 오판하게 됩니다.
--   → 291 적용 후 곧바로 292_event_groups_name_normalized_fix.sql 을 이어서
--     적용하고, **292 하단의 재검증 절차**를 쓰세요.
--
-- [3-폐기] ★ (옛 검증 — 공백 하나 차이도 중복으로 거부되는지)
-- INSERT INTO public.event_groups (name) VALUES ('REVERB팝업');
--   → 성공
-- INSERT INTO public.event_groups (name) VALUES ('REVERB 팝업');
--   → 실패해야 정상 (unique constraint "event_groups_name_normalized_key" violation)
--     두 값 모두 name_normalized = 'reverb팝업' 로 계산되기 때문(공백은
--     regexp_replace 로 압축된 뒤 trim 되어 사실상 제거됨).
--   검증 후 테스트 행 정리: DELETE FROM public.event_groups WHERE name = 'REVERB팝업';
--
-- [4] 캠페인 연결 → 묶음 삭제 시 캠페인 저장이 막히지 않는지
-- -- (1) 테스트 묶음 생성 + 실제 캠페인 1개에 연결
-- INSERT INTO public.event_groups (name) VALUES ('__검증용_임시묶음__') RETURNING id;
-- UPDATE public.campaigns SET event_group_id = '<위에서 나온 id>' WHERE id = '<검증용_캠페인_ID>';
-- -- (2) 묶음 삭제
-- DELETE FROM public.event_groups WHERE name = '__검증용_임시묶음__';
-- -- (3) 캠페인 행이 여전히 존재하고 event_group_id 만 NULL 로 끊겼는지 확인
-- SELECT id, event_group_id FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';
--   → event_group_id IS NULL, 캠페인 행 자체는 그대로
--
-- [5] 275 낙관적 락이 새 컬럼을 보호하는지(제외 목록에 안 들어갔는지)
-- SELECT id, version FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';
-- UPDATE public.campaigns SET event_group_id = NULL WHERE id = '<검증용_캠페인_ID>';
-- SELECT version FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';   -- +1 이어야 함(값이 이미 NULL이면 변화 없어 버전도 그대로 — 위 [4]에서 값이 있었던 캠페인으로 확인)
--
-- [6] 행 단위 보안 정책 확인
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename='event_groups' ORDER BY policyname;
--   → select/insert/update/delete 4개
-- ============================================================

-- ============================================================
-- 롤백 (역순: 캠페인 칸 → 트리거·함수 → 표)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS public.campaigns_event_group_id_idx;
-- ALTER TABLE public.campaigns DROP COLUMN IF EXISTS event_group_id;
--
-- DROP TRIGGER IF EXISTS trg_event_groups_updated_at ON public.event_groups;
-- DROP FUNCTION IF EXISTS public.touch_event_groups_updated_at();
-- DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
-- DROP FUNCTION IF EXISTS public.set_event_group_name_normalized();
--
-- DROP POLICY IF EXISTS event_groups_delete_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_update_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_insert_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_select_admin ON public.event_groups;
--
-- DROP TABLE IF EXISTS public.event_groups;
-- COMMIT;


-- ───────────────────────────────────────────────────────────────
-- [파일 292] 292_event_groups_name_normalized_fix.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 292_event_groups_name_normalized_fix.sql
-- 마이그레이션 291(행사 묶음 표)의 정규화 규칙 결함 교정
-- 사양서: docs/specs/2026-08-05-event-group-and-scoped-checkin.md §4-1
--
-- ⚠️ 291 파일은 이미 개발 데이터베이스에 적용됐으므로 수정하지 않는다.
--   이 파일은 291 이 만든 함수를 새 규칙으로 "다시 정의"하는
--   교체 마이그레이션이다(companies 표가 118→119 로 교체했던 것과 같은 방식).
--
-- 무엇이 잘못됐었나 (개발 데이터베이스 실측, 2026-08-05):
--   291 의 정규화 함수는
--     lower(trim(regexp_replace(name, '\s+', ' ', 'g')))
--   였다. 이건 "연속 공백을 하나로 압축"하는 규칙이지 "공백 제거"가
--   아니다. 그래서 「REVERB팝업」(공백 0개)과 「REVERB 팝업」(공백 1개)은
--   압축해도 서로 다른 문자열로 남아 유일 제약을 피해 **둘 다 저장됐다**.
--   291 파일 하단 주석 [3]에 "실패해야 정상"이라고 적혀 있었던 것 자체가
--   틀린 서술이었다(compress ≠ strip 를 착각).
--
--   291 헤더 주석이 근거로 든 "companies 마이그레이션 118→119 최종 패턴"도
--   목적이 다르다. 119 는 "제이펀"과 "제이 펀"을 **다른 회사로 남기는 것이
--   맞는** 회사명 정책이라 압축까지만 하면 충분했다. 이번 행사 묶음 이름은
--   반대로 "REVERB팝업"과 "REVERB 팝업"을 **같은 묶음으로** 봐야 하므로
--   압축이 아니라 완전 제거가 맞는 규칙이다. 두 정책은 서로 다른 요구라
--   같은 패턴을 그대로 옮겨 쓸 수 없었다.
--
-- 무엇으로 바뀌는가:
--   lower(trim(regexp_replace(name, '\s+', ' ', 'g')))            -- 291(폐기)
--   ↓
--   lower(regexp_replace(coalesce(name, ''), '[\s　]+', '', 'g'))  -- 292(신규)
--
--   공백을 압축하지 않고 전부 제거한다(문자 자체를 지우므로 trim 은
--   불필요 — 양 끝 공백도 이미 지워진다). 일반 공백·탭·줄바꿈 등은
--   정규식 문자 클래스 `\s` 로 잡히고, 여기에 **전각 공백(U+3000, 　)**
--   1개를 명시적으로 추가했다 — 이건 사용자 요청(모든 공백 문자)을
--   문자 그대로 해석하면 `\s` 만으로 충분하지만, 일본어 키보드 입력에서
--   흔히 섞여 들어오는 U+3000 전각 공백은 POSIX `\s` 가 못 잡는 별도
--   문자라서 방치하면 같은 사고(「REVERB　팝업」전각 공백이 딴 값으로
--   저장됨)가 형태만 바뀌어 재발할 수 있다고 판단해 방어적으로 추가했다.
--   요청 범위를 벗어난 판단이므로 이 사실을 명시해 둔다(리뷰 시 이견 있으면
--   되돌리기 쉽게 이 문단만 삭제하고 `[\s　]+` 를 `\s+` 로 되돌리면 된다).
--
-- 기존 행 재계산 — 검증용 테스트 행 삭제가 먼저 필요한 이유:
--   개발 데이터베이스에 이미 「REVERB팝업」·「REVERB 팝업」 두 행이 들어가
--   있다(291 검증 과정에서 생성됨, 서로 다른 name_normalized 로 저장돼
--   유일 제약을 피해 둘 다 성공했었다). 새 규칙으로 재계산하면 두 행의
--   name_normalized 가 똑같아져 유일 제약 위반으로 이 마이그레이션
--   자체가 실패한다.
--   이 두 행은 291 검증 목적으로만 만든 쓰레기 데이터이고 실사용 행사가
--   아니므로, 재계산 전에 **이름이 정확히 이 두 값과 일치하는 행만**
--   선택적으로 지운다(다른 이름의 정상 행은 절대 건드리지 않음).
--   운영 데이터베이스는 291 이 아직 적용되지 않아 event_groups 표 자체가
--   없거나 있어도 0행이므로, 이 삭제문은 운영에서 사실상 아무 일도 안 한다.
--
--   삭제 후에도 혹시 모를 다른 중복(이 두 값 이외의 이름이 새 규칙에서
--   충돌하는 경우)이 있으면, 재계산 직전 사전 점검이 알아보기 쉬운
--   오류 메시지로 멈춘다(무슨 값이 몇 개 충돌하는지는 안내만, 실제 처리는
--   운영자가 수동으로 정리 후 재실행).
--
-- 적용 순서 (운영 배포 시 반드시 지킬 것):
--   운영 데이터베이스에는 291 이 아직 적용되지 않았다. 291 → 292 를
--   **반드시 이 순서로, 두 파일 다** 적용한다(292 는 291 이 만든 함수를
--   전제로 "재정의"하는 파일이라 291 없이 단독 적용 불가 — CREATE OR
--   REPLACE 대상 함수 자체가 없어서가 아니라 event_groups 표·트리거가
--   없으면 이 파일의 문(DELETE·UPDATE)이 대상 표를 못 찾아 실패한다).
--
--   ⚠️ 291 파일 하단의 검증 절차 [3]("REVERB 팝업" 삽입이 "실패해야
--   정상")은 **291 만 적용한 직후에는 통과하지 않는다** — 그 시점엔 아직
--   압축 규칙이라 두 값 다 성공하는 게 291 단독 기준으로는 "정상"이다.
--   운영에서 291 을 적용한 뒤 그 검증 SQL을 그대로 돌리면 "고장났다"고
--   오판하게 되니, **291 적용 직후에는 그 검증 [3]을 돌리지 말고 바로
--   292 를 이어서 적용**한 다음 이 파일 하단의 재검증 절차로 확인한다.
--
-- 아직 이 표를 참조하는 화면 코드가 없음 (2026-08-05 기준):
--   관리자 캠페인 편집 폼의 묶음 드롭다운, 현장 확인 페이지의 목록 조회
--   모두 미착수(dev/ 미포함) — 그래서 지금이 정규화 규칙을 바꿔도
--   화면 쪽 영향이 0인, 가장 안전한 시점이다.
--
-- 롤백: 파일 하단 참고 (291 의 압축 규칙 함수 정의로 되돌림 — 단,
--   되돌려도 이미 292 가 지운 테스트 행 2개는 복원되지 않는다는 점 주의).
-- ============================================================

BEGIN;

-- ── 1. 검증용 테스트 행 정리 (이름이 정확히 이 두 값일 때만) ──
--    운영은 event_groups 가 비어 있거나 아예 없는 상태라 사실상 0행 영향.
DELETE FROM public.event_groups
 WHERE name IN ('REVERB팝업', 'REVERB 팝업');

-- ── 2. 사전 점검 — 새 규칙에서 여전히 충돌하는 이름이 남아있으면 여기서 멈춤 ──
DO $$
DECLARE
  v_dupe_groups int;
BEGIN
  SELECT count(*) INTO v_dupe_groups
  FROM (
    SELECT lower(regexp_replace(coalesce(name, ''), '[\s　]+', '', 'g')) AS norm
      FROM public.event_groups
     GROUP BY 1
    HAVING count(*) > 1
  ) dupes;

  IF v_dupe_groups > 0 THEN
    RAISE EXCEPTION
      'event_groups: 공백을 완전히 제거하는 새 정규화 규칙을 적용하면 서로 같아지는 이름 묶음이 %개 있습니다. 관리자 화면 또는 SQL로 이름을 수동 정리한 뒤 이 마이그레이션을 다시 실행하세요.',
      v_dupe_groups;
  END IF;
END $$;

-- ── 3. 정규화 함수 재정의 — 압축이 아니라 전부 제거 ──
CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- [292] 291 의 "연속 공백 압축" 규칙을 폐기하고 "공백 완전 제거"로 교체.
  -- \s(일반 공백·탭·줄바꿈 등) + U+3000(전각 공백) 를 전부 지운다.
  -- 문자 자체를 지우므로 trim 은 불필요(양 끝 공백도 이미 제거됨).
  NEW.name_normalized := lower(regexp_replace(coalesce(NEW.name, ''), '[\s　]+', '', 'g'));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_event_group_name_normalized() IS
  '[292] event_groups.name_normalized 자동 계산 — lower + 공백(일반+전각) 완전 제거.
  291 의 "다중 공백 압축" 규칙은 「REVERB팝업」과 「REVERB 팝업」을 구분하지
  못해 폐기됨(개발 데이터베이스 실측). companies(119)의 압축 패턴과는
  의도적으로 다른 규칙 — companies 는 "제이펀"≠"제이 펀"이 맞는 정책, 이
  표는 그 반대(같은 값으로 취급)가 맞는 정책이라 갈라짐.';

REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;

-- 트리거는 291 이 이미 함수 이름으로 연결해 두었으므로 재생성 불필요
-- (CREATE OR REPLACE FUNCTION 이 같은 이름을 그대로 유지하면 트리거는
-- 자동으로 새 함수 본문을 사용한다). 그래도 재적용 안전을 위해 명시:
DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
CREATE TRIGGER trg_event_groups_name_normalized
  BEFORE INSERT OR UPDATE OF name ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.set_event_group_name_normalized();

-- ── 4. 기존 행 재계산 — 새 규칙으로 name_normalized 다시 채움 ──
-- name 컬럼을 SET 절에 명시하면(값이 실제로 안 바뀌어도) "UPDATE OF name"
-- 트리거가 모든 행에 대해 발동한다 — PostgreSQL 표준 동작. 위 [2]에서
-- 충돌이 없다고 확인했으므로 여기서 유일 제약에 걸릴 일은 없다.
UPDATE public.event_groups SET name = name;

COMMIT;

-- ============================================================
-- 재검증 (SQL Editor에서 1단계씩 순서대로 — 292 적용 후 실행)
-- ============================================================
-- [1] 함수가 새 규칙으로 바뀌었는지 직접 계산으로 확인
-- SELECT lower(regexp_replace('REVERB 팝업', '[\s　]+', '', 'g'));   -- → 'reverb팝업'
-- SELECT lower(regexp_replace('REVERB팝업',  '[\s　]+', '', 'g'));   -- → 'reverb팝업' (위와 동일해야 함)
--
-- [2] ★ 핵심 재검증 — 이번엔 실제로 거부되는지
-- INSERT INTO public.event_groups (name) VALUES ('REVERB팝업');
--   → 성공
-- INSERT INTO public.event_groups (name) VALUES ('REVERB 팝업');
--   → 실패해야 정상 (unique constraint "event_groups_name_normalized_key" violation)
-- INSERT INTO public.event_groups (name) VALUES ('REVERB　팝업');  -- 전각 공백
--   → 이것도 실패해야 정상 (전각 공백도 같은 값으로 취급)
--
-- 검증 후 테스트 행 정리:
-- DELETE FROM public.event_groups WHERE name = 'REVERB팝업';
--
-- [3] 기존 행(있다면)이 전부 새 규칙으로 재계산됐는지 표본 확인
-- SELECT name, name_normalized FROM public.event_groups ORDER BY created_at DESC LIMIT 20;
--   → name_normalized 에 공백이 전혀 없어야 함
-- ============================================================

-- ============================================================
-- 롤백 (291 의 "압축" 규칙 함수 정의로 되돌림)
-- ⚠️ 되돌려도 이 마이그레이션이 지운 테스트 행 2개(REVERB팝업/REVERB 팝업)는
--   복원되지 않는다. 그 시점 이후 새로 들어간 실사용 행은 name_normalized
--   가 압축 규칙 기준으로 재계산되지 않은 채 남으므로, 롤백 후에는 아래
--   4번 재계산 UPDATE 를 반드시 함께 실행할 것.
-- ============================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
-- RETURNS trigger
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- BEGIN
--   NEW.name_normalized := lower(trim(regexp_replace(coalesce(NEW.name, ''), '\s+', ' ', 'g')));
--   IF NEW.name_normalized = '' THEN
--     RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
--   END IF;
--   RETURN NEW;
-- END;
-- $$;
--
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
-- GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;
--
-- UPDATE public.event_groups SET name = name;  -- 압축 규칙으로 재계산
-- COMMIT;
-- ============================================================

