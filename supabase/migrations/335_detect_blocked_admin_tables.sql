-- ============================================================
-- 335_detect_blocked_admin_tables.sql
-- 「조용히 죽는 관리자 화면」 감지 장치 — 작업 1 (②감지 함수)
-- 사양: docs/specs/2026-08-18-blocked-admin-screen-detection.md §3-3
-- 작업표: docs/specs/2026-08-18-blocked-admin-screen-detection-breakdown.md 작업 1
-- 선례: 277_detect_channel_code_drift.sql (구조를 그대로 따름 — 조회 전용,
--       SECURITY DEFINER + search_path='' + is_admin() 가드 + 표 형태 반환)
--
-- ▶ 왜 필요한가
--   마이그레이션 312(2026-08-07 운영)가 influencers 원본 표의 「관리자면 통과」
--   조회 정책을 지우고 가림막 뷰로 갈아타게 했는데, 고칠 자리 목록을
--   `.from('influencers')` 글자 검색으로만 만들어 관리자 화면 4곳이 조용히
--   죽었다(오류가 아니라 빈 결과라 오류 로그·정적 리뷰 어디에도 안 남는다).
--   이 함수는 "관리자 통로가 없는 표가 또 생겼는가"를 사람이 찾아 나서지
--   않아도 부팅 시 자동으로 드러낸다(사양서 §1-4 선례 원칙 ②).
--
-- ▶ 판정 규칙 — 순서가 중요하다 (사양서 §3-3)
--
--   후보 = 관리자 통로도, 전체 공개 조항도 없음
--          (⚠️ 조회 정책이 0개인 표도 여기 들어온다)
--     │
--     ├─ 334(admin_table_access_scan)에 이 표 행이 없다  → unverified (그린다)
--     ├─ 행이 있고 reading_sites = 0                     → 통과 (반환 안 함)
--     └─ 읽는 자리가 있다 ┬ 대체 뷰 있음                  → B
--                        └ 대체 뷰 없음                  → A
--
--   규칙 1(관리자 조항): 조회 정책 조건에 is_admin·is_campaign_admin·
--     is_super_admin·has_permission 네 가지 중 하나
--   규칙 2(전체 공개): 조건이 true 이거나 로그인 여부만 보는 것
--
-- ▶ ⚠️ pg_policies 에서 시작하면 안 된다 (사양서 §1-5-2 ㄷ)
--   pg_policies 를 표별로 묶으면 「정책이 하나도 없는 표」가 목록에 아예
--   안 나온다 — 그런데 그게 가장 심하게 막힌 상태다(관리자조차 못 읽는다).
--   그래서 아래 구현은 **pg_class 의 표 목록에서 시작해 정책을 LEFT JOIN**
--   한다. 이래야 정책 0개인 표가 「0개」로 살아남는다.
--   ⚠️ relkind='r' 로 뷰를 제외한다 — 가림막 뷰 자신이 감지 대상이 되면 안 된다.
--
-- ▶ ⚠️ 「코드가 읽는 자리 0곳이면 통과」 게이트를 A 에도 건다
--   운영에 조회 정책이 0개인 백업 표 3개(backup_campaigns_20260617 등,
--   2026-06-17 캠페인 복원 작업 때 만든 것)가 있는데 전부 코드 참조 0곳이다.
--   이 게이트가 없으면 그 3개가 영원히 안 없어지는 빨간 경고가 되어, 이
--   장치가 막으려던 실패(늘 빨간 게 있어 아무도 안 봄)를 장치 자신이
--   재현한다. **이름(backup_ 접두사)으로 거르지 않는다** — 이름은 언제든
--   달라진다. 나중에 그 백업 표를 읽는 코드가 생기면 그 순간부터 자동으로
--   경고가 켜진다(코드 참조 게이트가 미래에도 맞는 이유).
--
-- ▶ 행 단위 보안이 꺼진 표는 이 장치의 범위 밖 (사양서 §1-5-2)
--   「관리자가 못 읽는」 문제가 아니라 「아무나 읽는」 문제라 성격이 반대다.
--   relrowsecurity = false 인 표는 후보에서 아예 제외한다(별개 감사 대상).
--
-- ▶ 대체 뷰 판정 — 이름 규칙이 아니라 데이터베이스 의존 관계로
--   pg_depend(카탈로그 테이블)로 그 표를 실제로 읽는 뷰를 찾고, 그 뷰의
--   정의(pg_get_viewdef)에 관리자 판정 함수가 있는지 본다.
--   ⚠️ 이 저장소의 가림막 뷰(influencers_admin_view, 마이그레이션 312)는
--   `security_invoker = false` 뷰라 자체 RLS 정책이 아니라 **뷰 정의 SQL의
--   WHERE 절 자체**에 관리자 판정을 박아 넣는 방식이다. 그래서 뷰의
--   pg_policies 가 아니라 뷰 정의 텍스트(pg_get_viewdef)를 봐야 한다.
--   ⚠️ 이름 규칙(`_admin_view` 접미사)으로 판정하지 않는다 — 이름은 언제든
--   달라진다.
--   ⚠️ information_schema.view_table_usage 대신 pg_depend 로 직접 조회하는
--   이유(리뷰 지적으로 교체, 2026-08-18) — view_table_usage 는 정의 자체에
--   `pg_has_role(뷰소유자, 'USAGE')` 필터가 박혀 있다. 이 함수는 SECURITY
--   DEFINER 로 돌아 "현재 사용자"가 함수 소유자로 바뀌는데, 그 소유자가
--   대체 뷰의 소유자와 다른 역할이면(예: 나중에 다른 배포 계정으로 마이그를
--   적용하면) 필터에 걸려 **조용히 빈 결과**를 낸다 — 그러면 실제로 대체
--   뷰가 있는데도 substitute_view 가 NULL 이 되어 B 가 아니라 A 로 잘못
--   뜬다. pg_depend·pg_rewrite·pg_class·pg_namespace 는 카탈로그 테이블이라
--   그런 소유자 필터가 없다(누가 조회하든 항상 보인다) — "누가 만들었나"에
--   기대지 않는 판정을 위해 이쪽을 쓴다.
--
-- ▶ A 등급 사유 2종(등급은 안 늘림, 모달 안내만 갈린다)
--   no_policy       — 조회 정책이 하나도 없다(관리자는 물론 본인 행도 못 읽음)
--   no_admin_clause — 조회 정책은 있는데 관리자 통로가 없다
--
-- ▶ 「통과」는 반환하지 않는다 — 화면이 0건이면 아무것도 안 그리므로
--   (선례 원칙 ①), 통과 행을 결과에 섞으면 화면 쪽에서 또 걸러내야 한다.
--   함수 자체가 걸러서 반환한다.
--
-- ▶ 권한 — is_admin()(관리자 전원, 사양서 §5 ⑤ 확정). 조회 전용이라
--   쓰기 부작용 없음.
--
-- ▶ 개인정보 — 표 이름·정책 구성만 반환한다. 행 데이터·인플루언서 정보는
--   전혀 다루지 않는다.
--
-- ▶ 롤백
--   DROP FUNCTION IF EXISTS public.detect_blocked_admin_tables();
--
-- ⚠️ 번호 안내 — 334·335 사용. 332·333 은 iOS 작업 폴더(feature/ios-app)가
--    푸시 알림용으로 점유 중이라 비워 두었다(dev 의 332 는 일별 방문자수로 별개).
--    다음 사람은 336 부터 쓸 것.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.detect_blocked_admin_tables()
RETURNS TABLE (
  table_name         text,     -- public 스키마 표 이름
  grade               text,     -- 'A' | 'B' | 'unverified'
  a_reason            text,     -- 'no_policy' | 'no_admin_clause' (A 일 때만, 그 외 NULL)
  has_admin_clause    boolean,  -- 조회 정책에 관리자 판정 함수가 있는가 (후보는 항상 false)
  has_public_clause   boolean,  -- 조회 정책이 전체 공개인가 (후보는 항상 false)
  substitute_view     text,     -- 대체 뷰 이름(있으면), 없으면 NULL
  reading_sites       integer,  -- 334 에 기록된 "코드가 아직 읽는 자리 수"(미확인이면 NULL)
  scanned_at          timestamptz -- 334 의 마지막 점검 시각(미확인이면 NULL)
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
    SELECT c.relname AS tname, c.relrowsecurity AS rls_enabled
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
      t.relname AS base_table,
      v.relname AS view_name
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
    CASE
      WHEN s.table_name IS NULL     THEN 'unverified'
      WHEN sub.view_name IS NOT NULL THEN 'B'
      ELSE 'A'
    END                                                          AS grade,
    CASE
      WHEN s.table_name IS NOT NULL AND sub.view_name IS NULL THEN
        CASE WHEN c.policy_count = 0 THEN 'no_policy' ELSE 'no_admin_clause' END
      ELSE NULL
    END                                                          AS a_reason,
    c.has_admin_clause,
    c.has_public_clause,
    sub.view_name                                                AS substitute_view,
    s.reading_sites,
    s.scanned_at
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
