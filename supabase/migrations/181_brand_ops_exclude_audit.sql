-- ════════════════════════════════════════════════════════════════════
-- migration 181: get_brand_ops_overview / get_brand_ops_detail
--                감사용 계정(is_audit=true) 응모 격리
-- ────────────────────────────────────────────────────────────────────
-- 배경:
--   마이그레이션 179에서 influencers.is_audit 컬럼을 추가하고
--   get_campaign_application_counts / check_monitor_slots /
--   recompute_campaign_applied_count 에 감사용 격리를 적용했으나,
--   운영 현황 페인(#brand-ops)의 아래 두 함수는 누락됨.
--
--   - get_brand_ops_overview : app_agg CTE 가 applications 를 집계 →
--     승인수(approved_total) / 모집률(recruit_rate) / alert_level 에
--     감사용 응모가 포함되어 광고주 보고용 수치가 부정확.
--   - get_brand_ops_detail   : 캠페인별 4개 상관 서브쿼리
--     (신청 내부 × 2 + 외부 × 2) 가 applications / deliverables 를
--     직접 집계 → approved_app_count / deliv_submitted_inf /
--     deliv_total / deliv_approved 에 감사용 수치 혼입.
--
-- 변경 내용:
--   [overview] app_agg CTE 에서
--     JOIN public.influencers i ON i.id = a.user_id
--     AND i.is_audit = false
--   추가.
--
--   [detail] approved_app_count 서브쿼리 2지점에서
--     AND NOT EXISTS (
--       SELECT 1 FROM public.influencers i
--        WHERE i.id = a.user_id AND i.is_audit = true
--     )
--   추가 (코릴레이티드 서브쿼리 내 추가 JOIN 보다 안전).
--
--   [detail] deliverables 집계 3지점(deliv_submitted_inf / deliv_total /
--     deliv_approved) 에서 감사용 인플루언서의 결과물을 제외:
--     AND NOT EXISTS (
--       SELECT 1 FROM public.influencers i
--        WHERE i.id = d.user_id AND i.is_audit = true
--     )
--   추가.
--
--   함수 시그니처·반환 타입·기존 로직(alert_level·alert_reasons·날짜·
--   channel 등)·SECURITY DEFINER·SET search_path·GRANT 모두 불변.
--
-- 최신 정의 기준:
--   get_brand_ops_overview : 148_brand_ops_alert_reasons.sql
--   get_brand_ops_detail   : 150_brand_ops_detail_camp_periods.sql
--
-- ────────────────────────────────────────────────────────────────────
-- ROLLBACK:
--   get_brand_ops_overview 복원:
--     148_brand_ops_alert_reasons.sql 의
--     CREATE FUNCTION public.get_brand_ops_overview ... 블록 전체를
--     SQL Editor 에서 재실행 (DROP 없이 CREATE OR REPLACE 가능하나
--     반환 TABLE 컬럼 수가 같으므로 직접 대체 가능).
--
--   get_brand_ops_detail 복원:
--     150_brand_ops_detail_camp_periods.sql 의
--     CREATE OR REPLACE FUNCTION public.get_brand_ops_detail ... 블록 전체를
--     SQL Editor 에서 재실행.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════
-- 1. get_brand_ops_overview 재정의
--    최신 정의: 148_brand_ops_alert_reasons.sql
--    격리 추가: app_agg CTE 의 applications JOIN 에 감사용 제외 조건
-- ════════════════════════════════════════════════════════════════════

-- 반환 TABLE 구조가 148 과 동일하므로 CREATE OR REPLACE 사용 가능.
-- (120 → 148 때는 컬럼 수 변경으로 DROP 필요했으나 181 은 구조 불변)
CREATE OR REPLACE FUNCTION public.get_brand_ops_overview(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
  -- ── 기존 19컬럼 (148 기준 순서·이름 불변) ──
  brand_id              uuid,
  brand_seq             integer,
  brand_no              text,
  brand_name_ko         text,
  brand_name_ja         text,
  company_id            uuid,
  company_name_ko       text,
  open_applications     bigint,
  active_campaigns      bigint,
  slots_total           bigint,
  approved_total        bigint,
  recruit_rate          numeric,
  deliverable_total     bigint,
  deliverable_approved  bigint,
  deliverable_rate      numeric,
  d3_count              bigint,
  cancel_7d             bigint,
  last_activity_at      timestamptz,
  alert_level           text,
  -- ── 신규 3컬럼 (148 추가, 불변) ──
  alert_reasons         text[],
  soonest_deadline      date,
  d1_count              bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH
  -- ── 1. 캠페인 집계 (148 기준 그대로) ──
  camp_agg AS (
    SELECT
      c.brand_id,
      SUM(CASE WHEN c.status IN ('active','scheduled') THEN 1 ELSE 0 END)::bigint AS active_camps,
      SUM(CASE WHEN c.status IN ('active','scheduled','closed') THEN COALESCE(c.slots,0) ELSE 0 END)::bigint AS slots_sum,
      SUM(CASE
            WHEN c.status = 'active'
             AND c.deadline IS NOT NULL
             AND c.deadline <= (current_date + INTERVAL '3 days')::date
            THEN 1 ELSE 0
          END)::bigint AS d3,
      SUM(CASE
            WHEN c.status = 'active'
             AND c.deadline IS NOT NULL
             AND c.deadline <= (current_date + INTERVAL '1 days')::date
            THEN 1 ELSE 0
          END)::bigint AS d1,
      MIN(CASE WHEN c.status = 'active' THEN c.deadline END) AS soonest_dl,
      MAX(c.updated_at) AS latest_camp_update
    FROM public.campaigns c
    WHERE c.brand_id IS NOT NULL
    GROUP BY c.brand_id
  ),

  -- ── 2. 신청 집계 — [181] 감사용 응모 제외 ──
  -- 변경: influencers JOIN + is_audit = false 조건 추가.
  -- 취소(cancelled_at) 도 감사용 제외하여 cancel_7d 수치도 정확하게.
  app_agg AS (
    SELECT c.brand_id,
           COUNT(*) FILTER (WHERE a.status = 'approved')::bigint AS approved_cnt,
           COUNT(*) FILTER (
             WHERE a.cancelled_at IS NOT NULL
               AND a.cancelled_at >= (now() - INTERVAL '7 days')
           )::bigint AS cancel7,
           GREATEST(MAX(a.created_at), MAX(a.reviewed_at), MAX(a.cancelled_at)) AS latest_app_update
    FROM public.applications a
    JOIN public.campaigns    c ON c.id = a.campaign_id
    JOIN public.influencers  i ON i.id = a.user_id   -- [181] 감사용 격리용 JOIN
    WHERE c.brand_id IS NOT NULL
      AND i.is_audit = false                          -- [181] 감사용 응모 제외
    GROUP BY c.brand_id
  ),

  -- ── 3. 결과물 집계 — [181] 감사용 인플루언서 결과물 제외 ──
  -- deliverables.user_id 가 influencers.id 와 동일 경로이므로 JOIN 추가.
  deliv_agg AS (
    SELECT c.brand_id,
           COUNT(*)::bigint AS deliv_total,
           COUNT(*) FILTER (WHERE d.status = 'approved')::bigint AS deliv_approved
    FROM public.deliverables d
    JOIN public.campaigns    c ON c.id = d.campaign_id
    JOIN public.influencers  i ON i.id = d.user_id   -- [181] 감사용 격리용 JOIN
    WHERE c.brand_id IS NOT NULL
      AND i.is_audit = false                          -- [181] 감사용 결과물 제외
    GROUP BY c.brand_id
  ),

  -- ── 4. 광고주 신청(brand_applications) 집계 (148 기준 그대로) ──
  brand_app_agg AS (
    SELECT ba.brand_id,
           COUNT(*) FILTER (WHERE ba.status NOT IN ('done','rejected'))::bigint AS open_apps,
           MAX(ba.updated_at) AS latest_brand_app_update
    FROM public.brand_applications ba
    WHERE ba.brand_id IS NOT NULL
    GROUP BY ba.brand_id
  ),

  -- ── 5. alert 조건 플래그 사전 계산 (148 기준 그대로) ──
  flag_agg AS (
    SELECT
      b_id,
      (d1 >= 1)                                                            AS flag_d1,
      (cancel7 >= 5)                                                       AS flag_cancel_high,
      (slots_sum > 0
         AND recruit_pct < 30
         AND soonest_dl IS NOT NULL
         AND soonest_dl < (current_date + INTERVAL '7 days')::date)        AS flag_low_near,
      (d3 >= 1)                                                            AS flag_d3,
      (slots_sum > 0
         AND recruit_pct < 50
         AND (soonest_dl IS NULL
              OR soonest_dl >= (current_date + INTERVAL '7 days')::date))  AS flag_low,
      d1          AS d1_val,
      d3          AS d3_val,
      cancel7     AS cancel7_val,
      slots_sum   AS slots_val,
      soonest_dl  AS soonest_dl_val,
      recruit_pct AS recruit_pct_val
    FROM (
      SELECT
        b.id AS b_id,
        COALESCE(ca.d1, 0)                                     AS d1,
        COALESCE(ca.d3, 0)                                     AS d3,
        COALESCE(aa.cancel7, 0)                                AS cancel7,
        COALESCE(ca.slots_sum, 0)                              AS slots_sum,
        ca.soonest_dl,
        CASE
          WHEN COALESCE(ca.slots_sum, 0) = 0 THEN NULL
          ELSE ROUND(100.0 * COALESCE(aa.approved_cnt, 0) / ca.slots_sum, 1)
        END AS recruit_pct
      FROM public.brands b
      LEFT JOIN camp_agg  ca ON ca.brand_id = b.id
      LEFT JOIN app_agg   aa ON aa.brand_id = b.id
      WHERE (p_company_id IS NULL OR b.company_id = p_company_id)
    ) sub
  )

  -- ── 6. 최종 SELECT (148 기준 그대로) ──
  SELECT
    b.id                                                         AS brand_id,
    b.brand_seq                                                  AS brand_seq,
    b.brand_no                                                   AS brand_no,
    b.name                                                       AS brand_name_ko,
    b.name_ja                                                    AS brand_name_ja,
    b.company_id                                                 AS company_id,
    co.name_ko                                                   AS company_name_ko,
    COALESCE(ba.open_apps,    0)::bigint                         AS open_applications,
    COALESCE(ca.active_camps, 0)::bigint                         AS active_campaigns,
    COALESCE(ca.slots_sum,    0)::bigint                         AS slots_total,
    COALESCE(aa.approved_cnt, 0)::bigint                         AS approved_total,
    fg.recruit_pct_val                                           AS recruit_rate,
    COALESCE(da.deliv_total,    0)::bigint                       AS deliverable_total,
    COALESCE(da.deliv_approved, 0)::bigint                       AS deliverable_approved,
    CASE
      WHEN COALESCE(da.deliv_total, 0) = 0 THEN NULL
      ELSE ROUND(100.0 * COALESCE(da.deliv_approved, 0) / da.deliv_total, 1)
    END                                                          AS deliverable_rate,
    COALESCE(ca.d3, 0)::bigint                                   AS d3_count,
    COALESCE(aa.cancel7, 0)::bigint                              AS cancel_7d,
    GREATEST(
      COALESCE(ca.latest_camp_update,      'epoch'::timestamptz),
      COALESCE(aa.latest_app_update,       'epoch'::timestamptz),
      COALESCE(ba.latest_brand_app_update, 'epoch'::timestamptz),
      b.updated_at
    )                                                            AS last_activity_at,
    CASE
      WHEN fg.flag_d1          THEN 'danger'
      WHEN fg.flag_cancel_high THEN 'danger'
      WHEN fg.flag_low_near    THEN 'danger'
      WHEN fg.flag_d3          THEN 'warning'
      WHEN fg.flag_low         THEN 'caution'
      ELSE                          'normal'
    END                                                          AS alert_level,
    ARRAY_REMOVE(
      ARRAY[
        CASE WHEN fg.flag_d1          THEN 'd1_imminent'            END,
        CASE WHEN fg.flag_d3 AND fg.d3_val > fg.d1_val THEN 'd3_imminent' END,
        CASE WHEN fg.flag_cancel_high THEN 'cancel_7d_high'          END,
        CASE WHEN fg.flag_low_near   THEN 'recruit_low_deadline_near' END,
        CASE WHEN fg.flag_low        THEN 'recruit_low'              END
      ],
      NULL
    )                                                            AS alert_reasons,
    fg.soonest_dl_val                                            AS soonest_deadline,
    fg.d1_val::bigint                                            AS d1_count
  FROM public.brands b
  LEFT JOIN public.companies      co ON co.id = b.company_id
  LEFT JOIN brand_app_agg          ba ON ba.brand_id = b.id
  LEFT JOIN camp_agg               ca ON ca.brand_id = b.id
  LEFT JOIN app_agg                aa ON aa.brand_id = b.id
  LEFT JOIN deliv_agg              da ON da.brand_id = b.id
  JOIN  flag_agg                   fg ON fg.b_id    = b.id
  WHERE
    (p_company_id IS NULL OR b.company_id = p_company_id);
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_overview(uuid) IS
  '[120 → 148 → 181] 운영 현황 페인용 브랜드 카드 그리드 집계. '
  '모집률·결과물률·D-3 임박·7일 취소·alert_level. '
  '148 추가: alert_reasons(조건 코드 배열)/soonest_deadline/d1_count. '
  '181 추가: app_agg/deliv_agg 에서 감사용(is_audit=true) 응모·결과물 제외. '
  'is_admin() 가드.';

REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_brand_ops_overview(uuid) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 2. get_brand_ops_detail 재정의
--    최신 정의: 150_brand_ops_detail_camp_periods.sql
--    격리 추가:
--      approved_app_count  2지점 (신청 내부 캠페인 / 외부 캠페인)
--      deliv_submitted_inf 2지점
--      deliv_total         2지점
--      deliv_approved      2지점
--    → 합계 8지점에 NOT EXISTS 감사용 제외 조건 추가.
-- ════════════════════════════════════════════════════════════════════

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

  -- ── 신청 목록 (신청 내부에 캠페인 배열) ──
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
                          -- 149 추가: 결과물 집계 (상관 서브쿼리) — [181] 감사용 제외 추가
                          'approved_app_count', (
                            SELECT count(*)
                              FROM public.applications a
                             WHERE a.campaign_id = c.id
                               AND a.status = 'approved'
                               AND NOT EXISTS (             -- [181] 감사용 응모 제외
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
                               AND NOT EXISTS (             -- [181] 감사용 결과물 제외
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
                               AND NOT EXISTS (             -- [181] 감사용 결과물 제외
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
                               AND d.status = 'approved'
                               AND NOT EXISTS (             -- [181] 감사용 결과물 제외
                                 SELECT 1
                                   FROM public.influencers i
                                  WHERE i.id = d.user_id
                                    AND i.is_audit = true
                               )
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

  -- ── 외부 캠페인 (source_application_id IS NULL, brand 직접 등록) ──
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
           -- 149 추가: 결과물 집계 (상관 서브쿼리) — [181] 감사용 제외 추가
           'approved_app_count', (
             SELECT count(*)
               FROM public.applications a
              WHERE a.campaign_id = c.id
                AND a.status = 'approved'
                AND NOT EXISTS (                            -- [181] 감사용 응모 제외
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
                AND NOT EXISTS (                            -- [181] 감사용 결과물 제외
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
                AND NOT EXISTS (                            -- [181] 감사용 결과물 제외
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
                AND d.status = 'approved'
                AND NOT EXISTS (                            -- [181] 감사용 결과물 제외
                  SELECT 1
                    FROM public.influencers i
                   WHERE i.id = d.user_id
                     AND i.is_audit = true
                )
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
  '[120 → 129 → 149 → 150 → 181] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드. '
  '149에서 channel/channel_match/img1/recruit_start/submission_end/결과물집계 추가. '
  '150에서 purchase_start/purchase_end/visit_start/visit_end(구매·방문 기간) 추가. '
  '181에서 approved_app_count 2지점·deliv_* 6지점(신청내부×3 + 외부×3)에 감사용(is_audit=true) 제외 추가.';

COMMIT;
