-- =============================================================================
-- 마이그레이션 183: delete_mismatched_post_deliverable RPC
-- 제목    : 캠페인 채널과 불일치하는 게시물(post) 결과물을 super_admin 이 삭제
-- 의존    : 035 (deliverables / deliverable_events, ON DELETE CASCADE)
--           162 (deliverable_events.action CHECK 9종 — admin_proxy_revoke 포함)
--           182 (캠페인 채널 검증 패턴 참고 — string_to_array + ANY)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-06-16
-- 사양서  : docs/specs/2026-06-16-post-channel-validation-and-proxy-replace.md
-- 위험도  : 낮음 — 신규 RPC 1개. 테이블 구조·기존 RLS·기존 함수 무변경.
-- 멱등성  : DROP FUNCTION IF EXISTS + CREATE OR REPLACE FUNCTION
--
-- 목적:
--   캠페인 요구 채널과 다른 채널로 잘못 저장된 게시물(post) 결과물 행을
--   super_admin 이 직접 삭제할 수 있는 RPC.
--
--   서버 재검증(채널 불일치 시에만 삭제 허용)을 통해 오삭제를 방지하고,
--   승인(approved) 상태 행을 보호한다.
--
-- 설계 결정:
--   - audit INSERT(admin_proxy_revoke 재사용): deliverable_events.ON DELETE CASCADE
--     (마이그레이션 035) 로 audit 이벤트도 행 삭제와 함께 소멸하는 한계는
--     마이그레이션 162 delete_legacy_review_image, 160 admin_proxy_revoke 와 동일.
--     새 action 을 추가하지 않고 기존 admin_proxy_revoke 를 재사용한다
--     ("기존 방식 감수" 결정 — 별도 영구 audit 테이블은 현재 미구현).
--   - Storage 없음: post 결과물은 post_url(외부 URL)만 보유. Storage 파일 삭제 불필요.
--
-- 한계 사항:
--   deliverable_events.deliverable_id 에 ON DELETE CASCADE (마이그레이션 035) 가 걸려 있어
--   이 RPC 가 deliverables 행을 DELETE 하면 직전에 INSERT 한 audit 이벤트도 함께 삭제됨.
--   영구 감사가 필요하다면 별도 audit 테이블 분리를 권장 (현재 미구현).
--
-- 롤백 방법:
--   DROP FUNCTION IF EXISTS public.delete_mismatched_post_deliverable(uuid, text);
-- =============================================================================

BEGIN;

-- ============================================================
-- RPC: delete_mismatched_post_deliverable
--
--   목적  : post_channel 이 캠페인 channel 콤마 목록에 없는 게시물(post) 결과물 행을
--           super_admin 이 삭제한다. 정상 채널이거나 승인된 행은 거부한다.
--
--   인수  : p_deliverable_id — 삭제할 deliverable UUID
--           p_reason         — 삭제 사유 (기록용, NULL 허용)
--   반환  : void
--   권한  : is_super_admin() 전용
-- ============================================================

DROP FUNCTION IF EXISTS public.delete_mismatched_post_deliverable(uuid, text);

CREATE OR REPLACE FUNCTION public.delete_mismatched_post_deliverable(
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
  v_post_channel text;
  v_status      text;
  v_campaign_id uuid;
  v_camp_channel text;
  v_camp_list   text[];
BEGIN

  -- ① 권한 가드: super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. super_admin 권한이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 대상 행 검증 + 행 잠금 (동시 삭제 직렬화)
  SELECT kind, post_channel, status, campaign_id
    INTO v_kind, v_post_channel, v_status, v_campaign_id
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ③ post 행만 허용 (receipt / review_image 오삭제 방지)
  IF v_kind <> 'post' THEN
    RAISE EXCEPTION '게시물(post) 결과물만 삭제할 수 있습니다. 현재 종류: %', v_kind
      USING ERRCODE = 'P0001';
  END IF;

  -- ④ 승인 행 보호: approved 는 삭제 불가 (반려·검수중·draft 만 허용)
  IF v_status = 'approved' THEN
    RAISE EXCEPTION '승인된 게시물은 삭제할 수 없습니다.'
      USING ERRCODE = 'P0001';
  END IF;

  -- ④-b post_channel 미판별(NULL/빈값) 행 보호:
  --   채널이 없는 행은 "잘못된 채널" 이 아니라 "채널 미판별 레거시" 이므로
  --   이 RPC(채널 불일치 정리)의 대상이 아니다. 오삭제 방지.
  IF v_post_channel IS NULL OR trim(v_post_channel) = '' THEN
    RAISE EXCEPTION '채널 정보가 없는 게시물은 채널 불일치 삭제 대상이 아닙니다.'
      USING ERRCODE = 'P0001';
  END IF;

  -- ⑤ 채널 불일치 서버 재검증 (핵심 안전장치)
  --
  --   캠페인의 channel 콤마 목록(공백 제거 + 소문자)에 post_channel 이 포함되면
  --   "정상 채널" 로 간주하여 삭제를 거부한다.
  --
  --   campaigns.channel 이 NULL 이거나 빈 문자열이면 배열이 빈 배열({})이 되어
  --   ANY 검사가 false → 삭제 거부 (레거시 캠페인 보호).
  --   이는 shared.js postChannelMatchesCampaign 의 "빈 값이면 true(정상)" 와 동일한 의미.
  --
  --   즉 삭제가 허용되는 조건은:
  --     1) campaigns.channel 이 비어있지 않고
  --     2) post_channel 이 그 목록에 포함되지 않는 경우(불일치)
  --
  SELECT channel
    INTO v_camp_channel
    FROM public.campaigns
   WHERE id = v_campaign_id;

  -- 공백 제거 후 콤마 분리 (182 채널 검증 패턴과 동일)
  v_camp_list := string_to_array(
    lower(replace(COALESCE(v_camp_channel, ''), ' ', '')),
    ','
  );

  -- 캠페인 채널이 비어있거나, post_channel 이 목록에 있으면 → 정상 채널 → 삭제 거부
  IF array_length(v_camp_list, 1) IS NULL
     OR lower(trim(COALESCE(v_post_channel, ''))) = ANY(v_camp_list)
  THEN
    RAISE EXCEPTION '정상 채널 게시물은 삭제할 수 없습니다.'
      ' (캠페인 채널이 비어있거나, post_channel 이 캠페인 채널 목록에 포함됩니다.'
      ' 현재 post_channel: %, 캠페인 채널: %)',
      COALESCE(v_post_channel, '(NULL)'),
      COALESCE(v_camp_channel, '(NULL)')
      USING ERRCODE = 'P0001';
  END IF;

  -- ⑥ audit: deliverable_events INSERT
  --
  --   신규 action 없이 기존 admin_proxy_revoke 재사용 (새 action 추가하지 않음 — 기존 방식 감수).
  --   from_status = 삭제 전 status(단 CHECK 허용값 pending/rejected 만 — draft 는 NULL),
  --   to_status = NULL (행이 삭제되어 도달 상태 없음).
  --   ⚠️ deliverable_events.from_status/to_status CHECK 는 ('pending','approved','rejected') 만
  --      허용(035) → draft 를 그대로 넣으면 제약 위반. draft 면 NULL 로 기록.
  --
  --   ⚠️ 한계: deliverable_events.deliverable_id 에 ON DELETE CASCADE (마이그레이션 035) 가
  --   걸려 있어, 아래 DELETE 실행과 동시에 이 audit 행도 소멸함.
  --   영구 감사가 필요하면 별도 테이블 분리 권장 (마이그레이션 162 섹션 3, 160 과 동일 한계).
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
    'admin_proxy_revoke',   -- 기존 9종 중 삭제에 가장 가까운 값 재사용
    CASE WHEN v_status IN ('pending','rejected') THEN v_status ELSE NULL END,  -- from_status: draft 면 NULL(CHECK 보호)
    NULL,                   -- to_status: 행 삭제로 도달 상태 없음
    COALESCE(p_reason, '채널 불일치 게시물 삭제')
  );

  -- ⑦ DELETE: deliverables 행 삭제
  --   ON DELETE CASCADE (마이그레이션 035) 로 deliverable_events 도 함께 삭제됨.
  --   Storage 파일 없음 — post 결과물은 post_url(외부 URL)만 보유.
  DELETE FROM public.deliverables
   WHERE id = p_deliverable_id;

END;
$$;

REVOKE ALL ON FUNCTION public.delete_mismatched_post_deliverable(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_mismatched_post_deliverable(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.delete_mismatched_post_deliverable IS
  '[183] 캠페인 채널과 불일치하는 게시물(post) 결과물을 super_admin 이 삭제한다.'
  ' approved 행 및 정상 채널(캠페인 channel 목록에 있는) 행은 거부.'
  ' 주의: deliverable_events ON DELETE CASCADE(035)로 audit 이벤트도 함께 삭제됨.';


COMMIT;

-- =============================================================================
-- 적용 후 검증 SQL (SQL Editor에서 1단계씩 순차 실행)
--
-- ★ 개발 DB에서만 실행.
--
-- [1단계] RPC 시그니처 확인
-- SELECT proname, pg_get_function_arguments(oid)
--   FROM pg_proc
--  WHERE proname = 'delete_mismatched_post_deliverable';
-- 기대: 1행 반환 (p_deliverable_id uuid, p_reason text)
--
-- [2단계] 채널 불일치 post 행 확인 (1단계 이후)
-- SELECT d.id, d.post_channel, d.status, c.channel AS camp_channel
--   FROM public.deliverables d
--   JOIN public.campaigns c ON c.id = d.campaign_id
--  WHERE d.kind = 'post'
--    AND d.status <> 'approved'
--    AND c.channel IS NOT NULL
--    AND c.channel <> ''
--    AND NOT (
--      lower(trim(COALESCE(d.post_channel, '')))
--      = ANY(string_to_array(lower(replace(c.channel,' ','')), ','))
--    )
--  LIMIT 5;
-- 기대: 삭제 후보 행 목록 (없으면 테스트 데이터 생성 필요)
--
-- [3단계] 스모크 — 정상 채널 게시물 삭제 거부 확인 (2단계 이후)
--   (post 이고 캠페인 채널과 일치하는 pending 행 UUID 사용)
-- SELECT public.delete_mismatched_post_deliverable('<정상채널_uuid>', '테스트');
-- 기대: ERROR P0001 (정상 채널 게시물 삭제 불가)
--
-- [4단계] 스모크 — approved 행 삭제 거부 확인 (3단계 이후)
--   (kind='post', status='approved' 인 UUID 사용)
-- SELECT public.delete_mismatched_post_deliverable('<approved_uuid>', '테스트');
-- 기대: ERROR P0001 (승인된 게시물 삭제 불가)
--
-- [5단계] 스모크 — 채널 불일치 행 삭제 정상 동작 (4단계 이후)
--   (2단계에서 찾은 채널 불일치 UUID 사용)
-- SELECT public.delete_mismatched_post_deliverable('<불일치_uuid>', '채널 불일치 삭제 테스트');
-- 기대: 오류 없이 반환
-- 확인:
-- SELECT id FROM public.deliverables WHERE id = '<불일치_uuid>';
-- 기대: 0행 (삭제됨)
--
-- [6단계] 권한 없는 사용자 차단 확인 (5단계 이후)
--   (campaign_admin 또는 인플루언서 계정으로 실행)
-- SELECT public.delete_mismatched_post_deliverable('<임의_uuid>', NULL);
-- 기대: ERROR 42501 (super_admin 권한 필요)
-- =============================================================================
