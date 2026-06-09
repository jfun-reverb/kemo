-- ============================================================
-- 172: campaigns 에 브랜드명 일본어/영문 비정규화 컬럼 추가 + 백필
--
-- 배경: 캠페인 목록·인플 화면이 campaigns.brand(한국어 스냅샷) 하나만 표시 →
--       같은 브랜드라도 캠페인마다 brand 스냅샷이 한국어/일본어로 섞여 혼재.
-- 해결: brands 마스터의 3국어(name/name_ja/name_en)를 campaigns 에 비정규화 복사.
--       표시 헬퍼가 화면별 우선순위(관리자 한>영>일 / 인플 일>영>한)로 선택.
--       「항상 마스터 최신」은 173 의 brands UPDATE 동기화 트리거가 보장.
--
-- 사양서: docs/specs/2026-06-08-brand-name-i18n.md (B안)
-- 롤백: ALTER TABLE public.campaigns DROP COLUMN IF EXISTS brand_ja, DROP COLUMN IF EXISTS brand_en;
-- ============================================================

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS brand_ja  text,   -- 일본어 브랜드명 (brands.name_ja 동기화 복사본)
  ADD COLUMN IF NOT EXISTS brand_en  text;   -- 영문   브랜드명 (brands.name_en 동기화 복사본)

COMMENT ON COLUMN public.campaigns.brand_ja IS
  'brands.name_ja 동기화 복사본. brands UPDATE 트리거(173)가 자동 갱신. 인플 표시 우선순위 1위.';
COMMENT ON COLUMN public.campaigns.brand_en IS
  'brands.name_en 동기화 복사본. brands UPDATE 트리거(173)가 자동 갱신. 표시 폴백 2위(관리자·인플 공용).';

-- 기존 캠페인 백필 (brand_id IS NOT NULL 행만 대상 — 외부 캠페인은 brand 직접 입력 유지)
UPDATE public.campaigns c
SET
  brand_ja = b.name_ja,
  brand_en = b.name_en
FROM public.brands b
WHERE c.brand_id = b.id
  AND c.brand_id IS NOT NULL;

-- 백필 결과 확인용 (적용 후 SQL Editor 에서 실행)
-- SELECT count(*) AS total,
--        count(*) FILTER (WHERE brand_ja IS NOT NULL) AS has_ja,
--        count(*) FILTER (WHERE brand_en IS NOT NULL) AS has_en,
--        count(*) FILTER (WHERE brand_id IS NULL)     AS no_brand_id
-- FROM public.campaigns;
