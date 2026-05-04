-- ============================================================
-- 083_brands_data_migration.sql
-- 기존 brand_applications 데이터를 brands 마스터로 추출 + 역참조 채우기
--
-- 목적:
--   PR1(082)에서 만든 brands 테이블에 기존 brand_applications 데이터를 채운다.
--
--   전제:
--     - brands 테이블, 채번/정규화/updated_at 트리거 존재 (082 적용 완료)
--     - brand_applications에 brand_id, applicant_* 컬럼 존재 (082 적용 완료)
--
--   Pre-flight 결과 (2026-05-04 확인):
--     - 동일 정규화 키 그룹 없음 (23 신청 = 23 unique brand_name)
--     - 수동 분리 필요 케이스 0건
--     - 자동 마이그레이션 안전
--
--   이 마이그레이션은 데이터만 채운다.
--   - 스키마 변경 없음 (코드 변경 없이 DB만 적용 가능)
--   - 클라이언트는 PR3에서 brands 활용 예정
--
-- 작성일: 2026-05-04
-- ============================================================


BEGIN;


-- ============================================================
-- STEP 1: brands 행 자동 생성
--
--   DISTINCT normalized brand_name 별로 brands INSERT.
--   그룹 내 가장 최근 신청(max created_at)의 contact_name/phone/email/billing_email
--   을 primary_* 으로 사용.
--
--   트리거 동작 순서 (BEFORE INSERT):
--     1. trg_brand_name_normalized → NEW.name_normalized 자동 계산
--     2. trg_brand_no             → NEW.brand_no(BR-YYYY-NNNN) 자동 채번
--   따라서 name 만 제공하면 brand_no / name_normalized 자동 완성.
--
--   brands.total_applications / first_applied_at / last_applied_at 은
--   STEP 2에서 brand_id 채운 뒤 sync_brand_application_stats 트리거가
--   자동 갱신하므로 여기선 직접 집계값을 넣어 초기화한다
--   (STEP 2 이전에 트리거가 발동되지 않으므로 직접 계산).
-- ============================================================
INSERT INTO public.brands (
  name,
  primary_contact_name,
  primary_phone,
  primary_email,
  billing_email,
  status,
  total_applications,
  first_applied_at,
  last_applied_at,
  created_by
)
SELECT
  -- 그룹 내 brand_name 원본 중 가장 최근 신청에서 가져옴
  DISTINCT ON (lower(trim(regexp_replace(brand_name, '\s+', ' ', 'g'))))
  brand_name                                        AS name,
  contact_name                                      AS primary_contact_name,
  phone                                             AS primary_phone,
  email                                             AS primary_email,
  billing_email                                     AS billing_email,
  'active'                                          AS status,
  -- 집계: STEP 2 이전이므로 직접 계산
  (
    SELECT count(*)::integer
    FROM public.brand_applications ba2
    WHERE lower(trim(regexp_replace(ba2.brand_name, '\s+', ' ', 'g')))
          = lower(trim(regexp_replace(ba.brand_name, '\s+', ' ', 'g')))
  )                                                 AS total_applications,
  (
    SELECT min(ba3.created_at)
    FROM public.brand_applications ba3
    WHERE lower(trim(regexp_replace(ba3.brand_name, '\s+', ' ', 'g')))
          = lower(trim(regexp_replace(ba.brand_name, '\s+', ' ', 'g')))
  )                                                 AS first_applied_at,
  (
    SELECT max(ba4.created_at)
    FROM public.brand_applications ba4
    WHERE lower(trim(regexp_replace(ba4.brand_name, '\s+', ' ', 'g')))
          = lower(trim(regexp_replace(ba.brand_name, '\s+', ' ', 'g')))
  )                                                 AS last_applied_at,
  NULL::uuid                                        AS created_by   -- legacy: 수동 등록 아님
FROM public.brand_applications ba
ORDER BY
  lower(trim(regexp_replace(brand_name, '\s+', ' ', 'g'))),  -- DISTINCT ON 키
  ba.created_at DESC;                                          -- 최신 신청을 대표로 선택


-- ============================================================
-- STEP 2: brand_applications 역참조 채우기
--
--   name_normalized 로 brands 조회해서 brand_id 연결.
--   applicant_* 컬럼은 신청 시점 담당자 정보를 그대로 복사
--   (brands.primary_* 와 달리 신청별 스냅샷 보존 목적).
--   source 는 DEFAULT 'online_form' 이 이미 적용되어 변경 불필요.
--   intake_admin_id 는 NULL (legacy — online_form 경로).
-- ============================================================
UPDATE public.brand_applications ba
SET
  brand_id               = b.id,
  applicant_contact_name = ba.contact_name,
  applicant_phone        = ba.phone,
  applicant_email        = ba.email
FROM public.brands b
WHERE b.name_normalized =
      lower(trim(regexp_replace(ba.brand_name, '\s+', ' ', 'g')));


-- ============================================================
-- STEP 3: 인라인 검증 (트랜잭션 내부 — 실패 시 전체 롤백)
-- ============================================================

-- [V1] brand_applications 중 brand_id 가 NULL인 건 = 0
DO $$
DECLARE
  v_null_count integer;
BEGIN
  SELECT count(*) INTO v_null_count
  FROM public.brand_applications
  WHERE brand_id IS NULL;

  IF v_null_count > 0 THEN
    RAISE EXCEPTION '[083] 검증 실패 V1: brand_applications.brand_id NULL 건 = % (0 이어야 함)', v_null_count;
  END IF;
END;
$$;

-- [V2] brands.total_applications 합 = brand_applications 전체 건수
DO $$
DECLARE
  v_brands_sum  bigint;
  v_apps_count  bigint;
BEGIN
  SELECT COALESCE(sum(total_applications), 0) INTO v_brands_sum
  FROM public.brands;

  SELECT count(*) INTO v_apps_count
  FROM public.brand_applications;

  IF v_brands_sum <> v_apps_count THEN
    RAISE EXCEPTION '[083] 검증 실패 V2: brands.total_applications 합(%) ≠ brand_applications 건수(%)',
      v_brands_sum, v_apps_count;
  END IF;
END;
$$;

-- [V3] applicant_contact_name 이 NULL인 건이 brand_applications 내 contact_name이 NULL인 건과 동일
DO $$
DECLARE
  v_applicant_null integer;
  v_contact_null   integer;
BEGIN
  SELECT count(*) INTO v_applicant_null
  FROM public.brand_applications
  WHERE applicant_contact_name IS NULL;

  SELECT count(*) INTO v_contact_null
  FROM public.brand_applications
  WHERE contact_name IS NULL;

  IF v_applicant_null <> v_contact_null THEN
    RAISE EXCEPTION '[083] 검증 실패 V3: applicant_contact_name NULL(%) ≠ contact_name NULL(%)',
      v_applicant_null, v_contact_null;
  END IF;
END;
$$;

-- [V4] brands 행 수 = brand_applications 내 distinct normalized brand_name 수
DO $$
DECLARE
  v_brands_count   integer;
  v_distinct_count integer;
BEGIN
  SELECT count(*) INTO v_brands_count FROM public.brands;

  SELECT count(DISTINCT lower(trim(regexp_replace(brand_name, '\s+', ' ', 'g'))))
  INTO v_distinct_count
  FROM public.brand_applications;

  IF v_brands_count <> v_distinct_count THEN
    RAISE EXCEPTION '[083] 검증 실패 V4: brands 행 수(%) ≠ distinct normalized brand_name(%)',
      v_brands_count, v_distinct_count;
  END IF;
END;
$$;


COMMIT;


-- ============================================================
-- 사후 검증 SQL (COMMIT 후 SQL Editor에서 별도 실행)
-- ============================================================
/*
-- [1] brand_id NULL 잔존 확인 (0이어야 함)
SELECT count(*) AS null_brand_id
FROM public.brand_applications
WHERE brand_id IS NULL;

-- [2] brands 집계 일치 확인
SELECT
  b.brand_no,
  b.name,
  b.total_applications,
  count(ba.id)                 AS actual_count,
  b.first_applied_at::date     AS first_date,
  min(ba.created_at)::date     AS actual_first,
  b.last_applied_at::date      AS last_date,
  max(ba.created_at)::date     AS actual_last
FROM public.brands b
JOIN public.brand_applications ba ON ba.brand_id = b.id
GROUP BY b.id
ORDER BY b.brand_no;

-- [3] applicant_* 채움 확인 (샘플 5건)
SELECT
  ba.application_no,
  ba.brand_id IS NOT NULL       AS has_brand_id,
  ba.applicant_contact_name,
  ba.applicant_phone,
  ba.applicant_email,
  ba.source
FROM public.brand_applications ba
ORDER BY ba.created_at DESC
LIMIT 5;

-- [4] brands 채번 결과 확인
SELECT brand_no, name, name_normalized, status, total_applications
FROM public.brands
ORDER BY brand_no;

-- [5] brands_yearly_counter 확인 (BR- 채번 시작된 연도 행 존재)
SELECT * FROM public.brands_yearly_counter ORDER BY year;
*/


-- ============================================================
-- 롤백 SQL (문제 발생 시 역순으로 실행)
--
-- ※ 이 마이그레이션은 BEGIN..COMMIT 트랜잭션이므로
--    COMMIT 전 오류 시 자동 롤백됨.
--    COMMIT 후 수동 롤백이 필요한 경우 아래 실행:
-- ============================================================
/*
BEGIN;

-- STEP A: brand_applications 역참조 초기화
UPDATE public.brand_applications
SET
  brand_id               = NULL,
  applicant_contact_name = NULL,
  applicant_phone        = NULL,
  applicant_email        = NULL;
-- source = 'online_form' 은 DEFAULT값이므로 그대로 유지 (변경 없었음)
-- intake_admin_id 는 NULL 이었으므로 그대로 유지

-- STEP B: brands 행 전체 삭제 (brand_id=NULL 로 바꾼 뒤에야 RESTRICT FK 제거 가능)
DELETE FROM public.brands;

-- STEP C: 채번 카운터 초기화 (BR-YYYY 행 삭제)
DELETE FROM public.brands_yearly_counter;

COMMIT;

NOTIFY pgrst, 'reload schema';
*/
