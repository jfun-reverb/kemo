-- ============================================================
-- 483: 본인이 보낸 메시지 사진을 회수 뒤에도 (저장소 삭제용으로) 볼 수 있게
-- ============================================================
-- 목적
--   회원이 메시지를 회수하면 화면(withdrawOwnMessage, dev/lib/storage.js)이
--   ①withdraw_own_message 로 회수 표시 → ②저장소 remove() 로 사진 삭제를 한다.
--
-- 결함 (운영 실측 2026-09-29, 읽기 조회)
--   저장소 삭제는 DELETE ... RETURNING 이라 「조회 정책으로 보이는 행」만 지워진다.
--   회원 조회 정책(응모건 315 msg_attachments_influencer_select, 일반 문의 476
--   msg_attachments_general_influencer_select)이 「회수 안 됨」을 요구하므로,
--   회수 표시 직후 그 사진은 조회에서 가려져 삭제가 오류 없이 0건으로 끝난다.
--   운영: 회수 메시지 첨부 13장 중 12장 잔존, 12장 전부 2026-08-19(315 적용) 이후
--   회수분. 개발에서도 일반 문의로 재현(476 삭제 정책은 통과해도 조회에 가려짐).
--
-- 수정 (기존 정책은 한 글자도 안 고친다 — 정책 추가 + 보조 함수 1개)
--   ① public._own_sent_attachment_path(text) — 본인이 보냈고 관리자가 숨기지 않은
--      메시지의 첨부 경로인지(참/거짓만). 응모건·일반 문의 구분 없음, 회수 여부 무관.
--   ② 조회 정책 msg_attachments_own_sent_select — 위 함수가 참인 파일만 조회 허용.
--
-- 넓어지는 것: 「본인이 보낸 메시지의 사진을, 관리자가 숨기지 않은 한, 회수 뒤에도
--   본인이 볼 수 있다」. 회수 직후 화면이 바로 지우므로 실질 창은 잠깐이다.
--   관리자 숨김 메시지는 여전히 안 보이고, 남의 사진·운영팀이 보낸 사진은
--   sender_id 조건 때문에 안 보인다.
--
-- 삭제 정책 판단: 144 msg_attachments_delete(응모건)는 「관리자 또는 경로 첫 조각이
--   본인 응모」만 보고 회수 여부를 안 본다 → 조회만 통과하면 삭제도 통과한다.
--   476 일반 문의 삭제 정책도 회수 조건 없음. 삭제 정책은 손대지 않는다.
--
-- ------------------------------------------------------------
-- 검증 조회 (SQL 편집기, 읽기 전용 — 1단계씩)
-- ------------------------------------------------------------
-- [적용 전] 잔존 수 (회수 메시지 첨부 중 저장소에 남은 파일)
--   SELECT count(*) AS total_atts,
--          count(o.name) AS still_in_storage
--     FROM public.application_messages m
--     CROSS JOIN LATERAL jsonb_array_elements(m.attachments) AS att
--     LEFT JOIN storage.objects o
--            ON o.bucket_id = 'application-message-attachments'
--           AND o.name = att ->> 'path'
--    WHERE m.self_withdrawn_at IS NOT NULL;
-- [적용 후] 정책·함수 존재 및 권한
--   SELECT policyname FROM pg_policies
--    WHERE schemaname='storage' AND tablename='objects'
--      AND policyname='msg_attachments_own_sent_select';
--   SELECT p.proacl::text FROM pg_proc p
--     JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.proname='_own_sent_attachment_path';
--   (맨 앞 「=X/」 가 없고 authenticated 만 있어야 한다)
-- ※ 회원 권한 동작은 SQL 편집기(서비스 키)로 재현 불가 — 로그인 브라우저로 확인.
--
-- ------------------------------------------------------------
-- 남은 운영 파일 정리용 경로 조회 (SELECT 만 — 삭제는 별도 작업)
-- ------------------------------------------------------------
--   SELECT m.id AS message_id, m.application_id, att ->> 'path' AS path
--     FROM public.application_messages m
--     CROSS JOIN LATERAL jsonb_array_elements(m.attachments) AS att
--     JOIN storage.objects o
--       ON o.bucket_id = 'application-message-attachments'
--      AND o.name = att ->> 'path'
--    WHERE m.self_withdrawn_at IS NOT NULL
--    ORDER BY m.self_withdrawn_at;
--
-- 롤백 (하단 「되돌리기」 참조)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._own_sent_attachment_path(p_path text)
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
     WHERE m.sender_id = auth.uid()
       AND m.hidden_by_admin_at IS NULL
       AND att ->> 'path' = p_path
       -- 🔴 경로가 **본인 폴더**여야 한다(리뷰 지적). 응모건 발송 함수는 첨부 경로를 검사하지 않아,
       --    이 조건이 없으면 첨부 목록에 남의 파일 경로를 적어 보내는 것만으로 그 사진이 열린다.
       --    응모건 = 첫 조각이 그 메시지의 응모 번호이고 그 응모가 본인 것 / 일반 문의 = general/{본인 id}/
       AND (
         (m.application_id IS NOT NULL
          AND split_part(p_path, '/', 1) = m.application_id::text
          AND EXISTS (SELECT 1 FROM public.applications a
                       WHERE a.id = m.application_id AND a.user_id = auth.uid()))
         OR
         (m.application_id IS NULL
          AND split_part(p_path, '/', 1) = 'general'
          AND split_part(p_path, '/', 2) = auth.uid()::text)
       )
  );
$fn$;

COMMENT ON FUNCTION public._own_sent_attachment_path(text) IS
  '[483] 저장소 조회 정책 전용 — 로그인 회원이 보냈고 관리자가 숨기지 않은 메시지의 첨부 경로인지(참/거짓만). '
  '경로는 본인 폴더여야 한다(응모건 = 본인 응모 번호 / 일반 문의 = general/{본인 id}). '
  '회수 여부는 보지 않는다(회수 직후 사진 삭제가 조회에 가려져 0건이 되는 결함 방지).';

REVOKE ALL ON FUNCTION public._own_sent_attachment_path(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._own_sent_attachment_path(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public._own_sent_attachment_path(text) TO authenticated;

DROP POLICY IF EXISTS "msg_attachments_own_sent_select" ON storage.objects;
CREATE POLICY "msg_attachments_own_sent_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND public._own_sent_attachment_path(name)
  );

COMMIT;
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 되돌리기
--   BEGIN;
--   DROP POLICY IF EXISTS "msg_attachments_own_sent_select" ON storage.objects;
--   DROP FUNCTION IF EXISTS public._own_sent_attachment_path(text);
--   COMMIT;
--   NOTIFY pgrst, 'reload schema';
--   (되돌리면 회수 뒤 사진 삭제가 다시 0건이 된다)
-- ============================================================
