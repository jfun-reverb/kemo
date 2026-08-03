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
