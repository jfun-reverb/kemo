-- ============================================================
-- 591_action_alerts_exclude_record_only.sql
-- 2026-10-23 — 조치 경고에서 기록용 캠페인을 뺀다(관리자 일일 메일 다섯째 절 · 운영 현황 일정 뷰 꼬리표 · 브랜드 카드 경고)
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ⑥ · 작업표 docs/specs/2026-10-23-record-only-campaign-breakdown.md 조각 4
--   사용자 결정 S2(기록용은 경고에서 뺀다 — 캠페인 수·모집 인원 숫자는 그대로 센다) · S17(경고 줄 전용 모집률 칸)
--
-- 🔴 운영에 먼저 나가는 작업(사양서 배포 순서 ①) — 588 뒤에만(칸이 없으면 첫 호출에서 실패 — 함수 생성은 성공해 버린다)
--
-- 고치는 것(베이스 = 마지막 CREATE)
--   1) get_campaign_action_alerts() — 434(유일한 정의). target CTE 에 `AND c.is_record_only = false` 한 줄. 그 밖은 434 와 글자 그대로
--      (CREATE OR REPLACE — 실행 권한 {postgres, authenticated, service_role} 유지)
--   2) get_brand_ops_overview(uuid) — 259(120 → 148 → 181 → 259). 「표시 칸 / 경고 재료」를 가른다
--      · 표시 칸(그대로, 기록용 포함): active_campaigns · slots_total · approved_total · recruit_rate · 결과물 칸들
--      · 경고 재료(기록용 제외): d3_count · d1_count · soonest_deadline · alert_level · alert_reasons(판정 정원·모집률)
--        — 화면 경고 줄 문구 재료(admin-brand-ops.js brandOpsAlertReasonLines)와 같은 편
--      · 새 칸 alert_recruit_rate — 경고 줄 「모집률 N%」 전용(기록용 정원을 뺀 분모). 화면은 kemo-45 조각 8 이 쓴다(칸이 없으면 recruit_rate 로 대신)
--      · 기록용은 응모가 없어(588) app_agg·deliv_agg·cancel7 에는 처음부터 몫이 없다 — 손대지 않는다
--      반환 칸이 늘어 DROP 후 CREATE — 🔴 실행 권한을 끝에서 다시 건다(적용 전 개발 {postgres, service_role, authenticated})
--   · 바꾸지 않는 것: get_brand_ops_detail(259 — 브랜드 뷰 미니카드, S9) · 메일 사유 문구 표 두 벌 · _campaign_cert_success_counts(564)
--   · 짝: 화면 사본 ganttCampaignAlert(admin-brand-ops.js — 조각 8, 기록용이면 null)
--   · 화면 호출: storage.js fetchBrandOpsOverview → db.rpc('get_brand_ops_overview') 하나 — 결과를 칸 이름으로 읽는다(새 칸은 맨 끝, 순서 영향 없음)
--
-- 🔴 운영 적용 절차(조각 13 ⓪ — 실행 권한이 서버마다 다를 수 있다)
--   ① 적용 직전 운영에서 조회: SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--        WHERE n.nspname='public' AND p.proname IN ('get_brand_ops_overview','get_campaign_action_alerts');
--   ② 이 파일 실행(끝의 권한 줄은 개발에서 본 {postgres, service_role, authenticated} 를 건다)
--   ③ 같은 조회를 다시 — get_campaign_action_alerts 는 ①과 같아야 한다(CREATE OR REPLACE).
--      get_brand_ops_overview 가 ①과 다르면(예: ①에 service_role 이 없었음) 그 차이를 기획·사용자에게 알리고 ①에 맞춘다.
--      공개(PUBLIC)·비로그인(anon)이 나오면 안 된다
--
-- 편집기 경고: Supabase SQL 편집기의 「Success」는 이전 실행 잔상일 수 있다 — 끝의 기록 줄을 기록 표에서 확인한다.
--   두 함수 모두 is_admin() 가드라 SQL 편집기(서비스 키)로는 「forbidden」 — 관리자 로그인 흉내(request.jwt.claims) 또는 브라우저로 확인한다
--
-- 롤백(조각 3 보다 먼저, 칸(588)을 지우기 전에 — 화면 조각 8 이 alert_recruit_rate 를 안 읽는 상태에서)
--   434_campaign_action_alerts.sql 의 함수 블록(CREATE OR REPLACE ~ $$;)을 다시 실행
--   DROP FUNCTION public.get_brand_ops_overview(uuid); 후 259 의 get_brand_ops_overview 블록 + COMMENT + REVOKE/GRANT 다시 실행
--   (259 의 권한 줄은 service_role 을 안 건다 — 롤백 뒤 GRANT EXECUTE … TO service_role 를 함께)
--
-- 검증(개발서버 · 관리자 흉내)
--   기록용 시험 캠페인(active, 정원 10, 승인 0, 마감 2일 뒤)이 get_campaign_action_alerts 결과에 없고, 같은 조건의 일반 캠페인은 있다
--   그 브랜드의 get_brand_ops_overview 줄: slots_total 에는 기록용 정원이 들고, d3_count·alert_reasons·alert_recruit_rate 에는 기록용 몫이 없다
-- ============================================================
BEGIN;

-- ── 1. get_campaign_action_alerts — 베이스 434 ──
CREATE OR REPLACE FUNCTION public.get_campaign_action_alerts()
RETURNS TABLE (
  campaign_id     uuid,
  campaign_no     text,
  campaign_title  text,
  brand_name      text,
  recruit_type    text,
  status          text,
  level           text,
  reason_codes    text[],
  deadline        date,
  submission_end  date,
  days_left       integer,
  slots           integer,
  approved_count  integer,
  cert_raw        integer,
  cert_capped     integer,
  uncert_count    integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today date;
BEGIN
  -- 부르는 쪽이 둘 — 관리자(화면) 또는 로그인 없는 무인 실행(메일 배치).
  -- anon 은 auth.uid() 가 비어 이 가드를 통과하므로, anon 실행 권한을 아예
  -- 안 주는 것(아래 GRANT/REVOKE)이 진짜 방어선이다.
  IF NOT (public.is_admin() OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'permission_denied: get_campaign_action_alerts 는 관리자 또는 서비스 키만 호출할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  v_today := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  RETURN QUERY
  WITH target AS (
    -- 대상 = 모집중·모집마감이고 삭제되지 않은 캠페인.
    SELECT
      c.id, c.campaign_no, c.title, c.recruit_type, c.status,
      -- 브랜드명 — 화면 brandLabelAdmin(dev/lib/shared.js:2099) 과 같은 폴백.
      --   (c.brand || c.brand_en || c.brand_ja || '').trim()
      --   🔴 자바스크립트의 || 는 **빈 문자열도 건너뛴다** — 그래서 NULL 검사가 아니라
      --   NULLIF(...,'') 사슬이어야 같은 뜻이 된다. c.brand 만 보면
      --   brand 가 비고 brand_en·brand_ja 만 있는 캠페인에서 **메일 카드의 브랜드명이 빈다**.
      --   ⚠️ btrim 은 **고른 뒤 한 번만** 건다 — 후보마다 먼저 btrim 하면 「공백뿐인 brand」에서
      --   갈린다(자바스크립트는 공백뿐인 값을 그대로 골라 빈 문자열이 되고, 먼저 다듬으면
      --   다음 후보로 넘어간다). 실무 영향은 거의 없지만 「글자 그대로 같게」가 이 작업의 기준이다.
      btrim(COALESCE(
        NULLIF(c.brand, ''),
        NULLIF(c.brand_en, ''),
        NULLIF(c.brand_ja, ''),
        ''
      )) AS brand,
      c.deadline, c.submission_end,
      COALESCE(c.slots, 0)::integer AS slots
    FROM public.campaigns c
    WHERE c.status IN ('active', 'closed')
      AND c.deleted_at IS NULL
      AND c.is_record_only = false      -- [591] 기록용 캠페인 제외(작업표 조각 4 · S2) — 화면 사본 ganttCampaignAlert 와 짝
  ),
  appr AS (
    -- 승인 인원 — get_campaign_application_counts(179)와 같은 계산식을
    -- 직접 재현(그 함수는 is_admin() 가드라 무인 실행에서 못 부른다).
    SELECT a.campaign_id, COUNT(*) FILTER (WHERE a.status = 'approved')::integer AS approved
    FROM public.applications a
    JOIN public.influencers i ON i.id = a.user_id
    JOIN target t ON t.id = a.campaign_id
    WHERE i.is_audit = false
    GROUP BY a.campaign_id
  ),
  cert AS (
    -- 인증 성공 인원(cert_raw, 상한 전) — 433 의 내부 전용 함수.
    SELECT * FROM public._campaign_cert_success_counts(ARRAY(SELECT id FROM target))
  ),
  base AS (
    SELECT
      t.id, t.campaign_no, t.title, t.brand, t.recruit_type, t.status,
      t.deadline, t.submission_end, t.slots,
      COALESCE(ap.approved, 0)          AS approved_count,
      COALESCE(ce.cert_count, 0)        AS cert_raw,
      -- 남은 날 — 상태가 어느 마감을 보는지 정한다: active=모집 마감,
      -- closed=제출 마감. 날짜가 없거나 이미 지났으면(과거) NULL.
      CASE
        WHEN t.status = 'active' AND t.deadline IS NOT NULL AND t.deadline >= v_today
          THEN (t.deadline - v_today)
        WHEN t.status = 'closed' AND t.submission_end IS NOT NULL AND t.submission_end >= v_today
          THEN (t.submission_end - v_today)
        ELSE NULL
      END::integer AS days_left
    FROM target t
    LEFT JOIN appr ap ON ap.campaign_id = t.id
    LEFT JOIN cert ce ON ce.campaign_id = t.id
  ),
  scored AS (
    SELECT
      b.*,
      LEAST(b.approved_count, b.cert_raw)                          AS cert_capped,
      (b.approved_count - LEAST(b.approved_count, b.cert_raw))     AS uncert_count,
      -- 모집률(%) — 승인 인원은 늘 계산돼 있으므로(재료를 못 받는 상태가
      -- 없음) 게이트는 모집인원(slots) > 0 하나뿐(화면과 동일 가드).
      CASE WHEN b.slots > 0
        THEN ROUND((b.approved_count::numeric / NULLIF(b.slots, 0)) * 100)
        ELSE NULL
      END AS recruit_pct,
      -- 인증 성공률(%) — 모집마감 갈래의 게이트(승인 인원 > 0)와 동일 조건.
      CASE WHEN b.approved_count > 0
        THEN ROUND((LEAST(b.approved_count, b.cert_raw)::numeric / NULLIF(b.approved_count, 0)) * 100)
        ELSE NULL
      END AS cert_pct
    FROM base b
  ),
  flags AS (
    SELECT
      s.id, s.campaign_no, s.title, s.brand, s.recruit_type, s.status,
      s.deadline, s.submission_end, s.days_left, s.slots,
      s.approved_count, s.cert_raw, s.cert_capped, s.uncert_count,
      -- 마감 쌍(모집중 전용, else if 상호배타) — 코드 + 등급 순위(0=danger,1=warning)
      CASE
        WHEN s.status = 'active' AND s.days_left IS NOT NULL AND s.days_left <= 1 THEN 'deadline_1d'
        WHEN s.status = 'active' AND s.days_left IS NOT NULL AND s.days_left <= 3 THEN 'deadline_3d'
        ELSE NULL
      END AS code_deadline,
      CASE
        WHEN s.status = 'active' AND s.days_left IS NOT NULL AND s.days_left <= 1 THEN 0
        WHEN s.status = 'active' AND s.days_left IS NOT NULL AND s.days_left <= 3 THEN 1
        ELSE NULL
      END AS rank_deadline,
      -- 모집률 쌍(모집중 전용, else if 상호배타) — 0=danger, 2=caution
      CASE
        WHEN s.status = 'active' AND s.recruit_pct IS NOT NULL
             AND s.recruit_pct < 30 AND s.days_left IS NOT NULL AND s.days_left < 7
          THEN 'recruit_low_urgent'
        WHEN s.status = 'active' AND s.recruit_pct IS NOT NULL
             AND s.recruit_pct < 50 AND (s.days_left IS NULL OR s.days_left >= 7)
          THEN 'recruit_low'
        ELSE NULL
      END AS code_recruit,
      CASE
        WHEN s.status = 'active' AND s.recruit_pct IS NOT NULL
             AND s.recruit_pct < 30 AND s.days_left IS NOT NULL AND s.days_left < 7
          THEN 0
        WHEN s.status = 'active' AND s.recruit_pct IS NOT NULL
             AND s.recruit_pct < 50 AND (s.days_left IS NULL OR s.days_left >= 7)
          THEN 2
        ELSE NULL
      END AS rank_recruit,
      -- 모집마감 쌍(모집마감 전용, else if 상호배타, 승인 인원 > 0 게이트) —
      -- 0=danger(남은≤1일), 1=warning(남은 2~3일), 2=caution
      CASE
        WHEN s.status = 'closed' AND s.approved_count > 0
             AND s.days_left IS NOT NULL AND s.days_left <= 3 AND s.uncert_count > 0
          THEN 'uncert_near'
        WHEN s.status = 'closed' AND s.approved_count > 0
             AND s.days_left IS NOT NULL AND s.days_left <= 7
             AND s.cert_pct IS NOT NULL AND s.cert_pct < 50
          THEN 'result_low'
        ELSE NULL
      END AS code_result,
      CASE
        WHEN s.status = 'closed' AND s.approved_count > 0
             AND s.days_left IS NOT NULL AND s.days_left <= 3 AND s.uncert_count > 0
          THEN (CASE WHEN s.days_left <= 1 THEN 0 ELSE 1 END)
        WHEN s.status = 'closed' AND s.approved_count > 0
             AND s.days_left IS NOT NULL AND s.days_left <= 7
             AND s.cert_pct IS NOT NULL AND s.cert_pct < 50
          THEN 2
        ELSE NULL
      END AS rank_result
    FROM scored s
  ),
  alerts AS (
    SELECT
      f.*,
      -- LEAST() 는 NULL 을 무시하고, 인자 전부 NULL 이면 NULL 을 돌려준다 —
      -- 모집중 행은 rank_result 가 항상 NULL, 모집마감 행은 rank_deadline·
      -- rank_recruit 가 항상 NULL 이라(위 status 게이트), 상태별로 해당
      -- 안 되는 쌍은 자동으로 빠진다.
      LEAST(f.rank_deadline, f.rank_recruit, f.rank_result) AS min_rank,
      ARRAY_REMOVE(ARRAY[f.code_deadline, f.code_recruit, f.code_result], NULL) AS reason_codes
    FROM flags f
  )
  SELECT
    a.id                AS campaign_id,
    a.campaign_no,
    a.title             AS campaign_title,
    a.brand             AS brand_name,
    a.recruit_type,
    a.status,
    CASE a.min_rank WHEN 0 THEN 'danger' WHEN 1 THEN 'warning' WHEN 2 THEN 'caution' END AS level,
    a.reason_codes,
    a.deadline,
    a.submission_end,
    a.days_left,
    a.slots,
    a.approved_count,
    a.cert_raw,
    a.cert_capped,
    a.uncert_count
  FROM alerts a
  -- 경고가 없는 캠페인은 행을 안 돌려준다.
  WHERE a.min_rank IS NOT NULL;
END;
$$;

-- ── 2. get_brand_ops_overview — 베이스 259(120 → 148 → 181 → 259) ──
--   반환 칸이 늘어 CREATE OR REPLACE 가 안 된다 → DROP 후 CREATE + 실행 권한 다시 걸기(아래)
DROP FUNCTION IF EXISTS public.get_brand_ops_overview(uuid);

CREATE FUNCTION public.get_brand_ops_overview(p_company_id uuid DEFAULT NULL)
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
  d1_count              bigint,
  alert_recruit_rate    numeric      -- [591] 경고 줄 전용 모집률(기록용 제외) — 카드의 큰 숫자는 recruit_rate
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
      -- [591] 경고 재료 — 아래 slots_sum_alert·d3·d1·soonest_dl 은 기록용(is_record_only) 캠페인을 뺀다(S2).
      --   표시 칸(active_camps·slots_sum → active_campaigns·slots_total·recruit_rate)은 기록용도 그대로 센다.
      SUM(CASE WHEN c.status IN ('active','scheduled','closed') AND c.is_record_only = false THEN COALESCE(c.slots,0) ELSE 0 END)::bigint AS slots_sum_alert,
      SUM(CASE
            WHEN c.status = 'active'
             AND c.is_record_only = false      -- [591]
             AND c.deadline IS NOT NULL
             AND c.deadline <= (current_date + INTERVAL '3 days')::date
            THEN 1 ELSE 0
          END)::bigint AS d3,
      SUM(CASE
            WHEN c.status = 'active'
             AND c.is_record_only = false      -- [591]
             AND c.deadline IS NOT NULL
             AND c.deadline <= (current_date + INTERVAL '1 days')::date
            THEN 1 ELSE 0
          END)::bigint AS d1,
      MIN(CASE WHEN c.status = 'active' AND c.is_record_only = false THEN c.deadline END) AS soonest_dl,   -- [591] 기록용 제외
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
      (slots_alert > 0                                                     -- [591] 경고 전용 정원
         AND alert_pct < 30
         AND soonest_dl IS NOT NULL
         AND soonest_dl < (current_date + INTERVAL '7 days')::date)        AS flag_low_near,
      (d3 >= 1)                                                            AS flag_d3,
      (slots_alert > 0                                                     -- [591] 경고 전용 정원
         AND alert_pct < 50
         AND (soonest_dl IS NULL
              OR soonest_dl >= (current_date + INTERVAL '7 days')::date))  AS flag_low,
      d1          AS d1_val,
      d3          AS d3_val,
      cancel7     AS cancel7_val,
      slots_sum   AS slots_val,
      soonest_dl  AS soonest_dl_val,
      recruit_pct AS recruit_pct_val,
      alert_pct   AS alert_recruit_pct_val   -- [591]
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
        END AS recruit_pct,
        -- [591] 경고 전용 — 기록용 캠페인 정원을 뺀 분모(기록용은 응모가 없어 분자 approved_cnt 는 같다)
        COALESCE(ca.slots_sum_alert, 0)                        AS slots_alert,
        CASE
          WHEN COALESCE(ca.slots_sum_alert, 0) = 0 THEN NULL
          ELSE ROUND(100.0 * COALESCE(aa.approved_cnt, 0) / ca.slots_sum_alert, 1)
        END AS alert_pct
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
    fg.d1_val::bigint                                            AS d1_count,
    fg.alert_recruit_pct_val                                     AS alert_recruit_rate   -- [591]
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
  '[120 → 148 → 181 → 259 → 591] 운영 현황 페인용 브랜드 카드 그리드 집계. '
  '모집률·결과물률·D-3 임박·7일 취소·alert_level. '
  '148 추가: alert_reasons(조건 코드 배열)/soonest_deadline/d1_count. '
  '181 추가: app_agg/deliv_agg 에서 감사용(is_audit=true) 응모·결과물 제외. '
  '259 추가: camp_agg/app_agg/deliv_agg 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  '591 추가: 경고 재료(d3_count·d1_count·soonest_deadline·경고 판정)에서 기록용 캠페인 제외 + 칸 alert_recruit_rate(경고 줄 전용 모집률). '
  '표시 칸(active_campaigns·slots_total·recruit_rate)은 기록용도 센다. '
  'is_admin() 가드.';

-- 실행 권한 — DROP 후 CREATE 라 다시 건다(적용 전 개발: {postgres, service_role, authenticated} — 259 의 회수·부여 그대로 + service_role 보존)
GRANT EXECUTE ON FUNCTION public.get_brand_ops_overview(uuid) TO postgres, service_role, authenticated;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_brand_ops_overview(uuid) FROM anon;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '591', '591_action_alerts_exclude_record_only.sql');
COMMIT;
