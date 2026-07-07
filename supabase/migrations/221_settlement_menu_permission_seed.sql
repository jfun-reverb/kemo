-- ============================================================
-- 221_settlement_menu_permission_seed.sql
-- 인플루언서 정산 관리 PR2 — 1/3 (사이드바 메뉴 권한 시드)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §3(⑥ 권한), §7-1
--
-- PR2에서 관리자 정산 페인(#adminPane-settlements)이 신설되므로, 동적 권한
-- 관리(role_permissions, 마이그레이션 207/214)에 사이드바 노출용 feature_key
-- 'menu.settlements' 를 등록한다.
--
-- 값: campaign_admin=write, campaign_manager=hidden — 마이그레이션 220 의
--   settlement.view/settlement.pay 와 동일 등급 배분(사용자 확정 2026-07-07).
--   "메뉴는 보이는데 조회는 서버가 빈 배열로 막는" UX 사고를 피하기 위해
--   메뉴 노출(menu.settlements)과 조회 권한(settlement.view)을 항상 같은
--   값으로 유지할 것(향후 이 둘을 따로 바꾸면 220 파일 상단 주석 참고).
--
-- ADMIN_PERMISSION_CATALOG(dev/lib/shared.js) 등록과 사이드바 data-pane 추가는
-- 화면 작업(메인 세션 병행분) 몫 — 이 마이그레이션은 DB 시드만 담당.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('campaign_admin',   'menu.settlements', 'write',  'write'),
  ('campaign_manager', 'menu.settlements', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 시드 확인 (2행, settlement.view/pay 와 동일 등급인지 대조)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key IN ('menu.settlements', 'settlement.view', 'settlement.pay')
ORDER BY feature_key, role;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DELETE FROM public.role_permissions WHERE feature_key = 'menu.settlements';
