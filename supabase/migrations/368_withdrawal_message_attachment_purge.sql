-- ============================================================
-- 368_withdrawal_message_attachment_purge.sql
-- 2026-08-21
--
-- 목적:
--   탈퇴가 확정된 회원이 **응모건 메시지에 보낸 사진**을 확정 6개월 뒤
--   저장소에서 실제로 지운다. 지운 뒤 첨부 배열은 같은 길이의
--   [{"purged":true}, ...] 로 치환하고 파기 시각을 찍는다.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 12-B
-- 분해표: docs/specs/2026-08-21-message-attachment-purge-breakdown.md 조각 12-B-1
--
-- ============================================================
-- 이건 마이그레이션 364(영수증·인증샷 파기)와 「같은 모양의 장치를
-- 하나 더 세운 것」이다 — 364 를 넓힌 것이 아니다 (2026-08-21 사용자 결정 Q2)
-- ============================================================
--   364 를 그대로 넓히려던 초안은 세 가지에 막혔다(분해표 §1-4):
--     1) 목록 함수의 반환 모양이 다르다 — 364 는 deliverable_id 하나를
--        돌려주는데, 메시지 쪽은 한 메시지 안에 사진이 여러 장 있을 수
--        있어 message_id + 경로 배열 2종이 필요하다. 이름이 다른 칸을
--        넣으려면 CREATE OR REPLACE 로 안 되고 DROP 후 재생성인데, 그
--        함수는 **운영에서 매일 도는 메일 함수**가 읽는다.
--     2) 파기 표시 방식이 다르다 — 결과물은 receipt_url 칸 하나를 비우면
--        끝이지만, 메시지 첨부는 jsonb 배열을 다시 써야 하고 그 배열을
--        통째로 비우면 아래 [C] 의 CHECK 제약에 걸린다.
--     3) 저장소 통 이름이 상수 하나다 — 통이 둘이 되면 한쪽 통 장애가
--        다른 쪽 파기까지 함께 멈춘다.
--   → 재사용하는 것은 **_withdrawal_media_purge_due_ids() 하나뿐**이다.
--     ⚠️ 364 의 list_pending_withdrawal_media_purge / mark_withdrawal_media_purged
--     / count_overdue_withdrawal_media_purge 는 이 마이그레이션에서
--     **손대지 않는다.** 고치면 영수증·인증샷 파기 기준까지 함께 바뀐다.
--
-- ============================================================
-- 무엇을 지우나 / 무엇은 안 지우나 (2026-08-21 사용자 결정 Q1·Q4)
-- ============================================================
--   지운다  : application_messages 중 탈퇴 확정 6개월 지난 회원의
--             응모건에 달린 **sender_kind='influencer'** 메시지의 첨부 파일
--   안 지운다:
--            - sender_kind='admin' 메시지의 첨부 — 회사 발신 응대 기록.
--              지우면 분쟁 때 「우리가 뭘 보냈는지」를 증명할 수 없다
--            - 메시지 **본문**(body) · **번역본**(body_translated) ·
--              **발신자 이름 스냅샷**(sender_name) — 이번 범위 밖(Q4).
--              사진을 지워도 그 대화에는 회원 실명이 그대로 남는다
--            - application_message_broadcasts.attachments — 관리자가
--              만든 일괄 발송 원본. 애초에 이 표를 조회하지 않는다
--            - 캠페인이 보관 삭제된 응모의 메시지 — 마이그레이션 325 가
--              행째 지워 자연히 대상에서 빠진다
--
-- ============================================================
-- 첨부 배열을 어떻게 바꾸나 (2026-08-21 사용자 결정 Q3)
-- ============================================================
--   지금  : [{"path":"a1b2/xxx.jpg","name":"IMG_0451.jpg","size":183422,"mime":"image/jpeg"}, {...}]
--   파기후: [{"purged":true}, {"purged":true}]
--
--   🔴 배열을 비우지 않고 **길이를 유지**한다. 표에는 다음 CHECK 제약이
--   있다(마이그레이션 144):
--     CHECK (btrim(body) <> '' OR attachments <> '[]'::jsonb)
--   사진만 보낸 메시지는 body 가 빈 문자열이므로, attachments 를 '[]' 로
--   만드는 순간 그 행이 UPDATE 자체를 거부당한다. SECURITY DEFINER 도
--   CHECK 제약은 못 지나간다. path·name·size·mime 은 전부 버려
--   (파일 이름까지 지워야 파기가 온전하다) 「사진 N장이 있었다」는
--   사실만 남긴다.
--
-- ============================================================
-- 되돌리기
-- ============================================================
--   DROP FUNCTION IF EXISTS public.count_overdue_withdrawal_message_attachment_purge();
--   DROP FUNCTION IF EXISTS public.mark_withdrawal_message_attachments_purged(uuid[]);
--   DROP FUNCTION IF EXISTS public.list_pending_withdrawal_message_attachment_purge(integer);
--   DROP INDEX IF EXISTS public.idx_application_messages_purge_pending;
--   ALTER TABLE public.application_messages DROP COLUMN IF EXISTS attachments_purged_at;
--   ⚠️ 이 조각 이후 12-B-2(메일 함수)·12-B-3(예약 등록)이 배포됐다면
--   그것부터 먼저 되돌릴 것 — 순서가 바뀌면 함수가 사라진 채로 예약이
--   계속 돌아 매일 실패한다.
--   ⚠️ 이미 지워진 **파일은 되살아나지 않는다.** 칸을 되돌려도 마찬가지다.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] application_messages.attachments_purged_at — 파기 시각 + 색인
-- ============================================================
--   이 칸이 없으면 「지웠다」와 「원래 사진이 없었다」를 구분할 수 없고,
--   첨부 배열은 파기 후에도 원소가 그대로 남아 있으므로(§ 위 Q3) 이
--   칸이 없으면 매일 같은 메시지를 다시 집는다(분해표 §2 ②).
ALTER TABLE public.application_messages
  ADD COLUMN IF NOT EXISTS attachments_purged_at timestamptz;

COMMENT ON COLUMN public.application_messages.attachments_purged_at IS
'탈퇴 확정 6개월 뒤 이 메시지가 보낸 사진 파일을 저장소에서 지운 시각(마이그레이션 368). '
'NULL 이면 아직 파기 전(또는 애초에 첨부가 없었음), NOT NULL 이면 파기됨 — 이때 '
'attachments 는 원소 개수는 그대로이고 각 원소가 {"purged":true} 로 치환돼 있다. '
'sender_kind=''admin'' 메시지에는 이 칸이 채워지지 않는다(대상 아님, 마이그레이션 368).';

-- 조회 전용 부분 색인 — 아직 안 지운 사진이 있는 인플루언서 발신 메시지만.
CREATE INDEX IF NOT EXISTS idx_application_messages_purge_pending
  ON public.application_messages (application_id)
  WHERE attachments_purged_at IS NULL
    AND attachments <> '[]'::jsonb
    AND sender_kind = 'influencer';

-- ============================================================
-- [B] list_pending_withdrawal_message_attachment_purge — 지울 목록
-- ============================================================
--   🔴 **postgres·service_role 전용.** 이 통(application-message-attachments)은
--   비공개라 364 의 list_pending_withdrawal_media_purge 만큼 위험하지는
--   않지만, 관행을 다르게 할 이유가 없다. 관리자가 볼 것은 [D] 의
--   **건수**뿐이다.
--
--   반환하는 delete_paths / keep_paths 의 뜻(분해표 §4-3):
--     같은 경로를 **파기 대상 밖의 다른 메시지**(그 메시지가 아직
--     attachments_purged_at IS NULL 이면)도 가리키고 있으면, 그 경로는
--     keep_paths 로 간다 — 파일은 남기고 이 메시지의 첨부 표시만 한다.
--     대상 안의 다른 메시지끼리 우연히 같은 경로를 가리키는 경우는
--     delete_paths 로 둔다(어차피 같은 배치에서 함께 파기되므로 한 번
--     지워도 무해하다 — 마이그레이션 364 의 should_delete_file 과 같은 판단).
--   경로는 이미 통 안 상대 경로다({응모id}/{난수}.jpg, dev/lib/storage.js
--   uploadMessageAttachment) — 364 의 receipt_url 과 달리 공개 전체
--   주소가 아니므로 정규식 변환이 필요 없다.
CREATE OR REPLACE FUNCTION public.list_pending_withdrawal_message_attachment_purge(
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  message_id   uuid,
  delete_paths text[],
  keep_paths   text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  WITH target AS (
    SELECT am.id
      FROM public.application_messages am
      JOIN public.applications a ON a.id = am.application_id
      JOIN public._withdrawal_media_purge_due_ids() due
        ON due.influencer_id = a.user_id
     WHERE am.sender_kind = 'influencer'
       AND am.attachments <> '[]'::jsonb
       AND am.attachments_purged_at IS NULL
       -- 관리자를 겸한 회원은 건드리지 않는다(358·359·361·364 와 같은 판단).
       -- 눈에 보이게 남겨 [D] 의 밀린 건수에 계속 잡히게 한다.
       AND NOT public._influencer_is_admin_account(a.user_id)
     ORDER BY am.id
     LIMIT GREATEST(COALESCE(p_limit, 500), 1)
  ),
  -- 아직 안 지운(=파기되지 않은) 모든 메시지의 첨부 경로. 대상 배치뿐
  -- 아니라 표 전체를 본다 — 대상 밖 메시지가 같은 경로를 붙들고 있는지
  -- 확인해야 하기 때문이다(분해표 §2 ⑤, 캠페인 설명 이미지 참조세기 선례).
  all_active_paths AS (
    SELECT am.id AS message_id, (elem ->> 'path') AS path
      FROM public.application_messages am,
           jsonb_array_elements(am.attachments) AS elem
     WHERE am.attachments_purged_at IS NULL
       AND (elem ->> 'path') IS NOT NULL
  ),
  target_elem AS (
    SELECT ap.message_id,
           ap.path,
           EXISTS (
             SELECT 1
               FROM all_active_paths o
              WHERE o.path = ap.path
                AND o.message_id <> ap.message_id
                AND o.message_id NOT IN (SELECT t.id FROM target t)
           ) AS referenced_outside
      FROM all_active_paths ap
      JOIN target t ON t.id = ap.message_id
  )
  -- ⚠️ **COALESCE 를 빼면 안 된다.** array_agg(...) FILTER 는 걸리는 원소가
  --    하나도 없으면 **빈 배열이 아니라 NULL** 을 돌려준다. 그대로 내보내면
  --    12-B-2(파기 함수)가 그 값을 순회하다 터지거나, 더 나쁘게는 조용히
  --    「지울 것 없음」으로 넘어간다. 소비하는 쪽이 실수할 수 없게 **여기서**
  --    빈 배열로 맞춘다 — 계약을 문서로 경고하는 것보다 낫다.
  SELECT te.message_id,
         COALESCE(array_agg(DISTINCT te.path) FILTER (WHERE NOT te.referenced_outside), '{}'::text[]) AS delete_paths,
         COALESCE(array_agg(DISTINCT te.path) FILTER (WHERE te.referenced_outside),     '{}'::text[]) AS keep_paths
    FROM target_elem te
   GROUP BY te.message_id;
$fn$;

COMMENT ON FUNCTION public.list_pending_withdrawal_message_attachment_purge(integer) IS
'탈퇴 확정 6개월이 지나 파기해야 할 응모건 메시지 사진 목록(마이그레이션 368). '
'sender_kind=''influencer'' 메시지만 대상이다(admin 발신 응대 기록은 제외). '
'🔴 postgres·service_role 전용. 관리자에게는 건수만 '
'(count_overdue_withdrawal_message_attachment_purge). '
'⚠️ 364 의 list_pending_withdrawal_media_purge 와는 별개 장치다 — 재사용하는 것은 '
'_withdrawal_media_purge_due_ids() 하나뿐(2026-08-21 사용자 결정 Q2). '
'⚠️ delete_paths·keep_paths 는 **비어도 NULL 이 아니라 빈 배열**이다 — 부르는 쪽이 '
'NULL 검사를 잊어도 조용히 어긋나지 않게 여기서 맞춘다.';

REVOKE ALL ON FUNCTION public.list_pending_withdrawal_message_attachment_purge(integer) FROM PUBLIC;
-- 🔴 **PUBLIC 회수만으로는 안 잠긴다.** Supabase 가 새 함수에 anon·authenticated
--    실행 권한을 자동으로 부여하고, PUBLIC 회수는 그 개별 부여를 못 걷어낸다.
--    2026-08-21 에 이 구멍으로 파기 함수들이 비로그인에게 열려 있던 것이 드러났다
--    (마이그레이션 369). **명시적으로 회수한다.**
REVOKE EXECUTE ON FUNCTION public.list_pending_withdrawal_message_attachment_purge(integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_pending_withdrawal_message_attachment_purge(integer) TO postgres, service_role;

-- ============================================================
-- [C] mark_withdrawal_message_attachments_purged — 파기 표시
-- ============================================================
--   🔴 **순서가 전부다: 저장소에서 파일을 지운 뒤에 이걸 부른다.**
--   반대로 하면 삭제가 실패한 파일이 「지운 것」으로 찍혀 목록에서 빠지고
--   그 파일은 저장소에 영원히 남는다(364 와 같은 원칙).
--
--   첨부 배열은 **비우지 않고 같은 길이로 치환**한다 — 표의
--   CHECK (btrim(body) <> '' OR attachments <> '[]'::jsonb) 를 지나가기
--   위해서다. jsonb_array_elements 로 원소 개수를 센 뒤 그 개수만큼
--   {"purged":true} 를 다시 채운다.
CREATE OR REPLACE FUNCTION public.mark_withdrawal_message_attachments_purged(
  p_message_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_updated integer;
BEGIN
  IF p_message_ids IS NULL OR array_length(p_message_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.application_messages am
     SET attachments = (
           -- 원소 개수를 그대로 유지한 채 각 원소를 {"purged":true} 로 치환.
           -- attachments 가 이미 비어 있으면(정상적으로는 발생하지 않는다 —
           -- [B] 가 attachments <> '[]' 인 메시지만 넘긴다) jsonb_agg 가
           -- NULL 을 돌려주므로 COALESCE 로 '[]' 를 방어한다. 이 경우 body
           -- 도 비어 있으면 아래 UPDATE 는 CHECK 위반으로 그 행만 실패한다
           -- (트랜잭션 전체를 묶지 않았으므로 다른 행은 영향 없다 — 이
           -- 함수가 단일 UPDATE 문 하나이므로 실패 시 이 문장 전체가
           -- 롤백된다는 점은 364 의 mark 함수와 동일하다. [B] 가 이미
           -- 걸러 넘기므로 실무에서 도달하지 않는다).
           COALESCE(
             (SELECT jsonb_agg('{"purged":true}'::jsonb)
                FROM jsonb_array_elements(am.attachments)),
             '[]'::jsonb
           )
         ),
         attachments_purged_at = now()
   WHERE am.id = ANY(p_message_ids)
     AND am.attachments_purged_at IS NULL;     -- 멱등 — 두 번 불러도 시각이 안 밀린다

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE NOTICE '[368] 응모건 메시지 사진 파기 표시 %건', v_updated;
  RETURN v_updated;
END;
$fn$;

COMMENT ON FUNCTION public.mark_withdrawal_message_attachments_purged(uuid[]) IS
'저장소에서 실제로 지운 뒤에만 부른다(마이그레이션 368). '
'🔴 표시를 먼저 하면 삭제 실패한 파일이 목록에서 빠져 영영 남는다. '
'첨부 배열은 비우지 않고 같은 길이의 [{"purged":true}, ...] 로 치환한다 — '
'표의 CHECK(body 비었으면 attachments 도 비면 안 됨) 제약을 지나가기 위해서다 '
'(2026-08-21 사용자 결정 Q3). path·name·size·mime 은 전부 버린다.';

REVOKE ALL ON FUNCTION public.mark_withdrawal_message_attachments_purged(uuid[]) FROM PUBLIC;
-- 🔴 **PUBLIC 회수만으로는 안 잠긴다.** Supabase 가 새 함수에 anon·authenticated
--    실행 권한을 자동으로 부여하고, PUBLIC 회수는 그 개별 부여를 못 걷어낸다.
--    2026-08-21 에 이 구멍으로 파기 함수들이 비로그인에게 열려 있던 것이 드러났다
--    (마이그레이션 369). **명시적으로 회수한다.**
REVOKE EXECUTE ON FUNCTION public.mark_withdrawal_message_attachments_purged(uuid[]) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_withdrawal_message_attachments_purged(uuid[]) TO postgres, service_role;

-- ============================================================
-- [D] count_overdue_withdrawal_message_attachment_purge — 밀린 건수
-- ============================================================
--   작업 14 의 「밀린 파기 경고」(12-B-5)가 쓸 값. 경로는 안 주고
--   **숫자만** 준다. 0 이 정상이고, 며칠째 0 이 아니면 예약이 멈췄거나
--   삭제가 계속 실패 중이라는 뜻이다.
--
--   ⚠️ 권한이 없으면 0 이 아니라 오류를 낸다 — 이 저장소의 같은 목적
--   함수(364 의 두 함수 포함 44개 이상)가 전부 그렇다. 0 을 돌려주면
--   화면이 「밀린 것 없음」과 「볼 권한 없음」을 구분할 수 없다
--   (마이그레이션 276 이 세운 원칙).
--
--   ⚠️ 관리자를 겸한 회원의 메시지는 [B] 목록에서는 빠지지만 여기서는
--   **포함해서 센다**(364 의 [E] 와 동일 — 눈에 보이게 남긴다).
CREATE OR REPLACE FUNCTION public.count_overdue_withdrawal_message_attachment_purge()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM public.application_messages am
    JOIN public.applications a ON a.id = am.application_id
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = a.user_id
   WHERE am.sender_kind = 'influencer'
     AND am.attachments <> '[]'::jsonb
     AND am.attachments_purged_at IS NULL;

  RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION public.count_overdue_withdrawal_message_attachment_purge() IS
'파기 기한이 지났는데 아직 안 지워진 응모건 메시지 사진 건수(마이그레이션 368, '
'작업 12-B-5 경고용). 경로는 주지 않는다 — 관리자에게도. 0 이 정상이고, '
'권한이 없으면 0 이 아니라 42501 오류다. ⚠️ 관리자를 겸한 회원의 메시지는 '
'[B] 목록에서는 빠지지만 여기에는 계속 잡힌다(의도 — 그런 회원이 있으면 '
'이 값이 0 으로 안 내려간다).';

REVOKE ALL ON FUNCTION public.count_overdue_withdrawal_message_attachment_purge() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_overdue_withdrawal_message_attachment_purge() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인
-- (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
--  「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 신규 함수가
--  3개라 적용은 성공하고 **첫 호출에서** 자료형·컬럼 오류가 터질 수 있다.
--  1단계씩 순서대로, 결과를 보며 진행할 것)
-- ============================================================
--
-- [V0] 칸·색인이 생겼는지
--   SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='application_messages'
--      AND column_name='attachments_purged_at';
--   기대: 1행, timestamp with time zone.
--
--   SELECT indexname FROM pg_indexes
--    WHERE schemaname='public' AND tablename='application_messages'
--      AND indexname='idx_application_messages_purge_pending';
--   기대: 1행.
--
-- [V1] ★★ 목록 함수 첫 호출 — 자료형 오류(42804)·컬럼 모호성(42702)이
--      여기서 드러난다. 0행이어도 **호출 자체가 성공하는지**가 확인 대상.
--   SELECT * FROM public.list_pending_withdrawal_message_attachment_purge(10);
--   기대: 0행(오늘 기준 확정 탈퇴 0건), 오류 없음.
--
-- [V2] 건수 함수 — ⚠️ **여기서는 권한 오류가 나는 것이 정상이다.**
--      SQL 편집기는 서비스 키라 is_admin() 이 false 다.
--   SELECT public.count_overdue_withdrawal_message_attachment_purge();
--   기대: 오류 42501 'forbidden'.
--   → 여기서 숫자 0 이 나오면 권한 검사가 안 걸린 것이므로 확인할 것.
--   → 진짜 값 확인은 [V5] 에서 관리자 브라우저로 한다.
--
-- [V3] 같은 경로를 두 메시지가 실제로 가리키는 경우가 있는지(참조
--      세기가 안전망인지 핵심 장치인지 판단용, 분해표 §2 ⑤):
--   WITH elem AS (
--     SELECT am.id AS message_id, (e ->> 'path') AS path
--       FROM public.application_messages am,
--            jsonb_array_elements(am.attachments) AS e
--      WHERE am.attachments_purged_at IS NULL
--        AND (e ->> 'path') IS NOT NULL
--   )
--   SELECT path, count(*) FROM elem GROUP BY path HAVING count(*) > 1;
--   기대: 0행(경로에 난수가 들어가 사실상 겹치지 않는다). 0행이 아니면
--   [B] 의 keep_paths 로 실제로 걸러지는지 그 message_id 로 확인할 것.
--
-- [V4] ★★★ 「사진만 보낸 메시지」가 파기 뒤 모양으로도 저장이 되는지
--      (표의 CHECK 제약 통과 확인, 분해표 §2 ①). 실제 응모 id 로 바꿔
--      실행하고 **끝나면 반드시 그 시험 행을 지울 것**:
--   INSERT INTO public.application_messages
--     (application_id, sender_kind, sender_id, sender_name, body, attachments)
--   VALUES
--     ('<실제 존재하는 applications.id>', 'influencer',
--      '<임의 uuid, 예: gen_random_uuid()>', '삭제예정테스트',
--      '', '[{"purged":true}]'::jsonb);
--   기대: 오류 없이 INSERT 성공(body 가 빈 문자열이어도 attachments 가
--   '[]' 가 아니므로 CHECK 통과). 확인 후:
--   DELETE FROM public.application_messages WHERE sender_name = '삭제예정테스트';
--
-- [V5] 관리자 브라우저 콘솔에서(로그인한 상태 — SQL 편집기로는 is_admin()
--      분기가 아예 안 돈다):
--   await db.rpc('count_overdue_withdrawal_message_attachment_purge')
--   기대: {data: 0, error: null}.
--
-- [V6] 🔴 목록 함수가 관리자에게 **막히는지** (막혀야 정상):
--   await db.rpc('list_pending_withdrawal_message_attachment_purge', {p_limit: 1})
--   기대: 권한 오류(42501).
--
-- [V7] T1 재확인(개발 데이터베이스 — 분해표 §6 은 운영만 확인했다) —
--      application_messages 에 걸린 트리거가 삽입(4)에만 도는지:
--   SELECT tgname, tgtype FROM pg_trigger
--    WHERE tgrelid = 'public.application_messages'::regclass
--      AND NOT tgisinternal;
--   ⚠️ 결과에 웹훅 URL·서비스 키가 그대로 보일 수 있다 — 어디에도
--   붙여넣지 말고 tgtype 값만 확인할 것(4=삽입, 16=수정, 8=삭제 비트).
--   기대: 자동 번역 웹훅이 있다면 tgtype 이 4(삽입 전용)만 포함하고
--   16(수정)은 안 켜져 있어야 한다.
-- ============================================================
