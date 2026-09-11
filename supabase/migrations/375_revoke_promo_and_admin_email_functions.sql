-- ============================================================
-- 375_revoke_promo_and_admin_email_functions.sql
-- 2026-08-21
--
-- 🔴 **관리자·회원 이메일이 그대로 새고 있었다.**
--
-- 369·370 은 「내부 전용 함수」를 기준으로 훑었다. 이 파일은 **다른 기준**으로
-- 훑어 나온 것이다 — 「소유자 권한으로 돌면서 **안쪽에 호출자 검사가 아예 없는**
-- 함수」. 검사가 없으면 권한 부여가 **유일한 방어선**인데, 그게 열려 있었다.
--
-- (이 기준을 알려 준 것은 같은 날 iOS 세션이다 — 자기 신규 함수가 `GRANT` 만
--  있고 회수가 없는 것을 발견하고 「그 기준으로 훑으면 더 나올 것」이라고 짚었다.)
--
-- ============================================================
-- 무엇이 샜나 (2026-08-21 운영에서 실제로 호출해 확인)
-- ============================================================
--   ① `get_subscribed_admin_emails(text)` — 🔴 **가장 무겁다**
--      관리자 이메일 목록을 그대로 돌려준다. 권한이 **PUBLIC + anon + authenticated**
--      라 **로그인조차 필요 없다.** 종류값(`daily_digest` 등)은 저장소에 적혀 있다.
--      운영에서 회원 계정으로 불러 **11건이 그대로 나왔다.**
--      ⚠️ 이건 마이그레이션 243 이 일부러 피한 것과 정확히 반대다 — 그때는
--      비밀번호 찾기 기록에 이메일 대신 **해시**를 넣어 「유출돼도 관리자 명단이
--      되지 않게」 했는데, 정작 명단 자체를 돌려주는 함수가 열려 있었다.
--
--   ② `get_promo_digest_targets(date)` — 🔴 회원 개인정보
--      회원 고유번호·**이메일**·이름·**수신거부 토큰**을 돌려준다.
--      비로그인은 이미 막혀 있었지만 **로그인한 회원이면 누구나** 부를 수 있었다.
--      ⚠️ 수신거부 토큰이 특히 나쁘다 — `unsubscribe_by_token` 은 **일부러
--      비로그인에게 열어 둔** 함수라(메일 본문의 1클릭 수신거부), 토큰을 얻으면
--      **남의 수신 설정을 마음대로 끌 수 있다.**
--
--   ③ `mark_promo_digest_sent(...)` — 발송 기록을 아무나 쓸 수 있었다.
--      가짜 기록을 넣으면 그 회원이 **홍보 메일 대상에서 빠진다**(하루 1통 보장
--      장치를 역이용).
--
--   ④ `get_promo_digest_campaign_pool(date)` — 캠페인 풀. 캠페인 자체는 공개라
--      샐 것이 적지만 같은 이유로 함께 닫는다.
--
-- ============================================================
-- 왜 회수해도 메일이 안 죽나 (적용 전 확인함)
-- ============================================================
--   넷 다 홍보·알림 메일 함수(`notify-campaign-promo-digest` ·
--   `notify-admin-daily-digest` · `notify-brand-*` · `notify-orient-submitted`)
--   에서만 불리고, 그 함수들은 **서비스 키**로 돈다.
--   **브라우저에서 부르는 자리는 0곳**이다(`rpc('이름'` 검색 + 자립형 단독
--   화면 `event-scan.html`·`admin-setpw.html`·`sales/*.html` 포함).
--
--   🔴 **그런데 「서비스 키가 PUBLIC 을 통해서만 권한을 갖는」 경우가 있으면
--   PUBLIC 회수가 메일을 통째로 죽인다.** 그래서 적용 전에 넷 다
--   `has_function_privilege('service_role', …)` 와 권한 목록을 직접 조회해
--   **`service_role=X/postgres` 항목이 각각 따로 있는 것**을 확인했다.
--   아래 `GRANT` 두 줄은 그 확인 위에 **한 번 더** 못 박는 것이다.
--
-- ============================================================
-- 이미 새어 나갔나 — 확인했고, **한계가 크다** (2026-08-21)
-- ============================================================
--   🔴 **닫는 것과 「이미 샜나」는 다른 문제다.** 특히 ② 가 돌려주던 수신거부
--   토큰(`influencers.unsubscribe_token`)은 **영구값**이라(재구독해도 안 바뀐다)
--   한 번 새어 나갔으면 닫는 것만으로는 안 끝난다.
--
--   운영 API 로그를 네 함수 이름으로 훑었다. 호출 주체가 둘로 갈렸다:
--     · 메일 함수(`Deno/`) — 8/15 00:00 ~ 8/21 02:38 (정상 발송)
--     · **그 밖** — 8/21 08:41:16 ~ 08:45:30 (**4분**)
--   그 4분은 **이 작업의 확인 호출**이다(적용 전 200 → 적용 후 403).
--   즉 **메일 함수와 이 작업 말고는 아무도 안 불렀다.**
--
--   ⚠️ **조회가 맞는지 먼저 확인했다** — 이 작업의 호출이 200·403 으로 정확히
--   찍히는 것을 보고 나서 「없음」을 읽었다. 안 그러면 「조회가 잘못돼서 0건」과
--   「진짜 0건」을 구분할 수 없다(없는 통에 대한 삭제가 조용히 성공하던 것과
--   같은 함정 — 마이그레이션 364 참조).
--
--   🔴 **그러나 이것은 「유출 없음」의 증명이 아니다:**
--     · 로그 보존이 **7일뿐**이다(Pro 최대. 화면에서 더 긴 기간을 고를 수 없다)
--     · 이 함수들은 **2026-04~05부터** 있었다(103·141) — **약 4개월 중 마지막
--       7일만** 본 것이고, 그 앞 구간은 **확인할 방법이 아예 없다**
--   → 「흔적 없음」이 아니라 **「7일치만 볼 수 있고 그 안에서는 없음」**이다.
--     토큰 재발급 여부는 그 위에서 사람이 판단할 일이다(이 파일은 안 건드린다).
--
-- ============================================================
-- 안 닫는 것 (다음 사람이 「빠뜨렸나」로 오해하지 않게)
-- ============================================================
--   ① `_meets_min_followers` — 같은 기준에 걸리지만 **표를 전혀 안 읽는 순수 계산**
--      이라 남의 정보가 샐 수 없다(370 에서와 같은 판단).
--
--   ② `is_email_withdrawal_blocked(text)` — ⏸️ **판단 대기. 일부러 안 닫았다.**
--      같은 기준에 걸리지만 **비로그인에게 연 것이 의도**다 — 회원가입 화면이
--      로그인 전에 부르고, **362(가입 차단)가 미적용이라 지금은 그것이 유일하게
--      작동하는 재가입 차단 수단**이다. 닫으면 차단이 통째로 사라진다.
--      🔴 그런데 이 함수는 **임의의 이메일이 최근 탈퇴했는지 참·거짓으로 알려 준다**
--      — 361·362 가 「가입 실패 문구를 전부 같게 해 탈퇴 여부를 못 알아내게」 한
--      설계와 정면으로 어긋난다(그 노력이 이 함수 하나로 무의미해진다).
--      ⚠️ **지금은 시행일이 비어 있어 차단 기록이 하나도 안 쌓이므로 항상 거짓 —
--      샐 것이 없다.** 약관이 시행되는 순간부터 실제 문제가 된다.
--      → **작업 18(약관 개정)·362 와 함께 판단할 것.**
--
-- 적용 이력 (★ 파일 이름으로 판단하지 말 것 — 데이터베이스에만 남는다):
--   - 개발: **2026-08-21 적용 완료**
--   - 운영: **2026-08-21 적용 완료**
--
--   바깥에서 실제로 막히는지 확인함(운영 globalreverb.com, **로그인한 상태**):
--     · 적용 **전**: `get_subscribed_admin_emails('daily_digest')` → **관리자 이메일 11건**
--     · 적용 **후**: 같은 호출 → **42501 permission denied**
--     · `get_promo_digest_targets` 도 같은 결과(42501)
--   ⚠️ 확인에는 **읽기 전용 함수만** 썼다 — `mark_promo_digest_sent` 로 시험하면
--      막혀 있지 않을 경우 가짜 발송 기록이 진짜로 들어간다.
--
--   ⚠️ **적용 전 두 데이터베이스가 또 달랐다**(370 에서와 같은 현상):
--     `mark_promo_digest_sent` 가 **운영에서는 비로그인에게 열려 있고 개발은 닫혀**
--     있었다. 그래서 「개발에서 확인했으니 운영도 같겠지」가 성립하지 않는다 —
--     **양쪽을 각각 조회**할 것.
--
-- 되돌리기:
--   🔴 **REVOKE 를 그대로 GRANT 로 바꾸면 안 된다 — 원래 없던 접근이 새로 열린다.**
--   이 파일은 네 함수 모두에 `FROM PUBLIC` 과 `FROM anon, authenticated` 를 **둘 다**
--   썼지만, 원래 상태는 함수마다 달랐다:
--
--     · ① `get_subscribed_admin_emails` — 원래가 **PUBLIC** 이었다(정의 103 에
--       `REVOKE` 문이 아예 없어 Postgres 기본값이 그대로 살아 있었다).
--       원상복구는 `GRANT EXECUTE ON FUNCTION … TO PUBLIC;`
--
--     · ②③④ `get_promo_digest_targets` · `get_promo_digest_campaign_pool` ·
--       `mark_promo_digest_sent` — 정의(141·143·152·259·321) 때부터
--       **`PUBLIC`·`anon` 은 이미 회수돼 있었고 `authenticated` 만** 열려 있었다.
--       즉 이 파일의 `FROM PUBLIC`·`FROM anon` 은 이 셋에 대해 **아무것도 안 하는
--       빈 문장**이었다(실행에는 무해).
--       ⚠️ 원상복구는 **`GRANT EXECUTE ON FUNCTION … TO authenticated;` 만**.
--       `TO PUBLIC`·`TO anon` 까지 되돌리면 **원래 없던 비로그인 접근을 새로 여는**
--       것이라, 되돌리기가 원래보다 더 나쁜 상태를 만든다.
--
--   ⚠️ 되돌리면 관리자 이메일 명단이 다시 공개된다. 원인을 파악한 뒤 다시 조인다.
-- ============================================================

BEGIN;

-- 서비스 키·소유자 권한을 먼저 못 박는다 (이미 있지만 명시)
GRANT EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text)       TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.get_promo_digest_targets(date)          TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date)    TO postgres, service_role;

-- ① 관리자 이메일 목록 — PUBLIC 부여가 있어 **두 방향 다** 회수해야 한다
REVOKE EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text) FROM anon, authenticated;

-- ② 회원 이메일·수신거부 토큰
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM anon, authenticated;

-- ④ 캠페인 풀
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) FROM anon, authenticated;

COMMIT;

-- ③ 발송 기록 — 인자가 6개(기본값 3개)라 **별도 트랜잭션**으로 뗐다.
--    시그니처가 한 글자만 어긋나도 트랜잭션 전체가 실패하는데, 위 셋은 이미
--    확인이 끝났으므로 그것까지 같이 되돌아가면 손해다.
--    ⚠️ 인자는 **데이터베이스에서 직접 확인**한 것이다(개발·운영 동일):
--       p_influencer_id uuid, p_digest_date date, p_status text,
--       p_skip_reason text, p_error_message text, p_included_campaign_ids uuid[]
--    ⚠️ 기본값이 있어도 시그니처에는 **자료형만** 쓴다.
BEGIN;

GRANT  EXECUTE ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 확인 (적용 후)
-- ============================================================
/*
-- [V1] 넷 다 닫혔나 — 서비스키만 true 여야 한다
SELECT p.proname AS 함수,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS 서비스키,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       p.proacl::text AS 권한목록
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public'
   AND p.proname IN ('get_subscribed_admin_emails','get_promo_digest_targets',
                     'get_promo_digest_campaign_pool','mark_promo_digest_sent')
 ORDER BY 1;
기대: 서비스키 true / 로그인·비로그인 **false** / 권한목록 맨 앞에 `=X/` 없음.

-- 🔴 [V2] 바깥에서 실제로 막히는지 — 로그인한 브라우저 콘솔에서:
--   await db.rpc('get_subscribed_admin_emails', { p_mail_kind: 'daily_digest' })
--   기대: **42501 permission denied**.
--   ⚠️ 적용 전에는 이 호출이 관리자 이메일 11건을 그대로 돌려줬다.
--   ⚠️ 확인에는 **읽기 전용 함수만** 쓸 것 — ③ 으로 시험하면 막혀 있지 않을 경우
--      가짜 발송 기록이 진짜로 들어간다.

-- 🔴 [V3] **메일이 안 죽었는지 — 이쪽이 진짜 위험이다.**
--   다음 홍보 메일(매주 월·목 한국·일본 시각 09:00)과 관리자 일일 메일(매일 09:00)이
--   정상 발송됐는지 확인한다:
--     SELECT digest_date, status, recipients_count, error_message
--       FROM public.admin_daily_digest_runs ORDER BY digest_date DESC LIMIT 3;
--     SELECT digest_date, status, started_at, finished_at
--       FROM public.campaign_promo_digest_runs ORDER BY digest_date DESC LIMIT 3;
--   기대: status='sent'(또는 데이터가 없으면 'skipped_no_data'). 'failed' 면 이 파일을 되돌린다.
*/
