-- ============================================================
-- 271_update_role_permissions_lock_admin_accounts.sql
-- 슈퍼관리자 자기 제한 — 사이드바 「권한 관리」 상설 항목 제거에 따른 후속 잠금
-- 사양서: docs/specs/2026-07-29-super-admin-self-restriction.md (271 은 그 후속 조각)
--
-- 재정의 베이스 확인:
--   `grep -l "FUNCTION public.update_role_permissions" supabase/migrations/*.sql`
--   → 211_role_permissions_save.sql, 270_update_role_permissions_super.sql 두 개만 존재.
--   211 이 최초 정의, 270 이 지금까지의 유일한 개정판이자 "번호가 가장 큰 정의".
--   따라서 이번 271 은 270 원문을 베이스로 삼는다(211 을 베이스로 삼으면 270 에서
--   넣은 super_admin 허용·슈퍼 잠금 목록·배치 상한 200 이 통째로 사라진다 — 정산
--   함수 재정의 사고[project_settlement_reviewer_amount 메모리]와 같은 유형의 함정).
--
-- 배경(사양서 밖 후속 결정, 2026-07-29):
--   270 은 잠금 방지 장치 3중 중 하나로 "사이드바에 「권한 관리」 상설 항목"을
--   두어, 슈퍼관리자가 실수로 menu.permissions 를 숨겨도 진입로가 하나 더
--   남게 했다. 오늘 사용자 결정으로 그 사이드바 상설 항목을 제거한다 — 그러면
--   권한 관리 화면의 유일한 진입점이 「관리자 계정」 화면(menu.admin-accounts)
--   안의 버튼(btnPermManageBtn) 하나로 좁아진다.
--   이 상태에서 슈퍼관리자가 menu.admin-accounts 를 hidden/read 로 낮추면,
--   ① 「관리자 계정」 화면 자체가 사이드바에서 사라지고 ② 그 안의 「권한 관리」
--   버튼도 함께 사라져 아무도 권한 관리 화면에 들어갈 수 없는 잠금 사고가 된다
--   (menu.permissions 를 직접 잠그는 것과 최종 결과가 같음 — 진입로만 다름).
--
-- 사용자 결정 원문: 「슈퍼관리자는 뺄 수 없게 하고 나머지 관리자는 권한에 따라
--   보이게」 → menu.admin-accounts 는 super_admin 만 write 고정. campaign_admin·
--   campaign_manager 는 지금 그대로(자유롭게 write/read/hidden 설정 가능,
--   이번 마이그레이션이 이 두 등급에 어떤 제약도 추가하지 않음).
--
-- 이번 변경(270 대비 diff, 이 한 가지뿐):
--   슈퍼 잠금 목록(권한 상승 방지 IF 문 중 super_admin 쪽 — 270 라인 148~153)에
--   기존 3개(permissions.manage·admin.manage·menu.permissions) 옆에
--   'menu.admin-accounts' 1개를 추가한다. 이 IF 문 하나만 수정하고, 함수의
--   나머지(등급 2종 denylist·필수값 검증·FOR UPDATE 낙관적 락·idempotent 처리·
--   이력 INSERT·배치 상한 200·반환값·시그니처·SECURITY DEFINER·search_path)는
--   270 원문에서 단 한 글자도 바꾸지 않는다.
--   ⚠️ 등급 2종(campaign_admin/campaign_manager)의 denylist 블록은 완전히
--   별개이며 이번 변경과 무관 — 270 원문 그대로 완전 보존.
--
-- 데이터 정합성 보정(방어적, 함수 변경과 별개):
--   270 배포~이번 마이그레이션 사이에는 menu.admin-accounts 가 아직 슈퍼 잠금
--   목록에 없었으므로, 그 사이 권한 관리 화면에서 실수로 super_admin 의
--   menu.admin-accounts 를 write 가 아닌 값으로 낮췄을 가능성을 배제할 수 없다.
--   이번 마이그레이션은 함수 재정의와 함께, role_permissions 에서 그 값을
--   다시 'write' 로 강제 보정한다(이미 write 면 조건에 안 걸려 0행 — 멱등).
--   213_activate_pii_masking.sql 과 동일한 패턴(CTE로 실제 변경된 행만 이력
--   INSERT, actor=NULL=시스템 마이그레이션)을 따른다.
--
-- default_level 은 변경하지 않는다:
--   268_role_permissions_super_admin_rows.sql 이 그 시점에 존재하던 모든
--   feature_key 에 대해 super_admin 행을 (access_level, default_level) 모두
--   'write'/'write' 로 시드했고, menu.admin-accounts 는 207/214 부터 이미
--   존재하던 키라 268 시드 대상에 포함됐다. 268 이후 role_permissions 를
--   직접 만지는 마이그레이션은 269·270(둘 다 함수만, 데이터 미변경) 뿐이라
--   super_admin/menu.admin-accounts 의 default_level 은 지금도 'write' 다
--   (`grep -l role_permissions supabase/migrations/27*.sql` 로 재확인—
--   268/269/270 세 개만 걸리고 269·270 은 데이터를 안 건드림). 즉 이 값은
--   215_restore_role_permissions_defaults.sql 「기본값 복원」이 이미 'write'로
--   되돌리는 대상이라, 이번 마이그레이션에서 default_level 을 별도로 바꿀
--   필요가 없다(215 파일 상단 "정책 변경 마이그레이션은 default_level 도 함께
--   바꿀 것" 경고에 해당하지 않음 — 여기서는 default_level 자체의 "기본 정책"을
--   바꾸는 게 아니라 access_level 이 그 기본값에서 벗어나지 못하게 서버가
--   막는 것뿐이므로 baseline 은 그대로 write 유지가 맞다).
--
-- 「기본값 복원」(restore_role_permissions_defaults, 215)과의 관계:
--   215 는 role 무관하게 access_level <> default_level 인 행을 전부
--   default_level 로 되돌린다. super_admin/menu.admin-accounts 의 default_level
--   이 'write' 인 이상, 복원을 눌러도 이 값은 'write' 로(또는 이미 'write'라면
--   무변화로) 수렴한다 — 이번 잠금과 방향이 어긋나지 않는다. 반대로 만약 이후
--   어떤 마이그레이션이 이 키의 default_level 자체를 write 가 아닌 값으로 바꾸면
--   "기본값 복원" 버튼이 이번 잠금과 정면 충돌(복원이 잠금 상태로 되돌리는
--   역설)하니, 그런 변경을 하는 마이그레이션은 반드시 이 파일과 270 의 슈퍼
--   잠금 목록에서 해당 키를 먼저 빼야 한다.
--
-- 이번 마이그레이션이 다루지 않는 것(별도 후속 필요, 아래 응답 텍스트에 기록):
--   dev/js/admin-permissions.js 의 클라이언트측 배열 PERM_SUPER_LOCKED(41행)에도
--   동일한 3개 키가 있다 — 화면에서 셀을 잠가 보여주는 용도. 이번 마이그리이션은
--   서버 최종 방어선만 넣으므로, 클라 배열에 'menu.admin-accounts' 를 추가하지
--   않으면 슈퍼관리자가 그 칸을 바꾸려다 저장 시점에 서버 42501 에러 토스트만
--   보고 왜 안 되는지 화면상으로는 알 수 없다(기능은 안전, UX만 거칠음).
--
-- 응급 복구(잠금 사고가 실제로 나면):
--   UPDATE public.role_permissions
--      SET access_level = default_level
--    WHERE role = 'super_admin' AND feature_key = 'menu.admin-accounts';
--   (SQL Editor 에서 직접 실행 — 함수 경유 시도는 로그인 세션이 필요해 사고 중엔
--   못 쓸 수 있음. 270 원문과 동일한 응급 절차.)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ------------------------------------------------------------
-- 0. 데이터 정합성 보정 — super_admin 의 menu.admin-accounts 를 write 로 강제
--    (이미 write 면 WHERE 조건에 안 걸려 0행, 완전 멱등)
-- ------------------------------------------------------------
WITH upd AS (
  UPDATE public.role_permissions
     SET access_level = 'write',
         updated_at   = now()
   WHERE role = 'super_admin'
     AND feature_key = 'menu.admin-accounts'
     AND access_level <> 'write'
  RETURNING role, feature_key, access_level AS reverted_from
)
INSERT INTO public.role_permission_history (role, feature_key, prev_level, next_level, actor)
SELECT role, feature_key, reverted_from, 'write', NULL FROM upd;

-- ------------------------------------------------------------
-- 1. 함수 재정의 — 270 원문 + 슈퍼 잠금 목록에 'menu.admin-accounts' 1개 추가
-- ------------------------------------------------------------
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

  -- 배치 상한 — 카탈로그(41개 — 2026-07-29 menu.permissions 제거) x 등급(3) = 최대 123셀. 270 과 동일하게 200 유지
  -- (이번 변경은 잠금 목록에 키 1개를 추가하는 것뿐 — 카탈로그 총 개수는 불변).
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
    --    검증을 그냥 통과해버리는 함정을 피하기 위함). super_admin 도 허용(270부터).
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
    --     갖는 것 자체가 권한 상승이므로 항상 숨김 고정). 이번 271 은 이 블록을
    --     전혀 건드리지 않는다 — menu.admin-accounts 는 두 등급 모두 자유
    --     설정 그대로(사용자 결정: "나머지 관리자는 권한에 따라 보이게").
    IF v_role IN ('campaign_admin', 'campaign_manager')
       AND v_feature_key IN ('permissions.manage', 'admin.manage')
       AND v_next_level <> 'hidden' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) hidden 외의 값으로 저장할 수 없습니다(권한 상승 차단)', v_row.idx, v_feature_key
        USING ERRCODE = '42501';
    END IF;

    --   · super_admin: permissions.manage·admin.manage·menu.permissions·
    --     menu.admin-accounts 4개는 write 외 거부(잠금 방지). 271 에서
    --     menu.admin-accounts 를 추가한 이유 — 사이드바 「권한 관리」 상설
    --     항목이 제거되어, 이 키가 「관리자 계정」 화면(권한 관리 버튼의 유일한
    --     진입로)의 노출을 결정하는 사실상 새로운 잠금 지점이 됐기 때문이다.
    IF v_role = 'super_admin'
       AND v_feature_key IN ('permissions.manage', 'admin.manage', 'menu.permissions', 'menu.admin-accounts')
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
  '[271] 관리자 권한 설정 화면 일괄 저장 RPC(270 재정의). super_admin 전용(is_super_admin() 가드). '
  'p_changes = [{role, feature_key, prev_level, next_level}, ...] 배열(role 은 super_admin 포함 3종), '
  '함수 전체가 한 트랜잭션. 낙관적 락은 별도 version 컬럼 없이 prev_level 값 비교로 대체. '
  'denylist 는 등급별로 방향이 반대다 — campaign_admin/campaign_manager 의 permissions.manage·admin.manage 는 '
  'hidden 외 거부(권한 상승 차단), super_admin 의 permissions.manage·admin.manage·menu.permissions·'
  'menu.admin-accounts(271 추가) 는 write 외 거부(잠금 방지 — 복구 경로 자기 차단 방지). '
  '배열 상한 200(42키×3등급=126칸 여유). 변화 없는 원소는 이력 없이 건너뜀(idempotent). '
  '반환값 = 실제 적용된 건수.';

GRANT EXECUTE ON FUNCTION public.update_role_permissions(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ⚠️ SQL Editor 는 service_role 세션이라 auth.uid() 가 없어 is_super_admin() 이
--   항상 false 다. 아래 SELECT public.update_role_permissions(...) 호출은 전부
--   "① super_admin 만 호출 가능" 가드에서 즉시 42501 로 막힌다 — 이는 정상이며
--   버그가 아니다. 실제 등급별 판정은 각 등급 계정으로 로그인한 브라우저 세션
--   (권한 관리 화면 또는 콘솔의 supabase.rpc)에서 확인할 것.
-- ============================================================
/*

-- [V0] 데이터 정합성 보정이 적용됐는지 — super_admin 의 menu.admin-accounts 가
--   write/write 인지 확인 (이 마이그레이션 적용 직후 항상 참이어야 함)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key = 'menu.admin-accounts'
ORDER BY role;
-- 기대: super_admin=write/write, campaign_admin=write/write(기존값 유지),
--   campaign_manager=write/write(기존값 유지 — 이번 마이그레이션이 이 두 등급을 건드리지 않음)

-- [V1] 함수 시그니처 확인
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_role_permissions';

-- [V2] (super_admin 계정 로그인 세션에서) 신규 잠금 거부 확인 — menu.admin-accounts 를
--   super_admin 에서 hidden 으로 낮추려는 시도 (에러 기대)
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"menu.admin-accounts","prev_level":"write","next_level":"hidden"}]'::jsonb
-- );
-- 기대: ERROR 42501, 메시지에 "잠금 방지" 포함

-- [V3] (super_admin 계정 로그인 세션에서) 기존 잠금 3종 방향 불변 확인 — menu.permissions
--   를 read 로 낮추려는 시도 (여전히 거부돼야 함)
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"menu.permissions","prev_level":"write","next_level":"read"}]'::jsonb
-- );
-- 기대: ERROR 42501, 메시지에 "잠금 방지" 포함 (270 원문 동작 그대로)

-- [V4] (campaign_admin 또는 campaign_manager 계정 로그인 세션에서) menu.admin-accounts
--   를 자유롭게 바꿀 수 있는지 확인 — 사용자 결정("나머지 관리자는 권한에 따라 보이게")
--   대로 이번 잠금이 이 두 등급에는 전혀 영향을 주지 않아야 함
-- SELECT public.update_role_permissions(
--   '[{"role":"campaign_manager","feature_key":"menu.admin-accounts","prev_level":"write","next_level":"hidden"}]'::jsonb
-- );
-- 기대: 1 (적용 성공 — 거부되면 회귀)
-- 확인 후 원복:
-- SELECT public.update_role_permissions(
--   '[{"role":"campaign_manager","feature_key":"menu.admin-accounts","prev_level":"hidden","next_level":"write"}]'::jsonb
-- );

-- [V5] (super_admin 계정 로그인 세션에서) 잠금 목록 밖 키는 여전히 정상 저장되는지
--   회귀 확인 — 예: settlement.pay 를 write → read
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"settlement.pay","prev_level":"write","next_level":"read"}]'::jsonb
-- );
-- 기대: 1 (적용 성공)
-- 확인 후 원복:
-- SELECT public.update_role_permissions(
--   '[{"role":"super_admin","feature_key":"settlement.pay","prev_level":"read","next_level":"write"}]'::jsonb
-- );

*/

-- ============================================================
-- 롤백 — 270 원문으로 되돌림(슈퍼 잠금 목록에서 menu.admin-accounts 제거)
-- ⚠️ 데이터 보정(0단계) 자체는 되돌릴 필요 없음 — super_admin 의
--   menu.admin-accounts 가 write 인 것은 그 자체로 무해(268 시드값과 동일)하며,
--   함수만 270 으로 되돌리면 다시 자유롭게 바꿀 수 있는 상태로 복귀한다.
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

  IF jsonb_array_length(p_changes) > 200 THEN
    RAISE EXCEPTION '[update_role_permissions] p_changes 배열이 너무 큽니다(최대 200개, 입력 %개)', jsonb_array_length(p_changes)
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

    IF v_role IS NULL OR v_role NOT IN ('super_admin', 'campaign_admin', 'campaign_manager') THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: role 값이 올바르지 않습니다(super_admin|campaign_admin|campaign_manager 만 허용). 입력: %', v_row.idx, v_role
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

    IF v_role IN ('campaign_admin', 'campaign_manager')
       AND v_feature_key IN ('permissions.manage', 'admin.manage')
       AND v_next_level <> 'hidden' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) hidden 외의 값으로 저장할 수 없습니다(권한 상승 차단)', v_row.idx, v_feature_key
        USING ERRCODE = '42501';
    END IF;

    IF v_role = 'super_admin'
       AND v_feature_key IN ('permissions.manage', 'admin.manage', 'menu.permissions')
       AND v_next_level <> 'write' THEN
      RAISE EXCEPTION '[update_role_permissions] changes[%]: % 은(는) super_admin 에서 write 외의 값으로 저장할 수 없습니다(잠금 방지 — 복구 경로 자기 차단 방지)', v_row.idx, v_feature_key
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
