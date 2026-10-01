-- ============================================================
-- 2026-10-01-signup-resend-gate-on.sql  (고쳐 쓰기 관문 다시 켜기)
-- ============================================================
-- 언제 쓰나
--   …-resend-gate-off.sql 로 끈 뒤, 함수 코드를 고쳤다면 **고친 마이그레이션을 먼저 적용하고** 이것을 실행한다.
--   (트리거 함수를 CREATE OR REPLACE 로 고쳐도 트리거는 꺼진 채이므로 이 단계가 필요하다.)
-- 편집기 경고: 안 뜸 (예상 — ENABLE TRIGGER / CREATE TRIGGER 에는 drop·delete 단어가 없다)
-- 실행: 해당 서버 SQL 편집기.
-- ============================================================

ALTER TABLE auth.users ENABLE TRIGGER trg_signup_resend_gate;

-- [대체] off 파일에서 DROP TRIGGER 로 지웠다면(주석 해제해서 실행 — 497 과 같은 정의):
-- CREATE TRIGGER trg_signup_resend_gate
--   BEFORE UPDATE ON auth.users
--   FOR EACH ROW EXECUTE FUNCTION public._signup_resend_gate();

-- 확인 — tgenabled 가 'O'(켜짐)이어야 한다. 이어서 인증 완료 회원 로그인 1회.
SELECT t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_resend_gate';
