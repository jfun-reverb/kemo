-- ============================================================
-- 504_general_inquiry_threads_table.sql
-- 서비스 문의 「회원 한 명이 여러 대화」 — 데이터 ① 대화 표 + 메시지의 대화 칸
--
-- 사양서: docs/specs/2026-10-06-service-inquiry-threads.md 「설계 · 데이터」 마이그레이션 1
-- 작업표: docs/specs/2026-10-06-service-inquiry-threads-breakdown.md 조각 1
-- 선행: 475(응모 없는 메시지) · 477(옛 응대 완료 표 — 이 파일은 안 건드린다)
-- 다음: 505(옮기기 + 함수 + 검사 제약) → 506(뷰). 🔴 504 만 적용된 채로 두어도 서비스는 그대로 돈다
--       (새 칸·새 표가 비어 있을 뿐 아무 함수도 아직 안 쓴다).
--
-- 편집기 경고: 뜸 — 무해(DROP POLICY IF EXISTS 두 개 — 정책을 지우고 같은 이름으로 다시 만들 뿐)
--
-- 만드는 것
--   ① 표 public.general_inquiry_threads — 대화 한 줄. 마지막 글 시각·발신 종류 칸은 일부러 없다(뷰가 메시지에서 계산)
--   ② 행 단위 보안 켜기 + 정책 둘(회원 본인 조회 · 관리자 조회). 쓰기 정책 없음 — 함수(505)만 쓴다
--   ③ 부분 유일 색인 (influencer_id) WHERE status='open' — 「열린 대화는 회원당 하나」(P-2)를 서버가 강제
--   ④ application_messages.general_thread_id — 대화 삭제 시 메시지도 함께 삭제(CASCADE) + 색인
--
-- ⚠️ 칸은 NULL 허용으로만 더한다. 「응모 칸이 빈 행이면 대화 칸 필수」 검사 제약은 505 맨 끝에서 건다
--    (옮기기가 끝나기 전에 걸면 기존 일반 문의 행이 전부 위반이다).
-- ⚠️ 표 기본 권한은 이 저장소 관례(477·481)대로 따로 건드리지 않는다 — 접근은 행 단위 보안이 막는다.
--    쓰기 정책이 없으므로 anon·authenticated 가 직접 INSERT/UPDATE/DELETE 하면 0행(또는 거부)이다.
-- ⚠️ 닫은 시각·닫은 사람의 이력은 남기지 않는다(마지막 한 번만, 다시 열면 비운다). reopened_count 만 누적.
--
-- ── 적용 전 확인 ──
--   [P1] 표·칸이 아직 없나(재실행 안전 — IF NOT EXISTS 라 있어도 통과):
--     SELECT to_regclass('public.general_inquiry_threads'),
--            (SELECT count(*) FROM information_schema.columns
--              WHERE table_schema='public' AND table_name='application_messages' AND column_name='general_thread_id');
--     기대(최초 적용): NULL, 0
--
-- ── 적용 뒤 검증 조회 (1단계씩) ──
--   [V1] 표 칸:
--     SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='general_inquiry_threads' ORDER BY ordinal_position;
--     기대: id, influencer_id, status, opened_at, closed_at, closed_by, closed_by_name, reopened_count (8칸)
--   [V2] 행 단위 보안·정책:
--     SELECT relrowsecurity FROM pg_class WHERE oid='public.general_inquiry_threads'::regclass;   기대: t
--     SELECT policyname, cmd FROM pg_policies WHERE tablename='general_inquiry_threads' ORDER BY policyname;
--     기대: 2행, 둘 다 SELECT (쓰기 정책 없음)
--   [V3] 색인·제약:
--     SELECT indexname, indexdef FROM pg_indexes
--      WHERE tablename IN ('general_inquiry_threads','application_messages')
--        AND indexname IN ('uq_general_inquiry_threads_one_open','idx_application_messages_general_thread');
--     기대: 2행(앞 것은 WHERE status = 'open' 포함 UNIQUE)
--   [V4] 메시지 칸 + 외래 키 삭제 동작:
--     SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--      WHERE conrelid='public.application_messages'::regclass AND conname='application_messages_general_thread_id_fkey';
--     기대: 1행, ON DELETE CASCADE
--   [V5] 🔴 로그인 브라우저(회원): await db.from('general_inquiry_threads').select('*')  → [] (이 시점엔 대화가 없다). 오류면 정책 문제.
--
-- ── 되돌리는 방법 (505·506 을 먼저 되돌린 뒤) ──
--   supabase/patches/2026-10-06-general-inquiry-threads-rollback.sql 의 [A] 절.
-- ============================================================

BEGIN;

-- ① 대화 표
CREATE TABLE IF NOT EXISTS public.general_inquiry_threads (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id   uuid        NOT NULL
    REFERENCES public.influencers(id) ON DELETE CASCADE,       -- 회원 삭제(관리자 완전 삭제 등) 시 대화도 함께
  status          text        NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','closed')),
  opened_at       timestamptz NOT NULL DEFAULT now(),
  closed_at       timestamptz NULL,
  closed_by       uuid        NULL,                              -- 닫은 관리자 auth id (477 resolved_by 와 같이 외래 키 없음)
  closed_by_name  text        NULL,
  reopened_count  integer     NOT NULL DEFAULT 0,
  -- 열림이면 닫힘 칸이 비고, 닫힘이면 닫은 시각이 있다
  CONSTRAINT general_inquiry_threads_closed_consistent CHECK (
    (status = 'open'   AND closed_at IS NULL)
    OR (status = 'closed' AND closed_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.general_inquiry_threads IS
  '[504] 서비스 문의(응모 없는 일반 문의) 대화. 회원 한 명이 여러 대화를 가진다(열린 대화는 동시에 하나 — 부분 유일 색인). '
  '마지막 글 시각·발신 종류 칸은 없다(뷰 general_inquiry_thread_summary 가 메시지에서 계산). 쓰기는 505 의 함수만.';
COMMENT ON COLUMN public.general_inquiry_threads.reopened_count IS
  '[504] 다시 열린 횟수. 닫은 시각·닫은 사람 이력은 남기지 않고 마지막 한 번만 둔다(다시 열면 closed_* 를 비운다).';

-- ② 행 단위 보안 — 쓰기 정책은 일부러 없다(함수만)
ALTER TABLE public.general_inquiry_threads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "influencer_read_own_general_inquiry_threads" ON public.general_inquiry_threads;
CREATE POLICY "influencer_read_own_general_inquiry_threads"
  ON public.general_inquiry_threads FOR SELECT
  USING (influencer_id = (SELECT auth.uid()));       -- 대화 표엔 본문이 없어 숨김 가드 불필요

DROP POLICY IF EXISTS "admin_read_general_inquiry_threads" ON public.general_inquiry_threads;
CREATE POLICY "admin_read_general_inquiry_threads"
  ON public.general_inquiry_threads FOR SELECT
  USING ((SELECT public.is_admin()));                -- 415 방식 — 행마다 재평가 안 되게 감쌈

-- ③ 열린 대화는 회원당 하나(P-2) — 동시 첫 글이 둘 만들어도 하나는 색인이 거부한다
CREATE UNIQUE INDEX IF NOT EXISTS uq_general_inquiry_threads_one_open
  ON public.general_inquiry_threads (influencer_id)
  WHERE status = 'open';

-- 회원별 대화 목록·「이 회원 대화 N」 조회용
CREATE INDEX IF NOT EXISTS idx_general_inquiry_threads_influencer
  ON public.general_inquiry_threads (influencer_id, opened_at DESC);

-- ④ 메시지 → 대화 참조. 비어 있을 수 있다(응모건 메시지). 대화가 지워지면 메시지도 함께(SET NULL 이면 505 의 검사 제약과 충돌)
ALTER TABLE public.application_messages
  ADD COLUMN IF NOT EXISTS general_thread_id uuid NULL
  REFERENCES public.general_inquiry_threads(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.application_messages.general_thread_id IS
  '[504] 서비스 문의 메시지가 속한 대화. 응모건 메시지는 NULL. 505 맨 끝의 검사 제약 application_messages_general_thread_required 가 '
  '「응모 칸이 빈 행이면 이 칸 필수」를 강제한다. influencer_id 칸은 그대로 남는다(476·482·495 가 읽는다).';

CREATE INDEX IF NOT EXISTS idx_application_messages_general_thread
  ON public.application_messages (general_thread_id, created_at)
  WHERE general_thread_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
