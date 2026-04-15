-- ============================================================
-- migration: 037_create_notifications
-- purpose  : 결과물 관리 Stage 6 — 인플루언서 알림 테이블
--            - 반려(rejected) / 결과 변경(approved → 다른 상태 등) 시
--              트리거로 자동 알림 행 생성
--            - 읽음(read_at) 처리는 클라이언트에서 UPDATE
--            - 재제출(rejected → pending) 시 관련 미읽음 알림 자동 dismiss
--
-- rollback:
--   DROP TRIGGER IF EXISTS trg_deliverable_notify ON deliverables;
--   DROP FUNCTION IF EXISTS public.notify_deliverable_status();
--   DROP TABLE IF EXISTS notifications CASCADE;
-- ============================================================

CREATE TABLE IF NOT EXISTS notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN (
                'deliverable_rejected',  -- 결과물 반려
                'deliverable_changed',   -- 결과 변경 (되돌리기 등)
                'deliverable_approved'   -- 승인 (옵션, Stage 6+α)
              )),
  ref_table   text,
  ref_id      uuid,
  title       text NOT NULL,
  body        text,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON notifications(user_id, created_at DESC) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_ref
  ON notifications(ref_table, ref_id);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- 본인 알림만 조회·수정 가능 (read_at 업데이트용)
CREATE POLICY "notifications_select_own"
  ON notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "notifications_update_own"
  ON notifications FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 관리자 조회 (운영 디버깅용)
CREATE POLICY "notifications_select_admin"
  ON notifications FOR SELECT
  USING (is_admin());

-- INSERT는 SECURITY DEFINER 트리거에서만


-- ============================================================
-- 트리거: deliverables.status 변경 시 알림 자동 생성
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_deliverable_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_camp_title text;
BEGIN
  -- 상태가 변하지 않으면 skip
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 캠페인명 조회
  SELECT title INTO v_camp_title FROM public.campaigns WHERE id = NEW.campaign_id;

  -- ① 반려 알림 (pending → rejected, 또는 approved → rejected)
  IF NEW.status = 'rejected' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_rejected',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, '캠페인') || ' — 成果物が差し戻されました',
      NEW.reject_reason
    );

  -- ② 결과 변경 알림 (approved → pending 되돌리기 / approved → rejected)
  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_changed',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, '캠페인') || ' — 審査結果が変更されました',
      '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
    );

  -- ③ 재제출(rejected → pending)일 때: 해당 deliverable의 미읽음 반려 알림 dismiss
  ELSIF OLD.status = 'rejected' AND NEW.status = 'pending' THEN
    UPDATE public.notifications
       SET read_at = now()
     WHERE user_id = NEW.user_id
       AND ref_table = 'deliverables'
       AND ref_id = NEW.id
       AND read_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliverable_notify ON deliverables;
CREATE TRIGGER trg_deliverable_notify
  AFTER UPDATE ON deliverables
  FOR EACH ROW EXECUTE FUNCTION public.notify_deliverable_status();

COMMENT ON FUNCTION public.notify_deliverable_status IS
  'Stage 6: deliverables.status 전이에 따라 notifications 자동 생성·dismiss.';
