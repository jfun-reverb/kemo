-- ============================================================
-- 315_application_messages_influencer_hidden_guard.sql
-- 전수조사 후속 조치 묶음 E — E-6: 숨김·회수한 메시지를 인플루언서가
-- 표(application_messages)를 직접 조회해도 원문 그대로 못 읽게 한다.
--
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §1-6
--   "메시지 조회 정책이 행 가시성만 보고, 가림 처리는 조회 함수 안에만
--    있다. 표를 직접 부르면 그 분기를 안 거친다. 첨부도 저장소 정책이
--    「본인 응모 폴더면 허용」이라 다시 받을 수 있다."
-- 조치 계획: docs/specs/2026-08-07-audit-remediation-plan.md 묶음 E, E-6
--
-- ────────────────────────────────────────────────────────────
-- 재정의 기준 (전수 grep)
-- ────────────────────────────────────────────────────────────
-- "influencer_read_own_application_messages" / "msg_attachments_influencer_select"
-- 를 정의·변경한 마이그레이션을 전수 grep 한 결과, 둘 다 **144(최초 생성)가
-- 유일하고 가장 큰 번호의 정의**다(137 은 application_messages 표가 생기기
-- 전이라 손대지 않았고, 145·167 등 후속 파일도 재정의하지 않는다). 144 를
-- 기준으로 삼는다.
--
-- ────────────────────────────────────────────────────────────
-- 지금 무엇이 뚫려 있는가
-- ────────────────────────────────────────────────────────────
-- 1) 표 자체(application_messages) — influencer_read_own_application_messages
--    (144:113-121)은 "이 응모건이 내 것인가"만 본다. hidden_by_admin_at·
--    self_withdrawn_at 은 전혀 안 본다. get_application_messages RPC(SECURITY
--    DEFINER, owner=postgres role 이라 BYPASSRLS)만 이 두 칸을 보고 body를
--    NULL 로 마스킹한다(144:889-905) — RPC 를 안 거치고
--    `db.from('application_messages').select()` 로 직접 부르면 마스킹이
--    통째로 빠진다.
--
-- 2) 첨부 파일(Storage) — 첨부는 DB row 마스킹과 별개 저장소다. 업로드 경로는
--    `{application_id}/{난수}.jpg`(dev/lib/storage.js:3168-3178,
--    uploadMessageAttachment — 144 헤더 주석의 "{application_id}/{message_id}/
--    {filename}" 컨벤션은 실제 구현과 다르다, 실측 기준으로 이 마이그레이션을
--    작성함). 다운로드 정책 msg_attachments_influencer_select(144:723-738)는
--    "이 응모건이 내 것인가"만 보고, 그 파일이 어느 메시지의 첨부인지·그
--    메시지가 숨김/회수됐는지는 안 본다. 관리자가 강제 숨김(hide_application_
--    message, 145)해도 파일은 저장소에서 지워지지 않는다(145:399-433 확인 —
--    DB 플래그만 세운다) → 인플루언서가 숨겨지기 전에 알아 둔 경로를 다시
--    쓰면 그대로 다운로드된다.
--
-- ────────────────────────────────────────────────────────────
-- 어느 방식을 골랐나 — "정책을 좁히는 방식" vs "본문 열을 함수로만 읽게
-- 하는 방식"
-- ────────────────────────────────────────────────────────────
-- **정책을 좁히는 방식을 택했다.** 이유:
--   - get_application_messages RPC 는 owner(postgres role)가 BYPASSRLS 를
--     가지고 있어(144:128 주석) **RLS 정책을 어떻게 바꿔도 전혀 영향받지
--     않는다** — 화면이 실제로 쓰는 유일한 경로(dev/js/messaging.js)는
--     이 RPC 뿐이므로, 정책을 좁혀도 화면 동작은 100% 그대로다.
--   - "본문 열을 함수로만 읽게" 하려면 컬럼 단위 권한(REVOKE ... (body))을
--     걸어야 하는데, PostgREST 는 SELECT 요청 시 명시적으로 열을 지정하지
--     않으면 컬럼 권한 오류로 그 행 전체 조회가 실패한다 — 화면이 아직
--     안 쓰는 컬럼 하나 때문에 무관한 열까지 깨질 위험이 더 크다. 반면
--     행 자체를 안 보이게 하는 것은 "이 메시지는 너에게 안 보인다"는
--     의미상으로도 더 맞고, 실패 모드가 "조용히 0행"이라 더 안전하다.
--   - 정책을 좁혀도 admin_read_all_messages(144:123-125)는 그대로 둔다 —
--     이번 조사·계획 모두 "인플루언서" 범위로 한정했다(§1-6 제목). 관리자가
--     강제숨김(hidden_by_admin_at, 사건 D)·본인 회수(self_withdrawn_admin,
--     사건 F) 메시지를 직접 조회로 볼 수 있는 것은 get_application_messages
--     의 의도된 비대칭(운영팀 내부 대응·투명성)이라 건드리지 않는다.
--     ⚠️ 단 RPC 의 사건 E(인플루언서 본인 회수)는 "관리자도 못 봄" 규칙인데
--     admin_read_all_messages 는 이 예외를 반영하지 않는다 — 표를 직접 부르는
--     관리자는 사건 E 도 원문으로 볼 수 있다. 이번 조사·계획 범위 밖이라
--     손대지 않지만, 같은 성질의 구멍이므로 기록해 둔다(다음 조사 후보).
--
-- ────────────────────────────────────────────────────────────
-- 왜 DELETE 저장소 정책은 그대로 두는가 (중요 — 건드리면 안 된다)
-- ────────────────────────────────────────────────────────────
-- withdraw_own_message 흐름(dev/lib/storage.js:3151-3164)은 ①RPC 로
-- self_withdrawn_at 을 세운 **직후** ②같은 인플루언서가 자기 첨부 파일을
-- `storage.remove()` 로 즉시 삭제한다(개인정보 최소화). 이 삭제는
-- msg_attachments_delete(144:791-804) 정책을 탄다. 만약 DELETE 정책에도
-- "숨김/회수 안 된 메시지만" 조건을 넣으면, 방금 self_withdrawn_at 이 세워진
-- **바로 그 메시지의 첨부를 지우는 정당한 동작 자체가 막힌다** — 회수 직후
-- 삭제하려는 파일이 이제 막 회수 상태가 됐기 때문이다. 그래서 이번 변경은
-- **SELECT(다운로드) 정책만** 좁히고 DELETE·INSERT·UPDATE 정책은 그대로
-- 둔다.
--
-- ────────────────────────────────────────────────────────────
-- 이 마이그레이션이 하는 일
-- ────────────────────────────────────────────────────────────
-- 1) influencer_read_own_application_messages (표 RLS SELECT) —
--    hidden_by_admin_at IS NULL AND self_withdrawn_at IS NULL 조건 추가.
-- 2) msg_attachments_influencer_select (Storage RLS SELECT, 다운로드) —
--    해당 스토리지 경로(name)를 attachments 로 참조하는 메시지를
--    application_messages.attachments(jsonb 배열, {path,...}) 에서 찾아
--    그 메시지가 hidden_by_admin_at IS NULL AND self_withdrawn_at IS NULL
--    일 때만 허용하는 조건 추가.
--    ⚠️ 업로드 경로에 message_id 가 없어(위 실측) 경로만으로는 메시지를
--    특정할 수 없다 — application_messages.attachments 안의 path 문자열과
--    storage.objects.name 을 직접 매칭한다.
--
-- ────────────────────────────────────────────────────────────
-- 영향받지 않는 것
-- ────────────────────────────────────────────────────────────
-- - get_application_messages RPC — owner BYPASSRLS 라 무관. 화면
--   (dev/js/messaging.js)의 유일한 조회 경로, 마스킹·mask_state 그대로 동작.
-- - 관리자 화면(dev/js/admin-messaging.js) — admin_read_all_messages 정책
--   불변. fetchAdminSentAtMap·fetchMessagePreviews(둘 다 storage.js 직접
--   .from('application_messages') 호출)는 관리자 전용 함수라 영향 없음(전수
--   grep 확인 — 두 곳 모두 관리자 화면에서만 호출).
-- - withdraw_own_message 후 첨부 즉시 삭제 — DELETE 정책 불변(위 설명).
-- - 첨부 업로드(msg_attachments_insert)·재업로드(msg_attachments_update) —
--   불변.
--
-- 검증은 SQL 편집기로 불가 — 서비스 키 세션은 RLS(행 단위 보안 정책)를
-- 우회해 정책 자체를 관찰할 수 없다(313 과 동일 사유). 반드시 실제 로그인
-- 세션 기준으로 확인한다. 파일 하단 참고.
--
-- 롤백: 파일 하단.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. application_messages — 표 직접 조회 정책 좁히기
-- ============================================================
DROP POLICY IF EXISTS "influencer_read_own_application_messages" ON public.application_messages;

CREATE POLICY "influencer_read_own_application_messages"
  ON public.application_messages FOR SELECT
  USING (
    hidden_by_admin_at IS NULL
    AND self_withdrawn_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = application_id
         AND a.user_id = auth.uid()
    )
  );

COMMENT ON POLICY "influencer_read_own_application_messages" ON public.application_messages IS
  '[315] 본인 응모건 메시지 중 강제숨김·본인회수 되지 않은 행만 직접 조회
   가능(과거는 행 가시성만 봤음 — 마스킹은 get_application_messages RPC 만
   하고 있어 표를 직접 부르면 원문이 그대로 노출됐다). RPC 는 owner
   BYPASSRLS 라 이 정책 변경과 무관하게 계속 동작. admin_read_all_messages
   정책은 손대지 않음(범위 밖).';

-- ============================================================
-- 2. storage.objects — application-message-attachments 다운로드
--    정책 좁히기 (SELECT 만. INSERT/UPDATE/DELETE 는 절대 건드리지 않는다
--    — 위 「왜 DELETE 는 그대로 두는가」 참고)
-- ============================================================
DROP POLICY IF EXISTS "msg_attachments_influencer_select" ON storage.objects;

CREATE POLICY "msg_attachments_influencer_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1
          FROM public.applications a
          JOIN public.application_messages m
            ON m.application_id = a.id
         WHERE a.user_id = auth.uid()
           -- 경로 첫 세그먼트가 application_id 와 일치 여부(기존 조건)
           AND (storage.foldername(name))[1] = a.id::text
           -- 이 스토리지 객체가 그 메시지의 첨부로 등록돼 있는지
           -- (업로드 경로에 message_id 가 없어 attachments jsonb 로 역참조)
           AND EXISTS (
             SELECT 1 FROM jsonb_array_elements(m.attachments) AS att
              WHERE att ->> 'path' = name
           )
           -- 그 메시지가 강제숨김·본인회수 되지 않았을 때만
           AND m.hidden_by_admin_at IS NULL
           AND m.self_withdrawn_at  IS NULL
      )
    )
  );

COMMENT ON POLICY "msg_attachments_influencer_select" ON storage.objects IS
  '[315] application-message-attachments 다운로드(SELECT). 관리자는 무제한
   (기존 유지). 인플루언서는 본인 응모건 경로 + 그 파일이 실제로 속한
   메시지가 강제숨김·본인회수 되지 않았을 때만 허용 — 숨김·회수 전에 알아
   둔 경로를 재사용한 다운로드를 막는다. INSERT/UPDATE/DELETE 정책은
   변경하지 않음(withdraw_own_message 직후 첨부 삭제 흐름 보호, 파일 헤더
   참고).';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터
-- 확인. SQL 편집기(서비스 키)는 RLS 를 우회하므로 사용하지 않는다 — 전부
-- 실제 로그인 세션(개발서버 브라우저, 두 계정: 테스트 인플루언서 1명 +
-- 관리자 1명) 기준.
-- ============================================================
--
-- 사전 준비 — 관리자 계정으로:
--   1) 아무 응모건 메시지 스레드에서 인플루언서가 보낸 메시지 1건을
--      "숨김"(hide_application_message, 사유는 임의) 처리해 둔다.
--   2) 같은 스레드에서 첨부 이미지가 있는 메시지가 있으면 그 파일 경로
--      (attachments[0].path)를 미리 기록해 둔다(없으면 테스트 인플루언서
--      계정으로 새로 하나 보내 첨부를 만들어 둔다).
--
-- [1] 표 직접 조회 차단 확인 — 테스트 인플루언서 계정으로 로그인 후
--     브라우저 콘솔에서:
--   const { data, error } = await db.from('application_messages')
--     .select('id, body, hidden_by_admin_at')
--     .eq('application_id', '<위 응모건 id>');
--   → data 배열에 **숨김 처리한 메시지의 id 가 없어야 한다**(행 자체가
--     안 보임). error 는 없어야 정상(0행이 맞는 상태).
--
-- [2] 화면 정상 동작 확인 — 같은 계정으로 응모건 메시지 화면을 열어
--     get_application_messages RPC 경로가 여전히 정상 동작하는지 확인:
--     숨긴 메시지가 "이 메시지는 표시할 수 없습니다"류 placeholder 로
--     보이는지(원문이 아니라 mask_state 기반 안내), 나머지 메시지는
--     평소대로 보이는지.
--
-- [3] 첨부 다운로드 차단 확인 — 사전 준비에서 기록해 둔 첨부 경로가
--     "숨김 처리한 메시지"에 속한 것이면(아니면 하나 더 만들어 그 메시지를
--     숨김 처리), 테스트 인플루언서 계정 콘솔에서:
--   const { data, error } = await db.storage
--     .from('application-message-attachments')
--     .createSignedUrl('<숨긴 메시지의 첨부 path>', 60);
--   → error 가 나거나(정책 위반/Not Found), data 가 없어야 한다.
--
-- [4] 첨부 다운로드 회귀 확인(정상 케이스) — 아직 숨기지 않은 다른
--     메시지의 첨부 경로로 같은 호출:
--   → 정상적으로 signedUrl 이 발급돼야 한다(기존과 동일 동작).
--
-- [5] 관리자 회귀 확인 — 관리자 계정으로 로그인해:
--   5-1) 같은 스레드를 표 직접 조회 또는 화면으로 열어, 숨긴 메시지가
--        여전히 원문으로 보이는지(admin_read_all_messages 불변 확인).
--   5-2) 그 메시지의 첨부도 정상적으로 열람(다운로드)되는지 확인
--        (public.is_admin() 조항 불변 확인).
--
-- [6] withdraw_own_message 회귀 확인 — 테스트 인플루언서 계정으로 첨부
--     있는 새 메시지를 보낸 뒤 25분 이내에 회수(취소) 버튼을 눌러:
--     → 회수 성공 + 첨부 파일이 저장소에서 실제로 삭제되는지 확인(DELETE
--       정책이 이번 변경으로 막히지 않았는지 — 가장 중요한 회귀 지점).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP POLICY IF EXISTS "influencer_read_own_application_messages" ON public.application_messages;
-- CREATE POLICY "influencer_read_own_application_messages"
--   ON public.application_messages FOR SELECT
--   USING (
--     EXISTS (
--       SELECT 1 FROM public.applications a
--        WHERE a.id = application_id
--          AND a.user_id = auth.uid()
--     )
--   );
--
-- DROP POLICY IF EXISTS "msg_attachments_influencer_select" ON storage.objects;
-- CREATE POLICY "msg_attachments_influencer_select"
--   ON storage.objects FOR SELECT
--   TO authenticated
--   USING (
--     bucket_id = 'application-message-attachments'
--     AND (
--       public.is_admin()
--       OR EXISTS (
--         SELECT 1 FROM public.applications a
--          WHERE a.user_id = auth.uid()
--            AND (storage.foldername(name))[1] = a.id::text
--       )
--     )
--   );
-- COMMIT;
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
