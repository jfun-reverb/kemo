-- ============================================================
-- 327_update_deliverable_status_settlement_recalc.sql
-- 전수조사 후속 조치 — 묶음 H(정산) 중 남은 조각 H-2
--   + 그 과정에서 발견된 324(H-1, update_receipt_admin)의 같은 유형 결함 정정
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 H — 정산」
--
-- ⚠️ 이 파일은 「정산을 인플루언서에게 켜기 전 반드시」로 표시된 마지막 항목이다
--   (CLAUDE.md 정산 절 + 위 사양서 묶음 H 참고). 돈이 걸린 조각이다.
-- ⚠️ 이 파일은 화면 코드(dev/js/*.js, dev/lib/storage.js)를 전혀 건드리지 않는다.
--   데이터베이스 함수 2개를 바꾼다(아래 "이 파일이 바꾸는 함수 2개").
--
-- ── 이 파일이 바꾸는 함수 2개 ──
--   1. update_deliverable_status — H-2 본 작업. "인플루언서가 영수증을 다시 제출
--      → 관리자가 승인" 경로에 정산 재계산을 새로 추가한다(원래 이 함수 안에는
--      정산 관련 코드가 한 줄도 없었다).
--   2. update_receipt_admin — 검토 중 발견된 부수 결함 정정. 아래 "왜 324 를
--      여기서 함께 고치는가" 참고.
--
-- ── 이 파일이 없이 남아 있던 문제(1번, H-2 본 작업) ──
--   마이그레이션 324(H-1)가 고친 것은 "관리자가 영수증 칸을 손으로 고치는" 경로
--   (update_receipt_admin)뿐이었다. 실무에서 훨씬 자주 도는 경로는 따로 있다 —
--   "인플루언서가 반려된 영수증을 다시 제출 → 관리자가 그 새 영수증을 승인"
--   (update_deliverable_status, 마이그레이션 035 원본, 084 는 REVOKE/GRANT만 재실행
--   해 로직 변경 없음 — grep 재확인: `grep -rl "FUNCTION public.update_deliverable_status"
--   supabase/migrations/ *.sql` → 035·084 두 곳뿐, 084 는 CREATE 문 없이 REVOKE/GRANT
--   만 있음. 035 가 현재 유효한 유일한 본문 정의).
--
--   영수증은 재제출할 때마다 새 행이 쌓이는 구조다(301 파일 상단 설명 그대로 —
--   review_image·post 와 달리 기존 행을 UPDATE 로 재사용하지 않는다). 정산이 이미
--   "정산대기(pending)" 상태로 만들어진 뒤, 그 응모에 더 늦게 제출된 영수증이
--   생기고 그 영수증이 승인되면 — "최신 영수증"의 정의가 바뀌는데도 정산 금액은
--   옛 영수증 기준 그대로 남는다. update_deliverable_status 안에는 정산과 관련된
--   코드가 단 한 줄도 없었다(전수 확인 — 위 grep 결과 두 파일 모두 settlements·
--   settlement_events 참조 0건).
--
-- ── 재정의 기준(전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   update_deliverable_status → 035(현재 유일한 본문 원본, 084 는 권한 재실행뿐).
--   이 파일은 035 베이스 — 로직은 그대로 두고 "영수증이 승인될 때"에만 재계산
--   블록을 덧붙인다.
--   update_receipt_admin → grep 재확인 결과 128 → 178 → 302 → **324**(현재 유효한
--   원본). 이 파일은 324 베이스.
--   두 함수의 재계산 규칙(금액 계산식·amount_issue 판정 3종·자동 보류 문구)은
--   서로 동일하게 맞춘다. "최신 영수증" 판정 기준도 318(_settlement_cert_candidates
--   현재 원본)의 정의(임시저장 제외)로 **두 함수 모두** 통일한다.
--
-- ── 왜 324 를 여기서 함께 고치는가(진행 중 발견·지시에 따라 범위에 포함) ──
--   1번(update_deliverable_status)에 재계산 블록을 새로 쓰면서, "최신 영수증"을
--   고르는 조회를 318(_settlement_cert_candidates)의 정의(임시저장 제외)에 맞춰
--   작성했다. 그런데 324(update_receipt_admin)의 같은 자리 조회는 **임시저장
--   제외 조건이 없다** — 300/318/이번 update_deliverable_status 세 곳과 324
--   한 곳의 판정이 서로 다른 상태였다.
--
--   이 상태를 그대로 두면 "같은 사실(그 응모의 최신 영수증이 무엇인가)을 두
--   경로가 다르게 판정"하게 된다 — 어느 함수를 거쳐 정산이 재계산됐느냐에 따라
--   금액이 달라질 수 있다는 뜻이다. 구체적으로: 정산대기(pending) 중인 응모에
--   인플루언서가 폼을 채우다 만 임시저장(draft) 영수증을 남기고(예: 업로드만
--   하고 제출 버튼을 안 누름), 그 뒤 관리자가 이미 제출된(승인 대상) 영수증
--   금액을 손으로 고치면(update_receipt_admin) — submitted_at 이 더 늦은 그
--   임시저장 행이 "최신"으로 잘못 잡혀, **아직 제출하지도 않은 금액이 정산
--   금액(=송금액)이 될 수 있었다.** 이것은 318 이 인증 성공 판정에서 이미 한 번
--   고친 것과 완전히 같은 유형의 결함이다(318 파일 상단 "무엇이 문제였나" 참고) —
--   같은 결함이 정산 경로 중 한 곳에만 남아 있는 것을 그대로 두는 것은 이번
--   작업의 취지(판정 이원화 제거)에 어긋난다.
--
--   그래서 이 파일 안에서 update_receipt_admin 도 함께 재정의한다. 바뀌는
--   실질적인 조건은 **`AND status <> 'draft'` 한 줄뿐**이고, 그 외 로직(권한
--   가드·입력 검증·paid/on_hold/cancelled 차단·no-op 체크·이력 기록·시딩/방문형
--   비적용)은 324 와 완전히 동일하다 — 아래 "324 대비 diff 확인 결과" 참고.
--
-- ── 324 대비 diff 확인 결과(파일 하단 검증 [V5] 참고) ──
--   324 원본 함수 본문과 이 파일의 재정의를 diff 로 대조한 결과, 실행되는 SQL
--   기준으로 바뀐 것은 "최신 영수증" 조회의 WHERE 절에 `AND status <> 'draft'`
--   한 줄이 추가된 것뿐이다(그 바로 위 주석 6줄과, 함수 맨 끝 COMMENT ON FUNCTION
--   의 버전 표기[324→327]는 실행에 영향 없는 설명문 변경). 나머지 SQL 문장은
--   글자 하나 다르지 않다 — 특히 권한 가드(campaign_admin 이상)·paid/on_hold/
--   cancelled 차단·no-op 체크·receipt_edit_history 기록·시딩/방문형 미적용
--   분기·반환 타입(TABLE 4컬럼)은 전부 324 그대로다.
--
-- ── 정산 상태별로 무엇을 하는가(핵심 판단, 사용자 지시에 따른 결정 — update_deliverable_status 한정) ──
--   settlement 없음                 → 아무것도 안 함(대부분의 승인이 여기 해당).
--   settlement.status = 'pending'
--     AND recruit_type = 'monitor'  → 재계산(324/H-1 과 동일 규칙). 시딩·방문형은
--                                      금액 출처가 campaigns.reward 라 영수증과
--                                      무관 — 손대지 않는다(324 와 동일 판단).
--   settlement.status = 'paid'      → 손대지 않는다(사용자 명시 지시 — 확정된
--                                      금전 기록 보호).
--   settlement.status = 'cancelled' → 손대지 않는다(사용자 명시 지시 — 되돌아올
--                                      길이 없는 종료 상태, 301 파일의 같은 판단).
--   settlement.status = 'on_hold'   → ★손대지 않는다(이 파일의 판단, 아래 설명).
--
--   (update_receipt_admin 은 324 그대로 — pending 만 재계산 대상이고, paid/
--   on_hold/cancelled 는 애초에 수정 자체를 차단해 이 분기까지 오지 않는다.
--   두 함수의 "재계산 대상은 pending·monitor 뿐"이라는 결론은 동일하다.)
--
--   on_hold 를 건드리지 않기로 한 이유(update_deliverable_status):
--   on_hold 로 들어가는 경로가 세 가지다 — ①이 재계산 자체가 "금액 미확정"이라
--   판단해 자동 보류한 경우(H-1·H-2 공통) ②신청이 반려돼 자동 보류된 경우
--   (마이그레이션 246·320) ③관리자가 수동으로 보류한 경우. 세 경우 모두 "지금은
--   이 정산 금액을 확정 짓지 않겠다"는 의도로 걸린 상태다. 이 함수(영수증 승인)가
--   그 사이에 끼어들어 금액만 조용히 바꾸면, ②·③처럼 영수증 금액과 무관한 사유로
--   보류된 건까지 부작용으로 값이 바뀌거나(사유와 무관한 재계산), 반대로 ①처럼
--   "금액을 못 정해 보류"된 건에 뒤늦게 좋은 영수증이 들어와도 여전히 방치돼
--   보이는(재계산은 안 하면서 상태만 그대로) 어중간한 결과가 된다. on_hold 는
--   301(H-1 의 형제 가드)이 이미 "새 영수증 제출 자체를 막는" 잠금 상태로 다루고
--   있어(301 파일 "무엇을 막는가" 참고), 이 파일도 같은 결로 "손대지 않는 잠금
--   상태"에 on_hold 를 paid·cancelled 와 함께 둔다 — 재개가 필요하면 관리자가
--   기존 도구(mark_settlement_revert, 마이그레이션 224 — 보류 해제)로 pending 으로
--   되돌린 뒤, 그다음 영수증 승인·수정에서 자연히 재계산되게 한다.
--
-- ── 재계산이 실패하면 승인 자체가 실패해야 하는가(핵심 판단, 사용자 지시에 따른 결정 — update_deliverable_status 한정) ──
--   ★함께 실패한다(원자적) — 재계산 블록을 별도 예외 처리로 감싸지 않는다.
--   근거:
--   1) "실패"로 예상되는 거의 모든 경우(영수증 금액 없음·상시가 없음·절사 후 0)는
--      예외(RAISE)가 아니라 이미 결정된 분기로 처리된다 — 정산을 on_hold 로 돌리고
--      함수는 정상 종료한다(324·H-1 과 동일 설계). 이 경로는 "실패해서 승인이
--      막히는" 상황이 아니라 애초에 정상 동작이다.
--   2) 그 분기 밖에서 발생하는 진짜 예외(예: 스키마가 훼손돼 캠페인 행을 찾을 수
--      없는 경우 등, 정상 운영에서는 사실상 나지 않아야 하는 오류)라면 승인과
--      재계산이 함께 롤백되는 편이 낫다. 승인만 조용히 통과시키고 재계산을
--      건너뛰면, 정산 금액이 옛 값으로 남는 채 아무 신호도 없이 넘어간다 —
--      이 마이그레이션이 고치려는 바로 그 증상("조용히 옛 값으로 남는다")을
--      스스로 재현하게 된다. 관리자가 오류 메시지를 보고 즉시 원인을 찾을 수
--      있는 편이, 눈에 안 보이는 금액 오차보다 낫다.
--   3) 이 재계산이 도는 조건(kind='receipt' AND p_new_status='approved')은 이
--      함수가 처리하는 전체 호출(모든 종류·모든 상태 전이) 중 일부에 불과하다 —
--      게시물·인증샷 승인/반려, 영수증 반려·되돌리기는 이 블록에 전혀 들어가지
--      않으므로 영향받지 않는다. 영향 범위는 "정산대기 중인 리뷰어형 응모의
--      영수증을 승인하는" 좁은 경우로 한정된다.
--
-- ── 301(영수증 신규 제출 잠금 트리거)이 이 경로를 막을 수 있는가 — 확인 결과: 아니다 ──
--   301 의 트리거 함수(check_receipt_settlement_lock)는 ①auth.uid() 가 NULL 이거나
--   ②is_admin() 이면 즉시 통과시키고, 그 뒤에야 "NEW.status IN ('draft','pending')"
--   조건을 본다. update_deliverable_status 는 함수 맨 앞에서 이미 is_admin() 을
--   요구하므로(035 원본 그대로, 이 파일도 무변경) 이 함수를 거치는 모든 UPDATE 는
--   반드시 관리자 세션에서 실행된다 — 301 의 관리자 예외(②)에서 항상 걸려 먼저
--   통과한다. 게다가 이 함수가 만드는 NEW.status 값은 'pending'·'approved'·
--   'rejected' 세 가지뿐이라 'draft' 로는 절대 안 가고, 'approved'·'rejected' 는
--   애초에 301 의 조건(draft/pending)에도 안 걸린다. 즉 이론상으로도 실무상으로도
--   301 이 이 경로를 막을 일은 없다 — 그래서 이 파일은 301 을 우회하는 어떤 추가
--   분기도 넣지 않는다(넣을 필요가 없다). update_receipt_admin 은 애초에 status
--   컬럼을 건드리지 않으므로(order_number·purchase_date·purchase_amount 3개만
--   UPDATE) 301 의 대상 자체가 아니다(302 파일이 이미 확인해 둔 사실, 변경 없음).
--
-- ── 「최신 영수증」을 고르는 다른 지점이 더 있는가 — 전수 확인 결과 ──
--   `grep -rn "kind = 'receipt'" supabase/migrations/ *.sql` + `grep -rn
--   "ORDER BY.*submitted_at" supabase/migrations/ *.sql` 로 전수 확인했다.
--   ① _settlement_cert_candidates()(현재 원본 318) — 이미 임시저장 제외(원래부터
--      이번 정정의 기준으로 삼은 곳).
--   ② update_receipt_admin — 이번에 정정(위 참고).
--   ③ update_deliverable_status — 이번에 신규 추가(위 참고).
--   ④ 218·231·242 안의 backfill_settlements 등 자체 receipt_latest — 전부 옛
--      버전(그 뒤 262/300/324 가 CREATE OR REPLACE 로 덮어써 지금은 죽은 정의).
--      262 이후로는 이 세 함수가 자체 CTE 없이 _settlement_cert_candidates() 를
--      호출하는 구조로 바뀌었다(324 의 H-5·H-3·H-4 절도 전부 이 헬퍼 호출로
--      확인됨) — 실행되는 코드가 아니므로 손대지 않는다.
--   ⑤ 302(옛 update_receipt_admin) 의 같은 조회, 302 검증 주석 안의
--      "ORDER BY d.submitted_at DESC" — 둘 다 324 가 이미 대체한 죽은 정의이거나
--      검증용 SQL 주석(실제 판정 로직 아님).
--   ⑥ 160 검증 주석의 "ORDER BY d.submitted_at DESC LIMIT 1" — 대리 등록
--      스모크 테스트용 확인 쿼리(가장 최근에 INSERT 된 행을 찾는 것뿐, 정산
--      금액 판정과 무관).
--   ⑦ dev/lib/storage.js 의 fetchDeliverables() 계열(예: 1112·1630행)은 이미
--      `.neq('status', 'draft')` 로 **조회 단계에서** 임시저장을 걸러낸 뒤
--      가져오므로, 그 결과를 다시 정렬해 "최신"을 고르는 화면 쪽 코드
--      (dev/js/admin-deliverables.js 의 그룹핑 로직)는 애초에 임시저장을 볼
--      일이 없다 — 별도 조건을 추가할 필요가 없다(318 파일이 이미 지적한 사실
--      그대로).
--   ⑧ Edge Function `notify-deliverable-decision`(index.ts)의 "채널별 최신 1건"
--      로직은 게시물/인증샷의 **알림 문구**를 고르는 것으로, 정산 금액과 무관한
--      별개의 판정이다(review_image 채널 상태 표시용, kind='receipt' 아님) —
--      이번 조사 범위(정산 금액을 결정하는 최신 영수증) 밖이라 대조·수정 대상
--      아니다.
--   ⑨ 위 목록 외 "kind = 'receipt'" 를 참조하는 나머지 결과(대리 등록 RPC들 —
--      160·161·163·182·184, 일괄발송 대상 필터 — 168·169·171)는 모두 "그런
--      상태의 영수증이 존재하는가"(EXISTS/필터)를 보는 것이지 "그중 어느 게
--      최신인가"를 고르는 게 아니다 — 이번 결함 유형과 무관.
--   → 결론: **다른 곳에 숨어 있는 세 번째 판정 지점은 없다.** 정산 금액을
--   결정하는 "최신 영수증" 판정은 이제 ①②③ 세 곳뿐이고, 세 곳 모두 임시저장을
--   제외하는 동일한 정의를 쓴다.
--
-- ── 화면 변경 필요(이 파일은 하지 않음) ──
--   없음(이번 조각 한정) — 두 함수 모두 반환 타입이 전혀 바뀌지 않았다.
--   update_deliverable_status 는 여전히 정수 하나(dev/lib/storage.js
--   updateDeliverableStatus 가 그 값만 사용). update_receipt_admin 은 여전히
--   TABLE 4컬럼(324 가 이미 그렇게 바꿔 뒀고 이번엔 손대지 않음). 재계산 발생
--   여부·on_hold 전환 여부는 정산 페인(dev/js/admin-settlements.js)이 다음에
--   그 화면을 열 때 settlements 테이블에서 최신값을 다시 읽어와 자연히 반영된다
--   (324/H-6 이 붙이기로 한 "재계산 이력 한국어 라벨"은 이 파일 범위 밖 — H-6
--   자체가 별도 조각으로 명시돼 있다).
--
-- 롤백:
--   1) update_deliverable_status — 035_create_deliverables.sql 의 "8. 낙관적 락
--      RPC: update_deliverable_status" CREATE OR REPLACE FUNCTION 블록을 그대로
--      SQL Editor 에서 재실행하면 이 파일 이전 동작(재계산 없음)으로 되돌아간다.
--      REVOKE/GRANT 는 084 그대로이므로 별도 롤백 불필요.
--   2) update_receipt_admin — 324_settlement_audit_fixes_h1_h3_h4_h5_h8.sql 의
--      "1. update_receipt_admin 재정의" CREATE OR REPLACE FUNCTION 블록을 그대로
--      재실행하면 임시저장 제외 조건이 빠진 324 원본 동작으로 되돌아간다(이번
--      정정 이전 상태 — H-2 도입 이전과 같지 않음에 유의, 324 자체의 "정산대기·
--      리뷰어형만 재계산" 동작은 유지된 채 draft 제외만 없어진다).
-- ============================================================

BEGIN;

-- ============================================================
-- 1. update_deliverable_status 재정의 (H-2 본 작업, 035 베이스)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_deliverable_status(
  p_id               uuid,
  p_new_status       text,
  p_expected_version integer,
  p_reason           text    DEFAULT NULL,
  p_template_code    text    DEFAULT NULL
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_rows_updated       integer;
  v_new_version        integer;
  v_kind               text;   -- [327] 방금 갱신한 결과물의 종류 — 영수증인지 판별
  v_application_id     uuid;   -- [327] 그 결과물이 속한 응모

  -- [327, H-2] 정산 재계산용 변수(324, H-1 의 update_receipt_admin 재계산 블록과
  -- 같은 이름·용도로 맞췄다 — 나란히 읽었을 때 같은 규칙임을 바로 알아보도록).
  v_settlement             record;  -- 그 응모의 정산 행(있으면) + 캠페인 recruit_type
  v_settlement_found       boolean; -- FOUND 함정 방지용 명시적 플래그(302/324 파일 경고 계승)
  v_latest_receipt_amount  numeric; -- "그 응모의 최신 영수증"(임시저장 제외) 결제 금액
  v_cap                    bigint;  -- 다시 읽은 캠페인 상시가(product_price)
  v_new_amount             bigint;  -- 재계산된 정산 금액
  v_new_receipt_snapshot   bigint;  -- 재계산된 감사용 칸 — 영수증 원금액(floor)
  v_new_cap_snapshot       bigint;  -- 재계산된 감사용 칸 — 적용 상한
  v_amount_issue           text;    -- 재계산 실패 사유(정상이면 NULL)
BEGIN
  -- 관리자 권한 확인(035 원본 그대로, 변경 없음)
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 결과물 상태를 변경할 수 있습니다.';
  END IF;

  -- 상태값 유효성 확인(035 원본 그대로, 변경 없음)
  IF p_new_status NOT IN ('pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid_status: 유효하지 않은 상태값입니다. (pending|approved|rejected)';
  END IF;

  -- 낙관적 락 + 상태 업데이트(035 원본과 동일한 SET 절 — 변경 없음).
  -- [327] RETURNING 절에 kind·application_id 를 추가해 한 번에 받는다 — 035 원본은
  -- 이 UPDATE 뒤 "SELECT version INTO v_new_version" 를 별도로 한 번 더 실행했는데,
  -- kind·application_id 도 필요해진 김에 RETURNING 하나로 합쳤다(조회 1회 절감,
  -- 반환값·동작은 기존과 동일).
  UPDATE public.deliverables
  SET
    status               = p_new_status,
    reject_reason        = CASE WHEN p_new_status = 'rejected' THEN p_reason ELSE NULL END,
    reject_template_code = CASE WHEN p_new_status = 'rejected' THEN p_template_code ELSE NULL END,
    reviewed_by          = CASE WHEN p_new_status IN ('approved', 'rejected') THEN auth.uid() ELSE reviewed_by END,
    reviewed_at          = CASE WHEN p_new_status IN ('approved', 'rejected') THEN now() ELSE reviewed_at END,
    version              = version + 1
  WHERE
    id      = p_id
    AND version = p_expected_version  -- 낙관적 락: 기대 버전과 다르면 0행 UPDATE
  RETURNING version, kind, application_id INTO v_new_version, v_kind, v_application_id;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    -- 충돌 발생 — 클라이언트가 stale 데이터를 가지고 있음(035 원본 그대로)
    RETURN -1;
  END IF;

  -- ── [327, H-2] 영수증이 승인될 때만 정산 재계산을 시도한다 ──
  -- 게시물(post)·인증샷(review_image) 승인/반려, 영수증 반려·되돌리기는 이 블록에
  -- 들어가지 않는다 — 정산 금액의 근거가 영수증 결제 금액이기 때문이다.
  IF p_new_status = 'approved' AND v_kind = 'receipt' THEN
    -- 그 응모의 정산 행 조회(있으면) + 캠페인 recruit_type 함께 조회.
    -- FOR UPDATE OF s 로 settlements 행만 잠근다(campaigns 행은 잠그지 않음 —
    -- 324/H-1 과 동일 이유: 다른 캠페인 편집과 불필요하게 경합하지 않도록).
    -- settlements.application_id 는 UNIQUE(마이그레이션 217) 이므로 최대 1행만 매칭.
    SELECT s.id, s.status, s.version, s.amount_jpy, s.campaign_id,
           s.receipt_amount_jpy, s.amount_cap_jpy, c.recruit_type
      INTO v_settlement
      FROM public.settlements s
      JOIN public.campaigns   c ON c.id = s.campaign_id
     WHERE s.application_id = v_application_id
     FOR UPDATE OF s;
    v_settlement_found := FOUND;  -- 이후 문장이 FOUND 를 덮어쓰므로 즉시 변수로 옮김

    -- 정산이 없거나, paid·on_hold·cancelled 이거나, 시딩·방문형이면 아무것도 하지
    -- 않는다(파일 상단 "정산 상태별로 무엇을 하는가" 참고 — 예외를 던지지 않는다,
    -- 이 함수는 검수 화면의 핵심 승인 경로라 여기서 막으면 정상 검수 업무가 막힌다).
    IF v_settlement_found AND v_settlement.status = 'pending' AND v_settlement.recruit_type = 'monitor' THEN
      -- "최신 영수증" 재조회 — [318] _settlement_cert_candidates() 의 receipt_latest
      -- 정의와 동일(임시저장 제외, submitted_at DESC, updated_at DESC). 방금 이 함수가
      -- approved 로 갱신한 행이 대개 그 "최신"이지만, 그 사이 더 늦게 제출된 임시저장
      -- (draft) 행이 있을 수 있어 명시적으로 다시 조회한다. (update_receipt_admin 도
      -- 이 파일에서 같은 조건으로 맞췄다 — 파일 상단 "왜 324 를 함께 고치는가" 참고.)
      SELECT purchase_amount
        INTO v_latest_receipt_amount
        FROM public.deliverables
       WHERE application_id = v_application_id
         AND kind = 'receipt'
         AND status <> 'draft'
       ORDER BY submitted_at DESC, updated_at DESC
       LIMIT 1;

      -- 상한 재조회 — 저장된 옛 amount_cap_jpy 재사용 금지, campaigns 를 다시 읽는다
      -- (324/H-1 과 동일 이유 — 스냅샷이 아니라 그 시점 상시가를 반영).
      SELECT product_price
        INTO v_cap
        FROM public.campaigns
       WHERE id = v_settlement.campaign_id;

      -- amount_issue 판정 3종 — 300/318/324 와 완전히 동일한 조건.
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
        -- ── 재계산 실패 → 자동 보류(324/H-1 결정 그대로 계승) ──
        -- ⚠️ memo 에 "자동 보류"라는 연속 문자열을 절대 쓰지 않는다
        -- (dev/js/admin-settlements.js 의 신청반려 배지 문자열 매칭과 충돌 —
        -- 302/324 파일 상단 경고 그대로 계승).
        UPDATE public.settlements
           SET status  = 'on_hold',
               memo    = '영수증 승인으로 금액을 확정할 수 없어 보류 처리됨 (' || v_amount_issue || ')',
               version = version + 1
         WHERE id = v_settlement.id;

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (
          v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(),
          '영수증 승인 후 정산 금액 재계산 불가로 보류 처리 (' || v_amount_issue || ')'
        );
      ELSE
        -- ── 재계산 성공 — 300/318/324 와 완전히 동일한 계산식 ──
        v_new_amount           := NULLIF(GREATEST(floor(LEAST(v_latest_receipt_amount, v_cap::numeric)), 0), 0)::bigint;
        v_new_receipt_snapshot := floor(v_latest_receipt_amount)::bigint;
        v_new_cap_snapshot     := v_cap::bigint;

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
            '영수증 승인으로 정산 금액 재계산: ' || COALESCE(v_settlement.amount_jpy::text, '(없음)')
              || '엔 → ' || v_new_amount || '엔'
          );
        END IF;
        -- 값이 이전과 같으면(no-op) 아무것도 하지 않는다 — 324/H-1 과 동일 원칙.
      END IF;
    END IF;
  END IF;

  -- 갱신된 version 반환(035 원본과 동일한 반환값 — RETURNING 으로 이미 받아둔 값)
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.update_deliverable_status IS
  '[327 재정의, 035 원본 대체(084 는 REVOKE/GRANT 만 재실행, 로직 변경 없었음)] '
  '결과물 상태 변경 RPC. 낙관적 락으로 동시 편집 충돌 방지. 반환값 -1 = 충돌(클라이언트 '
  '재조회 필요). [327, H-2] 영수증(kind=receipt)이 승인(approved)될 때, 그 응모의 정산 '
  '(settlements)이 정산대기(pending)이고 캠페인이 리뷰어형(monitor)이면 최신 영수증'
  '(임시저장 제외, 318 정의)·현재 캠페인 상시가로 정산 금액을 재계산해 갱신(변경 시 '
  'settlement_events action=recalc 기록, 실패 시 on_hold 자동 전환 — 324/H-1 규칙 그대로). '
  '정산이 없거나 paid·on_hold·cancelled 이거나 시딩·방문형이면 손대지 않는다(예외를 '
  '던지지 않음 — 검수 승인 자체는 항상 정상 진행). 재계산 블록에서 발생하는 예외는 '
  '승인 자체와 함께 롤백된다(의도적 — 파일 상단 "재계산이 실패하면" 참고).';

REVOKE ALL ON FUNCTION public.update_deliverable_status(uuid, text, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_deliverable_status(uuid, text, integer, text, text) TO authenticated;


-- ============================================================
-- 2. update_receipt_admin 재정의 (324 베이스 — 임시저장 제외 조건 추가)
--    반환 타입 불변(324 와 동일 TABLE 4컬럼) — DROP 불필요, CREATE OR REPLACE 로 충분.
--    실질적으로 바뀌는 SQL 은 "최신 영수증" 조회의 WHERE 절에 추가된
--    `AND status <> 'draft'` 한 줄뿐이다(파일 상단 "324 대비 diff 확인 결과" 참고).
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_receipt_admin(
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

  v_settlement             record;  -- 그 응모의 정산 행(있으면) + [324] 캠페인 recruit_type
  v_settlement_found       boolean; -- FOUND 함정 방지용 명시적 플래그(302 파일 경고 그대로 계승)

  v_latest_receipt_amount  numeric; -- 저장 직후 다시 읽은 "그 응모의 최신 영수증" 결제 금액
  v_cap                    bigint;  -- 다시 읽은 캠페인 상시가(product_price, 옛 스냅샷 재사용 금지)
  v_new_amount             bigint;  -- 재계산된 정산 금액
  v_new_receipt_snapshot   bigint;  -- 재계산된 감사용 칸 — 영수증 원금액(floor)
  v_new_cap_snapshot       bigint;  -- 재계산된 감사용 칸 — 적용 상한
  v_amount_issue           text;    -- 재계산 실패 사유(정상이면 NULL)
  v_recalculated           boolean := false;
  v_out_status             text;    -- 반환용: 처리 후 정산 상태
  v_out_amount             bigint;  -- 반환용: 처리 후 정산 금액
BEGIN
  -- ── 권한 가드: campaign_admin 이상(302 와 동일, 변경 없음) ──────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 정규화(302 와 동일) ─────────────────────────────────────────
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  v_order_to_save := NULLIF(v_trimmed_order, '');

  -- ── 입력 검증: 최소 1개 필수(302 와 동일) ──────────────────────────
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

  -- ── 대상 행 조회(302 와 동일 + application_id 추가 조회) ───────────
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

  -- ── 그 응모의 정산 조회 + [324, H-1] 캠페인 모집 형식(recruit_type) 함께 조회 ──
  -- FOR UPDATE OF s 로 settlements 행만 잠근다(campaigns 행은 잠그지 않음 — 다른 캠페인
  -- 편집과 불필요하게 경합하지 않도록). settlements.application_id 는 UNIQUE(217) 이므로
  -- 최대 1행만 매칭된다.
  SELECT s.id, s.status, s.version, s.amount_jpy, s.campaign_id,
         s.receipt_amount_jpy, s.amount_cap_jpy, c.recruit_type
    INTO v_settlement
    FROM public.settlements s
    JOIN public.campaigns   c ON c.id = s.campaign_id
   WHERE s.application_id = v_prev.application_id
   FOR UPDATE OF s;
  v_settlement_found := FOUND;  -- 이후 문장이 FOUND 를 계속 덮어쓰므로 즉시 변수로 옮김

  -- 송금완료(paid)·보류(on_hold)·취소(cancelled) — 수정 자체를 차단.
  -- (302 그대로 — 모집 형식과 무관하게 확정된 금전 기록은 보호한다)
  IF v_settlement_found AND v_settlement.status IN ('paid', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'settlement_locked_receipt_edit: 이미 처리된 정산(송금완료·보류·취소)이 연결된 영수증은 수정할 수 없습니다. 정산 상태를 먼저 확인해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  -- ── no-op 체크(302 와 동일) ──────────────────────────────────────
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

  -- ── 관리자 이름 스냅샷(302 와 동일) ──────────────────────────────
  SELECT name INTO v_admin_name
    FROM public.admins
   WHERE auth_id = auth.uid()
   LIMIT 1;

  -- ── deliverables UPDATE(302 와 동일) ─────────────────────────────
  UPDATE public.deliverables
     SET order_number    = v_order_to_save,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT(302 와 동일) ─────────────────────
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

  -- ── [324, H-1] 정산이 정산대기(pending)이고 리뷰어형(monitor)일 때만 재계산 ──
  -- 시딩(gifting)·방문형(visit)은 금액 출처가 campaigns.reward 라 영수증 수정과
  -- 무관하다 — 재계산도, "금액 미확정" 자동 보류도 하지 않고 그대로 둔다.
  IF v_settlement_found AND v_settlement.status = 'pending' AND v_settlement.recruit_type = 'monitor' THEN
    -- "최신 영수증" 재조회 — [327] 300/318/327(update_deliverable_status) 과 동일한
    -- 정렬 기준 + 임시저장(draft) 제외. 324 원본은 이 제외 조건이 없었다 — "방금 이
    -- 함수가 UPDATE 한 행은 draft 가 아니라 기존 상태 그대로"라는 원본 주석은 그
    -- 함수가 UPDATE 하는 행 자체는 맞지만, "최신 1건"을 고르는 이 조회는 그 응모의
    -- 다른 영수증 행까지 전부 보므로 더 늦게 제출된 임시저장 행이 있으면 그게
    -- "최신"으로 잘못 잡혀 아직 제출하지도 않은 금액이 정산액이 되는 위험이 있었다
    -- (318 이 _settlement_cert_candidates() 에서 고친 것과 완전히 같은 유형의 결함).
    SELECT purchase_amount
      INTO v_latest_receipt_amount
      FROM public.deliverables
     WHERE application_id = v_prev.application_id
       AND kind = 'receipt'
       AND status <> 'draft'  -- [327] 신규 추가 — 실질적인 변경은 이 한 줄뿐
     ORDER BY submitted_at DESC, updated_at DESC
     LIMIT 1;

    -- 상한 재조회 — 저장된 옛 amount_cap_jpy 재사용 금지, campaigns 를 다시 읽는다.
    SELECT product_price
      INTO v_cap
      FROM public.campaigns
     WHERE id = v_settlement.campaign_id;

    -- amount_issue 판정 3종 — 300/318 과 완전히 동일한 조건.
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
      -- ── 재계산 실패 → 자동 보류(302 결정 그대로 계승) ──
      -- ⚠️ memo 에 "자동 보류"라는 연속 문자열을 절대 쓰지 않는다(dev/js/admin-settlements.js
      -- 의 신청반려 배지 문자열 매칭과 충돌 — 302 파일 상단 경고 그대로 계승).
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
      -- ── 재계산 성공 — 300/318 과 완전히 동일한 계산식 ──
      v_new_amount           := NULLIF(GREATEST(floor(LEAST(v_latest_receipt_amount, v_cap::numeric)), 0), 0)::bigint;
      v_new_receipt_snapshot := floor(v_latest_receipt_amount)::bigint;
      v_new_cap_snapshot     := v_cap::bigint;

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
  ELSIF v_settlement_found AND v_settlement.status = 'pending' THEN
    -- ── [324, H-1] 시딩(gifting)·방문형(visit) — 정산은 그대로, 손대지 않는다 ──
    -- 이 정산의 금액 출처는 campaigns.reward 지 영수증이 아니다. 방문형의 "현장 사진"
    -- (kind='receipt') 수정이 이 지점에 도달할 수 있지만, 재계산·자동 보류 어느 쪽도
    -- 하지 않는다 — 애초에 영수증 값이 이 정산 금액의 근거가 아니기 때문이다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  ELSIF v_settlement_found THEN
    -- 이 지점은 이론상 도달 불가 — status IN ('paid','on_hold','cancelled') 는 이미
    -- 위에서 차단됐고, 남는 값은 'pending' 뿐이다(217 CHECK 로 status 는 4종만 존재).
    -- 방어적으로 기존 값을 그대로 반환한다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  END IF;

  RETURN QUERY SELECT v_out_status, v_recalculated, v_out_amount, v_amount_issue;
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '[327 재정의, 324 원본 대체(재계산의 "최신 영수증" 조회에 임시저장(draft) 제외 조건 '
  '추가 — 327, update_deliverable_status 의 같은 조회와 판정을 맞춤)] 관리자가 '
  'deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 '
  '기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 그 응모에 정산(settlements)이 '
  '있으면: paid/on_hold/cancelled 는 수정 차단(RAISE EXCEPTION, 모집 형식 무관). pending 이고 '
  '캠페인 recruit_type=monitor(리뷰어형)이면 최신 영수증(임시저장 제외)·현재 캠페인 상시가로 '
  '정산 금액을 재계산해 갱신(변경 시 settlement_events action=recalc 기록, 실패 시 on_hold '
  '자동 전환). pending 이지만 시딩(gifting)·방문형(visit)이면 정산을 손대지 않는다(금액 출처가 '
  'campaigns.reward 라 영수증과 무관 — H-1: 방문형 "현장 사진" 수정이 엉뚱하게 리뷰어형 '
  '계산식을 타던 결함 수정). 정산 행이 없으면 302 이전과 동일 동작.';

REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor 에서 조각별로 1단계씩 실행 — 결과 확인 후 다음으로)
--   ⚠️ SQL Editor 세션은 auth.uid() 가 NULL 이라 is_admin()/is_campaign_admin() 게이트가
--   있는 함수는 이 안내 그대로는 permission_denied 가 난다. 274/301/302/324 와 동일하게
--   "request.jwt.claims 로 관리자 계정을 흉내내는" 방식([V-ADMIN] 참고)을 먼저 실행해 둘 것.
-- ============================================================
/*

-- [V0] 함수 재정의 확인(2개 모두)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('update_deliverable_status', 'update_receipt_admin');

-- [V-ADMIN] 관리자 계정 하나 확보(이후 흉내낼 대상) — campaign_admin 이상
SELECT auth_id, name, role FROM public.admins
 WHERE role IN ('super_admin', 'campaign_admin') LIMIT 3;


-- ══════════════ A. update_deliverable_status 검증 ══════════════

-- ═══════════════ 회귀 확인 — 정산 무관 승인/반려가 그대로 동작하는지 ═══════════════

-- [A1-1] 정산이 아예 없는 리뷰어형 영수증(pending) 1건 확보
SELECT d.id AS deliverable_id, d.version, d.status, d.kind, a.id AS application_id
  FROM public.deliverables d
  JOIN public.applications a ON a.id = d.application_id
 WHERE d.kind = 'receipt' AND d.status = 'pending'
   AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id = a.id)
 LIMIT 3;

-- [A1-2] 위 deliverable_id 로 승인 시도(반드시 ROLLBACK) — 정산이 없으므로 재계산
--   블록에 들어가지 않고 그냥 승인만 되어야 한다.
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT public.update_deliverable_status(
    '<A1-1 의 deliverable_id>'::uuid, 'approved', <A1-1 의 version>, null, null
  );
  -- 기대: 양수(새 version). -1 이 아니어야 함.
  SELECT status, version FROM public.deliverables WHERE id = '<A1-1 의 deliverable_id>';
  -- 기대: status='approved'
ROLLBACK;


-- ═══════════════ H-2 핵심 확인 — 정산대기(pending) 중 재제출 영수증 승인 시 재계산 ═══════════════

-- [A2-1] 정산이 pending·리뷰어형(monitor)인 응모 + 그 응모에 새로 제출된(아직
--   pending 인) 영수증 1건이 있으면 가장 좋다. 실제 운영 데이터에 이런 조합이
--   당장 없을 수 있다 — 개발 DB에서 임시로 재현하려면:
--     1) 리뷰어형 캠페인의 승인 응모 하나를 골라 그 영수증을 정상 승인해
--        settlements 를 하나 만든다(정산 페인의 "과거 미등록" 또는
--        backfill_settlements 호출로).
--     2) 같은 application_id 로 kind='receipt' 행을 하나 더 draft/pending 으로
--        INSERT 한다(구매금액을 원래보다 다른 값으로).
--     3) 아래 [A2-2] 로 그 새 행을 승인해 본다.
SELECT s.id AS settlement_id, s.status, s.amount_jpy, s.receipt_amount_jpy, s.amount_cap_jpy,
       c.recruit_type, c.product_price,
       d.id AS deliverable_id, d.version, d.status AS deliverable_status, d.purchase_amount, d.submitted_at
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending' AND c.recruit_type = 'monitor'
 ORDER BY d.submitted_at DESC
 LIMIT 10;

-- [A2-2] 위에서 확보한 "정산보다 늦게 제출된 pending 영수증"을 승인(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT public.update_deliverable_status(
    '<새 영수증의 deliverable_id>'::uuid, 'approved', <그 행의 version>, null, null
  );
  -- 기대: 양수(새 version)

  SELECT status, amount_jpy, amount_source, receipt_amount_jpy, amount_cap_jpy, version
    FROM public.settlements WHERE id = '<A2-1 의 settlement_id>';
  -- 기대: amount_jpy 가 새 영수증의 purchase_amount(또는 상시가 상한)로 바뀌어 있어야 함.
  --   status 는 'pending' 그대로(값만 바뀜) — 단, 새 영수증의 금액이 0/NULL 이거나
  --   product_price 가 없으면 status='on_hold' 로 바뀌는 것이 정상(재계산 실패 자동 보류).

  SELECT action, prev_status, next_status, memo, created_at
    FROM public.settlement_events
   WHERE settlement_id = '<A2-1 의 settlement_id>'
   ORDER BY created_at DESC LIMIT 3;
  -- 기대: action='recalc' (또는 금액 미확정이면 'hold') 행이 최상단에 새로 생김
ROLLBACK;


-- ═══════════════ paid·on_hold·cancelled 정산은 절대 안 바뀌는지 확인(회귀) ═══════════════

-- [A3-1] 정산이 paid 인 응모의 영수증(어떤 상태든) 확보
SELECT s.id AS settlement_id, s.status, s.amount_jpy, s.version AS settlement_version,
       d.id AS deliverable_id, d.version AS deliverable_version, d.status AS deliverable_status
  FROM public.settlements s
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'paid'
 LIMIT 3;

-- [A3-2] 그 영수증을 승인 시도(반드시 ROLLBACK) — deliverables 는 정상 승인되지만
--   settlements 는 절대 안 바뀌어야 한다.
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT public.update_deliverable_status(
    '<A3-1 의 deliverable_id>'::uuid, 'approved', <A3-1 의 deliverable_version>, null, null
  );
  SELECT status, amount_jpy, version FROM public.settlements WHERE id = '<A3-1 의 settlement_id>';
  -- 기대: status='paid' 그대로, amount_jpy 불변, version 불변(settlement_version 과 동일)
  SELECT count(*) FROM public.settlement_events WHERE settlement_id = '<A3-1 의 settlement_id>'
    AND created_at > now() - interval '1 minute';
  -- 기대: 0 (새 이력이 생기면 안 됨)
ROLLBACK;

-- [A3-3] on_hold·cancelled 정산도 같은 절차로 반복 확인(WHERE s.status='on_hold' /
--   'cancelled' 로 바꿔 [A3-1]~[A3-2] 재실행). 세 상태 모두 settlements 가 전혀
--   안 바뀌어야 한다.


-- ═══════════════ 시딩·방문형은 정산 존재해도 손대지 않는지 확인(회귀) ═══════════════

-- [A4-1] 정산이 pending 이고 recruit_type IN ('gifting','visit') 인 응모 +
--   그 응모의 receipt(현장 사진 등, 방문형 한정 — CLAUDE.md "방문형은 게시물뿐
--   아니라 현장 사진도 kind=receipt 로 제출" 참고) 확보
SELECT s.id AS settlement_id, s.status, s.amount_jpy, s.version AS settlement_version,
       c.recruit_type,
       d.id AS deliverable_id, d.version AS deliverable_version
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending' AND c.recruit_type IN ('gifting', 'visit')
 LIMIT 3;

-- [A4-2] 승인 시도(반드시 ROLLBACK) — settlements 는 전혀 안 바뀌어야 한다.
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT public.update_deliverable_status(
    '<A4-1 의 deliverable_id>'::uuid, 'approved', <A4-1 의 deliverable_version>, null, null
  );
  SELECT status, amount_jpy, version FROM public.settlements WHERE id = '<A4-1 의 settlement_id>';
  -- 기대: 전부 불변(settlement_version 과 동일)
ROLLBACK;


-- ══════════════ B. update_receipt_admin 검증(324 대비 회귀 + 이번 정정 효과) ══════════════

-- [B1-1] 정산이 paid/on_hold/cancelled 인 응모의 영수증 1건 확보(324 회귀 확인용 —
--   이번 정정으로도 여전히 수정 자체가 차단돼야 한다)
SELECT s.id AS settlement_id, s.status,
       d.id AS deliverable_id
  FROM public.settlements s
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status IN ('paid', 'on_hold', 'cancelled')
 LIMIT 5;

-- [B1-2] 위 영수증을 수정 시도(반드시 ROLLBACK) — 여전히 예외로 차단돼야 한다.
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<B1-1 의 deliverable_id>'::uuid, '테스트', '2026-08-01'::date, 5000
  );
  -- 기대: ERROR settlement_locked_receipt_edit (324 와 동일 — 회귀 없음)
ROLLBACK;

-- [B2] ★이번 정정의 핵심 확인 — 임시저장이 "최신"으로 잘못 잡히지 않는지.
--   준비(개발 DB): 정산이 pending·리뷰어형인 응모를 하나 고른 뒤, 그 응모에
--   kind='receipt' 임시저장(draft) 행을 하나 더 만든다(구매금액을 의도적으로
--   다른 값 — 예를 들어 999999 — 으로). 이 draft 행의 submitted_at 이 기존
--   승인된 영수증보다 늦어야 한다(그냥 지금 시각으로 INSERT 하면 됨).
--   그런 다음 관리자가 원래(승인된) 영수증의 값을 아주 조금만 고친다(예:
--   구매일만 하루 변경). 이번 정정 전(324)이었다면 그 draft 의 999999 가
--   "최신"으로 잘못 잡혀 정산 금액이 999999 기준으로 바뀌었을 것이다.
--   이번 정정 후에는 draft 를 무시하고 기존 승인 영수증 금액을 기준으로
--   재계산돼야 한다.
SELECT s.id AS settlement_id, s.status, s.amount_jpy,
       d.id AS deliverable_id, d.version, d.status AS deliverable_status,
       d.purchase_amount, d.submitted_at
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending' AND c.recruit_type = 'monitor'
 ORDER BY d.submitted_at DESC
 LIMIT 10;
-- (준비 완료 후) 아래로 "기존 승인 영수증"의 구매일만 살짝 고쳐 재계산을 유도(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V-ADMIN 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<기존 승인 영수증의 deliverable_id>'::uuid, null, '2026-08-02'::date, null
  );
  -- 기대: settlement_amount_jpy 가 draft 의 999999 가 아니라 기존 승인 영수증
  --   금액(또는 그 상한) 기준으로 나와야 한다.
ROLLBACK;

-- [B3] ★「324 와 327 이 같은 행을 고르는지」 비교 — 임시저장이 섞이지 않은 정상
--   케이스에서는 두 정의가 항상 같은 행을 골라야 한다(임시저장이 있을 때만
--   달라지는 것이 맞다). postgres(오너) 세션에서 실행 — 두 정의를 나란히
--   재현해 비교한다.
WITH targets AS (
  -- 검증할 응모 표본 — 리뷰어형 영수증이 1건 이상 있는 응모 최대 200개
  SELECT DISTINCT application_id
  FROM public.deliverables
  WHERE kind = 'receipt'
  LIMIT 200
),
old_324_pick AS (
  -- 324 원본과 동일한 조건(임시저장 제외 없음)
  SELECT DISTINCT ON (t.application_id)
    t.application_id, d.id AS deliverable_id, d.status, d.purchase_amount
  FROM targets t
  JOIN public.deliverables d
    ON d.application_id = t.application_id AND d.kind = 'receipt'
  ORDER BY t.application_id, d.submitted_at DESC, d.updated_at DESC
),
new_327_pick AS (
  -- 327(이번 정정) 조건(임시저장 제외)
  SELECT DISTINCT ON (t.application_id)
    t.application_id, d.id AS deliverable_id, d.status, d.purchase_amount
  FROM targets t
  JOIN public.deliverables d
    ON d.application_id = t.application_id AND d.kind = 'receipt' AND d.status <> 'draft'
  ORDER BY t.application_id, d.submitted_at DESC, d.updated_at DESC
)
SELECT
  o.application_id,
  o.deliverable_id AS old_324_deliverable_id, o.status AS old_324_status,
  n.deliverable_id AS new_327_deliverable_id, n.status AS new_327_status,
  (o.deliverable_id IS DISTINCT FROM n.deliverable_id) AS differs
FROM old_324_pick o
LEFT JOIN new_327_pick n ON n.application_id = o.application_id
ORDER BY differs DESC, o.application_id;
-- 기대: differs=true 인 행은 old_324_pick 의 status 가 'draft' 인 경우에만 나와야
--   한다(= 그 응모는 "가장 늦게 제출된 행이 임시저장"인 경우 — 이번 정정이 실제로
--   영향을 주는 대상). differs=true 인데 old_324_status<>'draft' 인 행이 하나라도
--   있으면 이번 변경이 의도치 않은 다른 곳까지 건드린 것이므로 반드시 원인을 확인할 것.


-- ══════════════ C. 다른 「최신 영수증」 선택 지점 부재 확인 ══════════════

-- [C1] 이 두 함수·헬퍼(_settlement_cert_candidates, 318) 외에 "kind='receipt'" +
--   "정렬 후 1건"을 고르는 살아있는 정의가 더 있는지 최종 재확인(정적 확인 — 이
--   파일 상단 "다른 지점이 더 있는가" 절의 grep 을 그대로 다시 실행해 결과가
--   같은지 확인. SQL Editor 가 아니라 로컬에서 아래 두 명령을 실행):
--     grep -rn "kind = 'receipt'" supabase/migrations/ *.sql
--     grep -rn "ORDER BY.*submitted_at" supabase/migrations/ *.sql
--   기대: 위 목록(①~⑨)과 동일한 결과 — 새로운 지점이 추가돼 있지 않아야 한다.

*/
