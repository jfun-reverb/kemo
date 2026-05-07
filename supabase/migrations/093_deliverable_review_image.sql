-- ============================================================
-- 093_deliverable_review_image.sql
-- purpose  : monitor(리뷰어) 결과물 2단계화 — review_image 종류 추가
--            1단계: 영수증(receipt) — 구매 증빙
--            2단계: 리뷰 이미지(review_image) — 게시된 리뷰 캡처
--
-- 변경 내용:
--   - deliverables.kind CHECK 제약을 ('receipt','post','review_image')로 확장
--   - 트리거·RLS 정책·dual-write 트리거는 kind 컬럼을 참조하지 않으므로
--     추가 수정 없이 review_image에도 자동 적용됨 (검증 완료)
--   - 이미지 주소는 기존 receipt_url 컬럼을 재사용 (신규 컬럼 없음)
--   - 마감일은 campaigns.submission_end 공용 (별도 컬럼 없음)
--   - 1장 제약은 클라이언트 화면에서만 강제 (DB UNIQUE INDEX 없음)
--   - 반려 사유는 기존 lookup_values kind='reject_reason' 6종 재사용
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. deliverables.kind CHECK 제약 확장
--    기존: ('receipt', 'post')
--    변경: ('receipt', 'post', 'review_image')
--
--    영향:
--    - 기존 데이터(receipt/post 행)는 CHECK 통과 — 데이터 손상 없음
--    - 기존 제약은 035에서 인라인 CHECK로 정의 → PostgreSQL이 자동 이름 부여.
--      이름이 'deliverables_kind_check' 가 아닐 가능성에 대비, DO 블록으로
--      kind 컬럼에 정의된 CHECK를 동적으로 찾아 DROP한 뒤 새 이름으로 ADD.
--    - deliverables 테이블에 현재 데이터가 있어도 제약 확장은 안전
-- ============================================================

DO $$
DECLARE
  v_conname text;
BEGIN
  -- kind 컬럼 단일에만 적용된 CHECK 제약을 찾음
  -- (review_image 가 이미 포함된 새 제약은 제외 — 멱등 적용 대비)
  SELECT conname INTO v_conname
  FROM pg_constraint
  WHERE conrelid = 'public.deliverables'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) ILIKE '%kind%'
    AND pg_get_constraintdef(oid) NOT ILIKE '%review_image%'
  LIMIT 1;

  IF v_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.deliverables DROP CONSTRAINT %I', v_conname);
    RAISE NOTICE '[093] dropped constraint: %', v_conname;
  ELSE
    RAISE NOTICE '[093] no kind CHECK constraint to drop (already migrated?)';
  END IF;
END;
$$;

-- 새 이름으로 ADD (이번부터 명시 이름이라 향후 마이그레이션 안정)
ALTER TABLE public.deliverables
  ADD CONSTRAINT deliverables_kind_check
  CHECK (kind IN ('receipt', 'post', 'review_image'));

COMMENT ON COLUMN public.deliverables.kind IS
  'receipt: 영수증(monitor 1단계) / post: 게시물 URL(gifting·visit) / review_image: 리뷰 캡처 이미지(monitor 2단계). receipt_url 컬럼을 review_image도 재사용.';


-- ============================================================
-- 2. 트리거·RLS 검증 결과 (변경 없음, 주석으로 기록)
--
--    record_deliverable_status_event (035→073):
--      kind 컬럼을 참조하지 않음 → review_image에 자동 적용. 수정 불필요.
--
--    notify_deliverable_status (037):
--      kind 컬럼을 참조하지 않음 → review_image 반려/승인 시 자동 알림 생성.
--      알림 title은 "成果物が差し戻されました" 고정 — review_image 전용 문구
--      분기가 필요하면 별도 마이그레이션에서 추가 (현 단계 허용)
--
--    sync_receipt_to_deliverable (035 dual-write):
--      receipts 테이블에서만 작동, kind='receipt' 하드코딩.
--      review_image와 완전히 무관 — 수정 불필요.
--
--    행 단위 보안 정책(RLS) (035+042):
--      모든 정책이 kind 무관 — review_image INSERT/UPDATE/SELECT 자동 적용.
--      추가 정책 불필요.
-- ============================================================


COMMIT;


-- ============================================================
-- 검증 쿼리 (적용 후 실행)
-- ============================================================
/*

-- [1] CHECK 제약 변경 확인
SELECT
  conname,
  pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.deliverables'::regclass
  AND contype = 'c'
  AND conname LIKE '%kind%';
-- 기대값: deliverables_kind_check | CHECK (kind = ANY (ARRAY['receipt','post','review_image']))

-- [2] review_image 행 INSERT 시뮬레이션 (개발 DB에서만)
-- application_id, user_id, campaign_id는 실제 존재하는 값으로 교체
-- status='pending' 사용 (deliverables.status CHECK 허용값: pending/approved/rejected)
INSERT INTO public.deliverables (
  application_id, user_id, campaign_id,
  kind, status, receipt_url, submitted_at
) VALUES (
  '<application_uuid>',
  '<user_uuid>',
  '<campaign_uuid>',
  'review_image',
  'pending',
  'https://example.com/test.jpg',
  now()
);
-- 기대값: INSERT 성공 (kind·status CHECK 통과)
-- 확인 후 DELETE로 롤백

-- [3] 기존 receipt/post 행 영향 없음 확인
SELECT kind, COUNT(*) FROM public.deliverables GROUP BY kind ORDER BY kind;
-- 기대값: receipt/post 행 수 변동 없음

*/


-- ============================================================
-- 롤백 (적용 취소 시 아래 실행)
-- 주의: review_image 행이 이미 INSERT된 경우 DELETE 먼저 수행 후 롤백할 것
-- ============================================================
/*

BEGIN;

-- review_image 행 존재 여부 확인
SELECT COUNT(*) FROM public.deliverables WHERE kind = 'review_image';
-- 0이면 롤백 안전. 1 이상이면 해당 행 처리 후 롤백.

ALTER TABLE public.deliverables
  DROP CONSTRAINT IF EXISTS deliverables_kind_check;

ALTER TABLE public.deliverables
  ADD CONSTRAINT deliverables_kind_check
  CHECK (kind IN ('receipt', 'post'));

COMMIT;

*/
