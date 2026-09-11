-- ============================================================
-- 400. 행사 승인자 명단 조회를 비로그인에서 닫는다
-- ============================================================
-- 전수조사(2차) 묶음 A — A-2.
-- 조사 근거: docs/research/2026-09-02-codebase-audit-findings.md §1-2
--
-- ── 무엇이 열려 있었나 ────────────────────────────────────
-- `get_event_roster(열쇠말, 캠페인번호)` 는 **비로그인(anon)에 열려 있고**,
-- 방어는 **함수 안에 박힌 sha256 해시 하나**뿐이다(392).
--
-- 🔴 그 해시가 **운영 사이트에서 그대로 내려받혔다.** 392 파일이 `main` 에 있고
--    Vercel 이 저장소를 통째로 서빙했기 때문이다
--    (`https://globalreverb.com/supabase/migrations/392_event_roster.sql`).
--    차단은 2026-09-02 `.vercelignore` 로 들어갔다(커밋 3a2c82e1) — 그 전까지 열려 있었다.
--    사람이 외워 쓰는 열쇠말의 해시는 **오프라인에서 대입해 풀 수 있고**,
--    그건 요청 제한으로 막을 수 없다. 요청 제한이 답이 아닌 이유가 이것이다.
--
-- 🔴 **조회 조건에 행사 여부가 없다** — `where c.campaign_no = p_campaign_no` 뿐이라
--    캠페인 번호만 맞으면 **어느 캠페인이든** 통과한다. 번호는 규칙적이라
--    (`B{4자리}-A{3자리}-C{3자리}`) 순회할 수 있다.
--
-- ── 노출 규모 (2026-09-03 운영 실측) ──────────────────────
--   승인 응모 **2,796건** · 서로 다른 회원 **513명**(전체 1,895명의 27%) ·
--   캠페인 **155개**. 항목 = 한자 이름·가나 이름·대표 SNS·네 채널 계정과 팔로워 수.
--   (전화·주소·이메일·페이팔은 애초에 반환하지 않는다 — 392 가 그건 잘 막았다)
--
-- ── 🔴 계획서의 「행사 캠페인으로 제한」은 지금 실행 불가다 ─
-- 조치 계획서는 「범위 제한은 확정」이라 적었으나, **`event_mode` 가 켜진 캠페인이
-- 운영에 0개**다(전부 false, 2026-09-03 실측). 그 조건을 걸면 **모든 캠페인에서
-- 0건**이 나와 기능이 통째로 죽는다. 8/28 팝업도 행사 모드가 아닌 캠페인으로 뽑았다 —
-- 조회에 행사 검사가 없는 것은 실수가 아니라 **그래야 돌아갔기 때문**으로 보인다.
--
-- ── 그래서 무엇을 했나 ────────────────────────────────────
-- **비로그인·로그인 실행 권한을 회수한다.** 사용자 확인 결과 그 구글시트는
-- **더 이상 쓰지 않는다**(2026-09-03). 쓰지 않는 통로를 열어 둘 이유가 없다.
--
-- ⚠️ **함수 자체는 지우지 않는다** — 지우면 나중에 되살릴 때 반환 항목·감사용 제외·
--    이름 충돌 회피(`o_` 접두어) 같은 392 의 판단이 함께 사라진다. 권한만 닫는다.
--
-- ⚠️ **`drop function` 을 쓰지 않는다** — 392 주석이 경고한 그대로다.
--    `drop` 은 아래 회수까지 함께 지운다. 이 저장소는 387 에서 같은 함정을 밟아
--    비로그인 차단이 풀린 적이 있다.
--
-- ── 되살릴 때 (그날 반드시 함께 할 것) ────────────────────
--   ① 🔴 **열쇠말을 새로 정하고 해시를 바꾼다.** 옛 해시는 이미 밖에 나갔으므로
--      같은 열쇠말로 되살리면 **닫지 않은 것과 같다.**
--   ② 🔴 **대상을 좁힌다.** `event_mode` 는 켜진 캠페인이 없어 기준이 못 된다 —
--      **캠페인 번호를 인자가 아니라 함수 안의 허용 목록으로** 두거나,
--      캠페인마다 다른 토큰을 표에 두고 대조하는 쪽(저장소의 다른 익명 함수 방식)으로.
--   ③ 구글시트의 Apps Script 에 새 열쇠말을 넣는다.
--   ④ 아래 `grant` 한 줄을 다시 실행한다.
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.get_event_roster(text, text) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_event_roster(text, text) FROM PUBLIC;

COMMENT ON FUNCTION public.get_event_roster(text, text) IS
  '[392] 행사 승인자 명단 조회. [400] 비로그인·로그인 실행 권한 회수 — '
  '방어값(열쇠말 해시)이 공개 저장소로 유출됐고 조회에 행사 검사가 없어 캠페인 155개가 열려 있었다. '
  '되살리려면 열쇠말을 새로 정하고 대상을 좁힌 뒤 GRANT 를 다시 걸 것(400 파일 주석).';


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 두 방향 다 회수됐는가
--      ⚠️ has_function_privilege 만 보면 방향을 모른다.
--         proacl 의 맨 앞이 '{=X/' 이면 PUBLIC 부여가 남아 있는 것이다.
SELECT p.proname,
       (p.proacl::text LIKE '{=X/%')                          AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       p.proacl::text                                          AS 권한목록
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'get_event_roster';
-- 기대: public_남음=false · 비로그인=false · 로그인=false

-- [V2] 양성 대조 — 다른 익명 함수는 그대로 열려 있어야 한다
--      (이걸 같이 안 보면 「조회 방법이 틀려서 false」인지 구분이 안 된다)
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_event_roster', 'is_email_withdrawal_blocked', 'unsubscribe_by_token')
 ORDER BY p.proname;
-- 기대: get_event_roster=false · 나머지 둘=true

*/


-- ============================================================
-- 롤백 (되살리기 전에 위 ①②③ 을 먼저 할 것)
-- ============================================================
-- GRANT EXECUTE ON FUNCTION public.get_event_roster(text, text) TO anon, authenticated;
