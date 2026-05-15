-- ============================================================
-- 126_brand_app_paid_at.sql
-- 브랜드 서베이 — 오리엔시트 전달 컬럼을 입금 날짜로 분리
--
-- 배경:
--   사용자 의도 — "오리엔시트 전달 열에 입력한 날짜는 사실 입금 날짜였다".
--   기존 orient_sheet_sent_at (마이그레이션 112) 컬럼이 입금일 의미로 사용되어 왔음.
--   신규 paid_at 컬럼으로 분리하고, 오리엔시트 전달 열은 URL 만 유지.
--
-- 변경 범위:
--   (1) brand_applications.paid_at timestamptz NULL 컬럼 추가
--   (2) 백필 — orient_sheet_sent_at → paid_at 전체 복사 (NULL 도 NULL 로)
--   (3) brand_applications.orient_sheet_sent_at 컬럼 DROP
--   (4) orient_sheet_sent_url 컬럼은 그대로 보존 (URL 만 남음)
--
-- 변경 이력 트리거:
--   현재 record_brand_application_history (079+122) 는 orient_sheet_sent_at 을 추적하지 않음.
--   paid_at 도 동일 패턴 유지 (추적 안 함). 필요해지면 추후 별도 마이그레이션에서 추가.
--
-- 사양서: docs/specs/2026-05-13-brand-app-product-admin-memo.md (구현 결과 섹션에 후속 항목)
-- 작성일: 2026-05-15
-- ============================================================


-- ============================================================
-- SECTION 1. paid_at 컬럼 추가
-- ============================================================
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS paid_at timestamptz NULL;

COMMENT ON COLUMN public.brand_applications.paid_at IS
  '[126] 입금 확인 일자 (운영자 수동 입력). 신청 목록 「입금 날짜」 컬럼에서 인라인 편집. status=paid 단계의 실제 입금일 기록용.';


-- ============================================================
-- SECTION 2. 백필 — orient_sheet_sent_at → paid_at
--   전체 행 복사 (NULL 도 그대로). 의미 변환 — 운영자가 입력해온 "오리엔시트 전달 일자" 가
--   실제로는 입금일이었으므로 paid_at 으로 이전.
-- ============================================================
UPDATE public.brand_applications
SET paid_at = orient_sheet_sent_at
WHERE orient_sheet_sent_at IS NOT NULL;


-- ============================================================
-- SECTION 3. orient_sheet_sent_at 컬럼 DROP
--   orient_sheet_sent_url 은 보존 (URL 표시는 유지)
-- ============================================================
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS orient_sheet_sent_at;


-- ============================================================
-- SECTION 4. PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (개발/운영 DB 적용 후)
-- ============================================================
/*

-- [V0-COUNT] 적용 전 — orient_sheet_sent_at IS NOT NULL 행 수 (백필 직전 캡쳐)
-- SECTION 2 직전에 실행하세요. 결과를 V2 와 대조
SELECT COUNT(*) AS rows_with_orient_date_before
FROM public.brand_applications
WHERE orient_sheet_sent_at IS NOT NULL;

-- [V1] paid_at 컬럼 존재 + orient_sheet_sent_at 컬럼 제거 확인
SELECT column_name
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name='brand_applications'
  AND column_name IN ('paid_at', 'orient_sheet_sent_at', 'orient_sheet_sent_url')
ORDER BY column_name;
-- paid_at, orient_sheet_sent_url 만 반환 (orient_sheet_sent_at 사라짐)

-- [V2] 백필 결과 — paid_at IS NOT NULL 행 수가 V0-COUNT 와 일치해야 함
SELECT COUNT(*) AS rows_with_paid_at_after
FROM public.brand_applications
WHERE paid_at IS NOT NULL;

-- [V3] 백필 결과 샘플 5건
SELECT id, application_no, paid_at, orient_sheet_sent_url
FROM public.brand_applications
WHERE paid_at IS NOT NULL
ORDER BY paid_at DESC
LIMIT 5;

*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

-- 1. orient_sheet_sent_at 컬럼 복원
ALTER TABLE public.brand_applications
  ADD COLUMN IF NOT EXISTS orient_sheet_sent_at timestamptz NULL;

-- 2. 데이터 역방향 복사
UPDATE public.brand_applications
SET orient_sheet_sent_at = paid_at
WHERE paid_at IS NOT NULL;

-- 3. paid_at 컬럼 제거
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS paid_at;

NOTIFY pgrst, 'reload schema';

*/
