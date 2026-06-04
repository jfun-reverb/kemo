-- ============================================================
-- 168_bulk_target_redesign.sql
-- 2026-06-02
--
-- 목적:
--   일괄 발송 대상선택 재설계 — 167 위에 얹히는 잠든 코드.
--   167(개발서버만 적용·운영 보류)을 직접 수정하지 않고, 3가지 변경을
--   이 파일에서 일괄 적용한다.
--
-- 사양서:
--   docs/specs/2026-06-02-deliverable-post-url-duplicate-fix.md (참고)
--   일괄발송 대상선택 재설계 요구사항 (2026-06-02 사용자 확정)
--
-- 전제 조건:
--   마이그레이션 167 (send_application_message_bulk / withdraw_broadcast /
--   resolve_bulk_recipients / get_broadcast_detail) 적용 완료
--
-- 변경 내용 (167 대비):
--   1. application_message_broadcasts 테이블에 title 컬럼 추가
--      - 관리자 전용 발송 제목, 인플루언서 메시지 본문에는 미노출
--   2. send_application_message_bulk 재정의
--      - p_title text DEFAULT NULL 파라미터 추가
--      - broadcasts INSERT 시 title 채움
--      - application_messages INSERT 에는 title 포함 안 함(인플 비노출 보장)
--   3. resolve_bulk_recipients 재정의 (인자 수 변경으로 DROP 후 CREATE)
--      - 결과물 필터를 영수증 전용(p_receipt_statuses)과 일반 결과물 전용
--        (p_post_statuses, kind IN ('post','review_image'))으로 분리
--      - 인플루언서 상태 필터 3종 추가:
--          p_require_verified  (인증된 인플만)
--          p_exclude_violation (위반 이력 있는 인플 제외)
--          p_exclude_blacklist (블랙리스트 인플 제외, 기본 true)
--      - 위반 판정: influencer_flags.action='violation' 이력 1건이라도 존재
--
-- 컬럼명 검증 결과 (마이그레이션 059/060 확인):
--   influencers.is_verified   ✅ (059 ADD COLUMN, boolean NOT NULL DEFAULT false)
--   influencers.is_blacklisted ✅ (059 ADD COLUMN, boolean NOT NULL DEFAULT false)
--   influencer_flags.influencer_id ✅ (059 CREATE TABLE)
--   influencer_flags.action        ✅ (060 CHECK: 'verify'|'unverify'|'blacklist'|'unblacklist'|'violation')
--   deliverables.kind              ✅ (기존 CHECK: 'receipt'|'review_image'|'post')
--
-- 운영 배포:
--   개발서버(qysmxtipobomefudyixw) 먼저 적용 후, 167과 동시에 운영서버
--   (nrwtujmlbktxjgdwlpjj) 에 적용. 메시지 약관 30일 통지 게이트 완료 후.
--
-- 롤백 SQL (주석):
--   -- 167 시그니처로 되돌리기:
--   BEGIN;
--   -- (A) title 컬럼 제거
--   ALTER TABLE public.application_message_broadcasts DROP COLUMN IF EXISTS title;
--   -- (B) send_application_message_bulk → 167 시그니처 복원
--   DROP FUNCTION IF EXISTS public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb, text);
--   -- 167 원본을 그대로 재실행 (167 파일 76~276줄)
--   -- (C) resolve_bulk_recipients → 167 시그니처 복원
--   DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(uuid, text[], text[], text[], text[], integer, boolean, boolean, boolean);
--   -- 167 원본을 그대로 재실행 (167 파일 472~598줄)
--   COMMIT;
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행 + 스모크 확인
--   2. 운영서버 SQL Editor 실행 (약관 통지 게이트 완료 후)
-- ============================================================

BEGIN;


-- ============================================================
-- (1) application_message_broadcasts — title 컬럼 추가
--
-- 관리자 전용 발송 제목 (선택 입력).
-- 인플루언서 메시지 본문(application_messages.body)에는 절대 넣지 않음.
-- ============================================================
ALTER TABLE public.application_message_broadcasts
  ADD COLUMN IF NOT EXISTS title text NULL;

COMMENT ON COLUMN public.application_message_broadcasts.title IS
  '[168] 관리자 전용 발송 제목. NULL 허용(선택 사항). '
  '인플루언서 메시지 본문에는 미노출 — broadcasts 메타 전용.';


-- ============================================================
-- (2) send_application_message_bulk 재정의 — title 파라미터 추가
--
-- 167 대비 변경:
--   - 마지막 파라미터로 p_title text DEFAULT NULL 추가
--   - broadcasts INSERT 시 title = p_title 채움
--   - application_messages INSERT 에는 title 컬럼 없음 (인플 비노출)
--   - 나머지 로직은 167 과 동일
--
-- 새 시그니처:
--   send_application_message_bulk(
--     p_application_ids     uuid[],
--     p_body                text,
--     p_attachments         jsonb    DEFAULT '[]',
--     p_context_kind        text     DEFAULT 'manual',
--     p_context_campaign_id uuid     DEFAULT NULL,
--     p_context_filter      jsonb    DEFAULT NULL,
--     p_title               text     DEFAULT NULL   ← 신규
--   ) RETURNS uuid
-- ============================================================
-- 167 의 6-인자 함수 + 168 재실행 시 7-인자 함수 모두 제거 후 재생성 (오버로드 모호성·멱등성)
DROP FUNCTION IF EXISTS public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb);
DROP FUNCTION IF EXISTS public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb, text);
CREATE FUNCTION public.send_application_message_bulk(
  p_application_ids     uuid[],
  p_body                text,
  p_attachments         jsonb DEFAULT '[]'::jsonb,
  p_context_kind        text  DEFAULT 'manual',
  p_context_campaign_id uuid  DEFAULT NULL,
  p_context_filter      jsonb DEFAULT NULL,
  p_title               text  DEFAULT NULL   -- 관리자 전용 제목, 인플 메시지 본문에 미포함
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
  -- ★ 167 대비 변경: title 컬럼 추가
  INSERT INTO public.application_message_broadcasts (
    sender_id,
    sender_name,
    body,
    attachments,
    recipient_count,
    context_kind,
    context_campaign_id,
    context_filter,
    title
  ) VALUES (
    auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'),
    COALESCE(p_body, ''),
    COALESCE(p_attachments, '[]'::jsonb),
    0,
    p_context_kind,
    p_context_campaign_id,
    p_context_filter,
    p_title   -- NULL 허용 (선택 사항)
  )
  RETURNING id INTO v_broadcast_id;

  -- ----------------------------------------------------------------
  -- FOREACH: 각 응모건에 메시지 INSERT + 응대 완료 자동 등록 + 알림
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
    -- ★ 인플루언서에게 보내는 메시지 본문에는 title 컬럼 없음 (인플 비노출 보장)
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

    -- 응대 완료 자동 등록 (auto_replied) — 145 의 send_application_message 와 동일 구조
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

    -- 알림 INSERT (kind='message_received')
    -- 같은 응모건에 미읽음 알림이 이미 있으면 INSERT 안 함 (145 와 동일 중복 방지 조건)
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

  -- 0건이면 broadcast 행 정리 후 예외
  IF v_inserted = 0 THEN
    DELETE FROM public.application_message_broadcasts WHERE id = v_broadcast_id;
    RAISE EXCEPTION '送信された応募がありません (すべて存在しないか削除済み)';
  END IF;

  RETURN v_broadcast_id;
END;
$$;

-- 167 의 구 시그니처(인자 6개)는 CREATE OR REPLACE 로 덮이지 않으므로 권한 재부여만 추가
-- (새 시그니처 인자 7개 기준)
REVOKE EXECUTE ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb, text)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb, text)
  TO authenticated;

COMMENT ON FUNCTION public.send_application_message_bulk(uuid[], text, jsonb, text, uuid, jsonb, text) IS
  '[168] 관리자 일괄 발송 원격 호출 함수 (167 재정의 — p_title 추가). '
  'campaign_admin 이상 가드. 1회 최대 200명. '
  'broadcasts.title = p_title (관리자 전용, 인플 메시지 본문 미포함). '
  '각 응모건마다 broadcast_id 붙인 메시지 INSERT + 응대완료 자동등록(auto_replied) + '
  '미읽음 알림 INSERT(중복 방지). 0건이면 broadcast 행 DELETE + 예외. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- (3) resolve_bulk_recipients 재정의 — 결과물 필터 분리 + 인플루언서 상태 필터
--
-- 인자 수가 변경되므로 DROP 후 CREATE.
--
-- 167 대비 변경:
--   - p_deliverable_statuses (단일) → p_receipt_statuses + p_post_statuses 분리
--     p_receipt_statuses: kind='receipt' 결과물 상태 필터
--     p_post_statuses:    kind IN ('post','review_image') 결과물 상태 필터
--     두 필터를 AND 로 연결 (각각 NULL 이면 해당 종류 필터 통과)
--   - p_require_verified  boolean DEFAULT false: true 면 is_verified=true 인플만
--   - p_exclude_violation boolean DEFAULT false: true 면 위반 이력 있는 인플 제외
--   - p_exclude_blacklist boolean DEFAULT true:  true 면 is_blacklisted=true 인플 제외
--
-- 위반 판정 정의 (2026-06-02 사용자 확정):
--   influencer_flags.action = 'violation' 이력 1건이라도 존재
--   (마이그레이션 060 에서 action CHECK: 'verify'|'unverify'|'blacklist'|'unblacklist'|'violation')
--
-- 새 시그니처:
--   resolve_bulk_recipients(
--     p_campaign_id        uuid,
--     p_app_statuses       text[]  DEFAULT NULL,
--     p_receipt_statuses   text[]  DEFAULT NULL,
--     p_post_statuses      text[]  DEFAULT NULL,
--     p_channels           text[]  DEFAULT NULL,
--     p_min_followers      integer DEFAULT NULL,
--     p_require_verified   boolean DEFAULT false,
--     p_exclude_violation  boolean DEFAULT false,
--     p_exclude_blacklist  boolean DEFAULT true
--   ) RETURNS uuid[]
-- ============================================================
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(uuid, text[], text[], text[], integer);
DROP FUNCTION IF EXISTS public.resolve_bulk_recipients(uuid, text[], text[], text[], text[], integer, boolean, boolean, boolean);

CREATE FUNCTION public.resolve_bulk_recipients(
  p_campaign_id        uuid,
  p_app_statuses       text[]  DEFAULT NULL,
  p_receipt_statuses   text[]  DEFAULT NULL,   -- kind='receipt' 결과물 상태 필터
  p_post_statuses      text[]  DEFAULT NULL,   -- kind IN ('post','review_image') 결과물 상태 필터
  p_channels           text[]  DEFAULT NULL,
  p_min_followers      integer DEFAULT NULL,
  p_require_verified   boolean DEFAULT false,
  p_exclude_violation  boolean DEFAULT false,
  p_exclude_blacklist  boolean DEFAULT true
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
       -- cancelled 항상 제외 (인플 화면 진입 차단 — 메시지 열람 불가)
       AND a.status <> 'cancelled'

       -- ── 응모 상태 필터 ──
       AND (
         p_app_statuses IS NULL
         OR a.status = ANY(p_app_statuses)
       )

       -- ── 영수증(kind='receipt') 결과물 상태 필터 ──
       -- 'none': 영수증 결과물 행이 하나도 없는 응모
       -- 'pending'/'approved'/'rejected': 해당 status 의 영수증 결과물이 EXISTS
       -- NULL 이면 이 블록 전체 통과 (필터 없음)
       AND (
         p_receipt_statuses IS NULL
         OR (
           (
             'none' = ANY(p_receipt_statuses)
             AND NOT EXISTS (
               SELECT 1 FROM public.deliverables d
                WHERE d.application_id = a.id
                  AND d.kind = 'receipt'
             )
           )
           OR EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind = 'receipt'
                AND d.status = ANY(
                  ARRAY(
                    SELECT x FROM unnest(p_receipt_statuses) x WHERE x <> 'none'
                  )
                )
           )
         )
       )

       -- ── 일반 결과물(kind IN 'post','review_image') 상태 필터 ──
       -- 'none': 해당 종류 결과물 행이 하나도 없는 응모
       -- 'pending'/'approved'/'rejected': 해당 status 의 결과물이 EXISTS
       -- NULL 이면 이 블록 전체 통과 (필터 없음)
       AND (
         p_post_statuses IS NULL
         OR (
           (
             'none' = ANY(p_post_statuses)
             AND NOT EXISTS (
               SELECT 1 FROM public.deliverables d
                WHERE d.application_id = a.id
                  AND d.kind IN ('post', 'review_image')
             )
           )
           OR EXISTS (
             SELECT 1 FROM public.deliverables d
              WHERE d.application_id = a.id
                AND d.kind IN ('post', 'review_image')
                AND d.status = ANY(
                  ARRAY(
                    SELECT x FROM unnest(p_post_statuses) x WHERE x <> 'none'
                  )
                )
           )
         )
       )

       -- ── 채널 필터 ──
       -- 인플루언서가 지정 채널 계정을 보유(핸들 컬럼 NOT NULL AND != '') 하는지 확인.
       -- Qoo10·LIPS·@cosme 는 인스타그램 핸들 보유로 판정 (167 과 동일 근거).
       AND (
         p_channels IS NULL
         OR (
           ('instagram' = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('tiktok'    = ANY(p_channels) AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
           OR ('x'         = ANY(p_channels) AND i.x       IS NOT NULL AND i.x       <> '')
           OR ('youtube'   = ANY(p_channels) AND i.youtube IS NOT NULL AND i.youtube <> '')
           OR ('qoo10'     = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('lips'      = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
           OR ('cosme'     = ANY(p_channels) AND i.ig      IS NOT NULL AND i.ig      <> '')
         )
       )

       -- ── 팔로워 필터 ──
       -- primary_channel 단일 기준 (행 단위 보안 정책(FEATURE_SPEC) §10 + 마이그레이션 141 정책 동일).
       AND (
         p_min_followers IS NULL
         OR (
           CASE
             COALESCE(
               NULLIF(TRIM(v_campaign_primary_ch), ''),
               TRIM(SPLIT_PART(v_campaign_channel, ',', 1))
             )
             WHEN 'instagram' THEN COALESCE(i.ig_followers,       0)
             WHEN 'qoo10'     THEN COALESCE(i.ig_followers,       0)
             WHEN 'tiktok'    THEN COALESCE(i.tiktok_followers,   0)
             WHEN 'x'         THEN COALESCE(i.x_followers,        0)
             WHEN 'youtube'   THEN COALESCE(i.youtube_followers,  0)
             ELSE 0  -- LIPS / @cosme: 팔로워 컬럼 없음
           END
         ) >= p_min_followers
       )

       -- ── 인플루언서 인증 필터 ──
       -- p_require_verified=true 이면 is_verified=true 인플만 포함
       -- (마이그레이션 059: influencers.is_verified boolean NOT NULL DEFAULT false)
       AND (
         NOT p_require_verified
         OR i.is_verified = true
       )

       -- ── 블랙리스트 필터 ──
       -- p_exclude_blacklist=true(기본값) 이면 is_blacklisted=true 인플 제외
       -- (마이그레이션 059: influencers.is_blacklisted boolean NOT NULL DEFAULT false)
       AND (
         NOT p_exclude_blacklist
         OR COALESCE(i.is_blacklisted, false) = false
       )

       -- ── 위반 이력 필터 ──
       -- p_exclude_violation=true 이면 influencer_flags.action='violation' 이력이
       -- 1건이라도 존재하는 인플 제외.
       -- (마이그레이션 060: action CHECK 에 'violation' 추가됨)
       AND (
         NOT p_exclude_violation
         OR NOT EXISTS (
           SELECT 1
             FROM public.influencer_flags f
            WHERE f.influencer_id = i.id
              AND f.action        = 'violation'
         )
       )

  ) INTO v_result;

  RETURN COALESCE(v_result, ARRAY[]::uuid[]);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], text[], integer, boolean, boolean, boolean)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], text[], integer, boolean, boolean, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.resolve_bulk_recipients(uuid, text[], text[], text[], text[], integer, boolean, boolean, boolean) IS
  '[168] 일괄 발송 대상 응모 ID 배열 반환 (167 재정의 — 결과물 필터 분리 + 인플 상태 필터). '
  'campaign_admin 이상 가드. cancelled 응모 항상 제외. '
  'p_receipt_statuses: NULL=전체, none/pending/approved/rejected 조합 (kind=receipt 한정). '
  'p_post_statuses:    NULL=전체, none/pending/approved/rejected 조합 (kind IN post,review_image 한정). '
  '두 결과물 필터는 AND 연결 (각각 NULL 이면 해당 종류 필터 통과). '
  'p_channels: NULL=전체, 인플루언서 보유 채널 기준. '
  'p_min_followers: NULL=제한없음, primary_channel 단일 기준. '
  'p_require_verified: true 이면 is_verified=true 인플만. '
  'p_exclude_violation: true 이면 influencer_flags.action=violation 이력 있는 인플 제외. '
  'p_exclude_blacklist: true(기본) 이면 is_blacklisted=true 인플 제외. '
  '빈 배열 반환 가능(예외 없음). SECURITY DEFINER + search_path 고정.';


COMMIT;
