-- ============================================================
-- 2026-10-01-signup-ticket-gate-on.sql  (삽입 관문 다시 켜기)
-- ============================================================
-- 언제 쓰나
--   …-ticket-gate-off.sql 로 끈 뒤, 함수 코드를 고쳤다면 **고친 마이그레이션을 먼저 적용하고** 이것을 실행한다.
--   ⚠️ 이 파일은 스위치를 바꾸지 않는다 — 켠 뒤에도 스위치는 대기 그대로다(강제 전환은 사양서 단계 3 의 별도 결정).
-- 편집기 경고: 안 뜸 (예상 — ENABLE TRIGGER / CREATE TRIGGER 에는 drop·delete 단어가 없다)
-- 실행: 해당 서버 SQL 편집기.
-- ============================================================

ALTER TABLE auth.users ENABLE TRIGGER trg_signup_ticket_gate;

-- [대체] off 파일에서 DROP TRIGGER 로 지웠다면(주석 해제해서 실행 — 497 과 같은 정의):
-- CREATE TRIGGER trg_signup_ticket_gate
--   BEFORE INSERT ON auth.users
--   FOR EACH ROW EXECUTE FUNCTION public._signup_ticket_gate();

-- 확인 — tgenabled 'O'(켜짐). 이어서 대기 상태에서 가입 1회가 되는지(실제 가입).
SELECT t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_ticket_gate';
