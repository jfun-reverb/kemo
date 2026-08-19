-- ============================================================
-- 355_withdrawal_proxy_permission_seed.sql
--
-- 회원 탈퇴 — 작업 19 「관리자 대행 탈퇴 신청」 1/3 (권한 시드)
--   356 = 토대(값 확장·공용 판정 함수·기존 함수 재정의)
--   357 = 본체(대행 신청·관리자 되돌리기 함수)
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 19」
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md §5 ⑤
--
-- ============================================================
-- ① 무엇을 하나
-- ============================================================
--   신규 권한 열쇠말 `withdrawal.proxy_request`(회원 대신 탈퇴 신청)를 동적 권한
--   관리(마이그레이션 207·214)에 편입한다. **이 파일만 적용하면 동작 변화가 0**
--   이다 — 아직 이 열쇠말을 읽는 곳이 없다.
--
--   값: 최고 관리자 = 쓰기 / 캠페인 관리자 = 쓰기 / 캠페인 매니저 = 숨김
--   (정산 화면·아웃바운드 명단과 같은 판단 — 되돌릴 수 없는 처리라 매니저 제외)
--
-- ============================================================
-- ② 왜 세 등급 행을 다 넣나 (228 은 두 등급만 넣었다)
-- ============================================================
--   마이그레이션 268 이 `role_permissions.role` CHECK 에 `super_admin` 을 더하고
--   42개 행을 시드했다. 그 뒤로 **신규 열쇠말은 세 등급 행을 다 넣어야** 권한
--   관리 화면의 슈퍼 열이 빈칸으로 뜨지 않는다.
--
--   ⚠️ `has_permission`(269)은 **행이 없을 때 등급별로 판정이 반대**다 —
--     최고 관리자는 통과(fail-open), 나머지 둘은 거부(fail-closed). 그래서
--     최고 관리자 행이 없어도 기능은 도는데 **화면에만 안 보인다.** 그게 더
--     헷갈리므로 명시적으로 넣는다.
--
--   ⚠️ `default_level` 은 214 에서 NOT NULL 로 바뀌었다 — 신규 행도 반드시
--     채워야 INSERT 가 성공한다(220·221·228 과 같은 패턴).
--
-- ============================================================
-- ③ ★ 이 시드와 화면은 **같은 배포에** 나가야 한다
-- ============================================================
--   화면 쪽 판정(`canWrite`)은 **설정을 못 읽었을 때 「쓰기」로 폴백**하고,
--   서버 판정(`has_permission`)은 등급 2종에 대해 **거부**한다. 방향이 반대다.
--   → 시드를 빠뜨린 채 화면만 배포하면 **캠페인 관리자에게 버튼은 보이는데
--     누르면 거부**된다. 반드시 함께 나갈 것.
--
-- ============================================================
-- ④ 되돌리기
-- ============================================================
--   DELETE FROM public.role_permissions WHERE feature_key = 'withdrawal.proxy_request';
--   ⚠️ 357 을 먼저 되돌린 뒤에 할 것 — 그쪽 함수가 이 열쇠말로 판정한다.
--     (시드만 지우면 캠페인 관리자가 조용히 거부당한다)
-- ============================================================

INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'withdrawal.proxy_request', 'write',  'write'),
  ('campaign_admin',   'withdrawal.proxy_request', 'write',  'write'),
  ('campaign_manager', 'withdrawal.proxy_request', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
-- ============================================================
/*

-- [V0] (SQL 편집기) 세 행이 들어갔는지
SELECT role, feature_key, access_level, default_level
  FROM public.role_permissions
 WHERE feature_key = 'withdrawal.proxy_request'
 ORDER BY role;
-- 기대: 3행 (super_admin=write · campaign_admin=write · campaign_manager=hidden)

-- [V1] (브라우저 콘솔) 실제 판정 — 등급별로 로그인해서
--   await db.rpc('has_permission', {p_feature:'withdrawal.proxy_request', p_min:'write'})
--   기대: 최고 관리자·캠페인 관리자 = true / 캠페인 매니저 = false
--   ⚠️ SQL 편집기로는 못 한다 — 서비스 키에는 로그인 사용자가 없어 이 함수의
--     등급 판정 분기가 아예 안 돈다

*/
