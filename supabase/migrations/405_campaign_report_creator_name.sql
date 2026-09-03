-- ============================================================
-- 405. 리포트 「만든 사람」 이름 스냅샷 + 목록 조회 함수
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 8」
--
-- 왜 필요한가 — 작업 8 의 목록 열이 「만든 사람」과 「캠페인 수」를 요구하는데
-- 402 에는 둘 다 없다:
--
--   🔴 `created_by` 는 `ON DELETE SET NULL` 이라 **그 관리자를 지우면 만든 사람이
--      통째로 사라진다.** 리포트는 브랜드에게 나가는 산출물이라 「누가 만들었나」가
--      지워지면 안 된다. 이 저장소는 같은 이유로 다른 감사 표에도 이름 스냅샷을
--      둔다(`campaign_change_history.changed_by_name` · 오리엔 메모 작성자 이름).
--
--   ⚠️ 이름을 지금 조인으로 때우면 **지워진 관리자에서만 빈칸**이 되는데,
--      그건 「이름을 안 적은 것」과 화면에서 구분되지 않는다.
--
-- ⚠️ **`created_by` 를 없애지 않는다.** 이름은 사람이 바꿀 수 있고 동명이인도 있다.
--    고유번호는 「누구인지」, 이름은 「지워져도 남는 표시」로 둘 다 쓴다.
--
-- 🔴 `create_campaign_report` 는 **`CREATE OR REPLACE`** 로 고친다.
--    `DROP` 후 `CREATE` 하면 403 이 건 회수(PUBLIC·anon 두 방향)가 **함께 풀린다**
--    — 이 저장소가 387 에서 실제로 밟은 함정이다. 시그니처는 그대로 둔다.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- ① 이름 스냅샷 칸
-- ------------------------------------------------------------
ALTER TABLE public.campaign_reports
  ADD COLUMN IF NOT EXISTS created_by_name text;

COMMENT ON COLUMN public.campaign_reports.created_by_name IS
  '만든 관리자 이름 스냅샷. created_by 가 ON DELETE SET NULL 이라 계정이 지워져도 '
  '「누가 만들었나」가 남도록 만들 때 한 번 적는다. 이후 이름이 바뀌어도 갱신하지 않는다.';

-- ------------------------------------------------------------
-- ② 만들 때 이름을 함께 적는다
--    ⚠️ 403 원본에서 INSERT 한 줄만 달라진다. 나머지는 글자 그대로 같다.
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
  v_name      text;
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

  -- ⚠️ 이름을 못 찾아도 만들기를 막지 않는다 — 이름은 표시용이고, 여기서 막으면
  --    관리자 표에 행이 없는 경우(있어서는 안 되지만) 리포트를 아예 못 만든다.
  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  INSERT INTO public.campaign_reports (title, created_by, created_by_name, include_audit)
  VALUES (btrim(p_title), auth.uid(), v_name, coalesce(p_include_audit, false))
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
  '[405, 베이스 403] 리포트 생성. 캠페인 번호·제목과 만든 사람 이름을 글자로 함께 보관하고, '
  '고른 순서를 sort_order 로 남긴다. 없는 캠페인이 섞이면 조용히 빼지 않고 거부한다.';

-- ------------------------------------------------------------
-- ③ 목록 — 캠페인 수를 서버가 세어 준다
--    ⚠️ 화면이 리포트마다 따로 세면 리포트 N개에 조회가 N번 나간다.
--    ⚠️ 외부 첨부 수(ext_count)는 **아직 없다** — 그 표는 작업 12에서 생긴다.
--       지금 0 으로 돌려주면 화면이 「첨부 0건」이라 단정하게 되므로 아예 안 담는다.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_campaign_reports()
RETURNS TABLE (
  o_id              uuid,
  o_title           text,
  o_created_by      uuid,
  o_created_by_name text,
  o_created_at      timestamptz,
  o_updated_at      timestamptz,
  o_include_audit   boolean,
  o_version         integer,
  o_campaign_count  bigint
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
         (SELECT count(*) FROM public.campaign_report_campaigns rc WHERE rc.report_id = r.id)
    FROM public.campaign_reports r
   ORDER BY r.created_at DESC;
END;
$$;

-- ⚠️ 반환 칸에 o_ 를 붙인 이유 — plpgsql 의 RETURNS TABLE 출력 이름이 원본 표의
--    컬럼명(title, created_at ...)과 같으면 42702(모호한 참조)로 **첫 호출에서** 터진다.
--    이 저장소가 2026-05-20 에 같은 함정을 겪었다(마이그레이션 392 주석 참조).

COMMENT ON FUNCTION public.list_campaign_reports() IS
  '[405] 리포트 목록 + 담긴 캠페인 수. 외부 첨부 수는 그 표가 생기는 작업 12에서 더한다.';

-- ------------------------------------------------------------
-- ④ 실행 권한 — 신규 함수는 두 방향 모두 회수한다(369·370·375)
--    🔴 위 create_campaign_report 는 CREATE OR REPLACE 라 403 의 회수가 보존된다.
--       여기서 다시 걸지 않는다(다시 걸어도 무해하지만, 보존된다는 사실을 남긴다).
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.list_campaign_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_campaign_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_campaign_reports() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 칸이 생겼나
SELECT column_name, data_type
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='campaign_reports' AND column_name='created_by_name';
-- 기대: 1행 (text)

-- [V2] 권한 — 비로그인 차단 · 로그인 허용, PUBLIC 안 남음
SELECT p.proname,
       (p.proacl::text LIKE '{=X/%')                            AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public'
   AND p.proname IN ('create_campaign_report','list_campaign_reports')
 ORDER BY p.proname;
-- 기대: 둘 다 false · false · true
--   🔴 create_campaign_report 가 여기서 true·true 로 나오면 CREATE OR REPLACE 가
--      아니라 DROP 후 CREATE 가 돌아 403 의 회수가 풀린 것이다. 403 의 REVOKE 3줄을
--      다시 실행할 것.

-- [V3] 🔴 **실제 로그인한 관리자 브라우저 콘솔에서** — SQL 편집기는 has_permission
--      분기를 재현하지 못한다(서비스 키에 로그인 사용자가 없다).
--
--   const camp = (await db.from('campaigns').select('id').limit(2)).data.map(c => c.id);
--   const { data: id } = await db.rpc('create_campaign_report',
--       { p_title: '[검증] 이름 스냅샷', p_campaign_ids: camp, p_include_audit: false });
--   console.log((await db.rpc('list_campaign_reports')).data.find(r => r.o_id === id));
--   // 기대: o_created_by_name 에 내 이름, o_campaign_count = 2
--   await db.rpc('delete_campaign_report', { p_report_id: id });   // 뒷정리

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.list_campaign_reports();
-- ALTER TABLE public.campaign_reports DROP COLUMN IF EXISTS created_by_name;
-- -- ⚠️ create_campaign_report 는 403 판을 다시 실행해 되돌린다(CREATE OR REPLACE).
