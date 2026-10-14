-- 529_brand_ops_detail_exclude_inactive_deliverables.sql
-- 전수조사 3차 ⑥-7: 운영현황 브랜드 상세 미니카드의 결과물 집계 세 값이
--   ① 반려·취소된 신청의 결과물까지 세고(「제출 13/12」) ② 임시저장(draft)도 센다.
-- 변경: get_brand_ops_detail 의 deliv_submitted_inf · deliv_total · deliv_approved
--       (신청 연결 캠페인 블록 3 + 외부 캠페인 블록 3 = 6곳)에 조건 2개 추가.
--         AND d.status <> 'draft'
--         AND EXISTS (신청 status NOT IN ('rejected','cancelled'))   -- isCertExcluded · 491 과 같은 기준
--       감사용(is_audit) 제외는 그대로. 그 밖의 키·순서·주석은 베이스와 동일.
--
-- 베이스: 259_exclude_deleted_campaigns_from_rpc.sql (현재 원본. 이 이름을 CREATE 하는 파일 =
--         120·129·149·150·181·259, 259 이후 정의 없음 — 237 은 이름만 언급)
-- 번호: 526·527·528 이 이미 다른 작업에 쓰여 529.
-- 편집기 경고: 안 뜸 (CREATE OR REPLACE · COMMENT 만. DROP 없음 → 실행 권한 보존)
-- 화면 영향: 미니카드 「제출」 막대(제출 인플/승인 인플)가 줄어든다. 분모(approved_app_count)는 불변.
--
-- 롤백: 259 파일의 get_brand_ops_detail 블록(CREATE OR REPLACE ~ COMMENT)을 그대로 재실행.
--
-- 검증(적용 전·후 같은 브랜드로 비교). 관리자 가드(is_admin) 때문에 로그인 흉내가 필요하다.
--   BEGIN;
--   SELECT set_config('request.jwt.claims',
--     json_build_object('sub', (SELECT auth_id::text FROM public.admins WHERE role='super_admin' LIMIT 1),
--                       'role','authenticated')::text, true);
--   SET LOCAL ROLE authenticated;
--   SELECT cc->>'campaign_no' AS camp, cc->>'deliv_submitted_inf' AS inf, cc->>'deliv_total' AS total,
--          cc->>'deliv_approved' AS appr, cc->>'approved_app_count' AS approved
--     FROM (SELECT public.get_brand_ops_detail('<브랜드 id>'::uuid) AS r) x,
--          LATERAL (SELECT jsonb_array_elements(x.r->'external_campaigns') AS cc
--                   UNION ALL
--                   SELECT jsonb_array_elements(a->'campaigns')
--                     FROM jsonb_array_elements(x.r->'applications') a) y;
--   ROLLBACK;
--   기대: 적용 후 inf 가 approved 이하, total·appr 는 적용 전 이하. 「제출 13/12」였던 캠페인이 12 이하로.

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

  -- ── 신청 목록 (신청 내부에 캠페인 배열) — [259] 보관 삭제 캠페인 제외 ──
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
                          'channel',        c.channel,
                          'channel_match',  c.channel_match,
                          'img1',           c.img1,
                          'recruit_start',  c.recruit_start,
                          'submission_end', c.submission_end,
                          'approved_app_count', (
                            SELECT count(*)
                              FROM public.applications a
                             WHERE a.campaign_id = c.id
                               AND a.status = 'approved'
                               AND NOT EXISTS (
                                 SELECT 1
                                   FROM public.influencers i
                                  WHERE i.id = a.user_id
                                    AND i.is_audit = true
                               )
                          ),
                          'deliv_submitted_inf', (
                            SELECT count(DISTINCT d.user_id)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                               AND d.status <> 'draft'                         -- [529] 임시저장 제외
                               AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                                            WHERE ap.id = d.application_id
                                              AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                               AND NOT EXISTS (
                                 SELECT 1
                                   FROM public.influencers i
                                  WHERE i.id = d.user_id
                                    AND i.is_audit = true
                               )
                          ),
                          'deliv_total', (
                            SELECT count(*)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                               AND d.status <> 'draft'                         -- [529] 임시저장 제외
                               AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                                            WHERE ap.id = d.application_id
                                              AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                               AND NOT EXISTS (
                                 SELECT 1
                                   FROM public.influencers i
                                  WHERE i.id = d.user_id
                                    AND i.is_audit = true
                               )
                          ),
                          'deliv_approved', (
                            SELECT count(*)
                              FROM public.deliverables d
                             WHERE d.campaign_id = c.id
                               AND d.status <> 'draft'                         -- [529] 임시저장 제외
                               AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                                            WHERE ap.id = d.application_id
                                              AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                               AND d.status = 'approved'
                               AND NOT EXISTS (
                                 SELECT 1
                                   FROM public.influencers i
                                  WHERE i.id = d.user_id
                                    AND i.is_audit = true
                               )
                          ),
                          'purchase_start', c.purchase_start,
                          'purchase_end',   c.purchase_end,
                          'visit_start',    c.visit_start,
                          'visit_end',      c.visit_end
                        ) ORDER BY c.created_at), '[]'::jsonb)
                 FROM public.campaigns c
                 WHERE c.source_application_id = ba.id
                   AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
               )
             ) AS app_row
        FROM public.brand_applications ba
       WHERE ba.brand_id = p_brand_id
    ) sub;

  -- ── 외부 캠페인 (source_application_id IS NULL, brand 직접 등록) — [259] 보관 삭제 캠페인 제외 ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
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
           'channel',        c.channel,
           'channel_match',  c.channel_match,
           'img1',           c.img1,
           'recruit_start',  c.recruit_start,
           'submission_end', c.submission_end,
           'approved_app_count', (
             SELECT count(*)
               FROM public.applications a
              WHERE a.campaign_id = c.id
                AND a.status = 'approved'
                AND NOT EXISTS (
                  SELECT 1
                    FROM public.influencers i
                   WHERE i.id = a.user_id
                     AND i.is_audit = true
                )
           ),
           'deliv_submitted_inf', (
             SELECT count(DISTINCT d.user_id)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
                AND d.status <> 'draft'                         -- [529] 임시저장 제외
                AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                             WHERE ap.id = d.application_id
                               AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                AND NOT EXISTS (
                  SELECT 1
                    FROM public.influencers i
                   WHERE i.id = d.user_id
                     AND i.is_audit = true
                )
           ),
           'deliv_total', (
             SELECT count(*)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
                AND d.status <> 'draft'                         -- [529] 임시저장 제외
                AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                             WHERE ap.id = d.application_id
                               AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                AND NOT EXISTS (
                  SELECT 1
                    FROM public.influencers i
                   WHERE i.id = d.user_id
                     AND i.is_audit = true
                )
           ),
           'deliv_approved', (
             SELECT count(*)
               FROM public.deliverables d
              WHERE d.campaign_id = c.id
                AND d.status <> 'draft'                         -- [529] 임시저장 제외
                AND EXISTS (SELECT 1 FROM public.applications ap -- [529] 반려·취소 신청의 결과물 제외
                             WHERE ap.id = d.application_id
                               AND coalesce(ap.status, '') NOT IN ('rejected','cancelled'))
                AND d.status = 'approved'
                AND NOT EXISTS (
                  SELECT 1
                    FROM public.influencers i
                   WHERE i.id = d.user_id
                     AND i.is_audit = true
                )
           ),
           'purchase_start', c.purchase_start,
           'purchase_end',   c.purchase_end,
           'visit_start',    c.visit_start,
           'visit_end',      c.visit_end
         ) ORDER BY c.created_at), '[]'::jsonb)
    INTO v_external_camps
    FROM public.campaigns c
   WHERE c.brand_id = p_brand_id
     AND c.source_application_id IS NULL
     AND c.deleted_at IS NULL;         -- [259] 보관 삭제 캠페인 제외

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
  '[120 → 129 → 149 → 150 → 181 → 259] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드. '
  '149에서 channel/channel_match/img1/recruit_start/submission_end/결과물집계 추가. '
  '150에서 purchase_start/purchase_end/visit_start/visit_end(구매·방문 기간) 추가. '
  '181에서 approved_app_count 2지점·deliv_* 6지점(신청내부×3 + 외부×3)에 감사용(is_audit=true) 제외 추가. '
  '259에서 신청내부/외부 캠페인 조회 2지점에 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외 추가. '
  '529에서 deliv_submitted_inf/deliv_total/deliv_approved 6지점에 임시저장·반려/취소 신청 결과물 제외 추가.';
