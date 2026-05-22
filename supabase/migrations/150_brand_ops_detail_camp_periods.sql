-- ============================================================
-- 150_brand_ops_detail_camp_periods.sql
-- 2026-05-22
--
-- 목적:
--   get_brand_ops_detail(p_brand_id) 의 캠페인 jsonb 항목에
--   리뷰어(monitor) 구매기간 + 방문형(visit) 방문기간 4개 키를 추가.
--   운영 현황 상세 미니카드에서 recruit_type 에 따라
--     monitor → 구매기간(purchase_start ~ purchase_end)
--     visit   → 방문기간(visit_start ~ visit_end)
--   를 제출 진행바 하단에 표시하기 위해 필요.
--
-- 변경 내용:
--   신청 내부 캠페인 서브쿼리(v_applications) 와
--   외부 캠페인 서브쿼리(v_external_camps) 양쪽에 동일하게 적용:
--
--   추가 키 4개 (campaigns 테이블 컬럼, 마이그레이션 036 정의, date 타입):
--     purchase_start  (monitor 구매 시작일, NULL 가능)
--     purchase_end    (monitor 구매 마감일, NULL 가능)
--     visit_start     (visit  방문 시작일, NULL 가능)
--     visit_end       (visit  방문 마감일, NULL 가능)
--
-- 유지된 기존 키 (149 에서 정의, 이 파일에도 그대로 유지):
--   id, campaign_no, title, brand_ko, product_ko, status,
--   recruit_type, slots, deadline, updated_at,
--   channel, channel_match, img1,
--   recruit_start, submission_end,
--   approved_app_count, deliv_submitted_inf, deliv_total, deliv_approved
--   (합계 19개 → 이번 150 에서 4개 추가 → 총 23개)
--
-- 하위호환:
--   반환 타입(jsonb)은 불변. 키만 추가되므로 기존 클라이언트에 영향 없음.
--
-- 컬럼 실존 확인 (마이그레이션 036_add_campaign_deadlines.sql):
--   ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS purchase_start date;
--   ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS purchase_end   date;
--   ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS visit_start    date;
--   ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS visit_end      date;
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
--   -- [2] 신규 4키 포함 확인 (brand_id 는 실제 존재하는 값으로 교체)
--   SELECT
--     c_item ? 'purchase_start' AS has_purchase_start,
--     c_item ? 'purchase_end'   AS has_purchase_end,
--     c_item ? 'visit_start'    AS has_visit_start,
--     c_item ? 'visit_end'      AS has_visit_end,
--     -- 149 기존 키도 여전히 있는지 확인
--     c_item ? 'recruit_start'  AS has_recruit_start,
--     c_item ? 'submission_end' AS has_submission_end,
--     c_item ? 'deliv_total'    AS has_deliv_total
--   FROM (
--     SELECT jsonb_array_elements(
--              (public.get_brand_ops_detail('<실제_brand_id_uuid>')
--               -> 'applications' -> 0 -> 'campaigns')
--            ) AS c_item
--   ) sub
--   LIMIT 1;
--   -- 기대값: 7개 모두 true
--   -- (캠페인이 신청 연결이 아닌 경우 external_campaigns 로 동일하게 확인)
--
-- rollback:
--   149_brand_ops_detail_camp_expand.sql 의 CREATE OR REPLACE FUNCTION 블록을
--   그대로 재실행하면 4개 키가 제거된 149 정의로 복원됨.
--   BEGIN; ... (149 파일 내용 그대로) ... COMMIT;
-- ============================================================

BEGIN;

-- ============================================================
-- 단계 1: get_brand_ops_detail 재정의
--   [120 → 129 → 149 → 150] 캠페인 항목에 구매·방문 기간 4키 추가
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
                          -- 149 추가: 채널·썸네일
                          'channel',        c.channel,
                          'channel_match',  c.channel_match,
                          'img1',           c.img1,
                          -- 149 추가: 기간
                          'recruit_start',  c.recruit_start,
                          'submission_end', c.submission_end,
                          -- 149 추가: 결과물 집계 (상관 서브쿼리)
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
                          ),
                          -- 150 신규 추가: 구매·방문 기간 (date, NULL 가능)
                          'purchase_start', c.purchase_start,
                          'purchase_end',   c.purchase_end,
                          'visit_start',    c.visit_start,
                          'visit_end',      c.visit_end
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
           -- 149 추가: 채널·썸네일
           'channel',        c.channel,
           'channel_match',  c.channel_match,
           'img1',           c.img1,
           -- 149 추가: 기간
           'recruit_start',  c.recruit_start,
           'submission_end', c.submission_end,
           -- 149 추가: 결과물 집계 (상관 서브쿼리)
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
           ),
           -- 150 신규 추가: 구매·방문 기간 (date, NULL 가능)
           'purchase_start', c.purchase_start,
           'purchase_end',   c.purchase_end,
           'visit_start',    c.visit_start,
           'visit_end',      c.visit_end
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
  '[120 → 129 → 149 → 150] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드. 149에서 channel/channel_match/img1/recruit_start/submission_end/결과물집계 추가. 150에서 purchase_start/purchase_end/visit_start/visit_end(구매·방문 기간) 추가.';

COMMIT;
