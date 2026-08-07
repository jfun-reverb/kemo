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
