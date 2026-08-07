-- ============================================================
-- 268_role_permissions_super_admin_rows.sql
-- 슈퍼관리자 권한 자기 제한 PR 1 — 1/3 (데이터베이스 기반: 등급 허용값 확장 + 슈퍼 행 시드)
-- 사양서: docs/specs/2026-07-29-super-admin-self-restriction.md §4-1 ①
--
-- 배경:
--   마이그레이션 207 은 role_permissions.role CHECK 를
--   ('campaign_admin','campaign_manager') 로 못박아 super_admin 행 저장 자체를
--   원천 차단했다(당시 목적 그대로 "잠금 방지"). 이번 기능은 super_admin 도
--   자기 등급의 접근 수준을 스스로 정할 수 있게 여는 것이므로, 그 차단을
--   구조적으로 풀어야 한다.
--
-- 이번 마이그레이션이 하는 일:
--   ① role_permissions.role CHECK 에 'super_admin' 추가
--   ② role_permission_history.role CHECK 에도 동일하게 추가
--      — 이걸 빠뜨리면 나중에 super_admin 행을 저장할 때 UPDATE 는 성공해도
--        뒤이은 role_permission_history INSERT 가 CHECK 위반으로 실패해
--        저장 트랜잭션 전체가 롤백된다(사양서 §2-6 첫 항목, 가장 흔한 함정).
--   ③ 현재 시점에 존재하는 모든 feature_key 에 대해 super_admin 행을
--      ('super_admin', 키, 'write', 'write') 로 시드
--      — 원본은 `SELECT DISTINCT feature_key FROM public.role_permissions` 다.
--        dev/lib/shared.js 의 ADMIN_PERMISSION_CATALOG 상수를 손으로 옮겨 적지
--        않는다 — 카탈로그와 이 표가 이미 어긋나 있을 수 있어(예: 새 기능 키가
--        카탈로그에는 있지만 아직 시드가 안 됐거나, 반대로 표에만 있는 레거시
--        키가 있을 수 있음), "지금 이 표에 실제로 존재하는 키"만이 신뢰 가능한
--        원본이기 때문이다.
--      access_level = default_level = 'write' 로 채우므로, 이 마이그레이션을
--      적용해도 has_permission() 판정 결과는 이전과 동일하다(마이그레이션 209는
--      is_super_admin() 이면 표 조회 없이 무조건 true 를 반환하는 구조라서,
--      이 시점까지는 이 표에 super_admin 행이 있든 없든 슈퍼 판정에 영향 없음
--      — 실제로 이 표를 조회하기 시작하는 건 다음 마이그레이션 269).
--
-- 영향:
--   ⚠️ 도입 즉시 동작 변화 0. has_permission() 은 아직 이 표의 super_admin 행을
--   보지 않는다(269 에서 바뀜). update_role_permissions() 도 아직 super_admin
--   role 을 허용하지 않는다(270 에서 바뀜) — 지금은 순수하게 "그릇"만 만든다.
--
-- ⚠️ 롤백 순서: 270 → 269 → 268 (적용의 역순).
--    268 을 먼저 되돌리면 CHECK 는 2등급으로 좁아지는데 270 의 저장 함수는 여전히
--    super_admin 을 허용해, 시도 시 이력 INSERT 가 제약 위반으로 실패한다
--    (트랜잭션 롤백이라 데이터는 안전하지만 원인을 찾기 어려운 오류가 난다).
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. role_permissions.role CHECK 확장
--    (207 은 명시적 제약 이름을 안 줬으므로 Postgres 기본 명명 규칙
--    "<table>_<column>_check" 을 그대로 사용 — 214 의 DROP/ADD CONSTRAINT
--    패턴과 동일)
-- ============================================================
ALTER TABLE public.role_permissions
  DROP CONSTRAINT IF EXISTS role_permissions_role_check;
ALTER TABLE public.role_permissions
  ADD CONSTRAINT role_permissions_role_check
    CHECK (role IN ('super_admin', 'campaign_admin', 'campaign_manager'));

COMMENT ON TABLE public.role_permissions IS
  '관리자 등급(super_admin/campaign_admin/campaign_manager)별 기능(feature_key) 접근 수준. '
  'super_admin 행은 268부터 저장 가능(자기 제한 기능) — 잠금 방지는 이제 "행 저장 자체를 막는 것"이 '
  '아니라 has_permission() 의 fail-open 계약(269) + update_role_permissions() 의 슈퍼 잠금 목록(270)이 '
  '담당한다. 카탈로그(feature_key 목록)의 단일 소스는 dev/lib/shared.js ADMIN_PERMISSION_CATALOG.';

-- ============================================================
-- 2. role_permission_history.role CHECK 확장
--    ⚠️ 이걸 빠뜨리면 268 시드는 성공해도, 이후 update_role_permissions()가
--    super_admin 행을 UPDATE 할 때 role_permission_history INSERT 에서
--    CHECK 위반이 나 저장 트랜잭션 전체가 롤백된다(사양서 §2-6).
-- ============================================================
ALTER TABLE public.role_permission_history
  DROP CONSTRAINT IF EXISTS role_permission_history_role_check;
ALTER TABLE public.role_permission_history
  ADD CONSTRAINT role_permission_history_role_check
    CHECK (role IN ('super_admin', 'campaign_admin', 'campaign_manager'));

COMMENT ON TABLE public.role_permission_history IS
  'role_permissions 변경 이력(audit). 268부터 super_admin 행도 기록 가능. '
  'prev_level NULL 허용 = 최초 등록(변경 전 값 없음).';

-- ============================================================
-- 3. 슈퍼 행 시드 — 현재 이 표에 존재하는 모든 feature_key 기준
--    (카탈로그 상수를 손으로 옮기지 않고, 이 표 자체를 원본으로 삼는다)
-- ============================================================
WITH existing_keys AS (
  SELECT DISTINCT feature_key FROM public.role_permissions
)
INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
SELECT 'super_admin', feature_key, 'write', 'write'
FROM existing_keys
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] CHECK 제약이 super_admin 을 허용하는지 확인 (두 표 모두)
SELECT conrelid::regclass AS table_name, conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname IN ('role_permissions_role_check', 'role_permission_history_role_check');
-- 기대: 둘 다 definition 에 'super_admin' 포함

-- [V1] 등급별 행 수가 동일한지 (도입 무영향 검증의 핵심 — 사양서 §5-2 A)
SELECT role, count(*) FROM public.role_permissions GROUP BY role ORDER BY role;
-- 기대: super_admin = campaign_admin = campaign_manager (전부 42)

-- [V2] 슈퍼 행 중 write 가 아닌 것이 0건인지 (도입 즉시 전부 write 여야 함)
SELECT count(*) FROM public.role_permissions
WHERE role = 'super_admin' AND (access_level <> 'write' OR default_level <> 'write');
-- 기대: 0

-- [V3] 전체 행 수 (42 feature_key × 3 role = 126)
SELECT count(*) FROM public.role_permissions;
-- 기대: 126

-- [V4] role_permission_history 에 super_admin 이력이 아직 없는지 (시드는 INSERT 만, 이력 기록 안 함)
SELECT count(*) FROM public.role_permission_history WHERE role = 'super_admin';
-- 기대: 0 (이 마이그레이션은 role_permissions 를 직접 INSERT — update_role_permissions() RPC 를
--   거치지 않으므로 이력이 안 남는다. 최초 시드는 audit 대상이 아니라는 기존 관례(207도 동일)와 일치)

*/

-- ============================================================
-- 롤백
-- ============================================================
/*

DELETE FROM public.role_permission_history WHERE role = 'super_admin';
DELETE FROM public.role_permissions WHERE role = 'super_admin';

ALTER TABLE public.role_permission_history
  DROP CONSTRAINT IF EXISTS role_permission_history_role_check;
ALTER TABLE public.role_permission_history
  ADD CONSTRAINT role_permission_history_role_check
    CHECK (role IN ('campaign_admin', 'campaign_manager'));

ALTER TABLE public.role_permissions
  DROP CONSTRAINT IF EXISTS role_permissions_role_check;
ALTER TABLE public.role_permissions
  ADD CONSTRAINT role_permissions_role_check
    CHECK (role IN ('campaign_admin', 'campaign_manager'));

NOTIFY pgrst, 'reload schema';

*/
