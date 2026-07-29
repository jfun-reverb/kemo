-- ============================================================
-- 269_has_permission_super_admin.sql
-- 슈퍼관리자 권한 자기 제한 PR 1 — 2/3 (판정 함수 has_permission 재정의)
-- 사양서: docs/specs/2026-07-29-super-admin-self-restriction.md §4-1 ②
--
-- 재정의 베이스: 마이그레이션 209_has_permission_fn.sql
--   (has_permission(text, text) 를 재정의한 마이그레이션은 209 가 유일함 —
--   `grep -l "FUNCTION public.has_permission"` 로 전수 확인 완료. 267 은
--   이 함수를 "참조"만 하고 재정의하지 않음. 따라서 209 원문이 곧 "번호가
--   가장 큰(=유일한) 기존 정의"이며 이번 269 가 그 위에 얹는 유일한 개정판이다.)
--
-- 이번 변경(209 대비 diff):
--   ① super_admin 판정에서 표 조회를 완전히 건너뛰고 무조건 true 를 반환하던
--      코드 레벨 하드 통과를 제거하고, super_admin 도 등급 2종과 같은 조회
--      경로를 타게 한다(단, 아래 ②의 비대칭 계약으로 안전성을 유지).
--   ② **비대칭 계약(fail-open vs fail-closed)** — 반드시 지킬 것:
--        · role = 'super_admin' 이고 (role, feature_key) 행이 없으면 → true
--          (fail-open). 이유: 슈퍼 제한은 "보안 경계"가 아니라 "자기 제한(실수
--          방지 안전장치)"다(사양서 §3 권고). 새 기능이 배포돼 아직
--          role_permissions 시드가 안 된 상태라면, "명시적으로 잠그지 않은
--          것"이므로 슈퍼는 계속 전권을 가져야 한다 — 그래야 신규 기능마다
--          슈퍼가 못 보는 사고(사양서 §2-2)가 안 생긴다.
--        · role = 'campaign_admin'/'campaign_manager' 이고 행이 없으면 → false
--          (fail-closed, 209 원문 그대로 불변). 이 두 등급은 "설정 안 함 =
--          접근 안 됨"이 원래 계약이라, 여기까지 슈퍼와 같은 방향으로 바꾸면
--          권한 관리 도입 이전에 존재하던 안전측 거부 원칙이 깨진다.
--      → 같은 함수 안에서 두 등급군이 "미등록 시" 정반대로 판정된다는 뜻이다.
--        이 비대칭은 실수가 아니라 설계다(사양서 §4-1 ②, §2-2).
--
-- 변경하지 않는 것:
--   STABLE·SECURITY DEFINER·SET search_path = ''·시그니처(text, text) 전부 동일
--   → CREATE OR REPLACE 라서 이 함수에 이미 내려진 GRANT(EXECUTE TO authenticated)
--   가 보존된다(신규 CREATE 가 아님). 그래도 재확인 차원에서 GRANT 문을 아래에
--   다시 실행한다(멱등, 부작용 없음).
--
-- 영향:
--   이 함수를 호출하는 모든 지점(가림막 뷰 212/213, 정산 217~233/262,
--   아웃바운드 226/229, 캠페인 이력 열람 267 등)이 재정의 직후부터 새 계약을
--   따른다. 등급 2종(campaign_admin/campaign_manager) 판정 결과는 209 와
--   100% 동일 — 로직 자체를 안 바꿨고, 비대칭 계약도 "미등록 시 false"라는
--   기존 동작 그대로다. super_admin 판정 결과도 마이그레이션 268 직후 시점엔
--   100% 동일(268이 존재하는 모든 feature_key 를 write 로 시드해뒀으므로 표
--   조회 결과가 항상 write, 즉 true) — 이 마이그레이션 자체로는 아직
--   동작 변화가 없다. 실제로 슈퍼 판정이 바뀌는 것은 이후 PR(update_role_permissions
--   에 super_admin 저장이 열리는 270번, 그리고 화면에서 실제로 값을 바꾸는
--   PR 2·3)부터다.
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
  v_min_rank := CASE p_min WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;

  -- super_admin 판정 경로 — 268부터 role_permissions 에 'super_admin' 행이
  -- 존재할 수 있으므로, 더 이상 표 조회를 건너뛰지 않는다.
  IF public.is_super_admin() THEN
    v_role := 'super_admin';
  ELSE
    -- 로그인한 사용자의 관리자 등급 조회 (관리자가 아니면 role 없음 = 거부)
    SELECT role INTO v_role
    FROM public.admins
    WHERE auth_id = auth.uid();

    IF v_role IS NULL THEN
      RETURN false;
    END IF;
  END IF;

  -- 설정값 조회 (역할 공통 — 269부터 super_admin 도 이 표를 조회한다)
  SELECT access_level INTO v_level
  FROM public.role_permissions
  WHERE role = v_role AND feature_key = p_feature;

  IF v_level IS NULL THEN
    -- ⚠️ 비대칭 계약(위 헤더 설명 참고, 사양서 §4-1 ②·§2-2):
    --   super_admin  → true  (fail-open — 슈퍼 제한은 자기 제한이지 보안 경계가
    --                          아니므로, 명시적으로 잠그지 않은 기능은 계속 전권)
    --   등급 2종     → false (fail-closed — 209 원문 계약 그대로 불변,
    --                          "설정 안 함 = 접근 안 됨")
    RETURN v_role = 'super_admin';
  END IF;

  v_level_rank := CASE v_level WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;

  RETURN v_level_rank >= v_min_rank;
END;
$$;

COMMENT ON FUNCTION public.has_permission(text, text) IS
  '[269] 관리자 등급별 기능 접근 판정(209 재정의). super_admin 도 268부터 role_permissions 를 '
  '조회한다 — 단, 미등록(행 없음) 시 계약이 등급별로 비대칭이다: super_admin=true(fail-open, '
  '자기 제한 원칙 — 사양서 2026-07-29-super-admin-self-restriction.md §4-1), '
  'campaign_admin/campaign_manager=false(fail-closed, 209 원문 그대로 불변).';

GRANT EXECUTE ON FUNCTION public.has_permission(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ⚠️ SQL Editor 는 service_role 세션이라 auth.uid() 가 없어 is_super_admin()·
--   admins 조회가 모두 실패하고 has_permission() 은 사실상 항상 등급 없음(false)
--   경로를 탄다. 등급별 실제 판정은 각 등급 계정으로 로그인한 브라우저 세션에서
--   확인해야 한다(211/215/267 의 기존 검증 SQL과 동일한 제약).
-- ============================================================
/*

-- [V0] 함수 시그니처·속성 확인 (STABLE·SECURITY DEFINER 유지 확인)
SELECT p.proname, pg_get_function_arguments(p.oid) AS args,
       p.provolatile, p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'has_permission';
-- 기대: provolatile = 's'(STABLE), is_security_definer = true

-- [V1] 등급별 실제 판정은 브라우저 콘솔에서 각 계정으로 로그인 후 아래 3종 실행
--   (sql editor 아님 — 클라이언트 supabase.rpc('has_permission', {...}) 또는
--   앱 화면의 canRead/canWrite 로 간접 확인해도 됨)
--   ① super_admin 계정, 존재하는 키(예: settlement.view) → true
--   ② super_admin 계정, 존재하지 않는 임의 키(예: 'no.such.key') → true (fail-open 확인)
--   ③ campaign_manager 계정, 존재하지 않는 임의 키 → false (fail-closed 불변 확인)

-- [V2] 슈퍼 fail-open 재현 — 테스트용으로 슈퍼 행 1개를 지웠다가 판정이 여전히
--   true 인지 확인 후 즉시 복구 (사양서 §5-2 C7과 동일한 시나리오)
-- 주의: 실제 값 삭제이므로 개발 DB에서만, 확인 직후 복구할 것
-- DELETE FROM public.role_permissions WHERE role='super_admin' AND feature_key='menu.dashboard';
-- (이 상태에서 super_admin 계정으로 로그인해 대시보드 진입 가능한지 확인 → 가능해야 함)
-- INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
-- VALUES ('super_admin', 'menu.dashboard', 'write', 'write')
-- ON CONFLICT (role, feature_key) DO NOTHING;

*/

-- ============================================================
-- 롤백 — 209 원문으로 되돌림(슈퍼는 즉시 전권 복구, 표 데이터는 그대로 둬도 무해)
-- ============================================================
/*

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
  IF public.is_super_admin() THEN
    RETURN true;
  END IF;

  SELECT role INTO v_role
  FROM public.admins
  WHERE auth_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

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

GRANT EXECUTE ON FUNCTION public.has_permission(text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';

*/
