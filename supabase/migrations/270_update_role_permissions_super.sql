-- ============================================================
-- 270_update_role_permissions_super.sql
-- 슈퍼관리자 권한 자기 제한 PR 1 — 3/3 (저장 함수 update_role_permissions 재정의)
-- 사양서: docs/specs/2026-07-29-super-admin-self-restriction.md §4-1 ③
--
-- 재정의 베이스: 마이그레이션 211_role_permissions_save.sql
--   (update_role_permissions(jsonb) 를 재정의한 마이그레이션은 211 이 유일함 —
--   `grep -l "FUNCTION public.update_role_permissions"` 로 전수 확인 완료. 213·220·
--   221·228 은 role_permissions 에 행을 INSERT 만 할 뿐 이 함수 본문을 재정의하지
--   않음. 따라서 211 원문이 곧 "번호가 가장 큰(=유일한) 기존 정의"이며 이번 270이
--   그 위에 얹는 유일한 개정판이다.)
--
-- 이번 변경(211 대비 diff):
--   ① 허용 role 목록에 'super_admin' 추가 (기존: campaign_admin/campaign_manager 만)
--      + 오류 메시지 갱신("campaign_admin|campaign_manager 만 허용"은 이제 거짓이므로
--      "super_admin|campaign_admin|campaign_manager 만 허용"으로 교체 — 사양서 §2-6
--      "오류 문구가 거짓" 지적 반영)
--   ② **슈퍼 잠금 규칙 신설(서버 최종 방어선, 사양서 §4-2 장치3)** —
--        role = 'super_admin' 이고 feature_key 가
--        permissions.manage · admin.manage · menu.permissions 중 하나면
--        next_level 이 'write' 가 아니면 거부.
--      ⚠️ 방향이 등급 2종의 기존 denylist 와 정반대다:
--        · campaign_admin/campaign_manager: permissions.manage·admin.manage 는
--          "hidden 외 거부"(이 두 등급이 이 기능을 갖는 것 자체가 상승이므로
--          항상 숨김 고정) — 211 원문 그대로 완전히 보존.
--        · super_admin: 위 둘 + menu.permissions 는 "write 외 거부"(슈퍼가 이
--          3개를 스스로 숨기거나 읽기 전용으로 낮추면, 「관리자 계정」→「권한
--          관리」 진입로와 설정 화면 자체 사이드바 노출이 동시에 끊겨 아무도
--          되돌릴 수 없는 잠금 사고가 된다 — 사양서 §2-1 잠금 경로 표).
--      두 규칙은 별개 IF 문으로 각자 완전히 유지한다(하나로 합치면 방향이
--      반대라 조건식이 뒤섞여 버그가 나기 쉬움).
--   ③ 배치 상한 100 → 200 (42 feature_key × 3 등급 = 126칸, 전체 일괄 변경 시
--      100 이면 실패 — 사양서 §2-6. 여유를 두어 200으로 설정)
--
-- 변경하지 않는 것(211 원문 그대로 완전 보존):
--   - 함수 진입 시 1회 super_admin 가드(IF NOT is_super_admin() THEN 42501)
--   - next_level·feature_key 필수값 검증
--   - SELECT ... FOR UPDATE 로 존재 확인 + 낙관적 락(잠금)을 겸하는 구조
--   - prev_level 비교에 의한 낙관적 락(conflict 거부)
--   - 현재값과 next_level 이 같으면 이력 없이 건너뛰는 idempotent 처리
--   - UPDATE + role_permission_history INSERT 원자 처리, 반환값(적용 건수)
--   - LANGUAGE/SECURITY DEFINER/SET search_path = '' 속성, 시그니처(jsonb) 동일
--     → CREATE OR REPLACE 라서 기존 GRANT(EXECUTE TO authenticated) 보존됨
--       (재확인 차원에서 GRANT 문은 아래에 다시 실행 — 멱등, 부작용 없음)
--   - restore_role_permissions_defaults()(215)는 이 마이그레이션 대상이 아님
--     — 등급 무관 전체(access_level<>default_level) 대상이라 268의 슈퍼 시드가
--     이미 access_level=default_level='write' 로 들어가 있는 한 자동으로
--     "슈퍼 전권 원복"이 성립한다(사양서 §4-1 ③ 마지막 줄, §4-2 장치4).
--
-- 전제:
--   이 마이그레이션이 유효하려면 268(role CHECK 확장 + 슈퍼 행 시드)이 먼저
--   적용돼 있어야 한다 — 그렇지 않으면 role='super_admin' 인 UPDATE 시도가
--   role_permissions_role_check 위반으로 실패한다.
--
-- 롤백: 파일 하단 참고.
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

  -- 배치 상한 — 카탈로그(42개) x 등급(3, 270부터 super_admin 포함) = 최대 126셀.
  -- 여유 있게 200으로 제한(211 시점엔 72셀 기준 100 이었음).
  IF jsonb_array_length(p_changes) > 200 THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 배열이 너무 큽니다(최대 200개, 입력 %개)', jsonb_array_length(p_changes)
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
    --    검증을 그냥 통과해버리는 함정을 피하기 위함). 270부터 super_admin 도 허용.
    IF v_role IS NULL OR v_role NOT IN ('super_admin', 'campaign_admin', 'campaign_manager') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: role 값이 올바르지 않습니다(super_admin|campaign_admin|campaign_manager 만 허용). 입력: %', v_row.idx, v_role
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

    -- ③ 권한 상승 차단(denylist) — 등급 2종과 super_admin 은 방향이 정반대다.
    --   · campaign_admin/campaign_manager: permissions.manage·admin.manage 는
    --     hidden 외 거부(211 원문 그대로, 완전 보존 — 이 두 기능을 등급 2종이
    --     갖는 것 자체가 권한 상승이므로 항상 숨김 고정).
    IF v_role IN ('campaign_admin', 'campaign_manager')
       AND v_feature_key IN ('permissions.manage', 'admin.manage')
       AND v_next_level <> 'hidden' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) hidden 외의 값으로 저장할 수 없습니다(권한 상승 차단)', v_row.idx, v_feature_key
        USING ERRCODE = '42501';
    END IF;

    --   · super_admin: permissions.manage·admin.manage·menu.permissions 3개는
    --     write 외 거부(잠금 방지 — 사양서 §2-1·§4-2. 슈퍼가 이 3개를 스스로
    --     숨기거나 읽기 전용으로 낮추면 「관리자 계정」→「권한 관리」 진입로와
    --     설정 화면 사이드바 노출이 동시에 끊겨 되돌릴 방법이 없어진다).
    IF v_role = 'super_admin'
       AND v_feature_key IN ('permissions.manage', 'admin.manage', 'menu.permissions')
       AND v_next_level <> 'write' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) super_admin 에서 write 외의 값으로 저장할 수 없습니다(잠금 방지 — 복구 경로 자기 차단 방지)', v_row.idx, v_feature_key
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
  '[270] 관리자 권한 설정 화면 일괄 저장 RPC(211 재정의). super_admin 전용(is_super_admin() 가드). '
  'p_changes = [{role, feature_key, prev_level, next_level}, ...] 배열(role 은 270부터 super_admin 포함 3종), '
  '함수 전체가 한 트랜잭션. 낙관적 락은 별도 version 컬럼 없이 prev_level 값 비교로 대체. '
  'denylist 는 등급별로 방향이 반대다 — campaign_admin/campaign_manager 의 permissions.manage·admin.manage 는 '
  'hidden 외 거부(권한 상승 차단), super_admin 의 permissions.manage·admin.manage·menu.permissions 는 '
  'write 외 거부(잠금 방지 — 복구 경로 자기 차단 방지). 배열 상한 200(42키×3등급=126칸 여유). '
  '변화 없는 원소는 이력 없이 건너뜀(idempotent). 반환값 = 실제 적용된 건수.';

GRANT EXECUTE ON FUNCTION public.update_role_permissions(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ⚠️ SQL Editor 는 service_role 세션이라 auth.uid() 가 없어 is_super_admin() 이
--   항상 false 다. 아래 SELECT public.update_role_permissions(...) 호출은 전부
--   "① super_admin 만 호출 가능" 가드에서 즉시 42501 로 막힌다 — 이는 정상이며
--   버그가 아니다(211/215 의 기존 검증 SQL과 동일한 제약). 실제 등급별 판정은
--   각 계정으로 로그인한 브라우저 세션(권한 관리 화면 또는 콘솔의 supabase.rpc)
--   에서 확인할 것.
-- ============================================================
/*

-- [V0] 함수 시그니처 확인
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_role_permissions';

-- [V1] (super_admin 계정 로그인 세션에서) 슈퍼 잠금 거부 확인 — menu.permissions 를
--   super_admin 에서 read 로 낮추려는 시도 (에러 기대)
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"menu.permissions","prev_level":"write","next_level":"read"}]'::jsonb
-- );
-- 기대: ERROR 42501, 메시지에 "잠금 방지" 포함

-- [V2] (super_admin 계정 로그인 세션에서) 슈퍼 정상 저장 — 예: settlement.pay 를
--   super_admin 에서 write → read 로 (허용돼야 함, 잠금 목록 3종 밖이므로)
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"settlement.pay","prev_level":"write","next_level":"read"}]'::jsonb
-- );
-- 기대: 1 (적용 성공)
-- 확인 후 원복:
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"settlement.pay","prev_level":"read","next_level":"write"}]'::jsonb
-- );

-- [V3] (super_admin 계정 로그인 세션에서) 등급 2종 기존 denylist 방향 불변 확인 —
--   campaign_admin 의 admin.manage 를 write 로 바꾸려는 시도 (여전히 거부돼야 함)
-- SELECT public.update_role_permissions(
--   '[{"role":"campaign_admin","feature_key":"admin.manage","prev_level":"hidden","next_level":"write"}]'::jsonb
-- );
-- 기대: ERROR 42501, 메시지에 "권한 상승 차단" 포함 (211 원문 동작 그대로)

-- [V4] role 값 검증 — super_admin 도 이제 유효한 role 인지(형식 검증만, 실제
--   저장은 super_admin 세션에서만 가능하므로 SQL Editor 에서는 ①단계에서
--   먼저 막혀 이 케이스까지 도달하지 않음 — 참고용)

*/

-- ============================================================
-- 롤백 — 211 원문으로 되돌림(등급 2종만 허용, 슈퍼 잠금 규칙·상한 200 제거)
-- ============================================================
/*

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
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '[update_role_permissions] permission denied: super_admin 만 권한 설정을 저장할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'array' THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 는 jsonb 배열이어야 합니다'
      USING ERRCODE = 'P0001';
  END IF;

  IF jsonb_array_length(p_changes) > 100 THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 배열이 너무 큽니다(최대 100개, 입력 %개)', jsonb_array_length(p_changes)
      USING ERRCODE = 'P0001';
  END IF;

  FOR v_row IN
    SELECT value AS elem, ordinality AS idx
    FROM jsonb_array_elements(p_changes) WITH ORDINALITY AS t(value, ordinality)
  LOOP
    v_role        := v_row.elem->>'role';
    v_feature_key := v_row.elem->>'feature_key';
    v_prev_level  := v_row.elem->>'prev_level';
    v_next_level  := v_row.elem->>'next_level';

    IF v_role IS NULL OR v_role NOT IN ('campaign_admin', 'campaign_manager') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: role 값이 올바르지 않습니다(campaign_admin|campaign_manager 만 허용). 입력: %', v_row.idx, v_role
        USING ERRCODE = 'P0001';
    END IF;

    IF v_next_level IS NULL OR v_next_level NOT IN ('write', 'read', 'hidden') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: next_level 값이 올바르지 않습니다(write|read|hidden 만 허용). 입력: %', v_row.idx, v_next_level
        USING ERRCODE = 'P0001';
    END IF;

    IF v_feature_key IS NULL OR btrim(v_feature_key) = '' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: feature_key 는 필수입니다', v_row.idx
        USING ERRCODE = 'P0001';
    END IF;

    SELECT access_level INTO v_current
    FROM public.role_permissions
    WHERE role = v_role AND feature_key = v_feature_key
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: 등록되지 않은 feature_key 입니다(role=%, feature_key=%). role_permissions 에 사전 시드된 키만 저장할 수 있습니다', v_row.idx, v_role, v_feature_key
        USING ERRCODE = 'P0001';
    END IF;

    IF v_feature_key IN ('permissions.manage', 'admin.manage') AND v_next_level <> 'hidden' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) hidden 외의 값으로 저장할 수 없습니다(권한 상승 차단)', v_row.idx, v_feature_key
        USING ERRCODE = '42501';
    END IF;

    IF v_current IS DISTINCT FROM v_prev_level THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: conflict — 다른 관리자가 먼저 변경했습니다(role=%, feature_key=%, 현재값=%, 요청한 prev_level=%). 화면을 새로고침한 뒤 다시 시도하세요', v_row.idx, v_role, v_feature_key, v_current, v_prev_level
        USING ERRCODE = 'P0001';
    END IF;

    IF v_current = v_next_level THEN
      CONTINUE;
    END IF;

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

GRANT EXECUTE ON FUNCTION public.update_role_permissions(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';

*/
