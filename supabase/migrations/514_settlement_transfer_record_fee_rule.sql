-- =============================================================================
-- 마이그레이션 514: record_settlement_transfers — 「이 송금 요율 직접 정하기」
-- 베이스  : 486 (현재 원본). 503~513 은 이 함수를 건드리지 않는다
-- 사양서  : docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md (설계 ⓪ 표 「확인 창」 세 줄 · ① (나))
-- 작업표  : docs/specs/2026-10-08-settlement-per-transfer-fee-rule-breakdown.md (D2)
-- 선행    : 513(fee_rule_custom 칸)
-- 대상    : 개발서버 → 운영서버
-- 위험도  : 중간 — 금전 기록 함수 재정의. 486 의 나머지(잠금 순서·미등록 판정·페이팔 재조회·먼저 전부 검사)는 글자 그대로
-- 편집기 경고: 안 뜸 (CREATE OR REPLACE — 인자 그대로라 실행 권한 보존. 끝의 권한 3줄은 486 과 같은 멱등 재선언)
--
-- 486 대비 바뀐 곳 넷:
--   ① 2단계 묶음 검사에 실패 사유 3종 — bundle_fee_rule_incomplete · bundle_fee_rule_invalid · bundle_fee_conflict
--      (486 과 같은 방식: 예외 대신 failures[] 에 쌓고 하나라도 있으면 아무것도 안 쓴다)
--   ② 8단계 수수료 — 요율·고정액이 오면 _settlement_fee_calc(합계, 그 요율, 그 고정액, 기록 순간 설정 끝수)
--   ③ 묶음 INSERT — 사본 3칸 = (그 요율, 그 고정액, 설정 끝수), fee_rule_custom
--   ④ 'create' 이력 next 에 fee_rule_custom (정정 이력과 맞춤 — 사양서 밖, 「구현 결과」에 기록)
--
-- 🔴 운영 SQL 편집기·콘솔에서 이 함수를 시험 호출하지 말 것 — source='app' 첫 기록이 곧 도입일이고
--    그 뒤 옛 송금완료 경로 셋이 payout_bundle_required 로 거부된다(되돌릴 함수 없음). 운영은 읽기만 확인(작업표 P2).
--
-- 되돌리기: 486 의 「4. record_settlement_transfers」 블록(CREATE OR REPLACE ~ GRANT)을 다시 적용
-- =============================================================================

BEGIN;

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
  -- 514: 이 송금 요율 직접 정하기
  v_rate_j       jsonb;                        -- 입력 원본 fee_rate_percent
  v_fixed_j      jsonb;                        -- 입력 원본 fee_fixed_jpy
  v_has_rate     boolean;
  v_has_fixed    boolean;
  v_rate         numeric;                      -- 이 묶음에 쓸 요율(사본)
  v_fixed        integer;                      -- 이 묶음에 쓸 고정액(사본)
  v_custom       boolean;                      -- fee_rule_custom
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

    -- 514: 이 송금 요율·고정액(선택). 「없음」 = 키 없음 또는 JSON null(fee_jpy 와 같은 관례).
    --   하나만 → bundle_fee_rule_incomplete · 숫자 아님·범위 밖(484 와 같은 범위)·고정액 정수 아님 → bundle_fee_rule_invalid
    --   금액(fee_jpy)과 함께 → bundle_fee_conflict(화면은 둘 중 하나만 보낸다 — 이것은 우회 호출 방어선)
    --   jsonb_typeof 를 먼저 보고 숫자일 때만 캐스트한다(문자열 캐스트 예외 방지)
    v_rate_j    := v_b.e -> 'fee_rate_percent';
    v_fixed_j   := v_b.e -> 'fee_fixed_jpy';
    v_has_rate  := v_rate_j  IS NOT NULL AND jsonb_typeof(v_rate_j)  <> 'null';
    v_has_fixed := v_fixed_j IS NOT NULL AND jsonb_typeof(v_fixed_j) <> 'null';
    IF v_has_rate <> v_has_fixed THEN
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_fee_rule_incomplete'));
    ELSIF v_has_rate THEN
      IF (v_b.e -> 'fee_jpy') IS NOT NULL AND jsonb_typeof(v_b.e -> 'fee_jpy') <> 'null' THEN
        v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_fee_conflict'));
      END IF;
      IF jsonb_typeof(v_rate_j) <> 'number' OR jsonb_typeof(v_fixed_j) <> 'number' THEN
        v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_fee_rule_invalid'));
      ELSIF (v_rate_j #>> '{}')::numeric < 0 OR (v_rate_j #>> '{}')::numeric > 100
         OR (v_fixed_j #>> '{}')::numeric < 0 OR (v_fixed_j #>> '{}')::numeric > 2147483647
         OR (v_fixed_j #>> '{}')::numeric <> trunc((v_fixed_j #>> '{}')::numeric) THEN
        v_fail := v_fail || jsonb_build_array(jsonb_build_object('bundle_index', v_b.bidx, 'reason', 'bundle_fee_rule_invalid'));
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

    -- 수수료(514): ①이 송금 요율·고정액이 오면 그 값 + 기록 순간 설정 끝수로 계산, 사본 = 그 값,
    --   fee_rule_custom = 기록 순간 설정과 요율·고정액이 다른가(끝수는 비교 안 함 — 사양서 경우의 수 3)
    --   ②금액을 넘기면 그 값 + 「손으로 고침」(계산값과 같아도), 사본 = 설정 규칙(486 그대로)
    --   ③둘 다 없으면 설정 규칙 계산(486 그대로)
    v_rate   := v_rule.rate_percent;
    v_fixed  := v_rule.fixed_jpy;
    v_custom := false;
    IF (v_b.e -> 'fee_rate_percent') IS NOT NULL AND jsonb_typeof(v_b.e -> 'fee_rate_percent') <> 'null' THEN
      v_rate   := (v_b.e ->> 'fee_rate_percent')::numeric;
      v_fixed  := (v_b.e ->> 'fee_fixed_jpy')::numeric::integer;
      v_fee    := public._settlement_fee_calc(v_total, v_rate, v_fixed, v_rule.rounding);
      v_manual := false;
      v_custom := (v_rate <> v_rule.rate_percent OR v_fixed <> v_rule.fixed_jpy);
    ELSIF NULLIF(v_b.e ->> 'fee_jpy', '') IS NOT NULL THEN
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
      fee_rate_percent, fee_fixed_jpy, fee_rounding, fee_manual, fee_rule_custom,
      paypal_txn_id, memo, source, recorded_by
    ) VALUES (
      v_sent, v_inf, v_total, v_fee,
      v_rate, v_fixed, v_rule.rounding, v_manual, v_custom,
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
        'fee_rate_percent', v_rate, 'fee_fixed_jpy', v_fixed, 'fee_rounding', v_rule.rounding,
        'fee_rule_custom', v_custom,
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
  '[514, 베이스 486] 송금 묶음 기록(페이팔 거래 1건 = 묶음 1개). 묶음에 fee_rate_percent·fee_fixed_jpy 를 함께 주면 그 요율로 계산하고 사본·fee_rule_custom 에 남긴다(fee_jpy 와 함께면 bundle_fee_conflict).  먼저 전부 검사해 하나라도 걸리면 아무것도 안 쓰고 {ok:false, failures:[{bundle_index, settlement_id|application_id, reason}]}, '
  '통과하면 묶음·연결·건 갱신(paid_amount_jpy 항상 숫자·current_transfer_id)·이력을 한 트랜잭션으로 쓴다. 수수료는 넘기면 fee_manual=true, 비우면 484 규칙 계산. '
  '알림 없음(343). source=app 묶음이 생기면 옛 송금완료 경로 셋이 payout_bundle_required 로 거부된다 — 운영 SQL 편집기 시험 호출 금지.';

REVOKE ALL ON FUNCTION public.record_settlement_transfers(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_settlement_transfers(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_settlement_transfers(jsonb) TO authenticated;

COMMIT;
