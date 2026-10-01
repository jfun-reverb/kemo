-- ============================================================
-- 2026-10-01-signup-ticket-gate-off.sql  (비상 — 삽입 관문 끄기 = 스위치 대기 + 트리거 지우기)
-- ============================================================
-- 언제 쓰나
--   삽입 관문(trg_signup_ticket_gate, 497)의 **코드 자체가 틀려** 정상 가입이 막힐 때(스위치를 대기로 돌려도 안 풀리는 경우).
--   🔴 **같은 트랜잭션에서 스위치를 먼저 대기로 둔다** — 강제인 채 삽입 관문만 지우면, 대조 없이 생긴 미인증 계정의
--      확인 메일 발송이 고쳐 쓰기 관문(강제)에 막혀 아무도 인증할 수 없게 된다(사양서 경우의 수 2).
--   지운 동안은 곧 「대기 구간」이다 — 새 화면 가입도 인증 완료 표시 없이 미인증으로 생기고(확인 메일 링크로 인증),
--   미인증 계정은 설계 ⑤ 정기 삭제 대상이 된다. 고쳐서 **바로 다시 만든다**(…-ticket-gate-on.sql).
-- 🔴 「잠깐 끄기」(ALTER TABLE auth.users DISABLE TRIGGER …)는 **안 된다** — 2026-10-01 개발서버 실측
--    「must be owner of table users」(편집기 역할 postgres 는 auth.users 의 주인이 아니다). 그래서 **지우고 → 다시 만든다**.
--    트리거를 만들고 지우는 것은 된다(497 이 만들었고, 같은 날 개발서버에서 지우기·다시 만들기 둘 다 확인).
-- 편집기 경고: 뜸 — 무해 (DROP TRIGGER 는 트리거 정의만 지운다. 스위치 UPDATE 는 WHERE 가 있다)
-- 실행: 해당 서버 SQL 편집기.
-- ============================================================

BEGIN;
UPDATE public.signup_code_settings SET mode = 'standby' WHERE id = 1;
DROP TRIGGER IF EXISTS trg_signup_ticket_gate ON auth.users;
COMMIT;

-- 확인 — 스위치 standby, 트리거 0행
SELECT s.mode,
       (SELECT count(*) FROM pg_trigger t
         WHERE t.tgrelid = 'auth.users'::regclass AND t.tgname = 'trg_signup_ticket_gate') AS ticket_gate_rows
  FROM public.signup_code_settings s WHERE s.id = 1;
