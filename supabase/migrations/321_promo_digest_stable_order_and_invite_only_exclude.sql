-- ============================================================
-- 321_promo_digest_stable_order_and_invite_only_exclude.sql
-- 캠페인 홍보 메일 — ①대상자 명단에 정렬 기준 추가 ②초대 전용 캠페인 제외
-- 사양: 전수조사 후속 조치 묶음 C — C-3(정렬) · C-4(비공개 캠페인 제외)
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -n "CREATE OR REPLACE FUNCTION public.get_promo_digest_targets\|
--            CREATE OR REPLACE FUNCTION public.get_promo_digest_campaign_pool"
--     supabase/migrations/*.sql
--   → get_promo_digest_targets       : 141 → 143 → 259 (259 가 가장 큰 번호)
--   → get_promo_digest_campaign_pool : 152 → 259        (259 가 가장 큰 번호)
--   두 함수 모두 **259 를 베이스로** 재정의한다. 259 는 「보관 삭제
--   (deleted_at) 캠페인 제외」 한 가지만 바꾼 파일이라, 이번 변경도 그
--   위에 이어 붙인다(259 의 deleted_at 제외 조건은 그대로 유지).
--
-- ▶ C-3 — 정렬 기준 없음 (get_promo_digest_targets 만 해당)
--   Edge Function `notify-campaign-promo-digest` 는 이 함수가 돌려주는
--   명단을 200명씩 끊어 나눠 보낸다. 그런데 이 함수에 ORDER BY 가 없어
--   Postgres 가 매번 다른 순서로 행을 돌려줄 수 있다 — 어디까지 처리했는지
--   재현이 안 되고, 몇 번째 200명이 누구인지도 실행마다 달라진다.
--   최종 SELECT 에 `ORDER BY t.influencer_id` 를 추가해 항상 같은 순서로
--   고정한다. 인플루언서 고유 번호(항상 있고 안 바뀜) 기준이라 가장 단순
--   하고 안전하다.
--   ⚠️ Edge Function 쪽도 같은 마이그레이션 세트로 함께 고친다(무한 반복
--   방어 포함) — `supabase/functions/notify-campaign-promo-digest/index.ts`.
--   get_promo_digest_campaign_pool 은 관리자용 「그날 캠페인 풀」 하나를
--   집계값(배열)으로만 돌려줄 뿐 인플루언서별로 나눠 보내는 대상이 아니라
--   (=배치 처리 대상이 아니라) 이 정렬 문제와 무관 — 손대지 않는다.
--
-- ▶ C-4 — 초대 전용(is_invite_only=true) 캠페인이 전체 홍보 메일로 나감
--   campaigns.is_invite_only(마이그레이션 280)가 이 두 함수 어디에도
--   없었다. 인플루언서 화면(dev/js/campaign.js visibleCamps)은 이미
--   `isInviteOnlyCampaign()` 으로 걸러 목록·홈에서 빼고 있는데, 홍보 메일
--   선정 두 함수만 그 조건을 몰랐다. 8/28 팝업처럼 초대 전용이면서
--   모집중(active)이고 마감이 임박한 캠페인이 있으면, 자격이 맞는
--   인플루언서 전원에게 「마감 임박」 카드로 나갈 수 있었다.
--   new_campaigns / deadline_d1_campaigns 두 CTE(신규·D-1 각각) 조건에
--   `AND c.is_invite_only = false` 추가. is_invite_only 는
--   `NOT NULL DEFAULT false`(280) 라 값이 비어 있을 일이 없다.
--   ⚠️ 대상 함수가 둘이다 — get_promo_digest_targets(인플루언서 개인화
--   명단) · get_promo_digest_campaign_pool(관리자용 풀 전체). 둘 다
--   고쳐야 관리자 메일에도 안 실린다.
--
-- ▶ 반환 타입 불변 — 두 함수 모두 CREATE OR REPLACE (DROP 불필요)
--
-- ▶ 롤백
--   259 파일의 두 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행하면
--   이 변경만 되돌아간다(ORDER BY·is_invite_only 조건 제거).
-- ============================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════════
-- 1. get_promo_digest_targets — 베이스: 259 (141 → 143 → 259 → 321)
--    변경: ① new_campaigns/deadline_d1_campaigns 에 is_invite_only 제외
--          ② 최종 SELECT 에 ORDER BY t.influencer_id 추가
--    (반환 컬럼 8개 불변 → CREATE OR REPLACE)
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
  -- [A] 신규 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
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
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
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
  -- [B] D-1 임박 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
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
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
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
  -- [G] 최종 반환 — [321] ORDER BY 추가(정렬 기준 없어 순서가 매번 달랐던 문제)
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
  JOIN public.influencers i ON i.id = t.influencer_id
  ORDER BY t.influencer_id;   -- [321] 안정적인 정렬 — Edge Function 이 매번 앞에서부터
                               --   200명씩 잘라 처리하므로 순서가 고정돼야 재현 가능하다.
$$;

REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_promo_digest_targets(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_targets(date) IS
  '[141 → 143 → 259 → 321] 홍보 메일 발송 대상 조회. 신규·D-1 섹션 각각 캠페인 ID 배열(최대 5건) + 매칭 총수 반환. '
  '259: new_campaigns/deadline_d1_campaigns 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  '321: 초대 전용(is_invite_only=true) 캠페인 제외 + 결과에 ORDER BY influencer_id 추가(Edge Function 배치 처리가 매번 같은 순서를 전제하기 때문). '
  'SECURITY DEFINER + search_path 고정.';


-- ════════════════════════════════════════════════════════════════════
-- 2. get_promo_digest_campaign_pool — 베이스: 259 (152 → 259 → 321)
--    변경: new_campaigns/deadline_d1_campaigns 에 is_invite_only 제외만
--          (배치 처리 대상이 아니므로 정렬 변경 없음)
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
  -- [A] 신규 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
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
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
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
  -- [B] D-1 임박 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
  -- ──────────────────────────────────────────────────────────
  deadline_d1_campaigns AS (
    SELECT
      c.id,
      c.deadline
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND c.deadline = CURRENT_DATE + 1
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
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
  '[152 → 259 → 321] 관리자 홍보 메일용 캠페인 풀 조회. '
  '신규·D-1 섹션 캠페인 ID 배열 + 총수 반환. '
  'get_promo_digest_targets 와 캠페인 선정 조건 동기화. '
  '인플 개인화 조건(채널 매칭·팔로워·응모/노출/클릭 제외) 없음 — 관리자는 풀 전체. '
  '259: new_campaigns/deadline_d1_campaigns 에서 보관 삭제(deleted_at IS NOT NULL) 캠페인 제외. '
  '321: 초대 전용(is_invite_only=true) 캠페인 제외. '
  'SECURITY DEFINER + search_path 고정.';

-- PostgREST 스키마 캐시 리로드 (함수 본문만 바뀌었지만 관례상 포함)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (마이그레이션 적용 후 SQL Editor에서 실행 — 1단계씩 순차)
--   ⚠️ 이 마이그레이션은 SQL 함수만 바꾼다. 실제 메일 발송 테스트는
--   개발서버에서 하지 않는다(프로젝트 규칙) — 아래는 함수 재정의·조건
--   반영 여부만 데이터 조회로 확인하는 SQL 이다.
-- ============================================================

-- [1] 함수 2개가 재정의됐는지 확인 (COMMENT 에 321 포함 여부)
-- SELECT p.proname, obj_description(p.oid) AS comment
--   FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public'
--    AND p.proname IN ('get_promo_digest_targets','get_promo_digest_campaign_pool');
-- 기대값: 2행, comment 에 "321" 포함

-- [2] 정렬 확인 — 같은 날짜로 두 번 연달아 호출해도 순서가 같은지
--     (대상자가 있는 실제 날짜로 바꿔서 실행. 대상자가 0명이면 빈 결과가 정상)
-- SELECT influencer_id FROM public.get_promo_digest_targets(CURRENT_DATE);
-- SELECT influencer_id FROM public.get_promo_digest_targets(CURRENT_DATE);
-- → 두 결과의 influencer_id 순서가 완전히 같아야 한다(ORDER BY 적용 확인)

-- [3] 초대 전용 캠페인이 신규/D-1 후보 자체에서 빠지는지 — 조건 재현
--     (campaigns 원본 조건과 똑같이 짜서, is_invite_only=true 캠페인이
--     여기서부터 걸러지는지 직접 확인. 오늘 날짜 기준)
-- SELECT id, title, campaign_no, is_invite_only, status, deadline
--   FROM public.campaigns
--  WHERE is_invite_only = true
--    AND status = 'active'
--    AND (deadline = CURRENT_DATE + 1 OR (first_active_at AT TIME ZONE 'Asia/Seoul')::date = CURRENT_DATE);
-- → 여기 나온 캠페인들의 id 가, [2]에서 실행한 get_promo_digest_targets 결과의
--   new_campaign_ids / deadline_d1_campaign_ids 배열 어디에도 없어야 한다.
--   (초대 전용 캠페인이 오늘 하나도 없으면 0행 — 그럴 땐 8/28 팝업 캠페인을
--   등록한 뒤 같은 조회로 재확인)

-- [4] 관리자 풀에서도 빠지는지
-- SELECT * FROM public.get_promo_digest_campaign_pool(CURRENT_DATE);
-- → new_campaign_ids / deadline_d1_campaign_ids 에 [3]에서 나온 초대 전용
--   캠페인 id 가 없어야 한다.
-- ============================================================
