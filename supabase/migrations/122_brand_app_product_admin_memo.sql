-- ============================================================
-- 122_brand_app_product_admin_memo.sql
-- 브랜드 서베이 신청 단위 내부 메모 → 제품별 내부 메모 분리
--
-- 목적:
--   brand_applications.admin_memo (신청 단위 단일 텍스트) 를
--   products[i].admin_memo (제품별 jsonb 내부 필드) 로 이전 후
--   기존 컬럼 DROP.
--
-- 변경 범위:
--   (1) 기존 admin_memo 값을 첫 제품(products[0])에 백필
--   (2) record_brand_application_history() 트리거 함수에서 admin_memo 추적 블록 제거
--   (3) admin_create_brand_application RPC에서 p_admin_memo 파라미터 제거
--   (4) brand_applications.admin_memo 컬럼 DROP
--
-- 백필 방식:
--   - admin_memo IS NOT NULL AND admin_memo <> '' AND products 배열 길이 >= 1 인 행만 대상
--   - products[0] 에 admin_memo 키 추가 (jsonb_set, create_missing=true)
--   - 나머지 제품(products[1..]) 은 키 없음 (빈값과 동등)
--
-- 이력 테이블 CHECK 제약 처리 (의도적 유지):
--   - brand_application_history.field_name CHECK 에 'admin_memo' 그대로 보존
--   - 트리거가 더 이상 admin_memo 를 INSERT 하지 않으므로 신규 행은 안 생김
--   - 기존 'admin_memo' field_name 이력 행은 감사 추적 목적으로 보존 (변경 불가)
--   - 'memo_added'/'memo_edited'/'memo_deleted' 등 다른 추적 값도 함께 영향 없음
--   - admin-brand.js 의 HISTORY_FIELD_LABELS.admin_memo 라벨이 기존 행 표시에 사용됨
--
-- 사양서: docs/specs/2026-05-13-brand-app-product-admin-memo.md
-- 작성일: 2026-05-14
-- 2026-05-14 수정: CHECK 제약 갱신 SECTION 제거 (기존 admin_memo 이력 행 위반 + memo_* 3종 누락 발견)
-- ============================================================


-- ============================================================
-- SECTION 1. admin_memo 백필 → products[0].admin_memo
-- ============================================================
UPDATE public.brand_applications
SET products = jsonb_set(
  products,
  '{0,admin_memo}',
  to_jsonb(admin_memo),
  true   -- create_missing = true
)
WHERE admin_memo IS NOT NULL
  AND admin_memo <> ''
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0;

COMMENT ON TABLE public.brand_applications IS
  '[122] products[i].admin_memo 로 제품별 내부 메모 이전 완료. 구 admin_memo 컬럼 제거됨.';


-- ============================================================
-- SECTION 2. record_brand_application_history 트리거 함수 갱신
--   admin_memo 컬럼이 제거되므로 해당 추적 블록 삭제.
--   나머지 5개 추적 필드(status/quote_sent_at/final_quote_krw/products) 유지.
--   products 변경 추적으로 products[i].admin_memo 변경도 자동 포함됨.
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_brand_application_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_actor_id   uuid;
  v_actor_name text;
BEGIN
  v_actor_id := auth.uid();

  IF v_actor_id IS NOT NULL THEN
    SELECT name INTO v_actor_name
    FROM public.admins
    WHERE auth_id = v_actor_id
    LIMIT 1;
  END IF;

  -- status 변경 감지
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'status', to_jsonb(OLD.status), to_jsonb(NEW.status));
  END IF;

  -- quote_sent_at 변경 감지
  IF NEW.quote_sent_at IS DISTINCT FROM OLD.quote_sent_at THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'quote_sent_at', to_jsonb(OLD.quote_sent_at), to_jsonb(NEW.quote_sent_at));
  END IF;

  -- final_quote_krw 변경 감지
  IF NEW.final_quote_krw IS DISTINCT FROM OLD.final_quote_krw THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'final_quote_krw', to_jsonb(OLD.final_quote_krw), to_jsonb(NEW.final_quote_krw));
  END IF;

  -- products 변경 감지 (jsonb 통째 비교 — products[i].admin_memo 변경도 자동 포함)
  IF NEW.products IS DISTINCT FROM OLD.products THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'products', OLD.products, NEW.products);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_brand_application_history IS
  '[079+122] brand_applications AFTER UPDATE 트리거. 추적 4개 컬럼(status/quote_sent_at/final_quote_krw/products). admin_memo 컬럼 제거(122)로 해당 블록 삭제됨. products 추적으로 products[i].admin_memo 변경도 자동 포함.';


-- ============================================================
-- SECTION 3. (제거됨 — 2026-05-14)
--
--   당초 brand_application_history.field_name CHECK 제약에서 'admin_memo' 를
--   제거하려 했으나 아래 두 문제로 SECTION 자체를 제거:
--
--   문제 1) ALTER TABLE ADD CONSTRAINT 는 기존 행을 즉시 검증.
--           field_name='admin_memo' 인 기존 이력 행이 있으면 23514 위반 에러.
--   문제 2) 사양서 작성 시점 점검을 놓침 — 현재 CHECK 에는
--           'memo_added'/'memo_edited'/'memo_deleted' 도 포함되어 있음
--           (마이그레이션 080+ 에서 추가됨). 사양서대로 4개로 줄이면
--           이 3종 신규 INSERT 가 차단되는 조용한 회귀 발생.
--
--   결정: CHECK 제약은 손대지 않음.
--         - 트리거가 더 이상 admin_memo INSERT 안 함 → 신규 admin_memo 행 없음
--         - 기존 admin_memo 이력 행은 감사 목적 보존
--         - memo_* 3종 추적도 영향 없음
-- ============================================================


-- ============================================================
-- SECTION 4. admin_create_brand_application RPC 갱신
--   p_admin_memo 파라미터 제거.
--   기존 14개 파라미터(091) → 확장 15개(102) → 이제 14개 (p_admin_memo 없음).
--
--   ※ 파라미터 수 변경 시 CREATE OR REPLACE 에러 → 기존 시그니처 DROP 후 재생성.
--   ※ 102 시그니처: (text,uuid,text,text,text,text,text,text,text,text,jsonb,text,text,boolean,text[])
--      이번:        (text,uuid,text,text,text,text,text,text,text,text,jsonb,text,boolean,text[])
--                    → p_admin_memo(13번째 text) 제거
-- ============================================================

-- 102 버전 DROP (파라미터 15개 → 14개로 변경)
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean, text[]
);
-- 혹시 남아있을 수 있는 이전 버전도 방어적 정리
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean
);
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean, text[]
);

CREATE OR REPLACE FUNCTION public.admin_create_brand_application(
  p_form_type           text,
  p_brand_id            uuid        DEFAULT NULL,
  p_company_name        text        DEFAULT NULL,
  p_brand_name          text        DEFAULT NULL,
  p_brand_name_ja       text        DEFAULT NULL,
  p_business_no         text        DEFAULT NULL,
  p_contact_name        text        DEFAULT NULL,
  p_phone               text        DEFAULT NULL,
  p_email               text        DEFAULT NULL,
  p_billing_email       text        DEFAULT NULL,
  p_products            jsonb       DEFAULT '[]'::jsonb,
  p_request_note        text        DEFAULT NULL,
  p_brand_sync          boolean     DEFAULT true,
  p_reviewer_channels   text[]      DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_id              uuid;
  v_brand_no              text;
  v_brand_name_normalized text;
  v_existing_primary      jsonb;
  v_app_id                uuid;
  v_app_no                text;
  v_note                  text;
  v_reviewer_channels     text[];
BEGIN

  -- 1. 권한 체크
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[admin_create_brand_application] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;

  -- 2. 입력 검증
  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RAISE EXCEPTION '[admin_create_brand_application] invalid form_type: %. reviewer|seeding 만 허용', p_form_type
      USING ERRCODE = '22023';
  END IF;

  IF p_brand_id IS NULL AND COALESCE(btrim(p_brand_name), '') = '' THEN
    RAISE EXCEPTION '[admin_create_brand_application] p_brand_name is required when p_brand_id is NULL'
      USING ERRCODE = '22023';
  END IF;

  IF p_products IS NULL
     OR jsonb_typeof(p_products) <> 'array'
     OR jsonb_array_length(p_products) < 1
     OR jsonb_array_length(p_products) > 50 THEN
    RAISE EXCEPTION '[admin_create_brand_application] invalid products: jsonb array 1~50개 필요'
      USING ERRCODE = '22023';
  END IF;

  -- 2-B. reviewer_channels 검증 및 정규화
  IF p_form_type <> 'reviewer' THEN
    v_reviewer_channels := NULL;
  ELSE
    IF p_reviewer_channels IS NULL THEN
      v_reviewer_channels := NULL;
    ELSE
      IF array_length(p_reviewer_channels, 1) NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION '[admin_create_brand_application] reviewer_channels 배열 길이는 1~2개여야 합니다. 입력값: %', p_reviewer_channels
          USING ERRCODE = '22023';
      END IF;
      IF NOT (p_reviewer_channels <@ ARRAY['qoo10', 'atcosme']::text[]) THEN
        RAISE EXCEPTION '[admin_create_brand_application] reviewer_channels 허용값: qoo10, atcosme. 입력값: %', p_reviewer_channels
          USING ERRCODE = '22023';
      END IF;
      v_reviewer_channels := p_reviewer_channels;
    END IF;
  END IF;

  -- 3. brand 처리
  IF p_brand_id IS NOT NULL THEN
    SELECT id INTO v_brand_id
    FROM public.brands
    WHERE id = p_brand_id
    FOR UPDATE;

    IF v_brand_id IS NULL THEN
      RAISE EXCEPTION '[admin_create_brand_application] brand not found: %', p_brand_id
        USING ERRCODE = '02000';
    END IF;

    IF p_brand_sync AND (
         COALESCE(btrim(p_contact_name), '') <> ''
      OR COALESCE(btrim(p_phone), '')        <> ''
      OR COALESCE(btrim(p_email), '')        <> ''
      OR COALESCE(btrim(p_brand_name_ja), '') <> ''
      OR COALESCE(btrim(p_business_no), '')   <> ''
      OR COALESCE(btrim(p_company_name), '')  <> ''
    ) THEN
      SELECT elem INTO v_existing_primary
      FROM public.brands b,
           LATERAL jsonb_array_elements(b.contacts) AS elem
      WHERE b.id = v_brand_id
        AND (elem->>'is_primary')::boolean = true
      LIMIT 1;

      IF v_existing_primary IS NOT NULL THEN
        UPDATE public.brands
        SET
          primary_contact_name = COALESCE(NULLIF(btrim(p_contact_name), ''), primary_contact_name),
          primary_phone        = COALESCE(NULLIF(btrim(p_phone), ''),        primary_phone),
          primary_email        = COALESCE(NULLIF(btrim(p_email), ''),        primary_email),
          billing_email        = COALESCE(NULLIF(btrim(p_billing_email), ''), billing_email),
          name_ja              = COALESCE(NULLIF(btrim(p_brand_name_ja), ''), name_ja),
          business_no          = COALESCE(NULLIF(btrim(p_business_no), ''),   business_no),
          company_name         = COALESCE(NULLIF(btrim(p_company_name), ''),  company_name),
          contacts = (
            SELECT jsonb_agg(
              CASE
                WHEN (elem->>'is_primary')::boolean = true THEN
                  elem
                  || jsonb_build_object(
                       'name',  COALESCE(NULLIF(btrim(p_contact_name), ''), elem->>'name'),
                       'phone', COALESCE(NULLIF(btrim(p_phone), ''),        elem->>'phone'),
                       'email', COALESCE(NULLIF(btrim(p_email), ''),        elem->>'email')
                     )
                ELSE elem
              END
            )
            FROM public.brands b2,
                 LATERAL jsonb_array_elements(b2.contacts) AS elem
            WHERE b2.id = v_brand_id
          )
        WHERE id = v_brand_id;

      ELSE
        UPDATE public.brands
        SET
          primary_contact_name = COALESCE(NULLIF(btrim(p_contact_name), ''), primary_contact_name),
          primary_phone        = COALESCE(NULLIF(btrim(p_phone), ''),        primary_phone),
          primary_email        = COALESCE(NULLIF(btrim(p_email), ''),        primary_email),
          billing_email        = COALESCE(NULLIF(btrim(p_billing_email), ''), billing_email),
          name_ja              = COALESCE(NULLIF(btrim(p_brand_name_ja), ''), name_ja),
          business_no          = COALESCE(NULLIF(btrim(p_business_no), ''),   business_no),
          company_name         = COALESCE(NULLIF(btrim(p_company_name), ''),  company_name),
          contacts = contacts || jsonb_build_array(
            jsonb_build_object(
              'id',         gen_random_uuid()::text,
              'name',       NULLIF(btrim(p_contact_name), ''),
              'phone',      NULLIF(btrim(p_phone), ''),
              'email',      NULLIF(btrim(p_email), ''),
              'is_primary', true
            )
          )
        WHERE id = v_brand_id;
      END IF;
    END IF;

  ELSE
    v_brand_name_normalized :=
      lower(trim(regexp_replace(p_brand_name, '\s+', ' ', 'g')));

    PERFORM pg_advisory_xact_lock(hashtext(v_brand_name_normalized)::bigint);

    SELECT id INTO v_brand_id
    FROM public.brands
    WHERE name_normalized = v_brand_name_normalized
    LIMIT 1;

    IF v_brand_id IS NULL THEN
      INSERT INTO public.brands (
        name,
        name_ja,
        company_name,
        business_no,
        primary_contact_name,
        primary_phone,
        primary_email,
        billing_email,
        contacts,
        created_by,
        status
      )
      VALUES (
        p_brand_name,
        NULLIF(btrim(COALESCE(p_brand_name_ja, '')), ''),
        NULLIF(btrim(COALESCE(p_company_name, '')), ''),
        NULLIF(btrim(COALESCE(p_business_no, '')), ''),
        NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
        NULLIF(btrim(COALESCE(p_phone, '')), ''),
        NULLIF(btrim(COALESCE(p_email, '')), ''),
        NULLIF(btrim(COALESCE(p_billing_email, '')), ''),
        CASE
          WHEN COALESCE(btrim(p_contact_name), '') <> ''
            OR COALESCE(btrim(p_phone), '') <> ''
            OR COALESCE(btrim(p_email), '') <> ''
          THEN jsonb_build_array(
            jsonb_build_object(
              'id',         gen_random_uuid()::text,
              'name',       NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
              'phone',      NULLIF(btrim(COALESCE(p_phone, '')), ''),
              'email',      NULLIF(btrim(COALESCE(p_email, '')), ''),
              'is_primary', true
            )
          )
          ELSE '[]'::jsonb
        END,
        auth.uid(),
        'active'
      )
      RETURNING id INTO v_brand_id;
    END IF;
  END IF;

  -- 4. request_note 정규화
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;

  -- 5. brand_applications INSERT
  INSERT INTO public.brand_applications (
    application_no,
    form_type,
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    brand_id,
    source,
    intake_admin_id,
    applicant_contact_name,
    applicant_phone,
    applicant_email,
    products,
    request_note,
    status,
    reviewer_channels
  )
  VALUES (
    '',
    p_form_type,
    COALESCE(NULLIF(btrim(COALESCE(p_brand_name, '')), ''),
             (SELECT name FROM public.brands WHERE id = v_brand_id)),
    NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
    NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_email, '')), ''),
    NULLIF(btrim(COALESCE(p_billing_email, '')), ''),
    v_brand_id,
    'manual_admin',
    auth.uid(),
    NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
    NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_email, '')), ''),
    p_products,
    v_note,
    'new',
    v_reviewer_channels
  )
  RETURNING id, application_no INTO v_app_id, v_app_no;

  SELECT brand_no INTO v_brand_no
  FROM public.brands
  WHERE id = v_brand_id;

  -- 6. 반환
  RETURN jsonb_build_object(
    'id',             v_app_id,
    'application_no', v_app_no,
    'brand_id',       v_brand_id,
    'brand_no',       v_brand_no
  );

END;
$$;

COMMENT ON FUNCTION public.admin_create_brand_application IS
  '[091+102+122] 관리자 직접 광고주 신청 등록 원격 호출 함수(RPC). SECURITY DEFINER + is_admin() 가드. [122] p_admin_memo 파라미터 제거 — 제품별 admin_memo 는 products[i].admin_memo 로 관리. 반환: {id, application_no, brand_id, brand_no}.';


-- ============================================================
-- SECTION 5. GRANT
--   시그니처: 14 파라미터 (102의 15개 중 p_admin_memo 제거)
-- ============================================================
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean, text[]
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean, text[]
) FROM anon;

GRANT EXECUTE ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean, text[]
) TO authenticated;


-- ============================================================
-- SECTION 6. admin_memo 컬럼 DROP
-- ============================================================
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS admin_memo;


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 실행)
-- ============================================================
/*

-- [V0-PRE] (실행 권장 — SECTION 1 백필 직전에 별도로) 백필 대상에서 누락되는 행 확인
-- products IS NULL 또는 빈 배열인데 admin_memo 가 있는 행이 있는지 사전 점검 (0이어야 함)
SELECT COUNT(*) AS rows_skipped_by_backfill
FROM public.brand_applications
WHERE admin_memo IS NOT NULL
  AND admin_memo <> ''
  AND (products IS NULL
    OR jsonb_typeof(products) <> 'array'
    OR jsonb_array_length(products) = 0);
-- 0이 아니면 어떤 행인지 검토 후 진행 (수동 백필 또는 운영 검토)

-- [V0-COUNT] 백필 대상 건수 — V2 와 대조하기 위해 적용 직전에 캡쳐
SELECT COUNT(*) AS should_have_memo_after
FROM public.brand_applications
WHERE admin_memo IS NOT NULL AND admin_memo <> '';

-- [V1] admin_memo 컬럼 제거 확인 (0건 반환되어야 함)
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'brand_applications'
  AND column_name  = 'admin_memo';

-- [V2] products[0].admin_memo 백필 확인
--   (V0-COUNT 와 동일한 숫자여야 함)
SELECT COUNT(*) AS backfilled_rows
FROM public.brand_applications
WHERE products->0->>'admin_memo' IS NOT NULL
  AND products->0->>'admin_memo' <> '';

-- [V2-SAMPLE] 백필 결과 5행 샘플 (눈으로 확인용)
SELECT id, application_no, products->0->>'admin_memo' AS product0_memo
FROM public.brand_applications
WHERE products->0->>'admin_memo' IS NOT NULL
LIMIT 5;

-- [V3] CHECK 제약 보존 확인 (의도적 미수정 — 기존 admin_memo 이력 행 보호)
SELECT conname, pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conrelid = 'public.brand_application_history'::regclass
  AND conname  = 'brand_application_history_field_name_check';
-- def에 'admin_memo' 가 그대로 남아있어야 함 (트리거가 더 이상 INSERT 안 함)

-- [V4] 트리거 함수 갱신 확인 (admin_memo 추적 블록 없어야 함)
SELECT prosrc
FROM pg_proc
WHERE proname = 'record_brand_application_history'
  AND pronamespace = 'public'::regnamespace;
-- admin_memo 문자열 없어야 함

-- [V5] RPC 파라미터 14개 확인
SELECT pg_get_function_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'admin_create_brand_application';
-- p_admin_memo 없어야 함, p_reviewer_channels text[] 있어야 함

-- [V6] 기존 이력(admin_memo field_name) 행 존재 여부 확인
SELECT COUNT(*) AS legacy_admin_memo_history
FROM public.brand_application_history
WHERE field_name = 'admin_memo';
-- 숫자: 과거 이력 보존 확인 (0 또는 기존 이력 수)

*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

-- 1. admin_memo 컬럼 복구 (데이터는 products[0].admin_memo 에서 수동 복원)
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS admin_memo text;

UPDATE public.brand_applications
SET admin_memo = products->0->>'admin_memo'
WHERE products->0->>'admin_memo' IS NOT NULL AND products->0->>'admin_memo' <> '';

-- 2. record_brand_application_history 함수 복구: 079 파일 내용 재실행
--    (CHECK 제약은 122 에서 손대지 않았으므로 복구 불필요)

-- 3. admin_create_brand_application 함수 복구: 102 파일 내용 재실행

NOTIFY pgrst, 'reload schema';

*/
