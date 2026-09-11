-- ============================================================
-- 404. 리포트 열쇠말 3개를 동적 권한 관리에 편입 (9행)
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 3」
-- 선례  : 355(회원 탈퇴 대행 권한 시드)
--
-- 🔴 **이 파일만 적용하면 동작 변화가 0 이다** — 아직 이 열쇠말을 읽는 곳이 없다.
--    그러나 **화면(작업 4)과 반드시 같은 배포에 실려야 한다.**
--    화면만 먼저 나가면 캠페인 관리자에게 **버튼은 보이는데 눌러도 거부**된다.
--    서버 `has_permission` 은 등급 2종에 **행이 없으면 거부**(fail-closed)이고
--    화면 `permLevel()` 은 `_rolePermMap[…] || 'write'` 라 **못 읽으면 쓰기로 폴백**
--    (fail-open)이다 — **방향이 정확히 반대**다.
--
-- 🔴 **세 등급 행을 다 넣는다.** 마이그레이션 268 이 `role_permissions.role` CHECK 에
--    `super_admin` 을 더했고, 그 뒤로 신규 열쇠말은 세 등급을 다 채워야 한다.
--    최고 관리자 행을 빼면 기능은 도는데(그쪽은 fail-open) **권한 관리 화면의
--    슈퍼 열이 빈칸**으로 떠서 더 헷갈린다.
--
-- ⚠️ `default_level` 은 NOT NULL 이다 — 안 채우면 삽입 자체가 실패한다.
--    「기본값 복원」(215)이 되돌릴 기준값이라 `access_level` 과 같은 값으로 둔다.
--
-- ⚠️ 값 판단 — 정산 화면·아웃바운드 명단과 같은 기준이다.
--    리포트는 브랜드에 나가는 산출물이라 **캠페인 매니저는 제외**한다.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'menu.reports',  'write',  'write'),
  ('campaign_admin',   'menu.reports',  'write',  'write'),
  ('campaign_manager', 'menu.reports',  'hidden', 'hidden'),

  ('super_admin',      'report.export', 'write',  'write'),
  ('campaign_admin',   'report.export', 'write',  'write'),
  ('campaign_manager', 'report.export', 'hidden', 'hidden'),

  ('super_admin',      'report.share',  'write',  'write'),
  ('campaign_admin',   'report.share',  'write',  'write'),
  ('campaign_manager', 'report.share',  'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 9행이 들어갔는가
SELECT role, feature_key, access_level, default_level
  FROM public.role_permissions
 WHERE feature_key IN ('menu.reports','report.export','report.share')
 ORDER BY feature_key, role;
-- 기대: 9행 · 매니저만 hidden · access_level = default_level

-- [V2] 🔴 실제 로그인 브라우저에서 (편집기는 has_permission 분기를 안 탄다)
--   캠페인 관리자 : (await db.rpc('has_permission',{p_feature:'menu.reports'})).data === true
--   캠페인 매니저 : 같은 호출이 false

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DELETE FROM public.role_permissions
--  WHERE feature_key IN ('menu.reports','report.export','report.share');
