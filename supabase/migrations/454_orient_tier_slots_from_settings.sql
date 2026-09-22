-- ============================================================
-- 454_orient_tier_slots_from_settings.sql
-- 2026-09-18 — 오리엔시트 구간별 모집 인원을 기준 데이터로 · 마이그레이션 ②
--   사양서 docs/specs/2026-09-18-orient-tier-slots-as-settings.md §3-2 · §3-3 · §3-4
--
-- 🔴 적용 순서 — 453 이 반드시 먼저다. 이 파일은 453 이 만든 tier_slots_t50·t100·t300·t500plus
--   4행을 읽는다. 453 없이 이 파일만 넣으면 그 행이 없어 **모든 견적이 fee_missing** 이 된다
--   (조용한 오답이 아니라 눈에 보이는 거부라 그나마 낫다 — 443 이 442 에 기댄 것과 같은 이유).
--
-- 셋을 재정의한다
--   A. `_orient_compute_quote`   — 🔴 베이스 **452**(430→431→443→448→452). 구간 판정 CASE 문 하나만
--      하드코딩(50·100·499·500)에서 기준값 읽기로 바꾼다. 그 외 단 한 줄도 다르지 않다.
--   B. `get_orient_tier_fees`    — 🔴 베이스 **448**. 반환에 `slots` 키(구간 인원 넷)를 더한다.
--      기존 키(success·fees·override_krw·form_type)는 그대로 둔다 — 작성 폼(orient.html)이 이미
--      `res.slots` 를 읽는 코드(`applyTierSlots`)를 갖고 있다(453 이전에 다른 작업으로 먼저 커밋됨).
--   C. `update_quote_setting`    — 🔴 베이스 **426**. 구간 인원 행(tier_slots_*)을 고칠 때만
--      네 값이 오름차순인지 검사한다. 다른 행은 종전대로 검사 없음. 거부 사유 코드는
--      정확히 `tier_slots_not_ascending` — 관리자 화면(admin-lookups.js `saveQuoteSetting`)이
--      이미 이 글자를 보고 한국어 문구로 바꾼다.
--
-- ------------------------------------------------------------
-- A 의 판정식 — 무엇이 바뀌고 무엇이 안 바뀌는가
-- ------------------------------------------------------------
--   지금(452):  v_slots <= 50 → t50 / <= 100 → t100 / <= 499 → t300 / 그 밖 → t500plus
--   이 파일:    v_slots <= tier_slots_t50 → t50 / <= tier_slots_t100 → t100 /
--               v_slots <  tier_slots_t500plus → t300 / 그 밖 → t500plus
--   🔴 셋째 조건만 부등호가 다르다(`<` 다) — 지금의 `<= 499` 는 "넷째 값(500) − 1" 이었다.
--      `tier_slots_t300`(300, 사양서 §3-2 표의 셋째 값)은 이 판정에 **안 쓰인다** — 판정 경계는
--      항상 t50·t100·t500plus 셋뿐이고, t300 은 단추 인원 표시용으로만 존재한다(453 주석과 동일).
--   기본값(50·100·300·500)일 때는 이 새 판정식이 지금과 **정확히 같은 결과**를 낸다
--      (v_slots < 500 ⇔ v_slots <= 499, 정수라 동치).
--   기준값 행(t50·t100·t500plus 셋)이 하나라도 없으면 `fee_missing` 으로 닫는다(v_tier := NULL,
--      그 뒤 reviewer/seeding 분기에서 `v_fee_key` 가 NULL 이 되어 자연히 같은 코드로 수렴 —
--      아래 [설계 메모] 참고). t300 행이 없어도 판정 자체는 막지 않는다(안 쓰이므로).
--
-- [설계 메모] fee_missing 을 어디서 세우나
--   452 의 reviewer/seeding 분기는 자기 안에서 `v_basis ? v_fee_key` 로 또 한 번 행 존재를 검사해
--   없으면 fee_missing 을 세운다. v_tier 가 NULL 이면 `v_fee_key := '…' || v_tier` 가 NULL 이 되고
--   (텍스트 || NULL = NULL), `v_basis ? NULL` 도 NULL(= IF 조건에서 거짓 취급)이라 같은 ELSE 경로로
--   떨어져 결국 fee_missing 이 된다. 그래서 이 파일은 **v_tier 계산 직전에 한 번만** 명시적으로
--   fee_missing 을 세우고, 나머지는 452 가 이미 하던 이중 방어를 그대로 둔다(코드 흐름을 더
--   바꾸지 않기 위해).
--
-- ------------------------------------------------------------
-- B — 새 키 `slots` 는 왜 두 반환 지점 모두에 있어야 하나
-- ------------------------------------------------------------
--   448 의 함수는 두 곳에서 RETURN 한다: ①발급 시 모집비를 직접 지정한 시트(override_krw 경로)
--   ②일반 시트(fees 경로). 작성 폼(orient.html)의 `applyTierSlots(res.slots)` 는 어느 경로든
--   `res.slots` 를 기대하므로 **양쪽 다** 채운다. 이 값은 override 여부와 무관하게 항상 같은
--   네 구간 인원이다(override 는 "단가"만 바꾸지 "구간 경계"는 안 바꾼다).
--
-- ------------------------------------------------------------
-- C — 오름차순 검사가 저장을 막는 유일한 경우
-- ------------------------------------------------------------
--   `update_quote_setting` 은 한 번에 한 값만 바꾼다(p_key, p_amount). 구간 인원 넷 중 하나를
--   저장하려 할 때, 지금 표에 저장된 나머지 셋 + 지금 저장하려는 값을 합쳐 **엄격히** 오름차순인지
--   본다(같은 값도 거부 — 사양서 §2-② "같은 값도 거부(두 단추가 같은 인원이 되어 뜻이 없다)").
--   다른 행(환율·수수료·모집비 등)은 이 검사를 거치지 않는다.
--
-- 🔴 셋 다 CREATE OR REPLACE 로 충분하다(인자 목록 전부 불변) — 그래도 이 저장소 관례대로
--   (448·452 가 그랬듯) REVOKE 를 한 번씩 다시 건다. 대상이 없어도 무해하고, 개발·운영 권한
--   상태가 다를 수 있다는 반복 경고와 같은 이유다.
--
-- 되돌리기: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행(452·448·426 함수 본문을 그대로 복구).
-- ============================================================
BEGIN;

-- ================================================================
-- A. _orient_compute_quote — 베이스 452, 구간 판정만 기준값에서 읽는다
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
  v_tier          text;        -- [443] t50 · t100 · t300 · t500plus
  v_tier_label    text;        -- [443→448] 라이트 · 스탠다드 · 프리미엄 · 500건
  v_fee_key       text;        -- [443] 읽을 기준값 열쇠말
  v_override      numeric;     -- [443] issued.recruit_fee_krw (없으면 NULL)
  v_suffix        text;        -- [443] ' · 직접 지정' 또는 ''
  v_markets       jsonb;       -- [443] sale.extra_markets
  v_opt_lips      numeric;     -- [443]
  v_opt_cosme     numeric;     -- [443]
  v_tier_t50      numeric;     -- [454] 구간 경계값 — 기준값(quote_settings)에서 읽는다
  v_tier_t100     numeric;     -- [454]
  v_tier_t500plus numeric;     -- [454] 🔴 tier_slots_t300 은 판정에 안 쓴다(단추 인원 표시용일 뿐)
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

  -- [454] 구간 경계값 — 기준값(quote_settings)에서 읽는다. 셋(t50·t100·t500plus) 중 하나라도
  --   행이 없으면 fee_missing 으로 닫는다(옛 하드코딩으로 조용히 안 돌아간다 — 사양서 §3-2).
  IF v_slots IS NOT NULL AND v_slots > 0 THEN
    IF v_basis ? 'tier_slots_t50' AND v_basis ? 'tier_slots_t100' AND v_basis ? 'tier_slots_t500plus' THEN
      v_tier_t50      := (v_basis ->> 'tier_slots_t50')::numeric;
      v_tier_t100     := (v_basis ->> 'tier_slots_t100')::numeric;
      v_tier_t500plus := (v_basis ->> 'tier_slots_t500plus')::numeric;
    ELSE
      v_quote_error := 'fee_missing';
    END IF;
  END IF;

  -- [443→454] 서버 구간 판정 — 화면이 보낸 slots_tier 를 믿지 않는다. 기준값을 못 읽었으면(위에서
  --   fee_missing 이 이미 세워졌으면) v_tier 는 NULL 로 둔다 — 아래 reviewer/seeding 분기가
  --   NULL 티어를 자연히 fee_missing 으로 다시 수렴시킨다(파일 머리말 [설계 메모] 참고).
  v_tier := CASE
    WHEN v_quote_error IS NOT NULL THEN NULL
    WHEN v_slots IS NULL      THEN NULL
    WHEN v_slots <= v_tier_t50        THEN 't50'
    WHEN v_slots <= v_tier_t100       THEN 't100'
    WHEN v_slots <  v_tier_t500plus   THEN 't300'
    ELSE 't500plus' END;
  v_tier_label := CASE v_tier
    WHEN 't50'       THEN '라이트'
    WHEN 't100'      THEN '스탠다드'
    WHEN 't300'      THEN '프리미엄'
    WHEN 't500plus'  THEN '500건'          -- [448] 네 번째 구간은 「500건」 고정(직접 입력 없음). 🔴 판정 경계(그 값 이상)는 그대로 — 조작된 호출·옛 값(700 등)도 이 구간이다
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 452 와 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[454, 베이스 452] 오리엔시트 견적 계산 본문 — 구간 경계(t50·t100·t500plus)를 기준값(quote_settings.tier_slots_*)에서 '
  '읽어 판정한다(453 이 없는 행을 만들면 fee_missing). 구간별 모집비·시딩 진행비, 발급 예외(issued.recruit_fee_krw → '
  '줄 이름에 「· 직접 지정」), 리뷰어 추가 옵션(LIPS·@cosme), 500건 이상이면 형식과 무관하게 「실검작업 — 담당자 협의」 '
  '(값 없음·합계 제외), 기준값 행이 없으면 fee_missing. 페이백 줄 이름 「판매가」. '
  'submit_orient_sheet·preview_orient_quote 가 공용. 실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 454.';

-- ================================================================
-- B. get_orient_tier_fees — 베이스 448, 반환에 slots(구간 인원 넷) 추가
-- ================================================================
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
  v_slots    jsonb;   -- [454] 구간 인원 넷 — {"t50":50,"t100":100,"t300":300,"t500plus":500}
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

  -- [454] 구간 인원 넷 — 형식·채널과 무관하게 항상 같은 값(override 여부와도 무관, 아래 두 RETURN
  --   경로 모두에서 쓴다). 행이 없는 구간은 키 자체가 빠진다(폼은 그 구간에 기본값을 그대로 쓴다).
  SELECT COALESCE(jsonb_object_agg(t.tier, (q.amount)::integer), '{}'::jsonb)
    INTO v_slots
    FROM unnest(ARRAY['t50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = 'tier_slots_' || t.tier;

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
                              'override_krw', v_override, 'fees', '{}'::jsonb, 'slots', v_slots);
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
                            'override_krw', NULL, 'fees', v_fees, 'slots', v_slots);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[454, 베이스 448] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식·채널에 해당하는 구간 단가 넷(t50·t100·t300·t500plus) + '
  '구간 인원 넷(slots, quote_settings.tier_slots_*)을 돌려준다. 발급 때 모집비를 직접 지정한 시트는 override_krw 하나 + '
  '빈 fees(slots 는 그대로 준다). 읽기 전용. anon GRANT(preview_orient_quote 가 이미 basis 전체를 주므로 새 노출 없음).';

-- ================================================================
-- C. update_quote_setting — 베이스 426, 구간 인원 행 오름차순 검사 추가
-- ================================================================
CREATE OR REPLACE FUNCTION public.update_quote_setting(p_key text, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_prev   numeric;
  v_unit   text;
  v_name   text;
  v_t50    numeric;   -- [454] 오름차순 검사용 — 구간 인원 4값(지금 고치는 키는 p_amount 로 덮는다)
  v_t100   numeric;
  v_t300   numeric;
  v_t500   numeric;
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_amount');
  END IF;

  SELECT amount, unit INTO v_prev, v_unit FROM public.quote_settings WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_key');
  END IF;
  -- 비율(부가세율)은 0~1 사이만 — 10 을 넣어 1000% 가 되는 실수 방지
  IF v_unit = 'rate' AND p_amount > 1 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_amount');
  END IF;

  -- [454] 구간 인원 4행은 오름차순이어야 한다(사양서 §2-②) — 단추와 판정이 어긋나면
  --   브랜드가 고른 구간과 다른 구간 단가가 적용돼 틀린 금액이 견적서에 찍힌다.
  --   같은 값도 거부(두 단추가 같은 인원이 되면 뜻이 없다). 다른 행은 이 검사를 거치지 않는다.
  IF p_key IN ('tier_slots_t50', 'tier_slots_t100', 'tier_slots_t300', 'tier_slots_t500plus') THEN
    SELECT amount INTO v_t50  FROM public.quote_settings WHERE key = 'tier_slots_t50';
    SELECT amount INTO v_t100 FROM public.quote_settings WHERE key = 'tier_slots_t100';
    SELECT amount INTO v_t300 FROM public.quote_settings WHERE key = 'tier_slots_t300';
    SELECT amount INTO v_t500 FROM public.quote_settings WHERE key = 'tier_slots_t500plus';
    -- 지금 저장하려는 값으로 그 자리만 덮어써서 판정(한 번에 한 값만 바뀐다)
    IF p_key = 'tier_slots_t50'      THEN v_t50  := p_amount; END IF;
    IF p_key = 'tier_slots_t100'     THEN v_t100 := p_amount; END IF;
    IF p_key = 'tier_slots_t300'     THEN v_t300 := p_amount; END IF;
    IF p_key = 'tier_slots_t500plus' THEN v_t500 := p_amount; END IF;

    IF v_t50 IS NULL OR v_t100 IS NULL OR v_t300 IS NULL OR v_t500 IS NULL
       OR NOT (v_t50 < v_t100 AND v_t100 < v_t300 AND v_t300 < v_t500) THEN
      RETURN jsonb_build_object('success', false, 'reason', 'tier_slots_not_ascending');
    END IF;
  END IF;

  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  UPDATE public.quote_settings
     SET amount = p_amount, updated_at = now(), updated_by = auth.uid()
   WHERE key = p_key;

  INSERT INTO public.quote_settings_history (key, prev_amount, next_amount, actor, actor_name)
  VALUES (p_key, v_prev, p_amount, auth.uid(), v_name);

  RETURN jsonb_build_object('success', true, 'key', p_key, 'prev_amount', v_prev, 'amount', p_amount);
END;
$$;

REVOKE ALL ON FUNCTION public.update_quote_setting(text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_quote_setting(text, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_quote_setting(text, numeric) TO authenticated;

COMMENT ON FUNCTION public.update_quote_setting(text, numeric) IS
  '[454, 베이스 426] 견적 기준값 수정 — 캠페인 관리자 이상(is_campaign_admin). 값이 같아도 이력 1행. 거부 reason: '
  'forbidden·invalid_amount·unknown_key·tier_slots_not_ascending(구간 인원 4행 전용, 엄격 오름차순 아니면 거부). '
  '비율(unit=rate)은 0~1 만 허용.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 반드시 453 을 먼저 적용한 뒤)
-- ============================================================
/*
-- [V1] 기본값(50·100·300·500)에서 452 와 같은 경계로 판정되는가 — 8개 표본
SELECT s AS slots,
       (public._orient_compute_quote(
          jsonb_build_object('issued', jsonb_build_object('form_type','reviewer','channel',NULL),
                             'cards', jsonb_build_array(jsonb_build_object(
                               'product', jsonb_build_object('slots', s::text),
                               'sale',    jsonb_build_object('price_regular','3429')))),
          'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier') AS tier
  FROM unnest(ARRAY[50,51,100,101,499,500,700]) s;
-- 기대: t50 · t100 · t100 · t300 · t300 · t500plus · t500plus (452 검증 [V1]과 동일 결과)

-- [V2] 🔴 판정이 기준값을 실제로 읽는가 — 둘째 경계를 150 으로 바꾸고 120명으로 계산
BEGIN;
UPDATE public.quote_settings SET amount = 150 WHERE key = 'tier_slots_t100';
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"120"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier';
-- 기대: t100 (지금은 <=100 이라 t300 이어야 하는데, 150 으로 늘렸으므로 t100)
ROLLBACK;

-- [V3] 셋째 구간 상한이 넷째 값을 따라 움직이는가 — 500 → 600 으로 바꾸고 550/700명 확인
BEGIN;
UPDATE public.quote_settings SET amount = 600 WHERE key = 'tier_slots_t500plus';
SELECT s, (public._orient_compute_quote(
  jsonb_build_object('issued', jsonb_build_object('form_type','reviewer','channel',NULL),
                     'cards', jsonb_build_array(jsonb_build_object(
                       'product', jsonb_build_object('slots', s::text),
                       'sale',    jsonb_build_object('price_regular','3429')))),
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier')
  FROM unnest(ARRAY[550, 700]) s;
-- 기대: 550→t300(600 미만이라 아직 프리미엄) · 700→t500plus
ROLLBACK;

-- [V4] fee_missing — 구간 경계값 행 하나를 지우면
BEGIN;
DELETE FROM public.quote_settings WHERE key = 'tier_slots_t100';
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"100"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) ->> 'quote_error';
-- 기대: fee_missing
ROLLBACK;

-- [V5] get_orient_tier_fees — slots 키가 항상 붙는가(실제 토큰으로, 새 구조 시트)
--   SELECT public.get_orient_tier_fees('<새 구조 시트 토큰>'::uuid);
--   기대: success:true, slots:{"t50":50,"t100":100,"t300":300,"t500plus":500} (기본값일 때)
--         fees 도 함께 채워짐(override 없는 시트) 또는 override_krw 채워지고 fees={}(직접 지정 시트) — 어느 쪽이든 slots 는 있다

-- [V6] 🔴 오름차순 검사 — 둘째를 400 으로 올리면 거부(셋째 300 을 넘어서므로)
SELECT public.update_quote_setting('tier_slots_t100', 400);
-- 기대: {"success":false,"reason":"tier_slots_not_ascending"} (트랜잭션 안에서 시험 — 아래 [V7] 전에 값이 이미 바뀌어 있지 않은지 확인할 것)

-- [V7] 정상 순서는 저장되는가 — 둘째를 90(50 초과·300 미만)으로
SELECT public.update_quote_setting('tier_slots_t100', 90);
-- 기대: {"success":true, ...} — 확인 후 원복: SELECT public.update_quote_setting('tier_slots_t100', 100);

-- [V8] 같은 값도 거부되는가 — 셋째를 100(둘째와 동일)으로
SELECT public.update_quote_setting('tier_slots_t300', 100);
-- 기대: tier_slots_not_ascending (원복 불필요 — 거부돼 값이 안 바뀐다)

-- [V9] 권한 — 세 함수 모두 다시 열리지 않았는가
SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('_orient_compute_quote', 'get_orient_tier_fees', 'update_quote_setting');
-- 기대: _orient_compute_quote — anon·authenticated·맨 앞 `=X/` 없음
--       get_orient_tier_fees   — anon=X·authenticated=X 있고 맨 앞 `=X/` 없음
--       update_quote_setting   — authenticated=X 있고 anon·맨 앞 `=X/` 없음

-- [V10] 지난 견적(스냅샷)은 안 변하는가 — 이미 저장된 시트의 quote.tier·quote.lines 는 이 배포와 무관
--   (data->'quote' 는 제출 시점 스냅샷이라 이 마이그레이션이 UPDATE 하지 않는다 — 코드 리뷰로 확인 가능,
--   실제 저장된 시트가 있으면 SELECT data->'quote' FROM orient_sheets WHERE token='<토큰>' 으로 적용 전후 비교)
*/

-- ============================================================
-- 되돌리기 (그대로 실행) — 452·448·426 의 함수 본문을 다시 CREATE OR REPLACE 로 덮는다.
--   452_orient_quote_label_sale_price.sql · 448_orient_tier_500_fixed_and_fee_lookup.sql ·
--   426_quote_settings.sql 각 파일의 함수 블록을 이 순서로 그대로 재실행하면 된다.
--   🔴 get_orient_tier_fees 는 448 판(slots 키 없음)으로 돌아가므로, 되돌린 뒤에는
--      작성 폼의 applyTierSlots(res.slots) 가 항상 no-op(slots undefined)이 되어
--      폼이 기본값(50·100·300·500)으로만 동작한다 — 코드도 같이 되돌리지 않는 한 정상이다.
-- ============================================================
