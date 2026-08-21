-- ============================================================
-- 347_request_withdrawal_function.sql
-- 회원 탈퇴 — 작업 5 (탈퇴 신청 함수)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-1·§4-2·§4-3·§4-6 ②
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 5
-- 선행(개발서버 적용·확인 완료): 345(withdrawal_requests 표) · 346(withdraw_reason 시드)
--
-- ⚠️ 이 파일은 최초 작성 당일(2026-08-19) 코드 리뷰에서 발견된 결함 2건을
--   반영해 다시 고쳤다 — 이 시점까지 어느 데이터베이스에도 적용된 적이
--   없어 새 마이그레이션을 얹지 않고 파일 자체를 수정한다. 무엇을 왜
--   고쳤는지는 아래 "2026-08-19 추가결정 A·B" 두 절 참고.
--
-- 산출 계약:
--   public.request_withdrawal(p_reason_code text DEFAULT NULL,
--                              p_reason_note text DEFAULT NULL)
--     RETURNS jsonb
--   성공: { ok:true, status, scheduled_date, cancelled_count, uncancelled_count,
--          unpaid_count }
--   실패: { ok:false, reason: 'not_authenticated' | 'not_found' |
--          'audit_account_blocked' | 'invalid_reason' }
--   ⚠️ p_reason_code·p_reason_note 둘 다 DEFAULT NULL 을 붙였다(요청 계약의
--   "request_withdrawal(p_reason_code text, p_reason_note text)" 2-인자
--   호출은 그대로 동작 — 기본값을 붙인다고 기존 호출이 깨지지 않는다).
--   p_reason_code 에 기본값을 더한 것은 추가결정 A(사유 필수→선택) 의
--   직접 결과 — 사유가 선택이 되었으니 인자 자체를 생략한 호출도 되어야
--   한다.
--   ⚠️ 'reason_required' 는 더 이상 반환하지 않는다 — 추가결정 A 로 사유가
--   선택이 되며 그 실패 사유 자체가 없어졌다. 'invalid_reason' 은
--   그대로 남는다(값을 줬는데 목록에 없는 코드인 경우에만 발동).
--   ⚠️ unpaid_amount_jpy 는 넣지 않는다 — 2026-08-19 사용자 결정(Q1). 정산
--   인플루언서 노출(금액 포함)을 오늘 전부 없앴는데(마이그레이션 343) 탈퇴
--   화면으로 금액을 되살리지 않기 위해서다. 건수만 돌려준다.
--
-- ============================================================
-- ① 「미지급」에 미등록(정산행이 아직 없는 인증 성공 건)을 포함한다
-- ============================================================
--   settlements 표만 보면, 인증에는 성공했지만 관리자가 아직 정산 화면을
--   열지 않아 정산 행 자체가 안 생긴 건(개발서버 관리자 정산 페인 「과거
--   미등록」 탭이 다루는 부류)이 통째로 빠진다. 운영 실측(작업표 stale
--   점검 ①) 509건 — 한 사람이 34건을 가진 경우도 있다. 이걸 빼면 "받을
--   돈이 있는 사람이 5일 뒤 계정을 잃는다"(결정 1 위반)가 그대로 재현된다.
--
--   판정은 _settlement_cert_candidates()(재정의 계보 232→262→264→300→318
--   →331, 331 이 현재 유효한 원본 — feedback_function_redefine_latest_base
--   메모리 규칙에 따라 331 을 그대로 재사용한다. 새로 베끼지 않는다)를
--   그대로 부른다. 이 함수는 이미 "승인된 응모 + 감사용 제외 + 정산행
--   없음(NOT EXISTS) + 무보수 시딩·방문형 제외" 를 candidates CTE 에서
--   전부 걸러 두었으므로, 여기서는 그 결과에서 `is_success = true` 인
--   행만 이 인플루언서 것으로 세면 된다 — 그게 정확히 "미등록인데 인증
--   성공한 건"의 정의다.
--
--   ⚠️ get_past_unregistered_settlements()(최신 정의 344)는 재사용하지
--   않는다 — has_permission('settlement.view','read') 관리자 가드가
--   걸려 있어 인플루언서 문맥(auth.uid() 가 인플루언서 본인)에서 그대로
--   부르면 42501 로 막힌다. _settlement_cert_candidates() 자체에는 그
--   가드가 없다(SECURITY DEFINER 이지만 판정 함수 자신은 무가드 — 344 가
--   가드를 자기 함수에서 하는 이유가 바로 이거다). 이 함수(347)가
--   SECURITY DEFINER 로 그 함수를 호출하면, 실행 컨텍스트가 함수
--   소유자(마이그레이션 실행 계정)로 전환되어 REVOKE ALL FROM PUBLIC 와
--   무관하게 호출 가능하다 — get_past_unregistered_settlements() 자신이
--   이미 같은 방식으로 _settlement_cert_candidates() 를 호출해 왔다
--   (내부 함수 호출 체인은 소유자 권한으로 평가되지, authenticated role
--   의 GRANT 여부로 평가되지 않는다 — Postgres 표준 동작).
--
-- ============================================================
-- ② on_hold(보류) 정산도 「미지급」에 포함한다 — 사양서가 정하지 않은 것,
--   이 마이그레이션이 판단해 결정한다(요청받은 대로 근거 + 반대 위험을
--   함께 남긴다. 최종 확인은 요청자 몫)
-- ============================================================
--   [선택: 포함한다]
--   근거 — on_hold 는 "지급 여부가 아직 안 정해진" 상태다. 결정 1의 글자
--   그대로("받을 돈이 남으면 지급이 끝난 뒤 탈퇴") 읽으면, 보류는 "안
--   끝난" 상태이지 "안 남은" 상태가 아니다. 정산대기(pending)만 보고
--   보류를 빼면, 결정 1이 막으려던 바로 그 상황(계정이 사라진 뒤에
--   지급 여부가 뒤늦게 확정되는 것)이 보류 건에서 그대로 재현된다.
--
--   구조적으로 "영영 막힌다"는 걱정도 크지 않다 — on_hold 는 관리자가
--   손으로 만든 상태이고(mark_settlement_hold, 마이그레이션 222) 언젠가
--   반드시 사람이 「보류 해제」(mark_settlement_revert, pending 복귀)
--   또는 「취소」로 정리한다. 탈퇴 신청 행 자체는 pending_payout 에 남아
--   있다가, 상태 전이 예약 실행(작업 7, 이번 마이그레이션 범위 밖)이
--   매일 다시 세어 보류가 풀리면 자동으로 「예정」으로 넘어간다 — 무한정
--   막히는 게 아니라 관리자 처리를 기다리는 정상적인 대기다.
--
--   반대 위험(포함하지 않는 쪽을 골랐다면 생겼을 문제, 참고용으로 남김)
--   — settlements.paypal_email 은 정산 행 생성 시점 스냅샷이라(217),
--   설령 탈퇴가 먼저 확정돼 influencers 행의 이메일·이름이 나중에
--   비워지거나 바뀌어도(작업 10, 이번 범위 밖) 정산 행 자체에는
--   지급에 필요한 값이 남는다 — 그래서 on_hold 를 미지급에서 뺐어도
--   "돈을 보낼 방법이 아예 사라지는" 사고는 아니었을 것이다. 다만
--   on_hold 에는 두 가지가 섞여 있다 — ⓐ pending 이었다가 문제가 생겨
--   보류된 것(진짜 미지급) ⓑ paid 였다가 환수 사유로 보류된 것(paid_at
--   보존, 마이그레이션 222 주석 — 이미 지급까지 갔던 돈의 사후 분쟁).
--   ⓑ 는 엄밀히는 "미지급"이 아니라 "지급 후 분쟁 중"이다. 이 함수는
--   ⓐ·ⓑ 를 구분하지 않고 status='on_hold' 전부를 센다 — 분쟁이 걸린
--   금전 문제가 하나라도 있으면 탈퇴를 미룬다는 보수적 판단이다. 이
--   구분(ⓐ/ⓑ)이 필요하다고 판단되면 paid_at IS NULL 조건을 더해 ⓐ만
--   세도록 좁힐 수 있다 — 이번엔 넣지 않았다.
--
-- ============================================================
-- 2026-08-19 추가결정 A — 탈퇴 사유를 필수 → 선택
-- ============================================================
--   근거: docs/research/2026-08-19-withdrawal-benchmark.md 결정①.
--     · 한국: 2025-12 개인정보보호위원회가 쿠팡에 탈퇴 절차 간소화를
--       요구해 사유 설문 단계가 삭제됐다.
--     · 일본: 조사한 플랫폼 중 약관에 탈퇴 사유 수집을 규정한 곳은
--       0곳이었다(전부 화면 설계 사항으로만 다룬다).
--
--   ⚠️ 이 결정을 반영하지 않고 그냥 "검증만 스킵"했다면 조용히 깨지는
--   지점이 있었다 — cancel_application(309)은 구매·방문 기간이 지난
--   응모(phase != 'recruit')에 대해 사유 코드가 비어 있으면
--   'reason_required' 로 거부한다(309 파일 176~177행). 최초 작성본은
--   회원이 고른 사유(withdraw_reason 코드)를 검증 후 그대로
--   cancel_application 에 넘기는 구조였다 — 그 상태에서 사유 검증만
--   없앴다면, 사유를 안 고른 회원은 모집 기간이 지난 응모가 단 하나도
--   철회되지 않고 전부 uncancelled_count 로 빠졌을 것이다. 화면에는
--   "철회 못 한 건 N개"로만 보여 원인을 알 수 없었을 것이다.
--   이 함수는 이제 회원이 고른 사유를 cancel_application 에 그대로
--   넘기지 않는다 — 아래 추가결정 B 를 볼 것. 그래서 회원이 사유를
--   아예 안 골라도 모든 응모가 정상적으로 철회된다.
--
-- ============================================================
-- 2026-08-19 추가결정 B — 탈퇴 사유(withdraw_reason)와 응모 취소 사유
--   (cancel_reason)를 같은 값으로 섞어 쓰지 않는다
-- ============================================================
--   [최초 작성본의 결함]
--   최초 작성본은 회원이 고른 탈퇴 사유 코드(withdraw_reason 시드, 346 —
--   예: 'app_hard')를 cancel_application 의 p_reason_code 인자에 그대로
--   넘기고 있었다. 그런데 cancel_application 은 그 값을 두 군데에 쓴다
--   (309 파일):
--     ① applications.cancel_reason_code 컬럼에 그대로 저장(186행)
--     ② lookup_values(kind='cancel_reason') 에서 그 code 로 name_ko 를
--        찾아 관리자 알림(admin_notices) 본문의 "사유" 줄에 넣는다
--        (228~233행, 못 찾으면 COALESCE 로 '-')
--   withdraw_reason 과 cancel_reason 은 서로 다른 kind 다 — 346 이
--   의도적으로 기존 cancel_reason 을 재사용하지 않고 새 kind 로 분리
--   했다(346 파일 17~24행, "응모 취소와 회원 탈퇴는 다른 사건"). 그
--   결과 ①에는 cancel_reason 표에 존재하지 않는 코드가 저장되고,
--   ②의 조회는 항상 실패해 관리자 알림의 "사유" 는 매번 "-" 로만
--   나왔을 것이다 — 저장된 데이터도, 관리자가 보는 화면도 둘 다
--   어긋난다.
--
--   [고친 방법]
--   회원이 고른 withdraw_reason 이 무엇이든(또는 아예 안 골랐든)
--   상관없이, cancel_application 에는 항상 고정된 시스템 코드
--   'withdrawal'(kind='cancel_reason', 아래 §0 에서 이 마이그레이션이
--   새로 시드)을 넘긴다. 이렇게 나눠도 되는 이유는 두 사유가 애초에
--   다른 질문에 답하기 때문이다:
--     · withdraw_reason = "왜 이 서비스를 떠나는가"(회원이 고름, 회원
--       전체에 딱 1번, withdrawal_requests.reason_code 에만 저장된다)
--     · cancel_reason    = "왜 이 응모가 취소됐는가"(응모마다 따로
--         있고, 회원이 고르는 게 아니라 이 함수가 "회원 탈퇴 때문"
--         이라고 매기는 값)
--   회원이 응모 3건을 갖고 탈퇴하면, 그 3건이 "취소된 이유"는 어느
--   withdraw_reason 을 골랐는지와 무관하게 셋 다 "회원 탈퇴"로 똑같다.
--   그래서 고정 코드 하나로 충분하고, 오히려 회원의 개인적인 탈퇴
--   사유를 응모마다 반복해 저장하는 것보다 데이터 의미에 맞다.
--
--   [자유 입력(p_reason_note)도 넘기지 않는다]
--   같은 이유로, 회원이 적은 자유 텍스트(탈퇴 사유 상세)도
--   cancel_application 의 note 인자에는 NULL 을 넘긴다. 그 값을 넘기면
--   cancel_application 이 그 문구를 "응모 취소" admin_notices 의 "보충"
--   문단에 그대로 박아 넣는데(309 파일 254~267행), 응모가 N건이면 같은
--   개인 텍스트가 관리자 화면에 N번 반복 노출된다 — 불필요한 중복이자
--   과다 노출이다. 회원이 요청받은 사항 ③에 따라, 자유 텍스트는
--   withdrawal_requests.reason_note 한 곳에만 남긴다.
--
--   [cancel_reason 시드 'withdrawal' 을 active=false 로 넣는 이유]
--   dev/lib/storage.js 의 fetchCancelReasons() 는
--   kind='cancel_reason' AND active=true 만 걸러서 반환하고, 화면
--   용도별로 나뉜 함수가 아니라 인플루언서의 "이 응모만 취소" 모달
--   (dev/js/mypage.js:751 select 옵션)과 관리자 화면의 사유 라벨 캐시
--   (dev/js/admin-influencers.js·admin-applications.js 의
--   ensureCancelReasonsCache)가 같은 함수를 함께 쓴다. active=true 로
--   넣으면 회원이 "이 응모만 취소" 모달에서 "회원 탈퇴"를 사유로 직접
--   고를 수 있게 된다 — 실제로는 그 응모 하나만 취소될 뿐 계정은 그대로
--   인데, 이름이 계정을 탈퇴시키는 것처럼 읽혀 오해를 부른다(참고:
--   마이그레이션 288 의 'admin_cancelled' 도 같은 함수를 active=true 로
--   공유해 회원 드롭다운에 노출되지만, 그 이름은 "탈퇴"만큼 행동을
--   오인시키지 않는다고 보아 지금까지 문제로 지적되지 않았다 — 여기서는
--   다르게 판단한다).
--   ⚠️ 반대급부 — active=false 로 두면 cancel_application 안의 라벨
--   조회(위 ②, active 조건 없음)는 여전히 정확히 "회원 탈퇴"를 찾아
--   admin_notices 본문에 넣는다(가장 중요한 자리는 문제없다). 다만
--   관리자 인플루언서 상세 모달의 "신청 이력" 취소 사유 배지
--   (admin-influencers.js cancelReasonLabelKo)와 신청 관리 목록의
--   같은 캐시는 active=true 만 보는 fetchCancelReasons() 에 의존해 이
--   코드를 못 찾고, 라벨 대신 원문 코드 문자열 'withdrawal' 을 그대로
--   보여준다 — 관리자 전용 화면의 코스메틱 결함이다. 이 마이그레이션은
--   데이터베이스 범위만 다루므로 고치지 않는다(클라이언트 쪽 후속 작업
--   필요 여부는 요청자가 판단할 것 — 예: fetchCancelReasons 에 "관리자
--   용 전체 조회" 옵션을 추가하거나, cancelReasonLabelKo 가 못 찾은
--   코드에 하드코딩 폴백 라벨을 붙이는 정도의 작은 수정).
--
-- ============================================================
-- 그 외 설계 메모
-- ============================================================
-- ▶ cancel_application 재사용 베이스 = 309(작업표 stale 점검 ②) — 306
--   아니다. 306→309 사이에 알림 INSERT 가 추가됐을 뿐 시그니처·검증
--   로직은 동일. 이 함수는 (p_application_id, p_reason_code, p_reason_note,
--   p_acknowledged) 그대로 호출한다 — 신규 재정의 없음.
--
-- ▶ 구매·방문 기간이 지난 응모는 cancel_application 이 사유·동의를
--   강제한다(phase != 'recruit' 이면 acknowledgement_required·
--   reason_required). 이 함수는 항상 p_acknowledged=true 를 넘기고
--   (탈퇴 신청 자체가 동의를 갈음 — 사양서 §4-2), p_reason_code 자리에는
--   회원이 고른 값이 아니라 위 추가결정 B 의 고정 시스템 코드
--   ('withdrawal')를 항상 넘긴다 — 이 값은 함수 안에서 리터럴로
--   정해지므로 회원의 withdraw_reason 선택 여부와 무관하게 절대 비지
--   않는다. 그래서 cancel_application 쪽의 두 조건(동의·사유) 모두 이
--   함수 안에서 이미 항상 충족되고, 추가로 막힐 일이 없다.
--
-- ▶ 건별 부분 실패(사양서 §4-2 "전부 아니면 전무로 짜지 않는다") — 응모
--   하나마다 별도 서브트랜잭션(BEGIN...EXCEPTION WHEN OTHERS)으로 감싼다.
--   한 건이 cancel_application 안에서 예외를 던져도(결과물 승인됨·
--   송금완료 정산 있음 — 마이그레이션 247 트리거 등) 그 한 건만
--   uncancelled_count 에 잡히고 나머지는 계속 처리된다. 추가결정 A·B
--   반영 이후에는 "사유가 없어서" 막히는 경로 자체가 사라졌으므로,
--   이 카운트에 잡히는 건 전부 다른 사유(결과물 승인·송금완료·행사
--   응모)뿐이다.
--
-- ▶ 오프라인 팝업(event_mode) 캠페인 응모는 특별 취급하지 않는다 —
--   applications 표에 BEFORE UPDATE OF status 트리거
--   guard_event_application_status_change(마이그레이션 289)가 있어,
--   cancel_application 의 일반 UPDATE 는 이 트리거에 막혀 예외를 던진다
--   (event_ticket_bypass 표시를 세우는 쪽은 reserve/cancel_event_ticket
--   뿐이고 이 함수는 그걸 세우지 않는다 — 의도적으로 안 세운다: 행사
--   티켓 취소는 재고·대기자 승격이 얽혀 있어 회원 탈퇴가 대신 처리할
--   범위가 아니다). 결과적으로 이런 응모는 예외로 잡혀 uncancelled_count
--   에 포함된다 — §4-2 가 말하는 "철회 못 한 건"의 정상적인 한 유형으로
--   본다. 관리자 화면(작업 14, 이번 범위 밖)이 그 건수를 보여주면
--   운영자가 캠페인의 「예약 현황」 탭에서 별도로 정리할 수 있다.
--
-- ▶ 멱등 — 이미 활성 신청(pending_payout·scheduled)이 있으면 새로
--   처리하지 않고 그 행을 그대로 돌려준다(cancelled_count=0,
--   uncancelled_count 는 그 신청 당시 값 그대로). unpaid_count 는 그
--   자리에서 다시 세어 최신값을 준다 — 화면이 반복 조회해도 늘 최신
--   미지급 건수를 보여주기 위해서다(재처리는 안 하지만 재계산은 한다).
--
-- ▶ 감사용 계정(is_audit=true) 은 거부한다(reason: audit_account_blocked)
--   — 운영팀 공용 계정이라 탈퇴 대상이 아니다(사양서 §1-5 ㅁ). 이
--   조건이 없으면 운영팀이 실수로 공용 계정을 탈퇴 신청 상태로 만들 수
--   있다.
--
-- ▶ 동시 중복 신청 방지 — influencers 행을 FOR UPDATE 로 먼저 잠근다.
--   같은 사람이 거의 동시에 두 번 누르면, 두 번째 호출은 첫 번째가
--   커밋될 때까지 이 지점에서 대기하고, 커밋 후에는 "이미 활성 신청이
--   있다"를 보고 멱등 경로로 빠진다 — withdrawal_requests_active_uidx
--   (345, 부분 유일 색인)가 최종 방어선이지만, 이 잠금이 있으면 유일
--   색인 위반 예외 자체를 사용자에게 보여줄 일이 거의 없어진다.
--
-- ▶ 날짜 계산은 전부 일본 시각(Asia/Tokyo) 기준 — scheduled_date =
--   (now() AT TIME ZONE 'Asia/Tokyo')::date + 5.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. cancel_reason 시드 추가 — 'withdrawal'(회원 탈퇴로 인한 응모 취소)
--    위 "2026-08-19 추가결정 B" 참고. kind='cancel_reason' 은 이미
--    CHECK 제약에 있다(마이그레이션 227, 346 이 16종으로 확장할 때도
--    그대로 유지됐다) — CHECK 확장 불필요, 시드 INSERT 만 한다.
--    active=false — 이유는 위 추가결정 B의 "cancel_reason 시드
--    'withdrawal' 을 active=false 로 넣는 이유" 절 참고.
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('cancel_reason', 'withdrawal', '회원 탈퇴', '退会のため', 96, false)
ON CONFLICT (kind, code) DO UPDATE SET
  name_ko    = EXCLUDED.name_ko,
  name_ja    = EXCLUDED.name_ja,
  sort_order = EXCLUDED.sort_order,
  active     = EXCLUDED.active,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_reason_code  text DEFAULT NULL,
  p_reason_note  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id        uuid := auth.uid();
  v_inf                  public.influencers%ROWTYPE;
  v_existing             public.withdrawal_requests%ROWTYPE;
  v_reason_valid         boolean;
  v_app_id               uuid;
  v_cancelled_count      integer := 0;
  v_uncancelled_count    integer := 0;
  v_registered_unpaid    integer;
  v_unregistered_unpaid  integer;
  v_unpaid_count         integer;
  v_status               text;
  v_scheduled_date       date;
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  -- [추가결정 B] cancel_application 에 넘길 "응모 취소 사유"는 회원이
  -- 고른 withdraw_reason 코드가 아니라 항상 이 고정값이다. 위 §0 에서
  -- 이 마이그레이션이 lookup_values(kind='cancel_reason', code=
  -- 'withdrawal') 를 함께 시드한다(active=false — 회원용 "이 응모만
  -- 취소" 드롭다운에는 노출하지 않는다).
  v_app_cancel_reason_code CONSTANT text := 'withdrawal';
BEGIN
  -- 1. 본인 확인
  IF v_influencer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 2. 본인 인플루언서 행 잠금(동시 중복 신청 직렬화) + 감사용 계정 판별
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 3. 멱등 — 이미 활성 신청(대기·예정)이 있으면 재처리하지 않고 그대로 반환
  SELECT * INTO v_existing
    FROM public.withdrawal_requests
   WHERE influencer_id = v_influencer_id
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1;

  IF FOUND THEN
    SELECT count(*) INTO v_registered_unpaid
      FROM public.settlements
     WHERE influencer_id = v_influencer_id
       AND status IN ('pending', 'on_hold');

    SELECT count(*) INTO v_unregistered_unpaid
      FROM public._settlement_cert_candidates() c
     WHERE c.influencer_id = v_influencer_id
       AND c.is_success;

    RETURN jsonb_build_object(
      'ok',                true,
      'status',             v_existing.status,
      'scheduled_date',     v_existing.scheduled_date,
      'cancelled_count',    0,
      'uncancelled_count',  v_existing.uncancelled_count,
      'unpaid_count',       v_registered_unpaid + v_unregistered_unpaid
    );
  END IF;

  -- 4. 사유 검증(선택) — [추가결정 A] 값이 있으면 withdraw_reason 시드
  --    (346)의 활성 코드여야 하지만, 값이 없어도(NULL/빈 문자열) 통과
  --    한다 — 사유는 더 이상 필수가 아니다.
  IF p_reason_code IS NOT NULL AND length(trim(p_reason_code)) > 0 THEN
    SELECT EXISTS (
      SELECT 1 FROM public.lookup_values
       WHERE kind = 'withdraw_reason'
         AND code = trim(p_reason_code)
         AND active = true
    ) INTO v_reason_valid;

    IF NOT v_reason_valid THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason');
    END IF;
  END IF;

  -- 5. 철회 가능한 응모만 취소 — 건별 처리, 한 건이 막혀도 계속 간다
  --    (§4-2 "전부 아니면 전무로 짜지 않는다"). cancel_application(309)
  --    은 phase!='recruit' 이면 사유·동의를 요구하므로 p_acknowledged=
  --    true 를 항상 넘기고(탈퇴 신청 자체가 그 동의를 갈음 — §4-2), 사유
  --    코드는 회원이 고른 withdraw_reason 이 아니라 위에서 정의한 고정
  --    시스템 코드(v_app_cancel_reason_code='withdrawal')를 넘긴다 —
  --    [추가결정 B]. 이 값은 회원이 사유를 아예 안 골랐어도 항상 채워져
  --    있으므로, 모집 기간이 지난 응모도 정상적으로 철회된다(이번 수정의
  --    핵심). 회원의 자유 입력(p_reason_note)은 여기엔 넘기지 않는다
  --    (추가결정 B) — withdrawal_requests.reason_note 1곳에만 남긴다.
  FOR v_app_id IN
    SELECT id FROM public.applications
     WHERE user_id = v_influencer_id
       AND status IN ('pending', 'approved')
  LOOP
    BEGIN
      PERFORM public.cancel_application(v_app_id, v_app_cancel_reason_code, NULL, true);
      v_cancelled_count := v_cancelled_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- 결과물 승인됨(cancel_application 자체 차단) · 송금완료 정산 있음
      -- (마이그레이션 247 트리거) · 행사(event_mode) 응모(마이그레이션 289
      -- 트리거) 등, 이유를 가리지 않고 "철회 못 한 건"으로만 센다. 사유가
      -- 없어서 막히는 경로는 추가결정 A·B 로 없어졌다.
      v_uncancelled_count := v_uncancelled_count + 1;
    END;
  END LOOP;

  -- 6. 미지급 판정 — ① 이미 등록된 정산(정산대기·보류, 위 헤더 ② 판단)
  --    + ② 인증 성공했지만 아직 정산행이 없는 건(위 헤더 ① 판단).
  SELECT count(*) INTO v_registered_unpaid
    FROM public.settlements
   WHERE influencer_id = v_influencer_id
     AND status IN ('pending', 'on_hold');

  SELECT count(*) INTO v_unregistered_unpaid
    FROM public._settlement_cert_candidates() c
   WHERE c.influencer_id = v_influencer_id
     AND c.is_success;

  v_unpaid_count := v_registered_unpaid + v_unregistered_unpaid;

  IF v_unpaid_count = 0 THEN
    v_status         := 'scheduled';
    v_scheduled_date := v_today_jst + 5;
  ELSE
    v_status         := 'pending_payout';
    v_scheduled_date := NULL;
  END IF;

  INSERT INTO public.withdrawal_requests (
    influencer_id, status, reason_code, reason_note,
    scheduled_date, requested_by_kind, uncancelled_count
  ) VALUES (
    v_influencer_id, v_status, NULLIF(trim(p_reason_code), ''), NULLIF(trim(p_reason_note), ''),
    v_scheduled_date, 'self', v_uncancelled_count
  );

  RETURN jsonb_build_object(
    'ok',                true,
    'status',             v_status,
    'scheduled_date',     v_scheduled_date,
    'cancelled_count',    v_cancelled_count,
    'uncancelled_count',  v_uncancelled_count,
    'unpaid_count',       v_unpaid_count
  );
END;
$$;

COMMENT ON FUNCTION public.request_withdrawal(text, text) IS
  '[347] 회원(인플루언서) 본인 탈퇴 신청. 사양서 §4-1·§4-2·§4-3, 작업표 작업 5. '
  '본인 확인 + 감사용 계정 거부 + 멱등(활성 신청 있으면 그대로 반환) + 사유 검증'
  '(선택 — 값이 있을 때만 lookup_values kind=withdraw_reason 대조, 2026-08-19 결정)'
  ' + 철회 가능한 응모만 건별 취소(cancel_application 309 재사용, 부분 실패 허용, '
  '넘기는 사유는 회원이 고른 withdraw_reason 이 아니라 고정 cancel_reason '
  '코드 ''withdrawal'') + 미지급 판정(등록된 정산[정산대기·보류] + '
  '_settlement_cert_candidates() 의 미등록 인증성공건) → 0건이면 scheduled'
  '(예정일=오늘[JST]+5일), 있으면 pending_payout. unpaid_amount_jpy 는 반환하지 '
  '않는다(2026-08-19 결정 — 금액 미노출).';

REVOKE ALL ON FUNCTION public.request_withdrawal(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text) TO authenticated;

-- 원격 호출 함수 목록 즉시 갱신 (345·346 과 같은 관행)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
-- 「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 1단계씩 순서대로
-- 실행하며 결과를 확인할 것 — 한 번에 다 실행하지 말 것)
-- ============================================================
--
-- [V0] (SQL 편집기 가능 — 읽기 전용, 권한 가드 없음) 함수 생성·서명 확인
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid) AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'request_withdrawal';
--   기대: 1행, args = 'p_reason_code text DEFAULT NULL::text,
--        p_reason_note text DEFAULT NULL::text', returns = 'jsonb'
--   (p_reason_code 도 DEFAULT NULL 이 붙었는지 반드시 확인 — 추가결정 A)
--
-- [V0-b] (SQL 편집기 가능 — 읽기 전용) cancel_reason 'withdrawal' 시드 확인
--   SELECT kind, code, name_ko, name_ja, sort_order, active
--     FROM public.lookup_values
--    WHERE kind = 'cancel_reason'
--    ORDER BY sort_order;
--   기대: 기존 6~7행(schedule_unavailable~other, admin_cancelled) +
--        'withdrawal'(name_ko='회원 탈퇴', name_ja='退会のため',
--        sort_order=96, active=false) 1행 추가 — 총 7~8행.
--
-- [V1] (SQL 편집기 가능 — 읽기 전용) 테스트에 쓸 계정 후보 찾기 — 개발서버에
--   정산 24건(정산대기 14 · 송금완료 5 · 보류 3 · 취소 2)이 이미 있으므로
--   새 시험 데이터를 안 만들어도 「대기」·「예정」 두 경로를 모두 시험할 수
--   있다(작업표 S2 해소 근거와 동일 데이터).
--     SELECT s.influencer_id, i.email, s.status, count(*)
--       FROM public.settlements s
--       JOIN public.influencers i ON i.id = s.influencer_id
--      WHERE i.is_audit = false
--      GROUP BY s.influencer_id, i.email, s.status
--      ORDER BY s.status, count(*) DESC;
--   → 이 목록에서 status='pending' 또는 'on_hold' 가 있는 influencer_id 로
--     "unpaid_count > 0(pending_payout)" 경로를, 이 목록에 전혀 없는 다른
--     인플루언서 계정으로 "unpaid_count = 0(scheduled)" 경로를 시험한다.
--
-- [V1-b] (SQL 편집기 가능 — 읽기 전용) ★ 이번 수정의 핵심을 시험할 계정
--   찾기 — 모집 기간이 이미 지난(phase != 'recruit') 응모를 가진 계정.
--   deadline 이 지났으면 cancel_application 의 phase 판정(309 파일
--   157~169행)이 절대 'recruit' 가 될 수 없다(recruit 조건 자체가
--   "now() <= deadline").
--     SELECT a.id AS application_id, a.user_id AS influencer_id, i.email,
--            a.status, c.title, c.deadline
--       FROM public.applications a
--       JOIN public.campaigns c ON c.id = a.campaign_id
--       JOIN public.influencers i ON i.id = a.user_id
--      WHERE a.status IN ('pending','approved')
--        AND i.is_audit = false
--        AND c.deadline IS NOT NULL
--        AND c.deadline < now()
--      ORDER BY c.deadline DESC
--      LIMIT 20;
--   → 여기서 나온 influencer_id 로, 그 계정에 withdrawal_requests 활성
--     행(pending_payout/scheduled)이 없는지 먼저 확인한 뒤(있으면 멱등
--     경로로 빠져 이번 시험이 안 됨) 아래 [V2]-⑦ 에서 쓴다.
--
-- ⚠️ [V2] 이 함수는 SQL 편집기로 검증할 수 없다 — auth.uid() 가 로그인
--   사용자를 요구하는데 SQL 편집기는 서비스 키라 auth.uid() 가 NULL 이고,
--   그러면 이 함수는 항상 {ok:false, reason:'not_authenticated'} 만 돌려준다
--   (그 자체는 정상 동작이지만 실제 검증이 아니다). 반드시 실제 로그인한
--   시험 인플루언서 계정의 브라우저 콘솔에서 실행할 것.
--
--   ① 정산대기(unpaid_count>0)가 있는 계정으로 로그인 → 브라우저 콘솔:
--     const {data, error} = await db.rpc('request_withdrawal',
--       {p_reason_code: 'app_hard', p_reason_note: '테스트'});
--     console.log(error, data);
--   기대: error 없음, data = {ok:true, status:'pending_payout',
--     scheduled_date:null, cancelled_count:<그 계정의 pending/approved 응모 수
--     중 철회 가능한 만큼>, uncancelled_count:<나머지>, unpaid_count:>0}
--
--   ② 같은 계정으로 한 번 더 호출(멱등 확인):
--     const {data:data2} = await db.rpc('request_withdrawal',
--       {p_reason_code: 'app_hard', p_reason_note: '테스트'});
--     console.log(data2);
--   기대: data2.cancelled_count === 0 (재처리 안 함), status/scheduled_date
--     는 data 와 동일, unpaid_count 는 그 사이 정산 상태가 안 바뀌었으면 동일
--
--   ③ 정산이 전혀 없는 계정으로 로그인 → 같은 호출
--   기대: data = {ok:true, status:'scheduled',
--     scheduled_date:'<오늘(JST)+5일 날짜>', unpaid_count:0, ...}
--
--   ④ [2026-08-19 갱신 — 추가결정 A] 사유 없이 호출(인자 자체를 생략해도
--   되고, null 을 명시해도 된다). ①~③ 에 안 쓴 새 계정(활성 신청 없는
--   계정)으로:
--     const {data:data4a} = await db.rpc('request_withdrawal', {});
--     console.log(data4a);
--   기대(변경!): data4a.ok === true (예전 기대였던
--   {ok:false, reason:'reason_required'} 는 더 이상 나오지 않는다 — 사유가
--   선택이 됐다). status 는 그 계정의 미지급 여부에 따라 pending_payout
--   또는 scheduled.
--
--   ⑤ 잘못된 사유 코드로 호출(값은 있는데 목록에 없는 코드 — 이 경로만
--   여전히 실패해야 한다):
--     const {data:data5} = await db.rpc('request_withdrawal', {p_reason_code: 'xxx'});
--   기대: data5 = {ok:false, reason:'invalid_reason'}
--
--   ⑥ 감사용 계정(influencers.is_audit=true)으로 로그인해 호출 — 감사용
--   계정이 없으면 SQL 편집기로 임의 계정을 잠시 is_audit=true 로 바꾼 뒤
--   그 계정으로 로그인해 시험하고, 시험 후 반드시 원래 값으로 되돌릴 것.
--   기대: {ok:false, reason:'audit_account_blocked'}
--
--   ⑦ [2026-08-19 신규 — ★ 이번 수정의 핵심] 모집 기간이 지난(phase !=
--   'recruit') 응모를 가진 계정으로, 사유 없이 호출. [V1-b] 에서 찾은
--   influencer_id 로 로그인 후:
--     const {data:data7} = await db.rpc('request_withdrawal', {});
--     console.log(data7);
--   기대: data7.ok === true 이고, [V1-b] 에서 찾은 그 응모(application_id)
--   가 uncancelled_count 가 아니라 cancelled_count 쪽에 포함돼야 한다
--   (정확히 몇 건인지는 그 계정의 응모 구성에 따라 다르므로, 아래 [V4-b]
--   로 그 특정 응모의 실제 상태를 직접 확인할 것). 이게 실패하면(그
--   응모가 uncancelled_count 로 빠지면) 이번 수정이 목표한 결함이
--   재현된 것이다.
--
-- [V3] (SQL 편집기 가능 — 읽기 전용) 실제로 신청 행이 만들어졌는지 확인
--   SELECT id, influencer_id, status, reason_code, reason_note, requested_at,
--          scheduled_date, requested_by_kind, uncancelled_count
--     FROM public.withdrawal_requests
--    ORDER BY requested_at DESC
--    LIMIT 10;
--
-- [V4] (SQL 편집기 가능) 위 ① 에서 실제로 취소된 응모가 있는지(cancelled_count>0
--   이었다면) 확인 — cancel_reason_code 는 이제 회원이 고른 withdraw_reason
--   값(예: 'app_hard')이 아니라 항상 'withdrawal' 로 저장되어야 한다
--   (추가결정 B, 예전 기대였던 원문 그대로 저장은 더 이상 맞지 않음).
--   SELECT id, status, cancel_reason_code, cancel_reason, cancel_phase, cancelled_at
--     FROM public.applications
--    WHERE user_id = '<① 에서 쓴 influencer_id>'
--      AND status = 'cancelled'
--    ORDER BY cancelled_at DESC;
--   → cancel_reason_code = 'withdrawal' 이어야 하고, cancel_reason(자유
--     텍스트 컬럼)은 NULL 이어야 한다(추가결정 B — note 를 안 넘김).
--
-- [V4-b] (SQL 편집기 가능) ⑦ 에서 확인한 "모집 기간이 지난 응모"가 실제로
--   취소됐는지 그 응모 id 하나로 직접 확인
--   SELECT id, status, cancel_reason_code, cancel_phase, cancelled_at
--     FROM public.applications
--    WHERE id = '<[V1-b] 에서 찾은 application_id>';
--   → status='cancelled', cancel_reason_code='withdrawal',
--     cancel_phase 는 'recruit' 가 아닌 값(purchase/visit/post/other 중
--     하나)이어야 한다 — 'recruit' 이면 애초에 phase 판정이 달라 이
--     검증의 취지와 안 맞는 계정을 골랐다는 뜻이니 [V1-b] 를 다시 실행.
--
-- [V5] 시험 데이터 정리 — ⚠️ 이 함수가 만든 withdrawal_requests 행과
--   cancel_application 이 취소한 applications 행은 되돌릴 수 없는 시험
--   결과다(cancel_application 자체가 취소를 되돌리는 기능이 없음 — 취소 후
--   재응모는 "새 응모"로만 가능). 개발서버 시험 계정이라면 그대로 둬도
--   무방하지만, 실제 서비스처럼 계속 써야 하는 계정으로 시험했다면 아래로
--   흔적을 지운다(운영에서는 절대 하지 말 것 — 이건 개발서버 정리용):
--     DELETE FROM public.withdrawal_requests WHERE influencer_id = '<시험 계정 id>';
--   ⚠️ applications.status='cancelled' 로 바뀐 응모는 이 DELETE 로 안
--   돌아온다 — 필요하면 별도로 status 를 수동 복구할 것(신청 원본 데이터를
--   보존해 둔 경우에만 가능).
--
-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.request_withdrawal(text, text);
-- DELETE FROM public.lookup_values WHERE kind = 'cancel_reason' AND code = 'withdrawal';
-- ⚠️ 이 함수가 이미 withdrawal_requests 행을 만들었거나 응모를 취소했다면,
-- 함수를 지워도 그 데이터는 그대로 남는다(함수 롤백은 코드만 되돌릴 뿐 이미
-- 발생한 부수효과를 되돌리지 않는다) — 필요하면 [V5] 방식으로 별도 정리.
-- ⚠️ lookup_values 의 'withdrawal' 행을 지우기 전에, 이미 그 코드로
-- cancel_reason_code 가 저장된 applications 행이 있는지 먼저 확인할 것
-- (실제 외래 키가 아니라 컨벤션뿐이라 DB 단에서는 안 막히지만, 지우면
-- 그 응모들의 취소 사유 라벨을 관리자 화면에서 못 찾게 된다).
-- 이 함수를 부르는 다른 데이터베이스 함수는 없다(전수 검색 결과 없음) —
-- DROP 순서 문제 없음. dev/lib/storage.js 의 requestWithdrawal() 래퍼가
-- 이 함수를 부르므로, 롤백 시 그 래퍼도 호출하지 않도록 클라이언트 배포와
-- 맞출 것(이번 작업 범위에서는 아직 화면[작업 9]이 없으므로 실사용 영향 없음).
