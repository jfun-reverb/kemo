-- ============================================================
-- 124_brand_app_memo_dedup_legacy.sql
-- 080 백필과 123 백필의 중복 legacy 메모 정리
--
-- 배경:
--   080 (2026-04-22) 적용 시점에 brand_applications.admin_memo 컬럼에 있던 데이터를
--   brand_application_memos 로 백필 (author_name='(legacy)'). 12건.
--
--   080 이후 admin_memo 컬럼이 그대로 남아있어 추가 신청이 컬럼에 메모 기록. 총 14건.
--
--   122 (2026-05-14) SECTION 1 에서 admin_memo → products[0].admin_memo 로 다시 백필.
--   123 (2026-05-14) SECTION 4 에서 products[i].admin_memo → brand_application_memos 로
--     또다시 백필 (제품별 product_idx 포함). 14건 INSERT.
--
--   결과: 080 의 12건 + 123 의 14건 = 26건. 그중 12쌍이 동일 텍스트 중복.
--
-- 변경 범위:
--   (1) 081 트리거 임시 비활성화 (memo_deleted 노이즈 history 행 방지)
--   (2) author_name='(legacy)' 중 같은 (application_id, product_idx, text) 페어에
--       2건 이상 존재하며 brand_application_history.memo_added 에 기록 없는 행 삭제
--       → 080 백필분만 정확히 식별되어 제거됨
--       → 123 백필분(history 에 memo_added 기록 있음)은 보존
--   (3) 081 트리거 재활성화
--
-- 운영 DB 적용:
--   122 + 123 적용 후 동일하게 124 실행. 결과 멱등.
--
-- 사양서: docs/specs/2026-05-13-brand-app-product-admin-memo.md
-- 작성일: 2026-05-14
-- ============================================================

BEGIN;


-- ============================================================
-- SECTION 1. 081 메모 변경 이력 트리거 임시 비활성화
--   이 마이그레이션의 DELETE 가 081 트리거를 호출하면 12건의
--   memo_deleted history 행이 의미 없는 노이즈로 누적됨.
-- ============================================================
ALTER TABLE public.brand_application_memos
  DISABLE TRIGGER trg_brand_app_memo_history;


-- ============================================================
-- SECTION 2. 중복 080 백필 행 삭제
--   삭제 기준 (모두 만족해야 함):
--     - author_name = '(legacy)'
--     - 같은 (application_id, product_idx, text) 조합에 다른 legacy 행이 1건 이상 존재
--     - brand_application_history 에 이 행의 id 로 memo_added 기록 없음 (= 080 백필)
-- ============================================================
DELETE FROM public.brand_application_memos m
WHERE m.author_name = '(legacy)'
  AND EXISTS (
    SELECT 1
    FROM public.brand_application_memos m2
    WHERE m2.author_name = '(legacy)'
      AND m2.application_id = m.application_id
      AND m2.product_idx = m.product_idx
      AND m2.text = m.text
      AND m2.id <> m.id
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.brand_application_history h
    WHERE h.field_name = 'memo_added'
      AND (h.new_value->>'id')::uuid = m.id
  );


-- ============================================================
-- SECTION 3. 081 트리거 재활성화
-- ============================================================
ALTER TABLE public.brand_application_memos
  ENABLE TRIGGER trg_brand_app_memo_history;


COMMIT;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL
-- ============================================================
/*

-- [V1] 중복 그룹 없어야 함 (0건 반환)
SELECT application_id, product_idx, text, COUNT(*) AS legacy_count
FROM public.brand_application_memos
WHERE author_name='(legacy)'
GROUP BY application_id, product_idx, text
HAVING COUNT(*) > 1;

-- [V2] 전체 legacy 메모 수 (개발 DB 기대: 14 = 123 백필분만 남음)
SELECT COUNT(*) AS legacy_total
FROM public.brand_application_memos
WHERE author_name='(legacy)';
-- 14

-- [V3] history memo_added 의 id 와 현재 메모 행의 id 일치도 (14)
SELECT COUNT(*) AS history_to_memo_link_count
FROM public.brand_application_history h
JOIN public.brand_application_memos m
  ON (h.new_value->>'id')::uuid = m.id
WHERE h.field_name='memo_added'
  AND m.author_name='(legacy)';
-- 14

-- [V4] memo_deleted 노이즈 history 행이 없어야 함 (이번 마이그레이션 적용 시점 전후)
--      → 트리거 비활성화로 0건 추가됐어야 함
SELECT COUNT(*) AS memo_deleted_after_124
FROM public.brand_application_history
WHERE field_name='memo_deleted'
  AND changed_at >= (now() - interval '1 hour');
-- 0

*/


-- ============================================================
-- 롤백 SQL (수동 복원, 정상 흐름에서는 불필요)
-- ============================================================
/*

-- 1. 080 백필 데이터 복원 (admin_memo 컬럼 → memo 행 재생성)
-- 122 가 이미 컬럼을 DROP 했으므로 직접 복원 불가
-- legacy 백필 텍스트는 현재 brand_application_memos 의 123 백필 행으로 유일하게 보존됨
-- 즉 124 가 삭제하는 12건은 같은 텍스트가 어차피 보존되어 있어 데이터 손실 없음

NOTIFY pgrst, 'reload schema';

*/
