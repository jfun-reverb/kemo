-- ════════════════════════════════════════════════════════════════════
-- migration 120: 운영 현황 페인 원격 호출 함수 2종
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-13-brand-ops-redesign.md §4-3
--
-- 신규 함수:
--   1. get_brand_ops_overview(p_company_id uuid DEFAULT NULL)
--        브랜드 카드 그리드용 — 모든 브랜드(또는 회사 필터)의 핵심 지표 집계
--        반환 컬럼 19개: brand 정보(7) + open_applications + active_campaigns
--                       + 모집률 + 결과물 제출률(3) + D-3 임박 + 7일 취소
--                       + 마지막 활동 시각 + alert_level (normal/caution/warning/danger)
--
--   2. get_brand_ops_detail(p_brand_id uuid)
--        브랜드 상세 페인용 — 신청 + 캠페인 리스트를 jsonb 로 반환
--
-- 보안:
--   SECURITY DEFINER + SET search_path = ''
--   is_admin() 가드 — anon/influencer 호출 차단 (42501)
--   1000-row cap 회피: 서버 집계 결과만 반환 (PostgREST 영향 없음)
--
-- alert_level 결정 규칙 (사양서 §5-3):
--   danger : D-1 임박(active 캠페인 deadline <= now() + 1일) 1개 이상
--            OR 7일 취소 >= 5건
--            OR (모집률 < 30% AND deadline 7일 미만)
--   warning: D-3 임박(active 캠페인 deadline <= now() + 3일) 1개 이상
--   caution: 모집률 < 50% AND deadline 7일 이상
--   normal : 위 모두 미해당
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.get_brand_ops_detail(uuid);
--   DROP FUNCTION IF EXISTS public.get_brand_ops_overview(uuid);
-- ════════════════════════════════════════════════════════════════════

BEGIN;


-- ── 1. 운영 현황 브랜드 카드 그리드용 집계 ──
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
  alert_level           text
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
  -- 활성 + 노출 캠페인 (모집률·결과물률 집계 대상)
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
      -- 모집률 분모용 deadline 임박 여부 (가장 임박한 active 캠페인 기준)
      MIN(CASE WHEN c.status = 'active' THEN c.deadline END) AS soonest_deadline,
      MAX(c.updated_at) AS latest_camp_update
    FROM public.campaigns c
    WHERE c.brand_id IS NOT NULL
    GROUP BY c.brand_id
  ),

  -- 캠페인별 승인 신청 (모집률 분자)
  -- applications 테이블에는 updated_at 컬럼 없음 — created_at/reviewed_at/cancelled_at 중 가장 최근값 사용
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

  -- 결과물 집계 (제출률)
  deliv_agg AS (
    SELECT c.brand_id,
           COUNT(*)::bigint AS deliv_total,
           COUNT(*) FILTER (WHERE d.status = 'approved')::bigint AS deliv_approved
    FROM public.deliverables d
    JOIN public.campaigns c ON c.id = d.campaign_id
    WHERE c.brand_id IS NOT NULL
    GROUP BY c.brand_id
  ),

  -- 브랜드 신청서(brand_applications) 진행건수
  brand_app_agg AS (
    SELECT ba.brand_id,
           COUNT(*) FILTER (WHERE ba.status NOT IN ('done','rejected'))::bigint AS open_apps,
           MAX(ba.updated_at) AS latest_brand_app_update
    FROM public.brand_applications ba
    WHERE ba.brand_id IS NOT NULL
    GROUP BY ba.brand_id
  )

  SELECT
    b.id                                                    AS brand_id,
    b.brand_seq                                             AS brand_seq,
    b.brand_no                                              AS brand_no,
    b.name                                                  AS brand_name_ko,
    b.name_ja                                               AS brand_name_ja,
    b.company_id                                            AS company_id,
    co.name_ko                                              AS company_name_ko,
    COALESCE(ba.open_apps,    0)::bigint                    AS open_applications,
    COALESCE(ca.active_camps, 0)::bigint                    AS active_campaigns,
    COALESCE(ca.slots_sum,    0)::bigint                    AS slots_total,
    COALESCE(aa.approved_cnt, 0)::bigint                    AS approved_total,
    CASE
      WHEN COALESCE(ca.slots_sum,0) = 0 THEN NULL
      ELSE ROUND(100.0 * COALESCE(aa.approved_cnt,0) / ca.slots_sum, 1)
    END                                                     AS recruit_rate,
    COALESCE(da.deliv_total,     0)::bigint                 AS deliverable_total,
    COALESCE(da.deliv_approved,  0)::bigint                 AS deliverable_approved,
    CASE
      WHEN COALESCE(da.deliv_total,0) = 0 THEN NULL
      ELSE ROUND(100.0 * COALESCE(da.deliv_approved,0) / da.deliv_total, 1)
    END                                                     AS deliverable_rate,
    COALESCE(ca.d3,        0)::bigint                       AS d3_count,
    COALESCE(aa.cancel7,   0)::bigint                       AS cancel_7d,
    GREATEST(
      COALESCE(ca.latest_camp_update,      'epoch'::timestamptz),
      COALESCE(aa.latest_app_update,       'epoch'::timestamptz),
      COALESCE(ba.latest_brand_app_update, 'epoch'::timestamptz),
      b.updated_at
    )                                                       AS last_activity_at,
    CASE
      -- danger 조건 우선 평가
      WHEN COALESCE(ca.d1, 0) >= 1                                   THEN 'danger'
      WHEN COALESCE(aa.cancel7, 0) >= 5                              THEN 'danger'
      WHEN COALESCE(ca.slots_sum, 0) > 0
           AND ROUND(100.0 * COALESCE(aa.approved_cnt,0) / ca.slots_sum, 1) < 30
           AND ca.soonest_deadline IS NOT NULL
           AND ca.soonest_deadline < (current_date + INTERVAL '7 days')::date THEN 'danger'
      WHEN COALESCE(ca.d3, 0) >= 1                                   THEN 'warning'
      WHEN COALESCE(ca.slots_sum, 0) > 0
           AND ROUND(100.0 * COALESCE(aa.approved_cnt,0) / ca.slots_sum, 1) < 50
           AND (ca.soonest_deadline IS NULL
                OR ca.soonest_deadline >= (current_date + INTERVAL '7 days')::date) THEN 'caution'
      ELSE 'normal'
    END                                                     AS alert_level
  FROM public.brands b
  LEFT JOIN public.companies      co ON co.id = b.company_id
  LEFT JOIN brand_app_agg          ba ON ba.brand_id = b.id
  LEFT JOIN camp_agg               ca ON ca.brand_id = b.id
  LEFT JOIN app_agg                aa ON aa.brand_id = b.id
  LEFT JOIN deliv_agg              da ON da.brand_id = b.id
  WHERE
    -- 회사 필터: NULL=전체, 명시=해당 회사
    (p_company_id IS NULL OR b.company_id = p_company_id);
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_overview(uuid) IS
  '[120] 운영 현황 페인용 브랜드 카드 그리드 집계. 모집률·결과물률·D-3 임박·7일 취소·alert_level. is_admin() 가드.';

REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_brand_ops_overview(uuid) TO authenticated;


-- ── 2. 브랜드 상세 페인용 — 신청 + 캠페인 리스트 jsonb 반환 ──
CREATE OR REPLACE FUNCTION public.get_brand_ops_detail(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand        public.brands%ROWTYPE;
  v_company      jsonb;
  v_applications jsonb;
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
                          'id',           c.id,
                          'campaign_no',  c.campaign_no,
                          'title',        c.title,
                          'brand_ko',     c.brand_ko,
                          'product_ko',   c.product_ko,
                          'status',       c.status,
                          'recruit_type', c.recruit_type,
                          'slots',        c.slots,
                          'deadline',     c.deadline,
                          'post_deadline',c.post_deadline,
                          'updated_at',   c.updated_at
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
           'id',           c.id,
           'campaign_no',  c.campaign_no,
           'title',        c.title,
           'brand_ko',     c.brand_ko,
           'product_ko',   c.product_ko,
           'status',       c.status,
           'recruit_type', c.recruit_type,
           'slots',        c.slots,
           'deadline',     c.deadline,
           'post_deadline',c.post_deadline,
           'updated_at',   c.updated_at
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
    'company',          v_company,
    'applications',     v_applications,
    'external_campaigns', v_external_camps
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_detail(uuid) IS
  '[120] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드.';

REVOKE ALL ON FUNCTION public.get_brand_ops_detail(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_detail(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_detail(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_brand_ops_detail(uuid) TO authenticated;


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 동작 검증 SQL (트랜잭션 밖, 수동 실행)
-- ────────────────────────────────────────────────────────────────────
/*
-- 전체 브랜드 오버뷰 (5건만)
SELECT * FROM public.get_brand_ops_overview() LIMIT 5;

-- 특정 회사 필터
SELECT * FROM public.get_brand_ops_overview(
  (SELECT id FROM public.companies LIMIT 1)
);

-- alert_level 별 분포 (회사 미필터)
SELECT alert_level, COUNT(*) FROM public.get_brand_ops_overview()
GROUP BY alert_level ORDER BY 1;

-- 단일 브랜드 상세
SELECT public.get_brand_ops_detail(
  (SELECT id FROM public.brands LIMIT 1)
);

-- 권한 가드 확인 (anon 으로 호출 시 42501)
-- 익명 키로 .rpc('get_brand_ops_overview') 호출 → forbidden 예외
*/
