-- ============================================================
-- 088_hierarchical_numbering_schema.sql
-- 계층 채번 시스템 — 스키마 + 카운터 + 컬럼 추가
--
-- 목적:
--   brand_applications와 campaigns에 브랜드 기준 계층 번호를 부여한다.
--
--   신규 포맷:
--     brand 번호:        B0001  (4자리, brands.brand_seq 자동채번)
--     신청 번호:         B0001-A001  (신청 999/brand, 누적)
--     캠페인(신청파생):  B0001-A001-C001  (캠페인 999/신청, 누적)
--     캠페인(외부):      B0001-C001  (캠페인 999/brand, 누적. source_application_id=NULL)
--
--   이 마이그레이션은 스키마 골격만 만든다:
--     - brands.brand_seq 채번 컬럼 + 카운터 테이블
--     - 카운터 테이블 3종 (신청/캠페인(신청별)/캠페인(브랜드별 외부))
--     - legacy_no 컬럼 추가 (기존 번호 보존)
--     - campaigns.brand_id / source_application_id FK 컬럼 추가
--     - numbering_legacy_map 영구 매핑 테이블
--
--   데이터 백필(재채번) + 트리거 재설계는 089_hierarchical_numbering_backfill.sql
--
-- 전제:
--   - 082: brands 테이블 존재
--   - 083: brand_applications.brand_id 채워짐
--   - 087: submit_brand_application RPC 존재
--
-- 작성일: 2026-05-04
-- ============================================================


BEGIN;


-- ============================================================
-- SECTION 1. brands.brand_seq — 연도 무관 브랜드 순번 컬럼
--   채번 포맷에서 B{seq} 세그먼트를 구성하는 정수 컬럼.
--   트리거 generate_brand_no (082)가 brand_no(BR-YYYY-NNNN)를 담당하므로
--   brand_seq는 별도 계층 채번 전용 컬럼으로 분리한다.
--   값: 1, 2, 3 ... 9999 (브랜드 등록 순서대로 단조 증가, 연도 무관 누적)
-- ============================================================

-- 브랜드 순번 카운터 (단일 행, id=1 고정)
CREATE TABLE IF NOT EXISTS public.brand_seq_counter (
  id   integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- 싱글톤 보장
  seq  integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.brand_seq_counter IS
  '[088] brands.brand_seq 채번 카운터. 싱글톤(id=1). 직접 UPDATE 금지 — SECURITY DEFINER 트리거 전용.';

-- 초기 행 삽입 (없으면)
INSERT INTO public.brand_seq_counter (id, seq) VALUES (1, 0)
  ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.brand_seq_counter ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "brand_seq_counter_select_admin" ON public.brand_seq_counter;
CREATE POLICY "brand_seq_counter_select_admin"
  ON public.brand_seq_counter FOR SELECT
  USING (public.is_admin());

-- brands 에 brand_seq 컬럼 추가 (NULL 허용 — SECTION 2 함수로 기존 행 채움)
ALTER TABLE public.brands
  ADD COLUMN IF NOT EXISTS brand_seq integer UNIQUE;

COMMENT ON COLUMN public.brands.brand_seq IS
  '[088] 계층 채번용 브랜드 순번. B{lpad(brand_seq,4,''0'')} 포맷의 앞 세그먼트. 연도 무관 누적.';

-- 인덱스
CREATE UNIQUE INDEX IF NOT EXISTS brands_brand_seq_idx ON public.brands (brand_seq);


-- ============================================================
-- SECTION 2. 카운터 테이블 3종
-- ============================================================

-- [A] 브랜드별 신청 누적 카운터 (A001~A999)
CREATE TABLE IF NOT EXISTS public.brand_application_counter (
  brand_id uuid   PRIMARY KEY REFERENCES public.brands(id) ON DELETE CASCADE,
  last_seq integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.brand_application_counter IS
  '[088] brands별 신청 누적 카운터. A{seq} 세그먼트 생성용. INSERT 전용 (직접 UPDATE 금지).';

ALTER TABLE public.brand_application_counter ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "brand_application_counter_select_admin" ON public.brand_application_counter;
CREATE POLICY "brand_application_counter_select_admin"
  ON public.brand_application_counter FOR SELECT
  USING (public.is_admin());


-- [B] 신청별 캠페인 누적 카운터 (C001~C999)
CREATE TABLE IF NOT EXISTS public.application_campaign_counter (
  application_id uuid   PRIMARY KEY REFERENCES public.brand_applications(id) ON DELETE CASCADE,
  last_seq       integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.application_campaign_counter IS
  '[088] brand_applications별 파생 캠페인 누적 카운터. B{B}-A{A}-C{seq} 생성용.';

ALTER TABLE public.application_campaign_counter ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "application_campaign_counter_select_admin" ON public.application_campaign_counter;
CREATE POLICY "application_campaign_counter_select_admin"
  ON public.application_campaign_counter FOR SELECT
  USING (public.is_admin());


-- [C] 브랜드별 외부 캠페인 카운터 (source_application_id=NULL 인 캠페인용)
CREATE TABLE IF NOT EXISTS public.brand_external_campaign_counter (
  brand_id uuid   PRIMARY KEY REFERENCES public.brands(id) ON DELETE CASCADE,
  last_seq integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.brand_external_campaign_counter IS
  '[088] brands별 외부 캠페인(신청 미연결) 누적 카운터. B{B}-C{seq} 생성용.';

ALTER TABLE public.brand_external_campaign_counter ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "brand_external_campaign_counter_select_admin" ON public.brand_external_campaign_counter;
CREATE POLICY "brand_external_campaign_counter_select_admin"
  ON public.brand_external_campaign_counter FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- SECTION 3. legacy_no 컬럼 추가
--   기존 번호를 영구 보존한다. 재채번 후에도 검색 + 감사 가능.
-- ============================================================

ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS legacy_no text;

COMMENT ON COLUMN public.brand_applications.legacy_no IS
  '[088] 재채번 전 구 application_no. 영구 보존. NULL = 재채번 전 미마이그레이션 (있어서는 안 됨).';

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS legacy_no text;

COMMENT ON COLUMN public.campaigns.legacy_no IS
  '[088] 재채번 전 구 campaign_no. 영구 보존.';

-- legacy_no 인덱스 (검색 최적화)
CREATE INDEX IF NOT EXISTS brand_applications_legacy_no_idx ON public.brand_applications (legacy_no)
  WHERE legacy_no IS NOT NULL;

CREATE INDEX IF NOT EXISTS campaigns_legacy_no_idx ON public.campaigns (legacy_no)
  WHERE legacy_no IS NOT NULL;


-- ============================================================
-- SECTION 4. campaigns FK 컬럼 추가
--   brand_id: 모든 캠페인은 brands를 반드시 참조해야 함
--             (백필 전까지 NULL 허용 — 089에서 NOT NULL 전환)
--   source_application_id: 신청에서 파생된 캠페인의 역참조
-- ============================================================

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS brand_id             uuid REFERENCES public.brands(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_application_id uuid REFERENCES public.brand_applications(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.campaigns.brand_id IS
  '[088] brands FK. 모든 캠페인은 브랜드에 속한다. 089에서 기존 free-text brand 컬럼 기준 백필.';

COMMENT ON COLUMN public.campaigns.source_application_id IS
  '[088] brand_applications FK. NULL=외부 캠페인(영업 직접 등록). NOT NULL=신청에서 파생된 캠페인.';

CREATE INDEX IF NOT EXISTS campaigns_brand_id_idx             ON public.campaigns (brand_id);
CREATE INDEX IF NOT EXISTS campaigns_source_application_id_idx ON public.campaigns (source_application_id);


-- ============================================================
-- SECTION 5. numbering_legacy_map — 외부 보고서용 영구 매핑 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.numbering_legacy_map (
  entity_type  text        NOT NULL CHECK (entity_type IN ('brand_application', 'campaign')),
  entity_id    uuid        NOT NULL,
  legacy_no    text        NOT NULL,
  new_no       text        NOT NULL,
  migrated_at  timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (entity_type, entity_id)
);

COMMENT ON TABLE public.numbering_legacy_map IS
  '[088] 재채번 매핑 영구 보존. entity_type=brand_application|campaign. 외부 보고서·메일 추적용.';

CREATE INDEX IF NOT EXISTS numbering_legacy_map_legacy_no_idx ON public.numbering_legacy_map (legacy_no);
CREATE INDEX IF NOT EXISTS numbering_legacy_map_new_no_idx    ON public.numbering_legacy_map (new_no);

ALTER TABLE public.numbering_legacy_map ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "numbering_legacy_map_select_admin" ON public.numbering_legacy_map;
CREATE POLICY "numbering_legacy_map_select_admin"
  ON public.numbering_legacy_map FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 직접 실행)
-- ============================================================
/*

-- [V1] 신규 테이블 존재 확인 (4개 반환)
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'brand_seq_counter',
    'brand_application_counter',
    'application_campaign_counter',
    'brand_external_campaign_counter',
    'numbering_legacy_map'
  )
ORDER BY table_name;

-- [V2] campaigns 신규 컬럼 확인
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'campaigns'
  AND column_name IN ('brand_id', 'source_application_id', 'legacy_no')
ORDER BY column_name;
-- 3개 행. brand_id/source_application_id: uuid nullable, legacy_no: text nullable

-- [V3] brand_applications 신규 컬럼 확인
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'brand_applications'
  AND column_name = 'legacy_no';

-- [V4] brand_seq_counter 초기 행
SELECT * FROM public.brand_seq_counter;
-- id=1, seq=0

-- [V5] FK 인덱스 확인
SELECT indexname FROM pg_indexes
WHERE tablename = 'campaigns'
  AND indexname IN (
    'campaigns_brand_id_idx',
    'campaigns_source_application_id_idx',
    'campaigns_legacy_no_idx'
  );

*/


-- ============================================================
-- 롤백 SQL (COMMIT 후 문제 발생 시 역순 실행)
-- ============================================================
/*

BEGIN;

-- 1. campaigns 컬럼 제거
ALTER TABLE public.campaigns
  DROP COLUMN IF EXISTS brand_id,
  DROP COLUMN IF EXISTS source_application_id,
  DROP COLUMN IF EXISTS legacy_no;

-- 2. brand_applications 컬럼 제거
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS legacy_no;

-- 3. brands 컬럼 제거
ALTER TABLE public.brands
  DROP COLUMN IF EXISTS brand_seq;

-- 4. 매핑/카운터 테이블 제거 (의존성 없음)
DROP TABLE IF EXISTS public.numbering_legacy_map;
DROP TABLE IF EXISTS public.brand_external_campaign_counter;
DROP TABLE IF EXISTS public.application_campaign_counter;
DROP TABLE IF EXISTS public.brand_application_counter;
DROP TABLE IF EXISTS public.brand_seq_counter;

COMMIT;

NOTIFY pgrst, 'reload schema';

*/
