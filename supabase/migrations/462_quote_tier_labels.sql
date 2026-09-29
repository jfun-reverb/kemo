-- ============================================================
-- 462_quote_tier_labels.sql
-- 2026-09-21 — 오리엔시트 견적 구간 이름·옵션 문구를 관리자가 고친다 · 마이그레이션 ①(표·이력·시드·정책·함수 둘)
--   사양서 docs/specs/2026-09-21-orient-tier-names-editable.md §3-1 · §3-2
--   상위: docs/specs/2026-09-21-orient-tier-slots-per-form.md(구간 인원 형식별, 460·461) ·
--         docs/specs/2026-09-21-orient-tier-direct-input.md(구간 다섯, 458·459)
--
-- 이 파일이 하는 일 — 표 둘 + 시드 10행 + 접근 정책 + 함수 둘. 계산·폼 응답은 아직 이 표를
--   안 읽으므로(다음 파일 463 이 읽는다) 이 파일 단독 적용으로는 견적·폼 표시가 한 가지도
--   안 바뀐다.
--   [A] 표 public.quote_tier_labels — 형식(reviewer|seeding) × 구간(tmin·t50·t100·t300·
--       t500plus) 별 이름·옵션 문구. 기본 키 (form_type, tier), 정확히 10행.
--   [B] 표 public.quote_tier_labels_history — 값 변경 이력(추가만). quote_settings_history 와
--       같은 꼴(칸 이름만 key→(form_type,tier,field)).
--   [C] 시드 10행 — 소량·라이트·스탠다드·프리미엄·프리미엄+(두 형식 공통). 옵션 문구는 맨 끝
--       구간만 "+실검작업", 나머지는 비움.
--   [D] 함수 get_quote_tier_labels() — 관리자 전원(is_admin) 조회.
--   [E] 함수 update_quote_tier_label(form_type, tier, name, option_text) — 캠페인 관리자
--       이상(is_campaign_admin) 수정 + 바뀐 칸마다 이력 1행.
--
-- 🔴 quote_settings 에 글자 칸을 더하는 방법은 쓰지 않는다(사양서 §3-1) — 45행 중 10행만
--   쓰는 칸이 생기고, get_quote_settings 반환 모양을 바꾸려면 DROP 이 필요해 권한 회수를
--   다시 걸어야 하며, 숫자 이력과 글자 이력이 한 표에 섞인다. 그래서 새 표를 쓴다.
--
-- 접근: SELECT is_admin(), 쓰기 정책 없음(함수만). 비로그인(작성 폼)은 이 표를 직접 못 읽는다
--   — 함수용 조회는 다음 파일(463)이 SECURITY DEFINER 안에서 읽는다.
--
-- 롤백: DROP FUNCTION public.update_quote_tier_label(text, text, text, text);
--       DROP FUNCTION public.get_quote_tier_labels();
--       DROP TABLE public.quote_tier_labels_history;
--       DROP TABLE public.quote_tier_labels;
--   🔴 463 을 먼저 되돌릴 것 — 463 의 두 함수가 이 표를 참조하므로, 이 표를 먼저 지우면 463 의
--   함수가 없는 표를 읽어 모든 견적 계산이 예외로 실패한다.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] quote_tier_labels
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quote_tier_labels (
  form_type    text         NOT NULL CHECK (form_type IN ('reviewer', 'seeding')),
  tier         text         NOT NULL CHECK (tier IN ('tmin', 't50', 't100', 't300', 't500plus')),
  name         text         NOT NULL,
  option_text  text         NOT NULL DEFAULT '',
  updated_at   timestamptz  NOT NULL DEFAULT now(),
  updated_by   uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (form_type, tier),
  -- 1~8자(앞뒤 공백 제거 뒤) — char_length 는 문자 수(바이트 아님)
  CONSTRAINT quote_tier_labels_name_len CHECK (char_length(btrim(name)) BETWEEN 1 AND 8),
  -- 0~16자(앞뒤 공백 제거 뒤). 비움 = 옵션 없음
  CONSTRAINT quote_tier_labels_option_len CHECK (char_length(btrim(option_text)) <= 16),
  -- 방어 — 저장형 교차 사이트 스크립팅(XSS) 차단. 실제 검증은 update_quote_tier_label 이 먼저 한다
  CONSTRAINT quote_tier_labels_no_angle_brackets CHECK (name !~ '[<>]' AND option_text !~ '[<>]')
);

COMMENT ON TABLE public.quote_tier_labels IS
  '[462] 오리엔시트 견적 구간 이름·옵션 문구. 형식(reviewer|seeding)마다 구간 다섯(tmin·t50·t100·t300· '
  't500plus) 이름을 따로 둔다(구간 인원 구조와 동일 — 461). 조회 is_admin(), 수정은 '
  'update_quote_tier_label()(캠페인 관리자 이상)만 — 직접 UPDATE 정책 없음. '
  '_orient_compute_quote·get_orient_tier_fees(463 부터)가 이 표를 읽는다. '
  '⚠️ 옵션 문구는 표시용일 뿐 견적 계산에 영향 없음(실검작업 줄은 인원 500 이상이면 형식·옵션과 '
  '무관하게 붙는다 — 461, 463 도 그대로 유지).';
COMMENT ON COLUMN public.quote_tier_labels.name IS
  '구간 이름(1~8자). 폼 단추·견적서 줄 이름·관리자 상세 「모집 구간」 칸에 쓰인다.';
COMMENT ON COLUMN public.quote_tier_labels.option_text IS
  '구간 옵션 문구(0~16자, 비움 허용). 폼 단추·직접입력 옆 줄에만 보이고 견적서·확인 화면 요약에는 안 싣는다.';

-- ------------------------------------------------------------
-- [B] quote_tier_labels_history — append-only
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quote_tier_labels_history (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  form_type    text         NOT NULL,
  tier         text         NOT NULL,
  field        text         NOT NULL CHECK (field IN ('name', 'option_text')),
  prev_value   text         NULL,
  next_value   text         NOT NULL,
  actor        uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name   text         NULL,
  at           timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quote_tier_labels_history_key_at
  ON public.quote_tier_labels_history (form_type, tier, at DESC);

COMMENT ON TABLE public.quote_tier_labels_history IS
  '[462] 견적 구간 이름·옵션 문구 변경 이력(추가만) — quote_settings_history 와 같은 목적. '
  '바뀐 칸(name·option_text)마다 별도 행.';

-- ------------------------------------------------------------
-- 접근 정책
-- ------------------------------------------------------------
ALTER TABLE public.quote_tier_labels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_tier_labels_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quote_tier_labels_select_admin ON public.quote_tier_labels;
CREATE POLICY quote_tier_labels_select_admin ON public.quote_tier_labels
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));

DROP POLICY IF EXISTS quote_tier_labels_history_select_admin ON public.quote_tier_labels_history;
CREATE POLICY quote_tier_labels_history_select_admin ON public.quote_tier_labels_history
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));
-- 쓰기 정책 없음 — 함수(SECURITY DEFINER)만 쓴다

-- ------------------------------------------------------------
-- [C] 시드 10행 (있으면 건드리지 않는다 — 재실행 안전) — 사양서 §3-1 표와 글자 그대로 같게
-- ------------------------------------------------------------
INSERT INTO public.quote_tier_labels (form_type, tier, name, option_text) VALUES
  ('reviewer', 'tmin',     '소량',    ''),
  ('reviewer', 't50',      '라이트',  ''),
  ('reviewer', 't100',     '스탠다드', ''),
  ('reviewer', 't300',     '프리미엄', ''),
  ('reviewer', 't500plus', '프리미엄+', '+실검작업'),
  ('seeding',  'tmin',     '소량',    ''),
  ('seeding',  't50',      '라이트',  ''),
  ('seeding',  't100',     '스탠다드', ''),
  ('seeding',  't300',     '프리미엄', ''),
  ('seeding',  't500plus', '프리미엄+', '+실검작업')
ON CONFLICT (form_type, tier) DO NOTHING;

-- ------------------------------------------------------------
-- [D] get_quote_tier_labels — 관리자 전원 조회
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_quote_tier_labels()
RETURNS TABLE (
  form_type   text,
  tier        text,
  name        text,
  option_text text,
  updated_at  timestamptz,
  updated_by  uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT l.form_type, l.tier, l.name, l.option_text, l.updated_at, l.updated_by
    FROM public.quote_tier_labels l
   WHERE public.is_admin()
   ORDER BY l.form_type,
            CASE l.tier
              WHEN 'tmin'     THEN 0
              WHEN 't50'      THEN 1
              WHEN 't100'     THEN 2
              WHEN 't300'     THEN 3
              WHEN 't500plus' THEN 4
              ELSE 9 END;
$$;

REVOKE ALL ON FUNCTION public.get_quote_tier_labels() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quote_tier_labels() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_quote_tier_labels() TO authenticated;

COMMENT ON FUNCTION public.get_quote_tier_labels() IS
  '[462] 견적 구간 이름·옵션 문구 10행 전체 조회 — 관리자(is_admin)만. 관리자가 아니면 0행 '
  '(오류 대신 빈 결과 — 표 정책과 같은 뜻).';

-- ------------------------------------------------------------
-- [E] update_quote_tier_label — 캠페인 관리자 이상 수정 + 이력
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_quote_tier_label(
  p_form_type   text,
  p_tier        text,
  p_name        text,
  p_option_text text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_prev_name   text;
  v_prev_option text;
  v_name        text;
  v_option      text;
  v_actor_name  text;
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;

  SELECT l.name, l.option_text INTO v_prev_name, v_prev_option
    FROM public.quote_tier_labels l
   WHERE l.form_type = p_form_type AND l.tier = p_tier
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_tier');
  END IF;

  -- 🔴 char_length — 문자 수로 센다(바이트로 세면 한글이 3배로 잡힌다)
  v_name   := btrim(COALESCE(p_name, ''));
  v_option := btrim(COALESCE(p_option_text, ''));

  IF v_name = '' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'name_required');
  END IF;
  IF char_length(v_name) > 8 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'name_too_long');
  END IF;
  IF char_length(v_option) > 16 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'option_too_long');
  END IF;
  IF v_name ~ '[<>]' OR v_option ~ '[<>]' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_text');
  END IF;

  SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid();

  UPDATE public.quote_tier_labels
     SET name = v_name, option_text = v_option, updated_at = now(), updated_by = auth.uid()
   WHERE form_type = p_form_type AND tier = p_tier;

  -- 바뀐 칸마다 이력 1행(안 바뀐 칸은 기록하지 않는다)
  IF v_prev_name IS DISTINCT FROM v_name THEN
    INSERT INTO public.quote_tier_labels_history (form_type, tier, field, prev_value, next_value, actor, actor_name)
    VALUES (p_form_type, p_tier, 'name', v_prev_name, v_name, auth.uid(), v_actor_name);
  END IF;
  IF v_prev_option IS DISTINCT FROM v_option THEN
    INSERT INTO public.quote_tier_labels_history (form_type, tier, field, prev_value, next_value, actor, actor_name)
    VALUES (p_form_type, p_tier, 'option_text', v_prev_option, v_option, auth.uid(), v_actor_name);
  END IF;

  RETURN jsonb_build_object('success', true, 'form_type', p_form_type, 'tier', p_tier,
                            'name', v_name, 'option_text', v_option);
END;
$$;

REVOKE ALL ON FUNCTION public.update_quote_tier_label(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_quote_tier_label(text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_quote_tier_label(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_quote_tier_label(text, text, text, text) IS
  '[462] 견적 구간 이름·옵션 문구 수정 — 캠페인 관리자 이상(is_campaign_admin). 두 값을 앞뒤 공백 '
  '제거해 저장, 바뀐 칸마다 이력 1행(둘 다 안 바뀌면 이력 없음). 거부 reason: forbidden · '
  'unknown_tier(없는 형식·구간 조합) · name_required(공백 제거 뒤 빈 값) · name_too_long(8자 초과) · '
  'option_too_long(16자 초과) · invalid_text(<, > 포함). 이 함수는 계산을 바꾸지 않는다 — 견적 '
  '금액·「실검작업」 줄 규칙은 _orient_compute_quote(463부터) 가 별도로 관리한다.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (개발 DB 적용 후)
-- ══════════════════════════════════════════════════════════════════════
/*
-- [V1] 정확히 10행이 들어갔는가
SELECT count(*) FROM public.quote_tier_labels;  -- 기대: 10
SELECT form_type, tier, name, option_text FROM public.quote_tier_labels
 ORDER BY form_type, CASE tier WHEN 'tmin' THEN 0 WHEN 't50' THEN 1 WHEN 't100' THEN 2
                                WHEN 't300' THEN 3 WHEN 't500plus' THEN 4 END;
-- 기대: 형식마다 소량·라이트·스탠다드·프리미엄·프리미엄+ / 옵션은 프리미엄+ 만 '+실검작업'

-- [V2] 관리자 조회(관리자 로그인 브라우저 콘솔)
--   await db.rpc('get_quote_tier_labels')  → 10행

-- [V3] 저장 — 정상
SELECT public.update_quote_tier_label('seeding', 't100', '베이직', '');
-- 기대: {"success":true,"form_type":"seeding","tier":"t100","name":"베이직","option_text":""}
SELECT name FROM public.quote_tier_labels WHERE form_type = 'reviewer' AND tier = 't100';
-- 기대: 스탠다드 (그대로 — 형식이 다르면 서로 영향 없음)
-- 원복: SELECT public.update_quote_tier_label('seeding', 't100', '스탠다드', '');

-- [V4] 거부 4종
SELECT public.update_quote_tier_label('reviewer', 't50', '', '');           -- 기대: name_required
SELECT public.update_quote_tier_label('reviewer', 't50', '<b>', '');        -- 기대: invalid_text
SELECT public.update_quote_tier_label('reviewer', 't50', '123456789', '');  -- 기대: name_too_long (9자)
SELECT public.update_quote_tier_label('reviewer', 'no_such_tier', '이름', ''); -- 기대: unknown_tier

-- [V5] 이력 — [V3] 저장이 name 만 바꿨을 때(option_text 는 '' 그대로) 이력이 1행만 쌓였는가
SELECT field, prev_value, next_value FROM public.quote_tier_labels_history
 WHERE form_type = 'seeding' AND tier = 't100' ORDER BY at DESC LIMIT 3;
-- 기대: 가장 최근 2행이 field='name' 만(원복 1행 + [V3] 1행) — option_text 이력 없음
*/
