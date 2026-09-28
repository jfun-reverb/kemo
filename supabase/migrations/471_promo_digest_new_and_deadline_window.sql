-- ============================================================
-- 471_promo_digest_new_and_deadline_window.sql
-- 캠페인 홍보 메일 — 「신규」 창을 14일로, 「마감 임박」을 다음 발송일까지로
-- 사양서: docs/specs/2026-09-28-promo-mail-new-and-deadline-window.md §4-1 ②
--
-- ── 왜 ──
--   「신규」 조건이 `first_active_at::date = 발송일`(당일 하루)이라 출시 이후 **한 번도** 안 나갔다
--   (운영 2026-09-28: campaign_promo_exposure kind='new' 전체 0건 — 모집 전환은 목록 조회 때
--   일어나 09:00 발송 시점엔 그날 전환분이 거의 없다). 마감 임박은 「내일 마감」 하루뿐이었다.
--
-- ── 무엇을 ──
--   ⓪ 도우미 _promo_next_send_date(date) — 다음 발송일(월 → 목, 목 → 다음 월). 두 함수·두 절이
--      **이 한 벌만** 쓴다(사본이 갈리면 틈이나 겹침이 생긴다).
--   ① 신규: 모집 시작이 발송일-13 ~ 발송일(도쿄 날짜) + 마감이 다음 발송일 **뒤** 또는 마감일 없음
--   ② 마감 임박: 마감이 발송일(당일 포함) ~ 다음 발송일
--   ③ CURRENT_DATE(세계시) → p_digest_date 전부 — 예약 시각이 바뀌면 깨지던 잠복 결함 제거
--   그 밖(반환 칸·정렬·삭제·초대 전용·정원·채널·팔로워·탈퇴·수신 동의·응모·클릭·노출 이력)은
--   베이스와 **글자 그대로** 같다 — 이 파일은 작성 스크립트가 베이스 본문을 복사해 위 자리만 바꿨다.
--
-- ── 베이스 ──
--   get_promo_digest_targets      — **417** (141→143→259→321→360→387→417)
--   get_promo_digest_campaign_pool — **321** (권한은 375)
--
-- 🔴 **반드시 CREATE OR REPLACE 로만** — DROP 후 CREATE 하면 375 의 회수가 풀려 로그인한 회원
--    누구나 다른 회원 이메일·수신거부 토큰을 받는다. 인자(p_digest_date date)가 그대로라 DROP 이 필요 없다.
--
-- ── 배포 순서 ── 🔴 Edge Function(「締切間近 D-1」→「締切間近」) 먼저, 이 파일 나중.
--   반대면 옛 칩이 최대 4일 뒤 마감에 「D-1」을 찍는다.
-- ============================================================

-- ⓪ 다음 발송일 — isodow 월=1 … 일=7. 월·화·수 → 그 주 목요일 / 목·금·토·일 → 다음 월요일.
--   수동으로 다른 요일에 불러도 그다음 월 또는 목이 된다(사양서 「의도 모호점」).
CREATE OR REPLACE FUNCTION public._promo_next_send_date(p_date date)
RETURNS date
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN extract(isodow FROM p_date) BETWEEN 1 AND 3 THEN p_date + (4 - extract(isodow FROM p_date))::int
    ELSE p_date + (8 - extract(isodow FROM p_date))::int
  END
$$;

COMMENT ON FUNCTION public._promo_next_send_date(date) IS
  '[471] 홍보 메일 다음 발송일(월→목, 목→다음 월). get_promo_digest_targets·get_promo_digest_campaign_pool 의 신규·마감 임박 경계가 이 한 벌만 쓴다.';

-- 안쪽 전용 — 계산만 하지만 회수 방향 둘 다 닫는다(369·370 규칙)
REVOKE ALL ON FUNCTION public._promo_next_send_date(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._promo_next_send_date(date) FROM anon, authenticated;

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

-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 권한 — 두 함수 모두 anon·authenticated 실행 불가, PUBLIC 없음(375 그대로여야 한다)
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_ok,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_ok,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as service_ok,
       left(p.proacl::text, 4) = chr(123) || '=X/'               as public_remains
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_promo_digest_targets','get_promo_digest_campaign_pool','_promo_next_send_date');
-- 기대: anon_ok false · auth_ok false · public_remains false · (대상·풀) service_ok true

-- [V2] 다음 발송일 — 월 2026-09-28 → 목 10-01 / 목 10-01 → 월 10-05 / 일 10-04 → 월 10-05
select public._promo_next_send_date('2026-09-28'), public._promo_next_send_date('2026-10-01'),
       public._promo_next_send_date('2026-10-04');

-- [V3] 대상 조회만(🔴 Edge Function 은 부르지 않는다 — 개발서버 메일 시험 금지)
select count(*), sum(new_total_count), sum(deadline_d1_total_count)
  from public.get_promo_digest_targets(current_date);
select * from public.get_promo_digest_campaign_pool(current_date);
*/
