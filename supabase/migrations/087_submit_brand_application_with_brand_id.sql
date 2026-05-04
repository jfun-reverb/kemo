-- ============================================================
-- Migration 085: submit_brand_application — brands 자동 등록/조회 + brand_id 채우기
--
-- 목적:
--   anon이 sales 폼에서 submit_brand_application RPC를 호출할 때
--   brands 마스터를 자동으로 lookup/insert하고 brand_applications.brand_id
--   및 applicant_* 컬럼을 채운다.
--
-- 전제:
--   - 082: brands 테이블 + brand_applications 컬럼 추가 (brand_id, applicant_* 등)
--   - 083: 기존 데이터 마이그레이션 완료
--   - 084: brands.contacts jsonb 컬럼 추가
--   - 현재 RPC (068 기준): RETURNS text (application_no 단일값)
--
-- 결정 사항:
--   [D1] 반환 타입 유지: RETURNS text (application_no)
--        → sales 폼 클라이언트 코드 변경 불필요.
--        brand_id/brand_no는 반환값에 포함하지 않음 (현 클라이언트가 사용 안 함).
--        필요 시 PR6에서 RETURNS jsonb로 확장.
--
--   [D2] 기존 brand 매칭: name_normalized 기준 lookup만 (UPDATE 없음)
--        → 운영자가 brands 페인에서 직접 수정하는 구조 유지 (자동 덮어쓰기 방지).
--
--   [D3] 신규 brand INSERT 시 contacts jsonb에 첫 담당자를 is_primary=true로 등록
--        → 084 마이그레이션 패턴과 동일. primary_* 컬럼도 동시에 채움(PR6 DROP 전까지 양쪽 유지).
--
--   [D4] legacy 컬럼(brand_name/contact_name/phone/email/billing_email) 동시 채움
--        → PR6에서 DROP 예정. 관리자 페인 기존 쿼리 호환 유지.
--
-- 트리거 영향:
--   - trg_brand_name_normalized (082): brands INSERT 시 name_normalized 자동 계산
--   - trg_brand_no (082): brands INSERT 시 brand_no(BR-YYYY-NNNN) 자동 채번
--   - trg_sync_brand_stats (082): brand_applications INSERT 후 brands 집계 자동 갱신
--   - recalc_brand_application_totals (052): products 합산. 영향 없음
--   - generate_brand_application_no (078): application_no 채번. 영향 없음
--   - record_brand_application_history (079): UPDATE만 hooking. INSERT 영향 없음
--
-- 클라이언트 영향:
--   - sales/reviewer.html, sales/seeding.html: 시그니처 동일, 반환값(text) 동일 → 변경 없음
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- SECTION 1. 기존 함수 DROP (시그니처 변경 없음이지만 RETURNS 타입 혼선 방지)
-- ============================================================
-- 068 버전 (9 파라미터 text 반환)
DROP FUNCTION IF EXISTS public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
);

-- 056 버전 (8 파라미터, 혹시 남아있을 경우 대비)
DROP FUNCTION IF EXISTS public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text
);


-- ============================================================
-- SECTION 2. 신규 RPC 생성
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL,   -- 057에서 DROP됨, 하위호환 유지 (무시)
  p_request_note          text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_name_normalized text;
  v_brand_id              uuid;
  v_note                  text;
  v_no                    text;
BEGIN

  -- --------------------------------------------------------
  -- 1. 입력 검증 (트리거 진입 전 빠른 피드백)
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

  -- --------------------------------------------------------
  -- 2. brand_name 정규화
  --    lower(trim(regexp_replace(brand_name, '\s+', ' ', 'g')))
  --    082의 set_brand_name_normalized 트리거와 동일한 로직
  -- --------------------------------------------------------
  v_brand_name_normalized :=
    lower(trim(regexp_replace(p_brand_name, '\s+', ' ', 'g')));

  -- --------------------------------------------------------
  -- 3. brands lookup 또는 자동 INSERT
  --    [D2] 기존 brand가 있으면 brand_id만 가져옴 (UPDATE 없음)
  --    [D3] 없으면 신규 INSERT — contacts + primary_* 동시 채움
  -- --------------------------------------------------------
  SELECT id INTO v_brand_id
  FROM public.brands
  WHERE name_normalized = v_brand_name_normalized
  LIMIT 1;

  IF v_brand_id IS NULL THEN
    -- 신규 브랜드: INSERT
    -- trg_brand_name_normalized: name → name_normalized 자동 계산
    -- trg_brand_no:              brand_no(BR-YYYY-NNNN) 자동 채번
    INSERT INTO public.brands (
      name,
      primary_contact_name,   -- PR6 DROP 전까지 병행 유지 [D3]
      primary_phone,
      primary_email,
      billing_email,
      contacts,               -- 084 컬럼: [{id, name, phone, email, is_primary}]
      status
    )
    VALUES (
      p_brand_name,           -- name_normalized는 트리거가 자동 계산
      p_contact_name,
      p_phone,
      p_email,
      p_billing_email,
      jsonb_build_array(
        jsonb_build_object(
          'id',         gen_random_uuid()::text,
          'name',       p_contact_name,           -- NULL 허용
          'phone',      p_phone,                  -- NULL 허용
          'email',      p_email,                  -- NULL 허용
          'is_primary', true
        )
      ),
      'active'
    )
    RETURNING id INTO v_brand_id;
  END IF;

  -- --------------------------------------------------------
  -- 4. request_note 정규화: 공백 trim + 1000자 컷 + 빈 문자열 → NULL
  -- --------------------------------------------------------
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;

  -- --------------------------------------------------------
  -- 5. brand_applications INSERT
  --    [D1] RETURNING application_no only (반환 타입 text 유지)
  --    [D4] legacy 컬럼 + 신규 컬럼 동시 채움
  -- --------------------------------------------------------
  INSERT INTO public.brand_applications (
    application_no,           -- 채번 트리거(078)가 JFUN-{Q|N}-YYYYMMDD-NNN 생성
    form_type,
    -- [D4] legacy 컬럼: PR6 DROP 전까지 유지
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    -- [D4] 신규 컬럼: brands 연결 + 신청 시점 스냅샷
    brand_id,
    source,
    applicant_contact_name,
    applicant_phone,
    applicant_email,
    -- 공통
    products,
    request_note
  ) VALUES (
    '',                        -- 채번 트리거가 채움
    p_form_type,
    -- legacy
    p_brand_name,
    p_contact_name,
    p_phone,
    p_email,
    p_billing_email,
    -- 신규
    v_brand_id,
    'online_form',             -- DEFAULT와 동일, 명시 [요구사항 §1]
    p_contact_name,            -- 신청 시점 스냅샷
    p_phone,
    p_email,
    -- 공통
    p_products,
    v_note
  )
  RETURNING application_no INTO v_no;

  -- trg_sync_brand_stats(082)가 AFTER INSERT로 brands 집계 자동 갱신

  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[085] 광고주 신청 폼 제출 RPC. brands 마스터 lookup/자동 INSERT + brand_id 채우기. SECURITY DEFINER(BYPASSRLS). 반환: application_no(text). 시그니처 유지로 sales 폼 클라이언트 변경 불필요.';

-- anon·authenticated가 RPC 호출 가능하도록 EXECUTE 권한 부여
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 직접 실행 — 반드시 ROLLBACK)
-- ============================================================
/*

-- ---- TEST 1: 신규 브랜드 신청 ----
BEGIN;

SELECT count(*) AS brands_before FROM public.brands;

SELECT public.submit_brand_application(
  'reviewer',
  '테스트브랜드 주식회사',     -- brand_name
  '홍길동',                   -- contact_name
  '010-0000-1111',            -- phone
  'test@example.com',         -- email
  '[{"name":"상품A","url":"https://example.com","price_jpy":1000,"qty":5}]'::jsonb,
  'billing@example.com',      -- billing_email
  NULL,                       -- business_license_path (무시)
  '테스트 요청사항입니다.'     -- request_note
) AS application_no;

-- brands 행 1개 추가 확인
SELECT count(*) AS brands_after FROM public.brands;

-- brand_applications.brand_id 채워짐 확인
SELECT
  ba.application_no,
  ba.brand_id IS NOT NULL            AS has_brand_id,
  ba.brand_name,
  ba.applicant_contact_name,
  ba.applicant_phone,
  ba.applicant_email,
  ba.source,
  b.brand_no,
  b.name_normalized,
  b.total_applications,
  jsonb_array_length(b.contacts)     AS contacts_count,
  b.contacts->0->>'is_primary'       AS first_contact_is_primary
FROM public.brand_applications ba
JOIN public.brands b ON b.id = ba.brand_id
ORDER BY ba.created_at DESC
LIMIT 1;

ROLLBACK;


-- ---- TEST 2: 동일 brand_name 재신청 → brands row 유지, brand_applications +1 ----
BEGIN;

SELECT count(*) AS brands_before FROM public.brands;
SELECT count(*) AS apps_before FROM public.brand_applications;

-- 1차 신청
SELECT public.submit_brand_application(
  'reviewer',
  'Apple Japan',
  '야마다',
  '090-0000-0001',
  'apple1@example.com',
  '[{"name":"상품B","url":"https://apple.co.jp","price_jpy":5000,"qty":3}]'::jsonb
) AS app_no_1;

-- 2차 신청 (같은 브랜드, 다른 담당자)
SELECT public.submit_brand_application(
  'seeding',
  'apple japan',              -- 소문자 + 공백 정규화로 동일 brands 행 매칭되어야 함
  '스즈키',
  '090-0000-0002',
  'apple2@example.com',
  '[{"name":"상품C","url":"https://apple.co.jp","price_jpy":3000,"qty":10}]'::jsonb
) AS app_no_2;

-- brands 행 수 변화 없어야 함 (1개)
SELECT count(*) AS brands_after FROM public.brands WHERE name_normalized = 'apple japan';

-- brand_applications 2건 모두 같은 brand_id 참조 확인
SELECT
  ba.application_no,
  ba.brand_id,
  b.brand_no,
  b.total_applications,       -- 트리거가 자동 +1 → 2이어야 함
  ba.applicant_contact_name,
  ba.applicant_email
FROM public.brand_applications ba
JOIN public.brands b ON b.id = ba.brand_id
WHERE b.name_normalized = 'apple japan'
ORDER BY ba.created_at;

ROLLBACK;


-- ---- TEST 3: 필수 필드 누락 → 예외 발생 ----
SELECT public.submit_brand_application(
  'reviewer',
  '',              -- brand_name 빈 값
  '홍길동',
  '010-0000-0000',
  'test@example.com',
  '[{"name":"상품","url":"https://example.com","price_jpy":1000,"qty":1}]'::jsonb
);
-- [submit_brand_application] missing required field 예외 발생해야 함

*/


-- ============================================================
-- 롤백 SQL (이전 버전 068으로 복원)
-- ============================================================
/*
DROP FUNCTION IF EXISTS public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
);

-- 068 버전 복원 (supabase/migrations/068_brand_app_request_note.sql 내 CREATE 부분 재실행)
-- 주요 차이: brand_id/applicant_* 채우지 않음, brands lookup 없음
CREATE OR REPLACE FUNCTION public.submit_brand_application(
  p_form_type             text,
  p_brand_name            text,
  p_contact_name          text,
  p_phone                 text,
  p_email                 text,
  p_products              jsonb,
  p_billing_email         text DEFAULT NULL,
  p_business_license_path text DEFAULT NULL,
  p_request_note          text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_no   text;
  v_note text;
BEGIN
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
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;
  INSERT INTO public.brand_applications (
    application_no, form_type,
    brand_name, contact_name, phone, email, billing_email,
    products, request_note
  ) VALUES (
    '', p_form_type,
    p_brand_name, p_contact_name, p_phone, p_email, p_billing_email,
    p_products, v_note
  )
  RETURNING application_no INTO v_no;
  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[068-rollback] 광고주 신청 폼 제출 RPC. brands lookup 없음 (085 롤백용).';

GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
*/
