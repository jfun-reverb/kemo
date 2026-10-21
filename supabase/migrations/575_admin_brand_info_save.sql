-- ============================================================
-- 575_admin_brand_info_save.sql
-- 관리자 브랜드 상세 탭 재구성 — 작업 3(관리자 브랜드 정보 저장 · 사양서 5-1 · 작업표 결정 S2=A)
-- 사양서: docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md
--
-- 왜: 관리자 브랜드 편집이 폼을 연 순간 값으로 브랜드 행을 통째로 덮어써, 그사이 브랜드 담당자(536)나 다른 관리자가
--   고친 값이 경고 없이 사라진다. 바뀐 칸만, 연 순간 값(p_prev)과 대조해 저장하는 서버 함수로 바꾼다.
--
-- 만드는 것
--   1) admin_update_brand_info(p_brand_id uuid, p_fields jsonb, p_prev jsonb) → jsonb {result, field?}
--      · 받는 열쇠 여덟: name · name_ja · name_en · company_id · status · official_instagram_url · official_x_url · publish_default
--        열쇠가 없으면 그 칸은 안 바꾼다. 🔴 그 밖 열쇠(contacts·description·appeal_points·official_qoo10_url·primary_* 등)가
--        오면 invalid_input(조용히 버리지 않는다 — 작업표 기본값 8)
--      · 결과: ok · stale · forbidden · duplicate_name · not_found · invalid_input(+field)
--      · 단계: 입력 검사 → ① p_fields 에 온 칸만 p_prev 와 지금 값을 비교(빈 문자열·열쇠 없음 = NULL, 536 규칙) → 하나라도 다르면 stale
--        (값을 싣지 않는다 — 화면이 다시 받는다) → ② 바뀐 칸이 없으면 쓰지 않고 ok → ③ 바뀐 칸만 UPDATE
--      · 바뀐 칸만 SET 에 넣는다(동적 SQL) — 이름을 안 바꿨는데 173(캠페인 이름 동기화)·275(캠페인 판 번호)가 헛돌지 않게
--      · company_id 가 바뀌면 company_name 사본 = 그 회사 name_ko(비우면 NULL — 지금 화면 _collectBrandFormPatch 와 같다)
--      · 가드 is_admin()(지금 brands 직접 쓰기 정책 082 와 같은 기준). publish_default 가 왔는데
--        has_permission('report.share','write') 가 아니면 forbidden — 다른 칸도 안 바꾼다
--      · 공개 기본 열은 544 admin_set_brand_publish_default_brand 를 안에서 부른다(사본을 만들지 않는다 — 기본값 3).
--        그 함수는 거부를 오류로 던지므로 권한·형식을 먼저 검사한다. NULL = 「전체 기본값 따르기」(따로 정한 줄 삭제)
--      · 이름 중복(brands_name_normalized_key) → duplicate_name
--   2) 이력 표 brand_profile_history 에 company_id·status 를 더한다(S2=A) — 🔴 세 곳 같은 집합(266 교훈):
--      ⓐ field_name CHECK ⓑ record_brand_profile_history() VALUES ⓒ 트리거 trg_brands_profile_history AFTER UPDATE OF.
--      베이스 536. 회사 쪽 트리거(record_company_profile_history)는 그대로
--   3) admin_get_brand_publish_defaults 에 칸 셋 더하기(베이스 544, 반환형 jsonb 그대로 → CREATE OR REPLACE):
--      brand_updated_at · brand_updated_by · brand_updated_by_name — S2 「공개 기본 열은 마지막 저장자·시각」. 기존 칸 그대로.
--      ⚠️ 「전체 기본값 따르기」로 바꾸면 따로 정한 줄이 지워져 저장자·시각도 없다(NULL)
--
-- 결과 field(invalid_input 일 때): 문제 칸 열쇠 이름. 받지 않는 열쇠면 그 열쇠, 형식이 틀리면(글자 아님 등) 그 칸
--   검사: name 빈 값 · 길이(이름 셋 100자, SNS 둘 500자) · SNS 는 http(s):// 로 시작(536 브랜드 쪽과 같다) · status 는 active/archived
--   · company_id 는 있는 회사 아이디 또는 빈 값 · publish_default 는 544 형식(_brand_publish_keys_valid) 또는 null
--
-- 알고 있는 것
--   · 173 트리거(브랜드명 → 연결 캠페인 이름)·275(캠페인 판 번호 상승)는 이름을 바꾼 저장에서 돈다(지금 화면 저장과 같다)
--   · 관리자 회사 화면(직접 저장) 경로로 회사 이름을 바꾸면 brands.company_name 사본은 안 맞춘다(기존 틈 — 이번 범위 밖.
--     브랜드 대표의 update_my_brand_company(536)는 맞춘다)
--   · 트리거 칸이 늘어 이 함수 밖의 경로도 company_id·status 이력을 남긴다 — 회사 일괄 할당(assignBrandsToCompany 직접 UPDATE)·
--     병합의 보관(merge_brands)·회사 삭제의 ON DELETE SET NULL(호출자 없으면 system). 이력 화면은 그런 줄도 있다고 보고 그린다
--
-- 🔴 다음에 record_brand_profile_history·trg_brands_profile_history·이력 CHECK 를 고칠 때 베이스는 이 파일(536 베이스 금지 — company_id·status 가 빠진다).
--   admin_get_brand_publish_defaults 도 이 파일이 베이스(544 금지 — 저장자 칸이 빠진다).
-- 편집기 경고: 뜸 — 「Potential issue detected · destructive operations」(이력 CHECK 를 지우고 다시 만드는 DO 블록·DROP TRIGGER 때문).
--   데이터는 안 지운다 — 「Run query」로 진행(2026-10-21 개발서버 적용, 기록 표 575 줄 12:41:31 JST). 운영 적용 때도 같은 창이 뜬다
-- 개발서버 실제 호출(2026-10-21, 로그인 관리자 콘솔 · 시험 브랜드 「시험브랜드0923…」 — 끝난 뒤 원래 값으로 되돌림):
--   이름만 → ok + 이력 1줄 · p_prev 틀림 → stale(값 그대로) · contacts·description 섞음 → invalid_input(field) · 빈 이름·SNS 형식·없는 상태·없는 회사 → invalid_input
--   · 다른 브랜드 이름 → duplicate_name · 회사 지정 → company_name = 회사 이름 · 회사·상태 변경 이력 남음(admin/이름) · 같은 값 → ok(안 씀)
--   · 공개 기본 열 저장 → 544 표에 반영 + 읽기 함수에 저장자 이름·시각 · 공개 기본 열 p_prev 틀림 → stale · 형식 틀림 → invalid_input
--   캠페인 매니저(SQL 편집기에서 manager.test 로 흉내 — report.share 쓰기 없음): 공개 기본 열 + 이름 → forbidden, 이름 그대로 / 이름만 → ok, 이력 이름 남음
-- 롤백(이 순서): ① 화면 작업 7·8 을 먼저 되돌린다 ② DROP FUNCTION admin_update_brand_info(uuid,jsonb,jsonb)
--   ③ 536 의 record_brand_profile_history 함수 블록(104~147줄)과 트리거 블록(201~207줄)을 다시 실행(브랜드 5칸으로)
--   ④ DELETE FROM public.brand_profile_history WHERE field_name IN ('company_id','status');
--   ⑤ ALTER TABLE public.brand_profile_history DROP CONSTRAINT brand_profile_history_field_name_check,
--        ADD CONSTRAINT brand_profile_history_field_name_check CHECK (field_name IN ('name','name_ja','name_en','official_instagram_url',
--        'official_x_url','name_ko','business_no','homepage_url','address','address_detail'));
--      (536 의 CHECK 는 CREATE TABLE 안에 있어 그 블록을 다시 돌릴 수 없다)
--   ⑥ 544 의 admin_get_brand_publish_defaults 블록(258~276줄) 재실행
-- ============================================================
BEGIN;

-- ── 1. 이력 표 CHECK 에 company_id·status 더하기 (ⓐ) ──────────────────
--   536 의 칸 CHECK 는 이름 없이 만들어져 자동 이름이다 — field_name 을 검사하는 CHECK 를 찾아 지우고 이름을 붙여 다시 만든다
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
      FROM pg_constraint c
     WHERE c.conrelid = 'public.brand_profile_history'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) LIKE '%field_name%'
  LOOP
    EXECUTE format('ALTER TABLE public.brand_profile_history DROP CONSTRAINT %I', r.conname);
  END LOOP;
END;
$$;

-- 🔴 [I] 세 곳 같은 집합: 이 CHECK · record_brand_profile_history/record_company_profile_history 의 VALUES 목록 · 트리거 AFTER UPDATE OF 목록
ALTER TABLE public.brand_profile_history
  ADD CONSTRAINT brand_profile_history_field_name_check CHECK (field_name IN (
    'name', 'name_ja', 'name_en', 'official_instagram_url', 'official_x_url', 'company_id', 'status',
    'name_ko', 'business_no', 'homepage_url', 'address', 'address_detail'
  ));

-- ── 2. 브랜드 이력 트리거 함수 (ⓑ — 베이스 536, VALUES 에 두 줄만 더함) ──────
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

  -- 🔴 [I] 이 VALUES 목록 = 이력 표 CHECK = 트리거 AFTER UPDATE OF 목록 (브랜드 7칸 — 575 가 company_id·status 추가)
  INSERT INTO public.brand_profile_history
    (target_kind, target_id, change_group_id, field_name, old_value, new_value, changed_by, changed_by_name, change_source)
  SELECT 'brand', NEW.id, v_group, v.f, v.o, v.n, v_uid, v_name, v_source
    FROM (VALUES
      ('name',                   to_jsonb(OLD.name),                   to_jsonb(NEW.name)),
      ('name_ja',                to_jsonb(OLD.name_ja),                to_jsonb(NEW.name_ja)),
      ('name_en',                to_jsonb(OLD.name_en),                to_jsonb(NEW.name_en)),
      ('official_instagram_url', to_jsonb(OLD.official_instagram_url), to_jsonb(NEW.official_instagram_url)),
      ('official_x_url',         to_jsonb(OLD.official_x_url),         to_jsonb(NEW.official_x_url)),
      ('company_id',             to_jsonb(OLD.company_id),             to_jsonb(NEW.company_id)),
      ('status',                 to_jsonb(OLD.status),                 to_jsonb(NEW.status))
    ) AS v(f, o, n)
   WHERE v.o IS DISTINCT FROM v.n;

  RETURN NULL;  -- AFTER 트리거
END;
$$;

COMMENT ON FUNCTION public.record_brand_profile_history() IS
  '[575] brands AFTER UPDATE OF name, name_ja, name_en, official_instagram_url, official_x_url, company_id, status. 바뀐 칸마다 brand_profile_history 1행. (536 에 company_id·status 추가)';

GRANT  EXECUTE ON FUNCTION public.record_brand_profile_history() TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.record_brand_profile_history() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_brand_profile_history() FROM anon, authenticated;

-- ── 3. 브랜드 이력 트리거 (ⓒ — 칸 목록에 company_id·status 추가) ──────────
-- 🔴 [I] 칸 목록(AFTER UPDATE OF …) = 위 VALUES 목록 = 이력 표 CHECK
DROP TRIGGER IF EXISTS trg_brands_profile_history ON public.brands;
CREATE TRIGGER trg_brands_profile_history
  AFTER UPDATE OF name, name_ja, name_en, official_instagram_url, official_x_url, company_id, status
  ON public.brands
  FOR EACH ROW
  EXECUTE FUNCTION public.record_brand_profile_history();

-- ── 4. 공개 기본 열 읽기에 저장자·시각 더하기 (베이스 544) ────────────────
CREATE OR REPLACE FUNCTION public.admin_get_brand_publish_defaults(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  g    jsonb;
  b    jsonb;
  b_at timestamptz;
  b_by uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT spec INTO g FROM public.brand_publish_default_global WHERE id = 1;
  IF p_brand_id IS NOT NULL THEN
    SELECT spec, updated_at, updated_by INTO b, b_at, b_by FROM public.brand_publish_default_by_brand WHERE brand_id = p_brand_id;
  END IF;
  RETURN jsonb_build_object(
    'global_spec',           COALESCE(g, '[]'::jsonb),
    'brand_spec',            b,      -- 따로 정하지 않았으면 brand_spec = null
    -- 575: 이 브랜드 값의 마지막 저장자·시각(저장 충돌 창 a03-10 의 「누가·언제」). 따로 정한 값이 없으면 셋 다 null
    'brand_updated_at',      b_at,
    'brand_updated_by',      b_by,
    'brand_updated_by_name', (SELECT NULLIF(btrim(a.name), '') FROM public.admins a WHERE b_by IS NOT NULL AND a.auth_id = b_by LIMIT 1)
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_publish_defaults(uuid) IS
  '[575] (544 재정의: brand_updated_at·brand_updated_by·brand_updated_by_name 추가) 공개 기본 열 읽기(관리자 전원, 아니면 42501). 반환 {global_spec, brand_spec(따로 정하지 않았으면 null), brand_updated_at, brand_updated_by, brand_updated_by_name}.';

GRANT  EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_publish_defaults(uuid) FROM anon;

-- ── 5. 관리자 브랜드 정보 저장 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_brand_info(p_brand_id uuid, p_fields jsonb, p_prev jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_ws     constant text := E' \t\r\n　';
  c_keys   constant text[] := ARRAY['name', 'name_ja', 'name_en', 'company_id', 'status',
                                    'official_instagram_url', 'official_x_url', 'publish_default'];
  c_text   constant text[] := ARRAY['name', 'name_ja', 'name_en', 'company_id', 'status',
                                    'official_instagram_url', 'official_x_url'];
  v_fields jsonb := p_fields;
  v_prev   jsonb := COALESCE(p_prev, '{}'::jsonb);
  b        record;
  v_key    text;
  v_val    jsonb;
  v_new    text;          -- 이번에 넣을 값(정리 뒤)
  v_cur    text;          -- 지금 저장된 값(정리 뒤)
  v_was    text;          -- 화면이 연 순간 값(정리 뒤)
  v_newmap jsonb := '{}'::jsonb;   -- 칸 → 넣을 값(정리 뒤, 글자 칸만)
  v_set    text[] := ARRAY[]::text[];
  v_pub_cur  jsonb;
  v_pub_new  jsonb;
  v_pub_prev jsonb;
  v_pub_chg  boolean := false;
  v_con    text;
  v_cname  text;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'not_found');
  END IF;
  IF v_fields IS NULL OR jsonb_typeof(v_fields) <> 'object' THEN
    RETURN jsonb_build_object('result', 'invalid_input');
  END IF;
  IF jsonb_typeof(v_prev) <> 'object' THEN
    RETURN jsonb_build_object('result', 'invalid_input', 'field', 'p_prev');
  END IF;

  -- 받지 않는 열쇠 → invalid_input(조용히 버리지 않는다)
  SELECT k INTO v_key FROM jsonb_object_keys(v_fields) AS k WHERE NOT (k = ANY (c_keys)) LIMIT 1;
  IF v_key IS NOT NULL THEN
    RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
  END IF;

  -- 공개 기본 열 권한 — 다른 칸도 안 바꾼다
  IF v_fields ? 'publish_default' AND NOT public.has_permission('report.share', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;

  SELECT id, name, name_ja, name_en, company_id, status, official_instagram_url, official_x_url
    INTO b FROM public.brands WHERE id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_found');
  END IF;

  -- 글자 칸: 형식 검사 + 정리값 계산 ---------------------------------
  FOREACH v_key IN ARRAY c_text LOOP
    CONTINUE WHEN NOT (v_fields ? v_key);
    v_val := v_fields -> v_key;
    IF jsonb_typeof(v_val) NOT IN ('string', 'null') THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
    END IF;
    v_new := NULLIF(btrim(v_val #>> '{}', c_ws), '');

    IF v_key = 'name' AND v_new IS NULL THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
    END IF;
    IF v_key IN ('name', 'name_ja', 'name_en') AND char_length(COALESCE(v_new, '')) > 100 THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
    END IF;
    IF v_key IN ('official_instagram_url', 'official_x_url')
       AND (char_length(COALESCE(v_new, '')) > 500 OR (v_new IS NOT NULL AND lower(v_new) !~ '^https?://')) THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
    END IF;
    IF v_key = 'status' AND (v_new IS NULL OR v_new NOT IN ('active', 'archived')) THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
    END IF;
    IF v_key = 'company_id' AND v_new IS NOT NULL THEN
      IF v_new !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         OR NOT EXISTS (SELECT 1 FROM public.companies co WHERE co.id = v_new::uuid) THEN
        RETURN jsonb_build_object('result', 'invalid_input', 'field', v_key);
      END IF;
      v_new := lower(v_new);
    END IF;

    v_newmap := v_newmap || jsonb_build_object(v_key, v_new);
  END LOOP;

  -- 공개 기본 열: 형식 검사 + 지금 값 --------------------------------
  IF v_fields ? 'publish_default' THEN
    v_pub_new := v_fields -> 'publish_default';
    IF jsonb_typeof(v_pub_new) = 'null' THEN v_pub_new := NULL; END IF;
    IF v_pub_new IS NOT NULL AND NOT public._brand_publish_keys_valid(v_pub_new) THEN
      RETURN jsonb_build_object('result', 'invalid_input', 'field', 'publish_default');
    END IF;
    SELECT d.spec INTO v_pub_cur FROM public.brand_publish_default_by_brand d WHERE d.brand_id = p_brand_id;
    v_pub_prev := v_prev -> 'publish_default';
    IF jsonb_typeof(v_pub_prev) = 'null' THEN v_pub_prev := NULL; END IF;
  END IF;

  -- ① 동시 수정 검사: 이번에 보낸 칸만, 연 순간 값(p_prev)과 지금 값 비교 ------------
  FOREACH v_key IN ARRAY c_text LOOP
    CONTINUE WHEN NOT (v_fields ? v_key);
    v_cur := NULLIF(btrim(CASE v_key
               WHEN 'name'                   THEN b.name
               WHEN 'name_ja'                THEN b.name_ja
               WHEN 'name_en'                THEN b.name_en
               WHEN 'company_id'             THEN b.company_id::text
               WHEN 'status'                 THEN b.status
               WHEN 'official_instagram_url' THEN b.official_instagram_url
               WHEN 'official_x_url'         THEN b.official_x_url
             END, c_ws), '');
    v_was := CASE WHEN jsonb_typeof(v_prev -> v_key) = 'string' THEN NULLIF(btrim(v_prev ->> v_key, c_ws), '') ELSE NULL END;
    IF v_key = 'company_id' THEN v_was := lower(v_was); END IF;
    IF v_was IS DISTINCT FROM v_cur THEN
      RETURN jsonb_build_object('result', 'stale');
    END IF;
    -- 바뀐 칸만 SET 에 넣는다
    IF (v_newmap ->> v_key) IS DISTINCT FROM v_cur THEN
      v_set := v_set || v_key;
    END IF;
  END LOOP;
  IF v_fields ? 'publish_default' THEN
    IF v_pub_prev IS DISTINCT FROM v_pub_cur THEN
      RETURN jsonb_build_object('result', 'stale');
    END IF;
    v_pub_chg := v_pub_new IS DISTINCT FROM v_pub_cur;
  END IF;

  -- ② 바뀐 것이 없으면 쓰지 않고 ok ---------------------------------
  IF cardinality(v_set) = 0 AND NOT v_pub_chg THEN
    RETURN jsonb_build_object('result', 'ok');
  END IF;

  -- ③ 쓰기 — 바뀐 칸만 SET(이름을 안 바꿨으면 173·275 가 돌지 않게) ------------
  IF cardinality(v_set) > 0 THEN
    IF 'company_id' = ANY (v_set) THEN
      SELECT co.name_ko INTO v_cname FROM public.companies co WHERE co.id = (v_newmap ->> 'company_id')::uuid;
    END IF;
    BEGIN
      EXECUTE format('UPDATE public.brands SET %s WHERE id = $1',
                     array_to_string(ARRAY(
                       SELECT CASE k
                                WHEN 'company_id' THEN 'company_id = ($2 ->> ''company_id'')::uuid, company_name = $3'
                                ELSE format('%I = $2 ->> %L', k, k)
                              END
                         FROM unnest(v_set) AS k), ', '))
        USING p_brand_id, v_newmap, v_cname;
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con = 'brands_name_normalized_key' THEN
        RETURN jsonb_build_object('result', 'duplicate_name');
      END IF;
      RAISE;  -- 다른 유일 위반은 숨기지 않는다
    END;
  END IF;

  -- 공개 기본 열은 544 함수가 저장(권한·형식은 위에서 확인 — 거기서 오류가 나면 이 저장 전체가 되돌아간다)
  IF v_pub_chg THEN
    PERFORM public.admin_set_brand_publish_default_brand(p_brand_id, v_pub_new);
  END IF;

  RETURN jsonb_build_object('result', 'ok');
END;
$$;

COMMENT ON FUNCTION public.admin_update_brand_info(uuid, jsonb, jsonb) IS
  '[575] 관리자 브랜드 정보 탭 저장(관리자 전원 · publish_default 는 report.share 쓰기). p_fields 열쇠 여덟(name·name_ja·name_en·company_id·status·official_instagram_url·official_x_url·publish_default) 중 온 칸만 — 그 밖 열쇠는 invalid_input. 보낸 칸만 p_prev 와 비교 → stale(값 없음). 바뀐 칸 없으면 ok(안 씀). 바뀐 칸만 UPDATE · company_id 바뀌면 company_name = 회사 name_ko. 공개 기본 열은 544 admin_set_brand_publish_default_brand. 반환 {result: ok|stale|forbidden|duplicate_name|not_found|invalid_input, field?}.';

GRANT  EXECUTE ON FUNCTION public.admin_update_brand_info(uuid, jsonb, jsonb) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_update_brand_info(uuid, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_brand_info(uuid, jsonb, jsonb) FROM anon;

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '575', '575_admin_brand_info_save.sql');
COMMIT;
