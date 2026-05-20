-- ============================================================
-- 145_application_messages_pr2.sql
-- 2026-05-20
--
-- 목적:
--   응모건 메시지 PR 2 DB 추가 — 알림·숨김·수동 응대 완료
--
-- 사양서:
--   docs/specs/2026-05-15-application-messaging.md §3-5, §4-3, §5-5
--   docs/specs/2026-05-20-HANDOFF-messaging-pr2.md §2
--
-- 전제 조건:
--   마이그레이션 144 (application_messages 5개 테이블 + RPC 4개) 적용 완료
--   패치 2026-05-20-msg-42702-hotfix.sql 적용 완료
--
-- 변경 내용:
--   (1) notifications.kind CHECK 제약 — message_received 추가 (기존 5종 + 신규 1종)
--   (2) send_application_message 재정의 — 관리자 발신 시 인플루언서 알림 INSERT 추가
--   (3) mark_application_resolved 신규 — 수동 응대 완료 (모든 관리자 is_admin)
--   (4) hide_application_message 신규 — 강제 숨김 (campaign_admin 이상)
--   (5) unhide_application_message 신규 — 복구 (super_admin 한정)
--
-- 신규 테이블·RLS·컬럼 변경:
--   없음 — 5개 테이블은 144에서 완성, 함수만 추가·재정의
--
-- 롤백:
--   BEGIN;
--   -- (5) unhide RPC 제거
--   DROP FUNCTION IF EXISTS public.unhide_application_message(uuid, text);
--   -- (4) hide RPC 제거
--   DROP FUNCTION IF EXISTS public.hide_application_message(uuid, text, text);
--   -- (3) mark_application_resolved RPC 제거
--   DROP FUNCTION IF EXISTS public.mark_application_resolved(uuid);
--   -- (2) send_application_message 를 핫픽스 버전으로 복원
--   --     (핫픽스 파일 supabase/patches/2026-05-20-msg-42702-hotfix.sql 재실행)
--   -- (1) notifications kind CHECK 제약 롤백
--   ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
--   ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--     'deliverable_rejected',
--     'deliverable_changed',
--     'deliverable_approved',
--     'application_cancelled'
--   ));
--   COMMENT ON COLUMN public.notifications.kind IS
--     '알림 종류. deliverable_* 3종(037)·application_cancelled(105). 관리자 알림은 admin_notices 테이블 별도.';
--   COMMIT;
-- ============================================================

BEGIN;


-- ============================================================
-- (1) notifications.kind CHECK 제약 확장 — message_received 추가
--
-- 현행 종류 (105까지 누적):
--   deliverable_rejected, deliverable_changed, deliverable_approved (037)
--   application_cancelled (105)
-- PR 2 신규:
--   message_received — 관리자가 인플루언서 응모건에 답장 시 발생
-- ============================================================
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received'
  ));

COMMENT ON COLUMN public.notifications.kind IS
  '알림 종류. '
  'deliverable_* 3종(037)·application_cancelled(105)·message_received(145). '
  '관리자 알림은 admin_notices 테이블 별도. '
  '인플루언서 화면 알림 모달: dev/js/notifications.js renderNotification().';


-- ============================================================
-- (2) send_application_message 재정의
--
-- 핫픽스(2026-05-20-msg-42702-hotfix.sql)에서 #variable_conflict use_column 추가 및
-- nested DECLARE 평탄화가 적용된 버전을 그대로 베이스로 사용.
--
-- PR 2 추가 내용:
--   관리자(admin)가 메시지를 발송한 경우,
--   해당 응모를 소유한 인플루언서에게 notifications 행 INSERT (kind='message_received').
--   인플루언서가 발신한 경우는 알림 INSERT 안 함 (관리자에겐 사이드바 미읽음 배지로 처리).
--
-- 보존된 내용 (핫픽스 포함):
--   - sender_kind 자동 판별 (관리자 먼저 검사)
--   - Rate limit 100건/시간
--   - 응모 종료 90일 경과 차단 (인플루언서만, nested DECLARE 평탄화 버전 유지)
--   - 자동 응대 처리 (결정 J):
--       인플루언서 → resolutions DELETE (reopen)
--       관리자     → resolutions UPSERT (auto_replied)
--   - SECURITY DEFINER + SET search_path=''
--   - #variable_conflict use_column 지시어 없음 (RETURNS uuid 단일 스칼라라 불필요)
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_application_message(
  p_application_id uuid,
  p_body           text,
  p_attachments    jsonb DEFAULT '[]'::jsonb
) RETURNS uuid  -- new message id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_kind text;
  v_sender_name text;
  v_app_owner   uuid;
  v_app_status  text;
  v_msg_id      uuid;
  v_rate_count  bigint;
  v_ended_at    timestamptz;  -- 응모 종료 시각 (90일 차단 판별용)
  v_camp_title  text;         -- [PR 2 추가] 알림 title 생성용 캠페인명
BEGIN
  -- 응모 소유자 확인
  SELECT user_id, status INTO v_app_owner, v_app_status
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '応募が見つかりません';
  END IF;

  -- sender_kind 판별 (관리자 먼저 검사 — 관리자가 본인 응모도 있을 수 있음)
  IF public.is_admin() THEN
    v_sender_kind := 'admin';
    SELECT name INTO v_sender_name FROM public.admins WHERE auth_id = auth.uid();
  ELSIF v_app_owner = auth.uid() THEN
    v_sender_kind := 'influencer';
    SELECT name INTO v_sender_name FROM public.influencers WHERE id = auth.uid();
  ELSE
    RAISE EXCEPTION '権限がありません';
  END IF;

  -- 본문/첨부 빈값 검증
  IF (p_body IS NULL OR btrim(p_body) = '') AND (p_attachments IS NULL OR p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です';
  END IF;

  -- Rate limit: 사용자별 100건/시간 (사양서 §9 행 1310)
  SELECT count(*) INTO v_rate_count
    FROM public.application_messages
   WHERE sender_id = auth.uid()
     AND created_at > now() - interval '1 hour';

  IF v_rate_count >= 100 THEN
    RAISE EXCEPTION 'メッセージの送信上限（1時間に100件）に達しました。しばらく経ってからお試しください';
  END IF;

  -- 응모 종료 90일 경과 차단 (사양서 §3-3)
  -- 관리자는 90일 경과 후에도 발송 허용 (사후 안내 필요 케이스 대응)
  -- nested DECLARE 제거 — 함수 상단 v_ended_at 사용 (핫픽스에서 평탄화)
  IF NOT public.is_admin() THEN
    SELECT CASE
      WHEN a.cancelled_at IS NOT NULL THEN a.cancelled_at
      WHEN a.status = 'rejected'      THEN a.reviewed_at
      WHEN a.status = 'approved' AND NOT EXISTS (
        SELECT 1 FROM public.deliverables d
         WHERE d.application_id = p_application_id
           AND d.status <> 'approved'
      ) AND EXISTS (
        SELECT 1 FROM public.deliverables d
         WHERE d.application_id = p_application_id
      ) THEN (
        SELECT max(d.reviewed_at) FROM public.deliverables d
         WHERE d.application_id = p_application_id
      )
      ELSE NULL
    END
    INTO v_ended_at
    FROM public.applications a
    WHERE a.id = p_application_id;

    IF v_ended_at IS NOT NULL AND v_ended_at < now() - interval '90 days' THEN
      RAISE EXCEPTION '応募終了から90日経過しました。閲覧のみ可能です';
    END IF;
  END IF;

  INSERT INTO public.application_messages (
    application_id, sender_kind, sender_id, sender_name, body, attachments
  ) VALUES (
    p_application_id,
    v_sender_kind,
    auth.uid(),
    COALESCE(v_sender_name, '(이름미상)'),
    COALESCE(p_body, ''),
    COALESCE(p_attachments, '[]'::jsonb)
  )
  RETURNING id INTO v_msg_id;

  -- 자동 응대 처리 (결정 J, 사양서 §3-4 + §4-1-3):
  --   인플루언서 새 메시지 → application_message_resolutions 행 자동 DELETE (reopen)
  --   관리자 답장 → application_message_resolutions 자동 UPSERT (auto_replied)
  IF v_sender_kind = 'influencer' THEN
    DELETE FROM public.application_message_resolutions
     WHERE application_id = p_application_id;
  ELSE  -- v_sender_kind = 'admin'
    INSERT INTO public.application_message_resolutions (
      application_id,
      resolved_at,
      resolved_by,
      resolved_by_name,
      resolved_after_message_at,
      resolution_method
    ) VALUES (
      p_application_id,
      now(),
      auth.uid(),
      COALESCE(v_sender_name, '(이름미상)'),
      COALESCE(
        (SELECT max(created_at)
           FROM public.application_messages
          WHERE application_id = p_application_id
            AND sender_kind = 'influencer'
            AND hidden_by_admin_at IS NULL
            AND self_withdrawn_at IS NULL),
        now()  -- 인플루언서 메시지 없을 때 (관리자가 먼저 시작한 케이스) now() 폴백
      ),
      'auto_replied'
    )
    ON CONFLICT (application_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';
  END IF;

  -- ----------------------------------------------------------------
  -- [PR 2 추가] 관리자 발신 시 인플루언서에게 알림 INSERT
  --
  -- 조건: v_sender_kind = 'admin' (인플루언서 발신은 알림 불필요 — 관리자는 사이드바 배지)
  -- 중복 방지: 같은 응모건에 대한 기존 미읽음 message_received 알림이 있으면
  --            INSERT 하지 않음 (이미 읽지 않은 알림이 누적되지 않도록).
  --            → 인플루언서가 열어서 읽어야 dismiss 되고, 다음 메시지가 또 알림 생성.
  --
  -- notifications 컬럼 구조 (037 기준):
  --   id, user_id, kind, ref_table, ref_id, title, body, read_at, created_at
  -- ----------------------------------------------------------------
  IF v_sender_kind = 'admin' THEN
    -- 캠페인명 조회 (알림 title 생성용)
    SELECT c.title INTO v_camp_title
      FROM public.applications a
      JOIN public.campaigns c ON c.id = a.campaign_id
     WHERE a.id = p_application_id;

    -- 같은 응모건에 미읽음 message_received 알림이 없을 때만 INSERT
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
       WHERE user_id   = v_app_owner
         AND kind      = 'message_received'
         AND ref_table = 'applications'
         AND ref_id    = p_application_id
         AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_app_owner,
        'message_received',
        'applications',
        p_application_id,
        COALESCE(v_camp_title, '') || ' — 運営からメッセージが届きました',
        COALESCE(v_sender_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;
  END IF;

  RETURN v_msg_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.send_application_message(uuid, text, jsonb) IS
  '[144][hotfix-42702][145] 메시지 발송 원격 호출 함수. 인플루언서·관리자 공용, sender_kind 자동 판별. '
  'Rate limit: 사용자별 100건/시간 (사양서 §9). '
  '관리자 답장 시 resolutions 자동 UPSERT + 인플루언서 알림(message_received) INSERT. '
  '인플루언서 발신은 알림 없음 (관리자는 사이드바 미읽음 배지로 처리). '
  '미읽음 message_received 알림이 이미 있으면 중복 INSERT 안 함. '
  '인플루언서는 응모 종료 90일 초과 시 발송 차단. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- (3) mark_application_resolved — 수동 응대 완료
--
-- 사양서 §4-1-3 (결정 J), §3-4, HANDOFF §2-3
-- is_admin() 가드 — 응대 완료 마킹은 모든 관리자 가능
--   (사양서 §3-4: super_admin·campaign_admin·campaign_manager 모두 발신·열람·응대완료 마킹).
--   자동 응대(send RPC)도 is_admin() 이라 수동도 동일 등급으로 통일.
-- application_message_resolutions 에 UPSERT (resolution_method='manual').
-- 가장 최근 인플루언서 메시지 시각을 resolved_after_message_at 에 기록.
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_application_resolved(
  p_application_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name              text;
  v_last_influencer_msg_at  timestamptz;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 전용)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 응모 존재 여부 확인
  IF NOT EXISTS (SELECT 1 FROM public.applications WHERE id = p_application_id) THEN
    RAISE EXCEPTION '응모를 찾을 수 없습니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 마지막 인플루언서 메시지 시각 (살아있는 것 기준)
  SELECT max(created_at) INTO v_last_influencer_msg_at
    FROM public.application_messages
   WHERE application_id = p_application_id
     AND sender_kind        = 'influencer'
     AND hidden_by_admin_at IS NULL
     AND self_withdrawn_at  IS NULL;

  INSERT INTO public.application_message_resolutions (
    application_id,
    resolved_at,
    resolved_by,
    resolved_by_name,
    resolved_after_message_at,
    resolution_method
  ) VALUES (
    p_application_id,
    now(),
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    COALESCE(v_last_influencer_msg_at, now()),
    'manual'
  )
  ON CONFLICT (application_id) DO UPDATE
    SET resolved_at               = EXCLUDED.resolved_at,
        resolved_by               = EXCLUDED.resolved_by,
        resolved_by_name          = EXCLUDED.resolved_by_name,
        resolved_after_message_at = EXCLUDED.resolved_after_message_at,
        resolution_method         = 'manual';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mark_application_resolved(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mark_application_resolved(uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_application_resolved(uuid) IS
  '[145] 응모건 수동 응대 완료 원격 호출 함수. is_admin() 가드 (모든 관리자 — 사양서 §3-4). '
  'application_message_resolutions UPSERT (resolution_method=manual). '
  '살아있는 마지막 인플루언서 메시지 시각 → resolved_after_message_at. '
  '인플루언서 메시지 없으면 now() 폴백. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- (4) hide_application_message — 강제 숨김
--
-- 사양서 §3-5 ① (HANDOFF §2-3)
-- campaign_admin 이상 가드.
-- application_messages.hidden_by_admin_at/_id/_reason_code/_memo UPDATE.
-- application_message_hide_history INSERT (action='hide').
-- 발송 대기 중인 이메일(email_send_at 도래 전)도 자동 취소.
--
-- hide_history 컬럼 구조 (144 기준):
--   id, message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo, at
-- ============================================================
CREATE OR REPLACE FUNCTION public.hide_application_message(
  p_message_id  uuid,
  p_reason_code text,
  p_reason_memo text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name text;
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 사유 카테고리 유효성 검증
  IF NOT EXISTS (
    SELECT 1 FROM public.lookup_values
     WHERE kind = 'message_hide_reason'
       AND code = p_reason_code
       AND active = true
  ) THEN
    RAISE EXCEPTION '유효하지 않은 사유 카테고리입니다: %', p_reason_code;
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 메시지 숨김 처리
  -- 이미 숨김 처리된 경우 UPDATE 0 → FOUND=false → 예외
  UPDATE public.application_messages
     SET hidden_by_admin_at = now(),
         hidden_by_admin_id = auth.uid(),
         hidden_reason_code = p_reason_code,
         hidden_reason_memo = p_reason_memo
   WHERE id = p_message_id
     AND hidden_by_admin_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION '메시지를 찾을 수 없거나 이미 숨김 처리되었습니다';
  END IF;

  -- 감사 이력 기록
  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id,
    'hide',
    'admin',
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    p_reason_code,
    p_reason_memo
  );

  -- 발송 대기 이메일 자동 취소 (email_send_at 도래 전인 경우)
  UPDATE public.application_messages
     SET email_skip_reason = 'cancelled'
   WHERE id = p_message_id
     AND email_send_at IS NOT NULL
     AND email_send_at > now()
     AND email_sent_at IS NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.hide_application_message(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.hide_application_message(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.hide_application_message(uuid, text, text) IS
  '[145] 메시지 강제 숨김 원격 호출 함수. campaign_admin 이상 가드. '
  'application_messages hidden_by_admin_* 4컬럼 UPDATE + hide_history INSERT(action=hide). '
  '이미 숨김 상태면 예외. 발송 대기 이메일 자동 취소. '
  'SECURITY DEFINER + search_path 고정. 조회는 get_application_messages RPC 비대칭 마스킹 참고.';


-- ============================================================
-- (5) unhide_application_message — 강제 숨김 복구
--
-- 사양서 §3-5 ① 복구 절차 (HANDOFF §2-3)
-- super_admin 한정 가드 (campaign_admin 은 hide 만 가능).
-- p_reason_memo 필수 (복구 사유 미기재 시 차단).
-- hidden_by_admin_* 4컬럼 NULL 복원.
-- application_message_hide_history INSERT (action='unhide').
-- ============================================================
CREATE OR REPLACE FUNCTION public.unhide_application_message(
  p_message_id  uuid,
  p_reason_memo text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (super_admin 한정)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 복구 사유 메모 필수
  IF p_reason_memo IS NULL OR btrim(p_reason_memo) = '' THEN
    RAISE EXCEPTION '복구 사유 메모는 필수입니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 숨김 상태인 메시지만 복원
  UPDATE public.application_messages
     SET hidden_by_admin_at = NULL,
         hidden_by_admin_id = NULL,
         hidden_reason_code = NULL,
         hidden_reason_memo = NULL
   WHERE id = p_message_id
     AND hidden_by_admin_at IS NOT NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION '메시지를 찾을 수 없거나 숨김 상태가 아닙니다';
  END IF;

  -- 감사 이력 기록
  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id,
    'unhide',
    'admin',
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    NULL,         -- unhide 는 사유 카테고리 없음
    p_reason_memo
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unhide_application_message(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.unhide_application_message(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.unhide_application_message(uuid, text) IS
  '[145] 메시지 강제 숨김 복구 원격 호출 함수. super_admin 한정. '
  'p_reason_memo 필수 (빈값 시 예외). '
  'hidden_by_admin_* 4컬럼 NULL 복원 + hide_history INSERT(action=unhide). '
  '숨김 상태가 아닌 메시지 호출 시 예외. SECURITY DEFINER + search_path 고정.';


COMMIT;
