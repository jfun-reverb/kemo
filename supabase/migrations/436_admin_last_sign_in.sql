-- ============================================================
-- 436_admin_last_sign_in.sql
-- 관리자 계정 목록의 「최근 로그인」 열 — 슈퍼관리자 전용 조회 함수
--
-- 관리자 계정 화면에 「누가 얼마나 안 들어왔나」를 보여 주기 위한 값.
-- 그 값은 auth.users.last_sign_in_at 에만 있고 **브라우저가 직접 못 읽는다**
-- (auth 스키마는 PostgREST 에 노출되지 않는다). 그래서 이 함수가 필요하다.
--
-- 🔴 이 값의 뜻을 오해하지 말 것 — 「마지막으로 **로그인**한 시각」이다.
--    ① 로그인 상태를 유지한 채 계속 쓰는 사람은 이 값이 안 오른다
--    ② 관리자를 겸한 회원이 **인플루언서 화면에서** 로그인해도 이 값이 오른다
--       (인증 계정이 하나라서 — admins.promoted_at 이 있는 승격 계정)
--    즉 「관리자 화면에 들어온 날」이 아니다. 화면 머리글 툴팁이 이 둘을 말한다.
--
-- 🔴 화면에서 열을 숨기는 것은 보안이 아니다 — 개발자 도구로 그냥 부를 수 있다.
--    그래서 이 함수 안에 is_super_admin() 가드를 두고, 실행 권한도 함께 좁힌다.
--    (가드와 권한은 둘 다 걸어야 한다 — 하나가 뚫려도 나머지가 남게)
--
-- 사양: 기획 설계 2026-09-14(관리자 계정 「최근 로그인」 열)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_admin_last_sign_in()
RETURNS TABLE (
  admin_id          uuid,
  last_sign_in_at   timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 🔴 슈퍼관리자만. 화면 숨김과 별개로 서버가 최종 방어선이다.
  --    ⚠️ 스키마 한정(public.)이 필요한 이유는 **이 함수의 search_path 가 '' 이기 때문**이다
  --       — 검색 경로가 비어 있어 스키마 없이 쓴 이름을 찾을 곳이 없다.
  --       (불리는 쪽 is_super_admin 의 search_path 가 무엇이든 상관없다)
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '관리자 최근 로그인 조회 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ⚠️ admins 기준 왼쪽 결합 — **모든 관리자 행에 대해 한 줄**을 보장한다.
  --    그래야 화면이 「값이 비었다」와 「행이 아예 없다」를 섞지 않는다.
  --    (008 기준 admins.auth_id 는 NULL 을 허용한다 — 연결이 없는 행이 있을 수 있다)
  -- ⚠️ 키는 admins.id 다. auth_id 는 비어 있을 수 있어 키로 못 쓴다.
  RETURN QUERY
    SELECT a.id, u.last_sign_in_at
      FROM public.admins a
      LEFT JOIN auth.users u ON u.id = a.auth_id;
END;
$$;

COMMENT ON FUNCTION public.get_admin_last_sign_in() IS
  '관리자별 마지막 로그인 시각(auth.users.last_sign_in_at). 슈퍼관리자 전용. '
  '⚠️ 「관리자 화면에 들어온 날」이 아니다 — 로그인 유지 시 안 오르고, 승격 계정은 '
  '인플루언서 화면 로그인에도 오른다. 관리자 계정 목록의 「최근 로그인」 열이 쓴다.';

-- 🔴 실행 권한 회수는 **두 방향이 서로를 대신하지 못한다**(CLAUDE.md 「함수 실행 권한」).
--    · Postgres 는 새 함수에 PUBLIC 실행 권한을 준다        → FROM PUBLIC 로 걷는다
--    · Supabase 는 거기 더해 anon·authenticated 에 개별로 준다 → FROM anon, authenticated 로 걷는다
--    ⚠️ 저장소 안에 반쪽짜리 선례가 둘 있다(125 는 PUBLIC 을, 366 은 anon 을 안 걷는다).
--       그것을 베끼지 말 것 — 온전한 것은 375 다.
--    ⚠️ 순서: 회수 먼저, 부여 나중. 반대로 하면 방금 준 것을 다시 걷는다.
-- 🔴 **회수 대상에 service_role 도 넣는다.** Supabase 는 public 스키마의 새 함수에
--    anon·authenticated **와 service_role 까지** 기본 부여한다 — 「안 줬으니 없다」가 아니라
--    「가만 두면 있다」가 맞다. 이 함수는 서버 쪽(메일·배치) 호출자가 0곳이라 남길 이유가 없다.
--    ⚠️ 실측으로 확인하고 넣었다(2026-09-14 개발서버: 회수 전 proacl 에 service_role=X 존재).
--    ⚠️ 회수해도 안전한 이유 — service_role 이 **자기 몫으로** 갖고 있던 것이라,
--       PUBLIC 을 통해서만 갖던 함수를 잘못 끊어 메일을 죽이는 경우와 다르다.
REVOKE ALL     ON FUNCTION public.get_admin_last_sign_in() FROM PUBLIC;
REVOKE ALL     ON FUNCTION public.get_admin_last_sign_in() FROM anon, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_admin_last_sign_in() TO authenticated;
-- ⚠️ anon·service_role 에는 다시 주지 않는다 — 비로그인도 서버 배치도 부를 이유가 없다.

-- PostgREST 가 새 원격 호출 함수를 알아보게 한다. 빠뜨리면 브라우저가 함수를 못 찾는다.
-- ⚠️ COMMIT 앞에 둔다(최근 마이그레이션 417~431 관례). 되돌려지면 알림도 함께 사라진다.
NOTIFY pgrst, 'reload schema';

COMMIT;

/* ────────────────────────────────────────────────────────────
   적용 뒤 확인

   [V1] 함수가 등록됐나 — 1건이어야 한다.
     SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'get_admin_last_sign_in';

   [V2] 🔴 실행 권한 — **두 방향 다** 확인한다. 개발·운영 각각 돌릴 것
        (같은 함수가 서버마다 다른 상태인 사례가 실제로 있었다).
     SELECT has_function_privilege('anon',          'public.get_admin_last_sign_in()', 'execute') AS anon,
            has_function_privilege('authenticated', 'public.get_admin_last_sign_in()', 'execute') AS auth_,
            has_function_privilege('service_role',  'public.get_admin_last_sign_in()', 'execute') AS svc,
            p.proacl::text AS acl
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'get_admin_last_sign_in';
     기대: anon=false · auth_=true · **svc=false** · acl 맨 앞에 「=X/」 가 **없을 것**
     ⚠️ svc 를 빠뜨리고 보면 「안 줬으니 없겠지」로 넘어간다 — Supabase 는 기본으로 준다.
     ⚠️ has_function_privilege 만 보면 어느 방향인지 모른다 — PUBLIC 이 남아 있으면
        로그인·비로그인 둘 다 true 로 나온다. acl 의 맨 앞을 함께 봐야 한다.

   [V3] 실제 호출 — 「적용 성공」은 동작 확인이 아니다.
     SELECT count(*) FROM public.get_admin_last_sign_in();
     기대: 관리자 수와 같다(모든 행에 한 줄 — 로그인한 적 없어도 NULL 로 한 줄).
     ⚠️ SQL 편집기는 서비스 키라 is_super_admin() 분기가 **아예 안 돈다** — 이 조회는
        통과하지만 그것이 가드가 동작한다는 증거가 아니다. 가드 확인은 [V4].

   [V4] 🔴 가드 — **슈퍼가 아닌 계정으로 로그인한 브라우저 콘솔**에서:
        await db.rpc('get_admin_last_sign_in')
     기대: 오류 42501.
     ⚠️ 빈 배열이 오면 가드가 안 도는 것이다. 반드시 오류여야 한다.
     ⚠️ 이 확인은 SQL 편집기로 대체 불가(위 [V3] 주석 참조).
   ──────────────────────────────────────────────────────────── */

-- 롤백: DROP FUNCTION IF EXISTS public.get_admin_last_sign_in();
--   화면은 조회 실패 시 그 열을 안 그리므로, 함수를 지워도 관리자 계정 화면은 정상 동작한다.
