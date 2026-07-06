-- ============================================================
-- 215_restore_role_permissions_defaults.sql
-- 관리자 동적 권한 관리 「기본값 복원」 PR1 — 2/2 (전용 복원 원격 호출 함수(RPC))
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--
-- 전제: 마이그레이션 214 에서 role_permissions.default_level(NOT NULL) 확보됨.
--
-- restore_role_permissions_defaults() — access_level ≠ default_level 인 행을
--   전부(campaign_admin·campaign_manager 등급 무관) default_level 값으로 되돌리는
--   전용 RPC. update_role_permissions(jsonb)(마이그레이션 211) 를 재사용하지 않고
--   별도 함수로 만든 이유: 클라이언트가 37×2=74개 셀의 prev/next 값을 일일이
--   조립해 보낼 필요 없이 "복원" 버튼 한 번으로 서버가 일괄 판단하게 하기 위함
--   (사용자 확정: 전용 복원 RPC).
--
-- 가드:
--   ① is_super_admin() 아니면 42501 거부 (update_role_permissions 과 동일 원칙)
--   ② denylist(permissions.manage/admin.manage/menu.permissions) 는 default_level 자체가
--      이미 'hidden' 이라 access_level 도 대개 'hidden' → 조건(access_level<>default_level)에
--      안 걸려 자연히 스킵된다. 별도 예외 처리 불필요(확인만, 코드 분기 없음).
--   ③ 변경된 행만 UPDATE + role_permission_history 이력 INSERT (211 과 동일한 audit 패턴).
--
-- 반환값: 실제로 access_level 이 바뀐(=default_level 과 달랐던) 건수.
--
-- ⚠️ 향후 정책 변경 마이그레이션 안내(중요): 이후 어떤 마이그레이션이
--   role_permissions.access_level 을 의도적으로 바꾸는 경우(213_activate_pii_masking.sql이
--   campaign_manager의 influencer.sensitive_pii를 read→hidden 으로 바꾼 것과 같은 성격의
--   변경), 그 마이그레이션은 반드시 같은 행의 default_level 도 함께 UPDATE 해야 한다.
--   안 하면 이 RPC("기본값 복원")를 한 번만 눌러도 그 정책 변경이 조용히 되돌려져
--   버그처럼 보이는 드리프트가 생긴다. (214의 213 반영이 그 선례.)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.restore_role_permissions_defaults()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_applied integer := 0;
BEGIN
  -- ① super_admin 만 호출 가능 (update_role_permissions 과 동일 가드)
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '[restore_role_permissions_defaults] permission denied: super_admin 만 기본값 복원을 실행할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ③ 변경 대상 행만 잠그고(FOR UPDATE) → 되돌리고 → 이력 기록. 한 문장(단일 트랜잭션)으로 원자 처리.
  WITH changed AS (
    SELECT role, feature_key, access_level AS prev_level, default_level AS next_level
    FROM public.role_permissions
    WHERE access_level <> default_level
    FOR UPDATE
  ),
  upd AS (
    UPDATE public.role_permissions rp
    SET access_level = changed.next_level,
        updated_at   = now(),
        updated_by   = auth.uid()
    FROM changed
    WHERE rp.role = changed.role AND rp.feature_key = changed.feature_key
    RETURNING changed.role, changed.feature_key, changed.prev_level, changed.next_level
  ),
  hist AS (
    INSERT INTO public.role_permission_history (role, feature_key, prev_level, next_level, actor)
    SELECT role, feature_key, prev_level, next_level, auth.uid()
    FROM upd
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_applied FROM hist;

  RETURN v_applied;
END;
$$;

COMMENT ON FUNCTION public.restore_role_permissions_defaults() IS
  '[215] 관리자 권한 설정 화면(PR2+) 「기본값 복원」 전용 RPC. super_admin 전용(is_super_admin() 가드). '
  'access_level <> default_level 인 모든 행(campaign_admin·campaign_manager 무관, 전체 일괄)을 '
  'default_level 값으로 되돌리고 role_permission_history 에 이력을 남긴다. '
  '반환값 = 실제로 되돌려진(=바뀐) 건수. denylist(permissions.manage 등)는 default_level 이 이미 '
  'hidden 이라 자연히 대상에서 제외됨(별도 분기 없음).';

GRANT EXECUTE ON FUNCTION public.restore_role_permissions_defaults() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 시그니처·SECURITY DEFINER 확인
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'restore_role_permissions_defaults';

-- [V1] 스모크 테스트 준비 — 개발용으로 몇 칸을 일부러 바꿔서 "복원 필요 상태"를 만든다
--   (campaign_manager 의 menu.deliverables 를 write → read 로, campaign_admin 의
--   notice.create 를 write → read 로 변경 — 211 의 update_role_permissions 재사용)
SELECT public.update_role_permissions(
  '[
    {"role":"campaign_manager","feature_key":"menu.deliverables","prev_level":"write","next_level":"read"},
    {"role":"campaign_admin","feature_key":"notice.create","prev_level":"write","next_level":"read"}
  ]'::jsonb
);
-- 기대값: 2 (적용 2건)

-- [V2] 복원 전 상태 확인 — access_level 과 default_level 이 다른 행 2개 나와야 함
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE access_level <> default_level
ORDER BY feature_key, role;

-- [V3] 복원 RPC 호출
SELECT public.restore_role_permissions_defaults();
-- 기대값: 2 (V1에서 바꾼 2건이 되돌아감. 개발 DB에 V1 이전부터 이미 다른 커스터마이즈가
--   있었다면 그만큼 더 나올 수 있음 — 그 경우 V2 결과 건수와 일치하는지로 판단)

-- [V4] 복원 후 확인 — access_level = default_level 로 전부 일치(0건)해야 함
SELECT count(*) FROM public.role_permissions WHERE access_level <> default_level;
-- 기대: 0

-- [V5] 원복된 두 값이 정확히 baseline(write)으로 돌아왔는지 확인
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE (role = 'campaign_manager' AND feature_key = 'menu.deliverables')
   OR (role = 'campaign_admin'   AND feature_key = 'notice.create')
ORDER BY feature_key;
-- 기대: 둘 다 access_level = 'write' (default_level 과 동일)

-- [V6] 이력 확인 — role_permission_history 에 이번 복원으로 생긴 2건이 남았는지
SELECT role, feature_key, prev_level, next_level, actor, at
FROM public.role_permission_history
WHERE at > now() - interval '5 minutes'
ORDER BY at DESC
LIMIT 10;

-- [V7] 재호출 시 0건(멱등) 확인 — 이미 복원됐으니 더 되돌릴 게 없어야 함
SELECT public.restore_role_permissions_defaults();
-- 기대값: 0

-- [V8] 비-super_admin 거부 확인 — campaign_admin/campaign_manager 로그인 세션에서 호출
--   (SQL Editor 는 보통 service_role 이라 이 항목은 실제 로그인 세션 또는 Dashboard
--   "Run as user" 기능으로 확인 권장 — 211 의 V6 과 동일한 제약)

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.restore_role_permissions_defaults();
-- NOTIFY pgrst, 'reload schema';
