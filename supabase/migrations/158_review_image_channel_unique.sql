-- =============================================================================
-- 마이그레이션 158: 채널별 리뷰 이미지 부분 유니크 인덱스
-- 제목    : deliverables review_image 행 — 같은 신청 + 같은 채널 중복 방지
-- 의존    : 마이그레이션 093 (kind='review_image' enum 활성화)
-- 대상    : 개발서버 + 운영서버
-- 사양서  : docs/specs/2026-05-28-multichannel-deliverable-split.md §3-2
-- =============================================================================
--
-- 목적:
--   하나의 신청(application_id)에서 같은 채널(post_channel)의 리뷰 이미지는
--   1행만 존재해야 한다. 재제출은 기존 행의 receipt_url을 UPDATE하는 방식으로
--   처리하므로 INSERT가 중복 발생하지 않는다.
--
-- 기존 NULL 행 처리:
--   기존 kind='review_image' 행은 post_channel=NULL로 저장돼 있음 (레거시).
--   이 인덱스는 WHERE post_channel IS NOT NULL 부분 인덱스이므로
--   NULL 행에는 적용되지 않는다 — 기존 데이터 영향 없음.
--
-- 신규 정책:
--   마이그레이션 158 이후 신규 신청부터 채널별로 post_channel을 채워 INSERT.
--   기존 NULL 행(레거시)은 그대로 grandfather 처리.
--
-- 롤백:
--   DROP INDEX IF EXISTS public.deliverables_review_image_app_channel_uniq;
-- =============================================================================

-- 적용 전 검증 (운영 적용 전 SQL Editor에서 실행하여 차이 확인):
-- SELECT
--   COUNT(*)                       AS total_review_image_rows,
--   COUNT(post_channel)            AS rows_with_channel,
--   COUNT(*) - COUNT(post_channel) AS null_channel_rows
-- FROM public.deliverables
-- WHERE kind = 'review_image';
--
-- 기대값: null_channel_rows = total_review_image_rows (현재 전부 NULL이 정상)
-- 이 SQL은 마이그레이션 파일 실행 전에 별도로 확인하는 용도임.

-- -----------------------------------------------------------------------------
-- 부분 유니크 인덱스 생성 (멱등)
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS deliverables_review_image_app_channel_uniq
  ON public.deliverables (application_id, post_channel)
  WHERE kind = 'review_image' AND post_channel IS NOT NULL;

-- =============================================================================
-- 적용 후 검증 (SQL Editor에서 아래 쿼리 실행하여 인덱스 존재 확인):
-- SELECT indexname, indexdef
-- FROM pg_indexes
-- WHERE indexname = 'deliverables_review_image_app_channel_uniq';
--
-- 기대값: 1행 반환 (인덱스 정의 포함)
-- =============================================================================
