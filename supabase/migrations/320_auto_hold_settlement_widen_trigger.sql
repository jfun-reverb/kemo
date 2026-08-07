-- ============================================================
-- 320_auto_hold_settlement_widen_trigger.sql
-- 「승인 → 되돌리기(pending) → 미승인(rejected)」 두 단계 전이에도 정산 자동 보류
-- 사양: 전수조사 후속 조치 묶음 G — G-7
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -l "FUNCTION public.auto_hold_settlement_on_app_reject" supabase/migrations/*.sql
--     → 246 단 1곳. 246 이 "가장 큰 번호의 정의" == "유일한 정의"이자
--     이 파일이 고치는 원본이다.
--
-- ▶ 왜 필요한가 — 지금 어떻게 새는가
--   246 의 트리거는 `WHEN (OLD.status = 'approved' AND NEW.status IN
--   ('rejected','cancelled'))` 로 걸려 있다. 관리자가 신청을
--     승인(approved) → 되돌리기(pending) → 미승인(rejected)
--   순서로 처리하면, **두 번째 전이(pending→rejected)의 OLD.status 는
--   'pending' 이라 이 WHEN 조건에 안 걸린다.** 결과적으로 최종 상태는
--   미승인인데 그 신청에 붙은 정산은 정산대기(pending) 그대로 남고,
--   화면의 「신청 반려로 자동 보류」 앰버 배지도 뜨지 않는다 — 되돌릴 수
--   없는 「송금완료 기록」 버튼이 있는 화면에서 이 사실이 안 보인 채로
--   방치될 수 있다. dev/js/admin-applications.js 의 updateAppStatus() 를
--   직접 확인한 결과, 되돌리기(status='pending')·미승인(status='rejected')
--   두 요청 모두 같은 일반 UPDATE 경로(updateApplication)를 타므로, 이
--   두 단계짜리 흐름은 관리자 화면에서 실제로 발생할 수 있는 조작이다.
--
-- ▶ 무엇을 바꿨나
--   트리거 WHEN 조건에서 `OLD.status = 'approved'` 요구를 없앤다. 대신
--   "최종적으로 반려·취소로 들어가는 모든 전이"에서 검사하도록 넓힌다:
--     WHEN (NEW.status IN ('rejected','cancelled')
--           AND OLD.status IS DISTINCT FROM NEW.status)
--   함수 본문의 이중 방어 조건(WHEN 과 같은 조건을 함수 안에도 한 번 더 두는
--   246·247·289 의 공통 관례)도 같은 모양으로 맞춘다.
--   ⚠️ `AFTER UPDATE OF status` 는 status 가 SET 절에 포함되기만 하면 값이
--   실제로는 안 바뀌어도 발동하는 Postgres 특성이 있어(289 파일 헤더가 같은
--   이유로 짚은 바로 그 특성), WHEN 절에 `OLD.status IS DISTINCT FROM
--   NEW.status` 를 명시해 헛도는 실행을 막았다.
--
--   함수 본문의 실제 처리 로직(정산이 pending 일 때만 on_hold 로 바꾸고,
--   paid 는 절대 건드리지 않는다)은 **한 글자도 바꾸지 않았다** — 이미 그
--   조건(`IF v_settlement.status = 'pending' THEN`)이 있어 넓어진 발동
--   조건 아래에서도 이 성질이 그대로 유지된다.
--
-- ▶ 247(송금완료 반려 차단 가드)과의 관계 — 확인 결과
--   247 은 BEFORE UPDATE 트리거이고 WHEN 이 `OLD.status = 'approved' AND
--   NEW.status IN ('rejected','cancelled','pending')` 이다. 즉 247 은
--   "되돌리기(approved→pending)" **그 자체**도 감시 대상에 포함하고 있어,
--   정산이 이미 송금완료(paid) 상태인 신청은 **되돌리기 시도 자체가 247 에
--   막힌다**(UPDATE 문이 예외로 롤백되어 pending 으로도 못 간다). 따라서
--   이 파일이 다루는 두 단계 흐름(approved→pending→rejected) 은 애초에
--   **paid 가 아닌 정산(pending/on_hold/없음)만 겪을 수 있는 경로**이고,
--   246 의 함수 본문도 pending 상태만 on_hold 로 바꾸므로 — 이 두 트리거
--   사이에 실제 충돌은 없다.
--   ⚠️ 다만 이번 확인 중 247 자체의 한계 하나를 발견했다(이 파일이 고치는
--   범위 밖 — 참고로만 남긴다): 247 의 WHEN 도 `OLD.status = 'approved'`
--   를 요구하므로, **두 번째 전이(pending→rejected)는 247 자체도 감시하지
--   않는다.** 즉 만약 어떤 다른 경로로 정산이 paid 인 신청이 'approved' 를
--   거치지 않고 'pending' 상태에 놓이는 일이 생긴다면(현재 발견된 정상
--   경로로는 일어나지 않는다 — 되돌리기는 반드시 approved 에서 출발한다),
--   그 상태에서의 반려는 247 에도 이 파일의 320 에도 안 걸린다. 지금
--   확인 가능한 모든 정상 경로에서는 이 경우가 발생하지 않으므로 이 파일의
--   범위에서는 조치하지 않았다 — 후속으로 다룰 항목이면 별도로 다룰 것.
--
-- ▶ 행사(이벤트) 예약과의 관계 — 확인 결과
--   `record_application_status_event()`(131/154 원본, 283 이 행사 캠페인에서
--   조기 반환하도록 재정의)는 이 트리거(auto_hold_settlement_on_app_reject,
--   246/320)와 **완전히 다른 트리거·다른 함수**다 — applications 표에 걸린
--   여러 AFTER UPDATE OF status 트리거 중 하나일 뿐이고, 283 의 재정의는
--   그 함수 자신에만 영향을 준다. 이 파일이 넓히는 246/320 트리거는 283 의
--   영향을 받지 않고 지금과 똑같이 동작한다.
--   행사 캠페인의 신청 상태는 289(guard_event_application_status_change)가
--   막아 두어, reserve_event_ticket·cancel_event_ticket·
--   cancel_event_ticket_admin(288) 세 함수만 bypass 표시를 세우고 직접
--   UPDATE 할 수 있다. 이 함수들이 신청을 cancelled 로 바꾸는 경우 — 정산이
--   붙어 있고 pending 이면 이 넓어진 트리거가 그대로 on_hold 로 보류한다.
--   이는 기존에도(OLD.status='approved' 인 취소 건에 한해) 이미 일어나던
--   동작이라 새로운 부작용이 아니다. approved→pending(되돌리기)에 대응하는
--   행사 전용 경로는 확인 결과 없다(288 의 세 함수 중 상태를 pending 으로
--   되돌리는 것은 "취소 후 재예약" 뿐이며, 그 경우 최종 상태가 approved 로
--   다시 확정되므로 rejected/cancelled 로 끝나지 않는다) — 이 파일이 넓힌
--   조건에 새로 걸리는 행사 케이스는 없다.
--
-- ▶ 메모 문구
--   기존 고정 문구 '신청 반려로 자동 보류' 를 그대로 쓴다(변경 안 함) —
--   정산 화면이 이 문자열로 앰버 배지를 그린다(memo LIKE '%자동 보류%').
--
-- ▶ 과거분은 이 마이그레이션이 고치지 않는다
--   이 트리거는 "앞으로 일어나는" applications.status 변경에만 반응한다.
--   이미 어긋나 있는(최종 상태는 미승인·취소인데 정산은 정산대기로 남은)
--   과거 건은 파일 하단 [사전 확인용] 조회로 찾아 사람이 직접 정산 화면에서
--   보류 처리해야 한다.
--
-- ▶ 롤백
--   246 파일의 CREATE OR REPLACE + CREATE TRIGGER 블록을 그대로 재실행하면
--   이 변경만 되돌아간다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.auto_hold_settlement_on_app_reject()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_settlement record;
BEGIN
  -- [320] 발동 조건 재확인 (WHEN 절과 이중 방어 — 함수가 단독으로 호출돼도
  -- 안전, 246·247·289 의 공통 관례). ⚠️ OLD.status='approved' 요구를
  -- 없앴다 — 「승인→되돌리기→미승인」 두 단계 전이의 두 번째 단계
  -- (pending→rejected)도 이 함수에 도달해야 하기 때문(파일 상단 참고).
  IF NEW.status NOT IN ('rejected', 'cancelled')
     OR NEW.status IS NOT DISTINCT FROM OLD.status
  THEN
    RETURN NEW;
  END IF;

  SELECT id, status, version
    INTO v_settlement
    FROM public.settlements
   WHERE application_id = NEW.id
   FOR UPDATE;

  -- 정산 행 자체가 없으면 아무 것도 하지 않음(no-op)
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- pending 만 자동 보류. paid/on_hold/cancelled 는 건드리지 않음
  -- (246 원본과 완전히 동일한 조건 — 이 부분은 바뀐 것이 없다)
  IF v_settlement.status = 'pending' THEN
    UPDATE public.settlements
       SET status  = 'on_hold',
           memo    = '신청 반려로 자동 보류',
           version = version + 1
     WHERE id = v_settlement.id;

    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(), '신청 반려로 자동 보류');
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.auto_hold_settlement_on_app_reject() IS
  '[320] applications.status 가 rejected/cancelled 로 바뀔 때(직전 상태가 approved 였든
   pending[되돌리기 경유]였든 무관), 연결된 settlements(정산) 이 pending 이면 on_hold 로
   자동 보류한다. [320] 이전(246)에는 OLD.status=''approved'' 를 요구해 「승인→되돌리기
   (pending)→미승인」 두 단계 전이의 두 번째 단계에서 보류가 안 걸리는 사각지대가 있었다.
   paid 는 여전히 절대 건드리지 않음(자동 환수 금지 — 247 가드가 되돌리기 자체를 막아
   paid 정산은 이 경로에 도달하지 않는다). 인플루언서 알림 없음(잠금 상태 정합).
   SECURITY DEFINER — 트리거 전용.';

DROP TRIGGER IF EXISTS trg_auto_hold_settlement_on_app_reject ON public.applications;
CREATE TRIGGER trg_auto_hold_settlement_on_app_reject
  AFTER UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (NEW.status IN ('rejected', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.auto_hold_settlement_on_app_reject();

COMMENT ON TRIGGER trg_auto_hold_settlement_on_app_reject ON public.applications IS
  '[320] rejected/cancelled 로 최종 전이될 때마다 발동(직전 상태 제한 없음). 246 은
   OLD.status=''approved'' 로 제한했었다 — 두 단계 전이(승인→되돌리기→미승인)의 두 번째
   단계를 놓치던 문제를 320 이 해소.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- ============================================================
--
-- [1] 함수·트리거 재정의 확인
-- SELECT tgname, pg_get_triggerdef(oid) AS def
--   FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND tgname = 'trg_auto_hold_settlement_on_app_reject';
-- → WHEN 절에 OLD.status='approved' 가 더는 없고, NEW.status IN
--   ('rejected','cancelled') AND OLD.status IS DISTINCT FROM NEW.status
--   조건만 있는지 눈으로 확인.
--
-- [2] 두 단계 전이 재현 — 개발서버에서만 실행 (운영 실데이터 직접 UPDATE 금지)
--     정산이 pending 상태로 걸린 approved 신청 하나를 준비한 뒤:
--     UPDATE applications SET status='pending' WHERE id='<테스트 신청 id>';
--     -- 246/320 트리거는 여기서는 발동하지 않아야 한다(되돌리기 자체는 최종
--     -- 상태가 아니므로). 아래로 확인:
--     SELECT status FROM settlements WHERE application_id='<테스트 신청 id>';
--     -- 기대값: 여전히 pending (아직 보류로 바뀌지 않음)
--
--     UPDATE applications SET status='rejected' WHERE id='<테스트 신청 id>';
--     -- 이제 두 번째 전이에서 발동해야 한다:
--     SELECT status, version, memo FROM settlements WHERE application_id='<테스트 신청 id>';
--     -- 기대값: status='on_hold', memo='신청 반려로 자동 보류'
--
--     SELECT action, prev_status, next_status, memo FROM settlement_events
--      WHERE settlement_id = (SELECT id FROM settlements WHERE application_id='<테스트 신청 id>')
--      ORDER BY at DESC LIMIT 1;
--     -- 기대값: action='hold', prev_status='pending', next_status='on_hold'
--
-- [3] 회귀 확인 — 기존 단일 단계(approved→rejected 직행) 는 그대로 동작하는지
--     UPDATE applications SET status='rejected' WHERE id='<정산 pending 붙은 approved 신청 id>';
--     -- 기대값: 246 시절과 동일하게 정상 보류
--
-- [4] paid 정산이 걸린 신청은 여전히 되돌리기 자체가 막히는지(247 회귀 확인)
--     UPDATE applications SET status='pending' WHERE id='<정산 paid 붙은 approved 신청 id>';
--     -- 기대값: ERROR settlement_already_paid: ... (247 가드가 그대로 막음.
--     -- 이 파일은 247 을 건드리지 않았으므로 이 동작은 원래도 그대로여야 한다)
--
-- ============================================================
-- [사전 확인용] 지금 이미 어긋나 있는 과거분 찾기 — 이 마이그레이션은
-- 앞으로만 막으므로, 과거에 이미 「최종 상태는 미승인·취소인데 정산은
-- 정산대기(pending)로 남은」 응모가 있으면 사람이 직접 정산 관리 화면에서
-- 확인·처리해야 한다. 적용 전후 아무 때나 실행 가능(과거분은 이 마이그레이션
-- 적용으로 자동 정리되지 않는다).
-- ============================================================
-- SELECT
--   s.application_id,
--   a.status               AS 신청_최종상태,
--   i.name                 AS 인플루언서_한자,
--   i.name_kana            AS 인플루언서_가나,
--   c.title                AS 캠페인명,
--   c.campaign_no          AS 캠페인번호,
--   s.amount_jpy            AS 정산금액,
--   s.status                AS 정산상태,
--   s.created_at             AS 정산행_생성일
--   FROM public.settlements s
--   JOIN public.applications a ON a.id = s.application_id
--   LEFT JOIN public.influencers i ON i.id = s.influencer_id
--   LEFT JOIN public.campaigns   c ON c.id = s.campaign_id
--  WHERE s.status = 'pending'
--    AND a.status IN ('rejected', 'cancelled')
--  ORDER BY s.created_at DESC;
-- → 0행이 아니면, 나온 각 행을 정산 관리 화면에서 「보류」 처리할지 사람이
--   직접 판단할 것(자동 처리 아님 — 되돌릴 수 없는 「송금완료 기록」 버튼이
--   있는 화면이므로 신중히).
-- ============================================================
