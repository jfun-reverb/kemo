-- ============================================================
-- 144_application_messages.sql
-- 2026-05-20
--
-- 목적:
--   인플루언서 ↔ 관리자 양방향 메시지 기능 — PR 1 DB 인프라.
--   응모건(applications) 단위 1:1 메시지 채널 + 관리자 일괄 발송(BCC) 지원.
--
-- 사양서:
--   docs/specs/2026-05-15-application-messaging.md §4
--
-- 신설 테이블 5개:
--   1. application_messages          — 메시지 본체
--   2. application_message_admin_reads — 관리자 개인별 읽음 추적
--   3. application_message_resolutions — 응모건 응대 완료 상태
--   4. application_message_broadcasts  — 일괄 발송 그룹 메타
--   5. application_message_hide_history — 숨김·회수 감사 이력
--
-- 신설 뷰:
--   application_message_summary — 응모건별 미읽음·미응대 집계
--
-- 신설 함수 4개:
--   application_message_admin_unread_counts — 관리자 본인 미읽음 수 집계
--   send_application_message                — 메시지 발송 (인플루언서·관리자 공용)
--   mark_application_messages_read         — 읽음 처리
--   withdraw_own_message                    — 본인 메시지 회수 (25분 한도)
--
-- lookup_values 시드:
--   kind='message_hide_reason' 7건 (숨김 사유 카테고리)
--
-- Storage:
--   버킷 'application-message-attachments' (비공개, 2MB, jpg/png/webp)
--   + Storage 정책 4개
--
-- PR 1 제외 (PR 2/3 에서 추가):
--   mark_application_resolved (수동 응대 완료, PR 2)
--   hide_application_message / unhide_application_message (PR 2)
--   send_application_message_bulk (일괄 발송, PR 3)
--   withdraw_broadcast (일괄 회수, PR 3)
--
-- 전제 조건:
--   마이그레이션 143 (campaign_promo_digest) 적용 완료
--   public.applications, public.campaigns, public.influencers, public.admins 존재
--   public.is_admin() / public.is_super_admin() / public.is_campaign_admin() 함수 존재
--
-- 보안 반영 (145 통합):
--   뷰 application_message_summary — WITH (security_invoker = true) 포함
--   함수 application_message_admin_unread_counts — is_admin() 가드 + LANGUAGE plpgsql 포함
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 롤백:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.withdraw_own_message(uuid);
--   DROP FUNCTION IF EXISTS public.mark_application_messages_read(uuid);
--   DROP FUNCTION IF EXISTS public.send_application_message(uuid, text, jsonb);
--   DROP FUNCTION IF EXISTS public.application_message_admin_unread_counts(uuid);
--   DROP VIEW  IF EXISTS public.application_message_summary;
--   DROP TABLE IF EXISTS public.application_message_hide_history;
--   DROP TABLE IF EXISTS public.application_message_admin_reads;
--   DROP TABLE IF EXISTS public.application_message_resolutions;
--   -- application_messages.broadcast_id 컬럼 제거 후 broadcasts 테이블 DROP
--   ALTER TABLE public.application_messages DROP COLUMN IF EXISTS broadcast_id;
--   DROP TABLE IF EXISTS public.application_message_broadcasts;
--   DROP TABLE IF EXISTS public.application_messages;
--   DELETE FROM public.lookup_values WHERE kind = 'message_hide_reason';
--   DELETE FROM storage.objects WHERE bucket_id = 'application-message-attachments';
--   DELETE FROM storage.buckets WHERE id = 'application-message-attachments';
--   COMMIT;
-- ============================================================

BEGIN;


-- ============================================================
-- 1. application_messages — 메시지 본체
-- ============================================================
CREATE TABLE public.application_messages (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid        NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  sender_kind     text        NOT NULL CHECK (sender_kind IN ('influencer','admin')),
  sender_id       uuid        NOT NULL,        -- auth.uid
  sender_name     text        NOT NULL,        -- 스냅샷 (관리자 이름 / 인플루언서 이름)
  body            text        NOT NULL
    CHECK (btrim(body) <> '' OR attachments <> '[]'::jsonb),
  attachments     jsonb       NOT NULL DEFAULT '[]'::jsonb,  -- [{path, name, size, mime}]
  created_at      timestamptz NOT NULL DEFAULT now(),
  read_by_influencer_at timestamptz NULL,
  -- 강제 숨김 (관리자 행위) — 마지막 상태 캐시. 상세 이력은 application_message_hide_history
  hidden_by_admin_at  timestamptz NULL,
  hidden_by_admin_id  uuid        NULL,
  hidden_reason_code  text        NULL,   -- lookup_values(kind='message_hide_reason').code
  hidden_reason_memo  text        NULL,   -- 자유 메모
  -- 본인 회수 (25분 한도) — sender_kind 별로 인플루언서·관리자 화면 노출 비대칭
  self_withdrawn_at      timestamptz NULL,
  self_withdrawn_by_kind text        NULL CHECK (self_withdrawn_by_kind IN ('influencer','admin')),
  -- 메일 발송 큐 (지연 발송 정책) — 관리자 메시지 INSERT 시 계산.
  -- 인플루언서 → 관리자 메시지는 모두 NULL (관리자는 사이드바 배지·일별 다이제스트로 처리)
  email_send_at     timestamptz NULL,
  email_sent_at     timestamptz NULL,
  email_skip_reason text        NULL CHECK (email_skip_reason IN
    ('read_in_time','rate_limited_24h','cancelled','merged_into_other'))
);

CREATE INDEX idx_application_messages_app_created
  ON public.application_messages (application_id, created_at);

ALTER TABLE public.application_messages ENABLE ROW LEVEL SECURITY;

-- SELECT 정책 — 행 가시성만 RLS. 본문·첨부 마스킹은 get_application_messages RPC 경유
CREATE POLICY "influencer_read_own_application_messages"
  ON public.application_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = application_id
         AND a.user_id = auth.uid()
    )
  );

CREATE POLICY "admin_read_all_messages"
  ON public.application_messages FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 는 SECURITY DEFINER RPC 경유만 (sender_kind 변조 방지)
-- 직접 INSERT/UPDATE 정책 없음 — RPC 함수 owner(postgres role)가 BYPASSRLS 보유


-- ============================================================
-- 2. application_message_broadcasts — 일괄 발송 그룹 메타
--    (broadcast_id 참조 외래 키를 application_messages 가 참조하므로 선행 생성)
-- ============================================================
CREATE TABLE public.application_message_broadcasts (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id       uuid        NOT NULL,
  sender_name     text        NOT NULL,
  body            text        NOT NULL,
  attachments     jsonb       NOT NULL DEFAULT '[]'::jsonb,
  recipient_count integer     NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- 발송 컨텍스트 추적
  context_kind        text NOT NULL CHECK (context_kind IN ('campaign','manual')),
  context_campaign_id uuid NULL REFERENCES public.campaigns(id) ON DELETE SET NULL,
  context_filter      jsonb NULL,  -- 적용한 필터 스냅샷 (status·channel·follower_min 등)
  -- 일괄 회수 (withdraw_broadcast RPC 가 함께 UPDATE, PR 3 구현)
  withdrawn_at          timestamptz NULL,
  withdrawn_by          uuid        NULL,
  withdrawn_reason_code text        NULL,  -- lookup_values(kind='message_hide_reason').code
  withdrawn_reason_memo text        NULL
);

CREATE INDEX idx_broadcasts_sender_created
  ON public.application_message_broadcasts (sender_id, created_at DESC);

CREATE INDEX idx_broadcasts_campaign
  ON public.application_message_broadcasts (context_campaign_id, created_at DESC)
  WHERE context_campaign_id IS NOT NULL;

ALTER TABLE public.application_message_broadcasts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_read_broadcasts"
  ON public.application_message_broadcasts FOR SELECT
  USING (public.is_admin());

-- INSERT 는 send_application_message_bulk RPC 경유만 (PR 3 구현)
-- UPDATE 는 withdraw_broadcast RPC 경유만 (PR 3 구현)


-- ============================================================
-- 3. application_messages.broadcast_id 컬럼 추가
--    (broadcasts 테이블 생성 후 참조 가능)
-- ============================================================
ALTER TABLE public.application_messages
  ADD COLUMN broadcast_id uuid NULL
  REFERENCES public.application_message_broadcasts(id) ON DELETE SET NULL;

CREATE INDEX idx_application_messages_broadcast
  ON public.application_messages (broadcast_id)
  WHERE broadcast_id IS NOT NULL;

COMMENT ON COLUMN public.application_messages.broadcast_id IS
  '[144] 일괄 발송으로 생성된 메시지면 broadcast 그룹 ID. 개별 발송이면 NULL';


-- ============================================================
-- 4. application_message_admin_reads — 관리자 개인별 읽음 추적
-- ============================================================
CREATE TABLE public.application_message_admin_reads (
  message_id    uuid        NOT NULL REFERENCES public.application_messages(id) ON DELETE CASCADE,
  admin_auth_id uuid        NOT NULL,
  read_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, admin_auth_id)
);

CREATE INDEX idx_admin_reads_admin
  ON public.application_message_admin_reads (admin_auth_id, read_at DESC);

ALTER TABLE public.application_message_admin_reads ENABLE ROW LEVEL SECURITY;

-- 본인 읽음 기록만 SELECT (다른 관리자가 언제 봤는지는 노출 안 함)
CREATE POLICY "admin_read_own_reads"
  ON public.application_message_admin_reads FOR SELECT
  USING (admin_auth_id = auth.uid() AND public.is_admin());

-- INSERT 는 mark_application_messages_read RPC 경유만
-- (직접 INSERT 정책 추가 시 RPC 우회 위험)


-- ============================================================
-- 5. application_message_resolutions — 응모건 응대 완료 상태
-- ============================================================
CREATE TABLE public.application_message_resolutions (
  application_id            uuid        PRIMARY KEY
    REFERENCES public.applications(id) ON DELETE CASCADE,
  resolved_at               timestamptz NOT NULL DEFAULT now(),
  resolved_by               uuid        NOT NULL,
  resolved_by_name          text        NOT NULL,
  resolved_after_message_at timestamptz NOT NULL,  -- 응대 완료 시점의 마지막 메시지 시각
  resolution_method         text        NOT NULL
    CHECK (resolution_method IN ('auto_replied','manual'))
);

ALTER TABLE public.application_message_resolutions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_read_resolutions"
  ON public.application_message_resolutions FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 는 RPC 경유만
-- 자동 처리: send_application_message RPC 끝부분 (결정 J)
-- 수동 처리: mark_application_resolved RPC (PR 2 구현)


-- ============================================================
-- 6. application_message_hide_history — 숨김·회수 감사 이력
-- ============================================================
CREATE TABLE public.application_message_hide_history (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id   uuid        NOT NULL
    REFERENCES public.application_messages(id) ON DELETE CASCADE,
  action       text        NOT NULL
    CHECK (action IN ('hide','unhide','self_withdraw','broadcast_withdraw')),
  by_user_kind text        NOT NULL CHECK (by_user_kind IN ('influencer','admin')),
  by_user_id   uuid        NOT NULL,
  by_name      text        NOT NULL,
  reason_code  text        NULL,  -- lookup_values(kind='message_hide_reason').code. self_withdraw 는 NULL
  reason_memo  text        NULL,
  at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_message_hide_history_message_at
  ON public.application_message_hide_history (message_id, at);

ALTER TABLE public.application_message_hide_history ENABLE ROW LEVEL SECURITY;

-- super_admin 만 SELECT — 운영팀 내부 부당 숨김 사례 감지·분쟁 대응용
CREATE POLICY "super_admin_read_hide_history"
  ON public.application_message_hide_history FOR SELECT
  USING (public.is_super_admin());

-- INSERT 는 hide/unhide/withdraw RPC 경유만 (SECURITY DEFINER, BYPASSRLS)


-- ============================================================
-- 7. 뷰 application_message_summary — 응모건별 집계
-- ============================================================
CREATE OR REPLACE VIEW public.application_message_summary
  WITH (security_invoker = true)
AS
SELECT
  a.id          AS application_id,
  a.user_id     AS influencer_id,
  a.campaign_id,
  -- message_count: 강제 숨김 제외 (self_withdrawn 포함 — placeholder 표시됨)
  count(m.*) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS message_count,
  -- 인플루언서 미열람: 관리자 회수 메시지는 본문 못 보므로 제외
  count(m.*) FILTER (
    WHERE m.sender_kind = 'admin'
      AND m.read_by_influencer_at IS NULL
      AND m.hidden_by_admin_at IS NULL
      AND m.self_withdrawn_at IS NULL
  ) AS unread_for_influencer,
  -- 미응대: resolutions 없거나 마지막 인플루언서 메시지(살아있는 것)가 응대 완료 시점 이후
  CASE
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind = 'influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) IS NULL THEN false
    WHEN r.resolved_after_message_at IS NULL THEN true
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind = 'influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) > r.resolved_after_message_at THEN true
    ELSE false
  END AS unresolved_for_admin_team,
  max(m.created_at) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS last_message_at
FROM public.applications a
LEFT JOIN public.application_messages m ON m.application_id = a.id
LEFT JOIN public.application_message_resolutions r ON r.application_id = a.id
GROUP BY a.id, a.user_id, a.campaign_id, r.resolved_after_message_at;


-- ============================================================
-- 8. 함수 application_message_admin_unread_counts
--    관리자 본인 기준 응모건별 미읽음 수 집계
-- ============================================================
CREATE OR REPLACE FUNCTION public.application_message_admin_unread_counts(
  p_admin_auth_id uuid DEFAULT NULL  -- NULL 이면 auth.uid() 사용
) RETURNS TABLE (application_id uuid, unread_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  -- 관리자 전용 가드: 인플루언서가 호출하면 전체 미읽음 집계가 노출되는 취약점 차단
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '관리자 전용 함수입니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    m.application_id,
    count(*) AS unread_count
  FROM public.application_messages m
  LEFT JOIN public.application_message_admin_reads r
    ON r.message_id = m.id
   AND r.admin_auth_id = COALESCE(p_admin_auth_id, auth.uid())
  WHERE m.sender_kind = 'influencer'
    AND m.hidden_by_admin_at IS NULL
    AND m.self_withdrawn_at IS NULL  -- 인플루언서 본인 회수 메시지는 관리자 미읽음 집계에서 제외
    AND r.message_id IS NULL         -- 본인이 안 읽음
  GROUP BY m.application_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.application_message_admin_unread_counts(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.application_message_admin_unread_counts(uuid) TO authenticated;

COMMENT ON FUNCTION public.application_message_admin_unread_counts(uuid) IS
  '[144] 관리자 본인 기준 응모건별 미읽음 인플루언서 메시지 수 집계. '
  'is_admin() 가드 포함 — 비관리자 호출 시 insufficient_privilege 예외. '
  'LANGUAGE plpgsql (RAISE EXCEPTION 사용 위해). 집계 로직은 설계 원안과 동일. '
  'p_admin_auth_id NULL = auth.uid(). SECURITY DEFINER + search_path 고정. '
  '인플루언서 GNB 미읽음 배지는 application_message_summary 뷰(security_invoker=true)로 직접 조회.';


-- ============================================================
-- 9. RPC send_application_message
--    메시지 발송 (인플루언서·관리자 공용, sender_kind 자동 판별)
--    결정 J: 관리자 답장 → resolutions 자동 UPSERT
--            인플루언서 새 메시지 → resolutions 자동 DELETE (reopen)
--    Rate limit: 사용자별 100건/시간 (사양서 §9 행 1310)
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
    DECLARE
      v_ended_at timestamptz;
    BEGIN
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
    END;
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
  '[144] 메시지 발송 RPC. 인플루언서·관리자 공용, sender_kind 자동 판별. '
  'Rate limit: 사용자별 100건/시간 (사양서 §9 행 1310, application_messages 집계). '
  '관리자 답장 시 resolutions 자동 UPSERT, 인플루언서 새 메시지 시 자동 DELETE(reopen). '
  '인플루언서는 응모 종료 90일 초과 시 발송 차단. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 10. RPC mark_application_messages_read
--     읽음 처리 (인플루언서·관리자 공용)
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_application_messages_read(
  p_application_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_role  text;
  v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.applications WHERE id = p_application_id;

  IF public.is_admin() THEN
    v_role := 'admin';
  ELSIF v_owner = auth.uid() THEN
    v_role := 'influencer';
  ELSE
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  IF v_role = 'admin' THEN
    -- 관리자: 본인이 안 읽은 인플루언서 메시지를 application_message_admin_reads 에 UPSERT
    INSERT INTO public.application_message_admin_reads (message_id, admin_auth_id, read_at)
    SELECT m.id, auth.uid(), now()
      FROM public.application_messages m
     WHERE m.application_id = p_application_id
       AND m.sender_kind = 'influencer'
       AND m.hidden_by_admin_at IS NULL
    ON CONFLICT (message_id, admin_auth_id) DO NOTHING;
  ELSE
    -- 인플루언서: 관리자 메시지를 read_by_influencer_at 일괄 UPDATE
    UPDATE public.application_messages
       SET read_by_influencer_at = now()
     WHERE application_id = p_application_id
       AND sender_kind = 'admin'
       AND read_by_influencer_at IS NULL
       AND hidden_by_admin_at IS NULL;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mark_application_messages_read(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mark_application_messages_read(uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_application_messages_read(uuid) IS
  '[144] 읽음 처리 RPC. '
  '관리자: application_message_admin_reads UPSERT. '
  '인플루언서: application_messages.read_by_influencer_at 일괄 UPDATE. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 11. RPC withdraw_own_message
--     본인 메시지 회수 (25분 한도, 인플루언서·관리자 공용)
--     Rate limit: 사용자별 50건/시간 (사양서 §9 행 1309)
--                 application_message_hide_history(action='self_withdraw') 집계
--     첨부 Storage 삭제는 클라이언트가 RPC 반환 후 별도 처리:
--       1안: 클라이언트가 storage.from('application-message-attachments').remove([...])
--       2안: pg_cron 5분 주기 cleanup Edge Function (개발 세션 결정)
-- ============================================================
CREATE OR REPLACE FUNCTION public.withdraw_own_message(
  p_message_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id   uuid;
  v_sender_kind text;
  v_created_at  timestamptz;
  v_sender_name text;
  v_rate_count  bigint;
BEGIN
  SELECT sender_id, sender_kind, created_at, sender_name
    INTO v_sender_id, v_sender_kind, v_created_at, v_sender_name
    FROM public.application_messages
   WHERE id = p_message_id;

  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION 'メッセージが見つかりません';
  END IF;

  -- 발신자 본인 검증
  IF v_sender_id <> auth.uid() THEN
    RAISE EXCEPTION '自分のメッセージのみ取り消し可能です';
  END IF;

  -- 25분 한도 검증
  IF v_created_at < now() - interval '25 minutes' THEN
    RAISE EXCEPTION '取り消し可能時間（25分）を過ぎています';
  END IF;

  -- 이미 처리된 메시지 차단
  IF EXISTS (
    SELECT 1 FROM public.application_messages
     WHERE id = p_message_id
       AND (hidden_by_admin_at IS NOT NULL OR self_withdrawn_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION '既に取り消し・非表示処理済みのメッセージです';
  END IF;

  -- Rate limit: 사용자별 50건/시간 (사양서 §9 행 1309)
  -- application_message_hide_history 에서 최근 1시간 self_withdraw 건수 집계
  SELECT count(*) INTO v_rate_count
    FROM public.application_message_hide_history
   WHERE by_user_id = auth.uid()
     AND action = 'self_withdraw'
     AND at > now() - interval '1 hour';

  IF v_rate_count >= 50 THEN
    RAISE EXCEPTION 'メッセージ取り消しの上限（1時間に50件）に達しました。しばらく経ってからお試しください';
  END IF;

  UPDATE public.application_messages
     SET self_withdrawn_at      = now(),
         self_withdrawn_by_kind = v_sender_kind
   WHERE id = p_message_id;

  -- 감사 이력 추가 (hide_history 에 기록 — rate limit 집계 소스이기도 함)
  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id, 'self_withdraw', v_sender_kind, auth.uid(), v_sender_name, NULL, NULL
  );

  -- 메일 발송 자동 cancel (email_send_at 도래 전이면)
  UPDATE public.application_messages
     SET email_skip_reason = 'cancelled'
   WHERE id = p_message_id
     AND email_send_at IS NOT NULL
     AND email_send_at > now()
     AND email_sent_at IS NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.withdraw_own_message(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.withdraw_own_message(uuid) TO authenticated;

COMMENT ON FUNCTION public.withdraw_own_message(uuid) IS
  '[144] 본인 메시지 회수 RPC. 25분 한도, 인플루언서·관리자 공용. '
  'Rate limit: 사용자별 50건/시간 (사양서 §9 행 1309, hide_history action=self_withdraw 집계). '
  '첨부 Storage 삭제는 클라이언트 또는 cleanup Edge Function 에서 별도 처리. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 12. lookup_values — message_hide_reason 시드 7건
--     숨김·강제회수 사유 카테고리 (사양서 §3-5)
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('message_hide_reason', 'inappropriate_expression', '부적절한 표현',    '不適切な表現',         10, true),
  ('message_hide_reason', 'personal_info_leak',       '개인정보 노출',     '個人情報の漏洩',       20, true),
  ('message_hide_reason', 'defamation',               '명예훼손',          '名誉毀損',             30, true),
  ('message_hide_reason', 'spam',                     '스팸·광고',         'スパム・広告',         40, true),
  ('message_hide_reason', 'wrong_recipient',          '잘못 발송',         '誤送信',               50, true),
  ('message_hide_reason', 'influencer_request',       '인플루언서 요청',   'インフルエンサーからの依頼', 60, true),
  ('message_hide_reason', 'other',                    '기타',              'その他',               70, true)
ON CONFLICT DO NOTHING;


-- ============================================================
-- 13. Storage — application-message-attachments 버킷 (비공개)
--     경로 컨벤션: {application_id}/{message_id}/{filename}
--     최대 2MB / MIME: jpg·png·webp (HEIC 는 클라이언트에서 jpg 변환 후 업로드)
--     메시지 1건당 첨부 최대 5장은 클라이언트 단에서 제한
-- ============================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'application-message-attachments',
  'application-message-attachments',
  false,
  2097152,  -- 2 MB
  ARRAY[
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/webp'
  ]
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- SELECT (다운로드·signed URL 사전 경로 확인)
-- 인플루언서: 본인 응모건 경로({application_id}/...) 만 허용
-- 관리자: 전체 허용
DROP POLICY IF EXISTS "msg_attachments_influencer_select" ON storage.objects;
CREATE POLICY "msg_attachments_influencer_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.applications a
         WHERE a.user_id = auth.uid()
           -- 경로 첫 세그먼트가 application_id 와 일치 여부
           AND (storage.foldername(name))[1] = a.id::text
      )
    )
  );

-- INSERT (업로드)
-- 인플루언서: 본인 응모건 경로만 허용
-- 관리자: 전체 허용
DROP POLICY IF EXISTS "msg_attachments_insert" ON storage.objects;
CREATE POLICY "msg_attachments_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.applications a
         WHERE a.user_id = auth.uid()
           AND (storage.foldername(name))[1] = a.id::text
      )
    )
  );

-- UPDATE (덮어쓰기 upsert 대응)
DROP POLICY IF EXISTS "msg_attachments_update" ON storage.objects;
CREATE POLICY "msg_attachments_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.applications a
         WHERE a.user_id = auth.uid()
           AND (storage.foldername(name))[1] = a.id::text
      )
    )
  )
  WITH CHECK (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.applications a
         WHERE a.user_id = auth.uid()
           AND (storage.foldername(name))[1] = a.id::text
      )
    )
  );

-- DELETE (회수 시 즉시 삭제 또는 cleanup 용)
-- 인플루언서: 본인 응모건 경로만 허용 (withdraw_own_message 후 클라이언트 호출)
-- 관리자: 전체 허용
DROP POLICY IF EXISTS "msg_attachments_delete" ON storage.objects;
CREATE POLICY "msg_attachments_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'application-message-attachments'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.applications a
         WHERE a.user_id = auth.uid()
           AND (storage.foldername(name))[1] = a.id::text
      )
    )
  );


-- ============================================================
-- 14. RPC get_application_messages — 서버 측 마스킹 조회
--     사양서 §9 행 1304-1305: 클라이언트 마스킹은 본문이 네트워크로 노출되어
--     보안상 부적합. SECURITY DEFINER RPC 에서 서버 측에서 마스킹 처리.
--
--     마스킹 4종 케이스 (사양서 §3-5 + §9 비대칭 분기):
--
--     [호출자 = 인플루언서]
--       A) hidden_by_admin_at IS NOT NULL (강제 숨김)
--          → body=NULL, attachments='[]', mask_state='hidden_by_admin'
--       B) self_withdrawn_at IS NOT NULL (회수)
--          → body=NULL, attachments='[]'
--            mask_state: self_withdrawn_by_kind='influencer' → 'self_withdrawn_influencer'
--                        self_withdrawn_by_kind='admin'      → 'self_withdrawn_admin'
--       C) 그 외 → body/attachments 원본, mask_state='visible'
--
--     [호출자 = 관리자]
--       D) hidden_by_admin_at IS NOT NULL (강제 숨김)
--          → body/attachments 원본 유지, mask_state='hidden_by_admin'
--            (다른 관리자가 원본 열람 가능 — §3-5 ①)
--       E) self_withdrawn_at IS NOT NULL AND self_withdrawn_by_kind='influencer' (인플루언서 본인 회수)
--          → body=NULL, attachments='[]', mask_state='self_withdrawn_influencer'
--            (관리자도 못 봄 — §3-5 본인 회수 양쪽 마스킹)
--       F) self_withdrawn_at IS NOT NULL AND self_withdrawn_by_kind='admin' (관리자 본인 회수)
--          → body/attachments 원본 유지, mask_state='self_withdrawn_admin'
--            (다른 관리자에게 원본 보임 — §3-5 ② 비대칭)
--       G) 그 외 → body/attachments 원본, mask_state='visible'
--
--     케이스 D vs E vs F 가 관리자 비대칭 핵심:
--       강제 숨김(D)       → 관리자는 원본 볼 수 있음 (운영팀 내부 분쟁 대응)
--       인플 본인 회수(E)  → 관리자도 원본 볼 수 없음 (본인 회수 존중)
--       관리자 본인 회수(F) → 다른 관리자는 원본 볼 수 있음 (관리자 간 투명성)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.get_application_messages(uuid);
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
  '[144] 응모건 메시지 목록 조회 RPC. 서버 측 마스킹 처리 (사양서 §9). '
  '인플루언서: 강제숨김+회수 시 body=NULL, attachments=[]. '
  '관리자: 인플루언서 본인 회수만 양쪽 마스킹, 강제숨김·관리자회수는 원본 유지 (비대칭). '
  'mask_state: visible|hidden_by_admin|self_withdrawn_influencer|self_withdrawn_admin. '
  'SECURITY DEFINER + search_path 고정.';


COMMIT;
