-- ============================================================
-- 253_receipt_edit_history_cascade_to_set_null.sql
-- 감사 후속 작업 묶음 3 — 영수증 수정 이력 보존 PR (2/2, 외래 키 재정의 + 계정삭제 분기)
-- 사양서: docs/specs/2026-07-22-audit-followup-consistency-fixes.md §작업 묶음 3
-- 전제: 252(스냅샷 컬럼 + deliverable_id nullable 전환)가 먼저 적용돼 있어야 함.
--
-- 변경 1 — receipt_edit_history.deliverable_id 외래 키: CASCADE → SET NULL
--   결과물 하드 삭제 경로 3종(admin_proxy_revoke=160, delete_legacy_review_image=162,
--   delete_mismatched_post_deliverable=183)이 deliverables 행을 DELETE 해도
--   receipt_edit_history 행은 더 이상 함께 삭제되지 않고, deliverable_id 만 NULL 로
--   비워진 채 남는다. 252 의 스냅샷 컬럼(deliverable_id_snapshot 등)이 "어떤
--   결과물이었는지"를 계속 식별 가능하게 해 준다.
--   ⚠️ deliverable_events(카트에 담긴 결과물 자체 상태변경 이력) 는 이번 범위 밖 —
--      여전히 CASCADE 다(217 파일 주석에 명시된 기존 한계, 이번엔 손대지 않음).
--
-- 변경 2 — delete_admin_completely(031): 경로별 정책 분기 (planner 반대론자 지적 ②)
--   계정 완전 삭제(개인정보 파기 목적)는 "이력 보존"이 오히려 파기 의무와
--   상충할 수 있다. 결과물 개별 하드 삭제(대리 등록 회수 등, 위 3종 RPC)는
--   "그 결과물 자체가 문제라서 지우는 것"이지 그 사람의 개인정보를 지우려는
--   목적이 아니므로 이력 보존(SET NULL)이 맞다. 반면 delete_admin_completely 는
--   계정 자체와 그 사람에 관한 모든 데이터를 지우는 것이 목적이므로, 이 경로에서는
--   receipt_edit_history 를 SET NULL 로 잔존시키지 않고 user_id_snapshot 기준으로
--   명시적으로 DELETE 한다(개인정보 파기 우선).
--
--   정산 차단(251)과의 순서 확인(반대론자 지적 ④):
--     이 함수는 맨 앞에서 applications 를 먼저 DELETE 한다. 그 대상 인플루언서에게
--     정산(settlements)이 하나라도 있으면 251 의 트리거가 그 시점에 바로 예외를
--     던져 함수 전체가 중단된다 — 즉 정산이 있는 계정은 이 receipt_edit_history
--     삭제 줄까지 절대 도달하지 않는다(정합 확인 완료, 충돌 없음). 이 줄이
--     실행되는 경우는 항상 "정산 자체가 없는" 계정이므로, 파기 대상 데이터에
--     정산 관련 참조가 남을 걱정도 없다.
--
-- 적용 순서:
--   1. 252 먼저 적용 확인
--   2. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   3. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행 — 1단계씩):
--   -- [1] 외래 키 규칙 확인 (confdeltype = 'n' 이면 SET NULL, 'c'면 여전히 CASCADE)
--   SELECT conname, confdeltype
--     FROM pg_constraint
--    WHERE conrelid = 'public.receipt_edit_history'::regclass
--      AND contype = 'f';
--   -- 기대값: confdeltype = 'n'
--
--   -- [2] 개발 DB에서 영수증 수정 이력이 있는 결과물 하나를 골라
--   --     delete_legacy_review_image 또는 delete_mismatched_post_deliverable 로
--   --     삭제한 뒤(super_admin 세션), 이력 행이 남아있는지 확인:
--   SELECT deliverable_id, deliverable_id_snapshot, changed_at
--     FROM public.receipt_edit_history
--    WHERE deliverable_id_snapshot = '<삭제한 결과물 id>';
--   -- 기대값: 행이 남아있고 deliverable_id 는 NULL, deliverable_id_snapshot 은 값 유지
--
--   -- [3] 함수 정의 갱신 확인(delete_admin_completely 가 receipt_edit_history 를
--   --     명시적으로 지우는 줄을 포함하는지)
--   SELECT prosrc FROM pg_proc WHERE proname = 'delete_admin_completely';
--   -- 기대값: 'DELETE FROM public.receipt_edit_history' 문자열 포함
--
-- 롤백:
--   -- 외래 키를 CASCADE 로 되돌리기
--   DO $$
--   DECLARE v_conname text;
--   BEGIN
--     SELECT conname INTO v_conname FROM pg_constraint
--      WHERE conrelid = 'public.receipt_edit_history'::regclass
--        AND contype = 'f' AND confrelid = 'public.deliverables'::regclass;
--     IF v_conname IS NOT NULL THEN
--       EXECUTE format('ALTER TABLE public.receipt_edit_history DROP CONSTRAINT %I', v_conname);
--     END IF;
--   END $$;
--   ALTER TABLE public.receipt_edit_history
--     ADD CONSTRAINT receipt_edit_history_deliverable_id_fkey
--     FOREIGN KEY (deliverable_id) REFERENCES public.deliverables(id) ON DELETE CASCADE;
--   -- delete_admin_completely 는 031_admin_invite_and_delete.sql 의 원본 CREATE OR REPLACE
--   -- 블록을 재실행해 되돌린다(함수 OID 유지되어 GRANT 재부여 불필요).
-- ============================================================

BEGIN;

-- ============================================================
-- 1. receipt_edit_history.deliverable_id 외래 키: CASCADE → SET NULL
--    (제약 이름을 하드코딩하지 않고 동적으로 찾아 드롭 — 실제 이름이 마이그레이션
--     128 작성 시점의 기본 명명 규칙과 다를 가능성에 대비)
-- ============================================================
DO $$
DECLARE
  v_conname text;
BEGIN
  SELECT conname INTO v_conname
    FROM pg_constraint
   WHERE conrelid = 'public.receipt_edit_history'::regclass
     AND contype = 'f'
     AND confrelid = 'public.deliverables'::regclass;

  IF v_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.receipt_edit_history DROP CONSTRAINT %I', v_conname);
  END IF;
END $$;

ALTER TABLE public.receipt_edit_history
  ADD CONSTRAINT receipt_edit_history_deliverable_id_fkey
  FOREIGN KEY (deliverable_id) REFERENCES public.deliverables(id) ON DELETE SET NULL;

COMMENT ON CONSTRAINT receipt_edit_history_deliverable_id_fkey ON public.receipt_edit_history IS
  '[253] CASCADE(128) → SET NULL 로 재정의. 결과물이 하드 삭제돼도 이 이력 행은 보존하고 '
  'deliverable_id 만 비운다 — 어떤 결과물이었는지는 252 의 deliverable_id_snapshot 로 식별.';

-- ============================================================
-- 2. delete_admin_completely(031) 재정의 — receipt_edit_history 명시적 파기 분기 추가
--    (그 외 로직은 031 원본과 완전히 동일 — 순서·조건 무변경)
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_admin_completely(target_auth_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;
  IF target_auth_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot delete own account';
  END IF;

  -- applications 삭제 시점에 정산(settlements)이 하나라도 있으면 251의
  -- BEFORE DELETE 트리거가 여기서 예외를 던져 함수 전체가 중단된다.
  -- 즉 아래 receipt_edit_history 명시 삭제 줄은 "정산이 전혀 없는 계정"에서만
  -- 실행된다(파일 상단 순서 확인 참고).
  DELETE FROM public.applications WHERE user_id = target_auth_id;

  -- [253] 개인정보 파기 목적 — 결과물 개별 하드삭제(160/162/183)와 달리 계정
  -- 완전삭제는 이력 보존보다 파기 의무가 우선하므로, SET NULL 로 잔존시키지 않고
  -- 이 사람과 관련된 영수증 수정 이력 행 자체를 명시적으로 삭제한다.
  DELETE FROM public.receipt_edit_history WHERE user_id_snapshot = target_auth_id;

  DELETE FROM public.receipts WHERE user_id = target_auth_id;
  DELETE FROM public.admins WHERE auth_id = target_auth_id;
  DELETE FROM public.influencers WHERE id = target_auth_id;
  DELETE FROM auth.identities WHERE user_id = target_auth_id;
  DELETE FROM auth.users WHERE id = target_auth_id;
END;
$$;

COMMENT ON FUNCTION public.delete_admin_completely(uuid) IS
  '[031, 253 개정] 관리자/인플루언서 계정 완전 삭제. 정산(settlements)이 있으면 251 트리거가 '
  'applications 삭제 단계에서 차단(개인정보 파기보다 정산 감사 보존 우선). 정산이 없으면 '
  'receipt_edit_history 도 SET NULL 로 남기지 않고 명시적으로 함께 삭제(개인정보 파기 우선, '
  '결과물 개별 하드삭제 경로와의 차이는 253 파일 상단 설명 참고).';

REVOKE ALL ON FUNCTION public.delete_admin_completely(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_admin_completely(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
