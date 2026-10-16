-- ============================================================
-- 539_orient_core_functions.sql
-- 2026-10-16 — 오리엔시트 본체 한 벌로 + 저장자 칸 + 3차 ①-5 + 브랜드 화면 상태 판정
--   작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 「작업 2」 · 결정 1·2·3·4 · 기본값 2
--
-- 무엇이 바뀌나 (이 파일이 하는 전부)
--   1) 칸 둘: orient_sheets.last_edited_at timestamptz NULL · last_edited_by uuid NULL (외래 키 없음 —
--      계정이 지워져도 행 보존). 브랜드(토큰 폼 포함)의 저장·제출이 **성공할 때만** 쓴다. 기존 행은 NULL(소급 없음).
--      관리자 동작·메일 기록은 안 건드린다. 토큰 폼은 시각만 찍고 저장자는 NULL.
--   2) 내부 함수 넷 — 저장·제출·미리보기·구간 조회의 **본문**. 시트를 토큰이 아니라 시트 번호(id)로 찾는다.
--        _orient_save_core(p_sheet_id, p_data, p_version, p_editor)      본문 = 538 save_orient_draft
--        _orient_submit_core(p_sheet_id, p_data, p_version, p_editor)    본문 = 538 submit_orient_sheet + [539] ①-5
--        _orient_preview_core(p_sheet_id, p_data)                        본문 = 430 [C] preview_orient_quote
--        _orient_tier_fees_core(p_sheet_id)                              본문 = 489 get_orient_tier_fees
--      시트가 없으면 {success:false, reason:'not_found'}.
--   3) 판정 _orient_brand_view_status(status, deadline, data, last_edited_at, version) → new|editing|submitted|registered|expired
--      우선순위(결정 1·3·4): ① status='consumed' 이거나 data.cards 중 campaign_id 가 비어 있지 않은 카드가 하나라도 있으면 registered
--      (옛 구조 일부 등록 포함) → ② status='expired' 이거나 기한 지남이면 expired (제출된 시트도) → ③ submitted → ④ draft:
--      저장 기록 없고 version=0 이면 new, 아니면 editing.
--      🔴 발급 직후 version 은 **0** 이다 — 186 표 기본값 0, create_orient_sheet(195·424·447·465·490)도 0 을 넣는다.
--         작업표의 「version = 1」은 틀린 추정이었다(작업 2 산출 계약 「실제 시작값은 작성 때 확인」). 그래서 new = version 0.
--   4) 토큰 함수 넷(save_orient_draft · submit_orient_sheet · preview_orient_quote · get_orient_tier_fees)을
--      「토큰 → 시트 번호」만 하고 본체를 부르도록 CREATE OR REPLACE. 인자·결과 키·invalid_token·권한·변동성은 그대로.
--      본체가 not_found 를 주면(조회와 잠금 사이 삭제) 토큰 함수는 invalid_token 으로 바꿔 준다.
--   5) 3차 ①-5 (_orient_submit_core): 견적 계산 예외 갈래(EXCEPTION WHEN OTHERS)가 quote 를 지우기 전에
--      직전 quote(객체면)를 quote_history 배열 끝에 붙인다 — 463 _orient_compute_quote 의 정상 경로와 같은 방식.
--      ⚠️ PL/pgSQL 변수는 예외로 되돌려지지 않으므로 블록 진입 전 v_data 를 v_data_before 에 보관하고,
--         예외 갈래에서 그 값으로 되돌린 뒤 이력 옮기기를 한다(계산 도중 일부 대입 차단).
--   get_orient_sheet(524)는 건드리지 않는다. _orient_compute_quote(463)·헬퍼 6종도 건드리지 않는다.
--
-- 🔴 다음 재정의의 베이스는 이 파일(539) — 여섯 함수 + 판정 함수:
--      save_orient_draft · submit_orient_sheet · preview_orient_quote · get_orient_tier_fees (토큰 래퍼)
--      _orient_save_core · _orient_submit_core · _orient_preview_core · _orient_tier_fees_core (본체) · _orient_brand_view_status
--    (본체를 고칠 때는 토큰 함수가 아니라 *_core 를 고친다. 538·430·489 를 베이스로 잡으면 저장자 칸·①-5 가 사라진다.)
--
-- 선행: 538(기한 결함 수정 — 운영에도 먼저 들어감) · 523·524(draft_data 칸) · 헬퍼 _orient_apply_card_uids(293)·
--      _orient_preserve_published_cards(328)·_orient_apply_issued_rules(445)·_orient_sent_card_uids(329)·
--      _orient_tier_prefix(461)·_orient_text_length·_orient_compute_quote(463)·표 quote_tier_labels(462)·quote_settings(426).
--
-- 🔴 운영 적용: 브랜드 묶음(526~537 · 530~536)과 함께. 단 **적용하는 순간부터 운영 링크 폼이 새 본체로 돈다**
--   (토큰 함수 넷은 운영 링크 폼이 지금 쓰는 함수). 그래서 적용 직후 운영 링크 폼에서 저장 한 번·견적 보기 한 번을 확인할 것.
--   개발서버에서 아래 [V1]~[V7] 을 먼저 통과시킨다.
--
-- 편집기 경고: 실행 구문에는 DROP·DELETE 없음(ALTER TABLE ADD COLUMN IF NOT EXISTS · CREATE OR REPLACE · GRANT/REVOKE · COMMENT).
--   롤백 설명 주석에 DROP 이 적혀 있어 편집기가 글자만 보고 경고를 띄우면 내용을 확인하고 진행한다.
--
-- 롤백 (순서 중요 — 3 이후 파일이 이 함수들을 부르면 그것을 먼저 되돌린다):
--   ① 토큰 함수 넷을 되돌린다:
--        save_orient_draft · submit_orient_sheet  → 538 의 [B]·[C] 블록 재실행
--        preview_orient_quote                     → 430 의 [C] 블록 재실행
--        get_orient_tier_fees                     → 489 의 CREATE OR REPLACE 블록 재실행
--      ⚠️ 524 로 되돌리면 538 의 기한 결함 수정이 사라진다.
--   ② 내부 함수·판정 제거:
--        DROP FUNCTION public._orient_brand_view_status(text, timestamptz, jsonb, timestamptz, int);
--        DROP FUNCTION public._orient_tier_fees_core(uuid);
--        DROP FUNCTION public._orient_preview_core(uuid, jsonb);
--        DROP FUNCTION public._orient_submit_core(uuid, jsonb, int, uuid);
--        DROP FUNCTION public._orient_save_core(uuid, jsonb, int, uuid);
--   ③ 칸 제거: ALTER TABLE public.orient_sheets DROP COLUMN last_edited_by, DROP COLUMN last_edited_at;
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 칸 둘 (기존 행 소급 없음)
-- ------------------------------------------------------------
ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS last_edited_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS last_edited_by uuid        NULL;

COMMENT ON COLUMN public.orient_sheets.last_edited_at IS
  '[539] 브랜드(토큰 폼·로그인)가 마지막으로 저장·제출에 성공한 시각. NULL = 아직 아무도 저장하지 않음(기존 행도 NULL — 소급 없음). 관리자 동작·메일 기록은 안 쓴다';
COMMENT ON COLUMN public.orient_sheets.last_edited_by IS
  '[539] 마지막으로 저장·제출한 로그인 계정 번호(auth.uid). 토큰 폼 저장은 NULL. 외래 키 없음 — 계정이 지워져도 행 보존. 이름은 사본으로 두지 않고 읽을 때 계정 표에서 찾는다';

-- ------------------------------------------------------------
-- [2] _orient_save_core — 본문 = 538 save_orient_draft (조회만 시트 번호 + 성공 UPDATE 에 저장자 칸)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_save_core(
  p_sheet_id uuid,
  p_data     jsonb,
  p_version  int,
  p_editor   uuid
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
   WHERE id = p_sheet_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
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
    --   [539] 작성본을 비우는 갈래도 「저장에 성공한 것」이라 저장자 칸을 찍는다.
    IF v_data = v_sheet.data THEN
      UPDATE public.orient_sheets
         SET draft_data     = NULL,
             draft_saved_at = NULL,
             version        = v_sheet.version + 1,
             last_edited_at = now(),
             last_edited_by = p_editor
       WHERE id      = v_sheet.id
         AND version = p_version;
    ELSE
      UPDATE public.orient_sheets
         SET draft_data     = v_data,
             draft_saved_at = now(),
             version        = v_sheet.version + 1,
             last_edited_at = now(),
             last_edited_by = p_editor
       WHERE id      = v_sheet.id
         AND version = p_version;
    END IF;
  ELSE
    -- 작성 중(draft) — 425 그대로 data 에 쓴다(미제출 시트는 발행 대상이 아니다).
    UPDATE public.orient_sheets
       SET data           = v_data,
           version        = v_sheet.version + 1,
           last_edited_at = now(),
           last_edited_by = p_editor
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

GRANT  EXECUTE ON FUNCTION public._orient_save_core(uuid, jsonb, int, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._orient_save_core(uuid, jsonb, int, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_save_core(uuid, jsonb, int, uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_save_core(uuid, jsonb, int, uuid) IS
  '[539, 베이스 538 save_orient_draft] 오리엔시트 임시저장 본체 — 시트 번호로 찾는다(없으면 not_found). 토큰 함수 save_orient_draft 와 '
  '로그인 계정 함수가 같은 본체를 부른다. 성공한 UPDATE(세 갈래 모두)에 last_edited_at=now(), last_edited_by=p_editor(토큰 폼은 NULL). '
  '거부 경로(기한·충돌·크기 등)는 저장자 칸을 건드리지 않는다. 기한 갈래는 538(draft 만 expired). 내부 전용 — 실행 권한 없음. 🔴 다음 재정의의 베이스는 539.';

-- ------------------------------------------------------------
-- [3] _orient_submit_core — 본문 = 538 submit_orient_sheet + 저장자 칸 + [539] 3차 ①-5
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_submit_core(
  p_sheet_id uuid,
  p_data     jsonb,
  p_version  int,
  p_editor   uuid
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
  -- [539] 3차 ①-5 — 견적 계산 블록 진입 전 v_data 보관 + 예외 갈래의 이력 옮기기용
  v_data_before  jsonb;
  v_prev_quote   jsonb;
  v_history      jsonb;
BEGIN
  SELECT id, brand_id, application_id, form_type, orient_no, token_expires_at,
         status, version, submitted_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_sheet_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
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
  --   본문은 _orient_compute_quote(현재 원본 463) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
  --   블록 전체를 예외 보호로 감싼다 — 지금 못 본 예외(기준값 표가 이상해지는 등)가 생겨도 「제출은 통과」가 구조로 보장된다.
  IF v_is_new AND v_card0 IS NOT NULL THEN
   -- [539] 블록 진입 전 값을 보관 — PL/pgSQL 변수는 예외로 되돌려지지 않는다
   v_data_before := v_data;
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
    -- [539·①-5] 직전 quote 를 지우기 전에 quote_history 끝에 붙인다 — _orient_compute_quote(463)의 정상 경로와 같은 방식.
    --   v_data 는 블록 진입 전 값으로 되돌린 뒤 시작한다(계산 도중 일부 대입이 됐을 가능성 차단).
    v_data := v_data_before;
    v_prev_quote := v_data -> 'quote';
    IF v_prev_quote IS NOT NULL AND jsonb_typeof(v_prev_quote) = 'object' THEN
      v_history := COALESCE(v_data -> 'quote_history', '[]'::jsonb);
      IF jsonb_typeof(v_history) <> 'array' THEN v_history := '[]'::jsonb; END IF;
      v_history := v_history || jsonb_build_array(v_prev_quote);
      v_data := jsonb_set(v_data, ARRAY['quote_history'], v_history, true);
    END IF;
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
         draft_saved_at    = NULL,
         -- [539] 저장자 칸 — 제출 성공 때만
         last_edited_at    = v_now,
         last_edited_by    = p_editor
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

GRANT  EXECUTE ON FUNCTION public._orient_submit_core(uuid, jsonb, int, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._orient_submit_core(uuid, jsonb, int, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_submit_core(uuid, jsonb, int, uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_submit_core(uuid, jsonb, int, uuid) IS
  '[539, 베이스 538 submit_orient_sheet] 오리엔시트 제출 본체 — 시트 번호로 찾는다(없으면 not_found). 토큰 함수 submit_orient_sheet 와 로그인 계정 함수가 '
  '같은 본체를 부른다. 성공 UPDATE 에 last_edited_at=now(), last_edited_by=p_editor(토큰 폼은 NULL). '
  '[539·3차 ①-5] 견적 계산 예외 갈래가 quote 를 지우기 전에 직전 quote(객체면)를 quote_history 끝에 붙인다(블록 진입 전 v_data 를 보관해 되돌린 뒤 처리). '
  '그 밖 본문(보정 세 단계·cards_limit·최소 인원·글자 수 검사·고정 안내 확인·견적 계산 463·기한 538)은 538 과 같다. 내부 전용 — 실행 권한 없음. 🔴 다음 재정의의 베이스는 539.';

-- ------------------------------------------------------------
-- [4] _orient_preview_core — 본문 = 430 [C] preview_orient_quote (조회만 시트 번호)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_preview_core(p_sheet_id uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet record;
  v_data  jsonb;
  v_calc  jsonb;
  v_now   timestamptz := now();
BEGIN
  SELECT orient_no, token_expires_at, status, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_sheet_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;
  IF octet_length(p_data::text) > 102400 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_too_large');
  END IF;

  -- 서버 키(issued·quote·quote_history)는 저장값 기준 — 제출과 같은 판 번호가 나온다
  v_data := public._orient_apply_issued_rules(p_data, v_sheet.data);
  IF (v_data -> 'issued') IS NULL OR jsonb_typeof(v_data -> 'issued') <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_new_layout');
  END IF;
  IF jsonb_typeof(v_data -> 'cards') <> 'array' OR jsonb_array_length(v_data -> 'cards') < 1
     OR jsonb_typeof(v_data -> 'cards' -> 0) <> 'object' THEN
    RETURN jsonb_build_object('success', true, 'quote', NULL, 'quote_error', 'slots_missing');
  END IF;

  BEGIN
    v_calc := public._orient_compute_quote(v_data, v_sheet.orient_no, v_sheet.token_expires_at, v_now);
    RETURN jsonb_build_object(
      'success',     true,
      'quote',       CASE WHEN jsonb_typeof(v_calc -> 'quote') = 'object' THEN v_calc -> 'quote' ELSE NULL END,
      'quote_error', v_calc ->> 'quote_error'
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[preview_orient_quote] quote calc failed for %: % (%)', v_sheet.orient_no, SQLERRM, SQLSTATE;
    RETURN jsonb_build_object('success', true, 'quote', NULL, 'quote_error', 'calc_error');
  END;
END;
$$;

GRANT  EXECUTE ON FUNCTION public._orient_preview_core(uuid, jsonb) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._orient_preview_core(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_preview_core(uuid, jsonb) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_preview_core(uuid, jsonb) IS
  '[539, 베이스 430 [C] preview_orient_quote] 제출 전 견적 미리보기 본체 — 시트 번호로 찾는다(없으면 not_found). 저장 없음. 토큰 함수 preview_orient_quote 와 '
  '로그인 계정 함수가 같은 본체를 부른다. 내부 전용 — 실행 권한 없음. 🔴 다음 재정의의 베이스는 539.';

-- ------------------------------------------------------------
-- [5] _orient_tier_fees_core — 본문 = 489 get_orient_tier_fees (조회만 시트 번호). STABLE 유지
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_tier_fees_core(p_sheet_id uuid)
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
  v_opt_fees    jsonb;     -- [489] 리뷰어 추가 옵션 금액 — {"lips":N,"cosme":N}(행 없는 키는 생략, 시딩은 {})
  v_now         timestamptz := now();
BEGIN
  -- 시트 검사 — preview_orient_quote(430)와 같은 순서
  SELECT s.token_expires_at, s.status, s.data
    INTO v_sheet
    FROM public.orient_sheets s
   WHERE s.id = p_sheet_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
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

  -- [489] 리뷰어 추가 옵션(LIPS·@cosme) 금액 — _orient_compute_quote(463) 의 v_basis 읽기와 같은 출처·같은 키
  --   (reviewer_option_fee_krw_lips / _cosme). 모집비 직접 지정과 무관한 기준값이라 **두 반환 경로 모두** 싣는다.
  --   행이 없는 키는 생략(0 은 값이므로 넣는다). 시딩은 옵션이 없어 빈 객체.
  IF v_ft = 'reviewer' THEN
    SELECT COALESCE(jsonb_object_agg(
             CASE q.key WHEN 'reviewer_option_fee_krw_lips' THEN 'lips' ELSE 'cosme' END,
             q.amount), '{}'::jsonb)
      INTO v_opt_fees
      FROM public.quote_settings q
     WHERE q.key IN ('reviewer_option_fee_krw_lips', 'reviewer_option_fee_krw_cosme');
  ELSE
    v_opt_fees := '{}'::jsonb;
  END IF;

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
                              'names', v_names, 'options', v_options,
                              'option_fees', v_opt_fees);
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
                            'names', v_names, 'options', v_options,
                              'option_fees', v_opt_fees);
END;
$$;

GRANT  EXECUTE ON FUNCTION public._orient_tier_fees_core(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._orient_tier_fees_core(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_tier_fees_core(uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_tier_fees_core(uuid) IS
  '[539, 베이스 489 get_orient_tier_fees] 오리엔시트 작성 폼용 구간 조회 본체 — 시트 번호로 찾는다(없으면 not_found). 읽기 전용(STABLE). '
  '토큰 함수 get_orient_tier_fees 와 로그인 계정 함수가 같은 본체를 부른다. 내부 전용 — 실행 권한 없음. 🔴 다음 재정의의 베이스는 539.';

-- ------------------------------------------------------------
-- [6] _orient_brand_view_status — 브랜드 화면 상태 판정(결정 1·3·4). 리스트·카드·모바일·상세가 이 값만 쓴다
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._orient_brand_view_status(
  p_status         text,
  p_deadline       timestamptz,
  p_data           jsonb,
  p_last_edited_at timestamptz,
  p_version        int
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- ① 등록 — 전 카드 등록(consumed)이거나 등록된 카드가 하나라도 있으면(옛 구조 일부 등록 포함 — 결정 4).
  --    등록이 기한보다 앞: 캠페인이 등록된 시트를 기한 뒤에 「만료」로 보이면 진행 중 캠페인이 죽은 것처럼 읽힌다(결정 3).
  IF p_status = 'consumed' THEN
    RETURN 'registered';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(p_data -> 'cards') = 'array' THEN p_data -> 'cards' ELSE '[]'::jsonb END
           ) c
     WHERE jsonb_typeof(c) = 'object'
       AND COALESCE(c ->> 'campaign_id', '') <> ''
  ) THEN
    RETURN 'registered';
  END IF;

  -- ② 만료 — status 가 expired 이거나 기한이 지남(제출된 시트도 — 538 이후 제출 시트는 기한 뒤에도 status 가 submitted 로 남는다)
  IF p_status = 'expired' OR (p_deadline IS NOT NULL AND p_deadline < now()) THEN
    RETURN 'expired';
  END IF;

  -- ③ 제출됨
  IF p_status = 'submitted' THEN
    RETURN 'submitted';
  END IF;

  -- ④ 작성 중 — 저장 기록이 없고 발급 직후 version(0)이면 신규, 아니면 작성 중
  IF p_status = 'draft' THEN
    IF p_last_edited_at IS NULL AND COALESCE(p_version, 0) = 0 THEN
      RETURN 'new';
    END IF;
    RETURN 'editing';
  END IF;

  -- 알 수 없는 status(CHECK 제약 draft|submitted|consumed|expired 때문에 실제로는 도달하지 않는다) —
  -- 쓸 수 있는 상태로 보이면 화면이 저장을 시도하다 막히므로 가장 보수적인 읽기 전용 값으로 둔다.
  RETURN 'expired';
END;
$$;

GRANT  EXECUTE ON FUNCTION public._orient_brand_view_status(text, timestamptz, jsonb, timestamptz, int) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._orient_brand_view_status(text, timestamptz, jsonb, timestamptz, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._orient_brand_view_status(text, timestamptz, jsonb, timestamptz, int) FROM anon, authenticated;

COMMENT ON FUNCTION public._orient_brand_view_status(text, timestamptz, jsonb, timestamptz, int) IS
  '[539] 브랜드 화면 상태 판정 — new|editing|submitted|registered|expired. 우선순위: registered(consumed 이거나 data.cards 에 campaign_id 가 비지 않은 카드가 하나라도 — 옛 구조 일부 등록 포함) → '
  'expired(status=expired 이거나 기한 지남 — 제출된 시트도) → submitted → draft 는 last_edited_at 없음 AND version=0(발급 직후) 이면 new, 아니면 editing. '
  'STABLE(now 비교). 알 수 없는 status 는 expired(읽기 전용). 내부 전용 — 실행 권한 없음. 🔴 화면은 이 값만 쓴다(사본 금지). 다음 재정의의 베이스는 539.';

-- ------------------------------------------------------------
-- [7] 토큰 함수 넷 — 「토큰 → 시트 번호」만 하고 본체를 부른다. 인자·결과 키·invalid_token·권한·변동성 그대로
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
  v_id  uuid;
  v_res jsonb;
BEGIN
  SELECT id INTO v_id FROM public.orient_sheets WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  v_res := public._orient_save_core(v_id, p_data, p_version, NULL);

  -- 조회와 잠금 사이에 시트가 지워진 경우 — 토큰 입장에서는 죽은 토큰
  IF v_res @> '{"success": false, "reason": "not_found"}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328, 329, 425, 524, 538, 539 개정] 오리엔시트 임시저장(토큰 폼). anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '[539] 토큰 → 시트 번호만 하고 본체 _orient_save_core 를 부른다(저장자는 NULL). 본체가 not_found 면 invalid_token. '
  '본문(만료·consumed 차단·보정 세 단계·100KB·낙관적 락·제출 시트는 draft_data 에·기한 지난 draft 만 expired)은 _orient_save_core 에 있다. '
  'SECURITY DEFINER + search_path 고정. 🔴 다음 재정의의 베이스는 539 (본문을 고칠 때는 _orient_save_core).';

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
  v_id  uuid;
  v_res jsonb;
BEGIN
  SELECT id INTO v_id FROM public.orient_sheets WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  v_res := public._orient_submit_core(v_id, p_data, p_version, NULL);

  -- 조회와 잠금 사이에 시트가 지워진 경우 — 토큰 입장에서는 죽은 토큰
  IF v_res @> '{"success": false, "reason": "not_found"}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446, 459, 461, 524, 538, 539 개정] 오리엔시트 제출(토큰 폼). anon GRANT. '
  '[539] 토큰 → 시트 번호만 하고 본체 _orient_submit_core 를 부른다(저장자는 NULL). 본체가 not_found 면 invalid_token. '
  '본문(보정 세 단계 → issued 시트만 cards_limit·최소 인원(461)·글자 수(425·429) → 고정 안내 확인(446) → 견적 계산(_orient_compute_quote 463, '
  '예외 갈래는 직전 견적을 quote_history 로 — 539) → 크기·낙관적 락 → 성공 시 작성본 비움(524)·저장자 칸(539)·기한 지난 draft 만 expired(538))은 _orient_submit_core 에 있다. '
  '🔴 다음 재정의의 베이스는 539 (본문을 고칠 때는 _orient_submit_core).';

CREATE OR REPLACE FUNCTION public.preview_orient_quote(p_token uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id  uuid;
  v_res jsonb;
BEGIN
  SELECT id INTO v_id FROM public.orient_sheets WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  v_res := public._orient_preview_core(v_id, p_data);

  -- 조회와 본체 사이에 시트가 지워진 경우 — 토큰 입장에서는 죽은 토큰
  IF v_res @> '{"success": false, "reason": "not_found"}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.preview_orient_quote(uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.preview_orient_quote(uuid, jsonb) TO anon, authenticated;

COMMENT ON FUNCTION public.preview_orient_quote(uuid, jsonb) IS
  '[430, 539 개정] 오리엔시트 제출 전 견적 미리보기(토큰 폼) — 살아 있는 토큰 + 지금 화면 값으로 _orient_compute_quote 를 돌려 quote/quote_error 만 돌려준다. 저장 없음. anon GRANT. '
  '[539] 토큰 → 시트 번호만 하고 본체 _orient_preview_core 를 부른다. 본체가 not_found 면 invalid_token. 🔴 다음 재정의의 베이스는 539 (본문을 고칠 때는 _orient_preview_core).';

CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id  uuid;
  v_res jsonb;
BEGIN
  SELECT s.id INTO v_id FROM public.orient_sheets s WHERE s.token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  v_res := public._orient_tier_fees_core(v_id);

  -- 조회와 본체 사이에 시트가 지워진 경우 — 토큰 입장에서는 죽은 토큰
  IF v_res @> '{"success": false, "reason": "not_found"}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  RETURN v_res;
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[489, 539 개정] 오리엔시트 작성 폼용(토큰 폼) — 살아 있는 토큰의 구간 단가·경계·최소 인원·이름·옵션 문구·추가 옵션 금액(option_fees)을 돌려준다. 읽기 전용(STABLE). anon GRANT. '
  '[539] 토큰 → 시트 번호만 하고 본체 _orient_tier_fees_core(베이스 489)를 부른다. 본체가 not_found 면 invalid_token. '
  '🔴 다음 재정의의 베이스는 539 (본문을 고칠 때는 _orient_tier_fees_core).';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 개발서버 확인 (개발 DB SQL 편집기 — 한 단계씩 실행하고 결과를 본 뒤 다음으로. 이 아래는 전부 주석)
-- ============================================================
/*
-- [V1] 칸 둘 존재 (기대: 2행 — last_edited_at timestamp with time zone / last_edited_by uuid, 둘 다 YES)
SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='orient_sheets' AND column_name IN ('last_edited_at','last_edited_by')
 ORDER BY column_name;

-- [V2] 함수 아홉(본체 넷 + 판정 + 토큰 넷)의 권한
--   기대: 내부 다섯(_orient_*)은 proacl 에 anon·authenticated 없음, 맨 앞 '=X/' 없음(public_granted=false), postgres·service_role 있음.
--         토큰 넷은 기존과 같음 — save_orient_draft·submit_orient_sheet 는 anon 만, preview_orient_quote·get_orient_tier_fees 는 anon·authenticated,
--         넷 다 맨 앞 '=X/' 없음.
SELECT p.proname, p.provolatile AS volatility, p.proacl::text AS proacl, (p.proacl::text LIKE '{=X/%') AS public_granted
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public'
   AND p.proname IN ('_orient_save_core','_orient_submit_core','_orient_preview_core','_orient_tier_fees_core','_orient_brand_view_status',
                     'save_orient_draft','submit_orient_sheet','preview_orient_quote','get_orient_tier_fees')
 ORDER BY p.proname;
--   volatility 기대: _orient_tier_fees_core·_orient_brand_view_status·get_orient_tier_fees = 's'(STABLE), 나머지 = 'v'.

-- [V3] 판정 함수 시나리오 (기대 열 expected 와 got 이 모두 같음)
SELECT label, expected, got, (expected = got) AS ok FROM (
  SELECT 'new: 발급 직후'          AS label, 'new'        AS expected, public._orient_brand_view_status('draft',     now() + interval '1 day', '{"cards":[{}]}'::jsonb, NULL, 0) AS got
  UNION ALL SELECT 'editing: 저장 기록 있음',        'editing',    public._orient_brand_view_status('draft',     now() + interval '1 day', '{}'::jsonb, now(), 3)
  UNION ALL SELECT 'editing: 기록 없어도 version>0', 'editing',    public._orient_brand_view_status('draft',     now() + interval '1 day', '{}'::jsonb, NULL, 2)
  UNION ALL SELECT 'submitted',                      'submitted',  public._orient_brand_view_status('submitted', now() + interval '1 day', '{"cards":[{"campaign_id":""}]}'::jsonb, now(), 5)
  UNION ALL SELECT 'registered: consumed',           'registered', public._orient_brand_view_status('consumed',  now() - interval '1 day', '{}'::jsonb, now(), 5)
  UNION ALL SELECT 'registered: 옛 구조 일부 등록(제출됨)', 'registered', public._orient_brand_view_status('submitted', now() + interval '1 day', '{"cards":[{"campaign_id":"11111111-1111-1111-1111-111111111111"},{}]}'::jsonb, now(), 5)
  UNION ALL SELECT 'registered: 일부 등록 + 기한 지남', 'registered', public._orient_brand_view_status('submitted', now() - interval '1 day', '{"cards":[{"campaign_id":"x"},{}]}'::jsonb, now(), 5)
  UNION ALL SELECT 'expired: status',                'expired',    public._orient_brand_view_status('expired',   now() + interval '1 day', '{}'::jsonb, NULL, 0)
  UNION ALL SELECT 'expired: 기한 지난 draft',       'expired',    public._orient_brand_view_status('draft',     now() - interval '1 day', '{}'::jsonb, NULL, 0)
  UNION ALL SELECT 'expired: 기한 지난 제출 시트',   'expired',    public._orient_brand_view_status('submitted', now() - interval '1 day', '{"cards":[{}]}'::jsonb, now(), 5)
  UNION ALL SELECT 'data NULL 안전',                 'editing',    public._orient_brand_view_status('draft',     NULL, NULL, now(), 1)
  UNION ALL SELECT 'campaign_id JSON null 은 미등록', 'submitted',  public._orient_brand_view_status('submitted', NULL, '{"cards":[{"campaign_id":null}]}'::jsonb, now(), 1)
) t;

-- [V4] 내부 함수 넷 — 존재하지 않는 시트 번호로 1회씩 실제 호출 (기대: 네 줄 모두 {"success": false, "reason": "not_found"})
SELECT '_orient_save_core'      AS fn, public._orient_save_core('00000000-0000-0000-0000-000000000000'::uuid, '{}'::jsonb, 0, NULL) AS result
UNION ALL SELECT '_orient_submit_core',    public._orient_submit_core('00000000-0000-0000-0000-000000000000'::uuid, '{"a":1}'::jsonb, 0, NULL)
UNION ALL SELECT '_orient_preview_core',   public._orient_preview_core('00000000-0000-0000-0000-000000000000'::uuid, '{}'::jsonb)
UNION ALL SELECT '_orient_tier_fees_core', public._orient_tier_fees_core('00000000-0000-0000-0000-000000000000'::uuid);

-- [V5] 토큰 함수 넷 — 엉터리 토큰 (기대: 네 줄 모두 {"success": false, "reason": "invalid_token"})
SELECT 'save_orient_draft'     AS fn, public.save_orient_draft('00000000-0000-0000-0000-000000000000'::uuid, '{}'::jsonb, 0) AS result
UNION ALL SELECT 'submit_orient_sheet',   public.submit_orient_sheet('00000000-0000-0000-0000-000000000000'::uuid, '{"a":1}'::jsonb, 0)
UNION ALL SELECT 'preview_orient_quote',  public.preview_orient_quote('00000000-0000-0000-0000-000000000000'::uuid, '{}'::jsonb)
UNION ALL SELECT 'get_orient_tier_fees',  public.get_orient_tier_fees('00000000-0000-0000-0000-000000000000'::uuid);

-- [V6] 실제 시트로 저장 → 미리보기 → 제출 → 재저장 → 재제출 (개발 DB 전용 — 시험 시트를 고른다)
--   ⚠️ 개발 프로젝트에는 orient_sheets 의 모든 UPDATE 에 notify-orient-submitted 웹훅(관리자 메일)이 걸려 있다(2026-10-16 확인 —
--      pg_trigger 의 「orient-submitted-notify」). 개발서버는 메일 발송 시험 금지 정책이므로 아래 6-3~6-7 은 단계별로 따로 돌리지 말고
--      [V7](b) 처럼 한 DO 블록 안에서 부른 뒤 끝에 RAISE EXCEPTION 으로 결과를 던져 통째로 되돌린다(pg_net 대기열도 함께 롤백).
--      제출 성공을 보려면 시험 data 에 jsonb_set(…, '{notice_ack_checked}', 'true') 를 넣는다(없으면 notice_not_acknowledged).
--   6-0) 시험 시트 고르기 — 새 구조(issued 있음) · 아직 안 만료 · draft · 저장 기록 없음:
--     SELECT id, token, orient_no, status, version, token_expires_at, last_edited_at, last_edited_by
--       FROM public.orient_sheets
--      WHERE status='draft' AND data ? 'issued' AND token_expires_at > now()
--      ORDER BY created_at DESC LIMIT 5;
--   6-1) 원래 값 보관 (결과 한 칸의 JSON 을 통째로 복사해 둔다 — 원복에 쓴다):
--     SELECT to_jsonb(s) FROM public.orient_sheets s WHERE id = '<시험 시트 id>';
--   6-2) 판정 확인 (기대: 'new' — version 0·저장 기록 없음):
--     SELECT public._orient_brand_view_status(status, token_expires_at, data, last_edited_at, version) FROM public.orient_sheets WHERE id='<id>';
--   6-3) 저장 (토큰 폼과 같은 호출. 현재 version 을 넣는다):
--     SELECT public.save_orient_draft('<token>'::uuid, (SELECT data FROM public.orient_sheets WHERE id='<id>'), <현재 version>);
--     → {"success":true,"version":<+1>,"card_uids":[...]}
--     SELECT last_edited_at, last_edited_by, version FROM public.orient_sheets WHERE id='<id>';
--     → last_edited_at 이 방금 시각, last_edited_by 는 NULL(토큰 폼). 판정은 'editing'.
--   6-4) 미리보기 (저장 없음 — version·last_edited_at 이 안 바뀌어야 한다):
--     SELECT public.preview_orient_quote('<token>'::uuid, (SELECT data FROM public.orient_sheets WHERE id='<id>'));
--     SELECT public.get_orient_tier_fees('<token>'::uuid);
--   6-5) 제출 (작성 내용이 제출 조건을 채운 시트일 때만 성공 — 모자라면 거부 사유가 그대로 나오는 것도 정상):
--     SELECT public.submit_orient_sheet('<token>'::uuid, (SELECT data FROM public.orient_sheets WHERE id='<id>'), <현재 version>);
--     → success=true 이면 status='submitted', last_edited_at 갱신, last_edited_by NULL, 판정 'submitted'.
--   6-6) 제출 뒤 재저장 → draft_data 에 쓰이고 판정은 그대로 'submitted'(작성본만 생김), last_edited_at 갱신:
--     SELECT public.save_orient_draft('<token>'::uuid, <data 에서 글자 하나 바꾼 jsonb>, <현재 version>);
--   6-7) 재제출 → draft_data 비워짐, last_edited_at 갱신.
--   6-8) 원복 (6-1 에서 복사한 JSON 을 아래 '…' 에 붙인다. 이 시험이 바꾸는 열만 되돌린다):
--     UPDATE public.orient_sheets o
--        SET data = r.data, status = r.status, version = r.version, submitted_at = r.submitted_at,
--            last_submitted_at = r.last_submitted_at, draft_data = r.draft_data, draft_saved_at = r.draft_saved_at,
--            last_edited_at = r.last_edited_at, last_edited_by = r.last_edited_by, token_expires_at = r.token_expires_at
--       FROM jsonb_populate_record(NULL::public.orient_sheets, '<6-1 의 JSON>'::jsonb) r
--      WHERE o.id = r.id;

-- [V7] 3차 ①-5 — 견적 계산 예외 갈래는 실제로 일으키기 어렵다. 두 가지로 확인한다.
--   (a) 정상 경로: 판매가에 글자를 넣은 시트를 제출하면 quote_error='price_unreadable' 이 되고 직전 quote 가 quote_history 에 남는다
--       (463 _orient_compute_quote 가 이미 하던 일 — 같은 방식을 예외 갈래가 따라 한다는 기준선).
--   (b) 예외 갈래 자체 — 되돌려지는 시험. 한 번의 DO 블록이 계산 함수를 일부러 터지는 것으로 바꿔 제출하고,
--       결과를 오류 메시지로 던져 **전체를 자동 롤백**한다(함수 교체·시트 변경·웹훅 대기열 모두 남지 않음).
--       ⚠️ 개발 DB 전용. 시험 시트는 이미 제출돼 quote 가 있는 새 구조 시트(status='submitted' · 기한 안)여야 한다 —
--          SELECT id, token FROM public.orient_sheets WHERE status='submitted' AND data ? 'issued' AND data ? 'quote' AND token_expires_at > now() LIMIT 5;
--       기대: 메시지의 hist_before 가 N, hist_after 가 N+1, has_quote_after=false, quote_error_after='calc_error', ok=true.
DO $do$
DECLARE
  v_id uuid := '<시험 시트 id>';
  v_before jsonb; v_res jsonb; v_after jsonb; v_ver int;
BEGIN
  SELECT data, version INTO v_before, v_ver FROM public.orient_sheets WHERE id = v_id;
  EXECUTE $f$
    CREATE OR REPLACE FUNCTION public._orient_compute_quote(p_data jsonb, p_orient_no text, p_valid_until timestamptz, p_now timestamptz)
    RETURNS jsonb LANGUAGE plpgsql AS $b$ BEGIN RAISE EXCEPTION 'forced for test'; END; $b$
  $f$;
  v_res := public._orient_submit_core(v_id, v_before, v_ver, NULL);
  SELECT data INTO v_after FROM public.orient_sheets WHERE id = v_id;
  RAISE EXCEPTION 'RESULT ok=% hist_before=% hist_after=% has_quote_after=% quote_error_after=% res_quote_error=%',
    (v_res->>'success'),
    COALESCE(jsonb_array_length(v_before->'quote_history'), 0),
    COALESCE(jsonb_array_length(v_after->'quote_history'), 0),
    (v_after ? 'quote'),
    (v_after->>'quote_error'),
    (v_res->>'quote_error');
END
$do$;
--   (c) 코드 대조: _orient_submit_core 의 EXCEPTION 갈래가 v_data := v_data_before → quote_history 끝에 v_prev_quote 추가 → quote 제거 순서인지,
--       463 의 「이전 판 → 이력」 블록(v_prev_quote / v_history 조립)과 같은 모양인지 눈으로 대조.
*/
