-- ============================================================
-- 109_campaign_ng_history.sql
-- campaign_caution_history 테이블에 NG 사항 변경 이력 컬럼 추가
-- 작성일: 2026-05-12
-- ============================================================
-- 목적:
--   migration 077에서 만든 audit 테이블 campaign_caution_history 에
--   NG 사항(ng_set_id, ng_items) 변경 전/후를 기록하는 컬럼 4종을 추가.
--   또한 record_caution_history() 원격 호출 함수(RPC)에 NG 파라미터 4개를 추가
--   (모두 NULL 기본값 — 기존 호출처에 영향 없음).
--
-- 설계 원칙:
--   - 테이블 이름 변경 없음 (개명 시 행 단위 보안 정책·인덱스 재구성 부담)
--   - 신규 파라미터 모두 DEFAULT NULL → 기존 클라이언트(admin.js)의
--     record_caution_history() 호출이 그대로 동작함
--   - SECURITY DEFINER + SET search_path = '' 유지
--
-- 영향 테이블:
--   campaign_caution_history — 컬럼 4종 추가
--   record_caution_history() RPC — 시그니처 확장 (하위호환)
--
-- 롤백:
--   ALTER TABLE public.campaign_caution_history
--     DROP COLUMN IF EXISTS ng_set_id_prev,
--     DROP COLUMN IF EXISTS ng_set_id_next,
--     DROP COLUMN IF EXISTS ng_items_prev,
--     DROP COLUMN IF EXISTS ng_items_next;
--
--   record_caution_history() 를 077의 원본 시그니처로 되돌림
--   (파라미터 4개 제거 버전으로 DROP 후 재생성).
-- ============================================================

BEGIN;

-- ============================================================
-- Step 1: campaign_caution_history 에 NG 컬럼 4종 추가
-- ============================================================
ALTER TABLE public.campaign_caution_history
  ADD COLUMN IF NOT EXISTS ng_set_id_prev  uuid  NULL,
  ADD COLUMN IF NOT EXISTS ng_set_id_next  uuid  NULL,
  ADD COLUMN IF NOT EXISTS ng_items_prev   jsonb NULL,
  ADD COLUMN IF NOT EXISTS ng_items_next   jsonb NULL;

COMMENT ON COLUMN public.campaign_caution_history.ng_set_id_prev  IS '변경 전 ng_set_id. NULL이면 미선택 또는 비활성 번들.';
COMMENT ON COLUMN public.campaign_caution_history.ng_set_id_next  IS '변경 후 ng_set_id.';
COMMENT ON COLUMN public.campaign_caution_history.ng_items_prev   IS '변경 전 ng_items 스냅샷. NULL이면 NG 변경 없음.';
COMMENT ON COLUMN public.campaign_caution_history.ng_items_next   IS '변경 후 ng_items 스냅샷.';

-- ============================================================
-- Step 2: record_caution_history() RPC 시그니처 확장
--   NG 파라미터 4개 추가, 모두 DEFAULT NULL — 기존 호출처 영향 없음.
--   이전 함수 시그니처(077 원본 11개 파라미터)는 PostgreSQL 함수 오버로드 방식으로
--   공존시키지 않고 CREATE OR REPLACE 로 교체.
--   주의: 기존 GRANT/REVOKE 는 함수 시그니처가 바뀌므로 재설정 필수.
-- ============================================================

-- 기존 11파라미터 함수 DROP (시그니처가 달라 CREATE OR REPLACE 가 교체하지 않음)
-- IF EXISTS 로 재실행 안전망 확보
DROP FUNCTION IF EXISTS public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
);

CREATE OR REPLACE FUNCTION public.record_caution_history(
  p_campaign_id                uuid,
  p_prev_caution_set_id        uuid    DEFAULT NULL,
  p_next_caution_set_id        uuid    DEFAULT NULL,
  p_prev_caution_items         jsonb   DEFAULT NULL,
  p_next_caution_items         jsonb   DEFAULT NULL,
  p_prev_participation_set_id  uuid    DEFAULT NULL,
  p_next_participation_set_id  uuid    DEFAULT NULL,
  p_prev_participation_steps   jsonb   DEFAULT NULL,
  p_next_participation_steps   jsonb   DEFAULT NULL,
  p_app_count                  integer DEFAULT 0,
  p_bypass_ack                 boolean DEFAULT false,
  -- NG 사항 파라미터 (migration 109 신규 — 모두 DEFAULT NULL)
  p_prev_ng_set_id             uuid    DEFAULT NULL,
  p_next_ng_set_id             uuid    DEFAULT NULL,
  p_prev_ng_items              jsonb   DEFAULT NULL,
  p_next_ng_items              jsonb   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_name  text;
  v_id    uuid;
BEGIN
  -- 권한: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'p_campaign_id 가 NULL 입니다' USING ERRCODE = '22023';
  END IF;

  -- 변경자 이름 스냅샷
  SELECT name INTO v_name
  FROM public.admins
  WHERE auth_id = v_uid
  LIMIT 1;

  INSERT INTO public.campaign_caution_history (
    campaign_id,
    changed_by,
    changed_by_name,
    prev_caution_set_id,
    next_caution_set_id,
    prev_caution_items,
    next_caution_items,
    prev_participation_set_id,
    next_participation_set_id,
    prev_participation_steps,
    next_participation_steps,
    app_count_at_change,
    bypass_warning_ack,
    ng_set_id_prev,
    ng_set_id_next,
    ng_items_prev,
    ng_items_next
  ) VALUES (
    p_campaign_id,
    v_uid,
    v_name,
    p_prev_caution_set_id,
    p_next_caution_set_id,
    p_prev_caution_items,
    p_next_caution_items,
    p_prev_participation_set_id,
    p_next_participation_set_id,
    p_prev_participation_steps,
    p_next_participation_steps,
    COALESCE(p_app_count, 0),
    COALESCE(p_bypass_ack, false),
    p_prev_ng_set_id,
    p_next_ng_set_id,
    p_prev_ng_items,
    p_next_ng_items
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END
$$;

COMMENT ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean,
  uuid, uuid, jsonb, jsonb
) IS
  'campaign_caution_history 레코드 INSERT (SECURITY DEFINER, campaign_admin 이상). search_path 고정. 077 Phase 2 + 109 NG 확장.';

-- 권한 재설정 (새 시그니처에 부여)
REVOKE ALL ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean,
  uuid, uuid, jsonb, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean,
  uuid, uuid, jsonb, jsonb
) TO authenticated;

-- ============================================================
-- 검증 쿼리 (수동 실행 후 확인):
--   SELECT column_name FROM information_schema.columns
--     WHERE table_name = 'campaign_caution_history'
--     AND column_name LIKE 'ng%';
--   -- 4행 반환: ng_set_id_prev, ng_set_id_next, ng_items_prev, ng_items_next
--
--   -- 기존 11파라미터 호출도 정상 동작하는지 테스트 (NULL 기본값 덕분에 호환):
--   SELECT public.record_caution_history(
--     '<campaign_uuid>',
--     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, false
--   );
-- ============================================================

COMMIT;
