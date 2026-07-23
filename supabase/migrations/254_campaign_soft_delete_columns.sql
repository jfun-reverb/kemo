-- ============================================================
-- 254_campaign_soft_delete_columns.sql
-- 캠페인 삭제 복구(soft delete) PR 1 — 1/5 (컬럼 추가)
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md §설계 ①
--
-- 목적:
--   관리자가 캠페인을 삭제하면 지금은 즉시 완전 삭제(hard delete)라 되돌릴 방법이
--   없다. campaigns.deleted_at / deleted_by 를 추가해 "30일간 보관 후 자동 완전
--   삭제"(soft delete)로 바꾸기 위한 밑준비. 개인정보(신청·결과물)는 이 컬럼과
--   무관하게 삭제 시점에 그대로 즉시 완전 파기(현행 유지) — 보관되는 것은
--   campaigns 행(캠페인 메타데이터)뿐이다.
--
-- 변경 사항:
--   1. campaigns.deleted_at timestamptz NULL — NULL=활성, 값 있으면 보관(삭제) 중
--   2. campaigns.deleted_by uuid NULL — 삭제를 실행한 관리자 auth_id (감사용, FK 없음.
--      admins 탈퇴 후에도 "누가 삭제했는지" 이력을 남기기 위해 참조 무결성 제약을
--      걸지 않음 — influencer_flags.updated_by 등 기존 감사 컬럼 패턴과 동일)
--   3. 부분 인덱스 idx_campaigns_deleted_at — 「삭제됨」 탭 조회·자동 완전삭제 배치
--      (purge_expired_deleted_campaigns, 후속 마이그레이션 258) 양쪽에서 사용
--
-- 이 마이그레이션은 컬럼·인덱스만 추가한다. 실제 동작(보관삭제·복구·완전삭제
-- 함수)은 255~258 에서 이어진다. 컬럼만 있는 상태에서는 기존 executeDeleteCampaign()
-- (dev/js/admin.js, hard delete)이 그대로 동작하므로 회귀 없음 — deleted_at 은
-- 아직 아무 함수도 세팅하지 않는다(PR 2 에서 admin.js 가 soft_delete_campaign RPC
-- 호출로 교체될 때까지 전부 NULL 유지).
--
-- 롤백:
--   DROP INDEX IF EXISTS public.idx_campaigns_deleted_at;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS deleted_at;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS deleted_by;
-- ============================================================

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL;

COMMENT ON COLUMN public.campaigns.deleted_at IS
  '[254] 관리자 보관 삭제(soft delete) 시각. NULL=활성 캠페인, 값이 있으면 30일간 '
  '「삭제됨」 탭에 보관 후 자동 완전삭제 대상(purge_expired_deleted_campaigns, 258). '
  '이 시점에 해당 캠페인의 신청·결과물(개인정보)은 이미 즉시 완전 파기됨(soft_delete_campaign, 255).';

COMMENT ON COLUMN public.campaigns.deleted_by IS
  '[254] 보관 삭제를 실행한 관리자 auth_id (감사용). FK 없음 — admins 행이 나중에 '
  '삭제/권한해제 되어도 "누가 삭제했는지" 이력이 끊기지 않게 하기 위함.';

CREATE INDEX IF NOT EXISTS idx_campaigns_deleted_at
  ON public.campaigns (deleted_at)
  WHERE deleted_at IS NOT NULL;

-- PostgREST 스키마 캐시 리로드 (신규 컬럼 즉시 반영 — 252 등 최근 컬럼 마이그레이션 패턴)
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (마이그레이션 적용 후 SQL Editor에서 실행 — 1단계)
-- ============================================================
-- [1] 컬럼 존재 + nullable 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns'
--    AND column_name IN ('deleted_at','deleted_by');
-- 기대값: 2행, 둘 다 is_nullable='YES'

-- [2] 인덱스 존재 확인
-- SELECT indexname, indexdef FROM pg_indexes
--  WHERE schemaname='public' AND indexname='idx_campaigns_deleted_at';
-- 기대값: 1행, indexdef 에 "WHERE (deleted_at IS NOT NULL)" 포함

-- [3] 기존 캠페인 전부 NULL(회귀 없음) 확인
-- SELECT count(*) AS total, count(deleted_at) AS deleted_count FROM public.campaigns;
-- 기대값: deleted_count = 0 (아직 아무도 삭제 처리 안 했으므로)
