-- ============================================================
-- 249_count_pending_review_exclude_unassigned.sql
-- 검수대기 배지 집계 함수 보정 — 채널 미지정 리뷰 이미지(legacy) 제외
--
-- ── 배경 ──
--   마이그레이션 248 count_pending_review_applications() 가 배지(신청 단위 검수대기)를
--   세는데, 운영에서 배지 9 vs 화면 「검수대기만」 목록 1건으로 크게 어긋났다.
--
-- ── 원인 ──
--   post_channel 이 NULL 인 review_image(채널 미지정 레거시 인증샷, 마이그레이션 162)의
--   pending 을 248 함수가 (kind='review_image', COALESCE(post_channel,'')='') 조합의
--   최신으로 세어 신청을 검수대기로 카운트했다. 그러나 화면(buildDeliverableGroups/
--   groupHasPendingReview)은 채널 미지정 review_image 를 reviewByChannel 에 넣지 않고
--   「채널 지정 필요」(unassignedBox, legacy_no_channel)로 별도 취급해 **검수대기로 세지 않는다.**
--   → 이 레거시 행이 운영에 8건 있어 배지만 과대(9), 목록(1)과 불일치.
--
-- ── 수정 ──
--   latest CTE 에서 `kind='review_image' AND post_channel IS NULL` 행을 제외한다.
--   (receipt 는 kind 가 달라 제외 안 됨. post 는 channel 유무와 무관하게 화면이 최신 1건으로
--    세므로 제외 안 함.) → 화면의 "채널 미지정은 검수대기 아님" 규칙과 정합해 배지=목록 일치.
--
-- ── 적용 순서 ──
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 배지=목록 대조
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 롤백: 마이그레이션 248 의 함수 본문으로 CREATE OR REPLACE 재실행.
-- ============================================================

CREATE OR REPLACE FUNCTION public.count_pending_review_applications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 호출할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  WITH latest AS (
    -- 신청×종류×채널 조합별 최신 1건. 채널 미지정 레거시 review_image 는 화면이
    -- 검수대기로 세지 않으므로(채널 지정 필요 항목으로 별도 취급) 여기서도 제외한다.
    SELECT DISTINCT ON (d.application_id, d.kind, COALESCE(d.post_channel, ''))
      d.application_id,
      d.status
    FROM public.deliverables d
    WHERE d.status <> 'draft'
      AND NOT (d.kind = 'review_image' AND d.post_channel IS NULL)
    ORDER BY
      d.application_id, d.kind, COALESCE(d.post_channel, ''),
      d.submitted_at DESC NULLS LAST,
      d.updated_at DESC
  )
  SELECT COUNT(DISTINCT l.application_id)::integer
  INTO v_count
  FROM latest l
  JOIN public.applications a ON a.id = l.application_id
  WHERE l.status = 'pending'
    AND a.status NOT IN ('rejected', 'cancelled');

  RETURN COALESCE(v_count, 0);
END;
$$;

COMMENT ON FUNCTION public.count_pending_review_applications() IS
  '[249] 검수대기 신청 수(사이드바 배지). 신청×종류×채널별 최신 결과물이 pending 이고 '
  '신청이 반려·취소 아닌 신청 수. 채널 미지정 review_image(legacy)는 화면과 정합 위해 제외. '
  'is_admin() 가드. 화면 buildDeliverableGroups/groupHasPendingReview 와 같은 기준(SQL 재현).';
