-- ============================================================
-- 169_bulk_recipients_region_follower.sql
-- 2026-06-04
--
-- 목적:
--   resolve_bulk_recipients 에 지역(도도부현) 필터와
--   팔로워 모드(채널별/합산) 를 추가한다.
--   168 의 9인자 시그니처를 DROP 하고 12인자로 교체한다.
--
-- 168 대비 변경:
--   1. p_prefectures text[] DEFAULT NULL  (신규)
--      influencers.prefecture IN (p_prefectures) 필터.
--      NULL 이면 전체 통과. prefecture 가 NULL 인 인플루언서는
--      ANY 매칭 실패로 자동 제외(의도된 동작).
--
--   2. p_follower_mode text DEFAULT NULL  (신규)
--      'per_channel' : p_follower_channel 기준 단일 채널 팔로워
--      'sum'         : ig+tiktok+x+youtube 합산 팔로워
--      NULL          : 팔로워 제한 없음(p_min_followers 무시)
--
--   3. p_follower_channel text DEFAULT NULL  (신규)
--      per_channel 모드일 때 기준 채널명.
--      'instagram'|'qoo10'|'tiktok'|'x'|'youtube'|'lips'|'cosme'
--      lips·cosme 는 팔로워 컬럼 없음 → 0 으로 처리.
--
--   4. p_min_followers (재정의)
--      168 의 primary_channel 단일 기준 로직 → 모드별 CASE 로 교체.
--
--   5. 나머지 인자·필터(응모상태/영수증/결과물/채널/인증/위반/블랙)는
--      168 로직 그대로 복사.
--
-- 컬럼명 검증 결과:
--   influencers.prefecture       ✅ (마이그레이션 002 ADD COLUMN IF NOT EXISTS)
--   influencers.ig_followers     ✅ (마이그레이션 002)
--   influencers.tiktok_followers ✅ (마이그레이션 002)
--   influencers.x_followers      ✅ (마이그레이션 002)
--   influencers.youtube_followers ✅ (마이그레이션 002)
--   influencers.ig               ✅ (168 에서 채널 필터로 사용 중)
--   influencers.is_verified      ✅ (마이그레이션 059)
--   influencers.is_blacklisted   ✅ (마이그레이션 059)
--   influencer_flags.action      ✅ (마이그레이션 060)
--   deliverables.kind            ✅ (기존 CHECK: 'receipt'|'review_image'|'post')
--
-- 운영 배포:
--   개발서버(qysmxtipobomefudyixw) 먼저 적용 후,
--   167·168 과 함께 운영서버(nrwtujmlbktxjgdwlpjj) 에 적용.
--   메시지 약관 30일 통지 게이트 완료 후.
--
-- 롤백 SQL (주석):
--   BEGIN;
--   -- 169(12인자) 제거 후 168(9인자) 복원:
--   DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
--     uuid, text[], text[], text[], text[], text[], text, text, integer,
--     boolean, boolean, boolean
--   );
--   -- 168 원본 재실행 (168 파일 341~542줄)
--   COMMIT;
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행
--   2. 개발서버 스모크 확인 (NULL 파라미터 호출 → 빈 배열 반환 확인)
--   3. 운영서버 SQL Editor 실행 (약관 통지 게이트 완료 후)
-- ============================================================

BEGIN;


-- ============================================================
-- resolve_bulk_recipients 재정의
-- 인자 수 변경 → DROP 후 CREATE
--
-- DROP 대상:
--   (A) 168 의 9인자 시그니처
--   (B) 169 재실행 시 존재할 수 있는 12인자 시그니처 (멱등성)
-- ============================================================

-- (A) 168 시그니처 DROP
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
  uuid,       -- p_campaign_id
  text[],     -- p_app_statuses
  text[],     -- p_receipt_statuses
  text[],     -- p_post_statuses
  text[],     -- p_channels
  integer,    -- p_min_followers
  boolean,    -- p_require_verified
  boolean,    -- p_exclude_violation
  boolean     -- p_exclude_blacklist
);

-- (B) 169 시그니처 DROP (멱등성 — 재실행 시 기존 함수 제거)
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
  uuid,       -- p_campaign_id
  text[],     -- p_app_statuses
  text[],     -- p_receipt_statuses
  text[],     -- p_post_statuses
  text[],     -- p_channels
  text[],     -- p_prefectures        ← 신규
  text,       -- p_follower_mode      ← 신규
  text,       -- p_follower_channel   ← 신규
  integer,    -- p_min_followers
  boolean,    -- p_require_verified
  boolean,    -- p_exclude_violation
  boolean     -- p_exclude_blacklist
);


-- ============================================================
-- CREATE: 12인자 시그니처
-- ============================================================
CREATE FUNCTION public.resolve_bulk_recipients(
  p_campaign_id        uuid,
  p_app_statuses       text[]  DEFAULT NULL,
  p_receipt_statuses   text[]  DEFAULT NULL,   -- kind='receipt' 결과물 상태 필터
  p_post_statuses      text[]  DEFAULT NULL,   -- kind IN ('post','review_image') 결과물 상태 필터
  p_channels           text[]  DEFAULT NULL,   -- 인플 보유 SNS 채널 필터 (168 로직 그대로)
  p_prefectures        text[]  DEFAULT NULL,   -- [신규] 도도부현 필터. NULL=전체. 일본어 값(예: '東京都')
  p_follower_mode      text    DEFAULT NULL,   -- [신규] 'per_channel'|'sum'|NULL
  p_follower_channel   text    DEFAULT NULL,   -- [신규] per_channel 기준 채널명
  p_min_followers      integer DEFAULT NULL,   -- 모드별 해석 (168 primary_channel 로직 교체)
  p_require_verified   boolean DEFAULT false,
  p_exclude_violation  boolean DEFAULT false,
  p_exclude_blacklist  boolean DEFAULT true
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_result uuid[];
BEGIN
  -- ── 권한 가드: campaign_admin 이상 ──
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 캠페인 존재 확인 ──
  IF NOT EXISTS (
    SELECT 1 FROM public.campaigns WHERE id = p_campaign_id
  ) THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다: %', p_campaign_id;
  END IF;

  -- ── 팔로워 모드 유효성 검증 ──
  IF p_follower_mode IS NOT NULL
     AND p_follower_mode NOT IN ('per_channel', 'sum') THEN
    RAISE EXCEPTION 'p_follower_mode 는 per_channel 또는 sum 만 허용됩니다: %', p_follower_mode;
  END IF;

  -- ----------------------------------------------------------------
  -- 대상 응모 집계
  -- ----------------------------------------------------------------
  SELECT ARRAY(
    SELECT a.id
      FROM public.applications a
      JOIN public.influencers  i ON i.id = a.user_id
     WHERE a.campaign_id = p_campaign_id
       -- cancelled 항상 제외 (인플 화면 진입 차단 — 메시지 열람 불가)
       AND a.status <> 'cancelled'

       -- ── 응모 상태 필터 ──
       AND (
         p_app_statuses IS NULL
         OR a.status = ANY(p_app_statuses)
       )

       -- ── 영수증(kind='receipt') 결과물 상태 필터 ──
       -- 'none': 영수증 결과물 행이 하나도 없는 응모
       -- 'pending'/'approved'/'rejected': 해당 status 의 영수증 결과물이 EXISTS
       -- NULL 이면 이 블록 전체 통과 (필터 없음)
       AND (
         p_receipt_statuses IS NULL
         OR (
           (
             'none' = ANY(p_receipt_statuses)
             AND NOT EXISTS (
               SELECT 1 FROM public.deliverables d
                WHERE d.application_id = a.id
                  AND d.kind = 'receipt'
             )
           )
           OR EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind = 'receipt'
                AND d.status = ANY(
                  ARRAY(
                    SELECT x FROM unnest(p_receipt_statuses) x WHERE x <> 'none'
                  )
                )
           )
         )
       )

       -- ── 일반 결과물(kind IN 'post','review_image') 상태 필터 ──
       -- 'none': 해당 종류 결과물 행이 하나도 없는 응모
       -- 'pending'/'approved'/'rejected': 해당 status 의 결과물이 EXISTS
       -- NULL 이면 이 블록 전체 통과 (필터 없음)
       AND (
         p_post_statuses IS NULL
         OR (
           (
             'none' = ANY(p_post_statuses)
             AND NOT EXISTS (
               SELECT 1 FROM public.deliverables d
                WHERE d.application_id = a.id
                  AND d.kind IN ('post', 'review_image')
             )
           )
           OR EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind IN ('post', 'review_image')
                AND d.status = ANY(
                  ARRAY(
                    SELECT x FROM unnest(p_post_statuses) x WHERE x <> 'none'
                  )
                )
           )
         )
       )

       -- ── 채널 필터 ──
       -- 인플루언서가 지정 채널 계정을 보유(핸들 컬럼 NOT NULL AND != '') 하는지 확인.
       -- Qoo10·LIPS·@cosme 는 인스타그램 핸들 보유로 판정 (167·168 과 동일 근거).
       AND (
         p_channels IS NULL
         OR (
           ('instagram' = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('tiktok'    = ANY(p_channels) AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
           OR ('x'         = ANY(p_channels) AND i.x       IS NOT NULL AND i.x       <> '')
           OR ('youtube'   = ANY(p_channels) AND i.youtube IS NOT NULL AND i.youtube <> '')
           OR ('qoo10'     = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('lips'      = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('cosme'     = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
         )
       )

       -- ── 지역(도도부현) 필터 ── [169 신규]
       -- p_prefectures NULL 이면 전체 통과.
       -- prefecture 가 NULL 인 인플루언서는 ANY 매칭 실패 → 자동 제외.
       -- 값 형식: 일본어 도도부현명(예: '東京都', '大阪府', '北海道').
       AND (
         p_prefectures IS NULL
         OR i.prefecture = ANY(p_prefectures)
       )

       -- ── 팔로워 필터 ── [169 재설계 — 168 의 primary_channel 단일 로직 교체]
       --
       -- p_follower_mode = 'sum':
       --   ig + tiktok + x + youtube 합산 팔로워 >= p_min_followers
       --
       -- p_follower_mode = 'per_channel':
       --   p_follower_channel 기준 채널 팔로워 >= p_min_followers
       --   instagram·qoo10 → ig_followers
       --   tiktok           → tiktok_followers
       --   x                → x_followers
       --   youtube          → youtube_followers
       --   lips·cosme       → 팔로워 컬럼 없음 → 0 (결과적으로 p_min_followers>0 이면 제외됨)
       --
       -- p_follower_mode = NULL 또는 p_min_followers = NULL:
       --   팔로워 제한 없음 (전체 통과)
       AND (
         p_min_followers IS NULL
         OR p_follower_mode IS NULL
         OR (
           CASE p_follower_mode
             WHEN 'sum' THEN
               COALESCE(i.ig_followers,       0)
               + COALESCE(i.tiktok_followers, 0)
               + COALESCE(i.x_followers,      0)
               + COALESCE(i.youtube_followers, 0)
             WHEN 'per_channel' THEN
               CASE p_follower_channel
                 WHEN 'instagram' THEN COALESCE(i.ig_followers,       0)
                 WHEN 'qoo10'     THEN COALESCE(i.ig_followers,       0)
                 WHEN 'tiktok'    THEN COALESCE(i.tiktok_followers,   0)
                 WHEN 'x'         THEN COALESCE(i.x_followers,        0)
                 WHEN 'youtube'   THEN COALESCE(i.youtube_followers,  0)
                 ELSE 0  -- lips·cosme: 팔로워 컬럼 없음 → 사실상 제외
               END
             ELSE 0  -- 알 수 없는 mode: 안전하게 0 반환 (UI 가 mode를 항상 올바르게 전달해야 함)
           END
         ) >= p_min_followers
       )

       -- ── 인플루언서 인증 필터 ──
       -- p_require_verified=true 이면 is_verified=true 인플만 포함
       -- (마이그레이션 059: influencers.is_verified boolean NOT NULL DEFAULT false)
       AND (
         NOT p_require_verified
         OR i.is_verified = true
       )

       -- ── 블랙리스트 필터 ──
       -- p_exclude_blacklist=true(기본값) 이면 is_blacklisted=true 인플 제외
       -- (마이그레이션 059: influencers.is_blacklisted boolean NOT NULL DEFAULT false)
       AND (
         NOT p_exclude_blacklist
         OR COALESCE(i.is_blacklisted, false) = false
       )

       -- ── 위반 이력 필터 ──
       -- p_exclude_violation=true 이면 influencer_flags.action='violation' 이력이
       -- 1건이라도 존재하는 인플 제외.
       -- (마이그레이션 060: action CHECK 에 'violation' 추가됨)
       AND (
         NOT p_exclude_violation
         OR NOT EXISTS (
           SELECT 1
             FROM public.influencer_flags f
            WHERE f.influencer_id = i.id
              AND f.action        = 'violation'
         )
       )

  ) INTO v_result;

  RETURN COALESCE(v_result, ARRAY[]::uuid[]);
END;
$$;


-- ── 권한 설정 ──
REVOKE EXECUTE ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean
) TO authenticated;


-- ── 함수 설명 주석 ──
COMMENT ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean
) IS
  '[169] 일괄 발송 대상 응모 ID 배열 반환 (168 재정의 — 지역 필터 + 팔로워 모드 추가). '
  'campaign_admin 이상 가드. cancelled 응모 항상 제외. '
  'p_receipt_statuses: NULL=전체, none/pending/approved/rejected (kind=receipt 한정). '
  'p_post_statuses:    NULL=전체, none/pending/approved/rejected (kind IN post,review_image 한정). '
  '두 결과물 필터는 AND 연결. '
  'p_channels:         NULL=전체, 인플루언서 보유 채널 기준. '
  'p_prefectures:      NULL=전체, influencers.prefecture 일본어 값 (예: 東京都). '
  '                    prefecture 가 NULL 인 인플루언서는 자동 제외. '
  'p_follower_mode:    NULL=제한없음, per_channel=단일채널, sum=4채널 합산. '
  'p_follower_channel: per_channel 모드 기준 채널(instagram/qoo10/tiktok/x/youtube/lips/cosme). '
  '                    lips·cosme 는 팔로워 컬럼 없어 0 처리(p_min_followers>0 이면 사실상 제외). '
  'p_min_followers:    NULL 또는 p_follower_mode NULL 이면 팔로워 제한 없음. '
  'p_require_verified: true 이면 is_verified=true 인플만. '
  'p_exclude_violation: true 이면 influencer_flags.action=violation 이력 있는 인플 제외. '
  'p_exclude_blacklist: true(기본) 이면 is_blacklisted=true 인플 제외. '
  '빈 배열 반환 가능(예외 없음). SECURITY DEFINER + search_path 고정.';


COMMIT;
