-- ============================================================
-- 452: 오리엔시트 견적 줄 이름 — 「상시가」 → 「판매가」
-- ============================================================
-- 무엇을 왜 바꾸는가
--   견적서 페이백 줄 이름에 「상시가」라는 낱말이 박혀 있었다. 브랜드가 폼에 입력하는 항목은
--   `sale.price_regular`("판매가"로 화면에 노출되는 입력칸)인데, 견적 줄 이름만 다른 낱말(「상시가」)을
--   써서 같은 값을 두 이름으로 부르고 있었다. 이 파일은 그 두 문구만 「판매가」로 고친다.
--     '상품 결제비용 ((상시가 + 배송비) × 환율)' → '상품 결제비용 ((판매가 + 배송비) × 환율)'
--     '상품 결제비용 (상시가 × 환율)'            → '상품 결제비용 (판매가 × 환율)'
--   계산식·구간 판정·quote_error 코드·반환 jsonb 키(price_regular_jpy·shipping_fee_jpy 등)는
--   한 글자도 바꾸지 않는다 — 전부 저장 키이거나 화면·이력이 참조하는 값이라 바꾸면
--   이미 저장된 견적·화면 렌더가 깨진다.
--
-- 🔴 베이스는 448이다 — 왜 448인가
--   `_orient_compute_quote` 의 계보는 427 → 429 → 430 → 443 → 448 이다. 옛 번호(427·429·430·443)를
--   베이스로 재작성하면 구간 요금 판정(443)·글자 수 검사(429)·구간 이름 「500건」(448)이 통째로
--   사라진다. 이 파일은 448 파일의 함수 본문을 그대로 옮기고 위 두 문구만 바꿨다 — 그 외 단 한 줄도
--   다르지 않다(파일 하단 diff 로 확인).
--
-- 소급하지 않는 이유
--   이미 저장된 견적(orient_sheets.data->'quote', data->'quote_history'[])의 label 은 제출 시점
--   스냅샷이다. 브랜드가 그 시점에 실제로 받은 견적서를 그대로 보존해야 하므로, 과거 행의 문구를
--   UPDATE 로 바꾸지 않는다. 새 문구는 이 마이그레이션 적용 뒤 새로 계산되는 견적(임시저장 견적 보기·
--   제출)부터만 적용된다.
--
-- CREATE OR REPLACE 로 충분한가
--   인자 목록(jsonb, text, timestamptz, timestamptz)이 448 과 완전히 동일하므로 DROP 없이
--   CREATE OR REPLACE 로 재정의한다. CREATE OR REPLACE 는 함수의 기존 실행 권한을 보존하지만,
--   448 자신도 "443 의 회수를 한 번 더 건다"고 적어 뒀으므로 같은 관례를 따라 REVOKE 를
--   한 번 더 실행한다(대상이 없어도 무해 — 개발·운영 권한 상태가 다를 수 있다는 이 저장소의
--   반복 경고와 같은 이유). get_orient_tier_fees(uuid) 는 이 파일에서 건드리지 않는다
--   (구간 단가 표시용이라 이 문구와 무관 — anon/authenticated GRANT 는 448 그대로 유지).
--
-- 배포 순서: 449 다음. 작성 폼(sales)·관리자 화면 어느 쪽도 이 두 문구를 하드코딩하지 않는다
--   (견적 줄 이름은 서버가 만들어 jsonb 로 내려주고 화면은 그대로 그린다) → 화면 재배포 불필요.
--
-- 되돌리기: 아래 함수 본문의 두 문구를 다시 448 의 문구로 바꿔 CREATE OR REPLACE.
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
  v_tier_label    text;        -- [443→448] 라이트 · 스탠다드 · 프리미엄 · 500건
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
  --   ⚠️ 101~499 는 화면에서 나올 수 없는 값(버튼은 50·100·300·500 넷뿐 — 448 에서 직접 입력을 없앴다)이라
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
    WHEN 't500plus'  THEN '500건'          -- [448] 네 번째 구간은 「500건」 고정(직접 입력 없음). 🔴 판정 경계(500 이상)는 그대로 — 조작된 호출·옛 값(700 등)도 이 구간이다
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

      -- [452] 「상시가」 → 「판매가」 — 브랜드 입력칸 이름과 견적 줄 이름을 같은 낱말로 맞춘다
      v_payback_label := CASE WHEN v_ship_jpy > 0
        THEN '상품 결제비용 ((판매가 + 배송비) × 환율)'
        ELSE '상품 결제비용 (판매가 × 환율)' END;

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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 448 과 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[452, 베이스 448] 오리엔시트 견적 계산 본문 — 인원으로 구간 판정(t50·t100·t300·t500plus), 구간별 모집비·시딩 진행비, '
  '발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), 리뷰어 추가 옵션(LIPS·@cosme), 500건 이상이면 형식과 무관하게 '
  '「실검작업 — 담당자 협의」(값 없음·합계 제외), 기준값 행이 없으면 fee_missing. [448] 네 번째 구간 이름 「500건」(판정 경계는 그대로). '
  '[452] 페이백 줄 이름 「상시가」 → 「판매가」(계산·저장키 무변경, 기존 저장 견적 소급 없음). '
  'submit_orient_sheet·preview_orient_quote 가 공용. 실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 452.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후)
-- ------------------------------------------------------------
-- [V1] 함수를 직접 불러 줄 이름이 새 문구로 나오는지 확인한다.
--   배송비 0인 경우와 배송비 있는 경우 둘 다 본다. p_data 는 최소 형태로 손으로 구성.
--
--   -- 배송비 없음 (판매가만)
--   SELECT public._orient_compute_quote(
--     '{"issued":{"form_type":"reviewer","channel":null},
--       "cards":[{"product":{"slots":"50"},"sale":{"price_regular":"3000"}}]}'::jsonb,
--     'TEST-452-A', now() + interval '30 days', now()
--   ) -> 'quote' -> 'lines' -> 0 ->> 'label';
--   기대: '상품 결제비용 (판매가 × 환율)'
--
--   -- 배송비 있음 (판매가 + 배송비)
--   SELECT public._orient_compute_quote(
--     '{"issued":{"form_type":"reviewer","channel":null},
--       "cards":[{"product":{"slots":"50"},"sale":{"price_regular":"3000","shipping_fee":"500"}}]}'::jsonb,
--     'TEST-452-B', now() + interval '30 days', now()
--   ) -> 'quote' -> 'lines' -> 0 ->> 'label';
--   기대: '상품 결제비용 ((판매가 + 배송비) × 환율)'
--
-- [V2] 448 대비 다른 부분이 이 두 문구뿐인지 — 파일 하단 diff 참고(마이그레이션 커밋 메시지·PR 본문에 기록).
--
-- [V3] 권한 — 내부 함수가 다시 열리지 않았는가
--   SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = '_orient_compute_quote';
--   기대: anon·authenticated·맨 앞 `=X/` 없음(448 검증 [V4] 와 같은 기대값)
-- ============================================================
