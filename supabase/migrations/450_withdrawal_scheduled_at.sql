-- ============================================================
-- 450_withdrawal_scheduled_at.sql
--   사양서 `docs/specs/2026-09-18-withdrawal-mail-alert-false-positive.md` §3-1·§3-2·§3-5①
--   「예정 상태가 된 시각」을 기록할 칸을 만들고, 그 칸을 쓰는 **세 경로를 같은 파일에서** 채운다.
--
--   왜 필요한가
--     「탈퇴 처리 점검」의 ①「예정일 안내 메일이 아직 안 나감」이 **정상 흐름에서도 떴다**
--     (2026-09-18 운영 실측 3건 — 메일도 예약도 정상이었고 그날 09:00 발송으로 저절로 사라졌다).
--     419 는 첫 판정 시점을 「예정 상태가 된 **날**의 09:30」으로 쟀는데, 그 날짜만으로는
--     **09:00 이후에 예정이 된 행**(그날 배치가 이미 지나가 다음 날 09:00 이 첫 기회)을 가릴 수 없다.
--     🔴 날짜에서 역산하는 방법도 있으나 **사양서가 명시적으로 배제**했다(§2-⑦) — 「예정 상태가 된
--        시각」은 신청 시각이 아니고, 미지급 대기를 거친 건은 둘이 몇 달 차이 난다.
--
--   🔴 세 자리를 한 파일에서 함께 고치는 이유 (§2-①)
--     예정으로 가는 길이 셋(회원 신청 즉시 · 관리자 대행 즉시 · 04:45 배치)인데 하나라도 빠뜨리면
--     그 경로의 행만 `scheduled_at` 이 NULL 이라 옛 식으로 떨어진다 — **고쳤다고 믿는데 한 경로에서만
--     오탐이 남는** 상태가 되어 더 나쁘다.
--
--   ⚠️ 기존 행은 백필하지 않는다 (§2-②) — 정확한 시각이 어디에도 없고, 틀린 값을 맞는 척 채우는 것은
--      이 저장소가 `cert_at` 에서 겪은 실수다. NULL 인 행은 **다음 파일(451)이 옛 식으로 떨어뜨린다.**
--      지금 예정 6건은 전부 발송 완료라 애초에 판정 대상이 아니다.
--   ⚠️ 트리거·제약으로 강제하지 않는다 (§3-1) — 쓰는 자리가 이 셋뿐이고, 강제하면 검증의 손수정이 막힌다.
--
--   🔴 **이 파일이 먼저, 판정 교체(451)가 나중**이다 (§3-5) — 순서를 바꾸면 없는 칸을 참조해 실패한다.
--
--   베이스(각 함수의 **현재 원본** — 정의 파일을 전수로 세어 확인했다):
--     request_withdrawal            357   /  request_withdrawal_for_member  357
--     advance_withdrawal_states     352
--   본문은 그 원본에서 **그대로 가져와** 위 한 자리씩만 더했다. 다른 조항은 한 글자도 안 건드렸다.
--   ⚠️ 확인법:  grep -lE "CREATE (OR REPLACE )?FUNCTION public\.<이름>\s*\(" supabase/migrations/*.sql
--      — 이름이 나오는 파일 중 **정의가 아닌 것**(권한·주석만 손댄 파일)이 섞이므로 반드시 가려서 셀 것.
-- ============================================================

BEGIN;

-- ── 칸 (§3-1) ────────────────────────────────────────────────
ALTER TABLE public.withdrawal_requests
  ADD COLUMN IF NOT EXISTS scheduled_at timestamptz;

COMMENT ON COLUMN public.withdrawal_requests.scheduled_at IS
'[450] 이 신청이 예정(scheduled) 상태가 된 시각. 신청 시각(created_at)이 아니다 — 미지급 대기를 '
'거친 건은 둘이 몇 달 차이 난다. 「예정일 안내 메일이 아직 안 나감」 경고가 **첫 발송 기회**(그 뒤 '
'처음 오는 일본 시각 09:00)를 계산하는 데 쓴다. 450 이전 행은 NULL 이고 그 경우 판정은 옛 식으로 '
'떨어진다(451). 쓰는 자리는 request_withdrawal · request_withdrawal_for_member · advance_withdrawal_states 셋뿐.';

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
    scheduled_date, requested_by_kind, uncancelled_count,
    scheduled_at                                   -- 450 추가
  ) VALUES (
    v_influencer_id, v_status, NULLIF(trim(p_reason_code), ''), NULLIF(trim(p_reason_note), ''),
    v_scheduled_date, 'self', v_uncancelled_count,
    -- 450: 예정으로 **바로** 들어갈 때만 그 시각을 남긴다. 미지급이 남아 `pending_payout`
    --   으로 들어가는 행은 NULL 이고, 나중에 배치(352)가 예정으로 올릴 때 거기서 찍는다.
    CASE WHEN v_status = 'scheduled' THEN now() END
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
    scheduled_date, requested_by_kind, uncancelled_count, processed_by,
    scheduled_at                                   -- 450 추가
  ) VALUES (
    p_influencer_id, v_status, NULLIF(trim(p_reason_code), ''), trim(p_reason_note),
    v_scheduled_date, p_kind, v_uncancelled_count, v_actor,
    CASE WHEN v_status = 'scheduled' THEN now() END   -- 450: 위 함수와 같은 규칙
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

CREATE OR REPLACE FUNCTION public.advance_withdrawal_states()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today_jst            date := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  v_advanced_scheduled   integer := 0;
  v_advanced_done        integer := 0;
  v_event_cancelled      integer := 0;
  v_event_blocked        integer := 0;

  v_ticket_id            uuid;
  v_ticket_influencer_id uuid;
  v_ticket_result        jsonb;

  v_cand_id              uuid;
  v_cand_influencer_id   uuid;
  v_req                  public.withdrawal_requests%ROWTYPE;
  v_unpaid               integer;
  v_scheduled_date       date;
  v_purge_result         jsonb;   -- [352 신규] purge_withdrawn_personal_data() 반환값
BEGIN
  -- ============================================================
  -- 0. 오프라인 행사 예약 정리 — 350 과 완전히 동일(무변경)
  -- ============================================================
  FOR v_ticket_id, v_ticket_influencer_id IN
    SELECT t.id, t.influencer_id
      FROM public.event_tickets t
      JOIN public.withdrawal_requests wr
        ON wr.influencer_id = t.influencer_id
       AND wr.status IN ('pending_payout', 'scheduled')
     WHERE t.status IN ('confirmed', 'waitlist')
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_ticket_influencer_id FOR UPDATE;

      IF NOT EXISTS (
        SELECT 1 FROM public.withdrawal_requests
         WHERE influencer_id = v_ticket_influencer_id
           AND status IN ('pending_payout', 'scheduled')
      ) THEN
        CONTINUE;
      END IF;

      v_ticket_result := public._withdrawal_cancel_event_ticket(v_ticket_id);

      IF COALESCE((v_ticket_result->>'ok')::boolean, false) THEN
        IF NOT COALESCE((v_ticket_result->>'already_cancelled')::boolean, false) THEN
          v_event_cancelled := v_event_cancelled + 1;

          UPDATE public.withdrawal_requests
             SET event_tickets_cancelled_count = event_tickets_cancelled_count + 1
           WHERE influencer_id = v_ticket_influencer_id
             AND status IN ('pending_payout', 'scheduled');
        END IF;
      ELSE
        v_event_blocked := v_event_blocked + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_event_blocked := v_event_blocked + 1;
      RAISE WARNING '[advance_withdrawal_states] event ticket % cancel failed: %', v_ticket_id, SQLERRM;
    END;
  END LOOP;

  UPDATE public.withdrawal_requests wr
     SET event_tickets_blocked_count = sub.cnt
    FROM (
      SELECT wr2.id AS wr_id, count(t.id) AS cnt
        FROM public.withdrawal_requests wr2
        LEFT JOIN public.event_tickets t
          ON t.influencer_id = wr2.influencer_id
         AND t.status IN ('confirmed', 'waitlist')
       WHERE wr2.status IN ('pending_payout', 'scheduled')
       GROUP BY wr2.id
    ) sub
   WHERE wr.id = sub.wr_id;

  -- ============================================================
  -- 1. pending_payout → scheduled — 350 과 완전히 동일(무변경)
  -- ============================================================
  FOR v_cand_id, v_cand_influencer_id IN
    SELECT wr.id, wr.influencer_id
      FROM public.withdrawal_requests wr
     WHERE wr.status = 'pending_payout'
     ORDER BY wr.requested_at
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_cand_influencer_id FOR UPDATE;

      SELECT * INTO v_req FROM public.withdrawal_requests WHERE id = v_cand_id FOR UPDATE;

      IF NOT FOUND OR v_req.status <> 'pending_payout' THEN
        CONTINUE;
      END IF;

      v_unpaid := public._withdrawal_unpaid_count(v_cand_influencer_id);

      IF v_unpaid = 0 THEN
        v_scheduled_date := v_today_jst + 5;

        UPDATE public.withdrawal_requests
           SET status = 'scheduled', scheduled_date = v_scheduled_date,
               scheduled_at = now()          -- 450 추가: 예정이 된 바로 그 순간
         WHERE id = v_req.id;

        v_advanced_scheduled := v_advanced_scheduled + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[advance_withdrawal_states] pending_payout row % failed: %', v_cand_id, SQLERRM;
    END;
  END LOOP;

  -- ============================================================
  -- 2. scheduled → done — [352] 여기만 바뀐다. 예정일이 지난 신청을
  --    확정하는 동시에, 같은 서브트랜잭션(BEGIN...EXCEPTION 블록) 안에서
  --    개인정보를 파기한다. 파기가 실패하면 이 블록 전체가(방금 한
  --    status='done' UPDATE 까지) 롤백돼 다음 실행에서 다시 시도된다
  --    (파일 헤더 「①」의 저울질 결론).
  -- ============================================================
  FOR v_cand_id, v_cand_influencer_id IN
    SELECT wr.id, wr.influencer_id
      FROM public.withdrawal_requests wr
     WHERE wr.status = 'scheduled'
       AND wr.scheduled_date IS NOT NULL
       AND wr.scheduled_date <= v_today_jst
     ORDER BY wr.scheduled_date
  LOOP
    BEGIN
      PERFORM 1 FROM public.influencers WHERE id = v_cand_influencer_id FOR UPDATE;

      SELECT * INTO v_req FROM public.withdrawal_requests WHERE id = v_cand_id FOR UPDATE;

      IF NOT FOUND OR v_req.status <> 'scheduled' THEN
        CONTINUE;
      END IF;

      UPDATE public.withdrawal_requests
         SET status = 'done', completed_at = now()
       WHERE id = v_req.id;

      -- [352 신규] 확정 즉시 파기(§4-7). 실패하면 예외를 직접 던져 위
      -- UPDATE 까지 포함해 이 블록 전체를 롤백시킨다 — purge 함수
      -- 자신은 "not_found"/"audit_account_blocked"/"admin_account_excluded"
      -- 를 조용한 {ok:false} 로 돌려주므로(내부 예외를 안 던지므로),
      -- 여기서 명시적으로 확인해 예외로 승격시켜야 롤백이 걸린다.
      v_purge_result := public.purge_withdrawn_personal_data(v_cand_influencer_id);

      IF NOT COALESCE((v_purge_result->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'purge_failed: %', COALESCE(v_purge_result->>'reason', 'unknown');
      END IF;

      UPDATE public.withdrawal_requests
         SET personal_data_purged_at = now()
       WHERE id = v_req.id;

      v_advanced_done := v_advanced_done + 1;
    EXCEPTION WHEN OTHERS THEN
      -- ⚠️ 이 WARNING 은 두 가지 원인을 구분하지 않는다 — "정말 예상 못한
      -- 오류"와 "purge_failed: admin_account_excluded 처럼 사람이 봐야
      -- 하는 예외"가 같은 로그 문구로 남는다. 메시지(SQLERRM)에
      -- purge_failed 사유가 그대로 실리므로 Supabase Logs 에서 텍스트로
      -- 구분 가능 — 별도 카운터를 새로 만들지 않는다(반환 계약을
      -- 이번 작업 범위에서 넓히지 않기 위해).
      RAISE WARNING '[advance_withdrawal_states] scheduled row % failed: %', v_cand_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                          true,
    'advanced_to_scheduled',       v_advanced_scheduled,
    'advanced_to_done',            v_advanced_done,
    'event_tickets_cancelled',     v_event_cancelled,
    'event_tickets_cancel_failed', v_event_blocked
  );
END;
$$;

-- ── 권한 — 원본과 같다(CREATE OR REPLACE 라 보존되지만 명시) ──
REVOKE ALL ON FUNCTION public.request_withdrawal(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.request_withdrawal_for_member(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_withdrawal_for_member(uuid, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.advance_withdrawal_states() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.advance_withdrawal_states() TO postgres;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인 (사양서 §4)
-- ============================================================
-- [V1] 칸이 생겼고 기존 행은 전부 NULL 인가 — 백필하지 않는 것이 맞다.
--   SELECT count(*) AS 전체,
--          count(scheduled_at) AS "시각_있음",
--          count(*) FILTER (WHERE status = 'scheduled') AS "예정_상태"
--     FROM public.withdrawal_requests;
--   기대: 시각_있음 = 0 (이 파일은 과거 행을 안 건드린다)
--
-- [V2] 🔴 세 경로가 각각 실제로 값을 넣는가 — **개발서버에서 시험 계정으로** 확인한다.
--   ⚠️ 운영에서 시험 신청을 만들지 말 것. 아래는 개발서버 절차다.
--   (a) 회원 본인 신청(미지급 0) — 시험 계정 브라우저에서 탈퇴 신청 → 그 행의 status='scheduled' 이고
--       scheduled_at 이 **방금 시각**인가. 그리고 scheduled_date = 오늘(일본)+5 인가.
--   (b) 관리자 대행 — 관리자 화면 「회원 대신 탈퇴 신청」 → 같은 확인.
--   (c) 배치 전이 — 미지급이 있는 행을 만들어 pending_payout 으로 둔 뒤 그 원인을 없애고
--       SELECT public.advance_withdrawal_states(); 를 직접 호출 → scheduled_at 이 그 순간으로 찍히는가.
--   🔴 (c) 를 건너뛰지 말 것 — 셋 중 하나만 빠져도 그 경로에서만 오탐이 남는다(§2-①).
--
-- [V3] 미지급이 남아 pending_payout 으로 들어간 행은 scheduled_at 이 NULL 인가(예정이 아닌데 찍히면 안 된다).
--   SELECT status, scheduled_at IS NULL AS "시각_비어있나"
--     FROM public.withdrawal_requests ORDER BY created_at DESC LIMIT 5;
--
-- [V4] 되돌리기 — 357·352 를 그대로 다시 실행하면 함수는 옛 판으로 돌아간다(권한 보존).
--   칸은 남겨 둬도 무해하다(아무도 안 읽는다). 지우려면 ALTER TABLE … DROP COLUMN scheduled_at.
