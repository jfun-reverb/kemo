-- ============================================================
-- 084_brands_contacts_jsonb.sql
-- brands.contacts jsonb 컬럼 신규 — 다중 담당자 + 대표 지정
--
-- 배경:
--   PR1(082)에서 단일 primary_contact_name/phone/email 컬럼으로 시작했으나
--   사용자 요구로 한 브랜드에 여러 담당자를 두고 그 중 1명을 대표로 지정하는
--   구조로 확장.
--
-- 구조: contacts jsonb array
--   [{ id, name, phone, email, is_primary }, ...]
--   - id: 클라이언트 생성 UUID (수정·삭제 식별용)
--   - is_primary: 정확히 1개 true (또는 0개) — 검증은 클라이언트 책임
--
-- 마이그레이션:
--   기존 brands.primary_* 데이터를 contacts 첫 항목으로 이전 (is_primary=true)
--   primary_* 컬럼은 즉시 DROP하지 않음 (PR6 cleanup 시점)
--
-- 작성일: 2026-05-04
-- ============================================================

BEGIN;

-- 1. 컬럼 추가
ALTER TABLE public.brands
  ADD COLUMN IF NOT EXISTS contacts jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.brands.contacts IS
  '[084] 다중 담당자 배열. [{id, name, phone, email, is_primary}]. is_primary는 최대 1개.';

-- 2. 기존 primary_* 데이터를 contacts 첫 항목으로 이전 (is_primary=true)
--    NULL인 컬럼들도 빈 문자열 대신 null로 보존
UPDATE public.brands
SET contacts = jsonb_build_array(
  jsonb_build_object(
    'id',         gen_random_uuid()::text,
    'name',       primary_contact_name,
    'phone',      primary_phone,
    'email',      primary_email,
    'is_primary', true
  )
)
WHERE jsonb_array_length(contacts) = 0
  AND (primary_contact_name IS NOT NULL
    OR primary_phone IS NOT NULL
    OR primary_email IS NOT NULL);

COMMIT;


-- ============================================================
-- 검증 SQL (별도 실행)
-- ============================================================
/*
-- 1. 컬럼 추가 확인
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name='brands' AND column_name='contacts';

-- 2. 마이그레이션된 brands 확인
SELECT brand_no, name, jsonb_array_length(contacts) AS contacts_count, contacts
FROM public.brands
ORDER BY brand_no
LIMIT 5;

-- 3. is_primary가 true인 contact가 있는 brands 수
SELECT COUNT(*) FROM public.brands WHERE contacts @> '[{"is_primary": true}]'::jsonb;
*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*
ALTER TABLE public.brands DROP COLUMN IF EXISTS contacts;
*/
