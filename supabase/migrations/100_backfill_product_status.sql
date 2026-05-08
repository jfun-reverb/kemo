-- ============================================================
-- 100_backfill_product_status.sql
-- brand_applications.products 배열의 각 원소에 status 키가 없으면
-- 해당 신청의 brand_applications.status 값을 복사하여 채운다.
--
-- 배경:
--   Phase A 완료 — 표 셀에서 products[i].status 우선 사용, 없으면 a.status 폴백
--   Phase B 전환을 위해 기존 신청들의 products[i].status 백필이 필요하다.
--   현재 대부분의 기존 행은 status 키 자체가 products[i] jsonb 에 없음.
--
-- 처리 대상:
--   products 배열 원소 중 status 키가 없는(? 연산자로 확인) 원소가
--   1개라도 존재하는 brand_applications 행 전체
--
-- 멱등성:
--   이미 status 키가 있는 원소는 jsonb_build_object 로 덮어쓰지 않음.
--   WITH ORDINALITY 로 순서 보존하여 재실행 시에도 동일 결과.
--
-- 트리거 주의사항 (중요):
--   052 마이그레이션의 trg_brand_app_touch (BEFORE UPDATE) 가 이 UPDATE 에도
--   발동하여 version 컬럼을 OLD.version + 1 로 자동 증가시킨다.
--   version 증가는 낙관적 락(클라이언트 충돌 감지)에 영향을 미치므로
--   아래 절차로 트리거를 일시 비활성화하고 실행한다.
--
--   비활성화 방법: ALTER TABLE ... DISABLE TRIGGER trg_brand_app_touch
--   재활성화 방법: ALTER TABLE ... ENABLE TRIGGER trg_brand_app_touch
--   (슈퍼유저 권한 또는 테이블 소유자가 아닌 경우 SET session_replication_role='replica'
--    를 대신 사용할 수 있으나 Supabase 대시보드 SQL Editor 에서는
--    ALTER TABLE 방식을 권장한다.)
--
-- 적용 환경:
--   개발서버(qysmxtipobomefudyixw) 먼저 적용 → 검증 → 운영서버 적용
--
-- 작성일: 2026-05-08
-- ============================================================


-- ============================================================
-- 0. 사전 확인 (적용 전 SQL Editor 에서 실행)
-- ============================================================
/*

-- [PRE-0] 백필 대상 행 수 확인 (적용 전 실행하여 예상 건수 파악)
SELECT COUNT(*) AS target_row_count
FROM public.brand_applications
WHERE products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(products) AS elem
    WHERE NOT (elem ? 'status')
  );

-- [PRE-1] 백필 대상 제품 원소 수 합계 (행 기준이 아닌 원소 기준)
SELECT COUNT(*) AS target_product_count
FROM public.brand_applications,
     jsonb_array_elements(products) AS elem
WHERE NOT (elem ? 'status');

-- [PRE-2] 현재 신청 status 분포 (백필 후 products[i].status 분포 기준과 비교용)
SELECT status, COUNT(*) AS cnt
FROM public.brand_applications
GROUP BY status
ORDER BY cnt DESC;

*/


-- ============================================================
-- 1. 트리거 일시 비활성화 (version 자동 증가 방지)
-- ============================================================
ALTER TABLE public.brand_applications
  DISABLE TRIGGER trg_brand_app_touch;


-- ============================================================
-- 2. 백필 UPDATE
--
-- 동작 설명:
--   WITH ORDINALITY 로 배열 원소 순서(ord)를 유지하면서 jsonb_array_elements 로 펼침.
--   각 원소에 status 키가 없으면 신청의 status 를 복사하고,
--   이미 status 키가 있으면 원소를 그대로 유지.
--   jsonb_agg ... ORDER BY ord 로 원래 순서로 재조합.
--
-- 멱등성:
--   EXISTS 조건 덕분에, products 배열 모든 원소에 이미 status 키가 있으면
--   WHERE 조건에 걸리지 않아 UPDATE 자체가 발생하지 않는다.
--   → 재실행 시 no-op
-- ============================================================
UPDATE public.brand_applications AS ba
SET
  products = (
    SELECT jsonb_agg(
      CASE
        -- status 키가 없는 원소 → 신청 status 복사
        WHEN NOT (elem ? 'status')
          THEN elem || jsonb_build_object('status', ba.status)
        -- 이미 status 키가 있으면 원소 그대로 유지
        ELSE elem
      END
      ORDER BY ord
    )
    FROM jsonb_array_elements(ba.products) WITH ORDINALITY AS t(elem, ord)
  )
WHERE
  -- NULL 또는 빈 배열인 행 제외
  ba.products IS NOT NULL
  AND jsonb_typeof(ba.products) = 'array'
  AND jsonb_array_length(ba.products) > 0
  -- status 키가 없는 원소가 1개라도 있는 행만 대상 (멱등성)
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(ba.products) AS elem
    WHERE NOT (elem ? 'status')
  );


-- ============================================================
-- 3. 트리거 재활성화
-- ============================================================
ALTER TABLE public.brand_applications
  ENABLE TRIGGER trg_brand_app_touch;


-- ============================================================
-- 4. 사후 검증 (적용 후 SQL Editor 에서 실행)
-- ============================================================
/*

-- [V1] 백필 후 status 키 누락 원소 0건 확인 (= 0 이어야 함)
SELECT COUNT(*) AS missing_status_count
FROM public.brand_applications,
     jsonb_array_elements(products) AS elem
WHERE NOT (elem ? 'status');

-- [V2] 신청 status vs 제품 status 일치 비율
--   products[i].status 가 신청 status 와 다른 원소는 Phase A 이후 직접 변경된 것.
--   현재는 0건이어야 정상 (백필 직후 기준, 이후 Phase B 운영 중에는 차이가 생길 수 있음).
SELECT
  COUNT(*) AS total_products,
  COUNT(*) FILTER (
    WHERE (elem->>'status') = ba.status
  ) AS match_count,
  COUNT(*) FILTER (
    WHERE (elem->>'status') IS DISTINCT FROM ba.status
  ) AS mismatch_count,
  ROUND(
    COUNT(*) FILTER (WHERE (elem->>'status') = ba.status)::numeric
    / NULLIF(COUNT(*), 0) * 100, 1
  ) AS match_pct
FROM public.brand_applications AS ba,
     jsonb_array_elements(ba.products) AS elem
WHERE ba.products IS NOT NULL
  AND jsonb_typeof(ba.products) = 'array';

-- [V3] products[i].status 값 분포 확인
SELECT
  elem->>'status' AS product_status,
  COUNT(*)        AS cnt
FROM public.brand_applications,
     jsonb_array_elements(products) AS elem
GROUP BY 1
ORDER BY cnt DESC;

-- [V4] trg_brand_app_touch 트리거 재활성화 확인
SELECT tgname, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.brand_applications'::regclass
  AND tgname = 'trg_brand_app_touch';
-- tgenabled = 'O' (enabled) 이어야 함

*/


-- ============================================================
-- 롤백 방법
--   이 마이그레이션은 데이터 변경만 수행하므로 DDL 롤백은 없음.
--   products[i].status 를 제거하려면 아래 SQL 을 실행:
--
--   ALTER TABLE public.brand_applications DISABLE TRIGGER trg_brand_app_touch;
--
--   UPDATE public.brand_applications
--   SET products = (
--     SELECT jsonb_agg(elem - 'status' ORDER BY ord)
--     FROM jsonb_array_elements(products) WITH ORDINALITY AS t(elem, ord)
--   )
--   WHERE products IS NOT NULL
--     AND jsonb_typeof(products) = 'array'
--     AND jsonb_array_length(products) > 0
--     AND EXISTS (
--       SELECT 1 FROM jsonb_array_elements(products) AS e WHERE e ? 'status'
--     );
--
--   ALTER TABLE public.brand_applications ENABLE TRIGGER trg_brand_app_touch;
-- ============================================================
