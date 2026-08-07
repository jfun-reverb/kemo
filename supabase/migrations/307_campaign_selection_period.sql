-- ============================================================
-- 307_campaign_selection_period.sql
-- 시딩형 캠페인의 「선정 기간」 — 언제 뽑는지를 날짜로 알린다
-- 사양서: docs/specs/2026-08-06-campaign-period-wording-and-payback-notice.md (3단계 · 변경 C)
-- 선행: 없음 (칸 2개 추가만)
--
-- 왜 필요한가:
--   시딩형 캠페인에 「모집 기간 → 결과물 제출 마감일」만 있어, 인플루언서가
--   「언제 뽑히는지」를 알 수 없었다. 기존 `winner_announce`(자유 텍스트)는
--   「어떻게 알려주는지」(LINE 연락 등)를 적는 칸이라 날짜를 대신하지 못한다.
--   → 두 칸은 **함께 쓴다**(2026-08-07 사용자 결정) — 날짜는 여기, 방법은 winner_announce.
--
-- ⚠️ 기존 행은 채우지 않는다. 값이 없으면 화면이 그 줄을 아예 그리지 않으므로
--    지금까지 등록된 캠페인은 보이는 모습이 달라지지 않는다.
--
-- ⚠️ 자동으로 따라오는 것 / 일부러 안 하는 것
--   ① 동시 저장 방어(275)는 **자동 적용**된다. `campaigns_bump_version()` 이
--      제외 6개(version·updated_at·view_count·applied_count·order_index·first_active_at)
--      를 뺀 나머지가 바뀌면 version 을 올리므로, 새 칸도 그날부터 보호 대상이다.
--      편집 저장은 이미 expectedVersion 을 넘기고 있어 추가 작업이 없다.
--   ② 변경 이력 화이트리스트(265·266)에는 **넣지 않는다.** 행사 칸 2개
--      (event_mode·is_invite_only)와 같은 판단 — 그 목록은 세 곳(제약·필드목록·
--      트리거 AFTER UPDATE OF)이 항상 같은 집합이어야 하고, 어긋나면 CHECK 위반으로
--      캠페인 저장 자체가 실패한다. 날짜 두 칸을 위해 그 위험을 지지 않는다.
-- ============================================================

BEGIN;

ALTER TABLE public.campaigns ADD COLUMN IF NOT EXISTS selection_start date;
ALTER TABLE public.campaigns ADD COLUMN IF NOT EXISTS selection_end   date;

COMMENT ON COLUMN public.campaigns.selection_start IS
  '[307] 선정 기간 시작일. 시딩형에서만 입력받는다. NULL 이면 화면에 줄을 안 그린다.';
COMMENT ON COLUMN public.campaigns.selection_end IS
  '[307] 선정 기간 종료일. winner_announce(발표 방법 문구)와 함께 쓴다 — 대체 관계가 아니다.';

-- 시작일이 종료일보다 늦을 수 없다.
--   구매 기간·방문 기간(036)이 같은 제약을 갖고 있어 관례를 맞춘다. 화면의 달력이
--   범위 선택이라 사람 손으로는 역전이 안 되지만, **화면 밖 경로**(직접 SQL·이관
--   스크립트·앞으로 만들 서버 함수)로 들어오는 값은 아무도 막지 않는다.
--   ⚠️ 값이 하나도 없는 지금이 이 제약을 거는 가장 안전한 시점이다.
ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS chk_campaigns_selection_range;
ALTER TABLE public.campaigns
  ADD  CONSTRAINT chk_campaigns_selection_range
       CHECK (selection_start IS NULL OR selection_end IS NULL OR selection_start <= selection_end);

-- ── 자기 검증 ──
--   칸이 실제로 생겼는지 같은 트랜잭션 안에서 확인한다. 안 생겼으면 되돌린다.
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'campaigns'
    AND column_name IN ('selection_start', 'selection_end');

  IF v_cnt <> 2 THEN
    RAISE EXCEPTION '[307] 선정 기간 칸이 2개가 아니라 %개입니다 — 되돌립니다.', v_cnt;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_campaigns_selection_range') THEN
    RAISE EXCEPTION '[307] 날짜 순서 제약이 걸리지 않았습니다 — 되돌립니다.';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- 검증 (적용 뒤 따로 돌려 확인)
-- ============================================================
/*
-- [V1] 칸 2개가 생겼고 전부 비어 있는지
SELECT
  count(*) AS 전체캠페인,
  count(selection_start) AS 선정시작_채워진수,
  count(selection_end)   AS 선정종료_채워진수
FROM public.campaigns;
-- 기대: 채워진 수 둘 다 0

-- [V2] 자료형이 날짜인지
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='campaigns'
  AND column_name IN ('selection_start','selection_end');
-- 기대: date · YES 2줄
*/

-- ============================================================
-- 되돌리기
-- ============================================================
/*
-- ⚠️ 값이 들어가기 전에만 안전하다. 입력이 시작된 뒤에 지우면 그 내용이 사라진다.
ALTER TABLE public.campaigns DROP COLUMN IF EXISTS selection_start;
ALTER TABLE public.campaigns DROP COLUMN IF EXISTS selection_end;
*/
