-- ============================================================
-- 397. 광고주 신청(익명 제출) — 제품 배열의 원소를 실제로 검사한다
-- ============================================================
-- 전수조사(2차) 묶음 A — A-4 의 데이터베이스 쪽.
-- 조사 근거: docs/research/2026-09-02-codebase-audit-findings.md §4-5
-- 조치 계획: docs/specs/2026-09-02-audit-remediation-plan.md 「묶음 A」
--
-- ── 무엇이 문제였나 ────────────────────────────────────────
-- 206 이 넣은 검사는 `p_products` 가 **배열인지 · 1~50개인지**까지만 본다.
-- 그 안에 무엇이 들었는지는 **한 번도 안 봤다.**
--   [123, "<script>…", null]  ← 전부 통과해 그대로 저장됐다
-- 이 함수는 `anon` 이 부르는 **익명 창구**라 화면(sales 폼)을 거치지 않고
-- 아무 값이나 직접 넣을 수 있다. 화면은 항상
--   { name: 문자열, url: 문자열, price: 숫자, qty: 숫자 }
-- 만 보내므로(sales/reviewer.html·seeding.html 의 collectProducts) 이 검사는
-- **정상 제출에 아무 영향이 없다.**
--
-- ⚠️ 짝이 되는 화면 쪽 조치가 함께 나간다 —
--    `supabase/functions/notify-brand-application/index.ts` 가 제품 금액·수량을
--    이스케이프 없이 메일 표에 넣고 있었다. 🔴 문자열도
--    `String.prototype.toLocaleString` 때문에 그대로 통과한다.
--    거기서 숫자로 걸러내고 이스케이프한다. **두 겹이 한 세트다.**
--
-- ── 무엇을 막고 무엇을 막지 않나 ──────────────────────────
--  막는다   : 원소가 객체가 아닌 것 / name·url 이 문자열이 아닌 것 /
--             price·qty 가 숫자가 아닌 것 / name 500자·url 2000자 초과
--  안 막는다: **키가 아예 없는 것**(선택 입력이 정상이다) /
--             `null` 값 / 여기 없는 키(관리자가 나중에 price_check·status 를 더한다)
--
-- ⚠️ 키가 없으면 `jsonb_typeof(e.v -> 'name')` 이 SQL NULL 이고
--    `NULL NOT IN (…)` 은 NULL 이라 조건이 참이 되지 않는다 — 그래서 통과한다.
--    이 성질에 기대고 있으므로 조건을 `IS DISTINCT FROM` 류로 바꾸면 **동작이 뒤집힌다.**
--
-- ⚠️ `jsonb -> text` 는 원소가 객체가 아닐 때도 오류 대신 NULL 을 준다.
--    다만 SQL 은 OR 의 평가 순서를 보장하지 않으므로
--    `jsonb_typeof(e.v) = 'object' AND (…)` 로 **명시적으로** 감쌌다.
--
-- ── 베이스 ────────────────────────────────────────────────
-- 🔴 이 함수의 현재 원본은 **206** 이다(056 → 057 → 068 → 087 → 206).
--    369 는 이 함수를 **정의하지 않고** 주석에서 언급만 한다 — 베이스로 삼지 말 것.
--    본문은 206 을 글자 그대로 옮기고 위 검사 한 덩어리만 더했다.
--
-- ⚠️ `CREATE OR REPLACE` 다 — `DROP` 후 `CREATE` 하면 `anon` 실행 권한이
--    통째로 사라져 **광고주 신청 창구가 죽는다.** 그래도 아래에서 명시 재부여한다.
--
-- ⚠️ 지금 공개 제출은 `brand_survey_settings.submissions_open = false` 로
--    **막혀 있다**(206). 그래서 이 조치는 **다시 열 때를 위한 것**이고
--    지금 당장 막히는 정상 제출은 0건이다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL,   -- 057에서 사용 중단됨, 하위호환 유지 (무시)
  p_request_note          text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submissions_open      boolean;
  v_brand_name_normalized text;
  v_brand_id              uuid;
  v_note                  text;
  v_no                    text;
BEGIN

  -- --------------------------------------------------------
  -- 0. 공개 제출 차단 가드 [206 추가]
  --    brand_survey_settings.submissions_open = false(기본)이면 즉시 거부.
  --    행이 없거나 NULL이면 안전 기본값 false(차단) 적용.
  --    SECURITY DEFINER라 RLS 우회하여 설정값 읽기 가능.
  -- --------------------------------------------------------
  SELECT submissions_open INTO v_submissions_open
  FROM public.brand_survey_settings
  WHERE id = 1;

  IF NOT COALESCE(v_submissions_open, false) THEN
    RAISE EXCEPTION 'submissions_closed'
      USING ERRCODE = 'P0001';
  END IF;

  -- --------------------------------------------------------
  -- 1. 입력 검증 (트리거 진입 전 빠른 피드백) [087 원본]
  -- --------------------------------------------------------
  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RAISE EXCEPTION '[submit_brand_application] invalid form_type: %', p_form_type
      USING ERRCODE = '22023';
  END IF;

  IF COALESCE(p_brand_name, '') = ''
     OR COALESCE(p_contact_name, '') = ''
     OR COALESCE(p_phone, '') = ''
     OR COALESCE(p_email, '') = '' THEN
    RAISE EXCEPTION '[submit_brand_application] missing required field'
      USING ERRCODE = '22023';
  END IF;

  IF p_products IS NULL
     OR jsonb_typeof(p_products) <> 'array'
     OR jsonb_array_length(p_products) < 1
     OR jsonb_array_length(p_products) > 50 THEN
    RAISE EXCEPTION '[submit_brand_application] invalid products array'
      USING ERRCODE = '22023';
  END IF;

  -- 1-B. 제품 배열의 **각 원소**를 본다 (397 신설)
  --      위 검사는 「배열인가·개수가 맞는가」까지만 봤다. 원소가 무엇이든 통과했다.
  --      익명 창구라 화면을 거치지 않고 아무 값이나 넣을 수 있다.
  --      ⚠️ 키가 없으면 jsonb_typeof(...) 가 NULL 이라 NOT IN 이 NULL 이 되어 통과한다 —
  --         「없는 키」는 막지 않는다(선택 입력이 정상). 「있는데 타입이 다른 것」만 막는다.
  --      ⚠️ 여기에 없는 키는 그대로 통과시킨다 — 관리자가 나중에 price_check·status 를 더한다.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_products) AS e(v)
     WHERE jsonb_typeof(e.v) <> 'object'
        OR (jsonb_typeof(e.v) = 'object' AND (
                 jsonb_typeof(e.v -> 'name')  NOT IN ('string', 'null')
              OR jsonb_typeof(e.v -> 'url')   NOT IN ('string', 'null')
              OR jsonb_typeof(e.v -> 'price') NOT IN ('number', 'null')
              OR jsonb_typeof(e.v -> 'qty')   NOT IN ('number', 'null')
              OR length(e.v ->> 'name') > 500
              OR length(e.v ->> 'url')  > 2000
            ))
  ) THEN
    RAISE EXCEPTION '[submit_brand_application] invalid products element'
      USING ERRCODE = '22023';
  END IF;

  -- --------------------------------------------------------
  -- 2. brand_name 정규화
  --    lower(trim(regexp_replace(brand_name, '\s+', ' ', 'g')))
  --    082의 set_brand_name_normalized 트리거와 동일한 로직
  -- --------------------------------------------------------
  v_brand_name_normalized :=
    lower(trim(regexp_replace(p_brand_name, '\s+', ' ', 'g')));

  -- --------------------------------------------------------
  -- 3. brands lookup 또는 자동 INSERT [087 원본]
  -- --------------------------------------------------------
  SELECT id INTO v_brand_id
  FROM public.brands
  WHERE name_normalized = v_brand_name_normalized
  LIMIT 1;

  IF v_brand_id IS NULL THEN
    INSERT INTO public.brands (
      name,
      primary_contact_name,
      primary_phone,
      primary_email,
      billing_email,
      contacts,
      status
    )
    VALUES (
      p_brand_name,
      p_contact_name,
      p_phone,
      p_email,
      p_billing_email,
      jsonb_build_array(
        jsonb_build_object(
          'id',         gen_random_uuid()::text,
          'name',       p_contact_name,
          'phone',      p_phone,
          'email',      p_email,
          'is_primary', true
        )
      ),
      'active'
    )
    RETURNING id INTO v_brand_id;
  END IF;

  -- --------------------------------------------------------
  -- 4. request_note 정규화 [087 원본]
  -- --------------------------------------------------------
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;

  -- --------------------------------------------------------
  -- 5. brand_applications INSERT [087 원본]
  --    trg_fill_reviewer_transfer_fee(092/098 BEFORE INSERT 트리거)가
  --    이 INSERT 후 자동 발화하여 products[].transfer_fee_krw 채움 — 동작 보존
  -- --------------------------------------------------------
  INSERT INTO public.brand_applications (
    application_no,
    form_type,
    -- legacy 컬럼 (PR6 DROP 전까지 유지)
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    -- 신규 컬럼
    brand_id,
    source,
    applicant_contact_name,
    applicant_phone,
    applicant_email,
    -- 공통
    products,
    request_note
  ) VALUES (
    '',                        -- 채번 트리거(078)가 채움
    p_form_type,
    -- legacy
    p_brand_name,
    p_contact_name,
    p_phone,
    p_email,
    p_billing_email,
    -- 신규
    v_brand_id,
    'online_form',
    p_contact_name,
    p_phone,
    p_email,
    -- 공통
    p_products,
    v_note
  )
  RETURNING application_no INTO v_no;

  RETURN v_no;
END;
$$;


-- ------------------------------------------------------------
-- 권한 재부여 (시그니처 동일 · REPLACE 라 보존되지만 명시)
-- ------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 (SQL Editor에서 실행 — 전부 조회 전용)
-- ============================================================
/*

-- [V1] 정상 형태는 통과해야 한다 (실제로 저장되지는 않게 되돌린다)
--      ⚠️ 공개 제출이 막혀 있으면 'submissions_closed' 로 끝난다 — 그것도 통과다
--         (그 0단계 게이트는 원소 검사보다 **앞**에 있다)
BEGIN;
  SELECT public.submit_brand_application(
    'reviewer', '검증용브랜드', '담당자', '010-0000-0000', 'a@example.com',
    '[{"name":"제품A","url":"https://example.com","price":1000,"qty":2}]'::jsonb
  );
ROLLBACK;

-- [V2] 원소가 객체가 아니면 거부돼야 한다
BEGIN;
  SELECT public.submit_brand_application(
    'reviewer', '검증용브랜드', '담당자', '010-0000-0000', 'a@example.com',
    '[123]'::jsonb
  );
ROLLBACK;
-- 기대: invalid products element

-- [V3] 금액이 문자열이면 거부돼야 한다 (메일 표에 그대로 실리던 값)
BEGIN;
  SELECT public.submit_brand_application(
    'reviewer', '검증용브랜드', '담당자', '010-0000-0000', 'a@example.com',
    '[{"name":"제품A","price":"<img src=x onerror=alert(1)>","qty":1}]'::jsonb
  );
ROLLBACK;
-- 기대: invalid products element

-- [V4] 키가 없는 것은 통과해야 한다 (선택 입력이 정상)
BEGIN;
  SELECT public.submit_brand_application(
    'reviewer', '검증용브랜드', '담당자', '010-0000-0000', 'a@example.com',
    '[{"name":"제품A"}]'::jsonb
  );
ROLLBACK;
-- 기대: 통과(또는 submissions_closed)

-- [V5] 실행 권한이 그대로인지 — anon 이 살아 있어야 한다
SELECT has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'submit_brand_application';
-- 기대: true

-- [V6] 이미 저장된 행 중 이 검사에 걸리는 것이 있는가 (소급 정리 필요 여부)
SELECT count(*) AS bad_rows
  FROM public.brand_applications a
 WHERE EXISTS (
   SELECT 1 FROM jsonb_array_elements(a.products) AS e(v)
    WHERE jsonb_typeof(e.v) <> 'object'
       OR (jsonb_typeof(e.v) = 'object' AND (
                jsonb_typeof(e.v -> 'name')  NOT IN ('string', 'null')
             OR jsonb_typeof(e.v -> 'price') NOT IN ('number', 'null')
             OR jsonb_typeof(e.v -> 'qty')   NOT IN ('number', 'null')
           ))
 );
-- 기대: 0. 0이 아니면 그 행의 메일은 이미 나갔으므로 내용을 확인할 것

*/


-- ============================================================
-- 롤백 (필요 시)
-- ============================================================
-- 206 을 그대로 다시 실행하면 이 검사가 빠진 판으로 돌아간다.
-- 함수 시그니처가 같으므로 권한은 보존된다.
