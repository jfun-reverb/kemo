-- ============================================================
-- 257_purge_campaign_fn.sql
-- 캠페인 삭제 복구(soft delete) PR 1 — 4/5 (수동 완전 삭제 RPC)
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md §설계 ④
--
-- purge_campaign(p_campaign_id) — 「삭제됨」 탭(PR 2)에서 super_admin 이
-- "완전 삭제"(30일을 기다리지 않고 즉시)를 누를 때 호출할 RPC.
-- dev/lib/storage.js 의 purgeCampaign() 이 이 시그니처(p_campaign_id uuid,
-- RETURNS boolean)로 대응돼 있다.
--
-- 동작:
--   1. is_super_admin() 가드 — 완전 삭제는 되돌릴 수 없는 최종 동작이라
--      보관삭제·복구(campaign_admin)보다 한 단계 높은 권한 요구(사양서 결정표).
--   2. 대상 행 잠금 조회
--   3. deleted_at IS NULL(아직 보관 처리 안 된 활성 캠페인)이면 예외 —
--      "활성 캠페인을 실수로 완전삭제" 사고를 서버가 원천 차단. 반드시 먼저
--      soft_delete_campaign(255)으로 보관 상태를 거쳐야 완전삭제할 수 있다.
--   4. campaigns 행 hard DELETE
--
-- 정산 방어(안전망, 실제로는 도달할 일이 거의 없음):
--   이 캠페인이 soft_delete_campaign(255)을 이미 거쳤다는 것은, 그 시점에 이
--   캠페인의 신청 중 정산이 걸린 건이 없었다는 뜻이다(있었다면 251 트리거가
--   막아 애초에 deleted_at 이 세팅되지 못했을 것). 따라서 이 시점엔 이 캠페인에
--   연결된 settlements 가 존재할 수 없다 — 그래도 251 의 campaigns 트리거가
--   이중 방어로 걸려 있으므로 별도 재확인 코드는 넣지 않는다(트리거 위임,
--   soft_delete_campaign 주석과 동일한 이유).
--
-- 이 함수가 카운트다운(30일)을 앞당기는 유일한 수동 경로다 — 자동 완전삭제는
-- purge_expired_deleted_campaigns(258, pg_cron)가 담당.
--
-- 권한: is_super_admin() (사양서 결정표 "완전삭제=super_admin").
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_campaign(p_campaign_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign record;
BEGIN
  -- ── 권한 가드 ────────────────────────────────────────────────
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'permission_denied: 캠페인 완전 삭제는 최고 관리자만 가능합니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, deleted_at INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다 (id: %)', p_campaign_id USING ERRCODE = '02000';
  END IF;

  -- ── 활성 캠페인 완전삭제 차단 ─────────────────────────────────
  IF v_campaign.deleted_at IS NULL THEN
    RAISE EXCEPTION 'campaign_not_archived: 보관(삭제) 상태의 캠페인만 완전 삭제할 수 있습니다. 먼저 삭제 처리해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  -- ── 완전 삭제 ────────────────────────────────────────────────
  DELETE FROM public.campaigns WHERE id = p_campaign_id;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.purge_campaign(uuid) IS
  '[257] 보관(삭제) 상태 캠페인의 수동 완전 삭제(30일을 기다리지 않고 즉시). '
  'is_super_admin() 가드. deleted_at IS NULL(아직 보관 처리 안 된 활성 캠페인)이면 '
  '예외로 차단. 신청·결과물은 soft_delete_campaign(255) 시점에 이미 파기됨.';

REVOKE ALL ON FUNCTION public.purge_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_campaign(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'purge_campaign';

-- [V1] 활성 캠페인(deleted_at NULL)으로 호출 시 차단 확인
--   (앱 super_admin 세션 콘솔 권장 — SQL Editor 직접 실행은 auth.uid() NULL 이라
--    permission_denied 가 먼저 발생할 수 있음, 정상)
-- SELECT public.purge_campaign('<활성 캠페인 id>'::uuid);
-- 기대값: ERROR — campaign_not_archived

-- [V2] soft_delete_campaign(255)로 보관 처리한 테스트 캠페인으로 완전삭제 스모크
-- SELECT public.purge_campaign('<보관 중인 테스트 캠페인 id>'::uuid);
-- 기대값: true

-- [V3] 완전삭제 후 행 자체가 없는지 확인
SELECT count(*) FROM public.campaigns WHERE id = '<위 id>';
-- 기대값: 0

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.purge_campaign(uuid);
