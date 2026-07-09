-- ============================================================
-- 208_role_permission_history.sql
-- 관리자 동적 권한 관리 PR1 — 2/4
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md §3
--
-- role_permission_history: role_permissions 변경 이력(audit) 골격.
--   PR1에는 이 테이블에 쓰는 화면·RPC가 없다(골격만). PR2 설정 화면이
--   "저장" 시 호출할 SECURITY DEFINER RPC(가칭 update_role_permission)에서
--   INSERT를 채운다 — application_events(마이그레이션 131) 패턴과 동일하게
--   RLS 는 SELECT만 열어두고 INSERT 정책은 만들지 않는다(직접 client INSERT 차단,
--   추후 RPC 가 SECURITY DEFINER 로 RLS 우회).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.role_permission_history (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  role        text        NOT NULL CHECK (role IN ('campaign_admin', 'campaign_manager')),
  feature_key text        NOT NULL,
  prev_level  text        CHECK (prev_level IN ('write', 'read', 'hidden')),
  next_level  text        NOT NULL CHECK (next_level IN ('write', 'read', 'hidden')),
  actor       uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.role_permission_history IS
  'role_permissions 변경 이력(audit). PR1은 골격만 — INSERT는 PR2가 만들 RPC(SECURITY DEFINER)가 담당. '
  'prev_level NULL 허용 = 최초 등록(변경 전 값 없음).';
COMMENT ON COLUMN public.role_permission_history.actor IS
  '변경한 super_admin 의 auth.uid(). 관리자 삭제 후에도 audit 보존 목적으로 ON DELETE SET NULL(이름 스냅샷은 PR2에서 필요 시 추가).';

-- 조회 편의 인덱스 (기능별 이력 타임라인)
CREATE INDEX IF NOT EXISTS idx_role_permission_history_feature
  ON public.role_permission_history (feature_key, at DESC);

-- ============================================================
-- 2. RLS — SELECT만 (INSERT는 향후 RPC 전용, 정책 없음 = 직접 INSERT 차단)
-- ============================================================
ALTER TABLE public.role_permission_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_permission_history_select ON public.role_permission_history
  FOR SELECT TO authenticated
  USING (is_super_admin());

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS role_permission_history_select ON public.role_permission_history;
-- DROP INDEX IF EXISTS idx_role_permission_history_feature;
-- DROP TABLE IF EXISTS public.role_permission_history;
