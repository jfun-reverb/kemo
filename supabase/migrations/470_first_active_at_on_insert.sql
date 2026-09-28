-- ============================================================
-- 470_first_active_at_on_insert.sql
-- 캠페인이 **처음부터 모집중(active)으로 삽입**돼도 first_active_at 을 기록한다 + 빈 값 채움
-- 사양서: docs/specs/2026-09-28-promo-mail-new-and-deadline-window.md §4-1 ①
--
-- ── 왜 ──
--   140 의 트리거는 `BEFORE UPDATE OF status` 뿐이라, 신규 등록 폼이 노출을 켜고 바로 active 로
--   삽입한 캠페인(2026-08-12 이후 — 오리엔시트 발행 포함)은 first_active_at 이 **영원히 비었다.**
--   홍보 메일 「신규」 절이 그 값으로 캠페인을 고르므로 그런 캠페인은 창을 고쳐도 빠진다.
--   운영 실측(2026-09-28): 빈 캠페인 16건(보관 삭제 제외) — 모집마감 6 · 종료 9 · 노출종료 1.
--
-- ── 무엇을 ──
--   ① 트리거 함수: 삽입이면 `NEW.status='active'` 만 보고, 수정이면 기존 조건(`OLD.status <> 'active'`)
--      그대로. 삽입에는 OLD 가 없어 TG_OP 로 가른다. 이미 값이 있으면 불변(140 과 같다).
--      🔴 CREATE OR REPLACE — 함수 권한(369·370 회수)이 그대로 남는다.
--   ② 트리거를 `BEFORE INSERT OR UPDATE OF status` 로 다시 건다.
--   ③ 빈 값 채움 — 140 B-2 와 같은 식 COALESCE(recruit_start, created_at).
--      대상 = active·closed·ended·expired + 빈 값 + 보관 삭제 아님.
--      ⚠️ 이 네 상태가 「한 번이라도 모집중이었다」와 정확히 같지는 않다(모집예정 → 모집마감 전이가 있다).
--         그런 행은 status 가 active 가 아니라 신규 조건에 안 걸리므로 채워도 해가 없다.
--
-- ⚠️ first_active_at 은 낙관적 잠금 제외 목록(275)에 있어 채워도 version 이 안 오른다 —
--    열려 있는 편집 폼과 충돌하지 않는다. 변경 이력 화이트리스트(265·266)에도 없다.
--
-- ── 적용 전 확인 ──(2026-09-28 운영 기준 16건 — 다르면 멈추고 확인)
--   select status, count(*) from public.campaigns
--    where deleted_at is null and first_active_at is null
--      and status in ('active','closed','ended','expired') group by status;
--
-- ── 되돌리기 ──
--   트리거를 140 판(BEFORE UPDATE OF status)으로 다시 걸고 함수도 140 본문으로.
--   채운 값은 되돌리지 않는다(원래 비어 있어야 할 값이 아니다).
-- ============================================================

CREATE OR REPLACE FUNCTION public._record_first_active_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $func$
BEGIN
  -- 처음으로 active 가 되는 순간만 기록 (이미 first_active_at 있으면 불변 유지)
  --   삽입(470): 처음부터 active 로 들어오면 그 순간이 모집 시작이다.
  --   수정(140): active 가 아니던 것이 active 가 될 때.
  IF NEW.status = 'active'
     AND NEW.first_active_at IS NULL
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'active')
  THEN
    NEW.first_active_at := now();
  END IF;
  RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION public._record_first_active_at() IS
  '[140→470] campaigns.status 가 처음 active 가 되는 순간(삽입 포함) first_active_at 를 기록하는 트리거 함수. SECURITY DEFINER + search_path 고정.';

DROP TRIGGER IF EXISTS trg_campaigns_first_active_at ON public.campaigns;
CREATE TRIGGER trg_campaigns_first_active_at
  BEFORE INSERT OR UPDATE OF status ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public._record_first_active_at();

UPDATE public.campaigns
   SET first_active_at = COALESCE(recruit_start::timestamptz, created_at)
 WHERE deleted_at IS NULL
   AND first_active_at IS NULL
   AND status IN ('active', 'closed', 'ended', 'expired');

-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 빈 값이 남지 않았는가 (0 이어야 한다)
select count(*) from public.campaigns
 where deleted_at is null and first_active_at is null
   and status in ('active','closed','ended','expired');

-- [V2] 트리거가 삽입·수정 둘 다에 걸리는가 — tgtype 비트: 4=INSERT, 16=UPDATE
select tgname, (tgtype & 4) > 0 as on_insert, (tgtype & 16) > 0 as on_update
  from pg_trigger where tgname = 'trg_campaigns_first_active_at';

-- [V3] 처음부터 active 로 삽입하면 기록되는가 — 되돌리는 시험(아무것도 안 남긴다)
do $$ declare v timestamptz; begin
  insert into public.campaigns (title, status) values ('__first_active_probe__', 'active')
    returning first_active_at into v;
  raise exception 'PROBE first_active_at=%', v;   -- 전부 되돌린다
end $$;
-- 기대: 「PROBE first_active_at=<지금 시각>」 오류 메시지(NULL 이면 실패)
*/
