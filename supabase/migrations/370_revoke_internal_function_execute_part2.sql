-- ============================================================
-- 370_revoke_internal_function_execute_part2.sql
-- 내부 전용 함수 실행 권한 회수 — 2차(마무리)
--
-- 369 의 후속. 369 는 「되돌릴 수 없는 일을 하는 9개」만 급히 닫았고,
-- 이 파일이 **나머지를 전수로** 닫는다.
-- ============================================================
-- 어떻게 대상을 골랐나 (기계적 기준 — 사람 판단 개입 없음)
-- ============================================================
--   저장소 전체를 훑어 아래를 **전부** 만족하는 함수를 골랐다:
--     ① `SECURITY DEFINER` 로 만들어졌다 (204개)
--     ② **어느 마이그레이션도 anon·authenticated 에 명시적으로 GRANT 한 적이 없다**
--        → 지금 갖고 있는 권한은 Supabase 기본값으로 딸려온 것이지 **의도된 게 아니다**
--        (명시적으로 허용한 119개는 그대로 둔다 — 광고주 신청·수신거부·오리엔시트 토큰 등)
--     ③ 브라우저에서 부르지 않는다 (`grep -rl "rpc('<이름>'" dev/` 0건)
--     ④ 트리거 함수가 아니다 (트리거 함수는 직접 호출 자체가 거부되므로 실질 노출 없음 — 63개 제외)
--     ⑤ 369 에서 이미 닫지 않았다
--
--   → **18개**가 남았고, 그중 이 파일이 닫는 것은 아래 15개다.
--
-- ⚠️ **③이 이 판정의 약한 고리다.** 글자 그대로의 검색이라, 이름을 변수로 넘기거나
--    문자열을 조립해 부르는 자리는 안 걸린다(마이그레이션 312 사고와 같은 유형).
--    그래서 적용 뒤 **화면을 눈으로** 확인한다 — 권한 회수의 실패는 오류가 아니라
--    **빈 결과**라 정적 점검만으로는 못 잡는다.
--
-- ============================================================
-- 무엇이 열려 있었나 (성격별)
-- ============================================================
--   [A] 남의 개인정보를 캐낼 수 있다 — 임의 회원 번호를 넣으면 답이 나온다
--         _influencer_is_admin_account : 그 사람이 관리자인가
--         _withdrawal_lock_blockers    : 결과물·행사·정산·미지급 건수
--         _withdrawal_unpaid_count     : 미지급 건수
--         _withdrawal_account_blocked  : 탈퇴 확정·예정 여부
--       🔴 이 넷은 **아무 값이나 넣어 보며 답을 모으는** 것이 가능하다.
--
--   [B] 파기 배치를 아무나 앞당겨 돌릴 수 있다
--         purge_expired_deleted_campaigns · purge_old_event_tickets ·
--         purge_old_influencer_flags · purge_expired_withdrawal_email_blocks ·
--         purge_old_admin_password_reset_requests
--
--   [C] 상태를 앞당길 수 있다 — 🔴 **가장 무겁다**
--         advance_withdrawal_states : 탈퇴 확정을 앞당기면 **개인정보 파기가 곧바로 실행**된다
--         advance_to_orient_sheet_sent : 영업 단계 전진
--
--   [D] 집계·목록
--         recompute_campaign_applied_count : 응모 수 재계산
--         _settlement_cert_candidates      : 정산 후보 목록(인증 성공 응모)
--
--   [E] 보안 보조
--         check_admin_password_reset_rate_limit : 요청 제한 기록을 오염시켜
--           관리자 비밀번호 찾기를 막거나 열 수 있다
--         gen_event_ticket_code : 티켓 코드 생성기
--
-- ============================================================
-- 일부러 안 닫는 것 3개 (다음 사람이 「빠뜨렸나」로 오해하지 않게)
-- ============================================================
--   `_meets_min_followers` · `_withdrawal_email_hash` · `_accumulate_legacy_no`
--   셋 다 **데이터베이스를 전혀 안 보는 순수 계산**이다. 넘긴 값으로 답을 낼 뿐이라
--   남의 정보가 새지 않는다. 굳이 닫아 얻는 것이 없어 그대로 둔다.
--
-- ============================================================
-- 적용 이력 (★ 파일 이름으로 판단하지 말 것 — 데이터베이스에만 남는다)
-- ============================================================
--   개발(qysmxtipobomefudyixw): **2026-08-21 적용 완료**
--   운영(nrwtujmlbktxjgdwlpjj): **2026-08-21 적용 완료**
--
--   ⚠️ **적용 전 두 데이터베이스의 상태가 서로 달랐다**(실측):
--     · `recompute_campaign_applied_count` — 개발은 **PUBLIC**(`=X/postgres`),
--       운영은 **역할별**(`anon=X/…, authenticated=X/…`)
--     · `check_admin_password_reset_rate_limit` — **운영에서는 이미 닫혀** 있었다
--   그래서 이 파일은 PUBLIC·역할별을 **둘 다** 회수한다. 어느 쪽이 없어도
--   REVOKE 는 그냥 성공하므로 양쪽에 그대로 돌려도 안전하다.
--
--   확인 방법(다음 사람이 「돌렸나?」를 판단할 때):
--     아래 [V1] 을 그 데이터베이스에서 돌려 **전부 false** 인지 본다.
--     ⚠️ [V1] 만으로는 PUBLIC 부여를 구분 못 한다 — [V1-b] 를 함께 볼 것.
--
--   바깥에서 실제로 막히는지도 확인했다(2026-08-21, 운영 globalreverb.com,
--   **로그인한 상태**에서 `_withdrawal_unpaid_count` 호출):
--     → `42501 permission denied for function _withdrawal_unpaid_count`
--     ⚠️ 이 확인에는 **읽기 전용 함수만** 쓸 것. 파기·상태 전진 함수로 시험하면
--        막혀 있지 않을 경우 **진짜로 실행된다.**
--
-- ============================================================
-- 되돌리기
-- ============================================================
--   아래 REVOKE 들을 GRANT 로 바꿔 실행하면 원상복구된다.
--   ⚠️ 구멍도 함께 되살아난다 — 원인을 파악한 뒤 다시 조인다.
--   ⚠️ `recompute_campaign_applied_count` 만 되돌릴 대상이 **PUBLIC** 이다
--      (`GRANT EXECUTE ON FUNCTION … TO PUBLIC;`). anon·authenticated 로
--      되돌리면 **원래 상태가 아니다.**
-- ============================================================

-- ⚠️ 한 덩어리로 묶는다 — 시그니처 하나가 어긋나 중간에 멈추면
--    **앞줄만 적용된 반쪽 상태**로 남는다(369 와 같은 판단).
BEGIN;

-- [A] 남의 정보 조회
REVOKE EXECUTE ON FUNCTION public._influencer_is_admin_account(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._withdrawal_lock_blockers(uuid)    FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._withdrawal_unpaid_count(uuid)     FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._withdrawal_account_blocked(uuid)  FROM anon, authenticated;

-- [B] 파기 배치
REVOKE EXECUTE ON FUNCTION public.purge_expired_deleted_campaigns()         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.purge_old_event_tickets()                 FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.purge_old_influencer_flags()              FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.purge_expired_withdrawal_email_blocks()   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.purge_old_admin_password_reset_requests() FROM anon, authenticated;

-- [C] 상태 전진 — 🔴 advance_withdrawal_states 는 개인정보 파기까지 이어진다
REVOKE EXECUTE ON FUNCTION public.advance_withdrawal_states()          FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.advance_to_orient_sheet_sent(uuid)   FROM anon, authenticated;

-- [D] 집계·목록
-- 🔴 **이 한 줄만 `PUBLIC` 이다 — 역할별 회수로는 안 걷힌다.**
--    개발서버 실측(2026-08-21): 이 함수의 권한 목록이
--    `{=X/postgres, postgres=X/postgres, service_role=X/postgres}` 였다.
--    맨 앞의 `=X/` 가 **PUBLIC(모두)에게 준 실행 권한**이고, 여기에는
--    `anon`·`authenticated` 도 포함되지만 **그 둘의 이름으로 회수해도 안 지워진다**
--    (역할별 부여가 아니라 전체 부여라서). 369 에서 배운 「PUBLIC 회수로는
--    개별 부여를 못 걷어낸다」의 **정확히 반대 방향**이다.
--    ⚠️ 저장소에는 084 가 PUBLIC 을 회수해 둔 기록만 있고 되돌린 기록이 없다
--    (384줄의 `GRANT … TO PUBLIC` 은 주석 블록 안이라 실행된 적 없다).
--    즉 **문서만 보고는 못 찾는다** — 실제 데이터베이스를 조회해야 드러난다.
--
-- 🔴 **이 줄이 이 파일에서 가장 위험하다 — 응모가 들어올 때마다 타는 경로다.**
--    그래서 되돌리기 전에 **개발서버에서 트랜잭션 안에 넣고 증명한 뒤 되돌렸다**:
--      · `authenticated` 로 **직접** 부르기 → **막힘**(false)
--      · 트리거(`sync_campaign_applied_count`, SECURITY DEFINER) 안쪽 호출 → **정상**(ok)
--    안쪽 호출이 사는 이유는 그 트리거 함수가 `SECURITY DEFINER` 라 **소유자
--    (postgres) 권한으로 돌기** 때문이고, postgres 는 위 목록에 그대로 있다.
--    ⚠️ 앞으로 이 함수를 부르는 자리를 새로 만들 때 **`SECURITY INVOKER` 로 만들면
--    그 순간 응모가 막힌다.** 반드시 `SECURITY DEFINER` 안쪽에서만 부를 것.
REVOKE EXECUTE ON FUNCTION public.recompute_campaign_applied_count(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.recompute_campaign_applied_count(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._settlement_cert_candidates()          FROM anon, authenticated;

-- [E] 보안 보조
REVOKE EXECUTE ON FUNCTION public.check_admin_password_reset_rate_limit(text, boolean) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gen_event_ticket_code()                              FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 확인 (적용 후)
-- ============================================================
/*
-- [V1] 열다섯 개가 닫혔나 — 로그인·비로그인 false / postgres·service_role true
SELECT p.proname AS 함수,
       has_function_privilege('postgres',      p.oid, 'EXECUTE') AS postgres,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS service_role,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('_influencer_is_admin_account','_withdrawal_lock_blockers',
                     '_withdrawal_unpaid_count','_withdrawal_account_blocked',
                     'purge_expired_deleted_campaigns','purge_old_event_tickets',
                     'purge_old_influencer_flags','purge_expired_withdrawal_email_blocks',
                     'purge_old_admin_password_reset_requests','advance_withdrawal_states',
                     'advance_to_orient_sheet_sent','recompute_campaign_applied_count',
                     '_settlement_cert_candidates','check_admin_password_reset_rate_limit',
                     'gen_event_ticket_code')
 ORDER BY 1;

-- [V1-b] 🔴 **`recompute_campaign_applied_count` 는 권한 목록까지 눈으로 볼 것**
--   위 [V1] 은 `has_function_privilege` 로 보는데, PUBLIC 부여가 남아 있으면
--   **로그인·비로그인 둘 다 true 로 보인다.** 실제 목록을 확인한다:
--     SELECT p.proname, p.proacl::text
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname='public' AND p.proname='recompute_campaign_applied_count';
--   기대: 결과에 **맨 앞 `=X/postgres` 가 없어야** 한다
--        (남아 있으면 PUBLIC 회수가 안 된 것이다).

-- 🔴 [V2] **정상 경로가 안 죽었는지 — 이쪽이 진짜 위험이다.**
--   회수한 함수들은 전부 다른 함수 안에서 불린다. 안쪽 호출은 소유자 권한으로
--   도니 영향이 없어야 하는데, **그 전제를 실제로 확인한다.**
--   관리자로 로그인한 브라우저 콘솔에서:
--     ① await db.rpc('get_withdrawal_precheck', { p_influencer_id: '<시험 회원>' })
--        → _withdrawal_lock_blockers·_withdrawal_unpaid_count 를 안쪽에서 부른다
--     ② await db.rpc('backfill_settlements')
--        → _settlement_cert_candidates 를 안쪽에서 부른다
--     ③ 캠페인 응모 화면에서 응모수가 정상인지
--        → recompute_campaign_applied_count 계열
--   기대: 셋 다 **권한 오류가 아닌** 정상 응답.
--
--   ④ **회원**(관리자 아님)으로 로그인한 브라우저 콘솔에서:
--        await db.rpc('get_my_withdrawal_state')
--      → 그 안에서 `_withdrawal_account_blocked` 를 부른다. 이 경로가 죽으면
--        **정상 회원의 로그인 판정이 통째로 실패**하므로 넷 중 가장 중요하다.
--      기대: {ok:true, has_request:false, login_blocked:false, write_blocked:false}
--
--   ⑤ 나머지 셋은 **이번에 확인하지 않아도 되는 이유가 각각 있다**(코드 추적으로
--      정상 경로가 service_role 또는 SECURITY DEFINER 안쪽임을 확인했다).
--      다만 어차피 그 흐름을 돌릴 때 함께 보면 좋다:
--        · `gen_event_ticket_code`  → `reserve_event_ticket` 안에서만 불린다.
--          ⚠️ **운영 행사 데이터가 아직 0건이라 예약을 실제로 돌려 본 적이 없다.**
--          8/28 행사 전 예약 흐름을 브라우저로 실측할 때 **함께** 확인할 것.
--        · `advance_to_orient_sheet_sent` → 오리엔시트 발급 메일 함수(service_role).
--          발급을 한 번 할 일이 생기면 그때 신청 단계가 전진하는지 본다.
--        · `check_admin_password_reset_rate_limit` → 관리자 비밀번호 찾기
--          메일 함수(service_role). 그 화면을 쓸 일이 생기면 그때 본다.
--
-- 🔴 [V3] **다음 날 새벽 예약 실행 전부 확인** — 회수한 파기 배치가 여기서 돈다.
--   SELECT j.jobname, d.status, d.return_message, d.start_time
--     FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
--    WHERE d.start_time > now() - interval '1 day'
--    ORDER BY d.start_time DESC;
--   기대: 전부 succeeded. 하나라도 실패하면 이 파일을 되돌린다.
*/
