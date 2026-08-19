-- ============================================================
-- 357_withdrawal_proxy_request.sql
--
-- 회원 탈퇴 — 작업 19 「관리자 대행 탈퇴 신청」 3/3 (본체)
--   355 = 권한 시드 · 356 = 토대 (**둘 다 먼저 적용**)
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 19」
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md §5 ⑤ · §5 ⑧
--
-- ============================================================
-- ① 무엇을 여나
-- ============================================================
--   [A] 관리자 되돌리기용 칸 3개 신설
--   [B] request_withdrawal 재정의(**베이스 354**) — 철회를 356 헬퍼로 위임 +
--       관리자 겸직 회원 거부
--   [C] request_withdrawal_for_member() 신설 — 관리자가 회원 대신 신청
--   [D] cancel_withdrawal_admin() 신설 — 관리자가 잘못 누른 것을 되돌린다
--
-- ============================================================
-- ② 왜 필요한가 — 잠금이 만든 막다른 길
-- ============================================================
--   시행 전 잠금(353·354)이 「걸린 회원은 문의 창구로」 보내는데, **운영팀이 그
--   회원을 처리할 수단이 시스템에 하나도 없었다.** `requested_by_kind` 에 관리자
--   값이 정의만 돼 있고 그 값을 쓰는 함수가 0개였다.
--   → 회원이 문의해도 탈퇴 의사가 아무 데도 안 남는다. **이 사양서가 고치려던
--     문제(§4-5-1 「누가 눌렀는지 아무 데도 안 남는다」)가 그 구간에 그대로 남는다.**
--
-- ============================================================
-- ③ ★ 이번에 여는 것은 「대행」뿐 (2026-08-19 결정)
-- ============================================================
--   값은 셋 다 만들지만(356), **화면은 대행만 보낸다.** 자격 상실 강제 탈퇴는
--   되돌릴 수단이 없는 처리라 약관 개정 전에 열지 않는다.
--   이 파일의 [C] 는 두 값을 다 받는다 — 나중에 강제를 열 때 함수를 다시 고치지
--   않기 위해서다. **여는 것은 화면이 정한다.**
--
-- ============================================================
-- ④ 잠금 게이트를 건너뛴다 — 의도적
-- ============================================================
--   잠금(353·354)의 목적은 「걸린 회원을 사람에게 넘긴다」이고, [C] 가 **그 사람이
--   쓰는 도구**다. 여기에 같은 게이트를 걸면 넘겨받은 운영팀의 처리 수단이 다시
--   0이 되어 **순환**한다. 백스톱도 걸지 않는다(이미 사람이 누른 것이다).
--
--   ⚠️ 대신 대가가 있다 — 353 헤더 ③ 이 적은 두 구멍(대기 중 조건이 사후에
--     깨진다 · 대기가 길면 현행 방침의 「5일 뒤 파기」를 어긴다)이 **대행 경로로는
--     되살아난다.** 그래서 화면의 확인 창이 **받지 못한 보수 건수를 미리 보여주고**
--     시행일 전이면 경고를 띄운다(화면 몫).
--
-- ============================================================
-- ⑤ 되돌리기
-- ============================================================
--   [B] 는 354 파일의 함수 블록을 그대로 다시 실행하면 되돌아간다.
--   [C]·[D] 는 DROP FUNCTION. [A] 는 칸을 지우면 되지만 **기록이 사라지므로**
--   남겨 두는 편이 낫다(칸이 있어도 아무 동작도 안 한다).
-- ============================================================

BEGIN;

-- ============================================================
-- [A] 관리자 되돌리기 기록 칸 3개
--
--   ⚠️ 기존 `processed_by` 를 재사용하지 않는다 — 그 칸은 [C] 가 「누가 대신
--     신청했나」로 쓴다. 취소하면서 덮으면 **신청한 사람이 사라진다.**
--   ⚠️ 본인 취소(cancel_withdrawal)는 이 칸들을 건드리지 않는다 — 본인이 누른
--     것은 `requested_by_kind`·`status` 만으로 설명된다.
-- ============================================================
ALTER TABLE public.withdrawal_requests
  ADD COLUMN IF NOT EXISTS admin_cancelled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS admin_cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_cancel_note  text;

COMMENT ON COLUMN public.withdrawal_requests.admin_cancelled_by IS
  '[357] 관리자가 이 신청을 되돌렸다면 그 관리자. 본인 취소(cancel_withdrawal)는 '
  '이 칸을 안 채운다. ⚠️ processed_by(누가 대신 신청했나)와 다른 칸이다 — 하나로 '
  '합치면 되돌린 순간 신청한 사람이 사라진다.';
COMMENT ON COLUMN public.withdrawal_requests.admin_cancel_note IS
  '[357] 관리자가 되돌린 근거. 되돌릴 수 없는 처리를 되돌리는 자리라 이유가 남아야 '
  '한다 — cancel_withdrawal_admin() 이 필수로 받는다.';

-- ============================================================
-- [B] request_withdrawal 재정의 — **베이스 354**
--   354 원본을 스크립트로 추출해 세 곳만 바꿨다:
--     ① 안 쓰게 된 변수 2개 제거  ② 관리자 겸직 가드 추가
--     ③ 철회 반복문 → 356 공용 헬퍼 호출
--   게이트·백스톱을 포함한 나머지는 354 와 글자 단위로 같다(스크립트로 대조).
-- ============================================================
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
  v_cancelled_count      integer := 0;
  v_uncancelled_count    integer := 0;
  v_unpaid_count         integer;
  v_status               text;
  v_scheduled_date       date;
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
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

  -- [357] 관리자를 겸한 회원 — 확정 단계의 파기 함수(352)가 거부하므로, 신청을
  --   받아 두면 **매일 재시도되며 영영 확정되지 않는다.** 신청 시점에 막는다.
  --   ⚠️ 이건 이 파일이 새로 만든 위험이 아니라 **원래 있던 구멍**이다 —
  --     352 가 거부만 하고 아무도 안 막고 있었다.
  IF public._influencer_is_admin_account(v_influencer_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_account_excluded');
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
    -- [357] 철회는 356 의 공용 헬퍼에 맡긴다 — 관리자 대행 신청
    --   (request_withdrawal_for_member)이 **같은 함수**를 부른다. 반복문을 두 벌로
    --   두면 이 저장소가 반복해 겪은 「같은 판단이 여러 곳」 사고가 된다.
    --   반복문 내용은 354 의 것과 논리가 같다(356 로 옮기며 변수 이름 셋만 바뀌었다).
    SELECT c.cancelled_count, c.uncancelled_count
      INTO v_cancelled_count, v_uncancelled_count
      FROM public._withdrawal_cancel_applications(v_influencer_id) c;

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
  '[357, 354 재정의] 회원 본인 탈퇴 신청. 354 와 같고 셋만 다르다 — ①응모 철회를 '
  '356 의 공용 헬퍼(_withdrawal_cancel_applications)에 위임해 관리자 대행 신청과 '
  '**같은 코드**를 쓴다 ②관리자를 겸한 회원을 신청 시점에 거부한다(안 막으면 확정 '
  '단계의 파기가 거부해 영영 대기에 갇힌다) ③그에 따라 안 쓰는 변수 둘을 뺐다. '
  '시행 전 잠금 게이트와 백스톱은 354 그대로다.';

REVOKE ALL ON FUNCTION public.request_withdrawal(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text) TO authenticated;

-- ============================================================
-- [C] request_withdrawal_for_member() — 관리자가 회원 대신 신청
--
--   반환 계약은 본인 함수와 같은 형태 + 주체 1칸. 실패는 예외가 아니라
--   {ok:false, reason} — 349·354 와 같은 계약이라 화면이 정상 분기로 받는다.
--
--   ⚠️ **p_kind 에 기본값을 두지 않는다.** 기본값이 있으면 화면 실수 하나로
--     「대행」이 「강제」가 되거나 반대가 된다 — 결과가 정반대다(본인이 취소할
--     수 있는가).
--   ⚠️ **근거 메모는 둘 다 필수**(2026-08-19 결정) — 회원 요청은 시스템 밖
--     (라인·메일)에서 오므로 자유 텍스트가 유일한 증거다.
--   ⚠️ 이미 활성 신청이 있으면 **거부**한다(본인 함수는 멱등 반환). 멱등이면
--     관리자가 주체를 바꾸려고 눌렀을 때 **안 바뀐 채 성공 표시**가 떠서
--     「대행으로 바꿨다」고 착각한다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_withdrawal_for_member(
  p_influencer_id uuid,
  p_kind          text,
  p_reason_code   text DEFAULT NULL,
  p_reason_note   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_actor            uuid := auth.uid();
  v_inf              public.influencers%ROWTYPE;
  v_existing_id      uuid;
  v_reason_valid     boolean;
  v_cancelled_count  integer := 0;
  v_uncancelled_count integer := 0;
  v_unpaid_count     integer;
  v_status           text;
  v_scheduled_date   date;
  v_today_jst        date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
BEGIN
  -- 1. 로그인 확인
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 2. 권한 — 화면 숨김은 표시 제어일 뿐이라 서버가 최종 판정한다(355 시드).
  IF NOT public.has_permission('withdrawal.proxy_request', 'write') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  -- 3. 주체 값 검증 — 화이트리스트
  IF p_kind IS NULL OR p_kind NOT IN ('admin_proxy', 'admin_forced') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_kind');
  END IF;

  -- 4. 근거 메모 필수
  IF p_reason_note IS NULL OR length(trim(p_reason_note)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_note_required');
  END IF;

  -- 5. 대상 회원 행 잠금
  --    ⚠️ 잠금 순서를 347·349·354 와 맞춘다(influencers 먼저) — 어기면 회원이
  --      같은 순간 본인 신청을 눌렀을 때 교착 위험.
  SELECT * INTO v_inf FROM public.influencers WHERE id = p_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 6. 관리자를 겸한 회원 — 확정 단계의 파기(352)가 거부하므로 여기서 막는다.
  --    안 막으면 매일 재시도되며 영영 확정되지 않는다.
  IF public._influencer_is_admin_account(p_influencer_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_account_excluded');
  END IF;

  -- 7. 이미 활성 신청이 있으면 거부(위 헤더 참조 — 멱등으로 두지 않는다)
  SELECT id INTO v_existing_id
    FROM public.withdrawal_requests
   WHERE influencer_id = p_influencer_id
     AND status IN ('pending_payout', 'scheduled')
   LIMIT 1;

  -- ⚠️ FOUND 대신 값으로 판정한다 — 바로 위에서 함수를 부르는 IF 문이 있어
  --   FOUND 가 무엇을 가리키는지가 읽는 사람에게 불분명해진다. 값 검사는
  --   어떤 경우에도 뜻이 하나다.
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_requested');
  END IF;

  -- 8. 사유 코드 검증(선택) — 354 와 같은 규칙
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

  -- 9. 응모 철회 — 본인 신청과 **같은 헬퍼**(356). 반복문을 두 벌로 만들지 않는다.
  --    ⚠️ 그 헬퍼가 통과 표시를 세우기 때문에, 관리자가 불러도 회원 응모가
  --      취소된다(356 헤더 ③).
  --    ⚠️ 감싸는 이유 — 본인 신청([B])은 백스톱 때문에 이미 블록 안이지만 여기는
  --      게이트를 건너뛰어 맨몸이다. 헬퍼가 예상 밖 예외를 던지면(반복문 진입 전
  --      실패 등) 관리자 화면에 **데이터베이스 원문 오류가 그대로** 뜬다. 이 함수의
  --      계약은 「실패도 {ok:false, reason} 으로 돌려준다」이므로 형태를 맞춘다.
  BEGIN
    SELECT c.cancelled_count, c.uncancelled_count
      INTO v_cancelled_count, v_uncancelled_count
      FROM public._withdrawal_cancel_applications(p_influencer_id) c;
  EXCEPTION WHEN OTHERS THEN
    -- 이 블록 안에서 한 취소는 저장점 롤백으로 전부 되돌아간다 — 「응모만 지워지고
    -- 신청은 안 된」 반쪽 상태가 남지 않는다.
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'cancel_applications_failed',
      'detail', SQLERRM
    );
  END;

  -- 10. 미지급 판정 — 350 의 공용 함수 그대로
  v_unpaid_count := public._withdrawal_unpaid_count(p_influencer_id);

  IF v_unpaid_count = 0 THEN
    v_status         := 'scheduled';
    v_scheduled_date := v_today_jst + 5;
  ELSE
    v_status         := 'pending_payout';
    v_scheduled_date := NULL;
  END IF;

  INSERT INTO public.withdrawal_requests (
    influencer_id, status, reason_code, reason_note,
    scheduled_date, requested_by_kind, uncancelled_count, processed_by
  ) VALUES (
    p_influencer_id, v_status, NULLIF(trim(p_reason_code), ''), trim(p_reason_note),
    v_scheduled_date, p_kind, v_uncancelled_count, v_actor
  );

  RETURN jsonb_build_object(
    'ok',                true,
    'status',            v_status,
    'scheduled_date',    v_scheduled_date,
    'cancelled_count',   v_cancelled_count,
    'uncancelled_count', v_uncancelled_count,
    'unpaid_count',      v_unpaid_count,
    'requested_by_kind', p_kind
  );
END;
$fn$;

COMMENT ON FUNCTION public.request_withdrawal_for_member(uuid, text, text, text) IS
  '[357] 관리자가 회원 대신 탈퇴를 신청한다. 본인 신청(request_withdrawal)과 같은 '
  '일을 하되 ①시행 전 잠금 게이트를 건너뛰고(이 함수가 잠금이 넘긴 사람을 처리하는 '
  '도구다) ②주체를 admin_proxy(대행) 또는 admin_forced(강제)로 남기고 ③누가 눌렀는지 '
  'processed_by 에 적는다. 응모 철회는 본인 신청과 **같은 헬퍼**를 쓴다. '
  '권한은 withdrawal.proxy_request(355) — 화면 숨김이 아니라 서버가 막는다. '
  '⚠️ 근거 메모 필수 · 이미 활성 신청이 있으면 거부(멱등 아님) · 관리자를 겸한 '
  '회원은 거부 · p_kind 에 기본값 없음(대행과 강제는 결과가 정반대다).';

REVOKE ALL ON FUNCTION public.request_withdrawal_for_member(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal_for_member(uuid, text, text, text) TO authenticated;

-- ============================================================
-- [D] cancel_withdrawal_admin() — 관리자가 잘못 누른 것을 되돌린다
--
--   ⚠️ **관리자가 만든 신청만** 되돌린다(admin_proxy·admin_forced). 회원이 스스로
--     낸 신청은 대상이 아니다 — 그건 본인이 cancel_withdrawal 로 취소한다.
--     관리자가 회원의 탈퇴 의사를 취소하는 것은 월권이고, 탈퇴를 막는 방향이라
--     회원에게 불리하다.
--   ⚠️ **철회된 응모는 되살아나지 않는다** — 349 와 같다. cancel_application 자체가
--     편도이고, 되살리면 마감·정원 경과와 충돌할 수 있다.
--   ⚠️ 근거 메모 필수 — 되돌릴 수 없는 처리를 되돌리는 자리다.
--   ⚠️ **감사용 계정을 막지 않는다** — 다른 함수들은 방어적으로 거부하지만, 이쪽은
--     「잘못 만들어진 신청을 지우는」 방향이라 오히려 되돌릴 수 있어야 한다.
--   ⚠️ 대상 회원이 없어도 따로 확인하지 않는다 — 그러면 뒤이은 신청 조회가
--     반드시 0행이라 결국 같은 not_found 로 귀결된다(신청 표의 연결이 CASCADE 라
--     「회원은 없는데 신청만 남은」 상태가 구조적으로 불가능하다).
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_withdrawal_admin(
  p_influencer_id uuid,
  p_note          text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_actor uuid := auth.uid();
  v_req   public.withdrawal_requests%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF NOT public.has_permission('withdrawal.proxy_request', 'write') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  IF p_note IS NULL OR length(trim(p_note)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'note_required');
  END IF;

  -- 잠금 순서는 다른 함수들과 같다 — influencers 먼저.
  PERFORM 1 FROM public.influencers WHERE id = p_influencer_id FOR UPDATE;

  SELECT * INTO v_req
    FROM public.withdrawal_requests
   WHERE influencer_id = p_influencer_id
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 회원이 스스로 낸 신청은 관리자가 못 되돌린다(위 헤더 참조)
  IF v_req.requested_by_kind = 'self' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'self_requested');
  END IF;

  UPDATE public.withdrawal_requests
     SET status             = 'cancelled',
         admin_cancelled_by = v_actor,
         admin_cancelled_at = now(),
         admin_cancel_note  = trim(p_note),
         updated_at         = now()
   WHERE id = v_req.id;

  RETURN jsonb_build_object(
    'ok',                true,
    'status',            'cancelled',
    'previous_status',   v_req.status,
    'requested_by_kind', v_req.requested_by_kind
  );
END;
$fn$;

COMMENT ON FUNCTION public.cancel_withdrawal_admin(uuid, text) IS
  '[357] 관리자가 대신 넣은 탈퇴 신청을 되돌린다(오조작 복구). 대상은 '
  'admin_proxy·admin_forced 뿐 — 회원이 스스로 낸 신청은 self_requested 로 '
  '거부한다(그건 본인이 취소한다). 근거 메모 필수이고 admin_cancelled_* 3칸에 '
  '남는다. ⚠️ 철회된 응모는 되살아나지 않는다(349 와 같은 판단). '
  '⚠️ 이 함수가 없으면 강제 탈퇴 오조작을 아무도 되돌릴 수 없어 5일 뒤 개인정보 '
  '파기로 이어진다.';

REVOKE ALL ON FUNCTION public.cancel_withdrawal_admin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_withdrawal_admin(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
--
-- 🔴 **356 의 [V2](회원 본인 응모 취소가 여전히 되는가)가 통과한 뒤에** 이 파일을
--    적용한다. 그게 이 묶음에서 가장 위험한 지점이다.
-- ⚠️ SQL 편집기로는 한 단계도 검증할 수 없다 — 로그인 사용자가 없어 권한 판정과
--    auth.uid() 분기가 아예 안 돈다.
-- ⚠️ 되돌릴 수 없는 동작이 섞여 있다(응모 철회는 편도). **시험 계정으로만.**
-- ============================================================
/*

-- ── 관리자 브라우저 콘솔 ────────────────────────────────────

-- [V1] 권한 없는 등급(캠페인 매니저)으로 로그인해 직접 호출
--   await db.rpc('request_withdrawal_for_member',
--     {p_influencer_id:'<시험 회원 uuid>', p_kind:'admin_proxy', p_reason_note:'시험'})
--   기대: { ok:false, reason:'forbidden' }   ← 화면을 안 거쳐도 서버가 막는다

-- [V2] 주체 값·메모 검증
--   p_kind:'self'        → invalid_kind
--   p_kind 생략          → invalid_kind
--   p_reason_note 생략   → reason_note_required

-- [V3] ★ 대행 접수 — 살아있는 응모가 있는 시험 계정으로
--   await db.rpc('request_withdrawal_for_member',
--     {p_influencer_id:'<uuid>', p_kind:'admin_proxy',
--      p_reason_code:null, p_reason_note:'라인으로 요청받음(시험)'})
--   기대: { ok:true, status:'scheduled'|'pending_payout',
--           cancelled_count:>0, requested_by_kind:'admin_proxy' }
--   ★★ 그리고 **응모가 실제로 취소됐는지** 확인:
--   await db.from('applications').select('id,status').eq('user_id','<uuid>')
--   기대: 심사중·승인이던 것이 cancelled 로 바뀌어 있다
--   🔴 여기서 cancelled_count 가 0이고 uncancelled_count 만 늘었다면 356 의 통과
--      표시가 안 먹은 것이다 — 그대로 두면 「접수는 됐는데 응모는 그대로」다

-- [V4] 같은 회원에 또 호출 → already_requested

-- [V5] 관리자를 겸한 회원으로 → admin_account_excluded
-- [V6] 감사용 계정으로       → audit_account_blocked

-- ── 대상 회원 브라우저 콘솔 ─────────────────────────────────

-- [V7] ★ 대행으로 접수된 것을 **본인이 취소할 수 있는가**(이번 설계의 핵심)
--   await db.rpc('cancel_withdrawal', {})
--   기대: { ok:true, status:'cancelled' }
--   🔴 admin_requested 로 거부되면 356 의 [E] 치환이 안 된 것이다

-- [V8] (선택) 강제로 넣어 본 뒤 본인이 취소 시도
--   관리자 콘솔에서 p_kind:'admin_forced' 로 접수 → 회원이 cancel_withdrawal
--   기대: { ok:false, reason:'admin_requested' }   ← 강제는 본인이 못 되돌린다

-- ── 관리자 브라우저 콘솔 (되돌리기) ─────────────────────────

-- [V9] 관리자 되돌리기
--   await db.rpc('cancel_withdrawal_admin',
--     {p_influencer_id:'<uuid>', p_note:'잘못 눌렀음(시험)'})
--   기대: { ok:true, status:'cancelled', requested_by_kind:'admin_proxy' }
--   그리고 admin_cancelled_by·admin_cancelled_at·admin_cancel_note 가 찼는지 확인

-- [V10] 회원이 스스로 낸 신청을 관리자가 되돌리려 하면
--   기대: { ok:false, reason:'self_requested' }

-- [V11] 메모 없이 되돌리려 하면 → note_required

-- [V12] 시험 데이터 정리
--   DELETE FROM public.withdrawal_requests WHERE influencer_id IN (...);
--   ⚠️ [V3] 에서 실제로 취소된 응모는 **되살아나지 않는다**(의도) — 시험 계정에
--     남는 영향을 감안하고 진행할 것

*/
