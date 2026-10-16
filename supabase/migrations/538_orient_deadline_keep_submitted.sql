-- ============================================================
-- 538_orient_deadline_keep_submitted.sql
-- 2026-10-16 — 오리엔시트 기한이 지나도 「제출된 시트」는 상태를 그대로 둔다 (긴급)
--   작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 「작업 1」
--
-- 결함: save_orient_draft·submit_orient_sheet(524)는 token_expires_at 이 지나면
--   status NOT IN ('expired','consumed') 인 시트를 전부 status='expired' 로 바꾼다.
--   그래서 이미 제출된(submitted) 시트에 기한 뒤 저장 요청 한 번(폼 자동저장)이 오면 「만료」로 바뀌고,
--   캠페인 등록 함수 mark_orient_card_consumed(196, status <> 'submitted' → invalid_status)와
--   link_orient_card_to_campaign(464, 같은 판정)가 그 시트를 거부해 운영팀이 캠페인을 등록하지 못한다.
--
-- 고침: 기한 갈래만 바꾼다.
--   - status='draft'     → 지금처럼 'expired' 로 바꾸고 {success:false, reason:'expired'}
--   - status='submitted' → 상태는 그대로 두고 같은 {success:false, reason:'expired'} 거부만  [538]
--   - 그 밖 본문은 524 와 글자 그대로. (consumed·expired 는 종전대로 상태 변경 없음)
--
-- 대상(기한에서 status 를 쓰는 함수 전수 — migrations 전체에서 SET status = 'expired' 를 찾아 확인):
--   save_orient_draft    현재 원본 524 → 이 파일 538
--   submit_orient_sheet  현재 원본 524 → 이 파일 538
--   ⚠️ 읽기 전용이라 안 건드린 것: get_orient_sheet(524 — 만료는 반환값으로만 알림, 주석 그대로 읽기 전용),
--      preview_orient_quote(430 — 저장 없음), get_orient_tier_fees(489 — 조회만).
--      mark_orient_card_consumed(196)·link_orient_card_to_campaign(464)은 기한을 보지 않고 status='submitted' 만 본다 — 고치지 않는다.
--   🔴 다음 재정의의 베이스는 save_orient_draft·submit_orient_sheet 둘 다 이 파일(538)이다.
--
-- 🔴 운영 적용: 526~537 브랜드 묶음과 별개로 **이 파일만 먼저** 넣는다(긴급).
--   - 두 함수는 운영 링크 폼(sales 오리엔 작성 폼)이 지금 쓴다.
--   - 이 파일은 523(draft_data·draft_saved_at 칸)·524(함수)·그 헬퍼(_orient_apply_card_uids 293·
--     _orient_preserve_published_cards 328·_orient_apply_issued_rules 445·_orient_sent_card_uids 329·
--     _orient_tier_prefix 461·_orient_text_length·_orient_compute_quote 463)에만 기댄다. 526~537 의 표·함수·칸을 부르지 않는다.
--   - ⚠️ 운영에 523·524 가 이미 있어야 한다(없으면 draft_data 칸이 없어 함수가 첫 호출에서 터진다) — 아래 [확인 1] 로 먼저 본다.
--
-- 편집기 경고: 안 뜸(CREATE OR REPLACE·REVOKE·GRANT·COMMENT 만 — 본문에 DELETE·DROP 없음).
-- 롤백: 524 의 [B] 블록(save_orient_draft)·[C] 블록(submit_orient_sheet)을 그대로 재실행(CREATE OR REPLACE).
--       ⚠️ 롤백하면 결함이 되살아난다. 되돌리기 전에 제출된 시트의 기한 상태를 확인할 것.
--
-- 적용 전 확인 (운영·개발 공통, 읽기만)
--   [확인 1] 523 칸 존재:
--     SELECT column_name FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='orient_sheets' AND column_name IN ('draft_data','draft_saved_at');   -- 2행
--
-- 적용 뒤 확인 (읽기만)
--   [확인 2] 새 갈래가 함수 정의에 들어갔다 (둘 다 true):
--     SELECT p.proname, position($q$status = 'draft'$q$ in pg_get_functiondef(p.oid)) > 0 AS has_draft_branch,
--            position('538' in pg_get_functiondef(p.oid)) > 0 AS has_538_mark
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname='public' AND p.proname IN ('save_orient_draft','submit_orient_sheet');
--   [확인 3] 권한 — 둘 다 anon 실행 가능, PUBLIC(=X/) 없음(proacl 맨 앞이 =X/ 로 시작하면 안 된다):
--     SELECT p.proname, p.proacl::text, (p.proacl::text LIKE '{=X/%') AS public_granted_must_be_false
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname='public' AND p.proname IN ('save_orient_draft','submit_orient_sheet');
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [B] save_orient_draft — 베이스 425. 변경점은 [524] 표시
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
    -- [538] 작성 중(draft)만 expired 로 바꾼다. 제출된(submitted) 시트는 상태를 그대로 둔다 —
    --   바꾸면 캠페인 등록(196·464 의 status='submitted' 검사)이 막힌다. consumed·expired 는 종전대로 변경 없음.
    IF v_sheet.status = 'draft' THEN
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

  -- 보정 세 단계 — 425 와 글자 그대로. 🔴 [524] 기준(두 번째 인자)은 언제나 data = 제출본(또는 작성 중 판)이다.
  --   작성본(draft_data)을 기준으로 삼으면 발행 카드 복구·서버 키 보존이 브랜드가 고친 판을 원본으로 착각한다.
  -- 카드 고유 번호 보정 (293)
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드 복구 (328)
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

  IF v_sheet.status = 'submitted' THEN
    -- [524] 제출된 시트 — 제출본(data)은 그대로 두고 작성본 칸에만 쓴다. 「다시 제출」해야 data 가 바뀐다.
    --   보정한 값이 제출본과 같으면(아무것도 안 고침·고쳤다가 되돌림) 작성본을 비운다 — 관리자 「수정 중」 표시가 거짓이 되지 않게.
    --   jsonb 의 = 는 키 순서·공백과 무관하게 내용으로 비교한다.
    IF v_data = v_sheet.data THEN
      UPDATE public.orient_sheets
         SET draft_data     = NULL,
             draft_saved_at = NULL,
             version        = v_sheet.version + 1
       WHERE id      = v_sheet.id
         AND version = p_version;
    ELSE
      UPDATE public.orient_sheets
         SET draft_data     = v_data,
             draft_saved_at = now(),
             version        = v_sheet.version + 1
       WHERE id      = v_sheet.id
         AND version = p_version;
    END IF;
  ELSE
    -- 작성 중(draft) — 425 그대로 data 에 쓴다(미제출 시트는 발행 대상이 아니다).
    UPDATE public.orient_sheets
       SET data    = v_data,
           version = v_sheet.version + 1
     WHERE id      = v_sheet.id
       AND version = p_version;
  END IF;

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

REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328, 329, 425, 524, 538 개정] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) '
  '(기준은 언제나 data) → 그 최종 값 기준 jsonb 100KB 상한. 임시저장에는 카드 수·글자 수 거부를 걸지 않는다(자동저장 보호). '
  '[524] status=submitted 면 data 를 건드리지 않고 draft_data·draft_saved_at 에 쓴다(보정 값이 data 와 같으면 둘 다 NULL). '
  'draft 상태는 data 에. 성공 응답에 card_uids. status 미변경(기한 지난 draft 만 expired, submitted 는 그대로 — 538). SECURITY DEFINER + search_path 고정. 🔴 다음 재정의의 베이스는 538.';

-- ------------------------------------------------------------
-- [C] submit_orient_sheet — 베이스 461(글자 그대로). 변경점은 성공 UPDATE 의 [524] 두 줄뿐
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
    -- [538] 작성 중(draft)만 expired 로 바꾼다. 제출된(submitted) 시트는 상태를 그대로 둔다 —
    --   바꾸면 캠페인 등록(196·464 의 status='submitted' 검사)이 막힌다. consumed·expired 는 종전대로 변경 없음.
    IF v_sheet.status = 'draft' THEN
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
         version           = v_sheet.version + 1,
         -- [524] 다시 제출하면 작성본은 제출본이 됐으므로 비운다(관리자 「수정 중」 표시도 함께 사라진다)
         draft_data        = NULL,
         draft_saved_at    = NULL
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

REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446, 459, 461, 524, 538 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429) → '
  '[461] 최소 인원 — 그 시트 형식(issued.form_type)의 열쇠(reviewer_tier_min_slots·seeding_tier_min_slots) 미만이면 '
  'slots_below_min 거부(임시저장은 검사 안 함, 값 못 읽으면 건너뜀, 형식 불명·행 없으면 1) → '
  '[446] 고정 안내 확인(notice_ack 도 없고 notice_ack_checked 도 참이 아니면 notice_not_acknowledged 거부, 통과하면 notice_ack={version,at 서버시각,form_type} 최초 1회 기록) → '
  '[427·430] 견적 계산(_orient_compute_quote 공용 — 현재 원본 463). 세트 규칙: 제출마다 quote 또는 quote_error 하나만. 견적 실패도 제출은 통과. '
  '[524] 성공 시 작성본(draft_data·draft_saved_at)을 비운다. '
  '[538] 기한이 지나면 draft 만 expired 로 바꾸고 submitted 는 상태를 그대로 둔 채 expired 거부. '
  '옛 시트는 어느 검사도 받지 않는다. 🔴 다음 재정의의 베이스는 538.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 피해 확인 (읽기만) — 이 결함으로 「제출됐는데 expired」가 된 시트
-- ============================================================
-- SELECT id, orient_no, brand_id, status, submitted_at, token_expires_at, campaign_id
--   FROM public.orient_sheets
--  WHERE status = 'expired' AND submitted_at IS NOT NULL
--  ORDER BY token_expires_at DESC;
--
-- 2026-10-16 운영 조회 결과: 피해 0건 → 되돌리는 패치는 **실행 불필요**. 아래는 만일을 위한 초안(실행 금지, 확인 후에만).
-- 되돌리는 패치 초안 (피해 행이 나왔을 때만):
--   -- 등록 카드(data.cards[].campaign_id)가 하나도 없으면 submitted, 전부 등록돼 있으면 consumed 로 되돌린다.
--   -- (일부만 등록된 시트는 종전 규칙대로 submitted — 196 이 부분 발행을 submitted 로 둔다)
--   UPDATE public.orient_sheets s
--      SET status = CASE
--            WHEN jsonb_typeof(s.data -> 'cards') = 'array' AND jsonb_array_length(s.data -> 'cards') > 0
--                 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s.data -> 'cards') c
--                                  WHERE c ->> 'campaign_id' IS NULL OR c ->> 'campaign_id' = '')
--              THEN 'consumed' ELSE 'submitted' END
--    WHERE s.status = 'expired' AND s.submitted_at IS NOT NULL
--      AND s.id IN ('<위 조회에서 확인한 id>');   -- 반드시 id 를 눈으로 확인해 좁힌다
--   -- ⚠️ token_expires_at 은 과거 그대로라 그 시트는 브랜드 폼에서 여전히 만료로 보인다(운영팀 등록 용도로만 살린다).
--
-- ============================================================
-- 개발서버 시험 절차 (개발 DB SQL 편집기 — 익명 함수라 토큰으로 바로 호출된다. 서비스 키여도 토큰 갈래는 돈다)
-- ============================================================
-- 인자: save_orient_draft(p_token uuid, p_data jsonb, p_version int) — 524 정의 그대로.
-- 0) 시험용 시트 둘 고르기(없으면 개발 브랜드로 새로 발급). 원래 값 메모:
--    SELECT id, token, status, version, token_expires_at, data FROM public.orient_sheets ORDER BY created_at DESC LIMIT 10;
--    A = status='submitted' 시트 / B = status='draft' 시트. 둘의 token_expires_at 원래 값을 적어 둔다.
-- 1) 기한을 과거로:
--    UPDATE public.orient_sheets SET token_expires_at = now() - interval '1 hour' WHERE id IN ('<A id>','<B id>');
-- 2) A(제출됨) — 거부되지만 상태는 그대로여야 한다:
--    SELECT public.save_orient_draft('<A token>'::uuid, (SELECT data FROM public.orient_sheets WHERE id='<A id>'), <A version>);
--      → {"success":false,"reason":"expired"}
--    SELECT status FROM public.orient_sheets WHERE id='<A id>';   -- 'submitted' 그대로
-- 3) B(작성 중) — 거부되고 expired 로 바뀐다:
--    SELECT public.save_orient_draft('<B token>'::uuid, (SELECT data FROM public.orient_sheets WHERE id='<B id>'), <B version>);
--      → {"success":false,"reason":"expired"}
--    SELECT status FROM public.orient_sheets WHERE id='<B id>';   -- 'expired'
-- 4) (선택) submit_orient_sheet 도 같은 갈래라 A 에 같은 방식으로 호출 → expired 거부 + 'submitted' 유지.
-- 5) 되돌리기(시험 값 원복):
--    UPDATE public.orient_sheets SET status='submitted', token_expires_at='<A 원래 값>' WHERE id='<A id>';
--    UPDATE public.orient_sheets SET status='draft',     token_expires_at='<B 원래 값>' WHERE id='<B id>';
-- ============================================================
