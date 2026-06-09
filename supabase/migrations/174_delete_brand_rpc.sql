-- ============================================================
-- 174: 브랜드 삭제 RPC (연결 0건 한정 hard delete)
--
-- brands 는 DELETE 행 단위 보안 정책(RLS)이 없어(082 — soft delete 방침)
-- 클라이언트 직접 delete 가 무음 실패. 삭제는 본 SECURITY DEFINER RPC 경유.
-- 연결(campaigns·brand_applications) 0건일 때만 삭제, 아니면 병합 안내 에러.
-- 채번 카운터(brand_application_counter·brand_external_campaign_counter)는
-- brand_id PK ON DELETE CASCADE 라 자동 정리.
--
-- 사양서: docs/specs/2026-06-09-brand-delete-merge.md (PR 1)
-- 롤백: DROP FUNCTION IF EXISTS public.delete_brand(uuid);
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_brand(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camps  bigint;
  v_apps   bigint;
  v_exists boolean;
BEGIN
  -- 권한: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION '브랜드를 찾을 수 없습니다' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_camps FROM public.campaigns          WHERE brand_id = p_brand_id;
  SELECT count(*) INTO v_apps  FROM public.brand_applications WHERE brand_id = p_brand_id;

  IF v_camps > 0 OR v_apps > 0 THEN
    RAISE EXCEPTION '연결된 캠페인 %건, 신청 %건이 있어 삭제할 수 없습니다. 병합 기능을 사용하세요.', v_camps, v_apps
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.brands WHERE id = p_brand_id;

  RETURN jsonb_build_object('ok', true, 'deleted', p_brand_id);
END;
$$;

COMMENT ON FUNCTION public.delete_brand(uuid) IS
  '브랜드 hard delete (연결 0건 한정). campaign_admin 가드. 연결 있으면 22023 + 병합 안내.';

GRANT EXECUTE ON FUNCTION public.delete_brand(uuid) TO authenticated;
