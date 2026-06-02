-- ============================================================
-- 167_bulk_message.sql
-- 2026-06-02
--
-- 목적:
--   응모건 메시지 PR 3 DB — 관리자 일괄 발송·일괄 회수
--
-- 사양서:
--   docs/specs/2026-05-15-application-messaging.md
--   §PR3 §2 결정 표 (라인 1422~1438)
--   §PR3 §4-1 (라인 1461~1489) — send_application_message_bulk 시그니처·가드·처리흐름
--   §PR3 §4-2 (라인 1490~1512) — withdraw_broadcast 시그니처·가드·처리흐름
--
-- 전제 조건:
--   마이그레이션 144 (application_messages 5개 테이블 + 기본 원격 호출 함수 4개) 적용 완료
--   마이그레이션 145 (send_application_message 재정의 + hide/unhide/resolved 함수) 적용 완료
--   application_message_broadcasts 테이블 존재
--   application_messages.broadcast_id 컬럼 존재
--   application_message_hide_history 테이블 존재
--   public.is_campaign_admin() / public.is_super_admin() 함수 존재
--   lookup_values(kind='message_hide_reason') 시드 7건 존재 (144)
--
-- 신설 함수 2개:
--   1. public.send_application_message_bulk(...)  — 관리자 일괄 발송 (최대 200명)
--   2. public.withdraw_broadcast(...)             — 일괄 발송 그룹 회수
--
-- 테이블·컬럼·행 단위 보안 정책 변경:
--   없음 — 144/145 에서 모든 인프라 완성됨
--
-- 결정 사항 (§PR3 §2, 2026-05-28 사용자 확정):
--   - 권한: campaign_admin 이상 (is_campaign_admin() 가드)
--   - 1회 한도: 200명 초과 시 예외
--   - 시간당 횟수: 무제한 (개별 send 의 100건/시간 한도와 별도 카운터)
--   - 90일 차단: 관리자 일괄도 면제 (개별 send 정책과 일관)
--   - cancelled 응모: 클라이언트가 사전 필터, RPC 는 존재하지 않는 id만 skip
--   - 회수 권한: 발신자 본인 또는 super_admin
--   - 첨부 Storage 파일 삭제: 없음 (영구 보존 — §3-5)
--
-- 기존 send_application_message (마이그레이션 145) 와 일관성:
--   - resolutions UPSERT (auto_replied) 동일 컬럼 구조
--   - notifications 알림 INSERT 동일 중복 방지 EXISTS 조건
--   - sender_name COALESCE(v_admin_name, '(이름미상)') 폴백 동일
--   - hide_history INSERT 컬럼 순서·값 구조 동일
--
-- 롤백:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.withdraw_broadcast(uuid, text, text);
--   DROP FUNCTION IF EXISTS public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb);
--   COMMIT;
--
-- 적용 순서:
--   1. 개발서버 (qysmxtipobomefudyixw) SQL Editor 실행 + 스모크 테스트 확인
--   2. 운영서버 (nrwtujmlbktxjgdwlpjj) SQL Editor 실행 — 운영 배포 게이트(약관 통지) 완료 후
-- ============================================================

BEGIN;


-- ============================================================
-- (1) send_application_message_bulk — 관리자 일괄 발송
--
-- §PR3 §4-1 결정 사항:
--   - is_campaign_admin() 미만 예외
--   - array_length(p_application_ids,1) IS NULL → 수신자 없음 예외
--   - 200명 초과 → 예외
--   - 본문+첨부 둘 다 비면 예외 (개별 send 와 동일)
--   - 90일 차단 없음 (관리자 발신 면제)
--   - FOREACH 로 각 응모건 존재 확인 후 INSERT (없으면 skip)
--   - resolutions UPSERT (auto_replied) — 개별 send 와 동일 컬럼
--   - notifications 알림 INSERT — 미읽음 중복 방지 EXISTS 동일
--   - recipient_count 실제 INSERT 수로 갱신
--   - 0건이면 broadcast DELETE + 예외
--
-- RETURNS uuid — 생성된 broadcast_id (클라이언트 UI 에서 「회수」 버튼 활성 등에 사용)
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_application_message_bulk(
  p_application_ids     uuid[],
  p_body                text,
  p_attachments         jsonb DEFAULT '[]'::jsonb,
  p_context_kind        text  DEFAULT 'manual',   -- 'campaign' | 'manual'
  p_context_campaign_id uuid  DEFAULT NULL,
  p_context_filter      jsonb DEFAULT NULL        -- 필터 스냅샷 (감사·재현용)
) RETURNS uuid  -- broadcast_id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name        text;
  v_broadcast_id      uuid;
  v_app_id            uuid;
  v_app_owner         uuid;
  v_camp_title        text;
  v_inserted          integer := 0;
  v_msg_id            uuid;
  v_last_inf_msg_at   timestamptz;
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 수신자 배열 비어 있음 검증
  IF array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION '受信者がいません';
  END IF;

  -- 1회 한도 200명 검증
  IF array_length(p_application_ids, 1) > 200 THEN
    RAISE EXCEPTION '1回の一括送信は最大200名までです';
  END IF;

  -- 본문·첨부 빈값 검증 (개별 send_application_message 와 동일)
  IF (p_body IS NULL OR btrim(p_body) = '')
     AND (p_attachments IS NULL OR p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION 'メッセージ本文または添付が必要です';
  END IF;

  -- context_kind 유효성 검증
  IF p_context_kind NOT IN ('campaign', 'manual') THEN
    RAISE EXCEPTION 'context_kind は campaign または manual のみ有効です';
  END IF;

  -- 발신자 이름 스냅샷 (145 와 동일 패턴)
  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- broadcast 그룹 메타 INSERT (recipient_count 는 실제 INSERT 후 UPDATE)
  INSERT INTO public.application_message_broadcasts (
    sender_id,
    sender_name,
    body,
    attachments,
    recipient_count,
    context_kind,
    context_campaign_id,
    context_filter
  ) VALUES (
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    COALESCE(p_body, ''),
    COALESCE(p_attachments, '[]'::jsonb),
    0,  -- 실제 INSERT 수로 아래에서 UPDATE
    p_context_kind,
    p_context_campaign_id,
    p_context_filter
  )
  RETURNING id INTO v_broadcast_id;

  -- ----------------------------------------------------------------
  -- FOREACH: 각 응모건에 메시지 INSERT + resolutions + 알림
  -- ----------------------------------------------------------------
  FOREACH v_app_id IN ARRAY p_application_ids LOOP
    -- 응모 소유자 조회 (존재하지 않는 id 는 skip)
    SELECT user_id INTO v_app_owner
      FROM public.applications WHERE id = v_app_id;

    IF v_app_owner IS NULL THEN
      CONTINUE;
    END IF;

    -- 캠페인명 조회 (알림 title 용 — 145 와 동일 패턴)
    SELECT c.title INTO v_camp_title
      FROM public.applications a
      JOIN public.campaigns c ON c.id = a.campaign_id
     WHERE a.id = v_app_id;

    -- 메시지 INSERT (broadcast_id 채움)
    INSERT INTO public.application_messages (
      application_id,
      sender_kind,
      sender_id,
      sender_name,
      body,
      attachments,
      broadcast_id
    ) VALUES (
      v_app_id,
      'admin',
      auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'),
      COALESCE(p_body, ''),
      COALESCE(p_attachments, '[]'::jsonb),
      v_broadcast_id
    )
    RETURNING id INTO v_msg_id;

    -- resolutions UPSERT (auto_replied) — 145 의 send_application_message 와 동일 구조
    -- 살아있는 마지막 인플루언서 메시지 시각을 resolved_after_message_at 에 기록
    SELECT max(created_at) INTO v_last_inf_msg_at
      FROM public.application_messages
     WHERE application_id = v_app_id
       AND sender_kind        = 'influencer'
       AND hidden_by_admin_at IS NULL
       AND self_withdrawn_at  IS NULL;

    INSERT INTO public.application_message_resolutions (
      application_id,
      resolved_at,
      resolved_by,
      resolved_by_name,
      resolved_after_message_at,
      resolution_method
    ) VALUES (
      v_app_id,
      now(),
      auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'),
      COALESCE(v_last_inf_msg_at, now()),
      'auto_replied'
    )
    ON CONFLICT (application_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';

    -- notifications INSERT (kind='message_received')
    -- 같은 응모건에 미읽음 message_received 알림이 이미 있으면 INSERT 안 함
    -- (145 의 send_application_message 와 완전히 동일한 중복 방지 조건)
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
       WHERE user_id   = v_app_owner
         AND kind      = 'message_received'
         AND ref_table = 'applications'
         AND ref_id    = v_app_id
         AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (
        user_id,
        kind,
        ref_table,
        ref_id,
        title,
        body
      ) VALUES (
        v_app_owner,
        'message_received',
        'applications',
        v_app_id,
        COALESCE(v_camp_title, '') || ' — 運営からメッセージが届きました',
        COALESCE(v_admin_name, '(이름미상)') || 'よりメッセージが送信されました'
      );
    END IF;

    v_inserted := v_inserted + 1;
  END LOOP;
  -- ----------------------------------------------------------------

  -- 실제 INSERT 수로 recipient_count 갱신
  UPDATE public.application_message_broadcasts
     SET recipient_count = v_inserted
   WHERE id = v_broadcast_id;

  -- 0건이면 (모든 application_id 가 존재하지 않는 경우) broadcast 행 정리 후 예외
  IF v_inserted = 0 THEN
    DELETE FROM public.application_message_broadcasts WHERE id = v_broadcast_id;
    RAISE EXCEPTION '送信された応募がありません (すべて存在しないか削除済み)';
  END IF;

  RETURN v_broadcast_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb)
  TO authenticated;

COMMENT ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb) IS
  '[167] 관리자 일괄 발송 원격 호출 함수. campaign_admin 이상 가드. '
  '1회 최대 200명, 시간당 횟수 무제한 (개별 send 와 별도 카운터). '
  '90일 차단 없음 (관리자 발신 면제). '
  '각 응모건마다 broadcast_id 붙인 메시지 INSERT + resolutions UPSERT(auto_replied) + '
  '미읽음 message_received 알림 INSERT(중복 방지 EXISTS 조건). '
  '0건이면 broadcast 행 DELETE + 예외. '
  'SECURITY DEFINER + search_path 고정. 사양서 §PR3 §4-1.';


-- ============================================================
-- (2) withdraw_broadcast — 일괄 발송 그룹 회수
--
-- §PR3 §4-2 결정 사항:
--   - is_campaign_admin() 미만 예외
--   - broadcast 존재 + (본인 OR super_admin) — 그 외 예외
--   - 이미 withdrawn_at IS NOT NULL → 예외 (중복 회수 차단)
--   - p_reason_code 유효성 검증 (lookup_values kind='message_hide_reason')
--   - broadcasts UPDATE (withdrawn_* 4컬럼)
--   - 해당 broadcast 의 미숨김 메시지 각각 hidden_by_admin_* 4컬럼 UPDATE
--   - 각 메시지마다 hide_history INSERT (action='broadcast_withdraw')
--   - 첨부 Storage 삭제 없음 (§3-5 영구 보존 — PR 4 메일 큐 활성화 시 email_skip_reason 자동 처리)
--
-- RETURNS void (회수된 건수는 UI 가 broadcast.recipient_count 로 표시)
-- ============================================================
CREATE OR REPLACE FUNCTION public.withdraw_broadcast(
  p_broadcast_id uuid,
  p_reason_code  text,
  p_reason_memo  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id   uuid;
  v_admin_name  text;
  v_msg_id      uuid;
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- broadcast 존재 + 발신자 확인
  SELECT sender_id INTO v_sender_id
    FROM public.application_message_broadcasts
   WHERE id = p_broadcast_id;

  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION '一括送信グループが見つかりません';
  END IF;

  -- 본인 또는 super_admin 만 회수 가능 (§PR3 §2 결정)
  IF v_sender_id <> auth.uid() AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION '送信者本人またはsuper_adminのみ一括取消が可能です'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 이미 회수된 그룹 차단
  IF EXISTS (
    SELECT 1 FROM public.application_message_broadcasts
     WHERE id           = p_broadcast_id
       AND withdrawn_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION '既に取り消されています';
  END IF;

  -- 사유 카테고리 유효성 검증 (lookup_values kind='message_hide_reason', 145 의 hide_application_message 와 동일)
  IF NOT EXISTS (
    SELECT 1 FROM public.lookup_values
     WHERE kind   = 'message_hide_reason'
       AND code   = p_reason_code
       AND active = true
  ) THEN
    RAISE EXCEPTION '유효하지 않은 사유 카테고리입니다: %', p_reason_code;
  END IF;

  -- 발신자 이름 스냅샷
  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- ----------------------------------------------------------------
  -- broadcast 행 회수 마킹 (§PR3 §4-2 처리흐름 1)
  -- withdrawn_at/by/reason_code/reason_memo 갱신
  -- ----------------------------------------------------------------
  UPDATE public.application_message_broadcasts
     SET withdrawn_at          = now(),
         withdrawn_by          = auth.uid(),
         withdrawn_reason_code = p_reason_code,
         withdrawn_reason_memo = p_reason_memo
   WHERE id = p_broadcast_id;

  -- ----------------------------------------------------------------
  -- 해당 broadcast 의 미숨김 메시지 각각 강제 숨김 처리 (§PR3 §4-2 처리흐름 2·3)
  -- 이미 개별적으로 숨김된 메시지는 건너뜀 (hidden_by_admin_at IS NULL 조건)
  -- ----------------------------------------------------------------
  FOR v_msg_id IN
    SELECT id FROM public.application_messages
     WHERE broadcast_id        = p_broadcast_id
       AND hidden_by_admin_at IS NULL
  LOOP
    -- 메시지 숨김 처리 (§PR3 §4-2 처리흐름 2)
    UPDATE public.application_messages
       SET hidden_by_admin_at = now(),
           hidden_by_admin_id = auth.uid(),
           hidden_reason_code = p_reason_code,
           hidden_reason_memo = p_reason_memo
     WHERE id = v_msg_id;

    -- 숨김 감사 이력 (§PR3 §4-2 처리흐름 3 — action='broadcast_withdraw')
    -- 145 의 hide_application_message 와 동일 컬럼 구조
    INSERT INTO public.application_message_hide_history (
      message_id,
      action,
      by_user_kind,
      by_user_id,
      by_name,
      reason_code,
      reason_memo
    ) VALUES (
      v_msg_id,
      'broadcast_withdraw',
      'admin',
      auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'),
      p_reason_code,
      p_reason_memo
    );

    -- 발송 대기 이메일 자동 취소 (PR 4 메일 큐 활성화 전에는 email_send_at = NULL 이라 무해)
    -- §PR3 §4-2 처리흐름 5 주석: PR 4 의 process_pending_message_emails() 가 hidden_by_admin_at 감지 시
    --   email_skip_reason='cancelled' 마킹. PR 3 단독 운영 단계에서는 email_send_at = NULL 이므로 하단 UPDATE 는 0건
    UPDATE public.application_messages
       SET email_skip_reason = 'cancelled'
     WHERE id              = v_msg_id
       AND email_send_at   IS NOT NULL
       AND email_send_at   > now()
       AND email_sent_at   IS NULL;
  END LOOP;
  -- ----------------------------------------------------------------

  -- 첨부 Storage 파일 삭제 없음 (§3-5 영구 보존 원칙)
END;
$$;

REVOKE EXECUTE ON FUNCTION public.withdraw_broadcast(uuid, text, text)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.withdraw_broadcast(uuid, text, text)
  TO authenticated;

COMMENT ON FUNCTION public.withdraw_broadcast(uuid, text, text) IS
  '[167] 일괄 발송 그룹 회수 원격 호출 함수. campaign_admin 이상 가드. '
  '발신자 본인 또는 super_admin 만 가능. 이미 회수된 그룹 재호출 시 예외. '
  'p_reason_code: lookup_values(kind=message_hide_reason).code 유효성 검증. '
  'broadcasts.withdrawn_* 4컬럼 UPDATE → '
  '미숨김 메시지 hidden_by_admin_* 4컬럼 UPDATE → '
  '각 메시지 hide_history INSERT(action=broadcast_withdraw). '
  '첨부 Storage 삭제 없음(§3-5 영구 보존). '
  'SECURITY DEFINER + search_path 고정. 사양서 §PR3 §4-2.';


-- ============================================================
-- (3) resolve_bulk_recipients — 일괄 발송 대상 응모 ID 배열 해결
--
-- 목적:
--   캠페인 + 필터 조건을 만족하는 응모(application) ID 배열을 반환.
--   미리보기 카운트(배열 길이)와 실제 발송(send_application_message_bulk 에
--   그대로 전달) 양쪽에 사용.
--
-- 필터 해석 근거:
--   [채널 필터 p_channels]
--     「캠페인 채널 CSV 중 선택한 채널을 인플루언서가 보유」 기준 채택.
--     근거: ① 관리자 UI 에서 "이 채널 사용자에게만 발송"이라는 맥락
--           ② 141 마이그레이션 채널 매칭 패턴(ig/tiktok/x/youtube 핸들 존재 여부)과 동일 구조
--           ③ applications 에 채널 선택 값을 별도 저장하지 않으므로
--              캠페인 채널 × 인플루언서 보유 채널 교집합이 가장 합리적
--     판단 포인트: LIPS / @cosme / Qoo10 은 팔로워 컬럼이 없어 팔로워 필터 불가.
--                 채널 보유 여부(핸들 컬럼 NOT NULL AND != '')로만 포함 처리.
--
--   [팔로워 필터 p_min_followers]
--     primary_channel 단일 기준 (FEATURE_SPEC §10 + 141 헬퍼 정책 동일).
--     primary_channel: campaigns.primary_channel → NULL/빈값이면 channel CSV 첫 번째.
--     채널별 팔로워 컬럼: ig=ig_followers, tiktok=tiktok_followers, x=x_followers,
--     youtube=youtube_followers. 그 외 채널(lips, cosme, qoo10 등)은 ELSE 0
--     → min_followers > 0 이면 제외(팔로워 검증 불가 채널이 primary 인 캠페인에서
--       p_min_followers 를 주면 의도대로 전원 제외됨).
--
--   [결과물 상태 필터 p_deliverable_statuses]
--     'none'   = 해당 응모에 deliverables 행이 하나도 없음
--     'pending'/'approved'/'rejected' = 그 status 의 deliverable 이 EXISTS
--     한 응모에 결과물이 여러 건 가능 → EXISTS 서브쿼리로 판정.
--     중요: draft status 는 폐기(042→073) 대상, 현재 CHECK 는 pending/approved/rejected.
--
-- ⚠️ 사용자 확인 필요 — 채널 필터 기준:
--   이 함수는 「인플루언서가 해당 채널 계정을 보유(핸들 컬럼 != '')」를 기준으로 필터.
--   사양서 §PR3 §3 에서 "응모자의 등록 채널 기준" / "캠페인 채널 옵션 기준" 중 어느
--   해석인지 명시가 없다면 위 근거로 합리적 해석 채택. 다른 의도라면 수정 요청.
--
-- cancelled 응모 제외 이유:
--   사양서 §PR3 §2 — 인플루언서 화면에서 cancelled 응모는 메시지 탭 진입 차단.
--   발송해도 열람 불가이므로 항상 제외.
--
-- RETURNS uuid[] — 조건 만족 application ID 배열 (빈 배열 가능, 예외 없음)
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_bulk_recipients(
  p_campaign_id          uuid,
  p_app_statuses         text[]  DEFAULT NULL,
  p_deliverable_statuses text[]  DEFAULT NULL,
  p_channels             text[]  DEFAULT NULL,
  p_min_followers        integer DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_campaign_channel      text;
  v_campaign_primary_ch   text;
  v_result                uuid[];
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 캠페인 존재 확인 + 채널·primary_channel 스냅샷
  SELECT channel, primary_channel
    INTO v_campaign_channel, v_campaign_primary_ch
    FROM public.campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다: %', p_campaign_id;
  END IF;

  -- ----------------------------------------------------------------
  -- 대상 응모 집계
  -- ----------------------------------------------------------------
  SELECT ARRAY(
    SELECT a.id
      FROM public.applications a
      JOIN public.influencers  i ON i.id = a.user_id
     WHERE a.campaign_id = p_campaign_id
       -- cancelled 항상 제외 (§PR3 §2 — 인플 화면 진입 차단)
       AND a.status <> 'cancelled'

       -- ── 응모 상태 필터 ──
       AND (
         p_app_statuses IS NULL
         OR a.status = ANY(p_app_statuses)
       )

       -- ── 결과물 상태 필터 ──
       AND (
         p_deliverable_statuses IS NULL
         OR (
           -- 'none': 결과물 행이 하나도 없는 응모
           ('none' = ANY(p_deliverable_statuses) AND NOT EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
           ))
           OR
           -- 'pending' / 'approved' / 'rejected': 해당 status 결과물이 EXISTS
           EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.status = ANY(
                  -- 'none' 제외하고 실제 status 값만 추출
                  ARRAY(SELECT x FROM unnest(p_deliverable_statuses) x WHERE x <> 'none')
                )
           )
         )
       )

       -- ── 채널 필터 ──
       -- 인플루언서가 지정 채널 계정을 보유(핸들 컬럼 NOT NULL AND != '') 하는지 확인.
       -- 캠페인 채널 CSV 에 있는 채널 중 관리자가 선택한 채널(p_channels) 기준.
       AND (
         p_channels IS NULL
         OR (
           ('instagram' = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('tiktok'    = ANY(p_channels) AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
           OR ('x'         = ANY(p_channels) AND i.x       IS NOT NULL AND i.x       <> '')
           OR ('youtube'   = ANY(p_channels) AND i.youtube IS NOT NULL AND i.youtube <> '')
           OR ('qoo10'     = ANY(p_channels) AND i.qoo10   IS NOT NULL AND i.qoo10   <> '')
           OR ('lips'      = ANY(p_channels) AND i.lips    IS NOT NULL AND i.lips    <> '')
           OR ('cosme'     = ANY(p_channels) AND i.cosme   IS NOT NULL AND i.cosme   <> '')
         )
       )

       -- ── 팔로워 필터 ──
       -- primary_channel 단일 기준 (FEATURE_SPEC §10 + 마이그레이션 141 _meets_min_followers 정책).
       -- primary_channel: campaigns.primary_channel → NULL/빈값이면 channel CSV 첫 번째.
       -- LIPS / @cosme / Qoo10 등 팔로워 컬럼 없는 채널 → ELSE 0 처리.
       AND (
         p_min_followers IS NULL
         OR (
           CASE
             COALESCE(
               NULLIF(TRIM(v_campaign_primary_ch), ''),
               TRIM(SPLIT_PART(v_campaign_channel, ',', 1))
             )
             WHEN 'instagram' THEN COALESCE(i.ig_followers,      0)
             WHEN 'tiktok'    THEN COALESCE(i.tiktok_followers,  0)
             WHEN 'x'         THEN COALESCE(i.x_followers,       0)
             WHEN 'youtube'   THEN COALESCE(i.youtube_followers,  0)
             ELSE 0
           END
         ) >= p_min_followers
       )
  ) INTO v_result;

  RETURN COALESCE(v_result, ARRAY[]::uuid[]);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], integer)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], integer)
  TO authenticated;

COMMENT ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], integer) IS
  '[167] 일괄 발송 대상 응모 ID 배열 반환. campaign_admin 이상 가드. '
  'cancelled 응모 항상 제외. '
  'p_app_statuses: NULL=전체, 또는 pending/approved/rejected 조합. '
  'p_deliverable_statuses: NULL=전체, none/pending/approved/rejected 조합(none=결과물 없음). '
  'p_channels: NULL=전체, 인플루언서 보유 채널 기준 필터. '
  'p_min_followers: NULL=제한없음, primary_channel 단일 기준(FEATURE_SPEC §10). '
  '빈 배열 반환 가능(예외 없음). SECURITY DEFINER + search_path 고정. 사양서 §PR3 §3.';


-- ============================================================
-- (4) get_broadcast_detail — 일괄 발송 이력 상세
--
-- 목적:
--   broadcast 그룹 메타 + 수신자별 읽음·답장·숨김 상태를 jsonb 로 반환.
--   관리자 발송 이력 상세 모달에서 사용.
--
-- 권한 분기:
--   super_admin    → 모든 broadcast 접근 가능
--   campaign_admin → 본인 발송분(sender_id = auth.uid())만
--   그 외(campaign_admin 미만) → 예외
--
-- replied 판정:
--   해당 application_id 에서 이 broadcast 메시지의 created_at 이후
--   sender_kind = 'influencer' 메시지가 존재하는지 여부.
--   broadcast 메시지의 created_at 은 application_messages 의 created_at 기준
--   (broadcasts.created_at 과 거의 동일하나 FOREACH 삽입 순서 차이 수 ms 존재 →
--   application_messages.broadcast_id 로 조인해 broadcast 연결 메시지 created_at 기준 사용).
--
-- 조인 키:
--   applications.user_id = influencers.id  (auth_id 컬럼 없음 — 메모리 교훈)
--
-- RETURNS jsonb — { broadcast: {...}, recipients: [...] }
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broadcast_detail(
  p_broadcast_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id     uuid;
  v_result        jsonb;
  v_broadcast_ts  timestamptz;  -- 해당 broadcast 메시지들의 최초 created_at (replied 기준점)
BEGIN
  -- 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '権限がありません (campaign_admin以上が必要です)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- broadcast 존재 + 발신자 확인
  SELECT sender_id INTO v_sender_id
    FROM public.application_message_broadcasts
   WHERE id = p_broadcast_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '一括送信グループが見つかりません: %', p_broadcast_id;
  END IF;

  -- 권한별 가시성: super_admin 이 아니면 본인 발송분만
  IF NOT public.is_super_admin() AND v_sender_id <> auth.uid() THEN
    RAISE EXCEPTION 'アクセス権限がありません'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- broadcast 에 속한 메시지 중 가장 이른 created_at (replied 기준점)
  SELECT MIN(m.created_at) INTO v_broadcast_ts
    FROM public.application_messages m
   WHERE m.broadcast_id = p_broadcast_id;

  -- 결과 조립
  SELECT jsonb_build_object(
    'broadcast', jsonb_build_object(
      'id',                    b.id,
      'sender_id',             b.sender_id,
      'sender_name',           b.sender_name,
      'body',                  b.body,
      'attachments',           b.attachments,
      'recipient_count',       b.recipient_count,
      'created_at',            b.created_at,
      'context_kind',          b.context_kind,
      'context_campaign_id',   b.context_campaign_id,
      'context_filter',        b.context_filter,
      'withdrawn_at',          b.withdrawn_at,
      'withdrawn_by',          b.withdrawn_by,
      'withdrawn_reason_code', b.withdrawn_reason_code,
      'withdrawn_reason_memo', b.withdrawn_reason_memo
    ),
    'recipients', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'application_id',  m.application_id,
          'message_id',      m.id,
          -- 인플루언서 이름: applications.user_id = influencers.id 조인
          'influencer_name', COALESCE(i.name, '(이름미상)'),
          -- 캠페인 제목
          'campaign_title',  COALESCE(c.title, '(캠페인 없음)'),
          -- 읽음 여부: read_by_influencer_at IS NOT NULL
          'read',            (m.read_by_influencer_at IS NOT NULL),
          -- 답장 여부: broadcast 메시지 이후 인플루언서 메시지 EXISTS
          'replied',         EXISTS (
            SELECT 1
              FROM public.application_messages r
             WHERE r.application_id = m.application_id
               AND r.sender_kind    = 'influencer'
               AND r.created_at     > COALESCE(v_broadcast_ts, b.created_at)
               AND r.self_withdrawn_at IS NULL  -- 본인 회수 메시지 제외
          ),
          -- 숨김 여부: hidden_by_admin_at IS NOT NULL
          'hidden',          (m.hidden_by_admin_at IS NOT NULL)
        )
        ORDER BY m.created_at ASC
      )
      FROM public.application_messages m
      JOIN public.applications        a ON a.id      = m.application_id
      JOIN public.influencers         i ON i.id      = a.user_id
      JOIN public.campaigns           c ON c.id      = a.campaign_id
      WHERE m.broadcast_id = p_broadcast_id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.application_message_broadcasts b
  WHERE b.id = p_broadcast_id;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_broadcast_detail(uuid)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_broadcast_detail(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_broadcast_detail(uuid) IS
  '[167] 일괄 발송 이력 상세 반환. campaign_admin 이상 가드. '
  'super_admin=전체 broadcast, campaign_admin=본인 발송분만. '
  '반환: {broadcast:{메타}, recipients:[{application_id, message_id, influencer_name, '
  'campaign_title, read, replied, hidden}]}. '
  'replied 기준: broadcast 메시지 최초 created_at 이후 인플루언서 메시지 EXISTS(본인회수 제외). '
  '조인 키: applications.user_id = influencers.id (auth_id 컬럼 없음). '
  'SECURITY DEFINER + search_path 고정. 사양서 §PR3 상세 모달.';


COMMIT;
