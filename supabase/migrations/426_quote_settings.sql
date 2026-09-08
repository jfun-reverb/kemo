-- ============================================================
-- 426_quote_settings.sql
-- 2026-09-08 — 오리엔시트 단순화 재설계 2단계 · 마이그레이션 Ⓒ (작업 13)
--   사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-5 · §4-8 Ⓒ
--   작업표 docs/specs/2026-09-08-orient-sheet-simplify-and-quote-breakdown.md 작업 13
--
-- 무엇을 만드나
--   [A] 표 public.quote_settings          — 견적 기준값(형식·항목별 행, key 가 기본 키)
--   [B] 표 public.quote_settings_history  — 값 변경 이력(금액 문서의 근거라 남긴다)
--   [C] 함수 get_quote_settings()          — 관리자 조회(is_admin)
--   [D] 함수 update_quote_setting(key, amount) — 캠페인 관리자 이상 수정(is_campaign_admin, 확정 ⓗ) + 이력 INSERT
--   [E] 초기 9행 — 환율 10 · 송금 수수료 2,500 · 모집비 0 · 시딩 채널 5종 0(선-1 값은 사용자가 화면에서 입력) · 부가세 0.10
--
-- 접근 정책: SELECT is_admin() · INSERT/UPDATE/DELETE 정책 없음(함수만). 익명(작성 폼)은 이 표를 직접 못 읽는다 —
--   제출 함수(427)가 SECURITY DEFINER 안에서 읽는다(익명 조회 함수를 늘리지 않는다 — 375 정리와 같은 방향).
--
-- ⚠️ 광고주 신청 폼(dev/sales/reviewer.html)의 환율 10·수수료 2,500 고정값과 트리거 111 은 이번에 안 건드린다(§8-⑩).
-- 🔴 시딩 채널 단가가 0 인 채 운영에 나가면 0원짜리 견적서가 브랜드에게 간다(작업 20 — 선-1 값 입력 뒤 배포).
--
-- 롤백: DROP FUNCTION public.update_quote_setting(text, numeric); DROP FUNCTION public.get_quote_settings();
--       DROP TABLE public.quote_settings_history; DROP TABLE public.quote_settings;
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] quote_settings
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quote_settings (
  key         text         PRIMARY KEY,
  amount      numeric      NOT NULL,
  unit        text         NOT NULL CHECK (unit IN ('krw', 'jpy', 'rate')),
  label_ko    text         NOT NULL,
  sort_order  integer      NOT NULL DEFAULT 0,
  updated_at  timestamptz  NOT NULL DEFAULT now(),
  updated_by  uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.quote_settings IS
  '[426] 오리엔시트 견적 기준값. 제출 함수(submit_orient_sheet, 427)가 서버 안에서 읽어 data.quote 스냅샷을 만든다. '
  '조회 is_admin(), 수정은 update_quote_setting()(캠페인 관리자 이상)만 — 직접 UPDATE 정책 없음. '
  '⚠️ 광고주 신청 폼·트리거 111 의 고정 상수와는 별개(§8-⑩).';
COMMENT ON COLUMN public.quote_settings.unit IS 'krw=원 금액 · jpy=엔 금액 · rate=비율(0.10 = 10%)';

-- ------------------------------------------------------------
-- [B] quote_settings_history — append-only
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quote_settings_history (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text         NOT NULL,
  prev_amount  numeric      NULL,
  next_amount  numeric      NOT NULL,
  actor        uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name   text         NULL,
  at           timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quote_settings_history_key_at ON public.quote_settings_history (key, at DESC);

COMMENT ON TABLE public.quote_settings_history IS
  '[426] 견적 기준값 변경 이력(추가만). 어느 판의 견적서가 어떤 기준값으로 계산됐는지는 data.quote.basis 가 따로 갖는다 — '
  '이 표는 「누가 언제 값을 바꿨나」의 근거.';

-- ------------------------------------------------------------
-- 접근 정책
-- ------------------------------------------------------------
ALTER TABLE public.quote_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_settings_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quote_settings_select_admin ON public.quote_settings;
CREATE POLICY quote_settings_select_admin ON public.quote_settings
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));

DROP POLICY IF EXISTS quote_settings_history_select_admin ON public.quote_settings_history;
CREATE POLICY quote_settings_history_select_admin ON public.quote_settings_history
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));
-- 쓰기 정책 없음 — 함수(SECURITY DEFINER)만 쓴다

-- ------------------------------------------------------------
-- [E] 초기 9행 (있으면 건드리지 않는다 — 재실행 안전)
-- ------------------------------------------------------------
INSERT INTO public.quote_settings (key, amount, unit, label_ko, sort_order) VALUES
  ('exchange_rate_krw_per_jpy',        10,    'krw',  '엔→원 환율 (1엔당 원)',              10),   -- ⚠️ 단위는 krw(1엔당 원) — rate 로 두면 화면이 「1000 %」로 그리고 1 초과 거부에 걸려 수정이 막힌다
  ('reviewer_transfer_fee_krw',        2500,  'krw',  '리뷰어 1명당 해외 송금 수수료',       20),
  ('reviewer_recruit_fee_krw',         0,     'krw',  '리뷰어 1명당 모집비',                 30),
  ('seeding_fee_krw_instagram_feed',   0,     'krw',  '시딩 1명당 진행비 — 인스타그램 피드',  40),
  ('seeding_fee_krw_instagram_reels',  0,     'krw',  '시딩 1명당 진행비 — 인스타그램 릴스',  41),
  ('seeding_fee_krw_x',                0,     'krw',  '시딩 1명당 진행비 — X',               42),
  ('seeding_fee_krw_tiktok',           0,     'krw',  '시딩 1명당 진행비 — 틱톡',            43),
  ('seeding_fee_krw_youtube',          0,     'krw',  '시딩 1명당 진행비 — 유튜브',          44),
  ('vat_rate',                         0.10,  'rate', '부가세율',                            90)
ON CONFLICT (key) DO NOTHING;

-- 2026-09-08 개발 적용본이 환율 단위를 rate 로 넣었던 것을 바로잡는다(운영 첫 적용에는 위 시드가 이미 krw 라 0행)
UPDATE public.quote_settings SET unit = 'krw' WHERE key = 'exchange_rate_krw_per_jpy' AND unit = 'rate';

-- ------------------------------------------------------------
-- [C] get_quote_settings — 관리자 조회
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_quote_settings()
RETURNS TABLE (key text, amount numeric, unit text, label_ko text, sort_order integer, updated_at timestamptz, updated_by uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT q.key, q.amount, q.unit, q.label_ko, q.sort_order, q.updated_at, q.updated_by
  FROM public.quote_settings q
  WHERE public.is_admin()
  ORDER BY q.sort_order, q.key;
$$;

REVOKE ALL ON FUNCTION public.get_quote_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quote_settings() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_quote_settings() TO authenticated;

COMMENT ON FUNCTION public.get_quote_settings() IS
  '[426] 견적 기준값 전체 조회 — 관리자(is_admin)만. 관리자가 아니면 0행(오류 대신 빈 결과 — 표 정책과 같은 뜻).';

-- ------------------------------------------------------------
-- [D] update_quote_setting — 캠페인 관리자 이상 수정 + 이력
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_quote_setting(p_key text, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_prev   numeric;
  v_unit   text;
  v_name   text;
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_amount');
  END IF;

  SELECT amount, unit INTO v_prev, v_unit FROM public.quote_settings WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_key');
  END IF;
  -- 비율(부가세율)은 0~1 사이만 — 10 을 넣어 1000% 가 되는 실수 방지
  IF v_unit = 'rate' AND p_amount > 1 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_amount');
  END IF;

  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  UPDATE public.quote_settings
     SET amount = p_amount, updated_at = now(), updated_by = auth.uid()
   WHERE key = p_key;

  INSERT INTO public.quote_settings_history (key, prev_amount, next_amount, actor, actor_name)
  VALUES (p_key, v_prev, p_amount, auth.uid(), v_name);

  RETURN jsonb_build_object('success', true, 'key', p_key, 'prev_amount', v_prev, 'amount', p_amount);
END;
$$;

REVOKE ALL ON FUNCTION public.update_quote_setting(text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_quote_setting(text, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_quote_setting(text, numeric) TO authenticated;

COMMENT ON FUNCTION public.update_quote_setting(text, numeric) IS
  '[426] 견적 기준값 수정 — 캠페인 관리자 이상(is_campaign_admin). 값이 같아도 이력 1행. 거부 reason: forbidden·invalid_amount·unknown_key. '
  '비율(unit=rate)은 0~1 만 허용.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후)
-- [V1] SELECT count(*) FROM public.quote_settings;  -- 9
-- [V2] 관리자 로그인 브라우저: await db.rpc('get_quote_settings')  → 9행
-- [V3] 캠페인 관리자: await db.rpc('update_quote_setting', {p_key:'vat_rate', p_amount:0.1})  → success, 이력 1행
-- [V4] 캠페인 매니저: 같은 호출 → reason 'forbidden'
-- [V5] 비로그인(anon 키): db.from('quote_settings').select() → 0행 (정책), rpc → 권한 오류
-- [V6] SELECT proacl::text FROM pg_proc WHERE proname IN ('get_quote_settings','update_quote_setting');  -- =X/ 없음, anon 없음
-- ============================================================
