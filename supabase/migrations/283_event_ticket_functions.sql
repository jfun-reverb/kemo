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
-- COMMIT;
