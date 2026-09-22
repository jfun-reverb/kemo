-- ============================================================
-- 461_orient_tier_slots_per_form_functions.sql
-- 2026-09-21 — 오리엔시트 구간 인원을 리뷰어·시딩 따로 · 마이그레이션 ②(헬퍼 + 함수 넷 재정의 + 옛 5행 삭제)
--   사양서 docs/specs/2026-09-21-orient-tier-slots-per-form.md §3-2 · §3-3 · §3-5
--   베이스: 459_orient_tier_five_and_direct_input.sql — 🔴 이 파일의 함수 넷은 전부 459 를
--   그대로 복사한 뒤 이 헤더가 말하는 부분만 고쳤다(454·446 을 베이스로 잡지 말 것 — tmin·최소
--   인원·오름차순의 최소 인원 조건·고정 안내 확인이 통째로 사라진다).
--   반드시 460_orient_tier_slots_per_form_rows.sql 뒤에 적용할 것 — 이 파일의 첫머리 가드가 그
--   10행이 없으면 즉시 예외를 던져 스스로 확인한다(아래 [0]).
--
-- 이 파일이 하는 일 — 헬퍼 1개 + 함수 재정의 4개 + 옛 5행 삭제, 전부 한 트랜잭션
--   [0] 첫머리 가드 — 새 10행이 전부 있는가 + 형식별로 오름차순인가. 하나라도 아니면
--       RAISE EXCEPTION 으로 파일 전체를 되돌린다(§2-1 ①·② — 460 없이 이 파일만 적용되거나,
--       460 적용 후 이 파일 전에 순서가 뒤집힌 값을 저장해 둔 경우를 막는다).
--   [1] `_orient_tier_prefix(p_form_type)` — 시트 형식 → quote_settings 열쇠 앞머리
--       ('reviewer'→'reviewer_tier_' · 'seeding'→'seeding_tier_' · 그 밖 NULL). IMMUTABLE,
--       표를 안 읽는다. 실행 권한 PUBLIC·anon·authenticated 전부 회수(내부 전용 — S1·S2·S4 가
--       SECURITY DEFINER 안에서만 부른다). S3(update_quote_setting)은 시트가 없는 자리라 이
--       헬퍼를 안 쓰고 고치려는 열쇠 이름 자체를 목록 비교로 가른다(§3-3).
--   [2] `_orient_compute_quote`(베이스 459) — 구간 경계 넷(t50·t100·t300·t500plus)을 그 시트
--       형식의 열쇠(`reviewer_tier_slots_*`·`seeding_tier_slots_*`)에서 읽는다. 🔴 형식을 모르면
--       (앞머리 NULL) **경계 존재 검사보다 먼저** price_unreadable 로 닫는다 — 순서를 안 지키면
--       NULL 열쇠 조회가 빈 결과를 내 fee_missing 으로 잘못 떨어진다(459 의 형식 ELSE 분기와 같은
--       결과를 유지하기 위한 순서, 424 가 형식을 막으므로 실제로는 도달하지 않는 방어선).
--       t500plus 구간의 견적 줄 이름은 459 의 고정 문자열 '500건' 대신 **그 형식의 t500plus
--       시작 인원**으로 조립한다(예: 시딩이 400이면 '400건'). 모집비·진행비 조회(v_fee_key) —
--       `reviewer_recruit_fee_krw_*`·`seeding_fee_krw_*_*` — 는 이번에 손대지 않는다(경계 열쇠와
--       다른 표, 이미 형식별로 나뉘어 있었다).
--   [3] `get_orient_tier_fees`(베이스 459) — 🔴 459 는 구간 경계를 형식 확인보다 **먼저** 읽었다
--       (지금은 바뀔 것이 없는 공용 열쇠였으니 상관없었다). 이제 경계가 형식마다 다르므로 순서를
--       뒤집어 **형식을 먼저 정하고**(NULL 이면 unknown_form_type 으로 즉시 종료) 그 앞머리로
--       경계 넷 · 최소 인원을 읽는다. 응답 모양(`slots:{t50,t100,t300,t500plus}`·`min_slots`)은
--       한 글자도 안 바뀐다 — 작성 폼(orient.html)이 이 응답만 보고 이미 §3-6 대로 구현돼 있어
--       고칠 게 없다(이 사양서 작성 중 다른 세션이 확인).
--   [4] `update_quote_setting`(베이스 459) — 오름차순 검사를 형식별로 가른다. 고치려는 열쇠가
--       리뷰어 5개 목록에 있으면 리뷰어 5행끼리, 시딩 5개 목록에 있으면 시딩 5행끼리만 검사
--       (LIKE 금지 — 목록 비교, §3-3). 거부 코드는 `tier_slots_not_ascending` 그대로 두고 응답에
--       `form_type`('reviewer'|'seeding')을 추가한다 — 관리자 화면(admin-lookups.js)이 이미
--       그 값을 읽어 문구를 분기하도록 짜여 있다(이 사양서 작성 중 다른 세션이 확인).
--   [5] `submit_orient_sheet`(베이스 459) — 최소 인원 검사가 읽는 열쇠를
--       `v_data -> 'issued' ->> 'form_type'` 의 앞머리로 바꾼다. 형식을 못 정하거나(방어적) 그
--       형식의 최소 인원 행이 없으면 1(=아무도 안 막는다) — get_orient_tier_fees 의 기본값과
--       같은 값이어야 「화면은 통과시켰는데 서버가 막는」 어긋남이 없다.
--   [6] 옛 공용 5행(`tier_min_slots`·`tier_slots_t50/t100/t300/t500plus`) 삭제 — 🔴 함수
--       재정의(2~5)와 반드시 같은 트랜잭션. 삭제가 먼저 들어가면(다른 배포로 쪼개지면) 그 사이
--       옛 함수가 지워진 열쇠를 읽어 모든 견적이 fee_missing 이 된다. `quote_settings_history`
--       의 옛 열쇠 기록은 남긴다(외래 키가 없어 지워도 안 막히고, 누가 언제 무엇으로 바꿨는지의
--       근거이기도 하다).
--
-- 🔴 넷 다 CREATE OR REPLACE 로 충분하다(인자 목록 전부 불변) — 저장소 관례대로 REVOKE·GRANT 를
--   다시 건다(대상이 없어도 무해, 권한은 CREATE OR REPLACE 로 이미 보존된다).
--
-- 롤백: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행(459 판 함수 복구 + 옛 5행 재삽입 +
--   헬퍼 삭제). 460 이 만든 리뷰어·시딩 10행은 이 파일이 손대지 않으므로 그대로 둔다 —
--   지우려면 460 의 되돌리기도 함께 실행할 것(460 이 먼저 되돌려지면 이 파일의 되돌리기가
--   재삽입할 값의 출처[reviewer_tier_* 값 복사]가 사라진다 — 반드시 이 파일부터 되돌릴 것).
-- ============================================================

BEGIN;

-- ================================================================
-- [0] 첫머리 가드 — 새 10행 존재 + 형식별 오름차순. 하나라도 어긋나면 파일 전체를 되돌린다.
-- ================================================================
DO $guard$
DECLARE
  v_missing text[];
  v_r_min numeric; v_r_t50 numeric; v_r_t100 numeric; v_r_t300 numeric; v_r_t500 numeric;
  v_s_min numeric; v_s_t50 numeric; v_s_t100 numeric; v_s_t300 numeric; v_s_t500 numeric;
BEGIN
  -- [0-1] 460 이 없이 이 파일만 적용되는 경우(§2-1 ②) 차단
  SELECT array_agg(k) INTO v_missing
    FROM unnest(ARRAY[
      'reviewer_tier_min_slots', 'reviewer_tier_slots_t50', 'reviewer_tier_slots_t100',
      'reviewer_tier_slots_t300', 'reviewer_tier_slots_t500plus',
      'seeding_tier_min_slots', 'seeding_tier_slots_t50', 'seeding_tier_slots_t100',
      'seeding_tier_slots_t300', 'seeding_tier_slots_t500plus'
    ]) AS k
   WHERE NOT EXISTS (SELECT 1 FROM public.quote_settings q WHERE q.key = k);
  IF v_missing IS NOT NULL AND array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION '[461] 새 10행이 없습니다 — 460_orient_tier_slots_per_form_rows.sql 을 먼저 적용할 것. 없는 열쇠: %', v_missing;
  END IF;

  -- [0-2] 460 적용 뒤 이 파일 전에 누가 순서를 뒤집어 저장해 둔 경우 차단(§2-1 ①)
  --   🔴 최소 인원만 등호 허용, 나머지는 엄격 오름차순 — 459 의 규칙 그대로.
  SELECT amount INTO v_r_min  FROM public.quote_settings WHERE key = 'reviewer_tier_min_slots';
  SELECT amount INTO v_r_t50  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t50';
  SELECT amount INTO v_r_t100 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t100';
  SELECT amount INTO v_r_t300 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t300';
  SELECT amount INTO v_r_t500 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t500plus';
  IF NOT (v_r_min <= v_r_t50 AND v_r_t50 < v_r_t100 AND v_r_t100 < v_r_t300 AND v_r_t300 < v_r_t500) THEN
    RAISE EXCEPTION '[461] 리뷰어 구간 인원이 오름차순이 아닙니다 (min=%, t50=%, t100=%, t300=%, t500plus=%)',
      v_r_min, v_r_t50, v_r_t100, v_r_t300, v_r_t500;
  END IF;

  SELECT amount INTO v_s_min  FROM public.quote_settings WHERE key = 'seeding_tier_min_slots';
  SELECT amount INTO v_s_t50  FROM public.quote_settings WHERE key = 'seeding_tier_slots_t50';
  SELECT amount INTO v_s_t100 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t100';
  SELECT amount INTO v_s_t300 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t300';
  SELECT amount INTO v_s_t500 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t500plus';
  IF NOT (v_s_min <= v_s_t50 AND v_s_t50 < v_s_t100 AND v_s_t100 < v_s_t300 AND v_s_t300 < v_s_t500) THEN
    RAISE EXCEPTION '[461] 시딩 구간 인원이 오름차순이 아닙니다 (min=%, t50=%, t100=%, t300=%, t500plus=%)',
      v_s_min, v_s_t50, v_s_t100, v_s_t300, v_s_t500;
  END IF;
END;
$guard$;

-- ================================================================
-- [1] _orient_tier_prefix — 시트 형식 → quote_settings 열쇠 앞머리
-- ================================================================
CREATE OR REPLACE FUNCTION public._orient_tier_prefix(p_form_type text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  RETURN CASE p_form_type
    WHEN 'reviewer' THEN 'reviewer_tier_'
    WHEN 'seeding'  THEN 'seeding_tier_'
    ELSE NULL END;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._orient_tier_prefix(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_tier_prefix(text) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_tier_prefix(text) IS
  '[461] 오리엔시트 형식(issued.form_type) → quote_settings 구간 경계 열쇠 앞머리. '
  'reviewer→reviewer_tier_ · seeding→seeding_tier_ · 그 밖 NULL. 표를 안 읽는다(IMMUTABLE). '
  '내부 전용 — 실행 권한 없음. _orient_compute_quote·get_orient_tier_fees·submit_orient_sheet 가 '
  'SECURITY DEFINER 안에서 부른다. update_quote_setting 은 시트가 없어 이 헬퍼를 안 쓴다.';

-- ================================================================
-- [2] _orient_compute_quote — 베이스 459. 구간 경계 넷을 형식별 열쇠에서 읽는다.
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
  v_tier_label    text;        -- [443→448→459→461] 소량 · 라이트 · 스탠다드 · 프리미엄 · <형식별 t500plus 시작 인원>건
  v_fee_key       text;        -- [443] 읽을 기준값 열쇠말(모집비·진행비 — 형식별로 이미 나뉘어 있던 표, 461 무변경)
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
  v_tier_label := CASE v_tier
    WHEN 'tmin'      THEN '소량'          -- [459] 최소 인원 ~ 라이트 시작 인원 미만(직접입력 전용, 단추 없음)
    WHEN 't50'       THEN '라이트'
    WHEN 't100'      THEN '스탠다드'
    WHEN 't300'      THEN '프리미엄'
    WHEN 't500plus'  THEN COALESCE(v_tier_t500plus::text, '') || '건'  -- [461] 형식별 t500plus 시작 인원으로 조립(459 는 '500건' 고정이었다)
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
      --   ⚠️ 461 무변경 — 이 표(reviewer_recruit_fee_krw_*)는 처음부터 형식별로 나뉘어 있었다.
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

    -- [443] 진행비 — 채널×구간. 예외가 있으면 그 값. ⚠️ 461 무변경 — 이 표도 처음부터 형식별.
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
-- CREATE OR REPLACE 는 권한을 보존한다. 그래도 459·454 와 같은 관례로 회수를 한 번 더 건다(대상이 없어도 무해)
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) FROM anon, authenticated;
COMMENT ON FUNCTION public._orient_compute_quote(jsonb, text, timestamptz, timestamptz) IS
  '[461, 베이스 459] 오리엔시트 견적 계산 본문 — 구간 경계(t50·t100·t300·t500plus, 전부 "그 구간의 시작값") '
  '넷을 그 시트 형식의 기준값(reviewer_tier_slots_*·seeding_tier_slots_*)에서 읽어 5갈래(tmin·t50·t100·t300·t500plus)로 '
  '판정한다(형식을 모르면 존재 검사보다 먼저 price_unreadable, 460 이 없는 행을 만들면 fee_missing). 구간별 모집비· '
  '시딩 진행비(tmin 포함, 열쇠는 461 이전과 무변경), 발급 예외(issued.recruit_fee_krw → 줄 이름에 「· 직접 지정」), '
  '리뷰어 추가 옵션(LIPS·@cosme), 500건 이상 구간이면 형식과 무관하게 「실검작업 — 담당자 협의」(값 없음·합계 제외), '
  't500plus 견적 줄 이름은 그 형식의 시작 인원 숫자로 조립(459 의 "500건" 고정에서 변경). 페이백 줄 이름 「판매가」. '
  'submit_orient_sheet·preview_orient_quote 가 공용(preview 는 최소 인원 검사를 안 받는다 — 그건 submit 몫). '
  '실행 권한 없음(내부 전용). 🔴 다음 재정의의 베이스는 461.';

-- ================================================================
-- [3] get_orient_tier_fees — 베이스 459. 형식을 먼저 정하고 그 형식의 경계·최소 인원을 준다.
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
                              'slots', v_slots, 'min_slots', v_min_slots);
  END IF;

  -- 열쇠말 앞머리(모집비·진행비, 461 무변경) — 443 의 v_fee_key 와 같은 조립. 이미 형식이
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
                            'slots', v_slots, 'min_slots', v_min_slots);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[461, 베이스 459] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식(reviewer|seeding)을 먼저 정하고(모르면 '
  'unknown_form_type), 그 형식의 구간 단가 다섯(tmin·t50·t100·t300·t500plus, 461 이전과 같은 표) + 구간 경계 '
  '(시작값) 넷(slots — 그 형식의 reviewer_tier_slots_*·seeding_tier_slots_*, tmin 없음) + 최소 인원(min_slots, '
  '그 형식의 값, 행 없으면 1)을 돌려준다. 응답 모양은 461 이전과 동일. 발급 때 모집비를 직접 지정한 시트는 '
  'override_krw 하나 + 빈 fees(slots·min_slots 는 그대로 준다). 읽기 전용. anon GRANT(preview_orient_quote 가 '
  '이미 basis 전체를 주므로 새 노출 없음).';

-- ================================================================
-- [4] update_quote_setting — 베이스 459. 오름차순 검사를 형식별로 가른다(목록 비교, LIKE 금지).
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
  v_form   text;      -- [461] 'reviewer' | 'seeding' | NULL(구간 인원 열쇠가 아님) — 목록 비교로 정한다
  v_min    numeric;    -- 오름차순 검사용 — 그 형식의 구간 인원 값들(지금 고치는 키는 p_amount 로 덮는다)
  v_t50    numeric;
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

  -- [461] 구간 인원 오름차순 검사 — 리뷰어 5개 목록·시딩 5개 목록을 **목록 비교**로 가른다
  --   (`LIKE 'reviewer_tier_%'` 로 하면 나중에 같은 앞머리의 다른 행이 생겼을 때 조용히 검사에
  --   끌려 들어간다 — 사양서 §3-3). 최소 인원은 라이트 시작 인원과 같아도 되지만(<=, 그 경우
  --   tmin 구간에 아무도 도달하지 못해 저절로 잠긴다), 구간 인원 넷은 여전히 엄격 오름차순이다.
  IF p_key IN ('reviewer_tier_min_slots', 'reviewer_tier_slots_t50', 'reviewer_tier_slots_t100',
               'reviewer_tier_slots_t300', 'reviewer_tier_slots_t500plus') THEN
    v_form := 'reviewer';
  ELSIF p_key IN ('seeding_tier_min_slots', 'seeding_tier_slots_t50', 'seeding_tier_slots_t100',
                  'seeding_tier_slots_t300', 'seeding_tier_slots_t500plus') THEN
    v_form := 'seeding';
  END IF;

  IF v_form = 'reviewer' THEN
    SELECT amount INTO v_min  FROM public.quote_settings WHERE key = 'reviewer_tier_min_slots';
    SELECT amount INTO v_t50  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t50';
    SELECT amount INTO v_t100 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t100';
    SELECT amount INTO v_t300 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t300';
    SELECT amount INTO v_t500 FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t500plus';
    IF p_key = 'reviewer_tier_min_slots'      THEN v_min  := p_amount; END IF;
    IF p_key = 'reviewer_tier_slots_t50'      THEN v_t50  := p_amount; END IF;
    IF p_key = 'reviewer_tier_slots_t100'     THEN v_t100 := p_amount; END IF;
    IF p_key = 'reviewer_tier_slots_t300'     THEN v_t300 := p_amount; END IF;
    IF p_key = 'reviewer_tier_slots_t500plus' THEN v_t500 := p_amount; END IF;
  ELSIF v_form = 'seeding' THEN
    SELECT amount INTO v_min  FROM public.quote_settings WHERE key = 'seeding_tier_min_slots';
    SELECT amount INTO v_t50  FROM public.quote_settings WHERE key = 'seeding_tier_slots_t50';
    SELECT amount INTO v_t100 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t100';
    SELECT amount INTO v_t300 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t300';
    SELECT amount INTO v_t500 FROM public.quote_settings WHERE key = 'seeding_tier_slots_t500plus';
    IF p_key = 'seeding_tier_min_slots'      THEN v_min  := p_amount; END IF;
    IF p_key = 'seeding_tier_slots_t50'      THEN v_t50  := p_amount; END IF;
    IF p_key = 'seeding_tier_slots_t100'     THEN v_t100 := p_amount; END IF;
    IF p_key = 'seeding_tier_slots_t300'     THEN v_t300 := p_amount; END IF;
    IF p_key = 'seeding_tier_slots_t500plus' THEN v_t500 := p_amount; END IF;
  END IF;

  IF v_form IS NOT NULL THEN
    IF v_min IS NULL OR v_t50 IS NULL OR v_t100 IS NULL OR v_t300 IS NULL OR v_t500 IS NULL
       OR NOT (v_min <= v_t50 AND v_t50 < v_t100 AND v_t100 < v_t300 AND v_t300 < v_t500) THEN
      RETURN jsonb_build_object('success', false, 'reason', 'tier_slots_not_ascending', 'form_type', v_form);
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
  '[461, 베이스 459] 견적 기준값 수정 — 캠페인 관리자 이상(is_campaign_admin). 값이 같아도 이력 1행. 거부 reason: '
  'forbidden·invalid_amount·unknown_key·tier_slots_not_ascending(고치는 열쇠가 리뷰어 5개 목록이면 리뷰어끼리, '
  '시딩 5개 목록이면 시딩끼리만 min<=t50<t100<t300<t500plus 검사 — 목록 비교, LIKE 금지. 응답에 form_type 포함). '
  '비율(unit=rate)은 0~1 만 허용.';

-- ================================================================
-- [5] submit_orient_sheet — 베이스 459. 최소 인원 검사가 그 시트 형식의 열쇠를 읽는다.
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
  -- [459→461] 최소 인원 — 제출만 막는다(§3-3). 461 부터 그 시트 형식의 열쇠를 읽는다.
  v_slots_txt    text;
  v_slots_chk    integer;
  v_min_slots    numeric;
  v_tier_prefix  text;
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

      -- [461] 최소 인원 — 그 시트 형식(issued.form_type)의 열쇠를 읽는다. 인원을 안 넣었으면
      --   (빈 문자열) 건너뛴다(그 경우는 아래 견적 계산이 slots_missing 으로 이미 막는다). 형식을
      --   못 정하거나(방어적 — 424 가 막으므로 실제로는 도달하지 않는다) 그 형식의 행이 없으면
      --   1 로 본다(=아무도 안 막는다, get_orient_tier_fees 의 기본값과 같은 값).
      --   🔴 임시저장(save_orient_draft)에는 이 검사를 걸지 않는다 — 자동저장 보호(429 와 같은 원칙).
      v_slots_txt := regexp_replace(COALESCE(v_card0 -> 'product' ->> 'slots', ''), '[^0-9]', '', 'g');
      IF v_slots_txt <> '' THEN
        v_slots_chk := LEAST(v_slots_txt::numeric, 999999)::integer;
        v_tier_prefix := public._orient_tier_prefix(v_data -> 'issued' ->> 'form_type');
        v_min_slots := NULL;
        IF v_tier_prefix IS NOT NULL THEN
          SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = v_tier_prefix || 'min_slots';
        END IF;
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
  --   본문은 _orient_compute_quote(현재 원본 461) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
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

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329·425·430·446·459 와 같은 관례)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446, 459, 461 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429) → '
  '[461] 최소 인원 — 그 시트 형식(issued.form_type)의 열쇠(reviewer_tier_min_slots·seeding_tier_min_slots) 미만이면 '
  'slots_below_min 거부(임시저장은 검사 안 함, 값 못 읽으면 건너뜀, 형식 불명·행 없으면 1) → '
  '[446] 고정 안내 확인(notice_ack 도 없고 notice_ack_checked 도 참이 아니면 notice_not_acknowledged 거부, 통과하면 notice_ack={version,at 서버시각,form_type} 최초 1회 기록) → '
  '[427·430] 견적 계산(_orient_compute_quote 공용 — 현재 원본 461). 세트 규칙: 제출마다 quote 또는 quote_error 하나만. 견적 실패도 제출은 통과. '
  '옛 시트는 어느 검사도 받지 않는다. 🔴 다음 재정의의 베이스는 461.';

-- ================================================================
-- [6] 옛 공용 5행 삭제 — 반드시 함수 재정의(2~5) 다음, 같은 트랜잭션
-- ================================================================
DELETE FROM public.quote_settings
 WHERE key IN ('tier_min_slots', 'tier_slots_t50', 'tier_slots_t100', 'tier_slots_t300', 'tier_slots_t500plus');
-- quote_settings_history 의 옛 열쇠 기록은 남긴다(외래 키 없음 — 「누가 언제 무엇으로 바꿨나」의 근거).

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (개발 DB 적용 후 — 460 을 먼저 적용한 뒤. 최소 인원 1 기준. 사양서 §4 V1~V11 과 대응)
-- ══════════════════════════════════════════════════════════════════════
/*
-- [V1] 옛 5행이 지워졌는가
SELECT count(*) FROM public.quote_settings
 WHERE key IN ('tier_min_slots', 'tier_slots_t50', 'tier_slots_t100', 'tier_slots_t300', 'tier_slots_t500plus');
-- 기대: 0

-- [V2] 리뷰어·시딩 판정이 서로 독립인가(사양서 V3·V5) — 시딩 라이트 시작을 20, 스탠다드 시작을 30 으로 저장
SELECT public.update_quote_setting('seeding_tier_slots_t50', 20);   -- 기대: {"success":true,...}
SELECT public.update_quote_setting('seeding_tier_slots_t100', 30);  -- 기대: {"success":true,...} (min=1<=20<30 만족)
-- 같은 인원(40명)으로 리뷰어·시딩 견적을 각각 계산 — 형식마다 다른 구간이어야 한다
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"40"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier';
-- 기대: tmin (리뷰어 t50=50 이므로 40 < 50)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"seeding","channel":"instagram_feed"},
    "cards":[{"product":{"slots":"40"}}]}'::jsonb,
  'B0002-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier';
-- 기대: t100 (시딩 t50=20·t100=30 이므로 30<=40<시딩 t300)
-- 값을 되돌린다(원래 복사값 50·150 로): 확인 후
SELECT public.update_quote_setting('seeding_tier_slots_t100', 150);
SELECT public.update_quote_setting('seeding_tier_slots_t50', 50);

-- [V3] 오름차순 거부에 form_type 이 실리는가
SELECT public.update_quote_setting('seeding_tier_slots_t50', 999999);
-- 기대: {"success":false,"reason":"tier_slots_not_ascending","form_type":"seeding"}
-- (원복은 이미 [V2] 마지막 줄에서 50 으로 되돌아가 있어야 한다 — 위 실패 호출은 값을 안 바꾼다)

-- [V4] 시딩 최소 인원을 10 으로 → 시딩 5명 제출은 막히고 리뷰어 5명은 통과(리뷰어 최소 1)
--   실제 시트 토큰으로: DO 블록(446·459 파일의 검증 패턴과 동일)으로 감싸 일부러 되돌린다.
--   DO $v$
--   DECLARE t uuid := '<시딩 새 구조 시트 토큰>'; ver int; r jsonb; d jsonb;
--   BEGIN
--     UPDATE public.quote_settings SET amount = 10 WHERE key = 'seeding_tier_min_slots';
--     SELECT version, data INTO ver, d FROM public.orient_sheets WHERE token = t;
--     d := jsonb_set(d, '{cards,0,product,slots}', '"5"');
--     r := public.submit_orient_sheet(t, d, ver);
--     RAISE NOTICE '[V4] %', r;   -- 기대: reason=slots_below_min, min_slots=10
--     RAISE EXCEPTION '검증 끝 — 일부러 되돌린다';
--   END $v$;

-- [V5] get_orient_tier_fees — 리뷰어·시딩 각각 그 형식의 값만 오는가(실제 토큰으로)
--   SELECT public.get_orient_tier_fees('<리뷰어 새 구조 시트 토큰>'::uuid);
--   기대: slots={"t50":50,"t100":150,"t300":300,"t500plus":500}, min_slots=1
--   SELECT public.get_orient_tier_fees('<시딩 새 구조 시트 토큰>'::uuid);
--   기대: 시딩 값(위 [V2] 에서 원복했다면 리뷰어와 같은 초기값)

-- [V6] 형식을 모르면(방어적 — 실제로는 424 가 막아 도달하지 않는다) price_unreadable
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"unknown_x","channel":null},
    "cards":[{"product":{"slots":"200"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) ->> 'quote_error';
-- 기대: price_unreadable (fee_missing 이 아니어야 한다 — 이게 §3-2 순서 가드의 핵심 증거)

-- [V7] t500plus 구간 견적 줄 이름 — 형식별 시작 인원으로 조립되는가
--   시딩 t500plus 시작 인원을 400 으로 저장 → 시딩 450명 견적의 recruit/seeding 줄 이름에 "400건" 포함
SELECT public.update_quote_setting('seeding_tier_slots_t500plus', 400);
SELECT (l ->> 'label') FROM jsonb_array_elements(
  (public._orient_compute_quote(
     '{"issued":{"form_type":"seeding","channel":"instagram_feed"},
       "cards":[{"product":{"slots":"450"}}]}'::jsonb,
     'B0002-C001', now() + interval '30 days', now()) -> 'quote' -> 'lines')
) l WHERE l ->> 'key' = 'seeding';
-- 기대: '시딩 진행비 — 인스타그램-피드 (400건)' 포함. 확인 후 원복: SELECT public.update_quote_setting('seeding_tier_slots_t500plus', 500);

-- [V8] 관리자 「견적 기준값」 화면(관리자 로그인 브라우저 콘솔) — 리뷰어 5행 + 시딩 5행이 각자 묶음 머리로 보이는가
--   await db.rpc('get_quote_settings') → group_ko 에 '리뷰어 구간 인원'·'시딩 구간 인원' 포함

-- [V9] 🔴 V5·V6(사양서 §4) 은 브라우저로 눈으로 볼 것 — 폼이 실제로 그 시트 형식의 단추를 그리는지,
--   직접입력 옆 최소 인원 안내가 그 형식 값인지는 SQL 로는 재현되지 않는다.
*/

-- ============================================================
-- 되돌리기 — 아래 순서로 그대로 실행 (🔴 460 보다 먼저 이 파일을 되돌릴 것)
-- ============================================================
/*
BEGIN;

-- ① 옛 공용 5행 재삽입 — 리뷰어 값에서 복사(460 적용 시점의 값과 같다고 가정. 그 사이 리뷰어
--   값을 관리자가 고쳤다면 실제 되돌리려는 시점의 "정답"이 무엇인지 사람이 다시 판단할 것)
INSERT INTO public.quote_settings (key, amount, unit, label_ko, group_ko, sort_order)
SELECT 'tier_min_slots', amount, 'count',
       '최소 모집 인원 (이 값보다 적은 인원은 접수하지 않음)', '구간', 16
  FROM public.quote_settings WHERE key = 'reviewer_tier_min_slots'
UNION ALL
SELECT 'tier_slots_t50', amount, 'count',
       '구간 인원 — 라이트 시작 인원 (이 값부터 라이트 구간)', '구간', 12
  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t50'
UNION ALL
SELECT 'tier_slots_t100', amount, 'count',
       '구간 인원 — 스탠다드 시작 인원 (이 값부터 스탠다드 구간)', '구간', 13
  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t100'
UNION ALL
SELECT 'tier_slots_t300', amount, 'count',
       '구간 인원 — 프리미엄 시작 인원 (이 값부터 프리미엄 구간)', '구간', 14
  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t300'
UNION ALL
SELECT 'tier_slots_t500plus', amount, 'count',
       '구간 인원 — 실검작업 구간 시작 인원 (이 값 이상이면 실검작업 구간)', '구간', 15
  FROM public.quote_settings WHERE key = 'reviewer_tier_slots_t500plus'
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ② 함수 넷을 459 판으로 되돌린다 — 459_orient_tier_five_and_direct_input.sql 의
--    [E] _orient_compute_quote · [F] get_orient_tier_fees · [G] update_quote_setting ·
--    [H] submit_orient_sheet 네 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.

-- ③ 헬퍼 삭제(461 이 만든 것 — 되돌린 459 판 함수들은 이 헬퍼를 안 부른다)
DROP FUNCTION IF EXISTS public._orient_tier_prefix(text);
NOTIFY pgrst, 'reload schema';

-- ④ 460 이 만든 리뷰어·시딩 10행은 이 파일이 손대지 않는다 — 지우려면 460 의 되돌리기를 이어서 실행할 것.
*/
