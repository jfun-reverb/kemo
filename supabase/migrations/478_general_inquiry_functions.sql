-- ============================================================
-- 478_general_inquiry_functions.sql
-- 일반 문의 창구 — 데이터 모델 ④ 새 원격 호출 함수 5개
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-4 ③⑥ · §5-5 ④ · §5-6 ②③
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ④)
-- 선행: 475(칸) · 477(응대 완료 표)
--
-- 만드는 함수 (전부 SECURITY DEFINER + SET search_path='' + 스키마 명시)
--   1. get_general_inquiry_messages(p_influencer_id uuid DEFAULT NULL)        — 대화 조회 (326 짝)
--   2. send_general_inquiry_message(p_body text, p_attachments jsonb DEFAULT '[]', p_influencer_id uuid DEFAULT NULL)
--                                                                            — 발신 (323 짝, 같은 계량)
--   3. mark_general_inquiry_messages_read(p_influencer_id uuid DEFAULT NULL)  — 읽음 (144 짝)
--   4. mark_general_inquiry_resolved(p_influencer_id uuid)                    — 수동 응대 완료 (145 짝)
--   5. general_inquiry_admin_unread_counts(p_admin_auth_id uuid DEFAULT NULL) — 관리자 안읽음 집계 (144 짝)
--
-- 베이스(짝으로 삼은 현재 원본 — 전부 정의(CREATE FUNCTION)인 파일만 골랐다)
--   get_application_messages         → 326 (144 → 235 → 326. 마지막 정의)
--   send_application_message         → 323 (144 → 145 → 323. 마지막 정의)
--   mark_application_messages_read   → 144 (유일한 정의)
--   mark_application_resolved        → 145 (유일한 정의)
--   application_message_admin_unread_counts → 144 (유일한 정의)
--   숨김·복구·회수 함수(hide/unhide/withdraw_own_message)는 메시지 id 만 봐서 **그대로 부른다** — 재정의 없음.
--
-- ⚠️ 인자 순서: 사양서·작업표 제안은 (p_influencer_id, p_body, p_attachments) 였으나, 발신 함수는
--    회원이 인자를 안 넘기는 쪽이 자연스러워 (p_body, p_attachments, p_influencer_id) 로 두고 뒤 둘에 기본값을 줬다.
--    원격 호출은 이름 인자(named)라 순서와 무관하게 부를 수 있고, p_influencer_id 를 항상 넘겨도 된다.
-- ⚠️ 관리자 검사를 먼저 한다(323·144 와 같은 방식) — 관리자를 겸한 회원은 이 함수들에서 관리자로 취급되어
--    인자(p_influencer_id)가 필수다. 일반 문의 화면을 여는 겸직 관리자는 자기 회원 id 를 인자로 넘겨야 한다.
--
-- 발신 제한(323 과 같은 계량): sender_id = auth.uid() · 최근 1시간 · broadcast_id IS NULL 행 수 ≥ 100 이면 거부.
--   같은 표(application_messages)를 같은 조건으로 세므로 응모건 발신과 일반 문의 발신이 **합산**된다(따로 세면 200/시간).
-- 탈퇴 확정 회원의 발신은 막지 않는다(사양서 §12 ③ 결론 — 359·422 의 차단 판정 함수를 부르지 않는다).
--
-- ── 적용 뒤 호출해 볼 조회 (함수마다 한 줄. 🔴 관리자·회원 판정은 SQL 편집기(서비스 키)로 재현 안 됨 —
--     편집기에서는 「로그인 없음」 거부가 나는 것이 정상. 실제 값은 로그인 브라우저 콘솔에서) ──
--   [V1] await db.rpc('get_general_inquiry_messages')                        // 회원: 본인 대화([]도 정상)
--   [V2] await db.rpc('send_general_inquiry_message', {p_body:'テスト'})      // 회원: uuid 반환 → 표에 행 1개, 응대완료 행 없음
--   [V3] await db.rpc('mark_general_inquiry_messages_read')                  // 회원: void
--   [V4] await db.rpc('mark_general_inquiry_resolved', {p_influencer_id:'<회원 uuid>'})   // 관리자: void, 응대 완료 행 manual
--   [V5] await db.rpc('general_inquiry_admin_unread_counts')                 // 관리자: [{influencer_id, unread_count}]
--   [V6] 권한 확인 — 다섯 함수 모두 맨 앞 =X/ 없고 anon 없음, authenticated 있음:
--        SELECT p.proname, p.proacl::text FROM pg_proc p
--         WHERE p.pronamespace='public'::regnamespace AND p.proname IN
--          ('get_general_inquiry_messages','send_general_inquiry_message','mark_general_inquiry_messages_read',
--           'mark_general_inquiry_resolved','general_inquiry_admin_unread_counts');
--   [V7] 거부 확인: 회원이 남의 첨부 경로(general/{남의id}/x.jpg)를 실어 보내면 P0001 「添付ファイルの保存先が正しくありません」.
--
-- ── 되돌리는 방법 ──
--   BEGIN;
--     DROP FUNCTION IF EXISTS public.general_inquiry_admin_unread_counts(uuid);
--     DROP FUNCTION IF EXISTS public.mark_general_inquiry_resolved(uuid);
--     DROP FUNCTION IF EXISTS public.mark_general_inquiry_messages_read(uuid);
--     DROP FUNCTION IF EXISTS public.send_general_inquiry_message(text, jsonb, uuid);
--     DROP FUNCTION IF EXISTS public.get_general_inquiry_messages(uuid);
--   COMMIT;
--   (이미 쌓인 일반 문의 행·알림은 함수를 지워도 남는다 — 필요하면 별도로 지운다.)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. get_general_inquiry_messages — 326 get_application_messages 의 짝
--    반환 열은 326 과 같은 17칸(번역 칸 셋 포함, sender_id 는 관리자에게만). 응모 열(application_id)은 항상 NULL.
--    마스킹 규칙(강제숨김·본인회수 4종)은 326 과 글자 그대로 같다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_general_inquiry_messages(
  p_influencer_id uuid DEFAULT NULL
) RETURNS TABLE (
  id                      uuid,
  application_id          uuid,
  sender_kind             text,
  sender_name             text,
  body                    text,
  attachments             jsonb,
  created_at              timestamptz,
  read_by_influencer_at   timestamptz,
  broadcast_id            uuid,
  hidden_by_admin_at      timestamptz,
  self_withdrawn_at       timestamptz,
  self_withdrawn_by_kind  text,
  mask_state              text,
  body_translated         text,
  translated_lang         text,
  translate_status        text,
  sender_id               uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller_is_admin  boolean;
  v_target           uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
  END IF;

  v_caller_is_admin := public.is_admin();

  -- 관리자는 대상 회원 필수, 회원은 인자를 무시하고 본인 것만
  IF v_caller_is_admin THEN
    IF p_influencer_id IS NULL THEN
      RAISE EXCEPTION '会員を指定してください' USING ERRCODE = 'P0001';
    END IF;
    v_target := p_influencer_id;
  ELSE
    v_target := auth.uid();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = v_target) THEN
    RAISE EXCEPTION 'ユーザーが見つかりません' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.application_id,
    m.sender_kind,
    m.sender_name,
    -- body 마스킹 분기 (326 과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.body
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.body
        END
    END AS body,
    -- attachments 마스킹 분기 (body 와 동일)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN '[]'::jsonb
          ELSE m.attachments
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN '[]'::jsonb
          WHEN m.self_withdrawn_at  IS NOT NULL THEN '[]'::jsonb
          ELSE m.attachments
        END
    END AS attachments,
    m.created_at,
    m.read_by_influencer_at,
    m.broadcast_id,
    m.hidden_by_admin_at,
    m.self_withdrawn_at,
    m.self_withdrawn_by_kind,
    -- mask_state (326 과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'
          ELSE 'visible'
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'
          ELSE 'visible'
        END
    END AS mask_state,
    -- [235 짝] 번역 칸 셋 — body 와 완전히 같은 마스킹 분기
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.body_translated
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.body_translated
        END
    END AS body_translated,
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translated_lang
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translated_lang
        END
    END AS translated_lang,
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translate_status
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translate_status
        END
    END AS translate_status,
    -- [326 짝] sender_id — 관리자 호출자에게만, body 와 같은 마스킹 분기. 회원 호출자에게는 항상 NULL.
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.sender_id
        END
      ELSE NULL
    END AS sender_id
  FROM public.application_messages m
  WHERE m.application_id IS NULL
    AND m.influencer_id = v_target
  ORDER BY m.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_general_inquiry_messages(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_general_inquiry_messages(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_general_inquiry_messages(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_general_inquiry_messages(uuid) IS
  '[478] 일반 문의(응모 없는 메시지) 대화 조회. 326 get_application_messages 의 짝 — 반환 17칸·마스킹 규칙 동일'
  '(번역 칸 셋 포함, sender_id 는 관리자에게만). 회원은 인자를 무시하고 본인 것만, 관리자는 p_influencer_id 필수. '
  'application_id 열은 항상 NULL. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 2. send_general_inquiry_message — 323 send_application_message 의 짝
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_general_inquiry_message(
  p_body            text,
  p_attachments     jsonb DEFAULT '[]'::jsonb,
  p_influencer_id   uuid  DEFAULT NULL
) RETURNS uuid  -- 새 메시지 id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_kind text;
  v_sender_name text;
  v_target      uuid;     -- 대화의 주인 회원
  v_att         jsonb;
  v_prefix      text;
  v_msg_id      uuid;
  v_rate_count  bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
  END IF;

  -- sender_kind 판별 (관리자 먼저 — 323 과 같은 순서)
  IF public.is_admin() THEN
    IF p_influencer_id IS NULL THEN
      RAISE EXCEPTION '会員を指定してください' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = p_influencer_id) THEN
      RAISE EXCEPTION 'ユーザーが見つかりません' USING ERRCODE = 'P0001';
    END IF;
    v_sender_kind := 'admin';
    v_target      := p_influencer_id;
    SELECT name INTO v_sender_name FROM public.admins WHERE auth_id = auth.uid();
  ELSE
    -- 회원은 인자를 무시하고 본인으로 고정
    SELECT name INTO v_sender_name FROM public.influencers WHERE id = auth.uid();
    IF NOT FOUND THEN
      RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
    END IF;
    v_sender_kind := 'influencer';
    v_target      := auth.uid();
  END IF;

  -- 첨부는 배열이어야 한다
  v_att := COALESCE(p_attachments, '[]'::jsonb);
  IF jsonb_typeof(v_att) <> 'array' THEN
    RAISE EXCEPTION '添付ファイルの形式が正しくありません' USING ERRCODE = 'P0001';
  END IF;

  -- 본문/첨부 빈값 검증 (323 과 같은 문구)
  IF (p_body IS NULL OR btrim(p_body) = '') AND v_att = '[]'::jsonb THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です' USING ERRCODE = 'P0001';
  END IF;

  -- 첨부 경로 서버 검사 — 모든 경로가 general/{대화 주인 회원 id}/ 로 시작해야 한다(사양서 §5-6 ②).
  --   접두어 비교는 LIKE 가 아니라 left() 로(경로 안 특수문자 영향 차단).
  v_prefix := 'general/' || v_target::text || '/';
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_att) AS e
     WHERE left(COALESCE(e ->> 'path', ''), length(v_prefix)) <> v_prefix
        -- 접두어 뒤는 파일 이름 한 조각만(추가 빗금·「..」 같은 경로 조작 거부)
        OR substr(e ->> 'path', length(v_prefix) + 1) !~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$'
  ) THEN
    RAISE EXCEPTION '添付ファイルの保存先が正しくありません' USING ERRCODE = 'P0001';
  END IF;

  -- Rate limit: 323 send_application_message 와 **같은 조회**(사용자별 100건/시간, 일괄 발송 행 제외).
  --   같은 표를 같은 조건으로 세므로 두 함수의 발신이 합산된다.
  SELECT count(*) INTO v_rate_count
    FROM public.application_messages
   WHERE sender_id = auth.uid()
     AND created_at > now() - interval '1 hour'
     AND broadcast_id IS NULL;

  IF v_rate_count >= 100 THEN
    RAISE EXCEPTION 'メッセージの送信上限（1時間に100件）に達しました。しばらく経ってからお試しください'
      USING ERRCODE = 'P0001';
  END IF;

  -- ⚠️ 응모 종료 90일 차단은 없다(응모가 없다). 탈퇴 확정 회원 차단도 일부러 안 건다(사양서 §12 ③).

  INSERT INTO public.application_messages (
    application_id, influencer_id, sender_kind, sender_id, sender_name, body, attachments
  ) VALUES (
    NULL,
    v_target,
    v_sender_kind,
    auth.uid(),
    COALESCE(v_sender_name, '(이름미상)'),
    COALESCE(p_body, ''),
    v_att
  )
  RETURNING id INTO v_msg_id;

  -- 자동 응대 처리 (145 와 같은 뜻 — 결정 J):
  --   회원 새 글 → 응대 완료 행 삭제(reopen) / 관리자 답장 → 응대 완료 행 upsert(auto_replied)
  IF v_sender_kind = 'influencer' THEN
    DELETE FROM public.general_inquiry_resolutions
     WHERE influencer_id = v_target;
  ELSE
    INSERT INTO public.general_inquiry_resolutions (
      influencer_id, resolved_at, resolved_by, resolved_by_name,
      resolved_after_message_at, resolution_method
    ) VALUES (
      v_target,
      now(),
      auth.uid(),
      COALESCE(v_sender_name, '(이름미상)'),
      COALESCE(
        (SELECT max(m.created_at)
           FROM public.application_messages m
          WHERE m.application_id IS NULL
            AND m.influencer_id = v_target
            AND m.sender_kind = 'influencer'
            AND m.hidden_by_admin_at IS NULL
            AND m.self_withdrawn_at IS NULL),
        now()  -- 회원 메시지가 없을 때(관리자가 먼저 시작) now() 폴백
      ),
      'auto_replied'
    )
    ON CONFLICT (influencer_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';

    -- 관리자 발신 시 회원에게 알림 — 종류는 message_received 그대로, ref_table 로 가른다(사양서 §5-6 ③).
    --   중복 방지(145 방식): 같은 회원에게 미읽음 일반 문의 알림이 이미 있으면 또 넣지 않는다.
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
       WHERE user_id   = v_target
         AND kind      = 'message_received'
         AND ref_table = 'general_inquiry'
         AND ref_id    = v_target
         AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_target,
        'message_received',
        'general_inquiry',
        v_target,
        'お問い合わせに運営から返信が届きました',
        COALESCE(v_sender_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;
  END IF;

  RETURN v_msg_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid) TO authenticated;

COMMENT ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid) IS
  '[478] 일반 문의(응모 없는 메시지) 발송. 323 send_application_message 의 짝 — 발신 제한 100건/시간을 같은 조회로 셈(합산). '
  '회원 발신은 p_influencer_id 무시하고 auth.uid(), 관리자 발신은 p_influencer_id 필수. 첨부 경로는 general/{주인 회원 id}/ 로 시작해야 함(서버 검사). '
  '관리자 답장 → 응대 완료 upsert(auto_replied) + 알림(message_received / ref_table=general_inquiry / ref_id=회원 id, 미읽음 중복 방지). '
  '회원 새 글 → 응대 완료 행 삭제. 탈퇴 확정 회원 발신은 막지 않음(사양서 §12 ③). SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 3. mark_general_inquiry_messages_read — 144 mark_application_messages_read 의 짝
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_general_inquiry_messages_read(
  p_influencer_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
  END IF;

  IF public.is_admin() THEN
    IF p_influencer_id IS NULL THEN
      RAISE EXCEPTION '会員を指定してください' USING ERRCODE = 'P0001';
    END IF;
    -- 관리자: 본인이 안 읽은 회원 메시지를 admin_reads 에 upsert (144 와 같은 조건)
    INSERT INTO public.application_message_admin_reads (message_id, admin_auth_id, read_at)
    SELECT m.id, auth.uid(), now()
      FROM public.application_messages m
     WHERE m.application_id IS NULL
       AND m.influencer_id = p_influencer_id
       AND m.sender_kind = 'influencer'
       AND m.hidden_by_admin_at IS NULL
    ON CONFLICT (message_id, admin_auth_id) DO NOTHING;
  ELSE
    -- 회원: 인자를 무시하고 본인 대화의 관리자 메시지를 읽음 처리 (144 와 같은 조건)
    UPDATE public.application_messages
       SET read_by_influencer_at = now()
     WHERE application_id IS NULL
       AND influencer_id = auth.uid()
       AND sender_kind = 'admin'
       AND read_by_influencer_at IS NULL
       AND hidden_by_admin_at IS NULL;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_general_inquiry_messages_read(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_general_inquiry_messages_read(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_general_inquiry_messages_read(uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_general_inquiry_messages_read(uuid) IS
  '[478] 일반 문의 읽음 처리. 144 mark_application_messages_read 의 짝. 관리자: 회원 메시지를 admin_reads 에 upsert(p_influencer_id 필수). '
  '회원: 본인 대화의 관리자 메시지 read_by_influencer_at 갱신(인자 무시). SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 4. mark_general_inquiry_resolved — 145 mark_application_resolved 의 짝 (수동 응대 완료)
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_general_inquiry_resolved(
  p_influencer_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name             text;
  v_last_influencer_msg_at timestamptz;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '権限がありません（管理者専用）' USING ERRCODE = 'P0001';
  END IF;

  IF p_influencer_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = p_influencer_id) THEN
    RAISE EXCEPTION 'ユーザーが見つかりません' USING ERRCODE = 'P0001';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 살아 있는 마지막 회원 메시지 시각 (145 와 같은 기준)
  SELECT max(m.created_at) INTO v_last_influencer_msg_at
    FROM public.application_messages m
   WHERE m.application_id IS NULL
     AND m.influencer_id = p_influencer_id
     AND m.sender_kind        = 'influencer'
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL;

  INSERT INTO public.general_inquiry_resolutions (
    influencer_id, resolved_at, resolved_by, resolved_by_name,
    resolved_after_message_at, resolution_method
  ) VALUES (
    p_influencer_id,
    now(),
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    COALESCE(v_last_influencer_msg_at, now()),
    'manual'
  )
  ON CONFLICT (influencer_id) DO UPDATE
    SET resolved_at               = EXCLUDED.resolved_at,
        resolved_by               = EXCLUDED.resolved_by,
        resolved_by_name          = EXCLUDED.resolved_by_name,
        resolved_after_message_at = EXCLUDED.resolved_after_message_at,
        resolution_method         = 'manual';
END;
$$;

REVOKE ALL ON FUNCTION public.mark_general_inquiry_resolved(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_general_inquiry_resolved(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_general_inquiry_resolved(uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_general_inquiry_resolved(uuid) IS
  '[478] 일반 문의 수동 응대 완료. 145 mark_application_resolved 의 짝(is_admin() 가드 — 모든 관리자). '
  'general_inquiry_resolutions upsert(manual). 회원 메시지가 없으면 now() 폴백. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 5. general_inquiry_admin_unread_counts — 144 application_message_admin_unread_counts 의 짝
--    (479 가 기존 집계에서 응모 없는 행을 빼므로, 이 짝이 없으면 일반 문의 「안읽음」 칩이 영영 안 뜬다)
-- ============================================================
CREATE OR REPLACE FUNCTION public.general_inquiry_admin_unread_counts(
  p_admin_auth_id uuid DEFAULT NULL  -- NULL 이면 auth.uid()
) RETURNS TABLE (influencer_id uuid, unread_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  -- 관리자 전용 가드 (144 와 같은 방식)
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '관리자 전용 함수입니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    m.influencer_id,
    count(*) AS unread_count
  FROM public.application_messages m
  LEFT JOIN public.application_message_admin_reads r
    ON r.message_id = m.id
   AND r.admin_auth_id = COALESCE(p_admin_auth_id, auth.uid())
  WHERE m.application_id IS NULL
    AND m.influencer_id IS NOT NULL
    AND m.sender_kind = 'influencer'
    AND m.hidden_by_admin_at IS NULL
    AND m.self_withdrawn_at IS NULL   -- 회원 본인 회수 메시지는 집계 제외 (144 와 같은 조건)
    AND r.message_id IS NULL          -- 본인이 안 읽음
  GROUP BY m.influencer_id;
END;
$$;

REVOKE ALL ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) TO authenticated;

COMMENT ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) IS
  '[478] 관리자 본인 기준 회원별 일반 문의 안읽음 회원 메시지 수. 144 application_message_admin_unread_counts 의 짝. '
  'is_admin() 가드 — 비관리자 호출 시 insufficient_privilege. p_admin_auth_id NULL = auth.uid(). SECURITY DEFINER + search_path 고정.';

NOTIFY pgrst, 'reload schema';

COMMIT;
