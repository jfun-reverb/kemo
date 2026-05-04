-- ============================================================
-- 082_brands_master_phase1.sql
-- brands 마스터 테이블 신규 생성 + brand_applications 컬럼 추가
--
-- 목적:
--   광고주(브랜드)를 독립 엔티티로 관리하는 마스터 테이블을 생성한다.
--   brand_applications는 기존 brand_name 텍스트 컬럼 외에 brands.id FK를
--   추가하여 정규화된 브랜드와 연결 경로를 확보한다.
--
--   이 마이그레이션은 골격(스키마)만 만든다.
--   - 기존 brand_applications 데이터의 brands 행 생성 및 brand_id 채움 → PR2 (데이터 마이그레이션)
--   - 클라이언트 코드 변경 없음 (PR1 단독으로 운영 적용 가능)
--   - brand_applications.brand_name 등 기존 컬럼 유지 → PR6에서 DROP
--
-- 채번: BR-YYYY-NNNN (JST 연도별, 4자리 순차, CAMP-YYYY-NNNN 동일 패턴)
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- SECTION 1. brands_yearly_counter — 채번 카운터
--   SECURITY DEFINER 트리거 전용, 직접 UPDATE 금지
-- ============================================================
CREATE TABLE IF NOT EXISTS public.brands_yearly_counter (
  year integer PRIMARY KEY,
  seq  integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.brands_yearly_counter IS
  '[082] brands.brand_no 채번 카운터 (JST 연도별). 직접 UPDATE 금지 — SECURITY DEFINER 트리거 전용.';

ALTER TABLE public.brands_yearly_counter ENABLE ROW LEVEL SECURITY;

-- 관리자만 카운터 조회 허용 (트리거 함수는 SECURITY DEFINER로 RLS 우회)
DROP POLICY IF EXISTS "brands_yearly_counter_select_admin" ON public.brands_yearly_counter;
CREATE POLICY "brands_yearly_counter_select_admin"
  ON public.brands_yearly_counter FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- SECTION 2. brands 테이블 신규 생성
-- ============================================================
CREATE TABLE IF NOT EXISTS public.brands (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 채번 트리거로 자동 생성 (BR-2026-0001)
  brand_no                text        UNIQUE NOT NULL,

  -- 표시명 (다국어)
  name                    text        NOT NULL,                  -- 한국어 표시명 (필수)
  name_ja                 text,                                  -- 일본어 (오리엔시트용)
  name_en                 text,                                  -- 영문

  -- 정규화 키: lower(trim(regexp_replace(name, '\s+', ' ', 'g')))
  -- 이름 정규화 자동 병합(Q1 결정사항): INSERT/UPDATE 시 트리거가 자동 계산
  name_normalized         text        UNIQUE NOT NULL,

  -- 사업자 정보
  business_no             text,                                  -- 사업자등록번호 (견적서 수신측)

  -- 브랜드 소개 (Phase 2 활용 예정)
  description             text,
  appeal_points           text,

  -- 공식 채널 URL
  official_qoo10_url      text,
  official_instagram_url  text,
  official_x_url          text,

  -- 주 담당자 (Q2 결정사항: brands.primary_* 컬럼 보존)
  primary_contact_name    text,
  primary_phone           text,
  primary_email           text,
  billing_email           text,                                  -- 세금계산서 수신 이메일

  -- 영업 메모 (관리자 내부 기록)
  memo                    text,

  -- 상태 (soft delete)
  status                  text        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'archived')),

  -- 집계 (brand_applications AFTER 트리거가 자동 갱신)
  total_applications      integer     NOT NULL DEFAULT 0,
  first_applied_at        timestamptz,
  last_applied_at         timestamptz,

  -- 감사 컬럼
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  created_by              uuid        REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE  public.brands                     IS '[082] 브랜드 마스터 테이블. brand_applications의 brand_name 텍스트를 정규화하여 독립 엔티티로 관리. PR2에서 기존 데이터를 채운다.';
COMMENT ON COLUMN public.brands.brand_no            IS 'BR-YYYY-NNNN 형식, JST 연도별 4자리 순차. INSERT 시 트리거 자동 생성.';
COMMENT ON COLUMN public.brands.name_normalized     IS 'lower(trim(regexp_replace(name, ⧵s+, , g))). INSERT/UPDATE 트리거가 자동 계산. UNIQUE 제약으로 동명 브랜드 중복 생성을 방지한다.';
COMMENT ON COLUMN public.brands.total_applications  IS 'brand_applications.brand_id 참조 건수. AFTER INSERT/UPDATE/DELETE 트리거가 자동 재집계.';
COMMENT ON COLUMN public.brands.first_applied_at    IS 'brand_applications 최초 생성일. 트리거 자동 갱신.';
COMMENT ON COLUMN public.brands.last_applied_at     IS 'brand_applications 최신 생성일. 트리거 자동 갱신.';
COMMENT ON COLUMN public.brands.status              IS 'active(기본) | archived. 삭제 대신 archived로 soft delete.';
COMMENT ON COLUMN public.brands.created_by          IS '브랜드 수동 등록 시 관리자 auth.uid(). PR2 자동 마이그레이션 행은 NULL.';

-- 인덱스
CREATE INDEX IF NOT EXISTS brands_status_idx      ON public.brands (status);
CREATE INDEX IF NOT EXISTS brands_normalized_idx   ON public.brands (name_normalized);
CREATE INDEX IF NOT EXISTS brands_created_at_idx   ON public.brands (created_at DESC);


-- ============================================================
-- SECTION 3. brand_no 채번 트리거 함수
--   패턴: campaign_no(055) 완전 동일, 접두만 BR-
-- ============================================================
CREATE OR REPLACE FUNCTION public.generate_brand_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_year integer;
  v_seq  integer;
BEGIN
  -- 이미 채번된 값 있으면 덮어쓰지 않음 (수동 지정 안전장치)
  IF NEW.brand_no IS NOT NULL AND NEW.brand_no <> '' THEN
    RETURN NEW;
  END IF;

  -- JST 기준 연도 (서버 타임존 의존 금지)
  v_year := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Tokyo'))::integer;

  -- 연도별 카운터 atomic 증가
  INSERT INTO public.brands_yearly_counter (year, seq)
  VALUES (v_year, 1)
  ON CONFLICT (year)
  DO UPDATE SET seq = public.brands_yearly_counter.seq + 1
  RETURNING seq INTO v_seq;

  -- BR-2026-0001
  NEW.brand_no := 'BR-' || v_year::text || '-' || lpad(v_seq::text, 4, '0');
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_no IS
  '[082] brands BEFORE INSERT 트리거. JST 연도별 카운터 atomic 증가로 brand_no(BR-YYYY-NNNN) 생성. 055_add_campaign_no의 패턴을 재사용.';

DROP TRIGGER IF EXISTS trg_brand_no ON public.brands;
CREATE TRIGGER trg_brand_no
  BEFORE INSERT ON public.brands
  FOR EACH ROW EXECUTE FUNCTION public.generate_brand_no();


-- ============================================================
-- SECTION 4. name_normalized 자동 계산 트리거
--   INSERT/UPDATE 시 name → name_normalized 자동 파생
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_brand_name_normalized()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  NEW.name_normalized :=
    lower(trim(regexp_replace(NEW.name, '\s+', ' ', 'g')));
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_brand_name_normalized IS
  '[082] brands BEFORE INSERT/UPDATE 트리거. name → name_normalized 자동 파생 (소문자+다중공백 정규화).';

DROP TRIGGER IF EXISTS trg_brand_name_normalized ON public.brands;
CREATE TRIGGER trg_brand_name_normalized
  BEFORE INSERT OR UPDATE OF name ON public.brands
  FOR EACH ROW EXECUTE FUNCTION public.set_brand_name_normalized();


-- ============================================================
-- SECTION 5. updated_at 자동 갱신 트리거
--   기존 테이블(participation_sets 등)과 동일 패턴
-- ============================================================
CREATE OR REPLACE FUNCTION public.touch_brands_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_brands_updated_at IS
  '[082] brands BEFORE UPDATE 트리거. updated_at 자동 갱신.';

DROP TRIGGER IF EXISTS trg_brands_updated_at ON public.brands;
CREATE TRIGGER trg_brands_updated_at
  BEFORE UPDATE ON public.brands
  FOR EACH ROW EXECUTE FUNCTION public.touch_brands_updated_at();


-- ============================================================
-- SECTION 6. RLS 정책
--   SELECT/INSERT/UPDATE: is_admin()
--   DELETE: 없음 (status='archived'로 soft delete)
-- ============================================================
ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "brands_select_admin"  ON public.brands;
DROP POLICY IF EXISTS "brands_insert_admin"  ON public.brands;
DROP POLICY IF EXISTS "brands_update_admin"  ON public.brands;

CREATE POLICY "brands_select_admin"
  ON public.brands FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY "brands_insert_admin"
  ON public.brands FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "brands_update_admin"
  ON public.brands FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- DELETE 정책은 의도적으로 생략 (archived 상태 전환으로 soft delete)


-- ============================================================
-- SECTION 7. brand_applications 컬럼 추가
--   NULL 허용 — PR2에서 데이터 채움, PR6에서 필요 시 NOT NULL 전환
--   기존 brand_name/contact_name/phone/email/billing_email 유지 → PR6 DROP
-- ============================================================
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS brand_id            uuid        REFERENCES public.brands(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source              text        NOT NULL DEFAULT 'online_form'
                                                             CHECK (source IN ('online_form', 'offline', 'manual_admin', 'imported')),
  ADD COLUMN IF NOT EXISTS intake_admin_id     uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS applicant_contact_name text,
  ADD COLUMN IF NOT EXISTS applicant_phone     text,
  ADD COLUMN IF NOT EXISTS applicant_email     text;

COMMENT ON COLUMN public.brand_applications.brand_id             IS '[082] brands 마스터 FK. NULL=아직 매칭 전(PR2에서 채움). ON DELETE RESTRICT(브랜드 삭제 전 신청 건 정리 필수).';
COMMENT ON COLUMN public.brand_applications.source               IS '[082] 신청 유입 경로. online_form=sales 폼(기존 기본값) | offline=오프라인 접수 | manual_admin=관리자 직접 등록 | imported=일괄 가져오기.';
COMMENT ON COLUMN public.brand_applications.intake_admin_id      IS '[082] 수동 등록/가져오기 처리 관리자. online_form 건은 NULL.';
COMMENT ON COLUMN public.brand_applications.applicant_contact_name IS '[082] 브랜드 정규화 후에도 보존하는 신청 시점 담당자명. brands.primary_contact_name과 별개.';
COMMENT ON COLUMN public.brand_applications.applicant_phone      IS '[082] 신청 시점 연락처. brands.primary_phone과 별개.';
COMMENT ON COLUMN public.brand_applications.applicant_email      IS '[082] 신청 시점 이메일. brands.primary_email과 별개.';

-- 인덱스
CREATE INDEX IF NOT EXISTS brand_applications_brand_id_idx ON public.brand_applications (brand_id);
CREATE INDEX IF NOT EXISTS brand_applications_source_idx   ON public.brand_applications (source);


-- ============================================================
-- SECTION 8. brands 집계 자동 갱신 트리거
--   brand_applications에 INSERT/UPDATE(brand_id 변경)/DELETE 발생 시
--   해당 brands 행의 total_applications / first_applied_at / last_applied_at 재집계
--   brand_id 변경 시 이전 브랜드와 새 브랜드 양쪽 모두 재집계
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_brand_application_stats()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_brand_ids uuid[];
  v_bid       uuid;
BEGIN
  -- 재집계 대상 brand_id 목록 수집
  v_brand_ids := ARRAY[]::uuid[];

  IF TG_OP = 'INSERT' THEN
    IF NEW.brand_id IS NOT NULL THEN
      v_brand_ids := array_append(v_brand_ids, NEW.brand_id);
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- 이전 brand_id (변경 전)
    IF OLD.brand_id IS NOT NULL THEN
      v_brand_ids := array_append(v_brand_ids, OLD.brand_id);
    END IF;
    -- 새 brand_id (변경 후, 이전과 다를 때만 중복 추가)
    IF NEW.brand_id IS NOT NULL AND NEW.brand_id IS DISTINCT FROM OLD.brand_id THEN
      v_brand_ids := array_append(v_brand_ids, NEW.brand_id);
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.brand_id IS NOT NULL THEN
      v_brand_ids := array_append(v_brand_ids, OLD.brand_id);
    END IF;
  END IF;

  -- 중복 제거 후 각 브랜드 재집계
  FOREACH v_bid IN ARRAY (SELECT ARRAY(SELECT DISTINCT unnest(v_brand_ids)))
  LOOP
    UPDATE public.brands b
    SET
      total_applications = (
        SELECT count(*)::integer
        FROM public.brand_applications
        WHERE brand_id = v_bid
      ),
      first_applied_at = (
        SELECT min(created_at)
        FROM public.brand_applications
        WHERE brand_id = v_bid
      ),
      last_applied_at = (
        SELECT max(created_at)
        FROM public.brand_applications
        WHERE brand_id = v_bid
      )
    WHERE b.id = v_bid;
  END LOOP;

  -- 트리거 반환
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_brand_application_stats IS
  '[082] brand_applications AFTER INSERT/UPDATE/DELETE 트리거. brands.total_applications / first_applied_at / last_applied_at 재집계. brand_id 변경 시 이전·새 브랜드 양쪽 처리.';

DROP TRIGGER IF EXISTS trg_sync_brand_stats ON public.brand_applications;
CREATE TRIGGER trg_sync_brand_stats
  AFTER INSERT OR UPDATE OF brand_id OR DELETE
  ON public.brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.sync_brand_application_stats();


-- ============================================================
-- PostgREST 스키마 캐시 즉시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 직접 실행)
-- ============================================================
/*
-- [1] brands 테이블 존재 확인
SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name IN ('brands', 'brands_yearly_counter');
-- 2개 행 반환되어야 함

-- [2] brands 컬럼 목록
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'brands'
ORDER BY ordinal_position;

-- [3] brand_applications 신규 컬럼 확인
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'brand_applications'
  AND column_name IN ('brand_id', 'source', 'intake_admin_id',
                      'applicant_contact_name', 'applicant_phone', 'applicant_email')
ORDER BY ordinal_position;
-- 6개 행 반환되어야 함

-- [4] RLS 정책 활성 확인
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE tablename = 'brands'
ORDER BY policyname;
-- brands_select_admin / brands_insert_admin / brands_update_admin 3개 확인

-- [5] 트리거 목록 확인
SELECT trigger_name, event_manipulation, event_object_table, action_timing
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND event_object_table IN ('brands', 'brand_applications')
ORDER BY event_object_table, trigger_name;
-- brands: trg_brand_no(BEFORE INSERT), trg_brand_name_normalized(BEFORE INSERT/UPDATE), trg_brands_updated_at(BEFORE UPDATE)
-- brand_applications: trg_sync_brand_stats(AFTER INSERT/UPDATE/DELETE)

-- [6] 채번 트리거 동작 테스트 (반드시 ROLLBACK)
BEGIN;
  INSERT INTO public.brands (name)
  VALUES ('테스트브랜드 주식회사')
  RETURNING id, brand_no, name_normalized;
  -- brand_no = 'BR-2026-0001' 형식, name_normalized = '테스트브랜드 주식회사' (소문자화)
  SELECT * FROM public.brands_yearly_counter;  -- seq = 1
ROLLBACK;

-- [7] name_normalized 중복 방지 테스트
BEGIN;
  INSERT INTO public.brands (name) VALUES ('Apple Japan');
  INSERT INTO public.brands (name) VALUES ('Apple  Japan');  -- 다중 공백
  -- 두 번째 INSERT에서 UNIQUE 위반 오류 발생해야 함
ROLLBACK;

-- [8] 인덱스 존재 확인
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('brands', 'brand_applications')
  AND indexname LIKE 'brand%'
ORDER BY indexname;
*/


-- ============================================================
-- 롤백 SQL (운영 적용 후 문제 발생 시 역순으로 실행)
-- ============================================================
/*
-- STEP 1. 트리거 제거
DROP TRIGGER IF EXISTS trg_sync_brand_stats      ON public.brand_applications;
DROP TRIGGER IF EXISTS trg_brand_no              ON public.brands;
DROP TRIGGER IF EXISTS trg_brand_name_normalized ON public.brands;
DROP TRIGGER IF EXISTS trg_brands_updated_at     ON public.brands;

-- STEP 2. 함수 제거
DROP FUNCTION IF EXISTS public.sync_brand_application_stats();
DROP FUNCTION IF EXISTS public.generate_brand_no();
DROP FUNCTION IF EXISTS public.set_brand_name_normalized();
DROP FUNCTION IF EXISTS public.touch_brands_updated_at();

-- STEP 3. brand_applications 신규 컬럼 제거
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS brand_id,
  DROP COLUMN IF EXISTS source,
  DROP COLUMN IF EXISTS intake_admin_id,
  DROP COLUMN IF EXISTS applicant_contact_name,
  DROP COLUMN IF EXISTS applicant_phone,
  DROP COLUMN IF EXISTS applicant_email;

-- STEP 4. brands 테이블 제거 (brands_yearly_counter 먼저)
DROP TABLE IF EXISTS public.brands CASCADE;
DROP TABLE IF EXISTS public.brands_yearly_counter;

NOTIFY pgrst, 'reload schema';
*/
