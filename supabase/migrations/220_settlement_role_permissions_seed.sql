-- ============================================================
-- 220_settlement_role_permissions_seed.sql
-- 인플루언서 정산 관리 PR1 — 4/4 (동적 권한 시드)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §3(⑥ 권한), §9
--
-- 신규 feature_key 2개를 동적 권한 관리(role_permissions, 마이그레이션 207/214)에 편입:
--   - settlement.view : 정산 조회 (settlements/settlement_events RLS 게이트 — 마이그레이션 217)
--   - settlement.pay  : 송금 처리 (PR2 mark_settlement_paid RPC 게이트 예정)
--
-- 값: campaign_admin=write, campaign_manager=hidden (사용자 확정 2026-07-07,
--   사양서 §3 ⑥ "campaign_admin 이상" 과 동일 동작). access_level·default_level 모두
--   동일하게 채운다 — role_permissions.default_level 은 마이그레이션 214 에서 NOT NULL
--   로 전환됐으므로 신규 행도 반드시 값을 채워야 INSERT 가 성공한다(CHECK 위반 방지).
--
-- ⚠️ menu.settlements 는 이번에 추가하지 않는다 — PR1은 화면이 없어 사이드바 항목
--   자체가 없다(ADMIN_PERMISSION_CATALOG 의 menu.* 는 실제 사이드바 data-pane 노출
--   여부와 1:1). PR2에서 관리자 정산 페인을 만들 때 menu.settlements feature_key +
--   ADMIN_PERMISSION_CATALOG 등록 + 사이드바 항목을 함께 추가할 것(빠뜨리면 권한
--   관리 화면에 정산 메뉴 행이 안 보임).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('campaign_admin',   'settlement.view', 'write',  'write'),
  ('campaign_admin',   'settlement.pay',  'write',  'write'),
  ('campaign_manager', 'settlement.view', 'hidden', 'hidden'),
  ('campaign_manager', 'settlement.pay',  'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 시드 확인 (4행)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key IN ('settlement.view', 'settlement.pay')
ORDER BY feature_key, role;

-- [V1] has_permission() 동작 확인 (campaign_admin 계정으로 로그인한 세션에서 실행 시 true 기대)
-- SELECT public.has_permission('settlement.view', 'read');

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DELETE FROM public.role_permissions WHERE feature_key IN ('settlement.view', 'settlement.pay');
