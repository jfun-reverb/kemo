-- 484_settlement_fee_rule.sql
-- 정산 송금 수수료 규칙 (조각 1 — 규칙 표 + 이력 + 조회·수정 함수)
-- 사양서: docs/specs/2026-09-30-settlement-transfer-fee-record.md / 작업표 …-breakdown.md 「조각 1」
--
-- 목적:
--   페이팔 송금 수수료 계산 규칙(비율 % + 고정 엔 + 반올림 방식)을 한 줄짜리 표로 두고,
--   변경 이력을 남긴다. 다음 조각(송금 묶음 기록 함수)이 이 규칙으로 수수료를 계산한다.
--   수수료 = 반올림(합계 * rate_percent / 100 + fixed_jpy). 초기값 4.1% + 50엔, 'round'.
--   예) 3,000엔 → round(3000*4.1/100+50) = 173엔
--
-- 권한:
--   - 조회: has_permission('settlement.view','read')  (표 정책 · get 함수 가드)
--   - 수정: has_permission('settlement.pay','write')  (update 함수만. 표 쓰기 정책 없음)
--
-- 오류 코드: forbidden / fee_rule_invalid: <사유>
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.update_settlement_fee_rule(numeric, integer, text);
--   DROP FUNCTION IF EXISTS public.get_settlement_fee_rule();
--   DROP TABLE IF EXISTS public.settlement_fee_rule_history;
--   DROP TABLE IF EXISTS public.settlement_fee_rule;
--   (새 표·함수뿐이라 다른 객체에 영향 없음. 조각 2 이후가 적용된 뒤에는 그쪽을 먼저 되돌릴 것)

BEGIN;

-- ============================================================
-- 1. 수수료 규칙 표 (싱글톤, id=1)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_fee_rule (
  id           integer PRIMARY KEY DEFAULT 1
                 CONSTRAINT settlement_fee_rule_singleton CHECK (id = 1),
  rate_percent numeric NOT NULL
                 CONSTRAINT settlement_fee_rule_rate_range CHECK (rate_percent >= 0 AND rate_percent <= 100),
  fixed_jpy    integer NOT NULL
                 CONSTRAINT settlement_fee_rule_fixed_range CHECK (fixed_jpy >= 0),
  rounding     text NOT NULL
                 CONSTRAINT settlement_fee_rule_rounding_check CHECK (rounding IN ('round','floor','ceil')),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.settlement_fee_rule IS
  '[484] 정산 송금 수수료 규칙(한 줄, id=1). 수수료 = 반올림(합계*rate_percent/100 + fixed_jpy). 수정은 update_settlement_fee_rule 만.';

INSERT INTO public.settlement_fee_rule (id, rate_percent, fixed_jpy, rounding)
VALUES (1, 4.1, 50, 'round')
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 2. 이력 표 (추가만)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_fee_rule_history (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prev_rate_percent numeric,
  next_rate_percent numeric,
  prev_fixed_jpy    integer,
  next_fixed_jpy    integer,
  prev_rounding     text,
  next_rounding     text,
  actor             uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name        text,
  at                timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.settlement_fee_rule_history IS
  '[484] 수수료 규칙 변경 이력(추가만). update_settlement_fee_rule 만 INSERT.';

CREATE INDEX IF NOT EXISTS idx_settlement_fee_rule_history_at
  ON public.settlement_fee_rule_history (at DESC);

-- ============================================================
-- 3. 행 단위 보안 정책 — 조회만, 쓰기 정책 없음 (settlement_settings 230 과 같은 형태)
-- ============================================================
ALTER TABLE public.settlement_fee_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_fee_rule_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS settlement_fee_rule_select ON public.settlement_fee_rule;
CREATE POLICY settlement_fee_rule_select ON public.settlement_fee_rule
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

DROP POLICY IF EXISTS settlement_fee_rule_history_select ON public.settlement_fee_rule_history;
CREATE POLICY settlement_fee_rule_history_select ON public.settlement_fee_rule_history
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

-- ============================================================
-- 4. get_settlement_fee_rule() — 규칙 + 최근 이력 20건
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_settlement_fee_rule()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rule    public.settlement_fee_rule%ROWTYPE;
  v_name    text;
  v_history jsonb;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
  END IF;

  SELECT a.name INTO v_name
    FROM public.admins a WHERE a.auth_id = v_rule.updated_by LIMIT 1;

  SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.at DESC), '[]'::jsonb)
    INTO v_history
    FROM (
      SELECT id, prev_rate_percent, next_rate_percent, prev_fixed_jpy, next_fixed_jpy,
             prev_rounding, next_rounding, actor, actor_name, at
        FROM public.settlement_fee_rule_history
       ORDER BY at DESC
       LIMIT 20
    ) h;

  RETURN jsonb_build_object(
    'rate_percent',    v_rule.rate_percent,
    'fixed_jpy',       v_rule.fixed_jpy,
    'rounding',        v_rule.rounding,
    'updated_at',      v_rule.updated_at,
    'updated_by',      v_rule.updated_by,
    'updated_by_name', v_name,
    'history',         v_history
  );
END;
$$;

-- ============================================================
-- 5. update_settlement_fee_rule() — 검증 + 잠금 + 이력
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_settlement_fee_rule(
  p_rate_percent numeric,
  p_fixed_jpy    integer,
  p_rounding     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old        public.settlement_fee_rule%ROWTYPE;
  v_new        public.settlement_fee_rule%ROWTYPE;
  v_actor_name text;
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_rate_percent IS NULL OR p_rate_percent < 0 OR p_rate_percent > 100 THEN
    RAISE EXCEPTION 'fee_rule_invalid: rate_percent must be between 0 and 100' USING ERRCODE = '22023';
  END IF;
  IF p_fixed_jpy IS NULL OR p_fixed_jpy < 0 THEN
    RAISE EXCEPTION 'fee_rule_invalid: fixed_jpy must be >= 0' USING ERRCODE = '22023';
  END IF;
  IF p_rounding IS NULL OR p_rounding NOT IN ('round','floor','ceil') THEN
    RAISE EXCEPTION 'fee_rule_invalid: rounding must be round, floor or ceil' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_old FROM public.settlement_fee_rule WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fee_rule_invalid: rule row missing' USING ERRCODE = '22023';
  END IF;

  IF v_old.rate_percent = p_rate_percent
     AND v_old.fixed_jpy = p_fixed_jpy
     AND v_old.rounding = p_rounding THEN
    RETURN jsonb_build_object(
      'unchanged',    true,
      'rate_percent', v_old.rate_percent,
      'fixed_jpy',    v_old.fixed_jpy,
      'rounding',     v_old.rounding,
      'updated_at',   v_old.updated_at
    );
  END IF;

  SELECT a.name INTO v_actor_name
    FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;

  UPDATE public.settlement_fee_rule
     SET rate_percent = p_rate_percent,
         fixed_jpy    = p_fixed_jpy,
         rounding     = p_rounding,
         updated_at   = now(),
         updated_by   = auth.uid()
   WHERE id = 1
   RETURNING * INTO v_new;

  INSERT INTO public.settlement_fee_rule_history (
    prev_rate_percent, next_rate_percent,
    prev_fixed_jpy,    next_fixed_jpy,
    prev_rounding,     next_rounding,
    actor, actor_name
  ) VALUES (
    v_old.rate_percent, v_new.rate_percent,
    v_old.fixed_jpy,    v_new.fixed_jpy,
    v_old.rounding,     v_new.rounding,
    auth.uid(), v_actor_name
  );

  RETURN jsonb_build_object(
    'unchanged',    false,
    'rate_percent', v_new.rate_percent,
    'fixed_jpy',    v_new.fixed_jpy,
    'rounding',     v_new.rounding,
    'updated_at',   v_new.updated_at
  );
END;
$$;

-- ============================================================
-- 6. 실행 권한 — 회수 방향이 둘 (PUBLIC · anon) 다 회수 후 authenticated 만 부여
-- ============================================================
REVOKE ALL ON FUNCTION public.get_settlement_fee_rule() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_fee_rule() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_fee_rule() TO authenticated;

REVOKE ALL ON FUNCTION public.update_settlement_fee_rule(numeric, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_settlement_fee_rule(numeric, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_settlement_fee_rule(numeric, integer, text) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩)
-- ⚠️ SQL 편집기는 서비스 키라 권한 분기(forbidden)가 안 돈다 → 2~4 는 로그인한 관리자 브라우저 콘솔에서.
-- ============================================================
-- [1] SQL 편집기: 표·시드·권한 확인
--   SELECT * FROM public.settlement_fee_rule;                       -- 1행: 4.1 / 50 / round
--   SELECT p.proname, p.proacl::text FROM pg_proc p
--    WHERE p.proname IN ('get_settlement_fee_rule','update_settlement_fee_rule');
--   -- proacl 맨 앞에 '=X/' 가 없고 anon= 이 없어야 한다
-- [2] 브라우저(정산 조회 권한 관리자):
--   (await db.rpc('get_settlement_fee_rule')).data   -- 4.1 / 50 / round, history []
-- [3] 브라우저(campaign_admin 이상):
--   (await db.rpc('update_settlement_fee_rule',{p_rate_percent:4.1,p_fixed_jpy:50,p_rounding:'round'})).data
--   -- unchanged:true, 이력 0행 증가 없음
--   (await db.rpc('update_settlement_fee_rule',{p_rate_percent:4.2,p_fixed_jpy:50,p_rounding:'round'})).data
--   -- 이력 1행 → 곧바로 4.1 로 되돌려 이력 2행. 잘못된 값(101, -1, 'x')은 fee_rule_invalid
-- [4] 브라우저(campaign_manager): 두 함수 모두 error 'forbidden'
-- [5] SQL 편집기: 수수료 공식 예시 (3,000엔 → 173)
--   SELECT round(3000 * rate_percent / 100 + fixed_jpy) AS fee_round,
--          floor(3000 * rate_percent / 100 + fixed_jpy) AS fee_floor,
--          ceil (3000 * rate_percent / 100 + fixed_jpy) AS fee_ceil
--     FROM public.settlement_fee_rule;                              -- 173 / 173 / 173 (초기값 기준)
