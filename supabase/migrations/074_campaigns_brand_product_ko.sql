-- 074_campaigns_brand_product_ko.sql
-- 2026-04-28
--
-- 목적: 캠페인 브랜드명·제품명 한국어 표기 컬럼 추가.
-- 배경: 관리자 신청관리 등에서 일본어 brand/product 데이터가 한글 환경 관리자에게 가독성 낮음.
--       자동 번역은 정확도·비용 한계가 있어 수동 입력 컬럼을 별도로 둠.
-- 동작: 캠페인 등록·편집 폼에서 한국어 입력란을 채우면 행 표시에서 우선 사용.
--       비어 있으면 기존 brand/product 원본 그대로 표시(폴백).
-- RLS: campaigns 정책은 그대로(SELECT 공개, CUD 관리자만). 신규 컬럼은 동일 정책 적용.

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS brand_ko text,
  ADD COLUMN IF NOT EXISTS product_ko text;

COMMENT ON COLUMN public.campaigns.brand_ko   IS '브랜드명 한국어 표기 (선택). 비어있으면 brand 컬럼 폴백';
COMMENT ON COLUMN public.campaigns.product_ko IS '제품명 한국어 표기 (선택). 비어있으면 product 컬럼 폴백';
