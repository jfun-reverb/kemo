-- 486_settlement_transfer_record.sql
-- 정산 송금 묶음 기록 함수 (조각 3~6 — 판정 헬퍼 · 기록 · 묶음 정정 · 341/416 재정의 · 옛 경로 거부)
-- 사양서: docs/specs/2026-09-30-settlement-transfer-fee-record.md (D-1~D-5)
-- 작업표: docs/specs/2026-09-30-settlement-transfer-fee-record-breakdown.md 「조각 3·4·5·6」
--
-- 선행: 484(수수료 규칙 표) · 485(송금 묶음·연결·묶음 이력 표 + settlements.current_transfer_id)
--
-- ▶ 이 파일이 하는 일 (한 파일 = 조각 3~6, 같은 함수를 연달아 재정의하므로 쪼개지 않는다)
--   [조각 3] _settlement_register_judge(uuid[])      — 미등록 응모 판정 공용 헬퍼(내부 전용)
--            register_past_settlements  재정의       — 베이스 339, 판정만 헬퍼로 교체(건너뛰기 동작 그대로)
--   [조각 4] record_settlement_transfers(jsonb)       — 새 기록 함수. 먼저 전부 검사 → 하나라도 걸리면 아무것도 안 쓴다
--   [조각 5] correct_settlement_transfer(...)         — 묶음 정정(송금일·수수료·거래번호·메모)
--            correct_settlement_payment 재정의        — 베이스 341(현재 묶음이 있는 건의 날짜 거부·금액 전파)
--            mark_settlement_revert     재정의        — 베이스 416(보류 해제 시 현재 연결을 이력 번호로 바꿔 적음)
--   [조각 6] _settlement_transfer_intro_at()          — 「도입일」(앱으로 처음 기록한 시각) 판정
--            mark_settlement_paid(343) · mark_settlements_paid_bulk(416) · register_past_settlements('paid' 만)
--            맨 앞에 도입일이 서 있으면 payout_bundle_required 로 거부
--   [추가 내부 헬퍼] _settlement_fee_calc(...)        — 수수료 계산식 **한 곳**(기록·금액 정정이 함께 쓴다 — 사본 금지)
--
-- ▶ 베이스 번호 (정의 파일을 전부 열어 확인 — 이름이 나오는 파일 ≠ 정의 파일)
--   register_past_settlements       현재 원본 339  (정의: 233·262·300·324·339, 이후 재정의 없음)
--   correct_settlement_payment      현재 원본 341  (정의: 341 하나)
--   mark_settlement_revert          현재 원본 416  (정의: 224·416)
--   mark_settlement_paid            현재 원본 343  (정의: 222·241·339·343. 339 의 5인자 판을 343 이 알림만 걷어냄)
--   mark_settlements_paid_bulk      현재 원본 416  (정의: 340·343·416)
--   _settlement_cert_candidates     현재 원본 455  (호출만 한다 — 이 파일에 사본 없음)
--   🔴 아래 다섯 재정의는 본문을 각 베이스에서 그대로 옮기고 표시한 자리([486])만 바꿨다.
--      223(보류·취소)은 안 건드린다 — 보류·취소는 current_transfer_id·연결을 그대로 둔다(환수 근거 보존).
--
-- ▶ 불변식 (485 머리말 — 표 제약으로 못 건다, 아래 함수가 지킨다)
--   settlements.current_transfer_id 가 있으면
--     ① settlements.paid_at         = 그 묶음 sent_at
--     ② settlements.paid_amount_jpy = 그 건의 「현재 연결」(revert_event_id IS NULL) 금액
--   지키는 자리: record_settlement_transfers · correct_settlement_transfer(송금일 전파)
--               · correct_settlement_payment(금액 전파·날짜 거부) · mark_settlement_revert(연결 해제)
--
-- ▶ 잠금 순서 — 「묶음 먼저, 정산 나중」
--   correct_settlement_transfer 가 묶음 → 그 묶음의 건(id 순) 순으로 잠그므로,
--   correct_settlement_payment 도 현재 묶음이 있으면 묶음부터 잠근 뒤 건을 잠근다(반대 순서면 교착).
--   record_settlement_transfers 는 새 묶음을 만들기 전에 건을 id 순으로 잠근다(새 묶음은 남이 못 본다).
--
-- ▶ 옛 경로 거부의 발동 조건이 「데이터」다
--   source='app' 묶음이 한 줄이라도 있으면(_settlement_transfer_intro_at() 이 NULL 이 아니면)
--   옛 송금완료 경로 셋의 'paid' 호출이 전부 payout_bundle_required 로 거부된다.
--   🔴 운영에서 SQL 편집기로 record_settlement_transfers 를 시험 호출하지 말 것 — 그 한 줄이 옛 화면의
--      「선택한 건 보냄」·단건 송금완료를 전부 막는다. 개발서버도 시험 뒤엔 옛 경로가 막히므로 **옛 경로 확인은 시험 전에**.
--   'sheet_backfill' 묶음만 있으면 거부는 켜지지 않는다.
--
-- ▶ 화면 잠금·배포 순서 — 데이터베이스 먼저, 화면 나중(조각 17). 이 파일은 화면을 바꾸지 않는다.
--
-- 롤백 (역순 — 🔴 거부 조항(조각 6)부터 되돌려야 옛 화면이 살아난다):
--   ① 옛 정의를 각 베이스 파일의 함수 블록 그대로 다시 적용(모두 CREATE OR REPLACE — 권한 보존):
--        mark_settlement_paid            → 343 의 ① 블록
--        mark_settlements_paid_bulk      → 416 의 ② 블록
--        register_past_settlements       → 339 의 ② 블록(⚠️ 339 는 DROP 후 CREATE 라 서명·권한이 같다 — REPLACE 만으로 충분)
--        correct_settlement_payment      → 341 의 2절
--        mark_settlement_revert          → 416 의 ① 블록
--   ② DROP FUNCTION IF EXISTS public.record_settlement_transfers(jsonb);
--      DROP FUNCTION IF EXISTS public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text);
--      DROP FUNCTION IF EXISTS public._settlement_register_judge(uuid[]);
--      DROP FUNCTION IF EXISTS public._settlement_transfer_intro_at();
--      DROP FUNCTION IF EXISTS public._settlement_fee_calc(bigint, numeric, integer, text);
--      (① 을 먼저 — ②가 먼저면 register_past_settlements 등이 없는 헬퍼를 불러 죽는다)
--   ⚠️ 이미 쌓인 settlement_transfers·items·events 행과 settlements.current_transfer_id 는 이 롤백이 지우지 않는다(485 롤백 참고).

BEGIN;

-- ============================================================
-- 0. 내부 헬퍼 — 수수료 계산식 (한 곳)
--    수수료 = 끝수처리(합계 × 비율/100 + 고정액). 484 머리말과 같은 식. 화면·다른 함수에 사본을 두지 않는다.
--    실행 권한을 아무에게도 주지 않는다(부르는 쪽은 전부 SECURITY DEFINER).
-- ============================================================
CREATE OR REPLACE FUNCTION public._settlement_fee_calc(
  p_total        bigint,
  p_rate_percent numeric,
  p_fixed_jpy    integer,
  p_rounding     text
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT (CASE p_rounding
            WHEN 'floor' THEN floor(p_total * p_rate_percent / 100 + p_fixed_jpy)
            WHEN 'ceil'  THEN ceil (p_total * p_rate_percent / 100 + p_fixed_jpy)
            ELSE              round(p_total * p_rate_percent / 100 + p_fixed_jpy)
          END)::bigint;
$$;

COMMENT ON FUNCTION public._settlement_fee_calc(bigint, numeric, integer, text) IS
  '[486] 송금 수수료 계산식 한 곳 = 끝수처리(합계*비율/100+고정액). record_settlement_transfers · correct_settlement_payment 가 쓴다. 내부 전용.';

REVOKE ALL ON FUNCTION public._settlement_fee_calc(bigint, numeric, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._settlement_fee_calc(bigint, numeric, integer, text) FROM anon;
REVOKE ALL ON FUNCTION public._settlement_fee_calc(bigint, numeric, integer, text) FROM authenticated;

-- ============================================================
-- 1. [조각 6] _settlement_transfer_intro_at() — 도입일
--    = 화면(앱)으로 처음 송금 묶음을 기록한 시각. 'sheet_backfill' 은 세지 않는다.
--    옛 송금완료 경로 셋이 맨 앞에서 이 값을 본다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._settlement_transfer_intro_at()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT min(t.recorded_at) FROM public.settlement_transfers t WHERE t.source = 'app';
$$;

COMMENT ON FUNCTION public._settlement_transfer_intro_at() IS
  '[486] 송금 묶음 도입일 = source=app 묶음의 가장 이른 recorded_at(없으면 NULL). NULL 이 아니면 옛 송금완료 경로 셋이 payout_bundle_required 로 거부한다. 내부 전용.';

REVOKE ALL ON FUNCTION public._settlement_transfer_intro_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._settlement_transfer_intro_at() FROM anon;
REVOKE ALL ON FUNCTION public._settlement_transfer_intro_at() FROM authenticated;

-- ============================================================
-- 2. [조각 3] _settlement_register_judge(uuid[]) — 미등록 응모 판정 헬퍼
--    판정 근거 = 339 register_past_settlements 의 「targets」 조건(_settlement_cert_candidates() 455
--    + is_success + amount_issue IS NULL) + 페이팔 유무(no_paypal) — 글자 그대로.
--    입력 응모마다 정확히 1행을 돌려준다(후보가 아니어도 not_candidate 로).
--
--    reason 우선순위: not_candidate → amount_issue → already_registered → paypal_missing (없으면 NULL = 통과)
--    · is_target         = 339 의 targets 와 같은 조건(후보 · 인증 성공 · 금액 확정). 페이팔·기등록은 안 본다
--    · no_paypal         = 339 의 no_paypal 과 같은 식(NULLIF(btrim(paypal_email),'') IS NULL)
--    · already_registered = 그 응모에 정산 행이 이미 있음(339 는 ON CONFLICT DO NOTHING 으로 조용히 넘겼다)
--    · ok                = is_target AND NOT already_registered AND NOT no_paypal (송금완료 기록 기준. 정산대기 추가는 페이팔을 안 본다)
--    ⚠️ 옛 함수(register_past_settlements)는 여전히 건너뛴다 — 사유로 「거부」하는 것은 새 함수(record_settlement_transfers)뿐.
-- ============================================================
CREATE OR REPLACE FUNCTION public._settlement_register_judge(p_application_ids uuid[])
RETURNS TABLE (
  application_id     uuid,
  ok                 boolean,
  reason             text,
  is_target          boolean,
  no_paypal          boolean,
  already_registered boolean,
  amount_jpy         bigint,
  amount_source      text,
  reward_part_jpy    bigint,
  receipt_amount_jpy bigint,
  amount_cap_jpy     bigint,
  influencer_id      uuid,
  campaign_id        uuid,
  cert_at            timestamptz,
  paypal_email       text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH ids AS (
    SELECT DISTINCT x AS id FROM unnest(p_application_ids) AS x WHERE x IS NOT NULL
  ),
  j AS (
    SELECT ids.id                                                    AS a_id,
           c.application_id                                          AS c_app,
           -- 339 targets 와 같은 조건 (c.is_success AND c.amount_issue IS NULL)
           (c.application_id IS NOT NULL AND COALESCE(c.is_success, false)) AS is_success,
           c.amount_issue                                            AS amount_issue,
           (c.application_id IS NOT NULL AND COALESCE(c.is_success, false) AND c.amount_issue IS NULL) AS is_target,
           -- 339 의 no_paypal 과 같은 식
           (NULLIF(btrim(c.paypal_email), '') IS NULL)               AS no_paypal,
           EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id = ids.id) AS registered,
           c.influencer_id, c.campaign_id, c.amount_jpy, c.amount_source, c.reward_part_jpy,
           c.receipt_amount_jpy, c.amount_cap_jpy, c.cert_at, c.paypal_email
      FROM ids
      LEFT JOIN public._settlement_cert_candidates() c ON c.application_id = ids.id
  )
  SELECT j.a_id,
         (j.is_target AND NOT j.registered AND NOT j.no_paypal),
         CASE
           WHEN NOT j.is_success          THEN 'not_candidate'
           WHEN j.amount_issue IS NOT NULL THEN 'amount_issue'
           WHEN j.registered              THEN 'already_registered'
           WHEN j.no_paypal               THEN 'paypal_missing'
         END,
         j.is_target,
         j.no_paypal,
         j.registered,
         j.amount_jpy, j.amount_source, j.reward_part_jpy, j.receipt_amount_jpy, j.amount_cap_jpy,
         j.influencer_id, j.campaign_id, j.cert_at, j.paypal_email
    FROM j;
$$;

COMMENT ON FUNCTION public._settlement_register_judge(uuid[]) IS
  '[486] 미등록 응모 판정 공용 헬퍼(입력 응모마다 1행). 339 register_past_settlements 의 판정(_settlement_cert_candidates 455 + 인증 성공 + 금액 확정 + 페이팔 유무)을 글자 그대로 옮겼다. '
  'reason = not_candidate / amount_issue / already_registered / paypal_missing(통과면 NULL). 내부 전용 — 판정을 고치면 이 함수 한 곳만.';

REVOKE ALL ON FUNCTION public._settlement_register_judge(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._settlement_register_judge(uuid[]) FROM anon;
REVOKE ALL ON FUNCTION public._settlement_register_judge(uuid[]) FROM authenticated;

-- ============================================================
-- 3. [조각 3+6] register_past_settlements 재정의 — 베이스 339
--    바꾼 것 둘뿐:
--      ① targets CTE 를 헬퍼 호출로 교체(조건은 헬퍼가 339 그대로 — is_target). blocked/eligible/inserted/events_ins·반환·건너뛰기는 339 그대로
--      ② [조각 6] 'paid' 목표일 때 도입일이 서 있으면 payout_bundle_required (권한 확인 바로 뒤 — 권한 없는 사람에게 상태를 안 알린다)
--    ⚠️ 'pending'(정산대기 추가)은 돈이 안 나가는 경로라 거부하지 않는다.
--    ⚠️ 서명·반환 모양 불변 → CREATE OR REPLACE (권한 보존).
-- ============================================================
CREATE OR REPLACE FUNCTION public.register_past_settlements(
  p_application_ids uuid[],
  p_target_status   text,
  p_memo            text,
  p_paid_at         timestamptz DEFAULT NULL
)
RETURNS TABLE (
  registered_count         integer,
  skipped_no_paypal_count  integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registered        integer := 0;
  v_skipped_no_paypal integer := 0;
  v_memo              text;
BEGIN
  -- ── 권한 게이트: settlement.pay 최소 write (300 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ★ [486] 도입일 뒤에는 옛 송금완료 경로('paid')를 거부한다. 'pending' 은 그대로 통과.
  IF p_target_status = 'paid' AND public._settlement_transfer_intro_at() IS NOT NULL THEN
    RAISE EXCEPTION 'payout_bundle_required: 송금 기록 방식이 바뀌었습니다. 화면을 새로 고친 뒤 다시 기록해 주세요'
      USING ERRCODE = '22023';
  END IF;

  -- ── 목표 상태 검증: paid | pending 만 허용 (300 과 동일) ──
  IF p_target_status NOT IN ('paid', 'pending') THEN
    RAISE EXCEPTION 'invalid_target_status: paid 또는 pending 만 허용됩니다 (입력값: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  IF p_application_ids IS NULL OR array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'empty_application_ids: 처리할 응모를 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ★ [339] 앞날 날짜 방어 (단건 함수와 같은 기준·같은 이유)
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- ★ [339] 「정산대기로 등록」인데 송금일을 준 경우 — 조용히 버리지 않고 막는다.
  --   정산대기는 아직 안 보낸 상태라 송금일이 성립하지 않는다. 인자를 무시하면 화면에서는
  --   날짜를 넣었는데 아무 데도 안 남아, 나중에 「왜 비었나」를 못 찾는다.
  IF p_paid_at IS NOT NULL AND p_target_status <> 'paid' THEN
    RAISE EXCEPTION 'paid_at_requires_paid: 송금일은 송금완료로 등록할 때만 넣을 수 있습니다 (목표 상태: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  v_memo := COALESCE(NULLIF(btrim(p_memo), ''), '과거 이관 (수동 처리)');

  WITH targets AS (
    -- ── 서버 재검증(300 원칙 유지) + [324, H-5] cert_at 함께 조회 ──
    -- [486] 판정은 공용 헬퍼로 옮겼다. is_target = 339 의 조건(후보 · 인증 성공 · 금액 확정) 그대로,
    --   no_paypal = 339 의 「[324, H-4] 이 건의 페이팔 등록 여부」 그대로.
    --   ★ [339] 도입일(컷오프) 조건은 없다(337 이 목록 함수에서 없앤 것과 짝). 중복 등록은
    --      아래 `ON CONFLICT (application_id) DO NOTHING` 이 막는다.
    SELECT j.application_id, j.influencer_id, j.campaign_id,
           j.amount_jpy, j.amount_source, j.reward_part_jpy,
           j.receipt_amount_jpy, j.amount_cap_jpy, j.cert_at, j.paypal_email,
           j.no_paypal
    FROM public._settlement_register_judge(p_application_ids) j
    WHERE j.is_target
  ),
  blocked AS (
    -- [324, H-4] "송금완료로 만드는데 페이팔이 없는" 건 — 이 배치에서 제외.
    SELECT * FROM targets WHERE p_target_status = 'paid' AND no_paypal
  ),
  eligible AS (
    -- pending 목표는 페이팔 유무와 무관하게 전부 통과(아직 실제 송금이 일어나지
    -- 않았으므로). paid 목표는 페이팔이 있는 건만 통과.
    SELECT * FROM targets WHERE NOT (p_target_status = 'paid' AND no_paypal)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, cert_at,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id,
      t.amount_jpy, t.amount_source, t.reward_part_jpy,
      t.receipt_amount_jpy, t.amount_cap_jpy, t.cert_at,
      p_target_status,
      NULLIF(t.paypal_email, ''),
      -- ★ [339] 받은 송금일을, 없으면 종전대로 지금 시각을. 정산대기는 여전히 NULL.
      CASE WHEN p_target_status = 'paid' THEN COALESCE(p_paid_at, now()) ELSE NULL END,
      CASE WHEN p_target_status = 'paid' THEN auth.uid() ELSE NULL END,
      v_memo
    FROM eligible t
    -- 동시 처리 경쟁 방지(이중 방어 — 300 과 동일).
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행.
    -- ⚠️ notifications INSERT 는 여기 없음(233 「알림 없음」 원칙 그대로 — 의도적).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, p_target_status, auth.uid(), v_memo
    FROM inserted
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM blocked)
  INTO v_registered, v_skipped_no_paypal;

  RETURN QUERY SELECT v_registered, v_skipped_no_paypal;
END;
$$;

COMMENT ON FUNCTION public.register_past_settlements(uuid[], text, text, timestamptz) IS
  '과거 미등록 정산을 일괄 등록. [339] 실제 보낸 날짜(p_paid_at)를 받을 수 있고 생략하면 종전대로 now(). '
  '금액 인자는 일부러 없다(건마다 달라 하나로 못 넣는다 — correct_settlement_payment 로 개별 정정). '
  '정산대기 목표에 송금일을 주면 조용히 버리지 않고 막는다. 324 의 페이팔 확인·cert_at 저장·알림 없음 원칙은 그대로. '
  '[486] 판정을 _settlement_register_judge 로 옮겼다(동작 동일 — 건너뛰기 그대로). 송금 묶음 도입일 뒤에는 ''paid'' 호출을 payout_bundle_required 로 거부(''pending'' 은 통과).';

-- 권한은 CREATE OR REPLACE 로 보존된다(339 가 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ============================================================
-- 4. [조각 4] record_settlement_transfers(jsonb) — 새 기록 함수
--
--    입력 p_bundles = [
--      { settlement_ids: [uuid…],            -- 정산 행이 있는(정산대기) 건
--        application_ids: [uuid…],           -- 정산 행이 없는 응모(함수 안에서 정산 행을 만든다)
--        item_amounts: { "<id>": 금액 },     -- 건별 보낸 금액(선택 — 비우면 그 건의 계산값 amount_jpy). 키 = settlement id 또는 application id
--        sent_at: timestamptz,               -- 필수. 송금일 정본
--        fee_jpy: 정수|null,                 -- 넘기면 그 값 + fee_manual=true(계산값과 같아도). null 이면 규칙(484)으로 계산
--        paypal_txn_id: text|null, memo: text|null,
--        source: 'app'|'sheet_backfill' }, … ]
--
--    🔴 건너뛰지 않는다 — 사용자 결정(2026-09-30): 「먼저 전부 검사 → 하나라도 걸리면 아무것도 안 쓴다」.
--       ① 대상 정산대기 건을 id 순으로 잠근다(340 방식)  ② 미등록 응모는 헬퍼로 판정  ③ 전부 검사
--       ④ 실패가 하나라도 있으면 쓰기 전에 {ok:false, failures:[…]} 반환(잠금은 트랜잭션 끝에 풀린다)
--       ⑤ 통과하면 묶음마다 쓴다. 쓰기 도중 예상 밖 오류는 예외 → 전체 롤백(부분 기록이 남는 경로 없음)
--
--    실패 사유(failures[].reason — bundle_index 는 입력 배열의 0부터 센 위치):
--      bundle_paypal_missing · bundle_not_pending(정산대기 아님 / 이미 정산 행이 있는 응모) · bundle_not_found ·
--      bundle_not_candidate · bundle_amount_issue · bundle_empty · bundle_duplicate_item(같은 묶음 안 + 묶음 사이 모두) ·
--      bundle_amount_invalid(건별 금액·수수료가 정수가 아니거나 0 이하/음수) · sent_at_in_future ·
--      bundle_mixed_influencer   ← [486 추가] 한 묶음 = 한 사람(settlement_transfers.influencer_id 가 하나)
--      bundle_txn_id_invalid     ← [486 추가] 거래번호 100자 초과(485 CHECK 가 던지는 예외 대신 사유로)
--    항목 지목: settlement_id(정산 행 항목) 또는 application_id(미등록 응모 항목). 묶음 전체 사유는 bundle_index 만.
--      item_amounts 의 키가 그 묶음 항목과 안 맞으면 {bundle_index, item_key, reason:'bundle_amount_invalid'}
--      (조용히 무시하면 입력한 금액 대신 계산값으로 기록된다 — 리뷰 지적으로 추가). 키 대소문자는 가리지 않는다.
--      수수료·건별 금액이 숫자가 아니면(문자열 등) 캐스트 예외 대신 bundle_amount_invalid.
--
--    입력 형식 자체가 틀리면(배열 아님·빈 배열·객체 아닌 묶음·sent_at 없음·source 값 틀림·uuid 아님) 사유 목록 없이 예외.
--    sent_at_in_future 기준 = now() + 1일(339·340·341 과 같은 여유 — 시계·시간대 어긋남 흡수. 일본 날짜로 「오늘」을 보내도 안 걸린다).
--
--    쓰기 내용(묶음마다):
--      settlement_transfers 1행(합계 = 건별 금액 합, 수수료 + 규칙 스냅샷 — 손으로 고쳤어도 스냅샷은 그때 규칙을 적는다)
--      settlement_transfer_items 건마다 1행
--      settlements: status='paid', paid_at=sent_at, paid_by, paid_amount_jpy=건별 금액(NULL 금지), paypal_email=최신값(343·416 과 같음),
--                   current_transfer_id, memo 덧붙임(340 과 같음), version+1
--                   (미등록 응모는 339 와 같은 칸으로 pending 정산 행을 만든 뒤 같은 갱신을 태운다)
--      settlement_events: 건마다 'pay'(미등록은 그 앞에 'create') · settlement_transfer_events: 묶음마다 'create'
--    🔴 인플루언서 알림 없음(343). 반환: {ok:true, transfer_ids, settlement_count, fee_total}
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_settlement_transfers(p_bundles jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_b            record;
  v_it           record;
  v_j            record;
  v_id           uuid;
  v_rule         public.settlement_fee_rule%ROWTYPE;
  v_actor_name   text;
  v_items        jsonb;                        -- 입력 평탄화 {seq, bundle_index, kind, id, amt_raw}
  v_judge        jsonb;                        -- 미등록 응모 판정 결과(헬퍼)
  v_res          jsonb;                        -- 항목별 확정값 {…, influencer_id, amount, amt_invalid}
  v_fail         jsonb := '[]'::jsonb;
  v_sent         timestamptz;
  v_fee_num      numeric;
  v_fee          bigint;
  v_manual       boolean;
  v_memo         text;
  v_txn          text;
  v_source       text;
  v_inf          uuid;
  v_total        bigint;
  v_paypal       text;
  v_tid          uuid;
  v_sid          uuid;
  v_tids         jsonb := '[]'::jsonb;
  v_count        integer := 0;
  v_fee_total    bigint := 0;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write (340·341 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  IF p_bundles IS NULL OR jsonb_typeof(p_bundles) <> 'array' OR jsonb_array_length(p_bundles) = 0 THEN
    RAISE EXCEPTION 'empty_bundles: 기록할 송금 묶음을 1개 이상 넘겨야 합니다' USING ERRCODE = '22023';
  END IF;

  SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;

  -- ── 1) 입력 평탄화: 항목마다 (순번, 묶음 위치, 종류 s=정산 행 / a=미등록 응모, id, 건별 금액 원본) ──
  --    id 가 uuid 가 아니면 여기서 예외(형식 오류 — 사유 목록 대상 아님).
  --    JSON null 원소는 조용히 뺀다(그 결과 묶음이 비면 bundle_empty).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'seq', t.seq, 'bundle_index', t.bidx, 'kind', t.kind, 'id', t.id, 'amt_raw', t.amt_raw
         ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT row_number() OVER (ORDER BY b.bidx, k.kord, k.ord) AS seq,
             b.bidx, k.kind, k.id_text::uuid AS id,
             -- 키 대소문자 차이를 흡수한다(uuid 는 대소문자 무관). 키가 항목과 안 맞는 경우는 6-f 가 실패로 잡는다
             (SELECT ia.value
                FROM jsonb_each(CASE WHEN jsonb_typeof(b.e -> 'item_amounts') = 'object'
                                     THEN b.e -> 'item_amounts' ELSE '{}'::jsonb END) AS ia
               WHERE lower(ia.key) = lower(k.id_text)
               LIMIT 1) AS amt_raw
        FROM (
          SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
            FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
        ) b
        CROSS JOIN LATERAL (
          SELECT 's'::text AS kind, 1 AS kord, q.ord, q.val AS id_text
            FROM jsonb_array_elements_text(
                   CASE WHEN jsonb_typeof(b.e -> 'settlement_ids') = 'array'
                        THEN b.e -> 'settlement_ids' ELSE '[]'::jsonb END
                 ) WITH ORDINALITY AS q(val, ord)
          UNION ALL
          SELECT 'a'::text, 2, q.ord, q.val
            FROM jsonb_array_elements_text(
                   CASE WHEN jsonb_typeof(b.e -> 'application_ids') = 'array'
                        THEN b.e -> 'application_ids' ELSE '[]'::jsonb END
                 ) WITH ORDINALITY AS q(val, ord)
        ) k
       WHERE k.id_text IS NOT NULL
    ) t;

  -- ── 2) 묶음 단위 검사 (송금일·수수료·거래번호·비어 있음) ──
  FOR v_b IN
    SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
      FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
     ORDER BY o.ord
  LOOP
    IF jsonb_typeof(v_b.e) <> 'object' THEN
      RAISE EXCEPTION 'invalid_bundle: 묶음은 객체여야 합니다 (묶음 위치: %)', v_b.bidx USING ERRCODE = '22023';
    END IF;
    IF NULLIF(v_b.e ->> 'sent_at', '') IS NULL THEN
      RAISE EXCEPTION 'invalid_bundle: sent_at 이 필요합니다 (묶음 위치: %)', v_b.bidx USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_b.e ->> 'source', '') NOT IN ('app', 'sheet_backfill') THEN
      RAISE EXCEPTION 'invalid_bundle: source 는 app 또는 sheet_backfill 이어야 합니다 (묶음 위치: %)', v_b.bidx
        USING ERRCODE = '22023';
    END IF;

    v_sent := (v_b.e ->> 'sent_at')::timestamptz;
    IF v_sent > now() + interval '1 day' THEN
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'sent_at_in_future'));
    END IF;

    -- 수수료: 없거나 JSON null 이면 규칙 계산. 숫자가 아니면(문자열 등) 캐스트 예외 대신 사유로
    IF (v_b.e -> 'fee_jpy') IS NOT NULL AND jsonb_typeof(v_b.e -> 'fee_jpy') <> 'null' THEN
      IF jsonb_typeof(v_b.e -> 'fee_jpy') <> 'number' THEN
        v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_amount_invalid'));
      ELSE
        v_fee_num := (v_b.e ->> 'fee_jpy')::numeric;
        IF v_fee_num < 0 OR v_fee_num <> trunc(v_fee_num) OR v_fee_num > 1000000000000 THEN
          v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_amount_invalid'));
        END IF;
      END IF;
    END IF;

    -- 건별 금액 칸이 있는데 객체가 아니면 실패(조용히 무시하면 계산값으로 기록된다)
    IF (v_b.e -> 'item_amounts') IS NOT NULL
       AND jsonb_typeof(v_b.e -> 'item_amounts') NOT IN ('object', 'null') THEN
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_amount_invalid'));
    END IF;

    IF char_length(btrim(COALESCE(v_b.e ->> 'paypal_txn_id', ''))) > 100 THEN
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_txn_id_invalid'));
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM jsonb_to_recordset(v_items) AS it(bundle_index integer) WHERE it.bundle_index = v_b.bidx
    ) THEN
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_empty'));
    END IF;
  END LOOP;

  -- ── 3) 정산 행 항목 잠금 — DISTINCT + ORDER BY 로 항상 같은 순서(340·416 그대로, 교착 방지) ──
  FOR v_id IN
    SELECT DISTINCT it.id FROM jsonb_to_recordset(v_items) AS it(kind text, id uuid)
     WHERE it.kind = 's' ORDER BY 1
  LOOP
    PERFORM 1 FROM public.settlements s WHERE s.id = v_id FOR UPDATE;
  END LOOP;

  -- ── 4) 미등록 응모 판정 (조각 3 헬퍼 — 339 판정과 같은 근거) ──
  SELECT COALESCE(jsonb_agg(to_jsonb(j)), '[]'::jsonb)
    INTO v_judge
    FROM public._settlement_register_judge(
           ARRAY(SELECT it.id FROM jsonb_to_recordset(v_items) AS it(kind text, id uuid) WHERE it.kind = 'a')
         ) j;

  -- ── 5) 항목별 확정값: 받는 사람 · 건별 금액(비우면 계산값) · 금액 형식 위반 여부 ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'seq', x.seq, 'bundle_index', x.bundle_index, 'kind', x.kind, 'id', x.id,
           'influencer_id', x.influencer_id,
           -- 중첩 CASE 로 「숫자인지」를 먼저 가른다(AND 는 평가 순서가 보장되지 않아 문자열도 캐스트될 수 있다)
           'amount', CASE
                       WHEN x.amt_raw IS NULL OR jsonb_typeof(x.amt_raw) = 'null' THEN x.default_amount
                       WHEN jsonb_typeof(x.amt_raw) <> 'number' THEN NULL
                       ELSE CASE
                              WHEN (x.amt_raw #>> '{}')::numeric > 0
                               AND (x.amt_raw #>> '{}')::numeric <= 1000000000000
                               AND (x.amt_raw #>> '{}')::numeric = trunc((x.amt_raw #>> '{}')::numeric)
                                THEN (x.amt_raw #>> '{}')::numeric::bigint
                              ELSE NULL
                            END
                     END,
           'amt_invalid', CASE
                            WHEN x.amt_raw IS NULL OR jsonb_typeof(x.amt_raw) = 'null' THEN false
                            WHEN jsonb_typeof(x.amt_raw) <> 'number' THEN true
                            ELSE NOT (
                                   (x.amt_raw #>> '{}')::numeric > 0
                               AND (x.amt_raw #>> '{}')::numeric <= 1000000000000
                               AND (x.amt_raw #>> '{}')::numeric = trunc((x.amt_raw #>> '{}')::numeric))
                          END
         ) ORDER BY x.seq), '[]'::jsonb)
    INTO v_res
    FROM (
      SELECT it.seq, it.bundle_index, it.kind, it.id, it.amt_raw,
             COALESCE(s.influencer_id, j.influencer_id) AS influencer_id,
             CASE it.kind WHEN 's' THEN s.amount_jpy ELSE j.amount_jpy END AS default_amount
        FROM jsonb_to_recordset(v_items) AS it(seq integer, bundle_index integer, kind text, id uuid, amt_raw jsonb)
        LEFT JOIN public.settlements s ON it.kind = 's' AND s.id = it.id
        LEFT JOIN jsonb_to_recordset(v_judge) AS j(application_id uuid, influencer_id uuid, amount_jpy bigint)
               ON it.kind = 'a' AND j.application_id = it.id
    ) x;

  -- ── 6) 항목 단위 검사 ──
  -- 6-a) 건별 금액 형식(숫자가 아니거나 정수·0 초과가 아님). 계산값이 없는 항목(없는 행·후보 아님)은 아래 다른 사유로 잡힌다
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'bundle_index', r.bundle_index,
             CASE r.kind WHEN 's' THEN 'settlement_id' ELSE 'application_id' END, r.id,
             'reason', 'bundle_amount_invalid') ORDER BY r.seq)
      FROM jsonb_to_recordset(v_res) AS r(seq integer, bundle_index integer, kind text, id uuid, amount bigint, amt_invalid boolean)
     WHERE r.amt_invalid
  ), '[]'::jsonb);

  -- 6-b) 중복 항목 — 같은 묶음 안 + 묶음 사이 모두(처음 것은 통과, 나머지를 지목)
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'bundle_index', d.bundle_index,
             CASE d.kind WHEN 's' THEN 'settlement_id' ELSE 'application_id' END, d.id,
             'reason', 'bundle_duplicate_item') ORDER BY d.seq)
      FROM (
        SELECT it.seq, it.bundle_index, it.kind, it.id,
               row_number() OVER (PARTITION BY it.kind, it.id ORDER BY it.seq) AS rn
          FROM jsonb_to_recordset(v_items) AS it(seq integer, bundle_index integer, kind text, id uuid)
      ) d
     WHERE d.rn > 1
  ), '[]'::jsonb);

  -- 6-c) 정산 행 항목 — 없음 / 정산대기 아님 / 페이팔 미등록 (잠금을 잡은 뒤의 값)
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'bundle_index', it.bundle_index,
             'settlement_id', it.id,
             'reason', CASE
                         WHEN s.id IS NULL           THEN 'bundle_not_found'
                         WHEN s.status <> 'pending'  THEN 'bundle_not_pending'
                         ELSE                             'bundle_paypal_missing'
                       END) ORDER BY it.seq)
      FROM jsonb_to_recordset(v_items) AS it(seq integer, bundle_index integer, kind text, id uuid)
      LEFT JOIN public.settlements s ON s.id = it.id
      LEFT JOIN public.influencers i ON i.id = s.influencer_id
     WHERE it.kind = 's'
       AND (s.id IS NULL OR s.status <> 'pending' OR NULLIF(btrim(i.paypal_email), '') IS NULL)
  ), '[]'::jsonb);

  -- 6-d) 미등록 응모 항목 — 헬퍼 사유 → 묶음 사유 (already_registered = 그 사이 다른 곳이 먼저 등록 = bundle_not_pending)
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'bundle_index', it.bundle_index,
             'application_id', it.id,
             'reason', CASE j.reason
                         WHEN 'not_candidate'      THEN 'bundle_not_candidate'
                         WHEN 'amount_issue'       THEN 'bundle_amount_issue'
                         WHEN 'already_registered' THEN 'bundle_not_pending'
                         WHEN 'paypal_missing'     THEN 'bundle_paypal_missing'
                       END) ORDER BY it.seq)
      FROM jsonb_to_recordset(v_items) AS it(seq integer, bundle_index integer, kind text, id uuid)
      JOIN jsonb_to_recordset(v_judge) AS j(application_id uuid, reason text) ON j.application_id = it.id
     WHERE it.kind = 'a' AND j.reason IS NOT NULL
  ), '[]'::jsonb);

  -- 6-e) 한 묶음 = 한 사람 (묶음의 influencer_id 가 하나여야 한다)
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object('bundle_index', g.bidx, 'reason', 'bundle_mixed_influencer') ORDER BY g.bidx)
      FROM (
        SELECT r.bundle_index AS bidx
          FROM jsonb_to_recordset(v_res) AS r(bundle_index integer, influencer_id uuid)
         WHERE r.influencer_id IS NOT NULL
         GROUP BY r.bundle_index
        HAVING count(DISTINCT r.influencer_id) > 1
      ) g
  ), '[]'::jsonb);

  -- 6-f) 건별 금액 키가 그 묶음의 어떤 항목과도 안 맞음 — 조용히 무시하면 계산값으로 기록되므로 실패로 잡는다
  v_fail := v_fail || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'bundle_index', b.bidx, 'item_key', ia.key, 'reason', 'bundle_amount_invalid') ORDER BY b.bidx, ia.key)
      FROM (
        SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
          FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
      ) b
      CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(b.e -> 'item_amounts') = 'object'
                                         THEN b.e -> 'item_amounts' ELSE '{}'::jsonb END) AS ia
     WHERE NOT EXISTS (
             SELECT 1 FROM jsonb_to_recordset(v_items) AS it(bundle_index integer, id uuid)
              WHERE it.bundle_index = b.bidx AND it.id::text = lower(ia.key))
  ), '[]'::jsonb);

  -- ── 7) 하나라도 걸렸으면 아무것도 쓰지 않고 사유 목록 반환 ──
  IF jsonb_array_length(v_fail) > 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'failures', (
        SELECT jsonb_agg(f.elem ORDER BY (f.elem ->> 'bundle_index')::integer, f.ord)
          FROM jsonb_array_elements(v_fail) WITH ORDINALITY AS f(elem, ord)
      )
    );
  END IF;

  -- ── 8) 쓰기 — 여기부터의 예상 밖 오류는 예외로 전체 롤백 ──
  SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
  END IF;

  FOR v_b IN
    SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
      FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
     ORDER BY o.ord
  LOOP
    v_sent   := (v_b.e ->> 'sent_at')::timestamptz;
    v_memo   := COALESCE(NULLIF(btrim(v_b.e ->> 'memo'), ''), '송금 묶음 기록');
    v_txn    := NULLIF(btrim(v_b.e ->> 'paypal_txn_id'), '');
    v_source := v_b.e ->> 'source';

    SELECT (array_agg(r.influencer_id))[1], sum(r.amount)::bigint
      INTO v_inf, v_total
      FROM jsonb_to_recordset(v_res) AS r(bundle_index integer, influencer_id uuid, amount bigint)
     WHERE r.bundle_index = v_b.bidx;

    -- 수수료: 값을 넘기면 그 값 + 「손으로 고침」(계산값과 같아도), 비우면 규칙 계산
    IF NULLIF(v_b.e ->> 'fee_jpy', '') IS NOT NULL THEN
      v_fee    := (v_b.e ->> 'fee_jpy')::numeric::bigint;
      v_manual := true;
    ELSE
      v_fee    := public._settlement_fee_calc(v_total, v_rule.rate_percent, v_rule.fixed_jpy, v_rule.rounding);
      v_manual := false;
    END IF;

    -- PayPal 최신값 재조회(마스킹 뷰 우회 — 343·416 과 같은 방식). 검사 뒤에 지워졌으면 전체 롤백.
    SELECT NULLIF(btrim(i.paypal_email), '') INTO v_paypal
      FROM public.influencers i WHERE i.id = v_inf;
    IF v_paypal IS NULL THEN
      RAISE EXCEPTION 'bundle_paypal_missing: PayPal 이메일이 등록되지 않아 송금 기록할 수 없습니다 (인플루언서: %)', v_inf
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.settlement_transfers (
      sent_at, influencer_id, sent_total_jpy, fee_jpy,
      fee_rate_percent, fee_fixed_jpy, fee_rounding, fee_manual,
      paypal_txn_id, memo, source, recorded_by
    ) VALUES (
      v_sent, v_inf, v_total, v_fee,
      v_rule.rate_percent, v_rule.fixed_jpy, v_rule.rounding, v_manual,
      v_txn, NULLIF(btrim(v_b.e ->> 'memo'), ''), v_source, auth.uid()
    )
    RETURNING id INTO v_tid;

    FOR v_it IN
      SELECT r.seq, r.kind, r.id, r.amount
        FROM jsonb_to_recordset(v_res) AS r(seq integer, bundle_index integer, kind text, id uuid, amount bigint)
       WHERE r.bundle_index = v_b.bidx
       ORDER BY r.seq
    LOOP
      IF v_it.kind = 'a' THEN
        -- 미등록 응모: 339 와 같은 칸으로 정산 행을 만든다(먼저 정산대기 → 아래에서 송금완료로 — 이력이 일반 경로와 같아진다)
        SELECT * INTO v_j
          FROM jsonb_to_recordset(v_judge) AS j(
                 application_id uuid, influencer_id uuid, campaign_id uuid, amount_jpy bigint,
                 amount_source text, reward_part_jpy bigint, receipt_amount_jpy bigint,
                 amount_cap_jpy bigint, cert_at timestamptz, paypal_email text)
         WHERE j.application_id = v_it.id;

        v_sid := NULL;
        INSERT INTO public.settlements (
          influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
          receipt_amount_jpy, amount_cap_jpy, cert_at, status, paypal_email
        ) VALUES (
          v_j.influencer_id, v_j.application_id, v_j.campaign_id, v_j.amount_jpy, v_j.amount_source, v_j.reward_part_jpy,
          v_j.receipt_amount_jpy, v_j.amount_cap_jpy, v_j.cert_at, 'pending', NULLIF(v_j.paypal_email, '')
        )
        ON CONFLICT (application_id) DO NOTHING
        RETURNING id INTO v_sid;

        -- 검사 뒤 다른 곳(자동 등록 등)이 먼저 만들었다 → 부분 기록 없이 전체 롤백
        IF v_sid IS NULL THEN
          RAISE EXCEPTION 'bundle_not_pending: 검사 뒤 다른 처리가 먼저 정산을 등록했습니다 (응모: %)', v_it.id
            USING ERRCODE = '22023';
        END IF;

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (v_sid, 'create', NULL, 'pending', auth.uid(), v_memo);
      ELSE
        v_sid := v_it.id;
      END IF;

      INSERT INTO public.settlement_transfer_items (transfer_id, settlement_id, amount_jpy)
      VALUES (v_tid, v_sid, v_it.amount);

      UPDATE public.settlements s
         SET status              = 'paid',
             paid_at             = v_sent,
             paid_by             = auth.uid(),
             paid_amount_jpy     = v_it.amount,          -- 항상 숫자(NULL 금지 — 불변식 ②)
             paypal_email        = v_paypal,
             current_transfer_id = v_tid,
             -- 메모는 덮어쓰지 않고 덧붙인다(340 과 같음)
             memo                = CASE
                                     WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_memo
                                     ELSE s.memo || E'\n' || v_memo
                                   END,
             version             = s.version + 1
       WHERE s.id = v_sid;

      -- 금전 감사 이력: 항상 남는다. 알림은 만들지 않는다(343).
      INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
      VALUES (v_sid, 'pay', 'pending', 'paid', auth.uid(), v_memo);

      v_count := v_count + 1;
    END LOOP;

    INSERT INTO public.settlement_transfer_events (transfer_id, action, prev, next, memo, actor, actor_name)
    VALUES (
      v_tid, 'create', NULL,
      jsonb_build_object(
        'sent_at', v_sent, 'sent_total_jpy', v_total, 'fee_jpy', v_fee, 'fee_manual', v_manual,
        'fee_rate_percent', v_rule.rate_percent, 'fee_fixed_jpy', v_rule.fixed_jpy, 'fee_rounding', v_rule.rounding,
        'paypal_txn_id', v_txn, 'source', v_source,
        'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('settlement_id', ti.settlement_id, 'amount_jpy', ti.amount_jpy)
                                            ORDER BY ti.created_at, ti.id), '[]'::jsonb)
                    FROM public.settlement_transfer_items ti WHERE ti.transfer_id = v_tid)
      ),
      NULLIF(btrim(v_b.e ->> 'memo'), ''), auth.uid(), v_actor_name
    );

    v_tids      := v_tids || jsonb_build_array(v_tid);
    v_fee_total := v_fee_total + v_fee;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'transfer_ids', v_tids,
    'settlement_count', v_count,
    'fee_total', v_fee_total
  );
END;
$$;

COMMENT ON FUNCTION public.record_settlement_transfers(jsonb) IS
  '[486] 송금 묶음 기록(페이팔 거래 1건 = 묶음 1개). 먼저 전부 검사해 하나라도 걸리면 아무것도 안 쓰고 {ok:false, failures:[{bundle_index, settlement_id|application_id, reason}]}, '
  '통과하면 묶음·연결·건 갱신(paid_amount_jpy 항상 숫자·current_transfer_id)·이력을 한 트랜잭션으로 쓴다. 수수료는 넘기면 fee_manual=true, 비우면 484 규칙 계산. '
  '알림 없음(343). source=app 묶음이 생기면 옛 송금완료 경로 셋이 payout_bundle_required 로 거부된다 — 운영 SQL 편집기 시험 호출 금지.';

REVOKE ALL ON FUNCTION public.record_settlement_transfers(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_settlement_transfers(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_settlement_transfers(jsonb) TO authenticated;

-- ============================================================
-- 5. [조각 5] correct_settlement_transfer — 묶음 정정
--    인자 NULL = 「그 칸은 안 고침」(341 과 같은 약속). 빈 문자열('')은 거래번호·메모를 **비운다**.
--    네 인자가 모두 NULL 이면 거부(nothing_to_correct).
--    반환 integer = 새 버전(341 과 같은 방식). 버전 충돌 -1. 바뀐 게 없으면 현재 버전을 그대로 돌려준다.
--    · 송금일을 고치면 「current_transfer_id = 이 묶음」인 건들의 paid_at 만 함께 고친다(건마다 settlement_events 'correct' 한 줄 — 감사).
--      보류 해제로 연결이 끊긴 건(current_transfer_id NULL)은 안 건드린다.
--    · 수수료를 넘기면 fee_manual=true (계산값과 같아도).
--    · 이력은 settlement_transfer_events('correct', 바뀌기 전·후 다섯 칸 jsonb).
--    · 잠금 순서: 묶음 → 그 묶음의 건(id 순).
-- ============================================================
CREATE OR REPLACE FUNCTION public.correct_settlement_transfer(
  p_transfer_id    uuid,
  p_version        integer,
  p_sent_at        timestamptz,
  p_fee_jpy        bigint,
  p_paypal_txn_id  text,
  p_memo           text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_t            record;
  v_s            record;
  v_new_sent     timestamptz;
  v_new_fee      bigint;
  v_new_manual   boolean;
  v_new_txn      text;
  v_new_memo     text;
  v_new_version  integer;
  v_actor_name   text;
  v_ev_memo      text;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  IF p_sent_at IS NULL AND p_fee_jpy IS NULL AND p_paypal_txn_id IS NULL AND p_memo IS NULL THEN
    RAISE EXCEPTION 'nothing_to_correct: 고칠 항목(송금일·수수료·거래번호·메모)을 하나 이상 지정해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- 앞날 날짜 방어 (339·341 과 같은 기준·같은 이유)
  IF p_sent_at IS NOT NULL AND p_sent_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'sent_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_sent_at USING ERRCODE = '22023';
  END IF;

  IF p_fee_jpy IS NOT NULL AND p_fee_jpy < 0 THEN
    RAISE EXCEPTION 'bundle_amount_invalid: 수수료는 0 이상이어야 합니다 (입력값: %)', p_fee_jpy USING ERRCODE = '22023';
  END IF;

  IF char_length(btrim(COALESCE(p_paypal_txn_id, ''))) > 100 THEN
    RAISE EXCEPTION 'bundle_txn_id_invalid: 거래번호는 100자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 묶음 잠금 ──
  SELECT * INTO v_t FROM public.settlement_transfers t WHERE t.id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '송금 묶음을 찾을 수 없습니다 (id: %)', p_transfer_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) — 341 과 같은 약속 ──
  IF v_t.version <> p_version THEN
    RETURN -1;
  END IF;

  v_new_sent   := COALESCE(p_sent_at, v_t.sent_at);
  v_new_fee    := COALESCE(p_fee_jpy, v_t.fee_jpy);
  v_new_manual := v_t.fee_manual OR (p_fee_jpy IS NOT NULL);
  v_new_txn    := CASE WHEN p_paypal_txn_id IS NULL THEN v_t.paypal_txn_id ELSE NULLIF(btrim(p_paypal_txn_id), '') END;
  v_new_memo   := CASE WHEN p_memo IS NULL THEN v_t.memo ELSE NULLIF(btrim(p_memo), '') END;

  -- 값이 실제로는 하나도 안 바뀌는 호출 — 이력만 늘어나므로 아무것도 안 하고 현재 판을 돌려준다(341 과 같음)
  IF v_new_sent   IS NOT DISTINCT FROM v_t.sent_at
     AND v_new_fee    = v_t.fee_jpy
     AND v_new_manual = v_t.fee_manual
     AND v_new_txn    IS NOT DISTINCT FROM v_t.paypal_txn_id
     AND v_new_memo   IS NOT DISTINCT FROM v_t.memo THEN
    RETURN v_t.version;
  END IF;

  -- ── 송금일이 바뀌면 이 묶음이 현재 묶음인 건들의 paid_at 만 따라온다(불변식 ①) ──
  IF v_new_sent IS DISTINCT FROM v_t.sent_at THEN
    FOR v_s IN
      SELECT s.id, s.status, s.paid_at
        FROM public.settlements s
       WHERE s.current_transfer_id = p_transfer_id
       ORDER BY s.id
         FOR UPDATE OF s
    LOOP
      UPDATE public.settlements s
         SET paid_at = v_new_sent, version = s.version + 1
       WHERE s.id = v_s.id;

      INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
      VALUES (v_s.id, 'correct', v_s.status, v_s.status, auth.uid(),
              format('송금 묶음 송금일 정정 [송금일 %s → %s]',
                     COALESCE(to_char(v_s.paid_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'), '(없음)'),
                     to_char(v_new_sent AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD')));
    END LOOP;
  END IF;

  UPDATE public.settlement_transfers t
     SET sent_at       = v_new_sent,
         fee_jpy       = v_new_fee,
         fee_manual    = v_new_manual,
         paypal_txn_id = v_new_txn,
         memo          = v_new_memo,
         version       = t.version + 1
   WHERE t.id = p_transfer_id
   RETURNING t.version INTO v_new_version;

  SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;
  v_ev_memo := CASE WHEN p_memo IS NULL THEN NULL ELSE NULLIF(btrim(p_memo), '') END;

  INSERT INTO public.settlement_transfer_events (transfer_id, action, prev, next, memo, actor, actor_name)
  VALUES (
    p_transfer_id, 'correct',
    jsonb_build_object('sent_at', v_t.sent_at, 'fee_jpy', v_t.fee_jpy, 'fee_manual', v_t.fee_manual,
                       'paypal_txn_id', v_t.paypal_txn_id, 'memo', v_t.memo),
    jsonb_build_object('sent_at', v_new_sent, 'fee_jpy', v_new_fee, 'fee_manual', v_new_manual,
                       'paypal_txn_id', v_new_txn, 'memo', v_new_memo),
    v_ev_memo, auth.uid(), v_actor_name
  );

  -- ⚠️ 알림 없음(343)
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) IS
  '[486] 송금 묶음 정정. 인자 NULL = 안 고침(빈 문자열은 거래번호·메모를 비움), 모두 NULL 이면 거부. 버전 충돌 -1, 변경 없으면 현재 버전. '
  '송금일을 고치면 current_transfer_id=이 묶음인 건들의 paid_at 만 함께 고친다(건마다 settlement_events correct). 수수료를 넘기면 fee_manual=true. 이력은 settlement_transfer_events.';

REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) TO authenticated;

-- ============================================================
-- 6. [조각 5] correct_settlement_payment 재정의 — 베이스 341 (서명 불변)
--    바꾼 것:
--      ① 현재 묶음(current_transfer_id)이 있으면 묶음을 **먼저** 잠근 뒤 건을 잠근다(correct_settlement_transfer 와 같은 순서 — 교착 방지).
--         그 사이 현재 묶음이 바뀌었으면 -1(충돌).
--      ② 현재 묶음이 있는 건에 p_paid_at 이 지금 값과 다르게 오면 거부 paid_at_owned_by_transfer
--         (송금일은 묶음 정정으로만 — 값이 같으면 통과).
--      ③ 금액이 실제로 바뀌면: 그 건의 현재 연결 금액 갱신 → 묶음 합(연결 행 전체 합) 재계산 →
--         묶음이 fee_manual=false 이고 규칙 스냅샷이 있으면 스냅샷으로 수수료 재계산 / fee_manual=true 면 수수료 그대로 →
--         묶음 이력 'correct'.
--      ④ 현재 묶음이 없으면 종전(341)대로 건만 고친다.
--    ⚠️ 묶음 합은 **묶음에 속한 모든 연결 행**의 합이다(보류 해제로 끊긴 건의 연결 행도 실제로 나간 돈이라 포함).
--    ⚠️ settlement_events.action 검사 제약은 안 넓힌다(341 이 넣은 7종 그대로).
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
  -- [486]
  v_pre_transfer uuid;
  v_t            record;
  v_new_total    bigint;
  v_new_fee      bigint;
  v_actor_name   text;
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

  -- ★ [486] 현재 묶음이 있으면 묶음부터 잠근다(잠금 순서 = 묶음 → 건). 건을 잠근 뒤 다시 확인한다.
  SELECT s0.current_transfer_id INTO v_pre_transfer
    FROM public.settlements s0 WHERE s0.id = p_settlement_id;
  IF v_pre_transfer IS NOT NULL THEN
    PERFORM 1 FROM public.settlement_transfers t0 WHERE t0.id = v_pre_transfer FOR UPDATE;
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT s.id, s.status, s.version, s.paid_at, s.paid_amount_jpy, s.amount_jpy, s.current_transfer_id
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

  -- ★ [486] 묶음을 잠근 뒤 건을 잠그는 사이 현재 묶음이 바뀌었다 → 충돌로 돌려보낸다
  IF v_row.current_transfer_id IS DISTINCT FROM v_pre_transfer THEN
    RETURN -1;
  END IF;

  -- ── 송금완료 건만 정정 대상 ───────────────────────────────────
  --   ⚠️ 보류·취소 건에는 쓰지 않는다. 그 상태의 송금 기록을 고치면
  --      「보낸 적 없는데 보낸 날짜가 있는」 행이 생긴다.
  IF v_row.status <> 'paid' THEN
    RAISE EXCEPTION '송금완료(paid) 건만 정정할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- ★ [486] 현재 묶음이 있는 건의 송금일은 묶음(sent_at)이 정본이다 — 여기서는 못 바꾼다.
  --   (금액이 함께 오더라도 거부. 지금 값과 같은 날짜를 다시 넘기는 것은 통과)
  IF v_row.current_transfer_id IS NOT NULL
     AND p_paid_at IS NOT NULL
     AND p_paid_at IS DISTINCT FROM v_row.paid_at THEN
    RAISE EXCEPTION 'paid_at_owned_by_transfer: 이 건의 송금일은 송금 묶음이 정합니다 — 「송금 내역」에서 묶음 단위로 고치세요'
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

  -- ★ [486] 금액이 실제로 바뀌었고 현재 묶음이 있으면: 연결 금액 → 묶음 합 → (자동이면) 수수료를 함께 고친다(불변식 ②)
  IF v_row.current_transfer_id IS NOT NULL
     AND p_paid_amount_jpy IS NOT NULL
     AND v_row.paid_amount_jpy IS DISTINCT FROM p_paid_amount_jpy THEN

    UPDATE public.settlement_transfer_items ti
       SET amount_jpy = p_paid_amount_jpy
     WHERE ti.settlement_id = p_settlement_id
       AND ti.transfer_id   = v_row.current_transfer_id
       AND ti.revert_event_id IS NULL;

    -- 현재 연결이 없으면 불변식이 이미 깨진 데이터 — 조용히 넘기지 않고 전체 롤백
    IF NOT FOUND THEN
      RAISE EXCEPTION 'transfer_item_missing: 현재 묶음의 연결 행을 찾을 수 없습니다 (정산: %, 묶음: %)',
        p_settlement_id, v_row.current_transfer_id USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_t FROM public.settlement_transfers t WHERE t.id = v_row.current_transfer_id;  -- 위에서 이미 잠금

    SELECT COALESCE(sum(ti.amount_jpy), 0)::bigint INTO v_new_total
      FROM public.settlement_transfer_items ti WHERE ti.transfer_id = v_row.current_transfer_id;

    v_new_fee := v_t.fee_jpy;
    IF NOT v_t.fee_manual
       AND v_t.fee_rate_percent IS NOT NULL AND v_t.fee_fixed_jpy IS NOT NULL AND v_t.fee_rounding IS NOT NULL THEN
      v_new_fee := public._settlement_fee_calc(v_new_total, v_t.fee_rate_percent, v_t.fee_fixed_jpy, v_t.fee_rounding);
    END IF;

    UPDATE public.settlement_transfers t
       SET sent_total_jpy = v_new_total,
           fee_jpy        = v_new_fee,
           version        = t.version + 1
     WHERE t.id = v_row.current_transfer_id;

    SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;

    INSERT INTO public.settlement_transfer_events (transfer_id, action, prev, next, memo, actor, actor_name)
    VALUES (
      v_row.current_transfer_id, 'correct',
      jsonb_build_object('sent_total_jpy', v_t.sent_total_jpy, 'fee_jpy', v_t.fee_jpy),
      jsonb_build_object('sent_total_jpy', v_new_total, 'fee_jpy', v_new_fee),
      '건별 송금액 정정 — ' || v_event_memo, auth.uid(), v_actor_name
    );
  END IF;

  -- ⚠️ 알림 없음 — 341 머리말 참조(이미 「보냈다」고 알린 건의 숫자 정정이다).

  SELECT s.version INTO v_new_version FROM public.settlements s WHERE s.id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.correct_settlement_payment(uuid, integer, timestamptz, bigint, text) IS
  '이미 송금완료된 정산의 실제 송금일·송금액만 정정. status·amount_jpy(계산값)는 안 바꾸고 알림도 없다. '
  '인자 NULL 은 「그 칸은 안 고침」이며, 둘 다 NULL 이면 거부. 사유(메모) 필수. '
  '낙관적 잠금 충돌 시 -1(222·241 과 같은 약속). settlement_events 에 action=correct + 전·후 값을 문장으로 남긴다. '
  '보류·취소 건에는 쓸 수 없다(보낸 적 없는데 송금일이 있는 행을 만들지 않기 위해). '
  '[486] 현재 송금 묶음이 있는 건: 송금일이 지금 값과 다르면 paid_at_owned_by_transfer 로 거부(묶음 정정으로만), '
  '금액을 바꾸면 현재 연결 금액·묶음 합을 함께 고치고 수수료는 fee_manual=false 일 때만 스냅샷으로 재계산. 묶음이 없으면 종전대로.';

-- 권한은 CREATE OR REPLACE 로 보존된다(341 이 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ============================================================
-- 7. [조각 5] mark_settlement_revert 재정의 — 베이스 416 (서명 불변)
--    바꾼 것: 이력 INSERT 에 RETURNING id INTO v_event_id → 그 건의 현재 연결(revert_event_id IS NULL)에
--             revert_event_id = 이 이력 id 를 적고, 정산 행의 current_transfer_id 를 NULL 로.
--    🔴 연결 행은 지우지 않는다 — 그 송금은 실제로 나갔다(D-5). 416 의 「송금 기록 3칸 비우기」·이력 메모는 그대로.
--    ⚠️ 보류(mark_settlement_hold)·취소(223)는 current_transfer_id 를 안 건드린다(환수 근거 보존) — 해제할 때만 끊긴다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_settlement_revert(
  p_settlement_id uuid,
  p_version       integer,
  p_memo          text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row         record;
  v_new_version integer;
  v_event_memo  text;
  v_event_id    uuid;   -- [486] 방금 넣은 settlement_events 행 id
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 보류 해제 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- [416] 비우기 전 값을 이력에 남기려고 송금 기록 3칸도 함께 읽는다.
  SELECT id, status, version, paid_at, paid_by, paid_amount_jpy, amount_jpy
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  IF v_row.status <> 'on_hold' THEN
    RAISE EXCEPTION '보류(on_hold) 상태만 해제할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- [416] 송금 기록이 있던 행(= paid 에서 보류로 온 행)이면 이력 메모에 옛 값을 적는다.
  --   ⚠️ 「자동 보류」 같은 연속 표현은 쓰지 않는다 — 화면이 그 문자열로 배지를 그린다(302).
  v_event_memo := p_memo;
  IF v_row.paid_at IS NOT NULL OR v_row.paid_amount_jpy IS NOT NULL THEN
    v_event_memo := COALESCE(NULLIF(btrim(p_memo), ''), '보류 해제')
      || E'\n[송금 기록 초기화] 송금일 '
      || COALESCE(to_char(v_row.paid_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI'), '없음')
      || ' · 송금액 '
      || CASE WHEN v_row.paid_amount_jpy IS NULL
              THEN '계산액 그대로(¥' || COALESCE(v_row.amount_jpy::text, '?') || ')'
              ELSE '¥' || v_row.paid_amount_jpy::text
         END
      || ' — 정산대기로 돌아가며 비움';
  END IF;

  -- [416] 정산대기로 돌아가면 「아직 안 보낸」 상태다 — 송금 기록 3칸을 비운다.
  --   paypal_email 은 수신처 스냅샷이라 그대로 둔다(다음 송금완료가 최신값으로 다시 채운다).
  -- [486] 현재 묶음 칸도 함께 비운다(불변식: 묶음이 없으면 paid_at·paid_amount_jpy 도 비어 있다).
  UPDATE public.settlements
     SET status              = 'pending',
         memo                = p_memo,
         paid_at             = NULL,
         paid_by             = NULL,
         paid_amount_jpy     = NULL,
         current_transfer_id = NULL,
         version             = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'revert', v_row.status, 'pending', auth.uid(), v_event_memo)
  RETURNING id INTO v_event_id;

  -- [486] 그 건의 「현재 송금 기록」 연결을 이 보류 해제 이력에 속한 옛 송금으로 바꿔 적는다(연결 행은 지우지 않는다).
  --   없으면(도입 전 송금이거나 애초에 묶음 없음) 0행 — 정상.
  UPDATE public.settlement_transfer_items ti
     SET revert_event_id = v_event_id
   WHERE ti.settlement_id = p_settlement_id
     AND ti.revert_event_id IS NULL;

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_revert(uuid, integer, text) IS
  '[224→416→486] 관리자가 보류(on_hold) 정산을 정산대기(pending)로 되돌리는 RPC. '
  'SECURITY DEFINER, has_permission(''settlement.pay'',''write'') 게이트. 낙관적 락 충돌 시 -1. '
  '[416] paid_at/paid_by/paid_amount_jpy 를 NULL 로 비우고 옛 값은 settlement_events.memo 에 남긴다 '
  '(정산대기에 송금 기록이 남으면 지급 준비 합계가 그 값을 써 과소 송금). paypal_email 은 보존. 인플루언서 알림 없음. '
  '[486] current_transfer_id 를 NULL 로 하고 그 건의 현재 연결(revert_event_id IS NULL)에 이 보류 해제 이력 id 를 적는다(연결 행은 지우지 않는다).';

-- 권한은 CREATE OR REPLACE 로 보존된다(224·416 이 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ============================================================
-- 8. [조각 6] mark_settlement_paid 재정의 — 베이스 343 (5인자 판, 서명 불변)
--    바꾼 것 하나: 권한 확인 바로 뒤에 도입일이 서 있으면 payout_bundle_required. 나머지는 343 그대로.
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_settlement_paid(
  p_settlement_id   uuid,
  p_version         integer,
  p_memo            text,
  p_paid_at         timestamptz DEFAULT NULL,
  p_paid_amount_jpy bigint      DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row          record;
  v_paypal_fresh text;
  v_new_version  integer;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──────────────────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ★ [486] 송금 묶음 도입일 뒤에는 옛 경로를 거부한다(옛 탭이 묶음 없이 송금완료를 만드는 것을 막는다).
  IF public._settlement_transfer_intro_at() IS NOT NULL THEN
    RAISE EXCEPTION 'payout_bundle_required: 송금 기록 방식이 바뀌었습니다. 화면을 새로 고친 뒤 다시 기록해 주세요'
      USING ERRCODE = '22023';
  END IF;

  -- 앞날 날짜 방어. 송금은 앞날에 일어날 수 없다(339 그대로).
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- 금액 방어. 음수·0 은 허용하지 않는다(339 그대로).
  IF p_paid_amount_jpy IS NOT NULL AND p_paid_amount_jpy <= 0 THEN
    RAISE EXCEPTION 'invalid_paid_amount: 송금액은 0보다 커야 합니다 (입력값: %)', p_paid_amount_jpy
      USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, status, version, influencer_id
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) ─────────────────────────
  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  -- ── 상태 전이 검증: pending 만 송금 처리 가능 ───────────────────
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '정산 대기(pending) 상태만 송금 처리할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- ── PayPal 최신값 재조회(마스킹 뷰 우회 — DEFINER 원본 테이블 직접 조회) ──────
  SELECT NULLIF(btrim(paypal_email), '') INTO v_paypal_fresh
    FROM public.influencers
   WHERE id = v_row.influencer_id;

  IF v_paypal_fresh IS NULL THEN
    RAISE EXCEPTION 'PayPal 이메일이 등록되지 않아 송금 처리할 수 없습니다 (인플루언서: %)', v_row.influencer_id
      USING ERRCODE = '22023';
  END IF;

  -- ── settlements UPDATE ──────────────────────────────────────
  UPDATE public.settlements
     SET status       = 'paid',
         paid_at      = COALESCE(p_paid_at, now()),
         paid_amount_jpy = p_paid_amount_jpy,
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  -- ── settlement_events 감사 이력 ─────────────────────────────
  -- 인플루언서 노출·알림과 무관하게 항상 남는다 — 금전 감사는 그대로 유지.
  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  -- [343] 인플루언서 알림(settlement_paid) INSERT 구간을 여기서 제거했다.
  --   241 이 만들고 339 가 문구만 정정했던 `IF public.is_settlement_public() THEN
  --   INSERT INTO public.notifications ... END IF` 블록이 있던 자리다.
  --   settlement_events 감사 이력은 위에서 그대로 남는다.

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) IS
  '정산 단건을 송금완료로. [343] 인플루언서 알림(settlement_paid) 발행을 제거 — '
  '사용자 결정(2026-08-19)으로 정산 인플루언서 노출·알림 경로를 아예 없앤다. '
  'settlement_events 감사 이력은 그대로. 339 의 실제 보낸 날짜(p_paid_at)·금액(p_paid_amount_jpy) '
  '인자·방어 로직은 무변경. [486] 송금 묶음 도입일(source=app 묶음 존재) 뒤에는 payout_bundle_required 로 거부 — 새 경로는 record_settlement_transfers.';

-- 권한은 CREATE OR REPLACE 로 보존된다(343 이 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ============================================================
-- 9. [조각 6] mark_settlements_paid_bulk 재정의 — 베이스 416 (서명 불변)
--    바꾼 것 하나: 권한 확인 바로 뒤에 도입일이 서 있으면 payout_bundle_required. 나머지는 416 그대로.
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_settlements_paid_bulk(
  p_settlement_ids uuid[],
  p_paid_at        timestamptz DEFAULT NULL,
  p_memo           text        DEFAULT NULL
)
RETURNS TABLE (
  paid_count                integer,
  skipped_no_paypal_count   integer,
  skipped_not_pending_count integer,
  not_found_count           integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id            uuid;
  v_row           record;
  v_paypal_fresh  text;
  v_paid_at       timestamptz;
  v_memo          text;
  v_paid          integer := 0;
  v_skip_paypal   integer := 0;
  v_skip_status   integer := 0;
  v_missing       integer := 0;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write (340 과 동일) ──────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ★ [486] 송금 묶음 도입일 뒤에는 옛 경로를 거부한다.
  IF public._settlement_transfer_intro_at() IS NOT NULL THEN
    RAISE EXCEPTION 'payout_bundle_required: 송금 기록 방식이 바뀌었습니다. 화면을 새로 고친 뒤 다시 기록해 주세요'
      USING ERRCODE = '22023';
  END IF;

  -- ⚠️ 「비었나」를 길이만으로 보면 안 된다(340 그대로). `[null]` 은 길이가 1이라
  --   이 검사를 통과한 뒤 반복문에서 걸러져 네 건수가 전부 0인 채 조용히 성공으로
  --   끝난다. 실제 값이 하나라도 있는지 본다.
  IF p_settlement_ids IS NULL
     OR array_length(p_settlement_ids, 1) IS NULL
     OR NOT EXISTS (SELECT 1 FROM unnest(p_settlement_ids) AS x WHERE x IS NOT NULL) THEN
    RAISE EXCEPTION 'empty_settlement_ids: 처리할 정산을 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── 앞날 날짜 방어 (340 과 같은 기준) ───────────────────────────
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  v_paid_at := COALESCE(p_paid_at, now());
  v_memo    := COALESCE(NULLIF(btrim(p_memo), ''), '일괄 송금완료');

  -- ⚠️ DISTINCT + ORDER BY — 같은 id 가 두 번 와도 한 번만 처리하고,
  --    항상 같은 순서로 잠가 동시 실행 시 교착을 막는다(340 그대로).
  FOR v_id IN
    SELECT DISTINCT x FROM unnest(p_settlement_ids) AS x WHERE x IS NOT NULL ORDER BY 1
  LOOP
    SELECT s.id, s.status, s.influencer_id, s.memo
      INTO v_row
      FROM public.settlements s
     WHERE s.id = v_id
     FOR UPDATE;

    IF NOT FOUND THEN
      v_missing := v_missing + 1;
      CONTINUE;
    END IF;

    -- 다른 관리자가 먼저 처리했거나 보류·취소된 건 — 건드리지 않는다.
    IF v_row.status <> 'pending' THEN
      v_skip_status := v_skip_status + 1;
      CONTINUE;
    END IF;

    -- 페이팔 최신값 재조회 (마스킹 뷰 우회 — DEFINER 로 원본 표 직접 조회)
    SELECT NULLIF(btrim(i.paypal_email), '')
      INTO v_paypal_fresh
      FROM public.influencers i
     WHERE i.id = v_row.influencer_id;

    IF v_paypal_fresh IS NULL THEN
      v_skip_paypal := v_skip_paypal + 1;
      CONTINUE;
    END IF;

    UPDATE public.settlements s
       SET status          = 'paid',
           paid_at         = v_paid_at,
           paid_by         = auth.uid(),
           -- [416] 일괄은 건별 금액을 받지 않는다 = 「계산액 그대로」. 단건(343)이 인자 없을 때
           --   NULL 로 덮어쓰는 것과 같은 뜻으로 **명시**한다 — 안 적으면 옛 값이 남은 행에서
           --   단건과 일괄이 다른 금액을 기록한다.
           paid_amount_jpy = NULL,
           paypal_email    = v_paypal_fresh,
           -- 메모는 덮어쓰지 않고 덧붙인다(340 그대로).
           memo            = CASE
                               WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_memo
                               ELSE s.memo || E'\n' || v_memo
                             END,
           version         = s.version + 1
     WHERE s.id = v_id;

    -- ── 금전 감사 이력: 항상 남는다 ──────────────────────────────
    INSERT INTO public.settlement_events
      (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_id, 'pay', 'pending', 'paid', auth.uid(), v_memo);

    -- [343] 인플루언서 알림(settlement_paid) INSERT 구간은 343 에서 제거됐고 여기서도 없다.

    v_paid := v_paid + 1;
  END LOOP;

  RETURN QUERY SELECT v_paid, v_skip_paypal, v_skip_status, v_missing;
END;
$$;

COMMENT ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) IS
  '[340→343→416→486] 정산 여러 건을 한 번에 송금완료로. 건너뛴 사유 3종을 각각 센다. '
  '[416] paid_amount_jpy = NULL 을 명시해 단건(mark_settlement_paid)과 같은 칸을 같은 뜻으로 쓴다. '
  '인플루언서 알림 없음(343). [486] 송금 묶음 도입일 뒤에는 payout_bundle_required 로 거부 — 새 경로는 record_settlement_transfers.';

-- 권한은 CREATE OR REPLACE 로 보존된다(224·343 이 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ⚠️ 새 함수를 PostgREST 가 알아보도록 스키마를 다시 읽으라고 알린다(241·324·341 관례).
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩 — ⚠️ 「적용 성공」은 「동작 확인」이 아니다)
-- ⚠️ SQL 편집기는 서비스 키라 has_permission 가드에 막힌다(42501)·auth.uid() 가 비어 관리자 분기가 안 돈다
--    → 호출 검증은 **관리자로 로그인한 브라우저 콘솔**(db.rpc)에서. 편집기로는 [1]·[2]만.
-- 🔴 순서가 중요하다: **[A] 옛 경로 확인을 먼저** 하고, 그 다음에 새 함수를 시험한다.
--    source='app' 묶음이 한 줄이라도 생기면 옛 송금완료 경로 셋이 payout_bundle_required 로 막혀 되돌릴 수 없다
--    (되돌리려면 시험 묶음을 지워야 한다 — 이력·연결이 RESTRICT 라 개발서버에서만, 아래 [Z] 참고).
--    운영에서는 SQL 편집기·브라우저 콘솔로 record_settlement_transfers 를 시험 호출하지 말 것(조각 17 의 첫 기록이 곧 도입일).
-- ============================================================
-- [1] SQL 편집기: 함수 등록·권한 (새 함수 둘 = authenticated 만, 헬퍼 셋 = 아무에게도 안 줌)
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.proacl::text
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('record_settlement_transfers','correct_settlement_transfer',
--                        '_settlement_register_judge','_settlement_transfer_intro_at','_settlement_fee_calc')
--    ORDER BY p.proname;
--   -- 기대: record_/correct_ → proacl 에 authenticated=X, 맨 앞 '=X/' 없음, anon 없음
--   --       헬퍼 셋 → proacl 에 authenticated·anon 없고 맨 앞 '=X/' 없음
-- [2] SQL 편집기: 재정의 다섯이 베이스 본문을 지켰나 (기대: 각 1)
--   SELECT p.proname,
--          pg_get_functiondef(p.oid) LIKE '%_settlement_transfer_intro_at()%' AS has_guard,
--          pg_get_functiondef(p.oid) LIKE '%_settlement_register_judge%'       AS uses_judge,
--          pg_get_functiondef(p.oid) LIKE '%RETURNING id INTO v_event_id%'     AS captures_event_id,
--          pg_get_functiondef(p.oid) LIKE '%paid_at_owned_by_transfer%'        AS owns_paid_at
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('mark_settlement_paid','mark_settlements_paid_bulk','register_past_settlements',
--                        'mark_settlement_revert','correct_settlement_payment');
--   -- 기대: paid·bulk·register → has_guard / register → uses_judge / revert → captures_event_id / correct → owns_paid_at
--   -- (343 의 알림 제거가 살아 있나: mark_settlement_paid 에 is_settlement_public 가 없어야 한다 → LIKE '%is_settlement_public%' = false)
--
-- ── [A] 옛 경로 확인 (묶음 0개 상태 — 새 함수를 시험하기 **전에**) ──
-- [A-1] SQL 편집기: 도입일이 아직 없다
--   SELECT count(*) FROM public.settlement_transfers WHERE source='app';                 -- 0
-- [A-2] 브라우저: 옛 경로가 종전처럼 동작 (없는 id 로 — 본문 통과 확인)
--   await db.rpc('mark_settlement_paid',{p_settlement_id:'00000000-0000-0000-0000-000000000000',p_version:1,p_memo:'시험'})
--     // 기대: 「정산 내역을 찾을 수 없습니다」(02000) — payout_bundle_required 가 아니다
--   await db.rpc('mark_settlements_paid_bulk',{p_settlement_ids:['00000000-0000-0000-0000-000000000000'],p_memo:'시험'})
--     // 기대: not_found_count 1
--   await db.rpc('register_past_settlements',{p_application_ids:['00000000-0000-0000-0000-000000000000'],p_target_status:'paid',p_memo:'시험'})
--     // 기대: registered_count 0 / skipped_no_paypal_count 0 (거부 아님)
--   await db.rpc('register_past_settlements',{p_application_ids:['00000000-0000-0000-0000-000000000000'],p_target_status:'pending',p_memo:'시험'})
--     // 기대: 0 / 0 (pending 은 언제나 통과)
-- [A-3] 조각 3 완료 정의: 재정의 전후 같은 응모 목록을 'pending' 으로 넣었을 때 반환 건수가 같다
--   (시험 응모 몇 건을 골라 이 파일 적용 전·후 각각 부르고 registered_count 를 비교 — 시험 행은 끝나고 정리)
--   ⚠️ 헬퍼 사유 네 종류: 시험 응모로 not_candidate / amount_issue / already_registered / paypal_missing 이 갈리는지
--      → 브라우저에서 직접 부를 수 없다(권한 없음). SQL 편집기(서비스 키)에서:
--      SELECT application_id, ok, reason FROM public._settlement_register_judge(ARRAY['<응모id>','<응모id>']::uuid[]);
--
-- ── [B] 새 기록 함수 (조각 4 완료 정의 — 개발 DB, 관리자 브라우저) ──
-- [B-1] 정산대기 2건 + 미등록 1건을 한 묶음(같은 사람)으로:
--   await db.rpc('record_settlement_transfers',{p_bundles:[{settlement_ids:['<s1>','<s2>'],application_ids:['<a1>'],
--     item_amounts:{}, sent_at:new Date().toISOString(), fee_jpy:null, paypal_txn_id:null, memo:'시험', source:'app'}]})
--   // 기대: {ok:true, transfer_ids:[1개], settlement_count:3, fee_total:…}
--   // 묶음 1·연결 3·건 3개 paid·current_transfer_id 채워짐·paid_amount_jpy 전부 숫자
-- [B-2] 수수료 비우고 합계 ¥3,000 → 수수료 173 (규칙 4.1%+50·round)
-- [B-3] 페이팔 없는 건을 섞으면 {ok:false, failures:[…bundle_paypal_missing…]} 이고 **어떤 행도 안 생긴다**
--       (settlement_transfers·items·events 건수, 해당 건의 status·version 이 호출 전과 같다)
-- [B-4] 같은 건 재기록 → bundle_not_pending / 같은 건 두 번 → bundle_duplicate_item / 두 사람 섞기 → bundle_mixed_influencer
--       미래 날짜 → sent_at_in_future / 빈 묶음 → bundle_empty / 금액 0·소수 → bundle_amount_invalid
-- [B-5] fee_jpy 를 계산값과 똑같이 넘겨도 fee_manual=true
--
-- ── [C] 정정·보류 해제 (조각 5 완료 정의) ──
-- [C-1] correct_settlement_payment 로 금액 정정 → 연결 금액·묶음 합·(fee_manual=false 면) 수수료가 함께 바뀜
-- [C-2] correct_settlement_payment 로 날짜 변경 → paid_at_owned_by_transfer
-- [C-3] correct_settlement_transfer 로 송금일 정정 → 그 묶음이 현재 묶음인 건의 paid_at 이 따라오고 건마다 settlement_events correct 1줄
--       버전 틀리게 → -1 / 네 인자 전부 null → nothing_to_correct
-- [C-4] 보류 → 보류 해제 → current_transfer_id NULL·paid_at/paid_by/paid_amount_jpy NULL, 연결 행은 남고 revert_event_id = 방금 revert 이력 id
-- [C-5] 그 건을 다시 record_settlement_transfers 로 보내면 연결이 두 개(하나는 revert_event_id 있음) — 유일 색인 위반 없음
--
-- ── [D] 옛 경로 거부 (조각 6 완료 정의 — [B] 로 source='app' 묶음이 생긴 **뒤**) ──
-- [D-1] SQL 편집기: SELECT public._settlement_transfer_intro_at();                     -- NULL 아님
-- [D-2] 브라우저: [A-2] 의 mark_settlement_paid·mark_settlements_paid_bulk·register_past_settlements('paid') 세 호출이
--       모두 payout_bundle_required 로 거부, register_past_settlements('pending') 는 계속 성공
-- [D-3] 'sheet_backfill' 묶음만 있으면 거부가 안 켜진다(source 를 그렇게만 넣은 시험은 [A] 를 다시 하기 전에 할 것)
--
-- ── [E] 불변식 점검 (485 [6] 과 같은 조회 — 세 값 모두 0) ──
--   SELECT
--     count(*) FILTER (WHERE it.id IS NULL)                                   AS missing_current_item,
--     count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_at IS DISTINCT FROM t.sent_at)    AS paid_at_mismatch,
--     count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_amount_jpy IS DISTINCT FROM it.amount_jpy) AS amount_mismatch
--     FROM public.settlements s
--     JOIN public.settlement_transfers t ON t.id = s.current_transfer_id
--     LEFT JOIN public.settlement_transfer_items it
--            ON it.settlement_id = s.id AND it.transfer_id = s.current_transfer_id AND it.revert_event_id IS NULL
--    WHERE s.current_transfer_id IS NOT NULL;
--   -- 추가: 묶음 합 = 연결 행 합
--   SELECT count(*) FROM public.settlement_transfers t
--    WHERE t.sent_total_jpy <> (SELECT COALESCE(sum(ti.amount_jpy),0) FROM public.settlement_transfer_items ti WHERE ti.transfer_id = t.id);   -- 0
--
-- ── [Z] 개발서버 정리 (시험 묶음을 지워 옛 경로 거부를 되돌리고 싶을 때 — 개발 DB 한정, 운영 금지) ──
--   시험 정산 행의 current_transfer_id 를 NULL 로 → items → events → transfers 순으로 삭제(모두 RESTRICT 외래 키라 이 순서).
--   ⚠️ items.revert_event_id 가 settlement_events 를 가리키므로 settlement_events 는 지우지 않는다(금전 감사 이력).
