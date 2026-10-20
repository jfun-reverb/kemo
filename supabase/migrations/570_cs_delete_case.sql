-- ============================================================
-- 570_cs_delete_case.sql   (569 는 같은 날 브랜드 비밀번호 재설정이 먼저 씀)
-- CS 이력 관리 — 잘못 열린 CS 건 삭제(D-22 · 2026-10-20 사용자 결정)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md D-22 · 「구현 결과」 건 삭제
--
-- 결정(사용자): **완전 삭제** · **열린 건만**(진행중·확인필요 — 완료 건은 「다시 열기」 뒤에만) ·
--   **메시지 메뉴 권한이 있는 관리자 누구나**(다른 CS 쓰기와 같은 `_cs_actor`)
--   · 그 건의 회원 글은 **같은 대화의 다른 열린 건**(접수가 가장 늦은 것)으로 옮긴다 — 없으면 **같은 대화의 가장 최근 건** —
--     그것도 없으면 연결만 풀린다(그 대화에 회원 글이 또 오면 새 건이 자동으로 생긴다 — 558)
--   · 메모·답글·읽음은 함께 지워진다(556 외래 키 CASCADE) · 🔴 메모 첨부 **파일**은 행이 사라지면 경로를 잃으므로
--     지우기 **전에** 경로를 파기 대기 표(`cs_attachment_purge_queue`)에 넣는다 — 서버 함수 purge-cs-comment-attachments 가 지운다
--   · 이 건을 「이전 건」으로 가리키던 재문의 연결은 비워진다(556 SET NULL)
--
-- 🔴 잠금 순서: 대화 잠금(558 과 같은 열쇠) **먼저** → 건 행. 반대면 회원 글 발신 트리거와 교착
--    (트리거는 대화 잠금을 2초 기다리고 포기한다 — 그 글은 건에 안 붙고 표에 「건 없음」으로 남아 「CS 추가」로 붙인다)
-- 편집기 경고: 뜸 — 무해(함수 본문 안의 DELETE · 표 생성) — 실행해도 행이 지워지지 않는다
-- 롤백: 파일 하단
-- ============================================================

-- ── 1. 첨부 파기 대기 표 — 지워진 메모의 파일 경로(행이 사라져도 파일을 지울 수 있게) ─────
CREATE TABLE IF NOT EXISTS public.cs_attachment_purge_queue (
  path       text        PRIMARY KEY CHECK (path NOT LIKE '%..%'),
  queued_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cs_attachment_purge_queue ENABLE ROW LEVEL SECURITY;   -- 정책 없음 = 로그인 역할은 못 읽고 못 쓴다(서비스 키·정의자 함수만)
REVOKE ALL ON public.cs_attachment_purge_queue FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.cs_attachment_purge_queue IS
  '[570] CS 건 삭제로 사라진 메모의 첨부 파일 경로 — purge-cs-comment-attachments 가 지우고 행을 지운다';

-- ── 2. 건 삭제 ─────────────────────────────────────────────
-- 반환 {moved_to: 옮겨 간 건 id | null, moved_count: 옮긴 회원 글 수, queued_files: 파기 대기에 넣은 파일 수}
CREATE OR REPLACE FUNCTION public.cs_delete_case(p_case_id uuid, p_version integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET lock_timeout = '5s'
AS $$
DECLARE
  a        record;
  pre      record;
  k        public.cs_cases%ROWTYPE;
  v_target uuid;
  v_moved  integer := 0;
  v_files  integer := 0;
BEGIN
  SELECT * INTO a FROM public._cs_actor();

  -- 대화를 알아야 잠금 열쇠를 정한다 — 잠그기 전 한 번 읽고, 잠근 뒤 다시 읽어 확인
  SELECT application_id, general_thread_id INTO pre FROM public.cs_cases WHERE id = p_case_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF pre.application_id IS NOT NULL OR pre.general_thread_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('cs_case_conv:' || COALESCE(pre.application_id, pre.general_thread_id)::text));
  END IF;

  SELECT * INTO k FROM public.cs_cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE = 'P0001'; END IF;
  IF k.version <> p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001'; END IF;
  IF k.status NOT IN ('in_progress', 'needs_check') THEN RAISE EXCEPTION 'not_open' USING ERRCODE = 'P0001'; END IF;
  IF k.application_id IS DISTINCT FROM pre.application_id OR k.general_thread_id IS DISTINCT FROM pre.general_thread_id THEN
    RAISE EXCEPTION 'version_conflict' USING ERRCODE = 'P0001';   -- 잠그는 사이 대화 연결이 바뀌었다(원본 삭제 등)
  END IF;

  -- 회원 글을 옮길 건 — 같은 대화의 다른 열린 건(접수가 가장 늦은 것), 없으면 가장 최근 건
  IF k.application_id IS NOT NULL OR k.general_thread_id IS NOT NULL THEN
    SELECT s.id INTO v_target
      FROM public.cs_cases s
     WHERE s.id <> k.id
       AND ((k.application_id IS NOT NULL AND s.application_id = k.application_id)
         OR (k.general_thread_id IS NOT NULL AND s.general_thread_id = k.general_thread_id))
     ORDER BY (s.status <> 'done') DESC, s.received_at DESC, s.case_no DESC
     LIMIT 1;
  END IF;
  IF v_target IS NOT NULL THEN
    UPDATE public.cs_case_messages SET case_id = v_target, linked_at = now() WHERE case_id = k.id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
  END IF;

  -- 메모 첨부 파일 경로를 파기 대기로(행은 곧 CASCADE 로 사라진다) — 562 올리기 검사와 같은 경로 규칙만
  INSERT INTO public.cs_attachment_purge_queue (path)
  SELECT DISTINCT e->>'path'
    FROM public.cs_case_comments c, jsonb_array_elements(CASE WHEN jsonb_typeof(c.attachments) = 'array' THEN c.attachments ELSE '[]'::jsonb END) e
   WHERE c.case_id = k.id
     AND jsonb_typeof(e->'path') = 'string'
     AND (e->>'path') LIKE k.id::text || '/%'
     AND (e->>'path') NOT LIKE '%..%'
  ON CONFLICT (path) DO NOTHING;
  GET DIAGNOSTICS v_files = ROW_COUNT;

  DELETE FROM public.cs_cases WHERE id = k.id;   -- 메모·답글·읽음·남은 연결은 CASCADE · 재문의 연결은 SET NULL

  RETURN jsonb_build_object('moved_to', v_target, 'moved_count', v_moved, 'queued_files', v_files);
END;
$$;
REVOKE ALL ON FUNCTION public.cs_delete_case(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cs_delete_case(uuid, integer) TO authenticated;   -- 안에서 메시지 메뉴 권한(_cs_actor)

-- ── 3. 파기 대기 목록·지우기(서비스 키 전용 — 567 과 같은 짝) ──────────────
CREATE OR REPLACE FUNCTION public.list_cs_attachment_purge_queue(p_limit integer DEFAULT 500)
RETURNS SETOF text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT path FROM public.cs_attachment_purge_queue ORDER BY queued_at
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 500), 2000));
$$;

CREATE OR REPLACE FUNCTION public.clear_cs_attachment_purge_queue(p_paths text[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE n integer;
BEGIN
  DELETE FROM public.cs_attachment_purge_queue WHERE path = ANY (COALESCE(p_paths, ARRAY[]::text[]));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.list_cs_attachment_purge_queue(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clear_cs_attachment_purge_queue(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_cs_attachment_purge_queue(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.clear_cs_attachment_purge_queue(text[]) TO service_role;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버)
-- ============================================================
/*
-- 관리자 역할 흉내로 시험 건(CS 추가로 만든 것) 삭제 → 반환 moved_to·moved_count · 그 건 행 없음 · 대기 표에 첨부 경로
-- 완료 건 → not_open · 낡은 version → version_conflict · 회원 역할 → forbidden
*/

-- ============================================================
-- 롤백
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(함수·표 삭제 — 대기 중인 경로가 있으면 먼저 비울 것)
-- DROP FUNCTION IF EXISTS public.clear_cs_attachment_purge_queue(text[]);
-- DROP FUNCTION IF EXISTS public.list_cs_attachment_purge_queue(integer);
-- DROP FUNCTION IF EXISTS public.cs_delete_case(uuid, integer);
-- DROP TABLE IF EXISTS public.cs_attachment_purge_queue;
