-- ============================================================
-- 408. 리포트 읽기에 연결 표의 줄 고유번호(row_id)를 함께 담는다
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 17·18」
--
-- 왜 필요한가 — 407 의 `remove_report_campaign` 이 **연결 표의 `id`** 로 지목한다.
--   🔴 `campaign_id` 로 받지 않은 이유: 원본이 지워진 줄은 그 값이 **NULL** 이라
--      지목할 수단이 없다. 그런데 정작 빼고 싶은 것이 그런 줄이다.
--   그런데 읽기 함수가 그 `id` 를 안 돌려줘서 **화면이 뺄 대상을 지목할 수 없었다.**
--
-- ⚠️ 405·406 과 같은 유형의 빠뜨림이다 — 「함수는 만들었는데 화면이 그것을 부를
--    재료를 못 받는다」. 만들 때 **부르는 쪽이 무엇을 갖고 있는지** 함께 볼 것.
--
-- 🔴 **`CREATE OR REPLACE`** — `DROP` 후 `CREATE` 면 403 의 회수가 함께 풀린다(387).
-- ⚠️ 베이스는 **406** 이다(403 아님 — 406 이 만든 사람 두 칸을 더했다).
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
    'created_by_name', r.created_by_name,
    'created_at',      r.created_at,
    'updated_at',      r.updated_at,
    'include_audit',   r.include_audit,
    'version',         r.version,
    'campaigns',       coalesce((
       SELECT jsonb_agg(jsonb_build_object(
                -- 408: 연결 표의 줄 고유번호. 화면이 「이 줄을 뺀다」를 지목할 때 쓴다.
                --      원본이 지워져 campaign_id 가 NULL 인 줄도 이것으로 지목된다.
                'row_id',         rc.id,
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
  '[408, 베이스 406] 리포트 1건 + 만든 사람 + 담긴 캠페인 목록(연결 줄 고유번호 row_id 포함). '
  '결과물은 화면이 따로 조회한다. campaign_exists 로 원본이 지워진 줄을 구분한다. 없는 고유번호는 NULL.';

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 권한이 그대로인가 — 🔴 true·true 면 회수가 풀린 것이다(403 의 REVOKE 재실행)
SELECT (p.proacl::text LIKE '{=X/%')                            AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='get_campaign_report';
-- 기대: false · false · true

-- [V2] 로그인한 관리자 브라우저 콘솔에서 row_id 가 오는지
--   const r = (await db.rpc('get_campaign_report',{p_report_id:'<리포트id>'})).data;
--   console.log(r.campaigns.map(c => c.row_id));   // 기대: 전부 uuid, NULL 없음

*/


-- ============================================================
-- 롤백
-- ============================================================
-- 406 의 get_campaign_report 정의를 다시 실행한다(CREATE OR REPLACE).
