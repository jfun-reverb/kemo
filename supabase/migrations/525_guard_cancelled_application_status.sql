-- ============================================================
-- 525_guard_cancelled_application_status.sql
-- 취소된 신청(cancelled)의 상태를 「취소 되돌리기」 함수 밖에서 못 바꾸게 막는다
--
-- 근거: 전수조사 3차 ⑤-1 (docs/research/2026-09-28-codebase-audit-findings.md)
--   관리자는 001 정책 applications_update_admin 으로 applications 를 직접
--   UPDATE 할 수 있어, 개발자 도구로 cancelled → pending/approved 를 바꾸면
--   440 restore_cancelled_application 의 거부 10종(탈퇴 관련·정원·다른 살아있는
--   신청·삭제 캠페인·행사 캠페인 등)과 원래 취소 기록 이력 보존을 우회한다.
--   화면에는 그런 버튼이 없다(cancelled 행은 처리 버튼 없음).
--
-- 편집기 경고: 뜸 — 무해 (DROP TRIGGER IF EXISTS 로 같은 이름 트리거를 지우고
--   다시 만드는 것뿐. 행·데이터 삭제 없음.)
--
-- 이 파일이 하는 것
--   [A] 트리거 함수 guard_cancelled_application_status() + 트리거
--       trg_guard_cancelled_application_status (BEFORE UPDATE OF status,
--       WHEN OLD.status='cancelled' AND NEW.status<>'cancelled')
--   [B] restore_cancelled_application(uuid,text) 재정의 — 베이스 = 440
--       (이 이름을 CREATE 하는 파일은 440 하나뿐, 441 은 권한 시드만).
--       440 본문 그대로 + ① UPDATE 직전 통과 표시 세우기 ② UPDATE 직후 끄기.
--       CREATE OR REPLACE 라 실행 권한(authenticated 만)은 보존된다 — DROP 금지.
--
-- ── 「cancelled 에서 다른 상태로 가는 정상 경로」 전수 결과 (2026-10-14) ──
--   마이그레이션 중 applications 를 UPDATE 하는 문장이 있는 파일을 모두 읽어
--   status 를 cancelled 밖으로 보내는 것을 가렸다. 둘뿐이다.
--     1) 440 restore_cancelled_application — 표시 reverb.restore_cancelled
--     2) 행사 예약 되살리기 — reserve_event_ticket(283→284→316→330→378,
--        현재 원본 378)의 「취소 후 재예약」 UPDATE. 함수 앞에서
--        reverb.event_ticket_bypass='on' 을 세운다(289 관례).
--        행사 대기자 승격(283/288/377/317)·뽑기 확정(379/380)도 같은 표시를
--        쓰며 원래 cancelled 가 아닌 신청만 대상이지만, 데이터가 어긋나 있어도
--        뽑기 전체가 롤백되지 않도록 표시가 있으면 통과시킨다.
--   그 밖에는 cancelled 로 들어가기만 하거나(104/113/306/309/356/394
--   cancel_application, 283/288/350/418 행사 취소·탈퇴) cancelled 를 WHERE 로
--   제외한다(176/177/289 자동 낙첨은 status='pending' 만). 246/247/320 은
--   상태 감시 트리거일 뿐 UPDATE 안 함, 396/520 탈퇴 개인정보 파기는 status
--   열을 SET 하지 않아 UPDATE OF status 트리거가 안 걸린다. Edge Function 은
--   applications 를 SELECT 만 한다. 화면은 storage.js updateApplication 한 곳 →
--   호출부 admin-applications.js updateAppStatus 하나이고 pending 행 승인/미승인,
--   승인 행 되돌리기 버튼에서만 불리며 cancelled 행엔 버튼이 없다. 재응모는 새
--   행 INSERT(104: cancelled 는 부분 유일 색인 제외)라 이 트리거와 무관하다.
--   supabase/patches 의 UPDATE 는 위 마이그레이션의 복사본이다.
--
-- ── 통과 조건 3종 ──────────────────────────────────────────────
--   ① reverb.restore_cancelled = 이 행의 id  (440 함수가 세우는 표시.
--      값에 대상 id 를 담아 다른 행은 안 풀린다. current_setting 두 번째 인자
--      true 필수 — 없으면 표시 없을 때 오류로 UPDATE 가 죽는다.)
--   ② reverb.event_ticket_bypass = 'on'  (행사 예약 함수들이 세우는 표시)
--   ③ auth.uid() IS NULL  (SQL 편집기·서비스 키·배치 — 로그인 사용자가 아닌
--      경로. 운영자가 편집기에서 긴급 보정할 길을 남긴다. 위 정상 경로 중
--      로그인 없이 도는 배치가 cancelled 를 벗어나는 것은 없다. 막으려는 대상은
--      「로그인한 관리자의 직접 UPDATE」다. 359 의 차단 장치와 같은 통과 조항.)
--   set_config 는 pg_catalog 함수라 PostgREST(공개 키·로그인 키)로 직접 부를
--   수 없다 — 관리자가 개발자 도구로 표시를 세울 수 없다.
--
-- 트리거 실행 순서: BEFORE UPDATE OF status 는 이름 알파벳순. 이 트리거
--   (trg_guard_cancelled…)는 trg_guard_event_application_status_change(289)·
--   trg_guard_reject_with_paid_settlement(247)보다 앞이다(c < e < r).
--
-- 거부 코드: cancelled_status_locked (ERRCODE P0001, 한글 안내 포함).
--
-- 실행 권한: 트리거 함수는 CREATE TRIGGER 시점에만 권한을 보므로 회수해도
--   발화에 영향 없다. 369·370 의 두 방향(PUBLIC / anon·authenticated)을 모두 회수.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] 트리거 함수 + 트리거
-- ============================================================
CREATE OR REPLACE FUNCTION public.guard_cancelled_application_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY INVOKER
  SET search_path = ''
AS $$
BEGIN
  -- 이중 방어(WHEN 절과 같은 조건) — 247·289 관례
  IF OLD.status IS DISTINCT FROM 'cancelled'
     OR NEW.status IS NOT DISTINCT FROM 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- ③ 로그인 사용자가 없는 경로(편집기·서비스 키·배치)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- ② 행사 예약 함수들의 통과 표시(289)
  IF COALESCE(current_setting('reverb.event_ticket_bypass', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  -- ① 440 취소 되돌리기 함수의 통과 표시 — 값이 이 행의 id 일 때만
  IF COALESCE(current_setting('reverb.restore_cancelled', true), '') = NEW.id::text THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'cancelled_status_locked: 취소된 신청의 상태는 직접 바꿀 수 없습니다. 신청 목록의 「취소 되돌리기」를 사용해 주세요.'
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION public.guard_cancelled_application_status() IS
  '[525] cancelled 신청의 상태를 로그인 사용자가 직접 UPDATE 로 바꾸는 것을 막는다 '
  '(440 restore_cancelled_application 우회 차단). 통과: reverb.restore_cancelled=행 id · '
  'reverb.event_ticket_bypass=on · auth.uid() IS NULL.';

REVOKE ALL ON FUNCTION public.guard_cancelled_application_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_cancelled_application_status() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_cancelled_application_status ON public.applications;
CREATE TRIGGER trg_guard_cancelled_application_status
  BEFORE UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (OLD.status = 'cancelled' AND NEW.status IS DISTINCT FROM 'cancelled')
  EXECUTE FUNCTION public.guard_cancelled_application_status();

-- ============================================================
-- [B] restore_cancelled_application(uuid, text) — 440 의 176~402행 +
--     [525] 표시 두 줄. CREATE OR REPLACE — 실행 권한 보존.
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

  -- [525] 상태 잠금 트리거 통과 표시 — 값에 대상 신청 id 를 담아 이 행만 풀린다
  PERFORM set_config('reverb.restore_cancelled', v_app.id::text, true);

  -- 🔴 reviewed_at·reviewed_by 는 절대 건드리지 않는다(위 헤더 경고 참조).
  UPDATE public.applications
     SET status             = v_restored_status,
         previous_status    = NULL,
         cancelled_at       = NULL,
         cancel_reason_code = NULL,
         cancel_reason      = NULL,
         cancel_phase       = NULL
   WHERE id = v_app.id;

  -- [525] 표시 끄기
  PERFORM set_config('reverb.restore_cancelled', '', true);

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


COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로(중간에 기대와 다르면 멈추고 원인부터)
-- 이 편집기는 서비스 키라 auth.uid() 가 NULL → 통과 조항 ③ 때문에 그대로는
-- 거부가 재현되지 않는다. 아래처럼 로그인 관리자인 척 하는 트랜잭션을 쓰고
-- 마지막에 ROLLBACK 한다(데이터 변경 없음).
-- ============================================================
-- [1] 트리거 확인
-- SELECT tgname, tgenabled FROM pg_trigger
--  WHERE tgrelid='public.applications'::regclass
--    AND tgname='trg_guard_cancelled_application_status';   -- 1행, 'O'
--
-- [2] 직접 UPDATE 거부 (cancelled 신청 1건과 관리자 auth_id 를 먼저 골라 대입)
-- BEGIN;
--   SET LOCAL ROLE authenticated;
--   SELECT set_config('request.jwt.claims',
--     '{"sub":"<관리자 auth_id>","role":"authenticated"}', true);
--   UPDATE public.applications SET status='pending' WHERE id='<cancelled 신청 id>';
--   -- 기대: ERROR cancelled_status_locked (P0001)
-- ROLLBACK;
--
-- [3] 함수 경유 통과 (같은 방식. 거부 사유가 걸리는 신청이면 {ok:false,error_code} 가
--     오는 것도 정상 — 그 경우 걸리지 않는 신청으로 다시 고를 것)
-- BEGIN;
--   SET LOCAL ROLE authenticated;
--   SELECT set_config('request.jwt.claims', '{"sub":"<관리자 auth_id>","role":"authenticated"}', true);
--   SELECT public.restore_cancelled_application('<cancelled 신청 id>', '525 스모크');
--   -- 기대: {"ok": true, ...}
-- ROLLBACK;
--
-- [4] 권한 보존 확인 (authenticated 만 실행 가능해야 함)
-- SELECT p.proacl::text FROM pg_proc p
--  WHERE p.oid='public.restore_cancelled_application(uuid,text)'::regprocedure;
--
-- ⚠️ 적용 뒤 행사 캠페인 「취소 후 재예약」 1회를 개발서버 화면에서 확인할 것
--    (cancelled → 예약 되살리기가 통과 조항 ②로 지나가는지).
--
-- ============================================================
-- 롤백
-- ============================================================
-- DROP TRIGGER IF EXISTS trg_guard_cancelled_application_status ON public.applications;
-- DROP FUNCTION IF EXISTS public.guard_cancelled_application_status();
-- restore_cancelled_application 은 440 의 [C] 블록(CREATE OR REPLACE)을 다시 실행해
-- 표시 두 줄을 걷어낸다(남겨 두어도 표시를 읽는 트리거가 없으면 무해).
