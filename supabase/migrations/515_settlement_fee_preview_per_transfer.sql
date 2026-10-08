-- =============================================================================
-- 마이그레이션 515: preview_settlement_fees — 묶음별 요율·고정액·끝수 미리보기
-- 베이스  : 488 (현재 원본)
-- 사양서  : docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md (① (다))
-- 작업표  : docs/specs/2026-10-08-settlement-per-transfer-fee-rule-breakdown.md (D3)
-- 대상    : 개발서버 → 운영서버
-- 위험도  : 낮음 — 읽기 함수. 서명이 바뀌어 DROP 후 CREATE(한 트랜잭션 — 사이에 공개 실행 권한이 생기지 않게)
-- 편집기 경고: 뜸 — 무해 (같은 이름 함수를 지우고 바로 다시 만든 뒤 권한 3줄을 다시 건다)
--
-- 488 대비:
--   · 입력에 p_totals 와 같은 길이의 선택 배열 p_rates·p_fixeds·p_roundings(원소 NULL = 설정 규칙).
--     새 인자는 DEFAULT NULL — 옛 화면(p_totals 만 보냄)도 그대로 돈다
--   · p_roundings 는 정정 창 미리보기가 그 묶음의 사본 끝수를 보내 정정(517)과 같은 값을 보이게 하려는 것이다.
--     확인 창은 보내지 않는다(기록은 설정 끝수 — 514)
--   · 반환에 custom[] — 그 자리의 요율·고정액이 설정과 다른가(끝수는 비교 안 함 — 사양서 경우의 수 3).
--     합계가 NULL·0 이하면 fees·custom 모두 NULL. 요율을 안 보낸 자리는 false
--   · 거부 bundle_fee_rule_invalid(22023): 배열 길이 불일치 · 한 자리에 요율·고정액 중 하나만 · 범위 밖(484 와 같은 범위) ·
--     끝수가 round/floor/ceil 이 아님. 가드(settlement.view 읽기)·2000개 상한은 488 그대로
--   🔴 수수료 식은 _settlement_fee_calc 한 곳 — 화면에 식을 두지 않는다
--
-- 되돌리기(한 트랜잭션):
--   DROP FUNCTION IF EXISTS public.preview_settlement_fees(bigint[], numeric[], integer[], text[]);
--   그다음 488 의 CREATE OR REPLACE ~ GRANT 블록 재적용
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.preview_settlement_fees(bigint[]);

CREATE FUNCTION public.preview_settlement_fees(
  p_totals     bigint[],
  p_rates      numeric[] DEFAULT NULL,
  p_fixeds     integer[] DEFAULT NULL,
  p_roundings  text[]    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rule   public.settlement_fee_rule%ROWTYPE;
  v_n      integer;
  v_fees   jsonb;
  v_custom jsonb;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 한 번에 넘기는 묶음 수 상한 — 확인 창 한 번에 이보다 많을 일은 없다
  IF p_totals IS NOT NULL AND cardinality(p_totals) > 2000 THEN
    RAISE EXCEPTION 'fee_rule_invalid: too many totals' USING ERRCODE = '22023';
  END IF;

  v_n := COALESCE(cardinality(p_totals), 0);

  -- 선택 배열은 보낼 거면 p_totals 와 같은 길이여야 한다(자리로 짝을 맞춘다)
  IF (p_rates     IS NOT NULL AND cardinality(p_rates)     <> v_n)
  OR (p_fixeds    IS NOT NULL AND cardinality(p_fixeds)    <> v_n)
  OR (p_roundings IS NOT NULL AND cardinality(p_roundings) <> v_n) THEN
    RAISE EXCEPTION 'bundle_fee_rule_invalid: 배열 길이가 합계 배열과 다릅니다' USING ERRCODE = '22023';
  END IF;

  -- 자리마다: 요율·고정액은 둘 다 있거나 둘 다 없어야 하고, 범위는 484 와 같다. 끝수는 셋 중 하나
  IF EXISTS (
    SELECT 1
      FROM generate_series(1, v_n) AS g(i)
     WHERE ((p_rates[g.i] IS NULL) <> (p_fixeds[g.i] IS NULL))
        OR p_rates[g.i]  < 0 OR p_rates[g.i] > 100
        OR p_fixeds[g.i] < 0
        OR (p_roundings[g.i] IS NOT NULL AND p_roundings[g.i] NOT IN ('round', 'floor', 'ceil'))
  ) THEN
    RAISE EXCEPTION 'bundle_fee_rule_invalid: 요율·고정액·끝수 값이 올바르지 않습니다' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
  END IF;

  -- 입력 순서 그대로. 합계가 NULL·0 이하이면 NULL(화면은 「—」). NULL 원소는 설정 규칙
  SELECT COALESCE(jsonb_agg(
           CASE WHEN t.total IS NULL OR t.total <= 0 THEN NULL
                ELSE to_jsonb(public._settlement_fee_calc(
                       t.total,
                       COALESCE(p_rates[t.ord],     v_rule.rate_percent),
                       COALESCE(p_fixeds[t.ord],    v_rule.fixed_jpy),
                       COALESCE(p_roundings[t.ord], v_rule.rounding)))
           END
           ORDER BY t.ord), '[]'::jsonb),
         COALESCE(jsonb_agg(
           CASE WHEN t.total IS NULL OR t.total <= 0 THEN NULL
                WHEN p_rates[t.ord] IS NULL THEN to_jsonb(false)
                ELSE to_jsonb(p_rates[t.ord] <> v_rule.rate_percent OR p_fixeds[t.ord] <> v_rule.fixed_jpy)
           END
           ORDER BY t.ord), '[]'::jsonb)
    INTO v_fees, v_custom
    FROM unnest(COALESCE(p_totals, ARRAY[]::bigint[])) WITH ORDINALITY AS t(total, ord);

  RETURN jsonb_build_object(
    'rate_percent', v_rule.rate_percent,
    'fixed_jpy',    v_rule.fixed_jpy,
    'rounding',     v_rule.rounding,
    'fees',         v_fees,
    'custom',       v_custom
  );
END;
$$;

COMMENT ON FUNCTION public.preview_settlement_fees(bigint[], numeric[], integer[], text[]) IS
  '[515, 베이스 488] 확인 창·정정 창 수수료 미리보기. 합계 배열 → 같은 순서의 수수료 배열(486 _settlement_fee_calc 한 곳). '
  '선택 배열 p_rates·p_fixeds·p_roundings(NULL 원소 = 설정 규칙), 반환 custom[] = 요율·고정액이 설정과 다른가(끝수 제외). 기록은 하지 않는다.';

REVOKE ALL ON FUNCTION public.preview_settlement_fees(bigint[], numeric[], integer[], text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preview_settlement_fees(bigint[], numeric[], integer[], text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.preview_settlement_fees(bigint[], numeric[], integer[], text[]) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (관리자 브라우저 콘솔 — SQL 편집기는 서비스 키라 권한 분기가 안 돈다)
--   (await db.rpc('preview_settlement_fees', {p_totals:[3000, 7000]})).data                                  -- 옛 호출 그대로
--   (await db.rpc('preview_settlement_fees', {p_totals:[3000, 7000], p_rates:[4.4, null], p_fixeds:[50, null]})).data
--   -- fees[0] = 4.4%+50, fees[1] = 설정 규칙, custom = [true, false] (설정이 4.1%+50 일 때)
-- 권한: SELECT p.proacl::text FROM pg_proc p WHERE p.proname = 'preview_settlement_fees';  → 맨 앞 =X/ 없음, 한 줄
-- ============================================================
