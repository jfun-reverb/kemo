-- ============================================================
-- 587_brand_publish_ext_lock.sql
-- 2026-10-22 — 외부 줄에 값이 없는 열을 기본 열에서 빼고, 외부 결과 파일이 붙은 캠페인에서는 서버가 잠근다
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ④ ⓓ-1·ⓓ-3·ⓔ·ⓕ(일부) — 2026-10-22 사용자 결정 · 피그마 a05-01b·a05-05
--   화면 짝: 관리자 공개 설정 창(kemo-45 — report-rows.js reportIsExtEmptyKey, 칸 ext_locked) · 브랜드 결과물 화면(88e88bfc — 화면 쪽 감추기)
--
-- 왜: 외부 줄(포인테일)에는 이름·후리가나·구매기간·구매일·SNS 채널 값이 없다. 그 열이 켜져 있으면 외부 줄만 빈칸이라
--   브랜드가 어느 줄이 외부인지 안다. 그래서 ①기본 열에 넣을 수 없고 ②외부 파일이 붙은 캠페인에서는 서버가 그 열을 싣지 않는다.
--
-- 잠기는 열(판정 한 곳 _brand_publish_ext_locked_key — 목록이 아니라 규칙)
--   name_kanji · name_kana · purchase_period · purchase_date
--   + 「ch_{코드}_(acct|url|at)」 중 코드가 qoo10·cosme 가 아닌 것 전부(기본 열의 종류 열쇠 ch_*_* · 대장에 없는 코드 포함). 앞 「-」는 떼고 본다.
--   🔴 화면 reportIsExtEmptyKey(report-rows.js)와 같은 규칙 — 바꾸면 두 곳 함께.
--
-- 고치는 것(베이스 = 마지막 CREATE)
--   1) 새 내부 넷: _brand_publish_ext_locked_key(text) · _brand_publish_strip_ext_locked(jsonb)(기본 열에서 켠 잠금 열쇠 빼기) ·
--      _brand_publish_ext_lock_cols(jsonb)(저장된 공개 열에 잠금 씌우기) · _campaign_ext_attached(uuid)(캠페인에 외부 파일이 붙었나)
--   2) admin_set_brand_publish_default_global(jsonb) · admin_set_brand_publish_default_brand(uuid, jsonb)(544) — 잠금 열쇠를 **걸러 내고** 저장(거부 아님 —
--      575 admin_update_brand_info 가 브랜드 쪽을 안에서 부르므로 거부하면 브랜드 정보 저장 전체가 실패한다). 끝에서 이미 저장된 기본값 두 표를 한 번 정리
--   3) admin_get_campaign_brand_publish(uuid)(544) — 칸 ext_locked(boolean) 추가
--   4) admin_set_campaign_brand_publish(uuid, boolean, jsonb, integer)(559) — 외부 파일이 붙은 동안 잠긴 열쇠는 들어온 값을 무시하고 저장값을 유지.
--      저장값이 없으면(첫 저장·열 목록이 빈 줄) 「꺼짐」만 받는다(새 열쇠의 「-열쇠」만, 옛 열쇠 넷은 뺀다). 파일을 다 떼면 저장값대로 다시 보인다
--   5) get_my_brand_campaign_results(uuid)(583) — 외부 파일이 붙어 있으면 잠금을 씌운 열 목록으로 본체를 부르고 그것을 columns 로 돌려준다.
--      잠긴 채널(큐텐·엣코스메가 아닌) 게시물·인증샷은 묶음((응모·종류·채널))마다 최신 1건만 남기고 submitted_at 을 비운다(업로드 날짜 열을 싣지 않기 —
--      최신 1건으로 먼저 줄이는 이유: 화면 buildReportRows 가 submitted_at 으로 최신을 골라 상태를 계산하므로, 비운 채 여러 건이면 상태가 바뀔 수 있다)
--   6) _brand_campaign_summary(uuid)(583) — 나눠 센 칸 applied_reverb · approved_reverb · ext_participants 를 뺀다(ⓕ — 화면은 88e88bfc 뒤로 안 읽는다)
--   · 바꾸지 않는 것: get_report_share_data·_results_payload_core·_results_ext_rows(공유 링크·관리자) · 관리자 화면·엑셀
--   · ⓔ(외부 줄 회원번호·포인테일 닉네임)는 이미 충족 — 브랜드 갈래 _results_ext_rows(p_for_brand=true)는 member_no·account_id 를 싣지 않는다(545·547)
--   ⚠️ 남는 것(받아들임): 구매기간은 캠페인 값(campaign_rows·deliverables.campaigns 의 purchase_start/end — 캠페인 상세에도 보인다)이라 비우지 않는다 ·
--      잠긴 채널 게시물의 채널 코드(post_channel)·상태는 「상태」 열 계산에 필요해 남긴다
--   ⚠️ 남은 것(다음 단계 — 사양서 「구현 결과」): ⓕ 외부 줄을 따로 담은 묶음(ext_rows)과 그 안의 외부 표시(source_id·review_kind·mission_status 원문) 걷기
--
-- 실행 권한: 바꾼 함수는 전부 CREATE OR REPLACE(이름·인자·반환형 그대로)라 보존. 새 내부 넷은 postgres·service_role 만(PUBLIC·anon·authenticated 회수).
-- 🔴 다음 재정의 베이스: 위 2)~6) 여섯 함수는 이 파일(544·559·583 베이스 금지).
-- 🔴 운영: 브랜드 묶음(544·547·559·583) 뒤 — 출시 날 함께.
-- 편집기 경고: 없음(DROP·DELETE 없음 — 기본값 정리는 UPDATE).
--
-- 롤백(관리자 공개 창 화면을 먼저 되돌리지 않아도 된다 — 화면은 ext_locked 가 없으면 「잠김」으로 그린다):
--   544 의 [3]·[7] 블록(조회·기본 열 쓰기 둘) · 559 블록 · 583 의 1·2 블록 재실행
--   → DROP FUNCTION public._brand_publish_ext_lock_cols(jsonb), public._brand_publish_strip_ext_locked(jsonb),
--      public._brand_publish_ext_locked_key(text), public._campaign_ext_attached(uuid);
--   (기본값 정리로 빠진 열쇠는 되살리지 않는다 — 기본 열 화면에서 다시 고른다)
-- ============================================================

BEGIN;

-- ── 1. 내부 판정 넷 ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._brand_publish_ext_locked_key(p_key text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_key IS NULL THEN false
    ELSE regexp_replace(p_key, '^-', '') IN ('name_kanji', 'name_kana', 'purchase_period', 'purchase_date')
      OR (regexp_replace(p_key, '^-', '') ~ '^ch_[^_]+_(acct|url|at)$'
          AND regexp_replace(p_key, '^-', '') !~ '^ch_(qoo10|cosme)_')
  END
$$;
COMMENT ON FUNCTION public._brand_publish_ext_locked_key(text) IS
  '[587] 외부 줄에 값이 없는 열쇠인가(사양서 ④ ⓓ) — 이름·후리가나·구매기간·구매일 + 큐텐·엣코스메가 아닌 ch_{코드}_(acct|url|at). 앞 「-」는 뗀다. 화면 reportIsExtEmptyKey 와 같은 규칙.';

-- 기본 열 값에서 켠 잠금 열쇠를 뺀다(「-」로 시작하는 원소는 그대로 — 기본 열에서는 뜻이 없지만 지울 이유도 없다)
CREATE OR REPLACE FUNCTION public._brand_publish_strip_ext_locked(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p IS NULL OR jsonb_typeof(p) <> 'array' THEN p
    ELSE coalesce((SELECT jsonb_agg(e ORDER BY ord)
                     FROM jsonb_array_elements(p) WITH ORDINALITY t(e, ord)
                    WHERE NOT (jsonb_typeof(e) = 'string'
                               AND left(e #>> '{}', 1) <> '-'
                               AND public._brand_publish_ext_locked_key(e #>> '{}'))), '[]'::jsonb)
  END
$$;
COMMENT ON FUNCTION public._brand_publish_strip_ext_locked(jsonb) IS
  '[587] 기본 열 값(켤 열쇠 목록)에서 잠금 열쇠를 뺀다(ⓓ-1). 배열이 아니면 그대로.';

-- 저장된 공개 열에 잠금을 씌운다 — 옛 열쇠 넷은 빼고(없음 = 꺼짐), 서버 채널 대장(_report_share_chan_col)의 잠긴 새 열쇠는 「-열쇠」.
--   🔴 서버가 그리는 채널은 _report_share_chan_col 의 일곱 + 기타 · 계정은 _results_payload_core 의 SNS 넷뿐이라 이 열거로 빠짐이 없다 —
--      그 둘에 채널을 더하면 여기도 더한다.
CREATE OR REPLACE FUNCTION public._brand_publish_ext_lock_cols(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH base AS (
    -- NULL(= 전부 켬)이면 옛 열쇠 전부를 켠 배열로 바꿔 시작한다(공개 켜짐은 늘 배열이라 실제로는 안 탄다)
    SELECT CASE WHEN p IS NULL OR jsonb_typeof(p) <> 'array'
                THEN '["no","campaign_no","campaign_name","purchase_period","status","order_no","purchase_date","amount","receipt_url","receipt_uploaded_at","name_kanji","name_kana","ch_qoo10_url","ch_qoo10_at","ch_cosme_url","ch_cosme_at"]'::jsonb
                ELSE p END AS a
  ), kept AS (
    SELECT coalesce(jsonb_agg(e ORDER BY ord), '[]'::jsonb) AS a
      FROM base, jsonb_array_elements(base.a) WITH ORDINALITY t(e, ord)
     WHERE NOT (jsonb_typeof(e) = 'string' AND public._brand_publish_ext_locked_key(e #>> '{}'))
  )
  SELECT kept.a || '["-ch_lips_url","-ch_lips_at",
                     "-ch_instagram_acct","-ch_instagram_url","-ch_instagram_at",
                     "-ch_tiktok_acct","-ch_tiktok_url","-ch_tiktok_at",
                     "-ch_x_acct","-ch_x_url","-ch_x_at",
                     "-ch_youtube_acct","-ch_youtube_url","-ch_youtube_at",
                     "-ch_etc_url","-ch_etc_at"]'::jsonb
    FROM kept
$$;
COMMENT ON FUNCTION public._brand_publish_ext_lock_cols(jsonb) IS
  '[587] 공개 열 목록에 외부 잠금을 씌운 「실효 열 목록」(ⓓ-3) — 잠금 원소를 빼고 옛 열쇠 넷은 없음(꺼짐), 잠긴 새 열쇠는 「-열쇠」를 붙인다.';

CREATE OR REPLACE FUNCTION public._campaign_ext_attached(p_campaign_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.campaign_report_sources s WHERE s.campaign_id = p_campaign_id)
$$;
COMMENT ON FUNCTION public._campaign_ext_attached(uuid) IS
  '[587] 캠페인에 외부 결과 파일(546 캠페인 첨부)이 붙어 있나 — 잠금 판정 한 곳. 정의자 권한 함수 안에서만 부른다.';

GRANT  EXECUTE ON FUNCTION public._brand_publish_ext_locked_key(text)   TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_publish_strip_ext_locked(jsonb) TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_publish_ext_lock_cols(jsonb)    TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._campaign_ext_attached(uuid)           TO postgres, service_role;
REVOKE ALL ON FUNCTION public._brand_publish_ext_locked_key(text)   FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_publish_ext_locked_key(text)   FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._brand_publish_strip_ext_locked(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_publish_strip_ext_locked(jsonb) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._brand_publish_ext_lock_cols(jsonb)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_publish_ext_lock_cols(jsonb)    FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._campaign_ext_attached(uuid)           FROM PUBLIC;
REVOKE ALL ON FUNCTION public._campaign_ext_attached(uuid)           FROM anon, authenticated;

-- ── 2. 기본 열 쓰기 둘 (베이스 544) — 잠금 열쇠를 걸러 내고 저장 ──────────────
CREATE OR REPLACE FUNCTION public.admin_set_brand_publish_default_global(p_spec jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  IF NOT public._brand_publish_keys_valid(p_spec) THEN RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023'; END IF;
  p_spec := public._brand_publish_strip_ext_locked(p_spec);   -- 587 ⓓ-1
  INSERT INTO public.brand_publish_default_global (id, spec, updated_at, updated_by)
  VALUES (1, p_spec, now(), auth.uid())
  ON CONFLICT (id) DO UPDATE SET spec = EXCLUDED.spec, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_brand_publish_default_brand(p_brand_id uuid, p_spec jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('report.share', 'write') THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  PERFORM 1 FROM public.brands WHERE id = p_brand_id;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 브랜드입니다' USING ERRCODE = '22023'; END IF;
  IF p_spec IS NULL THEN
    -- 「전체 기본값 따르기」
    DELETE FROM public.brand_publish_default_by_brand WHERE brand_id = p_brand_id;
    RETURN true;
  END IF;
  IF NOT public._brand_publish_keys_valid(p_spec) THEN RAISE EXCEPTION '열 목록 형식이 올바르지 않습니다' USING ERRCODE = '22023'; END IF;
  p_spec := public._brand_publish_strip_ext_locked(p_spec);   -- 587 ⓓ-1
  INSERT INTO public.brand_publish_default_by_brand (brand_id, spec, updated_at, updated_by)
  VALUES (p_brand_id, p_spec, now(), auth.uid())
  ON CONFLICT (brand_id) DO UPDATE SET spec = EXCLUDED.spec, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.admin_set_brand_publish_default_global(jsonb) IS
  '[544 → 587] 전체 기본 열 저장(report.share 쓰기). 587: 외부 줄에 값이 없는 열쇠는 걸러 내고 저장(ⓓ-1).';
COMMENT ON FUNCTION public.admin_set_brand_publish_default_brand(uuid, jsonb) IS
  '[544 → 587] 브랜드 기본 열 저장(report.share 쓰기 · NULL 이면 전체 따르기). 587: 외부 줄에 값이 없는 열쇠는 걸러 내고 저장(ⓓ-1).';

-- 이미 저장된 기본값 정리(한 번) — 저장자·시각은 건드리지 않는다(데이터 정리)
UPDATE public.brand_publish_default_global
   SET spec = public._brand_publish_strip_ext_locked(spec)
 WHERE spec IS DISTINCT FROM public._brand_publish_strip_ext_locked(spec);
UPDATE public.brand_publish_default_by_brand
   SET spec = public._brand_publish_strip_ext_locked(spec)
 WHERE spec IS DISTINCT FROM public._brand_publish_strip_ext_locked(spec);

-- ── 3. 캠페인 공개 읽기 (베이스 544) — ext_locked 칸 ─────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_campaign_brand_publish(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand uuid;
  p       public.campaign_brand_publish%ROWTYPE;
  d       jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501'; END IF;
  SELECT c.brand_id INTO v_brand FROM public.campaigns c WHERE c.id = p_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 캠페인입니다' USING ERRCODE = '22023'; END IF;
  SELECT * INTO p FROM public.campaign_brand_publish WHERE campaign_id = p_campaign_id;
  d := public._brand_publish_default_for(v_brand);
  RETURN jsonb_build_object(
    'enabled',          COALESCE(p.enabled, false),
    'columns',          p.columns,                       -- 줄이 없거나 저장 전이면 NULL — 화면이 default_spec 으로 처음 체크를 펼친다
    'version',          COALESCE(p.version, 0),          -- 줄이 없으면 0(저장 때 expected_version 으로 그대로 보낸다)
    'updated_at',       p.updated_at,
    'first_enabled_at', p.first_enabled_at,
    'default_spec',     d -> 'spec',
    'default_source',   d ->> 'source',
    'ext_locked',       public._campaign_ext_attached(p_campaign_id)   -- 587: 외부 결과 파일이 붙어 있으면 참(ⓓ-3 — 잠긴 열은 창에서 회색)
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_campaign_brand_publish(uuid) IS
  '[544 → 587] 캠페인 브랜드 공개 읽기(관리자 전원). 587: ext_locked(외부 결과 파일이 붙어 있나) 칸 추가.';

-- ── 4. 캠페인 공개 쓰기 (베이스 559) — 외부 파일이 붙은 동안 잠긴 열쇠는 저장값 유지 ──────
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
  v_found    boolean;
  v_has_old  boolean;   -- 587
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
  v_found := FOUND;

  -- 587 ⓓ-3: 외부 파일이 붙은 동안 잠긴 열쇠는 들어온 값을 무시한다 —
  --   저장값이 있으면 그 잠금 원소를 그대로, 없으면 들어온 값 중 「꺼짐」(「-」로 시작)만 받는다.
  --   파일 붙이기(546)와 같은 캠페인 행을 잠그지 않으므로 붙이는 순간과 겹치면 이 저장은 붙기 전 판정이다 — 브랜드 응답은 늘 그 순간의 판정으로 잠근다(5).
  --   ⚠️ 저장된 잠금 원소는 뒤에 붙는다 — 옛 배열에서 중간에 있었으면 순서만 바뀌어 publish_columns 기록이 한 번 더 남을 수 있다(그 뒤로는 안정 — 받아들임).
  IF p_columns IS NOT NULL AND public._campaign_ext_attached(p_campaign_id) THEN
    v_has_old := v_found AND coalesce(jsonb_typeof(v_old_cols) = 'array', false);   -- 줄은 있는데 열 목록이 빈(NULL) 경우도 「저장값 없음」
    SELECT coalesce(jsonb_agg(e ORDER BY ord), '[]'::jsonb) INTO p_columns
      FROM (
        SELECT e, ord FROM jsonb_array_elements(p_columns) WITH ORDINALITY t(e, ord)
         WHERE NOT public._brand_publish_ext_locked_key(e #>> '{}')
        UNION ALL
        SELECT e, 100000 + ord
          FROM jsonb_array_elements(CASE WHEN v_has_old THEN v_old_cols ELSE '[]'::jsonb END) WITH ORDINALITY t(e, ord)
         WHERE public._brand_publish_ext_locked_key(e #>> '{}')
        UNION ALL
        SELECT e, 200000 + ord FROM jsonb_array_elements(p_columns) WITH ORDINALITY t(e, ord)
         WHERE NOT v_has_old
           AND public._brand_publish_ext_locked_key(e #>> '{}')
           AND left(e #>> '{}', 1) = '-'
      ) x;
  END IF;

  IF NOT v_found THEN
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
  '[544 → 559 → 587] 캠페인 브랜드 공개 저장(낙관적 잠금, 충돌 -1). 559: 켜기·끄기·열 바꾸기를 같은 거래에서 제공 기록. '
  '587: 외부 결과 파일이 붙은 동안 잠긴 열쇠(_brand_publish_ext_locked_key)는 들어온 값을 무시하고 저장값 유지(없으면 「꺼짐」만). 현재 원본 587.';

-- ── 5. 브랜드 결과물 조회 (베이스 583) — 외부 파일이 붙으면 잠금 열 목록 ─────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_campaign_results(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid    uuid := auth.uid();
  c        public.campaigns%ROWTYPE;
  pub      public.campaign_brand_publish%ROWTYPE;
  v_src    uuid[];
  v_core   jsonb;
  v_upd    timestamptz;
  v_cols   jsonb;     -- 587: 실효 열 목록
  v_locked boolean;   -- 587
  v_delivs jsonb;     -- 587
BEGIN
  IF v_uid IS NULL OR p_campaign_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND
     OR c.deleted_at IS NOT NULL
     OR c.status NOT IN ('scheduled', 'active', 'closed', 'ended')
     OR c.brand_id IS NULL
     OR NOT public.is_my_brand(c.brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- 583: 결과물 열람 정지 — 「내 브랜드」 확인 뒤, 공개 꺼짐 앞(더 앞이면 남의 캠페인에 정지 여부가 샌다)
  IF public._brand_active_suspension(c.brand_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'ready', false, 'reason', 'suspended');
  END IF;

  SELECT * INTO pub FROM public.campaign_brand_publish WHERE campaign_id = c.id;
  IF NOT FOUND OR NOT pub.enabled THEN
    RETURN jsonb_build_object('success', true, 'ready', false);   -- 🔴 세 숫자도 싣지 않는다(§4 ④)
  END IF;

  SELECT coalesce(array_agg(s.id), '{}') INTO v_src FROM public.campaign_report_sources s WHERE s.campaign_id = c.id;
  -- 587 ⓓ-3: 외부 파일이 붙어 있는 동안 잠긴 열은 서버가 싣지 않는다(저장값은 그대로 — 떼면 다시 보인다)
  v_locked := cardinality(v_src) > 0;
  v_cols   := CASE WHEN v_locked THEN public._brand_publish_ext_lock_cols(pub.columns) ELSE pub.columns END;
  v_core   := public._results_payload_core(ARRAY[c.id], v_cols, false);
  v_delivs := v_core -> 'deliverables';

  -- 587: 잠긴 채널(큐텐·엣코스메가 아닌) 게시물·인증샷 — 묶음마다 최신 1건만 남기고 업로드 날짜(submitted_at)를 비운다.
  --   최신 고르기는 화면 buildReportRows 와 같다(submitted_at 문자열 큰 것 · 같으면 먼저 온 것 · 빈 값은 가장 작다).
  --   ⚠️ 화면의 g.result(채널 무관 최신 게시물)는 날짜를 비우면 다른 건이 될 수 있으나, 상태 계산(_excelCertStatusKo)은 g.result 의 「있음」만 본다 —
  --      묶음마다 한 건은 남으므로 상태는 그대로다. 채널이 빈 게시물도 한 묶음('')으로 줄어드는데, 그 건들은 잠긴 「기타」 열에만 쓰인다(상태 판정 밖).
  IF v_locked THEN
    SELECT coalesce(jsonb_agg(CASE WHEN b.lk THEN b.e || jsonb_build_object('submitted_at', NULL) ELSE b.e END ORDER BY b.ord), '[]'::jsonb)
      INTO v_delivs
      FROM (
        SELECT a.e, a.ord, a.lk,
               row_number() OVER (PARTITION BY a.lk, a.e ->> 'application_id', a.e ->> 'kind', coalesce(a.e ->> 'post_channel', '')
                                  ORDER BY coalesce(a.e ->> 'submitted_at', '') DESC, a.ord) AS rn
          FROM (
            SELECT t.e, t.ord,
                   coalesce((t.e ->> 'kind') IN ('post', 'review_image'), false)
                     AND coalesce(t.e ->> 'post_channel', '') NOT IN ('qoo10', 'cosme') AS lk
              FROM jsonb_array_elements(coalesce(v_delivs, '[]'::jsonb)) WITH ORDINALITY t(e, ord)
          ) a
      ) b
     WHERE NOT b.lk OR b.rn = 1;
  END IF;

  SELECT greatest(
           (SELECT max(greatest(d.submitted_at, d.reviewed_at)) FROM public.deliverables d
             WHERE d.campaign_id = c.id AND d.status <> 'draft'),
           (SELECT max(s.attached_at) FROM public.campaign_report_sources s WHERE s.campaign_id = c.id),
           pub.updated_at)
    INTO v_upd;

  RETURN jsonb_build_object(
    'success',       true,
    'ready',         true,
    'campaign_id',   c.id,
    'columns',       v_cols,                                     -- 587: 실효 열 목록(잠금 반영)
    'campaign_rows', v_core -> 'campaign_rows',
    'deliverables',  v_delivs,
    'users',         v_core -> 'users',
    'ext_rows',      public._results_ext_rows(v_src, v_cols, true, true),
    'counts',        public._brand_campaign_result_counts(c.id),
    'updated_at',    v_upd
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaign_results(uuid) IS
  '[547 → 583 → 587] 브랜드 결과물 조회. 내 브랜드 캠페인 아님 → not_found · 정지 → suspended · 공개 꺼짐 → ready:false · 켜짐 → 결과물 본체. '
  '587: 외부 결과 파일이 붙어 있으면 잠금 열 목록(_brand_publish_ext_lock_cols)으로 부르고 columns 로 돌려준다 · 잠긴 채널 게시물은 묶음마다 최신 1건 + submitted_at 비움.';

-- ── 6. 캠페인 요약 (베이스 583) — 나눠 센 칸 셋 빼기 ──────────────────────
CREATE OR REPLACE FUNCTION public._brand_campaign_summary(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_counts   jsonb   := public._brand_campaign_counts(p_campaign_id);
  v_ext      integer := coalesce(public._campaign_ext_participant_count(p_campaign_id), 0);
  v_applied  integer := coalesce((v_counts ->> 'applied_count')::integer, 0);
  v_approved integer := coalesce((v_counts ->> 'approved_count')::integer, 0);
  v_pub      boolean;
  v_susp     boolean;   -- 583
  v_out      jsonb;
BEGIN
  SELECT p.enabled INTO v_pub FROM public.campaign_brand_publish p WHERE p.campaign_id = p_campaign_id;
  v_pub := coalesce(v_pub, false);
  -- 583: 결과물 열람 정지(브랜드 단위)
  SELECT public._brand_active_suspension(c.brand_id) IS NOT NULL INTO v_susp
    FROM public.campaigns c WHERE c.id = p_campaign_id;
  v_susp := coalesce(v_susp, false);
  -- 587 ⓕ: 합친 값만 — REVERB·외부를 나눠 센 칸(applied_reverb·approved_reverb·ext_participants)은 싣지 않는다
  v_out := jsonb_build_object(
    'applied_count',     v_applied  + v_ext,
    'approved_count',    v_approved + v_ext,
    'results_public',    v_pub,
    'results_suspended', v_susp   -- 583: 화면 brandResultsSuspended 가 참일 때만 본다
  );
  IF v_pub AND NOT v_susp THEN   -- 583: 정지면 결과물 게시 숫자를 싣지 않는다
    -- S11 — 「결과물 게시」 = 검수까지 끝난 결과물(최신 건 기준 · 외부 「완료」 포함). 분모는 화면이 approved_count(합계)로 그린다
    v_out := v_out || jsonb_build_object('result_posted', coalesce((public._brand_campaign_result_counts(p_campaign_id) ->> 'approved')::integer, 0));
  END IF;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION public._brand_campaign_summary(uuid) IS
  '[550 → 583 → 587] 브랜드 캠페인 목록·상세 요약: applied_count·approved_count(REVERB + 외부 합계)·results_public·results_suspended + 공개 켜짐이고 정지 아니면 result_posted. '
  '587: 나눠 센 칸 applied_reverb·approved_reverb·ext_participants 제거(ⓕ). 내부 전용(547 목록·상세가 붙인다).';

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '587', '587_brand_publish_ext_lock.sql');
COMMIT;

-- ============================================================
-- 적용 뒤 확인 (개발서버)
--   ① 기록:   SELECT * FROM public.migration_ledger WHERE key = '587' ORDER BY id DESC LIMIT 3;
--   ② 권한:   새 내부 넷 — authenticated·anon false, 맨 앞 =X/ 없음 · 바꾼 공개 함수 넷 — 그대로(authenticated=X, anon 없음)
--     SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND p.proname IN ('_brand_publish_ext_locked_key','_brand_publish_strip_ext_locked','_brand_publish_ext_lock_cols',
--            '_campaign_ext_attached','admin_get_campaign_brand_publish','admin_set_campaign_brand_publish','admin_set_brand_publish_default_global',
--            'admin_set_brand_publish_default_brand','get_my_brand_campaign_results','_brand_campaign_summary');
--   ③ 판정(계산만 — 표를 안 읽는다):
--     SELECT k, public._brand_publish_ext_locked_key(k) FROM unnest(ARRAY['name_kanji','-purchase_date','ch_instagram_acct','-ch_x_url','ch_*_at','ch_etc_url',
--            'ch_lips_at','ch_qoo10_url','-ch_cosme_at','status','receipt_url','no','account_id']) k;
--     기대: 앞 일곱 true · 뒤 여섯 false
--     SELECT public._brand_publish_ext_lock_cols('["no","status","name_kanji","receipt_url","-ch_tiktok_url"]'::jsonb);
--     기대: ["no","status","receipt_url", "-ch_lips_url", … "-ch_etc_at"](잠긴 새 열쇠 16개)
--     SELECT public._brand_publish_strip_ext_locked('["status","name_kana","ch_*_url","ch_qoo10_url","-ch_x_at"]'::jsonb);
--     기대: ["status","ch_qoo10_url","-ch_x_at"]
--   ④ 기본값 정리: SELECT spec FROM public.brand_publish_default_global; SELECT brand_id, spec FROM public.brand_publish_default_by_brand;
--     → 잠금 열쇠(켠 것)가 없다
--   ⑤ 🔴 실제 로그인 브라우저(관리자 판정은 편집기로 재현 안 됨):
--     외부 파일이 붙은 캠페인 — admin_get_campaign_brand_publish → ext_locked:true · 잠긴 열을 바꿔 저장해도 저장값의 잠금 원소가 그대로
--     브랜드 계정 — get_my_brand_campaign_results 의 columns 에 잠금 반영 · users 의 이름·SNS 계정 null · 잠긴 채널 게시물 submitted_at null ·
--     get_my_brand_campaigns 줄에 applied_reverb·approved_reverb·ext_participants 없음
--     외부 파일을 다 떼면 저장값대로 다시 보인다
-- ============================================================
