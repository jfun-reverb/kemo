-- ============================================================
-- 427_orient_submit_quote.sql
-- 2026-09-08 — 오리엔시트 단순화 재설계 2단계 · 마이그레이션 Ⓓ (작업 16)
--   사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-6 · §4-8 Ⓓ
--   작업표 docs/specs/2026-09-08-orient-sheet-simplify-and-quote-breakdown.md 작업 16
--
-- 🔴 베이스 = **425**(submit_orient_sheet ①차). 329 를 베이스로 잡으면 425 의 검사(서버 키 보존·형식 덮어쓰기·
--    cards_limit·글자 수)가 통째로 사라진다. save_orient_draft 는 425 판 그대로(이 파일은 제출 함수만 다시 쓴다).
-- 🔴 다음에 이 함수를 또 손댈 때의 베이스는 이 파일(427).
--
-- 무엇을 더하나 — 제출 시 견적 계산(issued 가 있는 새 구조 시트만)
--   · 기준값은 public.quote_settings(426)를 서버 안에서 읽는다(익명은 표를 못 읽는다).
--   · 리뷰어: 상시가(엔)×인원×환율 + 인원×송금 수수료 + 인원×모집비 → 공급가. 부가세 = floor(공급가 × vat_rate)(트리거 111 과 같은 자릿수 규칙).
--     상시가에서 숫자만 뽑는다(「3,429엔 (가격소구금지)」 → 3429). 숫자가 없으면 **제출은 통과**시키고 quote_error='price_unreadable'.
--   · 시딩: 인원 × 채널 단가 → 공급가(+ 제품 제공 0원 줄). 상시가는 계산에 안 쓴다.
--   · 계산 중 예상 못 한 오류는 quote_error='calc_error'(블록 전체 예외 보호 — 제출은 통과)
--   · 모집 인원을 숫자로 못 읽거나 0 이면 quote_error='slots_missing'(사양서에 없던 값 — 0원짜리 견적서가 나가는 것보다
--     「인원을 적으면 견적서를 받을 수 있어요」가 낫다는 판단. 폼·관리자 상세가 이 값을 안다).
--   🔴 세트 규칙 — quote·quote_error 는 제출마다 한 세트로 다시 쓴다:
--     성공 → 이전 quote 가 있으면 quote_history[] 뒤에 붙이고 quote 를 새 판으로(revision = 지난 판 + 1, quote_no 는 {orient_no}-Q 고정), quote_error 삭제
--     실패 → 이전 quote 를 똑같이 이력으로 보내고 quote 는 없앤 채 quote_error 기록
--     → quote 가 있다 ⇔ 마지막 제출이 견적을 만들었다 / quote_error 가 있다 ⇔ 못 만들었다. 둘이 동시에 있는 상태는 없다.
--   · 425 의 「서버 키 보존」이 먼저 돌고(옛 캐시 폼이 보낸 값 무시), 그 뒤에 이 세트를 새로 쓴다 — 순서가 바뀌면 방금 만든 견적이 보존 단계에서 옛 값으로 되돌아간다.
--   · 반환값에 quote(성공) 또는 quote_error(실패)를 더한다. 나머지 반환 키는 329·425 그대로(제출 알림 메일이 쓴다).
--   · 옛 시트(issued 없음)는 어느 것도 안 생긴다.
--
-- 롤백: 425 의 C 블록(submit_orient_sheet) 재실행.
-- ============================================================

BEGIN;

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
  -- [427] 견적
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
    END IF;
  END IF;

  -- ── [427] 견적 계산 — 새 구조 시트만. 제출을 막지 않는다(실패는 quote_error 로만) ──
  --   블록 전체를 예외 보호로 감싼다 — 지금 못 본 예외(기준값 표가 이상해지는 등)가 생겨도 「제출은 통과」가 구조로 보장된다.
  IF v_is_new AND v_card0 IS NOT NULL THEN
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
        'quote_no',          v_sheet.orient_no || '-Q',
        'revision',          v_revision,
        'issued_at',         v_now,
        'form_type',         v_ft,
        'channel',           v_ch,
        'basis',             v_basis,
        'lines',             v_lines,
        'subtotal_krw',      v_subtotal,
        'vat_krw',           v_vat,
        'total_krw',         v_total,
        'price_regular_jpy', v_price_jpy,          -- 시딩은 NULL
        'slots',             v_slots,
        'valid_until',       v_sheet.token_expires_at,
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
  '[293, 202, 328, 329, 425, 427 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425) → [427] 견적 계산(quote_settings 기준, 리뷰어=상시가×인원×환율+송금수수료+모집비 / 시딩=인원×채널 단가, 부가세 floor). '
  '세트 규칙: 제출마다 quote 또는 quote_error 하나만 남고 이전 판은 quote_history 로. 실패(price_unreadable·slots_missing)도 제출은 통과. '
  '반환값에 quote / quote_error 추가. 옛 시트는 무변경. 🔴 다음 재정의의 베이스는 427.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 익명 함수라 SQL 편집기 호출도 통한다. 되돌리기 블록으로)
-- ① 리뷰어(상시가 5300·인원 10, 환율 10·수수료 2500·모집비 0·부가세 0.1) → payback 530,000 + transfer 25,000 = 555,000 / vat 55,500 / total 610,500
-- ② 같은 시트 재제출 → revision 2, quote_history 1, quote_no 그대로
-- ③ 「3,429엔 (가격소구금지)」 → 3429 로 계산
-- ④ 「미정」 → success, quote 없음, quote_error=price_unreadable, 이전 판은 이력
-- ⑤ 다시 제대로 → quote 생기고 quote_error 사라짐
-- ⑥ 시딩(인원 5, 단가 0) → total 0, price_unreadable 안 뜸(상시가 「미정」이어도)
-- ⑦ 옛 시트 → quote·quote_error 둘 다 없음
-- ⑧ 425 검사 4종 여전히 동작(cards_limit·guide_too_long·appeal_too_long·issued 보존)
-- ============================================================
