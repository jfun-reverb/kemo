-- ============================================================
-- 567_cs_comment_attachment_purge.sql
-- CS 이력 관리 — 메모 첨부 파일 파기(작업표 1-6·4-1 「남은 것」 ① · S-3)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 「구현 결과」 1-6·4-1 · 첨부 파기
--
-- 대상 = **지운 메모**(deleted_at 있음)인데 첨부 목록이 아직 남은 것.
--   · 내가 지운 메모(562 cs_delete_comment) · 개인정보를 비운 건의 메모(563 _cs_purge_case_comments —
--     탈퇴 확정·원본 삭제·수기 3년)가 모두 deleted_at 을 남기므로 이 한 조건으로 다 잡힌다
--   · 파일은 데이터베이스 함수로 못 지운다(S-3) — 서버 함수 purge-cs-comment-attachments 가 지우고 이 함수로 표시
--   · 🔴 순서는 「지우고 → 표시」 — 표시(첨부 목록 비우기)를 먼저 하면 지울 목록이 사라져 파일이 영영 남는다
--
--   · `list_pending_cs_attachment_purge(limit)` — 지울 경로 목록(경로는 그 건 폴더 안 것만 — 562 가 올릴 때 검사한 규칙)
--   · `mark_cs_attachments_purged(comment_ids)` — 지운 메모의 첨부 목록을 '[]' 로(지운 메모만 — 살아 있는 메모는 건드리지 않는다)
--   둘 다 서비스 키 전용(정의자 권한 + 로그인 역할 실행 회수)
--
-- ⚠️ 알려진 틈: 파일을 올린 뒤 메모 쓰기가 실패하면 그 파일은 어떤 메모에도 없어 여기서 못 잡는다(화면에 지우기 정책이 없다) — 다음 단계에서 통 전체 대조로
-- 편집기 경고: 안 뜸(함수 생성·권한만)
-- 롤백: 파일 하단
-- ============================================================

CREATE OR REPLACE FUNCTION public.list_pending_cs_attachment_purge(p_limit integer DEFAULT 500)
RETURNS TABLE (comment_id uuid, paths text[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.id,
         ARRAY(SELECT e->>'path'
                 FROM jsonb_array_elements(c.attachments) e
                WHERE jsonb_typeof(e->'path') = 'string'
                  AND (e->>'path') LIKE c.case_id::text || '/%'
                  AND (e->>'path') NOT LIKE '%..%')
    FROM public.cs_case_comments c
   WHERE c.deleted_at IS NOT NULL
     AND jsonb_typeof(c.attachments) = 'array'
     AND jsonb_array_length(c.attachments) > 0
   ORDER BY c.deleted_at
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 500), 2000));
$$;

CREATE OR REPLACE FUNCTION public.mark_cs_attachments_purged(p_comment_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE n integer;
BEGIN
  UPDATE public.cs_case_comments
     SET attachments = '[]'::jsonb
   WHERE id = ANY (COALESCE(p_comment_ids, ARRAY[]::uuid[]))
     AND deleted_at IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.list_pending_cs_attachment_purge(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_cs_attachments_purged(uuid[])       FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_pending_cs_attachment_purge(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_cs_attachments_purged(uuid[])       TO service_role;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버)
-- ============================================================
/*
SELECT * FROM public.list_pending_cs_attachment_purge(10);                       -- 서비스 키(편집기)로 — 목록
-- 회원·관리자 역할 흉내로 → permission denied(42501)
*/

-- ============================================================
-- 롤백
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(함수 삭제)
-- DROP FUNCTION IF EXISTS public.mark_cs_attachments_purged(uuid[]);
-- DROP FUNCTION IF EXISTS public.list_pending_cs_attachment_purge(integer);
