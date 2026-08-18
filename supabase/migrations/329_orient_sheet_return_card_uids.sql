-- ============================================================
-- 329_orient_sheet_return_card_uids.sql
-- 전수조사 후속 조치 — 묶음 I(삭제·파기·그 밖) I-8
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I」 I-8
--
-- ── 이 파일이 하지 않는 것 ──
--   화면 코드(dev/sales/orient.html, dev/js/*.js, dev/lib/storage.js)는 전혀
--   건드리지 않는다. 데이터베이스 함수만 바꾼다. 화면이 이 반환값을 실제로
--   어떻게 써야 하는지는 이 파일 맨 아래 "화면이 해야 할 일"에 정리해 둔다
--   (구현은 이 마이그레이션과 다른 작업에서 진행한다).
--
-- ── 재정의 기준(전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   save_orient_draft      → 187 → 293 → 328(현재 원본). 이 파일은 328 베이스.
--   submit_orient_sheet    → 187 → 202 → 293 → 328(현재 원본). 이 파일은 328 베이스.
--     (grep -rl "FUNCTION public.save_orient_draft\|FUNCTION public.submit_orient_sheet"
--      supabase/migrations/ *.sql → 187·202·293·328 네 곳. 328 이 두 함수 모두의
--      최신 정의다 — 발행된 카드 원상 복구(_orient_preserve_published_cards, I-7)
--      로직을 포함한다. 293 을 베이스로 삼으면 그 복구 로직이 통째로 소실된다.)
--
-- ── 무엇이 문제였나(I-8) ──
--   브랜드 작성 폼은 저장할 때 카드에 번호(uid)를 붙이지 않고 보낸다 — 번호를
--   만드는 곳은 서버 저장 함수 한 곳뿐이라는 것이 293 의 설계다(293 파일
--   "카드 고유 번호 보정" 참고). 293 의 물려주기 규칙은 「없고 개수가 같을
--   때만 같은 자리 번호를 물려받는다」인데, 저장 함수가 그 결과(번호가 붙은
--   뒤의 카드 목록)를 지금까지 `{success, version}` 만 돌려주고 폼에 알려주지
--   않았다 — 폼은 자기 카드의 번호를 영원히 모른다.
--   → 브랜드가 카드를 하나 추가·삭제해 개수가 달라지면 293 의 「개수가 같을
--   때만 물려받기」가 깨지고, 폼이 애초에 아무 카드의 번호도 몰랐으므로 모든
--   카드가 새 번호를 받는다. 그 순간 카드 번호에 붙는 관리자 내부 메모(297·298)
--   가 전부 고아가 된다 — 이건 293 이 막으려던 사고("한 칸씩 밀려 메모가 엉뚱한
--   모집 건 아래 나타난다")의 다른 얼굴이다. 293 은 "폼이 번호를 실어 나른다"를
--   전제로 개수 조건을 걸었는데, 폼이 애초에 번호를 받은 적이 없었다.
--
-- ── 무엇을 어떤 모양으로 돌려주나 ──
--   두 함수의 성공 응답(`success: true`)에 `card_uids` 키를 추가한다.
--   값은 jsonb 배열 — **이번에 브랜드가 보낸 카드 배열(p_data.cards)과 정확히
--   같은 개수·같은 순서**로, 그 자리 카드의 최종 번호(uid)를 담는다.
--   (예: 카드 3개를 보냈으면 `card_uids` 도 원소 3개 — 1번째 값이 1번째로
--   보낸 카드의 번호, 2번째 값이 2번째로 보낸 카드의 번호…)
--
--   I-7(_orient_preserve_published_cards)이 되살려 뒤에 이어붙인 카드는 이
--   배열에 포함하지 않는다 — 그 카드는 폼이 이번에 보낸 것이 아니라서(폼
--   화면에 아예 없던 카드다) 짝지을 화면 요소 자체가 없다. 그 카드는 328 이
--   이미 정한 대로 "다음에 폼을 다시 불러올 때" 자연히 나타난다(이 파일이
--   바꾸는 부분이 아니다).
--
-- ── 왜 이 모양을 골랐나(순서만으로 위험하지 않은 이유) ──
--   `card_uids` 는 위치(배열 순서)로 짝짓는 값이다. 이것만 보면 293 이
--   경계했던 "밀림"이 폼 쪽에서 재현될 위험이 있어 보인다 — 하지만 293 의
--   밀림은 **서버**가 "지금 보낸 배열"과 "저장돼 있던 배열"의 개수 차이를
--   못 알아채 엉뚱한 자리에 옛 번호를 물려주는 문제였다. 이 반환값의 순서는
--   그것과 다른 층이다 — **같은 요청·같은 응답 안에서** 서버가 그 자리에 실제로
--   배정한 값을 그대로 돌려줄 뿐이라, 서버 쪽에서는 밀릴 여지가 없다(위치
--   i 의 응답 값은 그 요청의 위치 i 카드에 대해 서버가 실제로 확정한 번호다 —
--   이 문서 "구현 근거" 참고).
--
--   위험이 남는 지점은 오직 **폼(자바스크립트) 쪽**이다 — 요청을 보낸 뒤 응답이
--   돌아오기까지의 그 짧은 시간 동안 사용자가 카드를 추가·삭제해 화면
--   목록(DOM)이 바뀌면, 그때 가서 "화면에 지금 보이는 카드 목록"을 새로
--   조회해 이 배열과 순서로 맞추면 엉뚱한 카드에 번호가 붙는다 — 이게 바로
--   293 이 경계한 밀림이 폼 쪽에서 재현되는 경로다.
--   그래서 이 반환값은 **"요청을 만들 때 붙잡아 둔 그 화면 요소 목록"에만
--   순서대로 적용해야 안전**하다(요청 보낸 뒤 화면을 다시 조회해서 맞추면
--   안 된다) — 아래 "화면이 해야 할 일"에 정확히 적어 둔다. 이 규칙만 지키면
--   순서 기반이라도 밀릴 여지가 없다: 요청 배열과 그 "붙잡아 둔 목록"은 애초에
--   같은 시점·같은 한 번의 훑기에서 나온 것이라 항상 개수·순서가 일치한다.
--
--   (참고로 검토했으나 채택하지 않은 대안: 폼이 카드마다 임시 상관 번호를
--   같이 보내 서버가 그 번호로 되돌려주는 방식. 더 안전해 보이지만 함수
--   시그니처를 바꿔야 하고 — CREATE OR REPLACE 는 인자 개수가 다르면 기존
--   함수를 "교체"하지 못하고 별개 함수를 새로 만든다, 저장되는 데이터에
--   화면 전용 임시값이 섞이는 것도 막아야 한다. 위 "붙잡아 둔 목록" 방식은
--   서버 쪽 변경만으로 이 위험을 완전히 없앨 수 있어 이쪽을 택했다.)
--
-- ── 구현 근거: 왜 위치 i 가 항상 그 카드의 값인가 ──
--   1) `_orient_apply_card_uids`(293)는 `jsonb_set` 으로 **같은 인덱스 자리에**
--      번호를 채운다 — 배열 길이·순서를 바꾸지 않는다.
--   2) `_orient_preserve_published_cards`(328)는 되살릴 카드를 배열 **끝에만**
--      이어붙인다 — 앞쪽(보낸 카드들)의 자리는 절대 밀리지 않는다.
--   → 최종 배열의 앞 N개(N=보낸 카드 개수)는 항상 "보낸 순서 그대로"다.
--   이 사실을 활용해 새 순수 계산 함수 `_orient_sent_card_uids` 가 그 앞 N개의
--   번호만 뽑아 돌려준다.
--
-- ── 익명 호출자에게 새로 새는 정보가 있는가 ──
--   없다. `card_uids` 의 값은 ①브랜드가 이미 보낸 카드(번호를 이미 알고
--   있었던 카드는 그 번호 그대로) ②이번에 처음 서버가 새로 만든 번호(그
--   카드는 애초에 이번 요청을 보낸 바로 그 브랜드의 카드다 — 남의 카드
--   정보가 섞일 여지가 없다, `_orient_sent_card_uids` 가 보는 것은 그 요청
--   자신의 p_data 뿐이다). 되살아난(다른 카드) 번호는 이 배열에 아예 넣지
--   않으므로 그쪽에서 새로 노출되는 것도 없다.
--
-- ── 기존 반환 키는 그대로 ──
--   `success`·`version`·`reason`(save_orient_draft) 및
--   `success`·`version`·`submitted_at`·`last_submitted_at`·`is_first_submission`·
--   `orient_sheet_id`·`brand_id`·`form_type`·`application_id`(submit_orient_sheet)
--   전부 328 그대로 유지 — `card_uids` 는 추가만 한다.
--
-- 인자 시그니처 불변: (p_token uuid, p_data jsonb, p_version int) — 위 "채택하지
-- 않은 대안"에서 설명한 대로, 시그니처를 바꾸면 CREATE OR REPLACE 가 기존
-- 함수를 교체하지 못하고 별개 함수가 하나 더 생겨 옛 함수가 계속 남는다.
--
-- 보안:
--   - 세 함수 모두 SET search_path = ''
--   - ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋한다는 이 저장소의 확립된
--     전제에 따라(293·328 이 명시) REVOKE FROM PUBLIC → GRANT TO anon 을
--     이 파일에서도 다시 넣는다.
--   - 신규 `_orient_sent_card_uids` 는 표를 읽지 않는 순수 계산 함수라
--     SECURITY DEFINER 가 아니다. PUBLIC 실행 권한만 회수한다
--     (293·328 의 `_orient_apply_card_uids`·`_orient_preserve_published_cards`
--     와 동일한 대우 — 소유자 권한으로 도는 save_orient_draft·
--     submit_orient_sheet 안에서만 호출된다).
--
-- 운영 데이터 영향: 없음. 기존 행의 data 를 고치지 않는다. 응답 모양만 바뀐다.
--
-- 화면이 해야 할 일(이 마이그레이션이 하지 않는 것 — 다른 작업에서 구현):
--   1) `collectData()` 로 요청을 만들 때, 그 순간의 `.ocard` 요소 목록을
--      **변수로 붙잡아 둔다**(`const cardEls = Array.from(document.
--      querySelectorAll('.ocard'))`  — `collectData()`가 카드를 훑는 바로
--      그 순간의 목록과 같은 것이어야 한다).
--   2) 저장 응답이 도착하면, **그 순간 DOM 을 다시 조회하지 말고** 1)에서
--      붙잡아 둔 `cardEls` 를 그대로 순서대로 순회하며
--      `cardEls[i].setAttribute('data-uid', res.card_uids[i])` 로 적용한다
--      (`res.card_uids[i]` 가 없거나 null 이면 건너뛴다 — 방어적으로).
--      요청을 보낸 뒤 응답이 오기 전에 사용자가 카드를 추가·삭제해도, 이미
--      붙잡아 둔 목록의 원소(자바스크립트 객체 참조)는 그대로 유효하므로
--      틀린 카드에 번호가 붙을 일이 없다(화면에서 사라진 카드에 적용해도
--      아무 부작용 없이 무시된다).
--   3) 다음 자동저장부터는 `collectCard()` 가 그 요소의 `data-uid` 를 이미
--      읽고 있으므로(orient.html 1530번째 줄 부근 기존 로직) 별도 수정 없이
--      번호가 실려 나간다.
--   ⚠️ 카드를 하나도 추가·삭제하지 않은 평범한 저장에서는(개수가 안 바뀜)
--   293 의 물려주기만으로도 지금까지 우연히 문제가 없었다 — 이번 수정은
--   "카드 개수가 바뀌는 저장" 경로를 고치는 것이다.
-- ============================================================

BEGIN;


-- ============================================================
-- A. _orient_sent_card_uids — 보낸 카드들의 최종 번호만 순서대로 추출 (순수 계산)
--
--   p_sent_data  : 브랜드 폼이 이번에 보낸 데이터(p_data 원본 그대로 — uid 보정 전)
--   p_final_data : 저장 직전까지 확정된 최종 데이터(_orient_apply_card_uids +
--                  _orient_preserve_published_cards 를 모두 거친 뒤의 값)
--
--   반환: p_final_data.cards 의 앞쪽 N개(N=p_sent_data.cards 의 개수)에서
--         uid 값만 순서대로 뽑은 jsonb 배열. 어느 한쪽이라도 객체가 아니거나
--         cards 배열이 없으면 빈 배열을 돌려준다(방어적 — 293·328 과 동일한
--         방어 스타일).
-- ============================================================
CREATE OR REPLACE FUNCTION public._orient_sent_card_uids(
  p_sent_data  jsonb,
  p_final_data jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_sent_cards  jsonb;
  v_final_cards jsonb;
  v_sent_count  int;
  v_out         jsonb := '[]'::jsonb;
  v_i           int;
BEGIN
  IF p_sent_data IS NULL OR jsonb_typeof(p_sent_data) <> 'object' THEN
    RETURN v_out;
  END IF;

  v_sent_cards := p_sent_data -> 'cards';
  IF v_sent_cards IS NULL OR jsonb_typeof(v_sent_cards) <> 'array' THEN
    RETURN v_out;
  END IF;

  v_sent_count := jsonb_array_length(v_sent_cards);
  IF v_sent_count = 0 THEN
    RETURN v_out;
  END IF;

  IF p_final_data IS NULL OR jsonb_typeof(p_final_data) <> 'object' THEN
    RETURN v_out;
  END IF;

  v_final_cards := p_final_data -> 'cards';
  IF v_final_cards IS NULL OR jsonb_typeof(v_final_cards) <> 'array' THEN
    RETURN v_out;
  END IF;

  -- 보낸 개수만큼만 훑는다(그 뒤에 되살아난 카드가 이어붙어 있어도 제외됨).
  -- LEAST 는 최종 배열이 어떤 이유로든 보낸 개수보다 짧아지는 경우(정상
  -- 경로에서는 발생하지 않는다 — 위 파일 상단 "구현 근거" 참고)에 대비한
  -- 방어적 상한이다.
  FOR v_i IN 0 .. LEAST(v_sent_count, jsonb_array_length(v_final_cards)) - 1 LOOP
    IF jsonb_typeof(v_final_cards -> v_i) = 'object' THEN
      v_out := v_out || jsonb_build_array(v_final_cards -> v_i -> 'uid');
    ELSE
      v_out := v_out || jsonb_build_array(NULL);
    END IF;
  END LOOP;

  RETURN v_out;
END;
$$;

-- 표를 읽지 않는 순수 계산 함수 — 외부 직접 호출 필요 없음 (293·328 과 동일 스타일)
REVOKE EXECUTE ON FUNCTION public._orient_sent_card_uids(jsonb, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION public._orient_sent_card_uids(jsonb, jsonb) IS
  '[329] 오리엔시트 저장 응답용. p_final_data.cards 의 앞 N개(N=p_sent_data.cards '
  '개수)에서 uid 만 순서대로 뽑아 jsonb 배열로 돌려준다 — 되살아난(I-7) 카드는 '
  '제외. save_orient_draft·submit_orient_sheet 가 성공 응답에 담을 card_uids 를 '
  '이 함수로 만든다. 화면은 요청을 만들 때 붙잡아 둔 카드 요소 목록에만 순서대로 '
  '적용해야 안전하다(응답 도착 후 DOM 을 다시 조회해 맞추면 안 됨) — 이 파일 상단 '
  '"화면이 해야 할 일" 참고.';


-- ============================================================
-- B. save_orient_draft — 임시저장 (베이스: 328, 변경점만 주석 표시)
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
  v_data         jsonb;   -- 번호 보정 + 발행 카드 복구(328) 결과 — 이 값을 기준으로 크기 검사 + 저장
  v_card_uids    jsonb;   -- [329] 보낸 카드들의 최종 번호(순서대로) — 응답에만 사용, 저장 안 함
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 저장 충돌 대비) (293 과 동일)
  SELECT id, status, version, token_expires_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (293 과 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (293 과 동일)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 저장 불가 상태 차단 (293 과 동일)
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 카드 고유 번호 보정 (293) — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드가 이번 저장에서 통째로 사라졌으면 원래 내용 그대로
  -- 되살린다(328, I-7).
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트). 검사 기준 = 보정 후 값(v_data)
  -- (293·328 과 동일 원칙 — 카드 되살리기까지 반영된 실제 저장값 기준).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락 (293 과 동일)
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 임시저장: data·version만 갱신 (293 과 동일)
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

  -- [329] 실제로 저장된 v_data 기준으로, 이번에 브랜드가 보낸 카드들의 최종
  -- 번호를 순서대로 뽑는다(p_data = 원래 보낸 그대로, v_data = 저장된 최종값).
  v_card_uids := public._orient_sent_card_uids(p_data, v_data);

  RETURN jsonb_build_object(
    'success',   true,
    'version',   v_sheet.version + 1,
    'card_uids', v_card_uids  -- [329] 신규 — 화면이 이 값을 카드 요소에 되돌려 써야 다음 저장이 정확한 번호를 싣는다
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 293·328 과 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[293, 328, 329 개정] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). '
  '저장 직전 _orient_apply_card_uids(293)로 카드 고유 번호 보정 → '
  '_orient_preserve_published_cards(328)로 발행된 카드가 사라졌으면 원상 복구 → '
  '그 최종 값 기준으로 jsonb 100KB 상한 검사. '
  '[329] 성공 응답에 card_uids(이번에 보낸 카드들의 최종 번호, 보낸 순서 그대로) 포함 — '
  '화면이 요청 시점에 붙잡아 둔 카드 요소 목록에 순서대로 적용해야 한다(다시 조회해 '
  '맞추면 밀림 위험 재현, 이 파일 상단 "화면이 해야 할 일" 참고). '
  'status 미변경(submitted→draft 역전환 없음 — data·version만 갱신). '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- C. submit_orient_sheet — 제출 (베이스: 328, 변경점만 주석 표시)
--    328 이 293·202 에서 물려받은 반환 키를 하나도 빼지 않는다 (제출 알림 메일이 사용)
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
  v_data         jsonb;   -- 번호 보정 + 발행 카드 복구(328) 결과 — 이 값을 기준으로 크기 검사 + 저장
  v_card_uids    jsonb;   -- [329] 보낸 카드들의 최종 번호(순서대로) — 응답에만 사용, 저장 안 함
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 제출 충돌 대비) (293 과 동일)
  SELECT id, brand_id, application_id, form_type,
         status, version, token_expires_at, submitted_at, data
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (자원 열거 방지 — 187 패턴 유지, 293 과 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (293 과 동일)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 제출 불가 상태 차단 (293 과 동일)
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 기본 입력 검증: data가 NULL 이거나 빈 객체이면 제출 거부 (원본 입력 기준 — 보정 전, 293 과 동일)
  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
  END IF;

  -- 카드 고유 번호 보정 (293) — 저장돼 있던 data 를 물려주기 재료로 넘긴다.
  v_data := public._orient_apply_card_uids(p_data, v_sheet.data);

  -- 발행된 카드가 이번 제출에서 통째로 사라졌으면 원래 내용 그대로
  -- 되살린다(328, I-7 — save_orient_draft 와 동일 원칙).
  v_data := public._orient_preserve_published_cards(v_data, v_sheet.data);

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트). 검사 기준 = 보정 후 값(v_data)
  -- (save_orient_draft 와 동일 이유).
  v_data_size := octet_length(v_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'reason',       'data_too_large',
      'limit_bytes',  102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락 (293 과 동일)
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 신규/재제출 판정 (293 과 동일)
  v_is_first := (v_sheet.submitted_at IS NULL);

  -- 제출 전이: draft | submitted → submitted (293 과 동일)
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

  -- [329] 실제로 저장된 v_data 기준으로, 이번에 브랜드가 보낸 카드들의 최종
  -- 번호를 순서대로 뽑는다(p_data = 원래 보낸 그대로, v_data = 저장된 최종값).
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
    'card_uids',           v_card_uids  -- [329] 신규 — save_orient_draft 와 동일한 의미·용도
  );
END;
$$;

-- ⚠️ CREATE OR REPLACE 는 기존 GRANT 를 리셋 → 293·328 과 동일하게 재적용 (필수)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[293, 202, 328, 329 개정] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version 으로 최종 제출. '
  'draft·submitted 양쪽 허용(발행 전 재제출 가능). 만료·consumed 차단. 낙관적 락. '
  'submitted_at 은 최초 불변(COALESCE). last_submitted_at 은 매 제출 갱신. '
  '반환값에 is_first_submission·orient_sheet_id·brand_id·form_type·application_id 포함(202). '
  '저장 직전 _orient_apply_card_uids(293)로 카드 고유 번호 보정 → '
  '_orient_preserve_published_cards(328)로 발행된 카드가 사라졌으면 원상 복구 → '
  '그 최종 값 기준으로 jsonb 100KB 상한 검사. '
  '[329] 성공 응답에 card_uids(이번에 보낸 카드들의 최종 번호, 보낸 순서 그대로) 포함 — '
  '화면이 요청 시점에 붙잡아 둔 카드 요소 목록에 순서대로 적용해야 한다(다시 조회해 '
  '맞추면 밀림 위험 재현, 이 파일 상단 "화면이 해야 할 일" 참고). '
  'SECURITY DEFINER + search_path 고정.';

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ============================================================
-- 검증 SQL (1단계씩 실행·결과 확인 후 다음 단계로. 개발서버 먼저.
--   .claude/rules/supabase.md 「SQL 검증 순차 안내」)
--   ⚠️ 아래 블록 안에서 파일 경로를 적을 때 "migrations/" 바로 뒤에 "*.sql" 을
--   붙이지 않는다(공백을 하나 둔다) — PostgreSQL 은 블록 주석을 중첩 처리해서
--   "/*" 조합이 나오면 새 주석이 또 열린 것으로 읽어 이 블록 전체가 안 닫히는
--   사고가 327 에서 실제로 있었다.
-- ============================================================
/*

-- [1] 함수 3개 존재 확인
SELECT proname FROM pg_proc
 WHERE proname IN ('_orient_sent_card_uids', 'save_orient_draft', 'submit_orient_sheet')
   AND pronamespace = 'public'::regnamespace;
-- 기대: 3행

-- [2] 순수 계산 함수 단독 검증 — 보낸 2장 중 1장만 최종 배열에 uid 가 있는 경우
SELECT public._orient_sent_card_uids(
  '{"cards":[{"product_name":"A"},{"product_name":"B"}]}'::jsonb,
  '{"cards":[{"product_name":"A","uid":"aaa"},{"product_name":"B","uid":"bbb"},{"product_name":"복원됨","uid":"ccc","campaign_id":"11111111-1111-1111-1111-111111111111"}]}'::jsonb
);
-- 기대: ["aaa","bbb"]  (뒤에 이어붙은 "복원됨" 카드[3번째]는 포함되지 않아야 함 — 보낸 개수 2개만)

-- [3] 시험용 시트로 저장 함수 전체 재현(실제 orient_sheets 행을 만들고 끝에
--    지운다. 293/328 검증 블록과 같은 방식, 개발서버 한정)
INSERT INTO public.orient_sheets (brand_id, token, status, data, version, token_expires_at, orient_no)
SELECT
  (SELECT id FROM public.brands ORDER BY created_at LIMIT 1),
  gen_random_uuid(),
  'draft',
  '{"cards":[{"uid":"olduid001","product_name":"기존카드1"},{"uid":"olduid002","product_name":"기존카드2"}]}'::jsonb,
  1,
  now() + interval '30 days',
  'BTEST-O' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
RETURNING id, token, version;
-- ↑ token 값을 아래 <token> 자리에 사용.

-- [4] 카드 순서 그대로(개수 불변) 저장 — 번호가 물려받아지고, card_uids 가 그대로 돌아오는지
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"기존카드1-수정"},{"product_name":"기존카드2"}]}'::jsonb,
  1
);
-- 기대: {"success":true,"version":2,"card_uids":["olduid001","olduid002"]}
--   (uid 를 안 보냈지만 개수가 같아 293 물려주기로 옛 번호가 그대로 유지되고,
--   card_uids 응답도 그 값을 그대로 돌려준다)

-- [5] 카드 하나를 추가해서(개수가 바뀌어) 저장 — 새 번호가 생기고 그 값이
--    card_uids 로 정확히 돌아오는지(이번 수정의 핵심 시나리오)
SELECT public.save_orient_draft(
  '<token>'::uuid,
  '{"cards":[{"product_name":"기존카드1-수정"},{"product_name":"기존카드2"},{"product_name":"새카드"}]}'::jsonb,
  2
);
-- 기대: {"success":true,"version":3,"card_uids":["<32자리 새 uid>","<32자리 새 uid>","<32자리 새 uid>"]}
--   ⚠️ 293 의 3단계(개수 불일치 → 물려받기 건너뛰고 전부 새 번호)가 그대로
--   발동해 세 값 모두 이전과 다른 새 번호다 — 이게 바로 I-8 이 고치려는
--   지점이다: 이제 응답에 그 새 번호 3개가 실려 나오므로, 화면이 이 값을
--   저장해 뒀다가 다음 저장에 실어 보내면 그다음부터는 [4]처럼 안정된다.

SELECT data -> 'cards' FROM public.orient_sheets WHERE token = '<token>'::uuid;
-- 기대: 방금 응답의 card_uids 3개 값과 각 카드의 uid 가 순서대로 일치

-- [6] 정리 — 시험용 행 삭제
DELETE FROM public.orient_sheets WHERE token = '<token>'::uuid;

-- [7] 권한 확인 — anon 이 여전히 두 함수를 부를 수 있는지(로그인 없는 브랜드
--    작성 폼이 이 함수를 부른다)
SELECT grantee, privilege_type
  FROM information_schema.routine_privileges
 WHERE routine_name IN ('save_orient_draft','submit_orient_sheet')
   AND grantee = 'anon';
-- 기대: 두 함수 모두 anon EXECUTE 행이 있음

*/


-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
--   DROP FUNCTION IF EXISTS public._orient_sent_card_uids(jsonb, jsonb);
--   -- save_orient_draft·submit_orient_sheet 를
--   -- 328_audit_remediation_bundle_i_orient_and_deliverable_history.sql 의
--   -- CREATE OR REPLACE FUNCTION 블록(card_uids 없는 버전)을 그대로 재실행해
--   -- 되돌린다. ⚠️ 이미 이 함수 버전으로 저장된 데이터(카드 uid 자체)는
--   -- 롤백해도 그대로 유지된다(무해 — 그 값은 293 규칙대로 정상 부여된
--   -- 진짜 번호다. 되돌리는 것은 "응답에 card_uids 를 싣는 동작"뿐이다).
-- COMMIT;
