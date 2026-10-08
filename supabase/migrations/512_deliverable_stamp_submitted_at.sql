-- =============================================================================
-- 마이그레이션 512: 결과물 제출 시각을 실제 제출 순간에 찍는다
-- 사양서  : docs/specs/2026-10-06-deliverable-submit-approve-dates-handoff.md (고칠 것 ①)
-- 대상    : 개발서버 → 운영서버. 화면 코드보다 먼저(늦어도 같은 날) — 순서가 바뀌어도 깨지지는 않는다
-- 위험도  : 낮음 — 트리거 1개 추가. 표·칸 변경 없음, 기존 행은 고치지 않는다
-- 편집기 경고: 뜸 — 무해 (DROP TRIGGER IF EXISTS 로 같은 이름 트리거를 지우고 다시 만드는 줄)
--
-- 왜: deliverables.submitted_at 은 행이 처음 만들어질 때(035 기본값 now()) 한 번 찍히고 그 뒤 안 바뀌었다.
--     그래서 회원 화면·관리자 화면·검수 결과 메일의 「제출일」이 실제로는 「임시저장한 날 / 처음 올린 날」이었다.
--
-- 🔴 조건은 「임시저장(draft) → 검수 대기(pending)」 하나뿐이다.
--    처음 제출(submitDrafts)과 반려 뒤 재제출(insertDraftDeliverable 이 그 행을 draft 로 되돌린 뒤 submitDrafts)이
--    모두 이 길을 지난다. 「검수 대기가 아니던 행 → 검수 대기」로 넓히면 관리자 되돌리기(승인·반려 → 검수 대기)도
--    걸려 제출일이 되돌린 날로 바뀌고, 검수 대기 정렬에서 오래 기다린 건이 맨 뒤로 밀린다 — 넓히지 말 것.
--    관리자 대리 등록(511)은 이미 submitted_at = now() 를 넣는다(그대로).
--
-- 기존 BEFORE 트리거(274 제출 마감·301 정산 잠금·422 탈퇴 차단·035 updated_at)는 이 칸을 읽거나 쓰지 않는다.
-- 「최신 결과물」을 submitted_at 으로 고르는 서버 함수(정산 후보 455·인증 성공 수 456·리포트 공유 491)와 화면은
-- 재제출이 같은 행을 다시 쓰는 게시물에서만 결과가 달라진다 — 새 주소를 담은 행이 「최신」이 되므로 바른 쪽이다.
--
-- 되돌리기:
--   DROP TRIGGER IF EXISTS trg_deliverable_stamp_submitted_at ON public.deliverables;
--   DROP FUNCTION IF EXISTS public._deliverable_stamp_submitted_at();
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._deliverable_stamp_submitted_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.submitted_at := now();
  RETURN NEW;
END;
$$;

-- 트리거 함수라 직접 부를 일이 없다 — 실행 권한은 모두 회수(회수 방향 둘: PUBLIC 과 개별 역할)
REVOKE ALL ON FUNCTION public._deliverable_stamp_submitted_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._deliverable_stamp_submitted_at() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_deliverable_stamp_submitted_at ON public.deliverables;
CREATE TRIGGER trg_deliverable_stamp_submitted_at
  BEFORE UPDATE OF status ON public.deliverables
  FOR EACH ROW
  WHEN (OLD.status = 'draft' AND NEW.status = 'pending')
  EXECUTE FUNCTION public._deliverable_stamp_submitted_at();

COMMIT;

-- =============================================================================
-- 검증 SQL (1단계씩)
-- [1] 트리거가 붙었는지
--   SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
--    WHERE tgrelid = 'public.deliverables'::regclass AND tgname = 'trg_deliverable_stamp_submitted_at';
-- [2] 실제 제출 흐름은 로그인한 회원 화면에서 확인(임시저장 → 「提出する」 → 활동관리의 「提出日」이 오늘)
-- =============================================================================
