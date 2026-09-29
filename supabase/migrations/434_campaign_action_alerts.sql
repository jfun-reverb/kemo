-- ============================================================
-- 434_campaign_action_alerts.sql
-- 관리자 일일 메일 「조치가 필요한 캠페인」 절 — 데이터베이스 함수 ②
-- 캠페인별 조치 필요 경고(운영현황 일정 뷰 · 관리자 일일 메일 공용 재료)
--
-- 사양서: docs/specs/2026-09-11-admin-digest-deadline-section.md §3-1 ②
-- 작업표: docs/specs/2026-09-11-admin-digest-deadline-section-breakdown.md 작업 2
--
-- ── 무엇을 하나 ──
--   인자 없이 호출하면, 모집중(active)·모집마감(closed) 캠페인 중 「조치가
--   필요」한 캠페인만 1건 = 1행으로 돌려준다(경고가 없는 캠페인은 행 자체가
--   없다). 판정은 dev/js/admin-brand-ops.js 의 ganttCampaignAlert(c, stats)
--   를 **그대로** 옮긴 것 — 임계값·갈래·경계 처리를 바꾸지 않는다(사양서
--   §3-0 원칙 「판정은 서버 함수 한 곳. 옮기는 것이지 바꾸는 것이 아니다」).
--
-- 🔴 부르는 쪽이 둘이다 — ①운영현황 일정 뷰(로그인한 관리자, storage.js 경유)
--   ②관리자 일일 메일(pg_cron → Edge Function, 로그인 없는 무인 실행). 그래서
--   가드가 is_admin() 하나가 아니라 「is_admin() 또는 auth.uid() IS NULL」이다
--   (모집 마감 서버 강제 트리거[마이그레이션 272→326]가 쓰는 것과 같은 형태 —
--   「배치·서비스 키」 통과 조항). anon 은 auth.uid() 가 비어 이 가드를
--   통과하므로, anon 실행 권한을 아예 안 주는 것이 유일한 방어선이다.
--
-- ── 판정 원문(화면과 글자 그대로 같아야 하는 부분) ──
--   「오늘」= (now() AT TIME ZONE 'Asia/Tokyo')::date. 남은 날은 화면의
--   daysTo(ymd) 와 동일 — 날짜가 없거나 이미 지났으면 NULL(0 이하 음수가
--   되는 경우 포함). 🔴 SQL 의 NULL <= n 은 결과적으로 "참이 아님"이 되어
--   화면과 같게 동작하지만, 이 함수는 그 3값 논리에 기대지 않고 모든 갈래에
--   `days_left IS NOT NULL` 을 명시적으로 적는다(나중에 화면으로 되옮길 때
--   조용히 되살아나는 것을 막기 위함 — 사양서 §1-2 마지막 🔴 항목).
--
--   모집중(active) — 두 쌍이 각각 독립(else if 로 쌍 내부만 상호배타, 최대
--   2줄):
--     마감 쌍   deadline_1d(남은≤1일, danger) / deadline_3d(남은 2~3일, warning)
--     모집률 쌍 recruit_low_urgent(모집률<30% 그리고 남은<7일, danger)
--               / recruit_low(모집률<50% 그리고 (남은=NULL 또는 남은≥7일), caution)
--     🔴 모집률은 `승인 인원 IS NOT NULL 그리고 모집인원(slots) > 0` 일 때만
--     계산한다 — 모집인원 0인 캠페인은 이 쌍이 통째로 안 뜬다(화면에 있는
--     가드, 사양서 §1-2 「표에 안 담긴 가드 1」).
--
--   모집마감(closed) — 한 쌍만(최대 1줄), 🔴 **승인 인원 > 0 일 때만** 판정:
--     uncert_near(제출 마감 남은≤3일 그리고 미인증≥1명, 남은≤1일 danger·
--                 그 밖 warning)
--     result_low(제출 마감 남은≤7일 그리고 인증 성공률<50%, caution)
--     ※ 화면에는 "재료를 못 받은 상태"(승인 수 조회 실패·결과물 집계 조회
--     실패/집계중)가 따로 있었지만, 이 함수는 승인 인원·인증 성공 인원을
--     **같은 트랜잭션 안에서 직접 센다** — 그 상태가 아예 없다. 승인 0명이면
--     이 쌍을 안 그리고(위 가드), 결과물 0건이면 인증 성공 0명으로 정상
--     판정한다(화면과 같은 동작 — 사양서 §3-1 ② 🔴 항목).
--
--   여러 줄이면 등급이 가장 높은 것(danger > warning > caution)이 캠페인
--   등급. 🔴 사유 문구는 이 함수가 만들지 않는다 — **사유 코드만** 준다
--   (여섯: deadline_1d · deadline_3d · recruit_low_urgent · recruit_low ·
--   uncert_near · result_low). 문구 조립은 화면(작업 3)·메일(작업 6)이
--   각자 「코드 → 한국어 문구」 표로 한다(사양서 §1-2 표가 그 표의 기준).
--
-- ── 재료 ──
--   승인 인원 — 🔴 get_campaign_application_counts(마이그레이션 179 원본)
--   를 부르지 않는다. 그 함수는 본문 첫 줄이 `IF NOT public.is_admin() THEN
--   RAISE` 라 무인 실행(pg_cron → Edge Function)에서 반드시 막힌다. 이
--   함수가 **같은 기준**(승인 상태 신청 수, 감사용 계정만 제외)으로 직접
--   센다 — 179 와 계산식은 같되 함수 호출은 안 한다.
--   인증 성공 인원 — 433_campaign_cert_success_counts.sql 의
--   _campaign_cert_success_counts(uuid[]) 를 부른다(제외 셋이 승인 인원과
--   다르다 — 감사용·임시저장·반려/취소. 사양서 §3-1 ② 🔴 항목).
--   🔴 두 값을 함께 돌려준다 — cert_raw(상한 전 원값)와
--   cert_capped(min(승인 인원, cert_raw)). 미인증 인원 = 승인 인원 −
--   cert_capped. 판정(uncert_near·result_low)에는 cert_capped 를 쓴다
--   (화면과 동일).
--
-- 롤백: DROP FUNCTION IF EXISTS public.get_campaign_action_alerts();
--   (데이터베이스 함수만 지워도 무해 — 아무도 안 부를 뿐. 단 이 함수가 화면·
--   메일 배포 뒤에 사라지면 경고·다섯째 절이 통째로 사라지므로, 되돌릴 때는
--   코드를 먼저 되돌리고 이 함수는 나중에 지운다.)
-- ============================================================

BEGIN;

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

COMMENT ON FUNCTION public.get_campaign_action_alerts() IS
  '캠페인별 「조치가 필요한」 경고 — dev/js/admin-brand-ops.js 의 '
  'ganttCampaignAlert(c, stats) 화면 판정을 옮긴 것(임계값·갈래·null 처리 '
  '무변경). 운영현황 일정 뷰(관리자 로그인)와 관리자 일일 메일 다섯째 절 '
  '「조치가 필요한 캠페인」(pg_cron 무인 실행) 이 함께 쓴다. 문구는 만들지 '
  '않고 사유 코드만 준다 — 코드→한국어 문구 표는 호출부(화면·메일)가 각자 '
  '조립한다(사양서 docs/specs/2026-09-11-admin-digest-deadline-section.md).';

-- 서비스 키·소유자 권한·로그인 관리자 권한을 먼저 못 박는다(마이그레이션 375
-- 「부여 먼저, 회수 나중」 선례). authenticated 는 화면(일정 뷰)이 브라우저
-- 에서 직접 부르므로 필요 — 이 뒤에 authenticated 를 다시 회수하지 않는다.
GRANT EXECUTE ON FUNCTION public.get_campaign_action_alerts() TO postgres, service_role, authenticated;

REVOKE EXECUTE ON FUNCTION public.get_campaign_action_alerts() FROM PUBLIC;
-- 🔴 anon 에는 실행 권한을 주지 않는다 — 익명은 auth.uid() 가 비어 함수
-- 안쪽 가드(is_admin() OR auth.uid() IS NULL)를 통과하므로, 이 REVOKE 가
-- 유일한 방어선이다.
REVOKE EXECUTE ON FUNCTION public.get_campaign_action_alerts() FROM anon;

COMMIT;

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 Success」는 검증이 아니다 — 첫 호출에서 터진다)
-- ============================================================
/*
-- [V1] 실행 권한 — postgres·service_role·authenticated 는 true, anon 은 false
SELECT has_function_privilege('postgres',      p.oid, 'EXECUTE') AS postgres,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS service_role,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'get_campaign_action_alerts';

-- [V1-b] 🔴 PUBLIC 부여가 남아 있으면 [V1] 의 비로그인 열도 true 로 보일 수
-- 있다 — 실제 목록의 맨 앞에 `=X/` 가 없는지 눈으로 확인.
--   SELECT p.proname, p.proacl::text
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'get_campaign_action_alerts';

-- [V2] 가드 통과 시험 둘 — SQL 편집기(서비스 키, auth.uid() IS NULL)만으로는
-- ①을 재현 못 한다(로그인 사용자가 없어 is_admin() 분기가 안 돈다).
--   ① 관리자 세션(브라우저 콘솔, 실제 로그인한 관리자로):
--        await db.rpc('get_campaign_action_alerts')
--      기대: 정상 응답(권한 오류 아님).
--   ② 서비스 키(SQL 편집기 — 무인 실행 자리 재현):
--        SELECT * FROM public.get_campaign_action_alerts();
--      기대: 정상 응답(auth.uid() IS NULL 통과 조항).
--
-- [V3] 같은 날 일정 뷰 화면의 경고 목록과 캠페인·등급·사유 코드가 일치하는지
-- 대조(문구가 아니라 코드로 — 문구 대조는 작업 6·9). 등급 코드는
-- BRAND_OPS_ALERT_RANK 와 같은 이름(danger/warning/caution).
*/

-- 롤백: DROP FUNCTION IF EXISTS public.get_campaign_action_alerts();
--   (화면·메일이 이미 배포된 뒤라면, 코드를 먼저 되돌리고 이 함수는 나중에
--   지운다 — 반대로 하면 경고·다섯째 절이 함수 없이 호출되어 통째로 사라진다.)
