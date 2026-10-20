-- ============================================================
-- 563_cs_case_personal_purge.sql
-- CS 이력 관리 — 작업 1-6(수기 건 3년 비우기) + 4-1(탈퇴·원본 삭제 때 비우기) — 데이터베이스 부분
-- 사양서: docs/specs/2026-10-16-cs-history-management.md D-10 · 4-5 · 「구현 결과」 1-2(범위 확장)
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-6 · 4-1 (S-3)
--
-- 비우는 것(사양서 D-10·4-5): 건의 이름·이메일·문의 요약·대응 안내(둘 다 번역 포함)·수기 문의/대응 내용 +
--   그 건 메모의 본문·번역. **건과 항목·시각·진행현황은 통계로 남긴다.** 비운 시각 = `personal_purged_at`.
--   메모는 「지운 메모」로 표시(deleted_at)하고 **첨부 목록은 남긴다** — 파일은 서버 함수가 저장소에서
--   지운 **뒤에** 목록을 비운다(「지우고 → 표시」 — 364 와 같은 순서, 다음 조각). 그래서 「아직 파일이
--   남은 메모」 = 「지운 메모인데 첨부 목록이 있는 줄」이 그대로 밀린 일의 표시가 된다(큐를 따로 두지 않는다).
--
-- 언제 비우나 — 기존 함수를 **하나도 다시 정의하지 않는다**
--   ① 원본이 지워질 때(2026-10-20 사용자 결정 「함께 비움」): 응모·대화·회원이 지워지면 556 의 외래 키가
--      CS 건의 그 칸을 비운다(SET NULL). 그 갱신에 거는 BEFORE 트리거 `trg_cs_case_source_removed` 가
--      같은 순간 개인정보 칸을 비운다. → 캠페인 보관 삭제(255)·완전 삭제(257·258)·관리자 완전 삭제(031)·
--      감사용 청소(480·505)·325 등 **지우는 길이 몇 개든** 따로 고칠 필요가 없다.
--      (캠페인 칸만 비는 것은 개인정보가 아니라 해당 없음 — 캠페인 제목 스냅샷은 남는다)
--      ⚠️ 외래 키 동작만 잡는다(`pg_trigger_depth() > 1`) — 화면 함수가 연결을 푸는 편집은 비우지 않는다
--   ② 탈퇴 확정: 파기 함수(520)가 회원 이메일을 자리표시 주소(`withdrawn+…@deleted.reverbjp.invalid`)로
--      바꾸는 **그 순간**에 거는 AFTER 트리거 `trg_cs_case_purge_on_withdrawal`(influencers) — 361 이
--      재가입 차단을 담는 것과 같은 자리(520·352 무변경). 같은 트랜잭션이라 **비우기가 실패하면 탈퇴 확정도
--      되돌아간다**(327·520 의 「파기 실패 = 확정 롤백」 구조를 그대로 따른다).
--   ③ 수기 건 3년(D-10): 회원과 짝이 없는 수기 건 — 완료 후 3년(미완료는 접수 후 3년). 매일 예약 06:15.
--
-- 그 밖에
--   · 560 의 공용 줄(`_cs_case_rows`)이 비운 건에서 시작 회원 글 본문으로 요약을 대신 채우지 않게 한 줄 고친다
--     (CREATE OR REPLACE — 인자·반환 칸 같음, 베이스 560). 탈퇴 정책상 메시지 원문은 남지만(§4-7) CS 화면이
--     비운 건에서 그것을 끌어와 보이면 「비웠다」가 거짓이 된다.
--   · 이미 탈퇴 확정된 회원의 건(백필에 들어갔을 수 있다)은 이 파일 끝에서 한 번 소급해 비운다.
--   · 562 의 CS 추가(`cs_split_case`)를 다시 정의(CREATE OR REPLACE, 베이스 562)해 **탈퇴 확정 회원 또는 이미 비운 대화**에서는
--     새 건을 만들지 않게 한다('case_purged') — 안 막으면 새 건이 시작 회원 글로 요약을 채워 비운 글이 다시 보인다.
--   · ⚠️ 번역 확장(1-8)이 번역 결과를 쓸 때 `personal_purged_at IS NULL` 인 건·지우지 않은 메모에만 쓰게 할 것(이 파일 밖)
--
-- 편집기 경고: 뜸 — 무해(트리거·예약을 지우고 같은 이름으로 다시 만든다. 소급 갱신은 WHERE 가 있다)
-- 롤백: 파일 하단.
-- ============================================================

-- ── 1. 건 하나의 메모 비우기(공용) ─────────────────────────────
CREATE OR REPLACE FUNCTION public._cs_purge_case_comments(p_case_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.cs_case_comments
     SET body = '', translated = NULL, translated_lang = NULL, translate_status = NULL,
         deleted_at = COALESCE(deleted_at, now())
   WHERE case_id = p_case_id
     AND (body <> '' OR translated IS NOT NULL OR deleted_at IS NULL);
$$;

-- ── 2. 건 여럿 비우기(탈퇴·3년·소급 공용) — 비운 건수 ───────────────────
CREATE OR REPLACE FUNCTION public._cs_purge_cases(p_case_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  n integer;
  c uuid;
BEGIN
  UPDATE public.cs_cases SET
    manual_name = NULL, manual_email = NULL,
    summary_body = NULL, summary_translated = NULL, summary_translated_lang = NULL, summary_translate_status = NULL,
    response_body = NULL, response_translated = NULL, response_translated_lang = NULL, response_translate_status = NULL,
    manual_inquiry_ja = NULL, manual_inquiry_ko = NULL, manual_response_ja = NULL, manual_response_ko = NULL,
    personal_purged_at = now()
  WHERE id = ANY (p_case_ids) AND personal_purged_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  FOREACH c IN ARRAY p_case_ids LOOP
    PERFORM public._cs_purge_case_comments(c);
  END LOOP;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public._cs_purge_case_comments(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cs_purge_cases(uuid[])      FROM PUBLIC, anon, authenticated;

-- ── 3. ① 원본이 지워질 때(외래 키 SET NULL 갱신에 걸린다) ─────────────────
CREATE OR REPLACE FUNCTION public._cs_case_source_removed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 🔴 외래 키의 비우기(SET NULL)만 잡는다 — 그 갱신은 참조 무결성 트리거 안에서 돌아 깊이가 2 이상이다.
  --    화면 함수(562 수기 편집이 회원 연결을 푸는 경우 등)가 직접 바꾸는 갱신은 깊이 1 이라 걸리지 않는다.
  --    이 조건이 없으면 관리자가 수기 건의 회원 연결을 풀기만 해도 건이 통째로 비워진다(2026-10-20 리뷰).
  IF pg_trigger_depth() > 1 AND NEW.personal_purged_at IS NULL AND (
       (OLD.application_id    IS NOT NULL AND NEW.application_id    IS NULL)
    OR (OLD.general_thread_id IS NOT NULL AND NEW.general_thread_id IS NULL)
    OR (OLD.influencer_id     IS NOT NULL AND NEW.influencer_id     IS NULL)) THEN
    NEW.manual_name := NULL;  NEW.manual_email := NULL;
    NEW.summary_body := NULL; NEW.summary_translated := NULL; NEW.summary_translated_lang := NULL; NEW.summary_translate_status := NULL;
    NEW.response_body := NULL; NEW.response_translated := NULL; NEW.response_translated_lang := NULL; NEW.response_translate_status := NULL;
    NEW.manual_inquiry_ja := NULL; NEW.manual_inquiry_ko := NULL; NEW.manual_response_ja := NULL; NEW.manual_response_ko := NULL;
    NEW.personal_purged_at := now();
    PERFORM public._cs_purge_case_comments(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._cs_case_source_removed() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_cs_case_source_removed ON public.cs_cases;
CREATE TRIGGER trg_cs_case_source_removed
  BEFORE UPDATE OF application_id, general_thread_id, influencer_id ON public.cs_cases
  FOR EACH ROW EXECUTE FUNCTION public._cs_case_source_removed();

-- ── 4. ② 탈퇴 확정(520 이 이메일을 자리표시 주소로 바꾸는 순간) ──────────────
CREATE OR REPLACE FUNCTION public._cs_case_purge_on_withdrawal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 520 의 자리표시 주소와 글자 그대로 같은 꼴일 때만(다른 이메일 변경에는 반응하지 않는다)
  IF NEW.email = 'withdrawn+' || NEW.id::text || '@deleted.reverbjp.invalid'
     AND OLD.email IS DISTINCT FROM NEW.email THEN
    PERFORM public._cs_purge_cases(ARRAY(SELECT id FROM public.cs_cases WHERE influencer_id = NEW.id));
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public._cs_case_purge_on_withdrawal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_cs_case_purge_on_withdrawal ON public.influencers;
CREATE TRIGGER trg_cs_case_purge_on_withdrawal
  AFTER UPDATE OF email ON public.influencers
  FOR EACH ROW EXECUTE FUNCTION public._cs_case_purge_on_withdrawal();

-- ── 5. ③ 수기 건 3년(D-10) — 회원과 짝 없는 수기 건 · 완료 후(미완료는 접수 후) 3년 ─────
CREATE OR REPLACE FUNCTION public.purge_old_cs_manual_cases()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._cs_purge_cases(ARRAY(
    SELECT id FROM public.cs_cases
     WHERE source IN ('mail','line','other')
       AND influencer_id IS NULL
       AND personal_purged_at IS NULL
       AND COALESCE(completed_at, received_at) < now() - interval '3 years'));
END;
$$;
REVOKE ALL ON FUNCTION public.purge_old_cs_manual_cases() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_old_cs_manual_cases() TO postgres, service_role;

-- 매일 06:15(한국·일본) = 21:15 UTC — 기존 예약(18:00~21:00 UTC 15분 간격)과 겹치지 않는 자리
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'cs-manual-cases-retention-daily';
SELECT cron.schedule('cs-manual-cases-retention-daily', '15 21 * * *', 'SELECT public.purge_old_cs_manual_cases();');

-- ── 6. 560 공용 줄 — 비운 건은 시작 회원 글로 요약을 대신 채우지 않는다(CREATE OR REPLACE, 베이스 560) ─────
CREATE OR REPLACE FUNCTION public._cs_case_rows(
  p_from timestamptz, p_to timestamptz,
  p_application_id uuid DEFAULT NULL, p_thread_id uuid DEFAULT NULL,
  p_include_audit boolean DEFAULT false
)
RETURNS TABLE (
  id uuid, case_no bigint, source text, application_id uuid, general_thread_id uuid,
  influencer_id uuid, influencer_name text, influencer_email text,
  campaign_id uuid, campaign_title text, recruit_type text, thread_title text,
  manual_name text, manual_email text, manual_category text,
  category_code text, status text, received_at timestamptz, first_reply_at timestamptz,
  completed_at timestamptz, completed_by_name text,
  summary_text text, summary_translated text, summary_translated_lang text, summary_edited boolean,
  response_body text, previous_case_id uuid, previous_case_no bigint,
  time_unknown boolean, origin text, source_deleted boolean, same_conversation_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    k.id, k.case_no, k.source, k.application_id, k.general_thread_id,
    k.influencer_id, i.name, i.email,
    k.campaign_id, COALESCE(c.title, k.manual_campaign_name), c.recruit_type, th.title,
    k.manual_name, k.manual_email, k.manual_category,
    k.category_code, k.status, k.received_at,
    CASE
      WHEN k.time_unknown THEN NULL
      WHEN k.source IN ('mail','line','other') THEN k.first_reply_at
      ELSE (
        SELECT min(m.created_at) FROM public.application_messages m
         WHERE m.sender_kind = 'admin'
           AND m.broadcast_id IS NULL
           AND m.hidden_by_admin_at IS NULL
           AND m.self_withdrawn_at IS NULL
           AND m.created_at > k.received_at
           AND CASE WHEN k.application_id IS NOT NULL THEN m.application_id = k.application_id
                    ELSE m.general_thread_id = k.general_thread_id END)
    END,
    k.completed_at, k.completed_by_name,
    -- [563] 비운 건(personal_purged_at)은 시작 회원 글로 대신 채우지 않는다
    CASE WHEN k.personal_purged_at IS NOT NULL THEN NULL ELSE COALESCE(k.summary_body, sm.body) END,
    CASE WHEN k.personal_purged_at IS NOT NULL THEN NULL
         WHEN k.summary_body IS NOT NULL THEN k.summary_translated
         WHEN sm.translate_status = 'done' THEN sm.body_translated END,
    CASE WHEN k.personal_purged_at IS NOT NULL THEN NULL
         WHEN k.summary_body IS NOT NULL THEN k.summary_translated_lang
         WHEN sm.translate_status = 'done' THEN sm.translated_lang END,
    k.summary_edited,
    k.response_body, k.previous_case_id, pk.case_no,
    k.time_unknown, k.origin,
    (k.source IN ('campaign_inquiry','service_inquiry') AND k.application_id IS NULL AND k.general_thread_id IS NULL),
    CASE WHEN k.application_id IS NULL AND k.general_thread_id IS NULL THEN 1
         WHEN k.application_id IS NOT NULL THEN
              (SELECT count(*) FROM public.cs_cases s WHERE s.application_id = k.application_id)
         ELSE (SELECT count(*) FROM public.cs_cases s WHERE s.general_thread_id = k.general_thread_id) END
  FROM public.cs_cases k
  LEFT JOIN public.influencers             i  ON i.id  = k.influencer_id
  LEFT JOIN public.campaigns               c  ON c.id  = k.campaign_id
  LEFT JOIN public.general_inquiry_threads th ON th.id = k.general_thread_id
  LEFT JOIN public.application_messages    sm ON sm.id = k.summary_message_id
  LEFT JOIN public.cs_cases                pk ON pk.id = k.previous_case_id
  WHERE (p_from IS NULL OR k.received_at >= p_from)
    AND (p_to   IS NULL OR k.received_at <  p_to)
    AND (p_application_id IS NULL OR k.application_id    = p_application_id)
    AND (p_thread_id      IS NULL OR k.general_thread_id = p_thread_id)
    AND (p_include_audit OR COALESCE(i.is_audit, false) = false);
$$;

-- ── 6-b. CS 추가 가드(562 cs_split_case 다시 정의 — 인자·반환 같음, 권한 보존) ─────────────
CREATE OR REPLACE FUNCTION public.cs_split_case(
  p_message_ids   uuid[],
  p_category_code text DEFAULT NULL,
  p_first_comment text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET lock_timeout = '5s'
AS $$
DECLARE
  a        record;
  v_app    uuid;
  v_thr    uuid;
  v_conv_n integer;
  v_first  record;
  v_new    uuid;
  v_infl   uuid;
  v_camp   uuid;
  v_title  text;
  v_cnt    integer;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  IF p_message_ids IS NULL OR cardinality(p_message_ids) = 0 THEN
    RAISE EXCEPTION 'messages_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM public._cs_check_category(p_category_code);
  IF char_length(COALESCE(btrim(p_first_comment), '')) > 5000 THEN RAISE EXCEPTION 'comment_too_long' USING ERRCODE = 'P0001'; END IF;

  -- 고른 글이 전부 「같은 대화의 보이는 회원 글」인지
  SELECT count(DISTINCT COALESCE(m.application_id::text, 't' || m.general_thread_id::text)),
         min(m.application_id::text)::uuid, min(m.general_thread_id::text)::uuid, count(*)
    INTO v_conv_n, v_app, v_thr, v_cnt
    FROM public.application_messages m
   WHERE m.id = ANY (p_message_ids)
     AND m.sender_kind = 'influencer'
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at IS NULL
     AND (m.application_id IS NOT NULL OR m.general_thread_id IS NOT NULL);
  IF v_cnt <> cardinality(ARRAY(SELECT DISTINCT unnest(p_message_ids))) OR v_conv_n <> 1 THEN
    RAISE EXCEPTION 'invalid_messages' USING ERRCODE = 'P0001';
  END IF;

  -- 🔴 대화 잠금 먼저(558 트리거와 같은 열쇠·순서)
  PERFORM pg_advisory_xact_lock(hashtext('cs_case_conv:' || COALESCE(v_app, v_thr)::text));

  -- 다른 건의 시작 글이면 거부
  IF EXISTS (SELECT 1 FROM public.cs_cases k WHERE k.summary_message_id = ANY (p_message_ids)) THEN
    RAISE EXCEPTION 'contains_case_start' USING ERRCODE = 'P0001';
  END IF;

  SELECT m.id, m.created_at INTO v_first
    FROM public.application_messages m WHERE m.id = ANY (p_message_ids)
   ORDER BY m.created_at, m.id LIMIT 1;

  IF v_app IS NOT NULL THEN
    SELECT i.id, ap.campaign_id, c.title INTO v_infl, v_camp, v_title
      FROM public.applications ap
      LEFT JOIN public.influencers i ON i.id = ap.user_id
      LEFT JOIN public.campaigns   c ON c.id = ap.campaign_id
     WHERE ap.id = v_app;
  ELSE
    SELECT t.influencer_id INTO v_infl FROM public.general_inquiry_threads t WHERE t.id = v_thr;
  END IF;

  -- [563] 탈퇴 확정 회원이거나 이 대화의 건이 이미 비워졌으면 새 건을 만들지 않는다
  IF EXISTS (SELECT 1 FROM public.influencers i
              WHERE i.id = v_infl
                AND i.email = 'withdrawn+' || i.id::text || '@deleted.reverbjp.invalid')
     OR EXISTS (SELECT 1 FROM public.cs_cases k
                 WHERE k.personal_purged_at IS NOT NULL
                   AND ((v_app IS NOT NULL AND k.application_id    = v_app)
                     OR (v_thr IS NOT NULL AND k.general_thread_id = v_thr))) THEN
    RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.cs_cases (
    source, application_id, general_thread_id, influencer_id, campaign_id, manual_campaign_name,
    category_code, status, received_at, summary_message_id, origin, created_by
  ) VALUES (
    CASE WHEN v_app IS NOT NULL THEN 'campaign_inquiry' ELSE 'service_inquiry' END,
    v_app, v_thr, v_infl, v_camp, left(v_title, 500),
    p_category_code, 'in_progress', v_first.created_at, v_first.id, 'live', a.actor_id
  ) RETURNING id INTO v_new;

  INSERT INTO public.cs_case_messages (message_id, case_id)
  SELECT DISTINCT unnest(p_message_ids), v_new
  ON CONFLICT (message_id) DO UPDATE SET case_id = EXCLUDED.case_id, linked_at = now();

  IF NULLIF(btrim(p_first_comment), '') IS NOT NULL THEN
    INSERT INTO public.cs_case_comments (case_id, author_id, author_name, body, translate_status)
    VALUES (v_new, a.actor_id, a.actor_name, btrim(p_first_comment), 'pending');
  END IF;

  RETURN v_new;
END;
$$;

-- ── 7. 소급 — 이미 탈퇴 확정된 회원의 건(백필에 들어갔을 수 있다) ───────────────
-- 판정은 트리거와 같은 기준(이메일이 520 의 자리표시 주소 = 파기를 실제로 마친 회원)
SELECT public._cs_purge_cases(ARRAY(
  SELECT k.id FROM public.cs_cases k
    JOIN public.influencers i ON i.id = k.influencer_id
   WHERE k.personal_purged_at IS NULL
     AND i.email = 'withdrawn+' || i.id::text || '@deleted.reverbjp.invalid')) AS backfill_withdrawn_purged;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버 — 각 항목 begin … rollback)
-- ============================================================
/*
-- [V1] 트리거 둘·예약 하나
SELECT tgname, tgrelid::regclass FROM pg_trigger WHERE tgname IN ('trg_cs_case_source_removed','trg_cs_case_purge_on_withdrawal');
SELECT jobname, schedule FROM cron.job WHERE jobname = 'cs-manual-cases-retention-daily';
-- [V2] 원본 삭제: 건이 붙은 응모 하나를 DELETE → 그 건 personal_purged_at 이 채워지고 요약·안내가 비고 메모가 「지운 메모」 → rollback
-- [V3] 탈퇴: 건이 있는 회원의 email 을 'withdrawn+<id>@deleted.reverbjp.invalid' 로 UPDATE → 그 회원 건 비워짐 → rollback
-- [V4] 3년: 시험 수기 건의 received_at 을 4년 전으로 넣고 purge_old_cs_manual_cases() → 1 → rollback
-- [V5] get_cs_cases 에서 비운 건의 summary_text 가 NULL(시작 글로 안 채움)
*/

-- ============================================================
-- 롤백
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(트리거·예약·함수 삭제). 이미 비운 칸은 되돌릴 수 없다
-- SELECT cron.unschedule('cs-manual-cases-retention-daily');
-- DROP TRIGGER IF EXISTS trg_cs_case_purge_on_withdrawal ON public.influencers;
-- DROP TRIGGER IF EXISTS trg_cs_case_source_removed ON public.cs_cases;
-- DROP FUNCTION IF EXISTS public.purge_old_cs_manual_cases();
-- DROP FUNCTION IF EXISTS public._cs_case_purge_on_withdrawal();
-- DROP FUNCTION IF EXISTS public._cs_case_source_removed();
-- DROP FUNCTION IF EXISTS public._cs_purge_cases(uuid[]);
-- DROP FUNCTION IF EXISTS public._cs_purge_case_comments(uuid);
-- -- _cs_case_rows 는 560 판을 다시 실행해 되돌린다
