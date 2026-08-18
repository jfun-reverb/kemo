-- ============================================================
-- 330_reserve_event_ticket_group_uniqueness.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 같은 행사 묶음 안에서는 1회만 예약
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 선행: 282(예약 표 · 캠페인 단위 유일 인덱스) · 283/284/288/316(예약 함수 이력) ·
--       291/292(행사 묶음 표·정규화) · 317(대기 승격)
--
-- ── 결정 배경 (사용자 결정 2026-08-10) ────────────────────────────
--   지금까지는 「캠페인 하나당 1건」만 막혀 있었다(282 의 부분 유일 인덱스
--   event_tickets_camp_influencer_active_uidx, 316 의 already_applied 검사
--   모두 t.campaign_id = v_camp.id 하나만 본다). 그런데 8/28~30 팝업은
--   캠페인이 2개(8/28 초대 전용 · 8/29~30 일반 공개)이고, 이 둘을 행사 묶음
--   (event_groups, 291/292)으로 묶어 두었다 — 현장 확인 화면이 캠페인
--   하나에 고정되면 둘째 날 아침에 명단이 비어 보이기 때문이다(291 헤더 참고).
--   묶음은 만들었지만 **예약 검사는 묶음을 보지 않는다** — 한 사람이 8/28에
--   한 번, 8/29에 또 한 번 예약할 수 있다. 정원이 한정된 팝업에서 한 사람이
--   두 자리를 잡으면 다른 사람이 못 온다. → 「한 사람은 행사 묶음 전체에서
--   1회만 예약할 수 있다」로 넓힌다.
--
-- ── 재정의 기준 (전수 확인) ────────────────────────────────────────
--   reserve_event_ticket 정의·재정의 이력: 283(최초 생성) → 284(주의사항
--   동의 인자 추가) → 288(bypass 표시 추가) → 316(캠페인 상태·타임 날짜
--   검사 추가, 현재 유효한 원본). 289·304·314·317 은 이 함수를 언급만 하고
--   재정의하지 않는다(316 파일 헤더가 이미 같은 확인을 해 두었고, 그 뒤로
--   새 재정의가 없음을 다시 확인했다 — grep 결과 4곳뿐).
--   이 파일은 316 의 함수 본문을 베이스로 삼아 「한 캠페인에 1타임」 검사
--   블록 하나만 넓힌다. 그 외 로직은 316 과 완전히 동일, 한 글자도 안 바꿨다.
--   시그니처(uuid, text, timestamptz, jsonb) 불변 — DROP 불필요.
--
-- ── 무엇을 넓히나 (핵심 변경 — 검사 1개만) ─────────────────────────
--   316 의 검사:
--     t.campaign_id = v_camp.id AND t.influencer_id = v_uid
--       AND t.status <> 'cancelled'  → 있으면 already_applied
--   이 파일의 검사:
--     (t.campaign_id = v_camp.id
--      OR (v_camp.event_group_id IS NOT NULL
--          AND c2.event_group_id = v_camp.event_group_id))
--     AND t.influencer_id = v_uid AND t.status <> 'cancelled'
--       → 있으면 already_applied (사유 코드 그대로 재사용 — 아래 참고)
--
--   ⚠️ 행사 묶음이 없는 캠페인(event_group_id IS NULL)은 뒤 조건이
--   `NULL IS NOT NULL` 로 항상 거짓이 되어, 앞 조건(t.campaign_id = v_camp.id)
--   하나만 남는다 — 316 과 완전히 같은 결과다. **묶음 없는 단일 행사는
--   이 변경으로 전혀 달라지지 않는다**(요청사항 확인 — 화면·검증 절차 c에서
--   실측 확인).
--
-- ── 사유 코드는 새로 만들지 않는다 (재사용 여부 판단) ───────────────
--   already_applied 를 그대로 쓴다. 화면 문구(dev/lib/i18n/ja.js
--   failAlreadyApplied: 「すでにこのイベントを予約しています。予約は1回
--   だけです」/ ko.js: 「이미 이 행사를 예약했습니다」)가 이미 **캠페인이
--   아니라 행사(イベント) 단위**로 쓰여 있어, 묶음 전체로 넓혀도 문구가
--   어긋나지 않는다 — 확인 완료(dev/js/application.js:618 eventReserveFailMessage,
--   dev/lib/i18n/{ja,ko}.js). **이 파일은 화면 코드·i18n 파일을 전혀 건드리지
--   않는다.**
--
-- ── 대기자 승격은 영향받지 않는다 (요청사항 확인) ───────────────────
--   대기 승격(_promote_next_event_waitlist, 288)·정원 승격
--   (promote_event_waitlist, 317)·본인 취소(cancel_event_ticket, 288)·
--   관리자 취소(cancel_event_ticket_admin, 288)는 전부 **이미 있는 티켓의
--   status 를 UPDATE** 할 뿐 새 티켓을 INSERT 하지 않는다(282 이후 표
--   자체가 INSERT/UPDATE/DELETE 직접 정책 없이 SECURITY DEFINER 함수로만
--   쓰이고, 새 행을 만드는 함수는 reserve_event_ticket 하나뿐 — grep 으로
--   전수 확인). 이 파일이 건드리는 검사는 reserve_event_ticket 의 **새
--   예약(INSERT) 진입 시점**에만 도니, 승격·취소는 전혀 영향받지 않는다.
--
-- ── 취소 후 재예약은 막히지 않는다 (요청사항 확인) ───────────────────
--   넓힌 검사도 `t.status <> 'cancelled'` 조건을 그대로 유지한다. 같은
--   묶음의 다른 캠페인 티켓이 cancelled 면 이 조건에 안 걸린다 — 취소한
--   사람은 같은 묶음 안 다른 캠페인이든 같은 캠페인이든 다시 예약할 수 있다
--   (282 헤더의 「취소해도 신청 행을 지우지 않고 되살린다」 설계와 정합).
--
-- ── 데이터베이스 제약(유일 인덱스)으로도 막을 수 있는가 — 검토 결과: 안 건다 ──
--   요청사항이 「가능한 방법(트리거 등)과 그 비용을 따져 판단하라」고 했으므로
--   검토한 내용과 판단 근거를 남긴다.
--
--   검토한 방법: event_tickets 에 event_group_id 를 새로 얹고(campaigns 의
--   값을 복사), (event_group_id, influencer_id) 부분 유일 인덱스를 건다
--   (282 의 campaign_id 유일 인덱스와 같은 모양). 캠페인 표 자체에는 유일
--   인덱스를 걸 수 없다 — 유일성은 event_tickets 행 사이에서 봐야 하는데
--   campaigns.event_group_id 는 다른 표에 있어 인덱스 표현식이 참조할 수
--   없다(부분 인덱스 조건은 그 행 자기 자신의 칸만 볼 수 있다).
--
--   이 방법을 걸지 않기로 한 이유 — 두 가지:
--
--   ① campaigns.event_group_id 는 살아있는 값이라 "복사해 두는 값"이 바로
--      낡는다. 캠페인 편집 폼(dev/admin/index.html #editCampEventGroup)이
--      이미 배포돼 있고, 관리자가 캠페인을 저장할 때마다
--      event_group_id 가 **매번 그 값 그대로 다시 보내진다**(dev/js/admin.js:2445
--      — 행사 모드 체크박스가 켜져 있으면 선택값, 꺼져 있으면 null. 껐다 켰다
--      해도 값이 사라지지 않게 일부러 매번 채운다). 즉 이 칸은 캠페인을 한 번
--      저장할 때마다 계속 바뀔 수 있는 값이다. 복사본을 만들면 그 복사본을
--      항상 최신으로 맞춰 주는 장치(캠페인이 UPDATE 될 때마다 관련 티켓 행을
--      다시 훑어 고쳐 쓰는 트리거)가 또 필요하다.
--
--   ② 그 장치를 만들면, **행사가 아닌 캠페인을 포함한 모든 캠페인의 저장**에
--      걸리는 자리(캠페인 표의 UPDATE 트리거)에 새 로직이 하나 더 붙는다.
--      이 예약 기능 자체가 잘못돼도 영향 범위는 「행사 예약」에 그치지만,
--      캠페인 저장 경로에 붙는 트리거가 잘못되면 **행사와 무관한 모든 캠페인
--      편집·저장**이 함께 흔들릴 수 있다 — 행사 예약 하나를 더 안전하게
--      하려다 훨씬 넓은 범위(전체 캠페인 관리)를 더 위험하게 만드는
--      맞바꿈이다. 8/28~30 행사가 임박한 지금, 캠페인 저장이라는 관리자의
--      가장 기본적인 작업 경로를 건드리는 위험을 새로 지는 것은 무리라고
--      판단했다.
--
--   대신 이렇게 안전을 확보한다 — event_tickets 표는 282 부터 **직접 쓰기
--   정책이 없다**(INSERT/UPDATE/DELETE 를 authenticated·anon 어느 쪽에도
--   허용하지 않는다, 282 파일 "RLS" 절 참고). 이 표에 새 행을 만드는 함수는
--   이 파일이 고치는 reserve_event_ticket 하나뿐이다(grep 전수 확인 — 위
--   "대기자 승격은 영향받지 않는다" 절 참고). 즉 지금 이 프로젝트 구조에서
--   event_tickets 에 새 행이 생기는 문은 하나뿐이고, 그 문에 검사를 세워
--   두면 사실상 표 전체에 건 것과 같은 효과를 낸다.
--
--   ⚠️ 남는 구멍(정직하게 밝힘): 이 함수는 예약하려는 **그 타임(슬롯) 행만**
--   FOR UPDATE 로 잠근다. 같은 사람이 같은 묶음의 **서로 다른 캠페인**(따라서
--   서로 다른 타임 행)에 정확히 동시에(수백 밀리초 이내) 예약을 두 번 넣으면,
--   두 트랜잭션이 서로 다른 행을 잠그고 있어 이 EXISTS 검사를 둘 다 통과한
--   뒤 각자 성공할 이론적 여지가 있다(고전적인 확인-후-삽입 경쟁). 이건
--   유일 인덱스가 아니라 함수 안의 조회로만 막는 모든 검사가 공통으로 갖는
--   한계다. 실제로 일어나려면 한 사람이 서로 다른 두 캠페인 페이지를 열어
--   두고 정확히 동시에 두 번 누르는 상황이 필요해 확률은 낮고, 만에 하나
--   이렇게 두 건이 생겨도 아래 검증 절차의 조회로 찾아낼 수 있다(사람이
--   보고 판단할 몫으로 남긴다 — 자동 취소하지 않는다, 요청사항). 같은
--   캠페인 안에서의 경쟁은 기존 282 유일 인덱스가 여전히 최종 방어선이다
--   (이 파일이 손대지 않은 부분).
--
-- ── 기존 위반 데이터가 있어도 이 마이그레이션은 실패하지 않는다 ──────
--   유일 인덱스를 새로 걸지 않으므로(위 판단), 기존에 같은 묶음에서 이미
--   두 건 이상 예약한 사람이 있어도 이 파일 적용 자체는 막히지 않는다.
--   그런 사람이 있는지는 파일 하단 검증 [3]의 조회로 찾는다 — **자동으로
--   지우거나 취소하지 않는다**(요청사항). 있으면 사람이 보고 판단한다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

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

  -- [316] 지난 날짜의 타임은 막는다 — 화면 필터(dev/js/application.js:500~512
  --   loadEventSlotPicker)와 같은 기준. 일본 날짜 단위로만 자르고 시각은 안 본다
  --   (오늘 타임은 시각이 지나도 통과 — 2026-08-06 사용자 결정, 화면과 동일).
  --   관리자는 사전 점검·행사 당일 수기 정리 목적으로 예외(316 파일 헤더 「관리자
  --   예외」 참고 — 모집 마감 검사와 같은 예외 패턴).
  IF NOT v_is_admin AND v_slot.slot_date < v_today_jst THEN
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

  -- [316] 캠페인이 'active' 상태가 아니면 예약을 받지 않는다 — 화면의 신청 버튼
  --   활성 기준(dev/js/application.js:406~421)과 같은 기준. 관리자는 캠페인
  --   공개 전 사전 점검을 위해 예외(316 파일 헤더 참고).
  IF NOT v_is_admin AND v_camp.status <> 'active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
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

  -- ── [330] 한 캠페인에 1타임 + 같은 행사 묶음에 1건 ────────────
  --   행사 묶음(event_group_id)이 없으면 아래 OR 뒤 조건이 항상 거짓이 되어
  --   앞 조건(t.campaign_id = v_camp.id) 하나만 남는다 — 316 과 완전히 같다.
  --   묶음이 있으면 그 묶음에 속한 다른 캠페인의 유효한 예약도 함께 본다
  --   (사용자 결정 2026-08-10 — 정원이 한정된 팝업에서 한 사람이 두 자리를
  --   잡으면 다른 사람이 못 온다). 관리자 예외를 두지 않는다 — 316 원문의
  --   already_applied 검사도 v_is_admin 을 보지 않았다(본인 확인 성격의
  --   검사라 정책 게이트[날짜·상태·마감·연령]와 다른 종류 — 이 파일이 그
  --   기존 성격을 그대로 이어받는다).
  IF EXISTS (
    SELECT 1
      FROM public.event_tickets t
      JOIN public.campaigns c2 ON c2.id = t.campaign_id
     WHERE t.influencer_id = v_uid
       AND t.status <> 'cancelled'
       AND (
         t.campaign_id = v_camp.id
         OR (v_camp.event_group_id IS NOT NULL
             AND c2.event_group_id = v_camp.event_group_id)
       )
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
  '[283+284+288+316+330] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 '
  '대기로 등록하고 짝이 되는 신청 행까지 같은 트랜잭션에서 만든다(또는 취소된 옛 신청 행을 '
  '되살린다). [288] 289 신청 상태 변경 차단 트리거를 위한 bypass 표시. [316] 지난 날짜의 '
  '타임과 ''active'' 상태가 아닌 캠페인의 예약을 막는다(둘 다 관리자 예외). [330] 「한 캠페인에 '
  '1타임」 검사를 「같은 행사 묶음(event_group_id)에 1건」으로 넓혔다 — 묶음이 없으면 종전과 '
  '동일. 실패는 예외가 아니라 {ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (1단계씩 — 결과 확인 후 다음 단계로. .claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ============================================================
--
-- [1단계] 함수가 여전히 1개뿐이고 시그니처가 안 바뀌었는지 (SQL 편집기, 서비스
--   키로 실행 가능 — 로그인 세션 불필요)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'reserve_event_ticket';
--   → reserve_event_ticket(uuid, text, timestamptz, jsonb) 1건만 나와야 한다
--     (오버로드 생기면 안 됨 — 나오면 즉시 중단하고 보고)
--
-- [2단계] 형식 확인 (SQL 편집기는 서비스 키라 auth.uid() 가 NULL — permission_denied
--   가 정상. 여기까지는 SQL 편집기로 가능)
-- SELECT public.reserve_event_ticket('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- [3단계] 기존에 같은 행사 묶음에서 이미 2건 이상 유효 예약을 가진 사람 찾기
--   (SQL 편집기, 서비스 키로 실행 가능 — 로그인 세션 불필요. 있어도 이 파일
--   적용을 막지 않는다 — 자동으로 지우거나 취소하지 않으니 사람이 보고
--   판단할 것)
--
--   3-1) 요약 — 누가·어느 묶음에서·몇 건인지
--   SELECT
--     t.influencer_id,
--     i.name  AS influencer_name,
--     i.email AS influencer_email,
--     eg.id   AS event_group_id,
--     eg.name AS event_group_name,
--     count(DISTINCT t.campaign_id)                       AS campaign_count,
--     array_agg(DISTINCT c.title ORDER BY c.title)         AS campaign_titles
--   FROM public.event_tickets t
--   JOIN public.campaigns c      ON c.id  = t.campaign_id
--   JOIN public.event_groups eg  ON eg.id = c.event_group_id
--   LEFT JOIN public.influencers i ON i.id = t.influencer_id
--   WHERE t.status <> 'cancelled'
--   GROUP BY t.influencer_id, i.name, i.email, eg.id, eg.name
--   HAVING count(DISTINCT t.campaign_id) > 1
--   ORDER BY campaign_count DESC;
--     → 0행이면 위반자 없음(8/28~30 행사는 아직 캠페인·예약이 없어 현재는
--       0행이 나올 것으로 예상됨 — CLAUDE.md 「오프라인 팝업 방문 예약」 항목
--       "운영 데이터는 아직 0건" 참고). 1행 이상 나오면 3-2 로 상세 확인.
--
--   3-2) 상세 — 위에서 나온 influencer_id 하나마다 실제 티켓 목록
--   SELECT
--     t.id, t.ticket_code, t.status, t.created_at,
--     c.title AS campaign_title, s.slot_date, s.start_time, s.end_time
--   FROM public.event_tickets t
--   JOIN public.campaigns c   ON c.id = t.campaign_id
--   JOIN public.event_slots s ON s.id = t.slot_id
--   WHERE t.status <> 'cancelled'
--     AND t.influencer_id = '<3-1에서 나온 influencer_id>'
--   ORDER BY s.slot_date, s.start_time;
--
-- [4단계] ⚠️ 이 함수는 본인 계정 가드(auth.uid() 필요) 때문에 SQL 편집기로는
--   묶음 차단 동작 자체를 검증할 수 없다. 반드시 실제 로그인 세션(테스트
--   인플루언서 계정 + 개발서버 브라우저)으로 확인한다:
--
--   준비: 행사 모드 캠페인 2개(A·B)를 만들고 같은 행사 묶음으로 연결한다
--     (관리자 캠페인 편집 폼의 「행사 묶음」 드롭다운). 둘 다 상태 active,
--     각각 타임을 1개 이상 만든다.
--
--   a. 묶음 차단 확인
--      테스트 인플루언서 계정으로 로그인해 캠페인 A 에서 정상 예약(성공
--      해야 함). 그다음 같은 계정으로 캠페인 B 상세를 열고 브라우저
--      콘솔에서 직접 호출:
--        `await window.db.rpc('reserve_event_ticket', {p_slot_id:'<B의 타임id>'})`
--      → `{ok:false, reason:'already_applied'}` 이어야 한다. 화면에서
--      캠페인 B 예약 버튼을 눌러도 같은 결과 + 「すでにこのイベントを予約
--      しています」 토스트가 뜨는지 확인.
--
--   b. 묶음 없는 캠페인은 무영향 확인 (회귀)
--      행사 묶음에 연결하지 않은 별도 행사 캠페인 C·D(둘 다 event_group_id
--      NULL)를 만들고, 같은 테스트 계정으로 C 예약 후 D 도 예약 시도 →
--      **성공해야 한다**(묶음이 없으면 캠페인 단위 검사만 적용 — 316 과
--      동일 동작). 실패하면 이 파일에 회귀가 있는 것이므로 즉시 중단하고
--      보고.
--
--   c. 취소 후 재예약 확인
--      a 에서 캠페인 A 예약을 취소(cancel_event_ticket)한 뒤, 같은 계정으로
--      캠페인 B 예약을 다시 시도 → 이제는 **성공해야 한다**(취소된 티켓은
--      already_applied 검사에서 제외).
--
--   d. 대기 승격 무영향 확인
--      캠페인 A 의 어느 타임을 정원 1로 만들고 테스트 계정 2개(갑·을)로
--      확정 1 · 대기 1 을 만든 뒤, 갑이 취소 → 을이 자동으로 확정 승격되는지
--      확인(288/317 로직 무변경이므로 정상 승격돼야 한다 — 이 파일이 그
--      경로를 건드리지 않았음을 재확인하는 회귀 테스트).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- -- 316 정의로 되돌린다 — 316_reserve_event_ticket_status_and_date_guard.sql 의
-- -- CREATE OR REPLACE FUNCTION public.reserve_event_ticket(...) 블록을 그대로
-- -- 재실행하면 된다(시그니처 동일이라 DROP 불필요).
-- COMMIT;
-- ============================================================
