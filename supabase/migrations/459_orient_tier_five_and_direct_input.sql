-- ============================================================
-- 459_orient_tier_five_and_direct_input.sql
-- 2026-09-21 — 오리엔시트 구간 다섯 + 모집 인원 직접입력 · 마이그레이션 ②(값 변경 + 함수 재정의)
--   사양서 docs/specs/2026-09-21-orient-tier-direct-input.md
--   §3-2(판정식) · §3-3(최소 인원) · §3-5(단가 조회) · §3-7(라벨 뒤집기) · §3-8(순서 고정)
--   베이스: 458_quote_settings_tmin_rows.sql(이 파일이 반드시 먼저 — tmin 7행을 이 파일이 읽는다)
--
-- 🔴 458 이 반드시 먼저다. 458 없이 이 파일만 넣으면 fee_missing 은 안 나지만(tier_min_slots·
--   tmin 단가 행이 없어도 COALESCE·행부재 처리로 죽지는 않는다) tmin 구간 단가가 전부 안 잡혀
--   fee_missing 으로 조용히 막힌다 — 458 을 반드시 먼저 적용할 것.
--
-- 이 파일이 하는 일 — 값 변경 4종 + 함수 재정의 4개
--   [A] tier_slots_t100 값 100 → 150 (UPDATE)
--   [B] 라벨 뒤집기 — 기존 tier_slots_t50·t100·t300·t500plus 4행의 label_ko
--       (뜻이 "위 경계(이하)"에서 "그 구간의 시작값(이상)"으로 바뀐다 — §3-2)
--   [C] quote_settings.unit 컬럼 COMMENT — "경계값" → "시작값"
--   [D] 458 이 만든 tmin 단가 6행(리뷰어 1 + 시딩 5)의 label_ko —
--       최소 인원과 같아지면 이 행이 안 쓰일 수 있다는 관계를 드러낸다(§3-7 코디네이터 지시 ③)
--   [E] `_orient_compute_quote`(베이스 454) — 구간 판정을 5갈래로, tmin 을 새로 읽는다
--   [F] `get_orient_tier_fees`(베이스 454) — 구간 단가 5개(+tmin) + 최소 인원을 함께 돌려준다
--   [G] `update_quote_setting`(베이스 454) — 오름차순 검사에 tier_min_slots 를 추가
--   [H] `submit_orient_sheet`(베이스 446) — 제출만 최소 인원 미만이면 거부(slots_below_min)
--
-- 🔴 [A]를 이 파일에 두는 이유 — 458(행 추가만)에 두지 않는 것이 이 두 파일 분리의 핵심이다.
--   458 만 적용된 상태에서 tier_slots_t100 을 150 으로 바꾸면, **아직 4갈래인 옛 판정식**이
--   그 값을 그대로 읽어 `v_slots <= tier_slots_t100(150) → t100` 이 되어 101~150명의 단가가
--   조용히 7,000 → 7,500 으로 바뀐다(옛 판정식은 tmin 을 모르므로 49명 이하도 t50 인 채다 —
--   즉 458 만으로는 tmin 도 안 잡히고 t100 값만 위험하게 앞당겨진다). [A]와 [E]는 반드시
--   같은 트랜잭션(이 파일)에서 함께 들어가야 한다 — 458_quote_settings_tmin_rows.sql 머리말과
--   사양서 §3-8 이 명시한 순서.
--
-- ------------------------------------------------------------
-- [E] 판정식 — 무엇이 바뀌고 무엇이 안 바뀌는가 (사양서 §3-2 대조표)
-- ------------------------------------------------------------
--   지금(454):  v_slots <= tier_slots_t50 → t50 / <= tier_slots_t100 → t100 /
--               v_slots <  tier_slots_t500plus → t300 / 그 밖 → t500plus
--               (tier_slots_t300 은 안 쓰인다 — 단추 인원 표시용일 뿐)
--   이 파일:    v_slots <  tier_slots_t50(시작값)       → tmin
--               v_slots <  tier_slots_t100(시작값)      → t50
--               v_slots <  tier_slots_t300(시작값)      → t100
--               v_slots <  tier_slots_t500plus(시작값)  → t300
--               그 밖                                    → t500plus
--   🔴 넷이 한꺼번에 뒤집히는 게 아니다 — 갈래는 셋이다:
--     · tier_slots_t50 을 쓰는 줄  — 부호(<=→<)와 뜻(위 경계→시작값) 둘 다 바뀐다
--     · tier_slots_t100 을 쓰는 줄 — 부호(<=→<)와 뜻(위 경계→시작값) 둘 다 바뀐다
--     · tier_slots_t300 을 쓰는 줄 — **새로 쓰이기 시작한다**(지금은 안 쓰임)
--     · tier_slots_t500plus 을 쓰는 줄 — ✅ 한 글자도 안 바뀐다(지금도 "< 그 값 → t300, 그 밖 → t500plus")
--   기준값 행이 하나라도(넷 중) 없으면 지금처럼 fee_missing 으로 닫는다 — 이제 t300 도 필수라
--   **셋에서 넷으로** 늘었다(458 이 만든 tmin 관련 행 유무는 이 검사와 무관 — tmin 은 경계가
--   아니라 v_slots < tier_slots_t50 일 때 도달하는 "결과"일 뿐이다).
--
-- ------------------------------------------------------------
-- [H] 최소 인원 — 제출에서만 막는다(§3-3)
-- ------------------------------------------------------------
--   `preview_orient_quote`(430)는 이 파일에서 손대지 않는다 — 저장하지 않는 자리라 서버가
--   막을 이유가 없고, 구간 계산은 [E]에 위임해 자동으로 5갈래를 따른다.
--   `submit_orient_sheet` 에서만 v_slots(카드0 의 product.slots, 숫자만 걸러낸 값)를 다시 읽어
--   tier_min_slots 와 비교한다 — 값을 못 읽었으면(빈 문자열) 이 검사를 건너뛴다(그 경우는
--   견적 계산이 slots_missing 으로 이미 막는다). 임시저장(save_orient_draft)에는 걸지 않는다.
--
-- 🔴 셋 다 CREATE OR REPLACE 로 충분하다(인자 목록 전부 불변) — 저장소 관례대로 REVOKE 를
--   다시 건다(대상이 없어도 무해).
--
-- 롤백: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행(454·446 함수 본문 + [A]~[D] 값을 복구).
-- ============================================================
BEGIN;

-- ================================================================
-- [A] tier_slots_t100 값 변경 — 100 → 150
--   🔴 이 UPDATE 는 반드시 [E](판정식 재정의) 와 같은 트랜잭션에서 커밋된다(둘 다 이 파일 안).
-- ================================================================
UPDATE public.quote_settings SET amount = 150 WHERE key = 'tier_slots_t100';

-- ================================================================
-- [B] 라벨 뒤집기 — 구간 인원 4행. 뜻이 "위 경계(이하)"에서 "시작값(이상)"으로 바뀐다.
--   🔴 453 의 시드 문장은 건드리지 않는다(이미 적용된 파일) — 여기는 UPDATE 뿐이다.
-- ================================================================
UPDATE public.quote_settings
   SET label_ko = '구간 인원 — 라이트 시작 인원 (이 값부터 라이트 구간)'
 WHERE key = 'tier_slots_t50';
UPDATE public.quote_settings
   SET label_ko = '구간 인원 — 스탠다드 시작 인원 (이 값부터 스탠다드 구간)'
 WHERE key = 'tier_slots_t100';
UPDATE public.quote_settings
   SET label_ko = '구간 인원 — 프리미엄 시작 인원 (이 값부터 프리미엄 구간)'
 WHERE key = 'tier_slots_t300';
UPDATE public.quote_settings
   SET label_ko = '구간 인원 — 실검작업 구간 시작 인원 (이 값 이상이면 실검작업 구간)'
 WHERE key = 'tier_slots_t500plus';

-- ================================================================
-- [C] unit 컬럼 COMMENT — "경계값" → "시작값"
-- ================================================================
COMMENT ON COLUMN public.quote_settings.unit IS
  '[459, 베이스 453] krw=원 금액 · jpy=엔 금액 · rate=비율(0.10 = 10%) · count=인원(구간 시작값, 금액 아님).';

-- ================================================================
-- [D] 458 이 만든 tmin 단가 6행 — 최소 인원과의 관계를 드러낸다
--   최소 인원(tier_min_slots)이 라이트 시작 인원(tier_slots_t50)과 같아지면 이 구간에 도달할
--   인원이 없어 이 행이 안 쓰이는 값이 된다(§3-3) — 그 사정을 라벨에 적어 둔다.
-- ================================================================
UPDATE public.quote_settings
   SET label_ko = '모집비 — 소량 (최소 인원=라이트 시작 인원이면 이 행은 쓰이지 않음)'
 WHERE key = 'reviewer_recruit_fee_krw_tmin';
UPDATE public.quote_settings
   SET label_ko = '진행비 — 인스타그램-피드 (소량 · 최소 인원=라이트 시작 인원이면 미사용)'
 WHERE key = 'seeding_fee_krw_instagram_feed_tmin';
UPDATE public.quote_settings
   SET label_ko = '진행비 — 인스타그램-릴스 (소량 · 최소 인원=라이트 시작 인원이면 미사용)'
 WHERE key = 'seeding_fee_krw_instagram_reels_tmin';
UPDATE public.quote_settings
   SET label_ko = '진행비 — X (소량 · 최소 인원=라이트 시작 인원이면 미사용)'
 WHERE key = 'seeding_fee_krw_x_tmin';
UPDATE public.quote_settings
   SET label_ko = '진행비 — 틱톡 (소량 · 최소 인원=라이트 시작 인원이면 미사용)'
 WHERE key = 'seeding_fee_krw_tiktok_tmin';
UPDATE public.quote_settings
   SET label_ko = '진행비 — 유튜브 (소량 · 최소 인원=라이트 시작 인원이면 미사용)'
 WHERE key = 'seeding_fee_krw_youtube_tmin';

-- ================================================================
-- [E] _orient_compute_quote — 베이스 454, 구간 판정을 5갈래로(tmin 추가)
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
  v_tier_label    text;        -- [443→448→459] 소량 · 라이트 · 스탠다드 · 프리미엄 · 500건
  v_fee_key       text;        -- [443] 읽을 기준값 열쇠말
  v_override      numeric;     -- [443] issued.recruit_fee_krw (없으면 NULL)
  v_suffix        text;        -- [443] ' · 직접 지정' 또는 ''
  v_markets       jsonb;       -- [443] sale.extra_markets
  v_opt_lips      numeric;     -- [443]
  v_opt_cosme     numeric;     -- [443]
  v_tier_t50      numeric;     -- [454] 구간 경계값(→[459] 시작값) — 기준값(quote_settings)에서 읽는다
  v_tier_t100     numeric;     -- [454→459]
  v_tier_t300     numeric;     -- [459] 🔴 454 에서는 안 쓰였으나 이 파일부터 실제 경계로 쓰인다
  v_tier_t500plus numeric;     -- [454→459]
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

  -- [459] 구간 경계값(시작값) — 기준값(quote_settings)에서 읽는다. 넷(t50·t100·t300·t500plus)
  --   중 하나라도 행이 없으면 fee_missing 으로 닫는다. 🔴 454 에서는 t300 이 검사 대상이 아니었으나
  --   이 파일부터 t300 도 실제 경계로 쓰이므로 넷 다 필수가 됐다(사양서 §3-2).
  IF v_slots IS NOT NULL AND v_slots > 0 THEN
    IF v_basis ? 'tier_slots_t50' AND v_basis ? 'tier_slots_t100'
       AND v_basis ? 'tier_slots_t300' AND v_basis ? 'tier_slots_t500plus' THEN
      v_tier_t50      := (v_basis ->> 'tier_slots_t50')::numeric;
      v_tier_t100     := (v_basis ->> 'tier_slots_t100')::numeric;
      v_tier_t300     := (v_basis ->> 'tier_slots_t300')::numeric;
      v_tier_t500plus := (v_basis ->> 'tier_slots_t500plus')::numeric;
    ELSE
      v_quote_error := 'fee_missing';
    END IF;
  END IF;

  -- [443→454→459] 서버 구간 판정 — 화면이 보낸 slots_tier 를 믿지 않는다. 기준값을 못 읽었으면
  --   (위에서 fee_missing 이 이미 세워졌으면) v_tier 는 NULL 로 둔다 — 아래 reviewer/seeding 분기가
  --   NULL 티어를 자연히 fee_missing 으로 다시 수렴시킨다(파일 머리말 [설계 메모] 참고).
  --   🔴 경계 넷 전부 "그 구간의 시작값" — 이제 놀고 있는 값이 없다(사양서 §3-2 대조표).
  v_tier := CASE
    WHEN v_quote_error IS NOT NULL THEN NULL
    WHEN v_slots IS NULL      THEN NULL
    WHEN v_slots <  v_tier_t50        THEN 'tmin'
    WHEN v_slots <  v_tier_t100       THEN 't50'
    WHEN v_slots <  v_tier_t300       THEN 't100'
    WHEN v_slots <  v_tier_t500plus   THEN 't300'
    ELSE 't500plus' END;
  v_tier_label := CASE v_tier
    WHEN 'tmin'      THEN '소량'          -- [459] 최소 인원 ~ 라이트 시작 인원 미만(직접입력 전용, 단추 없음)
    WHEN 't50'       THEN '라이트'
    WHEN 't100'      THEN '스탠다드'
    WHEN 't300'      THEN '프리미엄'
    WHEN 't500plus'  THEN '500건'          -- [448] 다섯 번째(맨 끝) 구간은 「500건」 고정. 🔴 판정 경계(그 값 이상)는 그대로
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 454 와 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[459, 베이스 454] 오리엔시트 견적 계산 본문 — 구간 경계(t50·t100·t300·t500plus, 전부 "그 구간의 시작값") '
  '넷을 기준값(quote_settings.tier_slots_*)에서 읽어 5갈래(tmin·t50·t100·t300·t500plus)로 판정한다 '
  '(458 이 없는 행을 만들면 fee_missing). 구간별 모집비·시딩 진행비(tmin 포함), 발급 예외(issued.recruit_fee_krw → '
  '줄 이름에 「· 직접 지정」), 리뷰어 추가 옵션(LIPS·@cosme), 500건 이상이면 형식과 무관하게 「실검작업 — 담당자 협의」 '
  '(값 없음·합계 제외), 기준값 행이 없으면 fee_missing. 페이백 줄 이름 「판매가」. '
  'submit_orient_sheet·preview_orient_quote 가 공용(preview 는 최소 인원 검사를 안 받는다 — 그건 submit 몫). '
  '실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 459.';

-- ================================================================
-- [F] get_orient_tier_fees — 베이스 454, 구간 단가 5개(+tmin) + 최소 인원을 함께 준다
-- ================================================================
CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet      record;
  v_issued     jsonb;
  v_ft         text;
  v_ch         text;
  v_prefix     text;
  v_override   numeric;
  v_fees       jsonb;
  v_slots      jsonb;     -- 구간 경계(시작값) 넷 — {"t50":50,"t100":150,"t300":300,"t500plus":500}
  v_min_slots  numeric;   -- [459] 최소 인원 — 행이 없으면 1(아무도 안 막는다)
  v_now        timestamptz := now();
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

  -- 구간 경계(시작값) 넷 — 형식·채널과 무관하게 항상 같은 값(override 여부와도 무관, 아래 두 RETURN
  --   경로 모두에서 쓴다). 행이 없는 구간은 키 자체가 빠진다(폼은 그 구간에 기본값을 그대로 쓴다).
  --   🔴 [459] 이 배열은 안 늘린다 — tier_slots_tmin 행이 없기 때문이다(최하단 구간의 시작값은
  --   tier_min_slots 이 대신한다. 사양서 §3-6). tmin 을 여기 넣으면 없는 행을 찾아 조용히 빠질 뿐이라
  --   틀린 것은 아니지만, 존재하지 않는 개념(tier_slots_tmin)을 굳이 흉내 낼 이유가 없다.
  SELECT COALESCE(jsonb_object_agg(t.tier, (q.amount)::integer), '{}'::jsonb)
    INTO v_slots
    FROM unnest(ARRAY['t50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = 'tier_slots_' || t.tier;

  -- [459] 최소 인원 — 화면이 입력칸 min 과 직접입력 옆 안내에 쓴다. 행이 없으면 1(=제한 없음)로 본다.
  --   submit_orient_sheet 의 기본값과 같은 값이어야 「화면은 통과시켰는데 서버가 막는」 어긋남이 없다.
  SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = 'tier_min_slots';
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
                              'slots', v_slots, 'min_slots', v_min_slots);
  END IF;

  -- 열쇠말 앞머리 — 443 의 v_fee_key 와 같은 조립
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
                            'slots', v_slots, 'min_slots', v_min_slots);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[459, 베이스 454] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식·채널에 해당하는 구간 단가 다섯 '
  '(tmin·t50·t100·t300·t500plus) + 구간 경계(시작값) 넷(slots, tmin 없음 — tier_slots_tmin 행이 없으므로) + '
  '최소 인원(min_slots, 행 없으면 1)을 돌려준다. 발급 때 모집비를 직접 지정한 시트는 override_krw 하나 + '
  '빈 fees(slots·min_slots 는 그대로 준다). 읽기 전용. anon GRANT(preview_orient_quote 가 이미 basis 전체를 주므로 새 노출 없음).';

-- ================================================================
-- [G] update_quote_setting — 베이스 454, 오름차순 검사에 tier_min_slots 추가
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
  v_min    numeric;   -- [459] 최소 인원 — tier_min_slots <= t50 (등호 허용, 나머지는 엄격 오름차순)
  v_t50    numeric;   -- 오름차순 검사용 — 구간 인원 값들(지금 고치는 키는 p_amount 로 덮는다)
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

  -- [459] 최소 인원 + 구간 인원 4행 — 함께 오름차순 검사(사양서 §3-3): 최소 인원은 라이트
  --   시작 인원과 같아도 되지만(<=, 그 경우 tmin 구간에 아무도 도달하지 못해 저절로 잠긴다),
  --   구간 인원 넷은 여전히 엄격 오름차순이어야 한다(같은 값도 거부 — 454 의 규칙 그대로).
  IF p_key IN ('tier_min_slots', 'tier_slots_t50', 'tier_slots_t100', 'tier_slots_t300', 'tier_slots_t500plus') THEN
    SELECT amount INTO v_min  FROM public.quote_settings WHERE key = 'tier_min_slots';
    SELECT amount INTO v_t50  FROM public.quote_settings WHERE key = 'tier_slots_t50';
    SELECT amount INTO v_t100 FROM public.quote_settings WHERE key = 'tier_slots_t100';
    SELECT amount INTO v_t300 FROM public.quote_settings WHERE key = 'tier_slots_t300';
    SELECT amount INTO v_t500 FROM public.quote_settings WHERE key = 'tier_slots_t500plus';
    -- 지금 저장하려는 값으로 그 자리만 덮어써서 판정(한 번에 한 값만 바뀐다)
    IF p_key = 'tier_min_slots'      THEN v_min  := p_amount; END IF;
    IF p_key = 'tier_slots_t50'      THEN v_t50  := p_amount; END IF;
    IF p_key = 'tier_slots_t100'     THEN v_t100 := p_amount; END IF;
    IF p_key = 'tier_slots_t300'     THEN v_t300 := p_amount; END IF;
    IF p_key = 'tier_slots_t500plus' THEN v_t500 := p_amount; END IF;

    IF v_min IS NULL OR v_t50 IS NULL OR v_t100 IS NULL OR v_t300 IS NULL OR v_t500 IS NULL
       OR NOT (v_min <= v_t50 AND v_t50 < v_t100 AND v_t100 < v_t300 AND v_t300 < v_t500) THEN
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
  '[459, 베이스 454] 견적 기준값 수정 — 캠페인 관리자 이상(is_campaign_admin). 값이 같아도 이력 1행. 거부 reason: '
  'forbidden·invalid_amount·unknown_key·tier_slots_not_ascending(tier_min_slots + 구간 인원 4행, '
  'tier_min_slots<=tier_slots_t50<tier_slots_t100<tier_slots_t300<tier_slots_t500plus 아니면 거부 — 최소 인원만 등호 허용). '
  '비율(unit=rate)은 0~1 만 허용.';

-- ================================================================
-- [H] submit_orient_sheet — 베이스 446, 제출만 최소 인원 거부(slots_below_min) 추가
--   🔴 430 과 [446]의 diff 확인 관례를 이어, 이 파일도 446 과 무엇이 다른지 아래 "만드는 법"에 남긴다.
-- ================================================================
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
  -- [459] 최소 인원 — 제출만 막는다(§3-3)
  v_slots_txt    text;
  v_slots_chk    integer;
  v_min_slots    numeric;
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

      -- [459] 최소 인원 — 인원을 안 넣었으면(빈 문자열) 건너뛴다(그 경우는 아래 견적 계산이
      --   slots_missing 으로 이미 막는다). 행이 없으면 1 로 본다(=아무도 안 막는다,
      --   get_orient_tier_fees 의 기본값과 같은 값 — 화면·서버가 같은 폴백을 쓴다).
      --   🔴 임시저장(save_orient_draft)에는 이 검사를 걸지 않는다 — 자동저장 보호(429 와 같은 원칙).
      v_slots_txt := regexp_replace(COALESCE(v_card0 -> 'product' ->> 'slots', ''), '[^0-9]', '', 'g');
      IF v_slots_txt <> '' THEN
        v_slots_chk := LEAST(v_slots_txt::numeric, 999999)::integer;
        SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = 'tier_min_slots';
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
  --   본문은 _orient_compute_quote(현재 원본 459) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
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
    'quote_error',         v_quote_error    -- [427] 실패 사유(price_unreadable·slots_missing), 아니면 NULL. 🔴 slots_below_min 은
                                             --   이 칸이 아니라 이 함수의 별도 조기 RETURN(reason='slots_below_min')으로 나간다 — 여기 도달했다는 건 그 검사를 이미 통과했다는 뜻
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329·425·430·446 과 같은 관례)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446, 459 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429) → '
  '[459] 최소 인원(tier_min_slots) 미만이면 slots_below_min 거부(임시저장은 검사 안 함, 값 못 읽으면 건너뜀) → '
  '[446] 고정 안내 확인(notice_ack 도 없고 notice_ack_checked 도 참이 아니면 notice_not_acknowledged 거부, 통과하면 notice_ack={version,at 서버시각,form_type} 최초 1회 기록) → '
  '[427·430] 견적 계산(_orient_compute_quote 공용 — 현재 원본 459). 세트 규칙: 제출마다 quote 또는 quote_error 하나만. 견적 실패도 제출은 통과. '
  '옛 시트는 어느 검사도 받지 않는다. 🔴 다음 재정의의 베이스는 459.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 만드는 법 — 446 과 무엇이 다른지 확인
-- ══════════════════════════════════════════════════════════════════════
--   diff <(awk '/CREATE OR REPLACE FUNCTION public\.submit_orient_sheet/,/^\$\$;/' supabase/migrations/446_orient_submit_notice_ack.sql) \
--        <(awk '/CREATE OR REPLACE FUNCTION public\.submit_orient_sheet/,/^\$\$;/' supabase/migrations/459_orient_tier_five_and_direct_input.sql)
--   → 변수 선언 3줄([459]) + 최소 인원 검사 블록 하나만 나와야 한다(그 밖 1글자도 다르면 잘못 옮긴 것).

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (개발 DB 적용 후 — 458 을 먼저 적용한 뒤. 최소 인원 기본값 1 기준)
-- ══════════════════════════════════════════════════════════════════════
/*
-- [V1] ①·② 적용 후 — 최소 인원 1행·리뷰어 모집비 5행(tmin 포함)·시딩 진행비 25행(tmin 포함), tier_slots_t100 이 150
SELECT count(*) FROM public.quote_settings WHERE key = 'tier_min_slots';                 -- 기대: 1
SELECT count(*) FROM public.quote_settings WHERE key LIKE 'reviewer_recruit_fee_krw_%';  -- 기대: 5 (원래 4 + tmin 1. lips·cosme 는 다른 접두라 안 걸림)
SELECT count(*) FROM public.quote_settings WHERE key LIKE 'seeding_fee_krw_%';           -- 기대: 25 (원래 20 + tmin 5)
SELECT amount FROM public.quote_settings WHERE key = 'tier_slots_t100';                  -- 기대: 150

-- [V2] 🔴 경계 여덟 자리(최소 인원 1 인 상태) — 사양서 §3-2 대조표와 전부 일치해야 한다
SELECT s AS slots,
       (public._orient_compute_quote(
          jsonb_build_object('issued', jsonb_build_object('form_type','reviewer','channel',NULL),
                             'cards', jsonb_build_array(jsonb_build_object(
                               'product', jsonb_build_object('slots', s::text),
                               'sale',    jsonb_build_object('price_regular','3429')))),
          'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier') AS tier
  FROM unnest(ARRAY[49,50,149,150,299,300,499,500]) s;
-- 기대: tmin · t50 · t50 · t100 · t100 · t300 · t300 · t500plus

-- [V3] 단추 넷 — 단가가 지금과 같은가(8000·7500·7000·6500)
SELECT s AS slots, l ->> 'unit_krw' AS recruit_unit_krw
  FROM unnest(ARRAY[50,150,300,500]) s
  CROSS JOIN LATERAL jsonb_array_elements(
    (public._orient_compute_quote(
       jsonb_build_object('issued', jsonb_build_object('form_type','reviewer','channel',NULL),
                          'cards', jsonb_build_array(jsonb_build_object(
                            'product', jsonb_build_object('slots', s::text),
                            'sale',    jsonb_build_object('price_regular','3429')))),
       'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines')
  ) AS l
 WHERE l ->> 'key' = 'recruit';
-- 기대: 8000 · 7500 · 7000 · 6500 (인원 50·150·300·500 순 — 단추 넷의 값이 지금과 같아야 한다)

-- [V4] fee_missing — 새로 필수가 된 tier_slots_t300 행을 지우면
BEGIN;
DELETE FROM public.quote_settings WHERE key = 'tier_slots_t300';
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"200"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) ->> 'quote_error';
-- 기대: fee_missing (454 였으면 통과했을 값 — t300 이 이제 필수임을 증명)
ROLLBACK;

-- [V5] get_orient_tier_fees — min_slots·tmin 단가가 오는가(실제 새 구조 시트 토큰으로)
--   SELECT public.get_orient_tier_fees('<새 구조 시트 토큰>'::uuid);
--   기대: min_slots:1, fees 에 tmin 키 포함(예: {"tmin":8500,"t50":8000,"t100":7500,"t300":7000,"t500plus":6500})
--         slots 는 여전히 4개뿐(tmin 없음): {"t50":50,"t100":150,"t300":300,"t500plus":500}

-- [V6] 오름차순 — 최소 인원을 60(t50=50보다 큼)으로 저장하면 거부
SELECT public.update_quote_setting('tier_min_slots', 60);
-- 기대: {"success":false,"reason":"tier_slots_not_ascending"}

-- [V7] 오름차순 — 최소 인원을 50(t50 과 같음)으로 저장하면 통과(등호 허용)
SELECT public.update_quote_setting('tier_min_slots', 50);
-- 기대: {"success":true,...} — 확인 후 원복: SELECT public.update_quote_setting('tier_min_slots', 1);

-- [V8] submit_orient_sheet — 최소 인원 50(위 [V7]로 저장한 값)일 때 30명 제출 → slots_below_min
--   (DO 블록으로 감싸 일부러 되돌린다 — 446 파일의 검증 패턴과 동일, <토큰>에 새 구조 시트 토큰)
--   DO $v$
--   DECLARE t uuid := '<토큰>'; ver int; r jsonb; d jsonb;
--   BEGIN
--     UPDATE public.quote_settings SET amount = 50 WHERE key = 'tier_min_slots';
--     SELECT version, data INTO ver, d FROM public.orient_sheets WHERE token = t;
--     d := jsonb_set(d, '{cards,0,product,slots}', '"30"');
--     r := public.submit_orient_sheet(t, d, ver);
--     RAISE NOTICE '[V8-a] %', r;   -- 기대: reason = slots_below_min, min_slots = 50
--     d := jsonb_set(d, '{cards,0,product,slots}', '"50"');
--     r := public.submit_orient_sheet(t, d, ver);
--     RAISE NOTICE '[V8-b] %', r;   -- 기대: success = true (50 은 50 이상이라 통과)
--     RAISE EXCEPTION '검증 끝 — 일부러 되돌린다';
--   END $v$;

-- [V9] 지난 견적(스냅샷)은 안 변하는가 — data->'quote' 는 제출 시점 스냅샷이라 이 마이그레이션이 UPDATE 하지 않는다
--   (458 이전에 이미 제출된 시트가 있으면 SELECT data->'quote' FROM orient_sheets WHERE token='<토큰>' 으로 적용 전후 비교)
*/

-- ============================================================
-- 되돌리기 — 아래 순서로 그대로 실행
--   ① 함수 넷을 454·446 판으로 되돌린다(각 파일의 함수 블록을 그대로 재실행)
--   ② [A]~[D] 값을 되돌린다(아래)
--   🔴 이 파일을 되돌린 뒤에도 458 이 만든 7행은 남는다 — 지우려면 458 의 되돌리기도 함께.
-- ============================================================
/*
BEGIN;

-- ① [A] tier_slots_t100 원복
UPDATE public.quote_settings SET amount = 100 WHERE key = 'tier_slots_t100';

-- ② [B] 라벨 원복 (453 판)
UPDATE public.quote_settings SET label_ko = '구간 인원 — 라이트'       WHERE key = 'tier_slots_t50';
UPDATE public.quote_settings SET label_ko = '구간 인원 — 스탠다드'     WHERE key = 'tier_slots_t100';
UPDATE public.quote_settings SET label_ko = '구간 인원 — 프리미엄'     WHERE key = 'tier_slots_t300';
UPDATE public.quote_settings SET label_ko = '구간 인원 — 실검작업 구간' WHERE key = 'tier_slots_t500plus';

-- ③ [C] unit COMMENT 원복 (453 판)
COMMENT ON COLUMN public.quote_settings.unit IS
  '[453, 베이스 426] krw=원 금액 · jpy=엔 금액 · rate=비율(0.10 = 10%) · count=인원(구간 경계값, 금액 아님).';

-- ④ [D] tmin 라벨 원복 (458 판 플레이스홀더로)
UPDATE public.quote_settings SET label_ko = '모집비 — 소량' WHERE key = 'reviewer_recruit_fee_krw_tmin';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-피드 (소량)' WHERE key = 'seeding_fee_krw_instagram_feed_tmin';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-릴스 (소량)' WHERE key = 'seeding_fee_krw_instagram_reels_tmin';
UPDATE public.quote_settings SET label_ko = '진행비 — X (소량)'              WHERE key = 'seeding_fee_krw_x_tmin';
UPDATE public.quote_settings SET label_ko = '진행비 — 틱톡 (소량)'            WHERE key = 'seeding_fee_krw_tiktok_tmin';
UPDATE public.quote_settings SET label_ko = '진행비 — 유튜브 (소량)'          WHERE key = 'seeding_fee_krw_youtube_tmin';

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ⑤ 함수 넷 되돌리기 — 아래 세 파일의 CREATE OR REPLACE FUNCTION 블록을 이 순서로 그대로 재실행
--    454_orient_tier_slots_from_settings.sql   (_orient_compute_quote · get_orient_tier_fees · update_quote_setting)
--    446_orient_submit_notice_ack.sql          (submit_orient_sheet)
*/
