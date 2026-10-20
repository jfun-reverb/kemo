-- ============================================================
-- 562_cs_case_write_functions.sql   (561 은 같은 날 배송 메일 점검이 먼저 씀)
-- CS 이력 관리 — 작업 1-5 (쓰기 함수)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 4-2·D-4·D-11·D-12·D-16·D-17·D-19·D-20 · 4-1(수기 등록·편집)
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-5 (S-7)
--
-- 556 의 네 표에는 쓰기 정책·권한이 없다 — 화면은 전부 이 함수들로만 쓴다.
-- 공통
--   · 권한: 메시지 메뉴 권한(`has_permission('menu.messages','read')` — D-9 「메시지를 볼 수 있으면 CS 도 보고 고친다」).
--     없으면 'forbidden'.
--   · 거부는 `RAISE EXCEPTION '<코드>'`(P0001, 메시지 = 코드) — 505·508 과 같은 꼴. 화면이 코드로 문구를 고른다.
--   · 건을 고치는 함수는 `p_version`(낙관적 잠금) — 다르면 'version_conflict'. 성공하면 새 version 을 돌려준다.
--   · 항목 코드는 `cs_category` 의 **켜진 행**이어야 하고 「미분류(과거)」는 고를 수 없다('invalid_category' — D-7).
--   · 사람이 새로 쓰거나 고친 글(대응 안내·요약·메모)은 번역 상태를 'pending' 으로 둔다 — 번역 확장(1-8)이 채운다
--     (4-4 ⑧ 「사람이 새로 쓰거나 고친 값만 자동 번역」). 1-8 전에는 'pending' 으로 남는다.
--   · 🔴 같은 대화 잠금(558 의 `hashtext('cs_case_conv:'||…)`)을 잡는 함수(CS 추가)는 **잠금을 맨 먼저** 잡는다 —
--     회원 발신 트리거와 순서를 맞춰 교착을 막는다.
--
-- 함수(S-7)
--   cs_complete_case · cs_reopen_case · cs_set_case_status · cs_split_case(CS 추가) · cs_update_case_summary
--   cs_create_manual_case · cs_update_manual_case · cs_add_comment · cs_delete_comment · cs_mark_case_comments_read
--   + 내부 _cs_actor() · _cs_check_category()
--
-- 첨부 경로 규칙: 통 `cs-case-attachments` 안 `{건 id}/{임의}.{확장자}` — cs_add_comment 가 앞부분을 검사한다.
-- 건 행 잠금은 `FOR NO KEY UPDATE` — 회원 글 연결(558 트리거의 외래 키 검사)과 부딪히지 않게(부딪히면 2초 뒤 그 글이 건에 안 붙는다).
-- 개인정보를 비운 건(personal_purged_at)에는 새 글을 쓰지 않는다('case_purged').
-- 메모 지우기는 표시만(행·첨부 목록은 남김 — 파일 정리는 1-6·4-1 의 파기 함수가 지운 메모까지 함께 본다).
--
-- 편집기 경고: 안 뜸(함수 생성·권한만)
-- 롤백: 파일 하단.
-- ============================================================

-- ── 내부 도우미 ─────────────────────────────────────────────
-- 권한 확인 + 지금 관리자(auth id·이름)
CREATE OR REPLACE FUNCTION public._cs_actor(OUT actor_id uuid, OUT actor_name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('menu.messages', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;
  actor_id := auth.uid();
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;
  SELECT a.name INTO actor_name FROM public.admins a WHERE a.auth_id = actor_id;
  actor_name := COALESCE(NULLIF(btrim(actor_name), ''), '(이름미상)');
END;
$$;

-- 항목 코드 검사(비우는 것은 허용 여부를 호출부가 정한다)
CREATE OR REPLACE FUNCTION public._cs_check_category(p_code text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_code IS NULL THEN RETURN; END IF;
  IF p_code = 'legacy_unclassified' OR NOT EXISTS (
       SELECT 1 FROM public.lookup_values
        WHERE kind = 'cs_category' AND code = p_code AND active) THEN
    RAISE EXCEPTION 'invalid_category' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._cs_actor() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cs_check_category(text) FROM PUBLIC, anon, authenticated;

-- ── 1. CS 건 완료(D-4·D-17) ──────────────────────────────────
-- 항목·대응 안내 필수. 수기 건은 완료 일시 필수(미래 금지), 앱 건은 누른 때.
CREATE OR REPLACE FUNCTION public.cs_complete_case(
  p_case_id       uuid,
  p_version       integer,
  p_category_code text,
  p_response_body text,
  p_completed_at  timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a   record;
  k   public.cs_cases%ROWTYPE;
  v_body text := NULLIF(btrim(p_response_body), '');
  v_at   timestamptz;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.personal_purged_at IS NOT NULL THEN RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001'; END IF;
  IF k.status = 'done' THEN RAISE EXCEPTION 'already_done' USING ERRCODE = 'P0001'; END IF;
  IF p_category_code IS NULL THEN RAISE EXCEPTION 'category_required' USING ERRCODE = 'P0001'; END IF;
  PERFORM public._cs_check_category(p_category_code);
  IF v_body IS NULL THEN RAISE EXCEPTION 'response_required' USING ERRCODE = 'P0001'; END IF;
  IF char_length(v_body) > 10000 THEN RAISE EXCEPTION 'response_too_long' USING ERRCODE = 'P0001'; END IF;

  IF k.source IN ('mail','line','other') THEN
    IF p_completed_at IS NULL THEN RAISE EXCEPTION 'completed_at_required' USING ERRCODE = 'P0001'; END IF;
    IF p_completed_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'completed_at_future' USING ERRCODE = 'P0001'; END IF;
    IF p_completed_at < k.received_at THEN RAISE EXCEPTION 'completed_before_received' USING ERRCODE = 'P0001'; END IF;
    v_at := p_completed_at;
  ELSE
    v_at := now();
  END IF;

  UPDATE public.cs_cases SET
    status = 'done',
    category_code = p_category_code,
    completed_at = v_at,
    completed_by = a.actor_id,
    completed_by_name = a.actor_name,
    response_body = v_body,
    -- 완료 양식에 사람이 쓴 글이라 수기 건도 자동 번역 대상(4-4 ⑧). 등록 때의 수기 대응 내용(일·한)은 원기록으로 그대로 둔다.
    -- 고친 글만 다시 번역(같은 글이면 기존 번역 유지)
    response_translated       = CASE WHEN v_body IS DISTINCT FROM k.response_body THEN NULL      ELSE k.response_translated END,
    response_translated_lang  = CASE WHEN v_body IS DISTINCT FROM k.response_body THEN NULL      ELSE k.response_translated_lang END,
    response_translate_status = CASE WHEN v_body IS DISTINCT FROM k.response_body THEN 'pending' ELSE k.response_translate_status END,
    version = k.version + 1
  WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;

-- ── 2. 다시 열기(완료 → 진행중, 완료 칸 지움 — 4-2) ─────────────────
CREATE OR REPLACE FUNCTION public.cs_reopen_case(p_case_id uuid, p_version integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a record;
  k public.cs_cases%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.status <> 'done' THEN RAISE EXCEPTION 'not_done' USING ERRCODE = 'P0001'; END IF;

  UPDATE public.cs_cases SET
    status = 'in_progress',
    completed_at = NULL, completed_by = NULL, completed_by_name = NULL,
    -- 「미분류(과거)」는 고르는 자리에서 숨으므로 다시 열면 비운다(완료 양식이 숨은 값을 들고 열리지 않게)
    category_code = NULLIF(k.category_code, 'legacy_unclassified'),
    version = k.version + 1
  WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;

-- ── 3. 진행현황 바꾸기(진행중 ↔ 확인필요 — 완료와 별개, D-20) ────────────
CREATE OR REPLACE FUNCTION public.cs_set_case_status(p_case_id uuid, p_version integer, p_status text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a record;
  k public.cs_cases%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  IF p_status NOT IN ('in_progress','needs_check') THEN RAISE EXCEPTION 'invalid_status' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.status = 'done' THEN RAISE EXCEPTION 'already_done' USING ERRCODE = 'P0001'; END IF;
  IF k.status = p_status THEN RETURN k.version; END IF;

  UPDATE public.cs_cases SET status = p_status, version = k.version + 1 WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;

-- ── 4. CS 추가(같은 대화의 회원 글을 골라 새 건 — D-12·D-19) ─────────────
-- 고른 글은 새 건으로 옮긴다(원래 건에서 빠진다). 다른 건의 **시작 글**은 고를 수 없다.
-- 가장 이른 글 = 접수 시각·시작 글. 항목·첫 메모는 선택. 돌려주는 값 = 새 건 id.
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

-- ── 5. 문의 요약 고치기(D-12) ────────────────────────────────
CREATE OR REPLACE FUNCTION public.cs_update_case_summary(p_case_id uuid, p_version integer, p_summary text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a record;
  k public.cs_cases%ROWTYPE;
  v text := NULLIF(btrim(p_summary, E' \t\r\n'), '');
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  IF v IS NULL THEN RAISE EXCEPTION 'summary_required' USING ERRCODE = 'P0001'; END IF;
  IF char_length(v) > 10000 THEN RAISE EXCEPTION 'summary_too_long' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.personal_purged_at IS NOT NULL THEN RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001'; END IF;
  IF v IS NOT DISTINCT FROM k.summary_body THEN RETURN k.version; END IF;

  UPDATE public.cs_cases SET
    summary_body = v,
    summary_edited = true,
    summary_translated = NULL, summary_translated_lang = NULL, summary_translate_status = 'pending',
    version = k.version + 1
  WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;

-- ── 6. 수기 등록(메일·LINE — 4-1 · D-17) ──────────────────────────
-- 완료로 등록하면 항목·대응 내용(일·한 중 하나 이상)·완료 일시 필수. 대응 안내 = 대응 내용 한국어(없으면 일본어).
-- 요약 = 문의 내용 한국어 첫 줄(없으면 일본어). 회원을 골랐으면 회원 id(이름·이메일은 회원 표에서 — 직접 칸은 비움).
CREATE OR REPLACE FUNCTION public.cs_create_manual_case(
  p_source          text,
  p_received_at     timestamptz,
  p_influencer_id   uuid    DEFAULT NULL,
  p_manual_name     text    DEFAULT NULL,
  p_manual_email    text    DEFAULT NULL,
  p_campaign_id     uuid    DEFAULT NULL,
  p_campaign_name   text    DEFAULT NULL,
  p_manual_category text    DEFAULT NULL,
  p_category_code   text    DEFAULT NULL,
  p_inquiry_ja      text    DEFAULT NULL,
  p_inquiry_ko      text    DEFAULT NULL,
  p_response_ja     text    DEFAULT NULL,
  p_response_ko     text    DEFAULT NULL,
  p_first_reply_at  timestamptz DEFAULT NULL,
  p_status          text    DEFAULT 'in_progress',
  p_completed_at    timestamptz DEFAULT NULL,
  p_first_comment   text    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a        record;
  v_new    uuid;
  v_inq    text := COALESCE(NULLIF(btrim(p_inquiry_ko, E' \t\r\n'), ''), NULLIF(btrim(p_inquiry_ja, E' \t\r\n'), ''));
  v_resp   text := COALESCE(NULLIF(btrim(p_response_ko), ''), NULLIF(btrim(p_response_ja), ''));
  v_title  text;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  IF greatest(char_length(COALESCE(p_inquiry_ja,'')), char_length(COALESCE(p_inquiry_ko,'')),
              char_length(COALESCE(p_response_ja,'')), char_length(COALESCE(p_response_ko,''))) > 10000
     OR char_length(COALESCE(p_manual_name,'')) > 200 OR char_length(COALESCE(p_manual_email,'')) > 320
     OR char_length(COALESCE(p_campaign_name,'')) > 500 THEN
    RAISE EXCEPTION 'text_too_long' USING ERRCODE = 'P0001';
  END IF;
  IF char_length(COALESCE(btrim(p_first_comment), '')) > 5000 THEN RAISE EXCEPTION 'comment_too_long' USING ERRCODE = 'P0001'; END IF;
  IF p_source NOT IN ('mail','line','other') THEN RAISE EXCEPTION 'invalid_source' USING ERRCODE = 'P0001'; END IF;
  IF p_status NOT IN ('in_progress','needs_check','done') THEN RAISE EXCEPTION 'invalid_status' USING ERRCODE = 'P0001'; END IF;
  IF p_received_at IS NULL THEN RAISE EXCEPTION 'received_at_required' USING ERRCODE = 'P0001'; END IF;
  IF p_received_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'received_at_future' USING ERRCODE = 'P0001'; END IF;
  IF p_first_reply_at IS NOT NULL AND p_first_reply_at < p_received_at THEN
    RAISE EXCEPTION 'reply_before_received' USING ERRCODE = 'P0001';
  END IF;
  IF p_influencer_id IS NULL AND NULLIF(btrim(p_manual_name), '') IS NULL AND NULLIF(btrim(p_manual_email), '') IS NULL THEN
    RAISE EXCEPTION 'member_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_influencer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.influencers WHERE id = p_influencer_id) THEN
    RAISE EXCEPTION 'member_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF p_manual_category IS NOT NULL AND p_manual_category NOT IN ('monitor','gifting','visit','service') THEN
    RAISE EXCEPTION 'invalid_manual_category' USING ERRCODE = 'P0001';
  END IF;
  IF v_inq IS NULL THEN RAISE EXCEPTION 'inquiry_required' USING ERRCODE = 'P0001'; END IF;
  PERFORM public._cs_check_category(p_category_code);
  IF p_status = 'done' THEN
    IF p_category_code IS NULL THEN RAISE EXCEPTION 'category_required' USING ERRCODE = 'P0001'; END IF;
    IF v_resp IS NULL THEN RAISE EXCEPTION 'response_required' USING ERRCODE = 'P0001'; END IF;
    IF p_completed_at IS NULL THEN RAISE EXCEPTION 'completed_at_required' USING ERRCODE = 'P0001'; END IF;
    IF p_completed_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'completed_at_future' USING ERRCODE = 'P0001'; END IF;
    IF p_completed_at < p_received_at THEN RAISE EXCEPTION 'completed_before_received' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF p_campaign_id IS NOT NULL THEN
    SELECT c.title INTO v_title FROM public.campaigns c WHERE c.id = p_campaign_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0001'; END IF;
  END IF;

  INSERT INTO public.cs_cases (
    source, influencer_id, campaign_id, manual_name, manual_email, manual_campaign_name, manual_category,
    category_code, status, received_at, first_reply_at, completed_at, completed_by, completed_by_name,
    response_body, response_translated, response_translated_lang, response_translate_status,
    summary_body, summary_translated, summary_translated_lang, summary_translate_status,
    manual_inquiry_ja, manual_inquiry_ko, manual_response_ja, manual_response_ko,
    origin, created_by
  ) VALUES (
    p_source, p_influencer_id, p_campaign_id,
    CASE WHEN p_influencer_id IS NULL THEN NULLIF(btrim(p_manual_name), '') END,
    CASE WHEN p_influencer_id IS NULL THEN NULLIF(btrim(p_manual_email), '') END,
    left(COALESCE(v_title, NULLIF(btrim(p_campaign_name), '')), 500),
    p_manual_category,
    p_category_code, p_status, p_received_at, p_first_reply_at,
    CASE WHEN p_status = 'done' THEN p_completed_at END,
    CASE WHEN p_status = 'done' THEN a.actor_id END,
    CASE WHEN p_status = 'done' THEN a.actor_name END,
    -- 수기 두 칸은 자동 번역하지 않고 다른 언어 칸을 번역으로 쓴다(4-4 ⑧ — 한국어가 본문, 일본어가 번역).
    -- 한쪽만 있으면 번역 없음
    CASE WHEN p_status = 'done' THEN v_resp END,
    CASE WHEN p_status = 'done' AND NULLIF(btrim(p_response_ko), '') IS NOT NULL THEN NULLIF(btrim(p_response_ja), '') END,
    CASE WHEN p_status = 'done' AND NULLIF(btrim(p_response_ko), '') IS NOT NULL AND NULLIF(btrim(p_response_ja), '') IS NOT NULL THEN 'ja' END,
    CASE WHEN p_status = 'done' AND v_resp IS NOT NULL THEN
      CASE WHEN NULLIF(btrim(p_response_ko), '') IS NOT NULL AND NULLIF(btrim(p_response_ja), '') IS NOT NULL THEN 'done' ELSE 'skipped' END END,
    left(split_part(v_inq, E'\n', 1), 10000),
    CASE WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL THEN left(split_part(NULLIF(btrim(p_inquiry_ja), ''), E'\n', 1), 10000) END,
    CASE WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL AND NULLIF(btrim(p_inquiry_ja), '') IS NOT NULL THEN 'ja' END,
    CASE WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL AND NULLIF(btrim(p_inquiry_ja), '') IS NOT NULL THEN 'done' ELSE 'skipped' END,
    NULLIF(btrim(p_inquiry_ja), ''), NULLIF(btrim(p_inquiry_ko), ''),
    NULLIF(btrim(p_response_ja), ''), NULLIF(btrim(p_response_ko), ''),
    'live', a.actor_id
  ) RETURNING id INTO v_new;

  IF NULLIF(btrim(p_first_comment), '') IS NOT NULL THEN
    INSERT INTO public.cs_case_comments (case_id, author_id, author_name, body, translate_status)
    VALUES (v_new, a.actor_id, a.actor_name, btrim(p_first_comment), 'pending');
  END IF;
  RETURN v_new;
END;
$$;

-- ── 7. 수기 편집(진행현황·완료 일시·메모 없음 — 4-1) ──────────────────
CREATE OR REPLACE FUNCTION public.cs_update_manual_case(
  p_case_id         uuid,
  p_version         integer,
  p_source          text,
  p_received_at     timestamptz,
  p_influencer_id   uuid    DEFAULT NULL,
  p_manual_name     text    DEFAULT NULL,
  p_manual_email    text    DEFAULT NULL,
  p_campaign_id     uuid    DEFAULT NULL,
  p_campaign_name   text    DEFAULT NULL,
  p_manual_category text    DEFAULT NULL,
  p_category_code   text    DEFAULT NULL,
  p_inquiry_ja      text    DEFAULT NULL,
  p_inquiry_ko      text    DEFAULT NULL,
  p_response_ja     text    DEFAULT NULL,
  p_response_ko     text    DEFAULT NULL,
  p_first_reply_at  timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a       record;
  k       public.cs_cases%ROWTYPE;
  v_inq   text := COALESCE(NULLIF(btrim(p_inquiry_ko, E' \t\r\n'), ''), NULLIF(btrim(p_inquiry_ja, E' \t\r\n'), ''));
  v_resp  text := COALESCE(NULLIF(btrim(p_response_ko), ''), NULLIF(btrim(p_response_ja), ''));
  v_title text;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  IF greatest(char_length(COALESCE(p_inquiry_ja,'')), char_length(COALESCE(p_inquiry_ko,'')),
              char_length(COALESCE(p_response_ja,'')), char_length(COALESCE(p_response_ko,''))) > 10000
     OR char_length(COALESCE(p_manual_name,'')) > 200 OR char_length(COALESCE(p_manual_email,'')) > 320
     OR char_length(COALESCE(p_campaign_name,'')) > 500 THEN
    RAISE EXCEPTION 'text_too_long' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.source NOT IN ('mail','line','other') THEN RAISE EXCEPTION 'not_manual_case' USING ERRCODE = 'P0001'; END IF;
  IF k.personal_purged_at IS NOT NULL THEN RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001'; END IF;
  IF p_source NOT IN ('mail','line','other') THEN RAISE EXCEPTION 'invalid_source' USING ERRCODE = 'P0001'; END IF;
  IF p_received_at IS NULL THEN RAISE EXCEPTION 'received_at_required' USING ERRCODE = 'P0001'; END IF;
  IF p_received_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'received_at_future' USING ERRCODE = 'P0001'; END IF;
  IF k.completed_at IS NOT NULL AND k.completed_at < p_received_at THEN
    RAISE EXCEPTION 'completed_before_received' USING ERRCODE = 'P0001';
  END IF;
  IF p_first_reply_at IS NOT NULL AND p_first_reply_at < p_received_at THEN
    RAISE EXCEPTION 'reply_before_received' USING ERRCODE = 'P0001';
  END IF;
  IF p_influencer_id IS NULL AND NULLIF(btrim(p_manual_name), '') IS NULL AND NULLIF(btrim(p_manual_email), '') IS NULL THEN
    RAISE EXCEPTION 'member_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_influencer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.influencers WHERE id = p_influencer_id) THEN
    RAISE EXCEPTION 'member_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF p_manual_category IS NOT NULL AND p_manual_category NOT IN ('monitor','gifting','visit','service') THEN
    RAISE EXCEPTION 'invalid_manual_category' USING ERRCODE = 'P0001';
  END IF;
  IF v_inq IS NULL THEN RAISE EXCEPTION 'inquiry_required' USING ERRCODE = 'P0001'; END IF;
  -- 원래 값(시트·백필의 「미분류(과거)」 포함)은 그대로 둘 수 있고, 바꿀 때만 검사한다
  IF p_category_code IS DISTINCT FROM k.category_code THEN PERFORM public._cs_check_category(p_category_code); END IF;
  IF k.status = 'done' AND p_category_code IS NULL THEN RAISE EXCEPTION 'category_required' USING ERRCODE = 'P0001'; END IF;
  -- 실시간으로 만든 완료 건은 대응 내용이 남아 있어야 한다(시트 출신은 비어 있을 수 있다)
  IF k.status = 'done' AND k.origin = 'live' AND v_resp IS NULL THEN RAISE EXCEPTION 'response_required' USING ERRCODE = 'P0001'; END IF;
  IF p_campaign_id IS NOT NULL THEN
    SELECT c.title INTO v_title FROM public.campaigns c WHERE c.id = p_campaign_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0001'; END IF;
  END IF;

  UPDATE public.cs_cases SET
    source = p_source,
    received_at = p_received_at,
    influencer_id = p_influencer_id,
    campaign_id = p_campaign_id,
    manual_name  = CASE WHEN p_influencer_id IS NULL THEN NULLIF(btrim(p_manual_name), '') END,
    manual_email = CASE WHEN p_influencer_id IS NULL THEN NULLIF(btrim(p_manual_email), '') END,
    manual_campaign_name = left(COALESCE(v_title, NULLIF(btrim(p_campaign_name), '')), 500),
    manual_category = p_manual_category,
    category_code = p_category_code,
    first_reply_at = p_first_reply_at,
    manual_inquiry_ja  = NULLIF(btrim(p_inquiry_ja), ''),
    manual_inquiry_ko  = NULLIF(btrim(p_inquiry_ko), ''),
    manual_response_ja = NULLIF(btrim(p_response_ja), ''),
    manual_response_ko = NULLIF(btrim(p_response_ko), ''),
    -- 완료 건의 대응 안내는 대응 내용 칸을 따라간다(한국어 본문 · 일본어 번역 — 등록 규칙과 같게). 칸이 그대로면 손대지 않는다
    response_body = CASE WHEN k.status = 'done' AND v_resp IS NOT NULL
                          AND (NULLIF(btrim(p_response_ko), '') IS DISTINCT FROM k.manual_response_ko
                            OR NULLIF(btrim(p_response_ja), '') IS DISTINCT FROM k.manual_response_ja)
                         THEN v_resp ELSE k.response_body END,
    response_translated = CASE WHEN k.status = 'done' AND v_resp IS NOT NULL
                          AND (NULLIF(btrim(p_response_ko), '') IS DISTINCT FROM k.manual_response_ko
                            OR NULLIF(btrim(p_response_ja), '') IS DISTINCT FROM k.manual_response_ja)
                         THEN CASE WHEN NULLIF(btrim(p_response_ko), '') IS NOT NULL THEN NULLIF(btrim(p_response_ja), '') END
                         ELSE k.response_translated END,
    response_translated_lang = CASE WHEN k.status = 'done' AND v_resp IS NOT NULL
                          AND (NULLIF(btrim(p_response_ko), '') IS DISTINCT FROM k.manual_response_ko
                            OR NULLIF(btrim(p_response_ja), '') IS DISTINCT FROM k.manual_response_ja)
                         THEN CASE WHEN NULLIF(btrim(p_response_ko), '') IS NOT NULL AND NULLIF(btrim(p_response_ja), '') IS NOT NULL THEN 'ja' END
                         ELSE k.response_translated_lang END,
    response_translate_status = CASE WHEN k.status = 'done' AND v_resp IS NOT NULL
                          AND (NULLIF(btrim(p_response_ko), '') IS DISTINCT FROM k.manual_response_ko
                            OR NULLIF(btrim(p_response_ja), '') IS DISTINCT FROM k.manual_response_ja)
                         THEN CASE WHEN NULLIF(btrim(p_response_ko), '') IS NOT NULL AND NULLIF(btrim(p_response_ja), '') IS NOT NULL THEN 'done' ELSE 'skipped' END
                         ELSE k.response_translate_status END,
    -- 요약을 담당자가 고친 적 없으면 문의 내용 첫 줄을 따라간다
    summary_body = CASE WHEN k.summary_edited THEN k.summary_body ELSE left(split_part(v_inq, E'\n', 1), 10000) END,
    summary_translated = CASE WHEN k.summary_edited THEN k.summary_translated
                              WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL
                              THEN left(split_part(NULLIF(btrim(p_inquiry_ja), ''), E'\n', 1), 10000) END,
    summary_translated_lang = CASE WHEN k.summary_edited THEN k.summary_translated_lang
                                   WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL AND NULLIF(btrim(p_inquiry_ja), '') IS NOT NULL THEN 'ja' END,
    summary_translate_status = CASE WHEN k.summary_edited THEN k.summary_translate_status
                                    WHEN NULLIF(btrim(p_inquiry_ko), '') IS NOT NULL AND NULLIF(btrim(p_inquiry_ja), '') IS NOT NULL THEN 'done'
                                    ELSE 'skipped' END,
    version = k.version + 1
  WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;

-- ── 8. 메모 쓰기(D-11 — 답글은 한 단계) ────────────────────────────
-- p_attachments = [{path, name, size, mime}] · path 는 '{건 id}/' 로 시작해야 한다. 돌려주는 값 = 새 메모 id.
CREATE OR REPLACE FUNCTION public.cs_add_comment(
  p_case_id     uuid,
  p_body        text,
  p_parent_id   uuid  DEFAULT NULL,
  p_attachments jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a      record;
  v_body text := COALESCE(btrim(p_body), '');
  v_att  jsonb := COALESCE(p_attachments, '[]'::jsonb);
  v_new  uuid;
  k      public.cs_cases%ROWTYPE;
  p      public.cs_case_comments%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.personal_purged_at IS NOT NULL THEN RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001'; END IF;
  IF jsonb_typeof(v_att) <> 'array' THEN RAISE EXCEPTION 'invalid_attachments' USING ERRCODE = 'P0001'; END IF;
  IF jsonb_array_length(v_att) > 5 THEN RAISE EXCEPTION 'invalid_attachments' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_att) e WHERE jsonb_typeof(e) <> 'object') THEN
    RAISE EXCEPTION 'invalid_attachments' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_att) e
              WHERE jsonb_typeof(e->'path') IS DISTINCT FROM 'string'
                 OR (e->>'path') NOT LIKE p_case_id::text || '/%'
                 OR (e->>'path') LIKE '%..%') THEN
    RAISE EXCEPTION 'invalid_attachments' USING ERRCODE = 'P0001';
  END IF;
  IF v_body = '' AND jsonb_array_length(v_att) = 0 THEN RAISE EXCEPTION 'comment_empty' USING ERRCODE = 'P0001'; END IF;
  IF char_length(v_body) > 5000 THEN RAISE EXCEPTION 'comment_too_long' USING ERRCODE = 'P0001'; END IF;

  IF p_parent_id IS NOT NULL THEN
    SELECT * INTO p FROM public.cs_case_comments WHERE id = p_parent_id;
    IF NOT FOUND OR p.case_id <> p_case_id OR p.parent_id IS NOT NULL OR p.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'invalid_parent' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  INSERT INTO public.cs_case_comments (case_id, parent_id, author_id, author_name, body, attachments, translate_status)
  VALUES (p_case_id, p_parent_id, a.actor_id, a.actor_name, v_body, v_att,
          CASE WHEN v_body <> '' THEN 'pending' END)
  RETURNING id INTO v_new;

  -- 내가 쓴 글은 바로 읽음(요약 함수도 본인 글은 안 세지만 모달의 「새」 표시를 위해)
  INSERT INTO public.cs_case_comment_reads (comment_id, admin_auth_id) VALUES (v_new, a.actor_id)
  ON CONFLICT DO NOTHING;
  RETURN v_new;
END;
$$;

-- ── 9. 메모 지우기(내 글만 · 시트 이관 글은 아무도 못 지움 — D-11) ─────────
CREATE OR REPLACE FUNCTION public.cs_delete_comment(p_comment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a record;
  c public.cs_case_comments%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  SELECT * INTO c FROM public.cs_case_comments WHERE id = p_comment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'comment_not_found' USING ERRCODE = 'P0001'; END IF;
  IF c.origin = 'sheet' THEN RAISE EXCEPTION 'sheet_comment_locked' USING ERRCODE = 'P0001'; END IF;
  IF c.author_id IS DISTINCT FROM a.actor_id THEN RAISE EXCEPTION 'not_own_comment' USING ERRCODE = 'P0001'; END IF;
  IF c.deleted_at IS NOT NULL THEN RETURN; END IF;

  -- 본문·번역은 비우고 표시만 남긴다. 첨부 목록은 남겨 파기 함수(1-6·4-1)가 파일을 지우게 한다
  UPDATE public.cs_case_comments SET
    deleted_at = now(), body = '', translated = NULL, translated_lang = NULL, translate_status = NULL
  WHERE id = p_comment_id;
END;
$$;

-- ── 10. 메모 읽음(건 단위 — D-20, 298 과 같은 방식) ──────────────────
CREATE OR REPLACE FUNCTION public.cs_mark_case_comments_read(p_case_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a record;
  n integer;
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  INSERT INTO public.cs_case_comment_reads (comment_id, admin_auth_id)
  SELECT cm.id, a.actor_id FROM public.cs_case_comments cm
   WHERE cm.case_id = p_case_id AND cm.deleted_at IS NULL
  ON CONFLICT (comment_id, admin_auth_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ── 실행 권한: 로그인 사용자만(안에서 메시지 메뉴 권한) ───────────────────
DO $g$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.cs_complete_case(uuid, integer, text, text, timestamptz)',
    'public.cs_reopen_case(uuid, integer)',
    'public.cs_set_case_status(uuid, integer, text)',
    'public.cs_split_case(uuid[], text, text)',
    'public.cs_update_case_summary(uuid, integer, text)',
    'public.cs_create_manual_case(text, timestamptz, uuid, text, text, uuid, text, text, text, text, text, text, text, timestamptz, text, timestamptz, text)',
    'public.cs_update_manual_case(uuid, integer, text, timestamptz, uuid, text, text, uuid, text, text, text, text, text, text, text, timestamptz)',
    'public.cs_add_comment(uuid, text, uuid, jsonb)',
    'public.cs_delete_comment(uuid)',
    'public.cs_mark_case_comments_read(uuid)'
  ] LOOP
    EXECUTE 'REVOKE ALL ON FUNCTION ' || f || ' FROM PUBLIC, anon';
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || f || ' TO authenticated';
  END LOOP;
END $g$;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버) — 거부 갈래마다 1회 + 정상 갈래 1회(작업표 1-5 완료 정의). 관리자 역할 흉내로.
-- ============================================================
/*
-- 수기 등록 → 메모 → 읽음 → 요약 수정 → 진행현황 → 완료 → 다시 열기 → 메모 지우기, 각 단계 반환 version 확인
-- 거부: forbidden(회원 역할) · version_conflict · invalid_category(legacy_unclassified) · response_required ·
--       completed_at_required(수기) · contains_case_start · invalid_messages(운영팀 글·다른 대화 섞기) · invalid_parent(답글에 답글) ·
--       not_own_comment · sheet_comment_locked · invalid_attachments(다른 건 경로)
*/

-- ============================================================
-- 롤백
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(함수 삭제)
-- DROP FUNCTION IF EXISTS public.cs_mark_case_comments_read(uuid);
-- DROP FUNCTION IF EXISTS public.cs_delete_comment(uuid);
-- DROP FUNCTION IF EXISTS public.cs_add_comment(uuid, text, uuid, jsonb);
-- DROP FUNCTION IF EXISTS public.cs_update_manual_case(uuid, integer, text, timestamptz, uuid, text, text, uuid, text, text, text, text, text, text, text, timestamptz);
-- DROP FUNCTION IF EXISTS public.cs_create_manual_case(text, timestamptz, uuid, text, text, uuid, text, text, text, text, text, text, text, timestamptz, text, timestamptz, text);
-- DROP FUNCTION IF EXISTS public.cs_update_case_summary(uuid, integer, text);
-- DROP FUNCTION IF EXISTS public.cs_split_case(uuid[], text, text);
-- DROP FUNCTION IF EXISTS public.cs_set_case_status(uuid, integer, text);
-- DROP FUNCTION IF EXISTS public.cs_reopen_case(uuid, integer);
-- DROP FUNCTION IF EXISTS public.cs_complete_case(uuid, integer, text, text, timestamptz);
-- DROP FUNCTION IF EXISTS public._cs_check_category(text);
-- DROP FUNCTION IF EXISTS public._cs_actor();
