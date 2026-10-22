-- ============================================================
-- 586_orient_quote_channel_label_spacing.sql
-- 2026-10-22 — 오리엔시트 견적서 시딩 채널 이름을 화면과 같은 띄어쓰기로
--   「시딩 진행비 — 인스타그램-피드 (…)」 → 「시딩 진행비 — 인스타그램 피드 (…)」 (릴스도)
--
--   왜: 관리자 화면(OS_CH_LABEL)·브랜드 작성 폼(orient.html CHANNEL_LABEL)·브랜드 페이지가
--   PR #2283·#2284 에서 「인스타그램 피드」·「인스타그램 릴스」(띄어쓰기)로 바뀌었다. 서버가 만드는
--   견적 줄 이름만 하이픈으로 남으면 견적서 한 장 안에서 두 표기가 갈린다(사용자 결정 (가)).
--
--   [1] _orient_compute_quote — 베이스 463(🔴 539 안의 같은 이름은 주석 속 시험 코드라 정의가 아니다).
--       본문은 463 그대로이고 채널 이름 CASE 두 줄(+ 그 줄 주석)만 바꿨다. CREATE OR REPLACE 라
--       실행 권한(내부 전용 — 공개 회수)이 그대로 남는다. 463 과 같은 관례로 회수를 한 번 더 건다.
--   [2] quote_settings.label_ko — 「진행비 — 인스타그램-피드 (…)」 / 「…-릴스 (…)」 행의 하이픈만
--       띄어쓰기로(관리자 「견적 기준값」 탭 시딩 표 머리글은 화면 코드라 이미 띄어쓰기 — 이것은 행 이름표).
--       금액·열쇠말은 손대지 않는다.
--
--   ⚠️ 소급하지 않는다 — 이미 제출·저장된 견적(orient_sheets.data.quote·quote_history 의 lines[].label)
--      은 옛 하이픈 표기 그대로 남는다. 다음 제출·미리보기부터 새 이름.
--   ⚠️ 다음에 _orient_compute_quote 를 고칠 때 베이스는 이 파일(586).
--
--   롤백: [1] 은 463 의 [1] 블록(CREATE OR REPLACE ~ COMMENT)을 다시 실행,
--         [2] 는 아래 UPDATE 의 replace 인자(옛·새)를 맞바꿔 실행.
-- ============================================================
BEGIN;

-- ================================================================
-- [1] _orient_compute_quote — 베이스 463. 시딩 채널 이름 두 줄만 바뀐다.
-- ================================================================
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
  v_tier          text;        -- [443] tmin · t50 · t100 · t300 · t500plus [459: tmin 추가]
  v_tier_label    text;        -- [443→448→459→461→463] 이제 quote_tier_labels 표에서 읽는다(행 없으면 기본 이름)
  v_fee_key       text;        -- [443] 읽을 기준값 열쇠말(모집비·진행비 — 형식별로 이미 나뉘어 있던 표, 461·463 무변경)
  v_override      numeric;     -- [443] issued.recruit_fee_krw (없으면 NULL)
  v_suffix        text;        -- [443] ' · 직접 지정' 또는 ''
  v_markets       jsonb;       -- [443] sale.extra_markets
  v_opt_lips      numeric;     -- [443]
  v_opt_cosme     numeric;     -- [443]
  v_tier_prefix   text;        -- [461] 구간 경계 열쇠 앞머리 — issued.form_type 으로 정한다(_orient_tier_prefix)
  v_tier_t50      numeric;     -- [454→459] 구간 경계값(시작값) — 461 부터 형식별 열쇠에서 읽는다
  v_tier_t100     numeric;     -- [454→459→461]
  v_tier_t300     numeric;     -- [459→461] 🔴 459 부터 실제 경계로 쓰인다(454 에서는 안 쓰였다)
  v_tier_t500plus numeric;     -- [454→459→461]
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

  -- [461] 형식 → 구간 경계 열쇠 앞머리. 🔴 모르는 형식(NULL)이면 **경계 존재 검사보다 먼저** 닫는다 —
  --   순서를 안 지키면 NULL || 'slots_t50' = NULL 이라 `v_basis ? NULL` 이 unknown(=false 취급) 이 되어
  --   존재 검사가 조용히 실패해 fee_missing 으로 바뀐다(459 의 형식 ELSE 분기와 다른 결과가 된다).
  --   424 가 issued.form_type 을 reviewer|seeding 으로만 막으므로 실제로는 도달하지 않는 방어선이다.
  v_tier_prefix := public._orient_tier_prefix(v_ft);
  IF v_tier_prefix IS NULL THEN
    v_quote_error := 'price_unreadable';
  END IF;

  -- [459→461] 구간 경계값(시작값) — 그 형식의 열쇠(reviewer_tier_slots_*·seeding_tier_slots_*)에서
  --   읽는다. 넷(t50·t100·t300·t500plus) 중 하나라도 행이 없으면 fee_missing 으로 닫는다.
  IF v_quote_error IS NULL AND v_slots IS NOT NULL AND v_slots > 0 THEN
    IF v_basis ? (v_tier_prefix || 'slots_t50') AND v_basis ? (v_tier_prefix || 'slots_t100')
       AND v_basis ? (v_tier_prefix || 'slots_t300') AND v_basis ? (v_tier_prefix || 'slots_t500plus') THEN
      v_tier_t50      := (v_basis ->> (v_tier_prefix || 'slots_t50'))::numeric;
      v_tier_t100     := (v_basis ->> (v_tier_prefix || 'slots_t100'))::numeric;
      v_tier_t300     := (v_basis ->> (v_tier_prefix || 'slots_t300'))::numeric;
      v_tier_t500plus := (v_basis ->> (v_tier_prefix || 'slots_t500plus'))::numeric;
    ELSE
      v_quote_error := 'fee_missing';
    END IF;
  END IF;

  -- [443→454→459] 서버 구간 판정 — 화면이 보낸 slots_tier 를 믿지 않는다. 기준값을 못 읽었으면
  --   (위에서 fee_missing 이나 price_unreadable 이 이미 세워졌으면) v_tier 는 NULL 로 둔다.
  --   🔴 경계 넷 전부 "그 구간의 시작값" — 459 부터 놀고 있는 값이 없다.
  v_tier := CASE
    WHEN v_quote_error IS NOT NULL THEN NULL
    WHEN v_slots IS NULL      THEN NULL
    WHEN v_slots <  v_tier_t50        THEN 'tmin'
    WHEN v_slots <  v_tier_t100       THEN 't50'
    WHEN v_slots <  v_tier_t300       THEN 't100'
    WHEN v_slots <  v_tier_t500plus   THEN 't300'
    ELSE 't500plus' END;

  -- [463] 이름은 quote_tier_labels 표에서 읽는다(관리자가 고친 값). 형식·구간이 정해졌을 때만
  --   조회하고, 행이 없으면(462 시드가 손상된 방어적 상황) §3-1 시드와 같은 기본 이름으로 —
  --   이름은 금액이 아니라 표시라 fee_missing 으로 막지 않는다.
  --   🔴 461 의 "<형식별 t500plus 시작 인원>건" 조립은 지운다(사양서 §3-2 결정 2 — 맨 끝 단추도
  --   다른 구간처럼 「이름」으로 통일한다. 인원은 폼이 「N건」으로 별도 표시한다).
  IF v_tier IS NOT NULL THEN
    SELECT l.name INTO v_tier_label
      FROM public.quote_tier_labels l
     WHERE l.form_type = v_ft AND l.tier = v_tier;
  END IF;
  v_tier_label := COALESCE(v_tier_label, CASE v_tier
    WHEN 'tmin'      THEN '소량'
    WHEN 't50'       THEN '라이트'
    WHEN 't100'      THEN '스탠다드'
    WHEN 't300'      THEN '프리미엄'
    WHEN 't500plus'  THEN '프리미엄+'
    ELSE '' END);

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
      --   ⚠️ 461·463 무변경 — 이 표(reviewer_recruit_fee_krw_*)는 처음부터 형식별로 나뉘어 있었다.
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
      WHEN 'instagram_feed'  THEN '인스타그램 피드'    -- [586] ⚠️ 화면(orient.html CHANNEL_LABEL·admin OS_CH_LABEL)과 같은 띄어쓰기 표기 — 견적서 한 장 안에서 두 표기가 갈리면 안 된다
      WHEN 'instagram_reels' THEN '인스타그램 릴스'
      WHEN 'x'               THEN 'X'
      WHEN 'tiktok'          THEN '틱톡'
      WHEN 'youtube'         THEN '유튜브'
      ELSE COALESCE(v_ch, '채널') END;

    -- [443] 진행비 — 채널×구간. 예외가 있으면 그 값. ⚠️ 461·463 무변경 — 이 표도 처음부터 형식별.
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

  -- [443] 실검작업 — 인원 500 이상일 때만, 형식과 무관. 옵션 문구와도 무관(462·463 — 표시일 뿐).
  --   🔴 세 값 모두 JSON null(빈 문자열 금지)
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
      'tier_name',          v_tier_label,          -- [463] 그 순간 쓴 구간 이름 스냅샷(사양서 §3-3) — 이름을 나중에 바꿔도 이 값은 그대로
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 463 과 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[586, 베이스 463] 오리엔시트 견적 계산 본문 — 구간 경계(t50·t100·t300·t500plus, 전부 "그 구간의 시작값") '
  '넷을 그 시트 형식의 기준값(reviewer_tier_slots_*·seeding_tier_slots_*)에서 읽어 5갈래(tmin·t50·t100·t300·t500plus)로 '
  '판정한다(형식을 모르면 존재 검사보다 먼저 price_unreadable, 460 이 없는 행을 만들면 fee_missing). '
  '[463] 구간 이름은 quote_tier_labels 표에서 읽는다(관리자가 고친 값, 행 없으면 §3-1 시드와 같은 기본 이름) — '
  't500plus 도 다른 구간과 같은 방식(461 의 "<시작 인원>건" 조립은 폐기), 스냅샷에 tier_name 추가. '
  '구간별 모집비·시딩 진행비(tmin 포함, 열쇠는 461 이전과 무변경), 발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), '
  '리뷰어 추가 옵션(LIPS·@cosme), 500건 이상 구간이면 형식·옵션 문구와 무관하게 「실검작업 — 담당자 협의」(값 없음·합계 제외), '
  '페이백 줄 이름 「판매가」. [586] 시딩 채널 이름은 화면과 같은 띄어쓰기(인스타그램 피드·인스타그램 릴스). '
  'submit_orient_sheet·preview_orient_quote 가 공용(preview 는 최소 인원 검사를 안 받는다 — 그건 submit 몫). '
  '실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 586.';

-- ================================================================
-- [2] 견적 기준값 행 이름표 — 하이픈만 띄어쓰기로(금액·열쇠말 무변경)
-- ================================================================
UPDATE public.quote_settings
   SET label_ko = replace(replace(label_ko, '인스타그램-피드', '인스타그램 피드'), '인스타그램-릴스', '인스타그램 릴스')
 WHERE label_ko LIKE '%인스타그램-피드%' OR label_ko LIKE '%인스타그램-릴스%';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '586', '586_orient_quote_channel_label_spacing.sql');
COMMIT;

-- ============================================================
-- 적용 뒤 확인(개발 SQL 편집기, 읽기만 — 하나씩)
--   ① 기록:   SELECT * FROM public.migration_ledger WHERE key = '586' ORDER BY id DESC LIMIT 3;
--   ② 함수:   SELECT position('인스타그램 피드' in pg_get_functiondef('public._orient_compute_quote(jsonb,text,timestamptz,timestamptz)'::regprocedure)) > 0 AS new_label,
--                    position('인스타그램-피드' in pg_get_functiondef('public._orient_compute_quote(jsonb,text,timestamptz,timestamptz)'::regprocedure)) = 0 AS no_old;
--   ③ 권한:   SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public._orient_compute_quote(jsonb,text,timestamptz,timestamptz)'::regprocedure;
--             기대: 맨 앞에 「=X/」(PUBLIC 실행) 없음, anon·authenticated 없음
--   ④ 이름표: SELECT key, label_ko FROM public.quote_settings WHERE label_ko LIKE '%인스타그램%' ORDER BY sort_order;
--             기대: 하이픈 0행, 진행비 10행이 「인스타그램 피드·릴스」
--   ⑤ 계산:   SELECT l->>'label' FROM jsonb_array_elements((public._orient_compute_quote(
--               '{"issued":{"form_type":"seeding","channel":"instagram_feed"},"cards":[{"product":{"slots":"60"}}]}'::jsonb,
--               'TEST', now(), now()) -> 'quote' -> 'lines')) l;
--             기대: 「시딩 진행비 — 인스타그램 피드 (…)」 · 「제품 제공 (브랜드 부담)」 (시트를 쓰지 않는 계산만)
-- ============================================================
