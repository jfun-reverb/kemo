-- ============================================================
-- 440_restore_cancelled_application.sql
-- 관리자 「취소 되돌리기」 — 회원이 본인 취소한 신청을 원래 상태로
--
-- 사양서: docs/specs/2026-09-15-restore-cancelled-application.md
--         (「설계 → 데이터베이스 ①」·「확정된 결정」·거부 사유 10종 표)
-- 작업표: docs/specs/2026-09-15-restore-cancelled-application-breakdown.md
--         (조각 1, S-1~S-19)
--
-- 이 파일이 만드는 것:
--   [A] application_events.action 검사 제약 확장 — 3종 → 4종(restore_cancelled)
--   [B] notifications_kind_check 확장           — 12종(376) → 13종(application_restored)
--   [C] public.restore_cancelled_application(uuid, text) — 되돌리기 함수 본체
--
-- 선례:
--   · 305(application_events 와 무관하지만 「지웠다고 믿지 않는다」 자기 검증 패턴)
--   · 376(notifications_kind_check 를 12종으로 확장 — 이 파일의 베이스)
--   · 179(check_monitor_slots — 정원 판정 기준·감사용 계정 격리 패턴)
--   · 283(record_application_status_event — cancelled 전이가 조기 반환되는 근거)
--   · 357(withdrawal_proxy_request — {ok:false, error_code} 대신 이 저장소는
--     함수마다 reason/error_code 이름이 갈린다. 이 파일은 사양서·작업표 S-13 결정대로
--     **error_code** 로 고정한다)
--   · 394(cancel_application — 취소 칸 4개 이름·notifications 제목 조립 패턴의 원본)
--
-- 🔴 [A] 는 131 이 열 안쪽(inline)으로 정의해 **제약 이름이 자동 생성**이다.
--    이후 이 제약을 건드린 마이그레이션이 없어(전수 확인) 지금 이름이 무엇인지
--    파일만 봐서는 확신할 수 없다 — 그래서 DROP 전에 pg_constraint 를 직접 조회해
--    실제 이름을 얻는다(마이그레이션 305 가 겪은 「이름을 잘못 적어 DROP 이 조용히
--    통과」사고를 반복하지 않기 위해). 재생성한 뒤에는 **이름을 명시**해
--    (application_events_action_check) 다음부터는 이 함정이 없다.
--
-- 🔴 [B] 는 지금 이름이 이미 알려져 있다(notifications_kind_check, 376 에서 명시적
--    으로 지었다). 그래도 같은 방식으로 조회 후 지운다 — 스키마가 어긋나 있으면
--    (예: 누군가 대시보드에서 손으로 바꿈) 즉시 알 수 있게.
--
-- ⚠️ [B] 값 목록은 376 의 12종을 **한 글자도 안 빠뜨리고 그대로 옮기고**
--    application_restored 1종만 더한다. 하나라도 빠뜨리면 그 종류의 알림이
--    CHECK 위반으로 전부 실패한다(376·283 헤더가 같은 경고를 남겼다).
--
-- 🔴 이 파일이 **notifications_kind_check 의 다음 베이스**가 된다 — 이후 새
--    알림 종류를 추가하는 사람은 376 이 아니라 이 파일(440)을 베이스로 삼을 것.
--
-- [C] 함수 요약 — 잠금 순서 ①신청 행 FOR UPDATE → ②리뷰어형이면 캠페인 행
--    FOR UPDATE. 거부 사유 10종은 사양서 표 순서 그대로 판정해 처음 걸린 것
--    하나만 돌려준다:
--      1 forbidden  2 memo_required  3 not_found  4 not_cancelled
--      5 withdrawal_related  6 previous_status_not_restorable
--      7 campaign_deleted  8 event_campaign  9 active_application_exists
--      10 slots_full
--
--    🔴 `reviewed_at`·`reviewed_by` 는 **절대 건드리지 않는다** — 인플루언서
--       일일 메일(notify-influencer-daily-digest)이 「어제 reviewed_at + 승인」
--       으로 당선 절을 뽑는다. 채우면 다음 날 당선 메일이 다시 나가
--       사양서 결정 4(메일 없음, 알림 1건만)를 어긴다.
--
--    소유자 권한 실행(SECURITY DEFINER) 필수 — 빼면 UPDATE 로 신청 상태가
--    바뀔 때 도는 058 트리거(recompute_campaign_applied_count, 370 에서 일반
--    로그인 사용자 실행 권한이 회수됨)가 권한 부족으로 실패해 되돌리기 자체가
--    막힌다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] application_events.action 검사 제약 확장 — 3종 → 4종
-- ============================================================
DO $$
DECLARE
  v_conname text;
BEGIN
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'public.application_events'::regclass
     AND contype  = 'c'
     AND pg_get_constraintdef(oid) LIKE 'CHECK ((action =%';

  IF v_conname IS NULL THEN
    RAISE EXCEPTION
      '중단: application_events.action 검사 제약을 찾지 못했습니다. '
      '131 정의가 바뀌었을 수 있습니다 — 원인을 먼저 확인하세요.';
  END IF;

  EXECUTE format('ALTER TABLE public.application_events DROP CONSTRAINT %I', v_conname);
END $$;

ALTER TABLE public.application_events
  ADD CONSTRAINT application_events_action_check
  CHECK (action IN ('approve', 'reject', 'revert_to_pending', 'restore_cancelled'));

COMMENT ON COLUMN public.application_events.action IS
  'approve / reject / revert_to_pending / restore_cancelled([440] 관리자가 회원 본인 '
  '취소를 취소 직전 상태로 되돌림) — 본인 취소·재응모는 미기록. [440] 이전에는 이름이 '
  '자동 생성돼 있었다(131 inline CHECK) — 이제부터는 고정 이름(application_events_action_check).';

-- 자기 검증 — 「지웠다고 믿지 않는다」(305 와 같은 원칙)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.application_events'::regclass
       AND conname  = 'application_events_action_check'
       AND pg_get_constraintdef(oid) LIKE '%restore_cancelled%'
  ) THEN
    RAISE EXCEPTION
      '중단: application_events_action_check 재생성이 반영되지 않았습니다.';
  END IF;
END $$;


-- ============================================================
-- [B] notifications_kind_check 확장 — 12종(376) → 13종
-- ============================================================
DO $$
DECLARE
  v_conname text;
BEGIN
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'public.notifications'::regclass
     AND contype  = 'c'
     AND pg_get_constraintdef(oid) LIKE 'CHECK ((kind =%';

  IF v_conname IS NULL THEN
    RAISE EXCEPTION
      '중단: notifications.kind 검사 제약을 찾지 못했습니다. '
      '376 정의가 바뀌었을 수 있습니다 — 원인을 먼저 확인하세요.';
  END IF;

  EXECUTE format('ALTER TABLE public.notifications DROP CONSTRAINT %I', v_conname);
END $$;

-- ⚠️ 376 의 12종을 한 줄씩 그대로 옮기고 application_restored 1종만 더한다.
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved',
    'deliverable_proxy_submitted',
    'settlement_paypal_required',
    'settlement_paid',
    'submission_deadline_changed',
    'event_waitlist_promoted',
    'event_selection_won',
    'application_restored'   -- 440 신규: 관리자가 취소를 되돌렸다는 안내(응모이력으로 이동)
  ));

COMMENT ON COLUMN public.notifications.kind IS
  'deliverable_rejected | deliverable_changed | deliverable_approved | application_cancelled | '
  'message_received | application_approved | deliverable_proxy_submitted | '
  'settlement_paypal_required | settlement_paid | submission_deadline_changed | '
  'event_waitlist_promoted | event_selection_won | application_restored';

-- 자기 검증
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.notifications'::regclass
       AND conname  = 'notifications_kind_check'
       AND pg_get_constraintdef(oid) LIKE '%application_restored%'
  ) THEN
    RAISE EXCEPTION
      '중단: notifications_kind_check 재생성이 반영되지 않았습니다.';
  END IF;
END $$;


-- ============================================================
-- [C] restore_cancelled_application(uuid, text) — 되돌리기 함수 본체
-- ============================================================
CREATE OR REPLACE FUNCTION public.restore_cancelled_application(
  p_application_id uuid,
  p_memo           text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app                     public.applications%ROWTYPE;
  v_campaign                public.campaigns%ROWTYPE;
  v_memo_trimmed            text;
  v_withdrawal_related      boolean;
  v_active_exists           boolean;
  v_is_audit                boolean;
  v_current_count           int;
  v_slots_locked            int;
  v_on_hold_count           int;
  v_admin_name              text;
  v_notify_title            text;
  v_restored_status         text;
  -- 통과 직전에 담아 두는 「원래 취소 기록」 스냅샷(비우기 전에 값을 잃지 않기 위해)
  v_cancelled_at_snap       timestamptz;
  v_cancel_reason_code_snap text;
  v_cancel_reason_snap      text;
  v_cancel_phase_snap       text;
  v_event_memo              text;
BEGIN
  -- ── 1. forbidden ──────────────────────────────────────────
  IF NOT public.has_permission('application.restore_cancelled', 'write') THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'forbidden');
  END IF;

  -- ── 2. memo_required (비었거나 공백뿐) ────────────────────
  v_memo_trimmed := NULLIF(trim(p_memo), '');
  IF v_memo_trimmed IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'memo_required');
  END IF;

  -- ── 잠금 순서 ① 신청 행 FOR UPDATE ────────────────────────
  --   캠페인 행 잠금이 필요한지는 이 신청이 가리키는 캠페인(모집 형식)을
  --   읽어야 알 수 있으므로 신청 행을 먼저 잠근다.
  SELECT * INTO v_app
    FROM public.applications
   WHERE id = p_application_id
     FOR UPDATE;

  -- ── 3. not_found ──────────────────────────────────────────
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'not_found');
  END IF;

  -- ── 4. not_cancelled ──────────────────────────────────────
  IF v_app.status IS DISTINCT FROM 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'not_cancelled');
  END IF;

  -- ── 5. withdrawal_related ─────────────────────────────────
  --   ① 이 응모 자체가 탈퇴 절차로 철회됐거나(cancel_reason_code='withdrawal')
  --   ② 이 회원에게 진행 중(pending_payout·scheduled) 또는 확정(done) 탈퇴
  --      신청이 있으면 — 사유가 달라도 — 거부한다(사양서 결정 5·7).
  --   ⚠️ ①은 그 회원이 나중에 탈퇴를 취소(withdrawal_requests 가 전부
  --      cancelled)해도 그대로 거부된다 — 사유 코드만으로 거부되는 규칙이다.
  SELECT (v_app.cancel_reason_code = 'withdrawal')
      OR EXISTS (
           SELECT 1
             FROM public.withdrawal_requests w
            WHERE w.influencer_id = v_app.user_id
              AND w.status IN ('pending_payout', 'scheduled', 'done')
         )
    INTO v_withdrawal_related;

  IF v_withdrawal_related THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'withdrawal_related');
  END IF;

  -- ── 6. previous_status_not_restorable ─────────────────────
  --   previous_status 칸이 생기기 전(104 이전) 취소된 옛 행은 비어 있을 수
  --   있다 — 추측으로 승인시키지 않는다.
  IF v_app.previous_status IS DISTINCT FROM 'pending'
     AND v_app.previous_status IS DISTINCT FROM 'approved' THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'previous_status_not_restorable');
  END IF;

  -- ── 캠페인 조회(잠금 없음 — deleted_at·event_mode·recruit_type·slots 확인용) ──
  SELECT * INTO v_campaign
    FROM public.campaigns
   WHERE id = v_app.campaign_id;

  -- ── 7. campaign_deleted ───────────────────────────────────
  --   보관 삭제(soft_delete_campaign)는 신청을 즉시 파기하므로 정상 경로로는
  --   재현되지 않는다 — 방어용 판정. 캠페인 자체가 없는 경우도 같게 본다.
  IF v_campaign.id IS NULL OR v_campaign.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'campaign_deleted');
  END IF;

  -- ── 8. event_campaign ─────────────────────────────────────
  --   행사(티켓) 캠페인은 신청 상태를 예약 함수(283)만 다루고, 직접 상태
  --   변경은 guard_event_application_status_change(289) 가 막는다.
  IF COALESCE(v_campaign.event_mode, false) THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'event_campaign');
  END IF;

  -- ── 9. active_application_exists ──────────────────────────
  --   같은 회원·같은 캠페인에 이미 취소가 아닌 신청이 있으면(재응모 등)
  --   부분 유일 색인(applications_user_camp_active_uidx, 104)에 걸린다 —
  --   원문 오류가 화면에 뜨지 않게 먼저 조회해 전용 사유로 거부한다.
  SELECT EXISTS (
    SELECT 1
      FROM public.applications a
     WHERE a.user_id     = v_app.user_id
       AND a.campaign_id = v_app.campaign_id
       AND a.id          <> v_app.id
       AND a.status      <> 'cancelled'
  ) INTO v_active_exists;

  IF v_active_exists THEN
    RETURN jsonb_build_object('ok', false, 'error_code', 'active_application_exists');
  END IF;

  -- ── 10. slots_full — 리뷰어형만, check_monitor_slots(179)와 같은 기준 ──
  --   되돌리는 회원이 감사용 계정이면 검사하지 않는다. slots 가 없거나
  --   0 이하면 검사하지 않는다(가드와 같다). 기프팅·방문형은 원래 초과
  --   응모를 허용하므로 검사하지 않는다.
  IF v_campaign.recruit_type = 'monitor' AND COALESCE(v_campaign.slots, 0) > 0 THEN
    SELECT i.is_audit INTO v_is_audit
      FROM public.influencers i
     WHERE i.id = v_app.user_id;

    IF COALESCE(v_is_audit, false) = false THEN
      -- ── 잠금 순서 ② 리뷰어형이면 캠페인 행 FOR UPDATE ──────
      --   동시에 두 관리자가 되돌려도 둘 다 정원 검사를 통과하지 않도록,
      --   카운트 직전에 캠페인 행을 잠근다(check_monitor_slots 와 같은 대상).
      -- ⚠️ 정원(slots)도 **잠근 뒤 다시 읽는다** — 위 v_campaign 은 잠그기 전에
      --    읽은 값이라, 그 사이 정원이 줄었으면 옛 값으로 판정하게 된다.
      --    179 의 check_monitor_slots 도 잠금과 같은 조회에서 slots 를 읽는다.
      SELECT c.slots INTO v_slots_locked
        FROM public.campaigns c
       WHERE c.id = v_campaign.id
         FOR UPDATE;

      SELECT count(*) INTO v_current_count
        FROM public.applications a
        JOIN public.influencers i2 ON i2.id = a.user_id
       WHERE a.campaign_id = v_campaign.id
         AND a.status IN ('pending', 'approved')
         AND i2.is_audit = false;

      IF COALESCE(v_slots_locked, 0) > 0 AND v_current_count >= v_slots_locked THEN
        RETURN jsonb_build_object('ok', false, 'error_code', 'slots_full');
      END IF;
    END IF;
  END IF;

  -- ════════════════════════════════════════════════════════
  -- 여기부터 통과 — 취소 기록을 비우기 전에 값을 스냅샷으로 담아 둔다
  -- (⑩ 원래 취소 기록이 사라지는 것을 막기 위해 이력 행 memo 에 옮겨 적는다)
  -- ════════════════════════════════════════════════════════
  v_cancelled_at_snap       := v_app.cancelled_at;
  v_cancel_reason_code_snap := v_app.cancel_reason_code;
  v_cancel_reason_snap      := v_app.cancel_reason;
  v_cancel_phase_snap       := v_app.cancel_phase;
  v_restored_status         := v_app.previous_status;

  -- 🔴 reviewed_at·reviewed_by 는 절대 건드리지 않는다(위 헤더 경고 참조).
  UPDATE public.applications
     SET status             = v_restored_status,
         previous_status    = NULL,
         cancelled_at       = NULL,
         cancel_reason_code = NULL,
         cancel_reason      = NULL,
         cancel_phase       = NULL
   WHERE id = v_app.id;

  -- ── application_events 1행 — 관리자 사유 + 원래 취소 기록을 함께 남긴다 ──
  SELECT a.name INTO v_admin_name
    FROM public.admins a
   WHERE a.auth_id = auth.uid();

  v_event_memo :=
    '사유: ' || v_memo_trimmed ||
    ' / 원래 취소: ' ||
    COALESCE(
      to_char(v_cancelled_at_snap AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI'),
      '시각 불명'
    ) ||
    ' · ' || COALESCE(v_cancel_phase_snap, '단계 불명') ||
    ' · ' || COALESCE(v_cancel_reason_code_snap, '사유코드 없음') ||
    ' · 「' || COALESCE(v_cancel_reason_snap, '') || '」';

  INSERT INTO public.application_events (
    application_id, action, from_status, to_status, changed_by, changed_by_name, memo
  ) VALUES (
    v_app.id, 'restore_cancelled', 'cancelled', v_restored_status,
    auth.uid(), v_admin_name, v_event_memo
  );

  -- ── notifications 1행 — 회원 알림(캠페인 제목 유무로 제목 분기, 394 와 같은 방식) ──
  v_notify_title := CASE
    WHEN v_campaign.title IS NOT NULL AND length(trim(v_campaign.title)) > 0
      THEN '応募の取り消しが撤回されました — ' || v_campaign.title
    ELSE '応募の取り消しが撤回されました'
  END;

  INSERT INTO public.notifications (
    user_id, kind, ref_table, ref_id, title, body
  ) VALUES (
    v_app.user_id, 'application_restored', 'applications', v_app.id, v_notify_title, NULL
  );

  -- ⚠️ 058 트리거(trg_sync_applied_count → recompute_campaign_applied_count)가
  --    상태 UPDATE 에 반응해 모집 인원(applied_count)을 자동 재계산한다.
  --    여기서 따로 부를 필요 없음.

  -- ── 보류 정산 수(안전장치로만 — 자동으로 풀지 않는다) ────────
  SELECT count(*) INTO v_on_hold_count
    FROM public.settlements s
   WHERE s.application_id = v_app.id
     AND s.status = 'on_hold';

  RETURN jsonb_build_object(
    'ok',                      true,
    'restored_status',         v_restored_status,
    'on_hold_settlement_count', v_on_hold_count
  );
END;
$$;

COMMENT ON FUNCTION public.restore_cancelled_application(uuid, text) IS
  '[440] 관리자가 회원 본인이 취소한 신청(cancel_application, 394)을 취소 직전 상태로 '
  '되돌린다. 권한 has_permission(''application.restore_cancelled'',''write''). 거부 사유 10종 '
  '{ok:false, error_code}(forbidden·memo_required·not_found·not_cancelled·'
  'withdrawal_related·previous_status_not_restorable·campaign_deleted·event_campaign·'
  'active_application_exists·slots_full) — 사양서 표 순서대로 판정해 처음 걸린 것만 반환. '
  '성공 {ok:true, restored_status, on_hold_settlement_count}. 잠금 순서: ①신청 행 '
  'FOR UPDATE → ②리뷰어형이면 캠페인 행 FOR UPDATE(check_monitor_slots 와 같은 기준). '
  '🔴 reviewed_at·reviewed_by 는 건드리지 않는다(인플루언서 일일 메일의 당선 절 오발송 방지). '
  '원래 취소 기록(취소 시각·단계·사유코드·사유원문)은 비우기 전에 application_events.memo 에 '
  '옮겨 적는다. notifications.kind=''application_restored'' 1건 발송(메일 없음). '
  'application_events 트리거(record_application_status_event, 283)는 cancelled → 전이를 '
  '기록하지 않아 이 함수가 넣는 행·알림과 중복되지 않는다.';

REVOKE ALL ON FUNCTION public.restore_cancelled_application(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_cancelled_application(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.restore_cancelled_application(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 확인 (한 번에 전부 실행하지 말 것)
-- ⚠️ 권한 가드·auth.uid() 분기는 SQL 편집기(서비스 키)에서는 재현되지 않는다.
--    V2 이후는 반드시 실제 로그인한 브라우저 콘솔에서.
-- ============================================================
/*

-- [V0] 제약 2개가 기대한 값을 담고 있는가
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'public.application_events'::regclass
   AND conname  = 'application_events_action_check';
-- 기대: IN 목록에 4개('approve','reject','revert_to_pending','restore_cancelled')

SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'public.notifications'::regclass
   AND conname  = 'notifications_kind_check';
-- 기대: IN 목록에 13개 — 376 의 12개 + application_restored.
--   옛 12개를 하나씩 대조: deliverable_rejected · deliverable_changed ·
--   deliverable_approved · application_cancelled · message_received ·
--   application_approved · deliverable_proxy_submitted ·
--   settlement_paypal_required · settlement_paid · submission_deadline_changed ·
--   event_waitlist_promoted · event_selection_won (12개, 빠짐없음)
--   + application_restored (신규 1개) = 13개

-- [V1] 함수 시그니처·속성 확인
SELECT p.proname, pg_get_function_arguments(p.oid) AS args,
       p.prosecdef AS is_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'restore_cancelled_application';
-- 기대: 1행, is_security_definer = true

-- ── 아래부터는 실제 로그인 브라우저 콘솔(캠페인관리자·캠페인매니저 각 1개 계정) ──

-- [V2] forbidden — 캠페인매니저 계정에서
--   await db.rpc('restore_cancelled_application', {p_application_id:'<임의 uuid>', p_memo:'시험'})
--   기대: { ok:false, error_code:'forbidden' }

-- [V3] memo_required — 캠페인관리자 계정, 빈 사유
--   await db.rpc('restore_cancelled_application', {p_application_id:'<취소된 신청 id>', p_memo:'  '})
--   기대: { ok:false, error_code:'memo_required' }

-- [V4] not_found
--   p_application_id 에 없는 uuid → { ok:false, error_code:'not_found' }

-- [V5] not_cancelled
--   승인(approved) 상태 신청 id → { ok:false, error_code:'not_cancelled' }

-- [V6] withdrawal_related
--   ① cancel_reason_code='withdrawal' 인 시험 취소 행 → 거부, 그 회원의
--      withdrawal_requests 를 전부 cancelled 로 바꾼 뒤 다시 호출해도 여전히 거부
--      (사유 코드만으로 거부되는지 = 결정 5)
--   ② 그 회원에게 pending_payout·scheduled·done 탈퇴 신청이 있는 상태에서
--      본인 취소(사유 다름) 행 → 거부

-- [V7] previous_status_not_restorable
--   개발 데이터베이스에서 시험 취소 행의 previous_status 만 SQL 로 NULL 처리한 뒤 호출
--   → { ok:false, error_code:'previous_status_not_restorable' }
--   (확인 뒤 원래 값으로 되돌릴 것)

-- [V8] campaign_deleted
--   개발 데이터베이스에서 시험 캠페인에 deleted_at 만 SQL 로 넣고(신청 파기 없이) 호출
--   → { ok:false, error_code:'campaign_deleted' } (확인 뒤 되돌릴 것)

-- [V9] event_campaign
--   행사 모드 시험 캠페인에서 관리자 예약 취소(288)로 만든 취소 행 → 거부

-- [V10] active_application_exists
--   모집중 시험 캠페인에서 취소 → 재응모한 회원의 옛 취소 행 → 거부

-- [V11] slots_full
--   정원 1인 리뷰어형 시험 캠페인에서 A 취소 → B 응모(승인) → A 되돌리기 시도
--   → { ok:false, error_code:'slots_full' }

-- [V12] 성공 — 심사중(pending)으로 되돌리기
--   await db.rpc('restore_cancelled_application', {p_application_id:'<취소된 pending 신청>', p_memo:'실제로 리뷰 진행 예정 — 시험'})
--   기대: { ok:true, restored_status:'pending', on_hold_settlement_count:0 }
--   확인:
--     SELECT status, previous_status, cancelled_at, cancel_reason_code, cancel_reason,
--            cancel_phase, reviewed_at, reviewed_by
--       FROM public.applications WHERE id = '<그 id>';
--     → status='pending', previous_status/cancelled_at/cancel_* 모두 NULL,
--       reviewed_at·reviewed_by 는 되돌리기 전과 동일(변화 없음)
--     SELECT action, from_status, to_status, memo FROM public.application_events
--      WHERE application_id = '<그 id>' AND action='restore_cancelled';
--     → 정확히 1행, memo 에 「사유: … / 원래 취소: …」 포함
--     SELECT kind, title FROM public.notifications
--      WHERE ref_table='applications' AND ref_id='<그 id>' AND kind='application_restored';
--     → 1행
--     캠페인 applied_count 가 재계산됐는지도 확인(058 트리거)

-- [V13] 성공 — 승인(approved)으로 되돌리기
--   같은 방식, restored_status:'approved' 확인

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ 이미 restore_cancelled·application_restored 행이 생긴 뒤에는 옛 제약
--    목록으로 못 되돌린다(CHECK 위반) — 그 행을 먼저 지우거나 다른 값으로
--    바꿀 것.
--
-- BEGIN;
--
-- DROP FUNCTION IF EXISTS public.restore_cancelled_application(uuid, text);
--
-- ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
-- ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--   'deliverable_rejected','deliverable_changed','deliverable_approved',
--   'application_cancelled','message_received','application_approved',
--   'deliverable_proxy_submitted','settlement_paypal_required','settlement_paid',
--   'submission_deadline_changed','event_waitlist_promoted','event_selection_won'
-- ));
--
-- ALTER TABLE public.application_events DROP CONSTRAINT IF EXISTS application_events_action_check;
-- ALTER TABLE public.application_events ADD CONSTRAINT application_events_action_check
--   CHECK (action IN ('approve', 'reject', 'revert_to_pending'));
--
-- COMMIT;
--
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
