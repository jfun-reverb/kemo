-- 445_orient_preserve_notice_ack.sql
-- 서버가 지키는 키를 넷에서 다섯으로 — `notice_ack`(브랜드 고정 안내 확인 기록) 추가.
-- 사양서: docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-8 (결정 10)
-- 작업표: docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 작업 3 (마이그레이션 ③ — ④보다 먼저)
--
-- ── 무엇을 하나 ──────────────────────────────────────────────────────────
-- `_orient_apply_issued_rules(p_data, p_saved)`(🔴 베이스 **425** — 이 함수를 정의한 파일은 425 하나뿐이다)의
-- 보존 키 목록에 `notice_ack` 를 더한다. **그 한 줄 말고는 425 와 글자 그대로 같다.**
--
-- 이 헬퍼를 `save_orient_draft`·`submit_orient_sheet` 가 **이름으로** 부르므로, 헬퍼만 바꾸면 두 함수에 자동 반영된다
-- (두 함수를 다시 정의할 필요가 없다 — 431 이 견적 계산 헬퍼에서 쓴 것과 같은 방법).
--
-- ── 왜 서버가 지켜야 하나 ────────────────────────────────────────────────
-- `notice_ack` 는 「브랜드가 이 안내문을 확인했다」는 **기록**이고 시각은 서버가 찍는다(브라우저 값은 근거가 못 된다 — 420 선례).
-- 보존 목록에 없으면 ①브랜드 폼이 임의의 `notice_ack` 를 만들어 보낼 수 있고
-- ②옛 캐시 폼이 그 키를 모른 채 한 번 저장하면 **확인 기록이 조용히 사라진다**(424~425 가 `issued` 에서 막은 것과 같은 유형).
--
-- ⚠️ 이 파일만 넣으면 아무 일도 안 일어난다 — `notice_ack` 를 **쓰는** 것은 446 이다.
--    그 전까지는 저장된 값이 없으므로 「들어온 값도 지운다」 갈래만 돈다(폼은 아직 그 키를 보내지 않는다).
--
-- 권한: CREATE OR REPLACE 라 425 의 회수(PUBLIC · anon·authenticated 두 방향)가 그대로 남는다.
--       그래도 같은 회수를 다시 적는다(이 저장소 관례 — 회수 방향이 둘이라 하나만 남는 사고를 막는다, 369·370).
--
-- 롤백: 425 의 같은 함수 블록을 다시 실행(보존 키 넷으로 돌아간다). 446 을 먼저 되돌릴 것 —
--       446 이 살아 있는데 이것만 되돌리면 확인 기록이 다음 임시저장에 지워져 **제출할 때마다 다시 체크**해야 한다.

BEGIN;

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
  --    (브랜드 폼이 이 키를 만들 권한이 없다. 견적 3종은 제출 함수가 이 보존 **뒤에** 스스로 새로 쓴다.)
  --    [445] 다섯 번째 키 notice_ack — 고정 안내 확인 기록(서버 시각). 제출 함수(446)가 이 보존 **뒤에** 쓴다.
  --    🔴 폼이 보내는 notice_ack_checked(참·거짓)는 여기 없다 — 브랜드가 체크한 사실 자체라 보존 대상이 아니다.
  FOREACH v_key IN ARRAY ARRAY['issued', 'quote', 'quote_history', 'quote_error', 'notice_ack'] LOOP
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
  '[425, 445 개정] 서버 키 5종(issued·quote·quote_history·quote_error·notice_ack) 보존 + issued 시트의 형식·채널 원본을 cards[0] 에 덮어쓰기. '
  'save_orient_draft·submit_orient_sheet 공용. 내부 전용(실행 권한 전부 회수). 🔴 다음 재정의의 베이스는 445.';

-- 내부 전용 함수라 없어도 동작하지만 이 계열(293·431·443)의 관례를 따른다
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (적용 직후 — 순수 함수라 표를 안 건드린다)
-- ══════════════════════════════════════════════════════════════════════
--
-- [V1] 저장된 notice_ack 는 되살아나고, 폼이 멋대로 보낸 notice_ack 는 지워진다
--
--   SELECT
--     public._orient_apply_issued_rules(
--       '{"cards":[]}'::jsonb,
--       '{"issued":{"form_type":"reviewer"},"notice_ack":{"version":1,"at":"2026-09-17T00:00:00Z","form_type":"reviewer"}}'::jsonb
--     ) -> 'notice_ack' AS 되살아남,           -- 기대: {"at": "...", "version": 1, "form_type": "reviewer"}
--     public._orient_apply_issued_rules(
--       '{"cards":[],"notice_ack":{"version":1,"at":"1999-01-01T00:00:00Z"},"notice_ack_checked":true}'::jsonb,
--       '{"issued":{"form_type":"reviewer"}}'::jsonb
--     ) AS 위조_지워짐;                         -- 기대: notice_ack 키 없음 · notice_ack_checked 는 true 그대로 · issued 는 되살아남
--
-- [V2] 권한 — 세 값 모두 false 여야 한다(내부 전용)
--
--   SELECT has_function_privilege('anon', 'public._orient_apply_issued_rules(jsonb, jsonb)', 'EXECUTE') AS anon_,
--          has_function_privilege('authenticated', 'public._orient_apply_issued_rules(jsonb, jsonb)', 'EXECUTE') AS auth_,
--          (SELECT proacl::text FROM pg_proc WHERE oid = 'public._orient_apply_issued_rules(jsonb, jsonb)'::regprocedure) AS acl;
--   -- 기대: false / false / acl 맨 앞에 「=X/」 가 없다(PUBLIC 부여 없음)
