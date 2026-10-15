-- ============================================================
-- 2026-10-01-signup-resend-gate-on.sql  (고쳐 쓰기 관문 다시 켜기 = 트리거 다시 만들기)
-- ============================================================
-- 언제 쓰나
--   …-resend-gate-off.sql 로 지운 뒤. 함수 코드를 고쳤다면 **고친 마이그레이션(CREATE OR REPLACE)을 먼저 적용하고** 이것을 실행한다.
-- 🔴 「잠깐 끄기」(ALTER TABLE auth.users DISABLE TRIGGER …)는 **안 된다** — 2026-10-01 개발서버 실측
--    「must be owner of table users」(편집기 역할 postgres 는 auth.users 의 주인이 아니다). 그래서 **지우고 → 다시 만든다**.
--    트리거를 만들고 지우는 것은 된다(497 이 만들었고, 같은 날 개발서버에서 지우기·다시 만들기 둘 다 확인).
-- 편집기 경고: 안 뜸 (CREATE TRIGGER 에는 drop·delete 단어가 없다)
-- 실행: 해당 서버 SQL 편집기.
-- ============================================================

-- 497 과 같은 정의. 이미 있으면 「already exists」 오류로 끝난다(무해 — 이미 켜져 있다는 뜻)
CREATE TRIGGER trg_signup_resend_gate
  BEFORE UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public._signup_resend_gate();

-- 확인 — 1행, tgenabled 'O'(켜짐). 이어서 인증 완료 회원 로그인 1회.
SELECT t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_resend_gate';
