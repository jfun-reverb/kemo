-- ============================================================
-- migration: 042_deliverable_draft_flow
-- purpose  : 인플루언서 제출 플로우 도입 (draft → 제출 → pending)
--            - status CHECK에 'draft' 추가
--            - 본인이 draft 상태 행을 DELETE 가능
--            - 본인이 draft → pending UPDATE 가능 (제출)
--            - 관리자 SELECT·알림 트리거는 draft 제외
--
-- 사용 흐름:
--   1) 인플루언서가 URL/이미지 등록 → INSERT status='draft'
--   2) 필요시 draft 삭제/수정
--   3) "제출" 버튼 → 해당 application의 draft 전부 → status='pending'
--   4) 관리자 검수 (pending/approved/rejected)
--
-- rollback:
--   DROP POLICY "deliverables_delete_own_draft" ON deliverables;
--   DROP POLICY "deliverables_submit_own_draft" ON deliverables;
--   -- status CHECK 원복 별도 수행
-- ============================================================

-- status CHECK에 draft 추가
ALTER TABLE deliverables DROP CONSTRAINT IF EXISTS deliverables_status_check;
ALTER TABLE deliverables ADD CONSTRAINT deliverables_status_check
  CHECK (status IN ('draft', 'pending', 'approved', 'rejected'));

-- 인플루언서 INSERT 정책 확장 — draft 또는 pending으로 생성 가능
DROP POLICY IF EXISTS "deliverables_insert_own" ON deliverables;
CREATE POLICY "deliverables_insert_own"
  ON deliverables FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND status IN ('draft', 'pending')
  );

-- 인플루언서 UPDATE 정책 확장 — draft 상태에서 draft/pending으로만 전환 가능
DROP POLICY IF EXISTS "deliverables_update_own_pending" ON deliverables;
CREATE POLICY "deliverables_update_own_draft_or_pending"
  ON deliverables FOR UPDATE
  USING (auth.uid() = user_id AND status IN ('draft', 'pending'))
  WITH CHECK (
    auth.uid() = user_id
    AND status IN ('draft', 'pending')
  );

-- 인플루언서 DELETE 정책 — 본인 draft 행만 삭제 가능
DROP POLICY IF EXISTS "deliverables_delete_own_draft" ON deliverables;
CREATE POLICY "deliverables_delete_own_draft"
  ON deliverables FOR DELETE
  USING (auth.uid() = user_id AND status = 'draft');

-- 관리자 SELECT에서 draft 제외는 코드(fetchDeliverables)에서 처리
-- (RLS 단에서 막으면 관리자 디버깅 어려움 — 정책 유지, 쿼리 필터만 사용)

-- 알림 트리거: draft↔pending/rejected→approved 등 기존 로직은 유지
-- draft → pending 전환 시 상태가 "pending으로 새로 들어오는" 셈이지만
-- notify_deliverable_status는 OLD.status != NEW.status 중 특정 전이만 INSERT하므로
-- draft→pending은 어떤 분기도 타지 않아 알림 생성 안 함. 정상.

COMMENT ON CONSTRAINT deliverables_status_check ON deliverables IS
  'draft: 인플루언서 작성 중. pending: 관리자 검수 대기. approved/rejected: 검수 완료.';
