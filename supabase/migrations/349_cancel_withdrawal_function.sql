-- ============================================================
-- 349_cancel_withdrawal_function.sql
-- 회원 탈퇴 — 작업 6 (탈퇴 취소 함수)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-1·§4-6 ⑦
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 6
-- 선행(개발서버 적용·확인 완료): 345(withdrawal_requests 표) · 346(withdraw_reason 시드)
--                                347(request_withdrawal 신청 함수)
--
-- 산출 계약:
--   public.cancel_withdrawal() RETURNS jsonb   (인자 없음 — 사람당 활성 신청은
--     항상 1건뿐이라 응모 취소[cancel_application]처럼 대상 id 를 받을 필요가
--     없다. 345 의 부분 유일 색인 withdrawal_requests_active_uidx 가 그 전제를
--     보장한다)
--   성공: { ok:true, status:'cancelled', previous_status:'pending_payout'|'scheduled' }
--   실패: { ok:false, reason: 'not_authenticated' | 'not_found' |
--          'audit_account_blocked' | 'already_done' | 'already_cancelled' |
--          'admin_requested' }
--
-- ============================================================
-- ① 「본인이 낸 신청만 취소할 수 있다」 — requested_by_kind='admin' 은 거부
-- ============================================================
--   요청에 명시된 결정. influencer_id = auth.uid() 로만 걸러서는 이 조건을
--   못 지킨다 — 관리자가 자격 상실 등으로 대신 신청한 행(약관 제6조 3항,
--   345 컬럼 주석 "requested_by_kind: admin(관리자가 대신 신청)")도
--   influencer_id 는 여전히 그 회원 본인이다(관리자의 id 가 아니다). 그래서
--   "내 행인가"만으로는 admin 기원 행을 걸러내지 못하고, requested_by_kind
--   를 직접 봐야 한다.
--
--   이걸 안 막으면 강제 탈퇴(약관 제6조 3항 — 자격 상실)가 회원 본인의
--   "탈퇴 취소" 버튼 한 번으로 무력화된다. 이건 작업표에 없던 결정으로,
--   요청 본문에서 새로 지정됐다.
--
--   거부 사유 코드는 'admin_requested' 로 별도로 둔다 — 클라이언트가
--   "취소할 수 없는 이유"를 구분해 보여줄 수 있게(예: "이 탈퇴는 운영팀이
--   처리했습니다. 문의는 ~로 해 주세요" 같은 문구).
--
-- ============================================================
-- ② done · cancelled 는 거부 — 별도 사유 코드로 구분
-- ============================================================
--   done: 이미 확정됐다. 방침상 확정 시점부터 개인정보 칸 비우기(작업 10,
--   이번 범위 밖)가 돌 수 있는 시점이라 되돌리면 이미 지워진 정보를
--   복구해야 하는 모순이 생긴다 — 그래서 되돌리지 않는다(사양서 §4-1 상태
--   표 — "완료"는 유일하게 취소 화살표가 없는 상태).
--
--   cancelled: 이미 취소된 행을 또 취소하는 건 무의미한 재처리다. 여기서
--   'not_found' 로 뭉뚱그리지 않고 'already_cancelled' 로 따로 둔 이유 —
--   "탈퇴 신청 자체가 없다"(not_found)와 "신청했다가 이미 취소했다"
--   (already_cancelled)는 클라이언트가 서로 다른 안내를 보여줘야 하는
--   다른 상황이다.
--
--   ⚠️ 「최신 행」기준으로 판정한다(requested_at DESC LIMIT 1) — 번갈아
--   나오는 이유는 아래 "그 외 설계 메모" 참고.
--
-- ============================================================
-- ③ 철회된 응모는 되살리지 않는다 (의도된 동작 — 결함 아님)
-- ============================================================
--   request_withdrawal(347)이 자동 철회한 응모(applications.status=
--   'cancelled', cancel_reason_code='withdrawal')를 이 함수는 건드리지
--   않는다. 이유 세 가지:
--
--   (가) cancel_application(309) 자체에 "취소를 되돌리는" 기능이 없다 —
--       347 파일의 [V5] 절 주석이 이미 명시: "취소 후 재응모는 새 응모로만
--       가능". 이 프로젝트 컨벤션상 응모 취소는 편도(one-way)다. 탈퇴
--       취소만 예외적으로 응모를 되살리면 이 컨벤션과 어긋난다.
--
--   (나) 되살리는 게 안전하지 않다 — 취소된 시점과 취소를 취소하는 시점
--       사이에 그 캠페인의 모집이 마감됐거나(deadline 경과), 결과물 제출
--       마감이 지났거나, 다른 신청자로 정원이 채워졌을 수 있다. 응모를
--       그냥 되살리면 마감 강제 트리거(마이그레이션 272·326)가 막고 있는
--       "마감 지난 신규 응모"와 실질적으로 같은 상황을 UPDATE 경로로
--       우회하게 된다.
--
--   (다) 사양서가 이미 이걸 명시했다 — §4-6 ⑦ "취소하면 자동 철회된
--       응모는 되살아나지 않는다 — 응모 취소는 별개 사건이고 캠페인이
--       이미 마감됐을 수 있다. 회원에게 이 점을 미리 알린다"(화면 문구는
--       작업 9, 이번 범위 밖).
--
--   → 이 함수는 withdrawal_requests 행 하나만 갱신하고 applications 표는
--   전혀 건드리지 않는다.
--
-- ============================================================
-- ④ 홍보 대상 복귀에 별도 처리를 만들지 않는다
-- ============================================================
--   작업 16(get_promo_digest_targets 재정의, 이번 범위 밖·아직 미착수)이
--   대상을 고르는 조회에 "탈퇴 신청이 pending_payout 또는 scheduled 상태가
--   아닌 회원"이라는 조건을 걸 것이다(사양서 §4-6 ⑪). 이 함수가 하는 일은
--   status 를 'cancelled' 로 바꾸는 것뿐이므로, 작업 16 이 매번 최신 상태를
--   다시 읽는 구조라면 다음 배치 실행 때 자동으로 그 조건을 벗어나 홍보
--   대상으로 복귀한다 — 사양서가 명시적으로 "되살리는 처리를 따로 만들지
--   않는다"고 못 박은 이유가 이것이다(두 곳이 각자 상태를 관리하면 서로
--   다른 말을 하게 된다).
--
--   ⚠️ 이 마이그레이션 시점에는 작업 16 이 아직 없으므로(get_promo_digest_
--   targets 최신 정의는 321 — withdrawal_requests 를 전혀 모른다) 지금
--   당장은 "복귀"랄 것도 없다 — 끊는 처리 자체가 아직 안 걸려 있기
--   때문이다. 작업 16 을 만들 때 이 함수가 아니라 그쪽에서 상태 조건을
--   추가하면 이 코멘트가 말한 자동 복귀가 성립한다.
--
-- ============================================================
-- 그 외 설계 메모
-- ============================================================
-- ▶ 대상 행 조회는 "influencer_id 로 가장 최근 신청(requested_at DESC)
--   1건"이다 — 최신 행이 항상 "지금 이 사람의 탈퇴 상태"를 대표한다.
--   근거: 활성 상태(pending_payout·scheduled)는 부분 유일 색인(345)이
--   사람당 최대 1건만 허용하므로, 새 활성 행이 생기려면 이전 행이 반드시
--   먼저 종료(done 또는 cancelled)됐어야 한다 — 즉 "활성 행이 있다면 그건
--   항상 최신 행"이라는 사실이 색인으로 보장된다. done 행 다음에 새 신청이
--   가능한가(로그인 차단이 아직 없는 지금 이론상 가능)는 작업 8 소관이지,
--   이 함수가 걱정할 문제가 아니다 — 그런 경우에도 "최신 행을 취소 대상으로
--   본다"는 규칙은 항상 "지금 진행 중인 것을 취소한다"는 의미로 일관되게
--   맞아떨어진다.
--
-- ▶ 재신청·재취소를 반복하는 것을 막지 않는다(사양서 확인 완료 Q6과 직결).
--   Q6 확정 결정: "'취소됨' 상태로 남긴다 — 몇 번 탈퇴하려다 말았나가
--   이탈 신호다." 즉 반복 자체가 사양서가 의도적으로 관찰하려는
--   신호이지 막아야 할 남용이 아니다. 남용 가능성을 검토했지만 새로
--   열리는 위험은 없다고 판단했다:
--     · 재신청(347)이 두 번째부터 처리하는 응모 취소는, 첫 취소 이후
--       회원이 실제로 새 캠페인에 응모했을 때만 존재한다 — 그 자체가
--       정상적인 "다시 마음이 바뀌어 계속 쓰다가 또 나가려는" 흐름이고,
--       cancel_application 자체의 알림·감사 로직(관리자 admin_notices
--       등록) 은 이 반복 때문에 특별히 더 취약해지지 않는다(취소할 응모가
--       없으면 그 루프는 그냥 0회 반복된다).
--     · 재가입 차단(작업 8·11, 이번 범위 밖)이 보는 것은 "done" 상태
--       뿐이다 — cancelled 는 차단 대상이 아니므로 반복 자체가 재가입
--       규칙을 우회하는 수단이 되지 않는다.
--     · 부분 유일 색인이 "동시에 활성 행 2개"만 막을 뿐 "반복 횟수"는
--       원래부터 제한하지 않는다 — 이 함수가 새로 여는 구멍이 아니다.
--   → 그래서 이 함수에 쿨다운·횟수 제한을 넣지 않았다. 필요하다고
--   판단되면 별도 마이그레이션으로 추가할 수 있다(예: 최근 N일 내
--   cancelled 행 개수 제한).
--
-- ▶ 취소 이력은 "행을 지우지 않고 새 행을 쌓는" 방식으로 자연히 남는다.
--   cancel_withdrawal 은 기존 행의 status 만 'cancelled' 로 바꿀 뿐 지우지
--   않고, 다음 request_withdrawal 호출은 활성 행이 없으므로(방금
--   cancelled 로 바뀌었으니) 멱등 분기를 타지 않고 새 행을 INSERT 한다
--   (347 파일 323~350행 — 멱등 분기 조건이 status IN ('pending_payout',
--   'scheduled') 인 행만 찾으므로 cancelled 행은 여기 안 걸린다). 그
--   결과 한 사람이 "신청→취소→재신청→취소"를 반복하면 withdrawal_requests
--   에 cancelled 행이 시간순으로 쌓인다 — 이것이 345 컬럼 주석이 애초에
--   "인플루언서 표에 칸으로 두지 않고 별도 표로 둔" 이유(여러 줄 이력)와
--   정확히 일치한다. completed_at·scheduled_date 는 그 시점 계산값 그대로
--   보존되어(이 함수가 건드리지 않음) "취소 시점에 예정일이 언제였는지"도
--   이력으로 남는다.
--
-- ▶ completed_at 은 건드리지 않는다(NULL 그대로). 345 컬럼 주석 — "탈퇴가
--   실제로 확정(done)된 시각. 재가입 차단 6개월·PayPal 5년·결과물 이미지
--   6개월 파기가 전부 이 시각을 기준으로 센다." 이 함수가 취소를 허용하는
--   대상은 오직 status IN ('pending_payout','scheduled') 뿐이고(위 ②),
--   completed_at 은 오직 done 전이(작업 7, 이번 범위 밖) 시점에만 채워지는
--   값이라, 이 함수가 다루는 행은 애초에 completed_at 이 항상 NULL 이다 —
--   그러므로 "취소 시 completed_at 을 지운다"는 로직 자체가 불필요하다
--   (지울 값이 없다). 방어적으로 NULL 대입을 추가하지 않은 이유는, 만약
--   미래에 이 불변조건이 깨진다면(예: 작업 7 구현 버그로 done 행이 활성
--   상태 조건을 만족하는 채로 남는 경우) 그 값을 조용히 NULL 로 덮어쓰는
--   대신 위 ②의 already_done 가드가 먼저 걸려 그 이상 상태를 노출하는
--   편이 디버깅에 낫다고 판단했다.
--
-- ▶ processed_by 는 본인 취소면 NULL — 요청에 명시된 결정. 345 컬럼 주석
--   "본인 신청·자동 전이(예약 실행)는 NULL"과 대칭으로, "본인 취소"도
--   NULL 로 남긴다. 이 함수의 UPDATE 문은 processed_by 컬럼을 아예
--   SET 절에 넣지 않는다 — 위 ①에서 이미 requested_by_kind='admin' 행은
--   거부하므로, 이 UPDATE 가 실제로 도달하는 행은 항상 자기 신청(self)
--   행뿐이고, self 신청 행은 애초에 347 이 processed_by 를 채운 적이
--   없어(347 의 INSERT 문에 processed_by 가 없음) 원래부터 NULL 이다 —
--   그래서 "건드리지 않는 것"이 곧 "NULL 로 유지하는 것"과 같다.
--
-- ▶ 잠금 순서 — influencers 행을 먼저 FOR UPDATE 로 잠그고, 그다음
--   withdrawal_requests 의 대상 행을 FOR UPDATE 로 잠근다. 347
--   (request_withdrawal)과 같은 순서다(347 파일 313행 — influencers 를
--   먼저 잠근 뒤 withdrawal_requests 를 조회) — 두 함수가 같은 순서로
--   잠그지 않으면 동시에 호출될 때 교착(deadlock)이 날 수 있다. 이
--   순서를 지키면, 같은 사람이 request_withdrawal 과 cancel_withdrawal
--   을 거의 동시에 호출해도 둘 중 하나가 먼저 influencers 행 잠금을
--   얻고 나머지는 그 뒤에서 대기한다 — 순서가 어긋나 있으면(하나는
--   influencers→withdrawal_requests, 다른 하나는 반대 순서) 서로가
--   서로의 잠금을 기다리며 멈추는 상황이 생길 수 있다.
--
--   ⚠️ 후속 작업 7(advance_withdrawal_states, 이번 범위 밖)을 만들 때도
--   같은 순서(influencers 먼저, withdrawal_requests 나중)를 지킬 것 —
--   그 함수는 배치로 여러 행을 순회하므로 특히 이 순서를 지켜야
--   회원이 그 순간 request/cancel 을 부르는 것과 부딪히지 않는다.
--
-- ▶ 감사용 계정(is_audit=true) 처리는 347 과 맞춘다 — reason 코드도 동일하게
--   'audit_account_blocked'. 감사용 계정은 request_withdrawal 자체가
--   거부하므로 정상 흐름에서는 활성 탈퇴 신청 행을 가질 수 없지만,
--   운영자가 SQL 로 신청 행을 만든 뒤 그 계정을 감사용으로 전환하는 등의
--   비정상 경로까지 방어하기 위해 이 함수에도 같은 가드를 그대로 둔다.
--
-- ▶ 반환 형태는 request_withdrawal(347)과 동일한 계약 — 성공도 실패도
--   예외(EXCEPTION)를 던지지 않고 항상 {ok, ...} jsonb 를 반환한다.
--   PostgREST 오류 응답(네트워크·인증 만료 등 진짜 예외)과 "정상적인
--   업무 실패"(reason 있는 ok:false)를 클라이언트가 구분할 수 있게
--   하기 위해서다 — dev/lib/storage.js 의 requestWithdrawal() 이 이미
--   같은 방식으로 처리하고 있고, cancelWithdrawal() 도 동일하게 만든다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_withdrawal()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id  uuid := auth.uid();
  v_inf            public.influencers%ROWTYPE;
  v_req            public.withdrawal_requests%ROWTYPE;
BEGIN
  -- 1. 본인 확인
  IF v_influencer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 2. 본인 인플루언서 행 잠금(347 과 같은 순서 — 잠금 순서 메모 참고)
  --    + 감사용 계정 판별
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 3. 가장 최근 탈퇴 신청 행 잠금 — 활성 행이 있다면 이게 항상 그 행이다
  --    (부분 유일 색인이 "활성 행은 최신 행뿐"이라는 전제를 보장한다 —
  --    위 "그 외 설계 메모" 참고)
  SELECT * INTO v_req
    FROM public.withdrawal_requests
   WHERE influencer_id = v_influencer_id
   ORDER BY requested_at DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 4. 종료 상태는 거부(②) — done·cancelled 는 취소할 대상이 아니다
  IF v_req.status = 'done' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_done');
  END IF;

  IF v_req.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_cancelled');
  END IF;

  -- 5. 관리자가 대신 신청한 행은 회원이 못 되돌린다(①) — 여기 도달했다면
  --    status 는 pending_payout 또는 scheduled(활성) 둘 중 하나뿐이다
  IF v_req.requested_by_kind = 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_requested');
  END IF;

  -- 6. 취소 처리 — status 만 바꾼다. completed_at·processed_by·
  --    scheduled_date·reason_code·reason_note·uncancelled_count 는
  --    건드리지 않는다(위 "그 외 설계 메모" 각 항목 참고). updated_at 은
  --    trg_withdrawal_requests_updated_at(345) 트리거가 자동 갱신한다.
  --    ⚠️ applications 표는 전혀 건드리지 않는다 — 철회된 응모를 되살리지
  --    않는 것은 의도된 동작이다(위 ③).
  UPDATE public.withdrawal_requests
     SET status = 'cancelled'
   WHERE id = v_req.id;

  RETURN jsonb_build_object(
    'ok',               true,
    'status',            'cancelled',
    'previous_status',   v_req.status
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_withdrawal() IS
  '[349] 회원(인플루언서) 본인 탈퇴 취소. 사양서 §4-1·§4-6 ⑦, 작업표 작업 6. '
  '본인 확인 + 감사용 계정 거부 + 가장 최근 신청 행을 대상으로 판정 — '
  'done·cancelled 는 거부(already_done/already_cancelled), '
  'requested_by_kind=admin(관리자 대신 신청, 약관 제6조 3항)은 거부'
  '(admin_requested — 회원 본인의 취소로 강제 탈퇴를 무력화하지 못하게). '
  '통과하면 status만 cancelled 로 바꾸고 completed_at·processed_by 등은 '
  '건드리지 않는다. 철회됐던 응모는 되살리지 않는다(의도된 동작 — '
  'cancel_application 자체가 편도라 되돌리는 기능이 없고, 되살리면 마감 '
  '경과·정원 소진 등과 충돌할 수 있다). 재신청·재취소 반복은 막지 않는다'
  '(Q6 결정 — 반복 자체가 이탈 신호로 관찰 대상). 홍보 대상 복귀는 별도 '
  '처리 없음 — 작업 16(get_promo_digest_targets 재정의, 이번 범위 밖)이 '
  '상태를 다시 읽는 구조라면 자동으로 복귀한다.';

REVOKE ALL ON FUNCTION public.cancel_withdrawal() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_withdrawal() TO authenticated;

-- 원격 호출 함수 목록 즉시 갱신 (345·346·347 과 같은 관행)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
-- 「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 1단계씩 순서대로
-- 실행하며 결과를 확인할 것 — 한 번에 다 실행하지 말 것)
--
-- ⚠️ ★ 이 함수는 SQL 편집기로 "호출"할 수 없다 — 347 과 같은 이유(본인 확인
-- 가드가 auth.uid() 를 요구하는데 SQL 편집기는 서비스 키라 auth.uid() 가
-- NULL 이라 항상 {ok:false, reason:'not_authenticated'} 만 나온다. 그건
-- 정상 동작이지만 실제 검증이 아니다). 아래 [V2] 이후는 반드시 실제
-- 로그인한 시험 인플루언서 계정의 브라우저 콘솔에서 실행할 것.
-- 다만 "시험 데이터를 미리 만들어 두는 INSERT/UPDATE" 자체는 서비스 키로
-- SQL 편집기에서 해도 된다(RLS 는 authenticated 세션에만 걸리고 서비스
-- 키는 원래 그걸 우회한다 — 345 파일의 [V6] 이 이미 같은 방식으로 시험
-- 데이터를 직접 INSERT 했다).
--
-- ⚠️ ★ 작업 7(상태 전이 예약 실행)이 아직 없다 — 그래서 지금은 대기
-- (pending_payout) 행이 스스로 예정(scheduled)으로 넘어가는 일이 일어나지
-- 않는다(그 전이는 작업 7 이 매일 돌며 하는 일이다). 즉 아래 검증은
-- **pending_payout 상태에서만** 자연스럽게 재현할 수 있다.
--   ⚠️ 단, "scheduled" 상태 자체는 작업 7 이 없어도 나올 수 있다 —
--   request_withdrawal(347)은 신청 그 순간 미지급이 0건이면 그 자리에서
--   바로 scheduled 로 만든다(347 파일 409~415행, 예약 실행이 아니라 신청
--   함수 자신이 하는 일이다). 다만 아래 검증에 쓸 haruka.test@reverb.jp
--   계정은 정산 미지급 건이 있는 계정이라(347 검증 시 unpaid_count=2로
--   pending_payout 경로를 확인함, 이 파일 [V1] 참고) 다시 신청해도
--   pending_payout 으로만 떨어진다 — 그래서 이 계정으로는 pending_payout
--   경로만 자연스럽게 재현되고, scheduled 취소까지 보려면 미지급이 전혀
--   없는 다른 시험 계정이 필요하다(선택 사항, 아래 [V4] 참고).
--   already_done 은 done 상태 자체가 작업 7 없이는 정상 경로로 절대
--   나오지 않으므로, [V5]에서 서비스 키로 직접 흉내 낸다.
--
-- [V0] (SQL 편집기 가능 — 읽기 전용) 함수 생성·서명 확인
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid) AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'cancel_withdrawal';
--   기대: 1행, args = '' (인자 없음), returns = 'jsonb'
--
-- [V1] (SQL 편집기 가능 — 읽기 전용) haruka.test@reverb.jp 의 인플루언서
--   id 를 다시 확인 — 이 파일 시점에는 347 검증 후 그 계정의
--   withdrawal_requests 행을 지웠다고 안내받았으므로 지금은 0행이어야
--   정상이다.
--     SELECT i.id, i.email FROM public.influencers i
--      WHERE i.email = 'haruka.test@reverb.jp';
--     SELECT * FROM public.withdrawal_requests
--      WHERE influencer_id = '<위에서 나온 id>';
--   기대: 두 번째 조회 0행(비어 있음). 만약 남아 있다면 먼저
--   `DELETE FROM public.withdrawal_requests WHERE influencer_id = '<id>';`
--   로 정리한 뒤 아래로 진행한다.
--
-- [V2] haruka.test@reverb.jp 로 로그인 → 브라우저 콘솔에서 먼저 신청을
--   다시 만든다(정산 미지급 건이 그대로 있으므로 pending_payout 이 될
--   것으로 기대):
--     const {data:reqData} = await db.rpc('request_withdrawal', {});
--     console.log(reqData);
--   기대: reqData.ok === true, reqData.status === 'pending_payout'
--   (unpaid_count > 0). 만약 status 가 'scheduled' 로 나오면(정산 상태가
--   그 사이 바뀐 것) 아래 검증은 그대로 유효하다 — 사유 코드는 pending_
--   payout·scheduled 어느 쪽이든 동일한 already_* 체계로 검증된다.
--
-- [V3] 같은 브라우저 콘솔에서 취소 호출:
--     const {data:cancelData} = await db.rpc('cancel_withdrawal', {});
--     console.log(cancelData);
--   기대: { ok:true, status:'cancelled', previous_status:'pending_payout' }
--   (또는 [V2]에서 scheduled 였다면 previous_status:'scheduled')
--
-- [V3-b] (SQL 편집기 가능 — 읽기 전용) 실제로 바뀌었는지 직접 확인
--     SELECT id, status, completed_at, processed_by, scheduled_date,
--            requested_at, updated_at
--       FROM public.withdrawal_requests
--      WHERE influencer_id = '<haruka id>'
--      ORDER BY requested_at DESC LIMIT 1;
--   기대: status='cancelled', completed_at IS NULL, processed_by IS NULL,
--   updated_at > requested_at(트리거가 갱신했는지)
--
-- [V3-c] 같은 브라우저 콘솔에서 다시 한 번 취소 호출(이미 취소된 것을
--   또 취소 시도):
--     const {data:cancelData2} = await db.rpc('cancel_withdrawal', {});
--     console.log(cancelData2);
--   기대: { ok:false, reason:'already_cancelled' }
--
-- [V3-d] ★ 재신청이 "새 행"을 만드는지 확인(취소 이력이 남는지의 핵심) —
--   같은 브라우저 콘솔에서 다시 신청:
--     const {data:reqData2} = await db.rpc('request_withdrawal', {});
--     console.log(reqData2);
--   기대: reqData2.ok === true, status 는 그때 정산 상태에 따름(대개
--   pending_payout 그대로). 이어서 SQL 편집기에서:
--     SELECT id, status, requested_at FROM public.withdrawal_requests
--      WHERE influencer_id = '<haruka id>' ORDER BY requested_at DESC;
--   기대: 2행 이상 — 가장 최근 행은 새 status(pending_payout/scheduled),
--   그 이전 행은 status='cancelled' 로 그대로 남아 있다(재활성화가 아니라
--   새 행 생성 — 이력 보존 확인).
--
-- [V4] (선택 — scheduled 상태에서의 취소를 직접 보고 싶을 때만) 정산
--   미지급 건이 전혀 없는 다른 시험 인플루언서 계정을 하나 골라([V1] 과
--   같은 방식의 조회로 확인) 그 계정으로 로그인 후 [V2]~[V3-b] 를
--   반복한다. 기대: reqData.status==='scheduled', cancelData.
--   previous_status==='scheduled'.
--
-- [V5] (선택 — already_done 가드까지 보고 싶을 때만, ⚠️ 서비스 키로 상태를
--   직접 흉내 내는 시험용 절차) 아래는 정상 경로로는 절대 안 나오는
--   상태를 SQL 편집기에서 강제로 만들어 가드만 확인하는 것이다 —
--   운영에서는 하지 말 것, 개발서버 전용 시험 계정으로만:
--     -- 이미 cancelled 로 끝난 [V3] 의 행을 done 으로 임시로 바꾼다
--     UPDATE public.withdrawal_requests
--        SET status = 'done', completed_at = now()
--      WHERE influencer_id = '<haruka id>' AND status = 'cancelled'
--      ORDER BY requested_at DESC LIMIT 1;
--   → haruka 브라우저 콘솔에서:
--     const {data:cancelData3} = await db.rpc('cancel_withdrawal', {});
--     console.log(cancelData3);
--   기대: { ok:false, reason:'already_done' }
--   ⚠️ 시험 후 반드시 되돌릴 것(아래 [V6] 정리에서 함께 지운다 — done 으로
--   바꾼 행을 그대로 두면 haruka 계정이 실제로 파기 대상처럼 보일 수 있다).
--
-- [V6] (선택 — admin_requested 가드를 보고 싶을 때만) SQL 편집기에서
--   서비스 키로 관리자 대신 신청 행을 직접 만든다(정상 경로에는 아직
--   "관리자가 대신 신청하는" RPC 가 없으므로 — 이번 작업 범위 밖):
--     INSERT INTO public.withdrawal_requests
--       (influencer_id, status, requested_by_kind)
--     VALUES ('<haruka id>', 'pending_payout', 'admin');
--   → haruka 브라우저 콘솔:
--     const {data:cancelData4} = await db.rpc('cancel_withdrawal', {});
--     console.log(cancelData4);
--   기대: { ok:false, reason:'admin_requested' }
--
-- [V7] 시험 데이터 정리 — [V3]~[V6] 에서 만든 haruka.test@reverb.jp 의
--   withdrawal_requests 행을 전부 정리한다(운영에서는 이런 정리를
--   하지 말 것 — 이건 개발서버 정리 전용):
--     DELETE FROM public.withdrawal_requests
--      WHERE influencer_id = '<haruka id>';
--   ⚠️ [V2]/[V3-d] 에서 request_withdrawal 이 함께 취소한 응모(있다면)는
--   이 DELETE 로 되돌아오지 않는다 — 347 파일 [V5] 절과 같은 이유(응모
--   취소는 편도). 필요하면 별도로 그 응모의 status 를 수동 복구할 것.
--
-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.cancel_withdrawal();
-- ⚠️ 이 함수가 이미 어떤 회원의 withdrawal_requests 행을 cancelled 로
-- 바꿨다면, 함수를 지워도 그 데이터는 그대로 남는다(함수 롤백은 코드만
-- 되돌릴 뿐 이미 발생한 부수효과를 되돌리지 않는다) — 347 파일의 롤백
-- 절과 같은 성격.
-- 이 함수를 부르는 다른 데이터베이스 함수는 없다(전수 검색 결과 없음) —
-- DROP 순서 문제 없음. dev/lib/storage.js 의 cancelWithdrawal() 래퍼가
-- 이 함수를 부르므로, 롤백 시 그 래퍼도 호출하지 않도록 클라이언트
-- 배포와 맞출 것(이번 작업 범위에서는 아직 회원 탈퇴 화면[작업 9]이
-- 없으므로 실사용 영향 없음 — 347 롤백 절과 같은 사정).
