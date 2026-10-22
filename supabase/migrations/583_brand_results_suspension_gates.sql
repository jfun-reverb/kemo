-- ============================================================
-- 583_brand_results_suspension_gates.sql
-- 브랜드 계정 이용 제한 · 결과물 열람 정지 — 제한 3: 결과물·배송 판정 + 관리자 전달 거부 (사양서 4-4 · 5-3 · R7 · 작업표 stale 4)
-- 사양서: docs/specs/2026-10-21-brand-account-restriction.md · 작업표 docs/specs/2026-10-21-brand-account-restriction-breakdown.md 「제한 3」
-- (결과물 작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 조각 4c · 배송 작업표 D9 를 이 파일이 맡는다)
--
-- 왜: 결과물 열람 정지(581 표) 중인 브랜드에 결과물(표·엑셀·영수증)과 — 「배송 리스트 포함」이면 — 배송 리스트를 **서버가** 내주지 않는다(F8).
--   🔴 정지 줄이 0건인 동안은 결과가 지금과 같다(관리자 쓰기 함수는 제한 4).
--
-- 고치는 것(베이스 = 마지막 CREATE)
--   1) get_my_brand_campaign_results(uuid)(547) — 「내 브랜드인가」 확인 **뒤**, 공개 꺼짐 **앞**에서 정지면 {success:true, ready:false, reason:'suspended'}.
--      🔴 더 앞에 두면 남의 캠페인에도 suspended 를 돌려줘 정지 여부가 샌다. 서버 함수 brand-campaign-results(보기·엑셀·영수증 서명)는
--      모두 이 함수를 먼저 부르고 ready 가 아니면 그대로 돌려주므로 셋이 함께 막히고 제공 기록도 안 남는다
--   2) _brand_campaign_summary(uuid)(550) — 칸 results_suspended(늘 실음). 정지면 result_posted 를 **싣지 않는다**(목록·상세 「결과물 게시」 「-」)
--   3) 새 _shipping_list_block_reason(uuid) → text — 배송 리스트 「막힌 이유」 판정 한 곳: 'not_found'(내 브랜드 캠페인 아님) · 'not_ready'(시딩형 아님·전달 전) ·
--      'suspended'(배송 포함 정지 — 「내 브랜드」 확인 뒤) · NULL(열림). 🔴 정지 판정은 여기 한 곳(D9). 옛 _shipping_list_open_for_brand(uuid) 는 지운다
--      (반환형이 boolean 이라 이유를 실을 수 없다 — 부르던 셋을 모두 새 판정으로 바꿨다, 다른 호출자 없음: supabase·dev 검색 0건)
--   4) get_my_brand_shipping_summary(uuid)(557) — suspended 면 {success:true, ready:false, reason:'suspended'}, 그 밖은 지금 모양
--   5) _shipping_brand_rows_logged(uuid, text)(557 — 목록 get_my_brand_shipping_list·내려받기 get_my_brand_shipping_export 의 본체) ·
--      save_my_brand_shipping_rows(uuid, jsonb)(557) — suspended 면 {success:false, reason:'suspended'}, 나머지 거부는 지금처럼 not_found.
--      막히면 제공 기록(shipping_view·shipping_excel)이 안 남는다. 목록·내려받기 감싸개 둘은 본문이 같아 고치지 않는다
--   6) admin_deliver_shipping_list(uuid)(557) — 캠페인 브랜드가 배송 포함 정지면 {ok:false, reason:'results_suspended'}(이 함수의 거부 모양 ok/reason) —
--      전달 상태·목록 줄·메일 선점·제공 기록(shipping_deliver) 모두 안 생긴다(R7). 이미 전달된 목록이어도 같은 거부(새로 생기는 것은 없다)
--   · _application_shipping_sync(557 트리거)는 고치지 않는다 — 정지 중에도 승인 줄은 붙고 shipping_auto_add 가 남는다(사양서 4-4 — 받아들임)
--   ⚠️ 알려진 틈: 배송 메일 선점(561 service_claim_shipping_mail)은 정지를 보지 않는다 — 전달 뒤 메일을 못 보낸 채 정지가 걸리면 재시도 창(15분)에
--      「전달됐습니다」 메일이 나갈 수 있다(작업표 범위 밖 — 기획에 알림)
--
-- 실행 권한: 바꾼 함수는 CREATE OR REPLACE(이름·인자·반환형 그대로)라 보존. 새 내부 판정은 postgres 만(557 내부 함수 방식).
-- 🔴 개발서버 적용 → 제한 8 브랜드 배송 안내(kemo-45) · 제한 13-a 관리자 배송 안내(kemo-af) 병합을 같은 날.
-- 🔴 다음 재정의 베이스: get_my_brand_campaign_results·_brand_campaign_summary·get_my_brand_shipping_summary·_shipping_brand_rows_logged·
--    save_my_brand_shipping_rows·admin_deliver_shipping_list 는 이 파일(547·550·557 베이스 금지).
-- 편집기 경고: 뜸 — 「destructive operations」(DROP FUNCTION _shipping_list_open_for_brand). 「Run query」.
-- 롤백(제한 8·13-a 는 먼저 되돌리지 않아도 된다 — 화면은 모르는 이유를 일반 실패로 그린다):
--   547 get_my_brand_campaign_results 블록 · 550 블록 · 557 의 _shipping_list_open_for_brand·get_my_brand_shipping_summary·_shipping_brand_rows_logged·
--   save_my_brand_shipping_rows·admin_deliver_shipping_list 블록과 그 권한 줄 재실행 → DROP FUNCTION public._shipping_list_block_reason(uuid)
-- ============================================================
BEGIN;

-- ── 1. 결과물 조회 (베이스 547) ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_campaign_results(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid  uuid := auth.uid();
  c      public.campaigns%ROWTYPE;
  pub    public.campaign_brand_publish%ROWTYPE;
  v_src  uuid[];
  v_core jsonb;
  v_upd  timestamptz;
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
  v_core := public._results_payload_core(ARRAY[c.id], pub.columns, false);

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
    'columns',       pub.columns,
    'campaign_rows', v_core -> 'campaign_rows',
    'deliverables',  v_core -> 'deliverables',
    'users',         v_core -> 'users',
    'ext_rows',      public._results_ext_rows(v_src, pub.columns, true, true),
    'counts',        public._brand_campaign_result_counts(c.id),
    'updated_at',    v_upd
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaign_results(uuid) IS
  '[583] (547 재정의 — 결과물 열람 정지면 {success:true, ready:false, reason:suspended}, 내 브랜드 확인 뒤·공개 꺼짐 앞) 브랜드 결과물 조회. 내 브랜드 캠페인 아님 → not_found · 정지 → suspended · 공개 꺼짐 → ready:false · 켜짐 → 결과물 본체(_results_payload_core·_results_ext_rows). 서버 함수 brand-campaign-results 가 보기·엑셀·영수증 서명 전에 먼저 부른다.';

-- ── 2. 캠페인 요약 (베이스 550) ─────────────────────────────────
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
  v_out := jsonb_build_object(
    'applied_count',     v_applied  + v_ext,
    'approved_count',    v_approved + v_ext,
    'applied_reverb',    v_applied,
    'approved_reverb',   v_approved,
    'ext_participants',  v_ext,
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
  '[583] (550 재정의 — results_suspended 칸, 정지면 result_posted 없음) 브랜드 캠페인 목록·상세 요약: applied/approved(합계·REVERB)·ext_participants·results_public·results_suspended + 공개 켜짐이고 정지 아니면 result_posted. 내부 전용(547 목록·상세가 붙인다).';

-- ── 3. 배송 리스트 「막힌 이유」 판정 (신설 — 옛 _shipping_list_open_for_brand 대체) ──────
CREATE OR REPLACE FUNCTION public._shipping_list_block_reason(p_campaign_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c public.campaigns%ROWTYPE;
BEGIN
  c := public._shipping_brand_campaign(p_campaign_id);
  IF c.id IS NULL THEN
    RETURN 'not_found';                     -- 내 브랜드 캠페인 아님(정지 여부를 알리지 않는다)
  END IF;
  IF c.recruit_type IS DISTINCT FROM 'gifting'
     OR NOT EXISTS (SELECT 1 FROM public.campaign_shipping_lists s
                     WHERE s.campaign_id = p_campaign_id AND s.delivered_at IS NOT NULL) THEN
    RETURN 'not_ready';                     -- 시딩형 아님 · 아직 전달 전
  END IF;
  -- 🔴 정지 판정은 여기 한 곳(D9) — 「배송 리스트 포함」 정지만
  IF COALESCE((public._brand_active_suspension(c.brand_id) ->> 'include_shipping')::boolean, false) THEN
    RETURN 'suspended';
  END IF;
  RETURN NULL;                              -- 열림
END;
$$;

COMMENT ON FUNCTION public._shipping_list_block_reason(uuid) IS
  '[583] 브랜드 배송 리스트가 막힌 이유 — not_found(내 브랜드 캠페인 아님) · not_ready(시딩형 아님·전달 전) · suspended(배송 포함 결과물 열람 정지) · NULL(열림). 판정 한 곳(옛 _shipping_list_open_for_brand 대체). 내부 전용.';

GRANT  EXECUTE ON FUNCTION public._shipping_list_block_reason(uuid) TO postgres;
REVOKE EXECUTE ON FUNCTION public._shipping_list_block_reason(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_list_block_reason(uuid) FROM anon, authenticated, service_role;

-- ── 4. 배송 요약 (베이스 557) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_shipping_summary(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_block text;   -- 583
  v_pay   jsonb;
BEGIN
  -- 583: 막힌 이유 판정 한 곳(내 브랜드 → 전달 → 정지)
  v_block := public._shipping_list_block_reason(p_campaign_id);
  IF v_block = 'not_found' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  IF v_block = 'suspended' THEN
    RETURN jsonb_build_object('success', true, 'ready', false, 'reason', 'suspended');
  END IF;
  IF v_block IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'ready', false);
  END IF;
  -- 개인정보 없음 · 기록 없음 — 숫자만
  v_pay := public._shipping_rows_payload(p_campaign_id, true, false);
  RETURN jsonb_build_object('success', true, 'ready', true,
                            'delivered_at', v_pay->'delivered_at', 'today', v_pay->'today', 'counts', v_pay->'counts');
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_shipping_summary(uuid) IS
  '[583] (557 재정의 — 배송 포함 정지면 {success:true, ready:false, reason:suspended}) 브랜드 캠페인 상세 배송 카드 숫자. 내 브랜드 캠페인 아님 → not_found · 시딩형 아님·전달 전 → ready:false · 열림 → delivered_at·today·counts. 개인정보·기록 없음.';

-- ── 5. 배송 목록·내려받기 본체 (베이스 557) ─────────────────────────
CREATE OR REPLACE FUNCTION public._shipping_brand_rows_logged(p_campaign_id uuid, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c        public.campaigns%ROWTYPE;
  v_pay    jsonb;
  v_today  date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_persons jsonb;
  v_block  text;   -- 583
BEGIN
  -- 583: 막힌 이유 — 정지만 suspended 로 알리고 나머지는 지금처럼 not_found. 막히면 제공 기록도 안 남는다
  v_block := public._shipping_list_block_reason(p_campaign_id);
  IF v_block = 'suspended' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'suspended');
  END IF;
  IF v_block IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  c := public._shipping_brand_campaign(p_campaign_id);
  v_pay := public._shipping_rows_payload(p_campaign_id, false, false);

  -- 사람 목록 = 응답에 실린 줄의 회원(이름은 브랜드가 받은 모양 그대로) — 회원 번호는 응답에 없지만 기록에는 남긴다
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'influencer_id', a.user_id,
           'name', COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''), NULLIF(btrim(a.user_name), '')))
           ORDER BY sh.row_no), '[]'::jsonb)
    INTO v_persons
    FROM public.campaign_shipments sh
    JOIN public.applications a ON a.id = sh.application_id
    JOIN public.influencers i  ON i.id = a.user_id AND i.is_audit = false
   WHERE sh.campaign_id = p_campaign_id;

  PERFORM public._record_brand_provision(c.brand_id, p_campaign_id, p_action,
                                         public._shipping_provision_columns(), v_persons, NULL, 'brand');

  RETURN jsonb_build_object(
    'success',      true,
    'campaign_no',  c.campaign_no,
    'product',      COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
    'editable',     public._brand_campaign_view_status(c, v_today) <> 'ended',   -- D2
    'delivered_at', v_pay->'delivered_at',
    'today',        v_pay->'today',
    'counts',       v_pay->'counts',
    'carriers',     public._shipping_carriers(),
    'rows',         v_pay->'rows'
  );
END;
$$;

COMMENT ON FUNCTION public._shipping_brand_rows_logged(uuid, text) IS
  '[583] (557 재정의 — 배송 포함 정지면 {success:false, reason:suspended}) 브랜드 배송 목록·내려받기 본체(get_my_brand_shipping_list·get_my_brand_shipping_export 가 부른다). 열림일 때만 줄을 주고 제공 기록(shipping_view·shipping_excel)을 남긴다. 그 밖 거부는 not_found. 내부 전용.';

-- ── 6. 배송 저장 (베이스 557) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.save_my_brand_shipping_rows(p_campaign_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_today   date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c         public.campaigns%ROWTYPE;
  v_saved   jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_seen    integer[] := '{}';
  r         jsonb;
  v_no      integer;
  v_ship    public.campaign_shipments%ROWTYPE;
  v_status  text;
  v_chk     jsonb;
  v_exp     integer;
  v_on      date;
  v_block   text;   -- 583
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 2000 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;

  -- 판정을 잠금 앞에 — 남의 캠페인 번호로 잠금을 쥐지 못하게(전달은 되돌아가지 않으니 앞에서 봐도 안전하다)
  -- 583: 막힌 이유 — 정지만 suspended, 나머지는 지금처럼 not_found
  v_block := public._shipping_list_block_reason(p_campaign_id);
  IF v_block = 'suspended' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'suspended');
  END IF;
  IF v_block IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  PERFORM public._shipping_campaign_lock(p_campaign_id);
  c := public._shipping_brand_campaign(p_campaign_id);
  IF public._brand_campaign_view_status(c, v_today) = 'ended' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'campaign_ended');   -- D2
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    BEGIN
      v_no := NULLIF(r->>'row_no', '')::integer;
    EXCEPTION WHEN invalid_text_representation THEN
      v_no := NULL;
    END;
    IF v_no IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', r->'row_no', 'reason', 'not_found');
      CONTINUE;
    END IF;
    IF v_no = ANY (v_seen) THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'duplicate');
      CONTINUE;
    END IF;
    v_seen := v_seen || v_no;

    SELECT sh.* INTO v_ship
      FROM public.campaign_shipments sh
      JOIN public.applications a ON a.id = sh.application_id
      JOIN public.influencers i  ON i.id = a.user_id AND i.is_audit = false
     WHERE sh.campaign_id = p_campaign_id AND sh.row_no = v_no
     FOR UPDATE OF sh;
    IF NOT FOUND THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'not_found');
      CONTINUE;
    END IF;
    -- 🔴 지금 승인인 줄만 받는다(§4-2)
    SELECT a.status INTO v_status FROM public.applications a WHERE a.id = v_ship.application_id;
    IF v_status IS DISTINCT FROM 'approved' THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'cancelled');
      CONTINUE;
    END IF;
    BEGIN
      v_exp := NULLIF(r->>'expected_version', '')::integer;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      v_exp := NULL;
    END;
    IF v_exp IS DISTINCT FROM v_ship.version THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'version_conflict');
      CONTINUE;
    END IF;
    BEGIN
      v_on := NULLIF(r->>'shipped_on', '')::date;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'invalid_shipped_on');
      CONTINUE;
    END;

    v_chk := public._shipping_check_row(r->>'carrier_code', r->>'carrier_other', r->>'tracking_no', v_on);
    IF NOT (v_chk->>'ok')::boolean THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', v_chk->>'reason');
      CONTINUE;
    END IF;

    UPDATE public.campaign_shipments sh
       SET carrier_code    = v_chk->>'carrier_code',
           carrier_other   = v_chk->>'carrier_other',
           tracking_no     = v_chk->>'tracking_no',
           shipped_on      = (v_chk->>'shipped_on')::date,
           updated_by      = v_uid,
           updated_by_kind = 'brand',
           updated_at      = now(),
           version         = sh.version + 1
     WHERE sh.id = v_ship.id
    RETURNING * INTO v_ship;

    v_saved := v_saved || jsonb_build_object('row_no', v_no, 'version', v_ship.version, 'cleared', (v_chk->>'cleared')::boolean);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'saved', v_saved, 'skipped', v_skipped);
END;
$$;

COMMENT ON FUNCTION public.save_my_brand_shipping_rows(uuid, jsonb) IS
  '[583] (557 재정의 — 배송 포함 정지면 {success:false, reason:suspended}) 브랜드 배송 송장 저장(줄마다 버전 대조). 열림이 아니면 not_found, 종료 캠페인 campaign_ended. 반환 {success, saved[{row_no,version,cleared}], skipped[{row_no,reason}]}.';

-- ── 7. 관리자 배송 리스트 전달 (베이스 557) ──────────────────────────
CREATE OR REPLACE FUNCTION public.admin_deliver_shipping_list(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_today    date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c          public.campaigns%ROWTYPE;
  v_accounts jsonb;
  v_list     public.campaign_shipping_lists%ROWTYPE;
  v_next     integer;
  v_added    integer;
  v_persons  jsonb;
  v_rows     integer;
BEGIN
  IF v_uid IS NULL OR NOT public.has_permission('shipping.manage', 'write') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 🔴 잠금 먼저, 읽기는 그 뒤(554 [K1])
  PERFORM public._shipping_campaign_lock(p_campaign_id);

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF c.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'campaign_deleted');
  END IF;
  IF c.recruit_type IS DISTINCT FROM 'gifting' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_gifting');
  END IF;

  -- 583: 「배송 리스트 포함」 결과물 열람 정지 중이면 전달하지 않는다(R7) — 목록 줄·전달 상태·메일 선점·제공 기록 모두 안 생긴다
  IF c.brand_id IS NOT NULL
     AND COALESCE((public._brand_active_suspension(c.brand_id) ->> 'include_shipping')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'results_suspended');
  END IF;

  v_accounts := CASE WHEN c.brand_id IS NULL THEN '[]'::jsonb ELSE public._brand_mailable_accounts(c.brand_id) END;

  INSERT INTO public.campaign_shipping_lists (campaign_id) VALUES (p_campaign_id)
  ON CONFLICT (campaign_id) DO NOTHING;
  SELECT * INTO v_list FROM public.campaign_shipping_lists WHERE campaign_id = p_campaign_id;

  -- 이미 전달됨 — 오류가 아니다(기록·메일 없음, 두 관리자가 동시에 눌러도 true 는 한 번)
  IF v_list.delivered_at IS NOT NULL THEN
    SELECT count(*) INTO v_rows FROM public.campaign_shipments WHERE campaign_id = p_campaign_id;
    RETURN jsonb_build_object('ok', true, 'delivered_now', false, 'delivered_at', v_list.delivered_at,
                              'row_count', v_rows, 'account_count', jsonb_array_length(v_accounts));
  END IF;

  IF jsonb_array_length(v_accounts) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_account');
  END IF;

  -- ③ 지금 승인이 아닌(또는 감사용) 응모의 줄은 지운다 — 전달 전에 빠진 분은 넣지 않는다(§4-2)
  DELETE FROM public.campaign_shipments sh
   USING public.applications a
   LEFT JOIN public.influencers i ON i.id = a.user_id
   WHERE sh.application_id = a.id
     AND sh.campaign_id = p_campaign_id
     AND (a.status IS DISTINCT FROM 'approved' OR COALESCE(i.is_audit, true));

  -- ① 승인인데 줄이 없는 응모에 줄(승인 시각 순으로 번호)
  v_next := v_list.next_row_no;
  WITH todo AS (
    SELECT a.id, row_number() OVER (ORDER BY a.reviewed_at NULLS LAST, a.created_at, a.id) AS rn
      FROM public.applications a
      JOIN public.influencers i ON i.id = a.user_id AND i.is_audit = false
     WHERE a.campaign_id = p_campaign_id
       AND a.status = 'approved'
       AND NOT EXISTS (SELECT 1 FROM public.campaign_shipments sh WHERE sh.application_id = a.id)
  ), ins AS (
    INSERT INTO public.campaign_shipments (campaign_id, application_id, row_no, added_on, added_at)
    SELECT p_campaign_id, t.id, v_next + t.rn - 1, v_today, now() FROM todo t
    RETURNING 1
  )
  SELECT count(*) INTO v_added FROM ins;

  -- ② 모든 줄의 기한 기준일 = 전달한 날(D14)
  UPDATE public.campaign_shipments SET added_on = v_today WHERE campaign_id = p_campaign_id;

  UPDATE public.campaign_shipping_lists
     SET delivered_at = now(),
         delivered_by = v_uid,
         next_row_no  = v_next + v_added,
         version      = version + 1
   WHERE campaign_id = p_campaign_id;

  -- 제공 기록 — 그 순간 리스트에 든 사람 전부 [L7]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'influencer_id', a.user_id,
           'name', COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''), NULLIF(btrim(a.user_name), '')))
           ORDER BY sh.row_no), '[]'::jsonb), count(*)
    INTO v_persons, v_rows
    FROM public.campaign_shipments sh
    JOIN public.applications a ON a.id = sh.application_id
    JOIN public.influencers i  ON i.id = a.user_id
   WHERE sh.campaign_id = p_campaign_id;

  PERFORM public._record_brand_provision(c.brand_id, p_campaign_id, 'shipping_deliver',
                                         public._shipping_provision_columns(), v_persons, v_uid, 'admin');

  RETURN jsonb_build_object('ok', true, 'delivered_now', true, 'delivered_at', now(),
                            'row_count', v_rows, 'account_count', jsonb_array_length(v_accounts));
END;
$$;

COMMENT ON FUNCTION public.admin_deliver_shipping_list(uuid) IS
  '[583] (557 재정의 — 배송 포함 결과물 열람 정지면 {ok:false, reason:results_suspended}, 아무것도 안 만든다) 관리자 배송 리스트 전달. 반환 {ok, reason?: not_found|campaign_deleted|not_gifting|results_suspended|no_account, delivered_now, delivered_at, row_count, account_count}. 가드 has_permission(shipping.manage, write).';

-- ── 8. 옛 판정 지우기 (위 셋이 모두 새 판정으로 바뀐 뒤) ───────────────────
DROP FUNCTION IF EXISTS public._shipping_list_open_for_brand(uuid);

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '583', '583_brand_results_suspension_gates.sql');
COMMIT;
