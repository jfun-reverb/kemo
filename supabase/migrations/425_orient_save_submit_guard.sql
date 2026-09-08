-- ============================================================
-- 425_orient_save_submit_guard.sql
-- 2026-09-08 — 오리엔시트 단순화 재설계 1단계 · 마이그레이션 Ⓑ (작업 2)
--   사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-1 · §4-2 · §4-8 Ⓑ
--   작업표 docs/specs/2026-09-08-orient-sheet-simplify-and-quote-breakdown.md 작업 2
--
-- 🔴 2단계 마이그레이션 Ⓓ(제출 함수 ②차 — 견적 계산)는 329 가 아니라 **이 파일**을
--    베이스로 삼는다. save_orient_draft 는 이 판 그대로 두고 submit_orient_sheet 만 다시 쓴다.
--
-- 무엇을 바꾸나 — save_orient_draft · submit_orient_sheet 를 함께 재정의(베이스 329, 시그니처 그대로)
--   [공통] ① 서버가 쓴 키 보존 — issued · quote · quote_history · quote_error 네 키는
--          들어온 data 와 무관하게 **저장돼 있던 값을 다시 얹는다**(카드 uid 안전망 293 과 같은 원칙).
--          지금 두 함수는 data 를 통째로 저장하므로, 옛 캐시 폼(이 키를 모른다)이 임시저장을 한 번만
--          해도 issued 가 사라져 새 시트가 옛 시트로 둔갑한다. 이 보존이 없으면 §4-1 의 판별·
--          카드 제한·형식 덮어쓰기가 전부 헛돈다.
--          ② 형식·채널 원본 덮어쓰기 — **issued 가 있는 시트에서만** cards[0].form_type := issued.form_type,
--          시딩이면 cards[0].seeding.channels := [issued.channel]. 옛 시트는 덮어쓸 원본이 없다.
--   [제출만, issued 있을 때만] 카드 2개 이상 → cards_limit / 리뷰 가이드 1,000자 초과 → guide_too_long /
--          소구 키워드 1,000자 초과 → appeal_too_long. 글자 수는 서식(태그)을 뺀 본문 기준.
--   🔴 임시저장에는 어떤 거부도 걸지 않는다 — 막히면 자동저장이 반복 실패해 작성 중인 글을 잃는다.
--   🔴 옛 시트(issued 없음)는 어느 검사도 받지 않는다 — 「옛 시트는 옛 화면 그대로」.
--   카드 고유 번호 부분(_orient_apply_card_uids · _orient_preserve_published_cards · _orient_sent_card_uids)은
--   329 에서 글자 그대로.
--
-- 새 헬퍼 _orient_apply_issued_rules(p_data, p_saved) — [공통] ①②를 한 곳에서(두 함수가 같은 코드를 쓴다).
--   내부 전용 — 실행 권한을 아무에게도 주지 않는다(SECURITY DEFINER 함수 안에서만 돈다).
--
-- 반환 키 329 그대로(card_uids 포함). 거부 reason 3종 신설.
--
-- 롤백: 329 의 B·C 블록(두 함수) 재실행 + DROP FUNCTION public._orient_apply_issued_rules(jsonb, jsonb)
--       + DROP FUNCTION public._orient_text_length(text).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- A. 헬퍼 — 서버 키 보존 + 형식·채널 원본 덮어쓰기
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_apply_issued_rules(
  p_data   jsonb,   -- 이번에 들어온(카드 uid 보정·발행 카드 복구까지 끝난) data
  p_saved  jsonb    -- 저장돼 있던 data
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_out     jsonb := p_data;
  v_key     text;
  v_issued  jsonb;
  v_cards   jsonb;
  v_card0   jsonb;
  v_ft      text;
  v_ch      text;
BEGIN
  IF v_out IS NULL OR jsonb_typeof(v_out) <> 'object' THEN
    RETURN p_data;
  END IF;

  -- ① 서버가 쓴 키는 서버가 지킨다 — 저장돼 있던 값이 있으면 그 값으로, 없으면 들어온 값도 지운다
  --    (브랜드 폼이 이 키를 만들 권한이 없다. 견적 3종은 2단계 Ⓓ 가 제출 함수 안에서 스스로 새로 쓴다 — 이 보존 뒤에).
  FOREACH v_key IN ARRAY ARRAY['issued', 'quote', 'quote_history', 'quote_error'] LOOP
    IF p_saved IS NOT NULL AND jsonb_typeof(p_saved) = 'object' AND (p_saved ? v_key) THEN
      v_out := jsonb_set(v_out, ARRAY[v_key], p_saved -> v_key, true);
    ELSE
      v_out := v_out - v_key;
    END IF;
  END LOOP;

  -- ② issued 가 있는 시트만 — 형식·채널 원본으로 cards[0] 을 덮어쓴다
  v_issued := v_out -> 'issued';
  IF v_issued IS NULL OR jsonb_typeof(v_issued) <> 'object' THEN
    RETURN v_out;
  END IF;
  v_ft := v_issued ->> 'form_type';
  v_ch := v_issued ->> 'channel';
  v_cards := v_out -> 'cards';
  IF v_cards IS NULL OR jsonb_typeof(v_cards) <> 'array' OR jsonb_array_length(v_cards) = 0 THEN
    RETURN v_out;
  END IF;
  v_card0 := v_cards -> 0;
  IF jsonb_typeof(v_card0) <> 'object' THEN
    RETURN v_out;
  END IF;

  IF v_ft IS NOT NULL AND v_ft <> '' THEN
    v_card0 := jsonb_set(v_card0, ARRAY['form_type'], to_jsonb(v_ft), true);
  END IF;
  IF v_ft = 'seeding' AND v_ch IS NOT NULL AND v_ch <> '' THEN
    IF v_card0 -> 'seeding' IS NULL OR jsonb_typeof(v_card0 -> 'seeding') <> 'object' THEN
      v_card0 := jsonb_set(v_card0, ARRAY['seeding'], '{}'::jsonb, true);
    END IF;
    v_card0 := jsonb_set(v_card0, ARRAY['seeding', 'channels'], jsonb_build_array(v_ch), true);
  END IF;

  RETURN jsonb_set(v_out, ARRAY['cards', '0'], v_card0, false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public._orient_apply_issued_rules(jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_apply_issued_rules(jsonb, jsonb) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_apply_issued_rules(jsonb, jsonb) IS
  '[425] 오리엔시트 저장·제출 공통 — ①서버 키(issued·quote·quote_history·quote_error)는 저장돼 있던 값으로 되돌리고 '
  '②issued 가 있는 시트만 cards[0].form_type·seeding.channels 를 issued 원본으로 덮어쓴다. 내부 전용(실행 권한 없음).';

-- 서식 뺀 글자 수 — 폼(orient.html enforceCharLimit)이 세는 textContent 와 같은 기준으로 맞춘다:
--   태그 제거 → HTML 개체 참조(&amp; &lt; &gt; &quot; &#39; &nbsp; 그 밖의 &…;)는 글자 1개로 → 앞뒤 공백 제거.
--   ⚠️ 폼은 브라우저가 개체를 이미 해독한 본문을 세므로, 여기서 개체를 1글자로 안 접으면
--      '&' 가 많은 글은 「폼에서는 999자인데 제출은 막히는」 어긋남이 난다(리뷰 지적).
CREATE OR REPLACE FUNCTION public._orient_text_length(p_html text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT length(btrim(
    regexp_replace(
      regexp_replace(COALESCE(p_html, ''), '<[^>]*>', '', 'g'),   -- 태그 제거
      '&(#[0-9]+|#x[0-9a-fA-F]+|[a-zA-Z]+);', 'x', 'g'             -- 개체 참조 하나 = 글자 하나
    )
  ));
$$;

REVOKE EXECUTE ON FUNCTION public._orient_text_length(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_text_length(text) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_text_length(text) IS
  '[425] 리뷰 가이드·소구 키워드 글자 수 — 태그를 뺀 본문 기준(폼 표시와 같은 셈법). 내부 전용.';

-- ------------------------------------------------------------
-- B. save_orient_draft — 임시저장 (베이스 329, 변경점은 [425] 표시)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_orient_draft(
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
  v_data         jsonb;
  v_card_uids    jsonb;
BEGIN
  SELECT id, status, version, token_expires_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
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

  -- 카드 고유 번호 보정 (293) — 329 와 글자 그대로
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드 복구 (328) — 329 와 글자 그대로
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- [425] 서버 키 보존 + 형식·채널 원본 덮어쓰기. 🔴 임시저장은 어떤 거부도 걸지 않는다.
  v_data := public._orient_apply_issued_rules(v_data, v_sheet.data);

  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
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

  UPDATE public.orient_sheets
     SET data    = v_data,
         version = v_sheet.version + 1
   WHERE id      = v_sheet.id
     AND version = p_version;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'conflict'
    );
  END IF;

  v_card_uids := public._orient_sent_card_uids(p_data, v_data);

  RETURN jsonb_build_object(
    'success',   true,
    'version',   v_sheet.version + 1,
    'card_uids', v_card_uids
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329 와 같은 관례)
REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328, 329, 425 개정] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → '
  '[425] _orient_apply_issued_rules(서버 키 issued·quote·quote_history·quote_error 보존 + issued 시트의 형식·채널 원본 덮어쓰기) → '
  '그 최종 값 기준으로 jsonb 100KB 상한 검사. [425] 임시저장에는 카드 수·글자 수 거부를 걸지 않는다(자동저장 보호). '
  '[329] 성공 응답에 card_uids. status 미변경. SECURITY DEFINER + search_path 고정.';

-- ------------------------------------------------------------
-- C. submit_orient_sheet — 제출 (베이스 329, 변경점은 [425] 표시)
--    반환 키는 329 그대로(제출 알림 메일이 쓴다).
-- ------------------------------------------------------------
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
  v_is_new       boolean;   -- data.issued 가 있는 새 구조 시트인가
  v_cards        jsonb;
  v_card0        jsonb;
  v_len          integer;
BEGIN
  SELECT id, brand_id, application_id, form_type,
         status, version, token_expires_at, submitted_at, data
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

  -- [425] 서버 키 보존 + 형식·채널 원본 덮어쓰기 (save_orient_draft 와 같은 헬퍼)
  v_data := public._orient_apply_issued_rules(v_data, v_sheet.data);

  -- [425] 새 구조(issued 있음) 시트만 — 카드 1개 제한 + 글자 수 재검증.
  --   옛 시트는 어느 검사도 받지 않는다(옛 폼은 자르지 않고 거부 코드도 모른다 — 「옛 시트는 옛 화면 그대로」).
  v_is_new := (v_data -> 'issued') IS NOT NULL AND jsonb_typeof(v_data -> 'issued') = 'object';
  IF v_is_new THEN
    v_cards := v_data -> 'cards';
    IF v_cards IS NOT NULL AND jsonb_typeof(v_cards) = 'array' AND jsonb_array_length(v_cards) > 1 THEN
      -- 옛 폼이 캐시로 남아 「제품 추가」로 카드를 늘린 경우의 안전판
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
    'card_uids',           v_card_uids
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329 와 같은 관례)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425 개정] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version 으로 최종 제출. '
  '저장 직전 _orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → [425] _orient_apply_issued_rules → '
  '[425] issued 가 있는 새 구조 시트만: 카드 2개 이상 cards_limit · 리뷰 가이드 1,000자 초과 guide_too_long · 소구 1,000자 초과 appeal_too_long '
  '(글자 수는 태그를 뺀 본문). 옛 시트는 검사 없음. 반환 키 329 그대로(제출 알림 메일 사용). '
  '🔴 2단계 Ⓓ(견적 계산)는 이 파일을 베이스로 삼는다. SECURITY DEFINER + search_path 고정.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 실제 토큰으로 rpc 호출. 익명 함수라 SQL 편집기 호출도 통한다)
-- ============================================================
-- [V1] 424 로 시딩 시트 발급 → 토큰 T, 버전 v.
-- [V2] issued 를 뺀 data 로 save_orient_draft(T, {brand:{…},cards:[…]}, v) → 조회하면 data.issued 살아 있음.
-- [V3] cards[0].form_type='reviewer' 로 저장 → 조회하면 'seeding' 으로 되돌아옴, seeding.channels=[issued.channel].
-- [V4] cards 2개로 save → success / submit → cards_limit.
-- [V5] review_guide 1,001자로 save → success / submit → guide_too_long (태그 붙여도 본문만 센다).
-- [V6] 옛 구조 시트(issued 없음)로 카드 2개·1,001자 submit → success.
-- [V7] 응답 card_uids 가 329 검증과 같은 값.
