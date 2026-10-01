-- ============================================================
-- 2026-10-01-signup-ticket-gate-off.sql  (비상 — 삽입 관문 끄기)
-- ============================================================
-- 언제 쓰나
--   삽입 관문(trg_signup_ticket_gate, 497)의 **코드 자체가 틀려** 정상 가입이 막힐 때(스위치를 대기로 돌려도 안 풀리는 경우).
--   🔴 **반드시 같은 트랜잭션에서 스위치를 먼저 대기로 둔다** — 강제인 채 삽입 관문만 끄면, 대조 없이 생긴 미인증 계정의
--      확인 메일 발송이 고쳐 쓰기 관문(강제)에 막혀 아무도 인증할 수 없게 될 수 있다(사양서 경우의 수 2).
--   끈 동안은 곧 「대기 구간」이다 — 새 화면 가입도 인증 완료 표시 없이 미인증으로 생기고(확인 메일 링크로 인증),
--   미인증 계정은 설계 ⑤ 정기 삭제 대상이 된다. 고쳐서 **바로 다시 켠다**(…-ticket-gate-on.sql).
-- 편집기 경고: 안 뜸 (예상 — 맨 위 UPDATE 는 WHERE 가 있고, ALTER … DISABLE TRIGGER 에는 drop·delete 단어가 없다. 대체 방법의 DROP TRIGGER 는 뜬다 — 무해)
-- 실행: 해당 서버 SQL 편집기.
--
-- ⚠️ ALTER 가 「must be owner of table users」 로 실패하면 이 트랜잭션이 통째로 되돌아가 스위치도 안 바뀐다 →
--    ① 스위치 UPDATE 만 먼저 따로 실행 ② [대체] 의 DROP TRIGGER 실행.
-- ============================================================

BEGIN;

UPDATE public.signup_code_settings SET mode = 'standby' WHERE id = 1;

ALTER TABLE auth.users DISABLE TRIGGER trg_signup_ticket_gate;

-- [대체] ALTER 가 권한 오류로 안 되면(위 BEGIN~COMMIT 대신, 주석 해제해서 실행):
-- UPDATE public.signup_code_settings SET mode = 'standby' WHERE id = 1;
-- DROP TRIGGER IF EXISTS trg_signup_ticket_gate ON auth.users;

COMMIT;

-- 확인 — 스위치 standby, 트리거 tgenabled 'D'(꺼짐; 대체로 지웠으면 0행)
SELECT s.mode,
       (SELECT t.tgenabled FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'auth' AND c.relname = 'users' AND t.tgname = 'trg_signup_ticket_gate') AS ticket_gate_state
  FROM public.signup_code_settings s WHERE s.id = 1;
