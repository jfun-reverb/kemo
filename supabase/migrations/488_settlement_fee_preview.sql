-- 488_settlement_fee_preview.sql
-- 정산 송금 수수료 — 확인 창 미리보기 (조각 11 보조)
-- 사양서: docs/specs/2026-09-30-settlement-transfer-fee-record.md / 작업표 …-breakdown.md 「조각 11」
--
-- 목적:
--   확인 창이 묶음마다 「예상 수수료」를 보여 줘야 하는데, 작업표가 **수수료 계산식의 사본을 금지**한다
--   (조각 11 주의). 화면에 식을 두면 규칙·끝수 처리가 바뀔 때 화면과 서버가 갈린다.
--   → 화면은 묶음 합계 배열을 넘기고, 서버가 486 의 `_settlement_fee_calc` 한 곳으로 계산해 돌려준다.
--   ⚠️ **미리보기일 뿐이다.** 실제 기록 수수료는 record_settlement_transfers(486) 가 저장 순간의
--      규칙으로 다시 계산한다(그 사이 규칙이 바뀌면 기록 값이 이긴다).
--
-- 권한: has_permission('settlement.view','read') — 조회와 같은 등급. 표를 쓰지 않는다.
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.preview_settlement_fees(bigint[]);

BEGIN;

CREATE OR REPLACE FUNCTION public.preview_settlement_fees(p_totals bigint[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rule public.settlement_fee_rule%ROWTYPE;
  v_fees jsonb;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 한 번에 넘기는 묶음 수 상한 — 확인 창 한 번에 이보다 많을 일은 없다
  IF p_totals IS NOT NULL AND cardinality(p_totals) > 2000 THEN
    RAISE EXCEPTION 'fee_rule_invalid: too many totals' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
  END IF;

  -- 입력 순서 그대로. 합계가 NULL·0 이하이면 NULL(화면은 「—」)
  SELECT COALESCE(jsonb_agg(
           CASE WHEN t.total IS NULL OR t.total <= 0 THEN NULL
                ELSE to_jsonb(public._settlement_fee_calc(t.total, v_rule.rate_percent, v_rule.fixed_jpy, v_rule.rounding))
           END
           ORDER BY t.ord), '[]'::jsonb)
    INTO v_fees
    FROM unnest(COALESCE(p_totals, ARRAY[]::bigint[])) WITH ORDINALITY AS t(total, ord);

  RETURN jsonb_build_object(
    'rate_percent', v_rule.rate_percent,
    'fixed_jpy',    v_rule.fixed_jpy,
    'rounding',     v_rule.rounding,
    'fees',         v_fees
  );
END;
$$;

COMMENT ON FUNCTION public.preview_settlement_fees(bigint[]) IS
  '[488] 확인 창 수수료 미리보기. 묶음 합계 배열 → 같은 순서의 수수료 배열(486 _settlement_fee_calc 한 곳). 기록은 하지 않는다. 화면에 식 사본을 두지 않기 위한 함수.';

REVOKE ALL ON FUNCTION public.preview_settlement_fees(bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preview_settlement_fees(bigint[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.preview_settlement_fees(bigint[]) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (관리자 브라우저 콘솔 — SQL 편집기는 서비스 키라 권한 분기가 안 돈다)
--   (await db.rpc('preview_settlement_fees', {p_totals:[3000, 7000, 6500, 0]})).data
--   -- fees: [173, 337, 317, null]  (4.1% + 50엔, 반올림 기준)
-- ============================================================
