-- ============================================================
-- 341_correct_settlement_payment.sql
-- **이미 송금완료된 건**의 송금일·송금액 정정 (정산 3단계 · 작업표 「작업 4 — E」)
--
-- ▶ 왜
--   송금완료는 지금 **한 번 누르면 되돌릴 길이 없다.** 날짜를 잘못 넣었거나 실제로 보낸
--   금액이 계산값과 달랐을 때 고칠 방법이 하나도 없어, 1·2단계가 기록 경로를 잠가 두었다.
--   특히 **일괄 등록(마이그레이션 D)으로 수백 건을 한 날짜·계산 금액으로 넣은 뒤**
--   그중 다른 건을 개별로 고치는 **유일한 경로**가 이 함수다. 이게 없으면 일괄 등록을
--   쓸 수 없다(틀리면 못 고치니까).
--
-- ▶ 무엇만 고치나 — **송금일·송금액 딱 둘**
--   · `status` 는 **안 바꾼다**(`paid` 그대로). 상태를 바꾸는 건 보류·취소 함수의 일이다.
--   · `amount_jpy`(계산값)도 **안 바꾼다.** 그 값은 계산 근거(영수증 금액·상한·출처)와
--     짝을 이루는 스냅샷이라, 덮으면 왜 그 금액인지 설명할 수 없게 된다.
--   · 알림은 **발행하지 않는다.** 이미 「보냈다」고 알린 건의 숫자를 고치는 것이라,
--     다시 알리면 인플루언서에게는 두 번 받은 것처럼 읽힌다.
--
-- ▶ ⚠️ `settlement_events.action` 에 `'correct'` 를 **함께 넓힌다**
--   안 넓히면 이력을 남기는 순간 제약 위반으로 **정정 트랜잭션 전체가 실패**한다.
--   함수만 만들고 제약을 안 고치면 「적용은 성공했는데 쓰면 반드시 터지는」 상태가 된다.
--   ⚠️ 베이스는 **302**(217 원본 5종 → 302 가 `recalc` 추가해 6종). 아래 목록은 302 에서
--      그대로 옮기고 `correct` 만 더한 **7종**이다 — 하나라도 빠지면 그 종류의 기존 이력을
--      남기던 함수가 조용히 죽는다.
--
-- ▶ 인자 규칙 — `NULL` = **그 칸은 안 고침**
--   · `p_paid_at`         NULL → 송금일 그대로
--   · `p_paid_amount_jpy` NULL → 송금액 그대로
--   · 둘 다 NULL 이면 **거부**(아무것도 안 하는 호출은 실수일 가능성이 높다)
--   ⚠️ 송금액을 「계산값과 같음」(NULL)으로 되돌리고 싶으면 **계산값을 그대로 입력**한다.
--      NULL 에 두 가지 뜻(안 고침 / 계산값과 같음)을 주면 화면·함수 어느 쪽도
--      의도를 확신할 수 없어, 돈을 다루는 자리에서 그 모호함은 만들지 않는다.
--
-- ▶ 사유(메모)는 **필수**
--   금전 기록을 사후에 고치는 자리다. 왜 고쳤는지 없이 숫자만 바뀌면 나중에
--   「이게 오타 수정인지 실제로 다르게 보낸 건지」를 아무도 못 가린다.
--
-- ⚠️ 이 마이그레이션은 **화면 잠금을 풀지 않는다.** 세 문은 작업 7에서 함께 연다.
-- ⚠️ 번호 안내 — 334~341 사용. 다음은 342.
--    332 는 **이 저장소 dev 에 이미 `site_daily_visits` 로 확정**돼 있다(iOS 와 무관).
--    333 만 `feature/ios-app` 브랜치와 겹쳐 비워 둔 것이다 — 그 브랜치를 dev 로 합치는
--    날 재번호가 필요하다(337 파일이 같은 내용을 정확히 적어 두었다).
-- ============================================================

BEGIN;

-- ============================================================
-- 1. settlement_events.action 확장 — 'correct' 추가 (302 의 6종 → 7종)
--    DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴(302 와 동일, 재실행 안전)
-- ============================================================
ALTER TABLE public.settlement_events
  DROP CONSTRAINT IF EXISTS settlement_events_action_check;

ALTER TABLE public.settlement_events
  ADD CONSTRAINT settlement_events_action_check
  CHECK (action IN (
    'create',  -- 정산 최초 생성(backfill_settlements/register_past_settlements)
    'pay',     -- 송금완료 처리(mark_settlement_paid, 222 / 일괄 mark_settlements_paid_bulk, 340)
    'hold',    -- 보류(관리자 수동 mark_settlement_hold, 223 / 신청 반려 자동, 246 /
               -- 영수증 재계산 실패 자동, 302 — memo 로 사유 구분)
    'cancel',  -- 취소(mark_settlement_cancel, 223)
    'revert',  -- 보류 해제·pending 복귀(mark_settlement_revert, 224)
    'recalc',  -- [302] 상태는 그대로(pending→pending)인데 영수증 사후 수정으로
               -- 금액(amount_jpy)만 재계산되어 바뀐 사건
    'correct'  -- [341 신규] 상태는 그대로(paid→paid)인데 **실제 송금일·송금액**을
               -- 사람이 사후 정정한 사건. 계산값(amount_jpy)은 안 바뀐다
  ));

-- ============================================================
-- 2. correct_settlement_payment — 송금 기록 정정
-- ============================================================
CREATE OR REPLACE FUNCTION public.correct_settlement_payment(
  p_settlement_id   uuid,
  p_version         integer,
  p_paid_at         timestamptz,
  p_paid_amount_jpy bigint,
  p_memo            text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row         record;
  v_memo        text;
  v_event_memo  text;
  v_new_paid_at timestamptz;
  v_new_amount  bigint;
  v_new_version integer;
  v_changes     text[] := ARRAY[]::text[];
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write (241·340 과 동일) ─────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  v_memo := NULLIF(btrim(p_memo), '');
  IF v_memo IS NULL THEN
    RAISE EXCEPTION 'memo_required: 정정 사유를 입력해야 합니다' USING ERRCODE = '22023';
  END IF;

  IF p_paid_at IS NULL AND p_paid_amount_jpy IS NULL THEN
    RAISE EXCEPTION 'nothing_to_correct: 고칠 항목(송금일 또는 송금액)을 하나 이상 지정해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- 앞날 날짜 방어 (339·340 과 같은 기준·같은 이유)
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- 금액은 0 이하가 될 수 없다. amount_jpy 의 CHECK(>0) 와 같은 기준.
  IF p_paid_amount_jpy IS NOT NULL AND p_paid_amount_jpy <= 0 THEN
    RAISE EXCEPTION 'invalid_paid_amount: 송금액은 0보다 커야 합니다 (입력값: %)', p_paid_amount_jpy
      USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT s.id, s.status, s.version, s.paid_at, s.paid_amount_jpy, s.amount_jpy
    INTO v_row
    FROM public.settlements s
   WHERE s.id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) — 222·241 과 같은 약속 ──
  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  -- ── 송금완료 건만 정정 대상 ───────────────────────────────────
  --   ⚠️ 보류·취소 건에는 쓰지 않는다. 그 상태의 송금 기록을 고치면
  --      「보낸 적 없는데 보낸 날짜가 있는」 행이 생긴다.
  IF v_row.status <> 'paid' THEN
    RAISE EXCEPTION '송금완료(paid) 건만 정정할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  v_new_paid_at := COALESCE(p_paid_at, v_row.paid_at);
  v_new_amount  := COALESCE(p_paid_amount_jpy, v_row.paid_amount_jpy);

  -- ── 무엇이 바뀌는지 이력에 남길 문장 만들기 ────────────────────
  --   ⚠️ 「정정함」만 남기면 **무엇을 무엇으로** 고쳤는지 아무 데도 안 남는다.
  --      돈을 다루는 감사 기록이라 전·후 값을 문장으로 함께 적는다.
  IF p_paid_at IS NOT NULL AND v_row.paid_at IS DISTINCT FROM p_paid_at THEN
    v_changes := v_changes || format('송금일 %s → %s',
                   COALESCE(to_char(v_row.paid_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'), '(없음)'),
                   to_char(p_paid_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'));
  END IF;

  IF p_paid_amount_jpy IS NOT NULL AND v_row.paid_amount_jpy IS DISTINCT FROM p_paid_amount_jpy THEN
    v_changes := v_changes || format('송금액 %s → ¥%s',
                   -- 정정 전이 비어 있으면 「계산값과 같음」이라는 뜻이라 계산값을 함께 적는다.
                   COALESCE('¥' || v_row.paid_amount_jpy::text,
                            '계산값(¥' || COALESCE(v_row.amount_jpy::text, '?') || ')'),
                   p_paid_amount_jpy::text);
  END IF;

  IF array_length(v_changes, 1) IS NULL THEN
    -- 값이 실제로는 하나도 안 바뀌는 호출 — 이력만 늘어나므로 아무것도 안 하고 현재 판을 돌려준다.
    RETURN v_row.version;
  END IF;

  v_event_memo := v_memo || ' [' || array_to_string(v_changes, ', ') || ']';

  UPDATE public.settlements s
     SET paid_at         = v_new_paid_at,
         paid_amount_jpy = v_new_amount,
         -- ★ 메모는 덮어쓰지 않고 덧붙인다 — 그 행이 갖고 있던 사연을 지우지 않는다(340 과 동일).
         memo            = CASE
                             WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_event_memo
                             ELSE s.memo || E'\n' || v_event_memo
                           END,
         version         = s.version + 1
   WHERE s.id = p_settlement_id;

  -- ── 금전 감사 이력 (상태는 그대로 paid→paid) ───────────────────
  INSERT INTO public.settlement_events
    (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'correct', 'paid', 'paid', auth.uid(), v_event_memo);

  -- ⚠️ 알림 없음 — 위 머리말 참조(이미 「보냈다」고 알린 건의 숫자 정정이다).

  SELECT s.version INTO v_new_version FROM public.settlements s WHERE s.id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.correct_settlement_payment(uuid, integer, timestamptz, bigint, text) IS
  '이미 송금완료된 정산의 실제 송금일·송금액만 정정. status·amount_jpy(계산값)는 안 바꾸고 알림도 없다. '
  '인자 NULL 은 「그 칸은 안 고침」이며, 둘 다 NULL 이면 거부. 사유(메모) 필수. '
  '낙관적 잠금 충돌 시 -1(222·241 과 같은 약속). settlement_events 에 action=correct + 전·후 값을 문장으로 남긴다. '
  '보류·취소 건에는 쓸 수 없다(보낸 적 없는데 송금일이 있는 행을 만들지 않기 위해).';

REVOKE ALL ON FUNCTION public.correct_settlement_payment(uuid, integer, timestamptz, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.correct_settlement_payment(uuid, integer, timestamptz, bigint, text) TO authenticated;

-- ⚠️ 새 함수를 PostgREST 가 알아보도록 스키마를 다시 읽으라고 알린다(241·324 관례).
--    안 넣으면 첫 호출이 「함수를 찾을 수 없다」(PGRST202)로 실패할 수 있다.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다) ────────────────
-- [1] action 목록이 7종인가 (기대: correct 포함)
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conrelid = 'public.settlement_events'::regclass
--      AND conname  = 'settlement_events_action_check';
--
-- [2] 기존 이력이 새 제약을 다 통과하나 (기대: 0 — 하나라도 나오면 목록에서 빠뜨린 종류가 있다)
--   SELECT action, count(*) FROM public.settlement_events
--    WHERE action NOT IN ('create','pay','hold','cancel','revert','recalc','correct')
--    GROUP BY action;
--
-- [3] ★ **실제로 한 번 부른다.** 함수를 만드는 구문은 본문 자료형을 검사하지 않아
--     적용은 성공하고 첫 호출에서 터진다(2026-08-18 마이그레이션 335, 42804).
--     ⚠️ 이 조각은 특히 **제약 위반이 안 나는지**가 실질 검증이다 — 실제로 한 건을
--        고쳐 봐야 `action='correct'` 가 들어가는지 알 수 있다.
--   ⚠️ SQL 편집기는 서비스 키라 has_permission 가드에 막힌다(42501) — **관리자 브라우저**에서:
--       // 사유 없이 — 기대: memo_required 오류
--       await db.rpc('correct_settlement_payment',
--         { p_settlement_id:'00000000-0000-0000-0000-000000000000', p_version:1,
--           p_paid_at:null, p_paid_amount_jpy:1000, p_memo:'' })
--       // 고칠 항목 없이 — 기대: nothing_to_correct 오류
--       await db.rpc('correct_settlement_payment',
--         { p_settlement_id:'00000000-0000-0000-0000-000000000000', p_version:1,
--           p_paid_at:null, p_paid_amount_jpy:null, p_memo:'시험' })
--   ⚠️ 실제 정정 시험은 **개발서버의 시험 행**으로만. 운영의 송금완료 건은 사람이 확인한
--      금전 기록이다.
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.correct_settlement_payment(uuid, integer, timestamptz, bigint, text);
--   ⚠️ action CHECK 를 6종으로 되돌리려면 **이미 쌓인 action='correct' 행을 먼저 처리**해야
--      한다(안 그러면 ADD CONSTRAINT 자체가 실패한다). 302 파일 하단 같은 경고 참조.
