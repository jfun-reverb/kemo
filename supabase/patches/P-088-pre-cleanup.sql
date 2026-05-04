-- ============================================================
-- P-088-pre-cleanup.sql
-- 재채번 전 테스트/이상 brands 사전 정리
--
-- 용도: 패치 (one-off) — 088 마이그레이션 적용 전 운영 DB에서만 실행
-- 실행 환경: 운영서버 SQL Editor (twofagomeizrtkwlhsuv)
--
-- 실행 순서:
--   1. STEP A: 이상 데이터 식별 쿼리 실행 → 결과 확인
--   2. STEP B: brand_applications 연결 건 확인
--   3. STEP C: 관리자 승인 후 DELETE 실행 (ROLLBACK 포함)
--
-- 주의:
--   - brands에 brand_applications FK (ON DELETE RESTRICT)가 걸려 있으므로
--     brand_applications를 먼저 처리하지 않으면 DELETE 실패
--   - 테스트 신청 건은 실데이터가 아니므로 함께 삭제 가능
--   - 불확실한 브랜드는 status='archived'로 soft delete
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- STEP A: 이상 데이터 식별 (읽기 전용, 삭제 전 반드시 실행)
-- ============================================================

SELECT
  b.id,
  b.brand_no,
  b.name,
  b.status,
  b.total_applications,
  b.created_at::date AS created_date,
  CASE
    WHEN b.name ~ '^\[QA'       THEN 'QA_TEST_BRACKET'
    WHEN b.name ~ '^\[TEST'     THEN 'TEST_BRACKET'
    WHEN b.name ~ '<script'     THEN 'XSS_PATTERN'
    WHEN b.name ~ '^[0-9]+$'   THEN 'NUMBERS_ONLY'
    WHEN length(b.name) < 3    THEN 'TOO_SHORT'
    ELSE 'UNKNOWN_SUSPECT'
  END AS suspect_reason
FROM public.brands b
WHERE
  b.name ~ '^\[QA'
  OR b.name ~ '^\[TEST'
  OR b.name ~ '<script'
  OR b.name ~ '^[0-9]+$'
  OR length(b.name) < 3
ORDER BY b.created_at;


-- ============================================================
-- STEP B: 이상 brands에 연결된 brand_applications 확인
-- ============================================================

SELECT
  b.brand_no,
  b.name AS brand_name,
  ba.id,
  ba.application_no,
  ba.status,
  ba.created_at::date AS app_date
FROM public.brand_applications ba
JOIN public.brands b ON b.id = ba.brand_id
WHERE
  b.name ~ '^\[QA'
  OR b.name ~ '^\[TEST'
  OR b.name ~ '<script'
  OR b.name ~ '^[0-9]+$'
  OR length(b.name) < 3
ORDER BY b.name, ba.created_at;


-- ============================================================
-- STEP C: 승인 후 삭제 실행 (관리자 확인 후 ROLLBACK → COMMIT 전환)
--
-- 패턴 1: 연결된 brand_applications가 테스트 데이터 → 함께 삭제
-- 패턴 2: 연결된 brand_applications가 실데이터 → brands만 archived (보존)
-- ============================================================

BEGIN;

-- C-0. brand_application_memos 먼저 삭제
--   081 트리거(record_brand_application_memo_history) AFTER DELETE 가
--   brand_application_history에 memo_deleted 행을 INSERT하므로
--   application 행이 살아 있는 동안 memos를 먼저 정리해야 FK 위반 회피.
DELETE FROM public.brand_application_memos
WHERE application_id IN (
  SELECT ba.id FROM public.brand_applications ba
  JOIN public.brands b ON b.id = ba.brand_id
  WHERE
    b.name ~ '^\[QA'
    OR b.name ~ '^\[TEST'
    OR b.name ~ '<script'
    OR b.name ~ '^[0-9]+$'
    OR length(b.name) < 3
);

-- C-0b. brand_application_history 명시 DELETE (FK CASCADE/RESTRICT 무관 안전)
DELETE FROM public.brand_application_history
WHERE application_id IN (
  SELECT ba.id FROM public.brand_applications ba
  JOIN public.brands b ON b.id = ba.brand_id
  WHERE
    b.name ~ '^\[QA'
    OR b.name ~ '^\[TEST'
    OR b.name ~ '<script'
    OR b.name ~ '^[0-9]+$'
    OR length(b.name) < 3
);

-- C-1. 테스트 brand_applications 삭제 (RESTRICT FK 해제)
DELETE FROM public.brand_applications
WHERE brand_id IN (
  SELECT id FROM public.brands
  WHERE
    name ~ '^\[QA'
    OR name ~ '^\[TEST'
    OR name ~ '<script'
    OR name ~ '^[0-9]+$'
    OR length(name) < 3
);

-- C-2. 테스트 brands 삭제
DELETE FROM public.brands
WHERE
  name ~ '^\[QA'
  OR name ~ '^\[TEST'
  OR name ~ '<script'
  OR name ~ '^[0-9]+$'
  OR length(name) < 3
;

-- 삭제 결과 확인
SELECT count(*) AS remaining_suspect
FROM public.brands
WHERE
  name ~ '^\[QA'
  OR name ~ '^\[TEST'
  OR name ~ '<script'
  OR name ~ '^[0-9]+$'
  OR length(name) < 3;
-- 0이어야 함

-- 확인 후: ROLLBACK (취소) 또는 COMMIT (확정)
ROLLBACK;
-- → 삭제 결과 확인 완료 후 COMMIT으로 교체


-- ============================================================
-- C-3 (대안): 연결 데이터가 있어서 삭제 불가 → soft delete
-- ============================================================
/*
UPDATE public.brands
SET status = 'archived'
WHERE
  name ~ '^\[QA'
  OR name ~ '^\[TEST'
  OR name ~ '<script'
  OR name ~ '^[0-9]+$'
  OR length(name) < 3
;
-- brands는 archived, brand_applications는 유지 (실데이터 보존)
*/
