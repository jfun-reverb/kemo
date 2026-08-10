-- ============================================================
-- 323_individual_message_rate_limit_exclude_bulk.sql
-- 전수조사 후속 묶음 F — F-14: 일괄 발송이 개별 발송 시간당 한도를 잡아먹는 문제
--
-- 계보(send_application_message 를 건드린 마이그레이션 — 재정의 시 항상
--   최신 파일을 원본으로 삼을 것, feedback_function_redefine_latest_base
--   재발 방지):
--   144(원본) → 145(현재 유효한 원본 — 관리자 발신 시 알림 INSERT 추가)
--   → 323(이 파일, 시간당 한도 계산에서 일괄 발송 행 제외)
--   ※ send_application_message_bulk 는 별개 함수다. 그쪽 계보는
--     167(원본) → 168(현재 유효한 원본 — p_title 파라미터 추가) 이고
--     이 파일에서는 건드리지 않는다.
--
-- 배경:
--   응모건 메시지 개별 발송(send_application_message)에는 "사용자별 시간당
--   100건" 한도가 있다. 그 계산은 application_messages 표에서
--   sender_id = auth.uid() AND created_at > now() - interval '1 hour'
--   조건으로 행 수를 세는 방식이다.
--
--   그런데 관리자 일괄 발송(send_application_message_bulk, 마이그레이션 167)이
--   넣는 행도 sender_id 가 그 관리자 자신이다. application_messages 에는
--   개별 발송이든 일괄 발송이든 구분 없이 같은 표에 쌓이고, 일괄 발송 행만
--   broadcast_id 가 채워진다(NULL 이 아님 — 마이그레이션 144 에서
--   broadcast_id uuid NULL, 부분 인덱스 WHERE broadcast_id IS NOT NULL).
--
--   그 결과, 어느 관리자가 100명 넘게 일괄 발송을 한 번 돌리면 —
--   200명 한도 이내라 일괄 발송 자체는 성공하지만 — 그 순간부터 한 시간
--   동안 같은 관리자는 개별 응모건에 답장을 단 한 통도 보낼 수 없게 된다.
--   "일괄 발송 시간당 횟수는 무제한(개별 send 의 100건/시간 한도와 별도
--   카운터)"이라는 마이그레이션 167 의 주석과 실제 동작이 어긋나 있었다 —
--   카운터가 나뉘어 있지 않고 같은 표·같은 sender_id 조건으로 합산됐다.
--
--   이 파일이 그 조건에 "AND broadcast_id IS NULL"을 추가해, 개별 발송
--   시간당 한도 계산에서 일괄 발송으로 들어간 행을 뺀다. 이제야 마이그레이션
--   167 의 그 주석이 사실이 된다.
--
-- 변경 범위 — 시간당 한도 계산 조건 1곳만:
--   기존: WHERE sender_id = auth.uid() AND created_at > now() - interval '1 hour'
--   변경: WHERE sender_id = auth.uid() AND created_at > now() - interval '1 hour'
--         AND broadcast_id IS NULL
--   그 외 함수 본문(sender_kind 판별·90일 차단·자동 응대·알림 INSERT 등)은
--   145 의 정의와 완전히 동일하다. COMMENT ON FUNCTION 은 이번 변경 사실을
--   반영하도록 문구만 갱신했다(로직 아님).
--
-- 한도 우회 가능성 검토(사용자 확인 필요 없음 — 새 구멍이 아니라는 판단 근거):
--   일괄 발송(send_application_message_bulk, 마이그레이션 167→168)의 함수
--   본문 자체에는 애초에 "시간당 몇 건"을 세는 코드가 없다. 그 함수가 가진
--   유일한 빈도 관련 가드는 ① is_campaign_admin() 권한(관리자 전용,
--   일반 인플루언서는 호출 불가) ② 1회 호출당 최대 200명 상한뿐이다.
--   즉 일괄 발송은 이 마이그레이션 이전에도 "시간당 횟수 무제한"이었다 —
--   개별 발송 카운터에 함께 잡혀 있던 것은 일괄 발송 자체를 막는 효과가
--   아니라, 일괄 발송을 많이 한 관리자의 "다른 기능인 개별 답장"을 부수
--   작용으로 막는 결함이었다. 이번 변경은 그 결함을 없앨 뿐, 일괄 발송
--   쪽에 새로운 능력을 추가하지 않는다. 관리자가 인원 1명짜리 일괄 발송을
--   여러 번 반복해 개별 100건/시간 한도를 우회하는 경로는 이 변경 전에도
--   이미 열려 있었다(일괄 발송 함수에 자체 시간당 상한이 없으므로) —
--   이번 변경으로 새로 열리는 것이 아니다.
--
--   ⚠️ 다만 이 조사에서 "일괄 발송 자체의 시간당 상한이 없다"는 사실이
--   확인됐다. 이는 이번 F-14 범위 밖이라 이 마이그레이션에서 고치지
--   않는다 — 후속 검토 대상으로만 남긴다.
--
-- 운영 적용 시 주의점:
--   응모건 메시지 개별 발송(send_application_message)은 이미 운영에
--   배포되어 있다(PR 1·2, 2026-05-28). 반면 일괄 발송(send_application_message_bulk)
--   은 CLAUDE.md 기준 "개발서버 구현 완료·운영 보류(약관 게이트)" 상태로,
--   운영 서버 application_messages 표에는 아직 broadcast_id 가 채워진 행이
--   없다. 즉 이 마이그레이션을 운영에 적용해도 "AND broadcast_id IS NULL"
--   조건은 운영에서는 지금 당장 결과에 영향이 없다(모든 기존 행이 이미
--   broadcast_id IS NULL) — 안전하게 먼저 반영해 둘 수 있다는 뜻이다.
--   일괄 발송이 나중에 운영 배포될 때 이 마이그레이션이 먼저 들어가 있지
--   않으면, 오늘 개발서버에서 확인한 것과 같은 증상(일괄 발송 많이 한
--   관리자가 개별 답장을 못 하는 현상)이 운영에서도 재현된다.
--
-- 롤백:
--   BEGIN;
--   -- 145 원본으로 되돌리기 (broadcast_id 조건 제거) — 145 파일
--   -- 101~284행을 그대로 재실행하면 된다.
--   COMMIT;
-- ============================================================

BEGIN;


-- ============================================================
-- send_application_message 재정의 — 시간당 한도 계산에서 일괄 발송 행 제외
--
-- 145 의 정의를 베이스로, 시간당 한도 계산 쿼리에
-- "AND broadcast_id IS NULL" 한 줄만 추가한다. 그 외 로직은 무변경.
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
  v_ended_at    timestamptz;  -- 응모 종료 시각 (90일 차단 판별용)
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
  -- nested DECLARE 제거 — 함수 상단 v_ended_at 사용 (핫픽스에서 평탄화)
  IF NOT public.is_admin() THEN
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
    INTO v_ended_at
    FROM public.applications a
    WHERE a.id = p_application_id;

    IF v_ended_at IS NOT NULL AND v_ended_at < now() - interval '90 days' THEN
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
  '[144][hotfix-42702][145][323] 메시지 발송 원격 호출 함수. 인플루언서·관리자 공용, sender_kind 자동 판별. '
  'Rate limit: 사용자별 100건/시간(사양서 §9), broadcast_id IS NULL 인 행만 집계(323 — 일괄 발송은 별도 카운터). '
  '관리자 답장 시 resolutions 자동 UPSERT + 인플루언서 알림(message_received) INSERT. '
  '인플루언서 발신은 알림 없음 (관리자는 사이드바 미읽음 배지로 처리). '
  '미읽음 message_received 알림이 이미 있으면 중복 INSERT 안 함. '
  '인플루언서는 응모 종료 90일 초과 시 발송 차단. SECURITY DEFINER + search_path 고정.';


COMMIT;


-- ============================================================
-- 검증 조회 (운영/개발 SQL 편집기에서 1단계씩 실행)
--
-- ① 함수가 재정의됐는지 — 함수 정의 본문에 "broadcast_id IS NULL" 문자열이
--    있는지 확인. 있으면 이 마이그레이션이 반영된 것.
--
--   SELECT prosrc LIKE '%broadcast_id IS NULL%' AS is_323_applied
--     FROM pg_proc
--    WHERE proname = 'send_application_message'
--      AND pronamespace = 'public'::regnamespace;
--
-- ② 일괄 발송 행이 실제로 한도 계산에서 빠지는지 — 최근 1시간 이내
--    발신자별로 "전체 행 수"와 "개별(broadcast_id IS NULL) 행 수"를
--    나란히 비교. 일괄 발송을 한 관리자가 있다면 두 숫자가 달라야 한다
--    (달라야 정상 — 같으면 그 관리자는 최근 1시간 내 일괄 발송을
--    안 한 것일 수 있으니 그 자체로 결함 신호는 아님).
--
--   SELECT sender_id,
--          count(*)                                   AS total_last_hour,
--          count(*) FILTER (WHERE broadcast_id IS NULL) AS individual_only_last_hour
--     FROM public.application_messages
--    WHERE sender_kind = 'admin'
--      AND created_at > now() - interval '1 hour'
--    GROUP BY sender_id
--    ORDER BY total_last_hour DESC;
-- ============================================================
