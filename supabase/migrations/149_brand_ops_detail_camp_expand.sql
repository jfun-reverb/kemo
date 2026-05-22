-- ============================================================
-- 149_brand_ops_detail_camp_expand.sql
-- 2026-05-22
--
-- 목적:
--   get_brand_ops_detail(p_brand_id) 의 캠페인 jsonb 항목에
--   운영 현황 상세 페인 미니카드 렌더에 필요한 컬럼과 집계 수치를 추가.
--
-- 변경 내용:
--   신청 내부 캠페인 서브쿼리(v_applications) 와
--   외부 캠페인 서브쿼리(v_external_camps) 양쪽에 동일하게 적용:
--
--   추가 키 9개:
--     channel          (campaigns.channel — 콤마구분 채널 문자열)
--     channel_match    (campaigns.channel_match — 'or'|'and')
--     img1             (campaigns.img1 — 썸네일 URL, NULL 가능)
--     recruit_start    (campaigns.recruit_start — 모집 시작일, NULL 가능)
--     submission_end   (campaigns.submission_end — 결과물 마감일, NULL 가능)
--     approved_app_count  (승인 신청 수 — 제출률 분모)
--     deliv_submitted_inf (결과물 제출한 distinct 인플 수 — 제출률 분자)
--     deliv_total         (결과물 전체 건수 — 승인률 분모)
--     deliv_approved      (승인된 결과물 건수 — 승인률 분자)
--
-- 하위호환:
--   반환 타입은 jsonb 불변. 캠페인 항목에 키만 추가되므로
--   기존 클라이언트가 새 키를 무시하면 그대로 동작함.
--   클라이언트(dev/js/admin-brand.js)에서 새 키를 활용하는
--   미니카드 렌더 코드와 함께 적용.
--
-- deliverables 스키마 확인 결과 (마이그레이션 035):
--   deliverables.user_id    — uuid NOT NULL (직접 distinct 집계 가능)
--   deliverables.campaign_id — uuid NOT NULL (상관 서브쿼리 조건으로 직접 사용)
--   → applications 경유 없이 deliverables 에서 직접 집계 가능.
--
-- 성능 고려:
--   브랜드 1개 상세라 캠페인 수가 적으므로 상관 서브쿼리 허용.
--   집계 서브쿼리 3개(approved_app_count / deliv_submitted_inf+deliv_total+deliv_approved)
--   는 각각 인덱스(idx_applications_campaign_id / idx_deliverables_campaign_id)를 탐.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 1단계씩 실행):
--   -- [1] 함수 재정의 확인
--   SELECT proname, prosrc IS NOT NULL AS ok
--     FROM pg_proc
--    WHERE proname = 'get_brand_ops_detail'
--      AND pronamespace = 'public'::regnamespace;
--   -- 기대값: ok = true
--
--   -- [2] 캠페인 항목에 신규 키 9개 포함 확인 (brand_id 는 실제 존재하는 값으로 교체)
--   SELECT
--     c_item ? 'channel'           AS has_channel,
--     c_item ? 'channel_match'     AS has_channel_match,
--     c_item ? 'img1'              AS has_img1,
--     c_item ? 'recruit_start'     AS has_recruit_start,
--     c_item ? 'submission_end'    AS has_submission_end,
--     c_item ? 'approved_app_count'   AS has_approved_app_count,
--     c_item ? 'deliv_submitted_inf'  AS has_deliv_submitted_inf,
--     c_item ? 'deliv_total'          AS has_deliv_total,
--     c_item ? 'deliv_approved'       AS has_deliv_approved
--   FROM (
--     SELECT jsonb_array_elements(
--              (public.get_brand_ops_detail('<실제_brand_id_uuid>')
--               -> 'applications' -> 0 -> 'campaigns')
--            ) AS c_item
--   ) sub
--   LIMIT 1;
--   -- 기대값: 9개 모두 true (캠페인 없으면 외부 캠페인으로 조회)
--
--   -- [3] 수치 일관성 확인 (임시 직접 쿼리와 비교)
--   -- SELECT count(*) FROM applications WHERE campaign_id='<id>' AND status='approved';
--   -- SELECT count(DISTINCT user_id) FROM deliverables WHERE campaign_id='<id>';
--   -- SELECT count(*) FROM deliverables WHERE campaign_id='<id>';
--   -- SELECT count(*) FROM deliverables WHERE campaign_id='<id>' AND status='approved';
--
-- rollback:
--   아래 함수를 129_remove_post_deadline.sql 의 정의로 복원 (57~162행 재실행)
--   또는 단순 COMMENT 제거:
--   --  BEGIN;
--   --  CREATE OR REPLACE FUNCTION public.get_brand_ops_detail(p_brand_id uuid)
--   --  ... (129 파일 내용 그대로)
--   --  COMMIT;
-- ============================================================

BEGIN;

-- ============================================================
-- 단계 1: get_brand_ops_detail 재정의
--   [120 → 129 → 149] 캠페인 항목에 channel/channel_match/img1/기간/결과물집계 추가
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_brand_ops_detail(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand          public.brands%ROWTYPE;
  v_company        jsonb;
  v_applications   jsonb;
  v_external_camps jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_brand FROM public.brands WHERE id = p_brand_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'brand_not_found' USING ERRCODE = '22023';
  END IF;

  -- 소속 회사 (선택)
  IF v_brand.company_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id',       co.id,
             'name_ko',  co.name_ko,
             'name_ja',  co.name_ja
           )
      INTO v_company
      FROM public.companies co
     WHERE co.id = v_brand.company_id;
  ELSE
    v_company := NULL;
  END IF;

  -- 신청 목록 (신청 내부에 캠페인 배열)
  SELECT COALESCE(jsonb_agg(app_row ORDER BY app_row->>'created_at' DESC), '[]'::jsonb)
    INTO v_applications
    FROM (
      SELECT jsonb_build_object(
               'id',               ba.id,
               'application_no',   ba.application_no,
               'form_type',        ba.form_type,
               'status',           ba.status,
               'final_quote_krw',  ba.final_quote_krw,
               'estimated_krw',    ba.estimated_krw,
               'created_at',       ba.created_at,
               'updated_at',       ba.updated_at,
               'campaigns',        (
                 SELECT COALESCE(jsonb_agg(jsonb_build_object(
                          -- 기존 키 (129 이후 유지)
                          'id',           c.id,
                          'campaign_no',  c.campaign_no,
                          'title',        c.title,
                          'brand_ko',     c.brand_ko,
                          'product_ko',   c.product_ko,
                          'status',       c.status,
                          'recruit_type', c.recruit_type,
                          'slots',        c.slots,
                          'deadline',     c.deadline,
                          'updated_at',   c.updated_at,
                          -- 149 신규 추가: 채널·썸네일
                          'channel',        c.channel,
                          'channel_match',  c.channel_match,
                          'img1',           c.img1,
                          -- 149 신규 추가: 기간
                          'recruit_start',  c.recruit_start,
                          'submission_end', c.submission_end,
                          -- 149 신규 추가: 결과물 집계 (상관 서브쿼리)
                          'approved_app_count', (
                            SELECT count(*)
                              FROM public.applications a
                             WHERE a.campaign_id = c.id
                               AND a.status = 'approved'
                          ),
                          'deliv_submitted_inf', (
                            SELECT count(DISTINCT d.user_id)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                          ),
                          'deliv_total', (
                            SELECT count(*)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                          ),
                          'deliv_approved', (
                            SELECT count(*)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                               AND d.status = 'approved'
                          )
                        ) ORDER BY c.created_at), '[]'::jsonb)
                 FROM public.campaigns c
                 WHERE c.source_application_id = ba.id
               )
             ) AS app_row
        FROM public.brand_applications ba
       WHERE ba.brand_id = p_brand_id
    ) sub;

  -- 외부 캠페인 (source_application_id IS NULL, brand 직접 등록)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           -- 기존 키 (129 이후 유지)
           'id',           c.id,
           'campaign_no',  c.campaign_no,
           'title',        c.title,
           'brand_ko',     c.brand_ko,
           'product_ko',   c.product_ko,
           'status',       c.status,
           'recruit_type', c.recruit_type,
           'slots',        c.slots,
           'deadline',     c.deadline,
           'updated_at',   c.updated_at,
           -- 149 신규 추가: 채널·썸네일
           'channel',        c.channel,
           'channel_match',  c.channel_match,
           'img1',           c.img1,
           -- 149 신규 추가: 기간
           'recruit_start',  c.recruit_start,
           'submission_end', c.submission_end,
           -- 149 신규 추가: 결과물 집계 (상관 서브쿼리)
           'approved_app_count', (
             SELECT count(*)
               FROM public.applications a
              WHERE a.campaign_id = c.id
                AND a.status = 'approved'
           ),
           'deliv_submitted_inf', (
             SELECT count(DISTINCT d.user_id)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
           ),
           'deliv_total', (
             SELECT count(*)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
           ),
           'deliv_approved', (
             SELECT count(*)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
                AND d.status = 'approved'
           )
         ) ORDER BY c.created_at), '[]'::jsonb)
    INTO v_external_camps
    FROM public.campaigns c
   WHERE c.brand_id = p_brand_id
     AND c.source_application_id IS NULL;

  RETURN jsonb_build_object(
    'brand', jsonb_build_object(
      'id',         v_brand.id,
      'brand_seq',  v_brand.brand_seq,
      'brand_no',   v_brand.brand_no,
      'name',       v_brand.name,
      'name_ja',    v_brand.name_ja,
      'company_id', v_brand.company_id,
      'updated_at', v_brand.updated_at
    ),
    'company',             v_company,
    'applications',        v_applications,
    'external_campaigns',  v_external_camps
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_detail(uuid) IS
  '[120 → 129 → 149] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드. 149에서 캠페인 항목에 channel/channel_match/img1/recruit_start/submission_end/approved_app_count/deliv_submitted_inf/deliv_total/deliv_approved 추가.';

COMMIT;
