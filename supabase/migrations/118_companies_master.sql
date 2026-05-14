-- ════════════════════════════════════════════════════════════════════
-- migration 118: companies 마스터 테이블 + brands.company_id 연결
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-13-brand-ops-redesign.md §4-1
--
-- 신설 목적:
--   1개 회사가 여러 브랜드를 보유하는 4단 계층(회사 > 브랜드 > 신청 > 캠페인)
--   지원. 「운영 현황」 페인의 회사 필터 + 회사 단위 정산·세무 기반.
--
-- 변경 내용:
--   1. companies 테이블 신설 (이름 한·일·영 + 사업자번호 + 연락처 + 메모)
--      - name_normalized 자동 계산 트리거 (lower(trim(name_ko)))
--      - status: active / archived 2종
--      - total_brands 캐시 컬럼 (brands 변경 시 트리거 자동 재계산)
--      - updated_at 자동 갱신 트리거
--   2. brands.company_id 컬럼 추가 (NULL 허용 — migration 119 백필)
--   3. RLS: SELECT는 모든 관리자, CUD는 campaign_admin 이상
--   4. 트리거 함수는 SECURITY DEFINER (RLS 우회) + SET search_path=''
--
-- 백필은 분리: migration 119 가 이름 유사도로 회사 자동 생성·매핑.
--
-- ROLLBACK:
--   DROP POLICY IF EXISTS companies_delete_admin ON public.companies;
--   DROP POLICY IF EXISTS companies_update_admin ON public.companies;
--   DROP POLICY IF EXISTS companies_insert_admin ON public.companies;
--   DROP POLICY IF EXISTS companies_select_admin ON public.companies;
--   DROP TRIGGER IF EXISTS trg_brands_company_total_brands ON public.brands;
--   DROP FUNCTION IF EXISTS public.recalc_company_total_brands();
--   DROP TRIGGER IF EXISTS trg_companies_updated_at ON public.companies;
--   DROP FUNCTION IF EXISTS public.touch_companies_updated_at();
--   DROP TRIGGER IF EXISTS trg_companies_name_normalized ON public.companies;
--   DROP FUNCTION IF EXISTS public.set_company_name_normalized();
--   ALTER TABLE public.brands DROP COLUMN IF EXISTS company_id;
--   DROP TABLE IF EXISTS public.companies;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. companies 테이블 신설 ──
CREATE TABLE IF NOT EXISTS public.companies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ko           text NOT NULL,
  name_ja           text,
  name_en           text,
  name_normalized   text UNIQUE NOT NULL,
  business_no       text,
  address           text,
  homepage_url      text,
  contact_name      text,
  contact_email     text,
  contact_phone     text,
  billing_email     text,
  billing_address   text,
  memo              text,
  status            text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'archived')),
  total_brands      integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.companies IS
  '[118] 회사 마스터 — 1개 회사가 여러 brands 를 보유 (회사 > 브랜드 > 신청 > 캠페인 4단 계층).';
COMMENT ON COLUMN public.companies.name_normalized IS
  '검색·중복 차단용 정규화 키. lower(trim(name_ko)). 트리거 자동 계산.';
COMMENT ON COLUMN public.companies.total_brands IS
  '소속 brand 개수 캐시. brands.company_id 변경 시 트리거 자동 재계산.';
COMMENT ON COLUMN public.companies.business_no IS
  '사업자등록번호. NULL 허용 — 회사 채번 키는 별도 도입 안 함, business_no 로 식별.';


-- ── 2. brands.company_id 컬럼 추가 ──
ALTER TABLE public.brands
  ADD COLUMN IF NOT EXISTS company_id uuid
    REFERENCES public.companies(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.brands.company_id IS
  '[118] 소속 회사 외래 키. NULL 허용 — migration 119 백필 후에도 매칭 실패 brand 는 NULL 유지(운영자 수동 정리).';

CREATE INDEX IF NOT EXISTS brands_company_id_idx ON public.brands (company_id);


-- ── 3. name_normalized 자동 계산 트리거 (set_brand_name_normalized 패턴 미러) ──
CREATE OR REPLACE FUNCTION public.set_company_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.name_normalized := lower(trim(coalesce(NEW.name_ko, '')));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'company name_ko must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_company_name_normalized() IS
  '[118] companies.name_normalized 자동 계산 — lower(trim(name_ko)). 빈 문자열은 CHECK 위반(23514).';

REVOKE ALL ON FUNCTION public.set_company_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_company_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_company_name_normalized() FROM anon;
GRANT EXECUTE ON FUNCTION public.set_company_name_normalized() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_companies_name_normalized ON public.companies;
CREATE TRIGGER trg_companies_name_normalized
  BEFORE INSERT OR UPDATE OF name_ko ON public.companies
  FOR EACH ROW
  EXECUTE FUNCTION public.set_company_name_normalized();


-- ── 4. updated_at 자동 갱신 트리거 ──
CREATE OR REPLACE FUNCTION public.touch_companies_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_companies_updated_at() IS
  '[118] companies.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_companies_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_companies_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_companies_updated_at() FROM anon;
GRANT EXECUTE ON FUNCTION public.touch_companies_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_companies_updated_at ON public.companies;
CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON public.companies
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_companies_updated_at();


-- ── 5. total_brands 집계 트리거 (brands.company_id 변경 시) ──
-- SECURITY DEFINER 로 companies UPDATE 권한 보장 (RLS 우회).
CREATE OR REPLACE FUNCTION public.recalc_company_total_brands()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- DELETE 또는 UPDATE: 기존 회사 카운트 감소
  IF TG_OP IN ('DELETE', 'UPDATE') AND OLD.company_id IS NOT NULL THEN
    UPDATE public.companies
       SET total_brands = GREATEST(total_brands - 1, 0)
     WHERE id = OLD.company_id;
  END IF;

  -- INSERT 또는 UPDATE: 새 회사 카운트 증가
  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.company_id IS NOT NULL THEN
    UPDATE public.companies
       SET total_brands = total_brands + 1
     WHERE id = NEW.company_id;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION public.recalc_company_total_brands() IS
  '[118] brands.company_id 변경 시 companies.total_brands 재계산. INSERT=+1, DELETE=-1, UPDATE는 OLD-1·NEW+1. SECURITY DEFINER 로 RLS 우회.';

REVOKE ALL ON FUNCTION public.recalc_company_total_brands() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recalc_company_total_brands() FROM authenticated;
REVOKE ALL ON FUNCTION public.recalc_company_total_brands() FROM anon;
GRANT EXECUTE ON FUNCTION public.recalc_company_total_brands() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_brands_company_total_brands ON public.brands;
CREATE TRIGGER trg_brands_company_total_brands
  AFTER INSERT OR DELETE OR UPDATE OF company_id ON public.brands
  FOR EACH ROW
  EXECUTE FUNCTION public.recalc_company_total_brands();


-- ── 6. 행 단위 보안 정책 ──
-- SELECT: 모든 관리자 (campaign_manager 포함) 열람 가능
-- INSERT/UPDATE/DELETE: campaign_admin 이상만 가능
-- FOR ALL 사용 시 SELECT 정책과 중첩되어 감사 시 혼동 — INSERT/UPDATE/DELETE 별도 분리
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS companies_select_admin ON public.companies;
CREATE POLICY companies_select_admin
  ON public.companies
  FOR SELECT
  USING (public.is_admin());

-- 이전 사양서의 FOR ALL 정책은 SELECT 도 포함하여 혼동 — INSERT/UPDATE/DELETE 분리
DROP POLICY IF EXISTS companies_cud_admin ON public.companies;
DROP POLICY IF EXISTS companies_insert_admin ON public.companies;
CREATE POLICY companies_insert_admin
  ON public.companies
  FOR INSERT
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS companies_update_admin ON public.companies;
CREATE POLICY companies_update_admin
  ON public.companies
  FOR UPDATE
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS companies_delete_admin ON public.companies;
CREATE POLICY companies_delete_admin
  ON public.companies
  FOR DELETE
  USING (public.is_campaign_admin());


COMMIT;
