-- ============================================================
-- 077_campaign_caution_history.sql
-- 캠페인 「주의사항/참여방법 변경 게이트」 Phase 2 — 변경 이력 audit 테이블
-- 작성일: 2026-04-30
-- ============================================================
-- 목적:
--   Phase 1(075)에서 closed 캠페인 caution/participation 변경을 트리거로 차단했고,
--   active/scheduled 캠페인은 클라이언트 경고 모달(showSensitiveChangeConfirm)로
--   확인을 받고 진행한다. Phase 2 는 그 "확인 후 변경" 시점의 변경 전/후 스냅샷과
--   당시 신청자 수, 모달 우회 여부(bypass_warning_ack)를 audit 형태로 영구 보존하여
--   추후 "이 캠페인의 caution/participation 이 누가 언제 어떻게 바뀌었나" 추적 가능하게 한다.
--
-- 배경:
--   기존 신청자(applications.caution_snapshot)는 동의 시점 스냅샷이 그대로 남기 때문에
--   효력은 유지된다. 그러나 이후 신규 신청자에게 적용될 신규 문구가 운영자가 의도한 것이
--   맞는지, 변경 시점에 신청자가 몇 명이었는지(bypass_warning_ack) 등의 감사 데이터가
--   필요하다. 클라이언트 트래픽 외부에서 직접 SQL로 변경한 케이스도 추후 기록하려면
--   서버 트리거 audit 으로 확장 가능하지만, 본 마이그레이션은 RPC 경유 명시 기록만 도입.
--
-- 영향 테이블:
--   campaign_caution_history — 신규 (audit 테이블)
--
-- 변경 없음:
--   campaigns / applications / caution_sets / participation_sets — 기존 컬럼/RLS 모두 유지.
--
-- RLS:
--   SELECT: super_admin 만 (감사 목적, 일반 캠페인 매니저 노출 X)
--   INSERT/UPDATE/DELETE: 정책 미정의 — 모든 클라이언트 직접 INSERT 차단.
--                        대신 record_caution_history() SECURITY DEFINER RPC 경유 INSERT 만 허용.
--
-- 인덱스:
--   (campaign_id, changed_at desc) — 캠페인 단위 타임라인 조회용
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.record_caution_history(uuid, jsonb, jsonb, uuid, uuid, jsonb, uuid, uuid, integer, boolean);
--   DROP TABLE IF EXISTS public.campaign_caution_history CASCADE;
-- ============================================================

BEGIN;

-- ============================================================
-- Step 1: campaign_caution_history 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.campaign_caution_history (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 uuid        NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  changed_by                  uuid        NULL,                       -- admins.auth_id (auth.uid()) — admins 행 삭제돼도 이력 보존 위해 FK 미설정
  changed_by_name             text        NULL,                       -- 변경 시점 admin.name 스냅샷 (admins 삭제 대비)
  changed_at                  timestamptz NOT NULL DEFAULT now(),
  prev_caution_set_id         uuid        NULL,
  next_caution_set_id         uuid        NULL,
  prev_caution_items          jsonb       NULL,
  next_caution_items          jsonb       NULL,
  prev_participation_set_id   uuid        NULL,
  next_participation_set_id   uuid        NULL,
  prev_participation_steps    jsonb       NULL,
  next_participation_steps    jsonb       NULL,
  app_count_at_change         integer     NOT NULL DEFAULT 0,         -- 변경 시점의 active(pending+approved) 신청자 수
  bypass_warning_ack          boolean     NOT NULL DEFAULT false      -- 사용자가 경고 모달 「확인하고 저장」을 눌러 통과했는지 여부 (false=신청자 0건이라 모달 미표시)
);

COMMENT ON TABLE  public.campaign_caution_history IS
  '캠페인 주의사항(caution_items/caution_set_id) + 참여방법(participation_steps/participation_set_id) 변경 audit. 077 Phase 2.';
COMMENT ON COLUMN public.campaign_caution_history.changed_by             IS '변경자 auth.uid(). admins 삭제돼도 이력 보존하기 위해 FK 미설정.';
COMMENT ON COLUMN public.campaign_caution_history.changed_by_name        IS '변경 시점 admins.name 스냅샷. 추후 admins 행이 사라져도 라벨 유지.';
COMMENT ON COLUMN public.campaign_caution_history.app_count_at_change    IS 'pending+approved 신청자 수 (변경 직전). bypass_warning_ack 가 true면 ≥1, false면 0인 게 일반적.';
COMMENT ON COLUMN public.campaign_caution_history.bypass_warning_ack     IS 'showSensitiveChangeConfirm 모달을 사용자가 「확인하고 저장」으로 통과했으면 true. 신청자 0건으로 모달 미표시면 false.';

CREATE INDEX IF NOT EXISTS idx_campaign_caution_history_campaign_changed_at
  ON public.campaign_caution_history (campaign_id, changed_at DESC);

-- ============================================================
-- Step 2: RLS — super_admin SELECT 만 허용. INSERT 는 RPC 전용.
-- ============================================================
ALTER TABLE public.campaign_caution_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "campaign_caution_history_select_super" ON public.campaign_caution_history;

CREATE POLICY "campaign_caution_history_select_super" ON public.campaign_caution_history
  FOR SELECT TO authenticated
  USING (public.is_super_admin());

-- INSERT/UPDATE/DELETE 정책은 의도적으로 정의하지 않음 → 클라이언트 직접 INSERT 차단.
-- 아래 record_caution_history() RPC(SECURITY DEFINER, BYPASSRLS)만 INSERT 가능.

-- ============================================================
-- Step 3: SECURITY DEFINER RPC — record_caution_history
-- ============================================================
-- 호출 컨텍스트:
--   dev/js/admin.js:saveCampaignEdit() 가 detectSensitiveChange().anyChanged === true 일 때
--   updateCampaign() 직후 호출. closed 캠페인은 호출 전에 차단되므로 도달하지 않음.
--
-- 권한:
--   campaign_admin 이상만 INSERT 허용. campaign_manager 는 캠페인 편집 권한 자체가 없으므로
--   현실적으로 도달하지 않지만 RPC 안에서도 한 번 더 가드.
--
-- 파라미터:
--   p_campaign_id           — 대상 캠페인
--   p_prev_caution_set_id / p_next_caution_set_id
--   p_prev_caution_items / p_next_caution_items
--   p_prev_participation_set_id / p_next_participation_set_id
--   p_prev_participation_steps / p_next_participation_steps
--   p_app_count             — 호출자가 countActiveApplications() 결과 전달
--   p_bypass_ack            — showSensitiveChangeConfirm 「확인하고 저장」 통과 여부
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_caution_history(
  p_campaign_id                uuid,
  p_prev_caution_set_id        uuid,
  p_next_caution_set_id        uuid,
  p_prev_caution_items         jsonb,
  p_next_caution_items         jsonb,
  p_prev_participation_set_id  uuid,
  p_next_participation_set_id  uuid,
  p_prev_participation_steps   jsonb,
  p_next_participation_steps   jsonb,
  p_app_count                  integer,
  p_bypass_ack                 boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_name      text;
  v_id        uuid;
BEGIN
  -- 권한: campaign_admin 이상
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'p_campaign_id 가 NULL 입니다' USING ERRCODE = '22023';
  END IF;

  -- 변경자 이름 스냅샷 — admins 행이 사라져도 추적 가능하도록 history 에 저장
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
    bypass_warning_ack
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
    COALESCE(p_bypass_ack, false)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END
$$;

COMMENT ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
) IS
  'campaign_caution_history 레코드 INSERT (SECURITY DEFINER, campaign_admin 이상). search_path 고정. 077 Phase 2.';

-- 클라이언트에서 호출 가능하도록 권한 부여
REVOKE ALL ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_caution_history(
  uuid, uuid, uuid, jsonb, jsonb, uuid, uuid, jsonb, jsonb, integer, boolean
) TO authenticated;

-- ============================================================
-- 검증 쿼리 (수동):
--   SELECT count(*) FROM public.campaign_caution_history;
--   -- super_admin 으로 로그인해서:
--   SELECT * FROM public.campaign_caution_history ORDER BY changed_at DESC LIMIT 5;
-- ============================================================

COMMIT;
