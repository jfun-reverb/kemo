-- 501_backfill_settlement_transfers_from_sheet.sql
-- 과거 지급 시트를 송금 묶음으로 반영하는 소급 함수 (시트 소급 반영 2/3)
-- 사양서: docs/specs/2026-10-01-settlement-sheet-backfill.md 결정 1~7 · 설계 ① (나) · 「착수 전 알아야 할 것」
-- 작업표: docs/specs/2026-10-02-settlement-sheet-backfill-breakdown.md 「S2」
--
-- 선행: 485(표 3개) · 486(_settlement_register_judge · _settlement_fee_calc) · 500(추정 표시 칸 2개)
--
-- ▶ 이 파일이 하는 일 — 함수 1개 신설: backfill_settlement_transfers_from_sheet(p_bundles jsonb) RETURNS jsonb
--   · 기존 함수는 하나도 안 바꾼다(486 의 record_settlement_transfers 와 별개).
--   · 🔴 출처는 항상 'sheet_backfill' — 입력으로 받지 않는다(app 을 넣을 길이 없다). 그래서 이 함수는 도입일
--     (_settlement_transfer_intro_at — source='app' 만 센다)을 만들지 않고, 도입일 판정도 부르지 않는다.
--   · 🔴 페이팔 유무로 막지 않는다 — 486 의 거부 세 곳(항목 검사·미등록 헬퍼 사유·쓰기 때 회원 현재 값 재조회)을 옮기지 않았다.
--     정산 행의 paypal_email 은 회원의 현재 값이 아니라 입력의 시트 주소로 쓴다(돈은 그 주소로 나갔다).
--   · 인플루언서 알림 없음(343 이후). 권한 has_permission('settlement.pay','write')(486 과 같다).
--   · 🔴 권한 판정은 로그인이 필요해 SQL 편집기(서비스 키)로는 호출이 안 된다 — 관리자 로그인 브라우저 콘솔에서 부른다.
--
-- ▶ 입력 p_bundles (jsonb 배열 — 송금 1번 = 묶음 1개)
--   [
--     { "sent_at": "2026-06-15",          -- 필수. 'YYYY-MM-DD' 문자열만. 일본 시각 그날 0시로 저장(화면 _settlementJstMidnight 와 같게)
--       "sent_at_estimated": false,       -- 선택(기본 false). true = 회차 지급일로 채운 추정값
--       "fee_jpy": 173.4,                 -- fee_estimated=false 이면 필수(숫자, 소수 가능 → 반올림해 저장). fee_estimated=true 이면 무시
--       "fee_estimated": false,           -- 선택(기본 false). true = 서버가 현재 규칙(settlement_fee_rule id=1)으로 계산
--       "memo": "…",                      -- 선택
--       "items": [                        -- 필수, 1개 이상. 아래 항목 모양
--         { "settlement_id": "<uuid>",    -- 정산 행으로 지목  ┐ 둘 중 정확히 하나
--           "application_id": "<uuid>",   -- 응모로 지목      ┘ (정산 행이 이미 있으면 그 행으로 취급, 없으면 미등록 응모)
--           "amount_jpy": 3000,           -- 필수. 기록 금액(그 건에 실제로 보낸 돈). 정수 > 0
--           "paypal_email": "a@b.c",      -- 선택. 시트의 페이팔 주소. 현재 송금 + 정산대기·미등록일 때 정산 행에 기록(없으면 기존 값 유지)
--           "link": "current",            -- 선택(기본 'current'). 'current' = 현재 송금 / 'old' = 옛 송금(연결만)
--           "revert_event_id": "<uuid>",  -- link='old' 일 때 필수(settlement_events.id, 그 건의 action='revert' 이력). 'current' 에는 넣을 수 없다
--           "confirmed_by": "홍길동",      -- ┐ 둘 다 있으면 「확인 표시」 — 사람이 정한 항목.
--           "confirm_reason": "페이팔 내역 확인" } -- ┘ 하나만 있으면 거부(bundle_confirm_incomplete)
--       ] }, …
--   ]
--
-- ▶ 반환 jsonb
--   { "written": [ { "bundle_index": 0, "transfer_id": "<uuid>",
--                    "items": [ { "item_index": 0, "settlement_id": "<uuid>", "application_id": "<uuid>",
--                                 "link": "current", "amount_jpy": 3000 }, … ] }, … ],
--     "skipped": [ { "bundle_index": 2, "reason": "already_applied" }, … ] }
--   bundle_index·item_index 는 입력 배열의 0부터 센 위치. 건너뛴 묶음은 아무것도 안 쓰였다.
--
-- ▶ 판정 순서 (사양서 설계 ① (나))
--   0) 입력 모양 검사 — 틀리면 즉시 예외(건너뛰기와 무관). 코드 invalid_input / invalid_bundle / bundle_* (아래 표)
--   1) 입력의 모든 정산 행(application_id 로 들어온 것도 기존 정산 행이 있으면 포함)을 id 순으로 FOR UPDATE — 판정보다 먼저.
--      486 의 잠금 순서와 같다(건은 id 순, 묶음은 이 함수가 새로 만들므로 남이 못 본다. 기존 묶음 행은 잠그지 않는다).
--   2) 「이미 반영됨」 항목이 하나라도 든 묶음은 통째로 건너뛴다 → skipped(reason='already_applied'), 다음 검사에 안 넣는다.
--        현재 송금 항목 = 그 건에 current_transfer_id 가 있음 / 옛 송금 항목 = 같은 건·같은 revert_event_id 의 옛 연결이 이미 있음
--   3) 남은 묶음 전부 검사 — 하나라도 걸리면 RAISE 로 전체 거부(아무것도 안 쓴다). 사유 코드는 『코드: 설명 (묶음 순번 N, 항목 순번 M)』.
--   4) 통과하면 묶음마다 쓴다. 쓰는 도중 예상 밖 오류도 예외 → 전체 롤백.
--
-- ▶ 거부 코드 (모두 ERRCODE 22023, 권한은 42501)
--   bundle_empty · bundle_item_invalid · bundle_amount_invalid · bundle_fee_required · bundle_link_invalid ·
--   bundle_revert_event_required · bundle_confirm_incomplete   — 입력 모양
--   bundle_not_found                  항목이 가리키는 정산 행·응모가 없다
--   bundle_not_pending                검사 뒤 다른 처리가 먼저 정산을 등록했다(경쟁)
--   bundle_revert_event_invalid       옛 송금인데 revert_event_id 가 「그 건의 action='revert' 이력」이 아니다(확인 표시와 무관하게 늘 검사)
--   bundle_old_link_unconfirmed       확인 표시 없는 항목이 옛 송금
--   bundle_not_candidate              확인 표시 없는 미등록 응모가 후보(인증 성공·금액 확정)가 아니다
--   bundle_status_not_allowed         확인 표시 없는 정산 행이 송금완료(현재 묶음 없음)·정산대기가 아니다(보류·취소)
--   bundle_revert_history             확인 표시 없는 건에 보류 해제 이력이 있다
--   bundle_amount_mismatch            확인 표시 없는 항목의 기록 금액이 시스템 금액과 다르다
--   bundle_mixed_influencer           한 묶음에 사람이 둘 이상(후보 아님 항목도 applications.user_id 로 센다)
--   bundle_duplicate_item             같은 묶음 안 같은 건 / 묶음 사이 같은 건의 현재 송금 / 같은 건·같은 revert_event_id 의 옛 송금이 둘
--   bundle_sent_at_in_future          송금일이 내일보다 뒤(486 과 같은 기준: now() + 1일)
--   fee_rule_invalid                  추정 수수료를 계산해야 하는데 규칙 행이 없다
--
-- ▶ 항목 종류별 쓰기 (현재 송금 'current' 항목만 — 아래 「옛 송금」 제외)
--   [이미 송금완료, 현재 묶음 없음] 상태·paypal_email 그대로. paid_at = 묶음 sent_at, paid_amount_jpy = 기록 금액, current_transfer_id 설정.
--       옛 송금일·옛 금액은 settlement_events action='correct'(prev/next 'paid')에
--       「[시트 소급] 송금일 A → B(추정), 송금액 ¥x → ¥y」 로 남긴다(486 correct_settlement_payment 의 『송금일 A → B, 송금액 x → ¥y』 와 같은 결).
--   [정산대기] 486 기록과 같은 갱신(status='paid'·paid_at·paid_by·paid_amount_jpy·current_transfer_id·이력 'pay'). paypal_email = 입력 시트 주소.
--   [미등록 응모] 후보면 486 'a' 분기와 같은 INSERT(ON CONFLICT (application_id) DO NOTHING, 이력 'create') 뒤 위 정산대기와 같은 갱신.
--       paypal_missing 사유는 통과로 본다. 🔴 후보 아님이면 헬퍼가 회원·캠페인을 NULL 로 주므로 applications 에서 직접 읽고
--       amount_jpy = 기록 금액, memo 「후보 아님 — 시트 소급 확인」 — 확인 표시 있는 항목만 여기 온다.
--   [보류·취소 + 확인 표시] 상태는 그대로. paid_at·paid_amount_jpy·current_transfer_id 만 채운다(불변식 지킴). paypal_email 은 안 건드린다.
--   [옛 송금 'old' (항상 확인 표시)] 묶음·연결 행(revert_event_id 설정)만 만든다. 상태·현재 묶음·paid_*·paypal_email 불변.
--       (확인자·사유를 남기려고 settlement_events 'correct' 한 줄만 추가 — 정산 행 자체는 안 바뀐다)
--   확인 표시가 있으면 확인자·사유를 settlement_events 메모에 남긴다(「 [확인: 이름 / 사유]」).
--
-- ▶ 확인 표시 없는 항목(= 목록 A)에 거는 조건 — 하나라도 어기면 거부
--   기록 금액 = 시스템 금액(이미 송금완료 = COALESCE(paid_amount_jpy, amount_jpy) — 🔴 paid_amount_jpy 는 NULL 이 정상 /
--   정산대기 = amount_jpy / 미등록 = 헬퍼 계산값) · 상태가 이미 송금완료·정산대기·미등록(후보) 중 하나 ·
--   보류 해제 이력(settlement_events action='revert') 없음 · link='current'.
--   확인 표시 있는 항목은 이 조건을 보지 않는다(옛 송금의 revert_event_id 검사와 한 사람·금액>0·중복 금지는 늘 건다).
--
-- ▶ 묶음 쓰기
--   settlement_transfers 1행: source='sheet_backfill', sent_total_jpy = 묶음 항목의 기록 금액 합(옛 송금 항목 포함 — 실제로 나간 돈),
--     sent_at_estimated · fee_estimated 는 입력 그대로.
--   수수료 — 🔴 둘로 갈린다:
--     fee_estimated=true  : 입력 fee_jpy 를 무시하고 settlement_fee_rule(id=1)의 현재 규칙으로 _settlement_fee_calc(기록 금액 합계)를 계산,
--                           규칙 스냅샷 3칸(fee_rate_percent·fee_fixed_jpy·fee_rounding)을 채운다. fee_manual=false.
--                           (이후 건별 금액 정정 때 규칙대로 따라 바뀐다 — 결정 7)
--     fee_estimated=false : 입력 fee_jpy 를 반올림(round)해 쓴다. fee_manual=false + 스냅샷 3칸 NULL (결정 6).
--                           🔴 이유: 486 correct_settlement_payment 는 fee_manual=false 이고 스냅샷 3칸이 모두 NOT NULL 일 때만 수수료를
--                           규칙으로 다시 계산한다. 스냅샷을 비워 두면 시트의 실제 수수료가 건별 금액 정정에 덮이지 않는다.
--                           fee_manual=true 로 막으면 화면에 「고친 값」 배지와 금액 정정 뒤 fee_stale 경고가 붙으므로 쓰지 않는다.
--   settlement_transfer_items 항목마다 1행(현재 송금 = revert_event_id NULL / 옛 송금 = 입력의 revert_event_id).
--   settlement_transfer_events 묶음마다 'create' 1행(486 과 같은 모양 + 추정 표시 2개).
--
-- ▶ 알아 둘 것
--   · 반려·취소 신청에 송금완료 정산이 생기면 guard_reject_with_paid_settlement(247·320)가 그 신청의 이후 반려·되돌리기를 막는다 — 의도된 동작.
--   · 소급을 하기 전에 수수료 규칙을 바꾸지 말 것 — 추정 수수료는 호출 시점의 현재 규칙을 쓰고 규칙 이력은 484 부터만 있다(작업표 G2).
--   · 🔴 운영 되돌리기 함수가 없다 — 쓰기 직전 대상 행을 조회해 저장소 밖에 저장해 둘 것(작업표 P4).
--   · 개인정보(시트의 페이팔 주소 등)는 이 파일에 넣지 않는다 — 입력은 실행 때 붙여넣는다.
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.backfill_settlement_transfers_from_sheet(jsonb);
--   ⚠️ 이 함수가 이미 쓴 묶음·연결·이력 행과 settlements 의 갱신은 되돌리지 않는다(되돌리려면 행별 수작업 — 이력에 옛 값이 문장으로 남는다).

BEGIN;

CREATE OR REPLACE FUNCTION public.backfill_settlement_transfers_from_sheet(p_bundles jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_b          record;
  v_it         record;
  v_e          jsonb;
  v_flat       jsonb := '[]'::jsonb;     -- 입력 평탄화(항목마다 1개)
  v_items      jsonb;                    -- 평탄화 + 정산 행 정보
  v_res        jsonb;                    -- 건너뛰지 않는 묶음의 항목 + 판정·받는 사람
  v_judge      jsonb;                    -- 미등록 응모 판정(헬퍼)
  v_skip       integer[] := ARRAY[]::integer[];
  v_skipped    jsonb := '[]'::jsonb;
  v_written    jsonb := '[]'::jsonb;
  v_witems     jsonb;
  v_rule       public.settlement_fee_rule%ROWTYPE;
  v_rule_ok    boolean := false;
  v_actor_name text;
  v_seq        integer := 0;
  v_id         uuid;
  -- 입력 검사용
  v_day        date;
  v_sent       timestamptz;
  v_sent_est   boolean;
  v_fee_est    boolean;
  v_fee_num    numeric;
  v_fee        bigint;
  v_bmemo      text;
  v_sid_text   text;
  v_app_text   text;
  v_id_text    text;
  v_rev_text   text;
  v_cby        text;
  v_crs        text;
  v_pp         text;
  v_link       text;
  v_amt        numeric;
  v_badb       integer;
  -- 쓰기용
  v_bidx       integer;
  v_iidx       integer;
  v_cls        text;
  v_conf       boolean;
  v_conf_txt   text;
  v_est_txt    text;
  v_note       text;
  v_status     text;
  v_sys        bigint;
  v_total      bigint;
  v_inf        uuid;
  v_tid        uuid;
  v_sid        uuid;
  v_amount     bigint;
  v_old_paid   timestamptz;
BEGIN
  -- ── 권한: settlement.pay 최소 write (486 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  IF p_bundles IS NULL OR jsonb_typeof(p_bundles) <> 'array' OR jsonb_array_length(p_bundles) = 0 THEN
    RAISE EXCEPTION 'invalid_input: 소급할 송금 묶음을 배열로 1개 이상 넘겨야 합니다' USING ERRCODE = '22023';
  END IF;

  SELECT a.name INTO v_actor_name FROM public.admins a WHERE a.auth_id = auth.uid() LIMIT 1;

  -- ============================================================
  -- 0) 입력 모양 검사 + 항목 평탄화 (틀리면 즉시 예외 — 건너뛰기보다 먼저)
  -- ============================================================
  FOR v_b IN
    SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
      FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
     ORDER BY o.ord
  LOOP
    IF jsonb_typeof(v_b.e) <> 'object' THEN
      RAISE EXCEPTION 'invalid_bundle: 묶음은 객체여야 합니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END IF;

    -- 송금일: 'YYYY-MM-DD' 문자열만
    IF jsonb_typeof(v_b.e -> 'sent_at') IS DISTINCT FROM 'string'
       OR (v_b.e ->> 'sent_at') !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'invalid_bundle: sent_at 은 YYYY-MM-DD 문자열이어야 합니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_day := (v_b.e ->> 'sent_at')::date;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid_bundle: sent_at 이 존재하지 않는 날짜입니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END;

    IF jsonb_typeof(v_b.e -> 'sent_at_estimated') NOT IN ('boolean', 'null')
       OR jsonb_typeof(v_b.e -> 'fee_estimated') NOT IN ('boolean', 'null') THEN
      RAISE EXCEPTION 'invalid_bundle: sent_at_estimated·fee_estimated 는 true/false 여야 합니다 (묶음 순번 %)', v_b.bidx
        USING ERRCODE = '22023';
    END IF;
    v_fee_est := COALESCE((v_b.e ->> 'fee_estimated')::boolean, false);

    -- 수수료: 추정이 아니면 숫자 필수. 추정이면 입력값은 쓰지 않으므로 보지 않는다
    IF NOT v_fee_est THEN
      IF jsonb_typeof(v_b.e -> 'fee_jpy') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'bundle_fee_required: 수수료 추정이 아니면 fee_jpy(숫자)가 필요합니다 (묶음 순번 %)', v_b.bidx
          USING ERRCODE = '22023';
      END IF;
      v_fee_num := (v_b.e ->> 'fee_jpy')::numeric;
      IF v_fee_num < 0 OR v_fee_num > 1000000000000 THEN
        RAISE EXCEPTION 'bundle_amount_invalid: 수수료는 0 이상이어야 합니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
      END IF;
    END IF;

    IF jsonb_typeof(v_b.e -> 'memo') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'invalid_bundle: memo 는 문자열이어야 합니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(v_b.e -> 'items') IS DISTINCT FROM 'array' OR jsonb_array_length(v_b.e -> 'items') = 0 THEN
      RAISE EXCEPTION 'bundle_empty: 묶음에 항목이 없습니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END IF;

    FOR v_it IN
      SELECT (q.ord - 1)::integer AS iidx, q.elem AS x
        FROM jsonb_array_elements(v_b.e -> 'items') WITH ORDINALITY AS q(elem, ord)
       ORDER BY q.ord
    LOOP
      IF jsonb_typeof(v_it.x) <> 'object' THEN
        RAISE EXCEPTION 'bundle_item_invalid: 항목은 객체여야 합니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;

      -- 지목: settlement_id 와 application_id 중 정확히 하나
      v_sid_text := NULLIF(btrim(v_it.x ->> 'settlement_id'), '');
      v_app_text := NULLIF(btrim(v_it.x ->> 'application_id'), '');
      IF (v_sid_text IS NULL) = (v_app_text IS NULL) THEN
        RAISE EXCEPTION 'bundle_item_invalid: settlement_id 또는 application_id 중 정확히 하나만 넣어야 합니다 (묶음 순번 %, 항목 순번 %)',
          v_b.bidx, v_it.iidx USING ERRCODE = '22023';
      END IF;
      v_id_text := COALESCE(v_sid_text, v_app_text);
      IF v_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'bundle_item_invalid: 아이디가 uuid 형식이 아닙니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;

      -- 기록 금액: 정수 > 0
      IF jsonb_typeof(v_it.x -> 'amount_jpy') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'bundle_amount_invalid: amount_jpy(숫자)가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;
      v_amt := (v_it.x ->> 'amount_jpy')::numeric;
      IF v_amt <= 0 OR v_amt <> trunc(v_amt) OR v_amt > 1000000000000 THEN
        RAISE EXCEPTION 'bundle_amount_invalid: 기록 금액은 0보다 큰 정수여야 합니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;

      -- 연결 방식
      v_link := COALESCE(NULLIF(btrim(v_it.x ->> 'link'), ''), 'current');
      IF v_link NOT IN ('current', 'old') THEN
        RAISE EXCEPTION 'bundle_link_invalid: link 는 current 또는 old 여야 합니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;
      v_rev_text := NULLIF(btrim(v_it.x ->> 'revert_event_id'), '');
      IF v_link = 'old' AND v_rev_text IS NULL THEN
        RAISE EXCEPTION 'bundle_revert_event_required: 옛 송금(old)에는 revert_event_id 가 필요합니다 (묶음 순번 %, 항목 순번 %)',
          v_b.bidx, v_it.iidx USING ERRCODE = '22023';
      END IF;
      IF v_link = 'current' AND v_rev_text IS NOT NULL THEN
        RAISE EXCEPTION 'bundle_link_invalid: 현재 송금(current)에는 revert_event_id 를 넣을 수 없습니다 (묶음 순번 %, 항목 순번 %)',
          v_b.bidx, v_it.iidx USING ERRCODE = '22023';
      END IF;
      IF v_rev_text IS NOT NULL
         AND v_rev_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'bundle_item_invalid: revert_event_id 가 uuid 형식이 아닙니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;

      -- 확인 표시: 확인자·사유가 둘 다 있을 때만
      v_cby := NULLIF(btrim(v_it.x ->> 'confirmed_by'), '');
      v_crs := NULLIF(btrim(v_it.x ->> 'confirm_reason'), '');
      IF (v_cby IS NULL) <> (v_crs IS NULL) THEN
        RAISE EXCEPTION 'bundle_confirm_incomplete: confirmed_by 와 confirm_reason 은 함께 넣어야 합니다 (묶음 순번 %, 항목 순번 %)',
          v_b.bidx, v_it.iidx USING ERRCODE = '22023';
      END IF;

      v_pp := NULLIF(btrim(v_it.x ->> 'paypal_email'), '');
      IF char_length(COALESCE(v_pp, '')) > 320 THEN
        RAISE EXCEPTION 'bundle_item_invalid: paypal_email 이 너무 깁니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_it.iidx
          USING ERRCODE = '22023';
      END IF;

      v_seq := v_seq + 1;
      v_flat := v_flat || jsonb_build_array(jsonb_build_object(
        'seq', v_seq, 'b', v_b.bidx, 'i', v_it.iidx,
        'kind', CASE WHEN v_sid_text IS NOT NULL THEN 's' ELSE 'a' END,
        'id', v_id_text, 'amount', v_amt::bigint, 'paypal', v_pp, 'link', v_link,
        'revert_event_id', v_rev_text, 'confirmed', (v_cby IS NOT NULL),
        'confirm_by', v_cby, 'confirm_reason', v_crs));
    END LOOP;
  END LOOP;

  -- ============================================================
  -- 1) 잠금 — 입력의 모든 정산 행(application_id 로 들어온 것도 기존 정산 행이 있으면)을 id 순으로, 판정보다 먼저
  -- ============================================================
  FOR v_id IN
    SELECT DISTINCT s.id
      FROM jsonb_to_recordset(v_flat) AS f(kind text, id uuid)
      JOIN public.settlements s
        ON (f.kind = 's' AND s.id = f.id) OR (f.kind = 'a' AND s.application_id = f.id)
     ORDER BY 1
  LOOP
    PERFORM 1 FROM public.settlements s WHERE s.id = v_id FOR UPDATE;
  END LOOP;

  -- 잠근 뒤의 값으로 항목마다 정산 행 정보를 붙인다
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.seq), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT f.seq, f.b, f.i, f.kind, f.id, f.amount, f.paypal, f.link, f.revert_event_id,
             f.confirmed, f.confirm_by, f.confirm_reason,
             s.id AS sid, s.application_id AS s_app, s.influencer_id AS s_inf, s.campaign_id AS s_camp,
             s.status AS s_status, s.amount_jpy AS s_amount, s.paid_at AS s_paid_at,
             s.paid_amount_jpy AS s_paid_amount, s.current_transfer_id AS s_cur, s.paypal_email AS s_paypal
        FROM jsonb_to_recordset(v_flat) AS f(
               seq integer, b integer, i integer, kind text, id uuid, amount bigint, paypal text, link text,
               revert_event_id uuid, confirmed boolean, confirm_by text, confirm_reason text)
        LEFT JOIN public.settlements s
          ON (f.kind = 's' AND s.id = f.id) OR (f.kind = 'a' AND s.application_id = f.id)
    ) t;

  -- 🔴 건너뛰기보다 먼저 — 입력 **전체**(건너뛸 묶음 포함)에서 같은 건이 둘 이상의 묶음에 현재 송금으로 들어왔는지.
  --    아래 중복 ② 는 건너뛴 묶음을 못 본다: 묶음 0(이미 반영됨 → 건너뜀)과 묶음 1 이 같은 건을 가지면
  --    묶음 1 만 조용히 쓰이고 묶음 0 의 나머지 항목은 안 쓰인다(사람이 묶음을 다시 짜야 하는 입력이 통과).
  SELECT (array_agg(t.b ORDER BY t.seq))[2] INTO v_badb
    FROM jsonb_to_recordset(v_items) AS t(seq integer, b integer, kind text, id uuid, link text, s_app uuid)
   WHERE t.link = 'current'
   GROUP BY COALESCE(t.s_app, CASE WHEN t.kind = 'a' THEN t.id END)
  HAVING count(DISTINCT t.b) > 1
   ORDER BY 1
   LIMIT 1;
  IF v_badb IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_duplicate_item: 같은 건이 둘 이상의 묶음에서 현재 송금으로 들어왔습니다 — 건너뛸 묶음 포함 (묶음 순번 %)', v_badb
      USING ERRCODE = '22023';
  END IF;
  v_badb := NULL;

  -- ============================================================
  -- 2) 「이미 반영됨」 — 그런 항목이 하나라도 든 묶음은 통째로 건너뛴다
  --    현재 송금 = 그 건에 current_transfer_id 가 있음 / 옛 송금 = 같은 건·같은 revert_event_id 의 옛 연결이 있음
  -- ============================================================
  SELECT COALESCE(array_agg(DISTINCT t.b ORDER BY t.b), ARRAY[]::integer[])
    INTO v_skip
    FROM jsonb_to_recordset(v_items) AS t(b integer, link text, revert_event_id uuid, sid uuid, s_cur uuid)
   WHERE t.sid IS NOT NULL
     AND (   (t.link = 'current' AND t.s_cur IS NOT NULL)
          OR (t.link = 'old' AND EXISTS (
                SELECT 1 FROM public.settlement_transfer_items ti
                 WHERE ti.settlement_id = t.sid AND ti.revert_event_id = t.revert_event_id)));

  SELECT COALESCE(jsonb_agg(jsonb_build_object('bundle_index', x, 'reason', 'already_applied') ORDER BY x), '[]'::jsonb)
    INTO v_skipped
    FROM unnest(v_skip) AS x;

  -- ============================================================
  -- 3) 남은 묶음의 항목 판정 — 미등록 응모는 헬퍼(486)로, 받는 사람은 정산 행 → 헬퍼 → applications 순으로
  -- ============================================================
  SELECT COALESCE(jsonb_agg(to_jsonb(j)), '[]'::jsonb)
    INTO v_judge
    FROM public._settlement_register_judge(
           ARRAY(SELECT t.id
                   FROM jsonb_to_recordset(v_items) AS t(b integer, kind text, id uuid, sid uuid)
                  WHERE t.sid IS NULL AND t.kind = 'a' AND NOT (t.b = ANY(v_skip)))
         ) j;

  SELECT COALESCE(jsonb_agg(
           to_jsonb(t) || jsonb_build_object(
             -- existing = 정산 행 있음 / candidate = 미등록 후보 / noncandidate = 후보 아님(응모는 있음) / missing = 가리키는 것이 없음
             'cls', CASE
                      WHEN t.sid IS NOT NULL                       THEN 'existing'
                      WHEN t.kind <> 'a' OR a.id IS NULL           THEN 'missing'
                      WHEN COALESCE(j.is_target, false)            THEN 'candidate'
                      ELSE                                              'noncandidate'
                    END,
             -- 🔴 후보 아님이면 헬퍼 값이 NULL 이라 applications 에서 직접 읽는다 — 헬퍼 값만 쓰면 「한 사람」 검사에서 조용히 빠진다
             'inf',  COALESCE(t.s_inf,  CASE WHEN COALESCE(j.is_target, false) THEN j.influencer_id ELSE a.user_id END),
             'camp', COALESCE(t.s_camp, CASE WHEN COALESCE(j.is_target, false) THEN j.campaign_id   ELSE a.campaign_id END),
             'app_key', COALESCE(t.s_app, CASE WHEN t.kind = 'a' THEN t.id END),
             'j_reason', j.reason, 'j_amount', j.amount_jpy, 'j_source', j.amount_source,
             'j_reward', j.reward_part_jpy, 'j_receipt', j.receipt_amount_jpy, 'j_cap', j.amount_cap_jpy,
             'j_cert', j.cert_at, 'j_paypal', j.paypal_email
           ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_res
    FROM jsonb_to_recordset(v_items) AS t(
           seq integer, b integer, i integer, kind text, id uuid, amount bigint, paypal text, link text,
           revert_event_id uuid, confirmed boolean, confirm_by text, confirm_reason text,
           sid uuid, s_app uuid, s_inf uuid, s_camp uuid, s_status text, s_amount bigint, s_paid_at timestamptz,
           s_paid_amount bigint, s_cur uuid, s_paypal text)
    LEFT JOIN jsonb_to_recordset(v_judge) AS j(
           application_id uuid, reason text, is_target boolean, amount_jpy bigint, amount_source text,
           reward_part_jpy bigint, receipt_amount_jpy bigint, amount_cap_jpy bigint, influencer_id uuid,
           campaign_id uuid, cert_at timestamptz, paypal_email text)
      ON t.sid IS NULL AND t.kind = 'a' AND j.application_id = t.id
    LEFT JOIN public.applications a
      ON t.sid IS NULL AND t.kind = 'a' AND a.id = t.id
   WHERE NOT (t.b = ANY(v_skip));

  -- ============================================================
  -- 4) 검사 — 하나라도 걸리면 RAISE(전체 거부, 아무것도 안 쓴다)
  -- ============================================================
  FOR v_e IN SELECT x.value FROM jsonb_array_elements(v_res) AS x(value)
  LOOP
    v_bidx := (v_e ->> 'b')::integer;
    v_iidx := (v_e ->> 'i')::integer;
    v_cls  := v_e ->> 'cls';
    v_link := v_e ->> 'link';
    v_conf := (v_e ->> 'confirmed')::boolean;

    IF v_cls = 'missing' THEN
      RAISE EXCEPTION 'bundle_not_found: 항목이 가리키는 정산 행·응모를 찾을 수 없습니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
        USING ERRCODE = '22023';
    END IF;
    IF v_e ->> 'j_reason' = 'already_registered' THEN
      RAISE EXCEPTION 'bundle_not_pending: 검사 중 다른 처리가 먼저 정산을 등록했습니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
        USING ERRCODE = '22023';
    END IF;

    -- 옛 송금: 그 revert_event_id 가 「그 건의 보류 해제 이력」인지 직접 확인(확인 표시와 무관하게 늘)
    IF v_link = 'old' THEN
      IF v_cls <> 'existing' OR NOT EXISTS (
           SELECT 1 FROM public.settlement_events ev
            WHERE ev.id = (v_e ->> 'revert_event_id')::uuid
              AND ev.settlement_id = (v_e ->> 'sid')::uuid
              AND ev.action = 'revert') THEN
        RAISE EXCEPTION 'bundle_revert_event_invalid: revert_event_id 가 그 건의 보류 해제(revert) 이력이 아닙니다 (묶음 순번 %, 항목 순번 %)',
          v_bidx, v_iidx USING ERRCODE = '22023';
      END IF;
    END IF;

    -- 확인 표시가 없는 항목(목록 A)의 조건
    IF NOT v_conf THEN
      IF v_link = 'old' THEN
        RAISE EXCEPTION 'bundle_old_link_unconfirmed: 옛 송금 연결은 확인 표시가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
          USING ERRCODE = '22023';
      END IF;
      IF v_cls = 'noncandidate' THEN
        RAISE EXCEPTION 'bundle_not_candidate: 인증 성공 후보가 아닌 미등록 응모는 확인 표시가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
          USING ERRCODE = '22023';
      END IF;
      IF v_cls = 'existing' THEN
        IF (v_e ->> 's_status') NOT IN ('paid', 'pending') THEN
          RAISE EXCEPTION 'bundle_status_not_allowed: 보류·취소 건은 확인 표시가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
            USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM public.settlement_events ev
                    WHERE ev.settlement_id = (v_e ->> 'sid')::uuid AND ev.action = 'revert') THEN
          RAISE EXCEPTION 'bundle_revert_history: 보류 해제 이력이 있는 건은 확인 표시가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
            USING ERRCODE = '22023';
        END IF;
        -- 🔴 송금완료 건의 시스템 금액 = COALESCE(paid_amount_jpy, amount_jpy) — paid_amount_jpy 는 NULL 이 정상
        v_sys := CASE WHEN (v_e ->> 's_status') = 'paid'
                      THEN COALESCE((v_e ->> 's_paid_amount')::bigint, (v_e ->> 's_amount')::bigint)
                      ELSE (v_e ->> 's_amount')::bigint END;
      ELSE
        v_sys := (v_e ->> 'j_amount')::bigint;       -- 미등록 후보 = 헬퍼 계산값
      END IF;
      IF (v_e ->> 'amount')::bigint IS DISTINCT FROM v_sys THEN
        RAISE EXCEPTION 'bundle_amount_mismatch: 기록 금액이 시스템 금액과 다릅니다 — 확인 표시가 필요합니다 (묶음 순번 %, 항목 순번 %)', v_bidx, v_iidx
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;

  -- 한 묶음 = 한 사람 (후보 아님 항목도 applications.user_id 로 센다)
  SELECT r.b INTO v_badb
    FROM jsonb_to_recordset(v_res) AS r(b integer, inf uuid)
   GROUP BY r.b
  HAVING count(DISTINCT r.inf) <> 1 OR bool_or(r.inf IS NULL)
   ORDER BY r.b
   LIMIT 1;
  IF v_badb IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_mixed_influencer: 한 묶음에 받는 사람이 둘 이상이거나 알 수 없습니다 (묶음 순번 %)', v_badb USING ERRCODE = '22023';
  END IF;

  -- 중복 ① 같은 묶음 안 같은 건
  v_badb := NULL;
  SELECT r.b INTO v_badb
    FROM jsonb_to_recordset(v_res) AS r(b integer, app_key uuid)
   GROUP BY r.b, r.app_key
  HAVING count(*) > 1
   ORDER BY r.b
   LIMIT 1;
  IF v_badb IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_duplicate_item: 한 묶음 안에 같은 건이 둘 이상입니다 (묶음 순번 %)', v_badb USING ERRCODE = '22023';
  END IF;

  -- 중복 ② 묶음 사이 같은 건의 현재 송금(둘째 이후 묶음을 지목)
  SELECT (array_agg(r.b ORDER BY r.seq))[2] INTO v_badb
    FROM jsonb_to_recordset(v_res) AS r(seq integer, b integer, link text, app_key uuid)
   WHERE r.link = 'current'
   GROUP BY r.app_key
  HAVING count(*) > 1
   ORDER BY 1
   LIMIT 1;
  IF v_badb IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_duplicate_item: 같은 건이 둘 이상의 묶음에서 현재 송금으로 들어왔습니다 (묶음 순번 %)', v_badb USING ERRCODE = '22023';
  END IF;

  -- 중복 ③ 같은 건·같은 revert_event_id 의 옛 송금이 둘
  SELECT (array_agg(r.b ORDER BY r.seq))[2] INTO v_badb
    FROM jsonb_to_recordset(v_res) AS r(seq integer, b integer, link text, sid uuid, revert_event_id uuid)
   WHERE r.link = 'old'
   GROUP BY r.sid, r.revert_event_id
  HAVING count(*) > 1
   ORDER BY 1
   LIMIT 1;
  IF v_badb IS NOT NULL THEN
    RAISE EXCEPTION 'bundle_duplicate_item: 같은 건의 같은 옛 송금이 둘 이상 들어왔습니다 (묶음 순번 %)', v_badb USING ERRCODE = '22023';
  END IF;

  -- 송금일이 내일보다 뒤인 묶음(486 과 같은 기준)
  FOR v_b IN
    SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
      FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
     ORDER BY o.ord
  LOOP
    IF v_b.bidx = ANY(v_skip) THEN CONTINUE; END IF;
    v_sent := ((v_b.e ->> 'sent_at')::date)::timestamp AT TIME ZONE 'Asia/Tokyo';
    IF v_sent > now() + interval '1 day' THEN
      RAISE EXCEPTION 'bundle_sent_at_in_future: 송금일이 앞날입니다 (묶음 순번 %)', v_b.bidx USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- ============================================================
  -- 5) 쓰기 — 여기부터의 예상 밖 오류는 예외로 전체 롤백
  -- ============================================================
  SELECT * INTO v_rule FROM public.settlement_fee_rule WHERE id = 1;
  v_rule_ok := FOUND;

  FOR v_b IN
    SELECT (o.ord - 1)::integer AS bidx, o.elem AS e
      FROM jsonb_array_elements(p_bundles) WITH ORDINALITY AS o(elem, ord)
     ORDER BY o.ord
  LOOP
    IF v_b.bidx = ANY(v_skip) THEN CONTINUE; END IF;

    v_day      := (v_b.e ->> 'sent_at')::date;
    v_sent     := (v_day::timestamp) AT TIME ZONE 'Asia/Tokyo';
    v_sent_est := COALESCE((v_b.e ->> 'sent_at_estimated')::boolean, false);
    v_fee_est  := COALESCE((v_b.e ->> 'fee_estimated')::boolean, false);
    v_bmemo    := NULLIF(btrim(v_b.e ->> 'memo'), '');
    v_est_txt  := CASE WHEN v_sent_est THEN '(추정)' ELSE '' END;

    SELECT (array_agg(r.inf))[1], sum(r.amount)::bigint
      INTO v_inf, v_total
      FROM jsonb_to_recordset(v_res) AS r(b integer, inf uuid, amount bigint)
     WHERE r.b = v_b.bidx;

    -- 수수료: 추정이면 서버 계산 + 규칙 스냅샷, 아니면 입력 반올림 + 스냅샷 비움(파일 머리말 「수수료」)
    IF v_fee_est THEN
      IF NOT v_rule_ok THEN
        RAISE EXCEPTION 'fee_rule_invalid: 수수료 규칙 행이 없습니다' USING ERRCODE = '22023';
      END IF;
      v_fee := public._settlement_fee_calc(v_total, v_rule.rate_percent, v_rule.fixed_jpy, v_rule.rounding);
    ELSE
      v_fee := round((v_b.e ->> 'fee_jpy')::numeric)::bigint;
    END IF;

    INSERT INTO public.settlement_transfers (
      sent_at, influencer_id, sent_total_jpy, fee_jpy,
      fee_rate_percent, fee_fixed_jpy, fee_rounding, fee_manual,
      paypal_txn_id, memo, source, recorded_by, sent_at_estimated, fee_estimated
    ) VALUES (
      v_sent, v_inf, v_total, v_fee,
      CASE WHEN v_fee_est THEN v_rule.rate_percent END,
      CASE WHEN v_fee_est THEN v_rule.fixed_jpy END,
      CASE WHEN v_fee_est THEN v_rule.rounding END,
      false,
      NULL, v_bmemo, 'sheet_backfill', auth.uid(), v_sent_est, v_fee_est
    )
    RETURNING id INTO v_tid;

    v_witems := '[]'::jsonb;

    FOR v_e IN
      SELECT x.value
        FROM jsonb_array_elements(v_res) WITH ORDINALITY AS x(value, ord)
       WHERE (x.value ->> 'b')::integer = v_b.bidx
       ORDER BY x.ord
    LOOP
      v_iidx   := (v_e ->> 'i')::integer;
      v_cls    := v_e ->> 'cls';
      v_link   := v_e ->> 'link';
      v_conf   := (v_e ->> 'confirmed')::boolean;
      v_amount := (v_e ->> 'amount')::bigint;
      v_sid    := (v_e ->> 'sid')::uuid;
      v_conf_txt := CASE WHEN v_conf
                         THEN ' [확인: ' || (v_e ->> 'confirm_by') || ' / ' || (v_e ->> 'confirm_reason') || ']'
                         ELSE '' END;
      -- 정산 행에 적을 시트 주소: 입력 → (없으면) 기존 정산 행 값 → 미등록 후보의 헬퍼 값
      v_pp := COALESCE(NULLIF(v_e ->> 'paypal', ''), NULLIF(v_e ->> 's_paypal', ''), NULLIF(v_e ->> 'j_paypal', ''));

      IF v_link = 'old' THEN
        -- 옛 송금: 연결만. 정산 행은 그대로 — 확인자·사유를 남기려 이력 한 줄만 추가
        INSERT INTO public.settlement_transfer_items (transfer_id, settlement_id, amount_jpy, revert_event_id)
        VALUES (v_tid, v_sid, v_amount, (v_e ->> 'revert_event_id')::uuid);

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (v_sid, 'correct', v_e ->> 's_status', v_e ->> 's_status', auth.uid(),
                format('[시트 소급] 옛 송금 연결(상태·현재 송금 기록 변경 없음) 송금일 %s%s, 송금액 ¥%s%s',
                       to_char(v_day, 'YYYY-MM-DD'), v_est_txt, v_amount::text, v_conf_txt));
      ELSE
        -- ── 현재 송금 ──
        IF v_cls IN ('candidate', 'noncandidate') THEN
          -- 미등록 응모: 정산 행을 먼저 정산대기로 만든다(486 'a' 분기와 같은 칸)
          v_sid := NULL;
          IF v_cls = 'candidate' THEN
            INSERT INTO public.settlements (
              influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
              receipt_amount_jpy, amount_cap_jpy, cert_at, status, paypal_email
            ) VALUES (
              (v_e ->> 'inf')::uuid, (v_e ->> 'id')::uuid, (v_e ->> 'camp')::uuid,
              (v_e ->> 'j_amount')::bigint, v_e ->> 'j_source', (v_e ->> 'j_reward')::bigint,
              (v_e ->> 'j_receipt')::bigint, (v_e ->> 'j_cap')::bigint, (v_e ->> 'j_cert')::timestamptz,
              'pending', NULLIF(v_e ->> 'j_paypal', '')
            )
            ON CONFLICT (application_id) DO NOTHING
            RETURNING id INTO v_sid;
            v_note := '[시트 소급] 미등록 응모를 송금 묶음으로 기록';
          ELSE
            -- 🔴 후보 아님: 회원·캠페인은 applications 에서 읽은 값, 금액은 기록 금액(계산값이 없다)
            INSERT INTO public.settlements (
              influencer_id, application_id, campaign_id, amount_jpy, status, paypal_email, memo
            ) VALUES (
              (v_e ->> 'inf')::uuid, (v_e ->> 'id')::uuid, (v_e ->> 'camp')::uuid,
              v_amount, 'pending', NULLIF(v_e ->> 'paypal', ''), '후보 아님 — 시트 소급 확인'
            )
            ON CONFLICT (application_id) DO NOTHING
            RETURNING id INTO v_sid;
            v_note := '후보 아님 — 시트 소급 확인';
          END IF;

          -- 검사 뒤 다른 곳이 먼저 만들었다 → 부분 기록 없이 전체 롤백
          IF v_sid IS NULL THEN
            RAISE EXCEPTION 'bundle_not_pending: 검사 뒤 다른 처리가 먼저 정산을 등록했습니다 (묶음 순번 %, 항목 순번 %)', v_b.bidx, v_iidx
              USING ERRCODE = '22023';
          END IF;

          INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
          VALUES (v_sid, 'create', NULL, 'pending', auth.uid(), v_note || v_conf_txt);
          v_status := 'pending';
        ELSE
          v_status := v_e ->> 's_status';
        END IF;

        INSERT INTO public.settlement_transfer_items (transfer_id, settlement_id, amount_jpy, revert_event_id)
        VALUES (v_tid, v_sid, v_amount, NULL);

        IF v_status = 'pending' THEN
          -- 정산대기·미등록: 486 기록과 같은 갱신. paypal_email 은 시트 주소
          v_note := format('[시트 소급] 송금일 %s%s, 송금액 ¥%s%s', to_char(v_day, 'YYYY-MM-DD'), v_est_txt, v_amount::text, v_conf_txt);
          UPDATE public.settlements s
             SET status              = 'paid',
                 paid_at             = v_sent,
                 paid_by             = auth.uid(),
                 paid_amount_jpy     = v_amount,                -- 항상 숫자(불변식 ②)
                 paypal_email        = COALESCE(v_pp, s.paypal_email),
                 current_transfer_id = v_tid,
                 memo                = CASE WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_note ELSE s.memo || E'\n' || v_note END,
                 version             = s.version + 1
           WHERE s.id = v_sid;

          INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
          VALUES (v_sid, 'pay', 'pending', 'paid', auth.uid(), v_note);

        ELSIF v_status = 'paid' THEN
          -- 이미 송금완료(현재 묶음 없음): 상태·paypal_email 그대로, 송금일·금액만 묶음 기준으로. 옛 값은 이력 문장에
          v_old_paid := (v_e ->> 's_paid_at')::timestamptz;
          v_note := format('[시트 소급] 송금일 %s → %s%s, 송금액 %s → ¥%s%s',
                           COALESCE(to_char(v_old_paid AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'), '(없음)'),
                           to_char(v_day, 'YYYY-MM-DD'), v_est_txt,
                           COALESCE('¥' || (v_e ->> 's_paid_amount'),
                                    '계산값(¥' || COALESCE(v_e ->> 's_amount', '?') || ')'),
                           v_amount::text, v_conf_txt);
          UPDATE public.settlements s
             SET paid_at             = v_sent,
                 paid_amount_jpy     = v_amount,
                 current_transfer_id = v_tid,
                 memo                = CASE WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_note ELSE s.memo || E'\n' || v_note END,
                 version             = s.version + 1
           WHERE s.id = v_sid;

          INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
          VALUES (v_sid, 'correct', 'paid', 'paid', auth.uid(), v_note);

        ELSE
          -- 보류·취소(확인 표시 있는 항목만 여기 온다): 상태는 그대로 두고 송금 기록·현재 묶음만. paypal_email 은 안 건드린다
          v_note := format('[시트 소급] 송금 기록 연결(상태 %s 유지) 송금일 %s%s, 송금액 ¥%s%s',
                           v_status, to_char(v_day, 'YYYY-MM-DD'), v_est_txt, v_amount::text, v_conf_txt);
          UPDATE public.settlements s
             SET paid_at             = v_sent,
                 paid_by             = COALESCE(s.paid_by, auth.uid()),
                 paid_amount_jpy     = v_amount,
                 current_transfer_id = v_tid,
                 memo                = CASE WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_note ELSE s.memo || E'\n' || v_note END,
                 version             = s.version + 1
           WHERE s.id = v_sid;

          INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
          VALUES (v_sid, 'correct', v_status, v_status, auth.uid(), v_note);
        END IF;
      END IF;

      v_witems := v_witems || jsonb_build_array(jsonb_build_object(
        'item_index', v_iidx, 'settlement_id', v_sid, 'application_id', v_e ->> 'app_key',
        'link', v_link, 'amount_jpy', v_amount));
    END LOOP;

    INSERT INTO public.settlement_transfer_events (transfer_id, action, prev, next, memo, actor, actor_name)
    VALUES (
      v_tid, 'create', NULL,
      jsonb_build_object(
        'sent_at', v_sent, 'sent_total_jpy', v_total, 'fee_jpy', v_fee, 'fee_manual', false,
        'fee_rate_percent', CASE WHEN v_fee_est THEN v_rule.rate_percent END,
        'fee_fixed_jpy',    CASE WHEN v_fee_est THEN v_rule.fixed_jpy END,
        'fee_rounding',     CASE WHEN v_fee_est THEN v_rule.rounding END,
        'paypal_txn_id', NULL, 'source', 'sheet_backfill',
        'sent_at_estimated', v_sent_est, 'fee_estimated', v_fee_est,
        'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                          'settlement_id', ti.settlement_id, 'amount_jpy', ti.amount_jpy,
                          'revert_event_id', ti.revert_event_id) ORDER BY ti.created_at, ti.id), '[]'::jsonb)
                    FROM public.settlement_transfer_items ti WHERE ti.transfer_id = v_tid)
      ),
      v_bmemo, auth.uid(), v_actor_name
    );

    v_written := v_written || jsonb_build_array(jsonb_build_object(
      'bundle_index', v_b.bidx, 'transfer_id', v_tid, 'items', v_witems));
  END LOOP;

  RETURN jsonb_build_object('written', v_written, 'skipped', v_skipped);
END;
$$;

COMMENT ON FUNCTION public.backfill_settlement_transfers_from_sheet(jsonb) IS
  '[501] 과거 지급 시트를 송금 묶음으로 소급 반영(출처 항상 sheet_backfill — 도입일을 만들지 않는다). 입력 묶음[{sent_at(YYYY-MM-DD), sent_at_estimated, fee_jpy, fee_estimated, memo, items[{settlement_id|application_id, amount_jpy, paypal_email, link(current|old), revert_event_id, confirmed_by, confirm_reason}]}]. '
  '이미 반영된 항목이 든 묶음은 통째로 건너뛰고(skipped), 남은 묶음을 전부 검사해 하나라도 걸리면 전체 거부. 페이팔 유무로 막지 않고 정산 행 paypal_email 은 입력의 시트 주소. '
  '수수료: 추정=서버 규칙 계산+스냅샷 3칸 / 아니면 입력 반올림+스냅샷 NULL+fee_manual=false(금액 정정에 덮이지 않게). 알림 없음. 관리자 로그인 브라우저에서 호출.';

-- 실행 권한: 회수 방향 둘(PUBLIC · anon) + authenticated 부여 — 486 record_settlement_transfers 와 같다
REVOKE ALL ON FUNCTION public.backfill_settlement_transfers_from_sheet(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.backfill_settlement_transfers_from_sheet(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.backfill_settlement_transfers_from_sheet(jsonb) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩 — 각 단계 결과를 확인하고 다음으로. 🔴 운영에서는 시험 호출하지 말 것)
-- ⚠️ 이 함수는 로그인한 관리자(settlement.pay 쓰기)만 호출할 수 있다 — SQL 편집기(서비스 키)에서는 권한 판정에 막힌다.
-- [1] SQL 편집기: 권한 확인 — proacl 맨 앞에 '=X/' 없음, anon= 없음, authenticated= 있음
--   SELECT p.proname, p.prosecdef, p.proconfig, p.proacl::text
--     FROM pg_proc p
--    WHERE p.proname = 'backfill_settlement_transfers_from_sheet';
--   -- prosecdef = true, proconfig 에 search_path= 가 있음
-- [2] 브라우저 콘솔(관리자 로그인): 입력 모양 오류가 예외로 나오는지 — 아무것도 안 쓰인다
--   (await db.rpc('backfill_settlement_transfers_from_sheet', { p_bundles: [] })).error   // invalid_input
-- [3] 브라우저 콘솔(개발서버 시험 입력): 정산대기 1건 + 추정 수수료 — 첫 호출 {written:[…], skipped:[]}, 같은 입력 둘째 호출 {written:[], skipped:[{already_applied}]}
--   p_bundles: [{ sent_at:'2026-06-15', sent_at_estimated:true, fee_estimated:true,
--                 items:[{ settlement_id:'<시험 정산 행>', amount_jpy:<그 행 amount_jpy>, paypal_email:'test@example.com' }] }]
-- [4] SQL 편집기: [3] 직후 불변식 위반 0건 (485 검증 [6] 과 같은 식)
--   SELECT count(*) FILTER (WHERE it.id IS NULL)                                                   AS missing_current_item,
--          count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_at IS DISTINCT FROM t.sent_at)       AS paid_at_mismatch,
--          count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_amount_jpy IS DISTINCT FROM it.amount_jpy) AS amount_mismatch
--     FROM public.settlements s
--     JOIN public.settlement_transfers t ON t.id = s.current_transfer_id
--     LEFT JOIN public.settlement_transfer_items it
--            ON it.settlement_id = s.id AND it.transfer_id = s.current_transfer_id AND it.revert_event_id IS NULL
--    WHERE s.current_transfer_id IS NOT NULL;   -- 세 값 모두 0
-- [5] SQL 편집기: 소급 묶음은 도입일에 안 들어간다 + 추정 표시·수수료 스냅샷 확인
--   SELECT source, sent_at_estimated, fee_estimated, fee_manual, fee_rate_percent, fee_fixed_jpy, fee_rounding
--     FROM public.settlement_transfers ORDER BY recorded_at DESC LIMIT 5;
--   SELECT public._settlement_transfer_intro_at();   -- sheet_backfill 만 있으면 NULL
-- [6] SQL 편집기: 알림이 한 건도 안 생겼다
--   SELECT count(*) FROM public.notifications WHERE created_at > now() - interval '10 minutes';   -- 시험 중 다른 알림이 없었다면 0
