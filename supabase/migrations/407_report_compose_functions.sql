-- ============================================================
-- 407. 리포트 구성 바꾸기 — 캠페인 추가·빼기 · 제목 고치기
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 17」
--
-- 🔴 **작업표의 순서와 다르게 먼저 만든다.** 작업표는 작업 16(외부 첨부 합치기) 뒤로
--    두었으나, 사용자가 「만든 뒤 캠페인을 못 바꾸는 것」을 먼저 물어 앞당겼다
--    (2026-09-03 사용자 지시).
--    ⚠️ 그래서 이 파일에는 **`remove_report_source` 를 안 넣었다** — 그 표
--       (`campaign_report_sources`)가 아직 없다. 작업 12~16 때 별도 파일로 더한다.
--
-- ⚠️ 작업표 경고 「1단계 마이그레이션에 미리 묶지 않는다」는 **지켰다** —
--    402~406(1-A)과 별도 파일이라, 1-A 만 운영에 올리고 이 파일은 안 올릴 수 있다.
--    🔴 **운영에 올릴 때 어느 파일까지 올리는지 사람이 정한다.**
--
-- ⚠️ 셋 다 `updated_at` 을 갱신한다 — 목록의 「마지막 고친 날」이 그 값이다.
--    안 갱신하면 바꿔도 목록이 그대로라 아무도 바뀐 걸 모른다.
--    (표에 붙은 `touch_campaign_report_updated_at` 트리거가 자동으로 한다 —
--     `campaign_reports` 행을 UPDATE 할 때만. 연결 표만 고치면 안 도므로
--     캠페인 추가·빼기는 **본체 행도 함께 건드린다**.)
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- ① 캠페인 추가
--    ⚠️ 이미 담긴 캠페인은 **조용히 건너뛴다**(오류로 만들지 않는다) —
--       고르는 화면이 이미 담긴 것을 빼고 보여주지만, 두 사람이 동시에 넣으면
--       겹칠 수 있다. 그때 통째로 실패시키면 나머지도 안 들어간다.
--    🔴 다만 **없는 캠페인은 거부**한다 — 403 의 만들기와 같은 규칙이다.
--       조용히 빼면 「넣었는데 안 들어간」 것을 아무도 모른다.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_report_campaigns(
  p_report_id    uuid,
  p_campaign_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_found    integer;
  v_added    integer;
  v_next     integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.campaign_reports WHERE id = p_report_id) THEN
    RAISE EXCEPTION '없는 리포트입니다' USING ERRCODE = '22023';
  END IF;

  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RAISE EXCEPTION '캠페인을 하나 이상 골라 주세요' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_found FROM public.campaigns c WHERE c.id = ANY(p_campaign_ids);
  IF v_found <> cardinality(p_campaign_ids) THEN
    RAISE EXCEPTION '없는 캠페인이 섞여 있습니다 (요청 %건 중 %건만 확인)',
      cardinality(p_campaign_ids), v_found USING ERRCODE = '22023';
  END IF;

  -- 새로 붙는 것은 기존 순서 뒤에 이어 놓는다
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_next
    FROM public.campaign_report_campaigns WHERE report_id = p_report_id;

  WITH ins AS (
    INSERT INTO public.campaign_report_campaigns
      (report_id, campaign_id, campaign_no, campaign_title, sort_order)
    SELECT p_report_id, c.id, c.campaign_no, c.title, v_next + (x.ord - 1)
      FROM unnest(p_campaign_ids) WITH ORDINALITY AS x(cid, ord)
      JOIN public.campaigns c ON c.id = x.cid
     WHERE NOT EXISTS (
       SELECT 1 FROM public.campaign_report_campaigns rc
        WHERE rc.report_id = p_report_id AND rc.campaign_id = c.id)
    RETURNING 1
  )
  SELECT count(*) INTO v_added FROM ins;

  -- 본체 행을 건드려 updated_at 트리거를 태운다(연결 표만 고치면 안 돈다)
  UPDATE public.campaign_reports SET version = version + 1 WHERE id = p_report_id;

  RETURN v_added;   -- 실제로 더해진 개수. 0 이면 전부 이미 담겨 있던 것
END;
$$;

COMMENT ON FUNCTION public.add_report_campaigns(uuid, uuid[]) IS
  '[407] 리포트에 캠페인을 더한다. 이미 담긴 것은 건너뛰고, 없는 캠페인은 거부한다. 실제로 더해진 개수를 돌려준다.';

-- ------------------------------------------------------------
-- ② 캠페인 빼기
--    ⚠️ **마지막 한 개는 못 뺀다.** 캠페인이 0개인 리포트는 표가 통째로 비어
--       무엇을 담았던 것인지 알 수 없게 된다. 지우려면 리포트를 지운다.
--    ⚠️ 원본이 지워져 글자만 남은 줄도 뺄 수 있어야 한다 → **연결 표의 id 로 받는다**
--       (`campaign_id` 로 받으면 그 값이 NULL 인 줄을 지목할 수 없다).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_report_campaign(
  p_report_id uuid,
  p_row_id    uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_left integer;
  v_n    integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_left
    FROM public.campaign_report_campaigns WHERE report_id = p_report_id;

  IF v_left <= 1 THEN
    RAISE EXCEPTION '마지막 캠페인은 뺄 수 없습니다. 리포트를 지워 주세요'
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.campaign_report_campaigns
   WHERE id = p_row_id AND report_id = p_report_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 THEN
    UPDATE public.campaign_reports SET version = version + 1 WHERE id = p_report_id;
  END IF;

  RETURN v_n > 0;   -- 이미 없으면 false — 오류로 만들지 않는다(두 번 눌러도 같은 결과)
END;
$$;

COMMENT ON FUNCTION public.remove_report_campaign(uuid, uuid) IS
  '[407] 리포트에서 캠페인 한 줄을 뺀다. 마지막 한 개는 거부한다. 연결 표의 id 로 지목하므로 원본이 지워진 줄도 뺄 수 있다.';

-- ------------------------------------------------------------
-- ③ 제목 고치기
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_report_title(
  p_report_id uuid,
  p_title     text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  IF coalesce(btrim(p_title), '') = '' THEN
    RAISE EXCEPTION '리포트 제목이 필요합니다' USING ERRCODE = '22023';
  END IF;

  UPDATE public.campaign_reports
     SET title = btrim(p_title)
   WHERE id = p_report_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN v_n > 0;
END;
$$;

COMMENT ON FUNCTION public.update_report_title(uuid, text) IS
  '[407] 리포트 제목을 고친다. 빈 제목은 거부. updated_at 은 표 트리거가 갱신한다.';

-- ------------------------------------------------------------
-- ④ 실행 권한 — 신규 함수는 두 방향 모두 회수한다(369·370·375)
--    🔴 `REVOKE ALL FROM PUBLIC` 과 `FROM anon` 은 **서로를 대신하지 못한다.**
--       Postgres 는 새 함수에 PUBLIC 을, Supabase 는 거기 더해 anon·authenticated 에
--       개별로 권한을 준다.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.add_report_campaigns(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_report_campaigns(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.add_report_campaigns(uuid, uuid[]) TO authenticated;

REVOKE ALL ON FUNCTION public.remove_report_campaign(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_report_campaign(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_report_campaign(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.update_report_title(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_report_title(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_report_title(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 권한 — 셋 다 비로그인 차단 · 로그인 허용
SELECT p.proname,
       (p.proacl::text LIKE '{=X/%')                            AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public'
   AND p.proname IN ('add_report_campaigns','remove_report_campaign','update_report_title')
 ORDER BY p.proname;
-- 기대: 셋 다 false · false · true

-- [V2] 🔴 **실제 로그인한 관리자 브라우저 콘솔에서** — SQL 편집기는 has_permission
--      분기를 재현하지 못한다(서비스 키에 로그인 사용자가 없다).
--
--   const camps = (await db.from('campaigns').select('id').limit(3)).data.map(c=>c.id);
--   const { data: id } = await db.rpc('create_campaign_report',
--       { p_title:'[검증] 구성 변경', p_campaign_ids: camps.slice(0,1), p_include_audit:false });
--   console.log('더하기', (await db.rpc('add_report_campaigns',
--       { p_report_id:id, p_campaign_ids: camps.slice(1) })).data);          // 기대 2
--   console.log('이미 담긴 것 또 더하기', (await db.rpc('add_report_campaigns',
--       { p_report_id:id, p_campaign_ids: camps.slice(1) })).data);          // 기대 0
--   const r = (await db.rpc('get_campaign_report',{p_report_id:id})).data;
--   console.log('빼기', (await db.rpc('remove_report_campaign',
--       { p_report_id:id, p_row_id: r.campaigns[2].row_id })).data);         // 기대 true
--   console.log('제목', (await db.rpc('update_report_title',
--       { p_report_id:id, p_title:'[검증] 바뀐 제목' })).data);               // 기대 true
--   await db.rpc('delete_campaign_report', { p_report_id: id });   // 뒷정리
--
-- ⚠️ 위 [V2] 는 `get_campaign_report` 가 연결 표의 `row_id` 를 돌려줘야 돈다 — 408 에서 더한다.

-- [V3] 마지막 한 개는 못 뺀다 (캠페인 1개짜리 리포트에서 remove → 22023)

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.add_report_campaigns(uuid, uuid[]);
-- DROP FUNCTION IF EXISTS public.remove_report_campaign(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.update_report_title(uuid, text);
