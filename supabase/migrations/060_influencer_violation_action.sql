-- ============================================================
-- 060_influencer_violation_action.sql
-- 인플루언서 위반 기록(violation) 액션 추가
--
-- 배경:
--   059에서 influencer_flags 테이블에 verify/unverify/blacklist/unblacklist
--   네 액션을 기록하는 구조를 배포함.
--   블랙리스트 등록과 독립적으로 경고 이력을 누적하는 경량 액션 'violation' 추가.
--   influencers 테이블은 변경하지 않음 (이력 기록 전용).
--
-- 변경 사항:
--   1. influencer_flags.action CHECK 제약 확장
--      ('verify','unverify','blacklist','unblacklist') → + 'violation'
--   2. lookup_values kind CHECK 제약 확장
--      'blacklist_reason' → + 'violation_reason'
--   3. lookup_values kind='violation_reason' seed 5종 추가
--   4. SECURITY DEFINER RPC 1개 추가:
--      record_influencer_violation(p_target_id, p_reason_code, p_note)
--
-- influencers 테이블: 변경 없음 (violation은 이력 기록 전용)
-- RLS: 기존 influencer_flags 정책 그대로 적용
--      (SECURITY DEFINER RPC가 우회하므로 INSERT 정책 별도 추가 불필요)
--
-- rollback:
--   -- Step 1: RPC 제거
--   DROP FUNCTION IF EXISTS public.record_influencer_violation(uuid, text, text);
--
--   -- Step 2: influencer_flags CHECK 제약 원복
--   ALTER TABLE public.influencer_flags
--     DROP CONSTRAINT IF EXISTS influencer_flags_action_check;
--   ALTER TABLE public.influencer_flags
--     ADD CONSTRAINT influencer_flags_action_check
--     CHECK (action IN ('verify','unverify','blacklist','unblacklist'));
--
--   -- Step 3: lookup_values violation_reason seed 제거 (선택적)
--   DELETE FROM public.lookup_values WHERE kind = 'violation_reason';
--
--   -- Step 4: lookup_values kind CHECK 제약 원복
--   ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
--   ALTER TABLE public.lookup_values
--     ADD CONSTRAINT lookup_values_kind_check
--     CHECK (kind IN ('channel','category','content_type','ng_item','reject_reason','blacklist_reason'));
-- ============================================================


-- ============================================================
-- Step 1: influencer_flags.action CHECK 제약 확장
--   기존: ('verify','unverify','blacklist','unblacklist')
--   변경: + 'violation' 추가
--
--   주의: 기존 행의 action 값은 유효하므로 DROP → ADD가 안전.
--   PostgreSQL은 컬럼 레벨 CHECK를 직접 수정할 수 없어 DROP/ADD 방식 사용.
-- ============================================================

ALTER TABLE public.influencer_flags
  DROP CONSTRAINT IF EXISTS influencer_flags_action_check;

ALTER TABLE public.influencer_flags
  ADD CONSTRAINT influencer_flags_action_check
  CHECK (action IN ('verify','unverify','blacklist','unblacklist','violation'));

COMMENT ON COLUMN public.influencer_flags.action IS
  'verify | unverify | blacklist | unblacklist | violation';


-- ============================================================
-- Step 2: lookup_values.kind CHECK 제약 확장
--   기존: ('channel','category','content_type','ng_item','reject_reason','blacklist_reason')
--   변경: + 'violation_reason' 추가
--
--   위반 사유 코드를 lookup_values로 관리해 관리자 페이지에서 편집 가능하게 함.
-- ============================================================

ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN (
    'channel',
    'category',
    'content_type',
    'ng_item',
    'reject_reason',
    'blacklist_reason',
    'violation_reason'
  ));


-- ============================================================
-- Step 3: lookup_values — kind='violation_reason' seed 5종
--   중복 삽입 방지: ON CONFLICT (kind, code) DO NOTHING
--   blacklist_reason과 일부 코드 겹치나 kind가 다르므로 독립 관리.
-- ============================================================

INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('violation_reason', 'late_submission',    '결과물 제출 지연',      '成果物の提出遅延',        10, true),
  ('violation_reason', 'guideline_breach',   '촬영 가이드 미준수',    '撮影ガイドライン不遵守',  20, true),
  ('violation_reason', 'false_report',       '허위 보고',             '虚偽報告',                30, true),
  ('violation_reason', 'inappropriate_post', '부적절한 게시물',       '不適切な投稿',            40, true),
  ('violation_reason', 'other',              '기타',                  'その他',                  50, true)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- Step 4: RPC — record_influencer_violation
--   인플루언서 위반 이력을 influencer_flags에 기록.
--   influencers 테이블은 변경하지 않음 (이력 기록 전용).
--
--   파라미터:
--     p_target_id   — influencers.id (= auth.users.id)
--     p_reason_code — 위반 사유 코드 필수, 빈 문자열 금지
--                     콤마 구분 복수 코드 허용 (예: 'late_submission,guideline_breach')
--     p_note        — 자유 메모 (선택)
--
--   동작:
--     - 호출자가 campaign_admin 이상인지 검증
--     - p_reason_code 빈 문자열 금지 검증
--     - 대상 인플루언서 존재 여부 확인
--     - admins.auth_id = auth.uid()로 호출자 이름 스냅샷 조회
--     - influencer_flags에 action='violation' 행 INSERT
--
--   반환: void
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_influencer_violation(
  p_target_id   uuid,
  p_reason_code text,
  p_note        text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_name text;
  v_exists      boolean;
BEGIN
  -- 1. 호출자 검증: campaign_admin 이상
  v_caller_id := auth.uid();
  SELECT name INTO v_caller_name
    FROM public.admins
   WHERE auth_id = v_caller_id
     AND role IN ('super_admin', 'campaign_admin');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_admin 이상 권한이 필요합니다.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 2. reason_code 필수 검증 (NULL 또는 빈 문자열 금지)
  IF p_reason_code IS NULL OR trim(p_reason_code) = '' THEN
    RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. 대상 인플루언서 존재 확인
  SELECT EXISTS (
    SELECT 1 FROM public.influencers WHERE id = p_target_id
  ) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION '인플루언서를 찾을 수 없습니다: %', p_target_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 4. influencer_flags에 violation 이력 INSERT
  --    influencers 테이블은 변경하지 않음
  INSERT INTO public.influencer_flags
    (influencer_id, action, reason_code, note, set_by, set_by_name)
  VALUES
    (p_target_id, 'violation', trim(p_reason_code), p_note, v_caller_id, v_caller_name);
END;
$$;

COMMENT ON FUNCTION public.record_influencer_violation(uuid, text, text) IS
  '[060] 인플루언서 위반 이력 기록 RPC. campaign_admin 이상 전용. influencer_flags INSERT 전용, influencers 테이블 변경 없음.';

-- RPC 실행 권한: authenticated 사용자만 호출 가능 (내부에서 role 재검증)
REVOKE ALL ON FUNCTION public.record_influencer_violation(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_influencer_violation(uuid, text, text) TO authenticated;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. influencer_flags.action CHECK 제약 확장 확인
--    'violation' 값 허용 여부 검증
-- SELECT conname, pg_get_constraintdef(oid) AS def
--   FROM pg_constraint
--  WHERE conrelid = 'public.influencer_flags'::regclass
--    AND conname = 'influencer_flags_action_check';
-- 기대: def에 'violation' 포함

-- 2. lookup_values violation_reason seed 확인 (5건)
-- SELECT code, name_ko FROM public.lookup_values
--  WHERE kind = 'violation_reason'
--  ORDER BY sort_order;
-- 기대: late_submission / guideline_breach / false_report / inappropriate_post / other

-- 3. RPC 존재 및 SECURITY DEFINER 확인
-- SELECT proname, prosecdef, pronargs
--   FROM pg_proc
--  WHERE proname = 'record_influencer_violation'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1건, prosecdef = true, pronargs = 3

-- 4. RPC 동작 테스트 (개발서버에서 campaign_admin 이상 세션으로 실행)
-- SELECT public.record_influencer_violation(
--   (SELECT id FROM public.influencers LIMIT 1),
--   'guideline_breach',
--   '촬영 각도 가이드 미준수 — 테스트 위반 기록'
-- );
-- 검증:
-- SELECT id, influencer_id, action, reason_code, note, set_by_name, set_at
--   FROM public.influencer_flags
--  WHERE action = 'violation'
--  ORDER BY set_at DESC
--  LIMIT 1;
-- 기대: action='violation', reason_code='guideline_breach', set_by_name=관리자명

-- ============================================================
-- 롤백 방법 (필요 시 아래 순서로 실행)
-- ============================================================
-- Step 1: RPC 제거
-- DROP FUNCTION IF EXISTS public.record_influencer_violation(uuid, text, text);
--
-- Step 2: influencer_flags.action CHECK 제약 원복
-- ALTER TABLE public.influencer_flags
--   DROP CONSTRAINT IF EXISTS influencer_flags_action_check;
-- ALTER TABLE public.influencer_flags
--   ADD CONSTRAINT influencer_flags_action_check
--   CHECK (action IN ('verify','unverify','blacklist','unblacklist'));
-- 주의: action='violation' 기존 행이 있으면 ADD CONSTRAINT 실패.
--       선제 삭제 또는 UPDATE 필요:
--       DELETE FROM public.influencer_flags WHERE action = 'violation';
--
-- Step 3: lookup_values violation_reason seed 제거 (선택적)
-- DELETE FROM public.lookup_values WHERE kind = 'violation_reason';
--
-- Step 4: lookup_values.kind CHECK 제약 원복 (059 상태로)
-- ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
-- ALTER TABLE public.lookup_values
--   ADD CONSTRAINT lookup_values_kind_check
--   CHECK (kind IN ('channel','category','content_type','ng_item','reject_reason','blacklist_reason'));
-- ============================================================
