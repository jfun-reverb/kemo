-- ============================================================
-- 143_promo_targets_total_counts.sql
-- 2026-05-19
--
-- 목적:
--   get_promo_digest_targets RPC 반환 시그니처에 캠페인 총수 2개 컬럼 추가.
--   기존 RPC 는 마감일 가까운 순으로 array 슬라이스 [1:5] 만 반환하므로
--   메일 본문 「他 N件のキャンペーン公開中」 안내 시 정확한 N 산정 불가.
--
--   본 마이그레이션은 슬라이스 전 매칭된 캠페인 총수를 추가 반환하도록 함수를 재정의.
--
-- 사양서:
--   docs/specs/2026-05-19-campaign-promo-email.md §16-5 (카드 5건 상한 + 「他 N件」 안내)
--
-- 시그니처 변경:
--   반환 컬럼 (기존 6개 → 8개):
--     influencer_id            uuid
--     email                    text
--     name                     text
--     unsubscribe_token        uuid
--     new_campaign_ids         uuid[]
--     deadline_d1_campaign_ids uuid[]
--     new_total_count          integer  ← 신규
--     deadline_d1_total_count  integer  ← 신규
--
-- 호출 측 영향:
--   - Edge Function notify-campaign-promo-digest 가 PR 2 에서 본 시그니처 사용
--   - 운영 DB 에 본 마이그레이션 미적용 상태로 Edge Function 호출 시 「column missing」 에러
--   → PR 2 머지 시 본 마이그레이션을 운영 DB 에 함께 적용
--
-- 전제 조건:
--   마이그레이션 141 (기존 get_promo_digest_targets) 적용 완료
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행 + 검증
--   2. 운영서버 SQL Editor 실행 (Edge Function 배포와 같은 묶음)
--
-- 롤백:
--   141 의 함수 정의로 다시 CREATE OR REPLACE (반환 컬럼 2개 제거)
-- ============================================================

BEGIN;

-- ============================================================
-- 시그니처 변경 → DROP 선행 필수 (CREATE OR REPLACE 는 반환 컬럼 변경 불가)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_promo_digest_targets(date);

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
  -- [A] 신규 캠페인 (p_digest_date 에 KST 기준 first_active_at 발생)
  --     캠페인 측 조건 (§16-1):
  --       - deadline 미경과
  --       - monitor 슬롯 잔여
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
  -- [B] D-1 임박 캠페인 (내일 마감, 아직 active)
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
  -- [C] 발송 대상 인플루언서 기본 조건
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
  -- [D] 신규 캠페인 × 인플루언서 매칭
  --     변경점: COUNT(*) 로 매칭 총수도 함께 집계 (슬라이스 전)
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
  -- [E] D-1 임박 캠페인 × 인플루언서 매칭
  --     변경점: COUNT(*) 로 매칭 총수도 함께 집계
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
  -- [F] 두 매칭 결합 — total_count 까지 누적 반환
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
  -- [G] 최종 반환
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

-- DROP 시 권한 함께 소실 → 다시 부여 (141 와 동일 권한 정책)
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_promo_digest_targets(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_targets(date) IS
  '[143] 홍보 메일 발송 대상 조회. 신규·D-1 섹션 각각 캠페인 ID 배열(최대 5건) + 매칭 총수 반환. 「他 N件」 안내 정확도 향상. SECURITY DEFINER + search_path 고정.';

COMMIT;
