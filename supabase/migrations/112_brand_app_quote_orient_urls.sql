-- migration 112: brand_applications에 견적서 전달 URL + 오리엔시트 전달 날짜·URL 컬럼 추가
-- 롤백:
--   ALTER TABLE public.brand_applications
--     DROP COLUMN IF EXISTS quote_sent_url,
--     DROP COLUMN IF EXISTS orient_sheet_sent_at,
--     DROP COLUMN IF EXISTS orient_sheet_sent_url;

BEGIN;

ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS quote_sent_url       text NULL,
  ADD COLUMN IF NOT EXISTS orient_sheet_sent_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS orient_sheet_sent_url text NULL;

COMMENT ON COLUMN public.brand_applications.quote_sent_url IS
  '견적서 전달 URL (Google Drive, Notion 등 외부 링크). http/https 스킴만 허용, 클라이언트에서 safeBrandUrl 검증 후 저장.';

COMMENT ON COLUMN public.brand_applications.orient_sheet_sent_at IS
  '오리엔시트 전달 시각 (JST 기준 날짜를 UTC timestamptz로 저장). NULL이면 미전달.';

COMMENT ON COLUMN public.brand_applications.orient_sheet_sent_url IS
  '오리엔시트 문서 URL (Google Drive, Notion 등 외부 링크). http/https 스킴만 허용, 클라이언트에서 safeBrandUrl 검증 후 저장.';

-- RLS 정책 변경 없음 — 기존 brand_applications 정책(관리자만 SELECT/UPDATE/DELETE)이 신규 컬럼에 그대로 적용됨.
-- 인덱스 추가 없음 — 텍스트 URL 컬럼이고 검색 대상 아님.

COMMIT;
