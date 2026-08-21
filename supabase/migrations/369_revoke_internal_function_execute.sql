-- ============================================================
-- 369_revoke_internal_function_execute.sql
-- 내부 전용 함수의 실행 권한을 anon·authenticated 에서 회수
--
-- 발견: 2026-08-21, 작업 12-B-1 검증 중
-- ============================================================
-- 🔴 무엇이 문제였나
-- ============================================================
--   여러 마이그레이션이 내부 전용 함수를 이렇게 잠갔다:
--
--       REVOKE ALL ON FUNCTION ... FROM PUBLIC;
--       GRANT EXECUTE ON FUNCTION ... TO postgres, service_role;
--
--   그런데 **Supabase 는 새 함수에 anon·authenticated 실행 권한을
--   자동으로 부여**한다(프로젝트 기본 권한). `PUBLIC` 회수는 그
--   **개별 부여를 걷어내지 못한다** — PUBLIC 과 개별 롤은 다른 항목이다.
--
--   결과: 잠근 줄 알았던 함수들이 **비로그인 공개 키로도 호출됐다.**
--   2026-08-21 개발서버에서 실제 확인 — 읽기 전용 함수 하나를 로그인
--   없이 불러 200 응답을 받았다.
--
-- ⚠️ **이 저장소가 이미 위험을 정확히 적어 두고 있었다.**
--   · 마이그레이션 352: 「본인 확인이 전혀 없어, 일반 로그인 사용자가 이
--     함수를 직접 호출할 수 있게 두면 **아무 인플루언서 uuid 나 넘겨 남의
--     개인정보를 지울 수 있는 구멍**이 된다」
--   · CLAUDE.md: `_withdrawal_cancel_applications` 는 「아무에게도 실행
--     권한을 주지 않는다 — 내부 전용이 아니라 **보안 경계**다」
--   둘 다 의도는 맞았고 **집행 수단이 한 겹 모자랐다.**
--
-- ============================================================
-- 무엇을 하나
-- ============================================================
--   아래 9개 함수에서 anon·authenticated 실행 권한을 **명시적으로** 회수한다.
--   postgres·service_role 은 건드리지 않는다.
--
--   ⚠️ **9개 모두 브라우저에서 부르지 않는다**(2026-08-21 확인 —
--      `grep -rl "rpc('<이름>'" dev/` 가 전부 0건).
--   ⚠️ 바깥에서 부르는 것은 **파기 전용 함수 `purge-withdrawal-media` 하나**이고,
--      그것이 **2개**(`list_pending_withdrawal_media_purge`·`mark_withdrawal_media_purged`)를
--      부른다. 그 함수는 service_role 로 도니 이 회수에 안 걸린다.
--      (처음에 「메일 함수 셋」이라 적었는데 사실과 달랐다 — 검토에서 정정됨)
--   ⚠️ 다른 SQL 함수 안에서 불리는 것들(예: 대기자 승격)은 **부르는 함수의
--      소유자 권한으로 실행**되므로 이 회수에 안 걸린다.
--
-- ============================================================
-- 이번에 손대지 않는 것 (의도)
-- ============================================================
--   토큰으로 신원을 확인하는 익명 함수는 **그대로 둔다** — 비로그인이
--   부르는 것이 정상이다:
--     get_orient_sheet · save_orient_draft · submit_orient_sheet ·
--     unsubscribe_by_token · track_promo_click · verify_event_invite ·
--     submit_brand_application · is_brand_survey_open · report_client_error ·
--     increment_campaign_view · record_site_visit
--
--   ⚠️ 같은 유형(소유자 권한 + 비로그인 실행 가능 + 호출자 검사 없음)이
--      운영에 **85개** 있다. 이 파일은 그중 **파기·철회처럼 되돌릴 수 없는
--      일을 하거나 저장소 경로를 내주는 9개**만 닫는다.
--      (「데이터를 바꾸고 식별자를 인자로 받는」이라고 적었으나 엄밀히는 안 맞는다 —
--       `_withdrawal_media_purge_due_ids()`는 조회이고 인자가 없다.)
--
--   ⚠️ **일부러 뺀 것 — 다음 사람이 「빠뜨렸나」로 오해하지 않게 적어 둔다.**
--      같은 결함 패턴이지만 **읽기 전용**이라 이번 배치에서 제외했다:
--        `_influencer_is_admin_account(uuid)` (356) — 그 회원이 관리자인지 여부
--          🔴 **셋 중 가장 값어치 있는 정보다**(임의 번호를 넣어 관리자를 골라낼 수 있다).
--             후속 배치에서 **가장 먼저** 닫을 것
--        `_withdrawal_lock_blockers(uuid)` (353) — 그 회원의 결과물·행사·정산·미지급 건수
--        `_withdrawal_unpaid_count(uuid)` (350) — 미지급 건수
--        `_withdrawal_account_blocked(uuid)` (358) — 탈퇴 확정·예정 여부
--      `_withdrawal_email_hash(text)` (361) 은 데이터베이스를 안 보는 순수 계산이라 위험 없음.
--
-- ============================================================
-- 되돌리기
-- ============================================================
--   GRANT EXECUTE ON FUNCTION public.<이름>(<인자>) TO authenticated;
--   (원래 상태로 돌리려면 anon 에도 같이)
-- ============================================================

-- ⚠️ 아홉 줄을 한 덩어리로 묶는다 — 시그니처 하나가 어긋나면 그 줄에서 멈추는데,
--    묶지 않으면 **앞줄만 적용된 반쪽 상태**로 남는다.
BEGIN;

-- ① 탈퇴 확정 시 개인정보 파기 — 호출자 검사가 **전혀 없다**(352 자체 경고)
REVOKE EXECUTE ON FUNCTION public.purge_withdrawn_personal_data(uuid) FROM anon, authenticated;

-- ② 응모 일괄 철회 — 통과 표시를 세우는 곳. CLAUDE.md 가 「보안 경계」라 부른 함수
REVOKE EXECUTE ON FUNCTION public._withdrawal_cancel_applications(uuid) FROM anon, authenticated;

-- ③ 파기 표시 — 안 지운 파일을 「지웠다」로 만들면 그 파일은 영영 안 지워진다
REVOKE EXECUTE ON FUNCTION public.mark_withdrawal_media_purged(uuid[]) FROM anon, authenticated;

-- ④ 파기 대상 목록 — 저장소 경로가 그대로 나온다
REVOKE EXECUTE ON FUNCTION public.list_pending_withdrawal_media_purge(integer) FROM anon, authenticated;

-- ⑤ 파기 기한 지난 회원 목록
REVOKE EXECUTE ON FUNCTION public._withdrawal_media_purge_due_ids() FROM anon, authenticated;

-- ⑥ 페이팔 5년 파기
REVOKE EXECUTE ON FUNCTION public.purge_withdrawn_paypal() FROM anon, authenticated;

-- ⑦ 행사 예약 취소(배치용) — 남의 예약을 취소할 수 있다
REVOKE EXECUTE ON FUNCTION public._withdrawal_cancel_event_ticket(uuid) FROM anon, authenticated;

-- ⑧⑨ 행사 대기 순번 조작
REVOKE EXECUTE ON FUNCTION public._promote_next_event_waitlist(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._renumber_event_waitlist(uuid)     FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 확인 (적용 후)
-- ============================================================
/*
-- [V1] 아홉 개가 다 닫혔나 — 로그인·비로그인 모두 false, postgres·service_role 은 true
SELECT p.proname AS 함수,
       has_function_privilege('postgres',      p.oid, 'EXECUTE') AS postgres,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS service_role,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('purge_withdrawn_personal_data','_withdrawal_cancel_applications',
                     'mark_withdrawal_media_purged','list_pending_withdrawal_media_purge',
                     '_withdrawal_media_purge_due_ids','purge_withdrawn_paypal',
                     '_withdrawal_cancel_event_ticket','_promote_next_event_waitlist',
                     '_renumber_event_waitlist')
 ORDER BY 1;
-- 기대: postgres·service_role = true / 로그인·비로그인 = false (9행 전부)

-- 🔴 [V2] **브라우저에서** — 이게 진짜 확인이다.
--   관리자로 로그인한 상태에서 개발자 도구 콘솔에 아래를 넣는다.
--   기대: 전부 거부(권한 오류). 하나라도 통과하면 회수가 안 먹은 것이다.
--     await db.rpc('list_pending_withdrawal_media_purge', { p_limit: 1 })
--
-- 🔴 [V3] **정상 경로가 안 죽었는지** — 회수의 진짜 위험은 이쪽이다.
--   ① 본인 응모 취소를 실제 회원 계정으로 눌러 본다(정상 동작해야 함)
--      ⚠️ 호출 방향을 헷갈리지 말 것 — `cancel_application` 이 회수 대상을 부르는 게
--         아니라, **회수 대상인 `_withdrawal_cancel_applications` 가
--         `cancel_application` 을 부른다.** 그래서 ①만으로는 체인이 안 걸린다 → ④ 필수
--   ② 행사 예약 취소를 눌러 본다(대기자 승격·순번 재정렬이 안쪽에서 돈다)
--   ③ 다음 날 새벽 예약 실행 5종이 정상 완료됐는지 확인
--      SELECT jobname, status, return_message, start_time
--        FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
--       WHERE j.jobname LIKE 'withdrawal-%' AND start_time > now() - interval '1 day'
--       ORDER BY start_time DESC;
--   🔴 ④ **가장 위험한 체인 — 이걸 빼면 안 된다.**
--      `_withdrawal_cancel_applications`(회수 대상 ②)를 부르는 자리는 코드 전체에서
--      `request_withdrawal`(회원 본인)과 `request_withdrawal_for_member`(관리자 대행)
--      **딱 둘뿐**이다. 살아 있는 응모가 있는 시험 계정으로 대행 신청을 넣어 본다.
--        기대: `cancelled_count > 0` 이고 그 응모가 실제로 `cancelled` 로 바뀐다.
--        🔴 실패하면 회수가 내부 호출까지 막은 것이므로 **즉시 되돌린다.**
--      ⚠️ 이 함수는 2026-05~08 **3개월간 조용히 죽어 있던** 전력이 있다(오류 로그에
--         흔적조차 없었다). CLAUDE.md 가 「가장 위험한 부분」이라 부르는 자리다.
--      ✅ 2026-08-21 개발서버 실측 — `cancelled_count: 1`, `approved → cancelled` 확인.
--         (감사용 계정은 `audit_account_blocked` 로 거부되므로 시험 대상이 안 된다)
--
--   ⚠️ ①②④는 **회수가 안쪽 호출까지 막지 않는다**는 전제를 실제로 확인하는
--      단계다. 막힌다면 이 파일을 즉시 되돌려야 한다(위 「되돌리기」).
*/
