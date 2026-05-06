-- ============================================================
-- 091_admin_create_brand_application.sql
-- 관리자 직접 광고주 신청 등록 RPC
--
-- 목적:
--   관리자가 관리자 페이지에서 brand_applications 행을 직접 생성한다.
--   기존 submit_brand_application(085)는 anon(sales 폼 전용).
--   이 RPC는 authenticated + is_admin() 전용이며 SECURITY DEFINER로 RLS 우회.
--
-- 전제:
--   - 082: brands 테이블 + brand_applications.source / intake_admin_id / applicant_* 컬럼 존재
--   - 084: brands.contacts jsonb 컬럼 존재
--   - 088: brands.brand_seq 컬럼 + 계층 카운터 테이블 존재
--   - 090: generate_brand_application_no() 트리거 — brand_id 필수, advisory lock 포함
--
-- 트리거 체인 (INSERT 시 자동 실행):
--   trg_brand_app_no (090): brand_id → B{seq}-A{seq} 채번
--   trg_brand_app_recalc (052): products → total_jpy/total_qty/estimated_krw 재계산
--   trg_brand_app_touch (052): updated_at/version 갱신 (INSERT 시는 미동작, BEFORE UPDATE 전용)
--   trg_sync_brand_stats (082): brand_id → brands.total_applications 재집계
--
-- Edge Function 알림 메일 처리:
--   notify-brand-application WebHook이 brand_applications INSERT 감지 시 자동 발송.
--   source='manual_admin' 건은 Phase 2에서 웹훅 필터로 분리 예정.
--   Phase 1에서는 관리자 등록 건도 브랜드 접수 확인 + 관리자 알림 메일이 발송됨.
--   클라이언트가 알림 메일 발송을 원하지 않을 때는 RPC 파라미터 p_skip_notify=true
--   를 전달하면 되나, 현재 Phase 1에서 웹훅은 DB 레이어에서 차단 불가.
--   (웹훅 자체를 source 분기로 막으려면 notify-brand-application Edge Function 수정 필요 — Phase 2)
--
-- brand 동기화 전략:
--   p_brand_id NOT NULL → 기존 brands 행 SELECT FOR UPDATE → primary_* + contacts 동기 갱신
--   p_brand_id NULL     → 신규 brands INSERT (name_normalized UNIQUE 충돌 시 기존 행 재사용)
--
-- 반환:
--   jsonb: { id, application_no, brand_id, brand_no }
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- SECTION 1. admin_create_brand_application RPC
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_brand_application(
  p_form_type         text,
  p_brand_id          uuid        DEFAULT NULL,
  p_brand_name        text        DEFAULT NULL,
  p_contact_name      text        DEFAULT NULL,
  p_phone             text        DEFAULT NULL,
  p_email             text        DEFAULT NULL,
  p_billing_email     text        DEFAULT NULL,
  p_products          jsonb       DEFAULT '[]'::jsonb,
  p_request_note      text        DEFAULT NULL,
  p_brand_sync        boolean     DEFAULT true
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
BEGIN

  -- ──────────────────────────────────────────────────────────
  -- 1. 권한 체크
  --    is_admin() = admins 테이블에서 auth.uid() 조회
  -- ──────────────────────────────────────────────────────────
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[admin_create_brand_application] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;


  -- ──────────────────────────────────────────────────────────
  -- 2. 입력 검증 (트리거 진입 전 빠른 피드백)
  -- ──────────────────────────────────────────────────────────
  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RAISE EXCEPTION '[admin_create_brand_application] invalid form_type: %. reviewer|seeding 만 허용', p_form_type
      USING ERRCODE = '22023';
  END IF;

  -- brand_name은 신규 생성 시 필수 (기존 brand 선택 시 NULL 허용)
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


  -- ──────────────────────────────────────────────────────────
  -- 3. brand 처리
  -- ──────────────────────────────────────────────────────────

  IF p_brand_id IS NOT NULL THEN
    -- 3-A. 기존 brand 선택: SELECT FOR UPDATE → 동시 수정 직렬화
    SELECT id INTO v_brand_id
    FROM public.brands
    WHERE id = p_brand_id
    FOR UPDATE;

    IF v_brand_id IS NULL THEN
      RAISE EXCEPTION '[admin_create_brand_application] brand not found: %', p_brand_id
        USING ERRCODE = '02000';
    END IF;

    -- 3-A-i. brand 마스터 동기 갱신 (p_brand_sync=true, 연락처가 입력된 경우)
    --   primary_* 컬럼 + contacts[is_primary=true] 동시 갱신
    --   p_brand_name은 기존 brand 이름 변경에 사용하지 않음 (brand 페인에서 직접 수정)
    IF p_brand_sync AND (
         COALESCE(btrim(p_contact_name), '') <> ''
      OR COALESCE(btrim(p_phone), '')        <> ''
      OR COALESCE(btrim(p_email), '')        <> ''
    ) THEN
      -- 기존 contacts 중 is_primary=true 항목 확인
      SELECT elem INTO v_existing_primary
      FROM public.brands b,
           LATERAL jsonb_array_elements(b.contacts) AS elem
      WHERE b.id = v_brand_id
        AND (elem->>'is_primary')::boolean = true
      LIMIT 1;

      IF v_existing_primary IS NOT NULL THEN
        -- 기존 primary contact를 갱신 (id는 유지, name/phone/email만 덮어씀)
        UPDATE public.brands
        SET
          primary_contact_name = COALESCE(NULLIF(btrim(p_contact_name), ''), primary_contact_name),
          primary_phone        = COALESCE(NULLIF(btrim(p_phone), ''),        primary_phone),
          primary_email        = COALESCE(NULLIF(btrim(p_email), ''),        primary_email),
          billing_email        = COALESCE(NULLIF(btrim(p_billing_email), ''), billing_email),
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
        -- contacts에 is_primary=true 항목 없음 → 신규 항목 추가
        UPDATE public.brands
        SET
          primary_contact_name = COALESCE(NULLIF(btrim(p_contact_name), ''), primary_contact_name),
          primary_phone        = COALESCE(NULLIF(btrim(p_phone), ''),        primary_phone),
          primary_email        = COALESCE(NULLIF(btrim(p_email), ''),        primary_email),
          billing_email        = COALESCE(NULLIF(btrim(p_billing_email), ''), billing_email),
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
    END IF; -- p_brand_sync

  ELSE
    -- 3-B. 신규 brand INSERT
    --   name_normalized UNIQUE 충돌 방지: 먼저 lookup, 없으면 INSERT
    v_brand_name_normalized :=
      lower(trim(regexp_replace(p_brand_name, '\s+', ' ', 'g')));

    -- advisory lock으로 동일 name_normalized 동시 INSERT 직렬화
    PERFORM pg_advisory_xact_lock(hashtext(v_brand_name_normalized)::bigint);

    -- 기존 brand 재확인 (advisory lock 획득 후)
    SELECT id INTO v_brand_id
    FROM public.brands
    WHERE name_normalized = v_brand_name_normalized
    LIMIT 1;

    IF v_brand_id IS NULL THEN
      -- 신규 INSERT
      -- trg_brand_name_normalized (082): name → name_normalized 자동 계산
      -- trg_brand_no (082): brand_no(BR-YYYY-NNNN) 자동 채번
      -- trg_brand_seq (090): brand_seq 자동 채번
      INSERT INTO public.brands (
        name,
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
    -- 기존 brand 재사용 시: 이름이 일치하는 브랜드가 이미 있으므로 그대로 사용.
    -- 연락처 갱신은 하지 않음 (의도치 않은 덮어쓰기 방지).

  END IF;


  -- ──────────────────────────────────────────────────────────
  -- 4. request_note 정규화: trim + 1000자 컷 + 빈 문자열 → NULL
  -- ──────────────────────────────────────────────────────────
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;


  -- ──────────────────────────────────────────────────────────
  -- 5. brand_applications INSERT
  --    - source = 'manual_admin'
  --    - intake_admin_id = auth.uid()
  --    - applicant_* 컬럼: 신청 시점 스냅샷
  --    - legacy 컬럼(brand_name/contact_name/phone/email/billing_email): PR6 DROP 전까지 병행 유지
  --    - trg_brand_app_no (090): brand_id → B{seq}-A{seq} 채번 (brand_id NULL이면 RAISE EXCEPTION)
  --    - trg_brand_app_recalc (052): products → 합계 재계산
  -- ──────────────────────────────────────────────────────────
  INSERT INTO public.brand_applications (
    application_no,             -- '' → 트리거가 B{seq}-A{seq} 채번
    form_type,
    -- [legacy] PR6 DROP 전까지 병행 유지
    brand_name,
    contact_name,
    phone,
    email,
    billing_email,
    -- [신규] 정규화 연결 + 신청 시점 스냅샷
    brand_id,
    source,
    intake_admin_id,
    applicant_contact_name,
    applicant_phone,
    applicant_email,
    -- 공통
    products,
    request_note,
    status
  )
  VALUES (
    '',                                                   -- 채번 트리거가 채움
    p_form_type,
    -- legacy
    COALESCE(NULLIF(btrim(COALESCE(p_brand_name, '')), ''),
             (SELECT name FROM public.brands WHERE id = v_brand_id)),
    NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
    NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_email, '')), ''),
    NULLIF(btrim(COALESCE(p_billing_email, '')), ''),
    -- 신규
    v_brand_id,
    'manual_admin',
    auth.uid(),
    NULLIF(btrim(COALESCE(p_contact_name, '')), ''),     -- 신청 시점 스냅샷
    NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_email, '')), ''),
    -- 공통
    p_products,
    v_note,
    'new'
  )
  RETURNING id, application_no INTO v_app_id, v_app_no;

  -- brand_no 조회 (반환값에 포함, 클라이언트 즉시 페인 갱신 가능)
  SELECT brand_no INTO v_brand_no
  FROM public.brands
  WHERE id = v_brand_id;

  -- ──────────────────────────────────────────────────────────
  -- 6. 반환
  -- ──────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'id',             v_app_id,
    'application_no', v_app_no,
    'brand_id',       v_brand_id,
    'brand_no',       v_brand_no
  );

END;
$$;

COMMENT ON FUNCTION public.admin_create_brand_application IS
  '[091] 관리자 직접 광고주 신청 등록 RPC. SECURITY DEFINER + is_admin() 가드. brand_id 지정 시 기존 brand 사용 + 연락처 동기 갱신, NULL 시 신규 brand INSERT (name_normalized 중복이면 기존 재사용). source=manual_admin, intake_admin_id=auth.uid(). 반환: {id, application_no, brand_id, brand_no}.';


-- ============================================================
-- SECTION 2. GRANT
--   authenticated: EXECUTE 허용 + 내부 is_admin() 가드
--   anon: 거부 (submit_brand_application이 anon용)
-- ============================================================
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
) FROM anon;

GRANT EXECUTE ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
) TO authenticated;


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 실행)
-- ============================================================
/*

-- ────────────────────────────────────────────────────────────
-- [V1] RPC 존재 확인
-- ────────────────────────────────────────────────────────────
SELECT routine_name, routine_type, security_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'admin_create_brand_application';
-- admin_create_brand_application / FUNCTION / DEFINER 반환되어야 함


-- ────────────────────────────────────────────────────────────
-- [V2] 파라미터 시그니처 확인
-- ────────────────────────────────────────────────────────────
SELECT
  p.proname,
  pg_get_function_arguments(p.oid) AS args,
  pg_get_function_result(p.oid)    AS ret
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'admin_create_brand_application';
-- args에 p_form_type text, p_brand_id uuid, ... p_brand_sync boolean 10개 파라미터 확인
-- ret = jsonb


-- ────────────────────────────────────────────────────────────
-- [V3] 신규 brand 생성 + 신청 등록 전체 흐름 (반드시 ROLLBACK)
-- ────────────────────────────────────────────────────────────
BEGIN;

-- admin 세션 컨텍스트가 있어야 함 (SQL Editor는 service_role로 실행되므로
-- is_admin() 체크가 RLS 우회됨. 실제 운영에서는 관리자 JWT로 호출해야 함)
-- 아래 테스트는 service_role 환경에서 is_admin() 우회 목적으로 직접 INSERT로 대체
-- 실제 클라이언트 테스트는 개발서버 관리자 로그인 후 adminCreateBrandApplication() 호출 권장

-- 브랜드 수 확인 (BEFORE)
SELECT count(*) AS brands_before FROM public.brands;
SELECT count(*) AS apps_before FROM public.brand_applications;

-- (주의: SQL Editor service_role이면 is_admin()=false가 되어 42501 발생 가능.
--  대신 아래 검증 로직으로 트리거 체인만 확인)

-- V3-A: 트리거 체인 확인 (INSERT 직접 실행으로 대체)
WITH new_brand AS (
  INSERT INTO public.brands (name)
  VALUES ('검증테스트브랜드_V3A')
  RETURNING id, brand_no, brand_seq
),
new_app AS (
  INSERT INTO public.brand_applications (
    application_no, form_type,
    brand_name, contact_name, phone, email,
    brand_id, source, intake_admin_id,
    applicant_contact_name, applicant_phone, applicant_email,
    products, status
  )
  SELECT
    '',
    'reviewer',
    '검증테스트브랜드_V3A',
    '테스트담당자',
    '010-1234-5678',
    'test@example.com',
    nb.id,
    'manual_admin',
    NULL,   -- SQL Editor: auth.uid() NULL
    '테스트담당자',
    '010-1234-5678',
    'test@example.com',
    '[{"name":"상품A","url":"https://example.com","price_jpy":1000,"qty":5}]'::jsonb,
    'new'
  FROM new_brand nb
  RETURNING application_no, brand_id, source, total_jpy, total_qty, estimated_krw
)
SELECT
  nb.brand_no,
  nb.brand_seq,
  na.application_no,          -- B{brand_seq}-A001 형태이어야 함
  na.source,                  -- 'manual_admin' 이어야 함
  na.total_jpy,               -- 5000 (1000 * 5)
  na.total_qty,               -- 5
  na.estimated_krw            -- reviewer: (5000*10 + 5*2500) * 1.1 = 68750
FROM new_brand nb, new_app na;

ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V4] 기존 brand 선택 + contacts 동기 갱신 테스트 (반드시 ROLLBACK)
-- ────────────────────────────────────────────────────────────
BEGIN;

-- 테스트 브랜드 준비
INSERT INTO public.brands (
  name, primary_contact_name, primary_phone, primary_email,
  contacts
)
VALUES (
  '기존브랜드_V4',
  '기존담당자', '000-0000-0000', 'old@example.com',
  '[{"id":"test-id-001","name":"기존담당자","phone":"000-0000-0000","email":"old@example.com","is_primary":true}]'::jsonb
);

-- 기존 brand contacts 확인
SELECT brand_no, contacts FROM public.brands WHERE name = '기존브랜드_V4';

-- is_admin() 가드 없이 UPDATE만 테스트 (brands 직접 UPDATE로 갱신 로직 검증)
UPDATE public.brands
SET
  primary_contact_name = '신규담당자',
  primary_phone        = '010-9999-8888',
  primary_email        = 'new@example.com',
  contacts = (
    SELECT jsonb_agg(
      CASE
        WHEN (elem->>'is_primary')::boolean = true THEN
          elem || jsonb_build_object('name','신규담당자','phone','010-9999-8888','email','new@example.com')
        ELSE elem
      END
    )
    FROM LATERAL jsonb_array_elements(contacts) AS elem
  )
WHERE name = '기존브랜드_V4';

-- 갱신 결과 확인
SELECT
  primary_contact_name,
  primary_phone,
  primary_email,
  contacts->0->>'name'  AS contacts_name,
  contacts->0->>'phone' AS contacts_phone,
  contacts->0->>'email' AS contacts_email,
  contacts->0->>'is_primary' AS is_primary
FROM public.brands
WHERE name = '기존브랜드_V4';
-- primary_* 와 contacts[0] 모두 신규담당자/010-9999-8888/new@example.com 이어야 함

ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V5] source='manual_admin' 존재 확인 (기존 데이터)
-- ────────────────────────────────────────────────────────────
SELECT source, count(*) FROM public.brand_applications GROUP BY source ORDER BY source;
-- online_form N건, manual_admin 0건 (아직 등록 전)


-- ────────────────────────────────────────────────────────────
-- [V6] GRANT 확인 (anon 거부, authenticated 허용)
-- ────────────────────────────────────────────────────────────
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name = 'admin_create_brand_application'
ORDER BY grantee;
-- authenticated: EXECUTE
-- anon: 없음 (거부)


-- ────────────────────────────────────────────────────────────
-- [V7] name_normalized 충돌 처리 확인 (advisory lock)
-- ────────────────────────────────────────────────────────────
BEGIN;

-- 동일 brand_name 2회 신청 → 두 번째는 기존 brand 재사용
INSERT INTO public.brands (name) VALUES ('충돌테스트브랜드');

-- name_normalized 조회
SELECT id, brand_no, name_normalized FROM public.brands WHERE name = '충돌테스트브랜드';

-- 같은 normalized name INSERT 시도 → UNIQUE 오류 발생 확인
INSERT INTO public.brands (name) VALUES ('충돌테스트브랜드');
-- ERROR: duplicate key value violates unique constraint "brands_name_normalized_key"

ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V8] products 검증 체크
-- ────────────────────────────────────────────────────────────
-- 빈 배열 → 에러 발생 확인 (실제 RPC 호출 시)
-- BEGIN;
-- SELECT public.admin_create_brand_application(
--   'reviewer',
--   NULL,           -- p_brand_id
--   '검증브랜드',
--   '담당자',
--   '010-0000-0000',
--   'test@x.com',
--   NULL,
--   '[]'::jsonb     -- 빈 배열 → 에러
-- );
-- ROLLBACK;
-- ERROR: [admin_create_brand_application] invalid products

*/


-- ============================================================
-- 롤백 SQL
-- 이 마이그레이션은 함수 추가만 수행하므로 DROP FUNCTION으로 완전 롤백 가능.
-- brands / brand_applications 데이터는 영향 없음.
-- ============================================================
/*

-- STEP 1. RPC 제거
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
);

NOTIFY pgrst, 'reload schema';

-- STEP 2. storage.js 대응 함수 제거 (코드 롤백)
-- dev/lib/storage.js의 adminCreateBrandApplication() 함수를 제거하고 빌드

*/
