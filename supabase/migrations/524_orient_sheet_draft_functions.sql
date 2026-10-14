-- ============================================================
-- 524_orient_sheet_draft_functions.sql
-- 2026-10-14 — 오리엔시트 「제출 뒤 수정은 작성본에만 저장」 ② 함수 3종 재정의
--   사양서 docs/specs/2026-10-01-orient-sheet-post-submit-draft.md 설계 ①-②
--   선행: 523(draft_data·draft_saved_at 칸)
--
-- 베이스(현재 원본 — 2026-10-14 CREATE 가 있는 파일만 세어 확인)
--   get_orient_sheet    = 187
--   save_orient_draft   = 425
--   submit_orient_sheet = 461
--   🔴 다음 재정의의 베이스는 셋 다 이 파일(524)이다.
--
-- 무엇을 바꾸나
--   [A] get_orient_sheet — 반환에 draft_data 를 더한다. 🔴 status='submitted' 이고 값이 있을 때만 키를 싣는다
--       (발행·만료 시트는 이 함수가 앞에서 이미 실패로 돌려보낸다). 나머지는 187 글자 그대로.
--   [B] save_orient_draft — status='submitted' 이면 보정(카드 번호 293 · 발행 카드 복구 328 · 서버 키 425·445,
--       🔴 기준은 제출본 data)을 거친 값을 data 가 아니라 draft_data 에 쓰고 draft_saved_at = now().
--       보정한 값이 제출본과 같으면 두 칸을 NULL 로(「내용 수정하기」로 들어와 아무것도 안 고쳐도 「수정 중」이 안 뜬다
--       — 고쳤다가 원래대로 되돌린 경우도 같다). draft(작성 중) 상태는 425 그대로 data 에.
--       낙관적 잠금(version +1)·100KB 상한·반환 키는 425 그대로.
--       🔴 거부를 새로 걸지 않는다(425·429·446 원칙 — 자동저장이 실패하면 작성 중인 글을 잃는다).
--   [C] submit_orient_sheet — 461 글자 그대로 + 성공 UPDATE 에서 draft_data·draft_saved_at 을 NULL 로.
--       제출 내용은 지금처럼 폼이 보낸 값(폼이 작성본을 보낸다).
--
-- ⚠️ 셋 다 익명 실행 함수 — 인자 목록이 그대로라 CREATE OR REPLACE 로 충분하다(반환은 jsonb 라 키만 는다).
--    저장소 관례대로 REVOKE·GRANT 를 다시 적는다(187·425·461 과 같은 대상).
-- ⚠️ 제출 알림 웹훅(notify-orient-submitted)은 Row filter status='submitted' 라 작성본 UPDATE 에도 불리지만,
--    게이트 ①(last_submitted_at 이 그대로면 건너뜀)이 지금 data UPDATE 를 거르듯 똑같이 거른다 — 새 비용 없음.
--
-- 편집기 경고: 안 뜸(CREATE OR REPLACE·REVOKE·GRANT 만 — 함수 본문에 DELETE·DROP 없음).
-- 롤백: 187 의 [A] 블록 · 425 의 [B] 블록 · 461 의 [5] 블록을 그대로 재실행(셋 다 CREATE OR REPLACE).
--       그 뒤 523 롤백. ⚠️ 롤백 시점에 쌓여 있던 작성본(draft_data)은 제출본에 반영되지 않은 채 버려진다.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] get_orient_sheet — 베이스 187. 변경점은 [524] 표시
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_orient_sheet(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet          record;
  v_initial_values jsonb := NULL;
  v_out            jsonb;
BEGIN
  -- 토큰으로 오리엔시트 행 조회
  SELECT id, brand_id, application_id, form_type, data, status, version,
         token_expires_at, submitted_at, consumed_at, campaign_id,
         draft_data                                    -- [524]
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token;

  -- 미매칭: UUID v4 엔트로피(122 bit)로 무차별 대입 사실상 불가.
  -- 잘못된 토큰은 success=false 반환 (자원 열거 공격 방지 — 140 패턴 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- consumed 상태: 캠페인 발행 완료, 더 이상 수정 불가
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'consumed',
      'status',  'consumed'
    );
  END IF;

  -- 만료 판정(P1-1): 조회 함수는 읽기 전용. 실제 status='expired' 전환은
  --   쓰기 함수(save_orient_draft·submit_orient_sheet)가 FOR UPDATE 잠금 하에 수행한다.
  --   여기서는 만료를 반환값으로만 알린다(조회 함수의 쓰기 부작용·동시 조회 race 제거).
  IF v_sheet.status = 'expired'
     OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now())
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'expired',
      'status',  'expired'
    );
  END IF;

  -- 연결된 신청이 있으면 모집 희망값을 initial_values로 반환 (잔여②)
  -- brand_applications의 관련 필드: products(모집 수량/종류), total_qty, total_jpy
  -- 추가로 form_type도 승계 참고로 포함
  IF v_sheet.application_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'form_type',   ba.form_type,
             'total_qty',   ba.total_qty,
             'total_jpy',   ba.total_jpy,
             'products',    ba.products
           )
      INTO v_initial_values
      FROM public.brand_applications ba
     WHERE ba.id = v_sheet.application_id;
    -- 신청 행이 삭제됐거나 못 찾으면 NULL 유지 (오류 없이 진행)
  END IF;

  -- 정상 반환: data, status, version + 초기값(있는 경우)
  v_out := jsonb_build_object(
    'success',        true,
    'id',             v_sheet.id,
    'form_type',      v_sheet.form_type,
    'data',           v_sheet.data,
    'status',         v_sheet.status,
    'version',        v_sheet.version,
    'submitted_at',   v_sheet.submitted_at,
    'initial_values', v_initial_values   -- NULL이면 JSON null로 직렬화됨
  );

  -- [524] 작성본 — 제출된 시트에 값이 있을 때만 키를 싣는다. 폼은 작성 화면을 이 값(없으면 data)으로 채우고,
  --   완료 화면·견적서는 계속 data(제출본)를 쓴다.
  IF v_sheet.status = 'submitted' AND v_sheet.draft_data IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('draft_data', v_sheet.draft_data);
  END IF;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_orient_sheet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_orient_sheet(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_orient_sheet(uuid) IS
  '[187, 524 개정] 오리엔시트 토큰 조회. anon GRANT — 로그인 없이 토큰만으로 현재 내용·상태 반환. '
  '미매칭·만료·소비 상태는 success=false. 연결 신청이 있으면 initial_values에 모집 희망값 포함. '
  '[524] status=submitted 이고 작성본이 있으면 draft_data 키를 더한다(없으면 키 없음). '
  'SECURITY DEFINER + search_path 고정. 🔴 다음 재정의의 베이스는 524.';

-- ------------------------------------------------------------
-- [B] save_orient_draft — 베이스 425. 변경점은 [524] 표시
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_orient_draft(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet        record;
  v_data_size    int;
  v_rows_updated int;
  v_data         jsonb;
  v_card_uids    jsonb;
BEGIN
  SELECT id, status, version, token_expires_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 보정 세 단계 — 425 와 글자 그대로. 🔴 [524] 기준(두 번째 인자)은 언제나 data = 제출본(또는 작성 중 판)이다.
  --   작성본(draft_data)을 기준으로 삼으면 발행 카드 복구·서버 키 보존이 브랜드가 고친 판을 원본으로 착각한다.
  -- 카드 고유 번호 보정 (293)
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드 복구 (328)
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- [425] 서버 키 보존 + 형식·채널 원본 덮어쓰기. 🔴 임시저장은 어떤 거부도 걸지 않는다.
  v_data := public._orient_apply_issued_rules(v_data, v_sheet.data);

  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
      'actual_bytes', v_data_size
    );
  END IF;

  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  IF v_sheet.status = 'submitted' THEN
    -- [524] 제출된 시트 — 제출본(data)은 그대로 두고 작성본 칸에만 쓴다. 「다시 제출」해야 data 가 바뀐다.
    --   보정한 값이 제출본과 같으면(아무것도 안 고침·고쳤다가 되돌림) 작성본을 비운다 — 관리자 「수정 중」 표시가 거짓이 되지 않게.
    --   jsonb 의 = 는 키 순서·공백과 무관하게 내용으로 비교한다.
    IF v_data = v_sheet.data THEN
      UPDATE public.orient_sheets
         SET draft_data     = NULL,
             draft_saved_at = NULL,
             version        = v_sheet.version + 1
       WHERE id      = v_sheet.id
         AND version = p_version;
    ELSE
      UPDATE public.orient_sheets
         SET draft_data     = v_data,
             draft_saved_at = now(),
             version        = v_sheet.version + 1
       WHERE id      = v_sheet.id
         AND version = p_version;
    END IF;
  ELSE
    -- 작성 중(draft) — 425 그대로 data 에 쓴다(미제출 시트는 발행 대상이 아니다).
    UPDATE public.orient_sheets
       SET data    = v_data,
           version = v_sheet.version + 1
     WHERE id      = v_sheet.id
       AND version = p_version;
  END IF;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'conflict'
    );
  END IF;

  v_card_uids := public._orient_sent_card_uids(p_data, v_data);

  RETURN jsonb_build_object(
    'success',   true,
    'version',   v_sheet.version + 1,
    'card_uids', v_card_uids
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328, 329, 425, 524 개정] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) '
  '(기준은 언제나 data) → 그 최종 값 기준 jsonb 100KB 상한. 임시저장에는 카드 수·글자 수 거부를 걸지 않는다(자동저장 보호). '
  '[524] status=submitted 면 data 를 건드리지 않고 draft_data·draft_saved_at 에 쓴다(보정 값이 data 와 같으면 둘 다 NULL). '
  'draft 상태는 data 에. 성공 응답에 card_uids. status 미변경. SECURITY DEFINER + search_path 고정. 🔴 다음 재정의의 베이스는 524.';

-- ------------------------------------------------------------
-- [C] submit_orient_sheet — 베이스 461(글자 그대로). 변경점은 성공 UPDATE 의 [524] 두 줄뿐
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_orient_sheet(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet        record;
  v_data_size    int;
  v_rows_updated int;
  v_now          timestamptz := now();
  v_is_first     boolean;
  v_data         jsonb;
  v_card_uids    jsonb;
  -- [425]
  v_is_new       boolean;
  v_cards        jsonb;
  v_card0        jsonb;
  v_len          integer;
  -- [427·430] 견적 — 계산 변수는 _orient_compute_quote 로 갔다
  v_calc         jsonb;
  v_quote        jsonb;
  v_quote_error  text;
  -- [446] 고정 안내 확인
  v_ack_ft       text;
  -- [459→461] 최소 인원 — 제출만 막는다(§3-3). 461 부터 그 시트 형식의 열쇠를 읽는다.
  v_slots_txt    text;
  v_slots_chk    integer;
  v_min_slots    numeric;
  v_tier_prefix  text;
BEGIN
  SELECT id, brand_id, application_id, form_type, orient_no, token_expires_at,
         status, version, submitted_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;

  -- 카드 고유 번호 보정 (293) — 329 와 글자 그대로
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드 복구 (328) — 329 와 글자 그대로
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- [425] 서버 키 보존 + 형식·채널 원본 덮어쓰기 (save_orient_draft 와 같은 헬퍼) — 🔴 견적 계산보다 먼저
  v_data := public._orient_apply_issued_rules(v_data, v_sheet.data);

  -- [425] 새 구조(issued 있음) 시트만 — 카드 1개 제한 + 글자 수 재검증. 옛 시트는 어느 검사도 받지 않는다.
  v_is_new := (v_data -> 'issued') IS NOT NULL AND jsonb_typeof(v_data -> 'issued') = 'object';
  IF v_is_new THEN
    v_cards := v_data -> 'cards';
    IF v_cards IS NOT NULL AND jsonb_typeof(v_cards) = 'array' AND jsonb_array_length(v_cards) > 1 THEN
      RETURN jsonb_build_object('success', false, 'reason', 'cards_limit', 'limit', 1,
                                'actual', jsonb_array_length(v_cards));
    END IF;
    IF v_cards IS NOT NULL AND jsonb_typeof(v_cards) = 'array' AND jsonb_array_length(v_cards) = 1
       AND jsonb_typeof(v_cards -> 0) = 'object' THEN
      v_card0 := v_cards -> 0;

      -- [461] 최소 인원 — 그 시트 형식(issued.form_type)의 열쇠를 읽는다. 인원을 안 넣었으면
      --   (빈 문자열) 건너뛴다(그 경우는 아래 견적 계산이 slots_missing 으로 이미 막는다). 형식을
      --   못 정하거나(방어적 — 424 가 막으므로 실제로는 도달하지 않는다) 그 형식의 행이 없으면
      --   1 로 본다(=아무도 안 막는다, get_orient_tier_fees 의 기본값과 같은 값).
      --   🔴 임시저장(save_orient_draft)에는 이 검사를 걸지 않는다 — 자동저장 보호(429 와 같은 원칙).
      v_slots_txt := regexp_replace(COALESCE(v_card0 -> 'product' ->> 'slots', ''), '[^0-9]', '', 'g');
      IF v_slots_txt <> '' THEN
        v_slots_chk := LEAST(v_slots_txt::numeric, 999999)::integer;
        v_tier_prefix := public._orient_tier_prefix(v_data -> 'issued' ->> 'form_type');
        v_min_slots := NULL;
        IF v_tier_prefix IS NOT NULL THEN
          SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = v_tier_prefix || 'min_slots';
        END IF;
        v_min_slots := COALESCE(v_min_slots, 1);
        IF v_slots_chk < v_min_slots THEN
          RETURN jsonb_build_object('success', false, 'reason', 'slots_below_min', 'min_slots', v_min_slots);
        END IF;
      END IF;

      v_len := public._orient_text_length(v_card0 ->> 'review_guide');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'guide_too_long', 'limit', 1000, 'actual', v_len);
      END IF;
      v_len := public._orient_text_length(v_card0 -> 'seeding' ->> 'appeal');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'appeal_too_long', 'limit', 1000, 'actual', v_len);
      END IF;
      -- [429] 긴 글 칸 4종 추가 — 거부 코드 하나(text_too_long) + field 로 어느 칸인지
      v_len := public._orient_text_length(v_card0 -> 'seeding' ->> 'shooting_guide');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'text_too_long', 'field', 'shooting_guide', 'limit', 1000, 'actual', v_len);
      END IF;
      v_len := public._orient_text_length(v_card0 -> 'seeding' ->> 'shipping_note');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'text_too_long', 'field', 'shipping_note', 'limit', 1000, 'actual', v_len);
      END IF;
      v_len := public._orient_text_length(v_card0 ->> 'ng');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'text_too_long', 'field', 'ng', 'limit', 1000, 'actual', v_len);
      END IF;
      v_len := public._orient_text_length(v_card0 ->> 'cautions');
      IF v_len > 1000 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'text_too_long', 'field', 'cautions', 'limit', 1000, 'actual', v_len);
      END IF;
    END IF;
  END IF;

  -- ── [446] 브랜드 고정 안내 확인 — 새 구조 시트만. 옛 시트는 이 열쇠말을 모른다(검사하지 않는다) ──
  --   통과 조건: 확인 기록(notice_ack)이 이미 있거나, 폼이 notice_ack_checked = true 를 보냈다.
  --   🔴 v_data 의 notice_ack 는 바로 위 _orient_apply_issued_rules(445) 가 **저장돼 있던 값으로 되돌린 것**이다 —
  --      폼이 멋대로 보낸 notice_ack 는 그 헬퍼가 이미 지웠으므로 여기서 「있다」는 곧 「서버가 예전에 썼다」는 뜻이다.
  --   🔴 임시저장(save_orient_draft)에는 이 검사가 없다 — 걸면 자동저장이 계속 실패하며 작성 중인 글을 잃는다.
  IF v_is_new THEN
    IF NOT (v_data ? 'notice_ack' AND jsonb_typeof(v_data -> 'notice_ack') = 'object')
       AND (v_data -> 'notice_ack_checked') IS DISTINCT FROM 'true'::jsonb THEN
      RETURN jsonb_build_object('success', false, 'reason', 'notice_not_acknowledged');
    END IF;
    -- 기록 — 처음 확인한 제출에서 한 번만 쓴다(재제출이 최초 확인 시각을 덮지 않는다).
    --   🔴 시각은 서버가 찍는다. 폼은 「체크했다」만 보낸다.
    --   version 은 자리만 잡아 둔 값(1 고정) — 지금은 아무것도 판정하지 않는다(사양서 §4-8).
    IF NOT (v_data ? 'notice_ack' AND jsonb_typeof(v_data -> 'notice_ack') = 'object') THEN
      v_ack_ft := v_data -> 'issued' ->> 'form_type';
      v_data := jsonb_set(v_data, ARRAY['notice_ack'],
                          jsonb_build_object('version', 1, 'at', v_now, 'form_type', v_ack_ft), true);
    END IF;
  END IF;

  -- ── [427·430] 견적 계산 — 새 구조 시트만. 제출을 막지 않는다(실패는 quote_error 로만) ──
  --   본문은 _orient_compute_quote(현재 원본 461) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
  --   블록 전체를 예외 보호로 감싼다 — 지금 못 본 예외(기준값 표가 이상해지는 등)가 생겨도 「제출은 통과」가 구조로 보장된다.
  IF v_is_new AND v_card0 IS NOT NULL THEN
   BEGIN
    v_calc := public._orient_compute_quote(v_data, v_sheet.orient_no, v_sheet.token_expires_at, v_now);
    v_data := v_calc -> 'data';
    v_quote := CASE WHEN jsonb_typeof(v_calc -> 'quote') = 'object' THEN v_calc -> 'quote' ELSE NULL END;
    v_quote_error := v_calc ->> 'quote_error';
   EXCEPTION WHEN OTHERS THEN
    -- 계산 중 예상 못 한 오류 — 견적만 포기하고 제출은 살린다. 세트 규칙대로 quote 는 없애고 사유만 남긴다.
    RAISE WARNING '[submit_orient_sheet] quote calc failed for %: % (%)', v_sheet.orient_no, SQLERRM, SQLSTATE;
    v_quote := NULL;
    v_quote_error := 'calc_error';
    v_data := (v_data - 'quote');
    v_data := jsonb_set(v_data, ARRAY['quote_error'], to_jsonb(v_quote_error), true);
   END;
  END IF;

  -- 크기 상한 — 견적 스냅샷까지 얹은 최종값 기준
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'reason',       'data_too_large',
      'limit_bytes',  102400,
      'actual_bytes', v_data_size
    );
  END IF;

  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  v_is_first := (v_sheet.submitted_at IS NULL);

  UPDATE public.orient_sheets
     SET data              = v_data,
         status            = 'submitted',
         submitted_at      = COALESCE(v_sheet.submitted_at, v_now),
         last_submitted_at = v_now,
         version           = v_sheet.version + 1,
         -- [524] 다시 제출하면 작성본은 제출본이 됐으므로 비운다(관리자 「수정 중」 표시도 함께 사라진다)
         draft_data        = NULL,
         draft_saved_at    = NULL
   WHERE id      = v_sheet.id
     AND version = p_version;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'conflict');
  END IF;

  v_card_uids := public._orient_sent_card_uids(p_data, v_data);

  RETURN jsonb_build_object(
    'success',             true,
    'version',             v_sheet.version + 1,
    'submitted_at',        COALESCE(v_sheet.submitted_at, v_now),
    'last_submitted_at',   v_now,
    'is_first_submission', v_is_first,
    'orient_sheet_id',     v_sheet.id,
    'brand_id',            v_sheet.brand_id,
    'form_type',           v_sheet.form_type,
    'application_id',      v_sheet.application_id,
    'card_uids',           v_card_uids,
    'quote',               v_quote,         -- [427] 성공 시 견적 스냅샷, 아니면 NULL
    'quote_error',         v_quote_error    -- [427] 실패 사유(price_unreadable·slots_missing), 아니면 NULL. 🔴 slots_below_min 은
                                             --   이 칸이 아니라 이 함수의 별도 조기 RETURN(reason='slots_below_min')으로 나간다 — 여기 도달했다는 건 그 검사를 이미 통과했다는 뜻
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446, 459, 461, 524 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429) → '
  '[461] 최소 인원 — 그 시트 형식(issued.form_type)의 열쇠(reviewer_tier_min_slots·seeding_tier_min_slots) 미만이면 '
  'slots_below_min 거부(임시저장은 검사 안 함, 값 못 읽으면 건너뜀, 형식 불명·행 없으면 1) → '
  '[446] 고정 안내 확인(notice_ack 도 없고 notice_ack_checked 도 참이 아니면 notice_not_acknowledged 거부, 통과하면 notice_ack={version,at 서버시각,form_type} 최초 1회 기록) → '
  '[427·430] 견적 계산(_orient_compute_quote 공용 — 현재 원본 463). 세트 규칙: 제출마다 quote 또는 quote_error 하나만. 견적 실패도 제출은 통과. '
  '[524] 성공 시 작성본(draft_data·draft_saved_at)을 비운다. '
  '옛 시트는 어느 검사도 받지 않는다. 🔴 다음 재정의의 베이스는 524.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 익명 함수라 SQL 편집기 호출도 통한다. 실제 토큰 T 로)
-- ============================================================
-- [V1] 정의 확인 — 세 함수 본문에 draft_ 가 들어 있다
-- SELECT p.proname, position('draft_' in pg_get_functiondef(p.oid)) > 0 AS has_draft
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname IN ('get_orient_sheet','save_orient_draft','submit_orient_sheet');
-- [V2] 권한 — 셋 다 anon 실행 가능(get 은 authenticated 도), PUBLIC 없음(proacl 맨 앞에 =X/ 없음)
-- SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname IN ('get_orient_sheet','save_orient_draft','submit_orient_sheet');
-- [V3] 제출된 시트 T 에서 내용을 고쳐 save_orient_draft → data 는 그대로, draft_data·draft_saved_at 채워짐
-- [V4] 같은 시트에서 제출본과 같은 내용으로 save → draft_data·draft_saved_at NULL
-- [V5] get_orient_sheet(T) → 작성본이 있으면 draft_data 키, 없으면 키 없음
-- [V6] submit → data 가 새 값, draft_data·draft_saved_at NULL
-- [V7] 작성 중(draft) 시트의 save → 종전대로 data 에, draft_data 는 NULL 그대로
