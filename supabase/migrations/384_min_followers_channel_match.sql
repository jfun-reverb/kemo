-- ============================================================
-- 384. 최소 팔로워수 — 채널 묶음에 맞춘 판정 (1단계)
--
--   사양서 docs/specs/2026-08-27-min-followers-channel-match.md
--   작업표 docs/specs/2026-08-27-min-followers-channel-match-breakdown.md 작업 3
--
--   무엇을 바꾸나
--     홍보 메일 대상 판정 `_meets_min_followers` 가 **기준 채널 하나**만 보던 것을
--     사양서 설계 1 의 **갈래 셋**으로 바꾼다.
--
--       채널 1개  → 그 채널로 검사 (종전과 같음)
--       또는(or)  → 모집 채널 중 **하나라도** 넘으면 통과   ← 이번에 바뀌는 것
--       그리고(and) → **이번엔 안 바꾼다** (기준 채널 하나 — 2단계에서 채널별로)
--
--   왜
--     「Instagram or X or TikTok」 캠페인인데 기준 채널 하나만 봐서, 인스타 100명·
--     틱톡 1만명인 사람이 막혔다. 2026-08-27 00:24 에 담당자가 팝업 3건의
--     min_followers 를 1,000 → 0 으로 바꿨다(campaign_change_history 3건, 1분 간격).
--     조건이 고쳐진 게 아니라 사라졌다. 이 변경은 그 재발을 막는다.
--
-- 🔴 **베이스는 마이그레이션 141 이다** — `_meets_min_followers` 의 **유일한 정의**다.
--    143·259·321·360 은 이 함수를 **호출만** 한다(정의하지 않는다). 확인함.
--
-- 🔴 **같은 판정이 두 곳에 따로 산다.** 여기와 화면(`dev/lib/shared.js` 의
--    `campaignFollowerKind`·`meetsMinFollowers`)이 코드를 공유할 수 없다.
--    둘이 어긋나면 **홍보 메일은 오는데 응모는 막히거나** 그 반대가 되고,
--    **어느 쪽도 오류를 내지 않는다.** 한쪽을 고치면 반드시 다른 쪽도 고칠 것.
--
-- ⚠️ **`get_promo_digest_targets`(이 함수를 부르는 쪽)는 안 건드린다.**
--    그 함수에는 **채널 문지기**가 따로 있어 네 채널(instagram·tiktok·x·youtube)만
--    안다. Qoo10·LIPS·@cosme 만 쓰는 캠페인은 애초에 홍보 메일 대상이 아니다.
--    **결함이 아니라 결정**이다(사양서 「확정된 결정」 3번) — 고치려면 회원 프로필에
--    그 채널 계정 칸을 만드는 일부터라 별도 기획거리다.
--    ⚠️ 그 함수의 **현재 원본은 360** 이다(141 아님). 141 을 베이스로 재작성하면
--       321(비공개 캠페인 제외)·360(탈퇴 신청자 제외)이 통째로 사라진다.
--    🔴 그 함수를 나중에 고치는 날 — 마이그레이션 **375** 가 실행 권한을 회수했다.
--       375 의 세 줄은 **부여 1 + 회수 2**이고 **부여가 먼저**다. `CREATE OR REPLACE`
--       는 권한을 보존하지만 `DROP` 후 `CREATE` 하면 **회수가 통째로 풀린다**(로그인한
--       회원 누구나 다른 회원 이메일·수신거부 토큰을 받게 된다). 오류도 표시도 없다.
--
-- ⚠️ 시그니처(인자 8개)는 **그대로 둔다** — 호출부 네 곳(143·259·321·360)을 안 건드리려고.
-- ⚠️ 기존 48건은 안 건드린다 — 전부 단일 채널이라 「채널 1개」 갈래로 그대로 동작한다.
-- ============================================================

BEGIN;

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
  v_tokens    text[];
  v_kind      text;
  v_channel   text;
  v_followers bigint;
  v_tok       text;
BEGIN
  -- monitor(리뷰어) 캠페인은 팔로워 무관 — 141 그대로
  IF p_recruit_type = 'monitor' THEN
    RETURN true;
  END IF;

  -- min_followers NULL 또는 0 이면 제한 없음 → true — 141 그대로
  IF p_min_followers IS NULL OR p_min_followers <= 0 THEN
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

  -- 갈래 판정 — 사양서 설계 1. 화면 `campaignFollowerKind` 와 같은 조건.
  --   🔴 채널이 하나면 channel_match 를 **보지 않는다**. 여기서는 애초에
  --      channel_match 를 인자로 받지 않으므로, 「그리고」는 호출부가 구분해 줄 수
  --      없다 — 아래 주석 참조.
  IF COALESCE(array_length(v_tokens, 1), 0) <= 1 THEN
    v_kind := 'single';
  ELSE
    v_kind := 'or';
  END IF;

  -- ⚠️ **여기서 「그리고」를 가릴 수 없다** — 이 함수는 `channel_match` 를 인자로 받지
  --    않는다(141 의 시그니처). 그래서 채널이 둘 이상이면 전부 「또는」으로 본다.
  --    🔴 **1단계에서는 이것이 의도한 동작이다.** 「그리고」 갈래는 2단계에서 다루고,
  --       그때 `channel_match` 를 인자로 더하거나 호출부에서 갈라 주어야 한다.
  --    🔴 그때까지 「그리고」 캠페인은 **홍보 메일 쪽에서만 「또는」으로 판정**되어
  --       응모 화면(기준 채널 하나)과 어긋난다. 운영 실측상 「그리고」 5건이 전부
  --       리뷰어형이라 위 조기 반환에 걸려 **실제로는 도달하지 않는다**(2026-08-27).
  --       2단계에서 반드시 닫을 것.

  IF v_kind = 'or' THEN
    -- 🔴 모집 채널 중 **하나라도** 넘으면 통과
    FOREACH v_tok IN ARRAY v_tokens LOOP
      v_followers := CASE v_tok
        WHEN 'instagram' THEN COALESCE(p_ig_followers, 0)
        WHEN 'qoo10'     THEN COALESCE(p_ig_followers, 0)  -- Qoo10 은 Instagram 값을 빌려 쓴다
        WHEN 'tiktok'    THEN COALESCE(p_tiktok_followers, 0)
        WHEN 'x'         THEN COALESCE(p_x_followers, 0)
        WHEN 'youtube'   THEN COALESCE(p_youtube_followers, 0)
        ELSE 0  -- 팔로워를 담는 자리가 없는 채널(LIPS·@cosme)
      END;
      IF v_followers >= p_min_followers THEN
        RETURN true;
      END IF;
    END LOOP;
    RETURN false;
  END IF;

  -- 'single' — 기준 채널 하나를 본다 (141 그대로)
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

COMMENT ON FUNCTION public._meets_min_followers(text, text, text, integer, integer, integer, integer, integer) IS
  '[384] 팔로워 수 매칭 헬퍼 — 채널 묶음 갈래 판정(141 재정의). '
  'monitor 캠페인은 항상 true. min_followers<=0 이면 true. '
  '채널 1개: 그 채널(primary_channel 우선, 없으면 첫 채널). '
  '채널 2개+: 하나라도 넘으면 통과(「또는」). '
  '⚠️ channel_match 를 인자로 안 받아 「그리고」를 못 가린다 — 2단계에서 닫을 것. '
  '⚠️ Qoo10 은 Instagram 팔로워 값을 빌려 쓴다. LIPS·@cosme 는 값이 없어 0. '
  '🔴 화면 dev/lib/shared.js 의 campaignFollowerKind·meetsMinFollowers 와 같은 판정이어야 한다. '
  'SECURITY DEFINER + search_path 고정.';

-- 내부 헬퍼 — 141 과 같은 회수를 유지한다.
--   ⚠️ CREATE OR REPLACE 는 권한을 보존하지만, 141 이 회수한 상태를 명시적으로 한 번 더
--      못 박는다(다음 사람이 DROP 후 CREATE 로 재작성하는 경우의 안전망은 아니다 —
--      그때는 이 줄을 그 파일에 다시 넣어야 한다).
REVOKE EXECUTE ON FUNCTION public._meets_min_followers(text, text, text, integer, integer, integer, integer, integer) FROM PUBLIC, anon;

COMMIT;

-- ============================================================
-- 적용 후 확인 (SQL 편집기에서 한 번 돌릴 것)
--
--   ⚠️ **적용 성공이 동작 확인이 아니다.** 함수를 만드는 구문은 본문의 자료형·컬럼
--      참조를 검사하지 않아, 적용은 성공하고 **첫 호출에서 터진다**
--      (.claude/rules/supabase.md 「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」).
--
-- -- [1] 「또는」 다채널 — 틱톡만 넘어도 통과해야 한다 (기대: true)
-- SELECT public._meets_min_followers(
--   'gifting', 'instagram', 'instagram,x,tiktok', 1000,
--   100 /*ig*/, 10000 /*tiktok*/, 0 /*x*/, 0 /*youtube*/);
--
-- -- [2] 「또는」 다채널 — 아무 채널도 못 넘으면 막혀야 한다 (기대: false)
-- SELECT public._meets_min_followers(
--   'gifting', 'instagram', 'instagram,x,tiktok', 1000,
--   100, 200, 300, 0);
--
-- -- [3] 단일 채널 — 종전 그대로 (기대: false, true)
-- SELECT public._meets_min_followers('gifting', 'instagram', 'instagram', 1000, 999, 0, 0, 0);
-- SELECT public._meets_min_followers('gifting', 'instagram', 'instagram', 1000, 1000, 0, 0, 0);
--
-- -- [4] 리뷰어형은 검사 안 함 (기대: true)
-- SELECT public._meets_min_followers('monitor', 'instagram', 'instagram', 1000, 0, 0, 0, 0);
--
-- -- [5] Qoo10 은 Instagram 값을 빌려 쓴다 (기대: true)
-- SELECT public._meets_min_followers('gifting', 'qoo10', 'qoo10', 1000, 5000, 0, 0, 0);
--
-- -- [6] 기준 채널이 비면 첫 채널로 (기대: true)
-- SELECT public._meets_min_followers('gifting', NULL, 'tiktok,youtube', 1000, 0, 5000, 0, 0);
--
-- -- [7] 팔로워 값이 없는 채널만 있으면 아무도 통과 못 한다 (기대: false)
-- --     ⚠️ 지금 안 터지는 것은 LIPS·@cosme 가 리뷰어형 전용이고 리뷰어형은 위에서
-- --        조기 반환되기 때문이다. 그 안전판이 사라지면 여기가 문제가 된다.
-- SELECT public._meets_min_followers('gifting', 'cosme', 'lips,cosme', 1000, 99999, 99999, 99999, 99999);
-- ============================================================
