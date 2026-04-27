-- ============================================================
-- 071_admin_notice_status.sql
-- admin_notices 게시 상태(draft/published) 도입
-- 작성일: 2026-04-27
-- ============================================================
-- 배경:
--   migration 063 도입 후 공지가 작성 즉시 모든 관리자(사이드바 배지·
--   로그인 팝업·대시보드 카드·목록)에 노출되어, 작성 중인 미완성 공지가
--   의도치 않게 표시되는 사고 위험. "초안 → 게시" 분리.
--
-- 정책:
--   상태       : 2단계 (draft / published) — 향후 'scheduled' 추가 호환 보장
--   가시성     : draft는 super_admin + 작성자 본인만 SELECT 가능
--   편집 정책  : (앱 레벨) published 본문 변경 시 자동 draft 회귀
--                + "게시 유지" 보조 액션. DB는 status 컬럼만 관리.
--   리셋       : 재게시 시 admin_notice_reads 자동 리셋 안 함.
--                중대 변경은 새 공지로 작성하는 운영 가이드.
--   기존 데이터: 모두 published 백필 (운영 중인 공지 끊기지 않게)
--
-- 영향:
--   - admin_notices: status, published_at, published_by, published_by_name 컬럼 추가
--   - admin_notices RLS SELECT 재정의 (draft 가시성 분기)
--   - admin_notices 인덱스 1개 추가 (게시 공지 정렬용)
--
-- 롤백 (한 트랜잭션으로 묶어 부분 실행 방지):
--   BEGIN;
--   DROP POLICY IF EXISTS "admin_notices_select" ON public.admin_notices;
--   CREATE POLICY "admin_notices_select" ON public.admin_notices
--     FOR SELECT TO authenticated USING (public.is_admin());
--   DROP INDEX IF EXISTS idx_admin_notices_published_list;
--   ALTER TABLE public.admin_notices
--     DROP COLUMN IF EXISTS status,
--     DROP COLUMN IF EXISTS published_at,
--     DROP COLUMN IF EXISTS published_by,
--     DROP COLUMN IF EXISTS published_by_name;
--   COMMIT;
-- ============================================================

BEGIN;

-- ============================================================
-- Step 1: 컬럼 추가
-- ============================================================
ALTER TABLE public.admin_notices
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','published')),
  ADD COLUMN IF NOT EXISTS published_at timestamptz,
  ADD COLUMN IF NOT EXISTS published_by uuid,
  ADD COLUMN IF NOT EXISTS published_by_name text;

COMMENT ON COLUMN public.admin_notices.status              IS '게시 상태: draft(초안, 작성자/super만 SELECT) | published(게시, 모든 관리자 SELECT). 노출 채널 4개(사이드바 배지/로그인 팝업/대시보드 카드/목록)는 published만 노출.';
COMMENT ON COLUMN public.admin_notices.published_at        IS '최초 published 전환 시각. 이 시각이 모든 관리자 미읽음 기준. 재게시해도 갱신하지 않음(앱 정책).';
COMMENT ON COLUMN public.admin_notices.published_by        IS '게시한 관리자 auth uid (감사용).';
COMMENT ON COLUMN public.admin_notices.published_by_name   IS '게시한 관리자 이름 (FK 끊겨도 표시 유지).';

-- ============================================================
-- Step 2: 기존 데이터 백필 (모두 published + published_at = created_at)
--   DEFAULT 'draft' 적용 후, 마이그레이션 직전까지의 모든 행을
--   published 로 명시 전환. 신규 INSERT 부터 draft 기본값 적용.
-- ============================================================
UPDATE public.admin_notices
SET status            = 'published',
    published_at      = COALESCE(published_at, created_at),
    published_by      = COALESCE(published_by, created_by),
    published_by_name = COALESCE(published_by_name, created_by_name)
WHERE status = 'draft';

-- ============================================================
-- Step 3: 게시 공지 정렬용 인덱스
--   목록 / 대시보드 카드 정렬 키:
--   (status, is_pinned DESC, pinned_at DESC NULLS LAST, published_at DESC NULLS LAST)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_admin_notices_published_list
  ON public.admin_notices (status, is_pinned DESC, pinned_at DESC NULLS LAST, published_at DESC NULLS LAST);

-- ============================================================
-- Step 4: SELECT RLS 재정의
--   - 관리자만 접근 가능 (현행 유지)
--   - draft 는 작성자 본인 또는 super_admin 만
-- ============================================================
DROP POLICY IF EXISTS "admin_notices_select" ON public.admin_notices;
CREATE POLICY "admin_notices_select"
  ON public.admin_notices FOR SELECT
  TO authenticated
  USING (
    public.is_admin()
    AND (
      status = 'published'
      OR public.is_super_admin()
      OR created_by = auth.uid()
    )
  );

-- INSERT/UPDATE/DELETE 는 현행 유지 (063 정책)

COMMIT;

-- ============================================================
-- 검증 쿼리 (실행 후 한 번 돌려보기)
-- ============================================================
-- [1] 컬럼 추가 확인
-- SELECT column_name, data_type, column_default
-- FROM information_schema.columns
-- WHERE table_schema='public' AND table_name='admin_notices'
--   AND column_name IN ('status','published_at','published_by','published_by_name');
--
-- [2] 백필 확인 — draft = 0, published = 기존 행 수
-- SELECT status, count(*) FROM public.admin_notices GROUP BY status;
--
-- [3] RLS 정책 USING 절 확인
-- SELECT policyname, cmd, qual FROM pg_policies
-- WHERE tablename='admin_notices' AND cmd='SELECT';
--
-- [4] 인덱스 생성 확인
-- SELECT indexname FROM pg_indexes
-- WHERE schemaname='public' AND tablename='admin_notices';
-- ============================================================
