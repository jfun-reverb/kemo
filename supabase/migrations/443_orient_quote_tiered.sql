-- ============================================================
-- 443_orient_quote_tiered.sql
-- 2026-09-16 — 오리엔시트 구간 요금 · 마이그레이션 ② (작업 2)
--   사양서 docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-1 · §4-4 · §4-9 · §4-11
--   작업표 docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 「작업 2」
--
-- 🔴 베이스 = **431**(431_orient_quote_shipping_fee.sql 의 `_orient_compute_quote`).
--    430 을 베이스로 잡으면 **배송비가 통째로 사라진다.** 431 본문을 그대로 두고 아래만 바꿨다.
--    ⚠️ `submit_orient_sheet`(430)·`preview_orient_quote`(430)는 이 헬퍼를 **이름으로** 부르고
--       시그니처가 그대로라 손댈 필요가 없다.
--
-- 무엇이 바뀌나 (431 대비)
--   ① **서버가 인원으로 구간을 판정**한다(`slots_tier` 는 화면 표시용이라 계산에 안 쓴다)
--        1~50 = t50 · 51~100 = t100 · 101~499 = t300 · 500 이상 = t500plus
--      🔴 101~499 를 t500plus 로 보내면 **「실검작업」 줄이 신청하지도 않은 견적서에 붙는다.**
--   ② 모집비·시딩 진행비를 **구간별 열쇠말**에서 읽는다. 줄 이름에 구간 이름을 넣는다
--      (「모집비 (스탠다드)」 · 「시딩 진행비 — 인스타그램-피드 (스탠다드)」)
--   ③ **발급 시 예외**(`issued.recruit_fee_krw`)가 있으면 그 값으로 덮고 이름 끝에 **「· 직접 지정」**
--      🔴 안 붙이면 견적서만 보고 표준 단가인지 예외인지 알 수 없다
--   ④ 리뷰어 **추가 옵션 두 줄**(`sale.extra_markets` 에 lips·cosme 가 있을 때만)
--   ⑤ 인원 **500 이상이면 「실검작업 — 담당자 협의」 줄** — 단가·수량·합계 모두 **JSON null**
--   ⑥ 페이백 줄 이름 「제품 구매 페이백 …」 → **「상품 결제비용 …」**(§4-4)
--   ⑦ 필요한 기준값 **행이 없으면** `quote_error = 'fee_missing'`(0 은 정상 — 무료 구간일 수 있다)
--
-- ------------------------------------------------------------
-- 🔴 「실검작업」 줄의 빈 값 — 빈 문자열이면 제출이 통째로 죽는다
-- ------------------------------------------------------------
--   `amount_krw` 를 `''` 로 넣으면 합계에서 `''::numeric` 이 터져 **제출·미리보기가 실패**한다.
--   → **JSON `null`** 로 넣고, 합계에서 그 줄을 **키로 걸러낸다**(`<> 'realtime_search'`).
--   ⚠️ `SUM` 이 null 을 건너뛰기는 하지만, 그것과 별개로 **「담당자 협의」 줄이 합계에 섞이지 않게** 한다.
--   ⚠️ 화면은 저절로 빈 칸이 되지 않는다 — `krw()`·`osKrw()` 가 `Number(n || 0)` 이라 「0원」으로 찍힌다.
--      그 두 자리는 **작업 8**에서 고친다(이 파일 밖).
--
-- ------------------------------------------------------------
-- ⚠️ 적용 순서 — ①(442)이 먼저다
-- ------------------------------------------------------------
--   이 파일은 442 가 만든 구간 열쇠말 26개를 읽는다. 442 없이 이 파일만 넣으면 그 행이 없어
--   **모든 견적이 `fee_missing`** 이 된다(조용한 오답이 아니라 눈에 보이는 거부라 그나마 낫다).
--
-- 되돌리기: 431 의 함수 블록을 그대로 다시 실행(시그니처가 같아 `CREATE OR REPLACE` 로 덮인다).
--   ⚠️ 그 경우 442 가 지운 옛 열쇠말을 읽으므로 **442 되돌리기도 함께** 해야 금액이 맞는다.
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
  v_tier          text;        -- [443] t50 · t100 · t300 · t500plus
  v_tier_label    text;        -- [443] 라이트 · 스탠다드 · 프리미엄 · 500건 이상
  v_fee_key       text;        -- [443] 읽을 기준값 열쇠말
  v_override      numeric;     -- [443] issued.recruit_fee_krw (없으면 NULL)
  v_suffix        text;        -- [443] ' · 직접 지정' 또는 ''
  v_markets       jsonb;       -- [443] sale.extra_markets
  v_opt_lips      numeric;     -- [443]
  v_opt_cosme     numeric;     -- [443]
BEGIN
  v_ft := v_data -> 'issued' ->> 'form_type';
  v_ch := v_data -> 'issued' ->> 'channel';
  v_quote := NULL;
  v_quote_error := NULL;

  -- 기준값 전부(basis 스냅샷용) — 관리자가 나중에 값을 바꿔도 이 판이 무엇으로 계산됐는지 남는다
  SELECT COALESCE(jsonb_object_agg(q.key, q.amount), '{}'::jsonb) INTO v_basis FROM public.quote_settings q;
  v_rate     := COALESCE((v_basis ->> 'exchange_rate_krw_per_jpy')::numeric, 0);
  v_transfer := COALESCE((v_basis ->> 'reviewer_transfer_fee_krw')::numeric, 0);
  v_vat_rate := COALESCE((v_basis ->> 'vat_rate')::numeric, 0);

  -- [443] 발급 시 모집비 예외 — 키가 있으면(0 포함) 그 값을 쓴다. 「비움」과 「0」은 다른 뜻이라 키 유무로 가른다
  v_override := CASE WHEN v_data -> 'issued' ? 'recruit_fee_krw'
                     THEN NULLIF(v_data -> 'issued' ->> 'recruit_fee_krw', '')::numeric END;
  v_suffix   := CASE WHEN v_override IS NOT NULL THEN ' · 직접 지정' ELSE '' END;

  -- 모집 인원 — 숫자만
  v_slots_txt := regexp_replace(COALESCE(v_card0 -> 'product' ->> 'slots', ''), '[^0-9]', '', 'g');
  -- ⚠️ numeric 을 거친다 — bigint 로 바로 바꾸면 20자리 넘는 입력(송장번호 붙여넣기·임의 호출)에 22003 으로 제출이 죽는다(리뷰 지적)
  v_slots := CASE WHEN v_slots_txt = '' THEN NULL ELSE LEAST(v_slots_txt::numeric, 999999)::integer END;

  -- [443] 서버 구간 판정 — 화면이 보낸 slots_tier 를 믿지 않는다
  --   ⚠️ 101~499 는 화면에서 나올 수 없는 값(버튼은 50·100·300, 직접 입력은 500 이상)이라
  --      조작된 호출·옛 데이터뿐이다 → 프리미엄으로 떨어뜨린다(t500plus 로 보내면 실검작업 줄이 붙는다)
  v_tier := CASE
    WHEN v_slots IS NULL      THEN NULL
    WHEN v_slots <= 50        THEN 't50'
    WHEN v_slots <= 100       THEN 't100'
    WHEN v_slots <= 499       THEN 't300'
    ELSE 't500plus' END;
  v_tier_label := CASE v_tier
    WHEN 't50'       THEN '라이트'
    WHEN 't100'      THEN '스탠다드'
    WHEN 't300'      THEN '프리미엄'
    WHEN 't500plus'  THEN '500건 이상'
    ELSE '' END;

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

      -- [443] §4-4 — 「제품 구매 페이백」 → 「상품 결제비용」
      v_payback_label := CASE WHEN v_ship_jpy > 0
        THEN '상품 결제비용 ((상시가 + 배송비) × 환율)'
        ELSE '상품 결제비용 (상시가 × 환율)' END;

      -- [443] 모집비 — 예외가 있으면 그 값, 없으면 구간 열쇠말. 🔴 행이 없으면 fee_missing(0 은 정상)
      v_fee_key := 'reviewer_recruit_fee_krw_' || v_tier;
      IF v_override IS NOT NULL THEN
        v_recruit := v_override;
      ELSIF v_basis ? v_fee_key THEN
        v_recruit := (v_basis ->> v_fee_key)::numeric;
      ELSE
        v_quote_error := 'fee_missing';
      END IF;

      IF v_quote_error IS NULL THEN
        v_lines := jsonb_build_array(
          jsonb_build_object('key', 'payback',  'label', v_payback_label, 'qty', v_slots,
                             'unit_krw', floor((v_price_jpy + v_ship_jpy) * v_rate),
                             'amount_krw', floor((v_price_jpy + v_ship_jpy) * v_rate * v_slots)),
          jsonb_build_object('key', 'transfer', 'label', '해외 송금 수수료', 'qty', v_slots,
                             'unit_krw', v_transfer, 'amount_krw', floor(v_transfer * v_slots)),
          jsonb_build_object('key', 'recruit',
                             'label', '모집비 (' || v_tier_label || v_suffix || ')', 'qty', v_slots,
                             'unit_krw', v_recruit, 'amount_krw', floor(v_recruit * v_slots))
        );

        -- [443] 추가 옵션 — 고른 것이 있을 때만. 기준값 행이 없으면 fee_missing
        v_markets := v_card0 -> 'sale' -> 'extra_markets';
        IF jsonb_typeof(v_markets) = 'array' AND v_markets @> '["lips"]'::jsonb THEN
          IF v_basis ? 'reviewer_option_fee_krw_lips' THEN
            v_opt_lips := (v_basis ->> 'reviewer_option_fee_krw_lips')::numeric;
            v_lines := v_lines || jsonb_build_array(
              jsonb_build_object('key', 'option_lips', 'label', '추가 옵션 — LIPS', 'qty', v_slots,
                                 'unit_krw', v_opt_lips, 'amount_krw', floor(v_opt_lips * v_slots)));
          ELSE
            v_quote_error := 'fee_missing';
          END IF;
        END IF;
        IF v_quote_error IS NULL AND jsonb_typeof(v_markets) = 'array' AND v_markets @> '["cosme"]'::jsonb THEN
          IF v_basis ? 'reviewer_option_fee_krw_cosme' THEN
            v_opt_cosme := (v_basis ->> 'reviewer_option_fee_krw_cosme')::numeric;
            v_lines := v_lines || jsonb_build_array(
              jsonb_build_object('key', 'option_cosme', 'label', '추가 옵션 — @cosme', 'qty', v_slots,
                                 'unit_krw', v_opt_cosme, 'amount_krw', floor(v_opt_cosme * v_slots)));
          ELSE
            v_quote_error := 'fee_missing';
          END IF;
        END IF;
      END IF;
    END IF;
  ELSIF v_ft = 'seeding' THEN
    v_ch_label := CASE v_ch
      WHEN 'instagram_feed'  THEN '인스타그램-피드'    -- ⚠️ 화면(orient.html CHANNEL_LABEL·admin OS_CH_LABEL)과 같은 하이픈 표기 — 견적서 한 장 안에서 두 표기가 갈리면 안 된다
      WHEN 'instagram_reels' THEN '인스타그램-릴스'
      WHEN 'x'               THEN 'X'
      WHEN 'tiktok'          THEN '틱톡'
      WHEN 'youtube'         THEN '유튜브'
      ELSE COALESCE(v_ch, '채널') END;

    -- [443] 진행비 — 채널×구간. 예외가 있으면 그 값
    v_fee_key := 'seeding_fee_krw_' || COALESCE(v_ch, '') || '_' || v_tier;
    IF v_override IS NOT NULL THEN
      v_fee := v_override;
    ELSIF v_basis ? v_fee_key THEN
      v_fee := (v_basis ->> v_fee_key)::numeric;
    ELSE
      v_quote_error := 'fee_missing';
    END IF;

    IF v_quote_error IS NULL THEN
      v_lines := jsonb_build_array(
        jsonb_build_object('key', 'seeding',
                           'label', '시딩 진행비 — ' || v_ch_label || ' (' || v_tier_label || v_suffix || ')',
                           'qty', v_slots, 'unit_krw', v_fee, 'amount_krw', floor(v_fee * v_slots)),
        jsonb_build_object('key', 'product', 'label', '제품 제공 (브랜드 부담)', 'qty', v_slots,
                           'unit_krw', 0, 'amount_krw', 0)
      );
    END IF;
  ELSE
    v_quote_error := 'price_unreadable';   -- 알 수 없는 형식 — 424 가 막으므로 도달하지 않는다
  END IF;

  -- [443] 실검작업 — 인원 500 이상일 때만, 형식과 무관. 🔴 세 값 모두 JSON null(빈 문자열 금지)
  --   ⚠️ 합계에서는 아래 SUM 이 키로 걸러낸다
  IF v_quote_error IS NULL AND v_tier = 't500plus' THEN
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('key', 'realtime_search', 'label', '실검작업 — 담당자 협의',
                         'qty', NULL, 'unit_krw', NULL, 'amount_krw', NULL));
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
    -- [443] 「담당자 협의」 줄은 합계에서 뺀다
    SELECT COALESCE(SUM((l ->> 'amount_krw')::numeric), 0) INTO v_subtotal
      FROM jsonb_array_elements(v_lines) l
     WHERE l ->> 'key' <> 'realtime_search';
    v_vat   := floor(v_subtotal * v_vat_rate);
    v_total := v_subtotal + v_vat;
    v_quote := jsonb_build_object(
      'quote_no',           p_orient_no || '-Q',
      'revision',           v_revision,
      'issued_at',          p_now,
      'form_type',          v_ft,
      'channel',            v_ch,
      'tier',               v_tier,               -- [443] 어느 구간으로 계산됐는지 남긴다
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
  '[443, 베이스 431] 오리엔시트 견적 계산 본문 — 인원으로 구간 판정(t50·t100·t300·t500plus), 구간별 모집비·시딩 진행비, '
  '발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), 리뷰어 추가 옵션(LIPS·@cosme), 500건 이상이면 '
  '「실검작업 — 담당자 협의」(값 없음·합계 제외), 기준값 행이 없으면 fee_missing. submit_orient_sheet·preview_orient_quote 가 공용. '
  '실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 443.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 442 를 먼저 넣고, 사양서 §9-1 3~10번)
-- ============================================================
/*
-- [V1] 구간 경계 — 50/51/100/101/499/500 이 각각 t50·t100·t100·t300·t300·t500plus 인가
SELECT s AS slots,
       (public._orient_compute_quote(
          jsonb_build_object('issued', jsonb_build_object('form_type','reviewer','channel',NULL),
                             'cards', jsonb_build_array(jsonb_build_object(
                               'product', jsonb_build_object('slots', s::text),
                               'sale',    jsonb_build_object('price_regular','3429')))),
          'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier') AS tier
  FROM unnest(ARRAY[50,51,100,101,499,500,700]) s;
-- 기대: t50 · t100 · t100 · t300 · t300 · t500plus · t500plus

-- [V2] 700건 리뷰어 — 「실검작업」 줄이 값 없이 붙고 합계에서 빠지는가
SELECT jsonb_pretty(public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"700"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote');
-- 기대: lines 에 realtime_search(qty·unit_krw·amount_krw 가 전부 null) · 모집비 줄 이름 「모집비 (500건 이상)」
--       subtotal 은 payback+transfer+recruit 만

-- [V3] 300건 리뷰어 — 실검작업 줄이 **없어야** 한다 (101~499 는 t300)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"350"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines';
-- 기대: realtime_search 없음 · 「모집비 (프리미엄)」

-- [V4] 추가 옵션 — 둘 다 고른 경우
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429","extra_markets":["lips","cosme"]}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines';
-- 기대: option_lips·option_cosme 두 줄(각 5,000 × 100)

-- [V5] 발급 예외 — 줄 이름 끝에 「· 직접 지정」
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null,"recruit_fee_krw":7000},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines' -> 2;
-- 기대: label '모집비 (스탠다드 · 직접 지정)' · unit_krw 7000
-- ⚠️ 0 도 허용되는지: recruit_fee_krw 를 0 으로 바꿔 unit_krw 0 · 이름에 「· 직접 지정」

-- [V5-b] 옵션을 **안 고르면** 그 줄이 아예 없는가 (§9-1 6-c)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines';
-- 기대: 세 줄(payback·transfer·recruit)뿐 — option_lips·option_cosme 키가 없다

-- [V5-c] 시딩에도 발급 예외가 걸리는가 (§9-1 6-f)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"seeding","channel":"tiktok","recruit_fee_krw":0},
    "cards":[{"product":{"slots":"50"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines' -> 0;
-- 기대: label '시딩 진행비 — 틱톡 (라이트 · 직접 지정)' · unit_krw 0 (0 도 예외로 인정 — 시드 99013 이 아니다)

-- [V6] 시딩 — 채널×구간 행을 제대로 읽는가(시드가 20개 전부 달라 숫자로 확인된다)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"seeding","channel":"instagram_feed"},
    "cards":[{"product":{"slots":"100"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines' -> 0;
-- 기대: label '시딩 진행비 — 인스타그램-피드 (스탠다드)' · unit_krw 99002
--       틱톡 라이트(slots 50)면 99013

-- [V7] fee_missing — 기준값 행 하나를 지우고 계산하면
BEGIN;
DELETE FROM public.quote_settings WHERE key = 'reviewer_recruit_fee_krw_t100';
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) ->> 'quote_error';   -- fee_missing
ROLLBACK;

-- [V8] 🔴 값이 0 인 기준값은 **정상 통과**해야 한다 — 「행이 없음」(fee_missing)과 다른 뜻이다.
--      442 시드에는 0 인 행이 없어, 이 갈래는 일부러 만들어 보지 않으면 한 번도 안 돈다.
BEGIN;
UPDATE public.quote_settings SET amount = 0 WHERE key = 'reviewer_recruit_fee_krw_t100';
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines' -> 2;
-- 기대: quote_error 없음 · label '모집비 (스탠다드)' · unit_krw 0 · amount_krw 0 (무료 구간은 정상)
ROLLBACK;

-- [V9] 회귀 — 431 검증 ①②③④(배송비·시딩 NULL)가 그대로 통과하는지
-- [V10] 🔴 [V2] 는 개발 적용 뒤 **실제로 한 번 돌려서** 세 값(qty·unit_krw·amount_krw)이 전부 비는 것을
--       눈으로 볼 것 — 이 저장소에서 한 줄에 값 없는 칸 셋을 동시에 넣는 것은 이 파일이 처음이다
*/
