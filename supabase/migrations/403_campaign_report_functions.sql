-- ============================================================
-- 403. 캠페인 리포트 — 만들기·읽기·지우기 함수 (1-A 몫만)
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 2」
--
-- ⚠️ **구성 변경(캠페인 추가·제거)은 여기 넣지 않는다** — 2단계 몫이다.
--    낙관적 잠금(`version`)이 필요한 것도 그때다.
--
-- 🔴 셋 다 권한 가드가 있어 **SQL 편집기로는 재현되지 않는다** — 편집기는 서비스 키라
--    `auth.uid()` 가 없고 `has_permission` 이 그 분기를 안 탄다(272·332·398 과 같은 함정).
--    **실제 로그인한 브라우저 콘솔에서 한 번씩 불러 봐야** 자료형 불일치(42804)·
--    컬럼 모호성(42702) 같은, 첫 호출에서만 드러나는 것이 걸린다.
-- ============================================================

-- ------------------------------------------------------------
-- 만들기
--   ⚠️ 캠페인 번호·제목을 **만드는 시점의 값으로 함께 저장**한다(402 참조).
--   ⚠️ 넘겨받은 배열 순서를 sort_order 로 그대로 쓴다 — 화면에서 고른 순서가 곧 표의 순서다.
--   ⚠️ 존재하지 않는 캠페인 고유번호가 섞이면 **그 줄만 조용히 빠지는 것이 아니라** 거부한다.
--      리포트는 「무엇을 담았나」가 전부라 조용히 빠지면 나중에 알 수 없다.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_campaign_report(
  p_title         text,
  p_campaign_ids  uuid[],
  p_include_audit boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_report_id uuid;
  v_found     integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  IF coalesce(btrim(p_title), '') = '' THEN
    RAISE EXCEPTION '리포트 제목이 필요합니다' USING ERRCODE = '22023';
  END IF;

  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RAISE EXCEPTION '캠페인을 하나 이상 골라 주세요' USING ERRCODE = '22023';
  END IF;

  -- 넘어온 고유번호가 전부 실재하는지 — 하나라도 없으면 거부한다
  SELECT count(*) INTO v_found
    FROM public.campaigns c
   WHERE c.id = ANY(p_campaign_ids);
  IF v_found <> cardinality(p_campaign_ids) THEN
    RAISE EXCEPTION '없는 캠페인이 섞여 있습니다 (요청 %건 중 %건만 확인)',
      cardinality(p_campaign_ids), v_found USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.campaign_reports (title, created_by, include_audit)
  VALUES (btrim(p_title), auth.uid(), coalesce(p_include_audit, false))
  RETURNING id INTO v_report_id;

  INSERT INTO public.campaign_report_campaigns
    (report_id, campaign_id, campaign_no, campaign_title, sort_order)
  SELECT v_report_id, c.id, c.campaign_no, c.title, x.ord - 1
    FROM unnest(p_campaign_ids) WITH ORDINALITY AS x(cid, ord)
    JOIN public.campaigns c ON c.id = x.cid;

  RETURN v_report_id;
END;
$$;

COMMENT ON FUNCTION public.create_campaign_report(text, uuid[], boolean) IS
  '[403] 리포트 생성. 캠페인 번호·제목을 글자로 함께 보관하고, 고른 순서를 sort_order 로 남긴다. '
  '없는 캠페인이 섞이면 조용히 빼지 않고 거부한다.';


-- ------------------------------------------------------------
-- 한 건 읽기
--   ⚠️ **결과물은 여기서 안 담는다** — 화면이 따로 조회한다(사양서 결정).
--      여기 담으면 리포트 하나가 수천 행을 한 덩어리로 끌고 온다.
-- ------------------------------------------------------------
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
    'id',            r.id,
    'title',         r.title,
    'created_at',    r.created_at,
    'updated_at',    r.updated_at,
    'include_audit', r.include_audit,
    'version',       r.version,
    'campaigns',     coalesce((
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
  '[403] 리포트 1건 + 담긴 캠페인 목록. 결과물은 화면이 따로 조회한다. '
  'campaign_exists 로 원본이 지워진 줄을 구분한다. 없는 고유번호는 NULL.';


-- ------------------------------------------------------------
-- 지우기
--   ⚠️ 연결 표는 `ON DELETE CASCADE` 라 함께 사라진다(402).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_campaign_report(p_report_id uuid)
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

  DELETE FROM public.campaign_reports WHERE id = p_report_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;   -- 이미 없으면 false — 오류로 만들지 않는다(두 번 눌러도 같은 결과)
END;
$$;

COMMENT ON FUNCTION public.delete_campaign_report(uuid) IS
  '[403] 리포트 삭제. 연결 표는 CASCADE 로 함께 사라진다. 이미 없으면 false(멱등).';


-- ------------------------------------------------------------
-- 실행 권한
--   🔴 새 함수는 기본으로 PUBLIC 이 붙고 Supabase 가 anon 에도 개별로 준다.
--      두 방향은 서로를 대신하지 못한다(369·370·375).
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_campaign_report(text, uuid[], boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_campaign_report(text, uuid[], boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_campaign_report(text, uuid[], boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.get_campaign_report(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_campaign_report(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_campaign_report(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_campaign_report(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_campaign_report(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_campaign_report(uuid) TO authenticated;


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
   AND p.proname IN ('create_campaign_report','get_campaign_report','delete_campaign_report')
 ORDER BY p.proname;
-- 기대: 셋 다 false · false · true

-- [V2] 🔴 **실제 로그인한 관리자 브라우저 콘솔에서** 세 함수를 한 번씩 부른다.
--      「적용 Success」는 검증이 아니다 — 자료형 불일치는 첫 호출에서만 드러난다.
--
--   const camp = (await db.from('campaigns').select('id').limit(2)).data.map(c => c.id);
--   const { data: id, error: e1 } = await db.rpc('create_campaign_report',
--       { p_title: '시험 리포트', p_campaign_ids: camp, p_include_audit: false });
--   console.log('만들기', id, e1);
--   console.log('읽기',  (await db.rpc('get_campaign_report', { p_report_id: id })).data);
--   console.log('지우기',(await db.rpc('delete_campaign_report', { p_report_id: id })).data);
--   console.log('다시 지우기(false 여야 함)',
--       (await db.rpc('delete_campaign_report', { p_report_id: id })).data);
--
-- [V3] 캠페인 매니저 계정에서 만들기가 거부되는지 (42501)

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.create_campaign_report(text, uuid[], boolean);
-- DROP FUNCTION IF EXISTS public.get_campaign_report(uuid);
-- DROP FUNCTION IF EXISTS public.delete_campaign_report(uuid);
