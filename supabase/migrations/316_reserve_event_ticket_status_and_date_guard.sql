-- ============================================================
-- 316_reserve_event_ticket_status_and_date_guard.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 캠페인 상태·타임 날짜 서버 검증 추가
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §2-4
-- 선행: 282~289(오프라인 예약 기본 골격) · 304(check_in_ticket 범위 가드)
-- 재정의 기준: public.reserve_event_ticket 정의/재정의 이력 전수 확인 —
--   283(최초 생성) → 284(주의사항 동의 추가, 시그니처 변경) → 288(bypass 표시
--   추가, 최신) 까지가 전부이고 289·304·314 는 이 함수를 **언급만** 하고
--   재정의하지 않는다(grep 확인 완료). 이 파일은 288 의 함수 본문을
--   한 글자도 바꾸지 않고 그대로 베이스로 삼아 새 검사 2개만 끼워 넣는다.
--
-- ── 왜 필요한가 (감사 §2-4) ──────────────────────────────────────
--   이 함수는 지금까지 캠페인 상태도, 타임 날짜도 보지 않는다. campaigns 표는
--   완전 공개 조회이고 event_slots 표는 로그인한 사람 전체가 조회할 수 있어
--   (281 헤더 참고), **캠페인을 미리 만들어 등록해 두는 순간부터** 아직 아무에게도
--   공개하지 않은 행사에 예약이 들어갈 수 있다. 화면 코드 자체가 이 사실을
--   인정하고 있다 — dev/js/application.js:502 주석: 「서버는 지난 타임을 막지
--   않는다 — 2026-08-06 테스트에서 실제로 성립했다」.
--   8/28~30 행사 캠페인을 곧 등록할 예정이라 그 **전에** 막아야 한다.
--
-- ── 화면 기준과 맞춘 두 가지 새 검사 ──────────────────────────────
--
--   ① 타임 날짜가 지나지 않았어야 한다 (일본 날짜 단위)
--      화면 필터(dev/js/application.js:500~512 loadEventSlotPicker)와 정확히
--      같은 기준을 서버에 그대로 옮긴다:
--        - 기준은 **일본 날짜**(이 함수가 이미 갖고 있는 v_today_jst, 함수 진입
--          시점에 `(now() AT TIME ZONE 'Asia/Tokyo')::date` 로 계산됨 — 현장
--          확인 화면(event-scan.html)·jstTodayStr() 과 동일 기준)
--        - **날짜만 비교하고 시각은 안 본다.** 오늘 타임은 예약 시각이 지났어도
--          막지 않는다 — 14시 타임을 14시 10분에 현장에서 받아 주는 경우가
--          있어 화면이 의도적으로 날짜 단위로만 자른다(2026-08-06 사용자 결정).
--          더 엄격하게(시각까지) 막으면 화면은 통과시키는데 서버가 막는
--          역전이 생긴다 — 요청사항 「더 엄격하면 정상 예약이 막힌다」에 해당.
--
--   ② 캠페인 상태가 'active' 여야 한다
--      화면의 신청 버튼 활성 기준을 그대로 옮긴다. 인플루언서 화면이 캠페인을
--      노출하는 상태는 4개(active/scheduled/closed/ended, dev/js/campaign.js:41)
--      이지만, 그 안에서 신청(예약) 버튼이 **눌리는** 상태는 하나뿐이다 —
--      dev/js/application.js:406~421 floatApplyBtn 분기를 그대로 옮기면:
--        draft/expired  → 버튼 자체가 비노출 상태(비공개 캠페인, 링크로 들어와도 차단)
--        scheduled      → 「募集開始前」 비활성
--        closed         → 「募集締切」 비활성 (마감일 경과 또는 관리자가 마감일 전에
--                          수동으로 '모집마감'으로 바꾼 경우 — CLAUDE.md 「상태 변경
--                          드롭다운 전이 규칙」. 마감일 미경과 상태에서도 발생하므로
--                          **날짜 검사(v_camp.deadline)만으로는 못 잡는다** — 이번
--                          문제의 핵심)
--        ended          → 「終了」 비활성
--        active         → 유일하게 눌리는 상태
--      즉 화면이 실제로 예약을 받는 캠페인 상태는 'active' 하나뿐이다. 서버도
--      그 기준 하나만 본다. 화면 노출 규칙(4개 상태)보다 좁게 잡는 것이지만
--      **화면이 그 4개 중 3개에서 이미 버튼을 비활성으로 막고 있으므로 어긋나지
--      않는다** — 화면이 여는데 서버가 닫는 경우가 없다(요청사항 확인 완료).
--
-- ── 관리자 예외 (요청사항 — 판단과 근거) ──────────────────────────
--   **둔다.** 이 함수는 이미 관리자 예외 패턴이 있다 — 모집 마감 검사
--   (`IF NOT v_is_admin AND v_camp.deadline...`)와 만 18세 검사가 둘 다
--   `v_is_admin` 이면 건너뛴다. 새 검사 2개도 같은 이유로 같은 예외를 둔다 —
--   운영자가 캠페인을 공개하기 **전에** 미리 예약 흐름을 시험해 볼 수 있어야
--   하고(8/28 행사처럼 시한이 촉박한 신규 캠페인일수록 사전 점검이 중요하다),
--   행사 당일 지난 타임에 대한 정리·수기 등록이 필요할 수도 있다(288 파일
--   헤더의 관리자 취소 함수와 같은 취지 — "지금 당장 정리할 수단이 없다"가
--   반복되지 않게). 관리자 전용 화면(admin-event.js)은 애초에 이 두 조건을
--   신경 쓰지 않고 운영 목적으로 동작해야 하므로 예외가 자연스럽다.
--
-- ── 사유 코드 (요청사항 — 재사용 여부 판단) ────────────────────────
--   **기존 코드를 재사용한다. 새 코드를 만들지 않는다 — 화면(dev/js/
--   application.js:614~628 eventReserveFailMessage) 수정이 필요 없다.**
--
--     ① 타임 날짜 지남           → 'slot_closed'
--        이미 이 함수가 같은 이유(타임 자체가 닫힘 — is_active=false)로 쓰고
--        있는 코드다. 화면 문구 「この日時は受付をしめきりました。ほかの
--        日時をえらんでください」(이 날짜는 접수가 끝났습니다. 다른 날짜를
--        선택해 주세요)가 그대로 들어맞는다 — 여러 날 행사면 실제로 다른
--        날짜가 있다.
--
--     ② 캠페인 상태 'active' 아님 → 'not_found'
--        이미 이 함수가 「캠페인이 event_mode 아니거나 없음」에 쓰는 코드다.
--        화면 문구 「この日時が見つかりませんでした。画面を更新してもう
--        一度おためしください」(이 날짜를 찾지 못했습니다. 화면을 새로
--        고치고 다시 시도해 주세요)를 그대로 쓴다. 'slot_closed' 대신
--        이걸 고른 이유: 'slot_closed' 문구는 "다른 날짜를 골라라"인데,
--        캠페인이 아직 공개 전(draft/scheduled)이면 고를 다른 날짜 자체가
--        없다 — 잘못된 안내가 된다. 'not_found' + 새로고침 안내가 "지금은
--        예약할 수 없는 상태"라는 사실을 더 정확히 전달한다. 이 경로는
--        정상적으로는 화면 버튼이 이미 막아 도달하지 않는 최종 방어선이므로
--        완벽한 문구보다 "틀린 인상을 안 주는" 쪽을 우선했다.
--
--   두 조건 다 새 i18n 키·클라이언트 코드 변경이 필요 없다(사양서·계획서
--   요청 「화면 코드 수정이 필요하면 무엇을 어떻게 바꿀지 알려만 달라」에
--   대한 답 — **이번 건은 화면 수정 불필요**).
--
-- ── 검사 위치 (요청사항 — 화면과 같은 우선순위) ────────────────────
--   ① 타임 날짜 검사는 타임 자체의 유효성(is_active) 검사 바로 뒤에 둔다
--      — 타임 레벨 검사끼리 모은다.
--   ② 캠페인 상태 검사는 소프트 삭제(deleted_at) 검사 바로 뒤, 초대 전용
--      재검증보다 앞에 둔다 — 캠페인 존재·상태 검사끼리 모으고, 그 캠페인이
--      "예약 가능한 상태"인지를 확정한 다음에 초대 코드·마감일·연령 같은
--      세부 조건을 본다.
--   둘 다 관리자 예외를 적용하는 기존 검사(모집 마감·연령)와 같은 코드
--   스타일(`IF NOT v_is_admin AND ...`)로 작성해 리뷰 시 눈에 띄게 한다.
--
-- ── 이 파일이 바꾸지 않는 것 ────────────────────────────────────
--   함수 시그니처(uuid, text, timestamptz, jsonb) 불변 — DROP 불필요.
--   위 두 검사 외 나머지 로직(초대 전용·마감일·연령·정원·신청 행 확보·
--   티켓 발급·bypass 표시)은 288 원문과 완전히 동일, 한 글자도 안 바꿨다.
--   cancel_event_ticket · cancel_event_ticket_admin 등 다른 함수는 무변경
--   (취소는 이미 만들어진 예약을 정리하는 경로라 이번 문제와 무관).
--
-- ── 실패 반환 방식 ──────────────────────────────────────────────
--   283·284·287·288 과 같은 방식 — 예외가 아니라 {ok:false, reason:...}.
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
  --   관리자는 사전 점검·행사 당일 수기 정리 목적으로 예외(파일 헤더 「관리자
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
  --   활성 기준(dev/js/application.js:406~421)과 같은 기준. 인플루언서 화면에
  --   노출되는 상태는 4개(active/scheduled/closed/ended)지만 버튼이 눌리는 건
  --   'active' 뿐이다 — draft·scheduled·closed·ended·expired 전부 화면에서
  --   이미 버튼이 비활성이라 어긋나지 않는다(파일 헤더 참고). 'closed' 는
  --   마감일이 지나지 않아도 관리자가 상태 드롭다운으로 수동 전환할 수 있어
  --   아래 마감일 검사만으로는 못 잡는다 — 이 검사가 그 구멍을 막는다.
  --   관리자는 캠페인 공개 전 사전 점검을 위해 예외(파일 헤더 참고).
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
  '[283+284+288+316] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 대기로 '
  '등록하고 짝이 되는 신청 행까지 같은 트랜잭션에서 만든다(또는 취소된 옛 신청 행을 되살린다). '
  '[288] 289 신청 상태 변경 차단 트리거를 위한 bypass 표시. '
  '[316] 지난 날짜의 타임(slot_date < 오늘 일본 날짜)과 ''active'' 상태가 아닌 캠페인의 예약을 '
  '막는다(둘 다 관리자 예외). 실패는 예외가 아니라 {ok:false, reason:...}.';

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
--   키로 실행 가능 — 이 단계는 로그인 세션이 필요 없다)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'reserve_event_ticket';
--   → reserve_event_ticket(uuid, text, timestamptz, jsonb) 1건만 나와야 한다
--     (오버로드 생기면 안 됨 — 나오면 즉시 중단하고 보고)
--
-- [2단계] 형식 확인 (SQL 편집기는 서비스 키라 auth.uid() 가 NULL — permission_denied
--   가 정상. 이 단계까지는 SQL 편집기로 가능)
-- SELECT public.reserve_event_ticket('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- [3단계] ⚠️ 이 함수는 본인 계정 가드(auth.uid() 필요) 때문에 SQL 편집기로는
--   실제 동작을 검증할 수 없다. 여기서부터는 반드시 **실제 로그인 세션**
--   (테스트 인플루언서 계정 + 개발서버 브라우저)으로 확인한다:
--
--   a. 지난 날짜 차단 확인
--      - 개발서버에 이미 있는(또는 새로 만든) 행사 캠페인의 타임 중 하나를
--        골라 SQL 편집기(이건 서비스 키라 UPDATE 는 가능)로
--        `UPDATE public.event_slots SET slot_date = (now() AT TIME ZONE
--        'Asia/Tokyo')::date - 1 WHERE id = '<타임id>';` 로 하루 전 날짜로
--        임시 변경(검증 끝나면 원래 날짜로 되돌릴 것)
--      - 테스트 인플루언서 계정으로 로그인해 그 캠페인 상세 페이지를 열고,
--        화면에는 그 날짜 탭이 아예 안 보여야 한다(loadEventSlotPicker 가
--        이미 걸러내므로 — 이건 화면 쪽 회귀가 없는지 확인용)
--      - 브라우저 개발자 도구 콘솔에서 직접 호출해 서버 응답을 본다:
--        `await window.db.rpc('reserve_event_ticket', {p_slot_id:'<그 타임id>'})`
--        → `{ok:false, reason:'slot_closed'}` 이어야 한다
--      - 확인 후 `UPDATE public.event_slots SET slot_date = '<원래 날짜>'
--        WHERE id = '<타임id>';` 로 반드시 되돌린다
--
--   b. 캠페인 상태 차단 확인
--      - 테스트용 행사 캠페인 하나를 관리자 화면에서 상태 드롭다운으로
--        'scheduled' 또는 'closed' 로 바꾼다(마감일은 미래로 둔 채 — 마감일
--        검사가 아니라 상태 검사가 걸리는지 보기 위함)
--      - 테스트 인플루언서 계정으로 그 캠페인의 미래 날짜 타임에 대해 위와
--        같이 콘솔에서 `reserve_event_ticket` 을 직접 호출
--        → `{ok:false, reason:'not_found'}` 이어야 한다
--      - 캠페인 상태를 'active' 로 되돌린 뒤 같은 호출을 다시 하면
--        정상적으로 `{ok:true, ...}` 이 나와야 한다(회귀 확인)
--
--   c. 관리자 예외 확인
--      - 관리자 계정으로 로그인해 위 a·b 상태(지난 날짜 또는 비-active
--        캠페인)에서 같은 호출을 하면 **차단되지 않고** 정상 예약(또는 이미
--        예약돼 있으면 'already_applied')이 나와야 한다
--
--   d. 정상 케이스 무회귀 확인
--      - 상태 'active' · 오늘 이후 날짜 · is_active=true 인 평범한 타임을
--        일반 인플루언서 계정으로 화면에서 그대로 예약 — 지금까지와 동일하게
--        성공해야 한다(288 원문 로직을 안 바꿨으므로 여기서 깨지면 이 파일이
--        아니라 다른 원인일 가능성이 높다)
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- -- 288 정의로 되돌린다 — 아래는 그 파일의 CREATE OR REPLACE 블록과 동일
-- -- (288_cancel_event_ticket_admin.sql 의 "5. reserve_event_ticket 재정의" 절을
-- --  그대로 재실행하면 된다. 시그니처가 같아 DROP 없이 CREATE OR REPLACE 로 충분)
-- COMMIT;
-- ============================================================
