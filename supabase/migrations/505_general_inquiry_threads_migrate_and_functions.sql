-- ============================================================
-- 505_general_inquiry_threads_migrate_and_functions.sql
-- 서비스 문의 「회원 한 명이 여러 대화」 — 데이터 ② 옮기기 + 함수 + 검사 제약 (한 파일·한 트랜잭션)
--
-- 사양서: docs/specs/2026-10-06-service-inquiry-threads.md 「설계 · 데이터」 마이그레이션 2 + 「코드 대조 결과」(R-1·R-2·R-6·R-7·R-9)
-- 작업표: docs/specs/2026-10-06-service-inquiry-threads-breakdown.md 조각 1
-- 선행: 504(대화 표·메시지의 대화 칸). 다음: 506(뷰)
--
-- 🔴 한 파일로 묶는 이유: 옮기기와 새 발신 함수 사이에 틈이 있으면 그 사이 옛 발신 함수가 대화 칸 없는 행을 넣는다.
--    실패하면 이 트랜잭션 전체가 되돌아간다(대화 표는 504 상태로 비어 있게 된다).
--
-- 현재 원본(함수 이름이 나오는 파일을 뽑아 정의(CREATE)인지 갈라 확인 — 484~503 재정의 없음)
--   get/send/mark_read/general_inquiry_admin_unread_counts → 478(유일한 정의)   mark_general_inquiry_resolved → 478(손대지 않음)
--   purge_audit_data_all → 480(179 → 480. 251·325·398 은 주석뿐)                 옛 뷰 → 481(손대지 않음)
--
-- 하는 일
--   ① 옮기기 — 메시지에서 출발해 회원마다 대화 하나(R-9). 477 resolution_method='manual' 이고 resolved_at 뒤에 보이는 회원 글이 없으면 닫힘
--      (closed_at=resolved_at, closed_by/name=resolved_by/name), 나머지(auto_replied 포함)는 열림. 전·후 건수를 NOTICE 로 남기고 어긋나면 예외.
--   ② 함수 — DROP 후 CREATE 4개(get·send·mark_read·admin_unread_counts) + 신설 3개(close·reopen·호출자 판정 보조 _general_inquiry_resolve_caller)
--      + purge_audit_data_all 재정의(CREATE OR REPLACE — 권한 보존). 새 함수·다시 만든 함수는 실행 권한을 **두 방향 모두** 건다.
--   ③ 검사 제약 application_messages_general_thread_required — 맨 끝.
--
-- 거부 코드(RAISE EXCEPTION '<코드>' → P0001, 메시지 본문 = 코드)
--   new_message_since_view  닫기: 화면이 본 마지막 글 뒤에 (숨김·회수 아닌) 회원 글이 있다
--   open_thread_exists      다시 열기: 그 회원에게 이미 열린 대화가 있다
--   no_open_thread          운영팀 발신: 그 회원에게 열린 대화가 없다(R-1)
--   thread_closed           운영팀 발신: 지정한 대화가 닫혀 있다 / 닫기: 이미 닫혀 있다
--   thread_not_found        없는 대화 · 남의 대화 · 운영팀이 넘긴 회원 id 와 대화 주인이 다름(구별하지 않는다)
--   기존 일본어 거부(権限がありません · 会員を指定してください · ユーザーが見つかりません …)는 그대로.
--
-- 호출자 판정(사양서 단일 정의) — 보조 함수 한 곳에 둔다: ⓪p_influencer_id 가 비면 관리자는 거부 / 아니면 본인 ①본인 id 면 회원 갈래
--   ②아니고 관리자면 운영팀 갈래 ③둘 다 아니면 거부. 본인 판정이 먼저(관리자를 겸한 회원의 본인 문의가 운영팀 갈래로 새지 않게).
--   가리기(숨김·회수)도 갈래 기준(R-6). 회원 단위 잠금 pg_advisory_xact_lock(hashtext('general_inquiry_thread'), hashtext(회원 id)) 을
--   발신·닫기·다시 열기가 공통으로 먼저 잡는다. 응대 완료 표(477)는 더는 건드리지 않는다(P-1).
--
-- 호환(옛 화면이 몇 분 남는 구간) — 새 인자 p_thread_id 는 전부 기본값 비움: 조회·읽음은 회원 전체, 회원 발신은 서버가 대화를 정함,
--   운영팀 발신은 그 회원의 열린 대화(없으면 거부). 옛 관리자 화면은 안 읽은 수 모양이 달라져 안 읽음 표시가 빠진다(예상).
--
-- 편집기 경고: 뜸 — 무해(DROP FUNCTION 은 함수를 지웠다 다시 만들 뿐, DO 블록의 INSERT·UPDATE 는 옮기기, 함수 본문 안 DELETE 는 감사용 청소).
--   ⚠️ DROP 으로 실행 권한 회수가 풀리므로 이 파일이 두 방향을 다시 건다 — 적용 뒤 [V6] 로 확인.
--
-- ── 적용 전 확인 (기준값 — 적용 전에 적어 둔다) ──
--   [P1] SELECT count(*) AS msgs, count(DISTINCT influencer_id) AS members
--          FROM public.application_messages WHERE application_id IS NULL;
--   [P2] SELECT resolution_method, count(*) FROM public.general_inquiry_resolutions GROUP BY 1;
--   [P3] 504 가 적용됐고 대화 표가 비어 있나:  SELECT count(*) FROM public.general_inquiry_threads;   기대: 0
--
-- ── 적용 뒤 검증 조회 (1단계씩 — 앞이 틀리면 멈추고 보고) ──
--   [V1] 옮기기 건수(NOTICE 와 같아야 한다):
--     SELECT (SELECT count(*) FROM public.application_messages WHERE application_id IS NULL)                      AS msgs,
--            (SELECT count(*) FROM public.application_messages WHERE application_id IS NULL AND general_thread_id IS NOT NULL) AS with_thread,
--            (SELECT count(*) FROM public.general_inquiry_threads)                                                AS threads,
--            (SELECT count(DISTINCT influencer_id) FROM public.application_messages WHERE application_id IS NULL)  AS members;
--     기대: msgs = with_thread = [P1] msgs, threads = members = [P1] members
--   [V2] 옮긴 상태(경우의 수 #5):
--     SELECT t.status, count(*) FROM public.general_inquiry_threads t GROUP BY 1;
--     SELECT t.influencer_id, t.status, t.opened_at, t.closed_at, r.resolution_method, r.resolved_at
--       FROM public.general_inquiry_threads t LEFT JOIN public.general_inquiry_resolutions r USING (influencer_id);
--   [V3] 검사 제약·유일 색인 동작(서비스 키 가능):
--     SELECT conname, convalidated FROM pg_constraint WHERE conname='application_messages_general_thread_required';   기대: 1행, t
--   [V4] 함수 모양:
--     SELECT p.proname, pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid)
--       FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN
--       ('send_general_inquiry_message','get_general_inquiry_messages','mark_general_inquiry_messages_read',
--        'general_inquiry_admin_unread_counts','close_general_inquiry_thread','reopen_general_inquiry_thread',
--        '_general_inquiry_resolve_caller') ORDER BY 1;
--     기대: 7행, 옛 시그니처(인자 적은 판) 없음. send = TABLE(message_id uuid, thread_id uuid), admin_unread_counts = TABLE(thread_id, influencer_id, unread_count bigint)
--   [V5] 번역 저장이 안 막히는지(옮긴 행에 대화 칸이 다 찼나): SELECT count(*) FROM public.application_messages WHERE application_id IS NULL AND general_thread_id IS NULL;   기대: 0
--   [V6] 🔴 실행 권한 — 일곱 함수 모두 맨 앞 =X/ 없음(PUBLIC 회수), anon 없음:
--     SELECT p.proname, p.proacl::text FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN
--       ('send_general_inquiry_message','get_general_inquiry_messages','mark_general_inquiry_messages_read',
--        'general_inquiry_admin_unread_counts','close_general_inquiry_thread','reopen_general_inquiry_thread',
--        '_general_inquiry_resolve_caller','mark_general_inquiry_resolved','purge_audit_data_all') ORDER BY 1;
--     기대: _general_inquiry_resolve_caller = postgres·service_role 만(authenticated·anon 없음), 나머지는 authenticated=X 있고 anon 없음
--   [V7] 🔴 로그인 브라우저 콘솔(서비스 키로는 호출자 분기가 안 돈다): 회원 로그인 후
--        await db.rpc('send_general_inquiry_message',{p_body:'テスト',p_attachments:[],p_influencer_id:<본인 id>})  → [{message_id, thread_id}]
--        await db.rpc('get_general_inquiry_messages',{p_influencer_id:<본인 id>})  /  관리자 로그인 후 close·reopen·admin_unread_counts
--
-- ── 되돌리는 방법 ──
--   supabase/patches/2026-10-06-general-inquiry-threads-rollback.sql 의 [C] 절(506 → 505 → 504 순서). 505 가 도중에 실패하면 자동으로 전부 되돌아간다.
-- ============================================================

BEGIN;

-- ============================================================
-- ① 옮기기 — 메시지에서 출발, 회원마다 대화 하나
-- ============================================================
DO $mig$
DECLARE
  v_msgs_before     bigint;
  v_members_before  bigint;
  v_unfilled        bigint;
  v_threads_before  bigint;
  v_threads_after   bigint;
  v_msgs_after      bigint;
  v_filled_after    bigint;
  v_closed          bigint;
  v_open            bigint;
BEGIN
  SELECT count(*), count(DISTINCT influencer_id) INTO v_msgs_before, v_members_before
    FROM public.application_messages WHERE application_id IS NULL;
  SELECT count(*) INTO v_unfilled
    FROM public.application_messages WHERE application_id IS NULL AND general_thread_id IS NULL;
  SELECT count(*) INTO v_threads_before FROM public.general_inquiry_threads;

  RAISE NOTICE '[505 옮기기 전] 서비스 문의 메시지 % 건 · 회원 % 명 · 대화 채워지지 않은 메시지 % 건 · 기존 대화 % 건',
    v_msgs_before, v_members_before, v_unfilled, v_threads_before;

  IF v_unfilled > 0 THEN
    -- 재실행으로 대화가 둘 이상 생기는 것을 막는다(504 직후 대화 표는 비어 있어야 한다)
    IF v_threads_before > 0 THEN
      RAISE EXCEPTION '[505] 대화 표가 비어 있지 않은데 대화 칸이 빈 서비스 문의 메시지가 있습니다(%). 수동 확인이 필요합니다', v_unfilled;
    END IF;

    -- 회원마다 대화 하나. 닫힘 = 마지막 응대 완료가 수동(manual)이고 그 뒤 보이는 회원 글이 없음(숨김·회수 글은 세지 않는다 — 옛 뷰 481 과 같은 기준)
    INSERT INTO public.general_inquiry_threads
      (influencer_id, status, opened_at, closed_at, closed_by, closed_by_name)
    SELECT
      mm.influencer_id,
      CASE WHEN r.resolution_method = 'manual'
            AND (mm.last_member_at IS NULL OR mm.last_member_at <= r.resolved_at)
           THEN 'closed' ELSE 'open' END,
      mm.first_at,
      CASE WHEN r.resolution_method = 'manual'
            AND (mm.last_member_at IS NULL OR mm.last_member_at <= r.resolved_at)
           THEN r.resolved_at END,
      CASE WHEN r.resolution_method = 'manual'
            AND (mm.last_member_at IS NULL OR mm.last_member_at <= r.resolved_at)
           THEN r.resolved_by END,
      CASE WHEN r.resolution_method = 'manual'
            AND (mm.last_member_at IS NULL OR mm.last_member_at <= r.resolved_at)
           THEN r.resolved_by_name END
    FROM (
      SELECT m.influencer_id,
             min(m.created_at) AS first_at,
             max(m.created_at) FILTER (
               WHERE m.sender_kind = 'influencer'
                 AND m.hidden_by_admin_at IS NULL
                 AND m.self_withdrawn_at IS NULL) AS last_member_at
        FROM public.application_messages m
       WHERE m.application_id IS NULL
         AND m.general_thread_id IS NULL
       GROUP BY m.influencer_id
    ) mm
    LEFT JOIN public.general_inquiry_resolutions r ON r.influencer_id = mm.influencer_id;

    UPDATE public.application_messages m
       SET general_thread_id = t.id
      FROM public.general_inquiry_threads t
     WHERE m.application_id IS NULL
       AND m.general_thread_id IS NULL
       AND t.influencer_id = m.influencer_id;
  END IF;

  SELECT count(*) INTO v_msgs_after
    FROM public.application_messages WHERE application_id IS NULL;
  SELECT count(*) INTO v_filled_after
    FROM public.application_messages WHERE application_id IS NULL AND general_thread_id IS NOT NULL;
  SELECT count(*), count(*) FILTER (WHERE status = 'closed'), count(*) FILTER (WHERE status = 'open')
    INTO v_threads_after, v_closed, v_open
    FROM public.general_inquiry_threads;

  RAISE NOTICE '[505 옮기기 후] 서비스 문의 메시지 % 건 · 대화 칸이 채워진 메시지 % 건 · 대화 % 건(열림 % · 닫힘 %)',
    v_msgs_after, v_filled_after, v_threads_after, v_open, v_closed;

  -- 일반 문의 메시지 수 = 대화 칸이 채워진 수, 전·후 메시지 수 같음, 대화 수 = 회원 수
  IF v_msgs_after <> v_msgs_before
     OR v_filled_after <> v_msgs_after
     OR v_threads_after <> v_members_before THEN
    RAISE EXCEPTION '[505] 옮기기 건수 불일치 — 메시지 전 % / 후 % / 채워짐 % / 대화 % / 회원 %',
      v_msgs_before, v_msgs_after, v_filled_after, v_threads_after, v_members_before;
  END IF;
END
$mig$;

-- ============================================================
-- ② 함수 — 먼저 옛 시그니처를 지운다(인자·반환이 바뀌므로 CREATE OR REPLACE 불가. 남기면 호출이 모호해진다)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_general_inquiry_messages(uuid);
DROP FUNCTION IF EXISTS public.send_general_inquiry_message(text, jsonb, uuid);
DROP FUNCTION IF EXISTS public.mark_general_inquiry_messages_read(uuid);
DROP FUNCTION IF EXISTS public.general_inquiry_admin_unread_counts(uuid);

-- ------------------------------------------------------------
-- 보조: 호출자 판정 한 곳 — 조회·읽음·발신이 모두 이것을 쓴다
--   반환 is_staff=true 면 운영팀 갈래(관리자가 p_influencer_id 회원을 대신 다룸), false 면 회원 갈래(호출자 본인).
--   p_check_thread=true 이고 p_thread_id 가 있으면 그 대화의 주인이 target 인지 확인(아니면 thread_not_found).
--   🔴 SECURITY DEFINER + 실행 권한을 아무에게도 안 준다(postgres·service_role 만) — 부르는 함수들이 정의자 권한이라 안쪽 호출은 산다.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._general_inquiry_resolve_caller(
  p_influencer_id uuid,
  p_thread_id     uuid,
  p_check_thread  boolean
) RETURNS TABLE (is_staff boolean, target_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_admin boolean;
  v_owner uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
  END IF;

  v_admin := public.is_admin();

  IF p_influencer_id IS NULL THEN
    -- ⓪ 비어 있으면: 관리자는 대상 회원을 모른다 → 거부 / 아니면 본인으로 본다
    IF v_admin THEN
      RAISE EXCEPTION '会員を指定してください' USING ERRCODE = 'P0001';
    END IF;
    is_staff := false;  target_id := v_uid;
  ELSIF p_influencer_id = v_uid THEN
    -- ① 본인 판정이 먼저 — 관리자를 겸한 회원의 본인 문의는 회원 갈래
    is_staff := false;  target_id := v_uid;
  ELSIF v_admin THEN
    -- ② 운영팀 갈래
    is_staff := true;   target_id := p_influencer_id;
  ELSE
    -- ③ 남의 회원 id
    RAISE EXCEPTION '権限がありません' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = target_id) THEN
    RAISE EXCEPTION 'ユーザーが見つかりません' USING ERRCODE = 'P0001';
  END IF;

  IF p_check_thread AND p_thread_id IS NOT NULL THEN
    SELECT t.influencer_id INTO v_owner
      FROM public.general_inquiry_threads t WHERE t.id = p_thread_id;
    -- 없는 대화와 남의 대화를 같은 코드로(존재 여부를 드러내지 않는다)
    IF v_owner IS DISTINCT FROM target_id THEN
      RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public._general_inquiry_resolve_caller(uuid, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._general_inquiry_resolve_caller(uuid, uuid, boolean) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._general_inquiry_resolve_caller(uuid, uuid, boolean) TO postgres, service_role;

COMMENT ON FUNCTION public._general_inquiry_resolve_caller(uuid, uuid, boolean) IS
  '[505] 서비스 문의 함수 셋(조회·읽음·발신)의 「호출자 판정」 단일 정의. 본인 판정 먼저 → 관리자(운영팀 갈래) → 거부. '
  '실행 권한은 postgres·service_role 만(내부 전용 — 부르는 함수가 SECURITY DEFINER).';

-- ------------------------------------------------------------
-- 1. get_general_inquiry_messages — 478 베이스(17칸·마스킹 규칙 그대로) + 대화 인자 + 반환 끝에 thread_id 한 칸
--    가리기 기준은 호출자가 아니라 **갈래**(R-6): 관리자를 겸한 회원이 회원 화면에서 보면 회원 기준으로 가려진다.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_general_inquiry_messages(
  p_influencer_id uuid DEFAULT NULL,
  p_thread_id     uuid DEFAULT NULL
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
  sender_id               uuid,
  thread_id               uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_staff  boolean;
  v_target uuid;
BEGIN
  SELECT c.is_staff, c.target_id INTO v_staff, v_target
    FROM public._general_inquiry_resolve_caller(p_influencer_id, p_thread_id, true) c;

  RETURN QUERY
  SELECT
    m.id,
    m.application_id,
    m.sender_kind,
    m.sender_name,
    -- body 마스킹 분기 (326 과 동일)
    CASE
      WHEN v_staff THEN
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
      WHEN v_staff THEN
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
      WHEN v_staff THEN
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
      WHEN v_staff THEN
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
      WHEN v_staff THEN
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
      WHEN v_staff THEN
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
      WHEN v_staff THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.sender_id
        END
      ELSE NULL
    END AS sender_id,
    m.general_thread_id AS thread_id
  FROM public.application_messages m
  WHERE m.application_id IS NULL
    AND m.influencer_id = v_target
    AND (p_thread_id IS NULL OR m.general_thread_id = p_thread_id)
  ORDER BY m.created_at ASC, m.id ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_general_inquiry_messages(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_general_inquiry_messages(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_general_inquiry_messages(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_general_inquiry_messages(uuid, uuid) IS
  '[478][505] 서비스 문의 메시지 조회. 반환 17칸·마스킹은 478(=326 짝) 그대로 + 끝에 thread_id. 「호출자 판정」은 _general_inquiry_resolve_caller. '
  '대화 인자를 주면 그 대화만(주인 확인), 비면 회원 전체(옛 화면 호환 — 새 화면은 대화 없는 주소에서 부르지 않는다, R-2). '
  '가리기 기준은 호출자가 아니라 갈래(R-6). SECURITY DEFINER + search_path 고정.';


-- ------------------------------------------------------------
-- 2. send_general_inquiry_message — 478 베이스. 반환 TABLE(message_id, thread_id)
--    회원: 대화 인자를 **확인 없이 무시**하고 서버가 정한다(열린 대화 → 닫힌 지 24시간 안이면 다시 열기 → 새 대화).
--    운영팀: p_thread_id 로 지정(비면 그 회원의 열린 대화). 열린 대화가 없으면 거부(R-1), 닫힌 대화는 거부.
--    응대 완료 표(477)는 더는 건드리지 않는다(P-1). 첨부 경로 검사·발신 제한 계량은 478 그대로(P-3).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_general_inquiry_message(
  p_body          text,
  p_attachments   jsonb DEFAULT '[]'::jsonb,
  p_influencer_id uuid  DEFAULT NULL,
  p_thread_id     uuid  DEFAULT NULL
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
  v_att         jsonb;
  v_prefix      text;
  v_msg_id      uuid;
  v_rate_count  bigint;
BEGIN
  -- 호출자 판정(대화 인자는 여기서 확인하지 않는다 — 회원 갈래는 무시, 운영팀 갈래는 아래에서 확인)
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

  -- 첨부 경로 서버 검사 — 478 그대로(P-3: 대화 조각 없음)
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

  -- 🔴 회원 단위 잠금 — 발신·닫기·다시 열기가 같은 열쇠를 먼저 잡는다(「열린 대화 찾기 → 새로 만들기」 사이를 비우지 않는다)
  PERFORM pg_advisory_xact_lock(hashtext('general_inquiry_thread'), hashtext(v_target::text));

  IF NOT v_staff THEN
    -- 회원: 열린 대화 → (없으면) 가장 최근에 닫힌 지 24시간 안인 대화를 다시 열기 → (없으면) 새 대화
    SELECT t.id INTO v_thread
      FROM public.general_inquiry_threads t
     WHERE t.influencer_id = v_target AND t.status = 'open';

    IF v_thread IS NULL THEN
      SELECT t.id INTO v_thread
        FROM public.general_inquiry_threads t
       WHERE t.influencer_id = v_target
         AND t.status = 'closed'
         AND t.closed_at > now() - interval '24 hours'
       ORDER BY t.closed_at DESC
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
  ELSE
    -- 운영팀: 지정한 대화(주인 확인) 또는 그 회원의 열린 대화. 새 대화를 운영팀이 만들지는 못한다(R-1)
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
      SELECT t.id INTO v_thread
        FROM public.general_inquiry_threads t
       WHERE t.influencer_id = v_target AND t.status = 'open';
      IF v_thread IS NULL THEN
        RAISE EXCEPTION 'no_open_thread' USING ERRCODE = 'P0001';
      END IF;
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

  -- 운영팀 발신 시 회원 알림 — ref_id = 대화 id, 미읽음 중복 방지도 대화 단위(R-7)
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

REVOKE ALL ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.send_general_inquiry_message(text, jsonb, uuid, uuid) IS
  '[478][505] 서비스 문의 발송. 반환 (message_id, thread_id). 회원 갈래: 대화 인자 무시, 열린 대화 → 닫힌 지 24시간 안이면 다시 열기 → 새 대화. '
  '운영팀 갈래: 지정 대화(주인 확인) 또는 열린 대화, 없으면 no_open_thread, 닫힌 대화는 thread_closed(R-1). '
  '응대 완료 표(477)는 안 건드림(P-1). 알림 ref_id=대화 id. 회원 단위 advisory 잠금. 첨부 경로 검사·발신 제한은 478 그대로. 거부 코드는 파일 머리말.';


-- ------------------------------------------------------------
-- 3. mark_general_inquiry_messages_read — 478 베이스 + 대화 인자(주인 확인). 대화가 비면 회원 전체(옛 동작)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_general_inquiry_messages_read(
  p_influencer_id uuid DEFAULT NULL,
  p_thread_id     uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_staff  boolean;
  v_target uuid;
BEGIN
  SELECT c.is_staff, c.target_id INTO v_staff, v_target
    FROM public._general_inquiry_resolve_caller(p_influencer_id, p_thread_id, true) c;

  IF v_staff THEN
    -- 운영팀: 본인이 안 읽은 회원 메시지를 admin_reads 에 upsert (478 과 같은 조건 + 대화 한정)
    INSERT INTO public.application_message_admin_reads (message_id, admin_auth_id, read_at)
    SELECT m.id, auth.uid(), now()
      FROM public.application_messages m
     WHERE m.application_id IS NULL
       AND m.influencer_id = v_target
       AND (p_thread_id IS NULL OR m.general_thread_id = p_thread_id)
       AND m.sender_kind = 'influencer'
       AND m.hidden_by_admin_at IS NULL
    ON CONFLICT (message_id, admin_auth_id) DO NOTHING;
  ELSE
    -- 회원: 본인 대화의 운영팀 메시지를 읽음 처리 (478 과 같은 조건 + 대화 한정)
    UPDATE public.application_messages m
       SET read_by_influencer_at = now()
     WHERE m.application_id IS NULL
       AND m.influencer_id = v_target
       AND (p_thread_id IS NULL OR m.general_thread_id = p_thread_id)
       AND m.sender_kind = 'admin'
       AND m.read_by_influencer_at IS NULL
       AND m.hidden_by_admin_at IS NULL;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_general_inquiry_messages_read(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_general_inquiry_messages_read(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_general_inquiry_messages_read(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_general_inquiry_messages_read(uuid, uuid) IS
  '[478][505] 서비스 문의 읽음 처리. 호출자 판정은 _general_inquiry_resolve_caller. 대화 인자를 주면 그 대화만(주인 확인), 비면 회원 전체(옛 화면 호환 — 새 화면은 대화 없는 주소에서 부르지 않는다, R-2). '
  '운영팀 갈래: admin_reads upsert / 회원 갈래: read_by_influencer_at 갱신. SECURITY DEFINER + search_path 고정.';


-- ------------------------------------------------------------
-- 4. close_general_inquiry_thread — 신설. 관리자 전원, 열린 대화만
--    화면이 본 마지막 글(숨김·회수 뺀 기준) 뒤에 보이는 회원 글이 있으면 거부(new_message_since_view).
--    p_seen_last_message_id 가 비면: 보이는 회원 글이 하나라도 있으면 거부.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_general_inquiry_thread(
  p_thread_id            uuid,
  p_seen_last_message_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_owner    uuid;
  v_status   text;
  v_seen_at  timestamptz;
  v_name     text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION '権限がありません（管理者専用）' USING ERRCODE = 'P0001';
  END IF;

  SELECT t.influencer_id INTO v_owner
    FROM public.general_inquiry_threads t WHERE t.id = p_thread_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- 회원 단위 잠금 — 같은 회원의 발신·다시 열기와 순서를 세운다(경우의 수 #4)
  PERFORM pg_advisory_xact_lock(hashtext('general_inquiry_thread'), hashtext(v_owner::text));

  SELECT t.status INTO v_status
    FROM public.general_inquiry_threads t WHERE t.id = p_thread_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'thread_closed' USING ERRCODE = 'P0001';
  END IF;

  -- 화면이 본 뒤에 도착한 회원 글(숨김·회수 제외 — 뷰와 같은 기준)이 있으면 거부
  IF p_seen_last_message_id IS NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.application_messages m
       WHERE m.general_thread_id = p_thread_id
         AND m.sender_kind = 'influencer'
         AND m.hidden_by_admin_at IS NULL
         AND m.self_withdrawn_at IS NULL
    ) THEN
      RAISE EXCEPTION 'new_message_since_view' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT m.created_at INTO v_seen_at
      FROM public.application_messages m
     WHERE m.id = p_seen_last_message_id AND m.general_thread_id = p_thread_id;
    IF v_seen_at IS NULL THEN
      -- 이 대화에 없는 글을 기준으로 넘김 — 화면 오류. 대화를 못 찾는 것과 같이 다룬다
      RAISE EXCEPTION 'thread_not_found' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.application_messages m
       WHERE m.general_thread_id = p_thread_id
         AND m.sender_kind = 'influencer'
         AND m.hidden_by_admin_at IS NULL
         AND m.self_withdrawn_at IS NULL
         AND m.created_at > v_seen_at
    ) THEN
      RAISE EXCEPTION 'new_message_since_view' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  UPDATE public.general_inquiry_threads t
     SET status = 'closed',
         closed_at = now(),
         closed_by = auth.uid(),
         closed_by_name = COALESCE(v_name, '(이름미상)')
   WHERE t.id = p_thread_id;
END;
$$;

REVOKE ALL ON FUNCTION public.close_general_inquiry_thread(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.close_general_inquiry_thread(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.close_general_inquiry_thread(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.close_general_inquiry_thread(uuid, uuid) IS
  '[505] 서비스 문의 대화 닫기(운영팀 「응대 완료」 버튼). 관리자 전원·열린 대화만. 화면이 본 마지막 글 뒤에 보이는 회원 글이 있으면 new_message_since_view. '
  '숨김·회수 글은 기준에서 뺀다. 회원 단위 advisory 잠금. 이미 닫혔으면 thread_closed. 옛 응대 완료 표(477)는 안 건드림.';


-- ------------------------------------------------------------
-- 5. reopen_general_inquiry_thread — 신설. 관리자 전원. 그 회원에게 열린 대화가 없을 때만(open_thread_exists)
--    이미 열려 있으면 아무 일도 하지 않고 끝낸다(연속 클릭 대비 — 횟수도 올리지 않는다).
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
    RETURN;   -- 이미 열림 — 멱등
  END IF;

  -- P-2: 그 회원에게 다른 열린 대화가 있으면 거부(유일 색인과 같은 규칙을 함수가 먼저 말해 준다)
  IF EXISTS (
    SELECT 1 FROM public.general_inquiry_threads t
     WHERE t.influencer_id = v_owner AND t.status = 'open'
  ) THEN
    RAISE EXCEPTION 'open_thread_exists' USING ERRCODE = 'P0001';
  END IF;

  -- 처리는 회원 글로 다시 열릴 때와 같다(닫힘 칸 비움 · 횟수 +1)
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
  '[505] 서비스 문의 닫힌 대화 다시 열기(운영팀 「다시 열기」 버튼). 관리자 전원. 그 회원에게 열린 대화가 이미 있으면 open_thread_exists. '
  '이미 열린 대화면 아무것도 안 하고 끝(멱등). 회원 단위 advisory 잠금.';


-- ------------------------------------------------------------
-- 6. general_inquiry_admin_unread_counts — 478 베이스, 반환이 **대화별**
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.general_inquiry_admin_unread_counts(
  p_admin_auth_id uuid DEFAULT NULL  -- NULL 이면 auth.uid()
) RETURNS TABLE (thread_id uuid, influencer_id uuid, unread_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '관리자 전용 함수입니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    m.general_thread_id,
    m.influencer_id,
    count(*) AS unread_count
  FROM public.application_messages m
  LEFT JOIN public.application_message_admin_reads r
    ON r.message_id = m.id
   AND r.admin_auth_id = COALESCE(p_admin_auth_id, auth.uid())
  WHERE m.application_id IS NULL
    AND m.general_thread_id IS NOT NULL
    AND m.influencer_id IS NOT NULL
    AND m.sender_kind = 'influencer'
    AND m.hidden_by_admin_at IS NULL
    AND m.self_withdrawn_at IS NULL   -- 회원 본인 회수 메시지는 집계 제외 (478 과 같은 조건)
    AND r.message_id IS NULL          -- 본인이 안 읽음
  GROUP BY m.general_thread_id, m.influencer_id;
END;
$$;

REVOKE ALL ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) TO authenticated;

COMMENT ON FUNCTION public.general_inquiry_admin_unread_counts(uuid) IS
  '[478][505] 관리자 본인 기준 **대화별** 서비스 문의 안읽음 회원 메시지 수. 반환 (thread_id, influencer_id, unread_count). '
  'is_admin() 가드 — 비관리자는 insufficient_privilege. p_admin_auth_id NULL = auth.uid(). SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 7. purge_audit_data_all — 480 베이스, 대화 표도 메시지 다음에 직접 지운다
--    인자·반환이 그대로라 CREATE OR REPLACE — 기존 실행 권한이 보존된다(권한을 다시 걸지 않는다). 477 지우는 줄은 그대로 둔다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_audit_data_all()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_audit_ids      uuid[];
  v_app_ids        uuid[];
  v_del_app_count  int;
  v_del_notif_count int;
  v_del_faq_count  int;
  v_msg_attach_paths text[];
  v_receipt_paths    text[];
  v_general_attach_paths text[];   -- [480] 일반 문의 첨부 경로
  v_del_general_msg_count int;     -- [480] 삭제한 일반 문의 메시지 수(반환 모양 불변이라 반환하지 않는다)
BEGIN
  -- super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)' USING ERRCODE = '42501';
  END IF;

  -- 감사용 계정 ID 수집
  SELECT array_agg(id) INTO v_audit_ids
    FROM public.influencers
   WHERE is_audit = true;

  IF v_audit_ids IS NULL OR cardinality(v_audit_ids) = 0 THEN
    RETURN jsonb_build_object('status', 'no_audit_account');
  END IF;

  -- 감사용 계정의 응모건 ID 수집 (Storage path 수집 + 삭제 범위 파악용)
  SELECT array_agg(id) INTO v_app_ids
    FROM public.applications
   WHERE user_id = ANY(v_audit_ids);

  -- ① Storage 파일 path 수집 (클라이언트가 후속 삭제할 수 있도록 반환)
  --    응모건 메시지 첨부 파일
  -- ⚠️ attachments는 [{path, name, size, mime}] 객체 배열(144 정의)이므로
  --    jsonb_array_elements + ->>'path'로 path만 추출 (text 추출 함수 사용 금지)
  SELECT array_agg(DISTINCT elem->>'path')
    INTO v_msg_attach_paths
  FROM public.application_messages am,
       jsonb_array_elements(
         COALESCE(am.attachments, '[]'::jsonb)
       ) AS elem
  WHERE am.application_id = ANY(v_app_ids)
    AND elem->>'path' IS NOT NULL;

  --    [480] 일반 문의(응모 없는 메시지) 첨부 파일 — 응모 삭제의 연쇄로는 안 지워지므로 여기서 따로 수집.
  --    반환 모양을 바꾸지 않으려고 기존 message_attachments 배열에 합친다(중복 제거).
  SELECT array_agg(DISTINCT elem->>'path')
    INTO v_general_attach_paths
  FROM public.application_messages am,
       jsonb_array_elements(
         COALESCE(am.attachments, '[]'::jsonb)
       ) AS elem
  WHERE am.application_id IS NULL
    AND am.influencer_id = ANY(v_audit_ids)
    AND elem->>'path' IS NOT NULL;

  IF v_general_attach_paths IS NOT NULL THEN
    SELECT array_agg(DISTINCT p)
      INTO v_msg_attach_paths
      FROM unnest(COALESCE(v_msg_attach_paths, '{}'::text[]) || v_general_attach_paths) AS p;
  END IF;

  --    영수증 이미지 (receipt_url)
  SELECT array_agg(DISTINCT d.receipt_url)
    INTO v_receipt_paths
    FROM public.deliverables d
   WHERE d.application_id = ANY(v_app_ids)
     AND d.receipt_url IS NOT NULL;

  -- ② notifications 명시적 DELETE (auth.users cascade 미적용)
  DELETE FROM public.notifications
   WHERE user_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_notif_count = ROW_COUNT;

  -- ③ faq_interactions 명시적 DELETE (influencer_id 기준, auth.users cascade 미적용)
  DELETE FROM public.faq_interactions
   WHERE influencer_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_faq_count = ROW_COUNT;

  -- [480] 일반 문의 정리 — 응모가 없어 ④ 의 연쇄 삭제에 안 걸리는 몫.
  --   ⓑ 메시지 행 삭제(admin_reads·hide_history 는 message_id 외래 키 연쇄로 함께 삭제)
  --   ⓒ 응대 완료 행 삭제(477 — influencer_id 기준. 감사용 계정은 influencers 행을 안 지우므로 명시 삭제 필요)
  DELETE FROM public.application_messages
   WHERE application_id IS NULL
     AND influencer_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_general_msg_count = ROW_COUNT;

  -- [505] 대화 표도 직접 지운다(메시지 → 대화 순). 감사용 계정은 influencers 행을 안 지워 연쇄 삭제가 없다.
  DELETE FROM public.general_inquiry_threads
   WHERE influencer_id = ANY(v_audit_ids);

  -- 477 지우는 줄은 그대로 둔다(감사용 계정의 옛 줄이 남아 있을 수 있다 — 빼는 것은 후속 정리 마이그레이션).
  DELETE FROM public.general_inquiry_resolutions
   WHERE influencer_id = ANY(v_audit_ids);

  -- ④ applications DELETE
  --    → deliverables, deliverable_events, receipt_edit_history,
  --      application_events, application_messages,
  --      application_message_admin_reads, application_message_resolutions,
  --      application_message_hide_history 모두 cascade
  DELETE FROM public.applications
   WHERE user_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_app_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',            'ok',
    'audit_account_count', cardinality(v_audit_ids),
    'deleted', jsonb_build_object(
      'applications',  v_del_app_count,
      'notifications', v_del_notif_count,
      'faq_interactions', v_del_faq_count
    ),
    'storage_paths_to_delete', jsonb_build_object(
      'message_attachments', COALESCE(to_jsonb(v_msg_attach_paths), '[]'::jsonb),
      'receipt_images',      COALESCE(to_jsonb(v_receipt_paths),    '[]'::jsonb)
    )
  );
END;
$$;

COMMENT ON FUNCTION public.purge_audit_data_all() IS
  '[179][480] 모든 감사용 계정(is_audit=true)의 응모·결과물·알림·메시지·FAQ 이력을 삭제. '
  'super_admin 전용. 반환값의 storage_paths_to_delete를 참조해 클라이언트가 Storage 파일도 삭제할 것. '
  '[480] 일반 문의(응모 없는 메시지)의 행·첨부 경로·응대 완료 행도 함께 정리(반환 모양 불변 — 첨부 경로는 message_attachments 에 합쳐짐). '
  '[505] 서비스 문의 대화 표(general_inquiry_threads)도 메시지 다음에 정리.';


-- ============================================================
-- ③ 검사 제약 — 맨 끝. 응모 칸이 빈 행(서비스 문의)은 대화 칸 필수
--    옮기기(①)에서 모든 행이 채워졌고 새 발신 함수가 항상 채우므로 NOT VALID 없이 전체 검증한다.
--    번역 저장(translate-message)은 번역 칸만 UPDATE 하므로 기존 행이 제약을 만족하는 한 통과한다.
-- ============================================================
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.application_messages'::regclass
       AND conname  = 'application_messages_general_thread_required'
  ) THEN
    ALTER TABLE public.application_messages
      ADD CONSTRAINT application_messages_general_thread_required
      CHECK (application_id IS NOT NULL OR general_thread_id IS NOT NULL);
  END IF;
END
$do$;

COMMENT ON CONSTRAINT application_messages_general_thread_required ON public.application_messages IS
  '[505] 응모 칸(application_id)이 빈 메시지 = 서비스 문의는 반드시 대화(general_thread_id)에 속한다. 475 의 owner_exactly_one 과 함께 건다.';

NOTIFY pgrst, 'reload schema';

COMMIT;
