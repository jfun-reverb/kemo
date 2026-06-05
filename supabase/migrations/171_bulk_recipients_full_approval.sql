-- ============================================================
-- 171_bulk_recipients_full_approval.sql
-- 2026-06-05
--
-- 목적:
--   resolve_bulk_recipients 에 결과물 "완전 승인" 파라미터 2개를 추가하고
--   "미제출(none)" 판정을 draft 흡수 방식으로 수정한다.
--   169 의 12인자 시그니처를 DROP 하고 14인자로 교체한다.
--
-- 169 대비 변경 사항:
--
--   1. p_receipt_all_approved boolean DEFAULT false  [신규 — 항목 B]
--      true 이면 영수증(kind='receipt')이 "완전 승인"인 응모만 통과.
--      "완전 승인" 정의:
--        EXISTS(kind='receipt' AND status='approved')
--        AND NOT EXISTS(kind='receipt' AND status IN ('pending','rejected','draft'))
--      p_receipt_statuses 필터보다 나중에 AND 연결.
--
--   2. p_post_all_approved boolean DEFAULT false  [신규 — 항목 B]
--      true 이면 게시물·이미지(kind IN 'post','review_image')가 "완전 승인"인 응모만 통과.
--      "완전 승인" 정의:
--        EXISTS(kind IN ('post','review_image') AND status='approved')
--        AND NOT EXISTS(kind IN ('post','review_image') AND status IN ('pending','rejected','draft'))
--
--   3. "미제출(none)" 판정 수정 [항목 D]
--      영수증 필터 none: NOT EXISTS(kind='receipt' AND status <> 'draft')
--      게시물 필터 none: NOT EXISTS(kind IN ('post','review_image') AND status <> 'draft')
--      → 결과물 행 자체가 없거나, 있어도 전부 draft 인 경우를 모두 "미제출"로 취급.
--        (169 는 행이 없을 때만 none 으로 처리 — draft 행 있으면 none 에서 누락됐음)
--
--   4. 나머지 인자·필터 (응모상태 / 채널 / 지역 / 팔로워 / 인증 / 위반 / 블랙리스트)
--      169 로직 그대로 유지.
--
-- 호환성 판단:
--   storage.js resolveBulkRecipients 래퍼는 명명 인자(p_key: value) 방식으로 호출.
--   신규 파라미터 2개(p_receipt_all_approved, p_post_all_approved)는 DEFAULT false 이므로
--   기존 래퍼에서 해당 키를 전달하지 않아도 false 로 처리됨.
--   PostgreSQL 은 인자 수가 다르면 다른 함수로 인식하므로,
--   기존 12인자 시그니처를 DROP 해야 충돌 없이 14인자 함수가 등록된다.
--   기존 래퍼 호출(12개 키)은 PostgreSQL 의 명명 인자 + DEFAULT 조합으로 정상 작동.
--
-- 컬럼명 검증 (169 기준 그대로):
--   deliverables.kind   CHECK: 'receipt' | 'review_image' | 'post'  ✅
--   deliverables.status CHECK: 'pending' | 'approved' | 'rejected' | 'draft' 등  ✅
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행
--   2. 개발서버 스모크 확인 (아래 「검증 쿼리」 참조)
--   3. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 검증 쿼리 (개발서버 스모크):
--   -- 캠페인 ID 는 실제 존재하는 값으로 교체
--   SELECT public.resolve_bulk_recipients(
--     p_campaign_id        := '<campaign_uuid>',
--     p_receipt_all_approved := false,
--     p_post_all_approved    := false
--   );
--   -- → 빈 배열 또는 uuid 배열 반환, 오류 없어야 함
--
--   SELECT public.resolve_bulk_recipients(
--     p_campaign_id        := '<campaign_uuid>',
--     p_app_statuses       := ARRAY['approved'],
--     p_post_all_approved  := true
--   );
--   -- → 게시물 완전 승인 응모만 반환
--
-- 롤백 SQL:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
--     uuid, text[], text[], text[], text[], text[], text, text, integer,
--     boolean, boolean, boolean, boolean, boolean
--   );
--   -- 169 원본 재실행 (169_bulk_recipients_region_follower.sql 전체)
--   COMMIT;
-- ============================================================

BEGIN;


-- ============================================================
-- 기존 시그니처 DROP
-- (A) 169 의 12인자 시그니처
-- (B) 171 재실행 시 존재할 수 있는 14인자 시그니처 (멱등성)
-- ============================================================

-- (A) 169 시그니처 DROP
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
  uuid,       -- p_campaign_id
  text[],     -- p_app_statuses
  text[],     -- p_receipt_statuses
  text[],     -- p_post_statuses
  text[],     -- p_channels
  text[],     -- p_prefectures
  text,       -- p_follower_mode
  text,       -- p_follower_channel
  integer,    -- p_min_followers
  boolean,    -- p_require_verified
  boolean,    -- p_exclude_violation
  boolean     -- p_exclude_blacklist
);

-- (B) 171 시그니처 DROP (멱등성 — 재실행 시 기존 14인자 함수 제거)
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
  uuid,       -- p_campaign_id
  text[],     -- p_app_statuses
  text[],     -- p_receipt_statuses
  text[],     -- p_post_statuses
  text[],     -- p_channels
  text[],     -- p_prefectures
  text,       -- p_follower_mode
  text,       -- p_follower_channel
  integer,    -- p_min_followers
  boolean,    -- p_require_verified
  boolean,    -- p_exclude_violation
  boolean,    -- p_exclude_blacklist
  boolean,    -- p_receipt_all_approved   ← 신규
  boolean     -- p_post_all_approved      ← 신규
);


-- ============================================================
-- CREATE: 14인자 시그니처
-- ============================================================
CREATE FUNCTION public.resolve_bulk_recipients(
  p_campaign_id          uuid,
  p_app_statuses         text[]  DEFAULT NULL,
  p_receipt_statuses     text[]  DEFAULT NULL,    -- kind='receipt' 결과물 상태 필터
  p_post_statuses        text[]  DEFAULT NULL,    -- kind IN ('post','review_image') 결과물 상태 필터
  p_channels             text[]  DEFAULT NULL,    -- 인플 보유 SNS 채널 필터
  p_prefectures          text[]  DEFAULT NULL,    -- 도도부현 필터 (169 그대로)
  p_follower_mode        text    DEFAULT NULL,    -- 'per_channel'|'sum'|NULL (169 그대로)
  p_follower_channel     text    DEFAULT NULL,    -- per_channel 기준 채널명 (169 그대로)
  p_min_followers        integer DEFAULT NULL,    -- 모드별 팔로워 하한 (169 그대로)
  p_require_verified     boolean DEFAULT false,
  p_exclude_violation    boolean DEFAULT false,
  p_exclude_blacklist    boolean DEFAULT true,
  p_receipt_all_approved boolean DEFAULT false,   -- [신규 — 항목 B] true=영수증 완전 승인만
  p_post_all_approved    boolean DEFAULT false    -- [신규 — 항목 B] true=게시물·이미지 완전 승인만
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
       -- 'none': 비draft 영수증 결과물이 하나도 없는 응모 [항목 D 수정]
       --         (169: 행이 없을 때만 none / 171: 행이 없거나 전부 draft 이면 none)
       -- 'pending'/'approved'/'rejected': 해당 status 의 영수증이 EXISTS
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
                  AND d.status <> 'draft'    -- [항목 D] draft 는 미제출로 취급
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
       -- 'none': 비draft 게시물·이미지 결과물이 하나도 없는 응모 [항목 D 수정]
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
                  AND d.status <> 'draft'    -- [항목 D] draft 는 미제출로 취급
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

       -- ── 영수증 완전 승인 필터 [항목 B 신규] ──
       -- p_receipt_all_approved=true 이면:
       --   kind='receipt' 결과물 중 approved 가 1건 이상 존재
       --   AND pending/rejected/draft 가 0건
       AND (
         NOT p_receipt_all_approved
         OR (
           EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind = 'receipt'
                AND d.status = 'approved'
           )
           AND NOT EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind = 'receipt'
                AND d.status IN ('pending', 'rejected', 'draft')
           )
         )
       )

       -- ── 게시물·이미지 완전 승인 필터 [항목 B 신규] ──
       -- p_post_all_approved=true 이면:
       --   kind IN ('post','review_image') 결과물 중 approved 가 1건 이상 존재
       --   AND pending/rejected/draft 가 0건
       AND (
         NOT p_post_all_approved
         OR (
           EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind IN ('post', 'review_image')
                AND d.status = 'approved'
           )
           AND NOT EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind IN ('post', 'review_image')
                AND d.status IN ('pending', 'rejected', 'draft')
           )
         )
       )

       -- ── 채널 필터 ──
       -- 인플루언서가 지정 채널 계정을 보유(핸들 컬럼 NOT NULL AND != '') 하는지 확인.
       -- Qoo10·LIPS·@cosme 는 인스타그램 핸들 보유로 판정 (169 와 동일).
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

       -- ── 지역(도도부현) 필터 ── (169 그대로)
       AND (
         p_prefectures IS NULL
         OR i.prefecture = ANY(p_prefectures)
       )

       -- ── 팔로워 필터 ── (169 그대로)
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
             ELSE 0
           END
         ) >= p_min_followers
       )

       -- ── 인플루언서 인증 필터 ──
       AND (
         NOT p_require_verified
         OR i.is_verified = true
       )

       -- ── 블랙리스트 필터 ──
       AND (
         NOT p_exclude_blacklist
         OR COALESCE(i.is_blacklisted, false) = false
       )

       -- ── 위반 이력 필터 ──
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
  boolean, boolean, boolean, boolean, boolean
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean
) TO authenticated;


-- ── 함수 설명 주석 ──
COMMENT ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean
) IS
  '[171] 일괄 발송 대상 응모 ID 배열 반환 (169 재정의 — 완전 승인 파라미터 + none 정의 확장). '
  'campaign_admin 이상 가드. cancelled 응모 항상 제외. '
  'p_receipt_statuses: NULL=전체, none/pending/approved/rejected (kind=receipt 한정). '
  '  none = 비draft 영수증 결과물 0건 (결과물 행 없거나 전부 draft 인 경우 포함). '
  'p_post_statuses:    NULL=전체, none/pending/approved/rejected (kind IN post,review_image 한정). '
  '  none = 비draft 게시물·이미지 결과물 0건 (결과물 행 없거나 전부 draft 인 경우 포함). '
  'p_receipt_all_approved: true=영수증 완전 승인 응모만 '
  '  (approved 1건+ AND pending/rejected/draft 0건). '
  'p_post_all_approved:    true=게시물·이미지 완전 승인 응모만 '
  '  (approved 1건+ AND pending/rejected/draft 0건). '
  'p_channels:         NULL=전체, 인플루언서 보유 채널 기준. '
  'p_prefectures:      NULL=전체, influencers.prefecture 일본어 값 (예: 東京都). '
  '                    prefecture 가 NULL 인 인플루언서는 자동 제외. '
  'p_follower_mode:    NULL=제한없음, per_channel=단일채널, sum=4채널 합산. '
  'p_follower_channel: per_channel 모드 기준 채널(instagram/qoo10/tiktok/x/youtube/lips/cosme). '
  '                    lips·cosme 는 팔로워 컬럼 없어 0 처리. '
  'p_min_followers:    NULL 또는 p_follower_mode NULL 이면 팔로워 제한 없음. '
  'p_require_verified: true 이면 is_verified=true 인플만. '
  'p_exclude_violation: true 이면 influencer_flags.action=violation 이력 있는 인플 제외. '
  'p_exclude_blacklist: true(기본) 이면 is_blacklisted=true 인플 제외. '
  '빈 배열 반환 가능(예외 없음). SECURITY DEFINER + search_path 고정.';


COMMIT;
