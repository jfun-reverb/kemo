-- ============================================================
-- 441. 「취소 되돌리기」 열쇠말을 동적 권한 관리에 편입 (3행)
-- ============================================================
-- 사양서: docs/specs/2026-09-15-restore-cancelled-application.md 「설계 → 데이터베이스 ②」
-- 작업표: docs/specs/2026-09-15-restore-cancelled-application-breakdown.md 「조각 2」
-- 선례  : 355(회원 탈퇴 대행) · 439(광고 추적)
--
--   application.restore_cancelled — 회원 본인 취소 신청을 취소 직전 상태로 되돌리기.
--                                   서버 강제(440 restore_cancelled_application)
--
-- 🔴 **440 다음에 적용한다.** 440 의 함수가 이 열쇠말로 판정하므로, 이 시드가 없으면
--    캠페인 관리자도 조용히 거부된다 — has_permission(현재 원본 269)은 슈퍼관리자만
--    「행이 없으면 통과」이고 등급 2종은 **행이 없으면 거부**(fail-closed)이기 때문이다.
--    즉 440 만 적용된 사이에는 캠페인 관리자가 `forbidden` 을 받는다.
--
-- 🔴 **화면과 같은 배포에 실려야 한다.** 화면 permLevel()은 못 읽으면 쓰기로 폴백
--    (fail-open)하고 서버는 거부(fail-closed) — 방향이 반대라 시드가 빠지면
--    「버튼은 보이는데 누르면 거부」가 된다.
--
-- 🔴 **세 등급 행을 다 넣는다**(268 이후 규칙). `default_level` 은 NOT NULL —
--    「기본값 복원」(215) 기준이라 access_level 과 같게 둔다.
--
-- ⚠️ 권한 = **캠페인관리자 이상**(사양서 확정된 결정 2). 캠페인매니저는 숨김 —
--    되돌리기는 회원의 응모를 되살리는 일이라 실무 판단이 필요하다.
--
-- ⚠️ 이 설정이 막는 것은 **이 함수와 화면 버튼뿐**이다(사양서 ⑧). 관리자 누구나
--    applications 표를 직접 수정하는 경로(기존 승인·미승인과 같은 경로)는 그대로 남아
--    있어, 권한 관리 화면의 「서버 차단」 배지를 「모든 경로가 막힌다」로 읽으면 안 된다.
--
-- ⚠️ 같은 열쇠말이 **네 곳**에 있다 — 이 시드 · 440 의 함수 가드 ·
--    ADMIN_PERMISSION_CATALOG(dev/lib/shared.js) · PERM_SUPER_SERVER_ENFORCED(같은 파일).
--    철자가 한 글자만 달라도 조용히 거부된다.
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'application.restore_cancelled', 'write',  'write'),
  ('campaign_admin',   'application.restore_cancelled', 'write',  'write'),
  ('campaign_manager', 'application.restore_cancelled', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 3행이 들어갔는가
SELECT role, feature_key, access_level, default_level
  FROM public.role_permissions
 WHERE feature_key = 'application.restore_cancelled'
 ORDER BY role;
-- 기대: 3행 · 매니저 hidden · access_level = default_level

-- [V2] 🔴 실제 로그인 브라우저에서 (편집기는 has_permission 분기를 안 탄다)
--   슈퍼·캠페인 관리자 : (await db.rpc('has_permission',{p_feature:'application.restore_cancelled', p_min:'write'})).data === true
--   캠페인 매니저      : 같은 호출이 false

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ SQL 자체는 순서와 무관하게 성공한다(다른 표가 이 행을 참조하지 않는다). 다만 440 의
--    함수가 살아 있는 채 이 행만 지우면 그 사이 캠페인 관리자가 되돌리기를 거부당한다 —
--    화면·440 을 먼저 되돌릴 것
-- DELETE FROM public.role_permissions
--  WHERE feature_key = 'application.restore_cancelled';
