-- ============================================================
-- 288_cancel_event_ticket_admin.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 관리자용 예약 취소 함수
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 선행: 280~287 (특히 282 티켓 표 · 283 예약/취소/입장 함수 · 284 주의사항 동의 ·
--       287 다른 날 입장 되묻기)
-- 다음 파일(289)과 반드시 이 순서로 적용한다 — 이유는 289 파일 헤더 참고.
--
-- 왜 필요한가:
--   관리자가 예약(입장 티켓)을 취소할 수단이 지금까지 하나도 없었다. 그래서
--   관리자는 「신청 미승인」으로 대신 처리해 왔는데, 그러면 신청만 반려되고
--   티켓은 확정으로 남아 — 입장 확인(check_in_ticket)이 신청 상태를 보지 않으므로
--   **반려된 사람이 현장에서 그대로 입장 처리될 수 있다.** 2026-08-04 확인 화면
--   경고(dev/js/admin-applications.js rejectApplication)는 「모르고 누르는 일」만
--   막을 뿐 근본 해결이 아니다. 이 파일이 실제 취소 수단을 만든다.
--
-- 이 파일이 만드는 것:
--   1) event_tickets 표에 취소 감사 컬럼 4개 추가
--      (cancelled_by · cancelled_by_role · cancelled_by_name · admin_cancel_note)
--   2) lookup_values 에 취소 사유 1건 추가(kind='cancel_reason', code='admin_cancelled')
--      — 기존 6종(schedule_unavailable·personal_reason·product_mismatch·delivery_issue·
--      account_change·other, 마이그레이션 104)과 겹치지 않음(사전 확인 완료,
--      .claude/rules/supabase.md 「기준 데이터 추가 시 중복 확인」).
--   3) public._promote_next_event_waitlist(slot_id) / public._renumber_event_waitlist(slot_id)
--      — 대기 1번 승격(+알림) / 남은 대기 순번 재정렬. 283 의 cancel_event_ticket
--      안에 있던 로직을 그대로 옮긴 것(함수를 둘로 나눈 이유는 §3 코드 주석 참고 —
--      재정렬은 승격 여부와 무관하게 항상 돌아야 한다). 본인 취소·관리자 취소
--      두 함수가 이 둘을 함께 쓴다(복사 금지 — 요청사항).
--   4) public.cancel_event_ticket(uuid) 재정의 — 로직은 283 과 완전히 같고,
--      승격 부분만 3)을 호출하도록 바꾸고, 취소 감사 컬럼을 채운다.
--      (시그니처 불변 — DROP 불필요)
--   5) public.reserve_event_ticket(uuid,text,timestamptz,jsonb) 재정의 — 284 와
--      로직은 완전히 같고, 다음 파일(289)이 읽을 표시(bypass 플래그)를 세우는
--      한 줄만 추가한다. (시그니처 불변 — DROP 불필요)
--   6) public.cancel_event_ticket_admin(ticket_id, reason_note) — 신규. 관리자 전용.
--
-- ── 본인 취소와 다른 점 3가지 (요청사항 — 판단과 근거) ──────────────
--
--   ① 본인 확인 대신 관리자 권한
--      cancel_event_ticket(283)은 `ticket.influencer_id = auth.uid()` 로 본인만
--      허용한다. 관리자 취소는 그 반대로 `public.is_admin()` 만 확인하고 티켓의
--      주인이 누구든 취소할 수 있다 — 그게 이 함수가 존재하는 이유다.
--
--   ② 시작 2시간 전 제한을 적용하지 **않는다**
--      본인 취소(283)는 「예약 타임 시작 2시간 전까지」만 허용해, 막판 취소가
--      대기자에게 넘어갈 시간을 확보한다(운영 목적의 제한). 관리자가 취소를
--      판단하는 상황은 이미 사람이 개입해 사정을 확인한 뒤이고, 무엇보다 이
--      함수를 만든 이유 자체가 「지금 당장 정리할 수단이 없다」였다 — 행사
--      당일에도 잘못 등록된 예약을 정리해야 할 수 있는데 시간 제한을 걸면
--      만들어 준 수단이 무용지물이 된다. → **관리자는 시간 제한 없이 취소 가능**.
--
--   ③ 취소 사유를 남긴다 — 단, 사용자에게 그대로 보이지 않는다
--      관리자가 남긴 자유 텍스트(p_reason_note)는 event_tickets.admin_cancel_note
--      에만 저장한다. applications.cancel_reason(자유 텍스트)에는 **넣지 않는다.**
--      이유: applications.cancel_reason 은 인플루언서 마이페이지의 취소 상세
--      모달(dev/js/mypage.js openCancelDetailModal)이 그대로 노출하는 칸이다.
--      관리자 화면은 한국어라 이 메모도 한국어로 쓰일 가능성이 높은데, 그 원문이
--      일본어 화면에 번역 없이 그대로 뜨면 사용자가 못 알아본다(이 프로젝트에
--      한국어→일본어 실시간 번역 장치가 없다 — 있는 건 응모건 메시지의 비동기
--      웹훅 번역뿐이고 이 함수 안에서 동기 호출할 수 없다). 대신
--      applications.cancel_reason_code = 'admin_cancelled' 는 채운다 — 이건
--      lookup_values 의 한국어/일본어 라벨 쌍이라 사용자에게는 자동으로
--      「運営によるキャンセル」로, 관리자 화면에는 「운영진 취소」로 보인다(안전).
--      즉 사용자는 "운영진이 취소했다"는 사실은 알지만 관리자의 내부 메모는
--      보지 못한다.
--
-- ── 대기자 자동 승격은 본인 취소와 같아야 한다 (요청사항) ────────────
--   확정 1자리가 비면 대기 1번이 올라가고 순번이 재정렬되며 알림이 나가는
--   로직은 두 취소 경로가 반드시 똑같아야 한다(따로 두면 한쪽만 고쳐진다).
--   → public._promote_next_event_waitlist(slot_id) 로 뽑아 공용화했다.
--
-- ── 짝이 되는 신청 행 (이 작업의 핵심) ────────────────────────────
--   관리자 취소도 283 의 「신청 행 처리 규칙」을 그대로 따른다 — 확정 티켓을
--   취소하면 신청도 cancelled 로, previous_status 에 취소 직전 신청 상태를
--   담는다. 취소해도 신청 행은 지우지 않는다(282 헤더 참고 — 옛 유일 제약 때문에
--   재예약은 행을 되살리는 방식이다).
--
-- ── 이미 입장한 티켓(entered_at 있음)을 취소할 수 있게 할지 (판단) ───
--   **막는다.** 본인 취소(283)와 같은 조건. 이미 입장했다는 사실 자체를
--   취소로 지울 이유가 없고, 취소하면 「신청은 취소인데 입장은 완료」인
--   모순 데이터가 남는다. 입장 이후 문제가 생겼다면(예: 위반 발견) 그건
--   이 함수의 몫이 아니라 다른 관리 조치(블랙리스트 등)의 영역이다.
--
-- ── 실패 반환 방식 ──────────────────────────────────────────────
--   283·284·287 과 같은 방식 — 예외가 아니라 {ok:false, reason:...}.
--
-- ── 다음 파일(289)과의 연결고리 ──────────────────────────────────
--   이 파일의 함수 3개(cancel_event_ticket · reserve_event_ticket ·
--   cancel_event_ticket_admin)는 applications.status 를 UPDATE 하기 직전에
--   `PERFORM set_config('reverb.event_ticket_bypass', 'on', true)` 를 세운다.
--   지금(289 적용 전)은 아무도 이 값을 읽지 않아 아무 효과가 없다 — 하지만
--   289 가 적용되면 이 표시가 있어야 그 함수들이 계속 신청 상태를 바꿀 수
--   있다. 순서를 바꿔 289 를 먼저 적용하면 그 사이 구간에는 티켓 함수조차
--   막혀 있을 것 같지만 그렇지 않다(289 파일이 아직 없으니 트리거 자체가
--   없다) — 그래도 지시받은 순서(이 파일 먼저) 그대로 둔다: 관리자가 예약을
--   정리할 수단이 먼저 존재해야, 나중에 "직접 수정 경로"를 막아도 안전하다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. event_tickets 취소 감사 컬럼 4개
-- ============================================================
ALTER TABLE public.event_tickets
  ADD COLUMN IF NOT EXISTS cancelled_by      uuid NULL,
  ADD COLUMN IF NOT EXISTS cancelled_by_role text NULL
    CHECK (cancelled_by_role IS NULL OR cancelled_by_role IN ('influencer','admin')),
  ADD COLUMN IF NOT EXISTS cancelled_by_name text NULL,
  ADD COLUMN IF NOT EXISTS admin_cancel_note text NULL;

COMMENT ON COLUMN public.event_tickets.cancelled_by IS
  '[288] 취소를 실행한 사람의 auth id. 본인 취소면 influencer_id 와 같은 값, '
  '관리자 취소면 관리자 auth_id.';
COMMENT ON COLUMN public.event_tickets.cancelled_by_role IS
  '[288] 취소 주체 — influencer(본인) | admin(관리자). NULL 은 288 이전에 취소된 옛 행.';
COMMENT ON COLUMN public.event_tickets.cancelled_by_name IS
  '[288] 관리자 취소일 때만 채운다(admins.name 스냅샷). 본인 취소는 role 만으로 '
  '충분해 이름을 채우지 않는다(자기 자신이므로).';
COMMENT ON COLUMN public.event_tickets.admin_cancel_note IS
  '[288] 관리자가 취소 시 남긴 내부 메모(선택, 최대 500자). 사용자에게 노출되지 '
  '않는다 — 이유는 파일 헤더 「③ 취소 사유를 남긴다」 참고. 인플루언서에게 보이는 '
  '건 applications.cancel_reason_code=''admin_cancelled'' 의 번역된 카테고리 라벨뿐이다.';

-- ============================================================
-- 2. lookup_values — 관리자 취소 사유 카테고리 1건
--    기존 cancel_reason 6종(마이그레이션 104)과 중복 확인 완료:
--    schedule_unavailable/personal_reason/product_mismatch/delivery_issue/
--    account_change/other — 겹치지 않는다.
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('cancel_reason', 'admin_cancelled', '운영진 취소', '運営によるキャンセル', 95, true)
ON CONFLICT (kind, code) DO NOTHING;

-- ============================================================
-- 3. 대기 승격 + 순번 재정렬 공용 함수 2개
--    cancel_event_ticket(283)에 있던 블록을 그대로 옮긴 것 — 단 **함수 하나로
--    합치지 않고 둘로 나눴다.** 283 원문은 「승격(조건부)」과 「순번 재정렬
--    (무조건)」이 별개 블록이다(재정렬은 IF status='confirmed' 바깥에 있어
--    대기 티켓이 직접 취소될 때도 항상 실행된다). 하나로 합쳐 승격 블록
--    안에서만 재정렬하면, **대기 중인 티켓이 직접 취소될 때 남은 대기자
--    순번에 구멍이 생기는 회귀**가 생긴다(승격은 확정 티켓이 취소될 때만
--    일어나므로, 그 조건 뒤에 재정렬을 두면 대기 티켓 취소는 재정렬을 건너뛴다
--    — 최초 초안에서 실제로 이 실수를 했다가 리뷰 중 발견해 둘로 나눴다).
-- ============================================================
CREATE OR REPLACE FUNCTION public._promote_next_event_waitlist(
  p_slot_id uuid
) RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_promoted   public.event_tickets%ROWTYPE;
  v_slot       public.event_slots%ROWTYPE;
  v_camp_title text;
BEGIN
  SELECT * INTO v_promoted
    FROM public.event_tickets t
   WHERE t.slot_id = p_slot_id
     AND t.status  = 'waitlist'
   ORDER BY t.waitlist_position NULLS LAST, t.created_at
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE public.event_tickets
     SET status            = 'confirmed',
         waitlist_position = NULL,
         version           = version + 1
   WHERE id = v_promoted.id;

  -- 짝이 되는 신청도 심사중 → 당선으로. 이 UPDATE 는 289 적용 후 차단 트리거를
  -- 지나가야 하므로, 호출부(cancel_event_ticket·cancel_event_ticket_admin)가
  -- 이 함수를 부르기 **전에** bypass 표시를 이미 세워 둔 상태여야 한다.
  IF v_promoted.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status = 'approved'
     WHERE id = v_promoted.application_id;
  END IF;

  -- 승격된 사람에게 앱 알림(일본어). 알림 실패가 승격 자체를 되돌리면 안 되므로
  -- 이 블록만 예외를 삼킨다(283 원문과 같은 판단 — 「알림은 못 갔지만 자리는
  -- 넘어갔다」가 반대 경우보다 낫다).
  BEGIN
    SELECT * INTO v_slot FROM public.event_slots WHERE id = p_slot_id;
    SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_promoted.campaign_id;

    INSERT INTO public.notifications (
      user_id, kind, ref_table, ref_id, title, body
    ) VALUES (
      v_promoted.influencer_id,
      'event_waitlist_promoted',
      'event_tickets',
      v_promoted.id,
      'キャンセル待ちから予約が確定しました',
      COALESCE(v_camp_title, 'イベント')
        || 'のご予約が確定しました。'
        || to_char(v_slot.slot_date, 'MM月DD日')
        || ' ' || to_char(v_slot.start_time, 'HH24:MI')
        || ' にご来場ください。入場チケットからQRコードをご確認いただけます。'
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_promoted.id;
END;
$$;

COMMENT ON FUNCTION public._promote_next_event_waitlist(uuid) IS
  '[288] 확정 자리가 빈 타임(p_slot_id)에서 대기 1번만 확정으로 올린다(순번 재정렬은 '
  '_renumber_event_waitlist() 가 별도로 담당 — 반드시 함께 호출할 것). 짝이 되는 신청을 '
  'approved 로, 승격 알림도 함께 처리. 반환값은 승격된 티켓 id(없으면 NULL). '
  'cancel_event_ticket(283)·cancel_event_ticket_admin(288) 둘 다 이 함수를 쓴다 — '
  '승격 로직을 두 곳에 복사하면 한쪽만 고쳐지는 사고를 막기 위함. 내부 전용 함수 '
  '(밑줄 접두어, _settlement_cert_candidates() 와 같은 명명 관례) — 호출부가 이미 '
  '슬롯 행을 잠근 상태에서 부르는 것을 전제로 한다.';

CREATE OR REPLACE FUNCTION public._renumber_event_waitlist(
  p_slot_id uuid
) RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pos integer := 0;
  r     record;
BEGIN
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
  '[288] 타임(p_slot_id)의 남은 대기(waitlist) 티켓 순번을 1부터 다시 매긴다. '
  '**취소 함수는 이 함수를 취소 종류(확정이었든 대기였든)와 무관하게 항상 호출해야 '
  '한다** — 대기 중인 티켓이 직접 취소될 때도 뒷사람 순번이 당겨져야 하기 때문(283 '
  '원문에서 이 재정렬 루프가 승격 조건문 바깥에 있던 이유와 같다). 내부 전용 함수.';

-- 내부 전용 — 283 gen_event_ticket_code() 와 같은 패턴. authenticated 에 GRANT 하지
-- 않는다. cancel_event_ticket·cancel_event_ticket_admin(둘 다 이 함수 소유자 권한으로
-- 실행되는 SECURITY DEFINER 함수) 안에서만 불린다.
REVOKE ALL ON FUNCTION public._promote_next_event_waitlist(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._renumber_event_waitlist(uuid) FROM PUBLIC;

-- ============================================================
-- 4. cancel_event_ticket(uuid) 재정의 — 283 과 로직 동일, 승격만 3)에 위임 +
--    취소 감사 컬럼 채움 + 289 를 위한 bypass 표시. 시그니처 불변(DROP 불필요).
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
  v_promoted_id  uuid := NULL;
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

  -- 본인 것만. 관리자라도 이 함수로는 남의 티켓을 취소할 수 없다
  -- (대리 취소는 아래 5) cancel_event_ticket_admin 을 쓴다).
  IF v_ticket.influencer_id <> v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancelled');
  END IF;

  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- ── 송금 완료된 정산이 걸려 있으면 취소하지 않는다 (283 원문과 동일 이유) ──
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- ── 취소 마감: 예약 타임 시작 2시간 전까지 (본인 취소 전용 제한) ──
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  v_slot_start := (v_slot.slot_date + v_slot.start_time) AT TIME ZONE 'Asia/Tokyo';

  IF now() > (v_slot_start - interval '2 hours') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancel_window_passed');
  END IF;

  -- [288] 다음 마이그레이션(289)이 읽을 표시 — 「이 트랜잭션은 예약 함수가 낸
  --   변경」. 지금은 아무도 읽지 않는다(289 적용 전) — 파일 헤더 참고.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  -- ── 취소 처리 ─────────────────────────────────────────────────
  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = v_uid,
         cancelled_by_role = 'influencer',
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
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
    v_promoted_id := public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- ── 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행 ──────
  --   대기 중인 티켓이 직접 취소돼도(승격이 안 일어나도) 뒷사람 순번은
  --   당겨져야 한다(283 원문과 동일 — _renumber_event_waitlist() 주석 참고).
  PERFORM public._renumber_event_waitlist(v_slot.id);

  RETURN jsonb_build_object(
    'ok',                 true,
    'ticket_id',          v_ticket.id,
    'status',             'cancelled',
    'promoted_ticket_id', v_promoted_id
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_event_ticket(uuid) IS
  '[283+288] 본인 예약 취소. 예약 타임 시작 2시간 전까지만(일본 시각 기준 서버 판정). '
  '확정 자리가 빠지면 _promote_next_event_waitlist() 로 같은 타임 대기 1번을 자동 승격. '
  '취소해도 신청 행은 지우지 않고 cancelled 로 남겨, 재예약 때 그 행을 되살린다. '
  '[288] 승격 로직을 공용 함수로 분리 + 취소 감사 컬럼(cancelled_by 등) 채움 + '
  '289 신청 상태 변경 차단 트리거를 위한 bypass 표시.';

REVOKE ALL ON FUNCTION public.cancel_event_ticket(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_event_ticket(uuid) TO authenticated;

-- ============================================================
-- 5. reserve_event_ticket 재정의 — 284 와 로직 동일, bypass 표시 한 줄만 추가.
--    시그니처 불변(DROP 불필요).
-- ============================================================
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
  '[283+284+288] 오프라인 행사 타임 예약. 타임 행을 잠그고 정원을 세어 확정 또는 대기로 '
  '등록하고 짝이 되는 신청 행까지 같은 트랜잭션에서 만든다(또는 취소된 옛 신청 행을 되살린다). '
  '[288] 289 신청 상태 변경 차단 트리거를 위한 bypass 표시. 실패는 예외가 아니라 '
  '{ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_event_ticket(uuid, text, timestamptz, jsonb) TO authenticated;

-- ============================================================
-- 6. cancel_event_ticket_admin — 신규. 관리자 전용 예약 취소.
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_event_ticket_admin(
  p_ticket_id   uuid,
  p_reason_note text DEFAULT NULL
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
  v_admin_name   text;
  v_camp_title   text;
  v_promoted_id  uuid := NULL;
  v_note         text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  SELECT * INTO v_ticket
    FROM public.event_tickets
   WHERE id = p_ticket_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_ticket.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'cancelled');
  END IF;

  -- ⚠️ 이미 입장한 티켓은 취소하지 않는다 — 판단 근거는 파일 헤더 참고.
  IF v_ticket.entered_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_entered');
  END IF;

  -- ── 송금 완료된 정산이 걸려 있으면 취소하지 않는다 (283 과 동일 이유) ──
  --   행사 캠페인은 리워드 0 고정이 원칙(admin-event.js applyEventModeFormLock)
  --   이라 정상적으로는 정산이 생기지 않지만, 관리자가 리워드를 수동으로 넣은
  --   예외 상황을 대비한 방어선이다.
  IF v_ticket.application_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.settlements s
        WHERE s.application_id = v_ticket.application_id
          AND s.status = 'paid'
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settlement_paid_cannot_cancel');
  END IF;

  -- ⚠️ 본인 취소(cancel_event_ticket)와 달리 「시작 2시간 전까지」 창을 두지
  --   않는다 — 판단 근거는 파일 헤더 「② 시작 2시간 전 제한을 적용하지 않는다」.
  SELECT * INTO v_slot FROM public.event_slots WHERE id = v_ticket.slot_id FOR UPDATE;

  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  v_note := NULLIF(btrim(COALESCE(p_reason_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_note := left(v_note, 500);
  END IF;

  -- [289] 이어지는 마이그레이션이 읽을 표시 — 신청 상태 UPDATE 두 건(아래 +
  --   _promote_next_event_waitlist 내부의 승격 UPDATE) 모두 이 트랜잭션 안에서
  --   일어나므로 한 번만 세우면 전부 적용된다.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'cancelled',
         waitlist_position = NULL,
         cancelled_at      = now(),
         cancelled_by      = v_uid,
         cancelled_by_role = 'admin',
         cancelled_by_name = v_admin_name,
         admin_cancel_note = v_note,
         version           = version + 1
   WHERE id = v_ticket.id;

  IF v_ticket.application_id IS NOT NULL THEN
    UPDATE public.applications
       SET status             = 'cancelled',
           previous_status    = CASE v_ticket.status
                                  WHEN 'confirmed' THEN 'approved'
                                  ELSE 'pending'
                                END,
           cancelled_at       = now(),
           cancel_phase       = 'other',
           cancel_reason_code = 'admin_cancelled'
           -- cancel_reason(자유 텍스트)은 일부러 채우지 않는다 — 파일 헤더
           -- 「③ 취소 사유를 남긴다」 참고. 관리자 메모는 admin_cancel_note 에만.
     WHERE id = v_ticket.application_id;
  END IF;

  -- ── 확정 자리가 빠졌으면 대기 1번을 승격 (본인 취소와 같은 공용 함수) ──
  IF v_ticket.status = 'confirmed' THEN
    v_promoted_id := public._promote_next_event_waitlist(v_slot.id);
  END IF;

  -- ── 남은 대기자 순번 다시 매기기 — 승격 여부와 무관하게 항상 실행 ──────
  --   관리자가 대기 중인 티켓을 직접 취소해도(승격이 안 일어나도) 뒷사람
  --   순번은 당겨져야 한다.
  PERFORM public._renumber_event_waitlist(v_slot.id);

  -- ── 취소당한 사람에게 알린다 ─────────────────────────────────
  --   본인이 요청한 취소가 아니라 운영진이 취소한 것이므로, cancel_event_ticket
  --   (본인 취소)과 달리 반드시 알려야 한다. kind='application_cancelled' 는
  --   이미 있는 알림 종류(마이그레이션 105)이고, 인플루언서 앱이 이 kind 를
  --   누르면 응모이력으로 이동하도록 이미 구현돼 있다(신규 클라이언트 코드 불필요).
  BEGIN
    IF v_ticket.application_id IS NOT NULL THEN
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'application_cancelled',
        'applications',
        v_ticket.application_id,
        'ご予約がキャンセルされました',
        COALESCE(v_camp_title, 'イベント')
          || 'のご予約が運営によりキャンセルされました。ご不明な点がございましたら運営までお問い合わせください。'
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 알림 실패가 취소·승격을 되돌리면 안 된다(283 원문과 같은 판단).
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok',                 true,
    'ticket_id',          v_ticket.id,
    'status',             'cancelled',
    'promoted_ticket_id', v_promoted_id
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_event_ticket_admin(uuid, text) IS
  '[288] 관리자 전용 예약 취소. 본인 취소(cancel_event_ticket)와 달리 티켓 소유자 '
  '확인 대신 is_admin() 을 확인하고, 시작 2시간 전 제한이 없다(관리자 판단에 맡김). '
  '이미 입장한 티켓·송금완료 정산이 걸린 티켓은 취소하지 않는다. 대기 승격은 '
  '_promote_next_event_waitlist() 공용 함수로 본인 취소와 동일하게 처리. 취소 사유는 '
  'event_tickets.admin_cancel_note 에만 남기고 사용자에게는 번역된 카테고리 라벨만 노출. '
  '실패는 예외가 아니라 {ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.cancel_event_ticket_admin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_event_ticket_admin(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 함수 존재 확인 (새 함수 2개 + 재정의 3개)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('cancel_event_ticket_admin', '_promote_next_event_waitlist',
--                       '_renumber_event_waitlist', 'cancel_event_ticket', 'reserve_event_ticket')
--  ORDER BY p.proname;
--   → cancel_event_ticket(uuid) 1건 · cancel_event_ticket_admin(uuid,text) 1건 ·
--     _promote_next_event_waitlist(uuid) 1건 · _renumber_event_waitlist(uuid) 1건 ·
--     reserve_event_ticket(uuid,text,timestamptz,jsonb) 1건
--     (오버로드가 생기면 안 된다 — 각 이름당 2건 이상이면 즉시 보고)
--
-- 2) event_tickets 새 컬럼 확인
-- SELECT column_name, data_type FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='event_tickets'
--    AND column_name IN ('cancelled_by','cancelled_by_role','cancelled_by_name','admin_cancel_note')
--  ORDER BY column_name;
--   → 4행
--
-- 3) lookup_values 시드 확인 + 중복 없는지
-- SELECT code, name_ko, name_ja, sort_order, active FROM public.lookup_values
--  WHERE kind = 'cancel_reason' ORDER BY sort_order;
--   → 7행(기존 6 + admin_cancelled). name_ko 가 서로 다른 문구인지 눈으로 확인.
--
-- 4) 형식 확인 (SQL Editor 는 서비스 키라 auth.uid() 가 NULL — is_admin() 가드에
--    막혀 permission_denied 가 나오는 것이 정상. 실제 취소 동작은 방문객·관리자
--    테스트 계정으로 브라우저에서 확인해야 한다 — 283 파일의 같은 함정 참고)
-- SELECT public.cancel_event_ticket_admin('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- 5) ⚠️ 실제 취소·승격·짝이 되는 신청 상태 동기화는 여기서 검증하지 않는다.
--    관리자 로그인 브라우저 세션에서 테스트 계정 3개(확정 1 + 대기 2)로:
--      a. 확정 티켓을 cancel_event_ticket_admin 으로 취소
--      b. 대기 1번 티켓이 confirmed 로 바뀌었는지, 짝이 되는 신청이 approved 로
--         바뀌었는지, event_waitlist_promoted 알림이 갔는지 확인
--      c. 남은 대기 2번 티켓의 waitlist_position 이 1로 당겨졌는지 확인
--      d. 취소된 사람의 응모이력이 「取消」로 보이는지, 취소 상세 모달에
--         「運営によるキャンセル」 카테고리만 보이고 관리자 메모는 안 보이는지 확인
--      e. ⚠️ 별도로: 대기 중인 티켓(확정 아님)을 직접 취소해도 남은 대기자
--         순번이 당겨지는지 확인 — 이 경로는 승격이 안 일어나므로 순번 재정렬만
--         단독으로 도는지가 핵심(초안에서 이 경로만 재정렬이 빠지는 회귀가
--         있었다 — 리뷰 중 발견해 수정, 코드 주석 §3 참고)
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.cancel_event_ticket_admin(uuid, text);
-- -- cancel_event_ticket · reserve_event_ticket 은 각각 283 · 284 정의로 되돌린다
-- --   (해당 파일의 CREATE OR REPLACE 블록을 그대로 재실행)
-- DROP FUNCTION IF EXISTS public._promote_next_event_waitlist(uuid);
-- DROP FUNCTION IF EXISTS public._renumber_event_waitlist(uuid);
-- DELETE FROM public.lookup_values WHERE kind='cancel_reason' AND code='admin_cancelled';
-- ALTER TABLE public.event_tickets
--   DROP COLUMN IF EXISTS admin_cancel_note,
--   DROP COLUMN IF EXISTS cancelled_by_name,
--   DROP COLUMN IF EXISTS cancelled_by_role,
--   DROP COLUMN IF EXISTS cancelled_by;
-- COMMIT;
