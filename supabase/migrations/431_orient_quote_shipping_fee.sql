-- ============================================================
-- 431_orient_quote_shipping_fee.sql
-- 2026-09-10 — 오리엔시트 단순화 · 리뷰어 견적에 배송비(선택) 반영 (사용자 결정 2026-09-10)
--   배경: 새 구조(issued 있음) 리뷰어 카드에 배송비(선택) 칸이 생긴다.
--         화면은 data.cards[0].sale.shipping_fee 에 문자열로 저장(비우면 빈 문자열 또는 키 없음 — 0 으로 처리).
--         견적서 페이백 줄을 (상시가 + 배송비) × 환율 × 인원 으로 바꾼다.
--
-- 🔴 베이스 = **430**(supabase/migrations/430_orient_quote_preview.sql 의 [A] 블록,
--    public._orient_compute_quote 정의). 430 의 [A] 본문을 그대로 복사한 뒤 아래만 바꿨다.
--    옛 번호(427)를 베이스로 잡으면 미리보기(preview_orient_quote)·글자 수 검사 분리(430)가 사라진다.
--
-- 무엇이 바뀌나 — _orient_compute_quote 재정의만. submit_orient_sheet·preview_orient_quote 는
-- 둘 다 이 헬퍼를 이름으로 부르므로(CREATE OR REPLACE 는 함수 본문만 교체, 시그니처 불변) 손대지 않아도
-- 자동으로 배송비가 반영된다. 다른 갈래(시딩·오류·이력·revision·부가세)는 430 과 문자 그대로 같다.
--   ① 리뷰어 분기에서 상시가 파싱 다음에 배송비 파싱 — 첫 숫자 덩어리만(콤마 제거), 없으면 0.
--      배송비가 없어도 오류가 아니다(price_unreadable 를 안 낸다 — 상시가만 필수).
--   ② 페이백 줄 금액 = (상시가 + 배송비) × 환율(단가) / × 인원(합계). 배송비 0 이면 종전과 숫자가 같다.
--      label 은 배송비 > 0 이면 '제품 구매 페이백 ((상시가 + 배송비) × 환율)', 0 이면 종전 문구 그대로.
--   ③ 견적 jsonb 에 shipping_fee_jpy 추가(리뷰어만 값, 시딩은 NULL — price_regular_jpy 와 같은 자리).
--
-- 되돌리기: 430_orient_quote_preview.sql 의 [A] 블록(CREATE OR REPLACE FUNCTION public._orient_compute_quote ~
--   COMMENT ON FUNCTION ... 까지)을 다시 실행하면 431 이전 상태로 복귀. submit_orient_sheet·preview_orient_quote 는
--   431 에서 재정의하지 않았으므로 되돌릴 것이 없다.
-- ============================================================
BEGIN;

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
  v_data          jsonb := p_data;
  v_card0         jsonb := p_data -> 'cards' -> 0;
  v_ft            text;
  v_ch            text;
  v_basis         jsonb;
  v_rate          numeric;
  v_transfer      numeric;
  v_recruit       numeric;
  v_vat_rate      numeric;
  v_fee           numeric;
  v_slots_txt     text;
  v_slots         integer;
  v_price_txt     text;
  v_price_jpy     numeric;
  v_ship_txt      text;        -- [431]
  v_ship_jpy      numeric;     -- [431]
  v_payback_label text;        -- [431]
  v_lines         jsonb;
  v_subtotal      numeric;
  v_vat           numeric;
  v_total         numeric;
  v_prev_quote    jsonb;
  v_history       jsonb;
  v_revision      integer;
  v_quote         jsonb;
  v_quote_error   text;
  v_ch_label      text;
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

      -- [431] 배송비(선택) — 상시가와 같은 방식으로 첫 숫자 덩어리만. 없거나 못 읽으면 0(오류를 안 낸다 — 상시가만 필수).
      v_ship_txt := (regexp_match(COALESCE(v_card0 -> 'sale' ->> 'shipping_fee', ''), '[0-9][0-9,]*'))[1];
      v_ship_txt := replace(COALESCE(v_ship_txt, ''), ',', '');
      v_ship_jpy := CASE WHEN v_ship_txt = '' THEN 0 ELSE v_ship_txt::numeric END;

      v_payback_label := CASE WHEN v_ship_jpy > 0
        THEN '제품 구매 페이백 ((상시가 + 배송비) × 환율)'
        ELSE '제품 구매 페이백 (상시가 × 환율)' END;

      v_lines := jsonb_build_array(
        jsonb_build_object('key', 'payback',  'label', v_payback_label, 'qty', v_slots,
                           'unit_krw', floor((v_price_jpy + v_ship_jpy) * v_rate),
                           'amount_krw', floor((v_price_jpy + v_ship_jpy) * v_rate * v_slots)),
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
      'quote_no',           p_orient_no || '-Q',
      'revision',           v_revision,
      'issued_at',          p_now,
      'form_type',          v_ft,
      'channel',            v_ch,
      'basis',              v_basis,
      'lines',              v_lines,
      'subtotal_krw',       v_subtotal,
      'vat_krw',            v_vat,
      'total_krw',          v_total,
      'price_regular_jpy',  v_price_jpy,          -- 시딩은 NULL
      'shipping_fee_jpy',   v_ship_jpy,           -- [431] 리뷰어만 값(0 포함), 시딩은 NULL
      'slots',              v_slots,
      'valid_until',        p_valid_until,
      'note',               '브랜드 입력값 기준 예상 견적'
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
  '[431] 오리엔시트 견적 계산 본문(430 베이스에 배송비(선택) 반영 — 페이백 = (상시가+배송비)×환율×인원, quote.shipping_fee_jpy 추가). submit_orient_sheet·preview_orient_quote 가 공용. 실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 431.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후 — 한 줄씩 실행)
-- ① 배송비 있음
-- SELECT public._orient_compute_quote(
--   '{"issued":{"form_type":"reviewer","channel":null},
--     "cards":[{"product":{"slots":"10"},"sale":{"price_regular":"3,429엔 (가격소구금지)","shipping_fee":"500엔"}}]}'::jsonb,
--   'B0001-A001-C001', now() + interval '30 days', now()
-- ) -> 'quote' -> 'lines' -> 0;
-- → label='제품 구매 페이백 ((상시가 + 배송비) × 환율)', unit_krw=(3429+500)×환율, quote.shipping_fee_jpy=500
--
-- ② 배송비 없음(키 없음) — 430 과 같은 숫자인지
-- SELECT public._orient_compute_quote(
--   '{"issued":{"form_type":"reviewer","channel":null},
--     "cards":[{"product":{"slots":"10"},"sale":{"price_regular":"3429"}}]}'::jsonb,
--   'B0001-A001-C001', now() + interval '30 days', now()
-- ) -> 'quote';
-- → label='제품 구매 페이백 (상시가 × 환율)', shipping_fee_jpy=0, unit_krw=3429×환율(430 과 동일 숫자)
--
-- ③ 배송비에 글자 섞임("무료(도서산간 제외)") — 숫자 없으면 0 처리, 오류 안 남
-- SELECT public._orient_compute_quote(
--   '{"issued":{"form_type":"reviewer","channel":null},
--     "cards":[{"product":{"slots":"10"},"sale":{"price_regular":"3429","shipping_fee":"무료(도서산간 제외)"}}]}'::jsonb,
--   'B0001-A001-C001', now() + interval '30 days', now()
-- ) -> 'quote' ->> 'quote_error';
-- → NULL (price_unreadable 아님 — 배송비는 파싱 실패해도 0 으로 통과)
--
-- ④ 시딩 — shipping_fee_jpy 가 NULL 인지(리뷰어 전용 자리)
-- SELECT public._orient_compute_quote(
--   '{"issued":{"form_type":"seeding","channel":"instagram_feed"},
--     "cards":[{"product":{"slots":"5"}}]}'::jsonb,
--   'B0001-A001-C001', now() + interval '30 days', now()
-- ) -> 'quote' -> 'shipping_fee_jpy';
-- → null
--
-- ⑤ 제출·미리보기 회귀(430 검증 ①②③④⑤ 그대로 통과하는지) — 실제 살아있는 토큰으로 preview_orient_quote/submit_orient_sheet 호출
-- ============================================================
