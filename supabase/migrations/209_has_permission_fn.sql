-- ============================================================
-- 209_has_permission_fn.sql
-- 관리자 동적 권한 관리 PR1 — 3/4
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md §3
--
-- has_permission(p_feature, p_min): 현재 로그인한 관리자가 p_feature 에 대해
--   p_min 이상의 접근 수준을 갖는지 판정.
--
-- ⚠️ 잠금 방지: is_super_admin() 이면 role_permissions 테이블을 조회하지 않고
--   무조건 true 를 반환한다(코드 레벨 하드 통과). role_permissions 에는
--   super_admin 행이 아예 존재할 수 없으므로(마이그레이션 207 CHECK 제약),
--   이 함수는 어떤 설정값으로도 super_admin 권한을 축소시킬 수 없다.
--
-- ⚠️ PR1 시점에는 이 함수를 호출하는 클라이언트·RPC 가드가 전혀 없다
--   (순수 인프라). 실제로 화면·RPC가 이 함수를 참조하기 시작하는 건 PR2(화면)·
--   PR3+(서버 차단)부터다 — 배포해도 기존 동작에 영향 없음.
--
-- 미등록 feature_key 계약: role_permissions 에 해당 (role, feature_key) 행이
--   없으면 안전측 거부(false) — "설정 안 함 = 접근 안 됨"이 기본값.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.has_permission(
  p_feature text,
  p_min     text DEFAULT 'read'
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role        text;
  v_level       text;
  v_level_rank  int;
  v_min_rank    int;
BEGIN
  -- super_admin 은 테이블 조회 없이 무조건 통과 (잠금 방지)
  IF public.is_super_admin() THEN
    RETURN true;
  END IF;

  -- 로그인한 사용자의 관리자 등급 조회 (관리자가 아니면 role 없음 = 거부)
  SELECT role INTO v_role
  FROM public.admins
  WHERE auth_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  -- 설정값 조회 (없으면 안전측 거부)
  SELECT access_level INTO v_level
  FROM public.role_permissions
  WHERE role = v_role AND feature_key = p_feature;

  IF v_level IS NULL THEN
    RETURN false;
  END IF;

  v_level_rank := CASE v_level WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;
  v_min_rank   := CASE p_min   WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;

  RETURN v_level_rank >= v_min_rank;
END;
$$;

COMMENT ON FUNCTION public.has_permission(text, text) IS
  '관리자 등급별 기능 접근 판정. super_admin은 테이블 조회 없이 무조건 true(잠금 방지). '
  'role_permissions 에 미등록 feature_key 는 false(안전측 거부). p_min 기본값 read.';

GRANT EXECUTE ON FUNCTION public.has_permission(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.has_permission(text, text);
