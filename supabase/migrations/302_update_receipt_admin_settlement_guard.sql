-- ============================================================
-- 302_update_receipt_admin_settlement_guard.sql
-- 관리자 영수증 사후 수정에 정산 정합 가드 추가
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-1(재계산 기준),
--   §3-4 「영수증 금액 사후 수정 가드」(관리자 경로)
--
-- ── 배경 ──
--   299·300 로 리뷰어형(monitor) 정산 금액이 "그 응모의 최신 영수증(receipt_latest)
--   purchase_amount 를 캠페인 상시가로 상한을 씌운 값"이 됐다. 그런데 관리자가 영수증을
--   등록한 뒤(=정산이 이미 만들어진 뒤)에도 update_receipt_admin(마이그레이션 128→178)
--   RPC 로 purchase_amount 를 얼마든지 고칠 수 있고, 지금까지 그 수정은 정산과 아무
--   관계가 없었다(178 은 deliverables 만 UPDATE 하고 settlements 는 건드리지 않는다).
--   이 파일 적용 전에는 "저장된 정산액"과 "영수증에 실제로 적힌 금액"이 관리자의
--   사후 수정 한 번으로 조용히 어긋날 수 있었다 — §3-1 이 요구하는 "판정·금액 단일
--   소스" 원칙이 저장 시점 이후로는 지켜지지 않는 구멍.
--
-- ── update_receipt_admin 의 "현재 유효한 정의" 전수 확인(작업 착수 전) ──
--   grep -rl "update_receipt_admin" supabase/migrations/ 결과 4개 파일:
--     128(원본 CREATE) → 178(CREATE OR REPLACE, 3종 필수→최소 1개로 완화)
--     → 252(receipt_edit_history 테이블에 트리거 추가 — update_receipt_admin 본문 자체는
--       무변경, RPC 코드를 안 건드리고 트리거로 투명 처리한다고 252 파일에 명시)
--     → 301(deliverables 에 별도 트리거 trg_receipt_settlement_lock 추가 — 이 함수의
--       UPDATE 문도 그 트리거를 통과하지만, is_admin() 이 함수 안에서 이미 참인 호출만
--       이 지점에 도달하므로 301 트리거 1번 조건에서 항상 조기 통과한다. update_receipt_
--       admin 자체의 시그니처·본문은 301 도 건드리지 않았다).
--   → 이 함수의 "현재 유효한 정의"는 178. 이번 파일이 178 을 대체하는 재정의다.
--
-- ── 무엇을 바꾸는가(요약) ──
--   그 영수증(deliverables.kind='receipt')이 속한 응모(application_id)에 정산
--   (settlements) 행이 있으면:
--     · status IN ('paid','on_hold','cancelled') → 수정 자체를 차단(RAISE EXCEPTION,
--       178 의 UPDATE 문에 도달하기 전에 막는다 — 반려 차단 트리거 247 과 같은 사고방식)
--     · status = 'pending' → 수정은 허용하고, 저장 직후 "그 응모의 최신 영수증"을
--       다시 읽어 정산 금액을 재계산해 갱신한다(재계산이 "금액 미확정"으로 떨어지면
--       아래 「재계산 결과가 실패할 때」참고)
--     · 정산 행 자체가 없음 → 178 과 완전히 동일하게 동작(영향 없음)
--
-- ── ⚠️ 여기서는 취소(cancelled)도 차단 대상이다 — 301(영수증 신규 제출 차단)와
--    다른 이유(사용자 2026-08-05 확인) ──
--   301 은 "취소(cancelled)된 정산이 있는 응모"에 새 영수증을 내는 것은 막지 않는다
--   (인플루언서가 영구히 새 영수증을 못 내는 상태로 굳는 것을 피하기 위해서다 — 301
--   파일 상단 참고). 이 파일(302)은 그 반대로 취소도 막는다. 두 가드는 막는 대상과
--   목적이 다르다:
--     · 301(제출 차단) = 인플루언서가 "새 영수증 행"을 만드는 것을 막는다. 목적은
--       "정산 금액과 영수증이 어긋나는 것"을 막는 것이고, 취소된 정산은 지급 자체를
--       하지 않으므로 애초에 어긋날 금액이 없다 — 막을 이유가 약하고, 막으면 인플루언서가
--       영원히 갇히는 부작용이 크다.
--     · 302(이 파일, 수정 차단) = 관리자가 "이미 존재하는 영수증 행의 금액 칸"을 고치는
--       것을 막는다. 목적은 "확정된 금전 기록이 흔들리는 것"을 막는 것이다. 취소된
--       정산도 한때 계산됐던 금액(amount_jpy)이 감사 기록(settlement_events)에 남아
--       있고, 그 근거였던 영수증을 사후에 바꾸면 "그 취소가 어떤 금액을 근거로 이뤄졌는지"
--       를 사후에 다시 쓸 수 있게 된다 — 즉 "인플루언서가 갇히는" 부작용이 없고(관리자가
--       거는 가드일 뿐, 인플루언서의 다음 행동을 막지 않는다), 반대로 "막지 않으면
--       감사 기록의 근거가 사후에 바뀐다"는 위험만 남는다. 그래서 302 는 3종
--       (paid·on_hold·cancelled) 모두 차단한다.
--
-- ── 재계산 기준(사양서 §3-1) ──
--   · "최신 영수증" = 300 의 receipt_latest 와 완전히 같은 정렬 기준
--     (application_id 기준 submitted_at DESC, updated_at DESC 최신 1건). 지금 수정하는
--     행(p_deliverable_id)이 그 최신 행이 아닐 수도 있으므로, 별도로 "이 행이 최신인지"
--     따지지 않고 그냥 응모 기준으로 다시 조회한다 — 이 UPDATE 가 이미 커밋 전 같은
--     트랜잭션에 반영돼 있으므로 방금 고친 값이 그대로 보인다.
--   · 상한(캠페인 상시가) = **저장된 옛 상한(settlements.amount_cap_jpy)을 재사용하지
--     않고 campaigns.product_price 를 다시 읽는다** — 캠페인이 그 사이 수정됐을 수
--     있어서다(사양서 §3-1 "재계산 기준" 행 명시).
--   · 계산식은 300 과 완전히 같아야 한다: NULLIF(GREATEST(floor(LEAST(영수증, 상한)), 0), 0)
--     ⚠️ LEAST() 는 NULL 을 무시하는 함수라(300 파일 상단과 동일 경고) 두 값이 모두
--     유효(NOT NULL·0 초과)할 때만 호출한다. 300 의 헬퍼(_settlement_cert_candidates)를
--     그대로 호출하지 못하는 이유 — 그 헬퍼는 "아직 정산행이 없는" 응모만 대상으로
--     하는 CTE(candidates, NOT EXISTS settlements)라 이미 정산행이 있는 이 케이스에는
--     맞지 않는다. 그래서 같은 계산식을 이 함수 안에 별도로 복제했다 — **300 의 계산식이
--     바뀌면 이 함수도 함께 고쳐야 한다**(드리프트 위험, 파일 양쪽에 서로를 가리키는
--     경고 주석을 남긴다).
--   · 감사용 칸 2개(receipt_amount_jpy·amount_cap_jpy, 299)도 재계산 성공 시 함께
--     갱신한다 — 안 하면 관리자 화면의 "왜 이 금액인가" 설명이 거짓 근거를 표시한다
--     (사양서 §3-1 "재계산 기준" 행 명시).
--
-- ── 재계산 결과가 "금액 미확정"이 될 때 — 이 파일의 결정 사항(사양서에 답이 없던 지점) ──
--   settlements.amount_jpy 는 CHECK(amount_jpy > 0) 이라 0/NULL 로 UPDATE 할 수 없다.
--   후보 3가지 중 **"정산 행을 보류(on_hold)로 돌린다"를 택했다**:
--     A) 수정 자체를 거부한다 — 기각. 관리자가 정당하게 오기(잘못 적은 값)를 고치려는 시도까지
--        막아 버리면, 잘못된 영수증 값을 영구히 못 고치는 새로운 막다른 길이 생긴다.
--     B) 정산을 보류(on_hold)로 돌리고 amount_jpy 는 손대지 않는다 — **채택**.
--     C) 재계산을 실패로만 기록하고 상태·금액을 그대로 둔다 — 기각. "조용한 어긋남"을
--        막으려고 만드는 가드인데, 이 선택지는 그 어긋남을 그대로 허용하는 것과 같다.
--   B 를 택한 이유:
--     · amount_jpy 칸을 건드리지 않으므로 CHECK(amount_jpy>0) 위반이 원천적으로
--       발생하지 않는다(0/NULL 을 넣으려는 시도 자체가 없다).
--     · "확정된 금전 기록이 흔들리는 것을 막는다"는 이 가드 전체의 목적과 정확히
--       일치한다 — 마지막으로 유효했던 금액을 그대로 보존한 채, 사람이 다시 검토할
--       때까지 더 이상 손대지 못하게 잠근다(on_hold 가 되면 이 함수 자신의 위쪽 차단
--       규칙에 걸려 재편집이 막힌다 — 아래 참고).
--     · 이미 있는 인프라를 그대로 재사용한다 — 관리자 정산 페인에 "보류 해제" 버튼이
--       이미 있고(마이그레이션 224 mark_settlement_revert, 화면 dev/js/admin-settlements.js),
--       관리자는 ①보류 해제로 pending 복귀 → ②영수증을 다시 올바르게 고침 → ③이 함수가
--       재실행되며 재계산 성공 이라는 흐름으로 스스로 복구할 수 있다. 새 UI 를 만들
--       필요가 없다.
--     · 정확히 같은 판단 패턴이 이 저장소에 이미 있다 — 246(auto_hold_settlement_on_app_
--       reject) 이 "신청이 반려되면 pending 정산을 자동으로 on_hold 로 돌린다"를 트리거로
--       구현해 뒀다. 이 파일은 그 판단을 "영수증 금액이 더 이상 신뢰할 수 없게 됐을 때"
--       라는 새 트리거 조건에 적용하는 것뿐이다.
--   ⚠️ amount_jpy·amount_source·receipt_amount_jpy·amount_cap_jpy 는 전부 이전 값
--   그대로 둔다(보류 시점 스냅샷 보존) — 재계산에 실패했다고 새 계산값(무효)을 감사
--   칸에 채우면 "왜 예전 금액이 지금 이상한 숫자로 보이는가"라는 혼란만 남긴다.
--
-- ── settlement_events.action 확장: 'recalc' 신설 ──
--   기존 5종(create/pay/hold/cancel/revert, 217) 중 어느 것도 "상태는 그대로(pending→
--   pending)인데 금액만 바뀌었다"는 사건을 표현하지 못한다. 그래서 'recalc' 를 새로
--   추가한다(52 recalc_brand_application_totals 등 이 저장소가 이미 "재계산"에 쓰는
--   용어와 동일). prev_status·next_status 는 둘 다 'pending' 으로 남긴다(CHECK 도메인
--   안에서 유효 — 상태가 안 바뀌었다는 사실 자체가 기록에 남는 편이 낫다).
--   "금액 미확정으로 자동 보류"되는 쪽은 **새 action 을 만들지 않고 기존 'hold' 를
--   재사용한다** — 246 이 이미 "자동 보류"를 별도 action 없이 memo 로만 구분하는
--   전례를 세워 뒀다(246 파일 "감사 구분" 섹션 참고). 같은 관례를 따른다.
--
-- ── ⚠️ 자동 보류 memo 문구는 반드시 "자동 보류"라는 두 글자 연속 표현을 피한다 ──
--   dev/js/admin-settlements.js:338 이 `(s.memo || '').includes('자동 보류')` 로
--   "신청 반려로 자동 보류"(246) 앰버 배지를 그린다. 이 파일이 만드는 자동 보류는
--   원인이 "신청 반려"가 아니라 "영수증 금액 확정 불가"이므로, memo 에 그 문자열
--   그대로가 들어가면 화면이 **엉뚱한 사유("신청이 반려·취소되어 자동 보류된 정산입니다")
--   를 사용자에게 보여준다.** 그래서 이 파일의 memo 문구는 "보류 처리"라고만 쓰고
--   "자동"과 "보류"를 붙여 쓰지 않는다(예: "영수증 수정으로 금액을 확정할 수 없어
--   보류 처리됨" — "자동"이라는 단어 자체가 없다). 이 gap 을 구분해 보여줄 전용 배지는
--   2단계(관리자 화면) 범위 — 지금은 "잘못된 기존 배지가 뜨는 것"만 피한다.
--
-- ── 권한: is_campaign_admin() 그대로, has_permission('settlement.pay') 추가 안 함 ──
--   정산 금액을 실제로 움직이는 RPC(mark_settlement_paid/hold/cancel/revert,
--   register_past_settlements) 는 has_permission('settlement.pay','write') 로 따로
--   막혀 있다(220 시드: campaign_admin=write, campaign_manager=hidden — 슈퍼관리자가
--   나중에 이 값을 등급별로 더 좁힐 수도 있는 동적 권한). 이 함수는 그 RPC 들을 직접
--   호출하는 게 아니라 "영수증 수정"이라는, 이미 is_campaign_admin() 으로 허가된 행위의
--   **자동 부수 효과**로 정산을 건드린다 — 246(신청 반려 시 자동 보류) 도 has_permission
--   검사 없이 신청 상태 변경 권한에만 의존하는 것과 같은 성격이다. 그래서 이 함수에
--   settlement.pay 검사를 추가로 걸지 않는다(추가하면 오히려 "영수증은 고쳤는데 정산은
--   조용히 안 맞아도 되는" 이 파일이 막으려는 그 구멍이 다시 열린다 — 권한이 없다고
--   그냥 통과시킬 수는 없고, 권한이 없다고 영수증 수정 자체를 막는 것도 178 의 기존
--   범위를 벗어난다).
--
-- ── ⚠️ PL/pgSQL FOUND 변수 함정 ──
--   settlements 를 조회한 직후의 FOUND 는 그 다음에 실행되는 아무 SQL 문(INSERT 등)
--   에도 계속 덮어써진다. 이 함수 본문에서 정산 조회 이후 여러 문장(deliverables
--   UPDATE·receipt_edit_history INSERT)이 이어지므로, 나중에 "정산이 있었는지"를
--   판단할 때 암묵적 FOUND 를 다시 참조하면 엉뚱한 문장의 결과를 읽게 된다. 그래서
--   정산 조회 직후 명시적 불리언 변수(v_settlement_found)에 그 순간의 FOUND 값을
--   즉시 옮겨 담고, 이후로는 전부 그 변수만 사용한다.
--
-- ── 반환값 설계(화면이 쓸 수 있도록) ──
--   기존 178 은 RETURNS void. 이 파일은 RETURNS TABLE(4컬럼)로 바꾼다 — 인자 목록
--   (uuid, text, date, numeric)은 그대로지만 반환 타입이 바뀌므로 CREATE OR REPLACE 로는
--   안 되고 DROP 후 CREATE 가 필요하다(300 이 get_past_unregistered_settlements 에
--   적용한 것과 동일 이유). storage.js 의 updateReceiptAdmin() 은 현재 {error} 만
--   구조분해하고 반환된 data 를 쓰지 않으므로(dev/lib/storage.js:1209) 이 반환 타입
--   변경만으로는 기존 화면 동작이 깨지지 않는다 — 새 값은 2단계(관리자 화면)가
--   토스트 문구("정산 금액이 N엔으로 재계산되었습니다" 등)를 만들 때 쓸 재료다.
--   반환 컬럼 4개:
--     settlement_status         — 처리 후 정산 상태. 정산 행 자체가 없으면 NULL.
--     settlement_recalculated   — 이번 호출로 정산 금액(amount_jpy)이 실제로 바뀌어
--                                  저장됐으면 true. 변경 없음(no-op·정산 없음·자동 보류)
--                                  이면 false.
--     settlement_amount_jpy     — 처리 후 정산 금액(엔). 정산이 없으면 NULL. 자동
--                                  보류된 경우 예전 값 그대로.
--     settlement_amount_issue   — 재계산 결과가 "금액 미확정"이 되어 자동 보류된
--                                  경우의 사유 문구. 그 외에는 NULL.
--   (paid/on_hold/cancelled 로 차단된 경우는 RAISE EXCEPTION 으로 트랜잭션이 끝나므로
--   이 반환값 자체가 존재하지 않는다 — 클라는 그 상황을 error 로 받는다, 301 과 동일)
--
-- ── 128/178 대비 변경 사항 요약 ──
--   [유지] 권한 가드(is_campaign_admin) · 입력 정규화·검증(최소 1개, 주문번호 200자,
--     구매금액 음수 금지) · 대상 행 조회 FOR UPDATE · kind='receipt' 검증 · no-op 시
--     이력 미기록 · receipt_edit_history INSERT
--   [신규] 정산 조회(FOR UPDATE) · paid/on_hold/cancelled 차단 · pending 이면 저장
--     직후 재계산·감사 칸 갱신·settlement_events 기록 · 재계산 실패 시 on_hold 자동
--     전환 · 반환 타입 void → TABLE(4컬럼)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. settlement_events.action CHECK 확장 — 'recalc' 추가(217 원본 5종 → 6종)
--    DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴(160/162/299 와 동일, 재실행 안전)
-- ============================================================
ALTER TABLE public.settlement_events
  DROP CONSTRAINT IF EXISTS settlement_events_action_check;

ALTER TABLE public.settlement_events
  ADD CONSTRAINT settlement_events_action_check
  CHECK (action IN (
    'create',  -- 정산 최초 생성(backfill_settlements/register_past_settlements)
    'pay',     -- 송금완료 처리(mark_settlement_paid, 222)
    'hold',    -- 보류(관리자 수동 mark_settlement_hold, 223 / 신청 반려 자동, 246 /
               -- 영수증 재계산 실패 자동, 302 — memo 로 사유 구분)
    'cancel',  -- 취소(mark_settlement_cancel, 223)
    'revert',  -- 보류 해제·pending 복귀(mark_settlement_revert, 224)
    'recalc'   -- [302 신규] 상태는 그대로(pending→pending)인데 영수증 사후 수정으로
               -- 금액(amount_jpy)만 재계산되어 바뀐 사건
  ));

-- ============================================================
-- 2. update_receipt_admin 재정의 — 반환 타입 변경(void→TABLE)이라 DROP 후 CREATE
-- ============================================================
DROP FUNCTION IF EXISTS public.update_receipt_admin(uuid, text, date, numeric);

CREATE FUNCTION public.update_receipt_admin(
  p_deliverable_id  uuid,
  p_order_number    text,
  p_purchase_date   date,
  p_purchase_amount numeric
)
RETURNS TABLE (
  settlement_status       text,
  settlement_recalculated boolean,
  settlement_amount_jpy   bigint,
  settlement_amount_issue text
)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_prev                  record;   -- 대상 영수증 행(order_number/purchase_date/purchase_amount/kind/application_id)
  v_admin_name             text;
  v_trimmed_order          text;
  v_order_to_save          text;    -- NULLIF(v_trimmed_order, '') — 저장에 사용할 최종값

  v_settlement             record;  -- 그 응모의 정산 행(있으면)
  v_settlement_found       boolean; -- FOUND 함정 방지용 명시적 플래그(파일 상단 경고 참고)

  v_latest_receipt_amount  numeric; -- 저장 직후 다시 읽은 "그 응모의 최신 영수증" 결제 금액
  v_cap                    bigint;  -- 다시 읽은 캠페인 상시가(product_price, 옛 스냅샷 재사용 금지)
                                    -- campaigns.product_price 는 bigint(003) — 300 과 타입을 맞춘다
  v_new_amount             bigint;  -- 재계산된 정산 금액
  v_new_receipt_snapshot   bigint;  -- 재계산된 감사용 칸 — 영수증 원금액(floor)
  v_new_cap_snapshot       bigint;  -- 재계산된 감사용 칸 — 적용 상한
  v_amount_issue           text;    -- 재계산 실패 사유(정상이면 NULL)
  v_recalculated           boolean := false;
  v_out_status             text;    -- 반환용: 처리 후 정산 상태
  v_out_amount             bigint;  -- 반환용: 처리 후 정산 금액
BEGIN
  -- ── 권한 가드: campaign_admin 이상(178 과 동일, 변경 없음) ──────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 정규화(178 과 동일) ─────────────────────────────────────────
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  v_order_to_save := NULLIF(v_trimmed_order, '');

  -- ── 입력 검증: 최소 1개 필수(178 과 동일) ──────────────────────────
  IF v_order_to_save IS NULL
     AND p_purchase_date   IS NULL
     AND p_purchase_amount IS NULL
  THEN
    RAISE EXCEPTION '주문번호·구매일·구매금액 중 최소 1개는 입력해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  IF v_order_to_save IS NOT NULL AND length(v_order_to_save) > 200 THEN
    RAISE EXCEPTION '주문번호는 200자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  IF p_purchase_amount IS NOT NULL AND p_purchase_amount < 0 THEN
    RAISE EXCEPTION '구매금액은 0 이상이어야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 조회(178 과 동일 + application_id 추가 조회) ───────────
  SELECT order_number, purchase_date, purchase_amount, kind, application_id
    INTO v_prev
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다 (id: %)', p_deliverable_id USING ERRCODE = '02000';
  END IF;

  IF v_prev.kind != 'receipt' THEN
    RAISE EXCEPTION '영수증 결과물만 수정 가능합니다 (kind=receipt 필요, 실제: %)', v_prev.kind
      USING ERRCODE = '22023';
  END IF;

  -- ── [302 신규] 그 응모의 정산 조회 + 상태별 차단 ────────────────────
  -- FOR UPDATE 로 행 잠금 — mark_settlement_*() RPC 들과의 동시 처리 경쟁 방지.
  -- settlements.application_id 는 UNIQUE(217) 이므로 최대 1행만 매칭된다.
  SELECT id, status, version, amount_jpy, campaign_id, receipt_amount_jpy, amount_cap_jpy
    INTO v_settlement
    FROM public.settlements
   WHERE application_id = v_prev.application_id
   FOR UPDATE;
  v_settlement_found := FOUND;  -- 이후 문장이 FOUND 를 계속 덮어쓰므로 즉시 변수로 옮김

  -- 송금완료(paid)·보류(on_hold)·취소(cancelled) — 수정 자체를 차단.
  -- (파일 상단 "여기서는 취소도 차단 대상" 설명 참고 — 301 의 제출 차단과 집합이 다르다)
  IF v_settlement_found AND v_settlement.status IN ('paid', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'settlement_locked_receipt_edit: 이미 처리된 정산(송금완료·보류·취소)이 연결된 영수증은 수정할 수 없습니다. 정산 상태를 먼저 확인해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  -- ── no-op 체크(178 과 동일) ──────────────────────────────────────
  -- 정산 잠금 차단(바로 위)을 먼저 통과한 뒤에 검사한다 — 값이 실제로 바뀌는지와
  -- 무관하게 "정산이 paid/on_hold/cancelled 면 이 함수 호출 자체를 막는다"는 규칙을
  -- 예외 없이 적용하기 위해서다(잠긴 정산에는 no-op 호출도 허용하지 않는다).
  IF v_prev.order_number    IS NOT DISTINCT FROM v_order_to_save
     AND v_prev.purchase_date   IS NOT DISTINCT FROM p_purchase_date
     AND v_prev.purchase_amount IS NOT DISTINCT FROM p_purchase_amount
  THEN
    RETURN QUERY SELECT
      (CASE WHEN v_settlement_found THEN v_settlement.status ELSE NULL END),
      false,
      (CASE WHEN v_settlement_found THEN v_settlement.amount_jpy ELSE NULL END),
      NULL::text;
    RETURN;
  END IF;

  -- ── 관리자 이름 스냅샷(178 과 동일) ──────────────────────────────
  SELECT name INTO v_admin_name
    FROM public.admins
   WHERE auth_id = auth.uid()
   LIMIT 1;

  -- ── deliverables UPDATE(178 과 동일) ─────────────────────────────
  UPDATE public.deliverables
     SET order_number    = v_order_to_save,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT(178 과 동일) ─────────────────────
  INSERT INTO public.receipt_edit_history (
    deliverable_id, changed_by, changed_by_name,
    order_number_prev, order_number_next,
    purchase_date_prev, purchase_date_next,
    purchase_amount_prev, purchase_amount_next,
    source
  ) VALUES (
    p_deliverable_id, auth.uid(), COALESCE(v_admin_name, '(이름미상)'),
    v_prev.order_number, v_order_to_save,
    v_prev.purchase_date, p_purchase_date,
    v_prev.purchase_amount, p_purchase_amount,
    'admin_edit'
  );

  -- ── [302 신규] 정산이 정산대기(pending)면 저장 직후 재계산 ─────────
  IF v_settlement_found AND v_settlement.status = 'pending' THEN
    -- "최신 영수증" 재조회 — 300 receipt_latest 와 완전히 동일한 정렬 기준.
    -- 방금 위에서 커밋 전 UPDATE 한 값이 같은 트랜잭션 안이라 바로 보인다.
    SELECT purchase_amount
      INTO v_latest_receipt_amount
      FROM public.deliverables
     WHERE application_id = v_prev.application_id AND kind = 'receipt'
     ORDER BY submitted_at DESC, updated_at DESC
     LIMIT 1;

    -- 상한 재조회 — 저장된 옛 amount_cap_jpy 재사용 금지, campaigns 를 다시 읽는다.
    SELECT product_price
      INTO v_cap
      FROM public.campaigns
     WHERE id = v_settlement.campaign_id;

    -- amount_issue 판정 3종 — 300 과 완전히 동일한 조건(⚠️ 300 계산식이 바뀌면
    -- 이 블록도 함께 고칠 것 — 파일 상단 "재계산 기준" 절 경고 참고)
    IF v_latest_receipt_amount IS NULL OR v_latest_receipt_amount <= 0 THEN
      v_amount_issue := '리뷰어형 영수증 결제 금액(purchase_amount) 값 없음 또는 0 이하';
    ELSIF v_cap IS NULL OR v_cap <= 0 THEN
      v_amount_issue := '리뷰어형 제품 가격(product_price, 지급 상한) 값 없음 또는 0 이하';
    ELSIF floor(LEAST(v_latest_receipt_amount, v_cap::numeric)) <= 0 THEN
      v_amount_issue := '리뷰어형 정산 금액이 소수점 절사 후 0 이하';
    ELSE
      v_amount_issue := NULL;
    END IF;

    IF v_amount_issue IS NOT NULL THEN
      -- ── 재계산 실패 → 자동 보류(파일 상단 "재계산 결과가 금액 미확정" 절 결정 B) ──
      -- amount_jpy/amount_source/receipt_amount_jpy/amount_cap_jpy 는 절대 건드리지
      -- 않는다 — CHECK(amount_jpy>0) 보호 + "확정된 금전 기록 보존" 원칙.
      -- ⚠️ memo 에 "자동 보류"라는 연속 문자열을 절대 쓰지 않는다(파일 상단 경고 참고 —
      -- dev/js/admin-settlements.js:338 의 신청반려 배지와 충돌한다).
      UPDATE public.settlements
         SET status  = 'on_hold',
             memo    = '영수증 수정으로 금액을 확정할 수 없어 보류 처리됨 (' || v_amount_issue || ')',
             version = version + 1
       WHERE id = v_settlement.id;

      INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
      VALUES (
        v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(),
        '영수증 수정 후 정산 금액 재계산 불가로 보류 처리 (' || v_amount_issue || ')'
      );

      v_out_status := 'on_hold';
      v_out_amount := v_settlement.amount_jpy;  -- 예전 값 그대로(변경 없음)
      v_recalculated := false;
    ELSE
      -- ── 재계산 성공 — 300 과 완전히 동일한 계산식 ──
      v_new_amount           := NULLIF(GREATEST(floor(LEAST(v_latest_receipt_amount, v_cap::numeric)), 0), 0)::bigint;
      v_new_receipt_snapshot := floor(v_latest_receipt_amount)::bigint;
      v_new_cap_snapshot     := v_cap::bigint;

      -- 실제로 달라질 때만 UPDATE+이력 기록(불필요한 settlement_events 잡음 방지 —
      -- 이 영수증 행이 "최신"이 아니었거나 값이 우연히 같으면 아무것도 안 바뀐다)
      IF v_new_amount           IS DISTINCT FROM v_settlement.amount_jpy
         OR v_new_receipt_snapshot IS DISTINCT FROM v_settlement.receipt_amount_jpy
         OR v_new_cap_snapshot     IS DISTINCT FROM v_settlement.amount_cap_jpy
      THEN
        UPDATE public.settlements
           SET amount_jpy         = v_new_amount,
               amount_source      = 'receipt_amount',
               receipt_amount_jpy = v_new_receipt_snapshot,
               amount_cap_jpy     = v_new_cap_snapshot,
               version            = version + 1
         WHERE id = v_settlement.id;

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (
          v_settlement.id, 'recalc', 'pending', 'pending', auth.uid(),
          '영수증 수정으로 정산 금액 재계산: ' || COALESCE(v_settlement.amount_jpy::text, '(없음)')
            || '엔 → ' || v_new_amount || '엔'
        );

        v_out_amount    := v_new_amount;
        v_recalculated  := true;
      ELSE
        v_out_amount := v_settlement.amount_jpy;  -- 재계산했지만 값이 같음 — no-op
      END IF;

      v_out_status := 'pending';  -- 재계산 성공 경로는 상태가 바뀌지 않는다
    END IF;
  ELSIF v_settlement_found THEN
    -- 이 지점에 도달했다는 것 자체가 이론상 불가능하다 — status IN ('paid','on_hold',
    -- 'cancelled') 는 위에서 이미 차단됐고, 남는 값은 'pending' 뿐이다(217 CHECK 로
    -- status 는 4종만 존재). 방어적으로 기존 값을 그대로 반환한다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  END IF;

  RETURN QUERY SELECT v_out_status, v_recalculated, v_out_amount, v_amount_issue;
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '[302 재정의, 178 원본 대체(반환 타입 void→TABLE, 정산 정합 가드 추가)] 관리자가 '
  'deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 '
  '기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 그 응모에 정산(settlements)이 '
  '있으면: paid/on_hold/cancelled 는 수정 차단(RAISE EXCEPTION), pending 은 수정 허용 후 '
  '최신 영수증·현재 캠페인 상시가로 정산 금액을 재계산해 갱신(변경 시 settlement_events '
  'action=recalc 기록). 재계산이 "금액 미확정"이 되면 amount_jpy 는 그대로 두고 정산을 '
  'on_hold 로 자동 전환(action=hold, memo 로 사유 구분). 정산 행이 없으면 178 과 동일 동작.';

REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 299·300·301 까지 적용된 뒤에 실행할 것.
--
--   ⚠️ is_campaign_admin() 은 auth.uid() 를 참조하므로 SQL Editor 의 기본 서비스 키
--   세션(auth.uid() IS NULL)으로는 이 함수를 직접 호출할 수 없다(178 원본부터 있던
--   제약, 302 가 새로 만든 제약이 아님). 아래 [V4] 부터는 274/301 과 동일한
--   "request.jwt.claims 로 관리자 계정을 흉내내는" 방식을 쓴다 — 이 함수는
--   SECURITY DEFINER 로 deliverables/settlements 를 직접 UPDATE 하므로(행 단위
--   보안 정책을 거치지 않음), 이 흉내내기 방식만으로 대부분의 분기를 SQL Editor
--   안에서 검증할 수 있다(301 의 "브라우저 필수" 제약과 다른 점 — 301 은 RLS INSERT
--   정책이 관여했지만 이 함수는 함수 내부 UPDATE 라 흉내내기로 충분하다). 다만
--   [V8](실제 저장 버튼 클릭 후 화면이 안 깨지는지)은 브라우저 확인을 권장한다.
-- ============================================================
/*

-- [V0] 함수·제약 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'update_receipt_admin';

SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.settlement_events'::regclass
  AND conname = 'settlement_events_action_check';
-- 기대: 'recalc' 가 허용 목록에 보임

-- [V1] 테스트 대상 확보 — status='pending' 정산 + 그 응모의 최신 영수증 1건
SELECT s.id AS settlement_id, s.version, s.status, s.amount_jpy, s.receipt_amount_jpy,
       s.amount_cap_jpy, s.campaign_id, a.user_id, d.id AS deliverable_id, d.purchase_amount
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending'
 ORDER BY d.submitted_at DESC
 LIMIT 5;

-- [V2] 차단 대상 확보 — status IN ('paid','on_hold','cancelled') 정산 + 그 응모의 영수증 1건
SELECT s.id AS settlement_id, s.status, a.user_id, d.id AS deliverable_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status IN ('paid', 'on_hold', 'cancelled')
 LIMIT 5;

-- [V3] admins 계정 하나 확보(흉내낼 관리자) — campaign_admin 이상
SELECT auth_id, name, role FROM public.admins
 WHERE role IN ('super_admin', 'campaign_admin') LIMIT 3;

-- [V4] 차단 확인 — [V2] 의 deliverable_id 를 [V3] 관리자로 수정 시도(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V2 의 deliverable_id>'::uuid, '테스트주문', '2026-08-01'::date, 3000
  );
  -- 기대: ERROR — settlement_locked_receipt_edit: 이미 처리된 정산(...)이 연결된...
ROLLBACK;

-- [V5] 재계산 성공 확인 — [V1] 의 deliverable_id 에 상한(product_price)보다 낮은
--   금액으로 수정(반드시 ROLLBACK, 실제 반영은 [V7] 에서)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V1 의 deliverable_id>'::uuid, null, null, 1234
  );
  -- 기대: settlement_status='pending', settlement_recalculated=true,
  --       settlement_amount_jpy=1234(또는 상한 이하 시 그 값), settlement_amount_issue=NULL
ROLLBACK;

-- [V6] 재계산 실패(금액 미확정) 확인 — [V1] 의 deliverable_id 에 0 을 넣어 시도
--   ⚠️ purchase_amount=0 은 178 자체 검증("음수만 차단")은 통과하지만 302 재계산에서
--   "영수증 결제 금액 없음/0 이하"로 판정돼야 한다(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V1 의 deliverable_id>'::uuid, null, null, 0
  );
  -- 기대: settlement_status='on_hold', settlement_recalculated=false,
  --       settlement_amount_jpy=(V1 의 기존 amount_jpy 그대로), settlement_amount_issue IS NOT NULL
  SELECT status, memo, amount_jpy FROM public.settlements WHERE id = '<V1 의 settlement_id>';
  -- 기대: status='on_hold', memo 에 "자동 보류"라는 연속 문자열이 없어야 함(위 검색 참고),
  --       amount_jpy 는 트랜잭션 내에서만 바뀌지 않은 값 확인(ROLLBACK 이라 실제 반영 안 됨)
ROLLBACK;

-- [V7] 실제 반영 확인(선택, COMMIT) — [V5] 를 실제로 커밋해 settlement_events 에
--   action='recalc' 행이 남는지 확인
-- BEGIN;
--   SELECT set_config('request.jwt.claims', json_build_object('sub','<V3 의 auth_id>')::text, true);
--   SELECT * FROM public.update_receipt_admin('<V1 의 deliverable_id>'::uuid, null, null, 1234);
-- COMMIT;
-- SELECT action, prev_status, next_status, memo FROM public.settlement_events
--  WHERE settlement_id = '<V1 의 settlement_id>' ORDER BY at DESC LIMIT 1;
-- -- 기대: action='recalc', prev_status='pending', next_status='pending'

-- [V8] 회귀 — 정산이 아예 없는 응모의 영수증을 관리자 화면(브라우저)에서 정상 수정.
--   기대: 기존과 동일하게 성공(에러 없음), receipt_edit_history 에 새 행 1건.

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ settlement_events 에 이미 action='recalc' 행이 쌓였다면, CHECK 제약을 5종으로
--    되돌리기 전에 그 행들을 먼저 삭제하거나 action 값을 다른 값으로 바꿔야 한다
--    (그렇지 않으면 아래 ADD CONSTRAINT 자체가 기존 데이터 위반으로 실패한다).
--
-- DROP FUNCTION IF EXISTS public.update_receipt_admin(uuid, text, date, numeric);
-- -- 178 버전(RETURNS void, 정산 가드 없음)으로 복원하려면
-- -- supabase/migrations/178_relax_update_receipt_admin.sql 의
-- -- "update_receipt_admin RPC" CREATE OR REPLACE 블록 전체를 SQL Editor 에서 재실행.
--
-- ALTER TABLE public.settlement_events
--   DROP CONSTRAINT IF EXISTS settlement_events_action_check;
-- ALTER TABLE public.settlement_events
--   ADD CONSTRAINT settlement_events_action_check
--   CHECK (action IN ('create', 'pay', 'hold', 'cancel', 'revert'));
