-- ============================================================
-- 313_influencers_update_allow_narrow.sql
-- 전수조사 후속 조치 묶음 E — E-3: 원본 표(influencers) 관리자 수정 허가를
-- 좁힌다. 지금은 등급 무관 모든 관리자가 아무 인플루언서 행이나 UPDATE 할 수
-- 있다(마이그레이션 137:365-368, influencers_update_allow — is_admin() OR
-- auth.uid()=id).
--
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §1-3 "덤"
--   "같은 표의 수정 정책(137:365-368)도 「관리자면 통과」라 하위 등급이 아무
--    인플루언서 행이나 고칠 수 있다."
-- 조치 계획: docs/specs/2026-08-07-audit-remediation-plan.md 묶음 E, E-3
-- 전제: 마이그레이션 312(E-2)가 먼저 적용돼 있어야 한다(파일 번호 순서 그대로
--   따르면 자동으로 지켜짐 — 312 → 313).
--
-- ────────────────────────────────────────────────────────────
-- 정당한 관리자 수정 경로가 있는지 먼저 확인(전수 grep, 2026-08-07)
-- ────────────────────────────────────────────────────────────
-- `db.from('influencers').update(...)` / `.upsert(...)` 호출부를 전수 grep 했다
-- (dev/js/*.js, dev/lib/storage.js):
--   - upsertInfluencer / updateInfluencer(dev/lib/storage.js) — 호출부 전원이
--     auth.js:114·179, application.js:1145, mypage.js:403·424 로 전부
--     `currentUser.id`(본인) 만 넘긴다. 관리자 화면에서 다른 사람의 행을
--     대상으로 부르는 호출은 0건.
--   - updateMarketingOptIn(storage.js:3096) — `eq('id', currentUser.id)` 본인
--     한정, 관리자 화면 무관.
--   - 관리자가 인플루언서 상태(인증·블랙리스트·위반)를 바꾸는 유일한 경로는
--     set_influencer_verified / set_influencer_blacklist /
--     record_influencer_violation / update_influencer_violation
--     (마이그레이션 059~062) 4개 RPC 뿐이다. 전부 SECURITY DEFINER + 함수
--     안에서 `UPDATE public.influencers ...` 를 직접 실행 — 함수 소유자(=표
--     소유자, FORCE ROW LEVEL SECURITY 미설정)의 권한으로 돌아 RLS 를
--     원래도 우회하고 있었다(호출자 등급 검증은 함수 안에서 admins 테이블을
--     직접 조회해 별도로 함).
--
-- 결론: **정당한 "관리자가 다른 사람의 인플루언서 행을 직접 UPDATE" 경로는
-- 화면 코드에 없다.** 지금 정책이 열어 주는 건 PostgREST REST API 를 직접
-- 두드리는 통로뿐이고(예: PATCH /rest/v1/influencers?id=eq.<다른사람>), 이건
-- 화면 어디에서도 쓰지 않는 통로다. 본인만 남기는 게 맞다 — 059 원본 주석의
-- "본인 or is_admin() 그대로 유지"는 "이번 마이그레이션(059) 범위에서는
-- 안 건드린다"는 뜻이었을 뿐, 이 정책에 기능적으로 의존하는 코드는 없다
-- (059의 RPC 들은 SECURITY DEFINER 라 이 정책 자체가 사라져도 무관하게 계속
-- 동작 — 위 문단 확인 내용).
--
-- ────────────────────────────────────────────────────────────
-- 이 마이그레이션이 하는 일
-- ────────────────────────────────────────────────────────────
-- influencers_update_allow 를 "본인 or is_admin()" → "본인만" 으로 좁힌다.
-- 007 이전(006까지)의 influencers_update_own 과 동일한 조건 — 이름은 137 의
-- 명명 그대로 influencers_update_allow 유지(과거 감사·문서가 이 이름으로
-- 정책을 지목하므로 이름을 바꾸면 다음 조사에서 "삭제됐나?"로 오인될 위험).
--
-- ────────────────────────────────────────────────────────────
-- 영향받지 않는 것
-- ────────────────────────────────────────────────────────────
-- - 인플루언서 본인의 마이페이지 수정(이름·SNS·배송지·PayPal·마케팅 수신설정) —
--   전부 본인 id 로 UPDATE, influencers_update_allow 의 "auth.uid()=id" 조건은
--   그대로 남아 있어 무관.
-- - 인증/블랙리스트/위반 RPC 4종 — 위 확인대로 SECURITY DEFINER 라 RLS 자체를
--   안 탄다. 정책이 좁아져도 동작 불변.
-- - influencers_delete_admin(001, USING is_admin()) — 이번 조각의 대상 아님
--   (조사·계획 모두 SELECT·UPDATE 만 지목). 손대지 않음.
--
-- 롤백: 파일 하단.
-- ============================================================

DROP POLICY IF EXISTS "influencers_update_allow" ON public.influencers;

CREATE POLICY "influencers_update_allow"
  ON public.influencers FOR UPDATE
  USING ((SELECT auth.uid()) = id)
  WITH CHECK ((SELECT auth.uid()) = id);

COMMENT ON POLICY "influencers_update_allow" ON public.influencers IS
  '[313] 본인 행만 UPDATE 가능(과거 is_admin() OR 본인 → 본인만으로 좁힘). '
  '관리자가 인플루언서 상태를 바꾸는 정당한 경로는 전부 SECURITY DEFINER RPC '
  '(set_influencer_verified 등, 마이그레이션 059~062)이고, 그 RPC 들은 표 '
  '소유자 권한으로 실행돼 이 정책과 무관하게 계속 동작한다.';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (SQL 편집기 불가 — 서비스 키 세션은 RLS 를 우회해 정책 자체를
-- 관찰할 수 없다. 실제 로그인 세션 기준으로 확인한다.)
-- ============================================================
-- 1. campaign_manager(또는 임의 관리자) 계정으로 로그인 후 콘솔에서:
--      await db.from('influencers')
--        .update({ bio: 'rls-probe' })
--        .eq('id', '<자기 것이 아닌 다른 인플루언서 id>')
--    → error 가 나거나(RLS 위반) data 가 빈 배열(0행 매치)이어야 한다.
--    (PostgREST 는 WITH CHECK 위반이 아니라 애초에 USING 이 그 행을 안
--    보여주므로 "0행 UPDATE" 로 조용히 끝나는 경우가 많다 — 그 뒤 별도
--    조회로 그 인플루언서의 bio 가 실제로 안 바뀌었는지 재확인할 것.)
--
-- 2. 같은 관리자 계정으로 인플루언서 상세 모달의 "인증 부여" 또는
--    "위반 기록" 버튼을 눌러 정상 동작하는지 확인(RPC 경로, 영향 없어야 함).
--
-- 3. 테스트 인플루언서 계정(sakura.test@reverb.jp)으로 로그인해 마이페이지
--    기본정보 저장이 정상 동작하는지 확인(본인 UPDATE, 영향 없어야 함).
-- ============================================================

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS "influencers_update_allow" ON public.influencers;
-- CREATE POLICY "influencers_update_allow"
--   ON public.influencers FOR UPDATE
--   USING (public.is_admin() OR (SELECT auth.uid()) = id)
--   WITH CHECK (public.is_admin() OR (SELECT auth.uid()) = id);
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
