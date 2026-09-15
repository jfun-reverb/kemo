-- ============================================================
-- 439. 광고 추적 열쇠말 2개를 동적 권한 관리에 편입 (6행)
-- ============================================================
-- 사양서: docs/specs/2026-09-03-meta-pixel.md 「관리 화면 — 위치·권한」
-- 작업표: docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 2」
-- 선례  : 355(회원 탈퇴 대행) · 404(리포트)
--
--   menu.ad-tracking    — 사이드바 「광고 추적」 노출. 캠페인 매니저는 **읽기**(현재 상태만 본다)
--   ad_tracking.manage  — 켜기·끄기·픽셀 아이디 저장. 서버 강제(438 update_meta_pixel_settings)
--
-- 🔴 **438 다음에 적용한다.** 438 의 저장 함수가 이 열쇠말로 판정하므로, 이 시드가 없으면
--    캠페인 관리자도 조용히 거부된다(has_permission 은 등급 2종에 행이 없으면 fail-closed).
--
-- 🔴 **화면(작업 4)과 같은 배포에 실려야 한다.** 화면 permLevel() 은 못 읽으면 쓰기로 폴백
--    (fail-open)하고 서버는 거부(fail-closed) — 방향이 반대라 시드가 빠지면 「버튼은 보이는데
--    누르면 거부」가 된다.
--
-- 🔴 **세 등급 행을 다 넣는다**(268 이후 규칙). `default_level` 은 NOT NULL — 「기본값 복원」(215)
--    기준이라 access_level 과 같게 둔다.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'menu.ad-tracking',   'write',  'write'),
  ('campaign_admin',   'menu.ad-tracking',   'write',  'write'),
  ('campaign_manager', 'menu.ad-tracking',   'read',   'read'),

  ('super_admin',      'ad_tracking.manage', 'write',  'write'),
  ('campaign_admin',   'ad_tracking.manage', 'write',  'write'),
  ('campaign_manager', 'ad_tracking.manage', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 6행이 들어갔는가
SELECT role, feature_key, access_level, default_level
  FROM public.role_permissions
 WHERE feature_key IN ('menu.ad-tracking','ad_tracking.manage')
 ORDER BY feature_key, role;
-- 기대: 6행 · 매니저 menu=read / manage=hidden · access_level = default_level

-- [V2] 🔴 실제 로그인 브라우저에서 (편집기는 has_permission 분기를 안 탄다)
--   슈퍼·캠페인 관리자 : (await db.rpc('has_permission',{p_feature:'ad_tracking.manage', p_min:'write'})).data === true
--   캠페인 매니저      : 같은 호출이 false

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ SQL 자체는 순서와 무관하게 성공한다(다른 표가 이 행을 참조하지 않는다). 다만 438 의 저장 함수가
--    살아 있는 채 이 행만 지우면 그 사이 캠페인 관리자가 저장을 거부당한다 — 화면·438 을 먼저 되돌릴 것
-- DELETE FROM public.role_permissions
--  WHERE feature_key IN ('menu.ad-tracking','ad_tracking.manage');
