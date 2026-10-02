-- ============================================================
-- 475_general_inquiry_messages_influencer_id.sql
-- 일반 문의 창구(응모건에 매이지 않는 회원↔운영팀 메시지) — 데이터 모델 ①
--
-- 사양서: docs/specs/2026-05-21-general-inquiry-desk.md §5-4 · §5-5 ①
-- 작업표: docs/specs/2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ①)
--
-- 목적:
--   application_messages 를 재사용해 「응모 없는 메시지」를 담는다(D안).
--     ① influencer_id 칸 추가 — 이 메시지가 어느 회원의 문의 대화인가
--        (ON DELETE CASCADE: delete_admin_completely(253)가 influencers 행을
--         직접 지우므로, 없으면 관리자 완전 삭제가 막힌다)
--     ② application_id 의 NOT NULL 해제 — 일반 문의는 응모가 없다
--     ③ 검사 제약 「응모 번호와 회원 번호 중 정확히 하나만」 —
--        둘 다 비었거나 둘 다 찬 「주인 없는/주인 둘인 글」 차단(2026-09-29 사용자 결정)
--     ④ 조회용 부분 색인
--
-- 베이스: application_messages 구조 = 144 + 175(broadcast_id) + 235(번역 3칸)
--         + 368(attachments_purged_at). 이 파일은 표 구조만 더하고 어떤 함수·정책도 안 건드린다.
--
-- 🔴 백필 없음 — 기존 행에 influencer_id 를 채우지 않는다(사양서 5-4 ①).
--    기존 행은 전부 application_id 만 차 있어 ③ 을 통과한다.
-- ⚠️ 이 파일 하나만 적용하면 「응모 없는 행」이 생길 수 있게 될 뿐 아무도 넣지 못한다
--    (넣는 함수는 478). 다만 479(관리자 안읽음 집계 방어 조건)는 **같은 배포**에 넣는다 —
--    행이 생기기 시작하는 순간 그 집계가 NULL 묶음 유령 행을 낸다.
-- ⚠️ 운영 중인 표의 제약을 바꾸는 일이다. 적용 뒤 기존 경로(응모건 메시지 발송·조회·읽음·회수)를
--    로그인 브라우저에서 실제로 한 번씩 써 볼 것(사양서 §9 검증 9).
--
-- ── 적용 전 확인 (반드시 0 이어야 한다 — 0 이 아니면 적용하지 말고 보고) ──
--   [P1] 제약 ③ 을 어길 기존 행:
--     SELECT count(*) FROM public.application_messages
--      WHERE num_nonnulls(application_id, influencer_id) <> 1;
--     ⚠️ 적용 전에는 influencer_id 칸이 아직 없어 이 조회가 오류(칸 없음)가 난다 —
--        그때는 대신 이것을 본다(기존 행은 application_id 가 NOT NULL 이므로 항상 0):
--     SELECT count(*) FROM public.application_messages WHERE application_id IS NULL;
--     기대: 0
--   [P2] 적용 전 전체 행 수(적용 뒤 같아야 함):
--     SELECT count(*) FROM public.application_messages;
--
-- ── 적용 뒤 검증 조회 (1단계씩) ──
--   [V1] 칸·NOT NULL 해제:
--     SELECT column_name, is_nullable, data_type
--       FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='application_messages'
--        AND column_name IN ('application_id','influencer_id');
--     기대: application_id YES / influencer_id YES(uuid)
--   [V2] 제약·색인:
--     SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--      WHERE conrelid='public.application_messages'::regclass
--        AND conname IN ('application_messages_owner_exactly_one','application_messages_influencer_id_fkey');
--     기대: 2행(제약 정의에 num_nonnulls / 외래 키에 ON DELETE CASCADE)
--   [V3] 전체 행 수가 [P2] 와 같고, 위반 0:
--     SELECT count(*), count(*) FILTER (WHERE num_nonnulls(application_id, influencer_id) <> 1)
--       FROM public.application_messages;
--     기대: 앞은 [P2] 와 같고 뒤는 0
--   [V4] 🔴 로그인 브라우저: 응모건 메시지를 보내고·읽고·회수해 본다(제약 완화 뒤 기존 경로 확인).
--
-- ── 되돌리는 방법 ──
--   ⚠️ 일반 문의 행(application_id IS NULL)이 한 건이라도 생긴 뒤에는 ②의 되돌리기가
--      실패한다 — 그 행을 먼저 지워야 한다(지우면 문의 내용이 사라진다).
--   BEGIN;
--     -- 476~482 를 먼저 되돌린 뒤에 아래를 실행(정책·함수·뷰가 이 칸을 읽는다)
--     DELETE FROM public.application_messages WHERE application_id IS NULL;
--     ALTER TABLE public.application_messages DROP CONSTRAINT IF EXISTS application_messages_owner_exactly_one;
--     DROP INDEX IF EXISTS public.idx_application_messages_general_inquiry;
--     ALTER TABLE public.application_messages ALTER COLUMN application_id SET NOT NULL;
--     ALTER TABLE public.application_messages DROP COLUMN IF EXISTS influencer_id;
--   COMMIT;
-- ============================================================

BEGIN;

-- ① 칸 추가 — 응모 없는 메시지의 주인(회원). 기존 행은 NULL 그대로(백필 금지).
ALTER TABLE public.application_messages
  ADD COLUMN IF NOT EXISTS influencer_id uuid NULL
  REFERENCES public.influencers(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.application_messages.influencer_id IS
  '[475] 일반 문의(응모에 매이지 않는 메시지)의 주인 회원. application_id 와 정확히 하나만 채워진다'
  '(검사 제약 application_messages_owner_exactly_one). 응모건 메시지 행은 NULL. '
  '🔴 기존 행에 백필하지 않는다 — 새 정책(476)이 「application_id IS NULL AND influencer_id = 본인」 두 조건으로 읽힌다.';

-- ② 응모 식별자를 필수 아님으로 — 외래 키(ON DELETE CASCADE)·기존 색인은 그대로.
ALTER TABLE public.application_messages
  ALTER COLUMN application_id DROP NOT NULL;

-- ④ 일반 문의 대화 조회용 부분 색인 — 응모건 행에는 영향 없음.
CREATE INDEX IF NOT EXISTS idx_application_messages_general_inquiry
  ON public.application_messages (influencer_id, created_at)
  WHERE application_id IS NULL;

-- ③ 「정확히 하나」 검사 제약 — NOT VALID 없이 건다(기존 행 전부 통과 확인은 [P1]).
--    이미 있으면(재실행) 건너뛴다.
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.application_messages'::regclass
       AND conname = 'application_messages_owner_exactly_one'
  ) THEN
    ALTER TABLE public.application_messages
      ADD CONSTRAINT application_messages_owner_exactly_one
      CHECK (num_nonnulls(application_id, influencer_id) = 1);
  END IF;
END
$do$;

COMMENT ON CONSTRAINT application_messages_owner_exactly_one ON public.application_messages IS
  '[475] 메시지의 주인은 응모(application_id) 또는 회원(influencer_id) 중 정확히 하나. '
  '둘 다 비거나 둘 다 찬 글을 막는다(일반 문의 창구, 2026-09-29 사용자 결정).';

NOTIFY pgrst, 'reload schema';

COMMIT;
