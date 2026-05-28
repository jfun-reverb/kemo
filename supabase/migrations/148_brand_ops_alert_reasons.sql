-- ════════════════════════════════════════════════════════════════════
-- migration 148: get_brand_ops_overview 반환 컬럼 3개 추가
-- ────────────────────────────────────────────────────────────────────
-- 목적:
--   운영 현황 페인(#brand-ops) 카드에 alert_level 사유(배너)를 표시하기 위해
--   get_brand_ops_overview 가 alert_reasons, soonest_deadline, d1_count 를
--   추가로 반환하도록 재정의.
--
-- 반환 TABLE 구조 변경 (19 → 22컬럼):
--   기존 19컬럼은 순서·이름 그대로 유지.
--   추가 컬럼 3개 (마지막에 붙임):
--     #20  alert_reasons    text[]      -- 해당 alert 를 발생시킨 조건 코드 배열
--     #21  soonest_deadline date        -- 가장 임박한 active 캠페인 deadline
--     #22  d1_count         bigint      -- D-1 임박 캠페인 수
--
-- alert_reasons 코드 정의 (화면이 이 코드로 한국어 문구를 조립):
--   'recruit_low_deadline_near'  모집률 < 30% AND soonest_deadline < current_date + 7일
--   'cancel_7d_high'             7일내 취소 >= 5건
--   'd1_imminent'                D-1 임박 active 캠페인 1개 이상
--   'd3_imminent'                D-3 임박 active 캠페인 1개 이상 (d1 미포함)
--   'recruit_low'                모집률 < 50% AND soonest_deadline >= current_date + 7일(또는 NULL)
--
-- alert_level 결정 규칙 (120 기준 그대로 유지 — 임계값 변경 금지):
--   danger : d1>=1 OR cancel7>=5 OR (모집률<30 AND soonest_deadline < current_date+7)
--   warning: d3>=1
--   caution: 모집률<50 AND (soonest_deadline IS NULL OR >= current_date+7)
--   normal : 그 외
--
-- 설계 방침:
--   동일 임계값을 두 번 계산하지 않기 위해 중간 CTE flag_agg 를 추가.
--   flag_agg 가 각 조건을 boolean 으로 미리 계산 → alert_level 과
--   alert_reasons 를 최종 SELECT 에서 동일 값 재참조.
--
-- 검증 쿼리 (트랜잭션 밖 수동 실행):
-- /*
--   -- 전체 브랜드 22컬럼 확인 (5건)
--   SELECT brand_name_ko, alert_level, alert_reasons, soonest_deadline, d1_count
--   FROM public.get_brand_ops_overview()
--   LIMIT 5;
--
--   -- alert_reasons 가 비어있지 않은 브랜드 목록
--   SELECT brand_name_ko, alert_level, alert_reasons
--   FROM public.get_brand_ops_overview()
--   WHERE alert_reasons <> '{}'
--   ORDER BY alert_level;
--
--   -- alert_level 별 건수
--   SELECT alert_level, COUNT(*)
--   FROM public.get_brand_ops_overview()
--   GROUP BY alert_level ORDER BY 1;
-- */
--
-- ROLLBACK (120 정의로 복원):
--   DROP FUNCTION IF EXISTS public.get_brand_ops_overview(uuid);
--   그 후 supabase/migrations/120_brand_ops_rpc.sql 의
--   get_brand_ops_overview 블록(BEGIN; ~ GRANT; 사이)을 SQL Editor에서 재실행.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- 반환 TABLE 구조가 변경되므로 CREATE OR REPLACE 불가 — DROP 후 재생성
DROP FUNCTION IF EXISTS public.get_brand_ops_overview(uuid);

CREATE FUNCTION public.get_brand_ops_overview(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
  -- ── 기존 19컬럼 (순서·이름 불변) ──
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
  -- ── 신규 3컬럼 (148 추가) ──
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
  -- ── 1. 캠페인 집계 (120 기준 그대로) ──
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

  -- ── 2. 신청 집계 (120 기준 그대로) ──
  app_agg AS (
    SELECT c.brand_id,
           COUNT(*) FILTER (WHERE a.status = 'approved')::bigint AS approved_cnt,
           COUNT(*) FILTER (
             WHERE a.cancelled_at IS NOT NULL
               AND a.cancelled_at >= (now() - INTERVAL '7 days')
           )::bigint AS cancel7,
           GREATEST(MAX(a.created_at), MAX(a.reviewed_at), MAX(a.cancelled_at)) AS latest_app_update
    FROM public.applications a
    JOIN public.campaigns c ON c.id = a.campaign_id
    WHERE c.brand_id IS NOT NULL
    GROUP BY c.brand_id
  ),

  -- ── 3. 결과물 집계 (120 기준 그대로) ──
  deliv_agg AS (
    SELECT c.brand_id,
           COUNT(*)::bigint AS deliv_total,
           COUNT(*) FILTER (WHERE d.status = 'approved')::bigint AS deliv_approved
    FROM public.deliverables d
    JOIN public.campaigns c ON c.id = d.campaign_id
    WHERE c.brand_id IS NOT NULL
    GROUP BY c.brand_id
  ),

  -- ── 4. 광고주 신청(brand_applications) 집계 (120 기준 그대로) ──
  brand_app_agg AS (
    SELECT ba.brand_id,
           COUNT(*) FILTER (WHERE ba.status NOT IN ('done','rejected'))::bigint AS open_apps,
           MAX(ba.updated_at) AS latest_brand_app_update
    FROM public.brand_applications ba
    WHERE ba.brand_id IS NOT NULL
    GROUP BY ba.brand_id
  ),

  -- ── 5. alert 조건 플래그 사전 계산 (신규 CTE — 중복 임계값 연산 방지) ──
  -- 동일 임계값을 alert_level 과 alert_reasons 양쪽에서 재참조.
  -- 모집률은 NULL 안전하게 처리 (slots_sum=0 → 모집률 없음 → 해당 조건 미발동).
  flag_agg AS (
    SELECT
      b_id,
      -- danger 조건 3종
      (d1 >= 1)                                                            AS flag_d1,
      (cancel7 >= 5)                                                       AS flag_cancel_high,
      (slots_sum > 0
         AND recruit_pct < 30
         AND soonest_dl IS NOT NULL
         AND soonest_dl < (current_date + INTERVAL '7 days')::date)        AS flag_low_near,
      -- warning 조건 1종 (d1 이 없을 때만 표시 대상 — level 결정은 CASE WHEN 순서가 처리)
      (d3 >= 1)                                                            AS flag_d3,
      -- caution 조건 1종
      (slots_sum > 0
         AND recruit_pct < 50
         AND (soonest_dl IS NULL
              OR soonest_dl >= (current_date + INTERVAL '7 days')::date))  AS flag_low,
      -- 수치 그대로 전달 (최종 SELECT 에서 재사용)
      d1          AS d1_val,
      d3          AS d3_val,
      cancel7     AS cancel7_val,
      slots_sum   AS slots_val,
      soonest_dl  AS soonest_dl_val,
      recruit_pct AS recruit_pct_val
    FROM (
      -- 브랜드별로 집계값을 모아 모집률을 미리 계산
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

  -- ── 6. 최종 SELECT ──
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
    -- alert_level: fg 의 boolean 플래그 재사용 (임계값 이중 계산 없음)
    CASE
      WHEN fg.flag_d1          THEN 'danger'
      WHEN fg.flag_cancel_high THEN 'danger'
      WHEN fg.flag_low_near    THEN 'danger'
      WHEN fg.flag_d3          THEN 'warning'
      WHEN fg.flag_low         THEN 'caution'
      ELSE                          'normal'
    END                                                          AS alert_level,
    -- alert_reasons: alert 발생 조건 코드 배열 (normal 이어도 해당 조건 코드 포함 가능)
    -- 화면이 이 배열 + soonest_deadline/d1_count/cancel_7d 수치로 한국어 문구 조립.
    -- 코드 간 중복 없음: d1_imminent 와 d3_imminent 는 상호 배타(d3>=d1).
    -- 단, 여러 danger 조건이 동시에 성립할 경우 배열에 함께 포함됨.
    ARRAY_REMOVE(
      ARRAY[
        CASE WHEN fg.flag_d1          THEN 'd1_imminent'            END,
        -- d3_imminent 는 d1 이 아닌 캠페인만 (D-3 이면서 D-1 은 아닌 것이 있을 때 의미 있음)
        -- 그러나 d3 카운트 자체는 d1 포함이므로 (d3>=d1 조건): d3>d1 인 경우에만 노출
        -- → d3 > 0 이고 d3 > d1 이면 'D-3 구간 캠페인 있음' 의미
        CASE WHEN fg.flag_d3 AND fg.d3_val > fg.d1_val THEN 'd3_imminent' END,
        -- d1 만 있고 d3 초과분이 없어도 d3_imminent 를 표시하려면 아래 조건으로 교체:
        -- CASE WHEN fg.flag_d3 THEN 'd3_imminent' END,
        CASE WHEN fg.flag_cancel_high THEN 'cancel_7d_high'          END,
        CASE WHEN fg.flag_low_near   THEN 'recruit_low_deadline_near' END,
        CASE WHEN fg.flag_low        THEN 'recruit_low'              END
      ],
      NULL
    )                                                            AS alert_reasons,
    -- soonest_deadline/d1_count: 이미 camp_agg/flag_agg 에 계산됨 — 출력만 추가
    fg.soonest_dl_val                                            AS soonest_deadline,
    fg.d1_val::bigint                                            AS d1_count
  FROM public.brands b
  LEFT JOIN public.companies      co ON co.id = b.company_id
  LEFT JOIN brand_app_agg          ba ON ba.brand_id = b.id
  LEFT JOIN camp_agg               ca ON ca.brand_id = b.id
  LEFT JOIN app_agg                aa ON aa.brand_id = b.id
  LEFT JOIN deliv_agg              da ON da.brand_id = b.id
  -- flag_agg 는 이미 brands 를 내부에서 순회했으므로 brand_id 로 조인
  JOIN  flag_agg                   fg ON fg.b_id    = b.id
  WHERE
    (p_company_id IS NULL OR b.company_id = p_company_id);
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_overview(uuid) IS
  '[120 → 148] 운영 현황 페인용 브랜드 카드 그리드 집계. '
  '모집률·결과물률·D-3 임박·7일 취소·alert_level. '
  '148 추가: alert_reasons(조건 코드 배열)/soonest_deadline/d1_count. '
  'is_admin() 가드.';

REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_brand_ops_overview(uuid) TO authenticated;

COMMIT;
