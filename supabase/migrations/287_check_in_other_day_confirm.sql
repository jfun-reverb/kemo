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
