-- ============================================================
-- 556_cs_case_tables.sql
-- CS 이력 관리 — 작업 1-2 (CS 건 표 · 메시지↔건 연결 · 메모 댓글 · 메모 읽음 · 메모 첨부 통)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 4-4 ②·3-a·3-b·3-c · D-9·D-10·D-11·D-12·D-17·D-20
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-2 (S-1·S-2·S-6) · 결정 Q1·Q2
--
-- 이 파일은 표·정책·통만 만든다. 행을 만드는 일(자동 생성 트리거·백필)은 1-3, 조회는 1-4,
-- 쓰기는 1-5 의 서버 함수가 한다 — 그래서 네 표에는 **쓰기 정책이 없다**(정의자 권한 함수만 쓴다).
--
-- 결정
--   Q1(S-1) 원본 대화가 지워져도 CS 건은 통계로 남긴다 — 응모·대화·메시지·회원·캠페인 외래 키는
--       전부 「비우기(SET NULL)」. 앱 건(캠페인 문의·서비스 문의)의 두 원본 칸이 모두 빈 것이 곧
--       「원본 대화 삭제됨」이다(따로 표시 칸을 두지 않는다 — 비우기가 칸을 못 채우므로).
--       응모 행이 실제로 지워지는 길: 캠페인 보관 삭제(255)·관리자 완전 삭제(031)·감사용 청소(480·505)·325.
--   Q2(S-2) 읽기 기준 = 메시지 메뉴 권한 `has_permission('menu.messages','read')` — 메시지 표(`is_admin()`)보다
--       좁다(매니저가 메시지를 숨김으로 두면 CS 도 숨김). `(SELECT …)` 로 감싸 행마다 다시 묻지 않는다(415).
--       ⚠️ 권한 카탈로그 `menu.messages` 의 `server_enforced` 와 권한 화면 「서버 차단」 안내 개수는
--       화면 조각(2-0)에서 함께 고친다 — 이 파일 적용만으로는 화면 배지가 아직 「화면에서만」이다.
--       시드: 207·214(캠페인 관리자·매니저 write) · 268(최고 관리자 write) — 세 등급 모두 행이 있다.
--   S-6 메시지 ↔ 건 연결은 **별도 표**(`cs_case_messages`) — `application_messages` 에 칸을 더하면 회원 조회
--       정책(315·476)이 그 칸도 내보낸다. 기본 키 = 메시지 id 라 「메시지 하나는 건 하나」를 표가 강제한다.
--
-- 확인한 것(2026-10-20, 저장소 검색)
--   [이름 충돌 없음] cs_cases · cs_case_messages · cs_case_comments · cs_case_comment_reads · cs-case-attachments
--     — migrations·dev/·supabase/functions 0건.
--   [메시지 표] application_messages(144) — application_id 는 475 부터 비어 있을 수 있음 · 서비스 문의는
--     general_thread_id(504) → general_inquiry_threads(504). 번역 칸 셋의 값 규칙은 235 와 같게.
--
-- 편집기 경고: 뜸 — 무해(DROP POLICY IF EXISTS 뒤 같은 이름으로 다시 만든다. 지워지는 데이터 없음)
-- 롤백: 파일 하단.
-- ============================================================

-- ── 1. CS 건 ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cs_cases (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_no            bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,   -- 표의 「번호」
  -- 출처: 캠페인 문의 / 서비스 문의(앱 건) · 메일 / LINE / 기타(수기 건)
  source             text        NOT NULL
    CHECK (source IN ('campaign_inquiry','service_inquiry','mail','line','other')),
  application_id     uuid        NULL REFERENCES public.applications(id)            ON DELETE SET NULL,
  general_thread_id  uuid        NULL REFERENCES public.general_inquiry_threads(id) ON DELETE SET NULL,
  influencer_id      uuid        NULL REFERENCES public.influencers(id)             ON DELETE SET NULL,
  campaign_id        uuid        NULL REFERENCES public.campaigns(id)               ON DELETE SET NULL,
  -- 수기용(회원·캠페인을 못 찾았을 때 직접 적은 값 · 시트 ⓒ 줄)
  manual_name           text     NULL,
  manual_email          text     NULL,
  manual_campaign_name  text     NULL,
  manual_category       text     NULL CHECK (manual_category IN ('monitor','gifting','visit','service')),
  -- 항목(lookup_values kind='cs_category' 의 code — 외래 키 없음, 555)
  category_code      text        NULL,
  status             text        NOT NULL DEFAULT 'in_progress'
    CHECK (status IN ('needs_check','in_progress','done')),
  received_at        timestamptz NOT NULL,
  first_reply_at     timestamptz NULL,      -- 수기 건 입력값 전용 — 앱 건은 조회(1-4)가 매번 계산
  completed_at       timestamptz NULL,
  completed_by       uuid        NULL,      -- 완료한 관리자 auth id(외래 키 없음 — 477·504 와 같게)
  completed_by_name  text        NULL,
  -- 대응 안내 내용(D-17) + 번역 칸 셋(235 와 같은 값 규칙)
  response_body               text NULL,
  response_translated         text NULL,
  response_translated_lang    text NULL CHECK (response_translated_lang IN ('ko','ja')),
  response_translate_status   text NULL CHECK (response_translate_status IN ('pending','done','failed','skipped')),
  -- 문의 요약(D-12) — 시작 회원 글 + 요약 글(앱 건은 비어 있으면 시작 글 본문을 보여 준다) + 번역 칸 셋
  summary_message_id          uuid NULL REFERENCES public.application_messages(id) ON DELETE SET NULL,
  summary_body                text NULL,
  summary_translated          text NULL,
  summary_translated_lang     text NULL CHECK (summary_translated_lang IN ('ko','ja')),
  summary_translate_status    text NULL CHECK (summary_translate_status IN ('pending','done','failed','skipped')),
  summary_edited              boolean NOT NULL DEFAULT false,
  -- 수기용 문의·대응 내용(일·한 — D-11)
  manual_inquiry_ja    text NULL,
  manual_inquiry_ko    text NULL,
  manual_response_ja   text NULL,
  manual_response_ko   text NULL,
  previous_case_id     uuid NULL REFERENCES public.cs_cases(id) ON DELETE SET NULL,   -- 재문의(D-6)
  time_unknown         boolean NOT NULL DEFAULT false,                                -- 「시간 미상」(D-8)
  -- 만들어진 경위: 실시간 / 과거 이관(백필) / 시트 이관(D-8 ⓑ·ⓒ) — 담당자 칸 표시의 근거
  origin               text    NOT NULL DEFAULT 'live' CHECK (origin IN ('live','backfill','sheet')),
  created_by           uuid    NULL,        -- 만든 관리자(자동 행·백필은 비움)
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  version              integer NOT NULL DEFAULT 1,     -- 쓰기 함수(1-5)의 낙관적 잠금
  -- 개인정보 칸(이름·이메일·요약·대응 안내·수기 문의/대응 + 번역)을 비운 시각 — 탈퇴 파기(4-1)·
  --   수기 3년(1-6)·원본 삭제 연동이 찍는다. 비운 뒤에도 항목·시각은 통계로 남는다
  personal_purged_at   timestamptz NULL,

  -- 원본 칸: 캠페인 문의는 응모만 · 서비스 문의는 대화만(둘 다 빈 것 = 원본 삭제됨, Q1) · 수기는 둘 다 없음
  CONSTRAINT cs_cases_source_link CHECK (
       (source = 'campaign_inquiry' AND general_thread_id IS NULL)
    OR (source = 'service_inquiry'  AND application_id    IS NULL)
    OR (source IN ('mail','line','other') AND application_id IS NULL AND general_thread_id IS NULL)
  ),
  -- 완료면 항목·완료 시각 필수(대응 안내 내용은 화면에서만 필수 — 백필·시트 출신 완료 건은 빌 수 있다)
  CONSTRAINT cs_cases_done_requires CHECK (
    status <> 'done' OR (category_code IS NOT NULL AND completed_at IS NOT NULL)
  ),
  -- 완료가 아니면 완료 칸이 비어 있다(다시 열기는 지운다 — 4-2)
  CONSTRAINT cs_cases_open_has_no_completion CHECK (
    status = 'done' OR (completed_at IS NULL AND completed_by IS NULL AND completed_by_name IS NULL)
  ),
  CONSTRAINT cs_cases_not_self_previous CHECK (previous_case_id IS NULL OR previous_case_id <> id),
  -- 글자 수 상한(쓰기 함수도 검사하지만 표가 마지막 방어선)
  CONSTRAINT cs_cases_text_len CHECK (
        char_length(coalesce(response_body, ''))       <= 10000
    AND char_length(coalesce(response_translated, '')) <= 10000
    AND char_length(coalesce(summary_body, ''))        <= 10000
    AND char_length(coalesce(summary_translated, ''))  <= 10000
    AND char_length(coalesce(manual_inquiry_ja, ''))   <= 10000
    AND char_length(coalesce(manual_inquiry_ko, ''))   <= 10000
    AND char_length(coalesce(manual_response_ja, ''))  <= 10000
    AND char_length(coalesce(manual_response_ko, ''))  <= 10000
    AND char_length(coalesce(manual_name, ''))         <= 200
    AND char_length(coalesce(manual_email, ''))        <= 320
    AND char_length(coalesce(manual_campaign_name, '')) <= 500
  )
);

COMMENT ON TABLE public.cs_cases IS
  '[556] CS 건 — 앱 대화 자동 1행(1-3) + 「CS 추가」 + 메일·LINE 수기 등록. 쓰기는 정의자 권한 함수만(1-3·1-5). '
  '앱 건의 원본 칸(응모·대화)이 둘 다 비면 원본 대화가 지워진 것(통계로 남김 — Q1).';
COMMENT ON COLUMN public.cs_cases.first_reply_at IS
  '[556] 수기 건 입력값 전용. 앱 건은 조회 함수가 「접수 뒤 첫 운영팀 글」(일괄 발송·숨김·회수 제외)로 매번 계산한다(4-3).';
COMMENT ON COLUMN public.cs_cases.summary_body IS
  '[556] 저장된 요약 글. 앱 건은 비어 있으면 summary_message_id 의 본문을 쓴다(D-12). 수기·시트 출신은 첫 줄을 저장한다.';

CREATE INDEX IF NOT EXISTS idx_cs_cases_application   ON public.cs_cases (application_id)    WHERE application_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_thread        ON public.cs_cases (general_thread_id) WHERE general_thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_influencer    ON public.cs_cases (influencer_id)     WHERE influencer_id     IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_received      ON public.cs_cases (received_at DESC);
-- 원본 행이 지워질 때 비우기(SET NULL)가 표를 통째로 훑지 않게(캠페인 보관 삭제는 응모·메시지를 수백 건 지운다)
CREATE INDEX IF NOT EXISTS idx_cs_cases_campaign      ON public.cs_cases (campaign_id)        WHERE campaign_id        IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_summary_msg   ON public.cs_cases (summary_message_id) WHERE summary_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_previous      ON public.cs_cases (previous_case_id)   WHERE previous_case_id   IS NOT NULL;
-- 「그 대화의 열린 건」 찾기(1-3 트리거가 회원 글마다 부른다)
CREATE INDEX IF NOT EXISTS idx_cs_cases_open_by_app    ON public.cs_cases (application_id, received_at DESC)
  WHERE status <> 'done' AND application_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cs_cases_open_by_thread ON public.cs_cases (general_thread_id, received_at DESC)
  WHERE status <> 'done' AND general_thread_id IS NOT NULL;

-- updated_at 은 고칠 때마다(쓰기 함수가 빠뜨려도)
CREATE OR REPLACE FUNCTION public._cs_cases_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._cs_cases_touch_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._cs_cases_touch_updated_at() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_cs_cases_updated_at ON public.cs_cases;
CREATE TRIGGER trg_cs_cases_updated_at
  BEFORE UPDATE ON public.cs_cases
  FOR EACH ROW EXECUTE FUNCTION public._cs_cases_touch_updated_at();

-- ── 2. 메시지 ↔ 건 연결(S-6) ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.cs_case_messages (
  message_id  uuid        PRIMARY KEY REFERENCES public.application_messages(id) ON DELETE CASCADE,
  case_id     uuid        NOT NULL    REFERENCES public.cs_cases(id)             ON DELETE CASCADE,
  linked_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.cs_case_messages IS
  '[556] 회원 글이 속한 CS 건. 기본 키 = 메시지 id → 메시지 하나는 건 하나에만(D-12). 운영팀 글은 넣지 않는다.';
CREATE INDEX IF NOT EXISTS idx_cs_case_messages_case ON public.cs_case_messages (case_id);

-- ── 3. 메모 댓글(D-11) ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cs_case_comments (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id            uuid        NOT NULL REFERENCES public.cs_cases(id) ON DELETE CASCADE,
  parent_id          uuid        NULL REFERENCES public.cs_case_comments(id) ON DELETE CASCADE,  -- 답글이면 원 메모(한 단계만 — 1-5 가 검사)
  author_id          uuid        NULL REFERENCES auth.users(id) ON DELETE SET NULL,              -- 시트 이관이면 비움
  author_name        text        NULL,                                                          -- 지워진 관리자 이름 보존(297 과 같게)
  origin             text        NOT NULL DEFAULT 'direct' CHECK (origin IN ('direct','sheet')),
  body               text        NOT NULL DEFAULT '' CHECK (char_length(body) <= 5000),
  attachments        jsonb       NOT NULL DEFAULT '[]'::jsonb,                                 -- [{path, name, size, mime}] — 메시지 첨부와 같은 꼴
  translated         text        NULL,
  translated_lang    text        NULL CHECK (translated_lang IN ('ko','ja')),
  translate_status   text        NULL CHECK (translate_status IN ('pending','done','failed','skipped')),
  deleted_at         timestamptz NULL,                                                          -- 내 글 지우기(1-5) — 행은 남기고 표시만
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cs_case_comments_not_empty CHECK (deleted_at IS NOT NULL OR btrim(body) <> '' OR attachments <> '[]'::jsonb),
  CONSTRAINT cs_case_comments_not_self_parent CHECK (parent_id IS NULL OR parent_id <> id)
);
COMMENT ON TABLE public.cs_case_comments IS
  '[556] CS 건의 담당자 메모 댓글(회원에게 안 보인다 — 메시지 표와 따로 둔 이유). 쓰기·지우기는 1-5 함수만.';
CREATE INDEX IF NOT EXISTS idx_cs_case_comments_case   ON public.cs_case_comments (case_id, created_at);
CREATE INDEX IF NOT EXISTS idx_cs_case_comments_parent ON public.cs_case_comments (parent_id) WHERE parent_id IS NOT NULL;

-- ── 4. 메모 읽음(D-20 — 오리엔시트 메모 읽음 297·298 방식) ─────────
CREATE TABLE IF NOT EXISTS public.cs_case_comment_reads (
  comment_id     uuid        NOT NULL REFERENCES public.cs_case_comments(id) ON DELETE CASCADE,
  admin_auth_id  uuid        NOT NULL,
  read_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (comment_id, admin_auth_id)
);
COMMENT ON TABLE public.cs_case_comment_reads IS
  '[556] 관리자별 메모 읽음. 읽음 처리는 건 단위 함수(1-5), 안 읽은 수는 요약 함수(1-4 — 본인 글 제외, COALESCE).';

-- ── 5. 행 단위 보안 — 읽기만, 메시지 메뉴 권한(Q2). 쓰기 정책은 일부러 없다 ──
ALTER TABLE public.cs_cases              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cs_case_messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cs_case_comments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cs_case_comment_reads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cs_cases_select" ON public.cs_cases;
CREATE POLICY "cs_cases_select" ON public.cs_cases
  FOR SELECT TO authenticated
  USING ((SELECT public.has_permission('menu.messages', 'read')));

DROP POLICY IF EXISTS "cs_case_messages_select" ON public.cs_case_messages;
CREATE POLICY "cs_case_messages_select" ON public.cs_case_messages
  FOR SELECT TO authenticated
  USING ((SELECT public.has_permission('menu.messages', 'read')));

DROP POLICY IF EXISTS "cs_case_comments_select" ON public.cs_case_comments;
CREATE POLICY "cs_case_comments_select" ON public.cs_case_comments
  FOR SELECT TO authenticated
  USING ((SELECT public.has_permission('menu.messages', 'read')));

-- 읽음은 본인 것만 보인다(남의 읽음 여부는 요약 함수가 필요 없다)
DROP POLICY IF EXISTS "cs_case_comment_reads_select" ON public.cs_case_comment_reads;
CREATE POLICY "cs_case_comment_reads_select" ON public.cs_case_comment_reads
  FOR SELECT TO authenticated
  USING (admin_auth_id = (SELECT auth.uid()) AND (SELECT public.has_permission('menu.messages', 'read')));

-- 표 권한도 읽기만(쓰기 권한이 남아 있으면 정책 추가 실수 한 번에 열린다)
REVOKE ALL ON public.cs_cases, public.cs_case_messages,
  public.cs_case_comments, public.cs_case_comment_reads FROM anon, authenticated;
GRANT SELECT ON public.cs_cases, public.cs_case_messages,
  public.cs_case_comments, public.cs_case_comment_reads TO authenticated;

-- ── 6. 메모 첨부 통(비공개, 관리자만 — D-11) ─────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'cs-case-attachments',
  'cs-case-attachments',
  false,        -- 🔴 비공개 — 화면은 서명 주소로 연다
  10485760,     -- 10 MB(메시지 첨부와 같은 한도)
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 읽기·올리기: 메시지 메뉴 권한. 덮어쓰기·지우기 정책은 없다 — 지우는 일은 서버(1-6·4-1, 서비스 키)만.
--   올리기를 'read' 로 둔 이유: D-9 「메시지를 볼 수 있으면 CS 도 보고 고친다」 — 쓰기 함수(1-5)와 같은 기준을 쓴다.
--   ⚠️ 올리기는 upsert:false 로(덮어쓰기 정책이 없어 upsert:true 면 막힌다 — 472 와 같은 성질)
DROP POLICY IF EXISTS "cs_case_attachments_select" ON storage.objects;
CREATE POLICY "cs_case_attachments_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'cs-case-attachments' AND (SELECT public.has_permission('menu.messages', 'read')));

DROP POLICY IF EXISTS "cs_case_attachments_insert" ON storage.objects;
CREATE POLICY "cs_case_attachments_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'cs-case-attachments' AND (SELECT public.has_permission('menu.messages', 'read')));

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후)
-- ============================================================
/*
-- [V1] 네 표 + 행 보안 켜짐
SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN ('cs_cases','cs_case_messages','cs_case_comments','cs_case_comment_reads') ORDER BY relname;

-- [V2] 정책 — 표마다 SELECT 하나 + 통 둘
SELECT tablename, policyname, cmd FROM pg_policies
WHERE policyname LIKE 'cs_case%' OR policyname LIKE 'cs_cases%' ORDER BY tablename, policyname;

-- [V3] 표 권한 — authenticated 는 SELECT 만, anon 은 없음
SELECT table_name, grantee, string_agg(privilege_type, ',' ORDER BY privilege_type)
FROM information_schema.role_table_grants
WHERE table_name LIKE 'cs_case%' AND grantee IN ('anon','authenticated')
GROUP BY 1,2 ORDER BY 1,2;

-- [V4] 검사 제약 — 아래 각각 실패해야 한다(트랜잭션 안에서 rollback)
-- INSERT INTO public.cs_cases (source, received_at, application_id, general_thread_id) VALUES ('campaign_inquiry', now(), NULL, gen_random_uuid());  -- 외래 키 또는 source_link
-- INSERT INTO public.cs_cases (source, received_at, status) VALUES ('mail', now(), 'done');   -- done_requires
-- INSERT INTO public.cs_cases (source, received_at, completed_at) VALUES ('mail', now(), now());  -- open_has_no_completion
-- 통과해야 하는 것: INSERT INTO public.cs_cases (source, received_at, manual_name) VALUES ('mail', now(), '시험');

-- [V5] 관리자 세션 콘솔(로그인 브라우저)에서: db.from('cs_cases').select('id').limit(1) → 오류 없이 [] ·
--      db.from('cs_cases').insert({source:'mail', received_at:new Date().toISOString()}) → 권한 오류(42501)
*/

-- ============================================================
-- 롤백 (CS 건 행이 생기기 전에만 — 1-3 백필 전에)
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(표·통 정책·트리거 삭제)
-- DROP POLICY IF EXISTS "cs_case_attachments_select" ON storage.objects;
-- DROP POLICY IF EXISTS "cs_case_attachments_insert" ON storage.objects;
-- -- 통은 비어 있을 때만: DELETE FROM storage.buckets WHERE id = 'cs-case-attachments';
-- DROP TABLE IF EXISTS public.cs_case_comment_reads;
-- DROP TABLE IF EXISTS public.cs_case_comments;
-- DROP TABLE IF EXISTS public.cs_case_messages;
-- DROP TABLE IF EXISTS public.cs_cases;
-- DROP FUNCTION IF EXISTS public._cs_cases_touch_updated_at();
