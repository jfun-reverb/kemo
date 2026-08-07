-- ════════════════════════════════════════════════════════════════════
-- migration 310: admins UPDATE 정책에 「본인 등급 변경 차단」 검사(WITH CHECK) 추가
-- ────────────────────────────────────────────────────────────────────
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §1-2
--       docs/specs/2026-08-07-audit-remediation-plan.md 묶음 A
--
-- ── 무엇이 잘못되어 있었나 ─────────────────────────────────────────
--   admins 테이블의 UPDATE 정책 "admins_update" 는
--     USING ( 최고 관리자 전체 OR 본인 행 )
--   만 있고 WITH CHECK(변경 후 값 검사)가 없다. PostgreSQL 은 UPDATE
--   정책에 WITH CHECK 가 없으면 USING 식을 그대로 WITH CHECK 에도
--   재사용하는데, 그 식이 "본인 행이면 통과"이므로 role 칸에 어떤 값이
--   들어오든(super_admin 포함) 검사되지 않는다.
--
--   실측 근거(2026-08-07, 운영 데이터베이스 — pg_policy 조회):
--     polname='admins_update' polcmd='w'
--     using_식     = "최고 관리자 전체 OR auth_id = auth.uid()"
--     with_check_식 = NULL (비어 있음)
--
--   실제로 뚫리는 경로 — SQL 인젝션이나 이론적 우회가 아니라 **화면에
--   이미 있는 버튼**이다: dev/js/admin-accounts.js 의 「관리자 계정」
--   목록 "수정" 버튼(_renderAdminAccountsTable, 131번째 줄)은
--   renderMailCell/renderInviteCell 과 달리 isSuper 조건이 전혀 없이
--   **모든 행에 무조건 렌더**된다. 등급과 무관하게 관리자 누구나 자기
--   행의 "수정"을 눌러 openEditAdmin → 등급 드롭다운(#adminFormRole,
--   disabled 속성 없음)에서 값을 바꾼 뒤 saveAdmin() 이
--     db.from('admins').update({name, role}).eq('id', editId)
--   을 그대로 호출한다(320번째 줄). USING 은 "본인 행"이라 통과되고
--   지금은 WITH CHECK 가 없어 등급이 그대로 저장된다 — 캠페인매니저가
--   자기 행을 최고 관리자로 바꾸는 데 개발자 도구조차 필요 없다.
--
--   이 결함이 뚫리면 이 프로젝트의 등급 기반 통제 전체(권한 관리 저장,
--   관리자 완전 삭제, 감사 흔적 청소, 민감정보 열람)가 함께 무의미해
--   진다(연구 문서 §1-2).
--
-- ── 재정의 기준 전수 확인 (.claude/rules/supabase.md 관례) ──────────
--   "admins_update" 정책을 만들거나 다시 정의한 마이그레이션을 전수
--   grep(`grep -rln "admins_update" supabase/migrations/`) 한 결과
--   4개뿐이다:
--     · 008_create_admins.sql        — 최초 CREATE POLICY (원본)
--     · 137_rls_initplan_optimization.sql
--         — DROP POLICY IF EXISTS + CREATE POLICY 로 실제 재정의.
--           auth.uid() 를 (SELECT auth.uid()) 로 감싸는 initplan
--           캐싱 최적화만 적용, 조건 자체(최고 관리자 전체 OR 본인 행)는
--           008 과 동일. **여기가 지금 운영에 적용된 최신 정의**이고,
--           위 실측 pg_policy 결과(using_식 표현)와 문자 그대로 일치한다.
--     · 244_admin_invite_mail_tracking.sql
--         — 정책을 다시 만들지 않고 **주석으로만** "admins_update 는
--           이미 본인 행 UPDATE 를 허용한다"를 언급(신규 컬럼 3개가
--           기존 정책을 상속함을 설명하는 용도). CREATE/DROP POLICY 없음.
--     · 245_invite_admin_preserve_password.sql
--         — 마찬가지로 주석 언급만, 정책 정의 없음.
--   따라서 **137 이 재정의 기준**이다. 이 마이그레이션은 137 의 USING
--   식을 한 글자도 바꾸지 않고 그대로 유지한 채 WITH CHECK 만 추가한다
--   (008/137 원본과 동일한 super_admin 판정 방식을 유지해, 이 변경이
--   기존에 검증된 초대·승인·삭제 흐름과 다른 판정 기준을 새로 만들지
--   않도록 함).
--
-- ── 설계: 왜 새 SECURITY DEFINER 헬퍼가 필요한가 (재귀 여부) ─────────
--   WITH CHECK 는 "변경 후(NEW) 행"만 볼 수 있고, "변경 전(OLD) 등급이
--   무엇이었는지"는 직접 알 방법이 없다 — 그래서 admins 테이블을 다시
--   조회해서 지금 저장된(아직 이 UPDATE 가 적용되기 전) 등급을 가져와
--   NEW 행의 role 과 대조해야 한다.
--
--   이 조회를 "재귀 없이" 할 수 있는 근거는 이미 이 코드베이스에
--   증명되어 있다 — 008/137 의 admins_update.USING 자체가
--     EXISTS (SELECT 1 FROM public.admins admins_1 WHERE ...)
--   로 **admins 테이블을 자기 자신의 정책 안에서 다시 조회**하고 있고,
--   이게 지금 운영에서 정상 동작 중이다. 이게 무한 재귀로 안 번지는
--   이유는, 그 서브쿼리가 admins 의 SELECT 정책(admins_select,
--   `USING (is_admin())`)을 한 번 더 타는데 is_admin() 이
--   SECURITY DEFINER 함수라 **테이블 소유자 권한으로 실행되어 행 단위
--   보안 정책 자체를 우회**하기 때문이다 — 거기서 체인이 끊긴다(한
--   단계로 종결, 무한 루프 아님).
--
--   같은 원리로 새 헬퍼 함수 current_admin_role() 을 is_admin()·
--   is_super_admin() 과 동일한 패턴(SECURITY DEFINER + SET search_path
--   = '' + STABLE, 008 원본 패턴)으로 만들면, WITH CHECK 안에서 호출해도
--   행 단위 보안 정책을 다시 타지 않고 admins 를 직접 읽는다 — 재귀
--   없음. STABLE 은 is_admin()/is_super_admin() 과 동일하게 "같은
--   트랜잭션 안에서는 같은 결과"를 의미하는 마킹이고, 이 함수도 이미
--   USING 절에서 실질적으로 이렇게 쓰이고 있어 새로운 위험이 아니다.
--
--   시점(intra-command 가시성)도 안전하다 — RLS 의 WITH CHECK 는
--   실제 heap_update 가 그 행에 적용되기 **전에** 평가되므로(새 행은
--   메모리에 구성된 튜플일 뿐 아직 힙에 쓰이지 않음), 이 시점에
--   current_admin_role() 이 admins 를 다시 SELECT 하면 **변경 전
--   값**을 정확히 돌려준다. 즉 "role = current_admin_role()" 비교는
--   "새로 저장하려는 등급이 지금 저장된 등급과 같은가"를 정확히 검사한다.
--
-- ── 최고 관리자 자기 강등은 이번 범위 밖 (충돌 없음) ─────────────────
--   이 정책은 최고 관리자에게는 여전히 USING/WITH CHECK 모두 무조건
--   통과를 허용한다(008/137 원본 그대로) — 최고 관리자가 자기 등급을
--   낮추는 것은 지금처럼 여전히 가능하다. 이 프로젝트에는 이미
--   「슈퍼관리자 자기 제한」 체계(마이그레이션 268~271)가 있지만, 그
--   체계는 role_permissions 표(기능별 접근 수준: permissions.manage·
--   admin.manage·menu.permissions·menu.admin-accounts 4종의 쓰기 고정)
--   를 다루는 것이지 admins.role 칸 자체를 잠그지 않는다 — 서로 다른
--   표, 서로 다른 메커니즘이라 이번 변경과 충돌하지 않는다. (최고
--   관리자가 자기 admins.role 을 낮췄을 때 role_permissions 판정이
--   그 즉시 새 등급 기준으로 바뀌어 스스로 잠길 수 있는 것은 사실이지만,
--   이번 조치 요청 범위(=낮은 등급의 자기 상향 차단)를 벗어나는 별개
--   사안이라 여기서 손대지 않는다 — 필요하면 후속 마이그레이션에서
--   admins_update 에 "role 이 super_admin → 다른 값으로 바뀌는 것"도
--   본인 행 한정으로 추가 차단할 수 있다.)
--
-- ── admins 를 수정하는 서버 함수들과의 충돌 확인 ─────────────────────
--   admins.role 을 쓰는(INSERT/UPDATE) SECURITY DEFINER 함수 전수
--   확인(`grep -rn "UPDATE public.admins\|UPDATE admins SET" supabase/
--   migrations/*.sql`) 결과, role 을 UPDATE 하는 함수는 없다:
--     · invite_admin(email, name, role)  — 031 원본 + 245 재정의.
--         INSERT INTO public.admins (auth_id, email, name, role, ...)
--         만 하고 UPDATE 는 하지 않는다(auth.users 쪽만 COALESCE로
--         UPDATE). INSERT 는 이 UPDATE 정책의 대상이 아니므로 영향 없음.
--     · remove_admin_role(target_auth_id)  — 031.
--         DELETE FROM public.admins WHERE auth_id = target_auth_id.
--         DELETE 라 admins_update 와 무관.
--     · delete_admin_completely(target_auth_id)  — 031.
--         DELETE FROM public.admins (외 cascade) — 역시 DELETE.
--   즉 admins.role 을 실제로 바꾸는 유일한 경로는 클라이언트의
--   `db.from('admins').update({name, role})` 직접 호출
--   (dev/js/admin-accounts.js saveAdmin(), 320번째 줄)뿐이고, 그
--   경로가 정확히 이번에 검사하려는 대상이다. 초대·승격·삭제 경로는
--   전부 INSERT/DELETE 라 이번 WITH CHECK 의 영향을 받지 않는다
--   (승격 시나리오도 INSERT 라 그대로 동작).
--
-- ── 화면 영향 확인 ───────────────────────────────────────────────────
--   · 내 계정 화면(dev/js/admin-accounts.js saveMyAdminInfo, 242~253
--     번째 줄)은 `update({name})` 만 보낸다 — role 키 자체가 없으므로
--     이번 WITH CHECK 대상 밖(role 칸이 안 바뀌니 항상 통과). 이름
--     변경은 그대로 동작.
--   · 「관리자 계정」 목록의 "수정" 버튼(관리자 편집 모달)은 위에서
--     확인했듯 **최고 관리자 전용이 아니라 모든 등급에 무조건 렌더**
--     되고, saveAdmin() 은 role 을 항상 함께 보낸다(317~320번째 줄).
--     최고 관리자가 자기 자신 또는 남을 편집하면 그대로 통과(변경
--     없음). 최고 관리자가 아닌 관리자가 **자기 행**을 열어 등급을
--     그대로 두고 저장하면(이름만 바뀌었어도) role 값이 동일하므로
--     통과한다 — 정상 이름 변경은 이 화면에서도 막히지 않는다. 등급을
--     실제로 바꿔 저장을 시도하면 PostgreSQL 이 새 행이 행 단위 보안
--     정책(WITH CHECK)을 위반했다는 오류(42501)를 던지고, saveAdmin()
--     의 catch(e) 가 이를 잡아 오류 토스트로 보여준다(조용한 실패가
--     아니라 명시적 거부).
--   · 최고 관리자가 아닌 관리자가 **남의 행**을 열어 저장을 시도하는
--     경로는 이번 변경과 무관하게 이미 USING 절("최고 관리자 전체 OR
--     본인 행")에서 막혀 있었다(0행 UPDATE, 이번 변경 전후 동일) —
--     수정 버튼이 무조건 렌더되는 것은 혼란을 주는 화면 문제이지만
--     보안 구멍은 아니었고, 이번 마이그레이션의 범위 밖(화면 코드는
--     건드리지 않음 — 필요하면 별도 조각으로 isSuper 조건을 그 버튼에도
--     추가하는 것을 권장).
--
-- ── 데이터베이스 변경 ────────────────────────────────────────────────
--   1. 신규 함수: public.current_admin_role() — 로그인한 사람의
--      admins.role 반환(SECURITY DEFINER, STABLE, search_path='').
--   2. admins_update 정책 재정의: USING 은 137 과 완전히 동일, WITH
--      CHECK 신규 추가(최고 관리자 전체 통과 / 그 외는 본인 행이고
--      role 이 변경 전과 같을 때만 통과).
--
-- ── 롤백 ─────────────────────────────────────────────────────────────
--   BEGIN;
--     DROP POLICY IF EXISTS "admins_update" ON public.admins;
--     CREATE POLICY "admins_update"
--       ON public.admins FOR UPDATE
--       USING (
--         (
--           EXISTS (
--             SELECT 1 FROM public.admins admins_1
--             WHERE admins_1.auth_id = (SELECT auth.uid())
--               AND admins_1.role = 'super_admin'::text
--           )
--         )
--         OR auth_id = (SELECT auth.uid())
--       );
--     DROP FUNCTION IF EXISTS public.current_admin_role();
--   COMMIT;
--   -- 되돌리면 137 시점(WITH CHECK 없음)으로 완전히 복원된다 — 등급
--   -- 자기 상향 결함도 함께 되돌아오므로, 롤백은 이 마이그레이션 자체에
--   -- 새 결함이 발견됐을 때만 쓸 것.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. 헬퍼 함수 — 로그인한 사람의 현재(변경 전) admins.role 스냅샷
--    is_admin()/is_super_admin() (008_create_admins.sql) 과 동일한
--    패턴: SQL/STABLE/SECURITY DEFINER/SET search_path='' — 정의자
--    권한으로 admins 를 직접 읽어 행 단위 보안 정책을 우회하므로,
--    admins_update 의 WITH CHECK 안에서 호출해도 그 정책을 다시
--    타지 않는다(재귀 없음).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.current_admin_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT role FROM public.admins WHERE auth_id = (SELECT auth.uid());
$$;

COMMENT ON FUNCTION public.current_admin_role() IS
  '[310] 로그인한 사람의 admins.role 반환(해당 행 없으면 NULL). '
  'is_admin()/is_super_admin() 과 동일한 SECURITY DEFINER 패턴 — '
  'admins 행 단위 보안 정책을 우회해 직접 읽으므로 admins_update '
  'WITH CHECK 안에서 호출해도 재귀가 없다. admins_update 정책이 '
  '"본인 행에서는 등급을 바꿀 수 없다"를 검사할 때, UPDATE 가 그 행의 '
  '힙 튜플에 실제로 쓰이기 전(WITH CHECK 평가 시점) 값을 돌려주므로 '
  '변경 전(OLD) 등급 스냅샷으로 쓸 수 있다.';

GRANT EXECUTE ON FUNCTION public.current_admin_role() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. admins_update 정책 재정의 — USING 은 137 원문과 완전히 동일,
--    WITH CHECK 신규 추가.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "admins_update" ON public.admins;

CREATE POLICY "admins_update"
  ON public.admins FOR UPDATE
  USING (
    (
      EXISTS (
        SELECT 1
        FROM public.admins admins_1
        WHERE admins_1.auth_id = (SELECT auth.uid())
          AND admins_1.role = 'super_admin'::text
      )
    )
    OR auth_id = (SELECT auth.uid())
  )
  WITH CHECK (
    (
      EXISTS (
        SELECT 1
        FROM public.admins admins_1
        WHERE admins_1.auth_id = (SELECT auth.uid())
          AND admins_1.role = 'super_admin'::text
      )
    )
    OR (
      auth_id = (SELECT auth.uid())
      AND role = public.current_admin_role()
    )
  );

COMMENT ON POLICY "admins_update" ON public.admins IS
  '[310] USING 은 137 원문 그대로(최고 관리자 전체 OR 본인 행). '
  'WITH CHECK 신규 — 최고 관리자는 그대로 전부 허용, 그 외는 본인 행이고 '
  '변경 후 role 이 변경 전과 같을 때만 허용(등급 자기 상향 차단). '
  '이름 등 role 이외 칸 수정은 계속 허용된다.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 검증 (마이그레이션 실행 후 SQL 편집기에서 확인용 — 1단계씩 순서대로
-- 결과를 확인하며 진행할 것. 한 번에 다 실행하지 말 것)
--
-- ⚠️ 이 마이그레이션이 만드는 방어선은 트리거가 아니라 "행 단위 보안
--   정책(RLS)" 그 자체다. Supabase SQL 편집기는 보통 행 단위 보안
--   정책을 우회하는 권한(postgres/service_role)으로 실행되므로,
--   set_config('request.jwt.claims', ...) 로 auth.uid() 를 흉내내도
--   USING/WITH CHECK 자체가 평가되지 않아 "성공"으로 보일 수 있다
--   (272_recruit_deadline_guard.sql 의 BEFORE INSERT 트리거와 달리,
--   트리거는 권한과 무관하게 항상 실행되지만 RLS 정책은 그렇지 않다).
--   그래서 3단계(실제 차단 확인)는 SQL 편집기가 아니라 **실제 로그인
--   세션**(브라우저 콘솔 또는 진짜 액세스 토큰으로 호출하는 REST API)
--   에서만 신뢰할 수 있다 — 아래 방법은 M3② 실측(2026-08-07)에 쓴
--   방법과 동일하다.
-- ════════════════════════════════════════════════════════════════════
--
-- 1단계 — 함수·정책 정의가 반영됐는지(메타데이터 조회는 SQL 편집기로
--   충분 — RLS 평가가 아니라 정의 확인이라 권한 우회와 무관):
--
-- SELECT prosecdef, provolatile
--   FROM pg_proc
--  WHERE proname = 'current_admin_role' AND pronamespace = 'public'::regnamespace;
-- → 1행, prosecdef = true, provolatile = 's'(stable)
--
-- SELECT polname, polcmd,
--        pg_get_expr(polqual,      polrelid) AS using_식,
--        pg_get_expr(polwithcheck, polrelid) AS with_check_식
--   FROM pg_policy
--  WHERE polrelid = 'public.admins'::regclass AND polname = 'admins_update';
-- → using_식 은 마이그레이션 전과 동일한 문구(최고 관리자 전체 OR
--   auth_id = auth.uid()), with_check_식 이 더 이상 NULL 이 아니고
--   role = current_admin_role() 조건이 포함돼 있어야 한다.
--
-- 2단계 — 실제 차단 확인 ①: 가장 낮은 등급 계정으로 자기 등급 변경
--   시도 → 거부되는지 (개발서버, 캠페인매니저 테스트 계정으로 관리자
--   화면에 실제 로그인한 뒤 브라우저 콘솔에서 — M3② 실측과 동일한 방식):
--
--   const me = (await db.auth.getUser()).data.user;
--   const r = await db.from('admins').update({ role: 'super_admin' }).eq('auth_id', me.id).select();
--   console.log(r);
--   → data 는 빈 배열이거나, error.code === '42501' (row-level security
--     policy violation) 이어야 한다. role 이 실제로 super_admin 으로
--     바뀌면 이 마이그레이션이 실패한 것 — 즉시 원인을 확인할 것.
--   ⚠️ 혹시 성공해 버리면(즉 이 마이그레이션 적용 전처럼 통과되면) 그
--     테스트 계정의 등급을 최고 관리자 계정으로 즉시 원래대로 되돌릴 것.
--
-- 3단계 — 실제 차단 확인 ②: 최고 관리자가 남의 등급을 바꾸는 것은
--   여전히 성공하는지 (최고 관리자 테스트 계정으로 로그인 후, 「관리자
--   계정」 목록에서 다른 관리자 행의 "수정" → 등급 변경 → 저장, 또는
--   콘솔에서):
--
--   const r = await db.from('admins').update({ role: 'campaign_manager' }).eq('id', '<대상 admins.id>').select();
--   console.log(r);
--   → data 에 변경된 행 1개, error 없음. 테스트가 끝나면 등급을 원래
--     값으로 되돌려 둘 것.
--
-- 4단계 — 실제 차단 확인 ③: 본인 이름만 변경하는 것은 등급과 무관하게
--   여전히 성공하는지 (캠페인매니저 테스트 계정, 「내 계정」 화면에서
--   이름만 바꿔 저장 — 또는 콘솔에서):
--
--   const me = (await db.auth.getUser()).data.user;
--   const r = await db.from('admins').update({ name: '이름변경테스트' }).eq('auth_id', me.id).select();
--   console.log(r);
--   → data 에 변경된 행 1개, error 없음(role 이 그대로라 WITH CHECK
--     통과).
-- ════════════════════════════════════════════════════════════════════
