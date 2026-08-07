-- ============================================================
-- 252_receipt_edit_history_snapshot_columns.sql
-- 감사 후속 작업 묶음 3 — 영수증 수정 이력 보존 PR (1/2, 스냅샷 컬럼 + nullable 전환)
-- 사양서: docs/specs/2026-07-22-audit-followup-consistency-fixes.md §작업 묶음 3
--
-- 문제:
--   receipt_edit_history.deliverable_id(마이그레이션 128)가 deliverables 를
--   ON DELETE CASCADE 로 참조한다. 결과물 하드 삭제 경로(admin_proxy_revoke=160,
--   delete_legacy_review_image=162, delete_mismatched_post_deliverable=183) 는
--   전부 deliverables 행을 직접 DELETE 하므로, 관리자가 남긴 영수증 수정 이력이
--   결과물과 함께 통째로 사라진다 — "관리자가 언제 무엇을 고쳤는지"의 감사 기록이
--   결과물 정리(주로 잘못 등록된 데이터 정리 목적) 부수 효과로 유실되는 구조.
--
-- 확정 방향(b) — 이력 보존 + 스냅샷 보강:
--   결과물이 삭제돼도 receipt_edit_history 행 자체는 남긴다. 다음 마이그레이션(253)
--   에서 외래 키를 CASCADE→SET NULL 로 바꾸므로, 이 마이그레이션에서 먼저
--   ① deliverable_id 를 nullable 로 전환하고 ② "이 이력이 어떤 결과물/응모/캠페인/
--   인플루언서 소속이었는지"를 영구히 남길 스냅샷 컬럼 4종을 추가한다.
--   (deliverable_id 가 SET NULL 로 비워진 뒤에도 스냅샷 컬럼은 절대 지워지지 않음 —
--   BEFORE INSERT 트리거가 1회만 기록하고 이후 이 행에 대해 다시는 안 건드림.)
--
-- 스냅샷 컬럼 4종 선택 근거:
--   deliverables 테이블 자체가 갖는 3개 연관 관계 컬럼(application_id·campaign_id·
--   user_id, 마이그레이션 035) + 결과물 자신의 id. 이 4개면 결과물이 사라진 뒤에도
--   "어느 응모·어느 캠페인·어느 인플루언서의 무슨 결과물이었는지"를 전부 복원 가능
--   (deliverables.kind·receipt_url 등 세부 필드까지는 스냅샷하지 않음 — 이 테이블은
--   원래 "주문번호·구매일·구매금액 변경 이력"만 다루던 감사 테이블이라 범위를
--   최소로 유지. 세부 필드가 더 필요해지면 별도 후속 마이그레이션에서 판단).
--
-- 컬럼별 nullable 여부:
--   deliverable_id_snapshot uuid NOT NULL — 트리거가 항상 채우므로 NOT NULL 로
--     강제해도 안전(신규 행 기준). 기존 행은 백필 후 NOT NULL 전환.
--   application_id_snapshot / campaign_id_snapshot / user_id_snapshot uuid NULL —
--     deliverables 조회 시점에 이론상 못 찾을 극단적 경우(트리거 타이밍 이슈 등)를
--     대비해 NULL 허용. FK 는 걸지 않음(informational 스냅샷일 뿐 — 이 컬럼들이
--     참조하는 applications/campaigns/influencers 는 이 정산 이력과 무관하게
--     독립적으로 삭제될 수 있어야 하므로, 여기 FK 를 걸면 오히려 새로운 삭제
--     차단 지점을 만들게 됨. 작업 묶음 2 의 settlements 체크와는 성격이 다르다 —
--     거긴 "정산 자체를 못 찾게 되는" 문제였고, 여긴 "이력에 참고용 배지"일 뿐).
--
-- BEFORE INSERT 트리거로 자동 채우는 이유(update_receipt_admin RPC 무변경):
--   update_receipt_admin(마이그레이션 128)의 INSERT 문을 직접 고치지 않아도,
--   트리거가 NEW.deliverable_id 로부터 나머지 3개를 조회해 자동으로 채운다.
--   RPC 코드는 그대로 두고 스냅샷 로직만 트리거 한 곳에 모아 유지보수 지점을 줄임.
--
-- 기존 행 백필:
--   이 마이그레이션 시점까지 receipt_edit_history 의 모든 행은 100% 유효한
--   deliverable_id 를 갖는다 — 지금까지는 CASCADE 였으므로, 결과물이 하드 삭제될
--   때 이력 행도 "NULL 로 남는" 게 아니라 "행 자체가 함께 삭제"됐기 때문에 고아
--   행(deliverable_id 가 가리키는 대상이 없는 행)이 존재할 수 없다. 따라서 전체
--   행을 deliverables JOIN 으로 안전하게 백필한다.
--
-- 적용 순서 (이 마이그레이션 → 253):
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--   3. 253 은 반드시 이 마이그레이션 이후에 적용(nullable 전환이 먼저 있어야
--      SET NULL 로 실제 NULL 이 들어갈 수 있음)
--
-- 검증 쿼리 (적용 후 실행 — 1단계씩):
--   -- [1] 컬럼 추가 확인
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='receipt_edit_history'
--    ORDER BY ordinal_position;
--   -- 기대값: deliverable_id 가 is_nullable='YES' 로 바뀌고, 4개 스냅샷 컬럼 추가됨
--
--   -- [2] 백필 결과 확인 — 스냅샷이 NULL 인 행이 있는지(있으면 안 됨, 기존 행 전수 백필 대상)
--   SELECT count(*) FROM public.receipt_edit_history WHERE deliverable_id_snapshot IS NULL;
--   -- 기대값: 0
--
--   -- [3] 트리거 생성 확인
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid = 'public.receipt_edit_history'::regclass
--      AND tgname = 'trg_receipt_edit_history_snapshot';
--   -- 기대값: 1 row
--
--   -- [4] 신규 INSERT 시 스냅샷 자동 채움 확인 — update_receipt_admin 을 실제
--   --     호출한 뒤(관리자 화면에서 영수증 하나 수정) 최근 이력 조회:
--   SELECT deliverable_id, deliverable_id_snapshot, application_id_snapshot,
--          campaign_id_snapshot, user_id_snapshot
--     FROM public.receipt_edit_history ORDER BY changed_at DESC LIMIT 1;
--   -- 기대값: deliverable_id_snapshot = deliverable_id, 나머지 3개도 NULL 아님
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_receipt_edit_history_snapshot ON public.receipt_edit_history;
--   DROP FUNCTION IF EXISTS public.snapshot_receipt_edit_history();
--   ALTER TABLE public.receipt_edit_history DROP COLUMN IF EXISTS deliverable_id_snapshot;
--   ALTER TABLE public.receipt_edit_history DROP COLUMN IF EXISTS application_id_snapshot;
--   ALTER TABLE public.receipt_edit_history DROP COLUMN IF EXISTS campaign_id_snapshot;
--   ALTER TABLE public.receipt_edit_history DROP COLUMN IF EXISTS user_id_snapshot;
--   ALTER TABLE public.receipt_edit_history ALTER COLUMN deliverable_id SET NOT NULL;
--   -- (마지막 줄은 253 이 먼저 적용돼 실제 NULL 행이 생겼다면 실패한다 — 그 경우
--   --  253 부터 먼저 롤백할 것)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 컬럼 추가 (스냅샷 4종 + deliverable_id nullable 전환)
-- ============================================================
ALTER TABLE public.receipt_edit_history
  ADD COLUMN IF NOT EXISTS deliverable_id_snapshot  uuid NULL,
  ADD COLUMN IF NOT EXISTS application_id_snapshot  uuid NULL,
  ADD COLUMN IF NOT EXISTS campaign_id_snapshot     uuid NULL,
  ADD COLUMN IF NOT EXISTS user_id_snapshot         uuid NULL;

COMMENT ON COLUMN public.receipt_edit_history.deliverable_id_snapshot IS
  '[252] deliverable_id 의 영구 스냅샷. 결과물이 삭제돼 deliverable_id 가 SET NULL(253) '
  '되어도 이 값은 남아 "어떤 결과물이었는지"를 식별할 수 있게 한다.';
COMMENT ON COLUMN public.receipt_edit_history.application_id_snapshot IS
  '[252] 수정 시점 deliverables.application_id 스냅샷. FK 없음(정보용) — 응모가 '
  '독립적으로 삭제돼도 이 이력 보존에 영향 없어야 하므로.';
COMMENT ON COLUMN public.receipt_edit_history.campaign_id_snapshot IS
  '[252] 수정 시점 deliverables.campaign_id 스냅샷. FK 없음(정보용).';
COMMENT ON COLUMN public.receipt_edit_history.user_id_snapshot IS
  '[252] 수정 시점 deliverables.user_id(인플루언서) 스냅샷. FK 없음(정보용). '
  '계정 완전 삭제(delete_admin_completely) 시 개인정보 파기 목적으로 이 값 기준 '
  '별도 DELETE 처리(마이그레이션 253 delete_admin_completely 개정 참고).';

ALTER TABLE public.receipt_edit_history
  ALTER COLUMN deliverable_id DROP NOT NULL;

-- ============================================================
-- 2. 기존 행 백필 (전체 — 이 시점까지는 100% 유효한 deliverable_id 를 가짐)
-- ============================================================
UPDATE public.receipt_edit_history reh
   SET deliverable_id_snapshot = reh.deliverable_id,
       application_id_snapshot = d.application_id,
       campaign_id_snapshot    = d.campaign_id,
       user_id_snapshot        = d.user_id
  FROM public.deliverables d
 WHERE d.id = reh.deliverable_id
   AND reh.deliverable_id_snapshot IS NULL;

-- 백필 후 deliverable_id_snapshot 은 NOT NULL 로 강제(신규 행은 트리거가 항상 채움)
ALTER TABLE public.receipt_edit_history
  ALTER COLUMN deliverable_id_snapshot SET NOT NULL;

-- ============================================================
-- 3. BEFORE INSERT 트리거 — 신규 이력 행에 스냅샷 자동 채움
--    (update_receipt_admin RPC 는 무변경 — 트리거가 투명하게 처리)
-- ============================================================
CREATE OR REPLACE FUNCTION public.snapshot_receipt_edit_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_deliverable record;
BEGIN
  NEW.deliverable_id_snapshot := NEW.deliverable_id;

  IF NEW.deliverable_id IS NOT NULL THEN
    SELECT application_id, campaign_id, user_id
      INTO v_deliverable
      FROM public.deliverables
     WHERE id = NEW.deliverable_id;

    IF FOUND THEN
      NEW.application_id_snapshot := v_deliverable.application_id;
      NEW.campaign_id_snapshot    := v_deliverable.campaign_id;
      NEW.user_id_snapshot        := v_deliverable.user_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.snapshot_receipt_edit_history() IS
  '[252] receipt_edit_history INSERT 시 deliverable_id 로부터 application_id/campaign_id/'
  'user_id 스냅샷을 자동 채움. update_receipt_admin(128) RPC 무변경 — 트리거가 투명 처리.';

DROP TRIGGER IF EXISTS trg_receipt_edit_history_snapshot ON public.receipt_edit_history;
CREATE TRIGGER trg_receipt_edit_history_snapshot
  BEFORE INSERT ON public.receipt_edit_history
  FOR EACH ROW
  EXECUTE FUNCTION public.snapshot_receipt_edit_history();

-- ============================================================
-- 4. 조회 인덱스 — 결과물 삭제 후에도 스냅샷 id 로 이력 조회 가능하도록
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_receipt_edit_history_deliverable_snapshot
  ON public.receipt_edit_history (deliverable_id_snapshot, changed_at DESC);

NOTIFY pgrst, 'reload schema';

COMMIT;
