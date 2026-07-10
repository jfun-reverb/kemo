-- ============================================================
-- 228_outbound_role_permissions_seed.sql
-- 인플루언서 추천 도구 1단계-a — 3/4 (동적 권한 시드)
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md §A "권한"
-- 인계서: docs/specs/2026-07-09-influencer-recommendation-stage1-handoff.md §PR-a 3번 항목
--
-- 신규 feature_key 2개를 동적 권한 관리(role_permissions, 마이그레이션 207/214)에 편입:
--   - menu.outbound    : 사이드바 「인플루언서 추천」(가칭) 메뉴 노출 (PR 1단계-b 화면 예정)
--   - outbound.view    : outbound_influencers 테이블 조회·쓰기 게이트
--                        (마이그레이션 226 RLS — has_permission('outbound.view', ...))
--
-- 값: campaign_admin=write, campaign_manager=hidden (사양서 §A "권한: 최고 관리자 +
--   캠페인 관리자, 제한 등급 캠페인 매니저 제외 — 정산 화면 패턴"). access_level·
--   default_level 모두 동일하게 채운다 — role_permissions.default_level 은
--   마이그레이션 214 에서 NOT NULL 로 전환됐으므로 신규 행도 반드시 값을 채워야
--   INSERT 가 성공한다(CHECK 위반 방지, 220/221 과 동일 패턴).
--
-- menu.outbound 과 outbound.view 를 같은 값(write/hidden)으로 유지할 것 —
--   "메뉴는 보이는데 조회는 서버가 막는" UX 사고 방지(221_settlement_menu_
--   permission_seed.sql 주석과 동일 원칙). 이 둘을 향후 따로 바꾸려면 이 파일
--   상단 주석을 참고해 의도적으로 분리하라.
--
-- ADMIN_PERMISSION_CATALOG(dev/lib/shared.js) 등록과 사이드바 data-pane 추가는
-- PR 1단계-b(화면) 몫 — 이 마이그레이션은 DB 시드만 담당.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('campaign_admin',   'menu.outbound',   'write',  'write'),
  ('campaign_admin',   'outbound.view',   'write',  'write'),
  ('campaign_manager', 'menu.outbound',   'hidden', 'hidden'),
  ('campaign_manager', 'outbound.view',   'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 시드 확인 (4행, menu/view 두 키 모두 role별 동일 값인지 대조)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key IN ('menu.outbound', 'outbound.view')
ORDER BY feature_key, role;

-- [V1] has_permission() 동작 확인 (campaign_admin 계정으로 로그인한 세션에서 실행 시 true 기대)
-- SELECT public.has_permission('outbound.view', 'write');

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DELETE FROM public.role_permissions WHERE feature_key IN ('menu.outbound', 'outbound.view');
