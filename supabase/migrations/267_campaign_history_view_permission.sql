-- ============================================================
-- 267_campaign_history_view_permission.sql
-- 캠페인 변경 이력 열람 권한 일원화 (PR 4)
-- 사양서: docs/specs/2026-07-27-campaign-full-change-history.md §0 Q3 · §5 PR 4
--
-- 목적:
--   `campaign_caution_history`(077, 주의사항·참여방법 이력) 와
--   `campaign_change_history`(265, 그 외 전체 항목 이력) 두 표는 지금까지
--   SELECT 정책이 `is_super_admin()` 으로 하드코딩돼 있다. 반면 권한 카탈로그
--   `dev/lib/shared.js`(ADMIN_PERMISSION_CATALOG)에는 `campaign.caution_history_view`
--   (「캠페인 주의사항 변경 이력 열람」, server_enforced:true) 항목이 마이그레이션
--   207 에서 이미 시드되어 있지만, 실제로 이 두 표 어디에서도 참조되지 않는다
--   (등록만 되고 안 쓰이는 상태 — 「권한 관리」 화면에서 켜도 아무 일도 안 일어남).
--
--   이 마이그레이션은 두 표의 SELECT 정책을 `is_super_admin()` 고정에서
--   `has_permission('campaign.caution_history_view', 'read')` 판정으로 교체해,
--   앞으로 super_admin 이 「권한 관리」 화면에서 campaign_admin/campaign_manager
--   등급별로 열람 가능 여부를 직접 조절할 수 있게 한다(사양서 Q3 결정).
--
-- has_permission(p_feature, p_min) 계약 (마이그레이션 209 원문 재확인, 변경 없음):
--   · is_super_admin() 이면 role_permissions 테이블을 조회하지 않고 무조건 true
--     (코드 레벨 하드 통과 — role_permissions 에는 애초 super_admin 행이 존재할 수
--     없다, CHECK 제약 마이그레이션 207). ⇒ super_admin 은 이 마이그레이션 전후로
--     동작이 완전히 동일 — 항상 열람 가능.
--   · super_admin 이 아니면 admins.role 로 (role, feature_key) 를 role_permissions
--     에서 조회하고, 값이 없으면 false(안전측 거부).
--
-- role_permissions 현재값 (변경 없음 — 이 마이그레이션은 데이터 시드를 건드리지 않음):
--   campaign.caution_history_view 는 마이그레이션 207(시드) · 214(default_level 백필)
--   에서 이미 campaign_admin=hidden / campaign_manager=hidden 으로 들어가 있다.
--   ⇒ has_permission('campaign.caution_history_view','read') 는 두 등급 모두 지금
--   시점엔 false 를 반환 — 정책 교체 직후에도 "super_admin 만 보인다"는 현재 동작이
--   그대로 유지된다(도입 즉시 동작 변화 0). 향후 super_admin 이 「권한 관리」 화면에서
--   campaign_admin(또는 campaign_manager)을 read 로 바꾸면 그 순간부터 그 등급도
--   즉시 열람 가능해진다(DB 함수만 바뀌므로 배포 재실행 불필요).
--
--   ⚠️ role_permissions 는 feature_key 당 "라벨"을 저장하지 않는다(role, feature_key,
--   access_level, default_level, updated_at, updated_by 컬럼뿐 — 마이그레이션 207).
--   라벨(「캠페인 주의사항 변경 이력 열람」)의 단일 소스는 dev/lib/shared.js
--   ADMIN_PERMISSION_CATALOG 뿐이라 이 마이그레이션은 라벨을 건드릴 게 없다
--   (요청대로 코드 상수 쪽은 별도로 수정 예정).
--
-- 정책 이름 변경 사유:
--   기존 이름 `*_select_super` 는 "super_admin 전용"이라는 지금 구현을 이름에
--   그대로 박아둔 것이라, 앞으로 등급별로 조절 가능해지는 이 변경 이후에는
--   이름이 실제 동작과 어긋난다(super 전용이 아니게 됨). 옛 정책은 DROP 하고
--   `*_select_perm` 이름으로 새로 만든다.
--
-- 영향 범위:
--   두 표의 SELECT 정책만 교체. INSERT/UPDATE/DELETE 정책(정의 자체가 없어 암묵
--   거부)·트리거·다른 테이블은 전혀 건드리지 않는다. record_caution_history() RPC
--   (077, INSERT 전용, `is_campaign_admin()` 가드)도 무영향 — 열람(SELECT) 권한과
--   기록(INSERT) 권한은 서로 다른 관문이라 이번 변경은 "누가 이력을 볼 수 있는가"
--   만 바꾼다.
--
--   ⚠️ 화면(dev/js/admin.js)은 이 마이그레이션 범위 밖이다. 더보기 메뉴의 「변경
--   이력」 항목(admin.js:2863~2865)과 openCautionHistoryModal() 진입 가드
--   (admin.js:989)가 여전히 `currentAdminInfo?.role === 'super_admin'` 을 직접
--   비교하는 하드코딩이라, 이 마이그레이션만 적용하고 화면을 안 고치면
--   campaign_admin 에게 read 를 줘도 메뉴 자체가 안 보여 실질적으로 열람할 수
--   없다(서버는 허용해도 클라이언트 진입로가 막혀 있음). 화면 쪽 전환(하드코딩 →
--   canRead('campaign.caution_history_view') 사용)은 사양서 PR 4 범위의 별도
--   작업으로 이 마이그레이션 다음에 필요하다.
--
-- 롤백:
--   BEGIN;
--   DROP POLICY IF EXISTS "campaign_caution_history_select_perm" ON public.campaign_caution_history;
--   CREATE POLICY "campaign_caution_history_select_super" ON public.campaign_caution_history
--     FOR SELECT TO authenticated USING (public.is_super_admin());
--   DROP POLICY IF EXISTS "campaign_change_history_select_perm" ON public.campaign_change_history;
--   CREATE POLICY "campaign_change_history_select_super" ON public.campaign_change_history
--     FOR SELECT TO authenticated USING (public.is_super_admin());
--   NOTIFY pgrst, 'reload schema';
--   COMMIT;
-- ============================================================

BEGIN;

-- ============================================================
-- 1. campaign_caution_history (077) — SELECT 정책 교체
-- ============================================================
DROP POLICY IF EXISTS "campaign_caution_history_select_super" ON public.campaign_caution_history;
DROP POLICY IF EXISTS "campaign_caution_history_select_perm"  ON public.campaign_caution_history;

CREATE POLICY "campaign_caution_history_select_perm" ON public.campaign_caution_history
  FOR SELECT TO authenticated
  USING (public.has_permission('campaign.caution_history_view', 'read'));

-- ============================================================
-- 2. campaign_change_history (265) — SELECT 정책 교체
-- ============================================================
DROP POLICY IF EXISTS "campaign_change_history_select_super" ON public.campaign_change_history;
DROP POLICY IF EXISTS "campaign_change_history_select_perm"  ON public.campaign_change_history;

CREATE POLICY "campaign_change_history_select_perm" ON public.campaign_change_history
  FOR SELECT TO authenticated
  USING (public.has_permission('campaign.caution_history_view', 'read'));

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 데이터베이스 SQL Editor 에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V1] 정책이 예정대로 교체됐는지 확인 (각 표 1행씩, has_permission 함수 참조)
SELECT schemaname, tablename, policyname, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('campaign_caution_history', 'campaign_change_history')
ORDER BY tablename;
-- 기대값: campaign_caution_history_select_perm / campaign_change_history_select_perm
--         각 1행, qual 에 has_permission(...) 문자열 포함. *_select_super 이름은 없어야 함(DROP됨)

-- [V2] role_permissions 현재값 재확인 — 이 마이그레이션이 시드값을 안 건드렸는지
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key = 'campaign.caution_history_view'
ORDER BY role;
-- 기대값: campaign_admin hidden/hidden, campaign_manager hidden/hidden (마이그레이션 207·214 그대로)

-- [V3] has_permission 함수가 이 feature_key 에 대해 지금 false 를 반환하는지
--      (SQL Editor 는 service_role 세션이라 auth.uid() 가 없어 admins 조회가 NULL →
--      is_super_admin() 도 false 이므로 has_permission 은 항상 false 로 나온다.
--      실제 등급별 결과는 각 등급 계정으로 로그인한 클라이언트 세션에서 확인할 것 — 아래 안내 참고)
SELECT public.has_permission('campaign.caution_history_view', 'read');
-- 기대값: false (SQL Editor 세션에는 로그인한 관리자가 없으므로 서비스 롤 세션은 참고용)

*/

-- ============================================================
-- 등급별 실제 동작 확인 (SQL Editor 로는 auth.uid() 가 없어 재현 불가 — 브라우저에서 확인)
-- ============================================================
-- 1) super_admin 계정으로 로그인 → 두 표 SELECT 항상 성공 (has_permission 이 코드 레벨에서
--    무조건 true — role_permissions 값과 무관)
-- 2) campaign_admin/campaign_manager 계정으로 로그인 → 이 마이그레이션 적용 직후에는
--    두 표 모두 SELECT 결과 0행(RLS 거부, 에러 아님) — role_permissions 가 아직 hidden/hidden
--    이기 때문. 「권한 관리」 화면(#permissions, PR2)에서 super_admin 이 해당 등급의
--    campaign.caution_history_view 를 read 로 바꾸면 → 그 즉시(재배포 불필요) 그 등급
--    계정도 두 표 SELECT 가 행을 반환하기 시작한다.
-- 3) 단, admin.js 의 메뉴 진입 가드(더보기 「변경 이력」 항목·openCautionHistoryModal)가
--    여전히 role==='super_admin' 하드코딩이라, 화면 쪽을 canRead('campaign.caution_history_view')
--    로 바꾸기 전까지는 campaign_admin 등급에게 read 를 줘도 메뉴 자체가 안 보여 이 SQL
--    권한만으로는 화면상 완전히 열리지 않는다(위 「영향 범위」 경고 참고, 별도 작업 필요).
-- ============================================================
