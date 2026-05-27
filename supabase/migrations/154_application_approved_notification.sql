-- ============================================================
-- 154_application_approved_notification.sql
-- 2026-05-27
--
-- 목적:
--   신청(applications)이 pending → approved 로 전환될 때
--   인플루언서에게 앱 알림(notifications) 자동 생성.
--   현재 승인 알림이 전혀 없어 인플루언서가 응모이력을 직접 확인해야
--   당첨 여부를 알 수 있는 문제를 해결한다.
--
-- 사양서:
--   docs/specs/2026-05-27-faq-accuracy-fix.md §2
--
-- 전제 조건:
--   마이그레이션 153 (policy_notice_log) 적용 완료
--
-- 변경 내용:
--   (1) notifications.kind CHECK 제약 — application_approved 추가
--       현행(145까지 누적): deliverable_rejected / deliverable_changed /
--         deliverable_approved / application_cancelled / message_received
--       신규: application_approved
--   (2) record_application_status_event() 함수 재정의
--       — 기존: application_events INSERT 만
--       — 추가: pending → approved 전이 시 notifications INSERT
--               되돌리기(approved → pending) 후 재승인 시 중복 알림 차단
--               (미읽음 application_approved 알림이 이미 있으면 INSERT 건너뜀)
--       — 트리거는 기존 trg_application_status_event 재사용 (새로 만들 필요 없음)
--
-- 알림 내용 (인플루언서 안내 — 쉬운 말):
--   kind    : application_approved
--   title   : 「キャンペーンに当選しました」
--   body    : 「{캠페인명}に当選しました。成果物の提出をお願いします。」
--   ref_table: applications
--   ref_id  : application.id
--   user_id : application.user_id (= influencers.id = auth.users.id)
--
-- 중복 방지 전략:
--   되돌리기(approved → pending) 후 재승인 케이스에서
--   같은 application_id 의 미읽음(read_at IS NULL) application_approved
--   알림이 이미 존재하면 INSERT 를 건너뜀.
--   → 인플루언서가 알림을 읽지 않은 채 재승인이 일어나도 중복 노출 없음.
--   읽은 뒤 재승인이면 새로운 알림 1건 발송 (정상 동작).
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버는 FAQ/메시지 기능 운영 배포 시점에 함께 적용 (현재 보류)
--
-- 검증 쿼리 (이 파일 아래쪽 §검증 섹션 참조)
--
-- 롤백:
--   -- 1. 트리거 함수를 마이그레이션 131 버전으로 복원 (아래 §롤백 참조)
--   -- 2. notifications.kind CHECK 제약 롤백
--   ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
--   ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--     'deliverable_rejected',
--     'deliverable_changed',
--     'deliverable_approved',
--     'application_cancelled',
--     'message_received'
--   ));
-- ============================================================

BEGIN;


-- ============================================================
-- (1) notifications.kind CHECK 제약 확장 — application_approved 추가
--
-- 현행 종류 (145까지 누적):
--   deliverable_rejected, deliverable_changed, deliverable_approved (037)
--   application_cancelled (105)
--   message_received (145)
-- 신규 (154):
--   application_approved — 신청 pending → approved 전이 시 인플루언서 알림
-- ============================================================
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved'
  ));

COMMENT ON COLUMN public.notifications.kind IS
  '알림 종류. '
  'deliverable_* 3종(037)·application_cancelled(105)·message_received(145)·'
  'application_approved(154). '
  '관리자 알림은 admin_notices 테이블 별도. '
  '인플루언서 화면 알림 모달: dev/js/notifications.js renderNotification().';


-- ============================================================
-- (2) record_application_status_event() 함수 재정의
--
-- 131 버전에서 변경된 내용:
--   - v_camp_title, v_already_notified 변수 추가
--   - pending → approved 전이 시 notifications INSERT 블록 추가
--   - 중복 방지: 같은 application_id 의 미읽음 application_approved 가
--     이미 있으면 INSERT 건너뜀
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_application_status_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_action           text;
  v_admin_name       text;
  v_camp_title       text;
  v_already_notified boolean;
BEGIN
  -- no-op (status 동일) 스킵
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ── 운영자 액션 매핑 ─────────────────────────────────────────
  -- cancelled 로의 전이는 cancel_application RPC 가 처리 (cancelled_at 별도 추적).
  -- cancelled → pending 은 현재 UI 없음 — 추후 필요 시 매핑 확장.
  v_action := CASE
    WHEN OLD.status = 'pending'                AND NEW.status = 'approved' THEN 'approve'
    WHEN OLD.status = 'pending'                AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status IN ('approved','rejected') AND NEW.status = 'pending'  THEN 'revert_to_pending'
    WHEN OLD.status = 'approved'               AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status = 'rejected'               AND NEW.status = 'approved' THEN 'approve'
    ELSE NULL
  END;

  -- 매핑 외 케이스 (cancelled 전이 등) 는 기록 안 함
  IF v_action IS NULL THEN
    RETURN NEW;
  END IF;

  -- ── application_events audit INSERT (131 기존 동작 유지) ─────
  SELECT a.name INTO v_admin_name
    FROM public.admins a
   WHERE a.auth_id = auth.uid();

  INSERT INTO public.application_events (
    application_id,
    action,
    from_status,
    to_status,
    changed_by,
    changed_by_name,
    memo
  ) VALUES (
    NEW.id,
    v_action,
    OLD.status,
    NEW.status,
    auth.uid(),
    v_admin_name,
    NULL
  );

  -- ── 승인 알림 INSERT (154 신규) ──────────────────────────────
  -- pending → approved 또는 rejected → approved (재승인) 전이에서만 발송
  IF NEW.status = 'approved' THEN

    -- 중복 방지: 같은 application_id 의 미읽음 승인 알림이 이미 있으면 스킵
    -- (되돌리기 후 재승인 케이스 — 인플루언서가 첫 알림을 아직 읽지 않은 상태)
    SELECT EXISTS (
      SELECT 1
        FROM public.notifications
       WHERE user_id   = NEW.user_id
         AND kind      = 'application_approved'
         AND ref_table = 'applications'
         AND ref_id    = NEW.id
         AND read_at   IS NULL
    ) INTO v_already_notified;

    IF NOT v_already_notified THEN
      -- 캠페인명 조회 (NULL 이면 일반 문구로 폴백)
      SELECT title INTO v_camp_title
        FROM public.campaigns
       WHERE id = NEW.campaign_id;

      INSERT INTO public.notifications (
        user_id,
        kind,
        ref_table,
        ref_id,
        title,
        body
      ) VALUES (
        NEW.user_id,
        'application_approved',
        'applications',
        NEW.id,
        'キャンペーンに当選しました',
        COALESCE(v_camp_title, 'キャンペーン') || 'に当選しました。成果物の提出をお願いします。'
      );
    END IF;

  END IF;
  -- ── 승인 알림 끝 ─────────────────────────────────────────────

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_application_status_event() IS
  '[131+154] applications.status 변경 시 application_events 자동 INSERT '
  '+ pending/rejected → approved 전이 시 인플루언서 승인 알림(notifications) INSERT. '
  'SECURITY DEFINER — 트리거에서만 호출. '
  'trg_application_status_event 트리거(131)는 변경 없이 재사용.';


COMMIT;


-- ============================================================
-- §검증 — 적용 후 개발서버 SQL Editor에서 1단계씩 실행
-- (아래는 실행 대상 SQL 이 아니라 주석으로 안내하는 검증 쿼리)
--
-- [1단계] notifications.kind CHECK 제약에 application_approved 포함 여부 확인
--   SELECT pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.notifications'::regclass
--      AND conname  = 'notifications_kind_check';
--   -- 기대값: CHECK 식에 'application_approved' 포함
--
-- [2단계] 함수 재정의 확인
--   SELECT routine_name, routine_definition
--     FROM information_schema.routines
--    WHERE routine_schema = 'public'
--      AND routine_name   = 'record_application_status_event';
--   -- 기대값: 1 row (v_camp_title 변수가 본문에 있으면 정상)
--
-- [3단계] 기능 검증 — 개발서버에서 pending 상태 신청 1건을 approved 로 변경
--   (개발서버 관리자 페이지에서 임의 신청을 승인하거나
--    SQL Editor에서 직접: UPDATE applications SET status='approved' WHERE id='<UUID>';)
--   이후 아래로 알림 행 확인:
--   SELECT kind, title, body, ref_table, ref_id, created_at
--     FROM notifications
--    WHERE kind = 'application_approved'
--    ORDER BY created_at DESC LIMIT 5;
--   -- 기대값: 방금 승인한 신청의 알림 행 1개
--
-- [4단계] 중복 방지 검증 — 같은 신청을 되돌리기(pending) 후 재승인
--   -- 1) 방금 승인된 신청을 pending 으로 되돌리기
--   UPDATE applications SET status='pending' WHERE id='<위와 같은 UUID>';
--   -- 2) 다시 approved 로
--   UPDATE applications SET status='approved' WHERE id='<같은 UUID>';
--   -- 3) 알림 건수 확인 (미읽음 상태이므로 여전히 1건이어야 함)
--   SELECT COUNT(*) FROM notifications
--    WHERE kind='application_approved' AND ref_id='<같은 UUID>' AND read_at IS NULL;
--   -- 기대값: 1 (중복 INSERT 없음)
-- ============================================================


-- ============================================================
-- §롤백 — 문제 발생 시 131 버전으로 복원
--
-- BEGIN;
--
-- -- (1) 함수를 131 버전(승인 알림 없는 버전)으로 복원
-- CREATE OR REPLACE FUNCTION public.record_application_status_event()
--   RETURNS trigger
--   LANGUAGE plpgsql
--   SECURITY DEFINER
--   SET search_path = ''
-- AS $rollback$
-- DECLARE
--   v_action      text;
--   v_admin_name  text;
-- BEGIN
--   IF OLD.status = NEW.status THEN RETURN NEW; END IF;
--   v_action := CASE
--     WHEN OLD.status = 'pending'                AND NEW.status = 'approved' THEN 'approve'
--     WHEN OLD.status = 'pending'                AND NEW.status = 'rejected' THEN 'reject'
--     WHEN OLD.status IN ('approved','rejected') AND NEW.status = 'pending'  THEN 'revert_to_pending'
--     WHEN OLD.status = 'approved'               AND NEW.status = 'rejected' THEN 'reject'
--     WHEN OLD.status = 'rejected'               AND NEW.status = 'approved' THEN 'approve'
--     ELSE NULL
--   END;
--   IF v_action IS NULL THEN RETURN NEW; END IF;
--   SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = auth.uid();
--   INSERT INTO public.application_events (
--     application_id, action, from_status, to_status, changed_by, changed_by_name, memo
--   ) VALUES (
--     NEW.id, v_action, OLD.status, NEW.status, auth.uid(), v_admin_name, NULL
--   );
--   RETURN NEW;
-- END;
-- $rollback$;
--
-- -- (2) notifications.kind CHECK 제약을 145 버전(application_approved 없는 버전)으로 복원
-- ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
-- ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--   'deliverable_rejected',
--   'deliverable_changed',
--   'deliverable_approved',
--   'application_cancelled',
--   'message_received'
-- ));
--
-- COMMIT;
-- ============================================================
