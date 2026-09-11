-- ============================================================
-- 417. 전수조사 조치 3종 — 홍보 메일 채널 정확 일치(D-6) · 추가 발송 가드 행 잠금(D-5) ·
--      관리자 초대 이메일 대소문자 무시(I-2)
-- ============================================================
-- 조치 계획: docs/specs/2026-09-02-audit-remediation-plan.md (D-5·D-6·I-2)
-- 조사 원문: docs/research/2026-09-02-codebase-audit-findings.md §4-7·§4-8·§(I-2)
-- 세 함수 모두 **현재 원본을 통째로 복사**하고 표시한 줄만 바꿨다(CREATE OR REPLACE — 시그니처
-- 불변이라 권한 보존). 베이스: get_promo_digest_targets=**387** · send_application_message_bulk=
-- **390** · invite_admin=**245**. ⚠️ 다음에 다시 손댈 때 베이스는 이 파일(417)이다.
--
-- ── D-6 홍보 메일 채널 문지기: `LIKE '%x%'` → 토큰 정확 일치 ─────────────
-- `c.channel` 은 콤마로 이은 채널 코드다. `LIKE '%x%'` 는 글자 x 가 든 **다른 코드**(자동 생성
-- 코드가 15.3% 확률로 x 를 포함, 영문 이름이면 확정적)에도 참이 되어 X 계정이 없는 회원에게
-- X 캠페인이 매칭될 수 있었다. 일괄 발송(389)이 이미 쓰는 정확 일치로 맞춘다. 운영 실측(M8)
-- 으로는 지금 x 가 든 코드가 0건 — 잠복. 🔴 이 함수는 375 의 권한 회수가 걸려 있다 —
-- **반드시 CREATE OR REPLACE**(DROP 하면 회수가 풀려 로그인한 회원 누구나 명단을 받는다).
--
-- ── D-5 추가 발송 사슬 가드: 부모 행 `FOR UPDATE` ───────────────────────
-- 390 의 「부모가 사슬의 마지막인가」 검사는 읽기만 해서, 같은 부모로 두 호출이 겹치면 둘 다
-- 「자손 없음」을 보고 통과 → 200건 반복문이 도는 수 초 사이 **같은 사람이 두 번 받는다**.
-- 부모 행을 `FOR UPDATE` 로 잠그면 두 번째 호출이 첫 호출의 커밋을 기다린 뒤 검사를 다시
-- 하므로 자손이 보여 거부된다. 유일 제약은 없다(388). 운영 실측(M7) 사슬 0건 — 잠복.
--
-- ── I-2 관리자 초대: 이메일 소문자·공백 정규화 ──────────────────────────
-- `invite_admin` 이 `email = admin_email` 로 글자 그대로 찾았다. 대소문자가 다르면 기존 계정을
-- 못 찾아 「신규」 갈래로 가고, admins 중복 검사도 못 잡는다. 입력을 소문자로 정규화하고 두 조회를
-- `lower(email)` 로 — 인증 서비스가 어떤 대소문자로 저장하든 무관하다. 화면 쪽은 이미 `ilike`
-- (CLAUDE.md). 운영 실측(M12) 어긋난 계정 0건.
--
-- 롤백: 387·390·245 의 정의로 되돌린다.
-- ============================================================

-- ── D-6 ─────────────────────────────────────────────────────
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


-- ── D-5 ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.send_application_message_bulk(
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
     WHERE b.id = p_parent_broadcast_id
       FOR UPDATE;   -- [417] 같은 부모로 이어 보내는 두 호출을 직렬화한다(아래 주석)

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


-- ── I-2 ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.invite_admin(admin_email text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  existing_user_id uuid;
  new_user_id       uuid;
  target_user_id    uuid;
  temp_password     text;
  is_promotion      boolean := false;
BEGIN
  -- [417] 이메일은 대소문자·앞뒤 공백을 무시한다(전수조사 I-2). 예전엔 `email = admin_email`
  --   글자 그대로 비교라 대소문자가 다르면 기존 계정을 못 찾아 「신규」 갈래로 가고(유일 제약에
  --   걸림), admins 중복 검사도 못 잡았다. 인증 서비스가 저장하는 대소문자와 **무관하게** 이 함수가
  --   양쪽을 소문자로 맞춰 비교·저장하므로 안전하다(CLAUDE.md 가 화면 조회에 ilike 를 쓰는 이유와 같다).
  admin_email := lower(btrim(admin_email));
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;

  IF EXISTS (SELECT 1 FROM public.admins WHERE lower(email) = admin_email) THEN
    RAISE EXCEPTION 'Admin with this email already exists';
  END IF;

  SELECT id INTO existing_user_id FROM auth.users WHERE lower(email) = admin_email LIMIT 1;

  IF existing_user_id IS NOT NULL THEN
    -- ────────────────────────────────────────────────────────
    -- 승격: 기존 계정(주로 인플루언서)을 관리자로 올린다.
    -- [245] 비밀번호는 절대 건드리지 않는다 — 이미 본인이 쓰고 있는 유효한 비밀번호를
    -- 덮어쓸 기술적 필요가 없다(031 원본은 여기서 encrypted_password 를 임시 랜덤값으로
    -- 덮어써 그 사람의 기존 로그인을 즉시 끊었다).
    -- 로그인 차단 방지용 메타데이터 보정만 유지 — 전부 COALESCE 라 기존 값이 있으면
    -- 그대로 두고, 비어 있던 값만 채운다(부작용 없음).
    -- ────────────────────────────────────────────────────────
    is_promotion := true;

    UPDATE auth.users
       SET email_confirmed_at = COALESCE(email_confirmed_at, now()),
           email_change       = COALESCE(email_change, ''),
           raw_app_meta_data  = COALESCE(raw_app_meta_data, jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')))
     WHERE id = existing_user_id;

    target_user_id := existing_user_id;
  ELSE
    -- 신규 생성: 기존 031 동작과 완전히 동일. 임시 32자 랜덤 비밀번호(받는 사람은
    -- 초대 메일 링크로만 로그인 가능 — 이 경로가 유일한 로그인 수단이므로 여기서만
    -- temp_password 를 생성한다).
    temp_password := encode(extensions.gen_random_bytes(24), 'base64');

    new_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email,
      encrypted_password, email_confirmed_at,
      created_at, updated_at,
      confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token,
      raw_app_meta_data, raw_user_meta_data
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      new_user_id, 'authenticated', 'authenticated', admin_email,
      extensions.crypt(temp_password, extensions.gen_salt('bf', 10)),
      now(), now(), now(),
      '', '', '', '', '', '', '', '',
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true, 'phone_verified', false)
    );
    INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
    VALUES (
      gen_random_uuid(), new_user_id,
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true),
      'email', new_user_id::text, now(), now()
    );
    target_user_id := new_user_id;
  END IF;

  INSERT INTO public.admins (auth_id, email, name, role, promoted_at)
  VALUES (target_user_id, admin_email, admin_name, admin_role, CASE WHEN is_promotion THEN now() ELSE NULL END);

  RETURN target_user_id;
END;
$$;


-- 권한은 CREATE OR REPLACE 로 보존된다(387: postgres·service_role 만 / 390: authenticated / 245: authenticated).
-- ⚠️ 그래도 D-6 는 적용 뒤 반드시 확인한다 — 이 함수가 `authenticated` 에 열리면 회원 명단이 샌다:
--   select p.proacl::text from pg_proc p where p.proname = 'get_promo_digest_targets';
--   → `authenticated=X` 가 **없어야** 하고 맨 앞 `=X/` 도 없어야 한다.
--
-- ============================================================
-- 검증 (개발 DB)
-- ============================================================
-- 1) D-6: select count(*) from public.get_promo_digest_targets(current_date);  -- 오류 없이 수가 나오면 됨
-- 2) D-5: begin; set local role authenticated; select set_config('request.jwt.claims','{"sub":"<관리자 auth_id>","role":"authenticated"}',true);
--         select public.send_application_message_bulk(array['00000000-0000-0000-0000-000000000000']::uuid[], '검증', '[]'::jsonb, 'manual', null, null, null, '00000000-0000-0000-0000-000000000001'::uuid);
--         → 「이어 보낼 발송을 찾을 수 없습니다」 예외면 새 본문이 컴파일·실행된 것. rollback;
-- 3) I-2: ⚠️ 2) 의 rollback 으로 역할·클레임이 초기화됐으므로 **다시** `begin; set local role authenticated;
--         select set_config(...)` 를 돌리되, sub 는 **super_admin** 의 auth_id 여야 한다(이 함수는 super_admin 만 통과).
--         select public.invite_admin('Dev.Test.UPPER@example.com','검증','campaign_manager');
--         select email from public.admins where email = 'dev.test.upper@example.com';  → 소문자로 저장. rollback;
