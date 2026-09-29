-- ============================================================
-- 463_orient_tier_labels_in_quote.sql
-- 2026-09-21 — 오리엔시트 견적 구간 이름·옵션 문구를 관리자가 고친다 · 마이그레이션 ②
--   (_orient_compute_quote·get_orient_tier_fees 재정의, 베이스 461)
--   사양서 docs/specs/2026-09-21-orient-tier-names-editable.md §3-2 · §3-3 · §3-4
--
--   베이스: 461_orient_tier_slots_per_form_functions.sql — 🔴 이 파일의 함수 둘은 전부 461 을
--   그대로 복사한 뒤 이 헤더가 말하는 부분만 고쳤다(454·459 를 베이스로 잡지 말 것 — 형식별
--   구간 인원 분리[461]가 통째로 사라진다).
--   반드시 462_quote_tier_labels.sql 뒤에 적용할 것 — 이 파일의 첫머리 가드가 그 표가 없거나
--   10행이 아니면 즉시 예외를 던져 스스로 확인한다(아래 [0]).
--
-- 이 파일이 하는 일 — 헬퍼 없음, 함수 재정의 2개(전부 한 트랜잭션)
--   [0] 첫머리 가드 — quote_tier_labels 표가 있는가 + 정확히 10행인가. 하나라도 아니면
--       RAISE EXCEPTION 으로 파일 전체를 되돌린다(462 없이 이 파일만 적용되는 경우를 막는다).
--   [1] `_orient_compute_quote`(베이스 461) — 구간 이름(v_tier_label)을 형식별 CASE 대신
--       quote_tier_labels 표에서 읽는다(form_type=issued.form_type, tier=판정된 구간). 행이
--       없으면(방어적 상황) §3-1 시드와 같은 기본 이름(소량·라이트·스탠다드·프리미엄·프리미엄+)
--       으로 — 이름은 금액이 아니라 표시라 fee_missing 으로 막지 않는다. 🔴 461 의 t500plus
--       "<형식별 시작 인원>건" 조립은 지운다(결정 2 — 맨 끝 단추도 이름으로 통일). 견적
--       스냅샷(v_quote)에 `tier_name`(쓴 이름)을 새로 추가한다. 「실검작업 — 담당자 협의」
--       줄 규칙(인원 500 이상이면 형식·옵션과 무관하게 붙는다)은 한 글자도 안 바꾼다.
--   [2] `get_orient_tier_fees`(베이스 461) — 응답에 `names: {tmin,t50,t100,t300,t500plus}` ·
--       `options: {…}` 를 더한다(그 시트 형식의 값, 두 반환 경로[모집비 직접 지정·일반] 모두).
--       행이 없는 구간은 키가 빠진다(462 가 10행을 보장하므로 정상 경로에서는 실제로 안 생긴다).
--       기존 칸(fees·slots·min_slots·override_krw 등)의 모양은 한 글자도 안 바꾼다.
--
-- 🔴 update_quote_setting·submit_orient_sheet 는 이 파일에서 손대지 않는다(사양서 §3-2 — 구간
--   이름 변경은 구간 인원 검사·오름차순 검사·최소 인원 검사와 무관하다). 다음에 그 둘을 고칠
--   때 베이스는 여전히 461.
--
-- 🔴 둘 다 CREATE OR REPLACE 로 충분하다(인자 목록 전부 불변) — 저장소 관례대로 REVOKE·GRANT 를
--   다시 건다(대상이 없어도 무해, 권한은 CREATE OR REPLACE 로 이미 보존된다).
--
-- 롤백: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행(461 판 함수 둘 복구). 462 가 만든 표는
--   이 파일이 손대지 않으므로 그대로 둔다 — 지우려면 462 의 되돌리기를 이어서 실행할 것.
-- ============================================================

BEGIN;

-- ================================================================
-- [0] 첫머리 가드 — quote_tier_labels 표 존재 + 정확히 10행. 하나라도 어긋나면 파일 전체를 되돌린다.
-- ================================================================
DO $guard$
DECLARE
  v_cnt integer;
BEGIN
  IF to_regclass('public.quote_tier_labels') IS NULL THEN
    RAISE EXCEPTION '[463] quote_tier_labels 표가 없습니다 — 462_quote_tier_labels.sql 을 먼저 적용할 것.';
  END IF;

  SELECT count(*) INTO v_cnt FROM public.quote_tier_labels;
  IF v_cnt <> 10 THEN
    RAISE EXCEPTION '[463] quote_tier_labels 이 정확히 10행이 아닙니다(현재 %행) — 462 의 시드가 온전한지 확인할 것.', v_cnt;
  END IF;
END;
$guard$;

-- ================================================================
-- [1] _orient_compute_quote — 베이스 461. 구간 이름을 quote_tier_labels 표에서 읽는다.
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
      WHEN 'instagram_feed'  THEN '인스타그램-피드'    -- ⚠️ 화면(orient.html CHANNEL_LABEL·admin OS_CH_LABEL)과 같은 하이픈 표기 — 견적서 한 장 안에서 두 표기가 갈리면 안 된다
      WHEN 'instagram_reels' THEN '인스타그램-릴스'
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 459·461 과 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[463, 베이스 461] 오리엔시트 견적 계산 본문 — 구간 경계(t50·t100·t300·t500plus, 전부 "그 구간의 시작값") '
  '넷을 그 시트 형식의 기준값(reviewer_tier_slots_*·seeding_tier_slots_*)에서 읽어 5갈래(tmin·t50·t100·t300·t500plus)로 '
  '판정한다(형식을 모르면 존재 검사보다 먼저 price_unreadable, 460 이 없는 행을 만들면 fee_missing). '
  '[463] 구간 이름은 quote_tier_labels 표에서 읽는다(관리자가 고친 값, 행 없으면 §3-1 시드와 같은 기본 이름) — '
  't500plus 도 다른 구간과 같은 방식(461 의 "<시작 인원>건" 조립은 폐기), 스냅샷에 tier_name 추가. '
  '구간별 모집비·시딩 진행비(tmin 포함, 열쇠는 461 이전과 무변경), 발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), '
  '리뷰어 추가 옵션(LIPS·@cosme), 500건 이상 구간이면 형식·옵션 문구와 무관하게 「실검작업 — 담당자 협의」(값 없음·합계 제외), '
  '페이백 줄 이름 「판매가」. submit_orient_sheet·preview_orient_quote 가 공용(preview 는 최소 인원 검사를 안 받는다 — 그건 submit 몫). '
  '실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 463.';

-- ================================================================
-- [2] get_orient_tier_fees — 베이스 461. 응답에 그 형식의 구간 이름·옵션 문구를 더한다.
-- ================================================================
CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet       record;
  v_issued      jsonb;
  v_ft          text;
  v_ch          text;
  v_tier_prefix text;    -- [461] 구간 경계(시작값) 열쇠 앞머리 — issued.form_type 으로 정한다
  v_prefix      text;    -- 모집비·진행비 열쇠 앞머리(기존 그대로, v_tier_prefix 와는 다른 표를 가리킨다)
  v_override    numeric;
  v_fees        jsonb;
  v_slots       jsonb;     -- 구간 경계(시작값) 넷 — {"t50":50,"t100":150,"t300":300,"t500plus":500}
  v_min_slots   numeric;   -- [459] 최소 인원 — 행이 없으면 1(아무도 안 막는다)
  v_names       jsonb;     -- [463] 그 형식의 구간 이름 다섯 — {"tmin":"소량", ...}
  v_options     jsonb;     -- [463] 그 형식의 구간 옵션 문구 다섯 — {"tmin":"", ..., "t500plus":"+실검작업"}
  v_now         timestamptz := now();
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

  -- [461] 🔴 형식을 **먼저** 정한다 — 459 는 구간 경계를 형식 확인보다 먼저 읽었는데(그때는 공용
  --   열쇠라 상관없었다), 이제 경계가 형식마다 달라 형식을 모르면 어느 표를 읽을지 정할 수 없다.
  v_tier_prefix := public._orient_tier_prefix(v_ft);
  IF v_tier_prefix IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_form_type');
  END IF;

  -- [463] 구간 이름·옵션 문구 — 그 형식의 값. 행이 없는 구간은 키가 빠진다(462 가 10행을 보장 —
  --   정상 경로에서는 실제로 안 생긴다. 폼은 그 자리에 기본 이름/빈 옵션으로 대체한다 — 사양서 §3-5).
  SELECT COALESCE(jsonb_object_agg(t.tier, l.name), '{}'::jsonb)
    INTO v_names
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_tier_labels l ON l.form_type = v_ft AND l.tier = t.tier;
  SELECT COALESCE(jsonb_object_agg(t.tier, l.option_text), '{}'::jsonb)
    INTO v_options
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_tier_labels l ON l.form_type = v_ft AND l.tier = t.tier;

  -- [461] 구간 경계(시작값) 넷 — 그 형식의 값. 응답 키는 여전히 t50·t100·t300·t500plus(형식
  --   접두 없음) — 작성 폼(orient.html)이 이 모양만 보고 짜여 있어 응답 모양을 바꾸지 않는다.
  --   행이 없는 구간은 키 자체가 빠진다(폼은 그 구간에 단추를 감춘다 — §3-6).
  SELECT COALESCE(jsonb_object_agg(t.tier, (q.amount)::integer), '{}'::jsonb)
    INTO v_slots
    FROM unnest(ARRAY['t50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = v_tier_prefix || 'slots_' || t.tier;

  -- [461] 최소 인원 — 그 형식의 값. 화면이 입력칸 min 과 직접입력 옆 안내에 쓴다. 행이 없으면
  --   1(=제한 없음)로 본다. submit_orient_sheet 의 기본값과 같은 값이어야 어긋남이 없다.
  SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = v_tier_prefix || 'min_slots';
  v_min_slots := COALESCE(v_min_slots, 1);

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
                              'override_krw', v_override, 'fees', '{}'::jsonb,
                              'slots', v_slots, 'min_slots', v_min_slots,
                              'names', v_names, 'options', v_options);
  END IF;

  -- 열쇠말 앞머리(모집비·진행비, 461·463 무변경) — 443 의 v_fee_key 와 같은 조립. 이미 형식이
  --   reviewer|seeding 로 확정됐으므로(위 v_tier_prefix 가드) 여기서 NULL 이 될 일은 없지만
  --   방어적으로 남겨 둔다.
  v_prefix := CASE v_ft
    WHEN 'reviewer' THEN 'reviewer_recruit_fee_krw_'
    WHEN 'seeding'  THEN 'seeding_fee_krw_' || COALESCE(v_ch, '') || '_'
    ELSE NULL END;
  IF v_prefix IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_form_type');
  END IF;

  -- [459] 구간 단가 — tmin 을 포함해 다섯(직접입력한 인원이 tmin 구간에 들면 그 단가를 보여줘야
  --   한다). 행이 없는 구간은 키 자체가 빠진다(화면은 그 자리에 금액을 안 그린다 — 0원으로 그리지 않는다).
  SELECT COALESCE(jsonb_object_agg(t.tier, q.amount), '{}'::jsonb)
    INTO v_fees
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = v_prefix || t.tier;

  RETURN jsonb_build_object('success', true, 'form_type', v_ft, 'channel', v_ch,
                            'override_krw', NULL, 'fees', v_fees,
                            'slots', v_slots, 'min_slots', v_min_slots,
                            'names', v_names, 'options', v_options);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[463, 베이스 461] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식(reviewer|seeding)을 먼저 정하고(모르면 '
  'unknown_form_type), 그 형식의 구간 단가 다섯(tmin·t50·t100·t300·t500plus, 461 이전과 같은 표) + 구간 경계 '
  '(시작값) 넷(slots — 그 형식의 reviewer_tier_slots_*·seeding_tier_slots_*, tmin 없음) + 최소 인원(min_slots, '
  '그 형식의 값, 행 없으면 1) + [463] 구간 이름 다섯(names, quote_tier_labels)·옵션 문구 다섯(options, 비어 '
  '있을 수 있음)을 돌려준다. 두 반환 경로(모집비 직접 지정·일반) 모두 names·options 를 싣는다. 발급 때 모집비를 '
  '직접 지정한 시트는 override_krw 하나 + 빈 fees(slots·min_slots·names·options 는 그대로 준다). 읽기 전용. '
  'anon GRANT(preview_orient_quote 가 이미 basis 전체를 주므로 새 노출 없음). 🔴 다음 재정의의 베이스는 463.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (개발 DB 적용 후 — 462 를 먼저 적용한 뒤. 사양서 §4 V1·V2·V4·V10 과 대응)
-- ══════════════════════════════════════════════════════════════════════
/*
-- [V1] ①(462)만 적용된 상태에서 계산된 옛 리뷰어 700명 「모집비」 줄 이름과, ② 적용 뒤 같은
--   계산의 줄 이름을 비교 — 462 시드 값이 기본 이름과 같으므로 t500plus 미만 구간(예: 40명)은
--   문구가 그대로다. t500plus 구간(500명 이상)만 "500건" → "프리미엄+" 로 바뀐다(사양서 V1·V2).
SELECT (l ->> 'label') FROM jsonb_array_elements(
  (public._orient_compute_quote(
     '{"issued":{"form_type":"reviewer","channel":null},
       "cards":[{"product":{"slots":"700"},"sale":{"price_regular":"3429"}}]}'::jsonb,
     'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines')
) l WHERE l ->> 'key' = 'recruit';
-- 기대: '모집비 (프리미엄+)' (462 이전에는 '모집비 (500건)' — 460 적용 시점 리뷰어 t500plus 시작 인원이 500 인 경우)

-- [V2] 스냅샷에 tier_name 이 실리는가 + 실검작업 줄이 여전히 붙는가
SELECT (public._orient_compute_quote(
     '{"issued":{"form_type":"reviewer","channel":null},
       "cards":[{"product":{"slots":"700"},"sale":{"price_regular":"3429"}}]}'::jsonb,
     'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote') ->> 'tier_name';
-- 기대: 프리미엄+
SELECT jsonb_array_length(
  (SELECT jsonb_agg(l) FROM jsonb_array_elements(
     (public._orient_compute_quote(
        '{"issued":{"form_type":"reviewer","channel":null},
          "cards":[{"product":{"slots":"700"},"sale":{"price_regular":"3429"}}]}'::jsonb,
        'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines')
   ) l WHERE l ->> 'key' = 'realtime_search')
);
-- 기대: 1 (실검작업 줄이 그대로 붙는다)

-- [V4] 관리자가 시딩 t100 이름을 「베이직」으로 바꾼 뒤, 같은 구간 시딩 견적 줄 이름이 즉시 반영되는가
SELECT public.update_quote_tier_label('seeding', 't100', '베이직', '');
SELECT (l ->> 'label') FROM jsonb_array_elements(
  (public._orient_compute_quote(
     '{"issued":{"form_type":"seeding","channel":"instagram_feed"},
       "cards":[{"product":{"slots":"200"}}]}'::jsonb,
     'B0002-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines')
) l WHERE l ->> 'key' = 'seeding';
-- 기대: '시딩 진행비 — 인스타그램-피드 (베이직)' 포함. 리뷰어 t100 은 '스탠다드' 그대로(형식별 독립)
-- 원복: SELECT public.update_quote_tier_label('seeding', 't100', '스탠다드', '');

-- [V10] ①(462) 없이 ②(이 파일) 단독 적용 — 새 개발 DB 등에서 순서를 안 지켰을 때 재현
--   (실제로 재현하려면 quote_tier_labels 를 임시로 지워야 하므로, 통상 검증은 위 [0] 가드
--   문구가 실제 적용 실패 로그에 남는지 확인하는 것으로 갈음한다.)

-- [V5·V6은 사양서 §4] 🔴 브라우저로 눈으로 볼 것 — get_orient_tier_fees 의 names·options 가 폼
--   단추에 실제로 반영되는지는 SQL 로 재현되지 않는다(작성 폼은 main 세션이 §3-5 대로 별도 구현).
SELECT public.get_orient_tier_fees('<새 구조 시트 토큰>'::uuid) -> 'names';
SELECT public.get_orient_tier_fees('<새 구조 시트 토큰>'::uuid) -> 'options';
-- 기대: 다섯 키 모두 채워짐. options 는 t500plus 만 '+실검작업', 나머지 ''
*/

-- ============================================================
-- 되돌리기 — 아래 순서로 그대로 실행 (🔴 462 보다 먼저 이 파일을 되돌릴 것)
-- ============================================================
/*
BEGIN;

-- ① _orient_compute_quote 를 461 판으로 되돌린다 — 461_orient_tier_slots_per_form_functions.sql
--    파일의 [2] _orient_compute_quote CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.

-- ② get_orient_tier_fees 를 461 판으로 되돌린다 — 같은 파일의 [3] get_orient_tier_fees
--    CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ③ 462 가 만든 표(quote_tier_labels·quote_tier_labels_history)는 이 파일이 손대지 않는다 —
--    지우려면 462 의 되돌리기를 이어서 실행할 것.
*/
