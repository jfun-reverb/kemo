-- ============================================================
-- 061_influencer_flag_edit.sql
-- influencer_flags violation 행 사후 수정 지원
--
-- 배경:
--   059로 influencer_flags 테이블을 불변 이력으로 구현.
--   060로 violation 액션 추가.
--   관리자 요청: violation 기록의 reason_code / note 사후 수정 가능하게.
--   verify/unverify/blacklist/unblacklist 는 influencers 테이블 상태와
--   연동되어 있으므로 수정 범위 외(이번 마이그레이션에서 제외).
--
-- 변경 사항:
--   1. influencer_flags 에 감사 추적 컬럼 3개 추가
--      - updated_at  timestamptz  (마지막 수정 일시)
--      - updated_by  uuid         (마지막 수정 관리자 auth_id)
--      - updated_by_name  text    (마지막 수정 관리자 이름 스냅샷)
--      원본 set_at / set_by / set_by_name 은 불변 보존
--   2. RLS UPDATE 정책 추가
--      influencer_flags_update_admin: campaign_admin 이상 + action='violation' 행만
--   3. SECURITY DEFINER RPC 추가
--      update_influencer_violation(p_flag_id, p_reason_code, p_note)
--
-- rollback:
--   -- Step 1: RPC 제거
--   DROP FUNCTION IF EXISTS public.update_influencer_violation(uuid, text, text);
--
--   -- Step 2: UPDATE 정책 제거
--   DROP POLICY IF EXISTS "influencer_flags_update_admin" ON public.influencer_flags;
--
--   -- Step 3: 감사 추적 컬럼 제거
--   ALTER TABLE public.influencer_flags
--     DROP COLUMN IF EXISTS updated_at,
--     DROP COLUMN IF EXISTS updated_by,
--     DROP COLUMN IF EXISTS updated_by_name;
-- ============================================================


-- ============================================================
-- Step 1: influencer_flags — 감사 추적 컬럼 3개 추가
--   updated_at/updated_by/updated_by_name 은 violation 수정 시에만 채워짐.
--   NULL = 아직 한 번도 수정되지 않은 원본 이력 행.
-- ============================================================

ALTER TABLE public.influencer_flags
  ADD COLUMN IF NOT EXISTS updated_at       timestamptz,
  ADD COLUMN IF NOT EXISTS updated_by       uuid,
  ADD COLUMN IF NOT EXISTS updated_by_name  text;

COMMENT ON COLUMN public.influencer_flags.updated_at      IS '[061] 마지막 수정 일시. NULL = 원본 그대로 (수정 이력 없음).';
COMMENT ON COLUMN public.influencer_flags.updated_by      IS '[061] 마지막 수정 관리자 auth_id. 관리자 계정 삭제 후에도 이 값은 보존됨.';
COMMENT ON COLUMN public.influencer_flags.updated_by_name IS '[061] 마지막 수정 관리자 이름 스냅샷. 계정 삭제·이름 변경 후에도 이력 판독 가능.';


-- ============================================================
-- Step 2: RLS — UPDATE 정책 추가
--   campaign_admin 이상 + action='violation' 행만 UPDATE 허용.
--   verify/unverify/blacklist/unblacklist 행은 정책 조건에서 제외 → 여전히 불변.
--   DELETE 정책은 추가하지 않음 (이력 완전 삭제 금지).
-- ============================================================

DROP POLICY IF EXISTS "influencer_flags_update_admin" ON public.influencer_flags;
CREATE POLICY "influencer_flags_update_admin"
  ON public.influencer_flags FOR UPDATE
  TO authenticated
  USING (public.is_campaign_admin() AND action = 'violation')
  WITH CHECK (public.is_campaign_admin() AND action = 'violation');

-- NOTE: SECURITY DEFINER RPC 가 이 정책을 우회하지 않도록
--       RPC 내부에서 직접 UPDATE를 수행(superuser context 아님).
--       RPC는 authenticated role 권한으로 실행되므로 RLS 정책이 그대로 적용됨.


-- ============================================================
-- Step 3: RPC — update_influencer_violation
--   violation 이력 행의 reason_code / note 를 사후 수정.
--   수정 가능 필드: reason_code (콤마 구분 복수 코드 허용), note (NULL 허용).
--   감사 컬럼(updated_at/updated_by/updated_by_name) 자동 기록.
--   원본(set_at/set_by/set_by_name) 불변.
--
--   파라미터:
--     p_flag_id     — influencer_flags.id (수정 대상 행 PK)
--     p_reason_code — 위반 사유 코드 필수. 빈 문자열 금지.
--                     콤마 구분 복수 코드 허용 (예: 'late_submission,guideline_breach')
--     p_note        — 자유 메모 (NULL 허용 — 기존 메모 지우기 용도)
--
--   동작:
--     1. 호출자 campaign_admin 이상 검증
--     2. p_flag_id 존재 + action='violation' 검증
--        (verify/blacklist 등 비-violation 행이면 EXCEPTION)
--     3. p_reason_code 빈 문자열 금지 검증
--     4. influencer_flags UPDATE (reason_code, note, updated_at, updated_by, updated_by_name)
--
--   반환: void
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_influencer_violation(
  p_flag_id     uuid,
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
  v_flag_action text;
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

  -- 2. 대상 행 존재 + action 검증
  SELECT action INTO v_flag_action
    FROM public.influencer_flags
   WHERE id = p_flag_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '수정할 이력 행을 찾을 수 없습니다: %', p_flag_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_flag_action <> 'violation' THEN
    RAISE EXCEPTION 'violation 행만 수정할 수 있습니다. (요청된 action: %)', v_flag_action
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. reason_code 필수 검증 (NULL 또는 빈 문자열 금지)
  IF p_reason_code IS NULL OR trim(p_reason_code) = '' THEN
    RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 4. UPDATE: 수정 가능 필드 + 감사 컬럼 기록
  --    원본(set_at/set_by/set_by_name)은 건드리지 않음
  UPDATE public.influencer_flags
     SET reason_code     = trim(p_reason_code),
         note            = p_note,
         updated_at      = now(),
         updated_by      = v_caller_id,
         updated_by_name = v_caller_name
   WHERE id = p_flag_id
     AND action = 'violation';  -- RLS와 동일 조건을 WHERE에도 명시 (이중 방어)
END;
$$;

COMMENT ON FUNCTION public.update_influencer_violation(uuid, text, text) IS
  '[061] influencer_flags의 violation 행 reason_code/note 사후 수정 RPC. '
  'campaign_admin 이상 전용. 원본(set_at/set_by) 불변, 감사 컬럼(updated_at/by/by_name) 기록.';

-- RPC 실행 권한: authenticated 사용자만 호출 가능 (내부에서 role 재검증)
REVOKE ALL ON FUNCTION public.update_influencer_violation(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_influencer_violation(uuid, text, text) TO authenticated;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. 컬럼 3개 존재 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'influencer_flags'
--    AND column_name IN ('updated_at', 'updated_by', 'updated_by_name')
--  ORDER BY column_name;
-- 기대: 3건 (updated_at=timestamptz/YES, updated_by=uuid/YES, updated_by_name=text/YES)

-- 2. RPC SECURITY DEFINER 확인
-- SELECT proname, prosecdef, pronargs
--   FROM pg_proc
--  WHERE proname = 'update_influencer_violation'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1건, prosecdef = true, pronargs = 3

-- 3. UPDATE 정책 존재 확인
-- SELECT policyname, cmd, qual, with_check
--   FROM pg_policies
--  WHERE tablename = 'influencer_flags'
--    AND policyname = 'influencer_flags_update_admin';
-- 기대: 1건, cmd = UPDATE, qual/with_check에 is_campaign_admin() + action='violation' 포함

-- 4. violation 이외 action 수정 거부 테스트 (verify 행으로 시도 — EXCEPTION 발생해야 함)
--    사전 조건: influencer_flags 에 action='verify' 행이 하나 이상 존재해야 함
-- DO $$
-- DECLARE v_verify_flag_id uuid;
-- BEGIN
--   SELECT id INTO v_verify_flag_id
--     FROM public.influencer_flags WHERE action = 'verify' LIMIT 1;
--   IF v_verify_flag_id IS NOT NULL THEN
--     BEGIN
--       PERFORM public.update_influencer_violation(
--         v_verify_flag_id, 'guideline_breach', '테스트 — 거부되어야 함'
--       );
--       RAISE NOTICE 'FAIL: 거부되지 않음';
--     EXCEPTION WHEN check_violation THEN
--       RAISE NOTICE 'OK: violation 이외 action 수정 거부 확인 (SQLSTATE=22000)';
--     END;
--   ELSE
--     RAISE NOTICE 'SKIP: verify 행이 없어 테스트 생략';
--   END IF;
-- END;
-- $$;

-- ============================================================
-- 롤백 방법 (필요 시 아래 순서로 실행)
-- ============================================================
-- 주의: 컬럼 DROP 전에 updated_at IS NOT NULL 인 행이 있어도 무방.
--       컬럼 제거 시 해당 데이터만 삭제됨. 원본(set_at 등)은 보존.
--
-- Step 1: RPC 제거
-- DROP FUNCTION IF EXISTS public.update_influencer_violation(uuid, text, text);
--
-- Step 2: UPDATE 정책 제거
-- DROP POLICY IF EXISTS "influencer_flags_update_admin" ON public.influencer_flags;
--
-- Step 3: 감사 추적 컬럼 제거
-- ALTER TABLE public.influencer_flags
--   DROP COLUMN IF EXISTS updated_at,
--   DROP COLUMN IF EXISTS updated_by,
--   DROP COLUMN IF EXISTS updated_by_name;
-- ============================================================
