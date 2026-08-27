-- ============================================================
-- 389. 일괄 발송 사슬 — 대상에서 「이미 받은 응모건」 빼기 (후속 발송 1단계 ②)
--
-- 무엇을 바꾸나
--   `resolve_bulk_recipients` 에 인자 하나(`p_exclude_broadcast_id`)를 더한다.
--   그 값이 있으면 **그 발송이 속한 사슬 전체**가 이미 보낸 응모건을 대상에서 뺀다.
--   NULL 이면 종전과 완전히 같다 — 지금 화면은 이 인자를 안 넘기므로 **동작 변화 0**.
--
-- 🔴 「이미 받은 사람」을 세는 데 **새 표를 만들지 않는다.**
--    홍보 메일은 별도 표(`campaign_promo_digest_sent`)를 쓰지만 그건 **메일이라
--    저장소에 흔적이 안 남아서**다. 일괄 발송은 보낸 결과가 `application_messages`
--    행으로 그대로 남고 `broadcast_id` 로 묶여 있다. 표를 새로 만들면 **같은 사실이
--    두 곳**이 되어 어긋날 자리가 생긴다.
--
-- 🔴 **응모건 단위로 뺀다.** 사람 단위로 빼면 같은 사람의 **다른 캠페인 건까지**
--    통째로 빠진다(일괄 발송은 응모건마다 한 통씩 간다).
--
-- 베이스 = **마이그레이션 171**(167 → 168 → **171**. 169 는 정의가 아니다).
--   🔴 본문은 171 파일에서 **기계로 가져와** 네 곳만 고쳤다(인자·변수·머리·꼬리).
--      손으로 옮기면 169(도도부현·팔로워)·171(완전 승인) 필터가 통째로 사라진다.
--   ⚠️ 인자 개수가 바뀌므로 **DROP 후 CREATE** 다. 이 함수에는 회수해 둔 실행 권한이
--      없다(369·370·375 가 건드리지 않았다 — 적용 전 조회로 확인할 것).
--      🔴 회수가 걸린 함수였다면 DROP 하는 순간 그것이 풀린다.
--
-- ⚠️ 옛 시그니처를 지울 때 **인자 목록을 정확히** 적어야 한다. 안 그러면 옛 정의가
--    남아 **같은 이름 두 개**가 되고, 인자를 다 안 주는 호출이 어느 쪽인지 몰라 터진다.
--
-- 선행: **388**(부모 칸). 없으면 `CREATE FUNCTION` 시점에 본문 검사가
--   「column parent_broadcast_id does not exist」로 **시끄럽게** 실패한다(조용한 실패 아님).
-- 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md` 설계 1·2
-- ============================================================

BEGIN;

-- 171 이 만든 15인자 정의를 지운다(인자 목록은 171 파일과 글자 그대로 같아야 한다)
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean);

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
  p_post_all_approved    boolean DEFAULT false,   -- [171 — 항목 B] true=게시물·이미지 완전 승인만
  -- [389] 추가 발송 — 이 발송이 속한 **사슬 전체**의 수신자를 뺀다.
  --   NULL 이면 아무것도 안 뺀다(= 종전 동작). 부모 하나가 아니라 뿌리와
  --   그 뿌리의 모든 자손을 본다 — 한 겹만 보면 2차 수신자가 3차에 또 받는다.
  p_exclude_broadcast_id uuid    DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_result   uuid[];
  v_root     uuid;    -- [389] 사슬의 뿌리
  v_sent_ids uuid[];  -- [389] 사슬 전체가 이미 보낸 응모건
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
  -- [389] 이미 받은 응모건 모으기 (추가 발송)
  --   ① 부모를 따라 **위로** 올라가 뿌리를 찾고
  --   ② 뿌리에서 **아래로** 내려가며 그 사슬의 모든 발송을 모은 뒤
  --   ③ 그 발송들이 실제로 넣은 메시지의 응모건을 전부 뺀다
  --
  --   ⚠️ **회수된 발송의 수신자도 뺀다** — 회수는 가리는 것이지 안 보낸 것이 아니다
  --      (메시지도 알림도 이미 갔다). 「마지막을 세는 기준」과 다른 기준이다.
  --   ⚠️ 깊이 제한 100 — 지금 구조상 고리가 생길 수 없지만(부모는 늘 자기보다 먼저
  --      만들어진 발송을 가리킨다), 고리가 한 번 생기면 이 함수가 **영원히 돌아**
  --      일괄 발송 화면이 통째로 멈춘다. 값싼 안전판이라 걸어 둔다.
  -- ----------------------------------------------------------------
  IF p_exclude_broadcast_id IS NOT NULL THEN
    WITH RECURSIVE up AS (
      SELECT b.id, b.parent_broadcast_id, 1 AS depth
        FROM public.application_message_broadcasts b
       WHERE b.id = p_exclude_broadcast_id
      UNION ALL
      SELECT p.id, p.parent_broadcast_id, up.depth + 1
        FROM public.application_message_broadcasts p
        JOIN up ON up.parent_broadcast_id = p.id
       WHERE up.depth < 100
    )
    SELECT u.id INTO v_root
      FROM up u
     WHERE u.parent_broadcast_id IS NULL
     LIMIT 1;

    -- 깊이 제한에 걸려 뿌리를 못 찾았으면 **아무것도 안 빼고 지나가지 않는다** —
    --   그러면 전원이 두 번 받는다. 눈에 보이게 막는 쪽이 낫다.
    IF v_root IS NULL THEN
      RAISE EXCEPTION '발송 사슬의 뿌리를 찾지 못했습니다 (broadcast_id=%)', p_exclude_broadcast_id
        USING ERRCODE = 'data_exception';
    END IF;

    WITH RECURSIVE down AS (
      SELECT b.id, 1 AS depth
        FROM public.application_message_broadcasts b
       WHERE b.id = v_root
      UNION ALL
      SELECT c.id, down.depth + 1
        FROM public.application_message_broadcasts c
        JOIN down ON c.parent_broadcast_id = down.id
       WHERE down.depth < 100
    )
    SELECT ARRAY(
      SELECT DISTINCT m.application_id
        FROM public.application_messages m
       WHERE m.broadcast_id IN (SELECT d.id FROM down d)
         AND m.application_id IS NOT NULL
    ) INTO v_sent_ids;
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

       -- ── [389] 이 사슬이 이미 보낸 응모건 빼기 ──
       --   ⚠️ **응모건 단위**로 뺀다. 사람 단위로 빼면 같은 사람의 **다른 캠페인 건까지**
       --      통째로 빠진다(일괄 발송은 응모건마다 한 통씩 간다).
       AND (
         v_sent_ids IS NULL
         OR NOT (a.id = ANY(v_sent_ids))
       )

  ) INTO v_result;

  RETURN COALESCE(v_result, ARRAY[]::uuid[]);
END;
$$;
-- 🔴 **171 이 걸어 둔 실행 권한을 새 15인자 함수에 다시 건다.**
--    `DROP` 은 그 함수에 붙은 회수·부여도 함께 지운다. 안 다시 걸면 새 함수가
--    Postgres·Supabase 기본값(PUBLIC·anon 열림)으로 돌아가 **167 부터 지켜 온
--    비로그인 차단이 조용히 풀린다.**
--    ⚠️ 387 에서 이 함정을 실제로 밟았다(`_meets_min_followers`). 그때는 적용 후
--       확인 조회에 `=X/postgres` 가 찍혀 나왔는데도 「의도한 것」으로 읽고 지나갔다.
--       → 이번에는 **적용 전 권한을 먼저 찍어 두고** 적용 후와 대조한다.
REVOKE EXECUTE ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean, uuid
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean, uuid
) TO authenticated;

COMMENT ON FUNCTION public.resolve_bulk_recipients(
  uuid, text[], text[], text[], text[], text[], text, text, integer,
  boolean, boolean, boolean, boolean, boolean, uuid) IS
  '[389] 일괄 발송 대상 고르기. p_exclude_broadcast_id 를 주면 그 발송이 속한 '
  '**사슬 전체**(뿌리와 그 모든 자손)가 이미 보낸 응모건을 뺀다 — 응모건 단위. '
  '회수된 발송의 수신자도 뺀다(회수는 가리는 것이지 안 보낸 것이 아니다).';

COMMIT;

-- ============================================================
-- 적용 후 확인 — **「성공」은 동작 확인이 아니다.**
--   (재정의 함수는 적용이 성공해도 첫 호출에서 터진다 — .claude/rules/supabase.md)
--   ⚠️ 이 함수는 `is_campaign_admin()` 가드가 있어 **SQL 편집기로는 [3]·[4]가 재현
--      안 된다**(서비스 키에는 로그인 사용자가 없어 가드에서 예외가 난다).
--      → **[1]·[2]는 여기서**, **[3]·[4]는 로그인한 관리자 브라우저 콘솔에서.**
--
-- ── [1] 같은 이름이 하나뿐인가 (기대: 1) ──
--   2 가 나오면 옛 14인자 정의가 남은 것이다 → 인자를 다 안 주는 호출이 터진다.
-- SELECT count(*) AS 정의_1
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'resolve_bulk_recipients';
--
-- ── [2] 🔴 인자가 15개인가 + 실행 권한이 종전과 같은가 ──
--   **기대값(개발서버 적용 전 실측, 2026-08-27):**
--     인자수 = 15
--     PUBLIC(`=X/`) **없음** · `anon=` **없음** · `authenticated=X/` **있음** · `service_role=X/` **있음**
--   ⚠️ 하나라도 어긋나면 DROP 이 회수를 푼 것이다 — 387 에서 실제로 그랬다.
--      **「그럴 수도 있지」로 넘기지 말 것.** 이 줄이 그때 없어서 놓쳤다.
-- SELECT p.pronargs AS 인자수_15,
--        (p.proacl::text LIKE '%anon=X/%')          AS anon_열림_false,
--        (p.proacl::text LIKE '%authenticated=X/%') AS auth_열림_true,
--        p.proacl::text AS 원문
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'resolve_bulk_recipients';
--
-- ── [3] 종전 호출(인자 안 줌)이 그대로 도는가 — 브라우저 콘솔 ──
--   기대: 예외 없이 배열. 이 값이 적용 전과 같아야 한다.
--   await db.rpc('resolve_bulk_recipients', { p_campaign_id: '<캠페인id>' })
--
-- ── [4] 사슬 빼기가 실제로 빼는가 — 브라우저 콘솔 ──
--   기대: 뺀 쪽이 안 뺀 쪽보다 **적거나 같다**. 그 발송의 수신자 수만큼 줄어야 한다.
--   const 전 = await db.rpc('resolve_bulk_recipients', { p_campaign_id: '<캠페인id>' })
--   const 후 = await db.rpc('resolve_bulk_recipients',
--                { p_campaign_id: '<캠페인id>', p_exclude_broadcast_id: '<발송id>' })
--
-- ── [5] 없는 발송 고유번호를 주면 어떻게 되나 ──
--   기대: 「뿌리를 찾지 못했습니다」 예외. **조용히 0건을 빼고 지나가면 안 된다** —
--         그러면 전원이 두 번 받는다.
--   await db.rpc('resolve_bulk_recipients',
--     { p_campaign_id: '<캠페인id>', p_exclude_broadcast_id: '00000000-0000-0000-0000-000000000000' })
-- ============================================================
