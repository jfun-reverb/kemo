-- ============================================================
-- 259_exclude_deleted_campaigns_from_rpc.sql
-- 캠페인 삭제 복구(soft delete) — PR 2 착수 전 필수 보완
-- 사양서: docs/specs/2026-07-22-campaign-soft-delete-restore.md
--         「구현 결과 → ⚠️ PR 2 착수 전 필수 보완」
--
-- 배경:
--   마이그레이션 254(campaigns.deleted_at 컬럼)~258(자동 완전삭제 배치)로
--   캠페인 보관 삭제(soft delete) 기반이 만들어졌다. PR 1 시점엔 관리자
--   삭제 버튼이 아직 hard delete(dev/js/admin.js executeDeleteCampaign)라
--   deleted_at 이 실제로 세팅되는 캠페인이 없어 안전했지만, PR 2에서 그
--   버튼이 soft_delete_campaign() RPC 호출로 교체되는 순간부터 최대 30일간
--   deleted_at IS NOT NULL 인 캠페인 행이 존재하게 된다.
--
--   아래 4개 함수는 public.campaigns 를 직접 SQL로 조회하면서 deleted_at
--   컬럼의 존재를 모른 채(작성 시점엔 컬럼이 없었음) 캠페인을 집계한다.
--   보완 없이 PR 2가 배포되면 "삭제됨(보관 중)" 캠페인이 아래 화면에
--   계속 노출·집계되는 회귀가 발생한다:
--     - 운영 현황 대시보드(브랜드 카드 그리드 · 브랜드 상세)
--     - 캠페인 홍보 메일 대상 풀(관리자 통계 + 실제 발송 대상 매칭)
--
-- 변경 함수 4개 (전부 CREATE OR REPLACE, 시그니처·반환 컬럼·로직 불변,
-- public.campaigns 를 직접 조회하는 지점에 `AND c.deleted_at IS NULL` 한
-- 조건만 추가):
--
--   1. get_brand_ops_overview(uuid)        — 최신 정의: 181_brand_ops_exclude_audit.sql
--      · camp_agg CTE  : FROM public.campaigns c ... 에 조건 추가
--      · app_agg CTE   : JOIN public.campaigns c ON c.id = a.campaign_id 에 조건 추가
--      · deliv_agg CTE : JOIN public.campaigns c ON c.id = d.campaign_id 에 조건 추가
--
--   2. get_brand_ops_detail(uuid)          — 최신 정의: 181_brand_ops_exclude_audit.sql
--      · 신청별 캠페인 서브쿼리 : FROM public.campaigns c WHERE c.source_application_id = ba.id 에 조건 추가
--      · 외부 캠페인 서브쿼리   : FROM public.campaigns c WHERE c.brand_id = p_brand_id AND c.source_application_id IS NULL 에 조건 추가
--      (각 캠페인 행 안의 결과물·신청 상관 서브쿼리는 campaigns 조회가 아니므로 변경 없음
--       — 어차피 삭제된 캠페인은 soft_delete_campaign() 이 신청·결과물을 이미 파기했음)
--
--   3. get_promo_digest_targets(date)      — 최신 정의: 143_promo_targets_total_counts.sql
--      · new_campaigns CTE          : FROM public.campaigns c WHERE c.status='active' ... 에 조건 추가
--      · deadline_d1_campaigns CTE  : FROM public.campaigns c WHERE c.status='active' ... 에 조건 추가
--      (반환 컬럼 8개 그대로 — DROP 불필요, CREATE OR REPLACE 가능)
--
--   4. get_promo_digest_campaign_pool(date) — 최신 정의: 152_admin_promo_email_subscription.sql
--      · new_campaigns CTE          : 동일 위치에 조건 추가
--      · deadline_d1_campaigns CTE  : 동일 위치에 조건 추가
--
-- 이 마이그레이션은 각 함수의 CTE/서브쿼리에 `AND c.deleted_at IS NULL`
-- 한 줄씩만 삽입한다. 그 외 로직·컬럼·이름·순서·SECURITY DEFINER·
-- SET search_path·GRANT/REVOKE 는 원본과 100% 동일하게 보존.
--
-- 전제 조건:
--   마이그레이션 254 (campaigns.deleted_at/deleted_by 컬럼) 적용 완료
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행
--   2. (PR 2·3 운영 배포 시점에) 운영서버 SQL Editor 실행
--
-- 롤백:
--   각 함수를 위에 명시한 「최신 정의」 원본 마이그레이션 파일의
--   CREATE OR REPLACE FUNCTION 블록으로 다시 실행하면 deleted_at 조건만
--   제거된 이전 상태로 복원된다 (반환 시그니처 불변이라 DROP 불필요).
-- ============================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════
-- 1. get_brand_ops_overview — 최신 정의: 181_brand_ops_exclude_audit.sql
--    변경: camp_agg / app_agg / deliv_agg 3개 CTE에 deleted_at IS NULL 추가
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_brand_ops_overview(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
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
  -- ── 1. 캠페인 집계 — [259] 보관 삭제(soft delete) 캠페인 제외 ──
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
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
    GROUP BY c.brand_id
  ),

  -- ── 2. 신청 집계 — 감사용 응모 제외(181) + [259] 보관 삭제 캠페인 제외 ──
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
    JOIN public.influencers  i ON i.id = a.user_id
    WHERE c.brand_id IS NOT NULL
      AND i.is_audit = false
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
    GROUP BY c.brand_id
  ),

  -- ── 3. 결과물 집계 — 감사용 결과물 제외(181) + [259] 보관 삭제 캠페인 제외 ──
  deliv_agg AS (
    SELECT c.brand_id,
           COUNT(*)::bigint AS deliv_total,
           COUNT(*) FILTER (WHERE d.status = 'approved')::bigint AS deliv_approved
    FROM public.deliverables d
    JOIN public.campaigns    c ON c.id = d.campaign_id
    JOIN public.influencers  i ON i.id = d.user_id
    WHERE c.brand_id IS NOT NULL
      AND i.is_audit = false
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
    GROUP BY c.brand_id
  ),

  -- ── 4. 광고주 신청(brand_applications) 집계 (변경 없음 — campaigns 미참조) ──
  brand_app_agg AS (
    SELECT ba.brand_id,
           COUNT(*) FILTER (WHERE ba.status NOT IN ('done','rejected'))::bigint AS open_apps,
           MAX(ba.updated_at) AS latest_brand_app_update
    FROM public.brand_applications ba
    WHERE ba.brand_id IS NOT NULL
    GROUP BY ba.brand_id
  ),

  -- ── 5. alert 조건 플래그 사전 계산 (변경 없음) ──
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

  -- ── 6. 최종 SELECT (변경 없음) ──
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
  '[120 → 148 → 181 → 259] 운영 현황 페인용 브랜드 카드 그리드 집계. '
  '모집률·결과물률·D-3 임박·7일 취소·alert_level. '
  '148 추가: alert_reasons(조건 코드 배열)/soonest_deadline/d1_count. '
  '181 추가: app_agg/deliv_agg 에서 감사용(is_audit=true) 응모·결과물 제외. '
  '259 추가: camp_agg/app_agg/deliv_agg 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  'is_admin() 가드.';

REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_brand_ops_overview(uuid) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 2. get_brand_ops_detail — 최신 정의: 181_brand_ops_exclude_audit.sql
--    변경: 신청별 캠페인 서브쿼리 + 외부 캠페인 서브쿼리 2지점에
--          deleted_at IS NULL 추가
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
  '259에서 신청내부/외부 캠페인 조회 2지점에 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외 추가.';


-- ════════════════════════════════════════════════════════════════════
-- 3. get_promo_digest_targets — 최신 정의: 143_promo_targets_total_counts.sql
--    변경: new_campaigns / deadline_d1_campaigns 2개 CTE에
--          deleted_at IS NULL 추가 (반환 컬럼 8개 불변 → CREATE OR REPLACE)
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_promo_digest_targets(p_digest_date date)
RETURNS TABLE (
  influencer_id            uuid,
  email                    text,
  name                     text,
  unsubscribe_token        uuid,
  new_campaign_ids         uuid[],
  deadline_d1_campaign_ids uuid[],
  new_total_count          integer,
  deadline_d1_total_count  integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH

  -- ──────────────────────────────────────────────────────────
  -- [A] 신규 캠페인 — [259] 보관 삭제 캠페인 제외
  -- ──────────────────────────────────────────────────────────
  new_campaigns AS (
    SELECT
      c.id,
      c.channel,
      c.recruit_type,
      c.min_followers,
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND (c.first_active_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
      AND c.deadline >= CURRENT_DATE
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [B] D-1 임박 캠페인 — [259] 보관 삭제 캠페인 제외
  -- ──────────────────────────────────────────────────────────
  deadline_d1_campaigns AS (
    SELECT
      c.id,
      c.channel,
      c.recruit_type,
      c.min_followers,
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND c.deadline = CURRENT_DATE + 1
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [C] 발송 대상 인플루언서 기본 조건 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  eligible_influencers AS (
    SELECT
      i.id,
      i.unsubscribe_token,
      i.name_kanji,
      i.name_kana,
      i.name,
      i.ig_followers,
      i.tiktok_followers,
      i.x_followers,
      i.youtube_followers,
      i.ig,
      i.tiktok,
      i.x,
      i.youtube
    FROM public.influencers i
    WHERE i.marketing_opt_in = true
      AND i.marketing_unsubscribed_at IS NULL
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_digest_sent s
         WHERE s.influencer_id = i.id
           AND s.digest_date   = p_digest_date
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [D] 신규 캠페인 × 인플루언서 매칭 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  new_matches AS (
    SELECT
      i.id                                            AS influencer_id,
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5]  AS campaign_ids,
      COUNT(*)::integer                               AS total_count
    FROM eligible_influencers i
    CROSS JOIN new_campaigns c
    WHERE
      (
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers
          )
      AND NOT EXISTS (
        SELECT 1
          FROM public.applications a
         WHERE a.user_id     = i.id
           AND a.campaign_id = c.id
           AND a.status     <> 'cancelled'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'new'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_email_clicks k
         WHERE k.campaign_id   = c.id
           AND k.influencer_id = i.id
      )
    GROUP BY i.id
  ),

  -- ──────────────────────────────────────────────────────────
  -- [E] D-1 임박 캠페인 × 인플루언서 매칭 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  d1_matches AS (
    SELECT
      i.id                                            AS influencer_id,
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5]  AS campaign_ids,
      COUNT(*)::integer                               AS total_count
    FROM eligible_influencers i
    CROSS JOIN deadline_d1_campaigns c
    WHERE
      (
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers
          )
      AND NOT EXISTS (
        SELECT 1
          FROM public.applications a
         WHERE a.user_id     = i.id
           AND a.campaign_id = c.id
           AND a.status     <> 'cancelled'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'deadline_d1'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_email_clicks k
         WHERE k.campaign_id   = c.id
           AND k.influencer_id = i.id
      )
    GROUP BY i.id
  ),

  -- ──────────────────────────────────────────────────────────
  -- [F] 두 매칭 결합 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  all_targets AS (
    SELECT
      COALESCE(nm.influencer_id, dm.influencer_id) AS influencer_id,
      COALESCE(nm.campaign_ids, '{}')              AS new_campaign_ids,
      COALESCE(dm.campaign_ids, '{}')              AS deadline_d1_campaign_ids,
      COALESCE(nm.total_count, 0)                  AS new_total_count,
      COALESCE(dm.total_count, 0)                  AS deadline_d1_total_count
    FROM new_matches nm
    FULL OUTER JOIN d1_matches dm
      ON nm.influencer_id = dm.influencer_id
    WHERE
      (COALESCE(array_length(nm.campaign_ids, 1), 0) > 0
       OR COALESCE(array_length(dm.campaign_ids, 1), 0) > 0)
  )

  -- ──────────────────────────────────────────────────────────
  -- [G] 최종 반환 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  SELECT
    t.influencer_id,
    (SELECT u.email FROM auth.users u WHERE u.id = t.influencer_id) AS email,
    COALESCE(
      NULLIF(TRIM(i.name_kanji), ''),
      NULLIF(TRIM(i.name),       ''),
      NULLIF(TRIM(i.name_kana),  ''),
      ''
    ) AS name,
    i.unsubscribe_token,
    t.new_campaign_ids,
    t.deadline_d1_campaign_ids,
    t.new_total_count,
    t.deadline_d1_total_count
  FROM all_targets t
  JOIN public.influencers i ON i.id = t.influencer_id;
$$;

REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_promo_digest_targets(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_targets(date) IS
  '[141 → 143 → 259] 홍보 메일 발송 대상 조회. 신규·D-1 섹션 각각 캠페인 ID 배열(최대 5건) + 매칭 총수 반환. 「他 N件」 안내 정확도 향상. '
  '259 추가: new_campaigns/deadline_d1_campaigns 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  'SECURITY DEFINER + search_path 고정.';


-- ════════════════════════════════════════════════════════════════════
-- 4. get_promo_digest_campaign_pool — 최신 정의: 152_admin_promo_email_subscription.sql
--    변경: new_campaigns / deadline_d1_campaigns 2개 CTE에
--          deleted_at IS NULL 추가
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_promo_digest_campaign_pool(p_digest_date date)
RETURNS TABLE (
  new_campaign_ids         uuid[],
  new_total_count          integer,
  deadline_d1_campaign_ids uuid[],
  deadline_d1_total_count  integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH

  -- ──────────────────────────────────────────────────────────
  -- [A] 신규 캠페인 — [259] 보관 삭제 캠페인 제외
  -- ──────────────────────────────────────────────────────────
  new_campaigns AS (
    SELECT
      c.id,
      c.deadline
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND (c.first_active_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
      AND c.deadline >= CURRENT_DATE
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [B] D-1 임박 캠페인 — [259] 보관 삭제 캠페인 제외
  -- ──────────────────────────────────────────────────────────
  deadline_d1_campaigns AS (
    SELECT
      c.id,
      c.deadline
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND c.deadline = CURRENT_DATE + 1
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [C] 신규 캠페인 집계 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  new_agg AS (
    SELECT
      array_agg(id ORDER BY deadline ASC) AS campaign_ids,
      COUNT(*)::integer                   AS total_count
    FROM new_campaigns
  ),

  -- ──────────────────────────────────────────────────────────
  -- [D] D-1 임박 캠페인 집계 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  d1_agg AS (
    SELECT
      array_agg(id ORDER BY deadline ASC) AS campaign_ids,
      COUNT(*)::integer                   AS total_count
    FROM deadline_d1_campaigns
  )

  -- ──────────────────────────────────────────────────────────
  -- [E] 최종 반환 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  SELECT
    COALESCE(na.campaign_ids,   '{}')  AS new_campaign_ids,
    COALESCE(na.total_count,    0)     AS new_total_count,
    COALESCE(da.campaign_ids,   '{}')  AS deadline_d1_campaign_ids,
    COALESCE(da.total_count,    0)     AS deadline_d1_total_count
  FROM (SELECT 1) dummy
  LEFT JOIN new_agg na ON true
  LEFT JOIN d1_agg  da ON true;
$$;

REVOKE EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_campaign_pool(date) IS
  '[152 → 259] 관리자 홍보 메일용 캠페인 풀 조회. '
  '신규·D-1 섹션 캠페인 ID 배열 + 총수 반환. '
  'get_promo_digest_targets 와 캠페인 선정 조건 동기화. '
  '인플 개인화 조건(채널 매칭·팔로워·응모/노출/클릭 제외) 없음 — 관리자는 풀 전체. '
  '259 추가: new_campaigns/deadline_d1_campaigns 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  'SECURITY DEFINER + search_path 고정.';

-- PostgREST 스키마 캐시 리로드 (함수 본문만 바뀌었지만 관례상 포함)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (마이그레이션 적용 후 SQL Editor에서 실행 — 1단계씩 순차)
-- ============================================================
-- [1] 함수 4개가 재정의됐는지 확인 (COMMENT 에 259 포함 여부)
-- SELECT p.proname, obj_description(p.oid) AS comment
--   FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public'
--    AND p.proname IN ('get_brand_ops_overview','get_brand_ops_detail',
--                       'get_promo_digest_targets','get_promo_digest_campaign_pool');
-- 기대값: 4행, comment 에 "259" 포함

-- [2] 실제 삭제된 캠페인이 아직 없으므로(soft_delete_campaign 미사용 상태)
--     회귀 없이 기존과 동일한 결과가 나오는지 대표 캠페인 1건으로 확인
-- SELECT * FROM public.get_brand_ops_overview(NULL) LIMIT 5;

-- [3] (선택, 스모크) 임시로 테스트 캠페인 1건을 deleted_at 세팅 후
--     위 함수들 결과에서 빠지는지 확인 → 확인 후 반드시 NULL 로 되돌릴 것
-- UPDATE public.campaigns SET deleted_at = now() WHERE id = '<테스트용 캠페인 id>';
-- ... 함수 재호출로 제외 확인 ...
-- UPDATE public.campaigns SET deleted_at = NULL WHERE id = '<테스트용 캠페인 id>';
