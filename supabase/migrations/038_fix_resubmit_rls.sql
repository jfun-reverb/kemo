-- ============================================================
-- migration: 038_fix_resubmit_rls
-- purpose  : 인플루언서 재제출 시 rejected → pending 변경 허용
--            기존 RLS는 status='pending' 행만 UPDATE 허용 →
--            rejected 행 재제출 불가 버그 수정
--
-- rollback:
--   DROP POLICY IF EXISTS "deliverables_update_own_rejected" ON deliverables;
-- ============================================================

-- rejected 상태 행도 본인이 pending으로 되돌릴 수 있는 정책
CREATE POLICY "deliverables_update_own_rejected"
  ON deliverables FOR UPDATE
  USING (auth.uid() = user_id AND status = 'rejected')
  WITH CHECK (auth.uid() = user_id AND status = 'pending');
