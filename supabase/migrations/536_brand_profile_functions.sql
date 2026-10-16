-- ============================================================
-- 536_brand_profile_functions.sql
-- 브랜드 정보 페이지 — 작업 3: 브랜드 화면용 서버 함수 셋 + 변경 이력 표
--   작업표 docs/specs/2026-10-16-brand-info-page-breakdown.md 「작업 3」(결정 D1~D4·Q1~Q4·기본값 1~10)
--
-- 목적
--   ① 로그인한 브랜드 계정이 부르는 함수 셋(SECURITY DEFINER, search_path=''):
--        get_my_brand_profile(uuid)         — 브랜드·회사 정보 조회(역할에 따라 일부만)
--        update_my_brand_info(...)          — 브랜드 정보 저장(한글명·영문명·SNS 둘. 일본어 칸 인자 없음 — D1)
--        update_my_brand_company(...)       — 회사 정보 저장(대표 담당자만. 회사 id 는 서버가 브랜드 행에서 읽는다)
--   ② 변경 이력 표 brand_profile_history + 트리거 둘(brands·companies) — 관리자 저장·브랜드 저장 모두 남는다(Q1)
--   brands·companies 읽기/쓰기 정책(is_admin 계열)은 바꾸지 않는다. 브랜드 계정은 이 함수들로만 두 표에 닿는다.
--   적용만으로 바뀌는 기존 동작: 없음(함수 셋 추가 + 새 표 + 트리거 둘. 트리거는 이름·SNS·회사 칸이 바뀔 때 이력 줄만 더한다).
--
-- 🔴 운영 반영 — 526~535 묶음 뒤, 개발서버만(운영 보류). 535(companies.address_detail)가 먼저 있어야 한다.
--   · 이 파일은 535 의 칸을 읽고 쓴다. 칸이 없으면 함수가 오류.
--   · 운영 적용 전 /약관확인 — 사업자등록번호(개인사업자면 개인정보)를 브랜드 계정이 읽고 고치며, 이력 표에 담당자 이름 스냅샷이 남는다.
--
-- 베이스
--   역할 판정       : 530 my_brand_role(p_brand_id) — 활성 연결 + 활성 브랜드일 때만 owner/member. 보관 브랜드는 NULL → not_linked
--   실행 권한       : 369·370·375 — 부여 먼저(postgres, authenticated, service_role) → PUBLIC 회수 → anon 회수
--   이력 표 선례    : 265·266 campaign_change_history(바뀐 칸 1개 = 1행 · 쓰기는 트리거만 · RLS 읽기 (SELECT public.is_admin()) 감싸기 — 415 방식)
--   브랜드명 동기화 : 173 trg_brands_sync_campaigns(AFTER UPDATE OF name, name_ja, name_en) — 이 함수의 UPDATE 에서도 돈다(막지 않음, 작업표 의심 2)
--
-- 설계 판단
--   [A] 결과 코드의 field 값 = 저장 칸 이름(인자에서 p_ 를 뺀 것). 브랜드: name · name_en · official_instagram_url · official_x_url /
--       회사: name_ko · business_no · homepage_url · address · address_detail.
--   [B] 검사 순서(저장 함수 공통): 역할 → (회사 함수는 회사 id) → 행 FOR UPDATE → 입력 정리(btrim — 일반·전각 공백·탭·줄바꿈, 빈 문자열 → NULL) → 필수 → 길이 → URL →
--       ① p_prev 칸 단위 비교(IS DISTINCT FROM — 빈 문자열·열쇠 없음 = NULL) 다르면 stale → ② 입력값 = 지금 값이면 쓰지 않고 ok → ③ UPDATE.
--       stale 은 값을 싣지 않는다(화면이 다시 불러온다). p_prev 가 NULL 이면 열쇠가 전부 없는 것으로 본다.
--   [C] 길이 상한(글자 수): 이름 100 · 사업자등록번호 30 · 주소 각 200 · URL 500. URL 판정: 빈 값이거나 대소문자 무시 http:// 또는 https:// 로 시작.
--   [D] name_taken: 유일 제약 이름이 정확히 brands_name_normalized_key(브랜드) / companies_name_normalized_key(회사)일 때만.
--       그 밖의 위반은 RAISE 로 다시 던진다. ⚠️ 제약 이름은 082·118 의 `name_normalized text UNIQUE NOT NULL` 이 자동으로 붙인 `<표>_name_normalized_key` 이다
--       (082 의 brands_normalized_idx 는 유일 색인이 아닌 보통 색인). 091 주석의 오류 메시지가 brands_name_normalized_key 로 확인해 준다.
--   [E] 멤버(role='member')에게 company_brands 는 [] — 같은 회사 다른 브랜드 이름은 대표 화면에만(D3). company_brands 는 status='active' 만.
--       회사 정보 자체(company)는 멤버에게도 싣는다. can_edit_company = owner AND 회사 연결됨.
--       🔴 청구 이메일·청구 주소·메모·회사명(일본어·영문)·회사 상태는 싣지 않는다.
--   [F] 기본값 8: 보관(archived) 회사에 연결된 브랜드도 회사 정보를 보여 주고 대표는 고칠 수 있다(회사 status 를 보지 않는다).
--   [G] 회사명이 바뀌면 같은 회사의 모든 brands.company_name 사본을 새 이름으로 맞춘다(기본값 6 — 브랜드 상태 무관, 보관 브랜드 포함).
--       이 UPDATE 는 이력 트리거(brands)의 칸 목록에 company_name 이 없으므로 브랜드 이력 줄을 만들지 않는다. companies.name_ko 변경은 회사 이력에 남는다.
--   [H] 이력 change_source 판정 순서(트리거 안): auth.uid() NULL → system(이름 NULL) / admins 에 auth_id 있으면 admin(admins.name) /
--       brand_accounts 에 auth_id 있으면 brand(brand_accounts.name) / 그 밖 system. 한 저장(트리거 호출 1회)의 줄들은 같은 change_group_id.
--       target_id 에는 외래 키를 걸지 않는다 — 브랜드·회사가 지워져도 기록이 남는다(265 의 changed_by 와 같은 이유).
--   [I] 🔴 세 곳이 같은 집합이어야 한다(266 교훈): ⓐ 이력 표 field_name CHECK ⓑ 트리거 안 비교 목록(VALUES) ⓒ 트리거 칸 목록(AFTER UPDATE OF …).
--       브랜드 5칸 = name · name_ja · name_en · official_instagram_url · official_x_url
--       회사   5칸 = name_ko · business_no · homepage_url · address · address_detail
--       하나라도 어긋나면 CHECK 위반으로 INSERT 가 실패해 브랜드·회사 저장이 통째로 막힌다. 칸을 늘릴 때 세 곳을 한꺼번에.
--       name_ja 는 이 파일의 함수가 안 쓰지만 관리자 저장이 바꾸므로 이력에는 들어간다.
--   [J] 캠페인 변경 이력(266)은 재정의하지 않는다(Q4) — 브랜드명 저장이 연결 캠페인을 고치면 거기엔 「시스템 / 직접 수정」으로 남고,
--       누가 바꿨는지는 이 이력 표에 있다.
--   [K] total_brands(118 트리거)는 company_id 변경 때만 센다 — 이 파일은 company_id 를 건드리지 않는다.
--
-- 되돌리는 방법  (화면 4~6 코드를 먼저 되돌린 뒤. 이력 표의 기록은 함께 사라진다 — 필요하면 먼저 백업)
--   DROP FUNCTION IF EXISTS public.update_my_brand_company(uuid, text, text, text, text, text, jsonb);
--   DROP FUNCTION IF EXISTS public.update_my_brand_info(uuid, text, text, text, text, jsonb);
--   DROP FUNCTION IF EXISTS public.get_my_brand_profile(uuid);
--   DROP TRIGGER IF EXISTS trg_companies_profile_history ON public.companies;
--   DROP TRIGGER IF EXISTS trg_brands_profile_history ON public.brands;
--   DROP FUNCTION IF EXISTS public.record_company_profile_history();
--   DROP FUNCTION IF EXISTS public.record_brand_profile_history();
--   DROP TABLE IF EXISTS public.brand_profile_history;
-- ============================================================

-- ── 1. 이력 표 ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.brand_profile_history (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  target_kind      text        NOT NULL CHECK (target_kind IN ('brand', 'company')),
  target_id        uuid        NOT NULL,   -- brands.id 또는 companies.id(target_kind 로 구분). 외래 키 없음 — 지워져도 기록 보존
  change_group_id  uuid        NOT NULL,   -- 같은 저장(트리거 1회)에서 나온 줄들의 묶음
  -- 🔴 [I] 세 곳 같은 집합: 이 CHECK · record_brand_profile_history/record_company_profile_history 의 VALUES 목록 · 트리거 AFTER UPDATE OF 목록
  field_name       text        NOT NULL CHECK (field_name IN (
                     'name', 'name_ja', 'name_en', 'official_instagram_url', 'official_x_url',
                     'name_ko', 'business_no', 'homepage_url', 'address', 'address_detail'
                   )),
  old_value        jsonb       NULL,
  new_value        jsonb       NULL,
  changed_by       uuid        NULL,       -- auth.uid(). 계정이 지워져도 보존하려고 외래 키 없음
  changed_by_name  text        NULL,       -- 변경 시점 이름 스냅샷(admins.name 또는 brand_accounts.name). system 이면 NULL
  change_source    text        NOT NULL CHECK (change_source IN ('admin', 'brand', 'system')),
  changed_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.brand_profile_history IS
  '[536] 브랜드·회사 정보 변경 이력(바뀐 칸 1개 = 1행). 쓰기는 brands·companies 의 AFTER UPDATE OF 트리거(SECURITY DEFINER)뿐 — 쓰기 정책 없음.
   읽기는 관리자 전원. 보는 화면은 관리자 화면 묶음 ③. change_source: admin(관리자) / brand(브랜드 계정) / system(로그인 밖·SQL 편집기·그 밖).';

CREATE INDEX IF NOT EXISTS brand_profile_history_target_idx
  ON public.brand_profile_history (target_kind, target_id, changed_at DESC);

ALTER TABLE public.brand_profile_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "brand_profile_history_select_admin" ON public.brand_profile_history;
CREATE POLICY "brand_profile_history_select_admin"
  ON public.brand_profile_history FOR SELECT TO authenticated
  USING ((SELECT public.is_admin()));
-- INSERT/UPDATE/DELETE 정책은 두지 않는다 — 트리거 함수(SECURITY DEFINER)만 쓴다.
-- 표 권한도 두 겹으로 막는다 — Supabase 가 새 표에 주는 기본 권한을 걷고 읽기만 남긴다(행 단위 보안은 그대로 관리자만).
REVOKE ALL ON public.brand_profile_history FROM anon, authenticated;
GRANT SELECT ON public.brand_profile_history TO authenticated;

-- ── 2. 이력 트리거 함수 둘 ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.record_brand_profile_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_source text;
  v_name   text;
  v_group  uuid := gen_random_uuid();
BEGIN
  -- [H] change_source 판정 순서
  IF v_uid IS NULL THEN
    v_source := 'system';
  ELSIF EXISTS (SELECT 1 FROM public.admins WHERE auth_id = v_uid) THEN
    v_source := 'admin';
    SELECT NULLIF(btrim(a.name), '') INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;
  ELSIF EXISTS (SELECT 1 FROM public.brand_accounts WHERE auth_id = v_uid) THEN
    v_source := 'brand';
    SELECT NULLIF(btrim(b.name), '') INTO v_name FROM public.brand_accounts b WHERE b.auth_id = v_uid;
  ELSE
    v_source := 'system';
  END IF;

  -- 🔴 [I] 이 VALUES 목록 = 이력 표 CHECK = 트리거 AFTER UPDATE OF 목록 (브랜드 5칸)
  INSERT INTO public.brand_profile_history
    (target_kind, target_id, change_group_id, field_name, old_value, new_value, changed_by, changed_by_name, change_source)
  SELECT 'brand', NEW.id, v_group, v.f, v.o, v.n, v_uid, v_name, v_source
    FROM (VALUES
      ('name',                   to_jsonb(OLD.name),                   to_jsonb(NEW.name)),
      ('name_ja',                to_jsonb(OLD.name_ja),                to_jsonb(NEW.name_ja)),
      ('name_en',                to_jsonb(OLD.name_en),                to_jsonb(NEW.name_en)),
      ('official_instagram_url', to_jsonb(OLD.official_instagram_url), to_jsonb(NEW.official_instagram_url)),
      ('official_x_url',         to_jsonb(OLD.official_x_url),         to_jsonb(NEW.official_x_url))
    ) AS v(f, o, n)
   WHERE v.o IS DISTINCT FROM v.n;

  RETURN NULL;  -- AFTER 트리거
END;
$$;

COMMENT ON FUNCTION public.record_brand_profile_history() IS
  '[536] brands AFTER UPDATE OF name, name_ja, name_en, official_instagram_url, official_x_url. 바뀐 칸마다 brand_profile_history 1행.';

CREATE OR REPLACE FUNCTION public.record_company_profile_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_source text;
  v_name   text;
  v_group  uuid := gen_random_uuid();
BEGIN
  IF v_uid IS NULL THEN
    v_source := 'system';
  ELSIF EXISTS (SELECT 1 FROM public.admins WHERE auth_id = v_uid) THEN
    v_source := 'admin';
    SELECT NULLIF(btrim(a.name), '') INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;
  ELSIF EXISTS (SELECT 1 FROM public.brand_accounts WHERE auth_id = v_uid) THEN
    v_source := 'brand';
    SELECT NULLIF(btrim(b.name), '') INTO v_name FROM public.brand_accounts b WHERE b.auth_id = v_uid;
  ELSE
    v_source := 'system';
  END IF;

  -- 🔴 [I] 이 VALUES 목록 = 이력 표 CHECK = 트리거 AFTER UPDATE OF 목록 (회사 5칸)
  INSERT INTO public.brand_profile_history
    (target_kind, target_id, change_group_id, field_name, old_value, new_value, changed_by, changed_by_name, change_source)
  SELECT 'company', NEW.id, v_group, v.f, v.o, v.n, v_uid, v_name, v_source
    FROM (VALUES
      ('name_ko',        to_jsonb(OLD.name_ko),        to_jsonb(NEW.name_ko)),
      ('business_no',    to_jsonb(OLD.business_no),    to_jsonb(NEW.business_no)),
      ('homepage_url',   to_jsonb(OLD.homepage_url),   to_jsonb(NEW.homepage_url)),
      ('address',        to_jsonb(OLD.address),        to_jsonb(NEW.address)),
      ('address_detail', to_jsonb(OLD.address_detail), to_jsonb(NEW.address_detail))
    ) AS v(f, o, n)
   WHERE v.o IS DISTINCT FROM v.n;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.record_company_profile_history() IS
  '[536] companies AFTER UPDATE OF name_ko, business_no, homepage_url, address, address_detail. 바뀐 칸마다 brand_profile_history 1행.';

-- 트리거 함수는 직접 호출 대상이 아니다 — 부여 먼저, 회수 나중(375)
GRANT  EXECUTE ON FUNCTION public.record_brand_profile_history()   TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.record_brand_profile_history()   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_brand_profile_history()   FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_company_profile_history() TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.record_company_profile_history() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_company_profile_history() FROM anon, authenticated;

-- 🔴 [I] 칸 목록(AFTER UPDATE OF …) = 위 VALUES 목록 = 이력 표 CHECK
DROP TRIGGER IF EXISTS trg_brands_profile_history ON public.brands;
CREATE TRIGGER trg_brands_profile_history
  AFTER UPDATE OF name, name_ja, name_en, official_instagram_url, official_x_url
  ON public.brands
  FOR EACH ROW
  EXECUTE FUNCTION public.record_brand_profile_history();

DROP TRIGGER IF EXISTS trg_companies_profile_history ON public.companies;
CREATE TRIGGER trg_companies_profile_history
  AFTER UPDATE OF name_ko, business_no, homepage_url, address, address_detail
  ON public.companies
  FOR EACH ROW
  EXECUTE FUNCTION public.record_company_profile_history();

-- ── 3. get_my_brand_profile ────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_my_brand_profile(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role   text;
  b        record;
  c        record;
  v_company jsonb := NULL;
  v_list   jsonb := '[]'::jsonb;
BEGIN
  v_role := public.my_brand_role(p_brand_id);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  SELECT id, name, name_ja, name_en, official_instagram_url, official_x_url, company_id
    INTO b FROM public.brands WHERE id = p_brand_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  IF b.company_id IS NOT NULL THEN
    SELECT id, name_ko, business_no, homepage_url, address, address_detail
      INTO c FROM public.companies WHERE id = b.company_id;
    IF FOUND THEN
      v_company := jsonb_build_object(
        'id', c.id, 'name_ko', c.name_ko, 'business_no', c.business_no,
        'homepage_url', c.homepage_url, 'address', c.address, 'address_detail', c.address_detail);
      -- [E] 같은 회사의 활성 브랜드 이름 목록은 대표에게만
      IF v_role = 'owner' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) ORDER BY x.name), '[]'::jsonb)
          INTO v_list
          FROM public.brands x
         WHERE x.company_id = b.company_id AND x.status = 'active';
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'result', 'ok',
    'role', v_role,
    'can_edit_company', (v_role = 'owner' AND v_company IS NOT NULL),
    'brand', jsonb_build_object(
      'id', b.id, 'name', b.name, 'name_ja', b.name_ja, 'name_en', b.name_en,
      'official_instagram_url', b.official_instagram_url, 'official_x_url', b.official_x_url),
    'company', v_company,
    'company_brands', v_list
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_profile(uuid) IS
  '[536] 브랜드 화면용 조회. 역할은 my_brand_role 로만. 멤버에게 company_brands 는 []. 청구 정보·메모·회사 일본어/영문명·상태는 싣지 않는다.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_profile(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_profile(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_profile(uuid) FROM anon;

-- ── 4. update_my_brand_info ────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_my_brand_info(
  p_brand_id uuid,
  p_name text,
  p_name_en text,
  p_official_instagram_url text,
  p_official_x_url text,
  p_prev jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role  text;
  b       record;
  v_name  text := NULLIF(btrim(p_name, E' \t\r\n\u3000'), '');
  v_en    text := NULLIF(btrim(p_name_en, E' \t\r\n\u3000'), '');
  v_ig    text := NULLIF(btrim(p_official_instagram_url, E' \t\r\n\u3000'), '');
  v_x     text := NULLIF(btrim(p_official_x_url, E' \t\r\n\u3000'), '');
  v_prev  jsonb := COALESCE(p_prev, '{}'::jsonb);
  v_con   text;
BEGIN
  v_role := public.my_brand_role(p_brand_id);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  SELECT id, name, name_ja, name_en, official_instagram_url, official_x_url
    INTO b FROM public.brands WHERE id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  -- 필수 → 길이 → URL (결과의 field = 저장 칸 이름)
  IF v_name IS NULL THEN
    RETURN jsonb_build_object('result', 'name_required');
  END IF;
  IF char_length(v_name) > 100 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'name'); END IF;
  IF char_length(COALESCE(v_en, '')) > 100 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'name_en'); END IF;
  IF char_length(COALESCE(v_ig, '')) > 500 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'official_instagram_url'); END IF;
  IF char_length(COALESCE(v_x, '')) > 500 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'official_x_url'); END IF;
  IF v_ig IS NOT NULL AND lower(v_ig) !~ '^https?://' THEN RETURN jsonb_build_object('result', 'url_invalid', 'field', 'official_instagram_url'); END IF;
  IF v_x  IS NOT NULL AND lower(v_x)  !~ '^https?://' THEN RETURN jsonb_build_object('result', 'url_invalid', 'field', 'official_x_url'); END IF;

  -- ① 동시 수정 검사: 화면이 열 때 받은 값(p_prev)과 지금 값을 칸 단위로 비교
  IF NULLIF(btrim(v_prev->>'name', E' \t\r\n\u3000'), '')                   IS DISTINCT FROM NULLIF(btrim(b.name, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'name_en', E' \t\r\n\u3000'), '')                IS DISTINCT FROM NULLIF(btrim(b.name_en, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'official_instagram_url', E' \t\r\n\u3000'), '') IS DISTINCT FROM NULLIF(btrim(b.official_instagram_url, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'official_x_url', E' \t\r\n\u3000'), '')         IS DISTINCT FROM NULLIF(btrim(b.official_x_url, E' \t\r\n\u3000'), '')
  THEN
    RETURN jsonb_build_object('result', 'stale');
  END IF;

  -- ② 바뀐 것이 없으면 쓰지 않고 ok (이력·캠페인 이름 동기화·updated_at 이 헛돌지 않게)
  IF v_name IS NOT DISTINCT FROM NULLIF(btrim(b.name, E' \t\r\n\u3000'), '')
     AND v_en IS NOT DISTINCT FROM NULLIF(btrim(b.name_en, E' \t\r\n\u3000'), '')
     AND v_ig IS NOT DISTINCT FROM NULLIF(btrim(b.official_instagram_url, E' \t\r\n\u3000'), '')
     AND v_x  IS NOT DISTINCT FROM NULLIF(btrim(b.official_x_url, E' \t\r\n\u3000'), '')
  THEN
    RETURN jsonb_build_object('result', 'ok', 'brand', jsonb_build_object(
      'id', b.id, 'name', b.name, 'name_ja', b.name_ja, 'name_en', b.name_en,
      'official_instagram_url', b.official_instagram_url, 'official_x_url', b.official_x_url));
  END IF;

  -- ③ 쓰기(네 칸만. name_ja 는 건드리지 않는다 — D1)
  BEGIN
    UPDATE public.brands
       SET name = v_name, name_en = v_en,
           official_instagram_url = v_ig, official_x_url = v_x
     WHERE id = p_brand_id
    RETURNING id, name, name_ja, name_en, official_instagram_url, official_x_url INTO b;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    IF v_con = 'brands_name_normalized_key' THEN
      RETURN jsonb_build_object('result', 'name_taken');
    END IF;
    RAISE;  -- 다른 유일 위반은 숨기지 않는다
  END;

  RETURN jsonb_build_object('result', 'ok', 'brand', jsonb_build_object(
    'id', b.id, 'name', b.name, 'name_ja', b.name_ja, 'name_en', b.name_en,
    'official_instagram_url', b.official_instagram_url, 'official_x_url', b.official_x_url));
END;
$$;

COMMENT ON FUNCTION public.update_my_brand_info(uuid, text, text, text, text, jsonb) IS
  '[536] 브랜드 정보 저장(한글명·영문명·SNS 둘). 일본어 칸 인자 없음(D1). 역할(대표·멤버)은 my_brand_role. p_prev 칸 단위 비교 → stale. 173 트리거로 연결 캠페인 이름이 따라간다.';

GRANT  EXECUTE ON FUNCTION public.update_my_brand_info(uuid, text, text, text, text, jsonb) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_info(uuid, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_info(uuid, text, text, text, text, jsonb) FROM anon;

-- ── 5. update_my_brand_company ─────────────────────────────

CREATE OR REPLACE FUNCTION public.update_my_brand_company(
  p_brand_id uuid,
  p_name_ko text,
  p_business_no text,
  p_homepage_url text,
  p_address text,
  p_address_detail text,
  p_prev jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role   text;
  v_cid    uuid;
  c        record;
  v_name   text := NULLIF(btrim(p_name_ko, E' \t\r\n\u3000'), '');
  v_bizno  text := NULLIF(btrim(p_business_no, E' \t\r\n\u3000'), '');
  v_home   text := NULLIF(btrim(p_homepage_url, E' \t\r\n\u3000'), '');
  v_addr   text := NULLIF(btrim(p_address, E' \t\r\n\u3000'), '');
  v_addr2  text := NULLIF(btrim(p_address_detail, E' \t\r\n\u3000'), '');
  v_prev   jsonb := COALESCE(p_prev, '{}'::jsonb);
  v_con    text;
  v_old_name text;
BEGIN
  v_role := public.my_brand_role(p_brand_id);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;
  IF v_role <> 'owner' THEN
    RETURN jsonb_build_object('result', 'not_owner');
  END IF;

  -- 회사 id 는 화면에서 받지 않는다 — 브랜드 행에서 읽는다
  SELECT company_id INTO v_cid FROM public.brands WHERE id = p_brand_id;
  IF v_cid IS NULL THEN
    RETURN jsonb_build_object('result', 'no_company');
  END IF;

  SELECT id, name_ko, business_no, homepage_url, address, address_detail
    INTO c FROM public.companies WHERE id = v_cid FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'no_company');
  END IF;

  -- 필수 → 길이 → URL (결과의 field = 저장 칸 이름)
  IF v_name IS NULL THEN RETURN jsonb_build_object('result', 'name_required'); END IF;
  IF v_bizno IS NULL THEN RETURN jsonb_build_object('result', 'business_no_required'); END IF;
  IF char_length(v_name) > 100 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'name_ko'); END IF;
  IF char_length(v_bizno) > 30 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'business_no'); END IF;
  IF char_length(COALESCE(v_home, '')) > 500 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'homepage_url'); END IF;
  IF char_length(COALESCE(v_addr, '')) > 200 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'address'); END IF;
  IF char_length(COALESCE(v_addr2, '')) > 200 THEN RETURN jsonb_build_object('result', 'too_long', 'field', 'address_detail'); END IF;
  IF v_home IS NOT NULL AND lower(v_home) !~ '^https?://' THEN RETURN jsonb_build_object('result', 'url_invalid', 'field', 'homepage_url'); END IF;

  -- ① 동시 수정 검사
  IF NULLIF(btrim(v_prev->>'name_ko', E' \t\r\n\u3000'), '')        IS DISTINCT FROM NULLIF(btrim(c.name_ko, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'business_no', E' \t\r\n\u3000'), '')    IS DISTINCT FROM NULLIF(btrim(c.business_no, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'homepage_url', E' \t\r\n\u3000'), '')   IS DISTINCT FROM NULLIF(btrim(c.homepage_url, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'address', E' \t\r\n\u3000'), '')        IS DISTINCT FROM NULLIF(btrim(c.address, E' \t\r\n\u3000'), '')
  OR NULLIF(btrim(v_prev->>'address_detail', E' \t\r\n\u3000'), '') IS DISTINCT FROM NULLIF(btrim(c.address_detail, E' \t\r\n\u3000'), '')
  THEN
    RETURN jsonb_build_object('result', 'stale');
  END IF;

  -- ② 바뀐 것이 없으면 쓰지 않고 ok
  IF v_name   IS NOT DISTINCT FROM NULLIF(btrim(c.name_ko, E' \t\r\n\u3000'), '')
     AND v_bizno IS NOT DISTINCT FROM NULLIF(btrim(c.business_no, E' \t\r\n\u3000'), '')
     AND v_home  IS NOT DISTINCT FROM NULLIF(btrim(c.homepage_url, E' \t\r\n\u3000'), '')
     AND v_addr  IS NOT DISTINCT FROM NULLIF(btrim(c.address, E' \t\r\n\u3000'), '')
     AND v_addr2 IS NOT DISTINCT FROM NULLIF(btrim(c.address_detail, E' \t\r\n\u3000'), '')
  THEN
    RETURN jsonb_build_object('result', 'ok', 'company', jsonb_build_object(
      'id', c.id, 'name_ko', c.name_ko, 'business_no', c.business_no,
      'homepage_url', c.homepage_url, 'address', c.address, 'address_detail', c.address_detail));
  END IF;

  -- ③ 쓰기 다섯 칸 + 회사명 사본 맞추기
  v_old_name := c.name_ko;
  BEGIN
    UPDATE public.companies
       SET name_ko = v_name, business_no = v_bizno, homepage_url = v_home,
           address = v_addr, address_detail = v_addr2, updated_by = (SELECT auth.uid())
     WHERE id = v_cid
    RETURNING id, name_ko, business_no, homepage_url, address, address_detail INTO c;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    IF v_con = 'companies_name_normalized_key' THEN
      RETURN jsonb_build_object('result', 'name_taken');
    END IF;
    RAISE;
  END;

  -- [G] 회사명이 바뀌었으면 같은 회사 모든 브랜드의 company_name 사본을 맞춘다(기본값 6)
  IF v_old_name IS DISTINCT FROM c.name_ko THEN
    UPDATE public.brands SET company_name = c.name_ko
     WHERE company_id = v_cid AND company_name IS DISTINCT FROM c.name_ko;
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'company', jsonb_build_object(
    'id', c.id, 'name_ko', c.name_ko, 'business_no', c.business_no,
    'homepage_url', c.homepage_url, 'address', c.address, 'address_detail', c.address_detail));
END;
$$;

COMMENT ON FUNCTION public.update_my_brand_company(uuid, text, text, text, text, text, jsonb) IS
  '[536] 회사 정보 저장(대표 담당자만). 회사 id 는 브랜드 행에서 읽는다. 사업자등록번호 필수(D4). p_prev 칸 단위 비교 → stale. 회사명이 바뀌면 같은 회사 모든 brands.company_name 사본 갱신.';

GRANT  EXECUTE ON FUNCTION public.update_my_brand_company(uuid, text, text, text, text, text, jsonb) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_company(uuid, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_company(uuid, text, text, text, text, text, jsonb) FROM anon;

-- ============================================================
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--
--   [V1] 표·정책·트리거
--     SELECT c.relname, c.relrowsecurity AS rls_on,
--            (SELECT count(*) FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname) AS policies
--       FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--      WHERE n.nspname='public' AND c.relname='brand_profile_history';
--     기대: rls_on true · policies 1.
--     SELECT tgname, tgrelid::regclass FROM pg_trigger
--      WHERE tgname IN ('trg_brands_profile_history','trg_companies_profile_history') AND NOT tgisinternal;
--     기대: 2행(brands · companies).
--
--   [V2] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--      WHERE n.nspname='public'
--        AND p.proname IN ('get_my_brand_profile','update_my_brand_info','update_my_brand_company',
--                          'record_brand_profile_history','record_company_profile_history')
--      ORDER BY 1;
--     기대: acl 맨 앞에 `=X/` 없음 · anon_can 전부 false · auth_can 은 앞의 셋만 true(트리거 함수 둘은 false) · svc_can 전부 true.
--
--   [V3] 유일 제약 이름 (name_taken 판정이 기대는 이름이 실제와 같은지)
--     SELECT conrelid::regclass AS tbl, conname FROM pg_constraint
--      WHERE contype='u' AND conname IN ('brands_name_normalized_key','companies_name_normalized_key');
--     기대: 2행. 이름이 다르면 두 함수의 비교 문자열을 실제 이름으로 고친다(안 고치면 이름 중복이 name_taken 이 아니라 오류로 나간다).
--
--   [V4] 인플루언서 화면에 일본어 이름이 비어 영문/한글이 뜨게 될 브랜드 수 (구현 결과에 기록)
--     SELECT count(*) FILTER (WHERE name_ja IS NULL OR btrim(name_ja) = '') AS ja_blank, count(*) AS total
--       FROM public.brands WHERE status = 'active';
--
-- 함수 동작 확인 — SQL 편집기로는 못 한다(auth.uid() 가 없어 my_brand_role 이 NULL → 늘 not_linked). 로그인한 브랜드 계정으로 호출:
--   1) 대표: get_my_brand_profile → ok · role owner · can_edit_company true · company_brands 에 같은 회사 활성 브랜드(보관 제외)
--   2) 멤버: get_my_brand_profile → can_edit_company false · company_brands [] · company 는 있음
--   3) 대표: update_my_brand_info 한글명 변경 → ok, 연결 캠페인 brand 이름 변경(173), 이력 표에 name 1줄 change_source='brand' · 이름 스냅샷=계정 이름
--   4) 멤버: update_my_brand_info → ok / update_my_brand_company → not_owner
--   5) 변경 없이 저장 → ok, 이력 0줄·updated_at 그대로
--   6) p_prev 를 일부러 틀리게 → stale (쓰기 없음)
--   7) 다른 브랜드와 같은 이름(공백·대소문자만 다르게) → name_taken / 같은 회사명 → name_taken
--   8) 이름 빈 값 → name_required / 회사명 빈 값 → name_required / 사업자등록번호 빈 값 → business_no_required
--   9) 101자 이름·501자 URL·201자 주소 → too_long + field / 'ftp://x' → url_invalid + field / 'HTTPS://x' → 통과
--  10) 회사명 변경 → 같은 회사 모든 brands.company_name 이 새 이름(보관 브랜드 포함), 회사 이력 name_ko 1줄, updated_by = 계정 id
--  11) 회사 미연결 브랜드의 대표: update_my_brand_company → no_company / 조회는 company null · can_edit_company false
--  12) 보관(archived) 브랜드 · 연결 해제된 계정 · 인플루언서 계정 → 셋 다 not_linked
--  13) 보관(archived) 회사에 연결된 브랜드의 대표 → 조회·수정 가능
--  14) 관리자 화면에서 브랜드/회사 저장 → 이력에 change_source='admin' · 이름=admins.name / SQL 편집기 UPDATE → 'system'·이름 NULL
--  15) 비로그인(공개 키)으로 세 함수 호출 → 실행 권한 오류(42501)
-- ============================================================
