-- ============================================================
-- 448: 오리엔시트 — 네 번째 구간을 「500건」 고정으로 + 작성 폼에 구간별 단가 표시
-- ============================================================
-- 사양서: docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md 「구현 결과 — 2026-09-17 추가 결정」
--
-- 2026-09-17 사용자 결정 셋
--   ① 네 번째 구간은 「500건 이상(직접 입력)」이 아니라 **「500건」 고정**이고 단추에 「(+실검작업)」을 덧붙인다.
--      직접 입력은 없앤다 → 화면에서 나올 수 있는 인원은 50·100·300·500 넷뿐이다.
--   ② 「실검작업」은 **리뷰어·시딩 둘 다** 붙는다(443 의 서버 동작 그대로 — 사양서 결정 3 의 「리뷰어 전용」을 뒤집었다).
--   ③ 구간 단추마다 **1건당 단가**를 보여준다(어느 구간이 싼지 고르기 전에 보이게).
--
-- 이 파일이 하는 일 셋
--   A. `quote_settings.label_ko` 6행 — 「500건 이상」 → 「500건」(관리자 「견적 기준값」 화면의 행 이름). 금액·열쇠말은 그대로.
--   B. `_orient_compute_quote` 재정의(🔴 베이스 **443** — 본문은 443 과 같고 **구간 이름 한 줄**만 다르다).
--      견적 줄 이름이 「모집비 (500건 이상)」 → 「모집비 (500건)」.
--      🔴 **판정 경계(500 이상 = t500plus)는 안 바꾼다** — 옛 값(700 등)·조작된 호출도 같은 구간으로 계산돼야 한다.
--      🔴 열쇠말 `t500plus` 도 안 바꾼다 — 기준값 6행·저장된 `slots_tier`·`quote.tier` 가 전부 그 글자를 쓴다.
--      `CREATE OR REPLACE` 라 443 의 권한 회수(PUBLIC·anon·authenticated)가 그대로 남는다.
--   C. 신규 익명 함수 `get_orient_tier_fees(p_token uuid)` — 그 시트의 형식·채널에 해당하는 **구간 단가 넷**만 돌려준다.
--      왜 새 함수인가: 폼을 여는 즉시(인원을 고르기 전) 보여야 하는데, 기존 `preview_orient_quote`(430)는 인원이 없으면
--        `slots_missing` 만 주고 기준값을 안 준다.
--      노출 범위: `preview_orient_quote` 는 이미 `quote.basis` 로 **기준값 표 전체**를 익명에게 준다 → 이 함수는 그보다 적게 준다.
--      토큰 검사는 `preview_orient_quote` 와 같은 순서(미매칭 → 발행됨 → 만료). 읽기 전용(STABLE).
--      🔴 발급 때 모집비를 직접 지정한 시트(`issued.recruit_fee_krw`, 447)는 네 구간이 전부 같은 값이라 비교가 무의미하다
--        → `override_krw` 하나만 주고 `fees` 는 비운다(화면은 「협의된 단가」 한 줄로 그린다). 0 도 값이다(무료 진행).
--
-- 배포 순서: **424~447 사슬 전체가 들어간 뒤**(443 을 고쳐 쓰고, 443 은 442·424 에 기댄다), **작성 폼(sales)보다 앞**. 폼이 먼저 나가면 함수가 없어 단가 줄만 안 그려진다(폼은 그대로 동작).
--   🔴 이 함수 때문에 **시딩 가짜 단가(99001~99020)가 폼 첫 화면에 뜬다** — 운영에서는 「견적 기준값」에 실제 금액을 넣은 뒤에 폼을 내보낸다(사양서 §7 ★ 단계).
--
-- 되돌리기: A 는 같은 UPDATE 를 반대로, B 는 443 의 함수 블록을 다시 실행, C 는 `DROP FUNCTION public.get_orient_tier_fees(uuid);`
-- ============================================================
BEGIN;

-- ── A. 기준값 행 이름 ───────────────────────────────────────────
UPDATE public.quote_settings
   SET label_ko = replace(label_ko, '500건 이상', '500건')
 WHERE key IN (
   'reviewer_recruit_fee_krw_t500plus',
   'seeding_fee_krw_instagram_feed_t500plus',
   'seeding_fee_krw_instagram_reels_t500plus',
   'seeding_fee_krw_x_t500plus',
   'seeding_fee_krw_tiktok_t500plus',
   'seeding_fee_krw_youtube_t500plus'
 )
   AND label_ko LIKE '%500건 이상%';

-- ── B. 견적 계산 — 구간 이름 한 줄만 다르다(베이스 443) ─────────
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 443 과 같은 회수를 한 번 더 건다(대상이 없어도 무해 — 개발·운영 권한 상태가 다를 수 있다)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[448, 베이스 443] 오리엔시트 견적 계산 본문 — 인원으로 구간 판정(t50·t100·t300·t500plus), 구간별 모집비·시딩 진행비, '
  '발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), 리뷰어 추가 옵션(LIPS·@cosme), 500건 이상이면 형식과 무관하게 '
  '「실검작업 — 담당자 협의」(값 없음·합계 제외), 기준값 행이 없으면 fee_missing. [448] 네 번째 구간 이름 「500건」(판정 경계는 그대로). '
  'submit_orient_sheet·preview_orient_quote 가 공용. 실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 448.';

-- ── C. 구간 단가 조회(익명) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet    record;
  v_issued   jsonb;
  v_ft       text;
  v_ch       text;
  v_prefix   text;
  v_override numeric;
  v_fees     jsonb;
  v_now      timestamptz := now();
BEGIN
  -- 토큰 검사 — preview_orient_quote(430)와 같은 순서
  SELECT s.token_expires_at, s.status, s.data
    INTO v_sheet
    FROM public.orient_sheets s
   WHERE s.token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 새 구조 시트만(구간 개념이 없는 옛 시트에는 줄 것이 없다)
  v_issued := v_sheet.data -> 'issued';
  IF v_issued IS NULL OR jsonb_typeof(v_issued) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_new_layout');
  END IF;
  v_ft := v_issued ->> 'form_type';
  v_ch := v_issued ->> 'channel';

  -- 발급 때 모집비 직접 지정(447) — 443 과 같은 읽기. 키가 있으면(0 포함) 그 값 하나만 준다
  --   ⚠️ 447 은 bigint 로만 넣으므로 숫자가 아닌 값은 올 수 없다. 그래도 한 겹 감싼다 — 443 의 같은 읽기는 부르는 쪽이
  --      예외를 받아 주는데 이 함수는 받아 줄 곳이 없어, 터지면 폼이 아니라 요청 자체가 500 이 된다(데이터베이스 검토 권고)
  BEGIN
    v_override := CASE WHEN v_issued ? 'recruit_fee_krw'
                       THEN NULLIF(v_issued ->> 'recruit_fee_krw', '')::numeric END;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'reason', 'override_unreadable');
  END;
  IF v_override IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'form_type', v_ft, 'channel', v_ch,
                              'override_krw', v_override, 'fees', '{}'::jsonb);
  END IF;

  -- 열쇠말 앞머리 — 443 의 v_fee_key 와 같은 조립
  v_prefix := CASE v_ft
    WHEN 'reviewer' THEN 'reviewer_recruit_fee_krw_'
    WHEN 'seeding'  THEN 'seeding_fee_krw_' || COALESCE(v_ch, '') || '_'
    ELSE NULL END;
  IF v_prefix IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_form_type');
  END IF;

  -- 행이 없는 구간은 키 자체가 빠진다(화면은 그 단추에 금액을 안 그린다 — 0원으로 그리지 않는다)
  SELECT COALESCE(jsonb_object_agg(t.tier, q.amount), '{}'::jsonb)
    INTO v_fees
    FROM unnest(ARRAY['t50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = v_prefix || t.tier;

  RETURN jsonb_build_object('success', true, 'form_type', v_ft, 'channel', v_ch,
                            'override_krw', NULL, 'fees', v_fees);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[448] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식·채널에 해당하는 구간 단가 넷(t50·t100·t300·t500plus)만 돌려준다. '
  '발급 때 모집비를 직접 지정한 시트는 override_krw 하나 + 빈 fees. 읽기 전용. anon GRANT(preview_orient_quote 가 이미 basis 전체를 주므로 새 노출 없음).';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후)
-- ------------------------------------------------------------
-- [V1] 행 이름 — 「500건 이상」이 남아 있지 않은가
--   SELECT key, label_ko FROM public.quote_settings WHERE key LIKE '%t500plus' ORDER BY sort_order;
--   기대: 6행, 전부 「… 500건」 / 「… (500건)」
--
-- [V2] 단가 조회 — 리뷰어 시트 토큰 / 시딩 시트 토큰 / 모집비 직접 지정 시트 토큰 / 없는 토큰
--   SELECT public.get_orient_tier_fees('<토큰>'::uuid);
--   기대: 리뷰어 fees={t50:8000,t100:7500,t300:7000,t500plus:6500} · 시딩 fees=그 채널의 넷 · 직접 지정 override_krw=그 값 + fees={} · 없는 토큰 invalid_token
--
-- [V3] 견적 줄 이름 — 500건 리뷰어 미리보기
--   SELECT public.preview_orient_quote('<토큰>'::uuid, <slots 를 500 으로 바꾼 data>) -> 'quote' -> 'lines';
--   기대: 「모집비 (500건)」 + realtime_search 줄(값 셋 다 null) · 합계는 그 줄을 빼고 계산
--
-- [V4] 권한 — 내부 함수가 다시 열리지 않았는가
--   SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname IN ('_orient_compute_quote', 'get_orient_tier_fees');
--   기대: _orient_compute_quote 에 anon·authenticated·맨 앞 `=X/` 없음 / get_orient_tier_fees 에 anon=X·authenticated=X 있고 맨 앞 `=X/` 없음
-- ============================================================
