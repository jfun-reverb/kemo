-- ============================================================
-- 523_orient_sheet_draft_columns.sql
-- 2026-10-14 — 오리엔시트 「제출 뒤 수정은 작성본에만 저장」 ① 칸 추가
--   사양서 docs/specs/2026-10-01-orient-sheet-post-submit-draft.md 설계 ①-①
--   (전수조사 3차 ①-7)
--
-- 무엇을: orient_sheets 에 작성본 칸 둘을 더한다. 기본값 없음 — 기존 행 전부 NULL = 작성본 없음.
--   draft_data      제출된 시트(status='submitted')에서 브랜드가 고친 내용. 「다시 제출」 전까지 여기에만 쌓인다.
--   draft_saved_at  작성본을 마지막으로 저장한 시각. 관리자 「브랜드 수정 중 · 미제출」 표시의 근거.
--
-- 🔴 이 파일만으로는 동작이 바뀌지 않는다 — 칸을 쓰는 함수는 524. 524 보다 먼저 적용한다.
-- ⚠️ 관리자 화면은 draft_saved_at 만 읽는다(작성본 내용은 관리자에게 안 보인다 — 사양서 결정 3).
--    관리자 조회(storage.js fetchOrientSheetById)는 select('*') 를 쓰지 않고 칸을 지정한다.
--
-- 편집기 경고: 안 뜸(ADD COLUMN 만).
-- 롤백(524 를 먼저 되돌린 뒤):
--   ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS draft_saved_at, DROP COLUMN IF EXISTS draft_data;
-- ============================================================

BEGIN;

ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS draft_data     jsonb       NULL,
  ADD COLUMN IF NOT EXISTS draft_saved_at timestamptz NULL;

COMMENT ON COLUMN public.orient_sheets.draft_data IS
  '[523] 제출 뒤 브랜드가 고친 작성본. save_orient_draft(524)가 status=submitted 일 때만 여기에 쓰고 data(제출본)는 건드리지 않는다. '
  '보정 뒤 제출본과 같으면 NULL. submit_orient_sheet(524) 성공 시 NULL. 관리자 화면은 읽지 않는다(결정 3).';
COMMENT ON COLUMN public.orient_sheets.draft_saved_at IS
  '[523] 작성본 마지막 저장 시각. draft_data 와 늘 함께 차고 함께 빈다. 관리자 「브랜드 수정 중 · 미제출」 표시 근거.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- 검증
-- [V1] 두 칸이 생겼고 전부 NULL
-- SELECT count(*) AS total, count(draft_data) AS with_draft, count(draft_saved_at) AS with_saved_at FROM public.orient_sheets;
