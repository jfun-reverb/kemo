-- ════════════════════════════════════════════════════════════════════
-- migration 119: brands → companies 백필 (이름 유사도 자동 매핑)
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-13-brand-ops-redesign.md §4-2
--
-- 변경 내용:
--   1. (보강) companies.name_normalized 정규화 함수를 brands 패턴과 동일하게.
--      brands 의 set_brand_name_normalized 는 `lower(trim(regexp_replace(name,'\s+',' ','g')))`
--      로 다중 공백을 단일 공백으로 압축. 118 의 함수는 압축이 없었음. 양쪽
--      정규화 결과가 어긋나면 백필 매칭 실패 가능 → 동일 패턴으로 통일.
--   2. brands.name_normalized 동일 그룹(2개 이상)을 companies 로 자동 생성.
--   3. 같은 그룹의 모든 brand 에 동일 company_id 할당.
--      매칭 애매한 경우(단일 brand 만 존재) 는 company_id = NULL 유지
--      → 운영자가 회사 관리 페인에서 수동 정리.
--   4. 트리거 trg_brands_company_total_brands 가 brands.company_id UPDATE 를
--      행 단위로 캐치 → companies.total_brands 자동 증가.
--
-- 멱등성:
--   - 정규화 함수: CREATE OR REPLACE
--   - 회사 INSERT: ON CONFLICT (name_normalized) DO NOTHING — 재실행 안전
--   - brands UPDATE: WHERE company_id IS NULL — 재실행 시 이미 매핑된 행 제외
--
-- ROLLBACK:
--   UPDATE public.brands SET company_id = NULL WHERE company_id IS NOT NULL;
--   TRUNCATE public.companies;
--   -- 118 의 정규화 함수 원본으로 복원하려면 118 본문의 set_company_name_normalized
--   -- 정의를 다시 CREATE OR REPLACE 실행 (다중 공백 압축 없는 버전)
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. (보강) companies.name_normalized 정규화를 brands 패턴과 통일 ──
-- brands 에서 사용하는 정규화 = lower + trim + 다중 공백 단일 공백 압축.
-- 118 의 함수는 압축이 없어 brand name 에 다중 공백이 있을 때 결과 불일치 위험.
CREATE OR REPLACE FUNCTION public.set_company_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.name_normalized := lower(trim(regexp_replace(coalesce(NEW.name_ko, ''), '\s+', ' ', 'g')));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'company name_ko must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_company_name_normalized() IS
  '[118+119] companies.name_normalized 자동 계산 — lower + trim + 다중 공백 단일 압축. brands.set_brand_name_normalized 패턴과 동일.';


-- ── 2. 동명 그룹별 회사 INSERT (2개 이상 brands 가 같은 name_normalized 가질 때만) ──
--    name_ko: 그룹 첫 brand 의 원본 name (트리거가 INSERT 시 정규화 재계산)
--    name_normalized: 트리거가 NEW.name_ko 로부터 다시 계산 → brands 패턴 동일
--    ON CONFLICT: 이미 같은 normalized 의 회사가 있으면 SKIP (멱등)
WITH grouped AS (
  SELECT
    b.name_normalized                                AS norm,
    (array_agg(b.name      ORDER BY b.created_at))[1] AS first_name,
    COUNT(*)                                          AS brand_count
  FROM public.brands b
  WHERE b.name_normalized IS NOT NULL
    AND b.name_normalized <> ''
  GROUP BY b.name_normalized
  HAVING COUNT(*) >= 2
)
INSERT INTO public.companies (name_ko)
SELECT first_name
FROM grouped
ON CONFLICT (name_normalized) DO NOTHING;


-- ── 3. brands.company_id 채움 — name_normalized 매칭 ──
-- companies 가 brands 패턴과 동일하게 정규화되므로 매칭 일관성 보장.
-- 단일 brand 만 있는 그룹은 companies 가 없어 company_id 가 NULL 유지.
UPDATE public.brands b
SET company_id = c.id
FROM public.companies c
WHERE c.name_normalized = b.name_normalized
  AND b.company_id IS NULL;


-- ── 4. (보강) total_brands 재계산 — 트리거가 처리하지만 안전망 ──
-- migration 119 가 단일 트랜잭션이라 트리거가 정상 발동해 total_brands 누적되지만,
-- 만약 트리거가 빠진 시점에 brands.company_id 가 수동으로 채워졌으면 카운트가
-- 어긋날 수 있음. 트랜잭션 마지막에 명시적 재계산으로 정확성 보장.
UPDATE public.companies c
SET total_brands = sub.cnt
FROM (
  SELECT company_id, COUNT(*) AS cnt
  FROM public.brands
  WHERE company_id IS NOT NULL
  GROUP BY company_id
) sub
WHERE c.id = sub.company_id;


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 백필 결과 검증 SQL (트랜잭션 밖, 수동 실행)
-- ────────────────────────────────────────────────────────────────────
/*
-- 자동 생성된 회사 수
SELECT COUNT(*) AS companies_created FROM public.companies;

-- brands 의 회사 매핑 비율
SELECT
  COUNT(*) FILTER (WHERE company_id IS NOT NULL) AS mapped,
  COUNT(*) FILTER (WHERE company_id IS NULL)     AS unmapped,
  COUNT(*)                                        AS total,
  ROUND(100.0 * COUNT(*) FILTER (WHERE company_id IS NOT NULL) / NULLIF(COUNT(*),0), 1) AS mapped_pct
FROM public.brands;

-- 회사별 brands 수 + total_brands 캐시 일치 확인
SELECT
  c.id, c.name_ko, c.total_brands AS cached,
  (SELECT COUNT(*) FROM public.brands b WHERE b.company_id = c.id) AS actual
FROM public.companies c
ORDER BY c.total_brands DESC
LIMIT 10;

-- 미분류 brands 표본
SELECT id, brand_no, name, name_normalized, total_applications, created_at
FROM public.brands
WHERE company_id IS NULL
ORDER BY total_applications DESC NULLS LAST, created_at
LIMIT 20;
*/
