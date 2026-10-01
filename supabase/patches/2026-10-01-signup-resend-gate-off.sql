-- ============================================================
-- 2026-10-01-signup-resend-gate-off.sql  (비상 — 고쳐 쓰기 관문 끄기 = 트리거 지우기)
-- ============================================================
-- 언제 쓰나
--   고쳐 쓰기 관문(trg_signup_resend_gate, 497)의 **코드 자체가 틀려** 로그인·토큰 갱신이 막힐 때.
--   ⚠️ 스위치를 대기로 돌려도 안 풀리는 경우에만 쓴다(스위치로 풀리는 사고는 `UPDATE public.signup_code_settings SET mode='standby' WHERE id=1;`).
--   🔴 지운 동안은 경우의 수 12-①·③ 우회(미인증 주소 재가입·재설정 링크로 인증)가 다시 열린다 — 고쳐서 **바로 다시 만든다**(…-resend-gate-on.sql).
-- 🔴 「잠깐 끄기」(ALTER TABLE auth.users DISABLE TRIGGER …)는 **안 된다** — 2026-10-01 개발서버 실측
--    「must be owner of table users」(편집기 역할 postgres 는 auth.users 의 주인이 아니다). 그래서 **지우고 → 다시 만든다**.
--    트리거를 만들고 지우는 것은 된다(497 이 만들었고, 같은 날 개발서버에서 지우기·다시 만들기 둘 다 확인).
-- 편집기 경고: 뜸 — 무해 (DROP TRIGGER 는 트리거 정의만 지운다. 데이터·함수는 그대로라 on 파일로 바로 되살린다)
-- 실행: 해당 서버(개발/운영) SQL 편집기.
-- ============================================================

DROP TRIGGER IF EXISTS trg_signup_resend_gate ON auth.users;

-- 확인 — 0행이어야 한다(지워짐)
SELECT t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_resend_gate';
