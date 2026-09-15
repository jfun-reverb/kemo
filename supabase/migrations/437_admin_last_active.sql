-- ============================================================
-- 437_admin_last_active.sql
-- 관리자 계정 목록 「최근 로그인」 → 「최근 접속」 — 로그인 연장 시각까지 반영
--
-- 436 은 auth.users.last_sign_in_at 만 돌려줬다. 그 값은 **로그인 화면에서 직접
-- 로그인할 때만** 오른다. 브라우저가 로그인 상태를 기억하면 화면을 열 때마다 로그인이
-- 조용히 연장(토큰 갱신)될 뿐이라, 오늘 쓴 사람이 「어제」로 보였다
-- (2026-09-15 개발서버 실측: 로그인 09-14 14:45 / 연장 09-15 11:57).
--
-- 그래서 「로그인 시각」과 「그 계정의 로그인 연장 마지막 시각」 중 늦은 쪽을 함께 준다.
--   last_active_at = GREATEST(last_sign_in_at, max(auth.sessions.updated_at))
--   ⚠️ GREATEST 는 NULL 을 무시한다 — 세션이 없으면 로그인 시각이, 로그인 기록이 없으면
--      세션 시각이 남는다. 둘 다 없으면 NULL(화면은 「접속 이력 없음」).
--   ⚠️ refreshed_at 이 아니라 updated_at 을 쓴다 — auth.sessions.refreshed_at 은
--      시간대 없는 칸이라 변환할 때 서버 시간대 설정에 기댄다. updated_at 은 시간대가 있다.
--   ✅ 「연장 때 updated_at 도 오르는가」는 실측으로 닫았다(2026-09-15 개발서버):
--      admin@kemo.jp updated_at 09-15 11:57:34(KST) = refreshed_at 2026-09-15 02:57:34(UTC),
--      다른 세션 두 건도 초 단위까지 일치. refreshed_at 타입 = timestamp without time zone.
--
-- 🔴 [적용 전 확인] 인증 서비스 버전이 바뀌면 이 전제가 깨질 수 있다 — 운영 적용 **전에**
--    아래를 먼저 돌려 updated_at 과 refreshed_at(세계시)이 같은 순간인지 본다.
--    어긋나면 BEGIN 이하를 실행하지 말고 기준 칸을 다시 정한다.
--      SELECT s.updated_at, s.refreshed_at FROM auth.sessions s
--        JOIN public.admins a ON a.auth_id = s.user_id ORDER BY s.updated_at DESC LIMIT 5;
--
-- 🔴 여전히 「관리자 화면에 들어온 날」과 정확히 같지는 않다.
--    ① 관리자를 겸한 회원은 인플루언서 화면만 써도 오른다(인증 계정이 하나라서)
--    ② 로그아웃하면 세션 행이 지워져 값이 마지막 로그인 시각으로 **돌아간다**
--       (틀린 날짜가 아니라 더 옛날 날짜가 된다)
--    화면 머리글 툴팁이 이 둘을 말한다.
--
-- ⚠️ 반환 칸이 늘어 CREATE OR REPLACE 로는 못 바꾼다(Postgres 는 반환 형태 변경을 거부).
--    그래서 DROP 후 CREATE 한다. 🔴 DROP 은 436 이 걸어 둔 권한 회수를 통째로 없애므로
--    아래에서 **같은 회수·부여를 다시** 건다(CLAUDE.md 「함수 실행 권한」).
--    이름은 그대로 둔다 — 부르는 곳(dev/lib/storage.js fetchAdminLastSignIn)을 안 바꾸려고.
--
-- 베이스: 436(이 함수의 유일한 이전 정의)
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_admin_last_sign_in();

CREATE FUNCTION public.get_admin_last_sign_in()
RETURNS TABLE (
  admin_id          uuid,
  last_sign_in_at   timestamptz,
  last_active_at    timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 🔴 슈퍼관리자만. 화면 숨김과 별개로 서버가 최종 방어선이다.
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '관리자 최근 접속 조회 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ⚠️ admins 기준 왼쪽 결합 — 모든 관리자 행에 한 줄(436 과 같다). 키는 admins.id.
  -- ⚠️ 세션 집계는 결합 전에 사용자별로 묶는다 — 세션이 여러 개인 사람이 여러 줄이 되지 않게.
  RETURN QUERY
    SELECT a.id,
           u.last_sign_in_at,
           GREATEST(u.last_sign_in_at, s.last_session_at)
      FROM public.admins a
      LEFT JOIN auth.users u ON u.id = a.auth_id
      LEFT JOIN (
        SELECT ss.user_id, max(ss.updated_at) AS last_session_at
          FROM auth.sessions ss
         GROUP BY ss.user_id
      ) s ON s.user_id = a.auth_id;
END;
$$;

COMMENT ON FUNCTION public.get_admin_last_sign_in() IS
  '관리자별 마지막 로그인 시각과 최근 접속 시각(로그인·로그인 연장 중 늦은 쪽). 슈퍼관리자 전용. '
  '⚠️ 승격 계정은 인플루언서 화면 사용에도 오르고, 로그아웃하면 세션이 지워져 로그인 시각으로 돌아간다. '
  '관리자 계정 목록의 「최근 접속」 열이 쓴다.';

-- 🔴 436 과 같은 회수·부여. DROP 으로 사라졌으므로 반드시 다시 건다.
--    · PUBLIC 회수와 역할별 회수는 서로를 대신하지 못한다 → 둘 다
--    · Supabase 는 service_role 에도 기본 부여한다 → 함께 회수(서버 쪽 호출자 0곳)
--    · 순서: 회수 먼저, 부여 나중
REVOKE ALL     ON FUNCTION public.get_admin_last_sign_in() FROM PUBLIC;
REVOKE ALL     ON FUNCTION public.get_admin_last_sign_in() FROM anon, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_admin_last_sign_in() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

/* ────────────────────────────────────────────────────────────
   적용 뒤 확인 (개발·운영 각각)

   [V1] 실행 권한 — 기대: anon=false · auth_=true · svc=false · acl 맨 앞에 「=X/」 없음
     SELECT has_function_privilege('anon',          'public.get_admin_last_sign_in()', 'execute') AS anon,
            has_function_privilege('authenticated', 'public.get_admin_last_sign_in()', 'execute') AS auth_,
            has_function_privilege('service_role',  'public.get_admin_last_sign_in()', 'execute') AS svc,
            p.proacl::text AS acl
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'get_admin_last_sign_in';

   [V2] 실제 호출 — 행 수 = 관리자 수. 🔴 소유자 권한으로 auth.sessions 를 읽을 수 있는지도
        이것으로 확인된다(permission denied 가 나면 안 된다). 로그인 시각보다 last_active_at 이
        늦은 행이 있어야 이번 변경의 효과가 보인다.
     SELECT * FROM public.get_admin_last_sign_in();

   [V3] 🔴 가드 — 슈퍼가 아닌 계정 브라우저 콘솔: await db.rpc('get_admin_last_sign_in') → 오류 42501
   ──────────────────────────────────────────────────────────── */

-- 롤백: 436 파일을 다시 실행한다(단, 436 은 CREATE OR REPLACE 라 반환 형태가 달라 먼저
--   DROP FUNCTION public.get_admin_last_sign_in(); 을 돌린 뒤 실행). 화면은 last_active_at 이
--   없으면 last_sign_in_at 으로 떨어지므로 롤백해도 표가 깨지지 않는다.
