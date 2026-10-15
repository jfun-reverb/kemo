-- ============================================================
-- 507_general_inquiry_threads_multi_open_title.sql
-- 서비스 문의 여러 대화 — 개정 R2 ① 표 개정(여러 열린 대화 + 문의 제목)
--
-- 사양서: docs/specs/2026-10-06-service-inquiry-threads.md 맨 위 「🔄 설계 개정」 절 · 데이터베이스 ①
-- 선행: 504 → 505 → 506(개발서버 적용됨 — 고쳐 쓰지 않고 이 파일로 덧붙인다)
-- 다음: 508(함수·뷰). 🔴 507 만 적용된 채로 두어도 서비스는 그대로 돈다
--       (505 의 회원 발신은 「열린 대화 → 24시간 안 → 새 대화」라 열린 대화를 둘 만들지 않는다. 새 칸은 비어 있다).
--
-- 편집기 경고: 뜸 — 무해(유일 색인 하나를 지울 뿐, 행 삭제 없음)
--
-- 하는 것
--   ① 504 의 부분 유일 색인 uq_general_inquiry_threads_one_open(회원당 열린 대화 하나) 삭제 — R2-1·R2-2
--   ② 제목 title(앞뒤 공백을 뗀 1~40자, 비어 있을 수 있다 — 옮겨 온 대화·옛 화면이 만든 대화) — T-1
--   ③ 제목 번역 title_translated · title_translate_status(pending·done·failed·skipped) — R2-6
--   ④ 새 문의 중복 방지 client_token + 유일 색인 (influencer_id, client_token) — 경우의 수 C
--   ⑤ 표 주석 갱신
--
-- ── 적용 전 확인 ──
--   [P1] SELECT indexname FROM pg_indexes WHERE indexname='uq_general_inquiry_threads_one_open';   기대: 1행(504)
--   [P2] SELECT count(*) FROM public.general_inquiry_threads;   (기준값 — 적용 뒤 같아야 한다)
--
-- ── 적용 뒤 검증 조회 ──
--   [V1] 칸: SELECT column_name, data_type, is_nullable FROM information_schema.columns
--             WHERE table_schema='public' AND table_name='general_inquiry_threads' ORDER BY ordinal_position;
--        기대: 504 의 8칸 + title · title_translated · title_translate_status · client_token (12칸)
--   [V2] 색인: SELECT indexname FROM pg_indexes WHERE tablename='general_inquiry_threads' ORDER BY 1;
--        기대: uq_general_inquiry_threads_one_open 없음 · uq_general_inquiry_threads_client_token 있음
--   [V3] 제약: SELECT conname FROM pg_constraint WHERE conrelid='public.general_inquiry_threads'::regclass ORDER BY 1;
--        기대: general_inquiry_threads_title_len · general_inquiry_threads_title_translate_status 포함
--   [V4] 행 수 = [P2]
--
-- ── 되돌리는 방법 ──
--   supabase/patches/2026-10-06-general-inquiry-threads-rollback.sql 의 [R2-①] 절(508 을 먼저 되돌린 뒤).
--   🔴 유일 색인을 되살리기 전에 「회원당 열린 대화 둘 이상」을 먼저 정리해야 한다(안 하면 색인 생성이 실패한다).
-- ============================================================

BEGIN;

-- ① 회원당 열린 대화 하나 규칙 삭제
DROP INDEX IF EXISTS public.uq_general_inquiry_threads_one_open;

-- ② 제목
ALTER TABLE public.general_inquiry_threads
  ADD COLUMN IF NOT EXISTS title text NULL;

ALTER TABLE public.general_inquiry_threads
  DROP CONSTRAINT IF EXISTS general_inquiry_threads_title_len;
ALTER TABLE public.general_inquiry_threads
  ADD CONSTRAINT general_inquiry_threads_title_len
  CHECK (title IS NULL OR (title = btrim(title) AND char_length(title) BETWEEN 1 AND 40));

-- ③ 제목 번역(관리자 화면용 한국어) — translate-message 가 채운다
ALTER TABLE public.general_inquiry_threads
  ADD COLUMN IF NOT EXISTS title_translated text NULL,
  ADD COLUMN IF NOT EXISTS title_translate_status text NULL;

ALTER TABLE public.general_inquiry_threads
  DROP CONSTRAINT IF EXISTS general_inquiry_threads_title_translate_status;
ALTER TABLE public.general_inquiry_threads
  ADD CONSTRAINT general_inquiry_threads_title_translate_status
  CHECK (title_translate_status IS NULL OR title_translate_status IN ('pending','done','failed','skipped'));

-- ④ 새 문의 중복 방지 — 같은 화면이 같은 토큰으로 다시 보내면 같은 대화
ALTER TABLE public.general_inquiry_threads
  ADD COLUMN IF NOT EXISTS client_token uuid NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_general_inquiry_threads_client_token
  ON public.general_inquiry_threads (influencer_id, client_token)
  WHERE client_token IS NOT NULL;

-- 열린 대화 세기(상한·뷰)용
CREATE INDEX IF NOT EXISTS idx_general_inquiry_threads_open
  ON public.general_inquiry_threads (influencer_id)
  WHERE status = 'open';

-- ⑤ 주석
COMMENT ON TABLE public.general_inquiry_threads IS
  '[504][507] 서비스 문의(응모 없는 일반 문의) 대화. 회원 한 명이 여러 대화를 가지고, 열린 대화도 여럿일 수 있다(507 — 회원이 여는 것은 상한까지, 508 의 상한 보조 함수). '
  '마지막 글 시각·발신 종류 칸은 없다(뷰 general_inquiry_thread_summary 가 메시지에서 계산). 쓰기는 함수만.';
COMMENT ON COLUMN public.general_inquiry_threads.title IS
  '[507] 문의 제목 — 회원이 새 문의를 열 때 입력(앞뒤 공백을 뗀 1~40자). 옮겨 온 대화·옛 화면이 만든 대화는 비어 있다(화면은 첫 글 미리보기). '
  '운영팀만 고친다(update_general_inquiry_thread_title). 🔴 탈퇴 때 본문과 같은 방침 — 본문 파기 방침이 바뀌면 이 칸과 번역 칸도 같이 지운다(T-3).';
COMMENT ON COLUMN public.general_inquiry_threads.title_translated IS
  '[507] 제목의 한국어 번역(관리자 화면). translate-message 가 웹훅으로 채운다. 비면 화면은 원문만.';
COMMENT ON COLUMN public.general_inquiry_threads.client_token IS
  '[507] 새 문의 화면이 만든 난수 — 같은 토큰이면 같은 대화(재시도·두 번 눌림 방지). 옛 대화는 비어 있다.';

NOTIFY pgrst, 'reload schema';

COMMIT;
