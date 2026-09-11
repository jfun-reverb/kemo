-- ============================================================
-- 379_event_selection_pick_reject.sql
-- 비공개 행사, 선착순형과 선정형 중 고르기 — 4/4 (뽑기 · 떨어뜨리기)
-- 사양서: docs/specs/2026-08-24-event-invite-only-selection.md (설계 2·4·5-B)
-- 작업표: docs/specs/2026-08-24-event-invite-only-selection-breakdown.md 「S-4」
-- 선행: 288(cancel_event_ticket_admin — 참고 원형·절대 재정의 안 함) ·
--       289(신청 상태 변경 차단 트리거·bypass 표시) ·
--       317(promote_event_waitlist — 관리자 전용 신규 함수 골격 참고) ·
--       376(event_selection_mode 칸·알림 종류 12종) ·
--       377(승격 두 경로 차단) · 378(선정형 접수 — waitlist·pending·순번NULL)
--
-- 🔴 확정 사항 1·2·4·6·7(작업표 §12, 2026-08-24 사용자 확인)이 그대로 이
--    파일의 설계다. 이 파일은 재정의가 아니라 **신규 함수 2개**만 만든다.
--
-- 이 파일이 만드는 것:
--   [1] public.pick_event_tickets(p_ticket_ids uuid[]) RETURNS jsonb
--       — waitlist → confirmed · 짝이 되는 신청 pending → approved · 당선 알림
--   [2] public.reject_event_tickets(p_ticket_ids uuid[], p_reason_note text)
--       RETURNS jsonb
--       — waitlist → cancelled(예약표) · 짝이 되는 신청 pending → **rejected**
--       (cancelled 아님, 확정 1) + reviewed_at 채움. 앱 알림 없음.
--
-- ── 왜 cancel_event_ticket_admin(288)을 재정의하지 않고 새로 만드나 ──────
--   확정 2. 288 은 「운영진이 취소했다」는 사실을 **일부러 알리도록** 설계된
--   함수다(파일 §688-738 알림 블록, 주석 「본인이 요청한 취소가 아니라
--   운영진이 취소한 것이므로 반드시 알려야 한다」). 선정 탈락은 그 반대다
--   — 확정 1 이 앱 알림을 아예 안 보내기로 했다. 288 을 그대로 재사용하면
--   그 알림 블록이 선정 탈락자에게도 나가 사실과 다른 말(「취소되었습니다」)
--   을 하게 된다. 인자 개수도 다르고(배열 vs 단건) 응모 상태도 반대(rejected
--   vs cancelled)라 분기를 넣는 것보다 새 함수가 안전하다(작업표 §3 권고 1).
--
-- ── 두 표의 상태를 일부러 갈라 둔다 (확정 1·7, 이 파일에서 가장 중요) ────
--   ┌──────────────────┬────────────┬──────────────────────────────────┐
--   │ event_tickets    │ cancelled  │ 330:277-280 묶음 중복 검사가 티켓  │
--   │                  │            │ status 만 보므로, 이래야 다른 날   │
--   │                  │            │ 예약 길이 열린다                  │
--   ├──────────────────┼────────────┼──────────────────────────────────┤
--   │ applications     │ rejected   │ 「落選」 배지가 저절로 뜨고        │
--   │ (cancelled 아님) │ +reviewed_ │ (dev/lib/i18n/ja.js:390 · ui.js:  │
--   │                  │ at         │ 370) 다음날 아침 낙첨 메일을 탄다 │
--   │                  │            │ (notify-influencer-daily-digest)  │
--   └──────────────────┴────────────┴──────────────────────────────────┘
--   🔴 reviewed_at 을 빠뜨리면 메일이 조용히 안 간다 — 그 메일이
--   status IN ('approved','rejected') AND reviewed_at 이 어제 KST 창인
--   것만 담는다(notify-influencer-daily-digest/index.ts:462-465). 오류도
--   안 나고 흔적도 안 남는다.
--   ⚠️ 새 취소 사유 코드를 만들지 않는다(확정 1) — rejected 는 취소가
--   아니므로 cancel_reason_code(취소 전용 칸)를 쓰지 않는다.
--   ⚠️ 앱 알림을 보내지 않는다(확정 1) — 288 의 알림 블록을 옮겨 오지
--   않는다. 일반 모집 낙첨에 앱 알림이 없는 것과 똑같다.
--   ⚠️ 승격을 부르지 않는다 — 선정형이므로 애초에 순번이 없다(378).
--   _promote_next_event_waitlist·_renumber_event_waitlist 어느 쪽도
--   호출하지 않는다(377 이 승격 두 경로를 이미 조기 반환으로 막아 뒀지만,
--   이 함수는 그 함수들을 아예 부르지 않는다 — 부를 이유가 없다).
--
-- ── 당선 알림 — 행사 전용 새 종류 (확정 4) ──────────────────────────
--   기존 application_approved(154)는 「成果物の提出をお願いします」(결과물
--   제출을 요청하는 문구)를 담아 방문객에게 안 맞는다(283 이 행사에서 그
--   알림을 끈 이유와 같다). event_selection_won(376 이 이미 만들어 둔
--   종류)을 써서 결과물·보수 언급 없이 입장 티켓 화면으로 바로 보낸다.
--   클릭 라우팅(iconMap·onNotifItemClick 분기)은 S-9 몫 — 이 파일은
--   ref_table='event_tickets' · ref_id=티켓id 로 재료만 만들어 둔다
--   (event_waitlist_promoted 가 이미 쓰는 같은 패턴, 283/288/377).
--
-- ── 교착(deadlock) 방지 — 타임을 오름차순으로 잠근다 (작업표 §2 ③) ──────
--   관리자가 여러 타임에 걸친 티켓을 한 번에 고를 수 있다(인자가 배열).
--   PostgreSQL 의 FOR UPDATE 는 ORDER BY 와 함께 써도 "정렬된 순서로 잠근다"
--   를 보장하지 않는다(정렬은 잠금 뒤 Sort 노드에서 일어난다) — 그래서 이
--   파일은 **한 행씩 개별 SELECT ... FOR UPDATE 로 반복문을 돌려** 잠그는
--   순서를 코드로 직접 강제한다:
--     1) 대상 **티켓** 행을 오름차순(id)으로 한 건씩 잠근다 — 288 의
--        cancel_event_ticket_admin 과 같은 방향(티켓 먼저, 그다음 슬롯)이라
--        그 함수와의 교착 가능성도 함께 없앤다.
--        🔴 **317(promote_event_waitlist)은 방향이 반대다** — 슬롯을 먼저
--        잠그고(317 함수 본문의 event_slots FOR UPDATE) 그 안에서
--        _promote_next_event_waitlist 가 티켓을 잠근다. 즉 317 은 슬롯→티켓,
--        이 함수는 티켓→슬롯이다.
--        ⚠️ **그런데도 지금 교착이 안 나는 이유는 잠금 방향이 아니라 377 이다**
--        — 377 이 promote_event_waitlist·_promote_next_event_waitlist 양쪽에
--        선정형 조기 반환을 심어, 선정형 타임에서는 317 이 슬롯만 잠그고
--        **티켓 잠금까지 가기 전에 반환**한다(단일 자원이라 순환 대기 불성립).
--        🔴 **377 의 그 조기 반환을 없애거나 선정형에도 정원 채우기 버튼을
--        여는 날, 이 조합은 실제로 교착한다.** 그때는 317 을 티켓→슬롯으로
--        바꾸거나 이 함수를 슬롯→티켓으로 맞춰야 한다. 「방향이 같으니
--        안전하다」로 읽지 말 것 — 방향은 같지 않다.
--     2) (뽑기 함수만) 그 티켓들이 걸린 **타임**을 distinct 로 뽑아 다시
--        오름차순으로 한 건씩 잠근다.
--   두 관리자가 같은 타임들을 반대 순서로 골라도, 실제 잠금은 항상 같은
--   순서(오름차순)로 일어나므로 서로 기다리다 되돌아가는 일이 없다.
--
-- ── 알려진 한계 — 거부 사유를 모으는 방식이 갈린다 ──────────────────
--   존재하지 않는 티켓(not_found)은 **발견 즉시 반환**하고, 상태 불일치
--   (already_confirmed·already_cancelled)와 정원 초과는 **전부 모아서** 반환한다.
--   그래서 한 요청에 「없는 티켓」과 「이미 처리된 티켓」이 섞이면 관리자는
--   앞의 사유만 보고 뒤를 모른다. 화면이 실제로 그려진 목록에서 식별자를
--   보내므로 없는 티켓이 섞일 일은 드물다고 보고 이대로 둔다 — 다만
--   **모르고 이렇게 된 것이 아니라는 것**을 여기 적어 둔다.
--
-- ── 정원 초과 — 전부 거부 + 누구·어느 타임 때문인지 반환 (확정 6) ──────
--   부분 통과를 허용하면 관리자가 "결국 누가 됐는지"를 다시 세어야 한다
--   (작업표 §2 ④). 타임별로 (이미 확정된 수 + 이번에 요청한 수)가 정원을
--   넘으면 그 타임 정보(정원·확정 수·요청 수·남은 자리)를 배열로 돌려주고
--   아무것도 쓰지 않는다 — 관리자가 그 타임에서 몇 명을 빼야 하는지 화면이
--   바로 계산할 수 있다.
--
-- ── 선정형 캠페인의 티켓만 받는다 (설계 0의 서버 절반, 검증 7-B) ────────
--   화면(폼)이 선착순형에서는 뽑기·탈락 버튼을 아예 안 그리는 것이 1차
--   방어선(설계 0 「화면과 서버 양쪽에서 막는다」)이고, 이 함수는 그 2차
--   방어선이다. 대상 티켓이 속한 캠페인이 event_selection_mode='selection'
--   이 아니면 즉시 {ok:false, reason:'not_selection_mode'} 로 거부한다
--   (배치 전체를 한 번에 막는다 — 정상적으로는 한 화면이 한 캠페인의
--   티켓만 모아 부르므로 뒤섞일 일이 없지만, 방어선은 그 전제를 믿지 않는다).
--
-- ── 실행 권한 — 두 방향을 다 회수한다 (2026-08-21 사고 재발 방지) ──────
--   REVOKE ALL ... FROM PUBLIC 만으로는 부족하다 — Supabase 는 새 함수를
--   만들 때 PostgreSQL 기본 PUBLIC 권한과는 **별도로** anon·authenticated
--   에도 자동으로 실행 권한을 부여한다. 두 회수는 서로를 대신하지 못한다
--   (메모리 feedback_function_execute_grants, 마이그레이션 369·370 이
--   이 구멍으로 24개 함수를 닫았다). 이 파일은 처음부터 두 방향을 다
--   회수한 뒤 authenticated 에만 되돌려 준다 — 288·317 이 만들어질 당시
--   (2026-07~08)에는 이 구멍이 아직 발견되지 않아 REVOKE ALL FROM PUBLIC
--   만으로 끝냈는데, 이 파일은 그 구멍을 알고 있는 상태에서 만들어지므로
--   처음부터 두 겹으로 닫는다(288·317 을 소급 수정하는 것은 이 파일의
--   범위가 아니다 — 별도 후속 과제).
--
-- ── 권한 — is_admin() (등급 무관, 작업표 §2 ⑥) ──────────────────────
--   행사 관련 기존 함수(283·288·317)가 전부 is_admin() 하나만 본다. 뽑기·
--   떨어뜨리기도 같은 관례를 따른다 — 등급을 새로 가르면 권한 카탈로그
--   (ADMIN_PERMISSION_CATALOG)에 열쇠말이 늘고 그 화면까지 번진다(작업표
--   §2 ⑥에서 이미 검토·보류된 사항).
--
-- ── 실패 반환 방식 ──────────────────────────────────────────────
--   283·284·288·317 과 같은 방식 — 예외가 아니라 {ok:false, reason:...}.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- [1] pick_event_tickets — 지목한 티켓들을 한 번에 당선 확정
-- ============================================================
CREATE OR REPLACE FUNCTION public.pick_event_tickets(
  p_ticket_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_ids              uuid[];
  v_id               uuid;
  v_ticket           public.event_tickets%ROWTYPE;
  v_mode             text;
  v_inf_name         text;
  v_invalid          jsonb := '[]'::jsonb;
  v_slot_ids         uuid[];
  v_slot_id          uuid;
  v_slot_row         public.event_slots%ROWTYPE;
  v_confirmed_cnt    integer;
  v_requested_cnt    integer;
  v_capacity_issues  jsonb := '[]'::jsonb;
  v_camp_title       text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF p_ticket_ids IS NULL OR array_length(p_ticket_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_input');
  END IF;

  -- 중복 제거 + 오름차순 정렬(잠금 순서를 이 배열 순서 그대로 따른다).
  v_ids := ARRAY(SELECT DISTINCT unnest(p_ticket_ids) ORDER BY 1);

  -- ── 1단계: 대상 티켓을 오름차순으로 한 건씩 잠그며 개별 검증 ────────
  --   쓰기 전에 전수 확인부터 끝낸다(§2 ④ "부분 실패는 전부 거부"). 아직
  --   아무것도 UPDATE 하지 않았으므로 여기서 RETURN 해도 되돌릴 것이 없다.
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT * INTO v_ticket FROM public.event_tickets WHERE id = v_id FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_found', 'ticket_id', v_id);
    END IF;

    SELECT c.event_selection_mode INTO v_mode
      FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

    -- 선정형 캠페인의 티켓만 받는다(설계 0 서버 절반, 검증 7-B).
    IF v_mode IS DISTINCT FROM 'selection' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_selection_mode', 'ticket_id', v_id);
    END IF;

    IF v_ticket.status <> 'waitlist' THEN
      SELECT COALESCE(NULLIF(btrim(COALESCE(i.name_kanji, '')), ''), i.name, i.email)
        INTO v_inf_name
        FROM public.influencers i WHERE i.id = v_ticket.influencer_id;

      v_invalid := v_invalid || jsonb_build_array(jsonb_build_object(
        'ticket_id',       v_id,
        'influencer_name', v_inf_name,
        'reason', CASE v_ticket.status
                    WHEN 'confirmed' THEN 'already_confirmed'
                    WHEN 'cancelled' THEN 'already_cancelled'
                    ELSE 'invalid_status'
                  END
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_invalid) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_tickets', 'tickets', v_invalid);
  END IF;

  -- ── 2단계: 관련 타임을 오름차순으로 한 건씩 잠그고 정원을 확인 ──────
  --   타임 잠금은 반드시 티켓 잠금 **뒤에** 한다(파일 헤더 「교착 방지」).
  v_slot_ids := ARRAY(
    SELECT DISTINCT t.slot_id FROM public.event_tickets t
     WHERE t.id = ANY(v_ids)
     ORDER BY t.slot_id
  );

  FOREACH v_slot_id IN ARRAY v_slot_ids LOOP
    SELECT * INTO v_slot_row FROM public.event_slots WHERE id = v_slot_id FOR UPDATE;

    -- 이미 확정된 수(잠근 뒤에 다시 세므로 동시 처리와 안전하게 직렬화된다)
    SELECT count(*) INTO v_confirmed_cnt
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot_id AND t.status = 'confirmed';

    -- 이번 요청에서 이 타임으로 뽑으려는 수
    SELECT count(*) INTO v_requested_cnt
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot_id AND t.id = ANY(v_ids);

    IF v_confirmed_cnt + v_requested_cnt > v_slot_row.capacity THEN
      v_capacity_issues := v_capacity_issues || jsonb_build_array(jsonb_build_object(
        'slot_id',          v_slot_id,
        'slot_date',        v_slot_row.slot_date,
        'start_time',       v_slot_row.start_time,
        'capacity',         v_slot_row.capacity,
        'already_confirmed', v_confirmed_cnt,
        'requested',        v_requested_cnt,
        'remaining',        GREATEST(v_slot_row.capacity - v_confirmed_cnt, 0)
      ));
    END IF;
  END LOOP;

  -- 정원 초과는 전부 거부 — 누구·어느 타임 때문인지 돌려준다(확정 6).
  IF jsonb_array_length(v_capacity_issues) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'capacity_exceeded', 'slots', v_capacity_issues);
  END IF;

  -- ── 3단계: 통과 — 실제 확정 처리 ───────────────────────────────
  -- [289] 이 UPDATE 두 건(티켓·신청)이 신청 상태 변경 차단 트리거를
  -- 지나가려면 반드시 이 표시가 먼저 서 있어야 한다(317 파일 헤더가 같은
  -- 함정을 기록 — 안 세우면 뽑기 전체가 롤백된다).
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'confirmed',
         waitlist_position = NULL,
         version           = version + 1
   WHERE id = ANY(v_ids);

  UPDATE public.applications a
     SET status = 'approved'
    FROM public.event_tickets t
   WHERE t.id = ANY(v_ids) AND t.application_id = a.id;

  -- ── 당선 알림 — 확정된 티켓마다(확정 4). 실패해도 확정 자체는 되돌리지
  --   않는다(283·288·317 원문과 같은 판단 — "알림은 못 갔지만 당선은
  --   확정됐다"가 반대 경우보다 낫다).
  FOR v_ticket IN SELECT * FROM public.event_tickets WHERE id = ANY(v_ids) LOOP
    BEGIN
      SELECT * INTO v_slot_row FROM public.event_slots WHERE id = v_ticket.slot_id;
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'event_selection_won',
        'event_tickets',
        v_ticket.id,
        '当選のお知らせ',
        COALESCE(v_camp_title, 'イベント')
          || 'に当選しました。'
          || to_char(v_slot_row.slot_date, 'MM月DD日')
          || ' ' || to_char(v_slot_row.start_time, 'HH24:MI')
          || ' にご来場ください。入場チケットからQRコードをご確認いただけます。'
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',              true,
    'confirmed_count', array_length(v_ids, 1),
    'ticket_ids',      to_jsonb(v_ids)
  );
END;
$$;

COMMENT ON FUNCTION public.pick_event_tickets(uuid[]) IS
  '[379] 관리자 전용. 선정형 행사 캠페인에서 심사중(waitlist)인 티켓들을 지목해 '
  '한 번에 당선(confirmed)으로 확정한다. 짝이 되는 신청도 approved 로, 당선 알림'
  '(event_selection_won, 376)도 티켓마다 발송. 타임을 오름차순으로 잠근 뒤 정원'
  '(확정 수 + 이번 요청 수 ≤ capacity)을 확인해 넘치면 전부 거부하고 어느 타임에서'
  '몇 명이 넘쳤는지 반환한다(부분 통과 없음). 선정형이 아닌 캠페인의 티켓·이미'
  '확정·취소된 티켓·존재하지 않는 티켓은 각각 다른 reason 으로 거부. 실패는 예외가'
  '아니라 {ok:false, reason:...}. 승격 함수(_promote_next_event_waitlist 등)는'
  '부르지 않는다 — 선정형은 순번이 없다(378).';

REVOKE ALL ON FUNCTION public.pick_event_tickets(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pick_event_tickets(uuid[]) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pick_event_tickets(uuid[]) TO authenticated;

-- ============================================================
-- [2] reject_event_tickets — 지목한 티켓들을 한 번에 탈락 처리
-- ============================================================
CREATE OR REPLACE FUNCTION public.reject_event_tickets(
  p_ticket_ids  uuid[],
  p_reason_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_ids         uuid[];
  v_id          uuid;
  v_ticket      public.event_tickets%ROWTYPE;
  v_mode        text;
  v_inf_name    text;
  v_admin_name  text;
  v_note        text;
  v_invalid     jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF p_ticket_ids IS NULL OR array_length(p_ticket_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_input');
  END IF;

  v_ids := ARRAY(SELECT DISTINCT unnest(p_ticket_ids) ORDER BY 1);

  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  v_note := NULLIF(btrim(COALESCE(p_reason_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_note := left(v_note, 500);
  END IF;

  -- ── 1단계: 대상 티켓을 오름차순으로 한 건씩 잠그며 개별 검증 ────────
  --   떨어뜨리기는 슬롯 정원과 무관해 타임을 잠글 필요가 없다(뽑기와의
  --   차이). waitlist 상태만 받는다 — 이미 confirmed 된 티켓을 취소하려면
  --   cancel_event_ticket_admin(288, 손대지 않음)을 쓴다.
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT * INTO v_ticket FROM public.event_tickets WHERE id = v_id FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_found', 'ticket_id', v_id);
    END IF;

    SELECT c.event_selection_mode INTO v_mode
      FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

    IF v_mode IS DISTINCT FROM 'selection' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_selection_mode', 'ticket_id', v_id);
    END IF;

    IF v_ticket.status <> 'waitlist' THEN
      SELECT COALESCE(NULLIF(btrim(COALESCE(i.name_kanji, '')), ''), i.name, i.email)
        INTO v_inf_name
        FROM public.influencers i WHERE i.id = v_ticket.influencer_id;

      v_invalid := v_invalid || jsonb_build_array(jsonb_build_object(
        'ticket_id',       v_id,
        'influencer_name', v_inf_name,
        'reason', CASE v_ticket.status
                    WHEN 'confirmed' THEN 'already_confirmed'
                    WHEN 'cancelled' THEN 'already_cancelled'
                    ELSE 'invalid_status'
                  END
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_invalid) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_tickets', 'tickets', v_invalid);
  END IF;

  -- ── 2단계: 통과 — 실제 탈락 처리. 두 표 상태를 일부러 갈라 둔다 ──────
  --   (파일 헤더 표 참고 — event_tickets=cancelled, applications=rejected)
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
   WHERE id = ANY(v_ids);

  -- 🔴 cancelled 가 아니라 rejected(확정 1) + reviewed_at — 다음날 아침
  -- 낙첨 메일(notify-influencer-daily-digest)이 이 칸의 창으로 대상을
  -- 고른다. cancel_reason_code 는 일부러 안 채운다 — 취소 전용 칸이다.
  UPDATE public.applications a
     SET status      = 'rejected',
         reviewed_by = COALESCE(v_admin_name, '(이름미상)'),
         reviewed_at = now()
    FROM public.event_tickets t
   WHERE t.id = ANY(v_ids) AND t.application_id = a.id;

  -- 🔴 앱 알림은 보내지 않는다(확정 1) — 288 의 알림 블록을 옮겨 오지
  -- 않는다. 통지는 다음날 아침 응모 결과 메일이 맡는다.

  RETURN jsonb_build_object(
    'ok',              true,
    'rejected_count',  array_length(v_ids, 1),
    'ticket_ids',      to_jsonb(v_ids)
  );
END;
$$;

COMMENT ON FUNCTION public.reject_event_tickets(uuid[], text) IS
  '[379] 관리자 전용. 선정형 행사 캠페인에서 심사중(waitlist)인 티켓들을 지목해 '
  '한 번에 탈락 처리한다. event_tickets 는 cancelled(다른 날 재예약 길을 열기 '
  '위해 — 330 묶음 중복 검사가 티켓 status 만 본다), applications 는 cancelled 가 '
  '아니라 rejected + reviewed_at(확정 1 — 落選 배지가 저절로 뜨고 다음날 아침 '
  '낙첨 메일을 탄다). 새 취소 사유 코드도 앱 알림도 만들지 않는다(일반 모집 낙첨과 '
  '동일). 관리자 메모는 event_tickets.admin_cancel_note 에만(최대 500자, 선택). '
  'cancel_event_ticket_admin(288)과 달리 이 함수가 만들어졌다 — 그 함수는 취소 '
  '알림을 일부러 보내도록 설계돼 있어 재사용하면 확정 1 과 부딪힌다(파일 헤더 '
  '참고). waitlist 가 아닌(이미 confirmed·cancelled 로 처리된) 티켓은 거부한다 — '
  'confirmed 된 티켓을 취소하려면 cancel_event_ticket_admin(288)을 쓴다(entered_at 은 '
  'confirmed 상태에서만 채워지므로 waitlist 한정 검증만으로 이미 방어된다, 304). '
  '실패는 예외가 아니라 {ok:false, reason:...}.';

REVOKE ALL ON FUNCTION public.reject_event_tickets(uuid[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_event_tickets(uuid[], text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reject_event_tickets(uuid[], text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (1단계씩 — 결과 확인 후 다음 단계로. .claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ============================================================
--
-- [1단계] 함수 2개가 각각 오버로드 없이 생성됐는지 (SQL 편집기, 서비스
--   키로 실행 가능 — 로그인 세션 불필요)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('pick_event_tickets', 'reject_event_tickets')
--  ORDER BY p.proname;
--   → 2건, 이름당 1건씩:
--     pick_event_tickets(uuid[])
--     reject_event_tickets(uuid[], text)
--
-- [2단계] 실행 권한 — 두 방향(PUBLIC·anon)이 다 회수됐는지 직접 확인한다.
--   ⚠️ has_function_privilege 만 보면 방향을 구분 못 한다. proacl 의 맨 앞
--   "=X/" 유무를 함께 볼 것(있으면 PUBLIC 에게도 권한이 남아 있다는 뜻 —
--   있으면 안 된다).
-- SELECT p.proname,
--        p.proacl::text AS acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authed_can
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('pick_event_tickets', 'reject_event_tickets');
--   → 둘 다: acl 에 "=X/" 없음, anon_can=false, authed_can=true
--
-- [3단계] 🔴 관리자 가드가 걸려 있어 SQL 편집기(서비스 키)로는 실제 동작을
--   재현할 수 없다 — auth.uid() 가 비어 있어 permission_denied 로만 답한다.
--   여기서부터는 개발서버에 준비한 시험 캠페인(비공개+선정형, T2)과
--   실제 로그인한 관리자 브라우저 콘솔에서 확인한다:
--
--   const {data} = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<waitlist 티켓 id>']});
--   console.log(data);
--     → {ok:true, confirmed_count:1, ticket_ids:[...]}
--
--   -- 검증 7: 여러 명을 한 번에 뽑으면 전부 confirmed + 짝 신청 approved
--   --         + notifications 에 event_selection_won 이 인원 수만큼 생김
--   SELECT id, status, waitlist_position FROM public.event_tickets WHERE id = ANY(ARRAY['<id1>','<id2>']::uuid[]);
--   SELECT id, status, reviewed_by, reviewed_at FROM public.applications WHERE id IN (SELECT application_id FROM public.event_tickets WHERE id = ANY(ARRAY['<id1>','<id2>']::uuid[]));
--   SELECT kind, ref_id, title FROM public.notifications WHERE kind='event_selection_won' ORDER BY created_at DESC LIMIT 5;
--
--   -- 🔴 검증 8: 정원을 넘겨 뽑으면 전부 거부(부분 통과 아님)
--   const r = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<정원 넘게 고른 waitlist id 여러 개>']});
--   console.log(r.data);
--     → {ok:false, reason:'capacity_exceeded', slots:[{slot_id,...,remaining:N}]}
--     → 위 event_tickets SELECT 로 실제 status 가 하나도 안 바뀌었는지 재확인
--
--   -- 🔴 검증 7-B(회귀): 선착순형 캠페인의 티켓을 넣으면 서버가 거부하는지
--   --   (검증 17 은 화면 버튼이 안 뜨는지만 본다 — 이건 그 서버 절반)
--   const r2 = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<선착순형 confirmed/waitlist 티켓 id>']});
--   console.log(r2.data);  -- → {ok:false, reason:'not_selection_mode', ticket_id:...}
--
--   -- 🔴 검증 12: reject_event_tickets — 떨어뜨리면 응모가 rejected +
--   --   reviewed_at 채워짐(메모는 선택이라 없어도 정상)
--   const r3 = await db.rpc('reject_event_tickets', {p_ticket_ids: ['<waitlist 티켓 id>'], p_reason_note: null});
--   console.log(r3.data);  -- → {ok:true, rejected_count:1, ...}
--
--   -- 🔴 검증 12-B: 두 표가 갈려 있는지 각각 확인(같아지면 둘 중 하나가 깨진 것)
--   SELECT status, admin_cancel_note FROM public.event_tickets WHERE id = '<위 티켓 id>';
--     → status='cancelled'
--   SELECT status, reviewed_at FROM public.applications WHERE id = (SELECT application_id FROM public.event_tickets WHERE id='<위 티켓 id>');
--     → status='rejected', reviewed_at NOT NULL
--
--   -- 검증 13: 떨어뜨린 사람이 다른 날(같은 캠페인의 다른 타임)을 다시
--   --   예약할 수 있다 — reserve_event_ticket(378) 을 그 사람 로그인으로
--   --   다시 호출해 성공하는지 확인
--
--   -- 🔴 떨어뜨린 직후 그 사람의 알림 목록에 아무것도 안 늘어난 것 확인
--   SELECT count(*) FROM public.notifications WHERE user_id = '<탈락자 influencer id>' AND created_at > now() - interval '5 minutes';
--     → reject_event_tickets 호출 전후로 건수 변화 없어야 한다
--
--   -- 🔴 검증 14-D(다음날 아침 낙첨 메일): 발송 없이 확인하려면 같은 조건을
--   --   데이터로 재현한다(2026-08-07 마감 안내 검증에서 쓴 방법과 동일 —
--   --   개발서버 실제 발송 금지, .claude/rules/supabase.md). 위 reviewed_at
--   --   이 어제 KST 09:00 이전 창에 들어오는 값인지 계산해 확인:
--   SELECT id, status, reviewed_at,
--          reviewed_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') - interval '1 day') AT TIME ZONE 'Asia/Seoul'
--            AND reviewed_at < date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') AT TIME ZONE 'Asia/Seoul'
--            AS in_yesterday_window
--     FROM public.applications
--    WHERE id = '<위 신청 id>';
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ 가장 위험한 되돌리기: 아래 DROP 을 실행해도 **이미 확정된 티켓·승인된
--    신청·이미 탈락 처리된 티켓/신청은 그대로 남는다.** 함수만 사라지고
--    데이터는 안 돌아온다 — 되돌린 뒤 그 캠페인의 티켓 상태를 사람이
--    확인해야 한다(작업표 §13 「가장 위험한 되돌리기」).
--
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.pick_event_tickets(uuid[]);
-- DROP FUNCTION IF EXISTS public.reject_event_tickets(uuid[], text);
-- COMMIT;
--
-- NOTIFY pgrst, 'reload schema';
