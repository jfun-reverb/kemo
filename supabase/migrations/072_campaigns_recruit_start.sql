-- ============================================================
-- 072_campaigns_recruit_start.sql
-- 캠페인 모집 시작일 컬럼 추가 (모집 마감일 단일 → 모집 기간 확장)
-- 작성일: 2026-04-27
-- ============================================================
-- 배경:
--   기존 캠페인 폼은 "모집 마감일(deadline)" 단일 일자만 받았다.
--   인플루언서 화면의 "募集期間" 표시는 "오늘 ~ deadline" 으로
--   현재 시점을 시작일처럼 동적 계산했고, 명시적인 모집 시작일은
--   DB에 저장되지 않았다.
--
--   운영 흐름상 캠페인을 미리 등록하고 며칠 뒤에 모집을 시작하는
--   시나리오가 필요해서, 모집 시작일 컬럼을 추가한다.
--
-- 정책:
--   recruit_start date NULL 추가 (NULL 허용)
--   - NULL = 즉시 모집 (기존 동작과 동일하게 fallback 처리)
--   - 신규 캠페인은 폼에서 명시적으로 입력
--   deadline 의미는 변경 없음 (모집 종료일로 자연 보존)
--   기존 캠페인 백필 안 함 — recruit_start NULL 그대로 두고 코드에서 fallback
--
-- 영향:
--   - campaigns 테이블에 recruit_start date 컬럼 1개 추가
--   - RLS 정책 영향 없음 (campaigns SELECT 공개·CUD 관리자 정책 그대로)
--   - 트리거/함수 영향 없음
--   - 인덱스 추가 안 함 (조회 빈도 낮음)
--
-- 클라이언트 측 후속 작업 (이 마이그레이션과 같은 PR에 포함):
--   - 캠페인 폼: 모집 마감일 단일 input → flatpickr range picker (시작 ~ 종료)
--   - autoOpenCampaigns(camps) 신규: status='scheduled' && recruit_start <= now → 'active'
--   - validateCampDateRanges 경계: deadline ~ post_deadline → recruit_start ~ post_deadline
--   - 인플루언서 募集期間 표시: recruit_start || new Date() ~ deadline
--
-- 롤백:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS recruit_start;
-- ============================================================

BEGIN;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS recruit_start date NULL;

COMMENT ON COLUMN public.campaigns.recruit_start IS
  '모집 시작일. NULL=즉시 모집 (인플루언서 화면에서 오늘부터로 표시 fallback). deadline(=모집 종료일)과 함께 모집 기간을 구성.';

COMMIT;

-- ============================================================
-- 검증 쿼리 (실행 후)
-- ============================================================
-- [1] 컬럼 추가 확인
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_schema='public' AND table_name='campaigns' AND column_name='recruit_start';
--
-- [2] 기존 캠페인은 모두 NULL
-- SELECT count(*) FILTER (WHERE recruit_start IS NULL) AS null_count,
--        count(*) AS total
-- FROM public.campaigns;
--
-- [3] 무결성 (recruit_start 입력된 캠페인은 deadline 이전이어야 함 — 폼 검증으로 보장)
-- SELECT count(*) FROM public.campaigns
-- WHERE recruit_start IS NOT NULL AND deadline IS NOT NULL
--   AND recruit_start::date > deadline::date;
-- 0 이어야 함
-- ============================================================
