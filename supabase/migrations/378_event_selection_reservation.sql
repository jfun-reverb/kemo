-- ============================================================
-- 378_event_selection_reservation.sql
-- 비공개 행사, 선착순형과 선정형 중 고르기 — 3/4 (선정형 접수)
-- 사양서: docs/specs/2026-08-24-event-invite-only-selection.md (설계 1)
-- 작업표: docs/specs/2026-08-24-event-invite-only-selection-breakdown.md 「S-3」
-- 선행: 330(reserve_event_ticket 현재 유효한 원본) · 376(event_selection_mode 칸) ·
--       377(승격 두 경로 차단 — 이 파일보다 반드시 먼저 적용돼 있어야 한다)
--
-- 🔴 이 파일이 데이터베이스 네 개 중 가장 위험하다 — 고치는 함수를 일반 공개
--    행사·비공개 선착순형·비공개 선정형 세 갈래가 전부 탄다.
--
-- ── 재정의 기준 (전수 확인) ────────────────────────────────────────
--   reserve_event_ticket 정의·재정의 이력: 283 → 284 → 288 → 316 → 330
--   (현재 유효한 원본, 번호가 가장 큰 정의). 330 이후 새 재정의 없음(grep 재확인).
--   이 파일은 330 의 함수 본문을 베이스로 삼는다. 330 의 「정원 판정」 블록
--   바로 앞에 분기 하나만 추가하고, 그 외 실행 코드는 330 과 완전히 동일
--   (지워진 줄 0, 주석을 뺀 실행 코드 기준 diff 로 대조 가능). 시그니처
--   (uuid, text, timestamptz, jsonb) 불변 — DROP 불필요.
--
-- ── 무엇을 넓히나 (핵심 변경 — 분기 1개만) ─────────────────────────
--   330 의 「정원 판정」 블록(t.status='confirmed' 수를 세어 확정/대기를
--   가르는 부분) 바로 앞에 다음 분기를 추가한다:
--
--     선정형(v_camp.event_selection_mode = 'selection')이면
--       → v_status:='waitlist' · v_app_status:='pending' · v_position:=NULL
--       (정원을 세지 않고 항상 심사중으로 접수)
--     아니면(선착순형 — 비공개·일반 공개 모두)
--       → 330 의 정원 판정 블록 그대로(한 글자도 안 바꿈)
--
-- ── 이 파일이 추가로 여는 것 둘 — 제약 완화 + 재정렬 함수 재정의 ──────
--   함수 분기만으로는 부족하다. event_tickets_waitlist_pos_chk 제약(282)이
--   「대기(waitlist)면 순번이 반드시 있어야 한다」를 요구해, 이 파일이
--   만드는 waitlist+순번NULL 조합을 그대로는 저장할 수 없다(선정형 예약이
--   100% 실패한다). 그래서 이 파일은 두 가지를 더 한다:
--
--   [A] event_tickets_waitlist_pos_chk 제약을 넓힌다 — waitlist 면 순번이
--       NULL 이거나 0보다 큰 값이어야 한다(넓히기만 한다 — 기존에 통과하던
--       조합은 전부 그대로 통과하고, 0 이하 금지는 그대로 유지해 선착순형이
--       기대는 규칙을 안 건드린다).
--
--   [B] public._renumber_event_waitlist(uuid)(288) 를 재정의한다 — 그
--       타임의 캠페인이 선정형이면 함수 맨 앞에서 아무것도 안 하고
--       끝낸다(RETURNS void). 제약만 풀고 이 함수를 그대로 두면, 이 함수는
--       그 타임의 waitlist 전체(순번 유무 무관)를 훑어 1부터 다시 매기므로
--       — 취소가 날 때마다 선정형 대기자에게도 번호가 생겨 「평소엔 비었다가
--       가끔 붙는」 들쭉날쭉한 상태가 된다. 조기 반환 모양은 377 이
--       _promote_next_event_waitlist(288) 에 쓴 것과 동일하다(조회 방식 —
--       event_slots → campaigns 조인, 값이 비면 통과, 주석 톤). 선착순형
--       타임의 재정렬 로직은 한 글자도 안 바꿨다.
--
--   🔴 377 파일 헤더의 서술을 여기서 바로잡는다 — 377 은 "이 함수는 손대지
--       않는다. 선정형은 waitlist_position 을 애초에 안 채우므로 그 함수가
--       돌아도 재정렬할 대상이 없어 아무 일도 안 한다" 고 적었는데 이는
--       틀렸다: 이 파일(378)이 실제로 만드는 것이 바로 「순번 없는 선정형
--       waitlist 행」이고, 그 행이 그 함수가 훑는 대상이다(위 [B] 가
--       막지 않으면 번호가 생긴다). 377 은 이미 개발서버에 적용돼 그 파일
--       자체는 고칠 수 없으므로, 여기서 그 서술이 틀렸음을 밝히고 이
--       파일이 [B] 로 실제 방어를 한다.
--
-- ── 🔴 이 조각에서 가장 위험한 것 — 분기 위치 ─────────────────────
--   분기를 함수 맨 앞에 두면 절대 안 된다. 정원 판정 앞에는 이미 아홉 개
--   넘는 검사가 있다 — 로그인 · 타임 잠금 · 타임 활성 · 지난 날짜(316) ·
--   캠페인 존재·행사 여부 · 방문형 여부 · 삭제 여부 · 캠페인 상태 active(316) ·
--   초대 번호 재검증 · 마감일(272 판정) · 만 18세(180 판정) · 행사 묶음
--   중복(330). 이 기능은 초대 전용 전용이라, 분기를 앞에 두어 이 검사들을
--   건너뛰면 비공개가 통째로 뚫린다. 이 파일은 330 의 「행사 묶음 중복」
--   검사(IF EXISTS ... already_applied) 블록이 끝난 **바로 다음**,
--   「정원 판정」 블록이 시작하는 **바로 그 자리**에만 분기를 심는다.
--
-- ── 정원을 세지 않는 이유 ──────────────────────────────────────────
--   선정형은 정원 무관 접수이고, 정원은 뽑을 때(다음 조각 S-4,
--   pick_event_tickets)만 지킨다. 신청은 넘쳐도 되고, 뽑을 때 넘기면 안 된다.
--
-- ── 순번을 비우는 이유 ─────────────────────────────────────────────
--   선정형은 뽑는 순서가 정해져 있지 않다. 순번이 보이면 방문객이 「내
--   차례가 정해져 있다」로 오해한다(작업표 §2 의심 ⑤).
--
-- ── set_config bypass 표시 — 그대로 둔다 ───────────────────────────
--   함수 앞부분의 PERFORM set_config('reverb.event_ticket_bypass','on',true)
--   는 손대지 않는다. 되살리기(취소 후 재예약) 분기가 신청 행을 UPDATE 할 때
--   이 표시가 있어야 289 신청 상태 변경 차단 트리거를 통과한다 — 선정형
--   분기 추가와 무관하게 계속 필요하다.
--
-- ── 실행 권한 — 재정의 방식과 보존 ─────────────────────────────────
--   시그니처 불변 → CREATE OR REPLACE 로 충분하며 DROP 이 필요 없다.
--   PostgreSQL 은 CREATE OR REPLACE 시 함수 본문만 바뀌고 실행 권한
--   (GRANT/REVOKE 로 쌓인 ACL)은 그대로 보존된다 — 이 파일은 그 성질에
--   기대어 REVOKE/GRANT 문을 다시 쓰지 않는다(377 과 같은 판단·같은 근거:
--   메모리 feedback_function_execute_grants — DROP 후 재생성만 위험하고
--   CREATE OR REPLACE 는 그 위험이 없다). 330 이 만든 REVOKE ALL FROM PUBLIC
--   + GRANT EXECUTE TO authenticated 상태가 그대로 유지된다.
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

  -- ── [378] 선정형 분기 — 여기가 유일하게 새로 넣는 부분이다 ────────
  --   이 지점은 위 「행사 묶음 중복」 검사가 끝난 직후이자, 아래 330 원문
  --   「정원 판정」 블록이 시작되는 바로 그 자리다. 위 모든 검사(로그인부터
  --   묶음 중복까지)를 이미 통과한 뒤에만 이 분기에 닿는다.
  IF v_camp.event_selection_mode = 'selection' THEN
    -- 선정형: 정원과 무관하게 항상 「심사중」으로 접수한다. 정원은 뽑을 때
    -- (S-4, pick_event_tickets)만 지킨다. 순번은 뽑는 순서가 없으므로 비운다
    -- (작업표 §2 의심 ⑤ — 순번이 보이면 뽑히는 차례가 정해져 있다는 오해를 준다).
    v_status     := 'waitlist';
    v_app_status := 'pending';
    v_position   := NULL;
  ELSE
    -- ── 이 아래는 330 원문(정원 판정 블록)과 완전히 동일 — 한 글자도 안
    --   바꿨다. 선착순형(비공개·일반 공개 모두)은 지금과 똑같이 동작한다.
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
  '[283+284+288+316+330+378] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 '
  '대기로 등록하고 짝이 되는 신청 행까지 같은 트랜잭션에서 만든다(또는 취소된 옛 신청 행을 '
  '되살린다). [288] 289 신청 상태 변경 차단 트리거를 위한 bypass 표시. [316] 지난 날짜의 '
  '타임과 ''active'' 상태가 아닌 캠페인의 예약을 막는다(둘 다 관리자 예외). [330] 「한 캠페인에 '
  '1타임」 검사를 「같은 행사 묶음(event_group_id)에 1건」으로 넓혔다 — 묶음이 없으면 종전과 '
  '동일. [378] 캠페인이 event_selection_mode=selection(선정형)이면 정원 판정을 건너뛰고 '
  '항상 waitlist(심사중)+신청 pending 으로 접수한다(순번 NULL) — 정원은 뽑을 때 '
  '(pick_event_tickets)만 지킨다. 선착순형(비공개·일반 공개 모두)은 330 의 정원 판정 그대로 '
  '무변경. 이 분기는 초대 번호·묶음 중복 등 앞선 검사를 모두 통과한 뒤(정원 판정 자리)에만 '
  '닿는다. 실패는 예외가 아니라 {ok:false, reason:...}.';

-- ============================================================
-- [378-A] event_tickets_waitlist_pos_chk 제약 완화 — waitlist+순번NULL 허용
--   (0 이하는 여전히 금지 — 선착순형이 그 규칙에 기댄다). 넓히기만 한다 —
--   기존에 통과하던 조합(확정+NULL, 대기+양수)은 전부 그대로 통과한다.
-- ============================================================
ALTER TABLE public.event_tickets
  DROP CONSTRAINT IF EXISTS event_tickets_waitlist_pos_chk;
ALTER TABLE public.event_tickets
  ADD CONSTRAINT event_tickets_waitlist_pos_chk CHECK (
    status <> 'waitlist' OR waitlist_position IS NULL OR waitlist_position > 0
  );

-- ============================================================
-- [378-B] _renumber_event_waitlist(uuid) 재정의(베이스 288) — 선정형
--   타임에서 조기 반환 한 단락만 추가. 나머지는 실행 코드 기준으로 288
--   원문과 완전히 동일(지워진 줄 0). 시그니처 불변 — DROP 불필요, 288 의
--   REVOKE ALL FROM PUBLIC + 369 의 REVOKE EXECUTE FROM anon, authenticated
--   는 CREATE OR REPLACE 로 그대로 보존된다(377 과 같은 판단·같은 근거 —
--   메모리 feedback_function_execute_grants).
-- ============================================================
CREATE OR REPLACE FUNCTION public._renumber_event_waitlist(
  p_slot_id uuid
) RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pos  integer := 0;
  v_mode text;
  r      record;
BEGIN
  -- [378] 선정형 캠페인은 waitlist_position 을 채우지 않는다(378-A 로
  -- 제약을 넓혀 waitlist+NULL 을 허용했기 때문에, 이 함수가 그대로 두면
  -- 그 행에도 번호를 매긴다). 타임(p_slot_id)이 속한 캠페인의 방식을 읽어
  -- 선정형이면 함수 맨 앞에서 아무것도 하지 않고 끝낸다(RETURNS void —
  -- 대기자가 없을 때와 같은 반환값). 슬롯이 안 보이거나(잘못된 id) 캠페인
  -- 연결이 끊긴 경우도 v_mode 는 NULL 이 되어 이 조건을 통과하지 않고
  -- 아래 원래 로직으로 흘러가며, 거기서도 결국 대상 없음으로 자연 종료한다
  -- (377 의 _promote_next_event_waitlist 조기 반환과 같은 모양·같은 근거).
  SELECT c.event_selection_mode INTO v_mode
    FROM public.event_slots s
    JOIN public.campaigns   c ON c.id = s.campaign_id
   WHERE s.id = p_slot_id;

  IF v_mode = 'selection' THEN
    RETURN;
  END IF;

  -- ── 이 아래는 288 원문과 동일 ─────────────────────────────────
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
  '[378, 베이스 288] 타임(p_slot_id)의 남은 대기(waitlist) 티켓 순번을 1부터 다시 매긴다. '
  '**취소 함수는 이 함수를 취소 종류(확정이었든 대기였든)와 무관하게 항상 호출해야 '
  '한다** — 대기 중인 티켓이 직접 취소될 때도 뒷사람 순번이 당겨져야 하기 때문(283 '
  '원문에서 이 재정렬 루프가 승격 조건문 바깥에 있던 이유와 같다). [378] 그 타임의 '
  '캠페인이 event_selection_mode=selection(선정형)이면 함수 맨 앞에서 아무것도 하지 '
  '않고 끝낸다 — 선정형은 waitlist_position 을 채우지 않으므로(순번이 있으면 뽑히는 '
  '차례가 정해져 있다는 오해를 준다, 378-A 참고) 재정렬 대상이 없다. 선착순형(비공개·'
  '일반 공개 모두)은 288 원문 그대로 무변경. 내부 전용 함수 — REVOKE ALL FROM '
  'PUBLIC(288) + REVOKE EXECUTE FROM anon, authenticated(369) 로 두 겹 닫혀 있으며 이 '
  '재정의는 그 권한을 그대로 보존한다(CREATE OR REPLACE, DROP 아님).';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (1단계씩 — 결과 확인 후 다음 단계로. .claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ============================================================
--
-- [1단계] 함수가 재정의 대상 둘(reserve_event_ticket·_renumber_event_waitlist)
--   뿐이고 각각 시그니처가 안 바뀌었는지 — 오버로드 생기면 안 됨 (SQL 편집기,
--   서비스 키로 실행 가능 — 로그인 세션 불필요)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('reserve_event_ticket', '_renumber_event_waitlist')
--  ORDER BY p.proname;
--   → 2건, 이름당 1건씩:
--     reserve_event_ticket(uuid, text, timestamptz, jsonb)
--     _renumber_event_waitlist(uuid)
--     (오버로드 생기면 안 됨 — 나오면 즉시 중단하고 보고)
--
-- [2단계] 실행 권한이 재정의 뒤에도 유지되는지 — proacl 을 직접 본다.
--   ⚠️ has_function_privilege 만 보면 방향을 구분 못 한다. proacl 의 맨 앞
--   "=X/" 유무를 함께 볼 것(있으면 PUBLIC 에게도 권한이 남아 있다는 뜻 —
--   있으면 안 된다).
-- SELECT p.proname,
--        p.proacl::text AS acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authed_can
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('reserve_event_ticket', '_renumber_event_waitlist');
--   → reserve_event_ticket: acl 에 "=X/" 없음, anon_can=false, authed_can=true
--     (330 그대로)
--   → _renumber_event_waitlist: acl 에 "=X/" 없음, anon_can=false,
--     authed_can=false (288 REVOKE ALL FROM PUBLIC + 369 REVOKE FROM anon,
--     authenticated 두 겹이 그대로 유지돼야 한다)
--
-- [2-B단계] ⚠️ 이 단계가 이번 수정의 핵심 검증이다. 제약이 실제로 넓어졌는지
--   + _renumber_event_waitlist 를 최소 1회 실제 호출(적용 성공은 검증이
--   아니다 — .claude/rules/supabase.md 「신규 데이터베이스 함수는 적용
--   성공이 동작 확인이 아니다」). 전부 SQL 편집기(서비스 키)로 가능 —
--   로그인 세션 불필요.
--
--   [2-B-1] 제약 정의가 넓어졌는지
-- SELECT conname, pg_get_constraintdef(oid) AS definition
--   FROM pg_constraint
--  WHERE conrelid = 'public.event_tickets'::regclass
--    AND conname  = 'event_tickets_waitlist_pos_chk';
--   → definition 에 "waitlist_position IS NULL" 이 포함돼야 한다
--     (예: CHECK (status <> 'waitlist' OR waitlist_position IS NULL
--          OR waitlist_position > 0))
--
--   [2-B-2] 기존 행이 새 제약을 이미 통과했는지(위반이 있었다면 위 ALTER
--     TABLE 자체가 실패했겠지만, 재확인용 — 0건이어야 정상)
-- SELECT count(*) FROM public.event_tickets
--  WHERE status = 'waitlist'
--    AND (waitlist_position IS NULL OR waitlist_position <= 0);
--   → 0 (이 기능이 아직 실사용 전이므로 waitlist+NULL 행이 있으면 안 됨)
--
--   [2-B-3] waitlist+순번NULL 이 이제 실제로 저장되는지(넣어 보고 되돌림).
--     ⚠️ event_tickets 행이 하나도 없으면(개발서버 초기 상태) 이 블록은
--     건너뛰고 4단계에서 실제 데이터로 확인한다.
-- BEGIN;
-- UPDATE public.event_tickets
--    SET status = 'waitlist', waitlist_position = NULL
--  WHERE id = (SELECT id FROM public.event_tickets LIMIT 1)
-- RETURNING id, status, waitlist_position;
-- ROLLBACK;
--   → 에러 없이 1행 반환(status='waitlist', waitlist_position=NULL) 후 롤백
--
--   [2-B-4] waitlist+순번0(또는 음수)은 여전히 거부되는지(넓히기가 과하지
--     않았는지)
-- BEGIN;
-- UPDATE public.event_tickets
--    SET status = 'waitlist', waitlist_position = 0
--  WHERE id = (SELECT id FROM public.event_tickets LIMIT 1);
-- ROLLBACK;
--   → 에러: new row for relation "event_tickets" violates check constraint
--     "event_tickets_waitlist_pos_chk" (거부돼야 정상 — ROLLBACK 은 그대로
--     실행해 트랜잭션을 정리할 것)
--
--   [2-B-5] _renumber_event_waitlist 스모크 호출(존재하지 않는 슬롯) —
--     내부 전용 함수라 SQL 편집기(서비스 키)로 postgres 소유자 권한으로
--     직접 호출 가능(377 3단계와 같은 이유)
-- SELECT public._renumber_event_waitlist('00000000-0000-0000-0000-000000000000');
--   → 에러 없이 끝남(RETURNS void 라 결과 행 없음. 슬롯이 없어 v_mode 도
--     NULL → 조기 반환 조건 통과 안 함 → 원래 루프 진입하되 대상 없어 자연
--     종료. 정상)
--
-- [3단계] 형식 확인 — reserve_event_ticket 을 최소 1회 실제 호출한다(적용
--   성공은 검증이 아니다 — 자료형·컬럼 모호성은 첫 호출에서 드러난다. SQL
--   편집기는 서비스 키라 auth.uid() 가 NULL — permission_denied 가 정상)
-- SELECT public.reserve_event_ticket('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- [4단계] ⚠️ 이 함수는 본인 계정 가드(auth.uid() 필요) 때문에 SQL 편집기로는
--   선정형 접수 동작 자체를 검증할 수 없다. 반드시 실제 로그인 세션(테스트
--   인플루언서 계정 + 개발서버 브라우저)으로 확인한다:
--
--   준비: 행사(event_mode) + 비공개(is_invite_only) 캠페인 1개를 만들고
--     초대 번호를 발급한다. 타임을 1개 만들고 정원을 1로 둔다.
--     event_selection_mode 를 'selection' 으로 UPDATE 한다(관리자 화면
--     S-6 이 아직 없으므로 SQL 편집기에서 직접 값을 바꿔 꾸민다).
--
--   a. [검증 5] 정원이 남아 있어도 「심사중」으로 접수되는지, 정원을
--      넘겨서도 들어오는지, 순번이 비는지
--      테스트 계정 갑으로 타임을 예약 → 응답의 status 가 'waitlist' 인지
--      확인(정원이 1이고 아무도 안 찼는데도 confirmed 가 아니어야 한다).
--      같은 타임에 테스트 계정 을도 예약 → 역시 성공 + status='waitlist'
--      (정원 1을 넘겨 2명이 들어와야 한다). 두 티켓 모두
--        SELECT status, waitlist_position FROM public.event_tickets
--         WHERE slot_id='<타임id>';
--        → 둘 다 status='waitlist', waitlist_position 은 둘 다 NULL
--
--   b. [검증 5-B ①] 틀린 초대 번호로 거부되는지
--      테스트 계정 병으로 잘못된 초대 번호를 넣고 예약 시도
--      → {"ok":false,"reason":"invite_mismatch"} (심사중으로도 접수되면
--        안 된다 — 접수 자체가 거부돼야 한다)
--
--   c. [검증 5-B ②] 같은 행사 묶음 안에서 두 번 예약이 막히는지
--      이 선정형 캠페인을 다른 캠페인과 같은 event_group_id 로 묶어 두고,
--      갑이 그 다른 캠페인에서 이미 유효한 예약이 있다면 이 선정형 캠페인
--      예약 시도가 already_applied 로 거부되는지 확인(330 검사가 여전히
--      선정형 분기보다 먼저 실행됨을 확인하는 것 — 4단계 준비에서 묶음이
--      없으면 이 항목은 별도 캠페인 2개를 묶어 준비할 것)
--
--   d. [검증 5-B ③] 모집중(active)이 아닌 캠페인이 거부되는지
--      캠페인 status 를 'scheduled' 등으로 바꾼 뒤 갑(비관리자 계정)으로
--      예약 시도 → {"ok":false,"reason":"not_found"}. 확인 후 status 를
--      다시 'active' 로 되돌릴 것
--
--   e. [검증 5-B ④] 지난 날짜의 타임이 거부되는지
--      타임의 slot_date 를 어제 날짜로 바꾼 뒤 갑으로 예약 시도
--      → {"ok":false,"reason":"slot_closed"}. 확인 후 날짜를 되돌릴 것
--
--   f. [검증 5-B ⑤] 취소 뒤 재예약 시 기존 신청 행이 되살아나는지
--      갑의 티켓을 cancel_event_ticket 로 취소한 뒤 같은 타임(또는 같은
--      캠페인의 다른 타임)에 다시 예약 → 새 응모 행이 또 생기지 않고
--      기존 applications 행 하나가 status 만 pending 으로 되돌아오는지
--        SELECT count(*) FROM public.applications
--         WHERE user_id='<갑 id>' AND campaign_id='<선정형 캠페인 id>';
--        → 1행이어야 한다(취소 전후 합쳐서)
--
--   g. [검증 6, 회귀] 일반 공개 예약이 종전 그대로인지
--      is_invite_only=false 인 일반 공개 행사 캠페인(event_selection_mode
--      는 CHECK 제약상 자동으로 'first_come')에서 정상 예약 → 정원 안이면
--      즉시 status='confirmed' + 신청 approved. 330 적용 시점과 동일하게
--      동작해야 한다
--
--   h. [검증 4, 회귀] 선착순형 비공개도 종전 그대로인지
--      4단계 준비에서 만든 캠페인의 event_selection_mode 를 다시
--      'first_come' 으로 되돌린 뒤 예약 → 정원 안이면 즉시 confirmed(당선),
--      넘치면 waitlist + 순번이 채워지는지(NULL 이 아님) 확인
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- -- 330 정의로 되돌린다 — 330_reserve_event_ticket_group_uniqueness.sql 의
-- -- CREATE OR REPLACE FUNCTION public.reserve_event_ticket(...) 블록(COMMENT
-- -- 포함)을 그대로 재실행하면 된다(시그니처 동일이라 DROP 불필요). 이
-- -- 롤백 뒤에도 event_selection_mode 칸(376)·값은 남아 있어도 무해하다
-- -- (330 정의는 그 칸을 안 읽으므로 값이 있어도 동작에 영향 없음).
-- --
-- -- [378-B] _renumber_event_waitlist 는 288 의 CREATE OR REPLACE 블록을
-- -- 그대로 재실행한다(역시 시그니처 동일).
-- --
-- -- [378-A] 제약은 **되돌리지 않아도 무해하다** — 넓히기만 했으므로 옛 정의가
-- -- 허용하던 조합은 전부 그대로 허용되고, 330 으로 되돌린 함수는 waitlist+NULL
-- -- 을 애초에 만들지 않는다. 굳이 282 의 엄격한 정의로 되돌리려면:
-- --
-- --   🔴 반드시 **먼저** 남아 있는 waitlist+NULL 행을 없애야 한다. 안 그러면
-- --      ADD CONSTRAINT 자체가 그 행들 때문에 실패해 롤백이 통째로 막힌다.
-- --      SELECT count(*) FROM public.event_tickets
-- --       WHERE status='waitlist' AND waitlist_position IS NULL;   → 0 이어야 함
-- --      (0 이 아니면 그 행들은 선정형 접수분이다 — 지우거나 순번을 채울지
-- --       사람이 판단할 일이지 롤백이 임의로 정할 일이 아니다.)
-- --
-- --   ALTER TABLE public.event_tickets
-- --     DROP CONSTRAINT IF EXISTS event_tickets_waitlist_pos_chk;
-- --   ALTER TABLE public.event_tickets
-- --     ADD CONSTRAINT event_tickets_waitlist_pos_chk CHECK (
-- --       (status = 'waitlist' AND waitlist_position IS NOT NULL AND waitlist_position > 0)
-- --       OR (status <> 'waitlist')
-- --     );
-- COMMIT;
-- ============================================================
