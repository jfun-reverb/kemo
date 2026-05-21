-- ════════════════════════════════════════════════════════════════════
-- migration 147: brands.company_name 기준 companies 보완 백필
-- ────────────────────────────────────────────────────────────────────
-- 목적:
--   migration 119 는 brands.name(브랜드명) 기준으로 2개 이상 동명 그룹만 회사로
--   묶었으나, 브랜드명은 대부분 유니크하여 자동 생성된 회사가 거의 0건이었음.
--   실제 회사 정보는 brands.company_name(자유 텍스트, migration 091 추가) 컬럼에
--   존재한다. 이 컬럼 기준으로 companies 를 생성·연결하는 보완 백필.
--
-- 119 와의 차이:
--   - 매칭 기준: brands.name(브랜드명) → brands.company_name(회사명)
--   - 그룹 조건: HAVING COUNT(*) >= 2 제거 → 1개짜리 그룹도 회사로 생성
--     (회사명이 명시돼 있으면 실재 회사로 간주)
--   - 정규화 키: brands.name_normalized → brands.company_name 을 동일 규칙으로
--     즉석 정규화한 값(companies.name_normalized 와 동일 공식 사용)
--
-- 멱등성 근거:
--   - INSERT ON CONFLICT (name_normalized) DO NOTHING
--     → 119 가 이미 만든 회사 또는 재실행 시 중복 차단
--   - UPDATE brands WHERE company_id IS NULL
--     → 이미 연결된 행 미변경
--   - companies.total_brands 명시적 재계산은 항상 최종 정확 값으로 덮어씀
--     → 트리거 발동 여부와 관계없이 안전
--
-- 정규화 공식 (119 + set_company_name_normalized 트리거와 100% 동일):
--   lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))
--
-- 신규 함수/테이블/행 단위 보안 정책 변경 없음 — 데이터 백필 전용.
--
-- ROLLBACK:
--   migration 119 는 brands.name(브랜드명) 동명 그룹 2개 이상을 조건으로 했기
--   때문에 개발/운영 모두 companies 에 0건을 생성했음. 따라서 현재 companies
--   의 모든 행은 실질적으로 이 147 백필 생성분이다.
--
--   ① 가장 안전한 전체 롤백 (119 가 0건임을 확인한 경우):
--      UPDATE public.brands SET company_id = NULL WHERE company_id IS NOT NULL;
--      TRUNCATE public.companies;
--
--   ② 만약 운영에서 119 가 일부 회사를 만들었을 가능성을 배제할 수 없다면,
--      먼저 백필 시각 이전 행을 확인:
--        SELECT id, name_ko, created_at FROM public.companies ORDER BY created_at;
--      147 실행 시각 이후 행만 선별 삭제:
--        DELETE FROM public.companies WHERE created_at >= '<147 실행 시각>';
--        UPDATE public.brands b
--        SET company_id = NULL
--        WHERE NOT EXISTS (
--          SELECT 1 FROM public.companies c WHERE c.id = b.company_id
--        );
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. brands.company_name 기준으로 companies INSERT ──
-- 정규화 공식: lower + trim + 다중 공백 단일 공백 압축
-- ON CONFLICT (name_normalized) DO NOTHING — 119 생성분·재실행 중복 차단
WITH grouped AS (
  SELECT
    lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))   AS norm,
    -- 가장 오래된 행의 원본 company_name 을 대표값으로 사용
    (array_agg(company_name ORDER BY created_at))[1]              AS first_company_name,
    COUNT(*)                                                       AS brand_count
  FROM public.brands
  WHERE company_name IS NOT NULL
    AND trim(company_name) <> ''
  GROUP BY lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))
)
INSERT INTO public.companies (name_ko)
SELECT first_company_name
FROM grouped
ON CONFLICT (name_normalized) DO NOTHING;
-- ※ INSERT 시 set_company_name_normalized 트리거가 name_ko 로부터
--    name_normalized 를 자동 계산. 위 grouped.norm 과 동일 값이 되어야 함.


-- ── 2. brands.company_id 채움 — company_name 정규화 기준 매칭 ──
-- companies.name_normalized 는 트리거가 name_ko 에서 동일 공식으로 계산.
-- WHERE company_id IS NULL 로 이미 연결된 행은 건드리지 않음(멱등).
UPDATE public.brands b
SET company_id = c.id
FROM public.companies c
WHERE c.name_normalized = lower(trim(regexp_replace(b.company_name, '\s+', ' ', 'g')))
  AND b.company_name IS NOT NULL
  AND trim(b.company_name) <> ''
  AND b.company_id IS NULL;


-- ── 3. total_brands 명시적 재계산 ──
-- trg_brands_company_total_brands 트리거가 brands UPDATE 시 행 단위로 발동하나,
-- 트랜잭션 내 대량 UPDATE 이후 캐시 값 정합성을 보장하기 위해 명시 재계산.
-- 119 와 동일 패턴.
UPDATE public.companies c
SET total_brands = sub.cnt
FROM (
  SELECT company_id, COUNT(*) AS cnt
  FROM public.brands
  WHERE company_id IS NOT NULL
  GROUP BY company_id
) sub
WHERE c.id = sub.company_id;

-- total_brands 가 0 인데 실제로 연결된 브랜드가 없는 회사는 0으로 그대로 유지
-- (신규 생성된 회사 중 매칭 실패한 경우는 이론상 없지만 방어적으로 두는 것)


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 백필 결과 검증 SQL (트랜잭션 밖, 수동 실행)
-- ────────────────────────────────────────────────────────────────────
-- ▶ 검증 1: 이번 백필로 생성된 회사 수 (전체 = 147 생성분)
/*
SELECT COUNT(*) AS companies_total
FROM public.companies;
*/

-- ▶ 검증 2: brands 의 회사 매핑 비율 (전체 기준)
/*
SELECT
  COUNT(*) FILTER (WHERE company_id IS NOT NULL) AS mapped,
  COUNT(*) FILTER (WHERE company_id IS NULL)     AS unmapped,
  COUNT(*)                                        AS total,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE company_id IS NOT NULL) / NULLIF(COUNT(*), 0),
    1
  ) AS mapped_pct
FROM public.brands;
*/

-- ▶ 검증 3: 생성된 회사별 brands 수 + total_brands 캐시 일치 확인
/*
SELECT
  c.id,
  c.name_ko,
  c.name_normalized,
  c.total_brands       AS cached,
  COUNT(b.id)          AS actual
FROM public.companies c
LEFT JOIN public.brands b ON b.company_id = c.id
GROUP BY c.id, c.name_ko, c.name_normalized, c.total_brands
ORDER BY actual DESC;
*/

-- ▶ 검증 4: company_name 이 있는데 여전히 미분류된 brands 표본 (매칭 실패 가능성 점검)
/*
SELECT
  id,
  name,
  company_name,
  lower(trim(regexp_replace(company_name, '\s+', ' ', 'g'))) AS normalized_company_name,
  created_at
FROM public.brands
WHERE company_id IS NULL
  AND company_name IS NOT NULL
  AND trim(company_name) <> ''
ORDER BY created_at
LIMIT 20;
*/
