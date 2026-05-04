-- ============================================================
-- 090_hierarchical_numbering_triggers.sql
-- 계층 채번 시스템 — 트리거 재설계
--
-- 목적:
--   신규 INSERT 시 계층 번호를 자동으로 생성하는 트리거를 설치한다.
--
--   generate_brand_application_no():
--     brand_id 필수. 없으면 RAISE EXCEPTION.
--     brand_application_counter UPSERT + last_seq+1
--     application_no = B{brand_seq}-A{seq}
--
--   generate_campaign_no():
--     source_application_id NOT NULL → application_campaign_counter
--       campaign_no = B{brand_seq}-A{app_seq}-C{camp_seq}
--     source_application_id NULL + brand_id NOT NULL → brand_external_campaign_counter
--       campaign_no = B{brand_seq}-C{ext_seq}
--     brand_id NULL → 기존 CAMP-YYYY-NNNN 포맷 유지 (캠페인 자동 할당 예외)
--
--   동시성:
--     pg_advisory_xact_lock(hashtext(brand_id::text)) 으로 동일 브랜드 내
--     동시 INSERT가 카운터를 중복으로 증가시키는 것을 방지.
--     (ON CONFLICT DO UPDATE만으로는 동시 트랜잭션 간 충돌 가능)
--
-- 전제:
--   - 088 적용 완료 (카운터 테이블 / FK 컬럼 존재)
--   - 089 적용 완료 (기존 데이터 재채번, 카운터 동기화)
--   - 084 적용 완료 (SECURITY DEFINER 함수 PUBLIC EXECUTE 권한 정리)
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- SECTION 1. generate_brand_application_no() 트리거 함수 교체
--   078 버전(JFUN-{R|S}-YYMMDD-NNN)을 완전히 대체.
-- ============================================================

CREATE OR REPLACE FUNCTION public.generate_brand_application_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_brand_seq integer;
  v_app_seq   integer;
BEGIN
  -- 이미 채번된 값 있으면 덮어쓰지 않음 (수동 지정 안전장치)
  IF NEW.application_no IS NOT NULL AND NEW.application_no <> '' THEN
    RETURN NEW;
  END IF;

  -- brand_id 필수 검증
  IF NEW.brand_id IS NULL THEN
    RAISE EXCEPTION '[generate_brand_application_no] brand_id is required for application_no generation'
      USING ERRCODE = '23502';
  END IF;

  -- 동일 브랜드 내 동시 INSERT 직렬화
  -- hashtext(brand_id::text)는 bigint → pg_advisory_xact_lock(bigint)
  PERFORM pg_advisory_xact_lock(hashtext(NEW.brand_id::text)::bigint);

  -- brands.brand_seq 조회
  SELECT brand_seq INTO v_brand_seq
  FROM public.brands
  WHERE id = NEW.brand_id;

  IF v_brand_seq IS NULL THEN
    RAISE EXCEPTION '[generate_brand_application_no] brands.brand_seq is NULL for brand_id=%', NEW.brand_id
      USING ERRCODE = '22023';
  END IF;

  -- brand_application_counter atomic 증가
  INSERT INTO public.brand_application_counter (brand_id, last_seq)
  VALUES (NEW.brand_id, 1)
  ON CONFLICT (brand_id)
  DO UPDATE SET last_seq = public.brand_application_counter.last_seq + 1
  RETURNING last_seq INTO v_app_seq;

  -- A999 초과 방지
  IF v_app_seq > 999 THEN
    RAISE EXCEPTION '[generate_brand_application_no] A-seq overflow (>999) for brand_id=%', NEW.brand_id
      USING ERRCODE = '22003';
  END IF;

  -- B0001-A001
  NEW.application_no :=
    'B' || lpad(v_brand_seq::text, 4, '0')
    || '-A' || lpad(v_app_seq::text, 3, '0');

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_application_no IS
  '[090] brand_applications BEFORE INSERT 트리거. brand_id 기준 계층 번호 B{B}-A{seq} 생성. 078 버전(JFUN-R/S) 대체. advisory lock으로 동시 INSERT 직렬화.';

-- 권한 정리 (084 패턴 유지 — 트리거 전용이므로 CLIENT 호출 불가)
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM anon;

-- 트리거는 BEFORE INSERT에만 (078과 동일 이름, 재사용)
DROP TRIGGER IF EXISTS trg_brand_app_no ON public.brand_applications;
CREATE TRIGGER trg_brand_app_no
  BEFORE INSERT ON public.brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.generate_brand_application_no();


-- ============================================================
-- SECTION 2. generate_campaign_no() 트리거 함수 교체
--   055 버전(CAMP-YYYY-NNNN)을 대체.
--   brand_id + source_application_id 조합에 따라 3가지 분기.
-- ============================================================

CREATE OR REPLACE FUNCTION public.generate_campaign_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_brand_seq integer;
  v_app_seq   integer;
  v_camp_seq  integer;
  v_ext_seq   integer;
  v_app_no    text;
  v_year      integer;  -- 분기 C (brand_id NULL 폴백) 전용
  v_year_seq  integer;  -- 분기 C 전용
BEGIN
  -- 이미 채번된 값 있으면 덮어쓰지 않음
  IF NEW.campaign_no IS NOT NULL AND NEW.campaign_no <> '' THEN
    RETURN NEW;
  END IF;

  -- ──────────────────────────────────────────────────────────
  -- 분기 A: source_application_id NOT NULL (신청 파생 캠페인)
  --   채번: B{brand_seq}-A{app_seq}-C{camp_seq}
  -- ──────────────────────────────────────────────────────────
  IF NEW.source_application_id IS NOT NULL THEN

    IF NEW.brand_id IS NULL THEN
      RAISE EXCEPTION '[generate_campaign_no] brand_id required when source_application_id is set'
        USING ERRCODE = '23502';
    END IF;

    -- 동일 신청 내 동시 INSERT 직렬화
    PERFORM pg_advisory_xact_lock(hashtext(NEW.source_application_id::text)::bigint);

    -- brand_seq 조회
    SELECT brand_seq INTO v_brand_seq
    FROM public.brands
    WHERE id = NEW.brand_id;

    IF v_brand_seq IS NULL THEN
      RAISE EXCEPTION '[generate_campaign_no] brands.brand_seq NULL for brand_id=%', NEW.brand_id
        USING ERRCODE = '22023';
    END IF;

    -- application_no에서 A 세그먼트 파싱
    SELECT application_no INTO v_app_no
    FROM public.brand_applications
    WHERE id = NEW.source_application_id;

    -- B0001-A001 형식에서 '001' 추출
    IF v_app_no SIMILAR TO 'B[0-9]{4}-A[0-9]{3}' THEN
      v_app_seq := split_part(v_app_no, '-A', 2)::integer;
    ELSE
      RAISE EXCEPTION '[generate_campaign_no] application_no format unexpected: %', v_app_no
        USING ERRCODE = '22023';
    END IF;

    -- application_campaign_counter atomic 증가
    INSERT INTO public.application_campaign_counter (application_id, last_seq)
    VALUES (NEW.source_application_id, 1)
    ON CONFLICT (application_id)
    DO UPDATE SET last_seq = public.application_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_camp_seq;

    IF v_camp_seq > 999 THEN
      RAISE EXCEPTION '[generate_campaign_no] C-seq overflow (>999) for application_id=%', NEW.source_application_id
        USING ERRCODE = '22003';
    END IF;

    -- B0001-A001-C001
    NEW.campaign_no :=
      'B' || lpad(v_brand_seq::text, 4, '0')
      || '-A' || lpad(v_app_seq::text, 3, '0')
      || '-C' || lpad(v_camp_seq::text, 3, '0');

    RETURN NEW;
  END IF;

  -- ──────────────────────────────────────────────────────────
  -- 분기 B: source_application_id NULL + brand_id NOT NULL (외부 캠페인)
  --   채번: B{brand_seq}-C{ext_seq}
  -- ──────────────────────────────────────────────────────────
  IF NEW.brand_id IS NOT NULL THEN

    -- 동일 브랜드 내 동시 INSERT 직렬화
    PERFORM pg_advisory_xact_lock(hashtext(NEW.brand_id::text)::bigint);

    SELECT brand_seq INTO v_brand_seq
    FROM public.brands
    WHERE id = NEW.brand_id;

    IF v_brand_seq IS NULL THEN
      RAISE EXCEPTION '[generate_campaign_no] brands.brand_seq NULL for brand_id=%', NEW.brand_id
        USING ERRCODE = '22023';
    END IF;

    -- brand_external_campaign_counter atomic 증가
    INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
    VALUES (NEW.brand_id, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_external_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_ext_seq;

    IF v_ext_seq > 999 THEN
      RAISE EXCEPTION '[generate_campaign_no] ext-C-seq overflow (>999) for brand_id=%', NEW.brand_id
        USING ERRCODE = '22003';
    END IF;

    -- B0001-C001
    NEW.campaign_no :=
      'B' || lpad(v_brand_seq::text, 4, '0')
      || '-C' || lpad(v_ext_seq::text, 3, '0');

    RETURN NEW;
  END IF;

  -- ──────────────────────────────────────────────────────────
  -- 분기 C: brand_id NULL (브랜드 미상) — 기존 CAMP-YYYY-NNNN 유지
  --   운영자가 brand_id 연결 후 수동 번호 갱신 필요.
  --   임시 번호로 CAMP-{YYYY}-NNNN을 그대로 사용.
  -- ──────────────────────────────────────────────────────────
  v_year := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Tokyo'))::integer;

  INSERT INTO public.campaigns_yearly_counter (year, seq)
  VALUES (v_year, 1)
  ON CONFLICT (year)
  DO UPDATE SET seq = public.campaigns_yearly_counter.seq + 1
  RETURNING seq INTO v_year_seq;

  NEW.campaign_no := 'CAMP-' || v_year::text || '-' || lpad(v_year_seq::text, 4, '0');

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_campaign_no IS
  '[090] campaigns BEFORE INSERT 트리거. brand_id+source_application_id 조합으로 3분기 채번. A: B{B}-A{A}-C{C} / B: B{B}-C{C} / C(브랜드미상): CAMP-YYYY-NNNN(임시). advisory lock으로 동시 INSERT 직렬화.';

-- 권한 정리 (084 패턴 유지)
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM anon;

-- 트리거 재등록 (055와 동일 이름)
DROP TRIGGER IF EXISTS trg_campaign_no ON public.campaigns;
CREATE TRIGGER trg_campaign_no
  BEFORE INSERT ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public.generate_campaign_no();


-- ============================================================
-- SECTION 3. generate_brand_seq() 트리거 함수
--   brands INSERT 시 brand_seq 자동 채번
--   082의 generate_brand_no()와 병행 동작 (순서: brand_seq → brand_no)
-- ============================================================

CREATE OR REPLACE FUNCTION public.generate_brand_seq()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_seq integer;
BEGIN
  -- 이미 채번된 값 있으면 덮어쓰지 않음
  IF NEW.brand_seq IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- brand_seq_counter atomic 증가
  UPDATE public.brand_seq_counter
  SET seq = seq + 1
  WHERE id = 1
  RETURNING seq INTO v_seq;

  NEW.brand_seq := v_seq;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_seq IS
  '[090] brands BEFORE INSERT 트리거. brand_seq_counter 싱글톤을 atomic 증가하여 brand_seq 생성. 082의 generate_brand_no()와 별개 트리거로 실행 순서 보장 불필요 (독립 값).';

REVOKE ALL ON FUNCTION public.generate_brand_seq() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_brand_seq() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_brand_seq() FROM anon;

DROP TRIGGER IF EXISTS trg_brand_seq ON public.brands;
CREATE TRIGGER trg_brand_seq
  BEFORE INSERT ON public.brands
  FOR EACH ROW EXECUTE FUNCTION public.generate_brand_seq();


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 ROLLBACK으로 실행)
-- ============================================================
/*

-- [T1] 신청 신규 INSERT — B 포맷 생성 확인
BEGIN;

-- 테스트 브랜드 준비
INSERT INTO public.brands (name) VALUES ('테스트채번브랜드0001')
RETURNING id, brand_no, brand_seq;
-- brand_seq가 현재 max+1이어야 함

-- 신청 INSERT
WITH b AS (SELECT id FROM public.brands WHERE name_normalized = '테스트채번브랜드0001')
INSERT INTO public.brand_applications (brand_id, form_type, brand_name, contact_name, phone, email, products)
SELECT b.id, 'reviewer', '테스트채번브랜드0001', '홍길동', '010-1234-5678', 'test@x.com',
       '[{"name":"상품A","url":"https://example.com","price_jpy":1000,"qty":1}]'::jsonb
FROM b
RETURNING application_no, brand_id;
-- 예: B0024-A001 (브랜드가 24번째인 경우)

ROLLBACK;


-- [T2] 외부 캠페인 INSERT — B{B}-C{C} 포맷 확인
BEGIN;

WITH b AS (SELECT id FROM public.brands LIMIT 1)
INSERT INTO public.campaigns (brand_id, title, brand, recruit_type, status, channel)
SELECT b.id, '채번테스트캠페인', 'test', 'gifting', 'draft', 'instagram'
FROM b
RETURNING campaign_no;
-- 예: B0001-C001

ROLLBACK;


-- [T3] 동시성 테스트 (별도 연결 2개에서 동시에 실행)
-- 연결 1: BEGIN; INSERT INTO brand_applications ... ; (커밋 전 대기)
-- 연결 2: BEGIN; INSERT INTO brand_applications ... (같은 brand_id) ;
-- 연결 1이 COMMIT 후 연결 2가 A002를 받아야 함 (A001 중복 불가)


-- [T4] brand_id NULL → CAMP-YYYY-NNNN 폴백 확인
BEGIN;

INSERT INTO public.campaigns (title, brand, recruit_type, status, channel)
VALUES ('브랜드미상테스트', '알수없는브랜드', 'gifting', 'draft', 'instagram')
RETURNING campaign_no;
-- CAMP-2026-NNNN 형태이어야 함

ROLLBACK;


-- [T5] A-seq overflow 검증 (999개 이상 신청 방지)
-- 실제 운영에서 999개는 불가능하므로 트리거 코드만 육안 검토


-- [T6] 함수 정의 확인 (advisory lock 포함 여부)
SELECT proname, prosrc
FROM pg_proc
WHERE proname IN (
  'generate_brand_application_no',
  'generate_campaign_no',
  'generate_brand_seq'
)
ORDER BY proname;

*/


-- ============================================================
-- 롤백 SQL (090만 롤백, 088/089는 별도 롤백)
-- ============================================================
/*

-- 1. 트리거 제거
DROP TRIGGER IF EXISTS trg_brand_app_no ON public.brand_applications;
DROP TRIGGER IF EXISTS trg_campaign_no  ON public.campaigns;
DROP TRIGGER IF EXISTS trg_brand_seq    ON public.brands;

-- 2. 함수 제거 (090 버전)
DROP FUNCTION IF EXISTS public.generate_brand_application_no();
DROP FUNCTION IF EXISTS public.generate_campaign_no();
DROP FUNCTION IF EXISTS public.generate_brand_seq();

-- 3. 078 버전 채번 함수 복원 (078_brand_app_no_format_v2.sql의 CREATE OR REPLACE 재실행)
-- 4. 055 버전 채번 함수 복원 (055_add_campaign_no.sql의 CREATE OR REPLACE 재실행)
-- → 각 마이그레이션 파일의 함수 정의를 SQL Editor에 붙여 실행

NOTIFY pgrst, 'reload schema';

*/
