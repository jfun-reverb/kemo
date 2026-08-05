-- ============================================================
-- 293_orient_card_uid_safety_net.sql
-- 2026-08-05
--
-- 목적:
--   오리엔시트 카드에 「고유 번호」(data.cards[].uid)를 심는다.
--   내부 메모가 어느 모집 건에 붙는지를 순번이 아니라 이 번호로 판정하므로,
--   어떤 경로로 저장되든 모든 카드가 번호를 갖고 나오도록 저장 함수가 보정한다.
--
-- 사양서:
--   docs/specs/2026-08-05-orient-sheet-internal-memo.md §설계 1, §의심 2·3
--   작업표  docs/specs/2026-08-05-orient-sheet-internal-memo-breakdown.md 작업 1
--
-- ⚠️ 이 파일은 1단계에서 **가장 먼저** 배포돼야 한다.
--    이게 없는 동안 옛 브랜드 작성 폼이 한 번만 저장해도
--    그 시트의 카드 번호가 통째로 사라진다.
--
-- 변경 내용:
--   [A] public._orient_apply_card_uids(p_data jsonb, p_existing jsonb) → jsonb  (신규)
--       저장 직전 카드 목록을 훑어 번호를 보정하는 순수 계산 함수.
--
--       0) 들어온 uid 값 유효성 정리(3단계 규칙보다 앞서 적용) —
--          문자열이 아니거나·빈 값이거나·공백뿐이면 없는 것으로 취급.
--          배열 안에서 같은 uid 가 두 번 이상 나오면 처음 것만 인정하고
--          나머지는 없는 것으로 취급(한 번호가 두 카드에 겹쳐 붙는 것 방지).
--       1) uid 가 있는 카드는 그대로 둔다
--       2) uid 가 없고 「들어온 카드 개수 = 저장돼 있던 카드 개수」일 때만
--          같은 순서 자리의 기존 uid 를 물려준다(물려줄 값이 이미 이번
--          배열에서 쓰였으면 물려주지 않고 3단계로 넘어간다 — 중복 방지)
--       3) 그래도 빈 자리는 **새 번호**를 만든다
--
--   [B] public.save_orient_draft(uuid, jsonb, int)      → 재정의 (베이스 = 187)
--   [C] public.submit_orient_sheet(uuid, jsonb, int)    → 재정의 (베이스 = **202**)
--       두 함수 모두 조회에 `data` 를 추가하고, UPDATE 직전 [A] 를 거친다.
--
-- ⚠️ 재정의 베이스 확인 (feedback_function_redefine_latest_base):
--   - save_orient_draft   : 187 이 **유일한 정의** → 187 기준
--   - submit_orient_sheet : 187 에서 만들고 **202 에서 재정의**한 것이 최신 →
--                           **202 기준**. 202 가 추가한
--                           last_submitted_at 갱신 · is_first_submission ·
--                           orient_sheet_id · brand_id · form_type · application_id
--                           반환 키를 하나도 빼지 않는다
--                           (제출 알림 Edge Function 이 이 값들을 쓴다).
--
-- 인자 시그니처 불변:
--   (p_token uuid, p_data jsonb, p_version int) — 브랜드 작성 폼이 지금 부르는
--   형태 그대로. 바꾸면 폼이 즉시 죽는다.
--
-- 크기 상한(100KB) 검사 시점 — 결정: **보정(uid 부여) 후 값을 기준으로 검사**한다.
--   이유: 100KB 상한은 "실제로 데이터베이스에 저장되는 값"이 넘지 않아야 한다는
--   가드다. 보정 전 값으로만 검사하면, 보정 전에는 통과했지만 uid 를 붙인 뒤
--   실제 저장값은 상한을 넘는 경우를 걸러내지 못한다.
--   위험 검토 — uid 1개가 늘리는 바이트 수를 어림하면:
--     `,"uid":"` (9바이트) + 32자리 16진수 값 (32바이트) + `"` (1바이트) ≈ 카드당 42바이트.
--   카드 수가 실무상 한 자릿수~십수 개 수준이므로, 카드 20개짜리 시트라도
--   늘어나는 양은 약 840바이트 — 100KB(102,400바이트) 대비 1% 미만이다.
--   "지금까지 되던 저장이 상한 근처에서 갑자기 거부되는" 사고가 나려면 보정 전
--   페이로드가 이미 상한에서 1KB 이내로 붙어 있어야 하는데, 오리엔시트는 브랜드가
--   입력하는 텍스트·이미지 URL 목록 수준이라 그 정도로 상한에 붙는 사례는 현재
--   운영 데이터에서 확인되지 않는다. → 위험은 이론상 존재하나 실질적이지 않다고
--   판단해 "실제 저장값 기준 검사"를 택한다.
--
-- 보안:
--   - 세 함수 모두 SET search_path = ''
--   - ⚠️ CREATE OR REPLACE 는 실행 권한을 초기화하므로 187·202 와 동일하게
--     REVOKE FROM PUBLIC → GRANT TO anon 을 반드시 다시 넣는다.
--     빠뜨리면 브랜드 폼 전체가 즉시 저장 불가.
--   - [A] 는 표를 읽지 않는 순수 계산 함수라 SECURITY DEFINER 가 아니다.
--     PUBLIC 실행 권한만 회수한다(소유자 권한으로 도는 [B]·[C] 는 그대로 호출 가능).
--
-- 운영 데이터 영향:
--   이 파일 자체는 기존 행을 고치지 않는다. 저장이 일어날 때부터 번호가 붙는다.
--   이미 저장돼 있는 시트에 일괄로 번호를 붙이는 것은 다음 마이그레이션(작업 3).
--
-- 적용 순서:
--   이 파일(293) → 브랜드 작성 폼 배포(작업 2) → 기존 데이터 채우기(작업 3)
--
-- 롤백:
--   187 의 save_orient_draft 정의와 202 의 submit_orient_sheet 정의를
--   그대로 다시 올리면 원상복구(인자 형태가 같아 안전).
--   부여된 uid 는 남지만 무해하다(아무도 안 읽으면 그냥 여분 키).
--   DROP FUNCTION IF EXISTS public._orient_apply_card_uids(jsonb, jsonb);
-- ============================================================

BEGIN;


-- ============================================================
-- A. _orient_apply_card_uids — 카드 고유 번호 보정 (순수 계산)
--
--   p_data     : 브랜드 폼이 보낸 저장 대상 데이터
--   p_existing : 현재 저장돼 있는 데이터 (물려주기 재료)
--
--   반환: cards 의 모든 항목에 uid 가 채워진 p_data
--
--   ⚠️ 2단계(물려주기)의 **개수 조건을 절대 빼지 말 것.**
--      조건 없이 물려주면 옛 폼이 카드를 지운 채 저장할 때 번호가 한 칸씩
--      밀려 붙어, 메모가 **아무 표시 없이 엉뚱한 모집 건 아래**에 나타난다.
--      개수 조건을 걸면 그 경우 메모가 눈에 보이게 고아로 빠진다
--      (관리자 상세의 「삭제된 모집 건의 메모」에 모임).
--
--   ⚠️ 0단계(유효성 정리·중복 판정)는 1·2·3단계보다 **먼저** 돈다.
--      - uid 가 문자열이 아니거나·빈 값이거나·공백뿐이면 없는 것으로 취급.
--      - 배열 안에서 같은 uid 가 두 번 이상 나오면 처음 것만 인정.
--        (한 번호가 두 카드에 붙어 메모가 양쪽에 나타나는 것을 막는다)
--      - 2단계에서 물려받으려는 값이 이미 이번 배열에서 쓰였다면
--        물려주지 않고 3단계(새 번호)로 넘어간다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._orient_apply_card_uids(
  p_data     jsonb,
  p_existing jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_cards     jsonb;
  v_old_cards jsonb;
  v_count     int;
  v_old_count int;
  v_inherit   boolean := false;
  v_i         int;
  v_uid       text;
  v_raw       text[] := ARRAY[]::text[];  -- 0단계 유효성 정리 결과. jsonb 0-based 인덱스 i ↔ v_raw[i+1](배열은 1-based)
  v_seen      text[] := ARRAY[]::text[];  -- 이번 저장에서 이미 채택(확정)된 uid 값 — 중복 판정용
BEGIN
  -- 방어: 객체가 아니거나 cards 배열이 없으면 손대지 않는다
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RETURN p_data;
  END IF;

  v_cards := p_data -> 'cards';
  IF v_cards IS NULL OR jsonb_typeof(v_cards) <> 'array' THEN
    RETURN p_data;
  END IF;

  v_count := jsonb_array_length(v_cards);
  IF v_count = 0 THEN
    RETURN p_data;
  END IF;

  -- 물려주기 재료 (저장돼 있던 카드 목록)
  v_old_cards := CASE
                   WHEN p_existing IS NOT NULL
                    AND jsonb_typeof(p_existing -> 'cards') = 'array'
                     THEN p_existing -> 'cards'
                   ELSE '[]'::jsonb
                 END;
  v_old_count := jsonb_array_length(v_old_cards);

  -- 2단계 발동 조건: 들어온 개수 = 저장돼 있던 개수 일 때만.
  -- 개수가 다르면 어느 자리가 밀렸는지 알 수 없으므로 물려주지 않는다.
  v_inherit := (v_old_count = v_count);

  -- ── 0-1차: 들어온 uid 값 유효성 정리 ────────────────────────
  --    문자열이 아니거나(숫자·불리언·객체·배열 등)·빈 값이거나·공백뿐이면
  --    없는 것으로 취급한다. 카드 원소가 객체가 아니면 그 자리는 건드리지
  --    않으므로(아래 최종 루프의 CONTINUE) 자리만 채우고 NULL 로 둔다.
  FOR v_i IN 0 .. v_count - 1 LOOP
    IF jsonb_typeof(v_cards -> v_i) <> 'object' THEN
      v_raw := v_raw || NULL::text;
      CONTINUE;
    END IF;

    IF jsonb_typeof(v_cards -> v_i -> 'uid') = 'string' THEN
      v_raw := v_raw || NULLIF(btrim(v_cards -> v_i ->> 'uid'), '');
    ELSE
      v_raw := v_raw || NULL::text;
    END IF;
  END LOOP;

  -- ── 0-2차: 배열 내부 중복 판정 ───────────────────────────────
  --    같은 uid 가 두 번 이상 나오면 처음 것만 인정, 나머지는 없는 것으로
  --    취급한다(없는 것으로 취급된 자리는 아래 최종 루프에서 2·3단계를 탄다).
  FOR v_i IN 1 .. v_count LOOP
    IF v_raw[v_i] IS NOT NULL THEN
      IF v_raw[v_i] = ANY(v_seen) THEN
        v_raw[v_i] := NULL;
      ELSE
        v_seen := v_seen || v_raw[v_i];
      END IF;
    END IF;
  END LOOP;

  -- ── 1·2·3단계: 카드별 최종 uid 결정 + 배열 반영 ─────────────
  FOR v_i IN 0 .. v_count - 1 LOOP
    -- 카드가 객체가 아니면 건너뛴다 (깨진 데이터 방어 — 그 원소는 그대로 둔다)
    CONTINUE WHEN jsonb_typeof(v_cards -> v_i) <> 'object';

    -- 1단계: 0단계 정리 후에도 값이 남아 있으면 그대로 둔다
    v_uid := v_raw[v_i + 1];

    -- 2단계: 없고 개수가 같으면 같은 자리의 기존 번호를 물려받는다
    IF v_uid IS NULL AND v_inherit THEN
      IF jsonb_typeof(v_old_cards -> v_i -> 'uid') = 'string' THEN
        v_uid := NULLIF(btrim(v_old_cards -> v_i ->> 'uid'), '');
      END IF;

      -- 물려받을 값이 이미 이번 배열에서 쓰인 번호면 물려주지 않는다(중복 방지)
      IF v_uid IS NOT NULL AND v_uid = ANY(v_seen) THEN
        v_uid := NULL;
      END IF;
    END IF;

    -- 3단계: 그래도 비어 있으면 새 번호를 만든다 (추측 불가한 무작위 문자열)
    IF v_uid IS NULL THEN
      v_uid := replace(gen_random_uuid()::text, '-', '');
    END IF;

    -- 이후 자리의 물려주기·중복 판정이 이 값과 겹치지 않도록 누적
    v_seen := v_seen || v_uid;

    v_cards := jsonb_set(v_cards, ARRAY[v_i::text, 'uid'], to_jsonb(v_uid), true);
  END LOOP;

  RETURN jsonb_set(p_data, ARRAY['cards'], v_cards, true);
END;
$$;

-- 표를 읽지 않는 순수 계산 함수 — 외부 직접 호출 필요 없음
REVOKE EXECUTE ON FUNCTION public._orient_apply_card_uids(jsonb, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION public._orient_apply_card_uids(jsonb, jsonb) IS
  '[293] 오리엔시트 카드 고유 번호(data.cards[].uid) 보정. '
  '0)유효성 정리(문자열 아님·빈값·공백→없는 것으로, 배열 내 중복 uid는 첫 항목만 인정) '
  '1)있으면 유지 2)없고 개수가 같으면 같은 자리 기존 번호 물려받기(단 이미 쓰인 값이면 제외) '
  '3)그래도 비면 새 번호. '
  '⚠️2단계의 개수 조건을 빼면 번호가 한 칸씩 밀려 붙어 메모가 엉뚱한 카드에 나타난다. '
  'save_orient_draft·submit_orient_sheet 가 저장 직전에 호출한다.';


-- ============================================================
-- B. save_orient_draft — 임시저장 (베이스: 187, 변경점만 주석 표시)
-- ============================================================
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
  v_data         jsonb;   -- [293] 번호 보정 결과 — 이 값을 기준으로 크기 검사 + 저장
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 저장 충돌 대비)
  --   [293] data 추가 — 물려주기 재료
  SELECT id, status, version, token_expires_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (쓰기 함수이므로 FOR UPDATE 잠금 하에 status='expired' 전환)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'   -- updated_at은 트리거가 자동 갱신
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 저장 불가 상태 차단
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- [293] 카드 고유 번호 보정 — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  --   크기 검사보다 먼저 계산해, 실제로 저장될 값을 기준으로 검사한다(아래).
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트)
  --   [293] 검사 기준 = **보정 후 값(v_data)**. 실제로 저장되는 값이 상한을
  --   넘지 않아야 한다는 것이 이 가드의 목적이므로, 보정 전 값으로만 검사하면
  --   uid 를 붙인 뒤 실제 저장값이 상한을 넘는 경우를 놓친다.
  --   카드당 늘어나는 양은 약 42바이트(`,"uid":"32자리16진수"`)로, 100KB 대비
  --   미미해 "지금까지 되던 저장이 갑자기 거부되는" 위험은 실질적이지 않다고
  --   판단했다 (파일 머리말 참조).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락: 클라이언트가 보낸 version이 현재 DB version과 다르면 충돌
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 임시저장: data·version만 갱신. status는 변경하지 않음(submitted→draft 역전환 없음, P0-1).
  --   updated_at은 BEFORE UPDATE 트리거(trg_orient_sheets_updated_at)가 자동 갱신.
  UPDATE public.orient_sheets
     SET data    = v_data,            -- [293] 보정된 데이터
         version = v_sheet.version + 1
   WHERE id      = v_sheet.id
     AND version = p_version;           -- 이중 낙관적 락 (FOR UPDATE + WHERE version)

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  -- UPDATE가 0행이면 version 충돌(FOR UPDATE 이후 다른 트랜잭션이 먼저 커밋)
  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'conflict'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'version', v_sheet.version + 1
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 187 과 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids 로 카드 고유 번호(uid) 보정 후, '
  '그 보정된 값 기준으로 jsonb 100KB 상한 검사. '
  'status 미변경(submitted→draft 역전환 없음 — data·version만 갱신). '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- C. submit_orient_sheet — 제출 (베이스: **202**, 변경점만 주석 표시)
--    202 가 추가한 반환 키를 하나도 빼지 않는다 (제출 알림 메일이 사용)
-- ============================================================
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
  v_data         jsonb;   -- [293] 번호 보정 결과 — 이 값을 기준으로 크기 검사 + 저장
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 제출 충돌 대비)
  --   [293] data 추가 — 물려주기 재료
  SELECT id, brand_id, application_id, form_type,
         status, version, token_expires_at, submitted_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (자원 열거 방지 — 187 패턴 유지)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (쓰기 함수이므로 FOR UPDATE 잠금 하에 expired 전환)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 제출 불가 상태 차단
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 기본 입력 검증: data가 NULL 이거나 빈 객체이면 제출 거부 (원본 입력 기준 — 보정 전)
  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;

  -- [293] 카드 고유 번호 보정 — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  --   크기 검사보다 먼저 계산해, 실제로 저장될 값을 기준으로 검사한다(아래).
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트)
  --   [293] 검사 기준 = **보정 후 값(v_data)**. 이유는 save_orient_draft 와 동일
  --   (파일 머리말 참조 — 카드당 약 42바이트 증가, 100KB 대비 미미).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'reason',       'data_too_large',
      'limit_bytes',  102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락: version 불일치 시 충돌 반환
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 신규/재제출 판정 (갱신 전 submitted_at 기준 — 반환값·Edge Function 메일 분기용)
  v_is_first := (v_sheet.submitted_at IS NULL);

  -- 제출 전이: draft | submitted → submitted
  --   submitted_at : COALESCE — 첫 제출 시각만 기록 (재제출 시 불변)
  --   last_submitted_at : now() — 매 제출마다 갱신 (202, PR 2 일일 보고용)
  UPDATE public.orient_sheets
     SET data              = v_data,          -- [293] 보정된 데이터
         status            = 'submitted',
         submitted_at      = COALESCE(v_sheet.submitted_at, v_now),
         last_submitted_at = v_now,
         version           = v_sheet.version + 1
         -- updated_at 은 BEFORE UPDATE 트리거가 자동 갱신
   WHERE id      = v_sheet.id
     AND version = p_version;     -- 이중 낙관적 락 (FOR UPDATE + WHERE version)

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  -- UPDATE 0행 = version 충돌 (FOR UPDATE 이후 다른 트랜잭션이 먼저 커밋)
  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'conflict');
  END IF;

  RETURN jsonb_build_object(
    -- 기존 반환 키 유지 (클라이언트 하위호환)
    'success',             true,
    'version',             v_sheet.version + 1,
    'submitted_at',        COALESCE(v_sheet.submitted_at, v_now),
    -- 202 반환 키 (Edge Function 및 클라이언트 신규/재제출 분기용) — 하나도 빼지 않는다
    'last_submitted_at',   v_now,
    'is_first_submission', v_is_first,
    'orient_sheet_id',     v_sheet.id,
    'brand_id',            v_sheet.brand_id,
    'form_type',           v_sheet.form_type,
    'application_id',      v_sheet.application_id
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 187·202 와 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version 으로 최종 제출. '
  'draft·submitted 양쪽 허용(발행 전 재제출 가능). 만료·consumed 차단. '
  '낙관적 락. submitted_at 은 최초 불변(COALESCE). last_submitted_at 은 매 제출 갱신. '
  '반환값에 is_first_submission·orient_sheet_id·brand_id·form_type·application_id 포함. '
  '저장 직전 _orient_apply_card_uids 로 카드 고유 번호(uid) 보정 후, '
  '그 보정된 값 기준으로 jsonb 100KB 상한 검사. '
  'SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드 (수정된 함수 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 서버에서 마이그레이션 적용 후 SQL Editor 에서 1단계씩 실행
--   SQL Editor 는 postgres(관리자) 세션이라 anon 전용 GRANT 와 무관하게
--   아래 함수들을 직접 호출할 수 있다(권한 검사를 우회하는 것이 아니라,
--   슈퍼유저 세션이 GRANT 대상 제한을 받지 않는 것 — 실제 브랜드 호출 경로는
--   변경되지 않는다).
-- ════════════════════════════════════════════════════════════
--
-- ⚠️ 이 절차는 **각 단계의 기대값이 바로 앞 단계의 결과에서 유도**되도록 짜여 있다.
--    단계를 건너뛰거나 순서를 바꾸면 저장돼 있는 카드 **개수**가 달라져,
--    「물려주기(2단계)」 발동 여부가 뒤집히고 기대값이 통째로 어긋난다.
--    반드시 0 → 6 순서대로, 한 번씩만 실행할 것.
--
--    각 단계 옆의 `[저장된 카드 n개]` 표시가 그 시점의 저장 상태다.
--    물려주기는 「보내는 카드 개수 = 저장된 카드 개수」일 때만 돈다.
--
/*
-- ── 0. 시험용 시트 만들기 (기존 브랜드 하나를 빌려 임시 행 생성) ──────────
--   ⚠️ orient_no 는 빈 값 불가(NOT NULL)이고 기본값·자동 채번 트리거가 없다.
--      발급 함수(create_orient_sheet)가 채우는 값이라, 직접 INSERT 할 때는
--      반드시 손으로 넣어야 한다. 실제 번호와 겹치지 않게 BTEST- 접두어를 쓴다.
--      (create_orient_sheet 를 대신 쓸 수는 없다 — 관리자 로그인 세션을 요구하는데
--       SQL 편집기에는 로그인 사용자가 없어 거부된다.)
INSERT INTO public.orient_sheets (brand_id, token, status, data, version, token_expires_at, orient_no)
SELECT
  (SELECT id FROM public.brands ORDER BY created_at LIMIT 1),
  gen_random_uuid(),
  'draft',
  '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb,
  1,
  now() + interval '30 days',
  'BTEST-O' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
RETURNING id, token, version, orient_no;
-- ↑ 결과의 token 값을 아래 모든 단계에서 '<token>' 자리에 그대로 사용한다.
--   version 은 매 호출 성공마다 1씩 올라간다. 아래 p_version 인자는 이 순서대로
--   실행했을 때의 값이므로, 중간에 실패해 version 이 안 올랐다면 조정할 것.
--   [저장된 카드 2개 — 둘 다 uid 없음]


-- ── 1. 최초 저장 — uid 없는 카드 2개 → 둘 다 새 번호가 붙는지 ──────────
--   보내는 2개 = 저장된 2개 → 물려주기 조건은 성립하지만, 물려줄 기존 번호가
--   없으므로(0단계 데이터에 uid 없음) 3단계로 넘어가 새 번호가 부여된다.
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb,
  1
);
-- 기대값: {"success":true,"version":2}

SELECT data -> 'cards' AS cards_after_1 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- 기대값: 카드 2개 모두 uid 가 32자리 16진수 문자열로 채워져 있다.
--   ★ 이 두 값을 적어 둔다 (아래 2단계 비교용). 이하 U1·U2 로 부른다.
--   [저장된 카드 2개 — uid U1·U2]


-- ── 2. ★검문소 ③ 물려주기 발동 확인 (개수 그대로, uid 없이 재저장) ──────
--   ⚠️ 저장된 uid 를 지우지 않은 채로 진행해야 한다. 지우면 물려줄 재료가
--   사라져 무조건 새 번호가 나오므로, 물려주기가 도는지 확인할 수 없다.
--   보내는 2개 = 저장된 2개 → 물려주기 발동.
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb,  -- uid 없이, 개수 그대로 2개
  2
);
-- 기대값: {"success":true,"version":3}

SELECT data -> 'cards' AS cards_after_2 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대값: 1단계에서 적어 둔 U1·U2 와 **정확히 같다** (순서대로 물려받아 유지)
--   → 이것이 「옛 화면이 저장해도 번호가 안 날아간다」는 안전망의 핵심 증거다.
--   [저장된 카드 2개 — uid U1·U2 그대로]


-- ── 3. ★개수가 다르면 물려주지 않는지 (카드 하나 빼고 저장) ─────────────
--   보내는 1개 ≠ 저장된 2개 → 물려주기 차단 → 새 번호.
--   ⚠️ 이 차단이 없으면 번호가 한 칸씩 밀려 붙어 메모가 엉뚱한 카드에 나타난다.
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"검증용A"}]}'::jsonb,  -- 카드 1개만, uid 없이
  3
);
-- 기대값: {"success":true,"version":4}

SELECT data -> 'cards' AS cards_after_3 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대값: 남은 카드의 uid 가 U1 과도 U2 와도 **다른 새 값**이다.
--   [저장된 카드 1개]


-- ── 4. 배열 안에 같은 번호가 두 번 들어온 경우 ──────────────────────────
--   보내는 2개 ≠ 저장된 1개 → 물려주기는 안 돈다. 중복 판정만 본다.
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"C1","uid":"dupe-test"},{"product_name":"C2","uid":"dupe-test"}]}'::jsonb,
  4
);
-- 기대값: {"success":true,"version":5}

SELECT data -> 'cards' AS cards_after_4 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대값: 첫 카드만 uid="dupe-test" 로 남고, 둘째 카드는 **다른 새 값**이다.
--   (한 번호가 두 카드에 붙으면 메모가 양쪽에 나타나므로 막는다)
--   [저장된 카드 2개]


-- ── 5. 번호가 문자열이 아닌 경우 (숫자·참거짓) ──────────────────────────
--   ⚠️ 카드를 **3개** 보내는 것이 중요하다. 2개를 보내면 저장된 2개와 같아져
--      물려주기가 돌아 버려서, "문자열이 아닌 값을 걸러내는지"가 아니라
--      "물려받았는지"를 보게 된다 — 검증하려던 것이 가려진다.
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"C1","uid":123},{"product_name":"C2","uid":true},{"product_name":"C3"}]}'::jsonb,
  5
);
-- 기대값: {"success":true,"version":6}

SELECT data -> 'cards' AS cards_after_5 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대값: 세 카드 모두 uid 가 32자리 16진수 문자열이다.
--   123·true·"dupe-test" 중 어느 값도 남아 있지 않다.
--   ★ 이 세 값을 적어 둔다 (6단계 비교용). 이하 V1·V2·V3.
--   [저장된 카드 3개 — uid V1·V2·V3]


-- ── 6. 제출 함수도 같은 보정을 타는지 + 202 반환 키가 보존됐는지 ─────────
--   보내는 3개 = 저장된 3개 → 물려주기 발동.
SELECT public.submit_orient_sheet(
  '<token>'::uuid,
  '{"cards":[{"product_name":"C1"},{"product_name":"C2"},{"product_name":"C3"}]}'::jsonb,  -- uid 없이, 개수 그대로 3개
  6
);
-- ★기대값: success=true 이고 아래 키가 **모두** 응답에 들어 있다 —
--   last_submitted_at · is_first_submission · orient_sheet_id · brand_id ·
--   form_type · application_id
--   (하나라도 빠졌으면 202 가 아니라 187 을 베이스로 고친 것이다 → 제출 알림 메일이 죽는다)

SELECT status, data -> 'cards' AS cards_after_6 FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- ★기대값: status='submitted' 이고, 카드 3개의 uid 가 5단계의 V1·V2·V3 과 동일하다.


-- ── 정리 — 시험용 행 삭제 (필수: 검증용 데이터를 남기지 않는다) ──────────
DELETE FROM public.orient_sheets WHERE token = '<token>'::uuid;
*/
