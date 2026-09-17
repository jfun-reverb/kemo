-- 446_orient_submit_notice_ack.sql
-- 제출에 「고정 안내 확인」 조건을 더하고, 통과하면 서버가 확인 기록을 쓴다.
-- 사양서: docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-8 (결정 10)
-- 작업표: docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 작업 3 (마이그레이션 ④ — ③[445] 뒤에)
--
-- ── 무엇을 하나 ──────────────────────────────────────────────────────────
-- submit_orient_sheet(🔴 베이스 **430** — 187→202→293→328→329→425→427→429→**430**. 443 은 견적 헬퍼만 고쳤다)에
--   ① 새 구조(issued 있음) 시트가 확인 기록도 없고 체크도 안 했으면 거부  → reason 'notice_not_acknowledged'
--   ② 통과하면 data.notice_ack = { version: 1, at: 서버 시각, form_type: 발급 형식 } 을 쓴다(이미 있으면 그대로 둔다)
-- 두 블록 말고는 430 과 글자 그대로 같다(파일 하단 「만드는 법」의 diff 로 확인).
--
-- 🔴 445 를 **먼저** 넣는다. 445 없이 이것만 넣으면 notice_ack 가 보존 목록에 없어,
--    다음 임시저장 때 헬퍼가 그 키를 지운다 → 브랜드가 **제출할 때마다 다시 체크**해야 하고 최초 확인 시각도 남지 않는다.
--
-- ── 안 하는 것 ────────────────────────────────────────────────────────────
-- · 임시저장(save_orient_draft)에는 걸지 않는다 — 자동저장이 실패하면 작성 중인 글을 잃는다(425·429 가 글자 수에서 세운 규칙).
-- · 옛 시트(issued 없음)는 검사하지 않는다 — 옛 폼은 이 열쇠말을 모른다(운영 옛 시트가 제출 불능이 된다).
-- · version 을 비교하지 않는다 — 문안을 고쳐도 이미 확인한 시트는 다시 안 묻는다(이번 범위 밖).
--
-- ⚠️ 이 파일이 나가는 순간부터 **이미 제출된 새 구조 시트를 다시 제출하려면 체크가 필요**하다.
--    폼(작업 12)이 같은 배포에 나가야 브랜드가 체크할 자리가 있다 — 운영은 445 → 446 → 폼 순서(사양서 §7).
--    그 사이 구간에는 옛 폼이 새 구조 시트 제출에서 'notice_not_acknowledged' 를 받고 일반 실패 문구를 띄운다.
--
-- 롤백: 430 의 submit_orient_sheet 블록을 다시 실행. 이미 쓰인 notice_ack 값은 남는다(445 가 지킨다 — 해롭지 않다).

BEGIN;

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
  --   본문은 _orient_compute_quote(430) 한 곳 — 미리보기(preview_orient_quote)와 같은 함수라 두 숫자가 어긋날 수 없다.
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
    'quote_error',         v_quote_error    -- [427] 실패 사유(price_unreadable·slots_missing), 아니면 NULL
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 뒤 권한 재선언 (293·328·329·425·430 과 같은 관례)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329, 425, 427, 429, 430, 446 개정] 오리엔시트 제출. anon GRANT. '
  '_orient_apply_card_uids(293) → _orient_preserve_published_cards(328) → _orient_apply_issued_rules(425·445) → '
  'issued 시트만 cards_limit·guide_too_long·appeal_too_long(425)·text_too_long 4칸(429) → '
  '[446] 고정 안내 확인(notice_ack 도 없고 notice_ack_checked 도 참이 아니면 notice_not_acknowledged 거부, 통과하면 notice_ack={version,at 서버시각,form_type} 최초 1회 기록) → '
  '[427·430] 견적 계산(_orient_compute_quote 공용 — 현재 원본 443). 세트 규칙: 제출마다 quote 또는 quote_error 하나만. 견적 실패도 제출은 통과. '
  '옛 시트는 어느 검사도 받지 않는다. 🔴 다음 재정의의 베이스는 446.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 만드는 법 — 430 과 무엇이 다른지 확인
-- ══════════════════════════════════════════════════════════════════════
--   diff <(awk '/CREATE OR REPLACE FUNCTION public\.submit_orient_sheet/,/^\$\$;/' supabase/migrations/430_orient_quote_preview.sql) \
--        <(awk '/CREATE OR REPLACE FUNCTION public\.submit_orient_sheet/,/^\$\$;/' supabase/migrations/446_orient_submit_notice_ack.sql)
--   → 변수 선언 2줄 + [446] 블록 하나만 나와야 한다.
--
-- ══════════════════════════════════════════════════════════════════════
-- 검증 (개발 DB — 되돌리기 블록 안에서. 사양서 §9-1 11~15번)
-- ══════════════════════════════════════════════════════════════════════
-- 🔴 제출이 성공하면 데이터베이스 웹훅이 관리자 알림 메일을 보낸다. 아래는 전부
--    DO 블록 안에서 **일부러 예외를 던져 되돌린다** — 커밋되지 않으므로 웹훅이 돌지 않는다.
--    <토큰> 자리에 새 구조(data ? 'issued') 이고 status 가 draft·submitted 인 시트의 token 을 넣는다.
--
--   DO $v$
--   DECLARE t uuid := '<토큰>'; ver int; r jsonb; d jsonb;
--   BEGIN
--     SELECT version, data INTO ver, d FROM public.orient_sheets WHERE token = t;
--     -- [11] 체크 없이 제출 → 거부. (확인 기록이 이미 있는 시트면 먼저 지운 사본으로 본다)
--     UPDATE public.orient_sheets SET data = data - 'notice_ack' WHERE token = t;
--     r := public.submit_orient_sheet(t, (d - 'notice_ack' - 'notice_ack_checked'), ver);
--     RAISE NOTICE '[11] %', r;                       -- 기대: reason = notice_not_acknowledged
--     -- [13] 임시저장은 안 막힌다
--     r := public.save_orient_draft(t, (d - 'notice_ack' - 'notice_ack_checked'), ver);
--     RAISE NOTICE '[13] %', r;                       -- 기대: success = true
--     SELECT version, data INTO ver, d FROM public.orient_sheets WHERE token = t;
--     -- [12] 체크하고 제출 + 폼이 위조한 시각을 함께 보낸다 → 서버 시각이 찍혀야 한다
--     r := public.submit_orient_sheet(t,
--            jsonb_set(jsonb_set(d, '{notice_ack_checked}', 'true'), '{notice_ack}', '{"version":9,"at":"1999-01-01T00:00:00Z"}'), ver);
--     RAISE NOTICE '[12] % / 기록 = %', r ->> 'success',
--       (SELECT data -> 'notice_ack' FROM public.orient_sheets WHERE token = t);
--                                                     -- 기대: true / {"at": 지금, "version": 1, "form_type": 그 시트의 형식}
--     -- [15] notice_ack 를 지운 값으로 임시저장 → 되살아난다
--     SELECT version, data INTO ver, d FROM public.orient_sheets WHERE token = t;
--     r := public.save_orient_draft(t, d - 'notice_ack', ver);
--     RAISE NOTICE '[15] 되살아남 = %', (SELECT data ? 'notice_ack' FROM public.orient_sheets WHERE token = t);   -- 기대: t
--     RAISE EXCEPTION '검증 끝 — 일부러 되돌린다';
--   END $v$;
--
-- [14] 옛 시트(data 에 issued 없음)는 체크 없이도 종전대로 통과한다 — 같은 방식(DO + 예외)으로 옛 시트 토큰을 넣어 본다.
