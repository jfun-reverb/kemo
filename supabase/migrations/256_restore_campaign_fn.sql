-- ============================================================
-- 256_restore_campaign_fn.sql
-- 캠페인 삭제 복구(soft delete) PR 1 — 3/5 (복구 RPC)
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md §설계 ③
--
-- restore_campaign(p_campaign_id) — 「삭제됨」 탭(PR 2)에서 관리자가 "복구"를
-- 누를 때 호출할 RPC. dev/lib/storage.js 의 restoreCampaign() 이 이 시그니처
-- (p_campaign_id uuid, RETURNS boolean = 실제로 복구됐는지)로 대응돼 있다.
--
-- 동작:
--   1. is_campaign_admin() 가드
--   2. 대상 행 잠금 조회
--   3. 이미 활성(deleted_at IS NULL)이면 아무것도 하지 않고 false 반환 — 멱등
--      (사양서 §설계 ③ "이미 활성이면 멱등"). 화면에서 중복 클릭·경쟁 상태로
--      두 번 눌려도 두 번째 호출이 에러 없이 조용히 무시됨.
--   4. deleted_at/deleted_by 를 NULL 로 되돌리고 true 반환
--
-- 복구되지 않는 것 (사양서 §의심 1 — 반드시 PR 2 확인 문구에 반영):
--   이 캠페인의 신청(applications)·결과물(deliverables)은 soft_delete_campaign(255)
--   시점에 이미 완전 삭제됐으므로 복구해도 되돌아오지 않는다. 복구되는 것은
--   campaigns 행(제목·설정 등 메타데이터)뿐이다. status 컬럼도 삭제 당시 값 그대로
--   보존되며(직교 컬럼이라 이 함수가 건드리지 않음), 필요하면 화면이
--   computeCampaignStatus() 로 재계산한다(이 함수 책임 아님).
--
-- 권한: is_campaign_admin() — soft_delete_campaign(255)과 동일 등급
--   (사양서 §설계 결정표 "보관삭제·복구=campaign_admin").
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.restore_campaign(p_campaign_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign record;
BEGIN
  -- ── 권한 가드 ────────────────────────────────────────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION 'permission_denied: 캠페인 복구 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, deleted_at INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다 (id: %)', p_campaign_id USING ERRCODE = '02000';
  END IF;

  -- ── 이미 활성이면 멱등 — false 반환(에러 아님) ────────────────────
  IF v_campaign.deleted_at IS NULL THEN
    RETURN false;
  END IF;

  -- ── 복구 ────────────────────────────────────────────────────
  UPDATE public.campaigns
     SET deleted_at = NULL,
         deleted_by = NULL
   WHERE id = p_campaign_id;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.restore_campaign(uuid) IS
  '[256] 보관 삭제(soft delete)된 캠페인 복구. is_campaign_admin() 가드. '
  'deleted_at/deleted_by 를 NULL 로 되돌림 — status 등 다른 컬럼은 삭제 당시 값 '
  '그대로 보존(재계산은 화면 computeCampaignStatus 책임). 이미 활성이면 false(멱등). '
  '신청·결과물은 soft_delete_campaign(255) 시점에 이미 파기돼 복구되지 않음(설계 의도).';

REVOKE ALL ON FUNCTION public.restore_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_campaign(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'restore_campaign';

-- [V1] 255 검증에서 삭제 처리한 캠페인으로 복구 스모크(앱 콘솔 세션 권장,
--   SQL Editor 직접 실행은 auth.uid() NULL 이라 permission_denied 정상 발생)
-- SELECT public.restore_campaign('<255 검증에서 삭제한 id>'::uuid);
-- 기대값: true

-- [V2] 복구 후 확인
SELECT id, title, status, deleted_at, deleted_by FROM public.campaigns WHERE id = '<위 id>';
-- 기대값: deleted_at IS NULL, deleted_by IS NULL, status 는 삭제 전 값 그대로

-- [V3] 이미 활성인 캠페인에 재호출 시 멱등(false, 에러 아님) 확인
-- SELECT public.restore_campaign('<위 id>'::uuid);
-- 기대값: false (에러 없음)

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.restore_campaign(uuid);
