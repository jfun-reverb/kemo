-- 마이그레이션 151: 캠페인별 신청 집계 원격 호출 함수
-- 목적: 관리자 캠페인 목록에서 신청 전건(약 3,000건)을 클라이언트로 전송하던 방식을
--       서버 집계로 전환. 캠페인별 {총 신청 수, 승인 수, 대기 수}를 1회 호출로 반환.
-- 동작 변경: total = 취소(cancelled) 제외 (PR 4 사용자 확정 결정)
--            approved/pending 은 기존과 동일.
--
-- 롤백: DROP FUNCTION IF EXISTS public.get_campaign_application_counts();

CREATE OR REPLACE FUNCTION public.get_campaign_application_counts()
RETURNS TABLE(
  campaign_id uuid,
  total       bigint,
  approved    bigint,
  pending     bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 관리자 전용 함수 — 비관리자 접근 차단
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    a.campaign_id,
    COUNT(*)                                FILTER (WHERE a.status <> 'cancelled') AS total,
    COUNT(*) FILTER (WHERE a.status = 'approved') AS approved,
    COUNT(*) FILTER (WHERE a.status = 'pending')  AS pending
  FROM public.applications a
  GROUP BY a.campaign_id;
END;
$$;

-- 기본 PUBLIC EXECUTE 회수 후 authenticated 에만 부여 (anon 미부여 — 함수 존재 노출 차단)
REVOKE ALL ON FUNCTION public.get_campaign_application_counts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_campaign_application_counts() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_campaign_application_counts() TO authenticated;
