-- ============================================================
-- 406. 리포트 한 건 읽기에 「만든 사람」을 함께 담는다
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 9」
--
-- 무엇이 문제였나 — 405 가 목록(`list_campaign_reports`)에는 만든 사람을 담았는데
-- **한 건 읽기(`get_campaign_report`)에는 안 담았다.** 그래서 리포트를 열면 머리말이
-- 「만든 사람 -」로 비었다. 목록에서는 이름이 보이고 열면 사라지니 더 헷갈린다.
-- 2026-09-03 개발서버 브라우저에서 눈으로 발견.
--
-- ⚠️ **이런 종류는 코드를 읽어서는 안 보인다** — 두 함수가 서로 다른 칸을 담는 것은
--    문법 오류도 아니고 조회 실패도 아니다. 화면을 열어야 빈칸이 보인다.
--
-- 🔴 **`CREATE OR REPLACE`** 로 고친다. `DROP` 후 `CREATE` 면 403 이 건 회수
--    (PUBLIC·anon **두 방향**)가 함께 풀린다 — 387 에서 실제로 밟은 함정이다.
--    시그니처(`uuid` 한 개)는 그대로 둔다.
--
-- ⚠️ 베이스는 **403** 이다(405 는 이 함수를 안 건드렸다). 반환 열쇠말 둘만 는다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_campaign_report(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
  IF NOT public.has_permission('menu.reports', 'read') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',              r.id,
    'title',           r.title,
    'created_by',      r.created_by,
    -- 405 가 심은 이름 스냅샷. created_by 는 ON DELETE SET NULL 이라
    -- 관리자를 지우면 고유번호는 비지만 이 이름은 남는다.
    'created_by_name', r.created_by_name,
    'created_at',      r.created_at,
    'updated_at',      r.updated_at,
    'include_audit',   r.include_audit,
    'version',         r.version,
    'campaigns',       coalesce((
       SELECT jsonb_agg(jsonb_build_object(
                'campaign_id',    rc.campaign_id,
                'campaign_no',    rc.campaign_no,
                'campaign_title', rc.campaign_title,
                'sort_order',     rc.sort_order,
                -- 🔴 원본이 지워졌는지 화면이 알아야 한다 — 글자만 남은 줄은 그렇게 표시한다
                'campaign_exists', (rc.campaign_id IS NOT NULL)
              ) ORDER BY rc.sort_order)
         FROM public.campaign_report_campaigns rc
        WHERE rc.report_id = r.id), '[]'::jsonb)
  ) INTO v_out
  FROM public.campaign_reports r
  WHERE r.id = p_report_id;

  RETURN v_out;   -- 없는 고유번호면 NULL — 화면이 「없음」으로 그린다
END;
$$;

COMMENT ON FUNCTION public.get_campaign_report(uuid) IS
  '[406, 베이스 403] 리포트 1건 + 만든 사람 + 담긴 캠페인 목록. 결과물은 화면이 따로 조회한다. '
  'campaign_exists 로 원본이 지워진 줄을 구분한다. 없는 고유번호는 NULL.';

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 권한이 그대로인가 — 🔴 여기가 true·true 로 나오면 CREATE OR REPLACE 가 아니라
--      DROP 후 CREATE 가 돌아 403 의 회수가 풀린 것이다. 403 의 REVOKE 를 다시 실행할 것.
SELECT (p.proacl::text LIKE '{=X/%')                            AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='get_campaign_report';
-- 기대: false · false · true

-- [V2] 🔴 **실제 로그인한 관리자 브라우저 콘솔에서** — SQL 편집기는 has_permission
--      분기를 재현하지 못한다(서비스 키에 로그인 사용자가 없다).
--
--   const camp = (await db.from('campaigns').select('id').limit(1)).data.map(c => c.id);
--   const { data: id } = await db.rpc('create_campaign_report',
--       { p_title: '[검증] 만든 사람', p_campaign_ids: camp, p_include_audit: false });
--   const r = (await db.rpc('get_campaign_report', { p_report_id: id })).data;
--   console.log(r.created_by_name, r.created_by);   // 기대: 내 이름 · 내 고유번호
--   await db.rpc('delete_campaign_report', { p_report_id: id });   // 뒷정리

*/


-- ============================================================
-- 롤백
-- ============================================================
-- 403 의 get_campaign_report 정의를 다시 실행한다(CREATE OR REPLACE).
