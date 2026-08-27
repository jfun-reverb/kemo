-- ============================================================
-- 390. 일괄 발송 사슬 — 부모 지정 + 서버 거부 세 가지 (후속 발송 1단계 ③)
--
-- 무엇을 바꾸나
--   `send_application_message_bulk` 에 인자 하나(`p_parent_broadcast_id`)를 더해
--   **어느 발송의 추가분인가**를 그룹 행에 남기고, 그 값이 있을 때만 도는
--   **거부 세 가지**를 얹는다. NULL 이면 종전과 완전히 같다 — 지금 화면은 이 인자를
--   안 넘기므로 **동작 변화 0**이고, 거부 셋은 **발동할 일이 없다.**
--
-- 🔴 왜 서버가 막나 — 화면 버튼이 유일한 방어선이면 안 된다.
--    겹쳐 받는 것이 이 기능이 막으려는 바로 그 사고다.
--
--   | # | 거절하는 것 | 짝이 되는 화면 조건 |
--   |---|---|---|
--   | ① | 남의 발송에 잇기 | 권한(이력 목록과 같은 기준) |
--   | ② | 부모가 그 사슬의 마지막이 아니면(회수된 것은 건너뛰고 셈) | 「그 사슬의 마지막 발송임」 |
--   | ③ | 부모 자신이 회수된 발송이면 | 「회수되지 않음」 |
--
--   🔴 ②를 「바로 아래 자식이 있으면 거절」로 쓰면 안 된다 — 한 겹만 보는데 화면은
--      사슬 전체를 본다. 「1차 → 2차(회수됨) → 3차(살아 있음)」에서 1차는 화면이
--      막는데 서버는 통과시켜, **금지한 나무가 서버를 뚫고 만들어진다.**
--      → 자손을 **전부** 훑고 **회수 안 된 것이 하나라도** 있으면 막는다.
--   🔴 ③이 없으면 「회수되지 않음」에 서버 방어가 통째로 없다. 회수된 발송에 이어
--      보내는 것은 **가린 내용을 새로 퍼뜨리는** 일이라 가볍지 않다.
--   ⚠️ ①의 진짜 이유는 「수신자가 두 번 받아서」가 아니다 — 추가 발송의 대상은 1차를
--      안 받은 사람이라 각자 한 통씩만 받는다. **목록에서 안 보이는 발송은 상세를 열 수
--      없어 조건도 본문도 알 수 없기 때문**이다.
--
-- ⚠️ 「마지막을 세는 기준」과 「뺄 집합」은 **다른 기준**이다.
--    · 마지막 세기(여기) — 회수된 것은 **건너뛴다**. 안 그러면 마지막이 회수된 사슬을
--      영영 이어 보낼 수 없는 **막다른 길**이 생긴다.
--    · 뺄 집합(389)   — 회수된 발송의 수신자도 **뺀다**. 회수는 가리는 것이지
--      안 보낸 것이 아니다(메시지도 알림도 이미 갔다).
--    한 기준으로 묶으면 회수된 발송의 수신자가 다시 받는다.
--
-- 베이스 = **마이그레이션 168**(167 → **168**).
--   🔴 본문은 168 파일에서 **기계로 가져와** 다섯 곳만 고쳤다.
--   ⚠️ 인자 개수가 바뀌므로 **DROP 후 CREATE**. 이 함수에는 회수해 둔 실행 권한이
--      없다(369·370·375 가 건드리지 않았다 — 적용 전 조회로 확인할 것).
--
-- 선행: **388**(부모 칸)이 먼저 적용돼 있어야 한다. 없으면 INSERT 가 없는 칸을 가리킨다.
-- 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md` 설계 2·6
-- ============================================================

BEGIN;

-- 168 이 만든 7인자 정의를 지운다(인자 목록은 168 파일과 글자 그대로 같아야 한다)
DROP FUNCTION IF EXISTS public.send_application_message_bulk(
  uuid[], text, jsonb, text, uuid, jsonb, text);

CREATE FUNCTION public.send_application_message_bulk(
  p_application_ids     uuid[],
  p_body                text,
  p_attachments         jsonb DEFAULT '[]'::jsonb,
  p_context_kind        text  DEFAULT 'manual',
  p_context_campaign_id uuid  DEFAULT NULL,
  p_context_filter      jsonb DEFAULT NULL,
  p_title               text  DEFAULT NULL,  -- 관리자 전용 제목, 인플 메시지 본문에 미포함
  -- [390] 추가 발송 — 이 발송이 어느 발송의 추가분인가. NULL 이면 최초 발송.
  p_parent_broadcast_id uuid  DEFAULT NULL
) RETURNS uuid  -- broadcast_id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name        text;
  v_broadcast_id      uuid;
  v_app_id            uuid;
  v_app_owner         uuid;
  v_camp_title        text;
  v_inserted          integer := 0;
  v_msg_id            uuid;
  v_last_inf_msg_at   timestamptz;
  v_parent_sender     uuid;       -- [390] 부모 발송의 발신자
  v_parent_withdrawn  timestamptz;-- [390] 부모 발송의 회수 시각
  v_live_descendant   uuid;       -- [390] 부모 아래에 살아 있는 자손
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 수신자 배열 비어 있음 검증
  IF array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION '受信者がいません';
  END IF;

  -- 1회 한도 200명 검증
  IF array_length(p_application_ids, 1) > 200 THEN
    RAISE EXCEPTION '1回の一括送信は最大200名までです';
  END IF;

  -- 본문·첨부 빈값 검증 (개별 send_application_message 와 동일)
  IF (p_body IS NULL OR btrim(p_body) = '')
     AND (p_attachments IS NULL OR p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です';
  END IF;

  -- context_kind 유효성 검증
  IF p_context_kind NOT IN ('campaign', 'manual') THEN
    RAISE EXCEPTION 'context_kind は campaign または manual のみ有効です';
  END IF;

  -- ----------------------------------------------------------------
  -- [390] 추가 발송 — 서버 거부 세 가지
  --   🔴 화면 버튼이 유일한 방어선이면 안 된다. 겹쳐 받는 것이 이 기능이 막으려는
  --      바로 그 사고이고, 화면 조건과 **글자 그대로 같은 기준**이어야 한다.
  -- ----------------------------------------------------------------
  IF p_parent_broadcast_id IS NOT NULL THEN
    SELECT b.sender_id, b.withdrawn_at
      INTO v_parent_sender, v_parent_withdrawn
      FROM public.application_message_broadcasts b
     WHERE b.id = p_parent_broadcast_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION '이어 보낼 발송을 찾을 수 없습니다: %', p_parent_broadcast_id;
    END IF;

    -- ① 남의 발송에 잇기 — 이력 목록과 **같은 기준**.
    --    🔴 이유는 「수신자가 두 번 받아서」가 아니다. 추가 발송의 대상은 1차를 안 받은
    --       사람이라 각자 한 통씩만 받는다. **진짜 이유는 목록에서 안 보이는 발송은
    --       상세를 열 수 없어 조건도 본문도 알 수 없기 때문**이다.
    IF NOT public.is_super_admin() AND v_parent_sender <> auth.uid() THEN
      RAISE EXCEPTION '다른 관리자의 발송에는 이어 보낼 수 없습니다'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- ③ 부모 자신이 회수된 발송이면 거절.
    --    회수된 발송에 이어 보내는 것은 **가린 내용을 새로 퍼뜨리는** 일이라
    --    겹쳐 받는 것보다 가볍지 않다.
    IF v_parent_withdrawn IS NOT NULL THEN
      RAISE EXCEPTION '회수된 발송에는 이어 보낼 수 없습니다';
    END IF;

    -- ② 부모가 그 사슬의 **마지막이 아니면** 거절 (회수된 것은 건너뛰고 셈).
    --    🔴 「바로 아래 자식이 있으면 거절」로 쓰면 안 된다 — 그건 **한 겹**만 보는데
    --       화면은 **사슬 전체**를 본다. 「1차 → 2차(회수됨) → 3차(살아 있음)」에서
    --       1차는 화면이 막는데 서버는 통과시켜, 1차 아래에 형제가 생겨
    --       **금지한 나무가 서버를 뚫고 만들어진다.**
    --    ⚠️ 그래서 자손을 **전부** 훑고, 그중 **회수 안 된 것이 하나라도** 있으면 막는다.
    WITH RECURSIVE down AS (
      SELECT c.id, c.withdrawn_at, 1 AS depth
        FROM public.application_message_broadcasts c
       WHERE c.parent_broadcast_id = p_parent_broadcast_id
      UNION ALL
      SELECT g.id, g.withdrawn_at, down.depth + 1
        FROM public.application_message_broadcasts g
        JOIN down ON g.parent_broadcast_id = down.id
       WHERE down.depth < 100
    )
    SELECT d.id INTO v_live_descendant
      FROM down d
     WHERE d.withdrawn_at IS NULL
     LIMIT 1;

    IF v_live_descendant IS NOT NULL THEN
      RAISE EXCEPTION '이미 추가 발송이 있습니다 — 그 사슬의 마지막 발송에서 이어 보내세요';
    END IF;
  END IF;

  -- 발신자 이름 스냅샷 (145 와 동일 패턴)
  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- broadcast 그룹 메타 INSERT (recipient_count 는 실제 INSERT 후 UPDATE)
  -- ★ 167 대비 변경: title 컬럼 추가
  INSERT INTO public.application_message_broadcasts (
    sender_id,
    sender_name,
    body,
    attachments,
    recipient_count,
    context_kind,
    context_campaign_id,
    context_filter,
    title,
    parent_broadcast_id   -- [390]
  ) VALUES (
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    COALESCE(p_body, ''),
    COALESCE(p_attachments, '[]'::jsonb),
    0,
    p_context_kind,
    p_context_campaign_id,
    p_context_filter,
    p_title,  -- NULL 허용 (선택 사항)
    p_parent_broadcast_id   -- [390] NULL 이면 최초 발송
  )
  RETURNING id INTO v_broadcast_id;

  -- ----------------------------------------------------------------
  -- FOREACH: 각 응모건에 메시지 INSERT + 응대 완료 자동 등록 + 알림
  -- ----------------------------------------------------------------
  FOREACH v_app_id IN ARRAY p_application_ids LOOP
    -- 응모 소유자 조회 (존재하지 않는 id 는 skip)
    SELECT user_id INTO v_app_owner
      FROM public.applications WHERE id = v_app_id;

    IF v_app_owner IS NULL THEN
      CONTINUE;
    END IF;

    -- 캠페인명 조회 (알림 title 용 — 145 와 동일 패턴)
    SELECT c.title INTO v_camp_title
      FROM public.applications a
      JOIN public.campaigns c ON c.id = a.campaign_id
     WHERE a.id = v_app_id;

    -- 메시지 INSERT (broadcast_id 채움)
    -- ★ 인플루언서에게 보내는 메시지 본문에는 title 컬럼 없음 (인플 비노출 보장)
    INSERT INTO public.application_messages (
      application_id,
      sender_kind,
      sender_id,
      sender_name,
      body,
      attachments,
      broadcast_id
    ) VALUES (
      v_app_id,
      'admin',
      auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'),
      COALESCE(p_body, ''),
      COALESCE(p_attachments, '[]'::jsonb),
      v_broadcast_id
    )
    RETURNING id INTO v_msg_id;

    -- 응대 완료 자동 등록 (auto_replied) — 145 의 send_application_message 와 동일 구조
    SELECT max(created_at) INTO v_last_inf_msg_at
      FROM public.application_messages
     WHERE application_id = v_app_id
       AND sender_kind        = 'influencer'
       AND hidden_by_admin_at IS NULL
       AND self_withdrawn_at  IS NULL;

    INSERT INTO public.application_message_resolutions (
      application_id,
      resolved_at,
      resolved_by,
      resolved_by_name,
      resolved_after_message_at,
      resolution_method
    ) VALUES (
      v_app_id,
      now(),
      auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'),
      COALESCE(v_last_inf_msg_at, now()),
      'auto_replied'
    )
    ON CONFLICT (application_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';

    -- 알림 INSERT (kind='message_received')
    -- 같은 응모건에 미읽음 알림이 이미 있으면 INSERT 안 함 (145 와 동일 중복 방지 조건)
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
       WHERE user_id   = v_app_owner
         AND kind      = 'message_received'
         AND ref_table = 'applications'
         AND ref_id    = v_app_id
         AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id,
        kind,
        ref_table,
        ref_id,
        title,
        body
      ) VALUES (
        v_app_owner,
        'message_received',
        'applications',
        v_app_id,
        COALESCE(v_camp_title, '') || ' — 運営からメッセージが届きました',
        COALESCE(v_admin_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;

    v_inserted := v_inserted + 1;
  END LOOP;
  -- ----------------------------------------------------------------

  -- 실제 INSERT 수로 recipient_count 갱신
  UPDATE public.application_message_broadcasts
     SET recipient_count = v_inserted
   WHERE id = v_broadcast_id;

  -- 0건이면 broadcast 행 정리 후 예외
  IF v_inserted = 0 THEN
    DELETE FROM public.application_message_broadcasts WHERE id = v_broadcast_id;
    RAISE EXCEPTION '送信された応募がありません (すべて存在しないか削除済み)';
  END IF;

  RETURN v_broadcast_id;
END;
$$;
-- 🔴 **168 이 걸어 둔 실행 권한을 새 8인자 함수에 다시 건다.**
--    `DROP` 은 그 함수에 붙은 회수·부여도 함께 지운다. 안 다시 걸면
--    **167 부터 지켜 온 비로그인 차단이 조용히 풀린다.**
--    ⚠️ 387 에서 이 함정을 실제로 밟았다(`_meets_min_followers`).
--       → 적용 전 권한을 먼저 찍어 두고 적용 후와 대조할 것.
REVOKE EXECUTE ON FUNCTION public.send_application_message_bulk(
  uuid[], text, jsonb, text, uuid, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message_bulk(
  uuid[], text, jsonb, text, uuid, jsonb, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.send_application_message_bulk(
  uuid[], text, jsonb, text, uuid, jsonb, text, uuid) IS
  '[390] 일괄 발송. p_parent_broadcast_id 를 주면 그 발송의 추가분으로 사슬에 잇는다. '
  '거부 셋 — ①남의 발송 ②그 사슬의 마지막이 아님(회수된 것은 건너뛰고 셈) ③부모가 회수됨. '
  '화면 버튼과 글자 그대로 같은 기준이어야 한다.';

COMMIT;

-- ============================================================
-- 적용 후 확인 — **「성공」은 동작 확인이 아니다.**
--   ⚠️ 이 함수는 `is_campaign_admin()` 가드가 있어 **SQL 편집기로는 [3] 이후가 재현
--      안 된다**(서비스 키에는 로그인 사용자가 없다). [1]·[2]는 여기서,
--      나머지는 **로그인한 관리자 브라우저 콘솔**에서.
--   🔴 [4]~[6]은 **실제로 메시지를 보낸다.** 반드시 개발서버에서, 시험 캠페인으로.
--
-- ── [1] 같은 이름이 하나뿐인가 (기대: 1) ──
-- SELECT count(*) AS 정의_1
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'send_application_message_bulk';
--
-- ── [2] 🔴 인자 8개 + 실행 권한이 종전과 같은가 ──
--   **기대값(개발서버 적용 전 실측, 2026-08-27):**
--     인자수 = 8
--     PUBLIC(`=X/`) **없음** · `anon=` **없음** · `authenticated=X/` **있음** · `service_role=X/` **있음**
--   ⚠️ 하나라도 어긋나면 DROP 이 회수를 푼 것이다 — 387 에서 실제로 그랬다.
-- SELECT p.pronargs AS 인자수_8,
--        (p.proacl::text LIKE '%anon=X/%')          AS anon_열림_false,
--        (p.proacl::text LIKE '%authenticated=X/%') AS auth_열림_true,
--        p.proacl::text AS 원문
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'send_application_message_bulk';
--
-- ── [3] 부모 칸이 실제로 저장되는가 (발송 뒤) ──
-- SELECT id, parent_broadcast_id, withdrawn_at, created_at
--   FROM public.application_message_broadcasts
--  ORDER BY created_at DESC LIMIT 5;
--
-- ── [4] 거부 ① — 남의 발송에 잇기 (기대: 「다른 관리자의 발송에는…」) ──
--   ⚠️ 최고 관리자로 하면 통과한다(의도). **캠페인 관리자 계정**으로 볼 것.
--
-- ── [5] 거부 ③ — 회수된 발송에 잇기 (기대: 「회수된 발송에는…」) ──
--   발송 하나를 `withdraw_broadcast` 로 회수한 뒤 그 발송을 부모로 준다.
--
-- ── [6] 🔴 거부 ② — 한 겹이 아니라 사슬 전체를 보는가 ──
--   **이것이 이 파일에서 가장 틀리기 쉬운 자리다.** 만들 상태:
--     1차 → 2차(회수함) → 3차(살아 있음)
--   기대: **1차를 부모로 주면 거절**되어야 한다(2차는 회수됐지만 3차가 살아 있다).
--   한 겹만 보는 구현이면 여기서 **통과해 버린다** — 그러면 1차 아래에 형제가 생겨
--   금지한 나무가 만들어지고, 두 갈래가 서로의 수신자를 못 봐 **겹쳐 받는다.**
--
-- ── [7] 막다른 길이 안 생기는가 ──
--   만들 상태: 1차 → 2차(회수함), 그 아래 없음
--   기대: **1차를 부모로 주면 통과**해야 한다(회수된 것은 건너뛰고 세므로).
--   여기서 막히면 그 사슬을 영영 이어 보낼 수 없다.
-- ============================================================
