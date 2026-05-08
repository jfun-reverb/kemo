-- ============================================================
-- 102_brand_app_reviewer_channels.sql
-- 브랜드 서베이 리뷰어 채널 서브타입 (큐텐/엣코스메) 컬럼 추가
--
-- 목적:
--   리뷰어 폼은 큐텐·엣코스메 중 어느 플랫폼을 대상으로 하는지
--   복수 선택이 가능하도록 reviewer_channels text[] 컬럼을 추가한다.
--   시딩 폼은 이 필드와 무관하므로 항상 NULL.
--   기존 신청 데이터는 NULL 유지 (영업팀 필요 시 수동 입력).
--
-- 변경 범위:
--   (1) brand_applications.reviewer_channels text[] 컬럼 추가
--   (2) CHECK 제약(이하 조건을 검사하는 규칙) 2가지 통합 등록
--       - 시딩 폼 또는 form_type NULL → reviewer_channels IS NULL 강제
--       - 리뷰어 폼 → NULL 허용 또는 배열 길이 1~2 이고
--         요소가 'qoo10' / 'atcosme' 부분집합
--   (3) admin_create_brand_application 원격 호출 함수(RPC) 갱신
--       - p_reviewer_channels text[] DEFAULT NULL 파라미터 추가
--       - 시딩 폼이면 NULL 강제, 리뷰어 폼이면 그대로 저장
--       - 기존 14개 파라미터 호출자(클라이언트)와 호환 (DEFAULT NULL이므로 기존 호출 그대로 동작)
--   (4) submit_brand_application RPC (sales 폼 전용) — 미수정
--       sales 폼에서 reviewer_channels를 수집하지 않으므로 항상 NULL INSERT
--   (5) GIN 인덱스(배열 검색용 인덱스): 향후 채널별 필터링 대비
--
-- 허용 값:
--   'qoo10'   — 큐텐 재팬
--   'atcosme' — 엣코스메
--
-- 전제:
--   - 091: admin_create_brand_application v3(14 params) 존재
--
-- 작성일: 2026-05-08
-- ============================================================


-- ============================================================
-- SECTION 1. 컬럼 추가
--   DEFAULT NULL: 기존 행과 시딩 폼 모두 NULL로 보존
-- ============================================================
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS reviewer_channels text[] DEFAULT NULL;

COMMENT ON COLUMN public.brand_applications.reviewer_channels IS
  '[102] 리뷰어 폼 전용 채널 서브타입. 허용값: qoo10 / atcosme. 시딩 폼은 항상 NULL. 관리자 직접 등록 모달에서 체크박스로 입력. sales 폼(submit_brand_application)은 수집 안 함.';


-- ============================================================
-- SECTION 2. CHECK 제약 (조건 검사 규칙) 등록
--   제약명: brand_applications_reviewer_channels_chk
--
--   규칙 (두 가지를 AND로 결합):
--     A. 리뷰어 폼이 아닌 경우(시딩·NULL 포함) → reviewer_channels IS NULL
--     B. 리뷰어 폼이고 reviewer_channels가 있으면
--        → 배열 길이 1~2 이고 요소가 모두 'qoo10' 또는 'atcosme'
--
--   논리 전개:
--     A: NOT (form_type = 'reviewer')  →  reviewer_channels IS NULL
--        ≡ form_type = 'reviewer' OR reviewer_channels IS NULL
--     B: form_type = 'reviewer' AND reviewer_channels IS NOT NULL
--        →  array_length(...) BETWEEN 1 AND 2
--           AND (reviewer_channels <@ ARRAY['qoo10','atcosme'])
--           (reviewer_channels <@ arr: reviewer_channels의 모든 요소가 arr 안에 있음)
--
--   두 조건을 하나로:
--     (form_type = 'reviewer' OR reviewer_channels IS NULL)
--     AND
--     (reviewer_channels IS NULL
--       OR (
--            array_length(reviewer_channels, 1) BETWEEN 1 AND 2
--            AND reviewer_channels <@ ARRAY['qoo10', 'atcosme']
--          )
--     )
-- ============================================================
ALTER TABLE public.brand_applications
  DROP CONSTRAINT IF EXISTS brand_applications_reviewer_channels_chk;

ALTER TABLE public.brand_applications
  ADD CONSTRAINT brand_applications_reviewer_channels_chk
  CHECK (
    -- 조건 A: 리뷰어 폼이 아닐 때 reviewer_channels는 반드시 NULL
    (form_type = 'reviewer' OR reviewer_channels IS NULL)
    AND
    -- 조건 B: reviewer_channels가 있으면 배열 길이 1~2 + 허용 요소만 포함
    (
      reviewer_channels IS NULL
      OR (
        array_length(reviewer_channels, 1) BETWEEN 1 AND 2
        AND reviewer_channels <@ ARRAY['qoo10', 'atcosme']::text[]
      )
    )
  );


-- ============================================================
-- SECTION 3. GIN 인덱스 (배열 검색용)
--   향후 관리자 목록에서 채널 필터 추가 시 속도 보장.
--   reviewer_channels가 NULL인 행(시딩·기존 데이터)은 인덱스에 포함되지 않으므로
--   인덱스 크기는 실제 사용 행에 한정됨.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_brand_applications_reviewer_channels
  ON public.brand_applications
  USING GIN (reviewer_channels)
  WHERE reviewer_channels IS NOT NULL;


-- ============================================================
-- SECTION 4. admin_create_brand_application RPC 갱신
--
--   변경 내용:
--     - p_reviewer_channels text[] DEFAULT NULL 파라미터 추가 (15번째 파라미터)
--     - 시딩 폼이면 NULL 강제 (CHECK 제약 위반 방지)
--     - 리뷰어 폼이면 그대로 INSERT
--     - 기존 14개 파라미터 호출은 p_reviewer_channels가 DEFAULT NULL로
--       처리되므로 클라이언트 수정 없이 계속 동작함
--
--   유지:
--     - SECURITY DEFINER + SET search_path = '' 그대로
--     - is_admin() 권한 가드 그대로
--     - brand 처리 로직(3-A 기존 brand / 3-B 신규 brand) 그대로
--     - 반환값 jsonb {id, application_no, brand_id, brand_no} 그대로
-- ============================================================

-- 기존 함수 DROP (파라미터 수가 달라지면 CREATE OR REPLACE 에러 발생)
-- v3 (14 params): 091에서 등록된 현재 버전
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean
);
-- 혹시 이전 버전이 남아있을 때를 위한 방어적 정리 (멱등)
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, jsonb, text, boolean
);
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, jsonb, text, boolean
);
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, boolean
);

CREATE OR REPLACE FUNCTION public.admin_create_brand_application(
  p_form_type           text,
  p_brand_id            uuid        DEFAULT NULL,
  p_company_name        text        DEFAULT NULL,   -- 회사 법인명 (선택)
  p_brand_name          text        DEFAULT NULL,
  p_brand_name_ja       text        DEFAULT NULL,   -- 브랜드명 일본어 (선택)
  p_business_no         text        DEFAULT NULL,   -- 사업자번호 (선택)
  p_contact_name        text        DEFAULT NULL,
  p_phone               text        DEFAULT NULL,
  p_email               text        DEFAULT NULL,
  p_billing_email       text        DEFAULT NULL,
  p_products            jsonb       DEFAULT '[]'::jsonb,
  p_request_note        text        DEFAULT NULL,
  p_admin_memo          text        DEFAULT NULL,   -- 등록 시점 내부 메모 (선택)
  p_brand_sync          boolean     DEFAULT true,
  p_reviewer_channels   text[]      DEFAULT NULL    -- [102] 리뷰어 채널 서브타입 (선택)
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
  v_reviewer_channels     text[];  -- [102] 최종 저장할 채널값
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
  -- 2-B. [102] reviewer_channels 검증 및 정규화
  --   - 시딩 폼이면 NULL 강제 (CHECK 제약 위반 선제 차단)
  --   - 리뷰어 폼이고 채널이 지정됐으면 허용값 검증
  -- ──────────────────────────────────────────────────────────
  IF p_form_type <> 'reviewer' THEN
    -- 시딩 폼: 입력값 무시, NULL로 강제
    v_reviewer_channels := NULL;
  ELSE
    -- 리뷰어 폼
    IF p_reviewer_channels IS NULL THEN
      v_reviewer_channels := NULL;
    ELSE
      -- 배열 길이 1~2 확인
      IF array_length(p_reviewer_channels, 1) NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION '[admin_create_brand_application] reviewer_channels 배열 길이는 1~2개여야 합니다. 입력값: %', p_reviewer_channels
          USING ERRCODE = '22023';
      END IF;
      -- 허용 요소 확인 (qoo10 / atcosme 만 허용)
      IF NOT (p_reviewer_channels <@ ARRAY['qoo10', 'atcosme']::text[]) THEN
        RAISE EXCEPTION '[admin_create_brand_application] reviewer_channels 허용값: qoo10, atcosme. 입력값: %', p_reviewer_channels
          USING ERRCODE = '22023';
      END IF;
      v_reviewer_channels := p_reviewer_channels;
    END IF;
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

    -- 3-A-i. brand 마스터 동기 갱신 (p_brand_sync=true, 연락처/브랜드명_ja/사업자번호 변경 시)
    --   primary_* 컬럼 + contacts[is_primary=true] + name_ja + business_no 동시 갱신
    --   p_brand_name은 기존 brand 이름 변경에 사용하지 않음 (brand 페인에서 직접 수정)
    IF p_brand_sync AND (
         COALESCE(btrim(p_contact_name), '') <> ''
      OR COALESCE(btrim(p_phone), '')        <> ''
      OR COALESCE(btrim(p_email), '')        <> ''
      OR COALESCE(btrim(p_brand_name_ja), '') <> ''
      OR COALESCE(btrim(p_business_no), '')   <> ''
      OR COALESCE(btrim(p_company_name), '')  <> ''
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
        -- contacts에 is_primary=true 항목 없음 → 신규 항목 추가
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
  --    - reviewer_channels: [102] 리뷰어 채널 서브타입 (시딩이면 NULL, 리뷰어이면 v_reviewer_channels)
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
    admin_memo,
    status,
    -- [102] 리뷰어 채널 서브타입
    reviewer_channels
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
    NULLIF(btrim(COALESCE(p_admin_memo, '')), ''),       -- 등록 시점 내부 메모
    'new',
    -- [102]
    v_reviewer_channels
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
  '[091+102] 관리자 직접 광고주 신청 등록 원격 호출 함수(RPC). SECURITY DEFINER + is_admin() 가드. brand_id 지정 시 기존 brand 사용 + 연락처 동기 갱신, NULL 시 신규 brand INSERT (name_normalized 중복이면 기존 재사용). source=manual_admin, intake_admin_id=auth.uid(). [102] p_reviewer_channels: 리뷰어 폼 전용 채널 서브타입(qoo10/atcosme), 시딩 폼이면 NULL 강제. 반환: {id, application_no, brand_id, brand_no}.';


-- ============================================================
-- SECTION 5. GRANT (권한 설정)
--   authenticated: EXECUTE 허용 (내부 is_admin() 가드로 관리자만 통과)
--   anon: 거부 (submit_brand_application이 anon용)
--
--   시그니처: 15 파라미터 (091의 14개 + p_reviewer_channels text[])
-- ============================================================
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean, text[]
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean, text[]
) FROM anon;

GRANT EXECUTE ON FUNCTION public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean, text[]
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
-- [V1] 컬럼 추가 확인
-- ────────────────────────────────────────────────────────────
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'brand_applications'
  AND column_name  = 'reviewer_channels';
-- column_name=reviewer_channels, data_type=ARRAY, is_nullable=YES 반환되어야 함


-- ────────────────────────────────────────────────────────────
-- [V2] CHECK 제약(조건 검사 규칙) 등록 확인
-- ────────────────────────────────────────────────────────────
SELECT conname, pg_get_constraintdef(oid) AS constraint_def
FROM pg_constraint
WHERE conrelid = 'public.brand_applications'::regclass
  AND conname  = 'brand_applications_reviewer_channels_chk';
-- conname: brand_applications_reviewer_channels_chk
-- constraint_def에 form_type / reviewer_channels / qoo10 / atcosme 포함되어야 함


-- ────────────────────────────────────────────────────────────
-- [V3] 시딩 폼에 reviewer_channels 삽입 → 실패 확인
-- ────────────────────────────────────────────────────────────
BEGIN;
INSERT INTO public.brand_applications (
  application_no, form_type, brand_name,
  products, status,
  reviewer_channels  -- 시딩 폼에 채널 지정 → CHECK 위반
)
VALUES (
  'TEST-FAIL-001',
  'seeding',
  '시딩폼제약테스트',
  '[{"name":"P1","price_jpy":1000,"qty":1}]'::jsonb,
  'new',
  ARRAY['qoo10']::text[]
);
-- ERROR: new row for relation "brand_applications" violates check constraint
--        "brand_applications_reviewer_channels_chk"
ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V4] 리뷰어 폼에 허용 채널 2개 삽입 → 성공 확인 (테스트 후 DELETE)
-- ────────────────────────────────────────────────────────────
BEGIN;
INSERT INTO public.brand_applications (
  application_no, form_type, brand_name,
  products, status,
  reviewer_channels
)
VALUES (
  'TEST-OK-001',
  'reviewer',
  '리뷰어폼채널테스트',
  '[{"name":"P1","price_jpy":1000,"qty":1}]'::jsonb,
  'new',
  ARRAY['qoo10', 'atcosme']::text[]
)
RETURNING application_no, form_type, reviewer_channels;
-- application_no=TEST-OK-001, reviewer_channels={qoo10,atcosme} 반환되어야 함
ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V5] 허용되지 않은 채널값 삽입 → 실패 확인
-- ────────────────────────────────────────────────────────────
BEGIN;
INSERT INTO public.brand_applications (
  application_no, form_type, brand_name,
  products, status,
  reviewer_channels
)
VALUES (
  'TEST-FAIL-002',
  'reviewer',
  '잘못된채널테스트',
  '[{"name":"P1","price_jpy":1000,"qty":1}]'::jsonb,
  'new',
  ARRAY['invalid']::text[]  -- 허용값 아님
);
-- ERROR: new row for relation "brand_applications" violates check constraint
--        "brand_applications_reviewer_channels_chk"
ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V6] 리뷰어 폼 NULL → 성공 확인 (기존 데이터 호환)
-- ────────────────────────────────────────────────────────────
BEGIN;
INSERT INTO public.brand_applications (
  application_no, form_type, brand_name,
  products, status,
  reviewer_channels
)
VALUES (
  'TEST-OK-002',
  'reviewer',
  '리뷰어NULL테스트',
  '[{"name":"P1","price_jpy":1000,"qty":1}]'::jsonb,
  'new',
  NULL
)
RETURNING application_no, form_type, reviewer_channels;
-- reviewer_channels=NULL 정상 삽입 확인
ROLLBACK;


-- ────────────────────────────────────────────────────────────
-- [V7] GIN 인덱스 등록 확인
-- ────────────────────────────────────────────────────────────
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'brand_applications'
  AND indexname = 'idx_brand_applications_reviewer_channels';
-- 1행 반환, GIN 포함되어야 함


-- ────────────────────────────────────────────────────────────
-- [V8] 원격 호출 함수(RPC) 갱신 확인 — 파라미터 15개
-- ────────────────────────────────────────────────────────────
SELECT
  p.proname,
  pg_get_function_arguments(p.oid) AS args,
  pg_get_function_result(p.oid)    AS ret
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'admin_create_brand_application';
-- args에 p_reviewer_channels text[] 마지막 파라미터 포함 확인
-- ret = jsonb


-- ────────────────────────────────────────────────────────────
-- [V9] GRANT 확인 (anon 거부, authenticated 허용)
-- ────────────────────────────────────────────────────────────
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name   = 'admin_create_brand_application'
ORDER BY grantee;
-- authenticated: EXECUTE
-- anon: 없음 (거부)

*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

-- STEP 1. 원격 호출 함수(RPC) v102 → v091 복구
--   아래 DROP 후 091_admin_create_brand_application.sql 을 다시 실행.
DROP FUNCTION IF EXISTS public.admin_create_brand_application(
  text, uuid, text, text, text, text, text, text, text, text, jsonb, text, text, boolean, text[]
);

-- STEP 2. GIN 인덱스 제거
DROP INDEX IF EXISTS public.idx_brand_applications_reviewer_channels;

-- STEP 3. CHECK 제약(조건 검사 규칙) 제거
ALTER TABLE public.brand_applications
  DROP CONSTRAINT IF EXISTS brand_applications_reviewer_channels_chk;

-- STEP 4. 컬럼 제거
--   ※ reviewer_channels에 데이터가 이미 입력된 행이 있으면 DROP 전에 NULL로 초기화 권장
UPDATE public.brand_applications SET reviewer_channels = NULL;
ALTER TABLE public.brand_applications DROP COLUMN IF EXISTS reviewer_channels;

-- STEP 5. 091 함수 복구 (SQL Editor에서 091 파일 내용 붙여넣어 재실행)

NOTIFY pgrst, 'reload schema';

*/
