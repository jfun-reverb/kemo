-- ============================================================
-- 211_role_permissions_save.sql
-- 관리자 동적 권한 관리 PR2 조각 A — 저장/이력 원격 호출 함수(RPC) + menu.permissions 시드
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--         docs/specs/2026-06-15-admin-permission-matrix.md
--
-- PR1 인프라(마이그레이션 207~210, dev+개발DB 적용됨):
--   - role_permissions(role, feature_key, access_level, updated_at, updated_by)
--     PK(role, feature_key). role CHECK IN(campaign_admin, campaign_manager)
--     — super_admin 행은 테이블 자체에 절대 존재할 수 없음(잠금 방지).
--   - role_permission_history(id, role, feature_key, prev_level, next_level, actor, at)
--     RLS는 SELECT만 열려 있고 INSERT 정책이 없음 — SECURITY DEFINER RPC로만 기록 가능.
--   - has_permission(feature, min) — super_admin은 테이블 조회 없이 무조건 true.
--
-- 이번 마이그레이션(PR2 조각 A, 2026-07-02 결정):
--   1) update_role_permissions(p_changes jsonb) — 권한 설정 화면(조각 B·C, 이후 작업)이
--      그리드에서 바뀐 여러 셀(role×feature_key)을 한 번에 저장하는 일괄 배치 RPC.
--        - 저장 방식: 일괄 배치. 함수 자체가 하나의 트랜잭션이므로 원소 하나라도
--          검증에 실패하면 RAISE EXCEPTION으로 전체가 롤백된다(부분 적용 없음).
--        - 낙관적 락: role_permissions 에 별도 version 컬럼이 없다. 대신 클라이언트가
--          화면에 표시했던 prev_level 값을 함께 보내 SELECT ... FOR UPDATE로 잠근
--          현재 DB 값과 비교한다 — prev_level 자체가 버전 역할을 겸한다.
--        - 기본값 복원: 별도 RPC를 만들지 않는다. 클라이언트가
--          dev/lib/shared.js ADMIN_PERMISSION_CATALOG 의 default 값을 next_level 로
--          채워 이 RPC 로 보내면 그대로 "복원"이 된다.
--        - 권한 상승 차단: permissions.manage(이 설정 화면 자체 접근) ·
--          admin.manage(관리자 계정 초대/삭제) 두 기능은 hidden 이 아닌 값으로의
--          저장을 서버가 원천 거부한다 — 화면에서 실수로 셀을 바꿔도 저장 단계에서
--          다시 막는 마지막 방어선(클라 검증만 믿지 않음).
--   2) menu.permissions 시드 2행 — 이 설정 화면 자체의 사이드바 메뉴 항목.
--      마이그레이션 207 시드에는 없던 feature_key(§아래 SECTION 2 주석 참고).
--
-- ⚠️ 잠금 방지: role CHECK 제약이 이미 super_admin 행 저장을 차단하므로
--   update_role_permissions() 는 campaign_admin/campaign_manager 두 등급만 다룬다.
--   super_admin 권한은 이 테이블·이 RPC로 절대 축소되지 않는다.
--
-- 이번 마이그레이션에 포함되지 않은 것(다른 조각 몫):
--   - dev/lib/shared.js ADMIN_PERMISSION_CATALOG 에 menu.permissions 키 추가(조각 B)
--   - 설정 화면 UI(조각 B·C)
--   - has_permission() 을 실제로 호출해 화면·RPC를 서버측 차단하는 작업(PR3+)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- SECTION 1. update_role_permissions(p_changes jsonb) RETURNS integer
--
--   p_changes = jsonb 배열, 각 원소:
--     { "role": "campaign_admin"|"campaign_manager",
--       "feature_key": "<role_permissions.feature_key 기존 값>",
--       "prev_level": "write"|"read"|"hidden"|null,   -- 클라이언트가 화면에 보던 값(낙관적 락 비교용)
--       "next_level": "write"|"read"|"hidden" }
--
--   가드 순서(원소별):
--     ① (함수 진입 시 1회) super_admin 아니면 즉시 거부
--     ② role / next_level 값 검증 + feature_key 존재 확인
--        (존재 확인은 아래 "낙관적 락"용 SELECT ... FOR UPDATE 가 겸함 — NOT FOUND = 미등록)
--     ③ denylist(permissions.manage/admin.manage → hidden 외 next_level 거부)
--     ④ 낙관적 락: FOR UPDATE 로 잠근 현재 access_level 과 prev_level 비교, 불일치 시 거부
--     ⑤ 현재값 == next_level(변화 없음) 이면 적용·이력 없이 건너뜀(idempotent)
--     ⑥ UPDATE + role_permission_history INSERT, 적용 건수 +1
--
--   반환값: 실제로 access_level 이 바뀐(=이력이 남은) 건수.
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_role_permissions(
  p_changes jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row         record;
  v_role        text;
  v_feature_key text;
  v_prev_level  text;
  v_next_level  text;
  v_current     text;
  v_applied     integer := 0;
BEGIN
  -- ① super_admin 만 호출 가능
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '[update_role_permissions] permission denied: super_admin 만 권한 설정을 저장할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  -- 입력 형태 검증
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'array' THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 는 jsonb 배열이어야 합니다'
      USING ERRCODE = 'P0001';
  END IF;

  -- 배치 상한 — 현재 카탈로그(36개) x 등급(2) = 최대 72셀. 여유 있게 100으로 제한.
  IF jsonb_array_length(p_changes) > 100 THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 배열이 너무 큽니다(최대 100개, 입력 %개)', jsonb_array_length(p_changes)
      USING ERRCODE = 'P0001';
  END IF;

  -- 원소별 처리 (1-based ordinality — 에러 메시지에서 어느 셀인지 추적용)
  FOR v_row IN
    SELECT value AS elem, ordinality AS idx
    FROM jsonb_array_elements(p_changes) WITH ORDINALITY AS t(value, ordinality)
  LOOP
    v_role        := v_row.elem->>'role';
    v_feature_key := v_row.elem->>'feature_key';
    v_prev_level  := v_row.elem->>'prev_level';
    v_next_level  := v_row.elem->>'next_level';

    -- ② role 검증 (IS NULL 을 먼저 명시 — NULL NOT IN (...) 은 plpgsql IF에서 false 취급되어
    --    검증을 그냥 통과해버리는 함정을 피하기 위함)
    IF v_role IS NULL OR v_role NOT IN ('campaign_admin', 'campaign_manager') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: role 값이 올바르지 않습니다(campaign_admin|campaign_manager 만 허용). 입력: %', v_row.idx, v_role
        USING ERRCODE = 'P0001';
    END IF;

    -- ② next_level 검증
    IF v_next_level IS NULL OR v_next_level NOT IN ('write', 'read', 'hidden') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: next_level 값이 올바르지 않습니다(write|read|hidden 만 허용). 입력: %', v_row.idx, v_next_level
        USING ERRCODE = 'P0001';
    END IF;

    IF v_feature_key IS NULL OR btrim(v_feature_key) = '' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: feature_key 는 필수입니다', v_row.idx
        USING ERRCODE = 'P0001';
    END IF;

    -- ② feature_key 존재 확인 + ④ 낙관적 락용 행 잠금을 한 번의 조회로 겸함
    SELECT access_level INTO v_current
    FROM public.role_permissions
    WHERE role = v_role AND feature_key = v_feature_key
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: 등록되지 않은 feature_key 입니다(role=%, feature_key=%). role_permissions 에 사전 시드된 키만 저장할 수 있습니다', v_row.idx, v_role, v_feature_key
        USING ERRCODE = 'P0001';
    END IF;

    -- ③ 권한 상승 차단(denylist) — 역할 무관, next_level 이 hidden 이 아니면 거부
    IF v_feature_key IN ('permissions.manage', 'admin.manage') AND v_next_level <> 'hidden' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) hidden 외의 값으로 저장할 수 없습니다(권한 상승 차단)', v_row.idx, v_feature_key
        USING ERRCODE = '42501';
    END IF;

    -- ④ 낙관적 락: 클라이언트가 화면에 표시했던 prev_level 과 방금 잠근 현재값 비교
    IF v_current IS DISTINCT FROM v_prev_level THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: conflict — 다른 관리자가 먼저 변경했습니다(role=%, feature_key=%, 현재값=%, 요청한 prev_level=%). 화면을 새로고침한 뒤 다시 시도하세요', v_row.idx, v_role, v_feature_key, v_current, v_prev_level
        USING ERRCODE = 'P0001';
    END IF;

    -- ⑤ 변화 없음(prev == next) 이면 적용·이력 없이 건너뜀(idempotent — 기본값 복원 재호출 등)
    IF v_current = v_next_level THEN
      CONTINUE;
    END IF;

    -- ⑥ 적용 + 이력 기록
    UPDATE public.role_permissions
    SET access_level = v_next_level,
        updated_at   = now(),
        updated_by   = auth.uid()
    WHERE role = v_role AND feature_key = v_feature_key;

    INSERT INTO public.role_permission_history (role, feature_key, prev_level, next_level, actor)
    VALUES (v_role, v_feature_key, v_current, v_next_level, auth.uid());

    v_applied := v_applied + 1;
  END LOOP;

  RETURN v_applied;
END;
$$;

COMMENT ON FUNCTION public.update_role_permissions(jsonb) IS
  '[211] 관리자 권한 설정 화면(PR2) 일괄 저장 RPC. super_admin 전용(is_super_admin() 가드). '
  'p_changes = [{role, feature_key, prev_level, next_level}, ...] 배열, 함수 전체가 한 트랜잭션. '
  '낙관적 락은 별도 version 컬럼 없이 prev_level 값 비교로 대체. '
  'permissions.manage·admin.manage 는 hidden 외 저장 거부(권한 상승 차단, denylist). '
  '변화 없는 원소는 이력 없이 건너뜀(idempotent). 반환값 = 실제 적용된 건수.';

GRANT EXECUTE ON FUNCTION public.update_role_permissions(jsonb) TO authenticated;

-- ============================================================
-- SECTION 2. menu.permissions 시드 2행
--
--   ⚠️ 기준 데이터 추가 시 중복 확인(.claude/rules/supabase.md) —
--   마이그레이션 207 시드(role_permissions 최초 36개 feature_key)에
--   menu.permissions 가 없음을 아래로 확인 후 추가:
--     grep -n "menu.permissions" supabase/migrations/*.sql supabase/seed/*.sql
--     → 이번 파일(211) 외 매치 없음(작성 시점 확인 완료).
--
--   두 등급 모두 hidden — 이 설정 화면은 설계상 super_admin 전용
--   (마이그레이션 207 SECTION 3 코멘트 'permissions.manage: 신설 화면(PR2) 자체 접근은
--   설계상 super_admin 전용' 과 동일 결정). super_admin 은 has_permission()이
--   role_permissions 테이블 조회 없이 무조건 통과시키므로, 이 hidden 시드가 있어도
--   super_admin 자신의 접근에는 영향이 없다(잠금 방지 원칙 위배 없음).
-- ============================================================
INSERT INTO public.role_permissions (role, feature_key, access_level)
VALUES
  ('campaign_admin',   'menu.permissions', 'hidden'),
  ('campaign_manager', 'menu.permissions', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] menu.permissions 시드 확인 (2행, 둘 다 hidden)
SELECT role, feature_key, access_level
FROM public.role_permissions
WHERE feature_key = 'menu.permissions'
ORDER BY role;

-- [V1] 함수 시그니처·권한 확인
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_role_permissions';

-- [V2] 정상 저장 1건 — 아래는 반드시 로그인 상태(super_admin 세션)에서 SQL Editor가
--   auth.uid() 를 잡을 수 있어야 하므로, SQL Editor보다는 "SELECT auth.uid()" 로
--   먼저 현재 세션 사용자가 super_admin admins 행과 매핑되는지 확인 권장.
--   예시: campaign_manager 의 menu.deliverables 를 write → read 로 변경
SELECT public.update_role_permissions(
  '[{"role":"campaign_manager","feature_key":"menu.deliverables","prev_level":"write","next_level":"read"}]'::jsonb
);
-- 기대값: 1 (적용 1건)

SELECT role, feature_key, access_level, updated_by, updated_at
FROM public.role_permissions
WHERE role = 'campaign_manager' AND feature_key = 'menu.deliverables';
-- access_level = 'read' 확인

SELECT role, feature_key, prev_level, next_level, actor, at
FROM public.role_permission_history
WHERE role = 'campaign_manager' AND feature_key = 'menu.deliverables'
ORDER BY at DESC LIMIT 1;
-- prev_level='write', next_level='read' 행 1건 확인

-- [V2-REVERT] 위 변경 원복 (다음 검증에 영향 없도록)
SELECT public.update_role_permissions(
  '[{"role":"campaign_manager","feature_key":"menu.deliverables","prev_level":"read","next_level":"write"}]'::jsonb
);

-- [V3] denylist 거부 — permissions.manage 를 write 로 바꾸려는 시도 (에러 기대)
SELECT public.update_role_permissions(
  '[{"role":"campaign_admin","feature_key":"permissions.manage","prev_level":"hidden","next_level":"write"}]'::jsonb
);
-- 기대: ERROR 42501, 메시지에 "권한 상승 차단" 포함

-- [V4] prev_level 충돌 거부 — 실제 현재값과 다른 prev_level 전송 (에러 기대)
SELECT public.update_role_permissions(
  '[{"role":"campaign_admin","feature_key":"menu.dashboard","prev_level":"hidden","next_level":"read"}]'::jsonb
);
-- 기대: ERROR, 메시지에 "conflict" 포함 (menu.dashboard 현재값은 write 이므로 hidden 과 불일치)

-- [V5] 미등록 feature_key 거부 (에러 기대)
SELECT public.update_role_permissions(
  '[{"role":"campaign_admin","feature_key":"menu.does_not_exist","prev_level":null,"next_level":"read"}]'::jsonb
);
-- 기대: ERROR, 메시지에 "등록되지 않은 feature_key" 포함

-- [V6] 비-super_admin 거부 — campaign_admin/campaign_manager 계정으로 로그인한 세션에서 호출
--   (SQL Editor 는 보통 service_role 이라 이 테스트는 실제 로그인 세션이 필요하면
--    Supabase Dashboard "Run as user" 기능 또는 클라이언트 콘솔에서 확인)
-- SELECT public.update_role_permissions('[{"role":"campaign_admin","feature_key":"menu.dashboard","prev_level":"write","next_level":"read"}]'::jsonb);
-- 기대: ERROR 42501, 메시지에 "super_admin 만" 포함

*/


-- ============================================================
-- 롤백
-- ============================================================
/*

DELETE FROM public.role_permissions WHERE feature_key = 'menu.permissions';
DROP FUNCTION IF EXISTS public.update_role_permissions(jsonb);

NOTIFY pgrst, 'reload schema';

*/
