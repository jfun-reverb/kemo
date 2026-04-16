-- ============================================================
-- migration: 044_notifications_delete_own
-- purpose  : 본인 알림 DELETE 정책 추가 — 참조 결과물 삭제 등으로
--            연결이 끊긴 알림을 목록에서 제거 가능하게 함
--
-- rollback:
--   DROP POLICY "notifications_delete_own" ON notifications;
-- ============================================================

CREATE POLICY "notifications_delete_own"
  ON notifications FOR DELETE
  USING (auth.uid() = user_id);
