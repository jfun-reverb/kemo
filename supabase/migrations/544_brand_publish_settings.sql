-- ============================================================
-- 544_brand_publish_settings.sql
-- 2026-10-19 — 캠페인마다 「브랜드 공개」 설정 + 브랜드 공개 기본 열(전체·브랜드) 서버
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 1」 · 결정 D3·D10·D12 · S19·S20
--   사양서 docs/specs/2026-07-15-brand-portal.md §4 「리포트 공유 링크」 ③(캠페인마다 브랜드 공개 · 기본 열 세 층)
--
-- 무엇을 하나 (이 파일이 하는 전부 — 표 셋·공개 함수 일곱·내부 함수 둘 추가, 기존 표·함수 변경 없음)
--   표   campaign_brand_publish          캠페인마다 공개 켜짐·열 목록(처음엔 줄이 없다 = 꺼짐)
--   표   brand_publish_default_global    전체 기본 열(싱글톤 id=1)
--   표   brand_publish_default_by_brand  브랜드만 따로 정한 기본 열(줄이 없으면 전체를 따른다)
--   함수 admin_get_campaign_brand_publish(campaign)                     읽기 — 공개 상태 + 처음 켤 때 쓸 기본값(서버가 고름)
--   함수 admin_set_campaign_brand_publish(campaign, enabled, columns, expected_version)  쓰기 — 낙관적 잠금(충돌이면 -1)
--   함수 admin_get_brand_publish_states(campaign[])                   읽기 — 배지·필터용 {캠페인: 켜짐}
--   함수 admin_get_brand_publish_defaults(brand)                      읽기 — {global_spec, brand_spec}
--   함수 admin_get_publish_default_for_campaigns(campaign[])          읽기 — 리포트 엑셀 처음 체크용 {spec, source}(서버가 고름)
--   함수 admin_set_brand_publish_default_global(spec)                  쓰기
--   함수 admin_set_brand_publish_default_brand(brand, spec)            쓰기 — NULL 이면 「전체 기본값 따르기」(줄 삭제)
--   적용만으로 바뀌는 기존 동작: 없음(이 표를 읽는 화면·판정이 아직 없다 — 조각 4·9·10·11 이 쓴다).
--
-- 🔴 운영 반영 — 작업표 「사전」 단계(출시 전 언제든). 브랜드 묶음(526~)의 표·함수에 기대지 않는다.
--
-- 계약
--   · 전부 SECURITY DEFINER SET search_path=''. 권한: GRANT TO postgres, authenticated, service_role → REVOKE FROM PUBLIC → REVOKE FROM anon.
--   · 읽기 = is_admin()(관리자 전원 — 매니저도 상태·기본값을 본다) / 쓰기 = has_permission('report.share','write')(413 공유 함수와 같은 등급 — 404 시드상 매니저 hidden).
--     🔴 권한이 없으면 42501. 화면은 숨김 등급에게 단추를 숨긴다(조각 9 — isHidden). 기본 열 칸만 사양서대로 읽기 전용(조각 11).
--   · 표 셋은 행 단위 보안을 켜고 정책을 두지 않는다 — 화면·브랜드는 이 함수들과 조각 4(정의자 권한)로만 읽고 쓴다.
--   · 열 목록·기본 열 명세는 문자열 배열(jsonb). 형식은 리포트 공유 열(412 share_columns)과 같은 열쇠 —
--     「-열쇠」 = 끔(새 열쇠), 옛 열쇠 16개는 「있으면 켬」. 판정은 report-rows.js reportShareColOff / 서버 _report_share_col_off.
--     기본 열 명세에는 종류 열쇠 kind:acct · kind:url · kind:at 가 더 있다 — 화면이 캠페인 열로 펼친다(조각 13 reportDefaultCheckedKeys).
--     이 파일은 형식(문자열 배열·길이)만 검사하고 열쇠 이름은 검사하지 않는다(열 대장은 화면 report-rows.js 한 곳).
--
-- 설계 판단
--   [A] 🔴 캠페인 표에 칸을 두지 않는다 — campaigns_bump_version()(275)이 공개를 켤 때마다 version 을 올려 편집 폼에 가짜 충돌이 나고,
--       변경 이력 화이트리스트 세 곳(265·266)을 함께 고쳐야 한다(작업표 의심 7).
--   [B] 처음 켤 때 체크 = 서버가 고른 기본값 — 캠페인의 브랜드가 따로 정했으면 그 값, 아니면(브랜드 없는 캠페인 포함) 전체 기본값.
--       🔴 기본값을 바꿔도 이미 켠 캠페인은 안 바뀐다 — 캠페인 줄에 저장된 columns 를 쓴다(사양서 ③).
--   [C] 줄이 한 번 생기면 지우지 않는다(끄면 enabled=false). 캠페인 복제는 이 줄을 복사하지 않는다(처음 꺼짐 — 복제 코드는 이 표를 모른다).
--   [D] 버전: 줄이 없을 때 expected_version = 0 으로 부르면 새 줄(version 1). 그 밖에는 줄의 version 과 같아야 저장(+1), 다르면 -1.
--   [E] merge_brands(528)는 손대지 않는다 — 원본 브랜드의 기본값 줄은 남고, 원본이 보관되면 그 브랜드 캠페인이 대상 브랜드로 옮겨 가므로 쓰이지 않는다.
--       브랜드 완전 삭제 때는 ON DELETE CASCADE 로 함께 지워진다.
--   [F] 변경 이력 표는 두지 않는다 — 누가 마지막으로 바꿨는지(updated_by·updated_at)와 처음 켠 시각(first_enabled_at)만(작업표 개발 기본값).
--
-- 🔴 반환 칸을 바꾸려면 DROP 후 CREATE 라 실행 권한 회수(PUBLIC → anon)를 다시 걸어야 한다. 다음 재정의의 베이스는 이 파일(544).
-- 편집기 경고: 실행 구문에 DROP·DELETE 가 있다 — admin_set_brand_publish_default_brand 본문의 DELETE(「전체 기본값 따르기」 = 브랜드 줄 삭제)뿐.
--
-- 롤백(화면 조각 9·10·11 을 먼저 되돌린 뒤):
--   DROP FUNCTION IF EXISTS public.admin_set_brand_publish_default_brand(uuid, jsonb);
--   DROP FUNCTION IF EXISTS public.admin_set_brand_publish_default_global(jsonb);
--   DROP FUNCTION IF EXISTS public.admin_get_publish_default_for_campaigns(uuid[]);
--   DROP FUNCTION IF EXISTS public.admin_get_brand_publish_defaults(uuid);
--   DROP FUNCTION IF EXISTS public.admin_get_brand_publish_states(uuid[]);
--   DROP FUNCTION IF EXISTS public.admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer);
--   DROP FUNCTION IF EXISTS public.admin_get_campaign_brand_publish(uuid);
--   DROP FUNCTION IF EXISTS public._brand_publish_keys_valid(jsonb);
--   DROP FUNCTION IF EXISTS public._brand_publish_default_for(uuid);
--   DROP TABLE IF EXISTS public.brand_publish_default_by_brand;
--   DROP TABLE IF EXISTS public.brand_publish_default_global;
--   DROP TABLE IF EXISTS public.campaign_brand_publish;
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 표 셋
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_brand_publish (
  campaign_id      uuid PRIMARY KEY REFERENCES public.campaigns(id) ON DELETE CASCADE,
  enabled          boolean     NOT NULL DEFAULT false,
  columns          jsonb       NULL,
  version          integer     NOT NULL DEFAULT 1,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid        NULL,
  first_enabled_at timestamptz NULL
);
COMMENT ON TABLE public.campaign_brand_publish IS
  '[544] 캠페인마다 브랜드 공개(브랜드 페이지 결과물 영역). 줄 없음 = 꺼짐. 읽기·쓰기는 admin_*_brand_publish 함수와 브랜드 결과물 조회(정의자 권한)로만.';
COMMENT ON COLUMN public.campaign_brand_publish.columns IS
  '보일 열 열쇠 배열 — 리포트 공유 열(412)과 같은 형식. 「-열쇠」 = 끔. 저장은 화면 reportPublishColsToSave(대장의 모든 새 열쇠를 적는다 — 공개 뒤 새로 생기는 열은 꺼짐, 결정 D3).';

CREATE TABLE IF NOT EXISTS public.brand_publish_default_global (
  id         integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  spec       jsonb       NOT NULL DEFAULT '[]'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid        NULL
);
COMMENT ON TABLE public.brand_publish_default_global IS
  '[544] 브랜드 공개 기본 열 — 전체(싱글톤). 처음 값은 담당자 회의 뒤(결정 D12 — 운영은 출시 날 ⓪에 넣는다).';
INSERT INTO public.brand_publish_default_global (id, spec) VALUES (1, '[]'::jsonb) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.brand_publish_default_by_brand (
  brand_id   uuid PRIMARY KEY REFERENCES public.brands(id) ON DELETE CASCADE,
  spec       jsonb       NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid        NULL
);
COMMENT ON TABLE public.brand_publish_default_by_brand IS
  '[544] 브랜드 공개 기본 열 — 이 브랜드만 따로 정한 값. 줄이 없으면 전체 기본값을 따른다.';

ALTER TABLE public.campaign_brand_publish         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_publish_default_global   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_publish_default_by_brand ENABLE ROW LEVEL SECURITY;
-- 정책 없음 — 함수로만 접근(계약 참조)

-- ------------------------------------------------------------
-- [2] 내부 — 열쇠 배열 형식 검사 · 캠페인 하나의 기본값 고르기
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_publish_keys_valid(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT p IS NOT NULL
     AND jsonb_typeof(p) = 'array'
     AND jsonb_array_length(p) <= 500
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(p) e
        WHERE jsonb_typeof(e) <> 'string' OR length(e #>> '{}') = 0 OR length(e #>> '{}') > 120
     );
$$;
COMMENT ON FUNCTION public._brand_publish_keys_valid(jsonb) IS '[544] 열 열쇠 배열 형식 검사(문자열 배열 · 500개 · 열쇠 120자 이하). 열쇠 이름은 검사하지 않는다.';

CREATE OR REPLACE FUNCTION public._brand_publish_default_for(p_brand_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  -- 브랜드가 따로 정했으면 그 값, 아니면(브랜드 없음 포함) 전체 기본값
  SELECT CASE
    WHEN b.spec IS NOT NULL THEN jsonb_build_object('spec', b.spec, 'source', 'brand')
    ELSE jsonb_build_object('spec', COALESCE(g.spec, '[]'::jsonb), 'source', 'global')
  END
    FROM (SELECT 1) one
    LEFT JOIN public.brand_publish_default_by_brand b ON b.brand_id = p_brand_id
    LEFT JOIN public.brand_publish_default_global   g ON g.id = 1;
$$;
COMMENT ON FUNCTION public._brand_publish_default_for(uuid) IS '[544] 브랜드 하나의 처음 체크 기본값 {spec, source} — 정의자 권한 함수 안에서만 부른다.';

GRANT  EXECUTE ON FUNCTION public._brand_publish_keys_valid(jsonb) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_publish_keys_valid(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_publish_keys_valid(jsonb) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._brand_publish_default_for(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_publish_default_for(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_publish_default_for(uuid) FROM anon, authenticated;

-- ------------------------------------------------------------
-- [3] 캠페인 공개 — 읽기
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_campaign_brand_publish(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand uuid;
  p       public.campaign_brand_publish%ROWTYPE;
  d       jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT c.brand_id INTO v_brand FROM public.campaigns c WHERE c.id = p_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 캠페인입니다' USING ERRCODE = '22023'; END IF;
  SELECT * INTO p FROM public.campaign_brand_publish WHERE campaign_id = p_campaign_id;
  d := public._brand_publish_default_for(v_brand);
  RETURN jsonb_build_object(
    'enabled',          COALESCE(p.enabled, false),
    'columns',          p.columns,                       -- 줄이 없거나 저장 전이면 NULL — 화면이 default_spec 으로 처음 체크를 펼친다
    'version',          COALESCE(p.version, 0),          -- 줄이 없으면 0(저장 때 expected_version 으로 그대로 보낸다)
    'updated_at',       p.updated_at,
    'first_enabled_at', p.first_enabled_at,
    'default_spec',     d -> 'spec',
    'default_source',   d ->> 'source'
  );
END;
$$;

-- ------------------------------------------------------------
-- [4] 캠페인 공개 — 쓰기(낙관적 잠금)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_campaign_brand_publish(
  p_campaign_id      uuid,
  p_enabled          boolean,
  p_columns          jsonb,
  p_expected_version integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ver integer;
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF p_enabled IS NULL THEN RAISE EXCEPTION '켜짐·꺼짐 값이 없습니다' USING ERRCODE = '22023'; END IF;
  IF p_columns IS NOT NULL AND NOT public._brand_publish_keys_valid(p_columns) THEN
    RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023';
  END IF;
  -- 켤 때는 열 목록이 있어야 한다(빈 배열은 허용 — 관리자가 일부러 아무 열도 안 고른 경우)
  IF p_enabled AND p_columns IS NULL THEN RAISE EXCEPTION '보일 열을 정해 주십시오' USING ERRCODE = '22023'; END IF;
  PERFORM 1 FROM public.campaigns WHERE id = p_campaign_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 캠페인입니다' USING ERRCODE = '22023'; END IF;   -- 보관 삭제된 캠페인은 바꾸지 않는다

  SELECT version INTO v_ver FROM public.campaign_brand_publish WHERE campaign_id = p_campaign_id FOR UPDATE;
  IF NOT FOUND THEN
    IF COALESCE(p_expected_version, 0) <> 0 THEN RETURN -1; END IF;
    INSERT INTO public.campaign_brand_publish (campaign_id, enabled, columns, version, updated_at, updated_by, first_enabled_at)
    VALUES (p_campaign_id, p_enabled, p_columns, 1, now(), v_uid, CASE WHEN p_enabled THEN now() END);
    RETURN 1;
  END IF;

  IF p_expected_version IS DISTINCT FROM v_ver THEN RETURN -1; END IF;
  UPDATE public.campaign_brand_publish SET
    enabled          = p_enabled,
    columns          = COALESCE(p_columns, columns),    -- 끌 때 열 목록을 안 보내면 저장된 열을 남긴다(다시 켤 때 그대로)
    version          = version + 1,
    updated_at       = now(),
    updated_by       = v_uid,
    first_enabled_at = COALESCE(first_enabled_at, CASE WHEN p_enabled THEN now() END)
  WHERE campaign_id = p_campaign_id
  RETURNING version INTO v_ver;
  RETURN v_ver;
END;
$$;

-- ------------------------------------------------------------
-- [5] 배지·필터용 상태 묶음
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_brand_publish_states(p_campaign_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF p_campaign_ids IS NULL OR cardinality(p_campaign_ids) = 0 THEN RETURN '{}'::jsonb; END IF;
  IF cardinality(p_campaign_ids) > 5000 THEN RAISE EXCEPTION '한 번에 5000개까지입니다' USING ERRCODE = '22023'; END IF;
  -- 줄이 없는 캠페인도 키로 싣는다(false) — 화면은 「키 없음」과 「꺼짐」을 가르지 않아도 된다
  SELECT COALESCE(jsonb_object_agg(x.id::text, COALESCE(p.enabled, false)), '{}'::jsonb)
    INTO v
    FROM (SELECT DISTINCT u AS id FROM unnest(p_campaign_ids) AS u WHERE u IS NOT NULL) x
    LEFT JOIN public.campaign_brand_publish p ON p.campaign_id = x.id;
  RETURN v;
END;
$$;

-- ------------------------------------------------------------
-- [6] 기본 열 — 읽기 둘
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_brand_publish_defaults(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  g jsonb;
  b jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT spec INTO g FROM public.brand_publish_default_global WHERE id = 1;
  IF p_brand_id IS NOT NULL THEN
    SELECT spec INTO b FROM public.brand_publish_default_by_brand WHERE brand_id = p_brand_id;
  END IF;
  RETURN jsonb_build_object('global_spec', COALESCE(g, '[]'::jsonb), 'brand_spec', b);   -- 따로 정하지 않았으면 brand_spec = null
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_publish_default_for_campaigns(p_campaign_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brands  integer;
  v_nobrand boolean;
  v_brand   uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF p_campaign_ids IS NULL OR cardinality(p_campaign_ids) = 0 THEN
    RETURN public._brand_publish_default_for(NULL);
  END IF;
  SELECT count(DISTINCT c.brand_id), bool_or(c.brand_id IS NULL), min(c.brand_id::text)::uuid
    INTO v_brands, v_nobrand, v_brand
    FROM public.campaigns c
   WHERE c.id = ANY (p_campaign_ids);
  -- 모두 한 브랜드면 그 브랜드의 기본값(따로 정했을 때만 brand), 여러 브랜드·브랜드 없는 캠페인이 섞이면 전체 기본값
  IF v_brands = 1 AND NOT COALESCE(v_nobrand, false) THEN
    RETURN public._brand_publish_default_for(v_brand);
  END IF;
  RETURN public._brand_publish_default_for(NULL);
END;
$$;

-- ------------------------------------------------------------
-- [7] 기본 열 — 쓰기 둘
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_brand_publish_default_global(p_spec jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF NOT public._brand_publish_keys_valid(p_spec) THEN RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.brand_publish_default_global (id, spec, updated_at, updated_by)
  VALUES (1, p_spec, now(), auth.uid())
  ON CONFLICT (id) DO UPDATE SET spec = EXCLUDED.spec, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_brand_publish_default_brand(p_brand_id uuid, p_spec jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  PERFORM 1 FROM public.brands WHERE id = p_brand_id;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 브랜드입니다' USING ERRCODE = '22023'; END IF;
  IF p_spec IS NULL THEN
    -- 「전체 기본값 따르기」
    DELETE FROM public.brand_publish_default_by_brand WHERE brand_id = p_brand_id;
    RETURN true;
  END IF;
  IF NOT public._brand_publish_keys_valid(p_spec) THEN RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.brand_publish_default_by_brand (brand_id, spec, updated_at, updated_by)
  VALUES (p_brand_id, p_spec, now(), auth.uid())
  ON CONFLICT (brand_id) DO UPDATE SET spec = EXCLUDED.spec, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
  RETURN true;
END;
$$;

-- ------------------------------------------------------------
-- [8] 실행 권한 — 공개 일곱: authenticated 만(관리자 판정은 본문) · PUBLIC·anon 회수 둘 다
-- ------------------------------------------------------------
GRANT  EXECUTE ON FUNCTION public.admin_get_campaign_brand_publish(uuid)                          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer) TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_get_brand_publish_states(uuid[])                          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid)                          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_get_publish_default_for_campaigns(uuid[])                 TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_set_brand_publish_default_global(jsonb)                   TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_set_brand_publish_default_brand(uuid, jsonb)              TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_get_campaign_brand_publish(uuid)                          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_states(uuid[])                          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid)                          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_publish_default_for_campaigns(uuid[])                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_publish_default_global(jsonb)                   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_publish_default_brand(uuid, jsonb)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_campaign_brand_publish(uuid)                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_states(uuid[])                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid)                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_publish_default_for_campaigns(uuid[])                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_publish_default_global(jsonb)                   FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_publish_default_brand(uuid, jsonb)              FROM anon;

COMMIT;

-- ============================================================
-- 적용 뒤 확인
--   [V1] 표 셋·함수 아홉이 있고 권한이 맞는가(SQL 편집기)
--     SELECT proname, proacl::text FROM pg_proc WHERE proname LIKE 'admin_%brand_publish%' OR proname LIKE '_brand_publish_%' OR proname = 'admin_get_publish_default_for_campaigns';
--     → 공개 일곱: authenticated=X, 맨 앞 =X/ 없음, anon 없음 · 내부 둘: authenticated·anon 없음
--   [V2] 🔴 실제 로그인 브라우저(관리자 판정은 편집기로 재현 안 됨)
--     캠페인 관리자: admin_set_campaign_brand_publish(캠페인, true, '["-tiktok:acct"]', 0) → 1, 다시 0 으로 → -1
--     캠페인 매니저: 같은 호출이 42501 · admin_get_campaign_brand_publish 는 성공
--     campaigns.version 이 공개를 켜도 그대로인지
-- ============================================================
