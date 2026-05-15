-- ============================================================
-- 127_admin_list_indexes.sql
-- 관리자 페이지 목록 페인의 정렬 컬럼 인덱스 5종 추가
--
-- 배경:
--   docs/specs/2026-05-15-admin-perf-diagnosis.md §5-5 / §6-3 진단 결과,
--   admin list 쿼리 5종이 모두 Seq Scan 으로 처리됨.
--   현재 데이터 양에선 캐시 hit 으로 < 20ms 이지만 누적 시 선형 악화 우려.
--   데이터 누적 (applications 2,673 → 1만+ 예상) 대비 사전 인덱스 추가.
--
-- 추가 인덱스 (CREATE INDEX IF NOT EXISTS, 모두 멱등):
--   1. applications.created_at DESC           (fetchApplications)
--   2. influencers.created_at ASC             (fetchInfluencers)
--   3. deliverables.updated_at DESC           (fetchDeliverables)
--   4. brand_applications.created_at DESC     (fetchBrandApplications)
--   5. campaigns.order_index NULLS LAST       (fetchCampaigns — 정렬용)
--
-- 적용 방식:
--   일반 CREATE INDEX (Supabase SQL Editor 가 multi-statement 를 트랜잭션으로 처리하므로
--   CONCURRENTLY 미사용). 현재 데이터 양 작아서 빌드 < 5초 예상.
--
-- 운영 영향:
--   - 인덱스 빌드 동안 해당 테이블 INSERT/UPDATE/DELETE 짧게 차단 (SELECT 는 가능)
--   - applications 2,673 행 기준 ~1초. 다른 테이블은 더 짧음
--   - 운영 트래픽 적은 새벽 권장
--
-- 사양서: docs/specs/2026-05-15-admin-perf-diagnosis.md §7-2
-- 작성일: 2026-05-15
-- ============================================================


-- 1. applications.created_at DESC — admin 신청 관리 페인 정렬용
CREATE INDEX IF NOT EXISTS idx_applications_created_at_desc
  ON public.applications (created_at DESC);

COMMENT ON INDEX public.idx_applications_created_at_desc IS
  '[127] fetchApplications ORDER BY created_at DESC 인덱스. Seq Scan → Index Scan 전환.';


-- 2. influencers.created_at ASC — admin 인플루언서 관리 페인 정렬용
CREATE INDEX IF NOT EXISTS idx_influencers_created_at_asc
  ON public.influencers (created_at ASC);

COMMENT ON INDEX public.idx_influencers_created_at_asc IS
  '[127] fetchInfluencers ORDER BY created_at ASC 인덱스.';


-- 3. deliverables.updated_at DESC — admin 결과물 관리 페인 정렬용
CREATE INDEX IF NOT EXISTS idx_deliverables_updated_at_desc
  ON public.deliverables (updated_at DESC);

COMMENT ON INDEX public.idx_deliverables_updated_at_desc IS
  '[127] fetchDeliverables 기본 정렬 (status != pending) ORDER BY updated_at DESC 인덱스.';


-- 4. brand_applications.created_at DESC — admin 브랜드 서베이 페인 정렬용
CREATE INDEX IF NOT EXISTS idx_brand_applications_created_at_desc
  ON public.brand_applications (created_at DESC);

COMMENT ON INDEX public.idx_brand_applications_created_at_desc IS
  '[127] fetchBrandApplications ORDER BY created_at DESC 인덱스.';


-- 5. campaigns.order_index NULLS LAST — admin 캠페인 관리 페인 정렬용
--    NULLS LAST 는 PostgreSQL 기본 ORDER BY ASC + NULLS LAST 패턴
CREATE INDEX IF NOT EXISTS idx_campaigns_order_index_nulls_last
  ON public.campaigns (order_index NULLS LAST);

COMMENT ON INDEX public.idx_campaigns_order_index_nulls_last IS
  '[127] fetchCampaigns ORDER BY order_index NULLS LAST 인덱스.';


-- ============================================================
-- 검증 SQL (개발/운영 DB 적용 후)
-- ============================================================
/*

-- [V1] 5개 인덱스 등록 확인 (5건 반환)
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_applications_created_at_desc',
    'idx_influencers_created_at_asc',
    'idx_deliverables_updated_at_desc',
    'idx_brand_applications_created_at_desc',
    'idx_campaigns_order_index_nulls_last'
  )
ORDER BY indexname;

-- [V2] applications EXPLAIN 으로 Seq Scan → Index Scan 전환 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.applications
ORDER BY created_at DESC
LIMIT 1000;
-- 「Index Scan using idx_applications_created_at_desc」 가 나타나야 함

-- [V3] influencers EXPLAIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.influencers
ORDER BY created_at ASC
LIMIT 1000;

-- [V4] 인덱스 크기 점검 (스토리지 영향 — 보통 테이블의 5~10%)
SELECT
  i.indexname,
  pg_size_pretty(pg_relation_size(i.indexname::regclass)) AS index_size
FROM pg_indexes i
WHERE i.schemaname = 'public'
  AND i.indexname IN (
    'idx_applications_created_at_desc',
    'idx_influencers_created_at_asc',
    'idx_deliverables_updated_at_desc',
    'idx_brand_applications_created_at_desc',
    'idx_campaigns_order_index_nulls_last'
  )
ORDER BY i.indexname;

*/


-- ============================================================
-- 롤백 SQL (인덱스 영향 발견 시)
-- ============================================================
/*

DROP INDEX IF EXISTS public.idx_applications_created_at_desc;
DROP INDEX IF EXISTS public.idx_influencers_created_at_asc;
DROP INDEX IF EXISTS public.idx_deliverables_updated_at_desc;
DROP INDEX IF EXISTS public.idx_brand_applications_created_at_desc;
DROP INDEX IF EXISTS public.idx_campaigns_order_index_nulls_last;

*/
