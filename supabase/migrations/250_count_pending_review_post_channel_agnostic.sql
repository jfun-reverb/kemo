-- ============================================================
-- 250_count_pending_review_post_channel_agnostic.sql
-- 검수대기 배지 집계 함수 보정 (2/2) — 게시물(post)·영수증은 채널 무관 신청당 최신 1건
--
-- ── 배경 ──
--   248→249 로 채널 미지정 review_image 를 제외했지만, 운영에서 여전히 배지 6 vs
--   화면 「검수대기만」 목록 1건으로 어긋났다.
--
-- ── 원인 ──
--   함수가 (application_id, kind, post_channel) 조합별로 최신을 잡는데, 게시물(post)에
--   post_channel 이 여러 개인 기프팅/방문형 신청에서 문제가 났다. 예: post/x=승인(최신),
--   post/other=검수대기(옛). 함수는 (post,'other') 최신 pending 을 세지만, 화면
--   buildDeliverableGroups 는 post 를 **채널 구분 없이 신청 전체 최신 1건**(g.result)으로만
--   보므로 최신(승인)만 반영해 검수대기로 안 센다. → 운영 5건이 이 케이스라 배지만 과대.
--
-- ── 수정 ──
--   최신 판정 조합에서 **review_image 만 채널별**로 구분하고, post·receipt 는 채널을 무시해
--   (application_id, kind) 신청당 최신 1건으로 본다. 화면과 정확히 정합:
--     - receipt  : 신청당 최신 1건 (g.receipt)
--     - post     : 신청당 최신 1건, 채널 무관 (g.result)
--     - review_image : 채널별 최신 1건 (g.reviewByChannel), 채널 미지정은 제외(249 유지)
--
-- ── 적용 순서 ──
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 배지=목록 대조
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- ── 성능 참고 ──
--   248 의 보조 색인 idx_deliverables_app_kind_channel_submitted 은 review_image 판정엔
--   유효하나, post·receipt 는 CASE 가 항상 '' 라 색인 물리 정렬(실채널값 기준)과 어긋나
--   별도 정렬이 붙을 수 있다(현재 수천 건 규모에선 무해). 규모가 커지면
--   (application_id, kind, submitted_at DESC) 보조 색인 추가를 검토.
--
-- 롤백: 마이그레이션 249 의 함수 본문으로 CREATE OR REPLACE 재실행.
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
    -- 최신 판정 조합: review_image 만 채널별로 구분(채널별 인증샷 각각 검수), post·receipt 는
    -- 채널 무관 신청당 최신 1건(화면 buildDeliverableGroups 의 g.result/g.receipt 와 정합).
    -- 채널 미지정 레거시 review_image 는 화면이 검수대기로 안 세므로 여기서도 제외.
    SELECT DISTINCT ON (
      d.application_id,
      d.kind,
      CASE WHEN d.kind = 'review_image' THEN COALESCE(d.post_channel, '') ELSE '' END
    )
      d.application_id,
      d.status
    FROM public.deliverables d
    WHERE d.status <> 'draft'
      AND NOT (d.kind = 'review_image' AND d.post_channel IS NULL)
    ORDER BY
      d.application_id,
      d.kind,
      CASE WHEN d.kind = 'review_image' THEN COALESCE(d.post_channel, '') ELSE '' END,
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
  '[250] 검수대기 신청 수(사이드바 배지). review_image 만 채널별 최신, post·receipt 는 채널 무관 '
  '신청당 최신 1건 판정 → 화면 buildDeliverableGroups/groupHasPendingReview 와 정합. '
  '채널 미지정 review_image·반려취소 신청 제외. is_admin() 가드.';
