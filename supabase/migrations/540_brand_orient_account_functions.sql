-- ============================================================
-- 540_brand_orient_account_functions.sql
-- 2026-10-16 — 브랜드 로그인 계정용 오리엔시트 함수 일곱
--   작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 「작업 3」 · 결정 1~8·13 · 기본값 3·4·5
--
-- 무엇을 하나 (이 파일이 하는 전부 — 함수 일곱 추가, 기존 함수·표 변경 없음)
--   get_my_orient_sheets(p_brand_id)            목록(STABLE)
--   get_my_orient_sheet(p_sheet_id)             상세(STABLE)
--   save_my_orient_draft(p_sheet_id, p_data, p_version)    → _orient_save_core(…, auth.uid())
--   submit_my_orient_sheet(p_sheet_id, p_data, p_version)  → _orient_submit_core(…, auth.uid())
--   preview_my_orient_quote(p_sheet_id, p_data)            → _orient_preview_core
--   get_my_orient_tier_fees(p_sheet_id)                    → _orient_tier_fees_core
--   resolve_my_orient_link(p_token)             옛 링크 토큰 → 시트 번호(내용 없음)
--   적용만으로 바뀌는 기존 동작: 없음(새 함수 일곱. 토큰 폼·관리자 화면은 영향 없음).
--
-- 왜
--   브랜드 페이지가 토큰 없이 로그인 계정으로 오리엔시트를 목록·작성·제출하게 한다. 본체는 539 의 내부 함수를 그대로 쓴다(사본 없음).
--
-- 🔴 운영 반영 — 개발서버만. 526~536 묶음 뒤, 539 뒤에 넣는다(539 의 내부 함수·판정 함수·칸을 부른다).
--
-- 계약
--   · 전부 SECURITY DEFINER SET search_path=''. 권한: GRANT TO postgres, authenticated, service_role → REVOKE FROM PUBLIC → REVOKE FROM anon(369·370·375 순서).
--   · 결과 {success:true,…} / {success:false, reason}. 거부는 `not_found` 하나로 뭉친다 — 시트 없음·남의 브랜드·연결 해제·보관 브랜드·로그인 없음(기본값 4).
--     브랜드 모양이 아니라 기존 오리엔시트 함수 모양이다(기본값 3 — 536 의 result 모양이 아니다).
--   · 권한 판정 = 시트의 brand_id 로 public.is_my_brand()(530). 화면이 보낸 브랜드 번호는 목록 함수에서만 쓰고 그 브랜드를 다시 판정한다.
--   · 토큰·created_by·mail_sent_to·내부 메모·application_id 는 결과에 싣지 않는다(기본값 5).
--
-- 설계 판단
--   [A] 🔴 is_my_brand 확인과 본체의 FOR UPDATE 사이 경쟁은 무해하다 — 확인 뒤 연결이 풀려도 그 한 번의 쓰기는 확인 시각에 정당했던 권한의 것이고,
--       본체가 잠금 안에서 status·기한·version 을 다시 보므로 상태가 어긋난 쓰기는 거부된다. 시트의 brand_id 는 브랜드 병합이 옮길 수 있으나
--       병합은 브랜드 계정 연결이 있으면 거부(467)하므로 연결된 계정이 있는 시트의 brand_id 가 바뀌는 경로는 없다.
--   [B] get_my_orient_sheet 가 524 get_orient_sheet 와 다른 점 — consumed 를 거부하지 않는다(등록 시트도 상세를 본다). 등록 시트는 기한 뒤에도 success 이고
--       그때는 data 에서 quote·quote_history·quote_error 를 뺀다(결정 3, 13-4 ⑦). 만료(view_status='expired')만 {success:false, reason:'expired', status:'expired'}.
--       새 키: brand_id·orient_no·layout·view_status·last_submitted_at·deadline_at·last_edited_at·last_edited_by_name·last_edited_by_me·read_only·campaigns.
--   [C] read_only = view_status='registered' 이거나 옛 구조(data.issued 없음). 옛 구조·기한 안·미등록이면 success + read_only 로 안내용 조회만 한다.
--   [D] 🔴 draft_data 는 524 조건(status='submitted' 이고 값 있음)에 더해 read_only 가 아닐 때만 싣는다 — 읽기 전용 화면은 작성본을 쓰지 않고,
--       기한 지난 등록 시트에 작성본(견적 이전 입력)을 싣지 않기 위해서다. 작성 모달이 열리는 시트(read_only=false)는 524 와 똑같다.
--   [E] campaigns 배열: data.cards 중 campaign_id 가 비지 않은 카드만 [{card_idx(0부터), campaign_id, linked_existing(없으면 false)}].
--   [F] 목록: layout = data.issued 가 객체이면 new 아니면 old. 상품 번호·제품명 = data.cards[0].sale.goods_code · product.name, extra_markets = sale.extra_markets(리뷰어형만),
--       channel = data.issued.channel(없으면 NULL). registered_count·card_count 는 data.cards 기준. issued_at = created_at(발급 때 한 번 찍힘).
--       has_unsubmitted_draft = status='submitted' AND draft_saved_at IS NOT NULL(관리자 osHasUnsubmittedDraft 와 같은 식). 발급 최신순(created_at DESC, id).
--   [G] last_edited_by_name 은 읽을 때 brand_accounts.name(빈 문자열 → NULL, 계정이 없어도 NULL) — 이름 사본을 남기지 않는다(결정 2).
--   [H] 본체가 주는 not_found(조회와 잠금 사이 시트 삭제)는 그대로 돌려준다.
--
-- 🔴 반환 칸을 나중에 바꾸려면 DROP 후 CREATE 라 실행 권한 회수(PUBLIC → anon)를 다시 걸어야 한다. 다음 재정의의 베이스는 이 파일(540).
-- 편집기 경고: 실행 구문에 DROP·DELETE 없음(CREATE OR REPLACE · GRANT/REVOKE · COMMENT). 하단 주석의 시험 데이터 SQL 에는 DELETE 가 있다(실행 안 함).
--
-- 롤백(화면 5~7 을 먼저 되돌린 뒤):
--   DROP FUNCTION IF EXISTS public.resolve_my_orient_link(uuid);
--   DROP FUNCTION IF EXISTS public.get_my_orient_tier_fees(uuid);
--   DROP FUNCTION IF EXISTS public.preview_my_orient_quote(uuid, jsonb);
--   DROP FUNCTION IF EXISTS public.submit_my_orient_sheet(uuid, jsonb, int);
--   DROP FUNCTION IF EXISTS public.save_my_orient_draft(uuid, jsonb, int);
--   DROP FUNCTION IF EXISTS public.get_my_orient_sheet(uuid);
--   DROP FUNCTION IF EXISTS public.get_my_orient_sheets(uuid);
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] get_my_orient_sheets — 목록
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_orient_sheets(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_sheets jsonb;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL OR NOT public.is_my_brand(p_brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY created_at DESC, id), '[]'::jsonb)
    INTO v_sheets
    FROM (
      SELECT s.id, s.created_at,
             jsonb_build_object(
               'id',                  s.id,
               'orient_no',           s.orient_no,
               'layout',              CASE WHEN jsonb_typeof(s.data -> 'issued') = 'object' THEN 'new' ELSE 'old' END,
               'form_type',           s.form_type,
               'channel',             s.data -> 'issued' ->> 'channel',
               'extra_markets',       CASE WHEN s.form_type = 'reviewer' THEN s.data -> 'cards' -> 0 -> 'sale' -> 'extra_markets' ELSE NULL END,
               'goods_code',          s.data -> 'cards' -> 0 -> 'sale' ->> 'goods_code',
               'product_name',        s.data -> 'cards' -> 0 -> 'product' ->> 'name',
               'status',              s.status,
               'view_status',         public._orient_brand_view_status(s.status, s.token_expires_at, s.data, s.last_edited_at, s.version),
               'registered_count',    (SELECT count(*) FROM jsonb_array_elements(
                                          CASE WHEN jsonb_typeof(s.data -> 'cards') = 'array' THEN s.data -> 'cards' ELSE '[]'::jsonb END) c
                                        WHERE jsonb_typeof(c) = 'object' AND COALESCE(c ->> 'campaign_id', '') <> ''),
               'card_count',          (SELECT count(*) FROM jsonb_array_elements(
                                          CASE WHEN jsonb_typeof(s.data -> 'cards') = 'array' THEN s.data -> 'cards' ELSE '[]'::jsonb END) c),
               'issued_at',           s.created_at,
               'deadline_at',         s.token_expires_at,
               'submitted_at',        s.submitted_at,
               'last_submitted_at',   s.last_submitted_at,
               'last_edited_at',      s.last_edited_at,
               'last_edited_by_name', (SELECT NULLIF(btrim(a.name), '') FROM public.brand_accounts a WHERE a.auth_id = s.last_edited_by),
               'last_edited_by_me',   (s.last_edited_by IS NOT NULL AND s.last_edited_by = v_uid),
               'has_unsubmitted_draft', (s.status = 'submitted' AND s.draft_saved_at IS NOT NULL)
             ) AS row_json
        FROM public.orient_sheets s
       WHERE s.brand_id = p_brand_id
    ) t;

  RETURN jsonb_build_object('success', true, 'server_now', now(), 'sheets', v_sheets);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.get_my_orient_sheets(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_sheets(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_sheets(uuid) FROM anon;

COMMENT ON FUNCTION public.get_my_orient_sheets(uuid) IS
  '[540] 브랜드 계정 오리엔시트 목록(STABLE). is_my_brand(p_brand_id) 거짓·비로그인이면 not_found. 발급 최신순. view_status 는 _orient_brand_view_status 만 쓴다. 토큰·created_by·mail_sent_to 는 싣지 않는다. 베이스 = 540.';

-- ------------------------------------------------------------
-- [2] get_my_orient_sheet — 상세
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_orient_sheet(p_sheet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := auth.uid();
  v_s              record;
  v_view           text;
  v_layout         text;
  v_read_only      boolean;
  v_past_deadline  boolean;
  v_data           jsonb;
  v_initial_values jsonb := NULL;
  v_campaigns      jsonb;
  v_out            jsonb;
BEGIN
  IF v_uid IS NULL OR p_sheet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT id, brand_id, application_id, orient_no, form_type, data, status, version, token_expires_at,
         submitted_at, last_submitted_at, last_edited_at, last_edited_by, draft_data
    INTO v_s
    FROM public.orient_sheets
   WHERE id = p_sheet_id;

  IF NOT FOUND OR NOT public.is_my_brand(v_s.brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  v_view   := public._orient_brand_view_status(v_s.status, v_s.token_expires_at, v_s.data, v_s.last_edited_at, v_s.version);
  v_layout := CASE WHEN jsonb_typeof(v_s.data -> 'issued') = 'object' THEN 'new' ELSE 'old' END;

  -- 만료 — 등록 시트는 view_status 가 registered 라 여기 오지 않는다(결정 3)
  IF v_view = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired', 'status', 'expired');
  END IF;

  v_read_only     := (v_view = 'registered' OR v_layout = 'old');
  v_past_deadline := (v_s.token_expires_at IS NOT NULL AND v_s.token_expires_at < now());
  v_data          := v_s.data;

  -- 기한 지난 등록 시트는 견적서를 보이지 않는다(13-4 ⑦)
  IF v_view = 'registered' AND v_past_deadline THEN
    v_data := v_data - 'quote' - 'quote_history' - 'quote_error';
  END IF;

  IF v_s.application_id IS NOT NULL THEN
    SELECT jsonb_build_object('form_type', ba.form_type, 'total_qty', ba.total_qty, 'total_jpy', ba.total_jpy, 'products', ba.products)
      INTO v_initial_values
      FROM public.brand_applications ba
     WHERE ba.id = v_s.application_id;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'card_idx',        (t.ord - 1)::int,
           'campaign_id',     t.c ->> 'campaign_id',
           'linked_existing', COALESCE(t.c -> 'linked_existing' = 'true'::jsonb, false)   -- 형 변환 오류 방지: 불리언 true 만 참
         ) ORDER BY t.ord), '[]'::jsonb)
    INTO v_campaigns
    FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(v_s.data -> 'cards') = 'array' THEN v_s.data -> 'cards' ELSE '[]'::jsonb END
         ) WITH ORDINALITY AS t(c, ord)
   WHERE jsonb_typeof(t.c) = 'object' AND COALESCE(t.c ->> 'campaign_id', '') <> '';

  v_out := jsonb_build_object(
    'success',             true,
    'id',                  v_s.id,
    'brand_id',            v_s.brand_id,
    'orient_no',           v_s.orient_no,
    'layout',              v_layout,
    'form_type',           v_s.form_type,
    'data',                v_data,
    'status',              v_s.status,
    'view_status',         v_view,
    'version',             v_s.version,
    'submitted_at',        v_s.submitted_at,
    'last_submitted_at',   v_s.last_submitted_at,
    'deadline_at',         v_s.token_expires_at,
    'initial_values',      v_initial_values,
    'last_edited_at',      v_s.last_edited_at,
    'last_edited_by_name', (SELECT NULLIF(btrim(a.name), '') FROM public.brand_accounts a WHERE a.auth_id = v_s.last_edited_by),
    'last_edited_by_me',   (v_s.last_edited_by IS NOT NULL AND v_s.last_edited_by = v_uid),
    'read_only',           v_read_only,
    'campaigns',           v_campaigns
  );

  -- 작성본: 524 조건 + 읽기 전용이 아닐 때만([D])
  IF NOT v_read_only AND v_s.status = 'submitted' AND v_s.draft_data IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('draft_data', v_s.draft_data);
  END IF;

  RETURN v_out;
END;
$$;

GRANT  EXECUTE ON FUNCTION public.get_my_orient_sheet(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_sheet(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_sheet(uuid) FROM anon;

COMMENT ON FUNCTION public.get_my_orient_sheet(uuid) IS
  '[540] 브랜드 계정 오리엔시트 상세(STABLE). 시트 brand_id 로 is_my_brand 판정(없음·남의 것·비로그인 = not_found). 524 get_orient_sheet 와 달리 consumed 를 거부하지 않는다 — 등록 시트는 read_only:true 로 열리고 기한 뒤에는 data 에서 quote·quote_history·quote_error 를 뺀다. '
  'view_status=expired 만 {success:false, reason:expired}. draft_data 는 submitted 이고 값이 있고 read_only 가 아닐 때만. 베이스 = 540.';

-- ------------------------------------------------------------
-- [3]~[6] 저장·제출·미리보기·구간 조회 — 권한 확인 뒤 539 본체를 부른다([A])
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_my_orient_draft(p_sheet_id uuid, p_data jsonb, p_version int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_brand uuid;
BEGIN
  IF v_uid IS NULL OR p_sheet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT brand_id INTO v_brand FROM public.orient_sheets WHERE id = p_sheet_id;
  IF v_brand IS NULL OR NOT public.is_my_brand(v_brand) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  RETURN public._orient_save_core(p_sheet_id, p_data, p_version, v_uid);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.save_my_orient_draft(uuid, jsonb, int) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.save_my_orient_draft(uuid, jsonb, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.save_my_orient_draft(uuid, jsonb, int) FROM anon;

COMMENT ON FUNCTION public.save_my_orient_draft(uuid, jsonb, int) IS
  '[540] 브랜드 계정 임시저장 — is_my_brand 확인 뒤 _orient_save_core(…, auth.uid()). 결과 키·거부 이유는 본체(538·539)와 같고 not_found 가 더해진다. 베이스 = 540.';

CREATE OR REPLACE FUNCTION public.submit_my_orient_sheet(p_sheet_id uuid, p_data jsonb, p_version int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_brand uuid;
BEGIN
  IF v_uid IS NULL OR p_sheet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT brand_id INTO v_brand FROM public.orient_sheets WHERE id = p_sheet_id;
  IF v_brand IS NULL OR NOT public.is_my_brand(v_brand) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  RETURN public._orient_submit_core(p_sheet_id, p_data, p_version, v_uid);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.submit_my_orient_sheet(uuid, jsonb, int) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_my_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_my_orient_sheet(uuid, jsonb, int) FROM anon;

COMMENT ON FUNCTION public.submit_my_orient_sheet(uuid, jsonb, int) IS
  '[540] 브랜드 계정 제출 — is_my_brand 확인 뒤 _orient_submit_core(…, auth.uid()). 결과 키(quote·quote_error 포함)·거부 이유는 본체(538·539)와 같고 not_found 가 더해진다. 베이스 = 540.';

CREATE OR REPLACE FUNCTION public.preview_my_orient_quote(p_sheet_id uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand uuid;
BEGIN
  IF auth.uid() IS NULL OR p_sheet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT brand_id INTO v_brand FROM public.orient_sheets WHERE id = p_sheet_id;
  IF v_brand IS NULL OR NOT public.is_my_brand(v_brand) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  RETURN public._orient_preview_core(p_sheet_id, p_data);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.preview_my_orient_quote(uuid, jsonb) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.preview_my_orient_quote(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.preview_my_orient_quote(uuid, jsonb) FROM anon;

COMMENT ON FUNCTION public.preview_my_orient_quote(uuid, jsonb) IS
  '[540] 브랜드 계정 견적 미리보기 — is_my_brand 확인 뒤 _orient_preview_core. 저장 없음. 결과는 430 과 같고 not_found 가 더해진다. 베이스 = 540.';

CREATE OR REPLACE FUNCTION public.get_my_orient_tier_fees(p_sheet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand uuid;
BEGIN
  IF auth.uid() IS NULL OR p_sheet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT brand_id INTO v_brand FROM public.orient_sheets WHERE id = p_sheet_id;
  IF v_brand IS NULL OR NOT public.is_my_brand(v_brand) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  RETURN public._orient_tier_fees_core(p_sheet_id);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.get_my_orient_tier_fees(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_tier_fees(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_orient_tier_fees(uuid) FROM anon;

COMMENT ON FUNCTION public.get_my_orient_tier_fees(uuid) IS
  '[540] 브랜드 계정 구간 단가 조회 — is_my_brand 확인 뒤 _orient_tier_fees_core. 결과는 489 와 같고 not_found 가 더해진다. 베이스 = 540.';

-- ------------------------------------------------------------
-- [7] resolve_my_orient_link — 옛 링크 토큰 → 시트 번호(내용 없음)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_my_orient_link(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand uuid;
  v_id    uuid;
BEGIN
  IF auth.uid() IS NULL OR p_token IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT id, brand_id INTO v_id, v_brand FROM public.orient_sheets WHERE token = p_token;
  IF v_id IS NULL OR NOT public.is_my_brand(v_brand) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  RETURN jsonb_build_object('success', true, 'sheet_id', v_id, 'brand_id', v_brand);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.resolve_my_orient_link(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.resolve_my_orient_link(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.resolve_my_orient_link(uuid) FROM anon;

COMMENT ON FUNCTION public.resolve_my_orient_link(uuid) IS
  '[540] 옛 토큰 링크 → 내 브랜드 시트면 {sheet_id, brand_id}, 아니면 not_found(토큰이 틀린 경우와 구분 안 함). 시트 내용·상태는 싣지 않는다. 베이스 = 540.';

COMMIT;

-- ============================================================
-- 확인 절차 (한 단계씩 실행 — 결과를 보고 다음으로)
--   🔴 SQL 편집기로는 auth.uid() 가 없어 일곱 모두 늘 not_found 다. 편집기로 확인되는 것은 V1(권한)·V2(형식 오류 없이 도는지)뿐.
--
-- [V1] 권한 — 기대: 일곱 모두 acl 맨 앞에 `=X/` 없음 · anon_can 전부 false · auth_can·svc_can 전부 true
--   SELECT p.proname, p.proacl::text AS acl,
--          has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--          has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('get_my_orient_sheets','get_my_orient_sheet','save_my_orient_draft','submit_my_orient_sheet',
--                        'preview_my_orient_quote','get_my_orient_tier_fees','resolve_my_orient_link')
--    ORDER BY p.proname;
--
-- [V2] 일곱을 아무 인자로 1회씩 호출 — 기대: 전부 {"success": false, "reason": "not_found"} (오류 없이)
--   SELECT public.get_my_orient_sheets(gen_random_uuid()),
--          public.get_my_orient_sheet(gen_random_uuid()),
--          public.save_my_orient_draft(gen_random_uuid(), '{}'::jsonb, 0),
--          public.submit_my_orient_sheet(gen_random_uuid(), '{}'::jsonb, 0),
--          public.preview_my_orient_quote(gen_random_uuid(), '{}'::jsonb),
--          public.get_my_orient_tier_fees(gen_random_uuid()),
--          public.resolve_my_orient_link(gen_random_uuid());
--
-- [V3] 로그인 시험은 curl 로 한다 — 시험 계정(zz-b2-owner@example.com / zz-b2-second@example.com)으로 토큰을 받아
--      /rest/v1/rpc/<함수> 를 부른다(개발서버 주소·공개 키는 SUPABASE_ENVS). 작업표 「작업 3 완료 정의」의 항목을 그대로 따른다.
--      · 비로그인(공개 키만): 일곱 모두 실행 권한 오류(42501)
--      · 인플루언서 계정·다른 브랜드 시트·연결 해제 계정: 일곱 모두 not_found
--
--   시험 시트 준비(개발서버만 — brand_id 는 brands 에서 이름으로 찾는다. 고정 id 로 심어 원복을 쉽게):
--     SELECT id, name FROM public.brands WHERE name LIKE '%가나다 시험%';          -- ← 이 id 를 아래 <BRAND> 에
--     INSERT INTO public.orient_sheets (id, orient_no, brand_id, form_type, status, version, token_expires_at, data) VALUES   -- orient_no 는 NOT NULL·UNIQUE(205), 채번은 발급 함수만 하므로 시험 값을 직접
--       ('aaaaaaaa-0000-0000-0000-000000000001', 'zzTEST-O001', '<BRAND>', 'reviewer', 'draft',     0, now() + interval '7 days',  '{"issued":{"form_type":"reviewer","issued_at":"2026-10-16T00:00:00Z"},"cards":[{}]}'),
--       ('aaaaaaaa-0000-0000-0000-000000000002', 'zzTEST-O002', '<BRAND>', 'reviewer', 'submitted', 2, now() - interval '1 day',   '{"issued":{"form_type":"reviewer"},"cards":[{}]}'),
--       ('aaaaaaaa-0000-0000-0000-000000000003', 'zzTEST-O003', '<BRAND>', 'reviewer', 'consumed',  3, now() - interval '1 day',   '{"issued":{"form_type":"reviewer"},"quote":{"x":1},"cards":[{"campaign_id":"11111111-1111-1111-1111-111111111111"}]}'),
--       ('aaaaaaaa-0000-0000-0000-000000000004', 'zzTEST-O004', '<BRAND>', 'seeding',  'draft',     1, now() + interval '7 days',  '{"cards":[{}]}');   -- 옛 구조(issued 없음)
--     -- 그 뒤 토큰 확인: SELECT id, token FROM public.orient_sheets WHERE id::text LIKE 'aaaaaaaa-0000-0000-0000-00000000000%';
--   기대: ①목록 4줄 view_status = new / expired / registered / editing · ②2번 상세 = expired · ③3번 상세 = read_only:true, data 에 quote 없음, campaigns 1건
--         · ④4번 상세 = success + read_only:true(layout old) · ⑤1번 저장 → version 1·last_edited_by_me:true · ⑥토큰으로 resolve → sheet_id
--   원복(시험이 끝나면 반드시):
--     DELETE FROM public.orient_sheets WHERE id::text LIKE 'aaaaaaaa-0000-0000-0000-00000000000%';
-- ============================================================
