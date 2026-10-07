-- ============================================================
-- 508_general_inquiry_threads_multi_open_functions.sql
-- 서비스 문의 여러 대화 — 개정 R2 ② 함수·뷰 개정(여러 열린 대화 + 문의 제목 + 상한 5)
--
-- 사양서: docs/specs/2026-10-06-service-inquiry-threads.md 맨 위 「🔄 설계 개정」 절 · 데이터베이스 ② · 발신 규칙 표
-- 선행: 507(표 개정). 현재 원본: send(505 → 508) · reopen(505 → 508) · 뷰(506 → 508)
--
-- 편집기 경고: 뜸 — 무해(옛 발신 함수 4인자 판을 지웠다 6인자로 다시 만들 뿐, 행 삭제 없음)
--   🔴 DROP 으로 실행 권한 회수가 풀리므로 이 파일이 두 방향(PUBLIC·anon 회수 / authenticated 부여)을 다시 건다 — [V3]
--
-- 하는 것
--   ① _general_inquiry_open_limit() — 회원이 동시에 열어 둘 수 있는 문의 수 5(R2-2). 발신 함수와 뷰가 **같이 부르는 한 곳**
--   ② send_general_inquiry_message(p_body, p_attachments, p_influencer_id, p_thread_id, p_title, p_client_token)
--      회원: 대화 id → 그 대화(24시간 안 닫힘이면 다시 열기, 상한) / 토큰 → 같은 토큰 대화 또는 새 대화(제목 필수·상한)
--            / 둘 다 없음 → 옛 화면 호환(열린 대화 중 마지막 글이 가장 최근 → 24시간 안 닫힘 → 제목 없는 새 대화)
--      운영팀: 대화 id → 그 대화(닫혔으면 thread_closed) / 없음 → 열린 대화가 정확히 하나일 때만(0개 no_open_thread · 둘 이상 thread_required)
--   ③ reopen_general_inquiry_thread — open_thread_exists 판정 삭제(R2 「유지」 Q-1). 운영팀 다시 열기는 상한 검사 없음
--   ④ update_general_inquiry_thread_title(p_thread_id, p_title) — 관리자 전원(R2-3). 빈 값이면 제목·번역 비움
--   ⑤ 뷰 general_inquiry_thread_summary — 맨 끝에 칸 넷(title · title_translated · influencer_open_thread_count · influencer_at_open_limit)
--
-- ⚠️ 동작 변화(옛 화면 호환 구간): 505 는 회원이 넘긴 대화 id 를 무시했지만 508 은 따른다 — 조각 3 판 회원 화면이 닫힌 지 24시간 지난
--    대화 id 를 넘기면 새 대화 대신 thread_closed, 남의 대화 id 면 thread_not_found. 대화 id 를 안 넘기는 화면(새 문의·옛 판)은 호환 갈래로 그대로.
--    anon 이 뷰를 직접 조회하면 빈 결과 대신 상한 함수 권한 오류(화면은 anon 으로 안 부른다 — 무해).
-- 거부 코드(새로): title_required · title_too_long · too_many_open_threads · thread_required
--   (그대로: thread_not_found · thread_closed · no_open_thread · new_message_since_view. open_thread_exists 는 없어진다)
--
-- ── 적용 뒤 검증 조회 ──
--   [V1] 함수 모양: SELECT p.proname, pg_get_function_identity_arguments(p.oid) FROM pg_proc p
--          WHERE p.pronamespace='public'::regnamespace AND p.proname IN
--          ('send_general_inquiry_message','reopen_general_inquiry_thread','update_general_inquiry_thread_title','_general_inquiry_open_limit') ORDER BY 1;
--        기대: send 는 6인자 판 **하나만**(4인자 판 없음)
--   [V2] 뷰 칸: 19칸, 맨 끝 넷이 title · title_translated · influencer_open_thread_count · influencer_at_open_limit
--   [V3] 🔴 실행 권한: SELECT p.proname, p.proacl::text FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN
--          ('send_general_inquiry_message','reopen_general_inquiry_thread','update_general_inquiry_thread_title','_general_inquiry_open_limit');
--        기대: 넷 모두 맨 앞 =X/ 없음 · anon 없음 · authenticated=X 있음
--   [V4] 🔴 로그인 브라우저(서비스 키로는 호출자 분기가 안 돈다) — 사양서 「개정 검증」 1~8
--
-- ── 되돌리는 방법 ──
--   supabase/patches/2026-10-06-general-inquiry-threads-rollback.sql 의 [R2-②] 절(505·506 판으로 되돌린다).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- ① 열린 문의 상한 — 숫자는 여기 한 곳(화면은 숫자를 갖지 않는다. 뷰의 influencer_at_open_limit 과 발신 거부만 본다)
--    표를 읽지 않는 순수 함수라 회원도 부를 수 있어야 한다(security_invoker 뷰가 호출자 권한으로 부른다)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._general_inquiry_open_limit()
RETURNS integer
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT 5 $$;

REVOKE ALL ON FUNCTION public._general_inquiry_open_limit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._general_inquiry_open_limit() FROM anon;
GRANT  EXECUTE ON FUNCTION public._general_inquiry_open_limit() TO authenticated, service_role;

COMMENT ON FUNCTION public._general_inquiry_open_limit() IS
  '[508] 회원이 동시에 열어 둘 수 있는 서비스 문의 수(R2-2). 발신 함수와 뷰 general_inquiry_thread_summary 가 함께 부른다 — 숫자를 바꿀 곳은 여기 하나.';


-- ------------------------------------------------------------
-- ② 발신 — 4인자 판을 지우고 6인자로
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.send_general_inquiry_message(text, jsonb, uuid, uuid);

CREATE OR REPLACE FUNCTION public.send_general_inquiry_message(
  p_body          text,
  p_attachments   jsonb DEFAULT '[]'::jsonb,
  p_influencer_id uuid  DEFAULT NULL,
  p_thread_id     uuid  DEFAULT NULL,
  p_title         text  DEFAULT NULL,
  p_client_token  uuid  DEFAULT NULL
) RETURNS TABLE (message_id uuid, thread_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_staff       boolean;
  v_sender_kind text;
  v_sender_name text;
  v_target      uuid;      -- 대화의 주인 회원
  v_thread      uuid;
  v_status      text;
  v_closed_at   timestamptz;
  v_owner       uuid;
  v_title       text;
  v_open_count  integer;
  v_att         jsonb;
  v_prefix      text;
  v_msg_id      uuid;
  v_rate_count  bigint;
BEGIN
  -- 호출자 판정(대화 주인 확인은 아래 갈래에서 — 거부 코드를 갈래마다 정확히 내기 위해)
  SELECT c.is_staff, c.target_id INTO v_staff, v_target
    FROM public._general_inquiry_resolve_caller(p_influencer_id, p_thread_id, false) c;

  IF v_staff THEN
    v_sender_kind := 'admin';
    SELECT a.name INTO v_sender_name FROM public.admins a WHERE a.auth_id = auth.uid();
  ELSE
    v_sender_kind := 'influencer';
    SELECT i.name INTO v_sender_name FROM public.influencers i WHERE i.id = auth.uid();
    IF NOT FOUND THEN
      RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- 첨부는 배열이어야 한다
  v_att := COALESCE(p_attachments, '[]'::jsonb);
  IF jsonb_typeof(v_att) <> 'array' THEN
    RAISE EXCEPTION '添付ファイルの形式が正しくありません' USING ERRCODE = 'P0001';
  END IF;

  -- 본문/첨부 빈값 검증 (478 과 같은 문구)
  IF (p_body IS NULL OR btrim(p_body) = '') AND v_att = '[]'::jsonb THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です' USING ERRCODE = 'P0001';
  END IF;

  -- 첨부 경로 서버 검사 — 478 그대로(P-3)
  v_prefix := 'general/' || v_target::text || '/';
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_att) AS e
     WHERE left(COALESCE(e ->> 'path', ''), length(v_prefix)) <> v_prefix
        OR substr(e ->> 'path', length(v_prefix) + 1) !~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$'
  ) THEN
    RAISE EXCEPTION '添付ファイルの保存先が正しくありません' USING ERRCODE = 'P0001';
  END IF;

  -- 발신 제한(323 과 같은 조회 — 응모건 발신과 합산) — 478 그대로
  SELECT count(*) INTO v_rate_count
    FROM public.application_messages
   WHERE sender_id = auth.uid()
     AND created_at > now() - interval '1 hour'
     AND broadcast_id IS NULL;

  IF v_rate_count >= 100 THEN
    RAISE EXCEPTION 'メッセージの送信上限（1時間に100件）に達しました。しばらく経ってからお試しください'
      USING ERRCODE = 'P0001';
  END IF;

  -- 🔴 회원 단위 잠금 — 발신·닫기·다시 열기가 같은 열쇠(「열린 대화 세기 → 새로 만들기·다시 열기」 사이를 비우지 않는다)
  PERFORM pg_advisory_xact_lock(hashtext('general_inquiry_thread'), hashtext(v_target::text));

  IF NOT v_staff THEN
    SELECT count(*) INTO v_open_count
      FROM public.general_inquiry_threads t
     WHERE t.influencer_id = v_target AND t.status = 'open';

    -- 회원 ⓐ 대화 id 우선(토큰은 무시) · ⓑ 토큰으로 이미 만든 대화 — 둘 다 「그 대화」 규칙
    IF p_thread_id IS NOT NULL THEN
      v_thread := p_thread_id;
    ELSIF p_client_token IS NOT NULL THEN
      SELECT t.id INTO v_thread
        FROM public.general_inquiry_threads t
       WHERE t.influencer_id = v_target AND t.client_token = p_client_token;
    END IF;

    IF v_thread IS NOT NULL THEN
      SELECT t.influencer_id, t.status, t.closed_at INTO v_owner, v_status, v_closed_at
        FROM public.general_inquiry_threads t WHERE t.id = v_thread FOR UPDATE;
      IF v_owner IS DISTINCT FROM v_target THEN
        RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';   -- 없는 대화·남의 대화를 같은 코드로
      END IF;
      IF v_status = 'closed' THEN
        -- R2-4: 회원이 연 그 대화가 닫힌 지 24시간 안이면 다시 연다(서버가 다른 대화로 옮기지 않는다)
        IF v_closed_at <= now() - interval '24 hours' THEN
          RAISE EXCEPTION 'thread_closed' USING ERRCODE = 'P0001';
        END IF;
        -- R2-2: 회원이 다시 여는 것도 상한에 든다
        IF v_open_count >= public._general_inquiry_open_limit() THEN
          RAISE EXCEPTION 'too_many_open_threads' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.general_inquiry_threads t
           SET status = 'open', closed_at = NULL, closed_by = NULL, closed_by_name = NULL,
               reopened_count = t.reopened_count + 1
         WHERE t.id = v_thread;
      END IF;

    ELSIF p_client_token IS NOT NULL THEN
      -- 회원 ⓒ 새 문의 — 제목 필수(앞뒤 공백 뗀 1~40자) · 상한 · 첫 글과 같은 트랜잭션에서 대화를 만든다
      v_title := NULLIF(btrim(COALESCE(p_title, '')), '');
      IF v_title IS NULL THEN
        RAISE EXCEPTION 'title_required' USING ERRCODE = 'P0001';
      END IF;
      IF char_length(v_title) > 40 THEN
        RAISE EXCEPTION 'title_too_long' USING ERRCODE = 'P0001';
      END IF;
      IF v_open_count >= public._general_inquiry_open_limit() THEN
        RAISE EXCEPTION 'too_many_open_threads' USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO public.general_inquiry_threads (influencer_id, title, title_translate_status, client_token)
      VALUES (v_target, v_title, 'pending', p_client_token)
      RETURNING id INTO v_thread;

    ELSE
      -- 회원 ⓓ 옛 화면 호환(대화 id·토큰 둘 다 없음) — 후속 정리 마이그레이션에서 지운다.
      --   열린 대화 중 마지막 보이는 글이 가장 최근인 것 → 닫힌 지 24시간 안 가장 최근 대화 다시 열기 → 제목 없는 새 대화.
      --   (새로 만들거나 다시 여는 것은 열린 대화가 0개일 때뿐이라 상한에 닿지 않는다)
      SELECT t.id INTO v_thread
        FROM public.general_inquiry_threads t
        LEFT JOIN LATERAL (
          SELECT max(m.created_at) AS last_at
            FROM public.application_messages m
           WHERE m.general_thread_id = t.id
             AND m.hidden_by_admin_at IS NULL
             AND m.self_withdrawn_at  IS NULL
        ) lm ON true
       WHERE t.influencer_id = v_target AND t.status = 'open'
       ORDER BY lm.last_at DESC NULLS LAST, t.opened_at DESC, t.id DESC
       LIMIT 1;

      IF v_thread IS NULL THEN
        SELECT t.id INTO v_thread
          FROM public.general_inquiry_threads t
         WHERE t.influencer_id = v_target
           AND t.status = 'closed'
           AND t.closed_at > now() - interval '24 hours'
         ORDER BY t.closed_at DESC, t.id DESC
         LIMIT 1;

        IF v_thread IS NOT NULL THEN
          UPDATE public.general_inquiry_threads t
             SET status = 'open', closed_at = NULL, closed_by = NULL, closed_by_name = NULL,
                 reopened_count = t.reopened_count + 1
           WHERE t.id = v_thread;
        ELSE
          INSERT INTO public.general_inquiry_threads (influencer_id)
          VALUES (v_target)
          RETURNING id INTO v_thread;
        END IF;
      END IF;
    END IF;

  ELSE
    -- 운영팀: 새 대화를 만들지 못한다(R-1). 제목·토큰 인자는 무시
    IF p_thread_id IS NOT NULL THEN
      SELECT t.id, t.status INTO v_thread, v_status
        FROM public.general_inquiry_threads t
       WHERE t.id = p_thread_id AND t.influencer_id = v_target;
      IF v_thread IS NULL THEN
        RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
      END IF;
      IF v_status <> 'open' THEN
        RAISE EXCEPTION 'thread_closed' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      -- 대화 id 없음(옛 관리자 화면이 남은 몇 분) — 열린 대화가 정확히 하나일 때만
      SELECT count(*) INTO v_open_count
        FROM public.general_inquiry_threads t
       WHERE t.influencer_id = v_target AND t.status = 'open';
      IF v_open_count = 0 THEN
        RAISE EXCEPTION 'no_open_thread' USING ERRCODE = 'P0001';
      ELSIF v_open_count > 1 THEN
        RAISE EXCEPTION 'thread_required' USING ERRCODE = 'P0001';
      END IF;
      SELECT t.id INTO v_thread
        FROM public.general_inquiry_threads t
       WHERE t.influencer_id = v_target AND t.status = 'open';
    END IF;
  END IF;

  INSERT INTO public.application_messages (
    application_id, influencer_id, general_thread_id, sender_kind, sender_id, sender_name, body, attachments
  ) VALUES (
    NULL,
    v_target,
    v_thread,
    v_sender_kind,
    auth.uid(),
    COALESCE(v_sender_name, '(이름미상)'),
    COALESCE(p_body, ''),
    v_att
  )
  RETURNING id INTO v_msg_id;

  -- 운영팀 발신 시 회원 알림 — ref_id = 대화 id, 미읽음 중복 방지도 대화 단위(R-7). 제목은 알림 문구에 넣지 않는다(T-2)
  IF v_staff THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications n
       WHERE n.user_id   = v_target
         AND n.kind      = 'message_received'
         AND n.ref_table = 'general_inquiry'
         AND n.ref_id    = v_thread
         AND n.read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_target,
        'message_received',
        'general_inquiry',
        v_thread,
        'お問い合わせに運営から返信が届きました',
        COALESCE(v_sender_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;
  END IF;

  message_id := v_msg_id;
  thread_id  := v_thread;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid, text, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid, text, uuid) IS
  '[478][505][508] 서비스 문의 발송. 반환 (message_id, thread_id). 회원: 대화 id → 그 대화(24시간 안 닫힘이면 다시 열기·상한, 지났으면 thread_closed) / '
  '토큰 → 같은 토큰 대화(같은 규칙) 또는 새 대화(제목 필수 title_required·title_too_long, 상한 too_many_open_threads) / 둘 다 없음 → 옛 화면 호환. '
  '운영팀: 대화 id(닫힘 thread_closed) 또는 열린 대화가 정확히 하나(0 no_open_thread · 2+ thread_required). 상한 = _general_inquiry_open_limit(). '
  '알림 ref_id=대화 id, 제목은 알림에 안 넣음. 회원 단위 advisory 잠금. 첨부 경로 검사·발신 제한은 478 그대로.';


-- ------------------------------------------------------------
-- ③ 다시 열기 — open_thread_exists 판정 삭제(운영팀 다시 열기는 상한 검사도 없다 — 운영팀 판단 우선)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reopen_general_inquiry_thread(
  p_thread_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_owner  uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION '権限がありません（管理者専用）' USING ERRCODE = 'P0001';
  END IF;

  SELECT t.influencer_id INTO v_owner
    FROM public.general_inquiry_threads t WHERE t.id = p_thread_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('general_inquiry_thread'), hashtext(v_owner::text));

  SELECT t.status INTO v_status
    FROM public.general_inquiry_threads t WHERE t.id = p_thread_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'open' THEN
    RETURN;   -- 이미 열림 — 멱등(횟수도 안 올린다)
  END IF;

  UPDATE public.general_inquiry_threads t
     SET status = 'open', closed_at = NULL, closed_by = NULL, closed_by_name = NULL,
         reopened_count = t.reopened_count + 1
   WHERE t.id = p_thread_id;
END;
$$;

REVOKE ALL ON FUNCTION public.reopen_general_inquiry_thread(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reopen_general_inquiry_thread(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.reopen_general_inquiry_thread(uuid) TO authenticated;

COMMENT ON FUNCTION public.reopen_general_inquiry_thread(uuid) IS
  '[505][508] 서비스 문의 닫힌 대화 다시 열기(운영팀 「다시 열기」). 관리자 전원. 다른 열린 대화가 있어도 된다(508 — open_thread_exists 삭제), 상한 검사 없음. '
  '이미 열린 대화면 아무것도 안 하고 끝(멱등). 회원 단위 advisory 잠금.';


-- ------------------------------------------------------------
-- ④ 제목 고치기 — 관리자 전원(R2-3). 개인정보·욕설이 든 제목을 지우는 수단(T-4)
--    같은 값 → 아무것도 안 바꿈 / 빈 값 → 제목·번역·번역 상태 NULL / 다른 값 → 번역 비우고 pending(웹훅의 translate-message 가 다시 번역)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_general_inquiry_thread_title(
  p_thread_id uuid,
  p_title     text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_title text;
  v_old   text;
  v_found boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION '権限がありません（管理者専用）' USING ERRCODE = 'P0001';
  END IF;

  v_title := NULLIF(btrim(COALESCE(p_title, '')), '');
  IF v_title IS NOT NULL AND char_length(v_title) > 40 THEN
    RAISE EXCEPTION 'title_too_long' USING ERRCODE = 'P0001';
  END IF;

  SELECT true, t.title INTO v_found, v_old
    FROM public.general_inquiry_threads t WHERE t.id = p_thread_id FOR UPDATE;
  IF v_found IS NULL THEN
    RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_title IS NOT DISTINCT FROM v_old THEN
    RETURN;   -- 같은 값 — 번역 상태도 건드리지 않는다
  END IF;

  UPDATE public.general_inquiry_threads t
     SET title = v_title,
         title_translated = NULL,
         title_translate_status = CASE WHEN v_title IS NULL THEN NULL ELSE 'pending' END
   WHERE t.id = p_thread_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_general_inquiry_thread_title(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_general_inquiry_thread_title(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.update_general_inquiry_thread_title(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.update_general_inquiry_thread_title(uuid, text) IS
  '[508] 서비스 문의 제목 고치기(운영팀만 — R2-3). 관리자 전원. 앞뒤 공백 뗀 1~40자(넘으면 title_too_long), 빈 값이면 제목·번역 비움. '
  '같은 값이면 아무것도 안 함. 다른 값이면 번역 칸 비우고 pending — 번역은 웹훅의 translate-message. 이력 없음.';


-- ------------------------------------------------------------
-- ⑤ 뷰 — 506 의 15칸 그대로 + 맨 끝에 넷(중간에 넣으면 CREATE OR REPLACE 가 실패한다)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.general_inquiry_thread_summary
  WITH (security_invoker = true)
AS
SELECT
  t.id            AS thread_id,
  t.influencer_id,
  t.status,
  t.opened_at,
  t.closed_at,
  COALESCE(agg.message_count, 0)::bigint        AS message_count,
  agg.last_message_at,
  lastm.sender_kind                              AS last_sender_kind,
  firstm.preview                                 AS first_message_preview,
  lastm.preview                                  AS last_message_preview,
  lastm.preview_translated                       AS last_message_preview_translated,
  lastm.translate_status                         AS last_translate_status,
  COALESCE(agg.unread_for_influencer, 0)::bigint AS unread_for_influencer,
  COALESCE(t.status = 'open' AND lastm.sender_kind = 'influencer', false) AS needs_reply,
  (SELECT count(*) FROM public.general_inquiry_threads t2
    WHERE t2.influencer_id = t.influencer_id)::bigint       AS influencer_thread_count,
  -- 508 — 맨 끝에만 덧붙인다
  t.title,
  t.title_translated,
  oc.open_count                                  AS influencer_open_thread_count,
  (oc.open_count >= public._general_inquiry_open_limit()) AS influencer_at_open_limit
FROM public.general_inquiry_threads t
LEFT JOIN LATERAL (
  SELECT count(*)         AS message_count,
         max(m.created_at) AS last_message_at,
         count(*) FILTER (
           WHERE m.sender_kind = 'admin' AND m.read_by_influencer_at IS NULL
         )                AS unread_for_influencer
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
) agg ON true
LEFT JOIN LATERAL (
  SELECT m.sender_kind,
         left(regexp_replace(btrim(m.body), '\s+', ' ', 'g'), 100)            AS preview,
         NULLIF(left(regexp_replace(btrim(COALESCE(m.body_translated, '')), '\s+', ' ', 'g'), 100), '') AS preview_translated,
         m.translate_status
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
   ORDER BY m.created_at DESC, m.id DESC
   LIMIT 1
) lastm ON true
LEFT JOIN LATERAL (
  SELECT left(regexp_replace(btrim(m.body), '\s+', ' ', 'g'), 100) AS preview
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
   ORDER BY m.created_at ASC, m.id ASC
   LIMIT 1
) firstm ON true
CROSS JOIN LATERAL (
  SELECT count(*)::bigint AS open_count
    FROM public.general_inquiry_threads t3
   WHERE t3.influencer_id = t.influencer_id AND t3.status = 'open'
) oc;

COMMENT ON VIEW public.general_inquiry_thread_summary IS
  '[506][508] 서비스 문의 대화별 요약(한 줄 = 대화 한 건). 대화 표에서 출발하는 security_invoker 뷰 — 회원은 본인 대화, 관리자는 전체. '
  '메시지에서 구하는 칸은 모두 숨김·회수 글 제외. needs_reply = 열림 + 마지막 보이는 글이 회원(P-5). 보이는 글 0건 대화도 줄이 남는다. '
  '508: 맨 끝 title · title_translated · influencer_open_thread_count(그 회원의 열린 대화 수) · influencer_at_open_limit(상한 도달 — 화면은 숫자 대신 이것). '
  '옛 뷰 general_inquiry_message_summary(481)는 그대로(후속 정리에서 삭제).';

NOTIFY pgrst, 'reload schema';

COMMIT;
