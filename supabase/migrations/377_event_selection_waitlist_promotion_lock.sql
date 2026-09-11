-- ============================================================
-- 377_event_selection_waitlist_promotion_lock.sql
-- 비공개 행사, 선착순형과 선정형 중 고르기 — 2/4 (승격 두 경로 차단)
-- 사양서: docs/specs/2026-08-24-event-invite-only-selection.md (설계 3)
-- 작업표: docs/specs/2026-08-24-event-invite-only-selection-breakdown.md 「S-2」
-- 선행: 288(_promote_next_event_waitlist·_renumber_event_waitlist 최초 정의) ·
--       317(promote_event_waitlist 최초 정의) · 369(_promote_next_event_waitlist
--       실행 권한 회수) · 376(event_selection_mode 칸 — 이 파일이 참조)
--
-- 🔴 이 파일이 S-3(선정형 접수, reserve_event_ticket 재정의)보다 먼저 들어가야
--    하는 이유(작업표 §4-6): S-3만 먼저 넣으면 선정형 심사중 티켓이 쌓이는
--    구간에 확정자가 취소할 경우 "안 뽑은 사람"이 순번대로 자동 확정된다.
--    이 파일을 먼저 넣어 그 구멍을 미리 막는다.
--
-- 이 파일이 만드는 것 — 재정의 딱 둘:
--   [1] public._promote_next_event_waitlist(uuid) 재정의(베이스 288, 현재
--       유효한 원본 — 369 는 실행 권한만 회수했을 뿐 본문을 재정의하지
--       않았다) — 함수 맨 앞에서 그 타임의 캠페인이 선정형이면 아무것도
--       안 하고 NULL 을 반환한다(대기자가 없을 때와 같은 반환값 — 호출부는
--       "승격할 사람이 없었다"로 자연스럽게 읽는다).
--   [2] public.promote_event_waitlist(uuid) 재정의(베이스 317, 유일한 정의) —
--       선정형이면 {ok:false, reason:'selection_mode'} 로 거부한다.
--
-- 🔴 막는 곳은 [1] 공용 함수 한 곳뿐이다. 호출부(cancel_event_ticket·
--    cancel_event_ticket_admin) 두 곳을 각각 고치지 않는다 — 호출부가
--    늘어나는 날 또 새기 때문이다(작업표 §9 S-2 "주의").
--
-- ⚠️ public._renumber_event_waitlist(uuid) 는 이 파일에서 **건드리지 않는다**.
--    선정형은 waitlist_position 을 애초에 안 채우므로(설계 1, 이 파일보다
--    뒤에 들어올 S-3 몫) 그 함수가 돌아도 재정렬할 대상이 없어 아무 일도
--    안 한다. 반대로 이 함수까지 함께 막으면 **선착순형에서 대기 티켓을
--    직접 취소했을 때 뒷사람 순번이 안 당겨지는 회귀**가 생긴다 — 288 이
--    승격(_promote_next_event_waitlist)과 재정렬(_renumber_event_waitlist)을
--    일부러 두 함수로 나눈 이유가 정확히 이것이다(288 파일 §3 코드 주석 —
--    "하나로 합쳐 승격 블록 안에서만 재정렬하면 대기 중인 티켓이 직접
--    취소될 때 남은 대기자 순번에 구멍이 생기는 회귀가 생긴다. 최초 초안에서
--    실제로 이 실수를 했다가 리뷰 중 발견해 둘로 나눴다"). 같은 실수를
--    반복하지 않는다.
--
-- 실행 권한 — 재정의 방식과 보존:
--   두 함수 다 시그니처(인자·반환형) 불변 → CREATE OR REPLACE 로 충분하며
--   DROP 이 필요 없다. PostgreSQL 은 CREATE OR REPLACE 시 함수 본문만
--   바뀌고 실행 권한(GRANT/REVOKE 로 쌓인 ACL)은 그대로 보존된다 — 이
--   파일은 그 성질에 기대어 REVOKE/GRANT 문을 다시 쓰지 않는다.
--   ⚠️ _promote_next_event_waitlist 는 두 겹으로 닫혀 있다:
--     · 288 — REVOKE ALL ... FROM PUBLIC
--     · 369 — REVOKE EXECUTE ... FROM anon, authenticated
--   이 두 REVOKE 를 CREATE OR REPLACE 로 다시 쓰지 않고 그대로 둔다.
--   되살리려면(DROP 후 재생성 등) 두 방향을 **둘 다** 다시 걸어야 한다
--   — 이 저장소는 2026-08-21 에 "FROM PUBLIC 회수"와 "FROM anon,
--   authenticated 회수"가 서로를 대신하지 못한다는 것을 실측으로 확인했다
--   (메모리 feedback_function_execute_grants). 이 파일은 DROP 을 쓰지
--   않으므로 이 위험 자체가 없다.
--   promote_event_waitlist(317)는 애초에 "내부 전용"이 아니라 화면이 직접
--   부르는 관리자 함수라 GRANT EXECUTE TO authenticated 상태이며(369·370
--   회수 대상에도 없음), 이 파일도 그대로 둔다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- [1] _promote_next_event_waitlist(uuid) 재정의(베이스 288)
--     — 함수 맨 앞에 선정형 조기 반환 한 단락만 추가. 나머지는 **실행 코드
--     기준으로** 288 원문과 완전히 동일(지워진 줄 0, diff 로 대조 가능).
--     ⚠️ 주석 한 곳만 사실 갱신했다 — 289 통과 표시를 세워야 하는 호출부
--     목록에 promote_event_waitlist 를 더했다(317 이 이 함수를 부르게 됐다).
--     「완전히 동일」이 주석까지 포함한다는 뜻이 아니므로 여기 적어 둔다.
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
  v_mode       text;
BEGIN
  -- [377] 선정형 캠페인은 순번 자동 승격을 하지 않는다 — 관리자가 뽑기
  -- 함수(S-4, 이 파일 다음)로 지목해서 확정한다. 타임(p_slot_id)이 속한
  -- 캠페인의 방식을 읽어 선정형이면 대기자가 없을 때와 같은 NULL 을
  -- 돌려준다(호출부는 "승격할 사람이 없었다"로 자연스럽게 처리한다 —
  -- 별도 실패 분기를 요구하지 않는다). 슬롯이 안 보이거나(잘못된 id) 캠페인
  -- 연결이 끊긴 경우도 v_mode 는 NULL 이 되어 이 조건을 통과하지 않고
  -- 아래 원래 로직으로 흘러가며, 거기서도 결국 대상 없음으로 NULL 을
  -- 반환한다(동작 변화 없음).
  SELECT c.event_selection_mode INTO v_mode
    FROM public.event_slots s
    JOIN public.campaigns   c ON c.id = s.campaign_id
   WHERE s.id = p_slot_id;

  IF v_mode = 'selection' THEN
    RETURN NULL;
  END IF;

  -- ── 이 아래는 288 원문과 동일 ─────────────────────────────────
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

  -- 짝이 되는 신청도 심사중 → 당선으로. 이 UPDATE 는 289 차단 트리거를
  -- 지나가야 하므로, 호출부(cancel_event_ticket·cancel_event_ticket_admin·
  -- promote_event_waitlist)가 이 함수를 부르기 **전에** bypass 표시를 이미
  -- 세워 둔 상태여야 한다.
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
  '[377, 베이스 288] 확정 자리가 빈 타임(p_slot_id)에서 대기 1번만 확정으로 올린다 '
  '(순번 재정렬은 _renumber_event_waitlist() 가 별도로 담당 — 반드시 함께 호출할 것). '
  '짝이 되는 신청을 approved 로, 승격 알림도 함께 처리. 반환값은 승격된 티켓 id(없으면 '
  'NULL). [377] 그 타임의 캠페인이 event_selection_mode=selection(선정형)이면 함수 '
  '맨 앞에서 아무것도 하지 않고 NULL 을 반환한다 — 선정형은 관리자가 pick_event_tickets '
  '(S-4)로 지목해서 뽑으며, 자동 승격을 켜 두면 안 뽑은 사람이 순번대로 새치기한다. '
  '_renumber_event_waitlist 는 이 조기 반환의 영향을 받지 않는다(선정형은 순번을 '
  '안 채우므로 재정렬할 대상이 없을 뿐, 함수 자체는 손대지 않았다). '
  'cancel_event_ticket(283)·cancel_event_ticket_admin(288)·promote_event_waitlist(317) '
  '모두 이 함수를 쓴다 — 승격 로직을 두 곳에 복사하면 한쪽만 고쳐지는 사고를 막기 위함. '
  '내부 전용 함수(밑줄 접두어) — REVOKE ALL FROM PUBLIC(288) + REVOKE EXECUTE FROM '
  'anon, authenticated(369) 로 두 겹 닫혀 있으며 이 재정의는 그 권한을 그대로 보존한다 '
  '(CREATE OR REPLACE, DROP 아님). 호출부가 이미 슬롯 행을 잠근 상태에서 부르는 것을 '
  '전제로 한다.';

-- ============================================================
-- [2] promote_event_waitlist(uuid) 재정의(베이스 317)
--     — 슬롯을 잠근 뒤 정원을 세기 **전에** 선정형 여부를 확인해 거부한다.
--     나머지는 317 원문과 완전히 동일.
-- ============================================================
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
  v_mode            text;
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

  -- [377] 선정형 캠페인은 이 버튼(순번대로 채우기)을 쓸 수 없다 — 관리자는
  -- 뽑기 함수(S-4, pick_event_tickets)로 지목해서 확정한다. 안 막으면
  -- "안 뽑은 사람"이 순번대로 확정되어 뽑기 자체가 무의미해진다
  -- (작업표 §2 의심 ②).
  SELECT c.event_selection_mode INTO v_mode
    FROM public.campaigns c
   WHERE c.id = v_slot.campaign_id;

  IF v_mode = 'selection' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'selection_mode');
  END IF;

  -- ── 이 아래는 317 원문과 동일 ─────────────────────────────────
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
  '[377, 베이스 317] 관리자 전용. 타임(p_slot_id)의 남은 자리(정원-확정 인원)만큼 '
  '대기자를 순번대로 확정 승격시킨다. [377] 그 타임의 캠페인이 '
  'event_selection_mode=selection(선정형)이면 정원 계산 전에 '
  '{ok:false, reason:selection_mode} 로 거부한다 — 선정형은 순번 승격이 아니라 '
  'pick_event_tickets(S-4)로 관리자가 지목해서 뽑는다. '
  'reserve_event_ticket(288/316)과 같은 정원 판정 기준, '
  '_promote_next_event_waitlist(288/377)/_renumber_event_waitlist(288)를 그대로 재사용 '
  '(복사 없음) — 승격 로직·알림(event_waitlist_promoted)·신청 상태 동기화가 취소 '
  '경로(cancel_event_ticket·cancel_event_ticket_admin)와 항상 같다. 대기자가 없거나 '
  '남은 자리가 0 이어도 실패가 아니라 {ok:true, promoted:0, ...} 를 반환한다. 실패는 '
  '예외가 아니라 {ok:false, reason:...}(permission_denied·not_found·selection_mode). '
  '조사 docs/research/2026-08-07-codebase-audit-findings.md §2-1.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- (.claude/rules/supabase.md 「SQL 검증 순차 안내」)
-- ============================================================
-- [1단계] 함수가 셋이 아니라 둘만 바뀌었는지 — 시그니처·오버로드 확인
--   (SQL 편집기로 실행 가능, 로그인 세션 불필요)
-- SELECT p.oid::regprocedure AS signature, p.prosrc IS NOT NULL AS has_body
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('_promote_next_event_waitlist','promote_event_waitlist',
--                       '_renumber_event_waitlist')
--  ORDER BY p.proname;
--   → 3건, 이름당 1건씩(오버로드 없음).
--   → _renumber_event_waitlist(uuid) 는 반드시 있어야 하고(안 지웠다는 뜻),
--     본문이 바뀌었는지는 아래 4단계에서 별도 확인한다.
--
-- [2단계] 실행 권한이 재정의 뒤에도 유지되는지 — proacl 을 직접 본다.
--   ⚠️ has_function_privilege 만 보면 PUBLIC 이 남아 있을 때도 true 가 나와
--   방향을 구분 못 한다. proacl 의 맨 앞 "=X/" 유무를 함께 볼 것
--   (있으면 PUBLIC 에게도 권한이 남아 있다는 뜻 — 있으면 안 된다).
-- SELECT p.proname,
--        p.proacl::text AS acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authed_can
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname IN ('_promote_next_event_waitlist','promote_event_waitlist');
--   → _promote_next_event_waitlist: acl 에 "=X/" 없음, anon_can=false,
--     authed_can=false (두 겹 회수가 그대로 유지돼야 한다 — 288+369)
--   → promote_event_waitlist: anon_can=false, authed_can=true
--     (317 그대로 — 화면이 직접 부르는 관리자 함수라 authenticated 는 열려
--     있어야 하고, is_admin() 이 내부에서 등급을 가른다)
--
-- [3단계] 형식 확인 (SQL 편집기는 서비스 키라 auth.uid() 가 NULL —
--   promote_event_waitlist 는 permission_denied 가 정상.
--   _promote_next_event_waitlist 는 내부 전용이라 anon/authenticated 권한이
--   없어 SQL 편집기에서도 postgres/service_role 로만 호출 가능하다)
-- SELECT public.promote_event_waitlist('00000000-0000-0000-0000-000000000000');
--   → {"ok": false, "reason": "permission_denied"}
--
-- SELECT public._promote_next_event_waitlist('00000000-0000-0000-0000-000000000000');
--   → NULL (슬롯이 없으니 v_mode 도 NULL → 원래 로직으로 흘러 대상 없음)
--
-- [4단계] ⚠️ 관리자 가드(is_admin())가 걸린 promote_event_waitlist 의 실제
--   선정형 거부 동작은 SQL 편집기(서비스 키, 로그인 사용자 없음)로 재현되지
--   않는다. 여기서부터는 실제 로그인 세션(관리자 계정, 개발서버 브라우저)이
--   필요하다:
--
--   준비: 개발서버에 행사(event_mode) + 비공개(is_invite_only) + 선정형
--     (event_selection_mode='selection') 캠페인 1개, 타임 1개(정원 1),
--     테스트 인플루언서 계정 2개로 그 타임에 심사중(waitlist) 티켓 2개를
--     만든다(S-3 적용 전이면 event_tickets 를 직접 INSERT 해 꾸며도 된다 —
--     status='waitlist', waitlist_position=NULL, application_id 는
--     테스트용 pending 신청과 연결).
--
--   a. [검증 10] 관리자 로그인 콘솔에서 순번 승격 버튼 호출이 거부되는지
--      await window.db.rpc('promote_event_waitlist', {p_slot_id:'<타임id>'})
--      → {ok:false, reason:'selection_mode'}
--      → event_tickets 두 행이 status='waitlist' 그대로인지 확인:
--        SELECT id, status, waitlist_position FROM public.event_tickets
--         WHERE slot_id='<타임id>';
--
--   b. [검증 9] 확정자를 취소해도 다음 사람이 자동 확정되지 않는지
--      선정형 타임에 확정(confirmed) 티켓 1개를 추가로 만든 뒤(정원을
--      2로 늘리거나 별도 타임 사용) 본인 취소(cancel_event_ticket) 또는
--      관리자 취소(cancel_event_ticket_admin)로 그 확정 티켓을 취소한다.
--      → 심사중이던 다른 티켓이 confirmed 로 바뀌지 않아야 한다:
--        SELECT status FROM public.event_tickets WHERE id='<심사중이던 티켓id>';
--        → 'waitlist' 그대로
--
--   c. [검증 11, 회귀] 같은 시나리오를 선착순형(first_come) 타임에서
--      반복해 종전대로 자동 승격 + 승격 알림이 도는지 확인
--      (event_selection_mode 를 다시 'first_come' 으로 UPDATE 한 별도
--      타임 또는 기존 선착순형 캠페인 사용):
--        - 확정자 취소 → 대기 1번이 즉시 confirmed 로, 짝이 되는 신청도
--          approved 로, event_waitlist_promoted 알림이 감
--        - 정원을 늘리고 promote_event_waitlist 호출 → 대기자가 순번대로
--          confirmed 로 올라감
--
--   d. [검증 10-B, 회귀 — 9·11 과 다른 축] 선착순형에서 "대기 티켓 자체를"
--      직접 취소하면(확정 티켓이 아니라) 뒷사람 순번이 당겨지는지.
--      ⚠️ 이 항목은 화면(순번 칸이 보이는지)이 아니라 데이터(번호가 실제로
--      당겨지는지)를 본다 — _renumber_event_waitlist 를 잘못 건드리면
--      여기서만 깨지고 a·b·c 는 통과할 수 있다.
--      선착순형 타임에 심사중 티켓 3개(순번 1·2·3)를 만들고, 순번 2번
--      티켓을 직접 취소(본인 또는 관리자 취소 함수)한 뒤:
--        SELECT waitlist_position FROM public.event_tickets
--         WHERE slot_id='<타임id>' AND status='waitlist'
--         ORDER BY waitlist_position;
--        → 1, 2 (구멍 없이 연속이어야 한다 — 옛 3번이 2번으로 당겨짐)
--
-- ============================================================
-- 롤백
-- ============================================================
-- 288·317 이 만든 원래 정의를 그대로 재실행한다(둘 다 CREATE OR REPLACE
-- 이고 시그니처가 같으므로, 해당 파일의 CREATE OR REPLACE FUNCTION 블록만
-- 복사해 다시 실행하면 이 파일이 추가한 선정형 조기 반환 단락이 사라지고
-- 옛 동작(선정형 구분 없이 항상 자동/버튼 승격)으로 돌아간다):
--   1) 288_cancel_event_ticket_admin.sql 의
--      "CREATE OR REPLACE FUNCTION public._promote_next_event_waitlist(...)"
--      블록(COMMENT 포함)을 그대로 재실행
--   2) 317_promote_event_waitlist.sql 의
--      "CREATE OR REPLACE FUNCTION public.promote_event_waitlist(...)"
--      블록(COMMENT 포함)을 그대로 재실행
-- REVOKE/GRANT 는 이 파일이 건드리지 않았으므로 되돌릴 것이 없다.
-- 이 롤백 뒤에도 event_selection_mode 칸(376)은 남아 있어도 무해하다
-- (아무도 안 읽으므로 값이 있어도 동작에 영향 없음).
-- ============================================================
