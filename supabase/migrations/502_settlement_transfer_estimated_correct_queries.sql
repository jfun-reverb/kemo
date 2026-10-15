-- 502_settlement_transfer_estimated_correct_queries.sql
-- 추정 표시를 정정으로 지우고, 조회 3개가 추정 표시·「추정 포함 건수」를 돌려준다 (시트 소급 반영 3/3)
-- 사양서: docs/specs/2026-10-01-settlement-sheet-backfill.md 설계 ① (다)·③ · 결정 5·7
-- 작업표: docs/specs/2026-10-02-settlement-sheet-backfill-breakdown.md 「S3」
--
-- 선행: 500(추정 표시 칸 2개) · 486(correct_settlement_transfer 원본) · 487(조회 3개 원본)
--
-- ▶ 이 파일이 하는 일
--   [1] correct_settlement_transfer 재정의 — 베이스 486(인자 그대로 → CREATE OR REPLACE, 실행 권한 보존)
--       486 에서 바꾼 것 셋:
--        ① 송금일 인자가 오면 sent_at_estimated=false, 수수료 인자가 오면 fee_estimated=false.
--           🔴 NULL 인자 칸의 표시는 그대로(정정 창은 바뀐 칸만 보낸다).
--        ② 486 의 「값이 하나도 안 바뀌면 조용히 끝」을 피한다 — 「추정 표시가 켜진 칸에 값이 옴」도 변경으로 센다
--           (같은 값이어도 「사람이 확인함」으로 표시를 지운다).
--        ③ 🔴 넘긴 수수료가 현재 값과 같으면 fee_manual 을 건드리지 않고 fee_estimated 만 지운다(결정 7 — 「값이 맞음」은 「고친 값」이 아니다).
--           다르면 486 처럼 fee_manual=true.
--           ⚠️ 486 은 같은 값이어도 fee_manual=true 로 만들었다. 이제 추정이 아닌 묶음에서 같은 수수료를 다시 넘기면 아무 일도 안 일어난다(변경 없음).
--       이력 형식은 486 유지(settlement_transfer_events 'correct' prev/next 다섯 칸) + 추정 표시 두 칸을 jsonb 에 더하고,
--       추정이 지워졌으면 이력 메모 끝에 「[추정 해제: 송금일, 수수료]」를 붙인다.
--       🔴 prev/next 에 sent_total_jpy 칸을 넣지 않는다 — 487 의 fee_stale 판정이 그 칸 유무로 「건별 금액 정정」과 「묶음 정정」을 가른다.
--   [2] 조회 3개 재생성 — 베이스 487. 반환 칸이 늘어 DROP FUNCTION 후 CREATE(CREATE OR REPLACE 는 반환 칸을 못 바꾼다).
--        get_settlement_transfers        — 묶음 목록에 sent_at_estimated · fee_estimated (fee_manual 바로 뒤)
--        get_settlement_transfer_monthly — 달별에 estimated_count 추가
--        get_settlement_transfer_by_round— 회차별에 estimated_count 추가
--       「추정 포함 건수」 estimated_count = 🔴 송금 묶음 수(정산 건 수가 아니다): 송금일 추정 또는 수수료 추정 표시가 하나라도 있는 묶음의 수.
--         · 월별: 그 달에 속한 묶음 중 추정 표시가 있는 묶음 수(묶음은 송금일 달 하나에만 속한다 → 달 합 = 전체).
--         · 회차별: 그 회차 줄에 기여하는 묶음(항목 하나라도 그 회차이거나, 수수료가 그 회차로 가는 묶음) 중 추정 표시가 있는 묶음 수.
--           한 묶음의 항목이 두 회차에 걸치면 두 줄에 각각 센다 → 회차 줄의 합은 전체 묶음 수보다 클 수 있다(settlement_count 와 같은 성질).
--       화면 문구 「추정 포함 N건」 의 N = 이 값. 건(件)이 정산 건이 아니라 송금 묶음임을 화면 안내에 명시할 것.
--       487 의 나머지(fee_stale·회차 판정·정렬·가드·페이팔 주소 미노출·합계는 저장값만)는 글자 그대로 옮겼다.
--       get_settlement_transfer_unrecorded · _settlement_payout_due 는 건드리지 않는다.
--   🔴 DROP · CREATE · 권한 3줄을 한 트랜잭션에 — 나눠 적용하면 그 사이 화면 조회가 실패하거나, 새 함수가 PUBLIC 실행 권한을 받은 채 남는다.
--
-- ▶ 편집기 경고 — 이 파일은 뜬다(문장 맨 앞 DROP FUNCTION). 무해: 같은 이름·같은 인자의 함수를 아래에서 바로 다시 만들고 권한을 다시 건다.
--
-- ▶ 배포 순서 — 데이터베이스(500 → 501 → 이 파일) 먼저, 화면(추정 배지·정정 창) 나중. 화면이 먼저 나가면 없는 칸을 읽는다.
--   ⚠️ 이 파일 적용 직후 옛 화면은 새 칸을 모를 뿐 그대로 동작한다(이름으로 읽는다).
--
-- 롤백 (역순 — 화면(추정 배지)이 붙은 뒤에는 화면을 먼저 걷을 것):
--   ① 조회 3개를 487 의 해당 블록 그대로 다시 만든다(DROP FUNCTION IF EXISTS … 후 CREATE + 권한 3줄 — 이 파일과 같은 한 트랜잭션 방식).
--   ② correct_settlement_transfer 를 486 의 5절 블록 그대로 CREATE OR REPLACE(권한 보존).
--   ⚠️ 500 의 칸은 이 파일이 되돌려진 뒤에만 지울 수 있다.

BEGIN;

-- ============================================================
-- 1. correct_settlement_transfer — 베이스 486, 서명 불변
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
  -- [502]
  v_new_sent_est boolean;
  v_new_fee_est  boolean;
  v_cleared      text[] := ARRAY[]::text[];
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
  -- ★ [502] 넘긴 수수료가 현재 값과 같으면 fee_manual 을 건드리지 않는다(「값이 맞음」은 「고친 값」이 아니다 — 결정 7).
  --        다르면 486 처럼 fee_manual=true.
  v_new_manual := CASE
                    WHEN p_fee_jpy IS NULL          THEN v_t.fee_manual
                    WHEN p_fee_jpy = v_t.fee_jpy    THEN v_t.fee_manual
                    ELSE                                 true
                  END;
  v_new_txn    := CASE WHEN p_paypal_txn_id IS NULL THEN v_t.paypal_txn_id ELSE NULLIF(btrim(p_paypal_txn_id), '') END;
  v_new_memo   := CASE WHEN p_memo IS NULL THEN v_t.memo ELSE NULLIF(btrim(p_memo), '') END;

  -- ★ [502] 값을 넘긴 칸의 추정 표시는 지운다. 넘기지 않은(NULL) 칸의 표시는 그대로.
  v_new_sent_est := CASE WHEN p_sent_at  IS NOT NULL THEN false ELSE v_t.sent_at_estimated END;
  v_new_fee_est  := CASE WHEN p_fee_jpy  IS NOT NULL THEN false ELSE v_t.fee_estimated     END;

  -- 값이 실제로는 하나도 안 바뀌는 호출 — 이력만 늘어나므로 아무것도 안 하고 현재 판을 돌려준다(341 과 같음).
  -- ★ [502] 추정 표시가 바뀌는 것도 변경으로 센다(같은 값을 「맞음」으로 확인해 표시만 지우는 경우).
  IF v_new_sent   IS NOT DISTINCT FROM v_t.sent_at
     AND v_new_fee    = v_t.fee_jpy
     AND v_new_manual = v_t.fee_manual
     AND v_new_txn    IS NOT DISTINCT FROM v_t.paypal_txn_id
     AND v_new_memo   IS NOT DISTINCT FROM v_t.memo
     AND v_new_sent_est = v_t.sent_at_estimated
     AND v_new_fee_est  = v_t.fee_estimated THEN
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
     SET sent_at           = v_new_sent,
         fee_jpy           = v_new_fee,
         fee_manual        = v_new_manual,
         paypal_txn_id     = v_new_txn,
         memo              = v_new_memo,
         sent_at_estimated = v_new_sent_est,
         fee_estimated     = v_new_fee_est,
         version           = t.version + 1
   WHERE t.id = p_transfer_id
   RETURNING t.version INTO v_new_version;

  SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;

  -- 이력 메모: 입력한 메모(486 과 같음) + 추정이 지워졌으면 그 사실
  IF v_t.sent_at_estimated AND NOT v_new_sent_est THEN v_cleared := array_append(v_cleared, '송금일'::text); END IF;
  IF v_t.fee_estimated     AND NOT v_new_fee_est  THEN v_cleared := array_append(v_cleared, '수수료'::text); END IF;
  v_ev_memo := CASE WHEN p_memo IS NULL THEN NULL ELSE NULLIF(btrim(p_memo), '') END;
  IF array_length(v_cleared, 1) IS NOT NULL THEN
    v_ev_memo := COALESCE(v_ev_memo || ' ', '') || '[추정 해제: ' || array_to_string(v_cleared, ', ') || ']';
  END IF;

  INSERT INTO public.settlement_transfer_events (transfer_id, action, prev, next, memo, actor, actor_name)
  VALUES (
    p_transfer_id, 'correct',
    jsonb_build_object('sent_at', v_t.sent_at, 'fee_jpy', v_t.fee_jpy, 'fee_manual', v_t.fee_manual,
                       'paypal_txn_id', v_t.paypal_txn_id, 'memo', v_t.memo,
                       'sent_at_estimated', v_t.sent_at_estimated, 'fee_estimated', v_t.fee_estimated),
    jsonb_build_object('sent_at', v_new_sent, 'fee_jpy', v_new_fee, 'fee_manual', v_new_manual,
                       'paypal_txn_id', v_new_txn, 'memo', v_new_memo,
                       'sent_at_estimated', v_new_sent_est, 'fee_estimated', v_new_fee_est),
    v_ev_memo, auth.uid(), v_actor_name
  );

  -- ⚠️ 알림 없음(343)
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) IS
  '[502] 송금 묶음 정정(베이스 486). 인자 NULL = 안 고침(빈 문자열은 거래번호·메모를 비움), 모두 NULL 이면 거부. 버전 충돌 -1, 변경 없으면 현재 버전. '
  '송금일을 고치면 current_transfer_id=이 묶음인 건들의 paid_at 만 함께 고친다. 수수료가 현재 값과 다르면 fee_manual=true, 같으면 fee_manual 그대로. '
  '송금일을 넘기면 sent_at_estimated=false, 수수료를 넘기면 fee_estimated=false(같은 값이어도 — 「값이 맞음」). NULL 칸의 추정 표시는 그대로. 이력은 settlement_transfer_events.';

-- 권한은 CREATE OR REPLACE 로 보존되지만, 환경 차이를 막으려고 같은 3줄을 다시 건다(멱등)
REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text) TO authenticated;

-- ============================================================
-- 2. 조회 3개 — 베이스 487, 반환 칸이 늘어 DROP 후 CREATE (같은 트랜잭션에서 권한까지)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_settlement_transfers(date, date);
DROP FUNCTION IF EXISTS public.get_settlement_transfer_monthly(date, date);
DROP FUNCTION IF EXISTS public.get_settlement_transfer_by_round(date, date);

-- ── 2-1. get_settlement_transfers — 묶음 1줄 + 포함 건 jsonb (+ sent_at_estimated · fee_estimated) ──
CREATE FUNCTION public.get_settlement_transfers(p_from date, p_to date)
RETURNS TABLE (
  id                uuid,
  sent_at           timestamptz,
  influencer_id     uuid,
  influencer_name   text,
  sent_total_jpy    bigint,
  fee_jpy           bigint,
  fee_manual        boolean,
  sent_at_estimated boolean,
  fee_estimated     boolean,
  fee_rate_percent  numeric,
  fee_fixed_jpy     integer,
  fee_rounding      text,
  fee_rule_jpy      bigint,
  paypal_txn_id     text,
  memo              text,
  source            text,
  recorded_by       uuid,
  recorded_by_name  text,
  recorded_at       timestamptz,
  version           integer,
  total_spend_jpy   bigint,
  fee_stale         boolean,
  items             jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT t.id,
         t.sent_at,
         t.influencer_id,
         i.name,
         t.sent_total_jpy,
         t.fee_jpy,
         t.fee_manual,
         t.sent_at_estimated,
         t.fee_estimated,
         t.fee_rate_percent,
         t.fee_fixed_jpy,
         t.fee_rounding,
         -- fee_rule_jpy — 저장된 규칙 스냅샷으로 다시 계산한 수수료(2026-10-02 사용자 결정 ①: 고친 값이면 「규칙 계산 · 실제 · 차이」).
         --   🔴 계산식은 _settlement_fee_calc 한 곳 — 화면에 식을 두지 않는다. 스냅샷이 하나라도 비면 NULL(시트 실제값 묶음 — 결정 6)
         CASE WHEN t.fee_rate_percent IS NOT NULL AND t.fee_fixed_jpy IS NOT NULL AND t.fee_rounding IS NOT NULL
              THEN public._settlement_fee_calc(t.sent_total_jpy, t.fee_rate_percent, t.fee_fixed_jpy, t.fee_rounding)
         END,
         t.paypal_txn_id,
         t.memo,
         t.source,
         t.recorded_by,
         (SELECT a.name FROM public.admins a WHERE a.auth_id = t.recorded_by LIMIT 1),
         t.recorded_at,
         t.version,
         (t.sent_total_jpy + t.fee_jpy),
         -- [2] fee_stale — 487 머리말 규칙 그대로
         (t.fee_manual AND EXISTS (
            SELECT 1
              FROM public.settlement_transfer_events pe
             WHERE pe.transfer_id = t.id
               AND pe.action = 'correct'
               AND pe.prev ? 'sent_total_jpy'
               AND pe.next ? 'sent_total_jpy'
               AND (pe.prev ->> 'sent_total_jpy') IS DISTINCT FROM (pe.next ->> 'sent_total_jpy')
               AND pe.at > COALESCE((
                     SELECT max(fe.at)
                       FROM public.settlement_transfer_events fe
                      WHERE fe.transfer_id = t.id
                        AND (fe.action = 'create'
                             OR (fe.action = 'correct'
                                 AND NOT (fe.prev ? 'sent_total_jpy')
                                 AND (fe.prev ->> 'fee_jpy') IS DISTINCT FROM (fe.next ->> 'fee_jpy')))
                   ), '-infinity'::timestamptz)
         )),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'settlement_id',   ti.settlement_id,
                    'application_id',  s.application_id,
                    'campaign_id',     s.campaign_id,
                    'campaign_no',     c.campaign_no,
                    'campaign_title',  c.title,
                    'amount_jpy',      ti.amount_jpy,
                    'due_date',        public._settlement_payout_due(s.cert_at),
                    'cert_at',         s.cert_at,
                    'is_current',      (ti.revert_event_id IS NULL),
                    'revert_event_id', ti.revert_event_id
                  ) ORDER BY ti.created_at, ti.id)
             FROM public.settlement_transfer_items ti
             JOIN public.settlements s ON s.id = ti.settlement_id
             LEFT JOIN public.campaigns c ON c.id = s.campaign_id
            WHERE ti.transfer_id = t.id
         ), '[]'::jsonb)
    FROM public.settlement_transfers t
    LEFT JOIN public.influencers i ON i.id = t.influencer_id
   WHERE (p_from IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date >= p_from)
     AND (p_to   IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date <= p_to)
   ORDER BY t.sent_at, t.id;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfers(date, date) IS
  '[502] 송금 묶음 목록(송금일=일본 날짜 기준 기간, NULL=열림). 묶음 1줄 + items(포함 건: 캠페인·연결 금액·원래 지급 예정일·현재 연결 여부) + fee_stale + 추정 표시(sent_at_estimated·fee_estimated) + fee_rule_jpy(스냅샷 규칙 계산값, 스냅샷 없으면 NULL). '
  '정렬 sent_at,id 유일. 페이팔 주소 미노출. fee_stale 규칙은 487 머리말 [2].';

REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfers(date, date) TO authenticated;

-- ── 2-2. get_settlement_transfer_monthly — 송금일(일본 시각) 달별 (+ estimated_count) ──
CREATE FUNCTION public.get_settlement_transfer_monthly(p_from date, p_to date)
RETURNS TABLE (
  month            date,
  transfer_count   bigint,
  settlement_count bigint,
  sent_total_jpy   bigint,
  fee_jpy          bigint,
  total_spend_jpy  bigint,
  estimated_count  bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH tr AS (
    SELECT t.id,
           date_trunc('month', t.sent_at AT TIME ZONE 'Asia/Tokyo')::date AS m,
           t.sent_total_jpy AS sent_total,
           t.fee_jpy        AS fee,
           (t.sent_at_estimated OR t.fee_estimated) AS est,
           (SELECT count(*) FROM public.settlement_transfer_items ti WHERE ti.transfer_id = t.id) AS n_items
      FROM public.settlement_transfers t
     WHERE (p_from IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date >= p_from)
       AND (p_to   IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date <= p_to)
  )
  SELECT tr.m,
         count(*)::bigint,
         sum(tr.n_items)::bigint,
         sum(tr.sent_total)::bigint,
         sum(tr.fee)::bigint,
         (sum(tr.sent_total) + sum(tr.fee))::bigint,
         count(*) FILTER (WHERE tr.est)::bigint        -- 추정 표시가 하나라도 있는 송금 묶음 수(정산 건 수 아님)
    FROM tr
   GROUP BY tr.m
   ORDER BY tr.m;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfer_monthly(date, date) IS
  '[502] 송금일(일본 시각) 달별 합계 — 송금 횟수·건수(연결 행 전부)·보낸 금액·수수료·총지출·estimated_count(송금일 또는 수수료 추정 표시가 하나라도 있는 송금 묶음 수). 저장값만 더한다. 487 머리말 [3].';

REVOKE ALL ON FUNCTION public.get_settlement_transfer_monthly(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfer_monthly(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfer_monthly(date, date) TO authenticated;

-- ── 2-3. get_settlement_transfer_by_round — 회차별 (+ estimated_count) ──
--    보낸 금액 = 연결 행마다 그 건 자신의 회차 / 수수료 = 묶음별로 가장 늦은 원래 회차에 통째로 / cert_at NULL → due_date NULL 줄. 487 머리말 [4].
--    estimated_count = 그 회차 줄에 기여하는 묶음(항목 또는 수수료) 중 추정 표시가 있는 묶음의 수(distinct).
CREATE FUNCTION public.get_settlement_transfer_by_round(p_from date, p_to date)
RETURNS TABLE (
  due_date         date,
  settlement_count bigint,
  sent_total_jpy   bigint,
  fee_jpy          bigint,
  total_spend_jpy  bigint,
  estimated_count  bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH it AS (
    SELECT ti.transfer_id,
           ti.settlement_id,
           ti.amount_jpy AS amt,
           public._settlement_payout_due(s.cert_at) AS due
      FROM public.settlement_transfer_items ti
      JOIN public.settlements s ON s.id = ti.settlement_id
  ),
  -- 묶음마다 가장 늦은 원래 회차(NULL 은 max 가 무시 — 전부 NULL 이면 NULL)
  fee_due AS (
    SELECT t.id AS transfer_id,
           t.fee_jpy AS fee,
           (SELECT max(it.due) FROM it WHERE it.transfer_id = t.id) AS due
      FROM public.settlement_transfers t
  ),
  rows_all AS (
    SELECT it.due, it.settlement_id AS sid, it.amt AS amt, 0::bigint AS fee, it.transfer_id AS tid FROM it
    UNION ALL
    SELECT fd.due, NULL::uuid, 0::bigint, fd.fee, fd.transfer_id FROM fee_due fd
  )
  SELECT r.due,
         count(DISTINCT r.sid)::bigint,
         sum(r.amt)::bigint,
         sum(r.fee)::bigint,
         (sum(r.amt) + sum(r.fee))::bigint,
         count(DISTINCT r.tid) FILTER (WHERE tt.sent_at_estimated OR tt.fee_estimated)::bigint
    FROM rows_all r
    JOIN public.settlement_transfers tt ON tt.id = r.tid
   WHERE (p_from IS NULL AND p_to IS NULL)
      OR (r.due IS NOT NULL
          AND (p_from IS NULL OR r.due >= p_from)
          AND (p_to   IS NULL OR r.due <= p_to))
   GROUP BY r.due
   ORDER BY r.due NULLS LAST;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfer_by_round(date, date) IS
  '[502] 회차(원래 지급 예정일)별 합계. 보낸 금액=연결 행마다 그 건의 회차, 수수료=묶음 안 가장 늦은 원래 회차에 통째로. cert_at NULL → due_date NULL 줄(기간을 주면 제외). '
  'estimated_count = 그 회차 줄에 기여하는 송금 묶음 중 송금일 또는 수수료 추정 표시가 있는 묶음 수(묶음이 두 회차에 걸치면 각 줄에 센다). 월별과 기준 축이 달라 기간을 주면 합이 안 맞는 것이 정상. 두 벌 — _settlement_payout_due.';

REVOKE ALL ON FUNCTION public.get_settlement_transfer_by_round(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfer_by_round(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfer_by_round(date, date) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩 — 각 단계 결과를 확인하고 다음으로)
-- ⚠️ SQL 편집기는 서비스 키라 가드(forbidden)·권한 판정이 안 돈다 → 함수 호출 확인은 로그인한 관리자 브라우저 콘솔에서.
-- [1] SQL 편집기: 권한 확인(S3 완료 정의) — 네 함수 모두 proacl 맨 앞 '=X/' 없음 · anon= 없음 · authenticated= 있음
--   SELECT p.proname, p.proacl::text
--     FROM pg_proc p
--    WHERE p.proname IN ('correct_settlement_transfer', 'get_settlement_transfers',
--                        'get_settlement_transfer_monthly', 'get_settlement_transfer_by_round');
-- [2] 브라우저 콘솔: 조회 3개 반환에 새 칸이 있다(500 적용 뒤라 모두 false·0)
--   (await db.rpc('get_settlement_transfers',{p_from:null,p_to:null})).data   // 각 행에 sent_at_estimated, fee_estimated
--   (await db.rpc('get_settlement_transfer_monthly',{p_from:null,p_to:null})).data   // estimated_count
--   (await db.rpc('get_settlement_transfer_by_round',{p_from:null,p_to:null})).data  // estimated_count
-- [3] 브라우저 콘솔(개발서버, 501 로 만든 추정 묶음 시험 뒤): 정정으로 표시 하나만 지워진다
--   송금일만 넘김 → sent_at_estimated=false · fee_estimated 그대로
--   (await db.rpc('correct_settlement_transfer',{p_transfer_id:'<묶음>',p_version:<현재 버전>,p_sent_at:'2026-06-15T00:00:00+09:00',p_fee_jpy:null,p_paypal_txn_id:null,p_memo:null})).data
--   수수료를 현재 값과 같게 넘김 → fee_estimated=false · fee_manual 그대로(결정 7). 다른 값이면 fee_manual=true
-- [4] SQL 편집기: [3] 직후 표시·이력 확인
--   SELECT sent_at_estimated, fee_estimated, fee_manual, fee_jpy FROM public.settlement_transfers WHERE id = '<묶음>';
--   SELECT action, prev, next, memo FROM public.settlement_transfer_events WHERE transfer_id = '<묶음>' ORDER BY at;
--   -- 마지막 'correct' 행 memo 끝에 「[추정 해제: …]」
-- [5] 브라우저 콘솔: estimated_count — 추정 묶음 1개를 만든 상태에서 월별 합 = 1, 지우면 0
