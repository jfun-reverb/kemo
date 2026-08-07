-- ============================================================
-- 304_check_in_ticket_scope_guard.sql
-- 오프라인 팝업 방문 예약 — 현장 확인 화면의 "보는 범위" 밖 티켓을 서버가 거부
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md (§4-4 이어지는 결함 수정)
-- 선행: 280~294, 297~303 (특히 283 원본 · 287 재정의)
--
-- 왜 필요한가 (2026-08-06 실측 발견):
--   현장 확인 화면(dev/event-scan.html)은 "행사 묶음"(291·292)으로 범위를 정해서
--   연다(?group=<묶음id>). 그런데 그 범위는 **명단 조회(loadRoster)에만** 적용되고
--   입장 확인(checkIn → check_in_ticket)에는 전혀 적용되지 않는다.
--   실측: 묶음1(캠페인 2개)로 연 화면에 **묶음 밖 캠페인**의 확정 티켓 번호를
--   손입력했더니, 화면은 "오늘이 아닙니다 · 8월 7일 예약"이라며 **날짜 문제로만**
--   안내하고 초록색 「입장 처리」 버튼을 그대로 내줬다. 누르면 다른 행사 예약자가
--   입장 처리된다 — 화면판(자립형 페이지)에서만 막으면 화면을 우회(직접 rpc 호출)
--   했을 때 그대로 뚫리므로, **서버가 범위를 모르는 한 근본적으로 막을 수 없다**.
--
-- 무엇을 바꾸나:
--   인자 p_scope_campaign_ids(uuid[], DEFAULT NULL) 추가.
--     · NULL 이거나 빈 배열       → **fail-closed**: 아무것도 기록하지 않고
--                                    reason='scope_required' (호출부가 범위를 안 보낸
--                                    버그/누락 신호. "검사를 생략"이 아니라 "거부"다 —
--                                    이유는 파일 하단 판단① 참고)
--     · 배열은 있는데 티켓의 campaign_id 가 그 안에 없음
--                                   → **아무것도 기록하지 않고** reason='out_of_scope'
--                                    + 이름·타임·**다른 행사의 캠페인 제목**을 함께
--                                    돌려준다(판단③ 참고). ⚠️ other_day 와 달리
--                                    **되묻는 인자가 없다** — 확인해도 넘어갈 방법이
--                                    없는 하드 차단이다(판단④ 참고, 이 프로젝트의
--                                    "막는다"·"묻는다" 구분).
--   그 외 로직(관리자 가드·취소/대기 차단·다른 날 되묻기·첫 입장 시각 보존·중복
--   감지)은 287 그대로.
--
-- ⚠️ 인자가 늘어 시그니처가 바뀐다. 옛 2인자 정의를 **먼저 DROP** 한다 — 남기면
--    같은 이름의 함수가 둘이 되어(오버로드) 세 번째 인자를 안 보낸 호출이 옛
--    2인자 함수로 새어 나가 이번 검사가 통째로 무력화된다. CREATE OR REPLACE 로
--    인자를 "추가"하는 것은 진짜 교체가 아니라 새 오버로드를 만드는 것이다
--    (284 가 reserve_event_ticket 에서, 287 이 check_in_ticket 자신에게서 이미
--    같은 함정을 문서화했다 — 이번에도 동일).
--
-- ⚠️ 재정의 베이스는 **287**(현재 유효한 유일한 정의, 283 아님). 287 의
--    "다른 날이면 되묻는다" 로직은 한 글자도 건드리지 않고, 그 앞에 범위 검사
--    한 단계만 끼워 넣는다.
--
-- 호출부 2곳이 함께 바뀌어야 한다(이 마이그레이션은 서버만 — 화면은 별도 작업):
--   · dev/event-scan.html   — 현장 확인 화면. _scopeCampaignIds 를 그대로 넘긴다.
--   · dev/lib/storage.js    — checkInTicket() 래퍼 → dev/js/admin-event.js 의
--     「입장 처리」(_eventPaneCampId 를 배열로 감싸 넘긴다).
--   파일 하단 "화면에서 호출하는 법" 참고.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.check_in_ticket(text, boolean);

CREATE OR REPLACE FUNCTION public.check_in_ticket(
  p_ticket_code         text,
  p_confirm_other_day   boolean DEFAULT false,
  p_scope_campaign_ids  uuid[]  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_ticket      public.event_tickets%ROWTYPE;
  v_slot        public.event_slots%ROWTYPE;
  v_inf         public.influencers%ROWTYPE;
  v_code        text;
  v_admin_name  text;
  v_already     boolean;
  v_first_at    timestamptz;
  v_today_jst   date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_slot_json   jsonb;
  v_camp_title  text;
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

  -- ── [304] 보는 범위 검사 — 다른 무엇보다 먼저 ─────────────────────
  -- 이 화면(또는 관리자 패널의 이 캠페인)이 담당하지 않는 티켓이면, 그 티켓의
  -- 상태(취소·대기·날짜)가 무엇이든 **여기서는 아무 판단도 하지 않는다**.
  -- 판단④: 범위 밖이면서 날짜도 다른 경우 "다른 날"부터 말하면 운영진이
  --   "같은 행사인데 날짜만 다르네" 로 오해하고 되묻기(confirm_other_day)로
  --   그냥 통과시킬 수 있다 — 실제로 이번 사고가 그 모양이었다(화면이 오늘이
  --   아니라고만 안내하고 입장 버튼을 내줬다). 범위 검사를 가장 먼저 두면
  --   그 오해가 애초에 발생하지 않는다.
  --
  -- 판단①: p_scope_campaign_ids 가 NULL(또는 빈 배열)이면 "검사 생략"이 아니라
  --   "거부"다(fail-closed). 이 함수를 부르는 곳은 현재 둘뿐이고(현장 확인 화면·
  --   관리자 예약 현황) 둘 다 항상 범위를 알고 있다(전자는 _scopeCampaignIds,
  --   후자는 _eventPaneCampId). "범위를 안 보냄"은 정상 케이스가 아니라 호출부
  --   버그거나 코드가 이 마이그레이션보다 먼저 배포된 과도기다 — 두 경우 모두
  --   "일단 통과"보다 "일단 거부"가 안전하다. 통과시키면 오늘 실측된 사고가
  --   그대로 재현된다(그게 애초에 이 마이그레이션을 쓰는 이유다).
  IF p_scope_campaign_ids IS NULL OR array_length(p_scope_campaign_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'scope_required');
  END IF;

  IF NOT (v_ticket.campaign_id = ANY (p_scope_campaign_ids)) THEN
    SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id;
    SELECT * INTO v_inf  FROM public.influencers WHERE id = v_ticket.influencer_id;
    SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

    -- 판단③: 다른 행사의 캠페인 제목·예약자 이름을 돌려주는 것 —
    --   호출자는 반드시 is_admin() 이고, 이 프로젝트의 event_tickets 조회 권한은
    --   애초에 "관리자 전체"이지 "그 캠페인 담당 관리자"로 더 좁혀져 있지 않다
    --   (282 헤더 — RLS 는 본인 또는 is_admin() 만 있고 역할별 세분화가 없다).
    --   즉 어떤 관리자든 관리자 예약 현황 화면에서 다른 캠페인으로 그냥 이동해도
    --   같은 이름·같은 캠페인 제목을 볼 수 있다 — 이 응답이 새로운 노출 범위를
    --   여는 것이 아니라 기존 권한 경계를 그대로 따르는 것이다. 대신 운영진이
    --   "이건 다른 행사 예약이에요" 라고 실제로 안내할 수 있어야 하므로 이름·
    --   시간대·행사명은 함께 준다(other_day 응답과 정보 수준을 맞춘다).
    RETURN jsonb_build_object(
      'ok',            false,
      'reason',        'out_of_scope',
      'ticket_id',      v_ticket.id,
      'ticket_code',    v_ticket.ticket_code,
      'name_kanji',     v_inf.name_kanji,
      'name_kana',      v_inf.name_kana,
      'campaign_title', v_camp_title,
      'slot', jsonb_build_object(
        'slot_date',      v_slot.slot_date,
        'start_time',     v_slot.start_time,
        'end_time',       v_slot.end_time,
        'audience_label', v_slot.audience_label
      )
    );
  END IF;
  -- ── [304] 범위 검사 끝 — 여기서부터는 287 원문과 동일 ─────────────

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

COMMENT ON FUNCTION public.check_in_ticket(text, boolean, uuid[]) IS
  '[283+287+304] 예약번호로 입장 확인. 첫 입장 시각은 재확인해도 덮어쓰지 않고 확인 횟수만 올린다. '
  '[287] 예약 날짜가 오늘이 아니면 아무것도 기록하지 않고 reason=other_day 로 되돌려보낸다(운영진이 '
  '확인하면 p_confirm_other_day=true 로 다시 부르면 기록). '
  '[304] p_scope_campaign_ids 로 "이 화면이 담당하는 캠페인 목록"을 반드시 넘겨야 한다 — NULL/빈 배열은 '
  'reason=scope_required 로 거부(fail-closed). 티켓의 campaign_id 가 그 목록에 없으면 reason=out_of_scope '
  '로 거부하며, 이 쪽은 p_confirm_other_day 로도 우회할 수 없다(하드 차단, other_day 는 되묻고 넘어갈 수 있는 것과 다름).';

REVOKE ALL ON FUNCTION public.check_in_ticket(text, boolean, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_in_ticket(text, boolean, uuid[]) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 화면에서 호출하는 법 (서버는 이 마이그레이션까지, 아래는 화면 쪽 참고)
-- ============================================================
-- dev/event-scan.html 의 checkIn(code, confirmOtherDay):
--   sb.rpc('check_in_ticket', {
--     p_ticket_code: code,
--     p_confirm_other_day: !!confirmOtherDay,
--     p_scope_campaign_ids: _scopeCampaignIds   -- 이미 있는 전역 변수를 그대로
--   });
--
-- dev/lib/storage.js 의 checkInTicket(ticketCode, confirmOtherDay, scopeCampaignIds):
--   세 번째 인자를 새로 받아 p_scope_campaign_ids 로 그대로 넘긴다.
--   dev/js/admin-event.js 의 checkInFromAdmin() 호출부는
--     checkInTicket(ticketCode, confirmOtherDay, [_eventPaneCampId])
--   처럼 "지금 보고 있는 캠페인 하나짜리 배열"을 넘긴다(그 화면은 이미 한
--   캠페인으로 좁혀져 있으므로 범위가 곧 그 캠페인 하나다).
--
-- 새 reason 2종 처리:
--   · 'scope_required' — 정상 흐름에서는 나오면 안 된다(호출부가 범위를 안 보낸
--     버그 신호). 일반 실패 문구(failGeneric 등)로 처리해도 되지만, 나오면
--     로그를 남겨 원인(배포 순서 과도기인지, 코드 누락인지)을 확인할 것.
--   · 'out_of_scope' — "이 예약은 다른 행사 것입니다(campaign_title)" 같은 안내.
--     other_day 와 달리 **확인 버튼(다시 부르기)을 두지 않는다** — 이 사유는
--     p_confirm_other_day 를 true 로 다시 불러도 통과하지 않는다(범위 자체가
--     바뀌지 않는 한 항상 거부).
--
-- ============================================================
-- 검증
-- ============================================================
-- 1) 같은 이름의 함수가 하나만 남았는지(오버로드가 안 생겼는지)
-- SELECT p.oid::regprocedure FROM pg_proc p
--  WHERE p.pronamespace='public'::regnamespace AND p.proname='check_in_ticket';
--   → 3인자 정의 1건만. 2건 이상이면 DROP 이 실패한 것이므로 즉시 보고.
--
-- 2) SQL 편집기(서비스 키, auth.uid() NULL)는 관리자 가드에서 막힌다 — 형식만 확인:
-- SELECT public.check_in_ticket('ZZZZZZZZ', false, ARRAY['00000000-0000-0000-0000-000000000000']::uuid[]);
--   → {"ok": false, "reason": "permission_denied"}
--
-- 3) 관리자 브라우저 세션(화면 배포 후)에서:
--    · 범위 안 캠페인의 오늘 예약 번호        → {ok:true}
--    · 범위 안 캠페인의 다른 날 예약 번호      → {ok:false, reason:'other_day'}, entered_at 은 NULL 유지
--    · **범위 밖** 캠페인의 확정 예약 번호     → {ok:false, reason:'out_of_scope'}, entered_at 은 NULL 유지
--      (이번 마이그레이션이 막으려는 사고 재현 — 반드시 이 케이스를 확인할 것)
--    · 화면이 아직 세 번째 인자를 안 보내는 과도기(예 배포 순서 확인용)
--                                              → {ok:false, reason:'scope_required'}
--
-- 4) 관리자 예약 현황의 「입장 처리」(화면 갱신 후) — 같은 캠페인 안의 정상 케이스가
--    scope_required 로 막히지 않는지 확인(범위를 [해당 캠페인 id] 로 보내는지 점검).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.check_in_ticket(text, boolean, uuid[]);
-- -- 이어서 287 의 check_in_ticket(text, boolean) 블록을 재실행
-- COMMIT;
