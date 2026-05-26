-- ============================================================
-- 141_promo_digest_helpers.sql
-- 2026-05-19
--
-- 목적:
--   캠페인 홍보 메일 다이제스트 핵심 함수 3종 신설.
--   Edge Function notify-campaign-promo-digest 가 사용.
--
-- 사양서:
--   docs/specs/2026-05-19-campaign-promo-email.md §3-3, §16-1·2·3·5, §17-4
--
-- 신설 함수:
--   1. _meets_min_followers(recruit_type, primary_channel, channels, min_followers, ig/tiktok/x/youtube followers) → boolean
--      팔로워 수 매칭 헬퍼. primary_channel 기준 (FEATURE_SPEC §10 정책 동일).
--      monitor(리뷰어) 캠페인은 항상 true (팔로워 무관).
--
--   2. get_promo_digest_targets(p_digest_date date)
--      → (influencer_id, email, name, unsubscribe_token,
--          new_campaign_ids uuid[], deadline_d1_campaign_ids uuid[])
--      발송 대상자 조회. 주 2회 cron 이 호출.
--      매칭 정책 (사양서 §16·§17 확정):
--        - 신규 캠페인: first_active_at 가 p_digest_date 의 KST 윈도우 안
--        - D-1 임박: deadline 가 tomorrow (KST 기준 내일)
--        - 자격 매칭: 채널 포함 + 팔로워 충족 (monitor 제외)
--        - 캠페인 조건: deadline 미경과 + monitor 슬롯 잔여
--        - 응모 제외: cancelled 만 「미응모」 간주, pending/approved/rejected 제외
--        - 노출 제외: campaign_promo_exposure 에 이미 기록된 (campaign, influencer, kind)
--        - 클릭 제외: campaign_promo_email_clicks 에 기록된 (campaign, influencer)
--        - 발송 제외: campaign_promo_digest_sent 에 오늘 발송 기록 있는 인플
--        - 인플 필수 정보 미완성자는 제외 안 함 (§16-1 — 응모 시점 모달에서 추가 등록 가능)
--        - 마감일 가까운 순 정렬 (array_agg ORDER BY deadline ASC)
--        - 캠페인 수 상한: 신규 5건, D-1 5건 (§16-5)
--
--   3. mark_promo_digest_sent(...)
--      인플별 발송 결과 INSERT (멱등 — ON CONFLICT DO NOTHING)
--
--   4. track_promo_click(p_token uuid, p_campaign_id uuid)
--      CTA 클릭 추적. 익명 anon GRANT.
--      클릭된 캠페인은 다음 다이제스트 매칭에서 자동 제외.
--
-- 전제 조건:
--   마이그레이션 139 (테이블 4종) + 140 (unsubscribe_token, first_active_at) 적용 완료
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행 + 검증
--   2. 운영서버 SQL Editor 실행
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.track_promo_click(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]);
--   DROP FUNCTION IF EXISTS public.get_promo_digest_targets(date);
--   DROP FUNCTION IF EXISTS public._meets_min_followers(text, text, text, integer, integer, integer, integer, integer);
-- ============================================================

BEGIN;


-- ============================================================
-- 1. _meets_min_followers — 팔로워 수 매칭 헬퍼
--   FEATURE_SPEC §10 정책: primary_channel 단일 기준 검증.
--   monitor(리뷰어) 캠페인은 팔로워 무관 → true 반환.
--   primary_channel 없으면 캠페인 channels CSV 첫 번째로 폴백.
--
--   파라미터를 개별 컬럼으로 받는 이유:
--     get_promo_digest_targets 의 eligible_influencers CTE 가
--     influencers 테이블 일부 컬럼만 SELECT 하므로 복합 행 타입 불일치 방지.
-- ============================================================
CREATE OR REPLACE FUNCTION public._meets_min_followers(
  p_recruit_type    text,
  p_primary_channel text,
  p_channels        text,
  p_min_followers   integer,
  p_ig_followers    integer,
  p_tiktok_followers integer,
  p_x_followers     integer,
  p_youtube_followers integer
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_channel   text;
  v_followers bigint;
BEGIN
  -- monitor(리뷰어) 캠페인은 팔로워 무관
  IF p_recruit_type = 'monitor' THEN
    RETURN true;
  END IF;

  -- min_followers NULL 또는 0 이면 제한 없음 → true
  IF p_min_followers IS NULL OR p_min_followers <= 0 THEN
    RETURN true;
  END IF;

  -- 캠페인 primary_channel 결정 (없으면 channels CSV 첫 번째)
  v_channel := COALESCE(
    NULLIF(TRIM(p_primary_channel), ''),
    SPLIT_PART(p_channels, ',', 1)
  );
  v_channel := TRIM(v_channel);

  -- 인플루언서 해당 채널 팔로워수 조회
  v_followers := CASE v_channel
    WHEN 'instagram' THEN COALESCE(p_ig_followers, 0)
    WHEN 'tiktok'    THEN COALESCE(p_tiktok_followers, 0)
    WHEN 'x'         THEN COALESCE(p_x_followers, 0)
    WHEN 'youtube'   THEN COALESCE(p_youtube_followers, 0)
    ELSE 0  -- 알 수 없는 채널: 0으로 처리 → min_followers > 0 이면 false
  END;

  RETURN v_followers >= p_min_followers;
END;
$$;

COMMENT ON FUNCTION public._meets_min_followers(text, text, text, integer, integer, integer, integer, integer) IS
  '[141] 팔로워 수 매칭 헬퍼. primary_channel 기준 (FEATURE_SPEC §10 정책). monitor 캠페인은 항상 true. 개별 컬럼 파라미터로 CTE 행 타입 불일치 방지. SECURITY DEFINER + search_path 고정.';

-- 내부 헬퍼 — anon/authenticated 직접 호출 불필요. Supabase 자동 GRANT 차단 (PUBLIC + anon)
REVOKE EXECUTE ON FUNCTION public._meets_min_followers(text, text, text, integer, integer, integer, integer, integer) FROM PUBLIC, anon;


-- ============================================================
-- 2. get_promo_digest_targets — 발송 대상자 조회
--
--   반환 컬럼 (§17-4 시그니처 확정):
--     influencer_id         uuid     — 인플루언서 ID
--     email                 text     — 발송 대상 이메일
--     name                  text     — 표시명 (한자 우선 → name → 가나)
--     unsubscribe_token     uuid     — 수신거부·클릭 추적 토큰
--     new_campaign_ids      uuid[]   — 신규 캠페인 ID 배열 (마감일 순 최대 5건)
--     deadline_d1_campaign_ids uuid[] — D-1 임박 캠페인 ID 배열 (마감일 순 최대 5건)
--
--   p_digest_date: cron 호출 날짜 (KST, 예: '2026-05-19')
--     → 신규 윈도우: first_active_at AT TIME ZONE 'Asia/Seoul' ::date = p_digest_date
--       (Edge Function 이 월요일/목요일 각 윈도우에 맞는 날짜를 계산해서 전달)
--     → D-1: deadline = (p_digest_date AT TIME ZONE 'Asia/Seoul')::date + 1
--       (내일 마감 = 오늘 기준 D-1)
--
--   Edge Function 책임:
--     - 월요일 cron: 지난 목~일 기간의 신규 캠페인 각 날짜별로 RPC 호출 (4회)
--       또는 Edge Function 내 통합 window 계산 후 단일 RPC 호출
--     - 본 함수는 단일 날짜(p_digest_date) 기준으로만 처리 (단일 책임 원칙)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_promo_digest_targets(p_digest_date date)
RETURNS TABLE (
  influencer_id            uuid,
  email                    text,
  name                     text,
  unsubscribe_token        uuid,
  new_campaign_ids         uuid[],
  deadline_d1_campaign_ids uuid[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH

  -- ──────────────────────────────────────────────────────────
  -- [A] 신규 캠페인 (p_digest_date 에 KST 기준 first_active_at 발생)
  --     + 캠페인 측 조건 (§16-1):
  --       - deadline 미경과 (오늘 포함 이후)
  --       - monitor 슬롯 잔여 (approved 수 < slots)
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
      AND c.deadline >= CURRENT_DATE  -- 마감 안 됨
      AND (
        -- 리뷰어(monitor) 캠페인: 슬롯 잔여 확인 (§16-1 캠페인 측 조건)
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
  --     동일 캠페인 측 조건 적용
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
      AND c.deadline = CURRENT_DATE + 1  -- 내일 마감 = 오늘 기준 D-1
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
  --     - marketing_opt_in = true (수신 동의)
  --     - marketing_unsubscribed_at IS NULL (수신거부 안 함)
  --     - 오늘 이미 발송된 인플 제외 (cron 재호출 멱등)
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
        -- 오늘 이미 발송된 인플 제외 (sent 또는 skipped 모두 제외)
        SELECT 1
          FROM public.campaign_promo_digest_sent s
         WHERE s.influencer_id = i.id
           AND s.digest_date   = p_digest_date
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [D] 신규 캠페인 × 인플루언서 매칭
  --     자격: 채널 포함 + 팔로워 충족 (§16-1 정책)
  --     제외: 이미 응모/거절 (§16-2) + 이미 노출 (§17) + 클릭함 (§17)
  --     정렬: 마감일 가까운 순 (§16-5)
  --     상한: 5건 (§16-5) — array_agg 안 LIMIT 불가 → Edge Function 이 첫 5개 사용
  -- ──────────────────────────────────────────────────────────
  new_matches AS (
    SELECT
      i.id            AS influencer_id,
      -- 마감일 가까운 순 정렬, 최대 5건 슬라이스 (§16-5)
      -- array_agg 안 ORDER BY + 배열 슬라이스
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5] AS campaign_ids
    FROM eligible_influencers i
    CROSS JOIN new_campaigns c
    WHERE
      -- 채널 매칭: 캠페인 channels CSV 에 인플 등록 채널이 포함 (§3-3 로직)
      (
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      -- 팔로워 매칭 (monitor 제외)
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers
          )
      -- 응모/거절 제외 (cancelled 는 재응모 가능이므로 포함 — §16-2)
      AND NOT EXISTS (
        SELECT 1
          FROM public.applications a
         WHERE a.user_id     = i.id
           AND a.campaign_id = c.id
           AND a.status     <> 'cancelled'
      )
      -- 이미 kind='new' 로 노출된 캠페인 제외 (§17-3)
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'new'
      )
      -- CTA 클릭한 캠페인 제외 (§17-2 — 클릭 = 확인 완료 신호)
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
  --     동일 자격 조건 + kind='deadline_d1' 미노출 필터
  -- ──────────────────────────────────────────────────────────
  d1_matches AS (
    SELECT
      i.id            AS influencer_id,
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5] AS campaign_ids
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
      -- kind='deadline_d1' 미노출만
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'deadline_d1'
      )
      -- 클릭한 캠페인 제외
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_email_clicks k
         WHERE k.campaign_id   = c.id
           AND k.influencer_id = i.id
      )
    GROUP BY i.id
  ),

  -- ──────────────────────────────────────────────────────────
  -- [F] 두 매칭 결합 — 한쪽 또는 양쪽 해당 인플 모두 포함
  --     양쪽 모두 NULL 이면 해당 인플 발송 제외 (Edge Function 이 판단)
  -- ──────────────────────────────────────────────────────────
  all_targets AS (
    SELECT
      COALESCE(nm.influencer_id, dm.influencer_id) AS influencer_id,
      COALESCE(nm.campaign_ids, '{}')              AS new_campaign_ids,
      COALESCE(dm.campaign_ids, '{}')              AS deadline_d1_campaign_ids
    FROM new_matches nm
    FULL OUTER JOIN d1_matches dm
      ON nm.influencer_id = dm.influencer_id
    WHERE
      -- 양쪽 모두 빈 배열이면 발송 불필요 (이 조건은 FULL JOIN 이후 자동 처리됨)
      (COALESCE(array_length(nm.campaign_ids, 1), 0) > 0
       OR COALESCE(array_length(dm.campaign_ids, 1), 0) > 0)
  )

  -- ──────────────────────────────────────────────────────────
  -- [G] 최종 반환 — 이메일·이름 결합
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
    t.deadline_d1_campaign_ids
  FROM all_targets t
  JOIN public.influencers i ON i.id = t.influencer_id;
$$;

-- Supabase 자동 GRANT 차단 (PUBLIC + anon) 후 authenticated 만 명시 GRANT
-- service_role 은 RLS 우회로 자동 실행 가능
-- authenticated GRANT 는 향후 운영자 수동 트리거 지원용
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_targets(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_promo_digest_targets(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_targets(date) IS
  '[141] 홍보 메일 발송 대상 조회. 신규·D-1 섹션 각각 캠페인 ID 배열 반환. 채널+팔로워 매칭, 응모/노출/클릭 제외 필터 포함. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 3. mark_promo_digest_sent — 인플별 발송 결과 INSERT (멱등)
--   ON CONFLICT DO NOTHING: cron 재호출 시 중복 INSERT 안전
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_promo_digest_sent(
  p_influencer_id         uuid,
  p_digest_date           date,
  p_status                text,
  p_skip_reason           text    DEFAULT NULL,
  p_error_message         text    DEFAULT NULL,
  p_included_campaign_ids uuid[]  DEFAULT '{}'
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.campaign_promo_digest_sent
    (influencer_id, digest_date, status, skip_reason, error_message, included_campaign_ids)
  VALUES
    (p_influencer_id, p_digest_date, p_status, p_skip_reason, p_error_message, p_included_campaign_ids)
  ON CONFLICT (influencer_id, digest_date) DO NOTHING;
  -- UNIQUE(influencer_id, digest_date) 충돌 시 무시 — 멱등 보장
$$;

-- Supabase 자동 GRANT 차단 (PUBLIC + anon) 후 authenticated 만 명시 GRANT
-- (service_role 은 RLS 우회로 자동 실행 — Edge Function 이 mark 호출)
REVOKE EXECUTE ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) TO authenticated;

COMMENT ON FUNCTION public.mark_promo_digest_sent(uuid, date, text, text, text, uuid[]) IS
  '[141] 홍보 메일 인플별 발송 결과 INSERT. ON CONFLICT DO NOTHING 으로 멱등 보장. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 4. track_promo_click — CTA 클릭 추적
--   익명 anon GRANT: 메일 CTA 클릭은 비로그인 상태에서 발생
--   토큰은 influencers.unsubscribe_token 재사용 (별도 발급 없음)
--   클릭된 (campaign_id, influencer_id) 는 다음 다이제스트 get_promo_digest_targets 에서 자동 제외
-- ============================================================
CREATE OR REPLACE FUNCTION public.track_promo_click(
  p_token       uuid,
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id uuid;
BEGIN
  -- 토큰으로 인플루언서 ID 조회 (influencers.id = auth.users.id, PK)
  SELECT id INTO v_influencer_id
    FROM public.influencers
   WHERE unsubscribe_token = p_token;

  IF v_influencer_id IS NULL THEN
    -- 잘못된 토큰 — 열거 공격 방지용 success=false (HTTP 200)
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 클릭 기록 INSERT 또는 재클릭 시 카운트 갱신
  INSERT INTO public.campaign_promo_email_clicks
    (campaign_id, influencer_id, first_clicked_at, click_count, last_clicked_at)
  VALUES
    (p_campaign_id, v_influencer_id, now(), 1, now())
  ON CONFLICT (campaign_id, influencer_id) DO UPDATE
    SET click_count     = public.campaign_promo_email_clicks.click_count + 1,
        last_clicked_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

-- PostgreSQL 기본 PUBLIC 권한 REVOKE 후 anon+authenticated 명시 GRANT
REVOKE EXECUTE ON FUNCTION public.track_promo_click(uuid, uuid) FROM PUBLIC;
-- 익명 GRANT 필수: 메일 CTA 클릭 = 비로그인
GRANT EXECUTE ON FUNCTION public.track_promo_click(uuid, uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.track_promo_click(uuid, uuid) IS
  '[141] 홍보 메일 CTA 클릭 추적. 익명 anon GRANT. 클릭된 (campaign_id, influencer_id) 페어는 다음 다이제스트 매칭에서 자동 제외. SECURITY DEFINER + search_path 고정.';


COMMIT;
