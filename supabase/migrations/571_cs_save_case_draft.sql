-- ============================================================
-- 571_cs_save_case_draft.sql
-- CS 이력 관리 — 열린 건의 항목·대응 안내 내용만 저장(완료와 별개 · 2026-10-20 사용자 요청)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 「구현 결과」 임시 저장
--
-- 왜: 562 의 `cs_complete_case` 는 항목·대응 안내를 저장하면서 **동시에 완료**한다. 진행 중에 고른 항목·쓰던 안내를
--   남길 길이 없었다(3-2 「초안 대비 달라진 것」 — 「진행 중 항목만 저장하는 함수가 없다」의 해소).
--   · `cs_save_case_draft(건, version, 항목, 대응 안내)` — 열린 건만(진행중·확인필요) · 진행현황·완료 시각은 그대로
--   · 항목: 비울 수 있다(NULL — 단 「미분류(과거)」 건은 빈 값이 오면 그대로 둔다) · 고르면 562 `_cs_check_category`(미분류(과거)·끈 항목 거부)
--   · 대응 안내: 비우면 NULL · 1만 자 상한 · 글이 바뀐 때만 자동 번역 대기(`pending`) — 완료 함수와 같은 규칙
--   · 반환 = 새 version(바뀐 것이 없으면 지금 version 그대로 — 쓰지 않는다)
-- 편집기 경고: 안 뜸(함수 생성·권한만)
-- 롤백: DROP FUNCTION IF EXISTS public.cs_save_case_draft(uuid, integer, text, text);
-- ============================================================

CREATE OR REPLACE FUNCTION public.cs_save_case_draft(
  p_case_id       uuid,
  p_version       integer,
  p_category_code text DEFAULT NULL,
  p_response_body text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  a      record;
  k      public.cs_cases%ROWTYPE;
  v_cat  text := NULLIF(btrim(p_category_code), '');
  v_body text := NULLIF(btrim(p_response_body), '');
BEGIN
  SELECT * INTO a FROM public._cs_actor();
  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.personal_purged_at IS NOT NULL THEN RAISE EXCEPTION 'case_purged' USING ERRCODE = 'P0001'; END IF;
  IF k.status = 'done' THEN RAISE EXCEPTION 'already_done' USING ERRCODE = 'P0001'; END IF;
  -- 미분류(과거)는 화면 선택 칸에 없어 빈 값으로 온다 — 빈 값이면 그 표시를 지우지 않고 둔다
  IF v_cat IS NULL AND k.category_code = 'legacy_unclassified' THEN v_cat := k.category_code; END IF;
  -- 이미 저장된 항목을 그대로 보내면 끈 항목이어도 통과(그 사이 항목을 꺼도 저장이 막히지 않게)
  IF v_cat IS DISTINCT FROM k.category_code THEN PERFORM public._cs_check_category(v_cat); END IF;
  IF char_length(COALESCE(v_body, '')) > 10000 THEN RAISE EXCEPTION 'response_too_long' USING ERRCODE = 'P0001'; END IF;
  -- 바뀐 것이 없으면 쓰지 않는다(562 cs_update_case_summary 와 같은 방식 — 번역 웹훅·version 증가 없음)
  IF v_cat IS NOT DISTINCT FROM k.category_code AND v_body IS NOT DISTINCT FROM k.response_body THEN RETURN k.version; END IF;

  UPDATE public.cs_cases SET
    category_code = v_cat,
    response_body = v_body,
    response_translated       = CASE WHEN v_body IS DISTINCT FROM k.response_body THEN NULL ELSE k.response_translated END,
    response_translated_lang  = CASE WHEN v_body IS DISTINCT FROM k.response_body THEN NULL ELSE k.response_translated_lang END,
    response_translate_status = CASE WHEN v_body IS DISTINCT FROM k.response_body
                                     THEN (CASE WHEN v_body IS NULL THEN NULL ELSE 'pending' END)
                                     ELSE k.response_translate_status END,
    version = k.version + 1
  WHERE id = p_case_id;
  RETURN k.version + 1;
END;
$$;
REVOKE ALL ON FUNCTION public.cs_save_case_draft(uuid, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cs_save_case_draft(uuid, integer, text, text) TO authenticated;   -- 안에서 메시지 메뉴 권한(_cs_actor)

NOTIFY pgrst, 'reload schema';
-- zz 시험 한 줄
