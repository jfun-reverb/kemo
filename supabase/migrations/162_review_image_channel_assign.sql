-- =============================================================================
-- 마이그레이션 162: 채널 미지정 리뷰 이미지 → 채널 지정 + 레거시 삭제
-- 제목    : assign_review_image_channel RPC + deliverable_events action 9종 확장
--           + delete_legacy_review_image RPC (super_admin, 지정 불가 행 삭제)
-- 의존    : 035 (deliverables / deliverable_events 원본)
--           158 (deliverables_review_image_app_channel_uniq 유니크 인덱스)
--           159 (review_image 채널 알림 트리거 — status 불변 시 미발화)
--           160 (deliverable_events.action CHECK 7종)
-- 대상    : 개발서버 + 운영서버
-- 사양서  : docs/specs/2026-05-29-deliverable-channel-assign.md §4-7
-- 위험도  : 낮음 — CHECK 확장(멱등) + 신규 RPC 2개. 기존 행·정책 무변경.
-- 멱등성  : DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT,
--           CREATE OR REPLACE FUNCTION
--
-- 롤백 방법:
--   -- 1. RPC 2개 제거
--   DROP FUNCTION IF EXISTS public.assign_review_image_channel(uuid, text);
--   DROP FUNCTION IF EXISTS public.delete_legacy_review_image(uuid, text);
--
--   -- 2. deliverable_events.action CHECK를 160 버전(7종)으로 복원
--   ALTER TABLE public.deliverable_events
--     DROP CONSTRAINT IF EXISTS deliverable_events_action_check;
--   ALTER TABLE public.deliverable_events
--     ADD CONSTRAINT deliverable_events_action_check
--     CHECK (action IN (
--       'submit', 'resubmit', 'approve', 'reject', 'revert',
--       'admin_proxy_submit', 'admin_proxy_revoke'
--     ));
--
-- 한계 사항:
--   deliverable_events.deliverable_id 에 ON DELETE CASCADE (마이그레이션 035)가 걸려 있어
--   delete_legacy_review_image 가 deliverables 행을 DELETE 하면 audit 이벤트도 함께 삭제됨.
--   영구 감사가 필요하다면 별도 audit 테이블 분리를 권장.
-- =============================================================================

BEGIN;

-- ============================================================
-- 섹션 1: deliverable_events.action CHECK 확장 — 9종
--
--   현재(160 기준):
--     ('submit','resubmit','approve','reject','revert',
--      'admin_proxy_submit','admin_proxy_revoke')  ← 7종
--
--   이후(162):
--     위 7종 + 'channel_assign' + 'channel_unassign'  ← 9종
--
--   DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴으로 멱등성 확보.
--   PostgreSQL 인라인 CHECK 자동 제약명: deliverable_events_action_check
-- ============================================================

ALTER TABLE public.deliverable_events
  DROP CONSTRAINT IF EXISTS deliverable_events_action_check;

ALTER TABLE public.deliverable_events
  ADD CONSTRAINT deliverable_events_action_check
  CHECK (action IN (
    'submit',              -- 인플루언서 최초 제출
    'resubmit',            -- 인플루언서 재제출 (반려 후)
    'approve',             -- 관리자 승인
    'reject',              -- 관리자 반려
    'revert',              -- 관리자 되돌리기 (approved/rejected → pending)
    'admin_proxy_submit',  -- 관리자 대리 등록·자동 승인 (마이그레이션 160)
    'admin_proxy_revoke',  -- super_admin 대리 등록 회수 (마이그레이션 160)
    'channel_assign',      -- 관리자 채널 미지정 행에 채널 지정 (마이그레이션 162)
    'channel_unassign'     -- 관리자 채널 지정 해제 → NULL 복귀 (마이그레이션 162)
  ));


-- ============================================================
-- 섹션 2: RPC assign_review_image_channel
--
--   목적  : post_channel IS NULL 인 review_image 행에 채널을 지정하거나
--           지정된 채널을 해제(NULL 복귀)한다.
--
--   핵심 설계 결정:
--     - post_channel 만 UPDATE, status 불변 → 마이그레이션 159 알림 트리거 미발화
--     - 신규 채널 지정은 NULL 행에서만 허용 (이미 지정된 행은 먼저 해제 필요)
--     - 해제(NULL 복귀)는 status IN ('pending','draft') 행만 허용
--       (검수 완료 행 보호 — 승인·반려 이력 정합성 유지)
--     - 유니크 충돌(마이그레이션 158) 사전 체크로 친화적 에러 반환
--     - FOR UPDATE 행 잠금으로 동시 지정 직렬화
--
--   인수  : p_deliverable_id — 대상 deliverable UUID
--           p_post_channel   — 지정할 채널 코드 (NULL 또는 빈 문자열이면 해제)
--   반환  : void
--   권한  : is_campaign_admin() 이상 (campaign_manager 차단)
-- ============================================================

CREATE OR REPLACE FUNCTION public.assign_review_image_channel(
  p_deliverable_id  uuid,
  p_post_channel    text   -- NULL / '' → 해제 동작
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app_id        uuid;
  v_camp_id       uuid;
  v_kind          text;
  v_status        text;
  v_cur_channel   text;
  v_camp_channels text[];
BEGIN

  -- ① 권한 가드: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. campaign_admin 이상이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 대상 행 조회 + 행 잠금 (동시 지정 직렬화)
  SELECT application_id, campaign_id, kind, status, post_channel
    INTO v_app_id, v_camp_id, v_kind, v_status, v_cur_channel
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ③ review_image 행만 허용
  IF v_kind <> 'review_image' THEN
    RAISE EXCEPTION '리뷰 이미지(review_image) 행만 채널 지정이 가능합니다. 현재 종류: %', v_kind
      USING ERRCODE = 'P0001';
  END IF;

  -- ──────────────────────────────────────────
  -- 분기 A: 채널 지정 (p_post_channel 값 있음)
  -- ──────────────────────────────────────────
  IF p_post_channel IS NOT NULL AND trim(p_post_channel) <> '' THEN

    -- ④ 이미 채널이 지정된 행이면 먼저 해제하도록 안내
    IF v_cur_channel IS NOT NULL THEN
      RAISE EXCEPTION '이미 채널이 지정된 행입니다. 해제 후 다시 지정해 주세요. 현재 채널: %', v_cur_channel
        USING ERRCODE = 'P0001';
    END IF;

    -- ⑤ 지정 채널이 해당 캠페인 채널 목록에 속하는지 확인
    SELECT string_to_array(channel, ',')
      INTO v_camp_channels
      FROM public.campaigns
     WHERE id = v_camp_id;

    IF NOT (p_post_channel = ANY (v_camp_channels)) THEN
      RAISE EXCEPTION '이 캠페인의 채널이 아닙니다: %. 캠페인 채널: %',
        p_post_channel, array_to_string(v_camp_channels, ', ')
        USING ERRCODE = '22023';
    END IF;

    -- ⑥ 같은 신청 내 채널 중복 사전 체크 (마이그레이션 158 유니크 인덱스 위반 전 친화적 에러)
    IF EXISTS (
      SELECT 1
        FROM public.deliverables
       WHERE application_id = v_app_id
         AND kind = 'review_image'
         AND post_channel = p_post_channel
    ) THEN
      RAISE EXCEPTION '해당 채널(%)의 리뷰 이미지가 이미 있습니다. 다른 채널을 선택해 주세요.', p_post_channel
        USING ERRCODE = '23505';
    END IF;

    -- ⑦ post_channel UPDATE (status 불변 → 159 트리거 미발화)
    UPDATE public.deliverables
       SET post_channel = p_post_channel
     WHERE id = p_deliverable_id;

    -- ⑧ audit: channel_assign
    INSERT INTO public.deliverable_events (
      deliverable_id,
      actor_id,
      action,
      from_status,
      to_status,
      reason
    )
    VALUES (
      p_deliverable_id,
      auth.uid(),
      'channel_assign',
      v_status,   -- 상태 불변이지만 맥락 기록
      v_status,
      '채널 지정: (없음) → ' || p_post_channel
    );

  -- ──────────────────────────────────────────
  -- 분기 B: 채널 해제 (p_post_channel NULL 또는 빈 문자열)
  -- ──────────────────────────────────────────
  ELSE

    -- ④' 검수 완료 행(approved/rejected)은 해제 차단 — 제출 전(pending/draft)만 허용
    IF v_status NOT IN ('pending', 'draft') THEN
      RAISE EXCEPTION '검수 완료된 행은 채널을 해제할 수 없습니다. 현재 상태: %', v_status
        USING ERRCODE = 'P0001';
    END IF;

    -- ⑤' 이미 NULL이면 해제할 것이 없음 (멱등 허용 — 에러 없이 리턴)
    IF v_cur_channel IS NULL THEN
      RETURN;
    END IF;

    -- ⑥' post_channel NULL 복귀 (status 불변)
    UPDATE public.deliverables
       SET post_channel = NULL
     WHERE id = p_deliverable_id;

    -- ⑦' audit: channel_unassign
    INSERT INTO public.deliverable_events (
      deliverable_id,
      actor_id,
      action,
      from_status,
      to_status,
      reason
    )
    VALUES (
      p_deliverable_id,
      auth.uid(),
      'channel_unassign',
      v_status,
      v_status,
      '채널 해제: ' || v_cur_channel || ' → (없음)'
    );

  END IF;

END;
$$;

REVOKE ALL ON FUNCTION public.assign_review_image_channel(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.assign_review_image_channel(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.assign_review_image_channel IS
  '[162] 채널 미지정(post_channel IS NULL) review_image 행에 채널을 지정하거나 해제한다.'
  ' p_post_channel=NULL/'' → 해제(pending 행만 허용).'
  ' status 불변이므로 마이그레이션 159 알림 트리거는 미발화.';


-- ============================================================
-- 섹션 3: RPC delete_legacy_review_image (super_admin 전용, 옵션 B)
--
--   목적  : 채널이 이미 모두 채워진 신청에서 지정 불가한 NULL 레거시 행을
--           super_admin이 삭제한다 (모든 채널이 이미 할당된 "잉여 행" 처리).
--
--   설계 결정 (옵션 B 채택):
--     - DELETE 방식. deliverable_events ON DELETE CASCADE (마이그레이션 035) 로
--       감사 이벤트가 행 삭제와 함께 소멸함 — 영구 감사 필요 시 별도 테이블 권장.
--     - 삭제 전 audit INSERT (deliverable_events)를 먼저 하지만,
--       이 역시 CASCADE 삭제 대상 — 즉 audit 의도는 "삭제 직전 기록 시도"이나
--       실제로 삭제와 함께 사라지는 한계가 있음 (마이그레이션 160의 admin_proxy_revoke와 동일).
--     - kind='review_image' AND post_channel IS NULL 행만 허용
--       (레거시 행 한정, 채널 지정된 정상 행은 삭제 불가)
--
--   인수  : p_deliverable_id — 삭제할 deliverable UUID
--           p_reason         — 삭제 사유 (기록용, NULL 허용)
--   반환  : void
--   권한  : is_super_admin() 전용
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_legacy_review_image(
  p_deliverable_id  uuid,
  p_reason          text   -- 삭제 사유 (기록용, NULL 허용)
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_kind        text;
  v_channel     text;
  v_status      text;
BEGIN

  -- ① 권한 가드: super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. super_admin 권한이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 대상 행 검증 + 행 잠금
  SELECT kind, post_channel, status
    INTO v_kind, v_channel, v_status
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ③ review_image 행만 허용
  IF v_kind <> 'review_image' THEN
    RAISE EXCEPTION '리뷰 이미지(review_image) 행만 삭제 가능합니다. 현재 종류: %', v_kind
      USING ERRCODE = 'P0001';
  END IF;

  -- ④ 채널이 NULL인 레거시 행만 삭제 허용 (채널 지정된 정상 행은 보호)
  IF v_channel IS NOT NULL THEN
    RAISE EXCEPTION '채널이 지정된 행은 삭제할 수 없습니다. 레거시(채널 미지정) 행만 삭제 가능합니다. 현재 채널: %', v_channel
      USING ERRCODE = 'P0001';
  END IF;

  -- ⑤ deliverables 행 삭제 (ON DELETE CASCADE → deliverable_events도 함께 삭제)
  --    ※ 감사(audit) 한계: deliverable_events 에 삭제 기록을 남겨도 같은 트랜잭션 CASCADE 로
  --      즉시 소멸하므로 무의미 → audit INSERT 를 두지 않음.
  --      영구 감사가 필요하면 deliverables 와 독립된 별도 audit 테이블이 필요(현재 미구현,
  --      마이그레이션 160 admin_proxy_revoke 와 동일 한계). 삭제 대상은 super_admin 전용·
  --      "모든 채널이 이미 채워진 잉여 레거시 행"으로 소수(운영 2건)라 영구 감사 필요성 낮음.
  DELETE FROM public.deliverables
   WHERE id = p_deliverable_id;

END;
$$;

REVOKE ALL ON FUNCTION public.delete_legacy_review_image(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_legacy_review_image(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.delete_legacy_review_image IS
  '[162] 채널 미지정(post_channel IS NULL) review_image 레거시 행을 super_admin이 삭제한다.'
  ' 모든 채널이 이미 할당된 신청에서 지정 불가한 잉여 행 제거용.'
  ' 주의: deliverable_events ON DELETE CASCADE로 audit 이벤트도 함께 삭제됨 (035 한계).';


COMMIT;

-- =============================================================================
-- 적용 후 검증 SQL (SQL Editor에서 1단계씩 순차 실행)
--
-- ★ 개발 DB에서만 실행. 스모크 테스트는 실제 데이터 변경을 수반.
--
-- [1단계] deliverable_events.action CHECK 9종 확인
-- SELECT pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conname = 'deliverable_events_action_check';
-- 기대: channel_assign, channel_unassign 포함 9종 목록
--
-- [2단계] RPC 시그니처 확인 (1단계 확인 후)
-- SELECT proname, pg_get_function_arguments(oid)
--   FROM pg_proc
--  WHERE proname IN (
--    'assign_review_image_channel',
--    'delete_legacy_review_image'
--  );
-- 기대: 2행 반환
--
-- [3단계] 스모크 — NULL→채널 지정 정상 동작 (1단계 확인 후)
--   (개발 DB에서 kind='review_image' AND post_channel IS NULL 인 deliverable UUID 확인)
-- SELECT id, application_id, post_channel, status
--   FROM public.deliverables
--  WHERE kind = 'review_image' AND post_channel IS NULL
--  LIMIT 1;
-- → UUID를 변수로 사용:
-- SELECT public.assign_review_image_channel(
--   '<위에서_조회한_uuid>',
--   '<해당_캠페인의_채널코드_예: qoo10>'
-- );
-- 기대: 오류 없이 반환
-- 확인:
-- SELECT id, post_channel, status
--   FROM public.deliverables
--  WHERE id = '<위UUID>';
-- 기대: post_channel = 'qoo10', status 불변
-- 확인:
-- SELECT action, from_status, to_status, reason
--   FROM public.deliverable_events
--  WHERE deliverable_id = '<위UUID>'
--  ORDER BY created_at DESC LIMIT 1;
-- 기대: action='channel_assign', reason에 '채널 지정: (없음) → qoo10' 포함
--
-- [4단계] 스모크 — 이미 채워진 채널 재지정 시 23505 (3단계 확인 후)
-- SELECT public.assign_review_image_channel(
--   '<3단계에서 방금 채널을 채운 UUID의 동일 신청 내 다른 NULL UUID>',
--   'qoo10'   -- 이미 채워진 채널
-- );
-- 기대: ERROR 23505 (해당 채널 이미 있음)
--
-- [5단계] 스모크 — 권한 없는 사용자 호출 차단 (4단계 확인 후)
--   (인플루언서 계정으로 로그인한 상태에서 실행하거나, anon으로 테스트)
-- SELECT public.assign_review_image_channel('<uuid>', 'qoo10');
-- 기대: ERROR 42501 (campaign_admin 이상 필요)
--
-- [6단계] 스모크 — pending 행 해제 (5단계 확인 후)
-- SELECT public.assign_review_image_channel('<3단계UUID>', NULL);
-- 기대: post_channel = NULL 복귀, deliverable_events에 channel_unassign 기록
--
-- [7단계] 스모크 — approved 행 해제 차단 (6단계 확인 후)
--   (status='approved'인 review_image UUID 확인 후)
-- SELECT public.assign_review_image_channel('<approved_uuid>', NULL);
-- 기대: ERROR P0001 (검수 완료 행 해제 차단)
-- =============================================================================
