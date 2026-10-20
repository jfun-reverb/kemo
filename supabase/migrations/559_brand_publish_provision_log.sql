-- ============================================================
-- 559_brand_publish_provision_log.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1 — 544·552 뒤)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 R1」
-- 사양서 docs/specs/2026-10-19-personal-data-access-records.md §4-3 「브랜드 공개 설정 변경」(누가·언제·무엇에서 무엇으로)
--   선행: 544(admin_set_campaign_brand_publish) · 552(_record_brand_provision)
--
-- 하는 일
--   admin_set_campaign_brand_publish 를 544 베이스로 CREATE OR REPLACE — 저장이 성공한 같은 거래에서 제공 기록 한 줄.
--   🔴 DROP 하지 않는다(인자·반환 그대로 — 실행 권한 보존). 이 파일 뒤 이 함수의 현재 원본은 559.
--   결과물 열람·내려받기 기록은 데이터베이스가 아니라 서버 함수 brand-campaign-results 의 view·excel 갈래가 남긴다(같은 병합 요청 —
--   547 get_my_brand_campaign_results 는 STABLE 그대로, 재정의하지 않는다).
--
-- ============================================================
-- 설계 판단
-- ============================================================
--   [R1] 기록 종류: 꺼짐(또는 줄 없음) → 켜짐 = publish_on · 켜짐 → 꺼짐 = publish_off · 켜짐 그대로 열 목록이 바뀜 = publish_columns.
--        꺼진 채 열만 저장하거나 아무것도 안 바뀐 저장은 기록하지 않는다(브랜드에게 새로 열리거나 닫힌 것이 없다).
--        버전 충돌(-1)이면 저장이 없으니 기록도 없다.
--   [R2] 「무엇에서 무엇으로」: 552 의 columns 칸은 배열이어야 한다(검사 제약) — 작업표의 {before, after} 를
--        [{enabled_before, enabled_after, before, after}] 한 원소 배열로 담는다. before·after = 그 순간 저장된 열 목록(NULL 가능).
--   [R3] 사람 목록은 비운다([]) — 공개 설정은 「누구의 무엇을 보게 했나」의 근거이고, 실제로 어떤 회원이 보였는지는 브랜드가 결과물을
--        열 때(results_view·results_excel) 사람 목록과 함께 남는다. 여기서 회원을 다 적으면 같은 사람이 매 설정마다 쌓인다.
--   [R4] 기록이 실패하면 저장도 실패한다(같은 거래 — 552 의 기본). 실패할 길은 사실상 관리자 계정이 admins 에 없는 경우뿐(has_permission 이 이미 막는다).
--
-- 롤백: 544 의 「[4] 캠페인 공개 — 쓰기(낙관적 잠금)」 블록을 다시 실행한다(기록만 빠진다 · 권한 그대로).
-- 편집기 경고: 없음(DROP·DELETE 없음).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_set_campaign_brand_publish(
  p_campaign_id      uuid,
  p_enabled          boolean,
  p_columns          jsonb,
  p_expected_version integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_ver      integer;
  v_brand    uuid;
  v_old_on   boolean := false;
  v_old_cols jsonb;
  v_new_cols jsonb;
  v_action   text;
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF p_enabled IS NULL THEN RAISE EXCEPTION '켜짐·꺼짐 값이 없습니다' USING ERRCODE = '22023'; END IF;
  IF p_columns IS NOT NULL AND NOT public._brand_publish_keys_valid(p_columns) THEN
    RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023';
  END IF;
  -- 켤 때는 열 목록이 있어야 한다(빈 배열은 허용 — 관리자가 일부러 아무 열도 안 고른 경우)
  IF p_enabled AND p_columns IS NULL THEN RAISE EXCEPTION '보일 열을 정해 주십시오' USING ERRCODE = '22023'; END IF;
  SELECT c.brand_id INTO v_brand FROM public.campaigns c WHERE c.id = p_campaign_id AND c.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 캠페인입니다' USING ERRCODE = '22023'; END IF;   -- 보관 삭제된 캠페인은 바꾸지 않는다

  SELECT p.version, p.enabled, p.columns INTO v_ver, v_old_on, v_old_cols
    FROM public.campaign_brand_publish p WHERE p.campaign_id = p_campaign_id FOR UPDATE;
  IF NOT FOUND THEN
    IF COALESCE(p_expected_version, 0) <> 0 THEN RETURN -1; END IF;
    INSERT INTO public.campaign_brand_publish (campaign_id, enabled, columns, version, updated_at, updated_by, first_enabled_at)
    VALUES (p_campaign_id, p_enabled, p_columns, 1, now(), v_uid, CASE WHEN p_enabled THEN now() END);
    v_ver      := 1;
    v_old_on   := false;
    v_old_cols := NULL;
    v_new_cols := p_columns;
  ELSE
    IF p_expected_version IS DISTINCT FROM v_ver THEN RETURN -1; END IF;
    UPDATE public.campaign_brand_publish SET
      enabled          = p_enabled,
      columns          = COALESCE(p_columns, columns),    -- 끌 때 열 목록을 안 보내면 저장된 열을 남긴다(다시 켤 때 그대로)
      version          = version + 1,
      updated_at       = now(),
      updated_by       = v_uid,
      first_enabled_at = COALESCE(first_enabled_at, CASE WHEN p_enabled THEN now() END)
    WHERE campaign_id = p_campaign_id
    RETURNING version, columns INTO v_ver, v_new_cols;
  END IF;

  -- 559 — 제공 기록 [R1][R2][R3]
  v_action := CASE
    WHEN p_enabled AND NOT COALESCE(v_old_on, false) THEN 'publish_on'
    WHEN NOT p_enabled AND COALESCE(v_old_on, false) THEN 'publish_off'
    WHEN p_enabled AND v_new_cols IS DISTINCT FROM v_old_cols THEN 'publish_columns'
  END;
  IF v_action IS NOT NULL THEN
    PERFORM public._record_brand_provision(
      v_brand, p_campaign_id, v_action,
      jsonb_build_array(jsonb_build_object(
        'enabled_before', COALESCE(v_old_on, false), 'enabled_after', p_enabled,
        'before', v_old_cols, 'after', v_new_cols)),
      '[]'::jsonb, v_uid, 'admin');
  END IF;

  RETURN v_ver;
END;
$$;

COMMENT ON FUNCTION public.admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer) IS
  '[544 → 559] 캠페인 브랜드 공개 저장(낙관적 잠금, 충돌 -1). 559: 켜기·끄기·열 바꾸기를 같은 거래에서 제공 기록(publish_on/off/columns, '
  'columns = [{enabled_before, enabled_after, before, after}], 사람 목록 없음). 현재 원본 559.';

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (개발서버 — 관리자 판정이라 SQL 편집기에서는 「관리자 흉내」 블록을 끝에서 예외로 되돌린다)
-- ============================================================
-- [1] 권한 그대로 — 기대: anon=false · authenticated=true · acl 맨 앞 `=X/` 없음
--   SELECT has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE'), p.proacl::text
--     FROM pg_proc p WHERE p.proname = 'admin_set_campaign_brand_publish';
-- [2] 켜기 → 열 바꾸기 → 같은 값 다시 저장 → 끄기 → 꺼진 채 열 저장 = 기록 셋(on·columns·off), 충돌 저장은 기록 없음
