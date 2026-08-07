-- ============================================================
-- 317_promote_event_waitlist.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 정원을 늘렸을 때 대기자를 순번대로
-- 확정으로 올리는 관리자 전용 함수.
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §2-1
-- 선행: 280~289(오프라인 예약 기본 골격, 특히 283 예약/취소/입장 함수 ·
--       288 대기 승격 공용 함수 분리 · 289 신청 상태 변경 차단 트리거) ·
--       316(정원 계산의 현재 유효한 기준)
--
-- ── 왜 필요한가 (감사 §2-1) ──────────────────────────────────────
--   지금까지 대기자를 확정으로 올리는 유일한 경로는 「확정자가 취소한다」
--   뿐이었다 — 대기 승격을 부르는 곳이 cancel_event_ticket(본인 취소)·
--   cancel_event_ticket_admin(관리자 취소) 두 곳뿐이다(둘 다 283→288).
--   정원 칸을 늘려도(dev/js/admin-event.js:757 onEventSlotCapacityChange)
--   승격을 부르는 코드가 없어, 현장에서 「이 타임 10명 더 받자」가 화면에서
--   안 된다 — 대기자는 계속 대기, 알림도 안 간다. 확정자가 취소해야만
--   1명씩 올라간다. 이 파일이 그 수단을 만든다.
--
-- ── 재정의 기준 (요청사항 ① — 전수 grep 확인) ─────────────────────
--   cancel_event_ticket 의 정의·재정의 이력을 전수 확인했다:
--     283(최초 생성) → 288(재정의 — 승격 로직을 공용 함수 2개로 분리,
--     **현재 유효**) 까지가 전부다. 289·304·314·316 은 이 함수를 **언급만**
--     하고 재정의하지 않는다:
--       289 — 취소 함수가 세우는 bypass 표시를 "읽기"만 한다(applications
--             상태 변경 차단 트리거).
--       304 — check_in_ticket 만 재정의(입장 확인 범위 가드).
--       314 — applications BEFORE INSERT 트리거 신설(이 함수와 무관 —
--             아래 「신청 행 상태」 절 참고).
--       316 — reserve_event_ticket 만 재정의(정원 계산 기준은 여기서
--             확정. cancel_event_ticket 은 289 파일 헤더 §③에서 "무변경"
--             으로 명시됨).
--   즉 승격 로직의 현재 유효한 원본은 288 이 만든
--   public._promote_next_event_waitlist(uuid) / public._renumber_event_waitlist(uuid)
--   이고, 이 파일은 그 두 함수를 **한 글자도 바꾸지 않고 그대로 호출**한다
--   (288 파일 헤더 「복사 금지(요청사항)」와 동일한 이유 — 승격 로직을
--   두 곳에 복사하면 한쪽만 고쳐지는 사고를 막기 위함).
--
-- ── event_waitlist_promoted 알림이 실제로 어떻게 만들어지는가 (요청사항 ②) ──
--   283 파일 헤더가 이미 적어 둔 대로: 「트리거는 행사에서 조기 반환하므로
--   안 나간다. 그래서 취소 함수가 직접 알림을 넣는다」(283 파일 헤더 16행).
--   public._promote_next_event_waitlist(288:187-210) 가 바로 그 "직접
--   넣는" 코드이고, 이 파일은 그 함수를 그대로 호출하므로 **같은 알림
--   종류(event_waitlist_promoted)·같은 문구**가 그대로 나간다. 이 파일은
--   별도로 알림을 만들지 않는다(중복 발송 방지 — 알림은 딱 한 군데,
--   _promote_next_event_waitlist 안에서만 INSERT 된다).
--
-- ── 신청 행(applications) 상태도 함께 바뀌는가 (요청사항 ③ — 확인 결과) ──
--   그렇다. public._promote_next_event_waitlist(288:181-185) 가 승격된
--   티켓의 application_id 가 있으면 그 신청을 **직접** approved 로
--   UPDATE 한다(대기="pending" 이었던 신청이 확정="approved" 로 바뀐다 —
--   283 설계, 288 파일 헤더 「짝이 되는 신청 행」 절과 동일).
--   이 UPDATE 는 289(신청 상태 변경 차단 트리거, trg_guard_event_
--   application_status_change)를 지나가야 하므로, 288의 기존 두 함수
--   (cancel_event_ticket · cancel_event_ticket_admin)와 똑같이 **호출
--   전에 bypass 표시를 세워야 한다** — 세우지 않으면 289 트리거가
--   'event_status_change_blocked' 예외를 던지고, 행 단위 트리거의 예외는
--   그 UPDATE 문 전체를 롤백시킨다(289 파일 헤더 44-52행과 같은 성질 —
--   _promote_next_event_waitlist 안의 티켓 UPDATE 까지 함께 되돌아가
--   **승격 자체가 통째로 실패**한다). 이 파일은 반복 승격을 시작하기
--   전에 딱 한 번 `PERFORM set_config('reverb.event_ticket_bypass', 'on',
--   true)` 를 세운다(트랜잭션 범위 설정이라 반복 호출 전체에 적용됨 —
--   288/316 의 기존 함수들과 동일한 관례).
--   314(응모 삽입 상태 강제)는 BEFORE **INSERT** 트리거라 이 함수처럼
--   **기존** 신청 행을 UPDATE 만 하는 경로에는 애초에 관여하지 않는다
--   (314 파일 헤더 「영향받지 않는 것」 절 확인 — INSERT 시에만 발동).
--
-- ── 이 파일이 만드는 것 ───────────────────────────────────────────
--   public.promote_event_waitlist(p_slot_id uuid) — 관리자 전용. 그
--   타임의 남은 자리(정원 - 확정 인원)만큼 대기 1번부터 순서대로
--   확정시킨다. 기존 함수(288)는 한 글자도 바꾸지 않는다.
--
-- ── 정원 계산 기준 (요청사항 ② — reserve_event_ticket 과 동일) ──────
--   reserve_event_ticket(288/316)과 똑같이 "그 타임의 status='confirmed'
--   건수" 로 확정 인원을 센다(대기·취소는 정원에 안 잡힌다 — 이 프로젝트의
--   정원 판정 기준, 281 헤더 「정원 판정은 이 표의 값이 한다」). 남은
--   자리 = GREATEST(capacity - 확정 인원, 0).
--
-- ── 여러 명을 한 번에 승격 (요구사항 2) ────────────────────────────
--   _promote_next_event_waitlist 는 한 번에 대기 1번만 올린다(288 설계 —
--   함수 이름 자체가 "next" 하나). 이 파일은 남은 자리 수만큼 그 함수를
--   반복 호출한다. 매 반복이 "그 시점 대기 1번(waitlist_position 이
--   가장 작은 사람, 동순위면 created_at 이 빠른 사람)"만 골라 확정시키므로
--   반복 호출 자체가 "순번대로" 를 보장한다 — 중간에 순번을 다시 매길
--   필요가 없다(승격된 사람이 빠져도 나머지는 이미 오름차순이라 다음
--   반복이 자연히 그다음 사람을 고른다). 순번 재정렬
--   (_renumber_event_waitlist)은 **반복이 다 끝난 뒤 한 번만** 호출한다 —
--   남은 대기자의 waitlist_position 을 1부터 다시 매겨 빈 앞자리를
--   없앤다(283/288 의 취소 함수도 같은 순서 — 승격은 조건부, 재정렬은
--   승격 여부와 무관하게 항상 마지막에 한 번. 288 파일 §3 주석 참고).
--
-- ── 행 잠금 (요구사항 4) ────────────────────────────────────────────
--   reserve_event_ticket(288/316)과 같은 방식 — 타임(event_slots) 행을
--   FOR UPDATE 로 잠근 뒤 정원을 센다. 동시에 두 관리자가 같은 타임의
--   정원을 늘리며 이 함수를 부르는 경우를 이 잠금으로 직렬화한다(정원
--   변경 자체는 이 함수가 아니라 upsertEventSlot 이 먼저 저장하고, 이
--   함수는 그 뒤에 불린다 — 화면 호출 순서는 파일 하단 「화면 연결」
--   참고).
--
-- ── 권한 (요구사항 3) ────────────────────────────────────────────
--   public.is_admin() 만 통과. cancel_event_ticket_admin(288) 과 동일한
--   가드 — 관리자 등급을 더 세분화하지 않는다(정원 변경 화면 자체가
--   campaign_admin 이상 화면이라 이 함수만 별도로 더 좁힐 이유가 없다).
--   방문객(인플루언서) 계정은 permission_denied 로 막힌다.
--
-- ── 실패 반환 방식 (요구사항 5) ─────────────────────────────────────
--   283·284·287·288·316 과 같은 방식 — 예외가 아니라 {ok:false, reason:...}.
--   대기자가 없거나 남은 자리가 0 이어도 **실패가 아니다** — {ok:true,
--   promoted:0, ...} 로 반환한다(정상적으로 "올릴 사람이 없었다"는 결과 —
--   관리자가 정원을 안 늘렸는데 이 함수를 눌러도 오류가 아니어야 한다).
--
-- ── 알림 (요구사항 6) ────────────────────────────────────────────
--   승격된 사람 각각에게 나간다 — _promote_next_event_waitlist 를 승격
--   인원 수만큼 반복 호출하므로, 그 함수 안의 알림 INSERT 도 승격 인원
--   수만큼 각자에게 실행된다(283 이 하는 방식 그대로, 새 코드 없음).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.promote_event_waitlist(
  p_slot_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid             uuid := auth.uid();
  v_slot            public.event_slots%ROWTYPE;
  v_confirmed_cnt   integer;
  v_remaining_cap   integer;
  v_promoted_id     uuid;
  v_promoted_ids    uuid[] := '{}';
  v_promoted_count  integer := 0;
  v_still_waiting   integer;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  SELECT * INTO v_slot
    FROM public.event_slots
   WHERE id = p_slot_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- ── 정원 판정 (reserve_event_ticket 288/316 과 같은 기준) ────────
  SELECT count(*) INTO v_confirmed_cnt
    FROM public.event_tickets t
   WHERE t.slot_id = v_slot.id
     AND t.status  = 'confirmed';

  v_remaining_cap := GREATEST(v_slot.capacity - v_confirmed_cnt, 0);

  -- [317] 이어지는 승격 UPDATE(_promote_next_event_waitlist 안에서 신청
  --   상태를 approved 로 바꾸는 UPDATE)가 289 의 차단 트리거를 지나가려면
  --   이 표시가 필요하다 — 288 의 두 취소 함수와 같은 장치를 재사용한다
  --   (새 표시를 만들지 않는다). 트랜잭션 범위 설정이라 아래 반복 호출
  --   전체에 한 번으로 적용된다.
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  -- ── 남은 자리 수만큼, 대기 1번부터 순서대로 반복 승격 ────────────
  --   매 반복이 그 시점의 대기 1번만 고르므로 순서는 자동으로 보장된다
  --   (파일 헤더 「여러 명을 한 번에 승격」 절 참고).
  WHILE v_promoted_count < v_remaining_cap LOOP
    v_promoted_id := public._promote_next_event_waitlist(v_slot.id);
    EXIT WHEN v_promoted_id IS NULL;  -- 더 이상 대기자가 없음 — 정상 종료

    v_promoted_count := v_promoted_count + 1;
    v_promoted_ids   := array_append(v_promoted_ids, v_promoted_id);
  END LOOP;

  -- ── 순번 재정렬 — 승격 인원(0명 포함)과 무관하게 항상 한 번
  --   (283/288 의 취소 함수와 동일 관례 — 파일 헤더 참고) ──────────
  PERFORM public._renumber_event_waitlist(v_slot.id);

  SELECT count(*) INTO v_still_waiting
    FROM public.event_tickets t
   WHERE t.slot_id = v_slot.id
     AND t.status  = 'waitlist';

  RETURN jsonb_build_object(
    'ok',                  true,
    'slot_id',             v_slot.id,
    'promoted',            v_promoted_count,
    'promoted_ticket_ids', to_jsonb(v_promoted_ids),
    'remaining_capacity',  GREATEST(v_remaining_cap - v_promoted_count, 0),
    'still_waiting',       v_still_waiting
  );
END;
$$;

COMMENT ON FUNCTION public.promote_event_waitlist(uuid) IS
  '[317] 관리자 전용. 타임(p_slot_id)의 남은 자리(정원-확정 인원)만큼 대기자를 '
  '순번대로 확정 승격시킨다. reserve_event_ticket(288/316)과 같은 정원 판정 기준, '
  '_promote_next_event_waitlist(288)/_renumber_event_waitlist(288)를 그대로 재사용 '
  '(복사 없음) — 승격 로직·알림(event_waitlist_promoted)·신청 상태 동기화가 취소 '
  '경로(cancel_event_ticket·cancel_event_ticket_admin)와 항상 같다. 대기자가 없거나 '
  '남은 자리가 0 이어도 실패가 아니라 {ok:true, promoted:0, ...} 를 반환한다. 실패는 '
  '예외가 아니라 {ok:false, reason:...}(permission_denied·not_found). 조사 '
  'docs/research/2026-08-07-codebase-audit-findings.md §2-1.';

REVOKE ALL ON FUNCTION public.promote_event_waitlist(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promote_event_waitlist(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 화면 연결 (참고 — 실제 화면 코드는 이 마이그레이션의 범위가 아니다)
-- ============================================================
-- dev/js/admin-event.js 의 onEventSlotCapacityChange(slotId, value)가
-- 정원을 upsertEventSlot() 으로 저장한 **직후** promoteEventWaitlist(slotId)
-- 를 부르면 된다(storage.js 에 새 함수 promoteEventWaitlist(slotId) 추가
-- 필요 — reserveEventTicket/cancelEventTicket 과 같은 패턴으로
-- db.rpc('promote_event_waitlist', {p_slot_id: slotId}) 래핑).
-- 정원을 늘린 경우에만 승격 대상이 생기므로, 값이 늘어났을 때만 불러도
-- 되고(요청 낭비 방지) 항상 불러도 무해하다(대기자가 없거나 자리가 없으면
-- promoted:0 으로 조용히 끝난다). 응답의 promoted 수를 토스트로
-- 안내하면(예: "정원을 저장했습니다 · 대기자 2명이 확정으로 올라갔습니다")
-- 운영자가 결과를 바로 알 수 있다.
--
-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- (.claude/rules/supabase.md 「SQL 검증 순차 안내」)
-- ============================================================
-- [1단계] 함수 존재·시그니처 확인 (SQL 편집기, 서비스 키로 실행 가능 —
--   이 단계는 로그인 세션이 필요 없다)
-- SELECT p.oid::regprocedure AS signature, p.prosecdef
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'promote_event_waitlist';
--   → promote_event_waitlist(uuid) 1건만, prosecdef=true
--   (오버로드가 생기면 안 된다 — 2건 이상이면 즉시 중단하고 보고)
--
-- [2단계] 형식 확인 (SQL 편집기는 서비스 키라 auth.uid() 가 NULL —
--   permission_denied 가 정상. 이 단계까지는 SQL 편집기로 가능)
-- SELECT public.promote_event_waitlist('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- [3단계] ⚠️ 이 함수는 관리자 로그인 세션(auth.uid() + is_admin())이 필요해
--   SQL 편집기로는 실제 승격 동작을 검증할 수 없다(283/288/316 파일의 같은
--   함정 참고). 여기서부터는 반드시 실제 로그인 세션(관리자 계정 + 테스트
--   인플루언서 계정 2~3개, 개발서버 브라우저)으로 확인한다:
--
--   준비: 정원 1인 타임을 만들고 테스트 인플루언서 계정 2개로 예약해
--     확정 1 · 대기 1 상태를 만든다(이미 그런 타임이 있으면 재사용).
--
--   a. 대기자가 있는 상태에서 정원을 늘리고 승격 호출
--      관리자 로그인 브라우저 콘솔에서 먼저 정원을 늘린다:
--        `UPDATE 는 화면(정원 입력칸)으로 하거나, 콘솔에서
--         await window.db.from('event_slots').update({capacity:2}).eq('id','<타임id>')`
--      그 다음 승격 함수를 직접 호출한다:
--        `await window.db.rpc('promote_event_waitlist', {p_slot_id:'<타임id>'})`
--      → `{ok:true, promoted:1, promoted_ticket_ids:[...],
--          remaining_capacity:0, still_waiting:0}` 이어야 한다.
--
--   b. 짝이 되는 신청 행 확인
--      SELECT status FROM public.applications WHERE id = (
--        SELECT application_id FROM public.event_tickets
--         WHERE id = '<위에서 나온 promoted_ticket_ids[0]>'
--      );
--      → 'approved' 여야 한다(승격 전엔 'pending' 이었을 것).
--
--   c. 알림 확인
--      SELECT kind, title FROM public.notifications
--       WHERE ref_table='event_tickets' AND ref_id = '<위 티켓 id>'
--       ORDER BY created_at DESC LIMIT 1;
--      → kind='event_waitlist_promoted' 1행. 해당 테스트 인플루언서
--        계정으로 로그인해 앱 알림 벨에도 떴는지 확인.
--
--   d. 대기자가 정원 증가분보다 많을 때 — 여러 명 승격
--      대기 3명이 있는 타임의 정원을 3명 더 늘려 호출 → `promoted:3` 이고,
--      순번(waitlist_position)이 가장 작던 3명이 순서대로(먼저 신청한
--      사람부터) 확정됐는지 event_tickets.created_at 과 대조해 확인.
--
--   e. 남은 자리보다 대기자가 적을 때
--      대기 1명뿐인 타임의 정원을 5명 늘려 호출 → `promoted:1,
--      remaining_capacity:4`(더 승격할 사람이 없어 4자리는 그대로 빈 채
--      남는다 — 오류 아님).
--
--   f. 남은 자리가 없을 때(정원 그대로)
--      대기자가 있어도 정원을 안 늘린 타임에 호출 → `promoted:0`
--      (기존 대기자는 그대로 대기 상태 유지, 오류 아님).
--
--   g. 순번 재정렬 확인
--      d 이후 남은 대기자의 waitlist_position 이 1부터 다시 매겨졌는지:
--      SELECT waitlist_position FROM public.event_tickets
--       WHERE slot_id='<타임id>' AND status='waitlist'
--       ORDER BY waitlist_position;
--      → 1, 2, 3 … 처럼 빈 구멍 없이 연속이어야 한다.
--
--   h. 관리자 아닌 계정으로 호출 시 차단
--      일반 인플루언서 계정 로그인 콘솔에서 같은 호출 →
--      `{ok:false, reason:'permission_denied'}`.
--
--   i. 동시 호출 방어(선택 — 급하지 않으면 생략 가능)
--      같은 타임에 정원을 늘린 채 두 관리자 브라우저에서 거의 동시에
--      promote_event_waitlist 를 부르면, 뒤에 도착한 호출이 앞선 호출이
--      끝날 때까지 기다렸다가(FOR UPDATE 잠금) 이미 자리가 찬 뒤의
--      상태로 계산해 promoted:0 을 내는지 확인(중복 승격 방지).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.promote_event_waitlist(uuid);
-- COMMIT;
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
