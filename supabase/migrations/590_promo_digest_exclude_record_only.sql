-- ============================================================
-- 590_promo_digest_exclude_record_only.sql
-- 2026-10-23 — 캠페인 홍보 메일 두 함수에서 기록용 캠페인을 뺀다
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ⑥ · 작업표 docs/specs/2026-10-23-record-only-campaign-breakdown.md 조각 3
--
-- 🔴 운영에 먼저 나가는 작업(사양서 배포 순서 ①) — 588 뒤에만(칸이 없으면 첫 호출에서 실패 — 함수 생성은 성공해 버린다)
--
-- 고치는 것(베이스 = 471, 두 함수 모두 마지막 CREATE)
--   get_promo_digest_targets(date) · get_promo_digest_campaign_pool(date)
--   신규·마감 임박 CTE 네 곳(대상 new_campaigns·deadline_d1_campaigns / 풀 new_campaigns·deadline_d1_campaigns)의
--   `AND c.is_invite_only = false` 바로 아래에 `AND c.is_record_only = false` 한 줄씩.
--   그 밖은 471 과 **글자 그대로** — 이 파일은 작성 스크립트가 471 본문(52~403줄)을 복사해 네 줄만 넣었다.
--   · 바꾸지 않는 것: _promo_next_send_date(471) · 반환 칸·정렬·인자
--
-- 🔴 **반드시 CREATE OR REPLACE 로만** — DROP 후 CREATE 하면 375 의 실행 권한 회수가 풀려 로그인한 회원
--    누구나 다른 회원 이메일·수신거부 토큰을 받는다. 인자가 그대로라 DROP 이 필요 없다.
--
-- 편집기 경고: Supabase SQL 편집기의 「Success」는 이전 실행 잔상일 수 있다 — 끝의 기록 줄을 기록 표에서 확인한다.
--
-- 롤백(조각 2 보다 먼저, 칸(588)을 지우기 전에): 471_promo_digest_new_and_deadline_window.sql 의 두 함수 블록
--   (「-- ① 회원별 대상」부터 get_promo_digest_campaign_pool 끝 $$; 까지)을 다시 실행
--
-- 검증(개발서버 · SQL 편집기나 명령줄 — 두 함수는 서비스 키 전용이라 편집기로 재현된다)
--   [V1] 실행 권한이 적용 전과 같다 — 471 하단 [V1] 조회(anon·authenticated false, PUBLIC 없음, service_role true)
--   [V2] 기록용 시험 캠페인(모집 중, 마감 다음 발송일 이내 또는 신규 창 안)이 get_promo_digest_campaign_pool(발송일) 결과에 없고,
--        같은 조건의 일반 캠페인은 있다. 🔴 실발송 시험은 하지 않는다(Edge Function 을 부르지 않는다)
-- ============================================================
BEGIN;

-- ① 회원별 대상 — 베이스 417
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
      c.channel_match,             -- [387] 「그리고」 갈래 판정에 필요
      c.min_followers_by_channel,  -- [387] 채널별 기준
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      -- [471] 신규 = 모집 시작이 발송일 포함 14일 이내(발송일-13 ~ 발송일, 도쿄 날짜) — 「당일 하루」에서 넓힘
      AND (c.first_active_at AT TIME ZONE 'Asia/Tokyo')::date BETWEEN p_digest_date - 13 AND p_digest_date
      -- [471] 다음 발송일까지 마감되는 것은 마감 임박 절이 맡는다(두 절이 겹치지 않게). 마감일 없음은 신규 대상
      AND (c.deadline IS NULL OR c.deadline > public._promo_next_send_date(p_digest_date))
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND c.is_record_only = false      -- [590] 기록용 캠페인 제외(작업표 조각 3)
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
      c.channel_match,             -- [387] 「그리고」 갈래 판정에 필요
      c.min_followers_by_channel,  -- [387] 채널별 기준
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      -- [471] 마감 임박 = 발송일(당일 포함) ~ 다음 발송일 마감. 종류 값 'deadline_d1' 은 이력 때문에 그대로 둔다
      --   ⚠️ 당일을 빼면 직전 발송 뒤 시작해 이번 발송일에 마감되는 캠페인이 어느 메일에도 안 나간다
      AND c.deadline BETWEEN p_digest_date AND public._promo_next_send_date(p_digest_date)
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND c.is_record_only = false      -- [590] 기록용 캠페인 제외(작업표 조각 3)
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
      -- [360] 탈퇴 절차가 진행 중이거나 끝난 회원은 홍보 메일 대상에서 뺀다.
      --   ⚠️ `cancelled` 는 넣지 않는다 — 탈퇴를 취소한 회원은 **즉시 대상으로 돌아와야**
      --     한다. 이 조건이 매번 상태를 다시 읽는 구조라, 되살리는 처리를 따로 만들지
      --     않아도 자동으로 복귀한다(작업표 작업 16 의 「자동 복귀」가 이 뜻이다).
      --   ⚠️ 확정된 회원은 메일 주소가 자리표시 주소로 바뀌어 어차피 닿지 않지만,
      --     발송 시도 자체가 메일 한도를 태우고 반송을 만든다.
      AND NOT EXISTS (
        SELECT 1
          FROM public.withdrawal_requests w
         WHERE w.influencer_id = i.id
           AND w.status IN ('pending_payout', 'scheduled', 'done')
      )
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
        ('instagram' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR ('tiktok' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR ('x' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.x       IS NOT NULL AND i.x       <> '')
        OR ('youtube' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers,
            c.channel_match, c.min_followers_by_channel  -- [387]
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
        ('instagram' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR ('tiktok' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR ('x' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.x       IS NOT NULL AND i.x       <> '')
        OR ('youtube' = ANY(string_to_array(lower(replace(c.channel, ' ', '')), ',')) AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers,
            c.channel_match, c.min_followers_by_channel  -- [387]
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

-- ② 관리자 요약 풀 — 베이스 321
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
      -- [471] 신규 = 모집 시작이 발송일 포함 14일 이내(발송일-13 ~ 발송일, 도쿄 날짜) — 「당일 하루」에서 넓힘
      AND (c.first_active_at AT TIME ZONE 'Asia/Tokyo')::date BETWEEN p_digest_date - 13 AND p_digest_date
      -- [471] 다음 발송일까지 마감되는 것은 마감 임박 절이 맡는다(두 절이 겹치지 않게). 마감일 없음은 신규 대상
      AND (c.deadline IS NULL OR c.deadline > public._promo_next_send_date(p_digest_date))
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND c.is_record_only = false      -- [590] 기록용 캠페인 제외(작업표 조각 3)
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
      -- [471] 마감 임박 = 발송일(당일 포함) ~ 다음 발송일 마감. 종류 값 'deadline_d1' 은 이력 때문에 그대로 둔다
      --   ⚠️ 당일을 빼면 직전 발송 뒤 시작해 이번 발송일에 마감되는 캠페인이 어느 메일에도 안 나간다
      AND c.deadline BETWEEN p_digest_date AND public._promo_next_send_date(p_digest_date)
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND c.is_record_only = false      -- [590] 기록용 캠페인 제외(작업표 조각 3)
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

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '590', '590_promo_digest_exclude_record_only.sql');
COMMIT;
