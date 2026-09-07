-- ============================================================
-- 415. 회원 「안 읽은 메시지」 배지 조회가 타는 관리자 정책 — is_admin() 을
--      (SELECT public.is_admin()) 로 감싼다 (InitPlan 1회 평가)
-- ============================================================
-- 사양서: docs/specs/2026-09-02-influencer-unread-badge-timeout.md §1-5·§1-6·§3 (조각 2, 안 ㄹ)
--
-- ── 무엇이 문제였나 ─────────────────────────────────────────
-- 회원 화면의 배지는 뷰 application_message_summary(144, security_invoker) 를
-- 읽는다. 그 뷰는 applications ⟕ application_messages ⟕ application_message_resolutions
-- 를 묶는데, 세 표 모두 관리자 SELECT 정책이 `USING (is_admin())` 이라
-- 회원이 조회할 때 **행마다** is_admin() 이 평가된다(허용 정책은 OR 로 합쳐져
-- 본인 조건이 거짓인 행마다 관리자 조건까지 돈다).
--
-- 운영 실측(2026-09-07, 회원 역할로 EXPLAIN ANALYZE — 응모 4,566 / 메시지 4,000 / 대화정리 1,008):
--   전체 469.267 ms · 버퍼 16,656
--   ├ application_messages 순차 탐색 283.8 ms (Filter: (…) OR is_admin(), 4,084행 제거)
--   ├ applications              (Filter: … OR is_admin(), 4,557행 제거)
--   └ application_message_resolutions 32.5 ms (Filter: is_admin(), 1,008행 제거)
-- 시간 제한(8초)까지 약 17배 남았지만 **비용이 표 전체에 비례**해 응모가 늘면
-- 모든 회원의 배지 조회가 함께 느려진다. 시간 초과가 실제로 9회 났다(2026-09-02).
--
-- ── 왜 감싸면 빨라지나 ──────────────────────────────────────
-- 마이그레이션 137 이 `auth.uid()` 를 `(SELECT auth.uid())` 로 감싸 InitPlan
-- 1회 평가로 바꿨는데, **`is_admin()` 은 한 건도 안 감쌌다**(137 에 그 이름이 0번).
-- is_admin() 은 `LANGUAGE sql STABLE SECURITY DEFINER`(018) 라 같은 방식이 통한다.
-- 운영에서 조건문만 바꿔 비교하니 표 하나에서 67.2 ms → 3.5 ms(§1-6).
--
-- ── 뜻은 안 바뀐다 ───────────────────────────────────────────
-- `(SELECT public.is_admin())` 은 같은 boolean 을 한 번만 계산해 상수처럼 쓴다.
-- 어느 행을 통과시키는지는 글자 그대로 같다(Rows Removed by Filter 가 같아야 한다 — 아래 검증).
--
-- ── 범위 ─────────────────────────────────────────────────────
-- 이 조회가 타는 세 표의 정책만. 저장소 전체에는 아직 감싸지 않은 is_admin()
-- 정책이 **84개**(2026-09-07 운영 pg_policies 실측) 더 있다 — 그것은 별도 작업.
-- ⚠️ 같은 표의 UPDATE/DELETE 관리자 정책(applications_update_admin·applications_delete_admin)
--    은 **일부러 안 건드린다** — 이 조회는 SELECT 만 타고, 사양서 §4 가 범위를 「이 조회가
--    타는 것」으로 좁혀 뒀다. 나머지 84개와 함께 후속 작업에서 한 번에 다룬다
--    (2026-09-07 Supabase 검토 권고).
--
-- ⚠️ 정책 이름·표·명령·대상 역할은 그대로다. 정책 원문은 001(applications) ·
--    144(application_messages·application_message_resolutions) 이고, 그 뒤에 이 세
--    정책을 재정의한 마이그레이션은 없다(전수 확인 2026-09-07 — 137 은 applications 의
--    _own 두 정책만, 315 는 application_messages 의 influencer_read_own… 만 손댔다.
--    315 가 「admin_read_all_messages 는 그대로 둔다」고 적은 전제 — 관리자는 숨김과
--    무관하게 전부 본다 — 도 반환값이 안 바뀌므로 유지된다).
--
-- ⚠️ DROP→CREATE 는 표에 배타 잠금을 잡는다. 한 번에 실행하면 바깥에서 보이는
--    공백은 없지만(137 과 같은 방식), 그 순간 그 표를 만지는 요청이 잠깐 기다린다 —
--    트래픽이 적은 시간대 권장.
--
-- 롤백: 아래 세 CREATE POLICY 의 USING 을 `public.is_admin()` 으로 되돌린다.
-- ============================================================

BEGIN;

-- ── applications ─────────────────────────────────────────────
DROP POLICY IF EXISTS "applications_select_admin" ON public.applications;
CREATE POLICY "applications_select_admin"
  ON public.applications FOR SELECT
  USING ((SELECT public.is_admin()));

-- ── application_messages ─────────────────────────────────────
DROP POLICY IF EXISTS "admin_read_all_messages" ON public.application_messages;
CREATE POLICY "admin_read_all_messages"
  ON public.application_messages FOR SELECT
  USING ((SELECT public.is_admin()));

-- ── application_message_resolutions ──────────────────────────
DROP POLICY IF EXISTS "admin_read_resolutions" ON public.application_message_resolutions;
CREATE POLICY "admin_read_resolutions"
  ON public.application_message_resolutions FOR SELECT
  USING ((SELECT public.is_admin()));

COMMIT;

-- ============================================================
-- 검증
-- ============================================================
-- 1) 정의가 반영됐는가 — 세 줄 모두 qual 에 `( SELECT is_admin()` 이 보여야 한다
--    (pg_policies 는 스키마 접두어를 떼고 보여준다):
--
--   select tablename, policyname, cmd, qual
--     from pg_policies
--    where schemaname = 'public'
--      and policyname in ('applications_select_admin','admin_read_all_messages','admin_read_resolutions')
--    order by 1, 2;
--
-- 2) 뜻이 안 바뀌었는가 + 얼마나 빨라졌는가 — 회원 역할로 배지 조회를 EXPLAIN ANALYZE.
--    ⚠️ SQL 편집기의 기본 권한(postgres)은 행 단위 보안 정책을 우회하므로
--       **`set local role authenticated`** 가 반드시 있어야 정책이 평가된다(310 주석 참조).
--    ⚠️ 적용 전과 같은 회원 id 로 돌려 `Rows Removed by Filter` 가 **같은지** 본다 —
--       같으면 걸러지는 행이 같다는 뜻이고, 줄어든 것은 함수를 부른 횟수뿐이다.
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<회원 uuid>","role":"authenticated"}', true);
--   explain (analyze, buffers)
--     select application_id, campaign_id, unread_for_influencer, last_message_at
--       from public.application_message_summary
--      where unread_for_influencer > 0
--      order by last_message_at desc;
--   commit;
--
--   적용 전(운영 2026-09-07): Execution Time 469.267 ms · Buffers 16,656 ·
--     applications 4,557 제거 / application_messages 4,084 제거 / resolutions 1,008 제거
--   적용 후(운영 2026-09-07 실측): Execution Time **7.809 ms** · application_messages 4,084 제거 /
--     resolutions 1,008 제거(둘 다 적용 전과 같음) · Filter 가 `(… OR (InitPlan N).col1)` 꼴.
--   개발서버(2026-09-07): 4.919 → 1.750 ms, Rows Removed 응모 60 / 메시지 61 / 대화정리 18 — 적용 전후 동일.
--
-- 3) 관리자 쪽이 그대로 보이는가 — 관리자 계정으로 받은편지함(#messages)과
--    인플 신청 관리 목록을 열어 건수가 적용 전과 같은지 눈으로 확인.
-- ============================================================
