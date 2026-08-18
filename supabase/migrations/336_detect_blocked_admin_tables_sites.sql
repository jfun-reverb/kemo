-- ============================================================
-- 336_detect_blocked_admin_tables_sites.sql
-- 감지 함수에 「아직 읽는 자리 목록」(sites) 추가
--
-- ▶ 왜
--   335 는 자리 **수**(reading_sites)만 돌려주고 **목록**(파일·줄)은 안 돌려준다.
--   그런데 사양서 §3-3 은 그 목록을 「어느 화면이 영향받는지에 가장 가까운 답」이라고
--   못 박았다 — 데이터베이스는 그걸 모르고, 코드 점검만이 아는 정보다.
--   목록이 없으면 관리자 화면 모달이 「이 표가 막혔다」까지만 말하고 **어디를 고쳐야
--   하는지는 영영 못 보여준다**(그 자리가 빈 채로 뜬다).
--
-- ▶ 왜 새 파일인가
--   반환 칸이 늘면 서명이 달라져 CREATE OR REPLACE 로는 못 바꾼다. DROP 후 재생성한다.
--
-- ⚠️ 이 파일이 이 함수의 **현재 유효한 원본**이다(335 아님). 다음에 재정의할 때는
--    파일 번호가 가장 큰 이 정의를 베이스로 삼을 것.
-- ⚠️ 번호 안내 — 334·335·336 사용. 332·333 은 iOS 작업 폴더가 점유 중.
--    다음 사람은 337 부터 쓸 것.
-- ============================================================

DROP FUNCTION IF EXISTS public.detect_blocked_admin_tables();

CREATE OR REPLACE FUNCTION public.detect_blocked_admin_tables()
RETURNS TABLE (
  table_name         text,     -- public 스키마 표 이름
  grade               text,     -- 'A' | 'B' | 'unverified'
  a_reason            text,     -- 'no_policy' | 'no_admin_clause' (A 일 때만, 그 외 NULL)
  has_admin_clause    boolean,  -- 조회 정책에 관리자 판정 함수가 있는가 (후보는 항상 false)
  has_public_clause   boolean,  -- 조회 정책이 전체 공개인가 (후보는 항상 false)
  substitute_view     text,     -- 대체 뷰 이름(있으면), 없으면 NULL
  reading_sites       integer,  -- 334 에 기록된 "코드가 아직 읽는 자리 수"(미확인이면 NULL)
  scanned_at          timestamptz, -- 334 의 마지막 점검 시각(미확인이면 NULL)
  sites               jsonb       -- 아직 읽는 자리 목록 [{file,line,form}] (미확인이면 NULL)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 조회할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH tbl AS (
    -- public 스키마의 "진짜 표"만(뷰·시퀀스 제외) — 가림막 뷰 자신이
    -- 감지 대상이 되지 않게 relkind='r' 로 제한한다.
    -- ⚠️ ::text 캐스팅 필수 — pg_class.relname 은 `name` 형이라, RETURNS TABLE 에
    --    text 로 선언한 칸과 형이 달라 호출 시 42804 로 터진다. 함수를 만드는
    --    구문은 본문의 형을 검사하지 않아 **적용은 성공하고 부를 때 터진다**
    --    (2026-08-18 개발서버에서 실제로 그렇게 났다).
    SELECT c.relname::text AS tname, c.relrowsecurity AS rls_enabled
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
  ),
  pol AS (
    -- 조회(SELECT/ALL) 정책만. tbl 에 LEFT JOIN 하므로 정책이 0개인 표도
    -- 아래 agg 에서 "0개"로 살아남는다(핵심 — pg_policies 에서 시작하지 않음).
    SELECT p.tablename, p.qual
      FROM pg_catalog.pg_policies p
     WHERE p.schemaname = 'public'
       AND p.cmd IN ('SELECT', 'ALL')
  ),
  agg AS (
    SELECT
      t.tname,
      t.rls_enabled,
      count(p.tablename)                                     AS policy_count,
      -- ★ FILTER 가 반드시 있어야 한다 — 이게 없으면 이 장치의 존재 이유가 무너진다.
      --   LEFT JOIN 이라 정책이 0개인 표에도 p.* 가 전부 NULL 인 행이 하나 생긴다.
      --   그 행에서 `p.qual IS NULL` 은 **참**이 되어 has_public_clause 가 true 로 서고,
      --   아래 candidate 의 「전체 공개 조항 없음」 조건에 걸려 **후보에서 통째로 빠진다.**
      --   즉 「조회 정책이 하나도 없는 표」(가장 심하게 막힌 상태)가 「누구나 읽는 정상
      --   표」로 판정된다 — 2026-08-18 기준선 조회가 정확히 같은 이유로 백업 표 3개를
      --   못 봤고(사양서 §1-5-2), 그것을 고치려고 만든 이 함수 안에서 같은 함정이
      --   한 겹 아래서 재현됐다. FILTER 를 빼거나 「간결하게」 정리하지 말 것.
      bool_or(
        p.qual ILIKE '%is_admin%'
        OR p.qual ILIKE '%is_campaign_admin%'
        OR p.qual ILIKE '%is_super_admin%'
        OR p.qual ILIKE '%has_permission%'
      ) FILTER (WHERE p.tablename IS NOT NULL)                AS has_admin_clause_raw,
      bool_or(
        p.qual IS NULL
        OR btrim(p.qual) = 'true'
        OR p.qual ILIKE '%auth.role()%'
        OR p.qual ILIKE '%auth.uid() is not null%'
      ) FILTER (WHERE p.tablename IS NOT NULL)                AS has_public_clause_raw
    FROM tbl t
    LEFT JOIN pol p ON p.tablename = t.tname
    GROUP BY t.tname, t.rls_enabled
  ),
  candidate AS (
    -- 후보 = 행 단위 보안이 켜져 있고, 관리자 통로도 전체 공개 조항도 없음.
    -- ⚠️ 행 보안이 꺼진 표는 "아무나 읽는" 별개 문제라 이 장치 범위 밖(사양서 §1-5-2).
    SELECT
      a.tname,
      a.policy_count,
      COALESCE(a.has_admin_clause_raw, false)  AS has_admin_clause,
      COALESCE(a.has_public_clause_raw, false) AS has_public_clause
    FROM agg a
   WHERE a.rls_enabled = true
     AND COALESCE(a.has_admin_clause_raw, false)  = false
     AND COALESCE(a.has_public_clause_raw, false) = false
  ),
  views_reading AS (
    -- 후보 표를 실제로 읽는 뷰(public 스키마) — pg_depend(카탈로그 테이블)로
    -- 직접 조회한다. information_schema.view_table_usage 를 안 쓰는 이유는
    -- 위 헤더 주석(대체 뷰 판정) 참고 — 그 뷰는 "뷰 소유자에 대한 USAGE
    -- 권한" 필터가 내장돼 있어 함수 소유자와 뷰 소유자가 다르면 조용히
    -- 빈 결과를 낼 수 있다. 아래는 PostgreSQL 이 view_table_usage 를
    -- 만들 때 쓰는 것과 같은 pg_depend 경로를 그대로 쓰되, 그 소유자
    -- 필터(pg_has_role)만 뺀 것이다.
    --   dv: (뷰의 내부 SELECT 규칙) → (그 뷰 자신) 의존 관계(deptype='i')
    --   dt: 같은 규칙(dv.objid=dt.objid) → (그 규칙이 실제로 읽는 표) 의존 관계
    SELECT DISTINCT
      t.relname::text AS base_table,   -- ⚠️ ::text — 위와 같은 이유
      v.relname::text AS view_name
      FROM pg_catalog.pg_namespace nv,
           pg_catalog.pg_class     v,
           pg_catalog.pg_depend    dv,
           pg_catalog.pg_depend    dt,
           pg_catalog.pg_class     t,
           pg_catalog.pg_namespace nt
     WHERE v.relnamespace = nv.oid
       AND v.relkind = 'v'
       AND v.oid = dv.refobjid
       AND dv.refclassid = 'pg_class'::regclass
       AND dv.classid = 'pg_rewrite'::regclass
       AND dv.deptype = 'i'
       AND dv.objid = dt.objid
       AND dv.refobjid <> dt.refobjid
       AND dt.classid = 'pg_rewrite'::regclass
       AND dt.refclassid = 'pg_class'::regclass
       AND dt.refobjid = t.oid
       AND t.relnamespace = nt.oid
       AND t.relkind = 'r'
       AND nv.nspname = 'public'
       AND nt.nspname = 'public'
       AND t.relname IN (SELECT tname FROM candidate)
  ),
  view_admin AS (
    -- 그 뷰의 정의 텍스트에 관리자 판정 함수가 있으면 "관리자 통로가 있는 뷰".
    -- ⚠️ 텍스트 조합 후 ::regclass 캐스팅 대신 pg_class.oid 를 직접 조인한다
    -- (뷰 이름에 식별자 인용이 필요한 경우까지 안전하게 처리하기 위함).
    SELECT DISTINCT
      vr.base_table,
      vr.view_name
    FROM views_reading vr
    JOIN pg_catalog.pg_class vc ON vc.relname = vr.view_name AND vc.relkind = 'v'
    JOIN pg_catalog.pg_namespace vn ON vn.oid = vc.relnamespace AND vn.nspname = 'public'
   WHERE pg_catalog.pg_get_viewdef(vc.oid, true) ILIKE '%is_admin%'
      OR pg_catalog.pg_get_viewdef(vc.oid, true) ILIKE '%is_campaign_admin%'
      OR pg_catalog.pg_get_viewdef(vc.oid, true) ILIKE '%is_super_admin%'
      OR pg_catalog.pg_get_viewdef(vc.oid, true) ILIKE '%has_permission%'
  ),
  substitute AS (
    -- 표 하나에 대체 뷰가 여러 개면 이름순 첫 번째만 대표로 반환
    SELECT base_table, min(view_name) AS view_name
      FROM view_admin
     GROUP BY base_table
  )
  SELECT
    c.tname                                                     AS table_name,
    -- ⚠️ ::text 캐스팅 — 글자 상수만 든 분기는 형이 확정되지 않아(unknown)
    --    RETURNS TABLE 의 text 칸과 안 맞아 42804 가 날 수 있다. 위 relname 과 같은 유형.
    CASE
      WHEN s.table_name IS NULL     THEN 'unverified'
      WHEN sub.view_name IS NOT NULL THEN 'B'
      ELSE 'A'
    END::text                                                    AS grade,
    CASE
      WHEN s.table_name IS NOT NULL AND sub.view_name IS NULL THEN
        CASE WHEN c.policy_count = 0 THEN 'no_policy' ELSE 'no_admin_clause' END
      ELSE NULL
    END::text                                                    AS a_reason,
    c.has_admin_clause,
    c.has_public_clause,
    sub.view_name                                                AS substitute_view,
    s.reading_sites,
    s.scanned_at,
    s.sites
  FROM candidate c
  LEFT JOIN public.admin_table_access_scan s ON s.table_name = c.tname
  LEFT JOIN substitute sub ON sub.base_table = c.tname
  -- ⚠️ 「통과」(행이 있고 reading_sites=0)는 여기서 걸러진다 — 반환하지 않는다.
  WHERE s.table_name IS NULL       -- 미확인: 아직 한 번도 점검 안 함 → 그린다
     OR s.reading_sites > 0        -- 점검했고 아직 읽는 자리가 있음 → A 또는 B
  ORDER BY c.tname;
END;
$$;

COMMENT ON FUNCTION public.detect_blocked_admin_tables() IS
  '[335] 관리자 통로 없는 표 감지(조회 전용). pg_class 표 목록에서 시작해 정책을 '
  'LEFT JOIN 하므로 조회 정책 0개인 표도 놓치지 않는다. 후보 = 관리자 판정 함수 '
  '(is_admin/is_campaign_admin/is_super_admin/has_permission) 도, 전체 공개 조항도 '
  '없는 행 보안 켜진 표. 334(admin_table_access_scan)에 코드 참조 기록이 없으면 '
  'unverified, 기록 있고 0곳이면 통과(반환 안 함), 있으면 대체 뷰 유무로 B/A 판정. '
  '대체 뷰는 이름 규칙이 아니라 pg_depend(소유자 필터 없는 카탈로그 조회) + '
  'pg_get_viewdef 로 실제 의존 관계를 본다. is_admin() 가드. '
  '사양: 2026-08-18-blocked-admin-screen-detection.md §3-3.';

REVOKE ALL ON FUNCTION public.detect_blocked_admin_tables() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.detect_blocked_admin_tables() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL 편집기 — 1단계씩 순서대로. 결과 확인 후 다음 단계)
-- ⚠️ 2단계부터는 SQL 편집기로 재현이 안 된다 — 편집기는 서비스 키 세션이라
--    auth.uid() 가 NULL 이고 is_admin() 이 항상 false → 함수가 RAISE EXCEPTION
--    으로 막힌다(233 등 "postgres 소유자는 GRANT 없이도 호출 가능" 트릭은
--    그쪽이 GRANT 기반 차단이라 통하는 것이고, 여기는 함수 본문 코드로 막는
--    것이라 소유자 우회가 안 통한다 — 277 과 동일한 제약).
--    반드시 관리자로 로그인한 브라우저의 개발자 콘솔에서 확인할 것:
--      await db.rpc('detect_blocked_admin_tables').then(r => console.table(r.data))
--    (db 는 dev/lib/supabase.js 가 만든 전역 Supabase 클라이언트)
-- ============================================================
--
-- [1] 함수 존재·시그니처
-- SELECT proname, prosecdef, provolatile, pronargs
--   FROM pg_proc
--  WHERE proname = 'detect_blocked_admin_tables' AND pronamespace = 'public'::regnamespace;
-- → prosecdef=true, provolatile='s'(STABLE), pronargs=0
--
-- [2] 관리자로 로그인한 브라우저에서 (334 표가 비어 있는 상태 그대로):
--   await db.rpc('detect_blocked_admin_tables').then(r => console.table(r.data))
-- → ⚠️ 「influencers 1건만」이 아니다. 334 표가 비어 있으면(= 한 번도 점검 안
--   함) influencers 뿐 아니라 조회 정책이 0개인 백업 표 3개(backup_campaigns_
--   20260617 · backup_cch_20260617 · backup_deliverables_20260617)도 후보라
--   함께 unverified 로 떠야 한다 — **총 4건**, 전부 grade='unverified',
--   reading_sites=null, scanned_at=null. (사양서 §3-3 "안 돌리면 백업 3개까지
--   「미확인」으로 떠 첫날 4건이 된다"와 정합)
--   4건 중 하나라도 안 뜨면 agg 의 FILTER(WHERE p.tablename IS NOT NULL) 가
--   빠졌다는 뜻이다 — 정책 0개인 표가 LEFT JOIN 의 합성 NULL 행 때문에
--   "전체 공개"로 잘못 읽혀 후보에서 통째로 빠지는 결함이 재발한 것이다.
-- → campaigns·event_slots·faq_nodes·lookup_values 는 (334 상태와 무관하게)
--   전혀 안 나와야 한다(규칙 2 로 자동 통과 — 이건 후보 자체가 아니므로
--   334 가 비어 있든 채워지든 영향 없음)
--
-- [3] 작업 2(검사 스크립트, ㉯ 모드)를 1회 돌려 334 표에 결과가 기록된 뒤 재호출:
--   await db.rpc('detect_blocked_admin_tables').then(r => console.table(r.data))
-- → backup_campaigns_20260617 · backup_cch_20260617 · backup_deliverables_20260617
--   3개는 결과에서 사라져야 한다(코드 참조 0곳 → 통과로 빠짐, 334 에 행은
--   생겼지만 reading_sites=0). ⚠️ 이 셋이 grade='A' 로 뜨면 코드 참조 게이트가
--   안 걸린 것이다(위 [2]와 같은 결함군).
-- → influencers 는 grade 가 'B'(대체 뷰 influencers_admin_view 존재 + 코드가
--   아직 원본 표를 읽는 자리가 남아 있으면) 또는 목록에서 사라짐(통과, 코드가
--   더 이상 원본 표를 안 읽으면)으로 바뀌어야 한다. 이 시점부터 결과가
--   4건→1건 이하로 줄어드는 것이 정상이다.
--
-- [4] 관리자 아닌 계정(또는 비로그인)으로 같은 호출을 하면 42501 로 거부되는지
--   await db.rpc('detect_blocked_admin_tables')
-- → error.code === '42501' 이어야 한다
-- ============================================================
