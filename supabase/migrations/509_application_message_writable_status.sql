-- ============================================================
-- 509_application_message_writable_status.sql
-- 응모건 메시지 「쓸 수 있는 응모건인가」 판정을 한 곳에 모은다
--
-- 목적:
--   응모 종료 후 90일이 지나면 인플루언서는 응모건 메시지를 못 보낸다(읽기만).
--   그 판정(종료 시각 CASE + 90일 비교)이 send_application_message 안에만 있어,
--   회원 화면이 「입력칸을 열지 말지」를 미리 알 방법이 없었다. 규칙은 그대로 두고
--   ① 판정을 헬퍼 두 개로 모으고 ② 회원이 자기 응모건 전부의 상태를 한 번에
--   받는 함수를 추가한다. 화면과 발송 함수가 같은 판정을 쓰므로 어긋나지 않는다.
--
-- 베이스: send_application_message = 323(144 → 145 → 323). 본문은 323 그대로이고
--   종료 시각 CASE + 90일 비교 부분만 헬퍼 호출로 바꿨다(한도·일괄 제외·알림 무변경).
--
-- 신규:
--   _application_message_ended_at(uuid) — 종료 시각(323 의 CASE 와 동일). 내부용
--   _application_message_writable(uuid) — 종료 시각 없음 또는 90일 이내면 true. 90일은 여기 한 곳
--   get_my_application_message_status() — 본인 응모건 전부 {"<id>":{writable,ended_at}} jsonb 하나
--   ※ 관리자는 90일 경과 후에도 발송 가능(send 안의 is_admin 분기 그대로).
--     이 상태 함수는 「회원으로서의 쓰기 가능 여부」만 돌려준다.
--
-- 편집기 경고: 뜸 — 무해 (send_application_message 함수 본문 안의 DELETE 단어를 편집기가
--   문장 시작으로 오인. 실제 삭제 없음. DROP·테이블 변경 없음)
--
-- 실행 권한(회수 방향 둘 — CLAUDE.md 「함수 실행 권한」):
--   헬퍼 둘: REVOKE FROM PUBLIC, anon, authenticated (SECURITY DEFINER 함수 안에서만 호출됨.
--            소유자 postgres 와 service_role 은 건드리지 않음)
--   get_my_application_message_status: REVOKE FROM PUBLIC, anon / GRANT TO authenticated
--   send_application_message: CREATE OR REPLACE 라 기존 권한 유지 + 323 의 REVOKE/GRANT 재기재
--
-- 검증 (1단계씩, 개발서버):
--   ① 권한: SELECT p.proname, p.proacl::text FROM pg_proc p
--            WHERE p.pronamespace='public'::regnamespace
--              AND p.proname IN ('_application_message_ended_at','_application_message_writable',
--                                'get_my_application_message_status');
--      → 헬퍼 둘 acl 에 anon/authenticated 와 맨 앞 `=X/` 모두 없어야 함, 상태 함수는 authenticated 만
--   ② 회원 로그인 브라우저에서 db.rpc('get_my_application_message_status') → 본인 응모건 키만
--      (SQL 편집기는 auth.uid() 가 NULL 이라 예외가 나는 것이 정상)
--   ③ 90일 지난 반려 응모건 회원으로 send_application_message → 기존과 같은 90일 거부 메시지
--
-- 롤백:
--   1) 323 파일의 CREATE OR REPLACE FUNCTION public.send_application_message … 블록을 그대로 재실행
--   2) DROP FUNCTION public.get_my_application_message_status();
--      DROP FUNCTION public._application_message_writable(uuid);
--      DROP FUNCTION public._application_message_ended_at(uuid);   -- 1) 다음에
-- ============================================================

BEGIN;

-- 응모 종료 시각 (323 의 인라인 CASE 와 동일). 종료 아님·응모 없음 = NULL
CREATE OR REPLACE FUNCTION public._application_message_ended_at(p_application_id uuid)
RETURNS timestamptz
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT CASE
    WHEN a.cancelled_at IS NOT NULL THEN a.cancelled_at
    WHEN a.status = 'rejected'      THEN a.reviewed_at
    WHEN a.status = 'approved' AND NOT EXISTS (
      SELECT 1 FROM public.deliverables d
       WHERE d.application_id = p_application_id
         AND d.status <> 'approved'
    ) AND EXISTS (
      SELECT 1 FROM public.deliverables d
       WHERE d.application_id = p_application_id
    ) THEN (
      SELECT max(d.reviewed_at) FROM public.deliverables d
       WHERE d.application_id = p_application_id
    )
    ELSE NULL
  END
  FROM public.applications a
  WHERE a.id = p_application_id;
$$;

-- 회원이 메시지를 쓸 수 있는가 — 90일 창은 이 함수 한 곳(숫자를 다른 곳에 복사하지 말 것)
CREATE OR REPLACE FUNCTION public._application_message_writable(p_application_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT COALESCE(
    public._application_message_ended_at(p_application_id) >= now() - interval '90 days',
    true);
$$;

REVOKE EXECUTE ON FUNCTION public._application_message_ended_at(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._application_message_writable(uuid) FROM PUBLIC, anon, authenticated;

-- 본인 응모건 전부의 쓰기 가능 상태 — jsonb 하나(1,000행 상한 없음)
CREATE OR REPLACE FUNCTION public.get_my_application_message_status()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT COALESCE(jsonb_object_agg(
           a.id::text,
           jsonb_build_object(
             'writable', public._application_message_writable(a.id),
             'ended_at', public._application_message_ended_at(a.id))),
         '{}'::jsonb)
    INTO v_result
    FROM public.applications a
   WHERE a.user_id = auth.uid();

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_my_application_message_status() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_my_application_message_status() TO authenticated;

-- ============================================================
-- send_application_message 재정의 — 323 본문 그대로, 종료 판정만 헬퍼 호출
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_application_message(
  p_application_id uuid,
  p_body           text,
  p_attachments    jsonb DEFAULT '[]'::jsonb
) RETURNS uuid  -- new message id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_kind text;
  v_sender_name text;
  v_app_owner   uuid;
  v_app_status  text;
  v_msg_id      uuid;
  v_rate_count  bigint;
  v_camp_title  text;         -- [PR 2 추가] 알림 title 생성용 캠페인명
BEGIN
  -- 응모 소유자 확인
  SELECT user_id, status INTO v_app_owner, v_app_status
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '応募が見つかりません';
  END IF;

  -- sender_kind 판별 (관리자 먼저 검사 — 관리자가 본인 응모도 있을 수 있음)
  IF public.is_admin() THEN
    v_sender_kind := 'admin';
    SELECT name INTO v_sender_name FROM public.admins WHERE auth_id = auth.uid();
  ELSIF v_app_owner = auth.uid() THEN
    v_sender_kind := 'influencer';
    SELECT name INTO v_sender_name FROM public.influencers WHERE id = auth.uid();
  ELSE
    RAISE EXCEPTION '権限がありません';
  END IF;

  -- 본문/첨부 빈값 검증
  IF (p_body IS NULL OR btrim(p_body) = '') AND (p_attachments IS NULL OR p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です';
  END IF;

  -- Rate limit: 사용자별 100건/시간 (사양서 §9 행 1310)
  -- [323] 일괄 발송(broadcast_id IS NOT NULL) 행은 이 한도 계산에서 제외.
  --       일괄 발송을 많이 돌린 관리자가 그 여파로 개별 응모건 답장까지
  --       막히는 것을 방지 — 마이그레이션 167 의 "개별 send 와 별도
  --       카운터" 주석을 실제 동작과 일치시킨다.
  SELECT count(*) INTO v_rate_count
    FROM public.application_messages
   WHERE sender_id = auth.uid()
     AND created_at > now() - interval '1 hour'
     AND broadcast_id IS NULL;

  IF v_rate_count >= 100 THEN
    RAISE EXCEPTION 'メッセージの送信上限（1時間に100件）に達しました。しばらく経ってからお試しください';
  END IF;

  -- 응모 종료 90일 경과 차단 (사양서 §3-3)
  -- 관리자는 90일 경과 후에도 발송 허용 (사후 안내 필요 케이스 대응)
  IF NOT public.is_admin() THEN
    -- [509] 종료 시각·90일 판정은 헬퍼 한 곳(_application_message_writable)에서 한다.
    IF NOT public._application_message_writable(p_application_id) THEN
      RAISE EXCEPTION '応募終了から90日経過しました。閲覧のみ可能です';
    END IF;
  END IF;

  INSERT INTO public.application_messages (
    application_id, sender_kind, sender_id, sender_name, body, attachments
  ) VALUES (
    p_application_id,
    v_sender_kind,
    auth.uid(),
    COALESCE(v_sender_name, '(이름미상)'),
    COALESCE(p_body, ''),
    COALESCE(p_attachments, '[]'::jsonb)
  )
  RETURNING id INTO v_msg_id;

  -- 자동 응대 처리 (결정 J, 사양서 §3-4 + §4-1-3):
  --   인플루언서 새 메시지 → application_message_resolutions 행 자동 DELETE (reopen)
  --   관리자 답장 → application_message_resolutions 자동 UPSERT (auto_replied)
  IF v_sender_kind = 'influencer' THEN
    DELETE FROM public.application_message_resolutions
     WHERE application_id = p_application_id;
  ELSE  -- v_sender_kind = 'admin'
    INSERT INTO public.application_message_resolutions (
      application_id,
      resolved_at,
      resolved_by,
      resolved_by_name,
      resolved_after_message_at,
      resolution_method
    ) VALUES (
      p_application_id,
      now(),
      auth.uid(),
      COALESCE(v_sender_name, '(이름미상)'),
      COALESCE(
        (SELECT max(created_at)
           FROM public.application_messages
          WHERE application_id = p_application_id
            AND sender_kind = 'influencer'
            AND hidden_by_admin_at IS NULL
            AND self_withdrawn_at IS NULL),
        now()  -- 인플루언서 메시지 없을 때 (관리자가 먼저 시작한 케이스) now() 폴백
      ),
      'auto_replied'
    )
    ON CONFLICT (application_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';
  END IF;

  -- ----------------------------------------------------------------
  -- [PR 2 추가] 관리자 발신 시 인플루언서에게 알림 INSERT
  --
  -- 조건: v_sender_kind = 'admin' (인플루언서 발신은 알림 불필요 — 관리자는 사이드바 배지)
  -- 중복 방지: 같은 응모건에 대한 기존 미읽음 message_received 알림이 있으면
  --            INSERT 하지 않음 (이미 읽지 않은 알림이 누적되지 않도록).
  --            → 인플루언서가 열어서 읽어야 dismiss 되고, 다음 메시지가 또 알림 생성.
  --
  -- notifications 컬럼 구조 (037 기준):
  --   id, user_id, kind, ref_table, ref_id, title, body, read_at, created_at
  -- ----------------------------------------------------------------
  IF v_sender_kind = 'admin' THEN
    -- 캠페인명 조회 (알림 title 생성용)
    SELECT c.title INTO v_camp_title
      FROM public.applications a
      JOIN public.campaigns c ON c.id = a.campaign_id
     WHERE a.id = p_application_id;

    -- 같은 응모건에 미읽음 message_received 알림이 없을 때만 INSERT
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
       WHERE user_id   = v_app_owner
         AND kind      = 'message_received'
         AND ref_table = 'applications'
         AND ref_id    = p_application_id
         AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_app_owner,
        'message_received',
        'applications',
        p_application_id,
        COALESCE(v_camp_title, '') || ' — 運営からメッセージが届きました',
        COALESCE(v_sender_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;
  END IF;

  RETURN v_msg_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.send_application_message(uuid, text, jsonb) IS
  '[144][hotfix-42702][145][323][509] 메시지 발송 원격 호출 함수. 인플루언서·관리자 공용, sender_kind 자동 판별. '
  'Rate limit: 사용자별 100건/시간(사양서 §9), broadcast_id IS NULL 인 행만 집계(323 — 일괄 발송은 별도 카운터). '
  '관리자 답장 시 resolutions 자동 UPSERT + 인플루언서 알림(message_received) INSERT. '
  '인플루언서 발신은 알림 없음 (관리자는 사이드바 미읽음 배지로 처리). '
  '미읽음 message_received 알림이 이미 있으면 중복 INSERT 안 함. '
  '인플루언서는 응모 종료 90일 초과 시 발송 차단. SECURITY DEFINER + search_path 고정.';


COMMIT;
