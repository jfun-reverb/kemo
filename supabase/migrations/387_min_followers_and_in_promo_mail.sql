-- ============================================================
-- 387. 최소 팔로워수 — 홍보 메일도 「그리고」를 가린다 (2단계 마무리)
--
-- 왜 고치나
--   384 가 화면과 홍보 메일의 판정을 「또는」까지 맞췄지만, 홍보 메일 쪽 판정 함수는
--   `channel_match` 를 **인자로 받지 않아** 다채널을 전부 「또는」으로 봤다.
--   그래서 「그리고(&)」 캠페인은 두 곳이 서로 다른 답을 낸다 —
--     · 응모 화면: 채널마다 따로 검사(min_followers_by_channel)
--     · 홍보 메일: 아무 채널이나 하나 넘으면 통과
--   조건을 안 채운 사람에게 메일이 가고, 눌러 들어오면 응모가 막힌다.
--   어느 쪽도 오류를 안 내서 **조용히 어긋난다.**
--
--   ⚠️ 운영 실측(2026-08-27) 「그리고」 캠페인 5건이 전부 리뷰어형이고 리뷰어형은
--      팔로워 검사를 건너뛰므로 **오늘은 도달하지 않는다.** 하지만 그 안전판은
--      「그리고」를 쓰는 시딩·방문형 캠페인이 하나 생기는 순간 사라진다.
--
-- 무엇을 바꾸나
--   ① `_meets_min_followers` 에 인자 둘 추가 — `p_channel_match`·`p_min_by_channel`.
--      🔴 옛 8인자 정의는 **DROP** 해야 한다(그냥 두면 기본값이 겹쳐 8인자 호출이
--         **어느 쪽인지 모호해져 오류**가 난다). 새 10인자는 `CREATE OR REPLACE` 로
--         만들어 이 파일을 **다시 돌릴 수 있게** 한다.
--      🔴 **DROP 은 그 함수에 걸어 둔 실행 권한 회수도 함께 지운다.**
--         `_meets_min_followers` 는 **141 이 `FROM PUBLIC, anon` 을 이미 회수해 둔**
--         함수다(384 가 같은 줄을 재확인까지 했다). 그대로 DROP 하면 새 함수가
--         Postgres·Supabase 기본값(PUBLIC·anon·authenticated 전부 열림)으로 돌아가
--         **141 부터 지켜 온 비로그인 차단이 조용히 풀린다.**
--         → 이 파일 아래에서 **같은 회수를 다시 건다.**
--      ⚠️ `CLAUDE.md` 의 「순수 계산 함수 3종은 일부러 안 닫았다」는 **369·370 의
--         2차 정리(`authenticated` 까지 닫기)에서 뺐다**는 뜻이지, 「회수가 하나도
--         없다」는 뜻이 아니다. **이 파일이 처음에 그 둘을 혼동했다**(검수에서 잡힘).
--   ② `get_promo_digest_targets` 는 **`CREATE OR REPLACE`** 로 본문만 바꾼다.
--      🔴 이쪽은 마이그레이션 375 가 실행 권한을 회수해 뒀다. DROP 후 CREATE 하면
--         **그 회수가 통째로 풀려** 로그인한 회원 누구나 다른 회원 이메일과
--         **수신거부 토큰**을 받아 갈 수 있게 된다. 시그니처를 한 글자도 바꾸지 말 것.
--      본문은 **360 파일에서 그대로 가져와** 네 곳만 고쳤다(두 CTE + 두 호출부).
--
-- 베이스: `_meets_min_followers` = **384** / `get_promo_digest_targets` = **360**
--   (141 → 143 → 259 → 321 → 360. ⚠️ 375 는 권한만 손댔고 정의가 아니다)
--
-- 「그리고」 판정 규칙 — 화면 `meetsMinFollowers`(dev/lib/shared.js)와 같아야 한다
--   · 채널이 하나면 `channel_match` 를 **안 본다**(「그리고」로 저장돼 있어도 single)
--   · 채널별 칸이 빈 채널은 **「검사 안 함」**이지 0 이 아니다
--   · Qoo10 은 Instagram 값을 빌려 쓴다 — 함께 모집되면 그 기준을 물려받는다
--   🔴 · 「그리고」는 `min_followers` 가 0 이라, **0 이면 통과** 조기 반환에서 빼야 한다
--        (화면 쪽에서 실제로 이 함정에 빠져 채널별 조건이 통째로 안 돌았다)
--
-- 적용 순서: 이 파일 하나로 끝난다(앱 코드 변경 없음). 개발 → 운영 순서만 지킬 것.
-- ============================================================

BEGIN;

-- ── ⓪ 채널별 기준 한 칸을 안전하게 숫자로 ──────────────────
--   🔴 그냥 `::bigint` 로 바꾸면 숫자가 아닌 값이 한 칸이라도 들어왔을 때
--      **그 날의 홍보 메일 대상 조회가 통째로 죽는다** — 이 판정은 대상 후보
--      **매 행마다** 호출되므로 한 캠페인만 건너뛰는 게 아니라 전부 멈춘다.
--      지금은 저장 경로가 관리자 폼 하나뿐이라 순수 숫자만 들어오지만,
--      **그 전제가 깨지는 날 조용히가 아니라 시끄럽게 죽는다.**
--   → 숫자로 안 읽히면 **「검사 안 함」(NULL)** 으로 본다. 조건 하나를 못 읽었다고
--      메일 전체를 멈추는 것보다, 그 조건만 빠지는 쪽이 낫다.
CREATE OR REPLACE FUNCTION public._min_by_channel_num(p_obj jsonb, p_key text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN BTRIM(COALESCE(p_obj ->> p_key, '')) ~ '^[0-9]+$'
           THEN BTRIM(p_obj ->> p_key)::bigint
           ELSE NULL
         END;
$$;

COMMENT ON FUNCTION public._min_by_channel_num(jsonb, text) IS
  '[387] min_followers_by_channel 의 한 칸을 안전하게 숫자로. '
  '숫자가 아니면 NULL(=검사 안 함) — 홍보 메일 대상 조회 전체가 죽는 것을 막는다.';

-- 표를 안 읽는 순수 계산이지만, 141 이 같은 성격의 헬퍼에 세운 기준을 따라
--   비로그인·PUBLIC 은 닫는다(`authenticated` 는 369·370 결정대로 열어 둔다).
REVOKE EXECUTE ON FUNCTION public._min_by_channel_num(jsonb, text) FROM PUBLIC, anon;

-- ── ① 판정 함수 — 인자 둘 추가 ─────────────────────────────
DROP FUNCTION IF EXISTS public._meets_min_followers(
  text, text, text, integer, integer, integer, integer, integer);

-- 새 10인자는 REPLACE — 이 파일을 다시 돌려도 「이미 있다」로 안 막힌다.
CREATE OR REPLACE FUNCTION public._meets_min_followers(
  p_recruit_type      text,
  p_primary_channel   text,
  p_channels          text,
  p_min_followers     integer,
  p_ig_followers      integer,
  p_tiktok_followers  integer,
  p_x_followers       integer,
  p_youtube_followers integer,
  p_channel_match     text  DEFAULT NULL,   -- [387] 'and' 면 채널마다 따로
  p_min_by_channel    jsonb DEFAULT NULL    -- [387] {"instagram":10000, ...}
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tokens    text[];
  v_kind      text;
  v_channel   text;
  v_followers bigint;
  v_tok       text;
  v_need      bigint;
  v_ig_need   bigint;
BEGIN
  -- 리뷰어(monitor)는 팔로워 무관 — 141 그대로
  IF p_recruit_type = 'monitor' THEN
    RETURN true;
  END IF;

  -- 채널 토큰 목록 (소문자·공백 제거·빈값 제외)
  --   ⚠️ 화면의 `campaignChannelTokens` 와 같은 규칙이어야 한다.
  SELECT COALESCE(array_agg(t), '{}')
    INTO v_tokens
    FROM (
      SELECT LOWER(BTRIM(x)) AS t
        FROM UNNEST(STRING_TO_ARRAY(COALESCE(p_channels, ''), ',')) AS x
       WHERE BTRIM(x) <> ''
    ) s;

  -- 갈래 판정 — 화면 `campaignFollowerKind` 와 같은 조건.
  --   🔴 채널이 하나면 `channel_match` 를 **보지 않는다.** 채널이 하나인데 'and' 로
  --      저장된 캠페인이 「그리고」로 빨려 들어가면, 비어 있는 채널별 칸을 읽어
  --      **검사가 통째로 사라진다.**
  IF COALESCE(array_length(v_tokens, 1), 0) <= 1 THEN
    v_kind := 'single';
  ELSIF LOWER(BTRIM(COALESCE(p_channel_match, ''))) = 'and' THEN
    v_kind := 'and';
  ELSE
    v_kind := 'or';
  END IF;

  -- min_followers 가 없거나 0 이면 제한 없음 — 141 그대로.
  --   🔴 단 「그리고」는 **여기서 빠져나가면 안 된다.** 그 갈래는 이 칸을 안 읽으므로
  --      정상적으로 0 이고, 그대로 통과시키면 채널별 조건이 한 번도 안 돈다.
  IF v_kind <> 'and' AND (p_min_followers IS NULL OR p_min_followers <= 0) THEN
    RETURN true;
  END IF;

  -- ── 「그리고」 — 채널마다 따로 ────────────────────────────
  IF v_kind = 'and' THEN
    -- Qoo10 이 물려받을 Instagram 기준을 먼저 꺼내 둔다.
    --   Qoo10 은 자체 팔로워 개념이 없어 Instagram 값을 빌려 쓴다(화면과 같다).
    v_ig_need := public._min_by_channel_num(p_min_by_channel, 'instagram');

    FOREACH v_tok IN ARRAY v_tokens LOOP
      v_need := public._min_by_channel_num(p_min_by_channel, v_tok);

      -- Qoo10 은 Instagram 이 함께 모집될 때 그 기준을 **덮어쓴다**.
      --   ⚠️ 「비어 있을 때만 채운다」가 아니라 **덮어쓴다** — 화면
      --      (`campaignMinFollowersByChannel`, dev/lib/shared.js)이 그렇게 한다.
      --      관리자 폼에 Qoo10 칸이 없어 지금은 도달할 수 없지만, **기준이 갈리면
      --      화면과 홍보 메일이 다른 답을 낸다**(이 함수의 존재 이유가 그것이다).
      IF v_tok = 'qoo10' AND v_ig_need > 0 AND 'instagram' = ANY(v_tokens) THEN
        v_need := v_ig_need;
      END IF;

      -- 값이 없는 채널은 「검사 안 함」 — 0 이 아니다
      CONTINUE WHEN COALESCE(v_need, 0) <= 0;

      v_followers := CASE v_tok
        WHEN 'instagram' THEN COALESCE(p_ig_followers, 0)
        WHEN 'qoo10'     THEN COALESCE(p_ig_followers, 0)
        WHEN 'tiktok'    THEN COALESCE(p_tiktok_followers, 0)
        WHEN 'x'         THEN COALESCE(p_x_followers, 0)
        WHEN 'youtube'   THEN COALESCE(p_youtube_followers, 0)
        ELSE 0  -- 팔로워를 담는 자리가 없는 채널(LIPS·@cosme)
      END;

      IF v_followers < v_need THEN
        RETURN false;   -- 하나라도 못 넘으면 끝
      END IF;
    END LOOP;

    RETURN true;  -- 검사할 채널이 하나도 없어도 통과(= 조건을 안 걸어 둔 것)
  END IF;

  -- ── 「또는」 — 모집 채널 중 하나라도 넘으면 통과 (384 그대로) ──
  IF v_kind = 'or' THEN
    FOREACH v_tok IN ARRAY v_tokens LOOP
      v_followers := CASE v_tok
        WHEN 'instagram' THEN COALESCE(p_ig_followers, 0)
        WHEN 'qoo10'     THEN COALESCE(p_ig_followers, 0)
        WHEN 'tiktok'    THEN COALESCE(p_tiktok_followers, 0)
        WHEN 'x'         THEN COALESCE(p_x_followers, 0)
        WHEN 'youtube'   THEN COALESCE(p_youtube_followers, 0)
        ELSE 0
      END;
      IF v_followers >= p_min_followers THEN
        RETURN true;
      END IF;
    END LOOP;
    RETURN false;
  END IF;

  -- ── 'single' — 기준 채널 하나 (141 그대로) ────────────────
  v_channel := COALESCE(
    NULLIF(TRIM(p_primary_channel), ''),
    SPLIT_PART(p_channels, ',', 1)
  );
  v_channel := LOWER(BTRIM(v_channel));

  v_followers := CASE v_channel
    WHEN 'instagram' THEN COALESCE(p_ig_followers, 0)
    WHEN 'qoo10'     THEN COALESCE(p_ig_followers, 0)
    WHEN 'tiktok'    THEN COALESCE(p_tiktok_followers, 0)
    WHEN 'x'         THEN COALESCE(p_x_followers, 0)
    WHEN 'youtube'   THEN COALESCE(p_youtube_followers, 0)
    ELSE 0
  END;

  RETURN v_followers >= p_min_followers;
END;
$$;

COMMENT ON FUNCTION public._meets_min_followers(
  text, text, text, integer, integer, integer, integer, integer, text, jsonb) IS
  '[387] 최소 팔로워수 판정 — 갈래 셋(채널 하나 / 또는 / 그리고). '
  '화면 dev/lib/shared.js 의 meetsMinFollowers 와 같은 규칙이어야 한다. '
  '한쪽만 고치면 홍보 메일은 오는데 응모는 막히고, 어느 쪽도 오류를 안 낸다.';

-- 🔴 141 이 걸어 둔 회수를 **새 10인자 함수에 다시 건다.**
--    옛 8인자를 DROP 하는 순간 그 회수가 함께 사라지고, 새 함수는 Postgres·Supabase
--    기본값(PUBLIC·anon 열림)으로 돌아간다. 384 가 파일 안에 「DROP 후 CREATE 로
--    재작성하는 경우 이 줄을 그 파일에 다시 넣어야 한다」고 미리 적어 두었는데,
--    이 파일이 처음에 그것을 빠뜨렸다(검수에서 잡힘).
--    ⚠️ `authenticated` 는 **일부러 안 닫는다** — 369·370 이 이 함수를 2차 정리
--       대상에서 뺀 결정 그대로다(표를 안 읽어 샐 것이 없다).
REVOKE EXECUTE ON FUNCTION public._meets_min_followers(
  text, text, text, integer, integer, integer, integer, integer, text, jsonb) FROM PUBLIC, anon;

-- ── ② 홍보 메일 대상 고르기 — 본문만 교체(권한 보존) ────────
--     🔴 CREATE OR REPLACE 유지. DROP 후 CREATE 하면 375 의 회수가 풀린다.
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
      c.channel_match,             -- [387] 「그리고」 갈래 판정에 필요
      c.min_followers_by_channel,  -- [387] 채널별 기준
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
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
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
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
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
COMMIT;

-- ============================================================
-- 적용 후 확인 — **「성공」은 동작 확인이 아니다. 반드시 아래를 돌릴 것.**
--   (신규·재정의 함수는 적용이 성공해도 첫 호출에서 터진다 — .claude/rules/supabase.md)
--
-- ── [1] 「그리고」 판정 (기대: false, false, true) ──
--   IG 1,000 & TikTok 5,000 인 캠페인
-- SELECT
--   public._meets_min_followers('gifting','instagram','instagram,tiktok',0,
--     100, 800, 0, 0, 'and', '{"instagram":1000,"tiktok":5000}'::jsonb)  AS 둘다_못넘음_false,
--   public._meets_min_followers('gifting','instagram','instagram,tiktok',0,
--     5000, 800, 0, 0, 'and', '{"instagram":1000,"tiktok":5000}'::jsonb) AS 인스타만_false,
--   public._meets_min_followers('gifting','instagram','instagram,tiktok',0,
--     5000, 9000, 0, 0, 'and', '{"instagram":1000,"tiktok":5000}'::jsonb) AS 둘다_넘음_true;
--
-- ── [2] 값 없는 채널은 검사 안 함 (기대: true) ──
--   TikTok 칸이 비었으므로 TikTok 팔로워가 0 이어도 통과해야 한다
-- SELECT public._meets_min_followers('gifting','instagram','instagram,tiktok',0,
--   5000, 0, 0, 0, 'and', '{"instagram":1000}'::jsonb) AS 틱톡_검사안함_true;
--
-- ── [3] 🔴 채널이 하나면 'and' 로 저장돼 있어도 single (기대: false) ──
--   여기서 「그리고」로 빨려 들어가면 빈 칸을 읽어 **검사가 사라진다**
-- SELECT public._meets_min_followers('gifting','instagram','instagram',1000,
--   999, 0, 0, 0, 'and', '{}'::jsonb) AS 채널하나_single_false;
--
-- ── [4] Qoo10 은 Instagram 기준을 물려받는다 (기대: false, true) ──
-- SELECT
--   public._meets_min_followers('gifting','instagram','instagram,qoo10',0,
--     500, 0, 0, 0, 'and', '{"instagram":1000}'::jsonb) AS qoo10_물려받아_막힘_false,
--   public._meets_min_followers('gifting','instagram','instagram,qoo10',0,
--     5000, 0, 0, 0, 'and', '{"instagram":1000}'::jsonb) AS qoo10_통과_true;
--
-- ── [5] 종전 갈래가 안 바뀌었나 (기대: true, false, false, true, true) ──
--   ⚠️ 인자 둘을 안 주는 옛 호출도 그대로 돌아야 한다(기본값 NULL → 「또는」)
-- SELECT
--   public._meets_min_followers('gifting','instagram','instagram,x,tiktok',1000,100,10000,0,0) AS 또는_틱톡만_true,
--   public._meets_min_followers('gifting','instagram','instagram,x,tiktok',1000,100,200,300,0) AS 또는_전부미달_false,
--   public._meets_min_followers('gifting','instagram','instagram',1000,999,0,0,0)             AS 하나_미달_false,
--   public._meets_min_followers('gifting','instagram','instagram',1000,1000,0,0,0)            AS 하나_충족_true,
--   public._meets_min_followers('monitor','instagram','instagram',1000,0,0,0,0)               AS 리뷰어형_true;
--
-- ── [5-1] 🔴 **판정 함수의 회수가 살아 있는가** ──
--   이 파일이 처음에 빠뜨렸던 자리다. 옛 8인자를 DROP 하면 회수가 함께 사라진다.
--   기대: `=X/` 로 시작하는 PUBLIC 몫 **없음**, `anon=` **없음**,
--         `authenticated=` **있음**(369·370 결정대로 열어 둔다)
-- SELECT p.proname, p.pronargs, p.proacl::text
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname IN ('_meets_min_followers','_min_by_channel_num')
--  ORDER BY p.proname;
--
-- ── [6] 🔴 홍보 메일 함수의 실행 권한이 그대로인가 ──
--   `=X/` 로 시작하면 PUBLIC 에 열린 것 = 375 의 회수가 풀린 것이다.
--   기대: proacl 에 PUBLIC 항목 없음, anon·authenticated 없음, service_role 있음
-- SELECT p.proname, p.proacl::text
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'get_promo_digest_targets';
--
-- ── [7] 홍보 메일 함수가 실제로 도는가 (기대: 오류 없이 0행 이상) ──
-- SELECT count(*) FROM public.get_promo_digest_targets(CURRENT_DATE - 1);
--
-- ── [8] 운영에서 이 변경이 실제로 영향을 주는 캠페인이 있나 ──
--   기대: 0건이면 「앞으로만 막는다」. 1건 이상이면 그 캠페인을 눈으로 확인할 것.
-- SELECT id, title, channel, channel_match, min_followers, min_followers_by_channel
--   FROM public.campaigns
--  WHERE channel_match = 'and'
--    AND recruit_type <> 'monitor'
--    AND deleted_at IS NULL
--    AND status = 'active';
-- ============================================================
