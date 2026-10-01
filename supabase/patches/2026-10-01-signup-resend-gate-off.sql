-- ============================================================
-- 2026-10-01-signup-resend-gate-off.sql  (비상 — 고쳐 쓰기 관문 끄기)
-- ============================================================
-- 언제 쓰나
--   고쳐 쓰기 관문(trg_signup_resend_gate, 497)의 **코드 자체가 틀려** 로그인·토큰 갱신이 막힐 때.
--   ⚠️ 스위치를 대기로 돌려도 안 풀리는 경우에만 쓴다(스위치로 풀리는 사고는 `UPDATE public.signup_code_settings SET mode='standby' WHERE id=1;`).
--   🔴 끈 동안은 경우의 수 12-①·③ 우회(미인증 주소 재가입·재설정 링크로 인증)가 다시 열린다 — 고쳐서 **바로 다시 켠다**(…-resend-gate-on.sql).
-- 편집기 경고: 안 뜸 (예상 — ALTER TABLE … DISABLE TRIGGER 는 drop·delete·truncate 단어가 없다. 단 맨 아래 대체 방법의 DROP TRIGGER 는 뜬다 — 무해: 트리거 정의만 지움, 데이터 무변경)
-- 실행: 해당 서버(개발/운영) SQL 편집기. 개발서버에서 먼저 한 번 시험해 두면 좋다.
--
-- ⚠️ 이 줄이 「must be owner of table users」 로 실패하면 postgres 역할이 auth.users 의 소유권이 없는 것이다 →
--    아래 [대체] 의 DROP TRIGGER 를 쓴다(그 뒤 다시 켜기는 …-resend-gate-on.sql 의 CREATE TRIGGER 대체 블록).
-- ============================================================

ALTER TABLE auth.users DISABLE TRIGGER trg_signup_resend_gate;

-- [대체] 위가 권한 오류로 안 되면(주석 해제해서 실행):
-- DROP TRIGGER IF EXISTS trg_signup_resend_gate ON auth.users;

-- 확인 — tgenabled 가 'D'(꺼짐)이어야 한다(대체로 지웠으면 0행)
SELECT t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_resend_gate';
