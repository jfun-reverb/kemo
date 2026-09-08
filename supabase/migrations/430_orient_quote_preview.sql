-- ============================================================
-- 430_orient_quote_preview.sql
-- 2026-09-08 — 오리엔시트 단순화 · 제출 전 견적 미리보기 (사용자 지시 2026-09-08 「이대로 제출 대신 견적 보기 → 견적서 화면에서 제출」)
--   사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-6
--
-- 🔴 베이스 = **429**(submit_orient_sheet ③차 — 견적 계산 + 글자 수 6칸). 다음 재정의의 베이스는 이 파일(430).
--
-- 무엇이 바뀌나
--   [A] _orient_compute_quote(p_data, p_orient_no, p_valid_until, p_now) — 429 의 견적 계산 블록을 **글자 그대로** 헬퍼로 분리.
--       제출·미리보기 둘 다 이 함수를 부른다(계산식이 두 벌이 되면 화면에서 본 금액과 저장된 금액이 갈린다).
--   [B] submit_orient_sheet — 계산 블록을 헬퍼 호출로 바꿨을 뿐, 검사·세트 규칙·예외 보호·반환값은 429 와 같다.
--   [C] preview_orient_quote(p_token, p_data) — 익명 호출. 저장하지 않고 지금 화면 값으로 견적을 계산해 돌려준다.
--       서버 키 보존(_orient_apply_issued_rules)을 거쳐 저장된 issued·quote·quote_history 기준으로 계산하므로
--       판 번호(revision)·견적 번호가 **바로 이어질 제출과 같다**. 옛 시트(issued 없음)는 not_new_layout.
--       실패 사유(slots_missing·price_unreadable·calc_error)는 quote_error 로 — 제출과 같은 값이라 폼이 같은 문구를 쓴다.
--   🔴 미리보기는 아무것도 쓰지 않는다 — 이력(quote_history)도 안 늘고 판도 안 오른다. 제출할 때만 남는다.
--
BEGIN;

-- [A] 견적 계산 헬퍼 — 제출(submit_orient_sheet)과 미리보기(preview_orient_quote)가 **같은 본문**을 쓴다.
--   429 의 계산 블록을 글자 그대로 옮겼다(v_sheet.* → 인자, v_now → p_now). 예외 처리는 부르는 쪽이 한다.
--   반환: {data: 견적·이력을 얹은 data, quote: 성공 시 스냅샷 | null, quote_error: 실패 사유 | null}
CREATE OR REPLACE FUNCTION public._orient_compute_quote(
  p_data        jsonb,        -- 서버 키 보존까지 끝난 data(issued 있음, cards[0] 있음)
  p_orient_no   text,
  p_valid_until timestamptz,  -- 견적 유효기간 = 토큰 만료
  p_now         timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_data         jsonb := p_data;
  v_card0        jsonb := p_data -> 'cards' -> 0;
  v_ft           text;
  v_ch           text;
  v_basis        jsonb;
  v_rate         numeric;
  v_transfer     numeric;
  v_recruit      numeric;
  v_vat_rate     numeric;
  v_fee          numeric;
  v_slots_txt    text;
  v_slots        integer;
  v_price_txt    text;
  v_price_jpy    numeric;
  v_lines        jsonb;
  v_subtotal     numeric;
  v_vat          numeric;
  v_total        numeric;
  v_prev_quote   jsonb;
  v_history      jsonb;
  v_revision     integer;
  v_quote        jsonb;
  v_quote_error  text;
  v_ch_label     text;
BEGIN
  v_ft := v_data -> 'issued' ->> 'form_type';
  v_ch := v_data -> 'issued' ->> 'channel';
  v_quote := NULL;
  v_quote_error := NULL;

  -- 기준값 전부(basis 스냅샷용) — 관리자가 나중에 값을 바꿔도 이 판이 무엇으로 계산됐는지 남는다
  SELECT COALESCE(jsonb_object_agg(q.key, q.amount), '{}'::jsonb) INTO v_basis FROM public.quote_settings q;
  v_rate     := COALESCE((v_basis ->> 'exchange_rate_krw_per_jpy')::numeric, 0);
  v_transfer := COALESCE((v_basis ->> 'reviewer_transfer_fee_krw')::numeric, 0);
  v_recruit  := COALESCE((v_basis ->> 'reviewer_recruit_fee_krw')::numeric, 0);
  v_vat_rate := COALESCE((v_basis ->> 'vat_rate')::numeric, 0);

  -- 모집 인원 — 숫자만
  v_slots_txt := regexp_replace(COALESCE(v_card0 -> 'product' ->> 'slots', ''), '[^0-9]', '', 'g');
  -- ⚠️ numeric 을 거친다 — bigint 로 바로 바꾸면 20자리 넘는 입력(송장번호 붙여넣기·임의 호출)에 22003 으로 제출이 죽는다(리뷰 지적)
  v_slots := CASE WHEN v_slots_txt = '' THEN NULL ELSE LEAST(v_slots_txt::numeric, 999999)::integer END;

  IF v_slots IS NULL OR v_slots <= 0 THEN
    v_quote_error := 'slots_missing';
  ELSIF v_ft = 'reviewer' THEN
    -- 상시가 — 첫 숫자 덩어리만(「3,429엔 (가격소구금지)」 → 3429). 없으면 price_unreadable
    v_price_txt := (regexp_match(COALESCE(v_card0 -> 'sale' ->> 'price_regular', ''), '[0-9][0-9,]*'))[1];
    v_price_txt := replace(COALESCE(v_price_txt, ''), ',', '');
    IF v_price_txt = '' THEN
      v_quote_error := 'price_unreadable';
    ELSE
      v_price_jpy := v_price_txt::numeric;
      v_lines := jsonb_build_array(
        jsonb_build_object('key', 'payback',  'label', '제품 구매 페이백 (상시가 × 환율)', 'qty', v_slots,
                           'unit_krw', floor(v_price_jpy * v_rate), 'amount_krw', floor(v_price_jpy * v_rate * v_slots)),
        jsonb_build_object('key', 'transfer', 'label', '해외 송금 수수료', 'qty', v_slots,
                           'unit_krw', v_transfer, 'amount_krw', floor(v_transfer * v_slots)),
        jsonb_build_object('key', 'recruit',  'label', '모집비', 'qty', v_slots,
                           'unit_krw', v_recruit, 'amount_krw', floor(v_recruit * v_slots))
      );
    END IF;
  ELSIF v_ft = 'seeding' THEN
    v_fee := COALESCE((v_basis ->> ('seeding_fee_krw_' || COALESCE(v_ch, '')))::numeric, 0);
    v_ch_label := CASE v_ch
      WHEN 'instagram_feed'  THEN '인스타그램-피드'    -- ⚠️ 화면(orient.html CHANNEL_LABEL·admin OS_CH_LABEL)과 같은 하이픈 표기 — 견적서 한 장 안에서 두 표기가 갈리면 안 된다
      WHEN 'instagram_reels' THEN '인스타그램-릴스'
      WHEN 'x'               THEN 'X'
      WHEN 'tiktok'          THEN '틱톡'
      WHEN 'youtube'         THEN '유튜브'
      ELSE COALESCE(v_ch, '채널') END;
    v_lines := jsonb_build_array(
      jsonb_build_object('key', 'seeding', 'label', '시딩 진행비 — ' || v_ch_label, 'qty', v_slots,
                         'unit_krw', v_fee, 'amount_krw', floor(v_fee * v_slots)),
      jsonb_build_object('key', 'product', 'label', '제품 제공 (브랜드 부담)', 'qty', v_slots,
                         'unit_krw', 0, 'amount_krw', 0)
    );
  ELSE
    v_quote_error := 'price_unreadable';   -- 알 수 없는 형식 — 424 가 막으므로 도달하지 않는다
  END IF;

  -- 이전 판 → 이력(성공·실패 공통). revision 은 지난 판 번호 + 1
  v_prev_quote := v_data -> 'quote';
  v_history := COALESCE(v_data -> 'quote_history', '[]'::jsonb);
  IF jsonb_typeof(v_history) <> 'array' THEN v_history := '[]'::jsonb; END IF;
  v_revision := 1;
  IF v_prev_quote IS NOT NULL AND jsonb_typeof(v_prev_quote) = 'object' THEN
    v_history := v_history || jsonb_build_array(v_prev_quote);
    v_revision := COALESCE((v_prev_quote ->> 'revision')::integer, jsonb_array_length(v_history)) + 1;
  ELSIF jsonb_array_length(v_history) > 0 THEN
    v_revision := COALESCE((v_history -> (jsonb_array_length(v_history) - 1) ->> 'revision')::integer, jsonb_array_length(v_history)) + 1;
  END IF;

  IF v_quote_error IS NULL THEN
    SELECT COALESCE(SUM((l ->> 'amount_krw')::numeric), 0) INTO v_subtotal FROM jsonb_array_elements(v_lines) l;
    v_vat   := floor(v_subtotal * v_vat_rate);
    v_total := v_subtotal + v_vat;
    v_quote := jsonb_build_object(
      'quote_no',          p_orient_no || '-Q',
      'revision',          v_revision,
      'issued_at',         p_now,
      'form_type',         v_ft,
      'channel',           v_ch,
      'basis',             v_basis,
      'lines',             v_lines,
      'subtotal_krw',      v_subtotal,
      'vat_krw',           v_vat,
      'total_krw',         v_total,
      'price_regular_jpy', v_price_jpy,          -- 시딩은 NULL
      'slots',             v_slots,
      'valid_until',       p_valid_until,
      'note',              '브랜드 입력값 기준 예상 견적'
    );
    v_data := jsonb_set(v_data, ARRAY['quote'], v_quote, true) - 'quote_error';
  ELSE
    v_data := (v_data - 'quote');
    v_data := jsonb_set(v_data, ARRAY['quote_error'], to_jsonb(v_quote_error), true);
  END IF;
  IF jsonb_array_length(v_history) > 0 THEN
    v_data := jsonb_set(v_data, ARRAY['quote_history'], v_history, true);
  END IF;
  RETURN jsonb_build_object('data', v_data, 'quote', v_quote, 'quote_error', v_quote_error);
END;
$$;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[430] 오리엔시트 견적 계산 본문(429 에서 분리). submit_orient_sheet·preview_orient_quote 가 공용. 실행 권한 없음(내부 전용)';

-- [B] 제출 함수 — 계산부만 헬퍼 호출로
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

  -- ── [427·430] 견적 계산 — 새 구조 시트만. 제출을 막지 않는다(실패는 quote_error 로만) ──
  --   본문은 _orient_compute_quote(430) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
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
         version           = v_sheet.version + 1
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
    'quote_error',         v_quote_error    -- [427] 실패 사유(price_unreadable·slots_missing), 아니면 NULL
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329·425 와 같은 관례)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429, field=shooting_guide|shipping_note|ng|cautions) → [427·430] 견적 계산(_orient_compute_quote 공용 — 미리보기와 같은 본문. quote_settings 기준, 리뷰어=상시가×인원×환율+송금수수료+모집비 / 시딩=인원×채널 단가, 부가세 floor). '
  '세트 규칙: 제출마다 quote 또는 quote_error 하나만 남고 이전 판은 quote_history 로. 실패(price_unreadable·slots_missing)도 제출은 통과. '
  '반환값에 quote / quote_error 추가. 옛 시트는 무변경. 🔴 다음 재정의의 베이스는 430.';

-- [C] 제출 전 견적 미리보기 — 익명 호출, 저장 없음
CREATE OR REPLACE FUNCTION public.preview_orient_quote(p_token uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet record;
  v_data  jsonb;
  v_calc  jsonb;
  v_now   timestamptz := now();
BEGIN
  SELECT orient_no, token_expires_at, status, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;
  IF octet_length(p_data::text) > 102400 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_too_large');
  END IF;

  -- 서버 키(issued·quote·quote_history)는 저장값 기준 — 제출과 같은 판 번호가 나온다
  v_data := public._orient_apply_issued_rules(p_data, v_sheet.data);
  IF (v_data -> 'issued') IS NULL OR jsonb_typeof(v_data -> 'issued') <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_new_layout');
  END IF;
  IF jsonb_typeof(v_data -> 'cards') <> 'array' OR jsonb_array_length(v_data -> 'cards') < 1
     OR jsonb_typeof(v_data -> 'cards' -> 0) <> 'object' THEN
    RETURN jsonb_build_object('success', true, 'quote', NULL, 'quote_error', 'slots_missing');
  END IF;

  BEGIN
    v_calc := public._orient_compute_quote(v_data, v_sheet.orient_no, v_sheet.token_expires_at, v_now);
    RETURN jsonb_build_object(
      'success',     true,
      'quote',       CASE WHEN jsonb_typeof(v_calc -> 'quote') = 'object' THEN v_calc -> 'quote' ELSE NULL END,
      'quote_error', v_calc ->> 'quote_error'
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[preview_orient_quote] quote calc failed for %: % (%)', v_sheet.orient_no, SQLERRM, SQLSTATE;
    RETURN jsonb_build_object('success', true, 'quote', NULL, 'quote_error', 'calc_error');
  END;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.preview_orient_quote(uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.preview_orient_quote(uuid, jsonb) TO anon, authenticated;
COMMENT ON FUNCTION public.preview_orient_quote(uuid, jsonb) IS
  '[430] 오리엔시트 제출 전 견적 미리보기 — 살아 있는 토큰 + 지금 화면 값으로 _orient_compute_quote 를 돌려 quote/quote_error 만 돌려준다. 저장 없음. anon GRANT';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 되돌리기 블록)
-- ① preview_orient_quote(살아 있는 토큰, 저장된 data) → success=true, quote.total_krw 가 그 시트의 저장된 quote 와 같고 revision = 저장 판 + 1
-- ② 같은 data 로 submit_orient_sheet → quote.total_krw·revision 이 ①과 같다(같은 헬퍼)
-- ③ 미리보기를 세 번 불러도 quote_history 길이·version 무변화(저장 없음)
-- ④ 모집 인원 빈 data → quote_error=slots_missing / 옛 시트 토큰 → not_new_layout / 죽은 토큰 → invalid_token
-- ⑤ 429 검사(text_too_long 4칸·guide_too_long·appeal_too_long·cards_limit) 여전히 동작
-- ============================================================
