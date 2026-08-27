-- ============================================================
-- 391. 일괄 발송 사슬 — 발송 상세가 사슬 정보를 돌려준다 (후속 발송 1단계 ④)
--
-- 무엇을 바꾸나
--   `get_broadcast_detail` 이 돌려주는 `broadcast` 안에 두 가지를 더한다.
--     · `parent_broadcast_id` — 이 발송이 어느 발송의 추가분인가
--     · `chain` — 화면이 「추가 발송」 버튼을 켤지 정하는 데 필요한 **날것의 사실**
--
--   | 열쇠말 | 뜻 |
--   |---|---|
--   | `has_live_descendant` | 이 발송 아래에 **회수 안 된** 자손이 있나 (= 서버 거부 ②와 같은 사실) |
--   | `last_live_id`        | 이 사슬에서 회수 안 된 것 중 **가장 나중 것**(= 이어 보낼 자리) |
--   | `last_live_visible`   | 🔴 그 발송을 **내가 볼 수 있나** |
--   | `followup_count`      | 이 사슬의 추가 발송 수(정보 표시용) |
--
-- 🔴 **날것의 사실만 준다.** 네 조건(조건 발송인가·회수됐나·마지막인가·판을 아는가)을
--    하나로 합쳐 「누를 수 있다/없다」로 주지 않는다 — 합치면 화면이 **왜** 막혔는지
--    말할 수 없고, 사양서가 「감추지 말고 이유를 말한다」로 세운 기준이 깨진다.
--    나머지 셋은 이미 돌려주고 있다(`context_kind`·`withdrawn_at`·`context_filter`).
--
-- 🔴 `has_live_descendant` 는 **바로 아래 한 겹이 아니라 자손 전체**를 본다.
--    한 겹만 보면 「1차 → 2차(회수됨) → 3차(살아 있음)」에서 1차가 통과해 버려,
--    1차 아래에 형제가 생기고 **두 갈래가 서로의 수신자를 못 봐 겹쳐 받는다.**
--
-- 🔴 `last_live_visible` 이 필요한 이유 — 캠페인 관리자 A 의 발송에 **최고 관리자 S 가
--    이어 보내면**, A 는 그 사슬에 영영 못 잇는다(목록에 안 보이고 서버도 거부한다).
--    그때 링크를 주면 **못 여는 링크**가 된다. 화면은 「다른 관리자가 이어 보냈습니다」
--    라고 **할 수 있는 일**을 말해야 한다.
--
-- ⚠️ 「마지막을 세는 기준」은 **회수된 것을 건너뛴다**(그래야 마지막이 회수된 사슬을
--    이어 보낼 수 있다). **뺄 집합(389)에서는 회수된 발송의 수신자도 뺀다** — 회수는
--    가리는 것이지 안 보낸 것이 아니다. **두 기준을 한 곳으로 묶지 말 것.**
--
-- 베이스 = **마이그레이션 167**(이 함수의 유일한 정의).
--   🔴 본문은 167 파일에서 **기계로 가져와** 세 곳만 고쳤다.
--   ✅ **시그니처가 안 바뀌므로 `CREATE OR REPLACE`** — 167 이 걸어 둔 실행 권한
--      (`REVOKE FROM PUBLIC, anon` + `GRANT TO authenticated`)이 **그대로 보존된다.**
--      🔴 DROP 후 CREATE 하면 그 회수가 풀린다(387 에서 실제로 겪었다).
--
-- ⚠️ **돌려주는 값이 는다 — 화면이 그것을 무시하는지 확인할 것.** 인자가 아니라
--    반환이 바뀌는 유일한 함수라, 화면이 열쇠말을 엄격하게 읽고 있으면 상세가 깨진다.
--
-- 선행: **388**(부모 칸). 없으면 `b.parent_broadcast_id` 가 없는 칸을 가리킨다.
-- 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md` 설계 2·5-2
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_broadcast_detail(
  p_broadcast_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id     uuid;
  v_result        jsonb;
  v_broadcast_ts  timestamptz;  -- 해당 broadcast 메시지들의 최초 created_at (replied 기준점)
  -- [391] 사슬 정보 — 화면 버튼 조건과 서버 거부가 **같은 사실**을 보게 한다
  v_has_live_desc     boolean := false;  -- 이 발송 아래에 회수 안 된 자손이 있나(서버 거부 ②의 원재료)
  v_last_live_id      uuid;              -- 이 사슬에서 회수 안 된 것 중 가장 나중 것
  v_last_live_sender  uuid;              -- 그 발송의 발신자(볼 수 있는지 판단용)
  v_followup_count    integer := 0;      -- 이 사슬의 추가 발송 수(정보 표시용)
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- broadcast 존재 + 발신자 확인
  SELECT sender_id INTO v_sender_id
    FROM public.application_message_broadcasts
   WHERE id = p_broadcast_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '一括送信グループが見つかりません: %', p_broadcast_id;
  END IF;

  -- 권한별 가시성: super_admin 이 아니면 본인 발송분만
  IF NOT public.is_super_admin() AND v_sender_id <> auth.uid() THEN
    RAISE EXCEPTION 'アクセス権限がありません'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- broadcast 에 속한 메시지 중 가장 이른 created_at (replied 기준점)
  SELECT MIN(m.created_at) INTO v_broadcast_ts
    FROM public.application_messages m
   WHERE m.broadcast_id = p_broadcast_id;

  -- ----------------------------------------------------------------
  -- [391] 사슬 정보
  --   🔴 화면 버튼 조건과 **글자 그대로 같은 사실**을 돌려준다. 기준이 갈리면
  --      화면이 막는 것을 서버가 통과시키거나, 그 반대가 된다.
  --   ⚠️ 여기서는 **날것의 사실만** 준다(「자손 중 살아 있는 게 있나」).
  --      네 조건(조건 발송인가·회수됐나·마지막인가·판을 아는가)을 하나로 합쳐
  --      「누를 수 있다/없다」로 주지 않는다 — 합치면 화면이 **왜** 막혔는지 말할 수 없고,
  --      사양서가 「감추지 말고 이유를 말한다」로 세운 기준이 깨진다.
  --   ⚠️ 「마지막을 세는 기준」은 **회수된 것을 건너뛴다.** 안 그러면 마지막이 회수된
  --      사슬을 영영 이어 보낼 수 없는 **막다른 길**이 생긴다.
  --      (뺄 집합에서는 회수된 발송의 수신자도 뺀다 — 다른 기준이다.)
  -- ----------------------------------------------------------------
  WITH RECURSIVE up AS (
    SELECT b.id, b.parent_broadcast_id, 1 AS depth
      FROM public.application_message_broadcasts b
     WHERE b.id = p_broadcast_id
    UNION ALL
    SELECT p.id, p.parent_broadcast_id, up.depth + 1
      FROM public.application_message_broadcasts p
      JOIN up ON up.parent_broadcast_id = p.id
     WHERE up.depth < 100
  ),
  root AS (
    SELECT u.id FROM up u WHERE u.parent_broadcast_id IS NULL LIMIT 1
  ),
  chain AS (
    SELECT b.id, b.withdrawn_at, b.sender_id, b.created_at, b.parent_broadcast_id, 1 AS depth
      FROM public.application_message_broadcasts b
     WHERE b.id = (SELECT r.id FROM root r)
    UNION ALL
    SELECT c.id, c.withdrawn_at, c.sender_id, c.created_at, c.parent_broadcast_id, chain.depth + 1
      FROM public.application_message_broadcasts c
      JOIN chain ON c.parent_broadcast_id = chain.id
     WHERE chain.depth < 100
  ),
  descendants AS (
    SELECT d.id, d.withdrawn_at, 1 AS depth
      FROM public.application_message_broadcasts d
     WHERE d.parent_broadcast_id = p_broadcast_id
    UNION ALL
    SELECT g.id, g.withdrawn_at, descendants.depth + 1
      FROM public.application_message_broadcasts g
      JOIN descendants ON g.parent_broadcast_id = descendants.id
     WHERE descendants.depth < 100
  )
  --   🔴 「가장 나중」은 **깊이**로 센다. 시각(`created_at`)으로 세면 안 된다 —
  --      같은 순간에 만들어진 발송이 있으면 순서가 뒤집힌다(개발서버 시험에서
  --      실제로 1차가 「마지막」으로 나왔다). 사슬은 줄이므로 깊이가 곧 순서이고,
  --      깊이는 절대 겹치지 않는다.
  SELECT
    EXISTS (SELECT 1 FROM descendants x WHERE x.withdrawn_at IS NULL),
    (SELECT c.id        FROM chain c WHERE c.withdrawn_at IS NULL ORDER BY c.depth DESC LIMIT 1),
    (SELECT c.sender_id FROM chain c WHERE c.withdrawn_at IS NULL ORDER BY c.depth DESC LIMIT 1),
    (SELECT count(*)::integer FROM chain c WHERE c.parent_broadcast_id IS NOT NULL)
    INTO v_has_live_desc, v_last_live_id, v_last_live_sender, v_followup_count;

  -- 결과 조립
  SELECT jsonb_build_object(
    'broadcast', jsonb_build_object(
      'id',                    b.id,
      'sender_id',             b.sender_id,
      'sender_name',           b.sender_name,
      'body',                  b.body,
      'attachments',           b.attachments,
      'recipient_count',       b.recipient_count,
      'created_at',            b.created_at,
      'context_kind',          b.context_kind,
      'context_campaign_id',   b.context_campaign_id,
      'context_filter',        b.context_filter,
      'withdrawn_at',          b.withdrawn_at,
      'withdrawn_by',          b.withdrawn_by,
      'withdrawn_reason_code', b.withdrawn_reason_code,
      'withdrawn_reason_memo', b.withdrawn_reason_memo,
      -- [391] 사슬 — 화면 버튼 조건이 서버 거부와 같은 사실을 보게 한다
      'parent_broadcast_id',   b.parent_broadcast_id,
      'chain', jsonb_build_object(
        -- 이 발송 아래에 **회수 안 된** 자손이 있나 = 서버 거부 ②와 같은 사실.
        --   🔴 「바로 아래 한 겹」이 아니라 **자손 전체**를 본다.
        'has_live_descendant', v_has_live_desc,
        -- 이 사슬에서 회수 안 된 것 중 가장 나중 것(= 이어 보낼 자리)
        'last_live_id',        v_last_live_id,
        -- 🔴 그 발송을 **내가 볼 수 있나.** 못 보는 남의 발송이면 화면은 링크를 주지 않고
        --    「다른 관리자가 이어 보냈습니다」라고 말해야 한다 — 링크를 주고 못 열게
        --    하는 것이 가장 나쁘다(최고 관리자가 남의 사슬에 이으면 실제로 생긴다).
        'last_live_visible',   (
          v_last_live_id IS NOT NULL
          AND (public.is_super_admin() OR v_last_live_sender = auth.uid())
        ),
        'followup_count',      v_followup_count
      )
    ),
    'recipients', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'application_id',  m.application_id,
          'message_id',      m.id,
          -- 인플루언서 이름: applications.user_id = influencers.id 조인
          'influencer_name', COALESCE(i.name, '(이름미상)'),
          -- 캠페인 제목
          'campaign_title',  COALESCE(c.title, '(캠페인 없음)'),
          -- 캠페인 고유번호 — 화면이 「캠페인별로 골라 보기」에 쓴다.
          --   ⚠️ 제목으로 묶으면 안 된다. 복제 캠페인은 제목이 같아서
          --      서로 다른 두 캠페인이 한 덩어리로 합쳐진다.
          'campaign_id',     a.campaign_id,
          -- 읽음 여부: read_by_influencer_at IS NOT NULL
          'read',            (m.read_by_influencer_at IS NOT NULL),
          -- 답장 여부: broadcast 메시지 이후 인플루언서 메시지 EXISTS
          'replied',         EXISTS (
            SELECT 1
              FROM public.application_messages r
             WHERE r.application_id = m.application_id
               AND r.sender_kind    = 'influencer'
               AND r.created_at     > COALESCE(v_broadcast_ts, b.created_at)
               AND r.self_withdrawn_at IS NULL  -- 본인 회수 메시지 제외
          ),
          -- 숨김 여부: hidden_by_admin_at IS NOT NULL
          'hidden',          (m.hidden_by_admin_at IS NOT NULL)
        )
        ORDER BY m.created_at ASC
      )
      FROM public.application_messages m
      JOIN public.applications        a ON a.id      = m.application_id
      JOIN public.influencers         i ON i.id      = a.user_id
      JOIN public.campaigns           c ON c.id      = a.campaign_id
      WHERE m.broadcast_id = p_broadcast_id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.application_message_broadcasts b
  WHERE b.id = p_broadcast_id;

  RETURN v_result;
END;
$$;
COMMENT ON FUNCTION public.get_broadcast_detail(uuid) IS
  '[391] 일괄 발송 이력 상세. 167 반환에 parent_broadcast_id 와 chain 을 더했다 — '
  'chain = {has_live_descendant, last_live_id, last_live_visible, followup_count}. '
  '화면 버튼 조건이 서버 거부(390)와 같은 사실을 보게 하는 것이 목적이다. '
  'has_live_descendant 는 바로 아래 한 겹이 아니라 자손 전체를 본다. '
  '마지막 세기는 회수된 것을 건너뛰고, 뺄 집합(389)은 회수된 것도 뺀다 — 다른 기준이다.';

COMMIT;

-- ============================================================
-- 적용 후 확인 — **「성공」은 동작 확인이 아니다.**
--   ⚠️ `is_campaign_admin()` 가드가 있어 **SQL 편집기로는 재현 안 된다**
--      (서비스 키에는 로그인 사용자가 없다). **로그인한 관리자 브라우저 콘솔**에서.
--
-- ── [1] 🔴 실행 권한이 167 그대로인가 ──
--   기대: `=X/` PUBLIC 몫 **없음**, `anon=` **없음**, `authenticated=X/` **있음**
--   (CREATE OR REPLACE 라 보존돼야 한다. 하나라도 어긋나면 DROP 이 섞인 것이다.)
-- SELECT p.proname, p.proacl::text
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'get_broadcast_detail';
--
-- ── [2] 종전 열쇠말이 그대로 있는가 — 브라우저 콘솔 ──
--   기대: recipients 가 예전과 같은 모양. **늘어난 값 때문에 상세가 깨지지 않는지**
--         화면을 실제로 열어 눈으로 볼 것(이 함수만 반환이 바뀐다).
--   const d = await db.rpc('get_broadcast_detail', { p_broadcast_id: '<발송id>' })
--
-- ── [3] 사슬 정보가 맞는가 — 부모 없는 발송(대부분) ──
--   기대: parent_broadcast_id = null,
--         chain.has_live_descendant = false, chain.followup_count = 0,
--         chain.last_live_id = 자기 자신, chain.last_live_visible = true
--
-- ⚠️ **시험 사슬은 한 문장으로 만들지 말 것** — 같은 `now()` 가 박혀 `created_at` 이
--    똑같아진다. 개발서버 첫 시험에서 그래서 `last_live_id` 가 1차로 나왔고,
--    그 덕에 「시각으로 세면 안 된다」는 것이 드러났다(지금은 깊이로 센다).
--    만들 때 각 줄 사이에 `pg_sleep(0.01)` 을 넣거나 따로 실행할 것.
--
-- ── [4] 🔴 한 겹이 아니라 자손 전체를 보는가 ──
--   **이 파일에서 가장 틀리기 쉬운 자리다.** 만들 상태(390 적용 후):
--     1차 → 2차(회수함) → 3차(살아 있음)
--   기대: **1차**를 조회하면 `has_live_descendant = true`(2차는 회수됐지만 3차가 산다),
--         `last_live_id = 3차`.
--   한 겹만 보는 구현이면 여기서 **false 가 나온다** — 그러면 화면 버튼이 켜지고
--   금지한 나무가 만들어진다.
--
-- ── [5] 막다른 길이 안 생기는가 ──
--   만들 상태: 1차 → 2차(회수함), 그 아래 없음
--   기대: **1차** 조회 시 `has_live_descendant = false`, `last_live_id = 1차`.
--         (회수된 것을 건너뛰므로 1차에서 이어 보낼 수 있다.)
--
-- ── [6] 🔴 남의 사슬은 링크를 주면 안 된다 ──
--   만들 상태: 캠페인 관리자 A 의 발송에 **최고 관리자 S** 가 이어 보냄
--   기대: **A 의 계정**으로 A 의 발송을 조회하면
--         `last_live_id` 는 채워지고 `last_live_visible = false`.
--         화면은 이때 **링크 없이** 「다른 관리자가 이어 보냈습니다」라고 말한다.
-- ============================================================
