-- ============================================================
-- 354_request_withdrawal_lock_gate.sql
--
-- 회원 탈퇴 — 작업 15 「시행 전 잠금 · 자동 해제」 ②/②
--   (① = 353_withdrawal_settings_and_lock.sql — **반드시 먼저** 적용)
--
-- 사양서   : docs/specs/2026-08-18-member-withdrawal.md §4-6 ⑭ · §5 ⑧
-- 작업표   : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 15」
--
-- ============================================================
-- ① 무엇을 하나 — request_withdrawal(text,text) **재정의**
-- ============================================================
--   ★ **베이스는 347 이 아니라 350 이다.**
--     347 이 만들고 350 이 재정의했다(350 §3 — 미지급 판정을 공용 내부 함수
--     _withdrawal_unpaid_count 로 뽑아냈다). 347 을 베이스로 삼으면 그 공용화가
--     **되돌아가** 신청 함수와 예약 실행이 서로 다른 기준으로 미지급을 세게
--     된다 — 350 헤더 ①이 막으려던 바로 그 사고다.
--     (규칙: 함수 재정의는 **파일 번호가 가장 큰 정의**를 베이스로 —
--      메모리 feedback_function_redefine_latest_base)
--
--   350 대비 바뀐 것은 **둘뿐**이고, 나머지는 한 글자도 안 건드렸다:
--     [가] 게이트  — 응모 철회 반복문 **앞**에 잠금 판정
--     [나] 백스톱  — 반복문 **뒤**에, 잠금 기간인데 철회 못 한 건이 나왔으면
--                    그 반복문째 되돌리고 「사람에게 넘김」으로 착지
--
-- ============================================================
-- ② [가] 게이트 — 왜 반복문 **앞**인가
-- ============================================================
--   뒤에 두면 「잠겨서 거부됐는데 응모는 이미 취소된」 상태가 된다. 회원은
--   탈퇴도 안 됐는데 응모만 사라진다 — 되돌릴 방법이 없다
--   (cancel_application 은 편도다).
--
--   판정은 353 의 _withdrawal_lock_blockers() **하나**를 부른다. 화면이
--   누르기 전에 부르는 get_withdrawal_precheck() 와 **같은 헬퍼**라 두 판정이
--   갈라지지 않는다(353 헤더 ④).
--
--   조건 셋(전부 0이어야 통과):
--     · 승인된 결과물이 있는 살아있는 응모
--     · 행사(오프라인 팝업) 살아있는 응모
--     · 정산 기록(상태 불문)
--     · 받지 못한 보수                       ← 353 헤더 ③ 참조(사양서 확장분)
--
--   ⚠️ 거부는 **예외가 아니라 `{ok:false, reason:'locked_needs_support'}`** 로
--     돌려준다. 350·349 와 같은 반환 계약이라 화면이 오류가 아니라 정상 분기로
--     받는다. 예외로 던지면 화면에 원문 오류 문자열이 뜬다.
--
--   ⚠️ 시행 후에는 이 블록에 **들어가지도 않는다**(`IF NOT is_withdrawal_open()`).
--     그래서 작업 18 이 조건문을 걷어내는 것을 잊어도 동작은 안전하다. 반대로
--     「항상 검사하고 시행 후만 예외 처리」로 짰다면 잊는 순간 시행 후에도 회원이
--     문의로 튕긴다 — 그래서 이 방향으로 짰다.
--
-- ============================================================
-- ③ [나] 백스톱 — 헬퍼가 낡을 때를 대비한 착지점
-- ============================================================
--   게이트의 판정은 cancel_application(309)의 거부 규칙을 **베낀 것이 아니라**
--   「이 회원에게 무엇이 있나」로 독립 서술한 것이다(353 헤더 ④). 개념이 갈라질
--   여지는 줄였지만 0은 아니다 — 새 차단 트리거가 하나 붙으면 헬퍼는 「깨끗함」
--   이라 하고 실제 철회는 막힐 수 있다.
--
--   그래서: **게이트를 통과했는데 실제로 철회 못 한 건이 나오면**(잠금 기간에
--   한해) 지정 예외를 던져 **철회 반복문 블록 전체를 되돌리고** 게이트와 같은
--   거부를 반환한다.
--
--   → 드리프트의 결과가 **「잘못된 처리」가 아니라 「사람에게 넘어감」**이 된다.
--     「0건이라고 판정해 놓고 실제로는 남은」 상태가 데이터베이스에 절대 안 생긴다.
--
--   ⚠️ PL/pgSQL 의 BEGIN…EXCEPTION 블록은 내부에 저장점(savepoint)을 만든다.
--     그래서 예외를 잡는 순간 **그 블록 안에서 한 데이터 변경만** 되돌아간다
--     (cancel_application 이 한 UPDATE·알림·감사 기록 전부). 함수 바깥
--     트랜잭션은 살아 있어 우리가 반환값을 돌려줄 수 있다.
--     변수 값은 롤백되지 않으므로 v_uncancelled_count 를 그대로 알려줄 수 있다.
--
--   ⚠️ **시행 후(open)에는 백스톱을 걸지 않는다.** 시행 후에는 철회 못 한 건이
--     있어도 그대로 진행하고 그 건수를 기록하는 것이 원래 설계다
--     (withdrawal_requests.uncancelled_count · 관리자 화면이 보여준다).
--
--   ⚠️ 반복문은 **한 벌만** 쓴다. 「잠금 기간용 / 시행 후용」으로 두 벌을 쓰면
--     이 저장소에서 반복된 「같은 판단이 여러 곳」 사고를 우리가 새로 만드는 것이다.
--
--   🔴 **백스톱 예외는 반드시 문자열(SQLERRM)로 식별한다 — 코드값으로 바꾸지 말 것.**
--     이 저장소에서 SQLSTATE '22023' 은 cancel_application(309)·
--     guard_reject_with_paid_settlement(247) 등 **여러 곳이 함께 쓰는 값**이다.
--     「코드값으로 판별하는 게 깔끔하다」며 `WHEN SQLSTATE '22023'` 으로 바꾸면
--     **다른 함수가 던진 예외를 백스톱으로 오인**해, 진짜 오류를 「문의 창구로
--     보내기」로 조용히 덮어버린다.
--     (지금 구조에서 충돌이 없는 이유 = 안쪽 반복문의 EXCEPTION 이
--      cancel_application 의 예외를 **전부 먼저 삼키고**, 백스톱의 RAISE 는
--      반복문이 끝난 뒤 별도로 실행되는 문장이라 겹칠 자리 자체가 없다.)
--
--   ⚠️ **백스톱은 「판정이 낡았을 때」뿐 아니라 「우연한 일시 오류일 때」도 발동한다.**
--     안쪽 반복문이 이유를 가리지 않고 세기 때문에, 잠깐의 행 잠금 경합 같은
--     것으로 한 건이 실패해도 **그 회원은 문의 창구로 간다**(정상 취소된 나머지
--     응모도 함께 되돌아간다). 의도한 선택이다 — 잠금 기간에 「일부만 처리된」
--     상태를 남기는 것보다 **통째로 사람에게 넘기는 쪽**이 안전하다. 회원은
--     다시 눌러 볼 수 있고, 그때 일시 오류가 없으면 정상 진행된다.
--
-- ============================================================
-- ④ 손대지 않는 것
-- ============================================================
--   · cancel_withdrawal(349) — **게이트를 절대 걸지 않는다.** 취소는 회원에게
--     유리한 동작이라 잠금과 무관하다. 걸면 「신청은 됐는데 취소는 안 되는」
--     함정이 된다.
--   · advance_withdrawal_states(352) — **잠금을 보지 않는다.** 보면 잠금 기간에
--     접수된 신청이 시행일까지 멈춰 「5일 뒤」 안내와 실제가 어긋난다. 잠금은
--     **입구에서만** 판정한다는 것이 이 설계의 일관된 규칙이다.
--   · purge_withdrawn_personal_data(352) · pg_cron 등록 · 350 의 나머지 함수
--
-- ============================================================
-- ⑤ 되돌리기
-- ============================================================
--   350 파일의 "CREATE OR REPLACE FUNCTION public.request_withdrawal(" 블록부터
--   그 GRANT 줄까지를 그대로 다시 실행하면 이 파일 이전 상태로 돌아간다
--   (350 파일 하단에도 같은 안내가 있다). 353 을 되돌리려면 이 파일을 먼저
--   되돌려야 한다 — 여기서 353 의 함수를 부르기 때문이다.
--
-- ⚠️ **적용 순서: 353 → 354.** 반대로 하면 없는 함수를 불러 실패한다.
-- ⚠️ **운영 배포 순서: 이 함수가 먼저, 화면이 나중.** 정산 3단계에서 「버튼은
--    열렸는데 함수가 없던 15시간」 사고를 반복하지 않는다.
-- ============================================================

BEGIN;

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
  v_unpaid_count         integer;
  v_status               text;
  v_scheduled_date       date;
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_app_cancel_reason_code CONSTANT text := 'withdrawal';
  -- [354] 잠금 판정용
  v_is_open              boolean;
  v_b                    record;
  v_backstop CONSTANT    text := 'withdrawal_lock_backstop';
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
  --    ⚠️ [354] 게이트보다 **앞**이다. 이미 접수된 신청을 조회하는 것은 잠금과
  --      무관하고, 뒤에 두면 잠금 기간에 상태가 바뀐 회원(예: 신청 뒤 정산 행이
  --      생긴 회원)이 자기 신청 상태조차 못 보게 된다.
  SELECT * INTO v_existing
    FROM public.withdrawal_requests
   WHERE influencer_id = v_influencer_id
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok',                true,
      'status',             v_existing.status,
      'scheduled_date',     v_existing.scheduled_date,
      'cancelled_count',    0,
      'uncancelled_count',  v_existing.uncancelled_count,
      'unpaid_count',       public._withdrawal_unpaid_count(v_influencer_id)
    );
  END IF;

  -- 4. 사유 검증(선택) — [추가결정 A, 347] 값이 있으면 withdraw_reason 시드
  --    (346)의 활성 코드여야 하지만, 값이 없어도(NULL/빈 문자열) 통과한다.
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

  -- ============================================================
  -- 4-b. ★ [354 신설] 시행 전 잠금 게이트 — 응모 철회 **앞**
  --
  --   시행 후에는 이 블록에 들어가지도 않는다. 걸린 것이 하나라도 있으면
  --   **아무것도 바꾸지 않고** 거부하고 문의 창구로 보낸다(사양서 §5 ⑧).
  -- ============================================================
  v_is_open := public.is_withdrawal_open();

  IF NOT v_is_open THEN
    SELECT * INTO v_b FROM public._withdrawal_lock_blockers(v_influencer_id);

    IF v_b.approved_deliverable_apps > 0
       OR v_b.event_apps      > 0
       OR v_b.settlement_rows > 0
       OR v_b.unpaid_count    > 0 THEN
      RETURN jsonb_build_object(
        'ok',     false,
        'reason', 'locked_needs_support',
        'blockers', jsonb_build_object(
          'approved_deliverable_apps', v_b.approved_deliverable_apps,
          'event_apps',                v_b.event_apps,
          'settlement_rows',           v_b.settlement_rows,
          'unpaid_count',              v_b.unpaid_count
        )
      );
    END IF;
  END IF;

  -- ============================================================
  -- 5. 철회 가능한 응모만 취소 — 건별 처리, 한 건이 막혀도 계속 간다
  --
  --   [354] 바깥 BEGIN…EXCEPTION 으로 감쌌다 — 백스톱(위 헤더 ③)이 예외를
  --   던지면 **이 블록 안에서 한 취소가 전부 되돌아간다**. 반복문 자체는
  --   350 과 한 글자도 다르지 않다.
  -- ============================================================
  BEGIN
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
        -- 트리거) 등, 이유를 가리지 않고 "철회 못 한 건"으로만 센다. 행사 응모는
        -- 마이그레이션 350 의 배치가 뒤이어 재시도한다.
        v_uncancelled_count := v_uncancelled_count + 1;
      END;
    END LOOP;

    -- ★ [354] 백스톱 — 잠금 기간인데 철회 못 한 건이 나왔다면, 게이트의 판정이
    --   실제와 어긋났다는 뜻이다(헬퍼가 낡았거나 새 차단이 생겼거나).
    --   그대로 두면 「0건이라 판정해 놓고 실제로는 남은」 상태가 된다.
    --   → 이 블록째 되돌리고 게이트와 같은 거부로 착지시킨다.
    IF NOT v_is_open AND v_uncancelled_count > 0 THEN
      RAISE EXCEPTION '%', v_backstop USING ERRCODE = '22023';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- ⚠️ 식별은 **문자열 비교**다. SQLSTATE '22023' 은 이 저장소에서 여러 함수가
    --   함께 쓰는 값이라 코드값으로 바꾸면 남의 예외를 백스톱으로 오인한다
    --   (위 헤더 ③ 참조 — 절대 `WHEN SQLSTATE '22023'` 으로 바꾸지 말 것).
    IF SQLERRM = v_backstop THEN
      -- 여기 도달한 시점에 위 블록의 취소는 전부 되돌아갔다(저장점 롤백).
      -- 어떤 종류가 막았는지는 알 수 없으므로 건수만 알린다 — 화면은 이 경우도
      -- locked_needs_support 로 같게 그리고, 운영팀이 개별 확인한다.
      RETURN jsonb_build_object(
        'ok',     false,
        'reason', 'locked_needs_support',
        'backstop', true,
        'blockers', jsonb_build_object('uncancellable_apps', v_uncancelled_count)
      );
    END IF;
    -- 백스톱이 아닌 예외(잠금 대기 실패 등)는 삼키지 않는다 — 조용히 성공한 척
    -- 하면 원인을 영영 모른다.
    RAISE;
  END;

  -- 6. 미지급 판정 — 공용 내부 함수로 통일(350 §3)
  v_unpaid_count := public._withdrawal_unpaid_count(v_influencer_id);

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
  '[354, 350 재정의] 회원(인플루언서) 본인 탈퇴 신청. 350 대비 둘만 다르다 — '
  '① 응모 철회 앞에 시행 전 잠금 게이트(is_withdrawal_open 이 false 이고 '
  '_withdrawal_lock_blockers 가 하나라도 0보다 크면 locked_needs_support 로 거부, '
  '아무것도 바꾸지 않는다) ② 철회 반복문 뒤에 백스톱(잠금 기간인데 철회 못 한 건이 '
  '나오면 그 반복문째 되돌리고 같은 거부로 착지 — 판정이 낡아도 잘못된 상태가 '
  '남지 않게). 시행 후에는 게이트·백스톱 어느 쪽도 발동하지 않는다. '
  '이 함수가 request_withdrawal 의 최신 원본이다.';

REVOKE ALL ON FUNCTION public.request_withdrawal(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
--
-- ⚠️ **SQL 편집기로는 한 단계도 검증할 수 없다.** 본인 확인 가드에서 무조건
--    not_authenticated 로 끝난다(서비스 키에는 로그인 사용자가 없다).
--    **시험 인플루언서 계정의 브라우저 콘솔**에서 1단계씩.
--
-- ⚠️ 되돌릴 수 없는 동작이 섞여 있다(응모 철회는 편도다). **시험 계정으로만**
--    하고, 매 단계 뒤 applications·withdrawal_requests 를 확인할 것.
-- ============================================================
/*

-- [V0] (SQL 편집기) 353 이 먼저 적용됐는지 — 이게 없으면 이 파일이 실패한다
SELECT public.is_withdrawal_open();   -- 기대: false

-- ── 이하 로그인한 브라우저 콘솔 ────────────────────────────

-- [V1] ★ 걸린 것이 있는 계정 — 게이트가 막고 **아무것도 안 바꾸는지**
--   (haruka.test@reverb.jp = 정산 행 0건 · 미지급 2건 → unpaid_count 로 걸린다)
--   await db.rpc('request_withdrawal', {})
--   기대: { ok:false, reason:'locked_needs_support', blockers:{ unpaid_count:2, 나머지 0 } }
--
--   ★★ 그리고 **응모가 하나도 안 바뀌었는지**를 반드시 확인한다:
--   await db.from('applications').select('id,status').eq('user_id', <본인 uuid>)
--   기대: 호출 전과 완전히 같다 (게이트가 반복문 앞이라는 것의 증거)
--   await db.from('withdrawal_requests').select('*')
--   기대: 0행 (신청도 안 만들어졌다)

-- [V2] 승인된 결과물이 있는 응모를 가진 계정
--   기대: blockers.approved_deliverable_apps > 0, 응모·신청 무변경

-- [V3] 행사(오프라인 팝업) 응모를 가진 계정
--   기대: blockers.event_apps > 0, 응모·신청 무변경

-- [V4] 정산 기록이 있는 계정
--   기대: blockers.settlement_rows > 0, 응모·신청 무변경

-- [V5] ★ 깨끗한 계정 — 잠금 기간에도 **그냥 탈퇴돼야 한다**(사양서 §5 ⑧)
--   await db.rpc('request_withdrawal', {})
--   기대: { ok:true, status:'scheduled', scheduled_date: 오늘+5일, unpaid_count:0 }
--   ⚠️ 이 계정은 이 시점에 탈퇴 신청이 실제로 생긴다 — 뒤에 cancel_withdrawal 로
--     되돌리거나 시험 데이터를 지울 것

-- [V6] 시행 후 — 시행일을 어제로 넣고([V1] 계정에서) 다시
--   (SQL 편집기) UPDATE public.withdrawal_settings
--                   SET effective_date = (now() AT TIME ZONE 'Asia/Tokyo')::date - 1
--                 WHERE id = 1;
--   await db.rpc('request_withdrawal', {})
--   기대: **성공**한다 — 걸린 것이 있어도 시행 후에는 그대로 진행되고
--         uncancelled_count 에 건수가 기록된다(게이트에 들어가지 않으므로)
--   ⚠️ 확인 뒤 반드시 effective_date = NULL 로 되돌릴 것

-- [V7] ★ 백스톱 — 판정이 낡았을 때를 흉내 낸다
--   ⚠️ **두 자리에서 나눠 한다** — 재정의는 SQL 편집기, 호출은 브라우저 콘솔.
--     한 자리에서 통째로 돌리면 not_authenticated 로 끝나 「백스톱이 안 돈다」로
--     오해한다.
--   (1) SQL 편집기 — _withdrawal_lock_blockers 의 ② 행사 항목이 일부러 0 을
--       돌려주도록 임시 재정의
--   (2) **브라우저 콘솔** — **행사 응모가 있는 계정**([V3])으로 로그인해
--       await db.rpc('request_withdrawal', {})
--   기대: { ok:false, reason:'locked_needs_support', backstop:true,
--           blockers:{ uncancellable_apps: 1 } }
--   그리고 **응모가 하나도 안 바뀌었는지**(반복문이 되돌아갔는지) 확인:
--   await db.from('applications').select('id,status').eq('user_id', <uuid>)
--   기대: 호출 전과 같다
--   ⚠️ 확인 뒤 353 의 헬퍼 정의를 그대로 다시 실행해 원상 복구할 것

-- [V8] 탈퇴 취소는 잠금과 무관한지 — [V5] 계정에서
--   await db.rpc('cancel_withdrawal', {})
--   기대: { ok:true, status:'cancelled' } (잠금 기간에도 성공해야 한다)

-- [V9] 시험 데이터 정리
--   (SQL 편집기) DELETE FROM public.withdrawal_requests WHERE influencer_id IN (...);
--   ⚠️ [V5]·[V6] 에서 실제로 취소된 응모는 **되살아나지 않는다**(의도) —
--     시험 계정에 남는 영향을 감안하고 진행할 것

*/
