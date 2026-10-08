-- =============================================================================
-- 마이그레이션 517: correct_settlement_transfer — 정정 창 「이 송금 요율 직접 정하기」
-- 베이스  : 502 의 「1」 블록(현재 원본)
-- 사양서  : docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md (설계 ⓪ 표 「정정 창」 세 줄 · ① (마))
-- 작업표  : docs/specs/2026-10-08-settlement-per-transfer-fee-rule-breakdown.md (D5 · 결정 P1)
-- 선행    : 513
-- 대상    : 개발서버 → 운영서버
-- 위험도  : 중간 — 금전 기록 정정 함수. 서명이 바뀌어 DROP 후 CREATE(한 트랜잭션에서 권한 3줄까지)
-- 편집기 경고: 뜸 — 무해 (옛 6인자 함수를 지우고 8인자로 바로 다시 만든 뒤 권한을 다시 건다)
--
-- 502 대비:
--   · 선택 인자 p_fee_rate_percent numeric·p_fee_fixed_jpy integer(DEFAULT NULL — 옛 화면의 6인자 호출도 그대로 돈다)
--   · 🔴 옛 6인자 서명은 반드시 지운다 — 두 벌이면 화면 호출이 「모호한 함수」 오류로 실패한다
--   · nothing_to_correct 관문에 새 두 인자 포함(빠뜨리면 요율만 보내는 정정이 거부된다 — 작업표 S-1)
--   · 검사(예외 22023): 하나만 bundle_fee_rule_incomplete → 수수료 금액과 함께 bundle_fee_conflict → 범위 밖 bundle_fee_rule_invalid
--   · 요율이 오면: 끝수 = 사본 끝수(비었으면 설정 끝수), 수수료 = _settlement_fee_calc(sent_total_jpy, …),
--     사본 3칸 갱신, fee_manual=false, fee_estimated=false, fee_rule_custom = 정정 순간 설정과 요율·고정액이 다른가
--   · 「아무것도 안 바뀜」 조기 반환에 사본 3칸·fee_rule_custom 비교 추가 — 결과가 완전히 같으면 이력 없이 현재 버전
--   · 이력 prev/next 에 사본 3칸·fee_rule_custom. 🔴 sent_total_jpy 는 넣지 않는다(487 fee_stale 판정이 그 칸 유무로 정정 종류를 가른다)
--   · 502 의 나머지(잠금·버전 충돌 -1·추정 표시 해제·같은 수수료면 fee_manual 그대로·건별 paid_at 따라가기)는 글자 그대로
--
-- 되돌리기(한 트랜잭션):
--   DROP FUNCTION IF EXISTS public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text, numeric, integer);
--   그다음 502 의 「1」 블록(CREATE OR REPLACE ~ GRANT, 6인자) 재적용
--   ⚠️ 되돌려도 그 사이 정한 사본(요율)은 남고, fee_rule_custom 은 513 을 되돌릴 때 칸과 함께 사라진다
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text);

CREATE FUNCTION public.correct_settlement_transfer(
  p_transfer_id      uuid,
  p_version          integer,
  p_sent_at          timestamptz,
  p_fee_jpy          bigint,
  p_paypal_txn_id    text,
  p_memo             text,
  p_fee_rate_percent numeric DEFAULT NULL,   -- [517] 이 송금 요율 직접 정하기(고정액과 함께)
  p_fee_fixed_jpy    integer DEFAULT NULL
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
  -- [517]
  v_has_rule     boolean := (p_fee_rate_percent IS NOT NULL OR p_fee_fixed_jpy IS NOT NULL);
  v_rule         public.settlement_fee_rule%ROWTYPE;
  v_new_rate     numeric;
  v_new_fixed    integer;
  v_new_rounding text;
  v_new_custom   boolean;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- [517] 요율·고정액도 「고칠 항목」으로 센다(빠뜨리면 요율만 보내는 정정이 여기서 거부된다)
  IF p_sent_at IS NULL AND p_fee_jpy IS NULL AND p_paypal_txn_id IS NULL AND p_memo IS NULL
     AND p_fee_rate_percent IS NULL AND p_fee_fixed_jpy IS NULL THEN
    RAISE EXCEPTION 'nothing_to_correct: 고칠 항목(송금일·수수료·요율·거래번호·메모)을 하나 이상 지정해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- [517] 이 송금 요율 — 검사 순서: 하나만 → 수수료 금액과 함께 → 범위 밖(기록 514 와 같은 코드)
  IF (p_fee_rate_percent IS NULL) <> (p_fee_fixed_jpy IS NULL) THEN
    RAISE EXCEPTION 'bundle_fee_rule_incomplete: 요율과 고정액을 함께 지정해야 합니다' USING ERRCODE = '22023';
  END IF;
  IF v_has_rule AND p_fee_jpy IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_fee_conflict: 수수료 금액과 요율을 함께 보낼 수 없습니다' USING ERRCODE = '22023';
  END IF;
  IF v_has_rule AND (p_fee_rate_percent < 0 OR p_fee_rate_percent > 100 OR p_fee_fixed_jpy < 0) THEN
    RAISE EXCEPTION 'bundle_fee_rule_invalid: 요율은 0~100, 고정액은 0 이상이어야 합니다' USING ERRCODE = '22023';
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

  -- ★ [517] 이 송금 요율로 다시 계산 — 직접 고친 수수료도 덮는다(사양서 설계 ⓪ 표 「정정 창 · 체크 켬」).
  --   끝수 = 그 묶음 사본 끝수(비었으면 정정 순간 설정 끝수 — 경우의 수 4). 사본 3칸 = (그 요율, 그 고정액, 그 끝수)
  --   fee_manual=false · fee_estimated=false · fee_rule_custom = 정정 순간 설정과 요율·고정액이 다른가(끝수 비교 안 함)
  --   요율을 안 보내면 사본 3칸·fee_rule_custom 은 그대로(수수료 금액 정정으로는 안 바뀐다)
  v_new_rate     := v_t.fee_rate_percent;
  v_new_fixed    := v_t.fee_fixed_jpy;
  v_new_rounding := v_t.fee_rounding;
  v_new_custom   := v_t.fee_rule_custom;
  IF v_has_rule THEN
    SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
    END IF;
    v_new_rate     := p_fee_rate_percent;
    v_new_fixed    := p_fee_fixed_jpy;
    v_new_rounding := COALESCE(v_t.fee_rounding, v_rule.rounding);
    v_new_fee      := public._settlement_fee_calc(v_t.sent_total_jpy, v_new_rate, v_new_fixed, v_new_rounding);
    v_new_manual   := false;
    v_new_fee_est  := false;
    v_new_custom   := (v_new_rate <> v_rule.rate_percent OR v_new_fixed <> v_rule.fixed_jpy);
  END IF;

  -- 값이 실제로는 하나도 안 바뀌는 호출 — 이력만 늘어나므로 아무것도 안 하고 현재 판을 돌려준다(341 과 같음).
  -- ★ [502] 추정 표시가 바뀌는 것도 변경으로 센다(같은 값을 「맞음」으로 확인해 표시만 지우는 경우).
  IF v_new_sent   IS NOT DISTINCT FROM v_t.sent_at
     AND v_new_fee    = v_t.fee_jpy
     AND v_new_manual = v_t.fee_manual
     AND v_new_txn    IS NOT DISTINCT FROM v_t.paypal_txn_id
     AND v_new_memo   IS NOT DISTINCT FROM v_t.memo
     AND v_new_sent_est = v_t.sent_at_estimated
     AND v_new_fee_est  = v_t.fee_estimated
     -- [517] 요율 사본·「이 송금만」이 바뀌는 것도 변경으로 센다
     AND v_new_rate     IS NOT DISTINCT FROM v_t.fee_rate_percent
     AND v_new_fixed    IS NOT DISTINCT FROM v_t.fee_fixed_jpy
     AND v_new_rounding IS NOT DISTINCT FROM v_t.fee_rounding
     AND v_new_custom   = v_t.fee_rule_custom THEN
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
         fee_rate_percent  = v_new_rate,
         fee_fixed_jpy     = v_new_fixed,
         fee_rounding      = v_new_rounding,
         fee_rule_custom   = v_new_custom,
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
                       'sent_at_estimated', v_t.sent_at_estimated, 'fee_estimated', v_t.fee_estimated,
                       'fee_rate_percent', v_t.fee_rate_percent, 'fee_fixed_jpy', v_t.fee_fixed_jpy,
                       'fee_rounding', v_t.fee_rounding, 'fee_rule_custom', v_t.fee_rule_custom),
    jsonb_build_object('sent_at', v_new_sent, 'fee_jpy', v_new_fee, 'fee_manual', v_new_manual,
                       'paypal_txn_id', v_new_txn, 'memo', v_new_memo,
                       'sent_at_estimated', v_new_sent_est, 'fee_estimated', v_new_fee_est,
                       'fee_rate_percent', v_new_rate, 'fee_fixed_jpy', v_new_fixed,
                       'fee_rounding', v_new_rounding, 'fee_rule_custom', v_new_custom),
    v_ev_memo, auth.uid(), v_actor_name
  );

  -- ⚠️ 알림 없음(343)
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text, numeric, integer) IS
  '[517, 베이스 502] 송금 묶음 정정. 요율·고정액(p_fee_rate_percent·p_fee_fixed_jpy)을 함께 주면 그 요율로 수수료를 다시 계산하고 사본·fee_rule_custom 을 바꾼다(fee_manual=false·fee_estimated=false, 수수료 금액과 함께면 bundle_fee_conflict).  인자 NULL = 안 고침(빈 문자열은 거래번호·메모를 비움), 모두 NULL 이면 거부. 버전 충돌 -1, 변경 없으면 현재 버전. '
  '송금일을 고치면 current_transfer_id=이 묶음인 건들의 paid_at 만 함께 고친다. 수수료가 현재 값과 다르면 fee_manual=true, 같으면 fee_manual 그대로. '
  '송금일을 넘기면 sent_at_estimated=false, 수수료를 넘기면 fee_estimated=false(같은 값이어도 — 「값이 맞음」). NULL 칸의 추정 표시는 그대로. 이력은 settlement_transfer_events.';

-- 새 서명이라 권한 3줄이 필요하다(DROP 으로 옛 권한은 사라졌다)
REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text, numeric, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text, numeric, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text, numeric, integer) TO authenticated;

COMMIT;

-- ============================================================
-- 검증
--   SELECT p.oid::regprocedure, p.proacl::text FROM pg_proc p WHERE p.proname = 'correct_settlement_transfer';
--   → 한 줄(8인자), 맨 앞 =X/ 없음
--   기능은 관리자 콘솔 — SQL 편집기는 서비스 키라 권한 분기가 안 돈다(작업표 D5 완료 정의 ①~⑤)
-- ============================================================
