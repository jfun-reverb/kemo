-- ============================================================
-- 255_soft_delete_campaign_fn.sql
-- 캠페인 삭제 복구(soft delete) PR 1 — 2/5 (보관 삭제 RPC)
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md §설계 ②
--
-- soft_delete_campaign(p_campaign_id) — 관리자가 캠페인을 "삭제"할 때 호출할 RPC.
-- dev/lib/storage.js 의 softDeleteCampaign() 이 이 시그니처(p_campaign_id uuid,
-- RETURNS integer = 삭제된 신청 건수)로 이미 대응돼 있다.
--
-- 동작 요약:
--   1. is_campaign_admin() 가드 (campaign_manager 는 42501)
--   2. 캠페인 존재·미삭제(deleted_at IS NULL) 확인 (FOR UPDATE 행 잠금)
--   3. 개인정보 즉시 파기 — 이 캠페인의 applications 를 완전 DELETE.
--      deliverables.application_id ON DELETE CASCADE(마이그레이션 035) 이므로
--      결과물도 자동으로 함께 삭제됨. 현행 dev/js/admin.js executeDeleteCampaign()
--      의 삭제 범위(신청+결과물 완전 삭제)를 그대로 재현 — Storage 파일(영수증
--      이미지 등)은 현행도 지우지 않으므로 이번에도 지우지 않는다(범위 밖, 사양서
--      §의심 확인 완료).
--   4. campaigns.deleted_at = now(), deleted_by = auth.uid() 세팅 (행은 삭제하지 않음)
--
-- 정산(settlements) 방어 — 트리거 위임(단일 소스, 251 파일 참고):
--   위 3번 DELETE FROM applications 실행 시, 마이그레이션 251 의
--   block_delete_with_settlements 트리거가 BEFORE DELETE 로 먼저 실행된다.
--   이 캠페인의 신청 중 정산(settlements)이 걸린 행이 하나라도 있으면 그 트리거가
--   'settlement_exists_cannot_delete' 예외를 던지고, PL/pgSQL 함수 전체가 암묵적
--   트랜잭션이라 이 함수 호출 자체가 그대로 실패로 끝난다 — 4번(deleted_at 세팅)
--   까지 도달하지 못하므로 "정산 걸린 캠페인은 삭제 자체가 안 됨"이 원자적으로
--   보장된다. 이 함수 안에 별도로 정산 존재 여부를 재확인하는 코드를 넣지 않는
--   이유 — 251 트리거가 이미 유일한 판정 소스이고, 중복 판정 로직을 여기 또
--   두면 나중에 251 정책이 바뀔 때 두 곳을 함께 고쳐야 하는 drift 위험이 생긴다.
--
-- 이미 삭제(보관) 처리된 캠페인 재호출:
--   deleted_at IS NOT NULL 이면 'campaign_already_deleted' 예외. 이미 신청이
--   전부 삭제된 상태에서 재호출해도 실질 피해는 없지만(재삭제할 신청이 없음),
--   "삭제됨" 상태에서 다시 삭제 버튼이 눌리는 것은 화면 흐름상 비정상이므로
--   막아서 원인을 명확히 한다.
--
-- 권한: is_campaign_admin() — super_admin·campaign_admin 만 (campaign_manager 차단,
--   기존 executeDeleteCampaign() 의 "campaign_manager 는 삭제 버튼 자체가 비활성"
--   과 동일 등급, admin.js:1951 deleteCampaign() 참고).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.soft_delete_campaign(p_campaign_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign      record;
  v_deleted_apps  integer;
BEGIN
  -- ── 권한 가드 ────────────────────────────────────────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION 'permission_denied: 캠페인 삭제 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, deleted_at INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다 (id: %)', p_campaign_id USING ERRCODE = '02000';
  END IF;

  IF v_campaign.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'campaign_already_deleted: 이미 삭제(보관) 처리된 캠페인입니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── 개인정보 즉시 파기 ────────────────────────────────────────
  -- 정산이 걸린 신청이 있으면 251 트리거가 여기서 예외를 던져 함수 전체가 실패한다
  -- (위 주석 "정산 방어 — 트리거 위임" 참고).
  DELETE FROM public.applications WHERE campaign_id = p_campaign_id;
  GET DIAGNOSTICS v_deleted_apps = ROW_COUNT;

  -- ── 캠페인 행은 유지, deleted_at 만 세팅(30일 보관 시작) ──────────
  UPDATE public.campaigns
     SET deleted_at = now(),
         deleted_by = auth.uid()
   WHERE id = p_campaign_id;

  RETURN v_deleted_apps;
END;
$$;

COMMENT ON FUNCTION public.soft_delete_campaign(uuid) IS
  '[255] 캠페인 보관 삭제(soft delete). is_campaign_admin() 가드. 이 캠페인의 '
  'applications(+cascade deliverables)를 즉시 완전 삭제(개인정보 즉시 파기)하고 '
  'campaigns.deleted_at/deleted_by 만 세팅해 행은 보존(30일 후 자동 완전삭제, '
  'purge_expired_deleted_campaigns 258). 정산 걸린 신청이 있으면 251 트리거가 '
  '예외를 던져 원자적으로 전체 실패. 반환값=삭제된 신청 건수.';

REVOKE ALL ON FUNCTION public.soft_delete_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.soft_delete_campaign(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'soft_delete_campaign';

-- [V1] 스모크 대상 확보 — 신청 1~2건 딸린 draft/scheduled 캠페인(정산 없는 것) 1건
SELECT c.id, c.title, c.status, c.deleted_at,
       (SELECT count(*) FROM public.applications a WHERE a.campaign_id = c.id) AS app_count
  FROM public.campaigns c
 WHERE c.deleted_at IS NULL
 ORDER BY app_count ASC
 LIMIT 5;

-- [V2] 스모크 호출 (앱에서 campaign_admin 로그인 세션으로 — SQL Editor 직접 실행은
--   auth.uid() 가 NULL 이라 is_campaign_admin() 도 false 로 판정돼 permission_denied
--   로 막힐 수 있음, 정상 동작. 실제 검증은 개발서버 관리자 화면 콘솔에서 권장)
-- SELECT public.soft_delete_campaign('<위 id>'::uuid);

-- [V3] 처리 후 확인 — deleted_at/deleted_by 세팅, applications 0건
SELECT id, title, status, deleted_at, deleted_by FROM public.campaigns WHERE id = '<위 id>';
SELECT count(*) FROM public.applications WHERE campaign_id = '<위 id>';
-- 기대값: deleted_at NOT NULL, applications count = 0

-- [V4] 재호출 시 예외 확인 (이미 삭제된 캠페인)
-- SELECT public.soft_delete_campaign('<위 id>'::uuid);
-- 기대값: ERROR — campaign_already_deleted

-- [V5] 정산 걸린 신청이 있는 캠페인으로 호출 시 차단 확인(정산 테스트 데이터가 있는 경우만)
-- SELECT public.soft_delete_campaign('<정산 걸린 캠페인 id>'::uuid);
-- 기대값: ERROR — settlement_exists_cannot_delete (251 트리거), campaigns.deleted_at 여전히 NULL

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.soft_delete_campaign(uuid);
