-- ============================================================
-- 패치: 2026-05-20-msg-42702-hotfix.sql
--
-- 목적:
--   마이그레이션 144 (응모건 메시지 기능 DB 인프라) 적용 후
--   PostgreSQL 에러 42702(컬럼 모호성) 핫픽스.
--   get_application_messages 함수의 SELECT 절에서
--   반환 컬럼 이름과 테이블 컬럼 이름이 충돌 → #variable_conflict use_column 지시어로 해소.
--
-- 원인:
--   RETURNS TABLE 절의 컬럼 이름(application_id, self_withdrawn_at 등)이
--   FROM 절의 application_messages 테이블 컬럼과 동일해 PostgreSQL이 모호성 에러 발생.
--   #variable_conflict use_column 지시어로 테이블 컬럼을 우선하도록 지정.
--
-- 적용 대상:
--   개발서버(qysmxtipobomefudyixw) SQL Editor — 1회 실행
--   (144 전체가 이미 적용된 상태에서 함수 정의만 교체)
--
-- 적용 함수:
--   1. public.send_application_message(uuid, text, jsonb)
--   2. public.get_application_messages(uuid)
--
-- 주의:
--   DROP TABLE, DROP/ALTER COLUMN 등 구조 변경 없음.
--   CREATE OR REPLACE FUNCTION 으로 함수 정의만 교체.
--
-- 롤백:
--   해당 없음 — 144 전체 롤백이 필요할 경우 144 파일 헤더의 롤백 블록 사용.
-- ============================================================


-- ============================================================
-- 1. send_application_message
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
  SELECT count(*) INTO v_rate_count
    FROM public.application_messages
   WHERE sender_id = auth.uid()
     AND created_at > now() - interval '1 hour';

  IF v_rate_count >= 100 THEN
    RAISE EXCEPTION 'メッセージの送信上限（1時間に100件）に達しました。しばらく経ってからお試しください';
  END IF;

  -- 응모 종료 90일 경과 차단 (사양서 §3-3)
  -- 관리자는 90일 경과 후에도 발송 허용 (사후 안내 필요 케이스 대응)
  -- 종료 시각 계산:
  --   1) cancelled_at IS NOT NULL → cancelled_at
  --   2) status='rejected' → reviewed_at
  --   3) status='approved' + 해당 응모의 모든 deliverables 가 approved → 마지막 deliverable.reviewed_at
  --   4) 위 모두 아니면 (진행 중) → NULL (차단 없음)
  IF NOT public.is_admin() THEN
    -- 응모 종료 90일 경과 차단 — nested DECLARE 제거하고 함수 상단 v_ended_at 사용
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

  RETURN v_msg_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message(uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.send_application_message(uuid, text, jsonb) IS
  '[144][hotfix-42702] 메시지 발송 RPC. 인플루언서·관리자 공용, sender_kind 자동 판별. '
  'Rate limit: 사용자별 100건/시간 (사양서 §9 행 1310, application_messages 집계). '
  '관리자 답장 시 resolutions 자동 UPSERT, 인플루언서 새 메시지 시 자동 DELETE(reopen). '
  '인플루언서는 응모 종료 90일 초과 시 발송 차단. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 2. get_application_messages
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_application_messages(
  p_application_id uuid
) RETURNS TABLE (
  id                      uuid,
  application_id          uuid,
  sender_kind             text,
  sender_name             text,
  body                    text,        -- 마스킹 시 NULL
  attachments             jsonb,       -- 마스킹 시 '[]'::jsonb
  created_at              timestamptz,
  read_by_influencer_at   timestamptz,
  broadcast_id            uuid,
  hidden_by_admin_at      timestamptz,
  self_withdrawn_at       timestamptz,
  self_withdrawn_by_kind  text,
  mask_state              text         -- 'visible' | 'hidden_by_admin' | 'self_withdrawn_influencer' | 'self_withdrawn_admin'
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller_is_admin  boolean;
  v_app_owner        uuid;
BEGIN
  -- 응모 소유자 확인
  SELECT user_id INTO v_app_owner
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '応募が見つかりません';
  END IF;

  -- 호출자 권한 판별
  v_caller_is_admin := public.is_admin();

  -- 인플루언서 본인 또는 관리자가 아니면 차단
  IF NOT v_caller_is_admin AND v_app_owner <> auth.uid() THEN
    RAISE EXCEPTION '権限がありません';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.application_id,
    m.sender_kind,
    m.sender_name,
    -- body 마스킹 분기
    CASE
      WHEN v_caller_is_admin THEN
        -- 관리자: 인플루언서 본인 회수(케이스 E)만 마스킹
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL  -- 케이스 E: 양쪽 마스킹 (관리자도 못 봄)
          ELSE m.body  -- 케이스 D(강제숨김), F(관리자회수), G(visible) 모두 원본 유지
        END
      ELSE
        -- 인플루언서: 강제 숨김(A) 또는 회수(B) 시 마스킹
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL  -- 케이스 A
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL  -- 케이스 B
          ELSE m.body                                      -- 케이스 C
        END
    END AS body,
    -- attachments 마스킹 분기 (body 와 동일 로직)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN '[]'::jsonb
          ELSE m.attachments
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN '[]'::jsonb
          WHEN m.self_withdrawn_at  IS NOT NULL THEN '[]'::jsonb
          ELSE m.attachments
        END
    END AS attachments,
    m.created_at,
    m.read_by_influencer_at,
    m.broadcast_id,
    m.hidden_by_admin_at,
    m.self_withdrawn_at,
    m.self_withdrawn_by_kind,
    -- mask_state 계산
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          -- 우선순위: 인플루언서 본인 회수(E)를 D보다 먼저 판별
          -- (혹시 hidden_by_admin_at + self_withdrawn_at 둘 다 있는 예외 케이스 대비)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'  -- 케이스 E
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'            -- 케이스 D
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'       -- 케이스 F
          ELSE 'visible'                      -- 케이스 G
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'                    -- 케이스 A
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'           -- 케이스 B (본인 회수)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'               -- 케이스 B (관리자 회수)
          ELSE 'visible'                              -- 케이스 C
        END
    END AS mask_state
  FROM public.application_messages m
  WHERE m.application_id = p_application_id
  ORDER BY m.created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_application_messages(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_application_messages(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_application_messages(uuid) IS
  '[144][hotfix-42702] 응모건 메시지 목록 조회 RPC. 서버 측 마스킹 처리 (사양서 §9). '
  '#variable_conflict use_column 으로 RETURNS TABLE 컬럼명 vs 테이블 컬럼명 42702 모호성 해소. '
  '인플루언서: 강제숨김+회수 시 body=NULL, attachments=[]. '
  '관리자: 인플루언서 본인 회수만 양쪽 마스킹, 강제숨김·관리자회수는 원본 유지 (비대칭). '
  'mask_state: visible|hidden_by_admin|self_withdrawn_influencer|self_withdrawn_admin. '
  'SECURITY DEFINER + search_path 고정.';
