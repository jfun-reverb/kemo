-- ============================================================
-- 410. 외부 첨부 저장·갱신·제거 함수 + 목록에 첨부 수
-- ============================================================
-- 작업표: 「작업 13」 (+ 작업 17 에서 미룬 remove_report_source)
--
-- 🔴 첨부 1건 + 행 N개를 **한 함수 안에서** 넣는다 — 중간에 끊기면 「첨부는 있는데
--    행이 반만」이 되므로 트랜잭션 하나여야 한다(함수 본문이 곧 트랜잭션이다).
-- 🔴 같은 소스에 다시 부르면 **지우고 새로 넣는다**(누적 금지) — 갱신은 덮어쓰기다.
-- ============================================================

BEGIN;

-- 공용: jsonb 배열 → ext_rows. 부르는 쪽이 이미 source 행을 잠그고 있다.
--   ⚠️ 칸 이름은 파서 출력(report-parsers.js)과 글자 그대로 같다. 하나라도 어긋나면
--      그 칸이 조용히 NULL 이 된다 — 오류가 아니다.
CREATE OR REPLACE FUNCTION public._insert_report_ext_rows(p_source_id uuid, p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_n integer;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION '행 배열이 필요합니다' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.campaign_report_ext_rows
    (source_id, member_no, account_id, mission_status, order_no, purchase_amount,
     receipt_url, receipt_at, review_kind, qoo10_urls, qoo10_at, cosme_urls, cosme_at)
  SELECT p_source_id,
         nullif(btrim(r->>'member_no'), ''),
         nullif(btrim(r->>'account_id'), ''),
         nullif(btrim(r->>'mission_status'), ''),
         nullif(btrim(r->>'order_no'), ''),
         CASE WHEN r->>'purchase_amount' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r->>'purchase_amount')::numeric END,
         nullif(r->>'receipt_url', ''),
         CASE WHEN nullif(r->>'receipt_at','') IS NOT NULL THEN (r->>'receipt_at')::timestamptz END,
         nullif(r->>'review_kind', ''),
         nullif(r->>'qoo10_urls', ''),
         CASE WHEN nullif(r->>'qoo10_at','') IS NOT NULL THEN (r->>'qoo10_at')::timestamptz END,
         nullif(r->>'cosme_urls', ''),
         CASE WHEN nullif(r->>'cosme_at','') IS NOT NULL THEN (r->>'cosme_at')::timestamptz END
    FROM jsonb_array_elements(p_rows) AS r
   WHERE nullif(btrim(r->>'member_no'), '') IS NOT NULL;   -- 회원번호 없는 줄은 짝지을 수 없어 버린다

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._insert_report_ext_rows(uuid, jsonb) FROM PUBLIC, anon, authenticated;
-- ↑ 내부 전용. 아무에게도 실행 권한을 주지 않는다 — 아래 함수들이 SECURITY DEFINER 로 부른다.

-- ------------------------------------------------------------
-- ① 붙이기 — 같은 (리포트·서비스·외부번호) 가 이미 있으면 **그 소스를 갱신**한다(사양서 ⑩)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_report_source(
  p_report_id     uuid,
  p_service_code  text,
  p_ext_no        text,
  p_ext_name      text,
  p_file_name     text,
  p_rows          jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source_id uuid;
  v_name      text;
  v_n         integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.campaign_reports WHERE id = p_report_id) THEN
    RAISE EXCEPTION '없는 리포트입니다' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_ext_no), '') = '' OR coalesce(btrim(p_ext_name), '') = '' THEN
    RAISE EXCEPTION '외부 캠페인 번호와 이름이 필요합니다' USING ERRCODE = '22023';
  END IF;

  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  -- 이미 있으면 갱신(행 전부 교체), 없으면 새로
  SELECT id INTO v_source_id
    FROM public.campaign_report_sources
   WHERE report_id = p_report_id AND service_code = p_service_code AND ext_campaign_no = btrim(p_ext_no)
   FOR UPDATE;

  IF v_source_id IS NULL THEN
    INSERT INTO public.campaign_report_sources
      (report_id, service_code, ext_campaign_no, ext_campaign_name, file_name, attached_by, attached_by_name)
    VALUES (p_report_id, p_service_code, btrim(p_ext_no), btrim(p_ext_name), p_file_name, auth.uid(), v_name)
    RETURNING id INTO v_source_id;
  ELSE
    DELETE FROM public.campaign_report_ext_rows WHERE source_id = v_source_id;
    UPDATE public.campaign_report_sources
       SET ext_campaign_name = btrim(p_ext_name), file_name = p_file_name,
           attached_by = auth.uid(), attached_by_name = v_name, attached_at = now()
     WHERE id = v_source_id;
  END IF;

  v_n := public._insert_report_ext_rows(v_source_id, p_rows);
  UPDATE public.campaign_report_sources SET row_count = v_n WHERE id = v_source_id;

  -- 본체 updated_at 트리거를 태운다(연결 표만 고치면 안 돈다 — 407 과 같다)
  UPDATE public.campaign_reports SET version = version + 1 WHERE id = p_report_id;

  RETURN v_source_id;
END;
$$;

COMMENT ON FUNCTION public.add_report_source(uuid, text, text, text, text, jsonb) IS
  '[410] 외부 결과물 붙이기. 같은 (리포트·서비스·외부번호) 가 있으면 행을 전부 교체해 갱신한다.';

-- ------------------------------------------------------------
-- ② 행만 갈아끼우기 — 지우고 새로 넣는다(누적되지 않는다)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.replace_report_source_rows(p_source_id uuid, p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_report uuid; v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  SELECT report_id INTO v_report FROM public.campaign_report_sources WHERE id = p_source_id FOR UPDATE;
  IF v_report IS NULL THEN
    RAISE EXCEPTION '없는 첨부입니다' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.campaign_report_ext_rows WHERE source_id = p_source_id;
  v_n := public._insert_report_ext_rows(p_source_id, p_rows);
  UPDATE public.campaign_report_sources
     SET row_count = v_n, attached_at = now(), attached_by = auth.uid()
   WHERE id = p_source_id;
  UPDATE public.campaign_reports SET version = version + 1 WHERE id = v_report;
  RETURN v_n;
END;
$$;

-- ------------------------------------------------------------
-- ③ 떼기 — 첨부 1건과 그 행 전부 (행은 ON DELETE CASCADE)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_report_source(p_source_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_report uuid; v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  SELECT report_id INTO v_report FROM public.campaign_report_sources WHERE id = p_source_id;
  DELETE FROM public.campaign_report_sources WHERE id = p_source_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    UPDATE public.campaign_reports SET version = version + 1 WHERE id = v_report;
  END IF;
  RETURN v_n > 0;
END;
$$;

-- ------------------------------------------------------------
-- ④ 리포트 읽기 — 첨부 목록을 함께 (행은 화면이 따로 조회한다: 563행을 jsonb 로 끌지 않는다)
--    🔴 CREATE OR REPLACE — 베이스는 408. row_id 도 그대로 있다.
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
                'row_id',         rc.id,
                'campaign_id',    rc.campaign_id,
                'campaign_no',    rc.campaign_no,
                'campaign_title', rc.campaign_title,
                'sort_order',     rc.sort_order,
                'campaign_exists', (rc.campaign_id IS NOT NULL)
              ) ORDER BY rc.sort_order)
         FROM public.campaign_report_campaigns rc
        WHERE rc.report_id = r.id), '[]'::jsonb),
    -- 410: 첨부 목록. 머리말 「외부 — (붙인 시각) 기준」은 attached_at 의 최댓값을 쓴다.
    'sources',         coalesce((
       SELECT jsonb_agg(jsonb_build_object(
                'id',                s.id,
                'service_code',      s.service_code,
                'ext_campaign_no',   s.ext_campaign_no,
                'ext_campaign_name', s.ext_campaign_name,
                'file_name',         s.file_name,
                'attached_at',       s.attached_at,
                'attached_by_name',  s.attached_by_name,
                'row_count',         s.row_count
              ) ORDER BY s.attached_at)
         FROM public.campaign_report_sources s
        WHERE s.report_id = r.id), '[]'::jsonb)
  ) INTO v_out
  FROM public.campaign_reports r
  WHERE r.id = p_report_id;

  RETURN v_out;
END;
$$;

-- ------------------------------------------------------------
-- ⑤ 목록 — 외부 첨부 수 (405 는 표가 없어 못 담았다). 베이스 405, CREATE OR REPLACE.
--    ⚠️ RETURNS TABLE 의 칸을 늘리면 CREATE OR REPLACE 가 거부된다(반환형 변경) → DROP 후 CREATE.
--       그래서 **회수를 여기서 다시 건다.**
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_campaign_reports();
CREATE FUNCTION public.list_campaign_reports()
RETURNS TABLE (
  o_id              uuid,
  o_title           text,
  o_created_by      uuid,
  o_created_by_name text,
  o_created_at      timestamptz,
  o_updated_at      timestamptz,
  o_include_audit   boolean,
  o_version         integer,
  o_campaign_count  bigint,
  o_source_count    bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('menu.reports', 'read') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT r.id, r.title, r.created_by, r.created_by_name,
         r.created_at, r.updated_at, r.include_audit, r.version,
         (SELECT count(*) FROM public.campaign_report_campaigns rc WHERE rc.report_id = r.id),
         (SELECT count(*) FROM public.campaign_report_sources  s  WHERE s.report_id = r.id)
    FROM public.campaign_reports r
   ORDER BY r.created_at DESC;
END;
$$;

-- ------------------------------------------------------------
-- ⑥ 실행 권한 — 두 방향 회수 + 로그인 부여. list 는 DROP 했으므로 **반드시** 다시 건다.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.add_report_source(uuid, text, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_report_source(uuid, text, text, text, text, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.replace_report_source_rows(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_report_source_rows(uuid, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.remove_report_source(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_report_source(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_campaign_reports() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_campaign_reports() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 권한 — 다섯 함수 false·false·true (내부 함수 _insert_report_ext_rows 는 로그인도 false)
SELECT p.proname,
       (p.proacl::text LIKE '{=X/%') AS public_남음,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname IN
   ('add_report_source','replace_report_source_rows','remove_report_source','list_campaign_reports','get_campaign_report','_insert_report_ext_rows')
 ORDER BY 1;

-- [V2] 로그인한 관리자 콘솔: 563행 넣고 → 다시 넣어도 563행(누적 안 됨)
--   const sid = (await db.rpc('add_report_source',{p_report_id:'<id>', p_service_code:'pointail',
--       p_ext_no:'102905', p_ext_name:'시험', p_file_name:'x.xlsx', p_rows: rows})).data;
--   (await db.from('campaign_report_ext_rows').select('id',{count:'exact'}).eq('source_id',sid)).count  // 563
--   ...같은 인자로 한 번 더 → 여전히 563
*/
