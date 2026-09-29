-- ============================================================
-- 476_general_inquiry_policies.sql
-- 일반 문의 창구 — 데이터 모델 ② 새 접근 정책 4개 (전부 회원용) + 보조 함수 1개
--
-- 사양서: docs/specs/2026-05-21-general-inquiry-desk.md §5-4 ①②⑥ · §5-5 ② · §5-6 ②
-- 작업표: docs/specs/2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ②)
-- 선행: 475 (influencer_id 칸)
--
-- 만드는 것
--   표 application_messages : influencer_read_own_general_inquiry_messages (조회)
--   저장소 storage.objects   : msg_attachments_general_influencer_select (내려받기)
--                              msg_attachments_general_influencer_insert (올리기)
--                              msg_attachments_general_influencer_delete (삭제)
--   보조 함수 public._general_inquiry_path_is_own(text) — 삭제 정책이 부른다(아래 ⚠️)
--
-- 🔴 정책은 같은 표·같은 동작이면 「또는」으로 합쳐진다. 그래서 새 정책은
--    ① 「application_id IS NULL」(응모건 메시지가 이 경로로 읽히지 않게)
--    ② 「influencer_id = 로그인 회원」(남의 일반 문의가 읽히지 않게)
--    두 조건을 **함께** 건다(사양서 5-4 ①). 조회·내려받기에는 숨김·회수 가드도 똑같이 붙인다.
-- 🔴 기존 정책 문장은 한 글자도 편집하지 않는다(5-4 ②) — 315·144 정책은 그대로.
-- 관리자용 새 정책은 없다 — 관리자는 표 조회 정책(415)에 응모 조건이 없고, 저장소 기존 네 정책이
--    관리자를 경로와 무관하게 통과시키므로 general/ 첨부도 이미 열린다(사양서 §13-1).
--
-- ⚠️ 삭제 정책이 보조 함수를 쓰는 이유(사양서가 「본인 메시지에 담김」 조건을 요구하는데,
--    그대로 EXISTS 로 쓰면 죽는다):
--    회원 회수는 순서가 「① withdraw_own_message 로 표에 회수 표시 → ② 저장소에서 파일 삭제」다
--    (dev/lib/storage.js withdrawOwnMessage). ②가 도는 시점에 그 메시지는 이미 회수 표시가 돼 있어
--    새 조회 정책(숨김·회수 가드)이 그 행을 **가린다** — 정책 안에서 표를 직접 읽는 EXISTS 는 그 행을
--    못 찾아 삭제가 거부되고, 회수한 사진이 저장소에 남는다(개인정보). 그래서 행 단위 보안을 우회하는
--    (SECURITY DEFINER) 판정 함수 하나에 맡긴다. 이 함수는 「로그인한 본인 경로인가」만 참/거짓으로
--    돌려주므로 남의 정보를 내보내지 않는다.
--    · 판정: 응모 없음 + 본인이 **보낸**(sender_id) 메시지의 첨부 경로 중 하나일 것.
--      (운영팀이 보낸 첨부를 회원이 지우는 것은 막는다 — 144 는 본인 폴더 전체를 허용했다.)
--    · 숨김·회수 조건은 일부러 없다(회수 도중에 도는 정책이라).
--    · ⚠️ 결과: 사진을 올리고 **보내지 않은**(메시지에 안 담긴) 파일은 회원이 못 지운다.
--      화면이 그 경우 삭제를 시도하면 조용히 거부된다 — 보고서 「결정이 필요한 곳」 참조.
--
-- ── 적용 뒤 검증 (1단계씩) ──
--   [V1] 정책 4개가 생겼나:
--     SELECT schemaname, tablename, policyname, cmd FROM pg_policies
--      WHERE policyname IN ('influencer_read_own_general_inquiry_messages',
--        'msg_attachments_general_influencer_select','msg_attachments_general_influencer_insert',
--        'msg_attachments_general_influencer_delete') ORDER BY policyname;
--     기대: 4행(public.application_messages SELECT 1개 + storage.objects SELECT/INSERT/DELETE 3개)
--   [V2] 기존 정책이 그대로인가(문장 무편집 확인 — 이름이 살아 있고 응모 조건이 그대로):
--     SELECT policyname, qual FROM pg_policies
--      WHERE tablename='application_messages' AND policyname IN
--        ('influencer_read_own_application_messages','admin_read_all_messages');
--     기대: 2행, 첫째 qual 에 applications 참조가 그대로
--   [V3] 보조 함수 권한(맨 앞 =X/ 없어야 함 = PUBLIC 회수됨, anon 없음, authenticated 있음):
--     SELECT p.proacl::text FROM pg_proc p
--      WHERE p.pronamespace='public'::regnamespace AND p.proname='_general_inquiry_path_is_own';
--   [V4] 🔴 로그인 브라우저(회원 계정): 일반 문의 첨부 올리기·내려받기·회수 뒤 삭제가 실제로 되는지,
--        다른 회원 폴더(general/{남의id}/…)와 응모건 폴더는 안 되는지. 서비스 키(SQL 편집기)로는 재현 불가.
--
-- ── 되돌리는 방법 ──
--   BEGIN;
--     DROP POLICY IF EXISTS "msg_attachments_general_influencer_delete" ON storage.objects;
--     DROP POLICY IF EXISTS "msg_attachments_general_influencer_insert" ON storage.objects;
--     DROP POLICY IF EXISTS "msg_attachments_general_influencer_select" ON storage.objects;
--     DROP POLICY IF EXISTS "influencer_read_own_general_inquiry_messages" ON public.application_messages;
--     DROP FUNCTION IF EXISTS public._general_inquiry_path_is_own(text);
--   COMMIT;
-- ============================================================

BEGIN;

-- ── 보조 함수: 「이 저장소 경로가 로그인 회원 본인이 보낸 일반 문의 메시지의 첨부인가」 ──
CREATE OR REPLACE FUNCTION public._general_inquiry_path_is_own(p_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM public.application_messages m,
           jsonb_array_elements(m.attachments) AS att
     WHERE m.application_id IS NULL
       AND m.influencer_id = auth.uid()
       AND m.sender_id     = auth.uid()
       AND att ->> 'path'  = p_path
  );
$fn$;

COMMENT ON FUNCTION public._general_inquiry_path_is_own(text) IS
  '[476] 저장소 삭제 정책 전용 — 로그인 회원 본인이 보낸 일반 문의 메시지의 첨부 경로인지(참/거짓만). '
  '회수 도중(회수 표시 뒤)에도 참이어야 해서 행 단위 보안을 우회한다(SECURITY DEFINER). 숨김·회수 조건 없음.';

REVOKE ALL ON FUNCTION public._general_inquiry_path_is_own(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._general_inquiry_path_is_own(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public._general_inquiry_path_is_own(text) TO authenticated;

-- ── ① 표 조회 — 본인의 일반 문의 메시지 중 숨김·회수되지 않은 행만 ──
DROP POLICY IF EXISTS "influencer_read_own_general_inquiry_messages" ON public.application_messages;
CREATE POLICY "influencer_read_own_general_inquiry_messages"
  ON public.application_messages FOR SELECT
  USING (
    application_id IS NULL                      -- 🔴 응모건 메시지는 이 정책으로 안 읽힌다
    AND influencer_id = (SELECT auth.uid())     -- 🔴 남의 일반 문의는 안 읽힌다
    AND hidden_by_admin_at IS NULL              -- 숨김·회수 가드(315 와 같은 조항)
    AND self_withdrawn_at  IS NULL
  );

COMMENT ON POLICY "influencer_read_own_general_inquiry_messages" ON public.application_messages IS
  '[476] 일반 문의(응모 없는 메시지) 본인 행만 직접 조회. 두 조건(응모 없음 + 본인) 필수, 숨김·회수 가드 포함. '
  '기존 influencer_read_own_application_messages(315)는 무편집. 화면은 get_general_inquiry_messages 함수를 쓴다.';

-- ── ② 첨부 내려받기 — 경로 「general/{본인id}/…」 + 본인 일반 문의 메시지에 실려 있고 숨김·회수 안 됨 ──
DROP POLICY IF EXISTS "msg_attachments_general_influencer_select" ON storage.objects;
CREATE POLICY "msg_attachments_general_influencer_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (storage.foldername(name))[1] = 'general'                          -- 첫 조각은 글자 general (응모 id 는 UUID 라 절대 안 겹침)
    AND (storage.foldername(name))[2] = (SELECT auth.uid())::text          -- 둘째 조각 = 본인
    AND EXISTS (
      SELECT 1
        FROM public.application_messages m
       WHERE m.application_id IS NULL
         AND m.influencer_id = (SELECT auth.uid())
         AND m.hidden_by_admin_at IS NULL                                   -- 315 와 같은 숨김·회수 가드
         AND m.self_withdrawn_at  IS NULL
         AND EXISTS (                                                       -- 이 파일이 그 메시지의 첨부로 등록돼 있는지
           SELECT 1 FROM jsonb_array_elements(m.attachments) AS att
            WHERE att ->> 'path' = name
         )
    )
  );

COMMENT ON POLICY "msg_attachments_general_influencer_select" ON storage.objects IS
  '[476] 일반 문의 첨부 내려받기(회원용). 경로 general/{본인id}/… 이고 본인 일반 문의 메시지의 첨부로 등록돼 있으며 '
  '숨김·회수되지 않았을 때만. 기존 msg_attachments_influencer_select(315)는 무편집. 관리자는 기존 정책이 경로 무관 통과.';

-- ── ③ 첨부 올리기 — 경로 두 조각만 본다(올리는 순간엔 메시지 행이 아직 없다) ──
DROP POLICY IF EXISTS "msg_attachments_general_influencer_insert" ON storage.objects;
CREATE POLICY "msg_attachments_general_influencer_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'application-message-attachments'
    AND (storage.foldername(name))[1] = 'general'
    AND (storage.foldername(name))[2] = (SELECT auth.uid())::text
  );

COMMENT ON POLICY "msg_attachments_general_influencer_insert" ON storage.objects IS
  '[476] 일반 문의 첨부 올리기(회원용). 경로 general/{본인id}/… 두 조각만 검사(메시지가 아직 없다). '
  '기존 msg_attachments_insert(144)는 무편집. 관리자는 기존 정책이 경로 무관 통과.';

-- ── ④ 첨부 삭제 — 회수 도중에 도는 정책 (숨김·회수 조건 없음, 보조 함수로 판정) ──
DROP POLICY IF EXISTS "msg_attachments_general_influencer_delete" ON storage.objects;
CREATE POLICY "msg_attachments_general_influencer_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (storage.foldername(name))[1] = 'general'
    AND (storage.foldername(name))[2] = (SELECT auth.uid())::text
    AND public._general_inquiry_path_is_own(name)     -- 본인이 보낸 일반 문의 메시지의 첨부일 것
  );

COMMENT ON POLICY "msg_attachments_general_influencer_delete" ON storage.objects IS
  '[476] 일반 문의 첨부 삭제(회원용, 본인 회수 직후 파일 삭제). 경로 general/{본인id}/… + 본인이 보낸 일반 문의 메시지의 '
  '첨부일 것(_general_inquiry_path_is_own). 숨김·회수 조건은 일부러 없다(회수 도중에 돌므로). '
  '기존 msg_attachments_delete(144)는 무편집.';

NOTIFY pgrst, 'reload schema';

COMMIT;
