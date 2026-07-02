-- ============================================================
-- 210_fix_is_campaign_admin_search_path.sql
-- 관리자 동적 권한 관리 PR1 — 4/4 (매트릭스 감사 갭3 정정)
-- 사양서: docs/specs/2026-06-15-admin-permission-matrix.md 갭3
--
-- is_campaign_admin() 이 다른 권한 함수(is_admin/is_super_admin/has_permission)와
-- 달리 SET search_path = 'public, pg_temp' 로 정의돼 있던 것을 SET search_path = ''
-- 로 통일 + admins 참조를 public.admins 로 스키마 명시.
-- (.claude/rules/security.md "SECURITY DEFINER 함수는 search_path='' 필수" 위반 정정)
--
-- 원본: supabase/migrations/024_create_lookup_values.sql
--   CREATE OR REPLACE FUNCTION public.is_campaign_admin()
--   RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
--   AS $$ SELECT EXISTS (SELECT 1 FROM admins WHERE auth_id = auth.uid() AND role IN ('super_admin','campaign_admin')); $$;
--
-- CREATE OR REPLACE FUNCTION 은 인자 목록이 같으면 함수를 참조하는 기존 RLS 정책·
-- GRANT 를 깨지 않고 본문/속성만 교체한다 — 별도 DROP·정책 재작성 불필요.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_campaign_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins
    WHERE auth_id = auth.uid()
      AND role IN ('super_admin', 'campaign_admin')
  );
$$;

COMMENT ON FUNCTION public.is_campaign_admin() IS
  'role IN (super_admin, campaign_admin). search_path='''' 정정(마이그레이션 210, 갭3) — '
  'admins 는 public.admins 로 스키마 명시. 판정 로직 자체는 변경 없음(024 원본과 동일 조건).';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 롤백 (024 원본으로 되돌리기 — 권장하지 않음, search_path 취약점 재도입)
-- ============================================================
-- CREATE OR REPLACE FUNCTION public.is_campaign_admin()
-- RETURNS boolean
-- LANGUAGE sql
-- SECURITY DEFINER
-- SET search_path = public, pg_temp
-- AS $$
--   SELECT EXISTS (
--     SELECT 1 FROM admins
--     WHERE auth_id = auth.uid()
--       AND role IN ('super_admin','campaign_admin')
--   );
-- $$;
