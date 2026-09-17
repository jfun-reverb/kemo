-- ============================================================
-- 438_meta_pixel_settings.sql
-- 2026-09-15 — 메타 픽셀 도입 · 마이그레이션 ① (작업 1)
--   사양서 docs/specs/2026-09-03-meta-pixel.md 「관리 화면 — 데이터베이스」
--   작업표 docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 1」
--
-- 무엇을 만드나
--   [A] 표 public.meta_pixel_settings          — 한 줄짜리 설정(아이디·켜기·방침 시행일)
--   [B] 표 public.meta_pixel_settings_history  — 변경 이력(추가만)
--   [C] 함수 _meta_pixel_policy_in_effect(date) — 🔴 방침 시행일 판정의 **유일한 정의처**
--   [D] 트리거 trg_meta_pixel_settings_history  — 세 칸 중 하나라도 바뀌면 이력 1행
--   [E] 함수 get_meta_pixel_admin()             — 관리 화면 조회(관리자 전원)
--   [F] 함수 update_meta_pixel_settings(text, boolean) — 아이디 저장·켜기·끄기
--   [G] 함수 get_public_meta_pixel_id()         — 인플루언서 앱용 조회(비로그인·로그인)
--
-- ★ 이 파일만 적용하면 **전송 0** 이다 — 시행일이 비어 있어 [G] 가 항상 '' 를 돌려준다.
--
-- ------------------------------------------------------------
-- ① 🔴 시행일 판정은 세 곳이 쓰지만 식은 한 곳에만 둔다
-- ------------------------------------------------------------
--   사양서는 세 곳(저장 거부 [F] · 앱용 조회 [G] · 상태 배지 [E])이 「글자 그대로 같은 식」을
--   갖도록 적었다. 한 곳만 `<` 이면 시행 당일 「켤 수는 있는데 전송이 안 되는」 상태가 생기기
--   때문이다. 세 벌을 맞춰 두는 대신 **[C] 한 함수를 셋이 부르게** 해 어긋날 자리 자체를 없앤다.
--     식: p_date IS NOT NULL AND p_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date
--   ⚠️ 이 식을 다른 함수에 복사해 넣지 말 것 — 반드시 [C] 를 부른다.
--
-- ------------------------------------------------------------
-- ② 🔴 시행일을 바꾸는 함수는 만들지 않는다
-- ------------------------------------------------------------
--   policy_effective_date 는 개인정보처리방침 개정 시행일이고, 그 값을 넣는 것이 곧 켜기 잠금
--   해제다. 화면·함수로 바꿀 수 있으면 사람 실수 하나로 잠금이 풀린다 → SQL 편집기로만 넣는다.
--   그래서 **이력은 저장 함수가 아니라 트리거가 쓴다** — SQL 로 넣은 시행일·SQL 로 켠 값도
--   이력에 남아야 하기 때문이다. 이때 「누가」는 auth.uid() 가 없어 NULL → 화면 「시스템(직접 입력)」.
--   ⚠️ updated_by 를 이력의 actor 로 옮겨 적지 않는다 — SQL 로 바꾸면 직전 저장자가 찍힌다.
--
-- ------------------------------------------------------------
-- ③ 🔴 켜기 거부 조건은 「꺼짐 → 켜짐」 한 방향뿐
-- ------------------------------------------------------------
--   켜짐 값인 채 아이디만 바꾸거나 끄는 것은 시행일과 무관하게 **항상** 허용한다.
--   끄기를 막으면 SQL 편집기로 켜 둔 값이 시행일 당일 확인 없이 전송을 시작하는 것을 막을
--   화면 수단이 사라진다(사양서 화면 구성 3).
--
-- ------------------------------------------------------------
-- ④ 앱용 조회 [G] 가 넷을 모두 보는 이유
-- ------------------------------------------------------------
--   켜짐 · 아이디 있음 · 시행일 도래 · 부른 사람이 관리자·감사용 계정 아님.
--   저장 함수만 막으면 SQL 로 enabled 를 켠 실수에 안 걸린다 → 내보내는 쪽에서 한 번 더 막는다.
--   관리자·감사용 제외는 332(record_site_visit)와 같은 판정이다.
--   ⚠️ 설정 표를 비로그인에게 열지 않는다 — 이력·수정자까지 보이면 안 된다. 문자열 하나만 준다.
--
-- ------------------------------------------------------------
-- ⑤ 권한 — 회수 방향이 둘이다(369·370·375)
-- ------------------------------------------------------------
--   [G] 만 anon·authenticated 에 연다. [E]·[F] 는 PUBLIC·anon 회수 + authenticated 부여.
--   [C]·트리거 함수는 PUBLIC·anon·authenticated 모두 회수(소유자 권한 함수 안에서만 쓴다).
--   ⚠️ [F] 의 서버 가드는 is_campaign_admin() 이 아니라 has_permission('ad_tracking.manage','write')
--     — 권한 관리 화면 설정이 무시되는 「설정 미적용」 목록을 늘리지 않는다.
--     그 열쇠말의 시드는 439. 🔴 439 가 없으면 캠페인 관리자도 거부된다(fail-closed).
--
-- ⚠️ 검증 함정: [E]·[F]·[G] 의 관리자·권한·감사용 판정은 auth.uid() 에 기댄다.
--   SQL 편집기는 서비스 키라 로그인 사용자가 비어 있어 그 분기를 재현하지 못한다 → 실제 로그인 브라우저로.
--
-- 롤백(읽는 코드가 없으면 영향 0 — 화면을 먼저 되돌린 뒤):
--   DROP FUNCTION public.get_public_meta_pixel_id();
--   DROP FUNCTION public.update_meta_pixel_settings(text, boolean);
--   DROP FUNCTION public.get_meta_pixel_admin();
--   DROP TRIGGER trg_meta_pixel_settings_history ON public.meta_pixel_settings;
--   DROP FUNCTION public.record_meta_pixel_settings_history();
--   DROP FUNCTION public._meta_pixel_policy_in_effect(date);
--   DROP TABLE public.meta_pixel_settings_history; DROP TABLE public.meta_pixel_settings;
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] meta_pixel_settings — 한 줄짜리
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.meta_pixel_settings (
  id                     smallint     PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  meta_pixel_id          text         NULL CHECK (meta_pixel_id IS NULL OR meta_pixel_id ~ '^[0-9]{1,32}$'),
  enabled                boolean      NOT NULL DEFAULT false,
  policy_effective_date  date         NULL,
  updated_at             timestamptz  NOT NULL DEFAULT now(),
  updated_by             uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.meta_pixel_settings IS
  '[438] 메타 픽셀 설정(한 줄, id=1). 조회 is_admin(), 쓰기 정책 없음 — 아이디·켜기는 update_meta_pixel_settings() 만, '
  '방침 시행일은 SQL 편집기로만 넣는다(수정 함수 없음). 인플루언서 앱은 get_public_meta_pixel_id() 로 문자열 하나만 받는다.';
COMMENT ON COLUMN public.meta_pixel_settings.meta_pixel_id IS '메타 픽셀 아이디(숫자만). 비면 전송하지 않는다.';
COMMENT ON COLUMN public.meta_pixel_settings.policy_effective_date IS
  '개인정보처리방침 개정 시행일(일본 날짜). 🔴 이 값을 넣는 것이 켜기 잠금 해제다 — 수정 함수 없음, SQL 로만. '
  '비어 있거나 미래면 켤 수 없고 앱용 조회도 빈 값. 판정은 _meta_pixel_policy_in_effect() 한 곳.';

INSERT INTO public.meta_pixel_settings (id, meta_pixel_id, enabled, policy_effective_date)
VALUES (1, NULL, false, NULL)
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------
-- [B] meta_pixel_settings_history — 추가만
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.meta_pixel_settings_history (
  id                          bigserial    PRIMARY KEY,
  at                          timestamptz  NOT NULL DEFAULT now(),
  actor                       uuid         NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name                  text         NULL,
  prev_meta_pixel_id          text         NULL,
  next_meta_pixel_id          text         NULL,
  prev_enabled                boolean      NULL,
  next_enabled                boolean      NULL,
  prev_policy_effective_date  date         NULL,
  next_policy_effective_date  date         NULL
);

CREATE INDEX IF NOT EXISTS idx_meta_pixel_settings_history_at
  ON public.meta_pixel_settings_history (at DESC, id DESC);

COMMENT ON TABLE public.meta_pixel_settings_history IS
  '[438] 메타 픽셀 설정 변경 이력(추가만). 설정 표의 변경 트리거가 쓴다 — SQL 로 넣은 시행일·SQL 로 켠 값도 남는다. '
  'actor NULL = 로그인 사용자 없음(SQL 편집기) → 화면 「시스템(직접 입력)」.';
COMMENT ON COLUMN public.meta_pixel_settings_history.actor_name IS
  '바꾼 시점의 관리자 이름 스냅샷(계정이 지워져도 남는다). actor 가 있는데 관리자가 아니면 NULL.';

-- ------------------------------------------------------------
-- 접근 정책 — 조회 관리자만, 쓰기 정책 없음
-- ------------------------------------------------------------
ALTER TABLE public.meta_pixel_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meta_pixel_settings_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS meta_pixel_settings_select_admin ON public.meta_pixel_settings;
CREATE POLICY meta_pixel_settings_select_admin ON public.meta_pixel_settings
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));

DROP POLICY IF EXISTS meta_pixel_settings_history_select_admin ON public.meta_pixel_settings_history;
CREATE POLICY meta_pixel_settings_history_select_admin ON public.meta_pixel_settings_history
  FOR SELECT TO authenticated USING ((SELECT public.is_admin()));

-- ------------------------------------------------------------
-- [C] _meta_pixel_policy_in_effect — 🔴 시행일 판정의 유일한 정의처
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._meta_pixel_policy_in_effect(p_date date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER   -- 명시 — 소유자 권한 함수([E][F][G]) 안에서만 불린다. DEFINER 로 바꿀 이유가 없다
SET search_path = ''
AS $$
  SELECT p_date IS NOT NULL AND p_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date;
$$;

REVOKE ALL ON FUNCTION public._meta_pixel_policy_in_effect(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._meta_pixel_policy_in_effect(date) FROM anon, authenticated;

COMMENT ON FUNCTION public._meta_pixel_policy_in_effect(date) IS
  '[438] 방침 시행일이 도래했나(일본 날짜, 당일 포함). 저장 거부·앱용 조회·상태 배지가 모두 이 함수를 부른다 — '
  '식을 다른 곳에 복사하지 말 것. 표를 읽지 않는 순수 판정이라 NULL 이면 false(fail-closed). 내부 전용.';

-- ------------------------------------------------------------
-- [D] 변경 트리거 — 세 칸 중 하나라도 바뀌면 이력 1행
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_meta_pixel_settings_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_name  text;
BEGIN
  IF NEW.meta_pixel_id         IS NOT DISTINCT FROM OLD.meta_pixel_id
     AND NEW.enabled               IS NOT DISTINCT FROM OLD.enabled
     AND NEW.policy_effective_date IS NOT DISTINCT FROM OLD.policy_effective_date THEN
    RETURN NULL;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = v_uid;
  END IF;

  INSERT INTO public.meta_pixel_settings_history (
    actor, actor_name,
    prev_meta_pixel_id, next_meta_pixel_id,
    prev_enabled, next_enabled,
    prev_policy_effective_date, next_policy_effective_date
  ) VALUES (
    v_uid, v_name,
    OLD.meta_pixel_id, NEW.meta_pixel_id,
    OLD.enabled, NEW.enabled,
    OLD.policy_effective_date, NEW.policy_effective_date
  );
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.record_meta_pixel_settings_history() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_meta_pixel_settings_history() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_meta_pixel_settings_history ON public.meta_pixel_settings;
CREATE TRIGGER trg_meta_pixel_settings_history
  AFTER UPDATE ON public.meta_pixel_settings
  FOR EACH ROW EXECUTE FUNCTION public.record_meta_pixel_settings_history();

-- ------------------------------------------------------------
-- [E] get_meta_pixel_admin — 관리 화면 조회(관리자 전원)
--   status 판정 순서(앞에서 걸리면 끝): policy_locked → no_pixel_id → disabled → active
--   ⚠️ 켜짐 값이어도 시행 전이면 policy_locked(SQL 로 켠 경우 포함)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_meta_pixel_admin()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row      public.meta_pixel_settings%ROWTYPE;
  v_status   text;
  v_history  jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.meta_pixel_settings WHERE id = 1;
  -- 설정 행이 지워진 경우(SQL 로만 가능) — 앱용 조회도 빈 값이므로 「시행 전」과 같게 보여준다.
  --   이력 표는 남아 있을 수 있으니 이력은 그대로 아래에서 읽는다.
  v_status := CASE
    WHEN NOT FOUND THEN 'policy_locked'
    WHEN NOT public._meta_pixel_policy_in_effect(v_row.policy_effective_date) THEN 'policy_locked'
    WHEN v_row.meta_pixel_id IS NULL THEN 'no_pixel_id'
    WHEN NOT v_row.enabled THEN 'disabled'
    ELSE 'active'
  END;

  SELECT COALESCE(jsonb_agg(h.item ORDER BY h.at DESC, h.id DESC), '[]'::jsonb)
    INTO v_history
    FROM (
      SELECT x.at, x.id,
             jsonb_build_object(
               'at', x.at,
               'by_system', x.actor IS NULL,
               'actor_name', x.actor_name,
               'prev_meta_pixel_id', x.prev_meta_pixel_id,
               'next_meta_pixel_id', x.next_meta_pixel_id,
               'prev_enabled', x.prev_enabled,
               'next_enabled', x.next_enabled,
               'prev_policy_effective_date', x.prev_policy_effective_date,
               'next_policy_effective_date', x.next_policy_effective_date
             ) AS item
        FROM public.meta_pixel_settings_history x
       ORDER BY x.at DESC, x.id DESC
       LIMIT 50
    ) h;

  RETURN jsonb_build_object(
    'meta_pixel_id', v_row.meta_pixel_id,
    'enabled', v_row.enabled,
    'policy_effective_date', v_row.policy_effective_date,
    'updated_at', v_row.updated_at,
    'status', v_status,
    'history', v_history
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_meta_pixel_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_meta_pixel_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_meta_pixel_admin() TO authenticated;

COMMENT ON FUNCTION public.get_meta_pixel_admin() IS
  '[438] 광고 추적 관리 화면 조회 — 관리자 전원(is_admin). 설정 + 서버가 정한 status(policy_locked·no_pixel_id·disabled·active) '
  '+ 최근 이력 50건. 화면은 status 를 그대로 그린다(날짜 비교 금지). 관리자가 아니면 42501.';

-- ------------------------------------------------------------
-- [F] update_meta_pixel_settings — 아이디 저장·켜기·끄기
--   거부 reason: forbidden · invalid_input · invalid_pixel_id · policy_not_in_effect
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_meta_pixel_settings(p_meta_pixel_id text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row  public.meta_pixel_settings%ROWTYPE;
  v_id   text;
BEGIN
  IF NOT public.has_permission('ad_tracking.manage', 'write') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;
  IF p_enabled IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_input');
  END IF;

  -- 빈 문자열·공백뿐 → NULL(아이디 삭제)
  v_id := NULLIF(btrim(COALESCE(p_meta_pixel_id, '')), '');
  IF v_id IS NOT NULL AND v_id !~ '^[0-9]{1,32}$' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_pixel_id');
  END IF;

  SELECT * INTO v_row FROM public.meta_pixel_settings WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_input');
  END IF;

  -- 🔴 「꺼짐 → 켜짐」 만 시행일로 막는다(③). 켜짐 유지 상태의 아이디 저장·끄기는 항상 허용
  IF v_row.enabled = false AND p_enabled = true
     AND NOT public._meta_pixel_policy_in_effect(v_row.policy_effective_date) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'policy_not_in_effect');
  END IF;

  UPDATE public.meta_pixel_settings
     SET meta_pixel_id = v_id,
         enabled       = p_enabled,
         updated_at    = now(),
         updated_by    = auth.uid()
   WHERE id = 1;
  -- 이력은 트리거([D])가 남긴다

  RETURN jsonb_build_object('success', true, 'meta_pixel_id', v_id, 'enabled', p_enabled);
END;
$$;

REVOKE ALL ON FUNCTION public.update_meta_pixel_settings(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_meta_pixel_settings(text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_meta_pixel_settings(text, boolean) TO authenticated;

COMMENT ON FUNCTION public.update_meta_pixel_settings(text, boolean) IS
  '[438] 메타 픽셀 아이디 저장·켜기·끄기 — has_permission(''ad_tracking.manage'',''write''). 빈 문자열은 아이디 삭제. '
  '「꺼짐→켜짐」 요청만 방침 시행 전이면 policy_not_in_effect 로 거부(끄기·아이디만 저장은 항상 허용). '
  '거부 reason: forbidden·invalid_input·invalid_pixel_id·policy_not_in_effect. 시행일은 바꾸지 않는다.';

-- ------------------------------------------------------------
-- [G] get_public_meta_pixel_id — 인플루언서 앱용(비로그인·로그인)
--   넷 다 참일 때만 아이디, 아니면 '' — 실패와 구분하려고 NULL 을 돌려주지 않는다
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_meta_pixel_id()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_id   text;
BEGIN
  IF v_uid IS NOT NULL THEN
    -- 관리자 제외(332 와 같은 판정)
    IF EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = v_uid) THEN
      RETURN '';
    END IF;
    -- 감사용 계정 제외(179·263·332 와 같은 기준)
    IF EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = v_uid AND i.is_audit = true) THEN
      RETURN '';
    END IF;
  END IF;

  SELECT s.meta_pixel_id INTO v_id
    FROM public.meta_pixel_settings s
   WHERE s.id = 1
     AND s.enabled = true
     AND s.meta_pixel_id IS NOT NULL
     AND public._meta_pixel_policy_in_effect(s.policy_effective_date);

  RETURN COALESCE(v_id, '');
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_meta_pixel_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_meta_pixel_id() TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_meta_pixel_id() IS
  '[438] 인플루언서 앱용 — ①켜짐 ②아이디 있음 ③방침 시행일 도래 ④부른 사람이 관리자·감사용 계정 아님, 넷 다 참일 때만 '
  '아이디 문자열. 아니면 빈 문자열(NULL 아님 — 화면이 조회 실패와 구분한다). 설정 표를 통째로 열지 않는다.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 1단계씩)
-- ============================================================
/*
-- [V1] (SQL 편집기) 표 2개·시드 1행
SELECT id, meta_pixel_id, enabled, policy_effective_date FROM public.meta_pixel_settings;
-- 기대: 1행 (1, NULL, false, NULL)

-- [V2] (SQL 편집기) 권한 — =X/ 없음, 앱용 조회만 anon 있음, 내부 함수 둘은 anon·authenticated 없음
SELECT proname, proacl::text FROM pg_proc
 WHERE pronamespace = 'public'::regnamespace
   AND proname IN ('get_meta_pixel_admin','update_meta_pixel_settings','get_public_meta_pixel_id',
                   'record_meta_pixel_settings_history','_meta_pixel_policy_in_effect');

-- [V3] (비로그인 브라우저 콘솔) await db.rpc('get_public_meta_pixel_id')  → data === ''

-- [V4] (관리자 로그인 콘솔) await db.rpc('get_meta_pixel_admin')  → status 'policy_locked', history []

-- [V5] (캠페인 관리자 로그인 콘솔 — 439 적용 뒤)
--   await db.rpc('update_meta_pixel_settings', {p_meta_pixel_id:'123', p_enabled:true})  → reason 'policy_not_in_effect'
--   await db.rpc('update_meta_pixel_settings', {p_meta_pixel_id:'12a', p_enabled:false}) → reason 'invalid_pixel_id'
--   await db.rpc('update_meta_pixel_settings', {p_meta_pixel_id:'123', p_enabled:false}) → success, 이력 1행(actor_name 채워짐)

-- [V6] (SQL 편집기) 시행일 입력 → 이력 actor NULL 1행 → 되돌림
UPDATE public.meta_pixel_settings SET policy_effective_date = '2000-01-01' WHERE id = 1;
SELECT actor, actor_name, prev_policy_effective_date, next_policy_effective_date
  FROM public.meta_pixel_settings_history ORDER BY id DESC LIMIT 1;   -- actor NULL
UPDATE public.meta_pixel_settings SET policy_effective_date = NULL WHERE id = 1;
*/
