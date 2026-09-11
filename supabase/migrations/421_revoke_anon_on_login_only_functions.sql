-- ============================================================
-- 421_revoke_anon_on_login_only_functions.sql
-- 전수조사 2차(2026-09-02) 9-4(I-3, 낮음) — 「로그인한 사람만」 함수의 회수 방향을 둘 다 건다
--   docs/research/2026-09-02-codebase-audit-findings.md
--   docs/specs/2026-09-02-audit-remediation-plan.md
--
-- 무엇이 문제였나
--   아래 함수들은 `REVOKE ALL … FROM PUBLIC` + `GRANT … TO authenticated` 만 했다(240·353·180).
--   그런데 Supabase 는 새 함수에 PUBLIC 과 **별도로** `anon`·`authenticated` 에 실행 권한을 준다
--   (369·370·375 가 세운 기준 — CLAUDE.md 「함수 실행 권한 — 회수 방향이 둘이다」). PUBLIC 만 걷으면
--   개별로 받은 `anon` 이 남아 **비로그인이 그대로 부를 수 있다.** 셋 다 상태값 하나(참·거짓·정수)를
--   돌려줄 뿐이라 새는 정보는 작지만, 「로그인 전용」이라는 주석과 실제가 달랐다.
--
-- 무엇을 하나
--   `anon` 에서 실행 권한을 걷는다. `authenticated` 부여는 그대로(화면이 로그인 뒤 부른다).
--   ⚠️ REVOKE 는 대상이 없어도 「Success」다 — 적용 뒤 아래 확인 조회로 눈으로 본다.
--   ⚠️ 개발과 운영의 권한 상태가 다른 전례가 있다 — 양쪽에서 각각 확인.
--   ⚠️ `is_email_withdrawal_blocked` 는 **일부러 비로그인에 연 것**(회원가입 화면이 로그인 전에 부른다)이라
--      여기 넣지 않는다. `is_brand_survey_open` 도 같은 이유(광고주 신청 폼)로 제외.
--   get_withdrawal_precheck(353)도 같은 모양(PUBLIC 회수 + authenticated 부여)이라 함께 걷는다 —
--   화면(storage.js)이 로그인 뒤에만 부른다.
-- ============================================================

BEGIN;

-- 🔴 개발 실측(2026-09-07 적용 전): calc_age_kst 는 PUBLIC 부여(`=X/`)까지 살아 있었다 — 180 이
--    PUBLIC 회수를 아예 안 했다(넷 중 유일). 두 방향을 다 걷는다. 다른 셋은 PUBLIC 은 이미 없었다.
REVOKE ALL     ON FUNCTION public.calc_age_kst(date)              FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.is_settlement_public()          FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_withdrawal_open()            FROM anon;
REVOKE EXECUTE ON FUNCTION public.calc_age_kst(date)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_withdrawal_precheck(uuid)   FROM anon;

COMMIT;

-- ── 적용 후 확인 (개발·운영 각각) ────────────────────────────────
-- SELECT p.proname, p.proacl::text,
--        has_function_privilege('anon', p.oid, 'EXECUTE') AS 비로그인,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public'
--    AND p.proname IN ('is_settlement_public','is_withdrawal_open','calc_age_kst','get_withdrawal_precheck');
-- 기대: 비로그인 false · 로그인 true · proacl 맨 앞에 `=X/` 없음(PUBLIC 부여 없음) · anon= 항목 없음.
-- 개발 실측(적용 후): 넷 다 anon false / authenticated true / `=X/` 없음.
