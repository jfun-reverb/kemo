-- ════════════════════════════════════════════════════════════════════
-- migration 104: 캠페인 신청 본인 취소 기능 — DB + RPC (PR-A)
-- ════════════════════════════════════════════════════════════════════
--
-- 사양: docs/specs/2026-05-11-application-cancel.md
-- 후속 PR: PR-B (인플루언서 UI), PR-C (관리자 UI), PR-D (알림),
--          PR-E (약관)
--
-- 본 마이그레이션 범위:
--   1. applications 테이블에 취소 보조 컬럼 5종 추가
--   2. (user_id, campaign_id) UNIQUE 제약을 partial unique index 로
--      재구성 (재신청 허용 — cancelled 행 제외)
--   3. cancel_application(uuid, text, text, boolean) 원격 호출 함수
--      (RPC) — 본인 검증 + 결과물 승인 차단 + cancel_phase 도출 +
--      사유·동의 강제 + UPDATE
--   4. lookup_values 시드:
--      - kind='cancel_reason' 6종 (사용자 확정)
--      - kind='violation_reason' 1건 (관리자가 취소를 위반으로
--        등록할 때 기본 선택)
--
-- 부작용 (사양 §2-3 점검):
--   - migration 048 (정원 가드): 슬롯 도달 시 INSERT 차단 — 정상
--   - migration 049 (monitor 자동 승인): 재신청 시 INSERT BEFORE
--     트리거가 다시 작동 → 슬롯 안이면 즉시 approved
--   - migration 058 (applied_count 트리거): status IN ('pending',
--     'approved') 기준이라 cancelled 는 자연 제외 — 슬롯 자동 복원
-- ════════════════════════════════════════════════════════════════════

-- ── 1. applications 테이블 컬럼 추가 ────────────────────────────────
ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS cancelled_at       timestamptz NULL,
  ADD COLUMN IF NOT EXISTS cancel_reason      text NULL,                       -- 자유 텍스트 보충
  ADD COLUMN IF NOT EXISTS cancel_reason_code text NULL,                       -- lookup_values code
  ADD COLUMN IF NOT EXISTS cancel_phase       text NULL
    CHECK (cancel_phase IS NULL OR cancel_phase IN ('recruit','purchase','visit','post','other')),
  ADD COLUMN IF NOT EXISTS previous_status    text NULL;                       -- 취소 직전 상태 백업

COMMENT ON COLUMN public.applications.cancelled_at IS
  '본인 취소 처리 시각. cancel_application RPC 가 now() 로 기록.';
COMMENT ON COLUMN public.applications.cancel_reason IS
  '인플루언서가 입력한 보충 텍스트 (선택, 최대 500자 권장).';
COMMENT ON COLUMN public.applications.cancel_reason_code IS
  'lookup_values(kind=''cancel_reason'') code 참조. recruit 외 단계에서는 NOT NULL.';
COMMENT ON COLUMN public.applications.cancel_phase IS
  '취소 시점의 캠페인 단계: recruit/purchase/visit/post/other.';
COMMENT ON COLUMN public.applications.previous_status IS
  '취소 직전 status 백업 (pending 또는 approved).';

-- ── 2. UNIQUE 제약 → partial unique index (재신청 허용) ──────────────
-- 기존 제약 제거 (이름은 PostgreSQL 자동 명명 규칙)
ALTER TABLE public.applications
  DROP CONSTRAINT IF EXISTS applications_user_id_campaign_id_key;

-- partial unique index: cancelled 행은 제외, 활성 행만 (user_id, campaign_id) 유일
-- → 같은 캠페인에 cancelled 이력이 있어도 재응모(신규 row INSERT) 가능
CREATE UNIQUE INDEX IF NOT EXISTS applications_user_camp_active_uidx
  ON public.applications (user_id, campaign_id)
  WHERE status != 'cancelled';

-- ── 3. cancel_application RPC ──────────────────────────────────────
-- 본인 취소 입구. 클라이언트는 .rpc('cancel_application', {...}) 만 호출.
-- 보안: SECURITY DEFINER + search_path 고정으로 RLS 우회.
-- 본인 검증·결과물 승인 차단·사유·동의 강제는 함수 본체에서 처리.
CREATE OR REPLACE FUNCTION public.cancel_application(
  p_application_id  uuid,
  p_reason_code     text DEFAULT NULL,
  p_reason_note     text DEFAULT NULL,
  p_acknowledged    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app             public.applications%ROWTYPE;
  v_campaign        public.campaigns%ROWTYPE;
  v_phase           text;
  v_deliv_approved  boolean;
BEGIN
  -- 1. 신청 행 잠금 + 본인 검증
  SELECT * INTO v_app
  FROM public.applications
  WHERE id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  -- auth.uid() 가 NULL 인 경우(anon 호출, GRANT 로 이미 차단되지만 명시적 방어)
  -- 도 차단되도록 IS DISTINCT FROM 사용 — `!=` 는 NULL 비교에서 NULL(false 와
  -- 동치) 을 반환해 검증을 silent 하게 통과시킬 수 있음.
  IF v_app.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'not_owner' USING ERRCODE = '42501';
  END IF;

  -- 2. 상태 검증 (pending/approved 만 취소 가능)
  IF v_app.status NOT IN ('pending','approved') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  -- 3. 결과물 1건이라도 승인됐으면 차단 (관리자 수동 처리만)
  SELECT EXISTS (
    SELECT 1 FROM public.deliverables
    WHERE application_id = p_application_id AND status = 'approved'
  ) INTO v_deliv_approved;

  IF v_deliv_approved THEN
    RAISE EXCEPTION 'deliverable_already_approved' USING ERRCODE = '22023';
  END IF;

  -- 4. 캠페인 일자 + now() 비교 → cancel_phase 도출
  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = v_app.campaign_id;

  -- visit_end / purchase_end 가 먼저 평가되어야 visit/purchase 캠페인의
  -- 「현재 단계」가 정확히 잡힌다. submission_end 가 visit_end 보다 이른
  -- 날짜로 잘못 설정되어 있어도 visit/purchase 단계는 먼저 평가하므로
  -- 'post' 로 잘못 직행하지 않는다.
  -- post 분기는 마지막 단계(visit_end/purchase_end/submission_end 중 하나라도
  -- 지났는지) — submission_end 는 결과물 단계 마감이라 가장 마지막에 평가.
  v_phase := CASE
    WHEN v_campaign.purchase_start IS NOT NULL
         AND now() >= v_campaign.purchase_start::timestamptz
         AND (v_campaign.purchase_end IS NULL OR now() <= v_campaign.purchase_end::timestamptz) THEN 'purchase'
    WHEN v_campaign.visit_start IS NOT NULL
         AND now() >= v_campaign.visit_start::timestamptz
         AND (v_campaign.visit_end IS NULL OR now() <= v_campaign.visit_end::timestamptz) THEN 'visit'
    WHEN v_campaign.submission_end IS NOT NULL AND now() > v_campaign.submission_end::timestamptz THEN 'post'
    WHEN v_campaign.purchase_end   IS NOT NULL AND now() > v_campaign.purchase_end::timestamptz   THEN 'post'
    WHEN v_campaign.visit_end      IS NOT NULL AND now() > v_campaign.visit_end::timestamptz      THEN 'post'
    WHEN v_campaign.deadline       IS NOT NULL AND now() <= v_campaign.deadline::timestamptz      THEN 'recruit'
    ELSE 'other'
  END;

  -- 5. recruit 외 단계는 사유·동의 필수
  IF v_phase != 'recruit' THEN
    IF NOT COALESCE(p_acknowledged, false) THEN
      RAISE EXCEPTION 'acknowledgement_required' USING ERRCODE = '22023';
    END IF;
    IF p_reason_code IS NULL OR length(trim(p_reason_code)) = 0 THEN
      RAISE EXCEPTION 'reason_required' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 6. UPDATE
  UPDATE public.applications
  SET status             = 'cancelled',
      previous_status    = v_app.status,
      cancelled_at       = now(),
      cancel_reason_code = NULLIF(trim(p_reason_code), ''),
      cancel_reason      = NULLIF(trim(p_reason_note), ''),
      cancel_phase       = v_phase
  WHERE id = p_application_id;

  RETURN jsonb_build_object(
    'cancel_phase',    v_phase,
    'cancelled_at',    now(),
    'previous_status', v_app.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_application(uuid, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.cancel_application(uuid, text, text, boolean) IS
  '캠페인 신청 본인 취소. 사양 §2-4. 본인 검증 + 결과물 승인 차단 + '
  'cancel_phase 도출 + 사유·동의 강제 + UPDATE. '
  '도입: migration 104 (2026-05-11).';

-- ── 4. lookup_values 시드 — 취소 사유 카테고리 ───────────────────────
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('cancel_reason', 'schedule_unavailable', '참여 가능 일정 부족', '期間内に参加が難しい',      10, true),
  ('cancel_reason', 'personal_reason',      '개인 사정 변경',     '個人的な事情',              20, true),
  ('cancel_reason', 'product_mismatch',     '제품 정보 불일치',   '商品情報が想定と違う',      30, true),
  ('cancel_reason', 'delivery_issue',       '배송 문제',          '配送に問題があった',         40, true),
  ('cancel_reason', 'account_change',       'SNS 계정 변경/제한', 'SNSアカウントの変更・制限', 50, true),
  ('cancel_reason', 'other',                '기타',               'その他',                     90, true)
ON CONFLICT (kind, code) DO NOTHING;

-- ── 5. lookup_values 시드 — 위반 사유 (취소 위반 등록용) ─────────────
-- PR-C 관리자 UI 에서 「위반 등록」 버튼이 이 코드를 기본 선택
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('violation_reason', 'cancel_after_purchase_start', '구매기간 이후 캠페인 신청 취소', '購入期間後の応募取消', 60, true)
ON CONFLICT (kind, code) DO NOTHING;
