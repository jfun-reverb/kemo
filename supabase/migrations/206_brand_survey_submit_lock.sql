-- ============================================================
-- Migration 206: 브랜드 서베이 공개 제출 차단
--
-- 목적:
--   공개 홍보 중단 후에도 옛 sales 폼 URL로 신청이 계속 들어오는 문제를 해결.
--   영업 2단계(초대 링크 발급) 폼 용도는 유지하되 무분별 공개 제출만 즉시 차단.
--
-- 설계 결정:
--   [D1] 차단 방식: 단일행 설정 테이블(brand_survey_settings) — A 방식
--        - 시그니처 유지: submit_brand_application 인자 추가 없음
--          → sales 폼 HTML 변경 최소화 (에러 메시지 분기만 추가)
--        - super_admin이 대시보드 SQL 또는 관리자 토글로 임시 재개 가능
--          (submissions_open=true 로 UPDATE)
--        - 2단계(영업 토큰 발급 화면) 전환 시에도 이 함수 내부만 교체하면 됨
--        - 비용 최소: 테이블 1개 + 함수 갱신 1건
--
--   [D2] 관리자 override 경로: admin_create_brand_application(091) 기존 함수 그대로
--        - authenticated + is_admin() 가드 보유 → 영업 공백 동안 관리자 페인 직접 입력 가능
--        - 본 마이그레이션 영향 없음 (별개 함수)
--
--   [D3] 오리엔시트 무영향 확인
--        - submit_orient_sheet(187)는 별개 함수(토큰 기반 보호), 영향 0
--        - 본 마이그레이션은 submit_brand_application만 수정
--
--   [D4] 차단 시 반환 형태 (폼이 분기 가능하도록)
--        - RAISE EXCEPTION 'submissions_closed' USING ERRCODE='P0001'
--        - supabase-js RPC 호출 시: error.message === 'submissions_closed'
--        - 폼은 이 메시지를 잡아 "현재 신규 접수를 받지 않습니다. ceo@jfun.co.kr 문의" 안내
--
--   [D5] 092/098 기본값 보존
--        - 트리거 fill_reviewer_transfer_fee(brand_applications BEFORE INSERT)는
--          brand_survey_settings를 읽지 않음 → 완전 독립, 영향 없음
--        - submit_brand_application 본문(087)을 REPLACE할 때 INSERT 구문 그대로 보존
--          → trg_fill_reviewer_transfer_fee가 여전히 INSERT 후 자동 발화
--
-- 차단 해제(임시 재개) 방법:
--   UPDATE public.brand_survey_settings SET submissions_open = true, updated_at = now()
--   WHERE id = 1;
--
-- 차단 재활성화:
--   UPDATE public.brand_survey_settings SET submissions_open = false, updated_at = now()
--   WHERE id = 1;
--
-- 2단계 전환 시 변경 포인트:
--   submit_brand_application 내 "0. 공개 제출 차단 가드" 섹션을
--   토큰 검증 로직(create_orient_sheet 패턴 참조)으로 교체.
--   brand_survey_settings 테이블은 더 이상 참조 안 해도 됨(또는 제거).
--
-- 작성일: 2026-06-30
-- 관련 사양서: docs/specs/2026-06-30-brand-survey-submit-lock.md
-- ============================================================


-- ============================================================
-- SECTION 1. 설정 테이블 (단일행 싱글톤)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.brand_survey_settings (
  id                integer PRIMARY KEY DEFAULT 1,
  submissions_open  boolean NOT NULL DEFAULT false,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT brand_survey_settings_singleton CHECK (id = 1)
);

COMMENT ON TABLE public.brand_survey_settings IS
  '[206] 브랜드 서베이 공개 제출 설정. 단일행 싱글톤(id=1). '
  'submissions_open=false(기본) = 공개 제출 차단. '
  'super_admin이 UPDATE로 임시 재개 가능.';

COMMENT ON COLUMN public.brand_survey_settings.submissions_open IS
  'true = 공개 제출 허용, false = 차단(기본). '
  '2단계(영업 토큰 발급 화면) 구현 후에는 이 컬럼 대신 토큰 검증으로 교체 예정.';

COMMENT ON COLUMN public.brand_survey_settings.updated_by IS
  '마지막으로 변경한 관리자 auth.uid(). 감사 목적.';


-- ============================================================
-- SECTION 2. 기본 데이터 (차단 상태로 시작, 멱등)
-- ============================================================

INSERT INTO public.brand_survey_settings (id, submissions_open)
VALUES (1, false)
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- SECTION 3. 행 단위 보안 정책(RLS)
-- ============================================================

ALTER TABLE public.brand_survey_settings ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만 (anon 접근 불가 — 함수가 SECURITY DEFINER로 내부에서 읽음)
DROP POLICY IF EXISTS "brand_survey_settings_select_admin" ON public.brand_survey_settings;
CREATE POLICY "brand_survey_settings_select_admin"
  ON public.brand_survey_settings
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- UPDATE: super_admin만
DROP POLICY IF EXISTS "brand_survey_settings_update_super_admin" ON public.brand_survey_settings;
CREATE POLICY "brand_survey_settings_update_super_admin"
  ON public.brand_survey_settings
  FOR UPDATE
  TO authenticated
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());

-- INSERT/DELETE: 허용 안 함 (단일행 싱글톤 — SQL Editor service_role 직접 조작만)


-- ============================================================
-- SECTION 4. submit_brand_application 함수 갱신
--            087 본문 기반 + 시작부 차단 가드(0단계) 추가
--            시그니처·SECURITY DEFINER·search_path·anon GRANT 유지
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

COMMENT ON FUNCTION public.submit_brand_application IS
  '[206] 광고주 신청 폼 제출 RPC. '
  '0단계 차단 가드(brand_survey_settings.submissions_open) 추가. '
  '차단 시 error.message=''submissions_closed'' (ERRCODE P0001) 반환. '
  'SECURITY DEFINER(BYPASSRLS). 반환: application_no(text). '
  'admin_create_brand_application(091)은 별개 — 이 가드 영향 없음. '
  'submit_orient_sheet(187)는 별개 함수 — 영향 없음.';


-- ============================================================
-- SECTION 4.5. 공개 제출 여부 조회 함수 (anon)
--   설정 테이블은 RLS로 anon SELECT 차단 → 폼(비로그인)이 직접 못 읽음.
--   이 함수로 open/closed 불리언만 노출(민감정보 없음) → 폼이 로드 시 분기:
--     false(차단) → 안내 화면 + 폼 숨김 / true(허용) → 정상 폼.
--   submissions_open 토글을 켜면 폼도 즉시 반영(정적 차단 아님).
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_brand_survey_open()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT COALESCE(
    (SELECT submissions_open FROM public.brand_survey_settings WHERE id = 1),
    false
  );
$$;

COMMENT ON FUNCTION public.is_brand_survey_open() IS
  '[206] 브랜드 서베이 공개 제출 허용 여부(boolean) 조회. anon 호출 가능. '
  'sales 폼이 로드 시 차단 안내 분기에 사용. 민감정보 미노출.';

REVOKE ALL ON FUNCTION public.is_brand_survey_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_brand_survey_open() TO anon, authenticated;


-- ============================================================
-- SECTION 5. 권한 재부여 (시그니처 동일, DROP 없이 REPLACE만 했으나 명시 재GRANT)
-- ============================================================

-- anon·authenticated 모두 호출 가능 유지 (087 원본과 동일)
-- 단, 함수 내부에서 차단 가드가 막음 — GRANT 자체를 줄이지 않음
--   이유: 2단계 전환 후 특정 authenticated 역할이 예외 없이 통과하도록 확장 용이
GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V1] 설정 테이블 확인 — submissions_open=false인 행 1개
SELECT id, submissions_open, updated_at
FROM public.brand_survey_settings;
-- 기대: id=1, submissions_open=false, 행 1개


-- [V2] 차단 상태에서 제출 시도 → 'submissions_closed' 에러 발생 확인
--      (ROLLBACK 불필요 — 차단이라 INSERT까지 진행 안 됨)
SELECT public.submit_brand_application(
  'reviewer',
  '차단테스트브랜드',
  '홍길동',
  '010-0000-0000',
  'block-test@example.com',
  '[{"name":"상품A","url":"https://example.com","price_jpy":1000,"qty":5}]'::jsonb
);
-- 기대: ERROR P0001 "submissions_closed" 발생
-- (supabase-js에서는 error.message === 'submissions_closed')


-- [V3] 임시 재개 후 제출 허용 확인 (ROLLBACK 필수)
BEGIN;

UPDATE public.brand_survey_settings
SET submissions_open = true, updated_at = now()
WHERE id = 1;

SELECT public.submit_brand_application(
  'reviewer',
  '재개테스트브랜드',
  '테스트담당',
  '010-0000-1111',
  'reopen-test@example.com',
  '[{"name":"상품B","url":"https://example.com","price_jpy":2000,"qty":3}]'::jsonb
);
-- 기대: application_no 반환 (JFUN-... 형식)

SELECT application_no, form_type, brand_name, source
FROM public.brand_applications
WHERE email = 'reopen-test@example.com'
ORDER BY created_at DESC
LIMIT 1;
-- 기대: 행 1개, source='online_form'

ROLLBACK;
-- 재개 상태가 롤백되어 다시 차단 상태로 복귀


-- [V4] transfer_fee 트리거(092/098) 동작 보존 확인 (재개 후, ROLLBACK 필수)
BEGIN;

UPDATE public.brand_survey_settings SET submissions_open = true WHERE id = 1;

SELECT public.submit_brand_application(
  'reviewer',
  '수수료테스트브랜드',
  '수수료담당',
  '010-0000-2222',
  'fee-test@example.com',
  '[{"name":"상품C","url":"https://example.com","price_jpy":3000,"qty":2}]'::jsonb
);

SELECT products
FROM public.brand_applications
WHERE email = 'fee-test@example.com'
ORDER BY created_at DESC
LIMIT 1;
-- 기대: products[0].transfer_fee_krw = 2500 (092/098 트리거 자동 채움)

ROLLBACK;


-- [V5] admin_create_brand_application(091) 무영향 확인
--      (이 함수는 별개 RPC라 brand_survey_settings를 읽지 않음)
SELECT proname, prosrc
FROM pg_proc
WHERE proname = 'admin_create_brand_application';
-- prosrc에 'brand_survey_settings' 문자열이 없어야 함


-- [V6] submit_orient_sheet(187) 무영향 확인
SELECT proname, prosrc
FROM pg_proc
WHERE proname = 'submit_orient_sheet';
-- prosrc에 'brand_survey_settings' 문자열이 없어야 함


-- [V7] 행 단위 보안 정책(RLS) 확인
SELECT policyname, cmd, roles
FROM pg_policies
WHERE tablename = 'brand_survey_settings';
-- 기대: 2개 정책 (select_admin, update_super_admin)

*/


-- ============================================================
-- 롤백 SQL (필요 시 SQL Editor에서 실행)
-- ============================================================
/*

-- 함수를 087 버전으로 되돌리기 (차단 가드 제거)
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
  v_brand_name_normalized text;
  v_brand_id              uuid;
  v_note                  text;
  v_no                    text;
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
  v_brand_name_normalized :=
    lower(trim(regexp_replace(p_brand_name, '\s+', ' ', 'g')));
  SELECT id INTO v_brand_id
  FROM public.brands
  WHERE name_normalized = v_brand_name_normalized
  LIMIT 1;
  IF v_brand_id IS NULL THEN
    INSERT INTO public.brands (
      name, primary_contact_name, primary_phone, primary_email,
      billing_email, contacts, status
    ) VALUES (
      p_brand_name, p_contact_name, p_phone, p_email, p_billing_email,
      jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text, 'name', p_contact_name,
        'phone', p_phone, 'email', p_email, 'is_primary', true
      )),
      'active'
    )
    RETURNING id INTO v_brand_id;
  END IF;
  v_note := NULLIF(btrim(COALESCE(p_request_note, '')), '');
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    v_note := substring(v_note FROM 1 FOR 1000);
  END IF;
  INSERT INTO public.brand_applications (
    application_no, form_type,
    brand_name, contact_name, phone, email, billing_email,
    brand_id, source, applicant_contact_name, applicant_phone, applicant_email,
    products, request_note
  ) VALUES (
    '', p_form_type,
    p_brand_name, p_contact_name, p_phone, p_email, p_billing_email,
    v_brand_id, 'online_form', p_contact_name, p_phone, p_email,
    p_products, v_note
  )
  RETURNING application_no INTO v_no;
  RETURN v_no;
END;
$$;

COMMENT ON FUNCTION public.submit_brand_application IS
  '[087-rollback] 광고주 신청 폼 제출 RPC. 차단 가드 제거(206 롤백용).';

GRANT EXECUTE ON FUNCTION public.submit_brand_application(
  text, text, text, text, text, jsonb, text, text, text
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- 설정 테이블 제거 (필요 시만 — 데이터 남겨도 무방)
-- DROP TABLE IF EXISTS public.brand_survey_settings;

*/
