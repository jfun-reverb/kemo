-- ============================================================
-- 059_influencer_verify_blacklist.sql
-- 인플루언서 인증(verified) + 블랙리스트(blacklisted) 관리
--
-- 배경:
--   관리자가 인플루언서에 대해 인증 배지 부여 또는 블랙리스트 마킹을
--   수행하고, 소명 가능한 이력을 보존하기 위한 구조.
--   이번 스코프: 마킹 + 감사 이력만. 차단(신청/로그인 제한) 동작 없음.
--
-- 변경 사항:
--   1. influencers 테이블에 상태 컬럼 8개 추가
--   2. influencer_flags 이력 테이블 신규 생성
--   3. lookup_values에 kind='blacklist_reason' seed 5종 추가
--      (lookup_values.kind CHECK 제약 확장 포함)
--   4. RLS 정책:
--      - influencers UPDATE: 상태 컬럼은 BEFORE UPDATE 트리거로 보호
--      - influencer_flags: campaign_admin 이상만 SELECT/INSERT
--   5. SECURITY DEFINER RPC 2개:
--      - set_influencer_verified(target_id, verify, note)
--      - set_influencer_blacklist(target_id, blacklist, reason_code, note)
--
-- rollback:
--   -- RPC 제거
--   DROP FUNCTION IF EXISTS public.set_influencer_verified(uuid, boolean, text);
--   DROP FUNCTION IF EXISTS public.set_influencer_blacklist(uuid, boolean, text, text);
--   -- 트리거 + 트리거 함수 제거
--   DROP TRIGGER IF EXISTS trg_guard_influencer_flag_columns ON public.influencers;
--   DROP FUNCTION IF EXISTS public.guard_influencer_flag_columns();
--   -- influencer_flags 테이블 제거
--   DROP TABLE IF EXISTS public.influencer_flags;
--   -- influencers 컬럼 제거
--   ALTER TABLE public.influencers
--     DROP COLUMN IF EXISTS is_verified,
--     DROP COLUMN IF EXISTS verified_at,
--     DROP COLUMN IF EXISTS verified_by,
--     DROP COLUMN IF EXISTS is_blacklisted,
--     DROP COLUMN IF EXISTS blacklisted_at,
--     DROP COLUMN IF EXISTS blacklisted_by,
--     DROP COLUMN IF EXISTS blacklist_reason_code,
--     DROP COLUMN IF EXISTS blacklist_reason_note;
--   -- lookup_values seed 제거 (선택적)
--   DELETE FROM public.lookup_values WHERE kind = 'blacklist_reason';
--   -- lookup_values kind CHECK 제약 원복 (reject_reason 유지)
--   ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
--   ALTER TABLE public.lookup_values
--     ADD CONSTRAINT lookup_values_kind_check
--     CHECK (kind IN ('channel','category','content_type','ng_item','reject_reason'));
-- ============================================================


-- ============================================================
-- Step 1: influencers 테이블 — 상태 컬럼 추가
-- ============================================================

ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS is_verified         boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS verified_at         timestamptz,
  ADD COLUMN IF NOT EXISTS verified_by         uuid,         -- admins.auth_id (soft ref)
  ADD COLUMN IF NOT EXISTS is_blacklisted      boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS blacklisted_at      timestamptz,
  ADD COLUMN IF NOT EXISTS blacklisted_by      uuid,         -- admins.auth_id (soft ref)
  ADD COLUMN IF NOT EXISTS blacklist_reason_code text,       -- lookup_values.code (soft ref)
  ADD COLUMN IF NOT EXISTS blacklist_reason_note text;       -- 자유 메모

COMMENT ON COLUMN public.influencers.is_verified          IS '[059] 관리자 인증 배지 여부 (campaign_admin 이상만 변경 가능)';
COMMENT ON COLUMN public.influencers.verified_at          IS '[059] 인증 처리 일시';
COMMENT ON COLUMN public.influencers.verified_by          IS '[059] 인증 처리 관리자 auth_id (soft ref → admins.auth_id)';
COMMENT ON COLUMN public.influencers.is_blacklisted       IS '[059] 블랙리스트 마킹 여부 (차단 동작 없음 — 이력 기록 전용)';
COMMENT ON COLUMN public.influencers.blacklisted_at       IS '[059] 블랙리스트 처리 일시';
COMMENT ON COLUMN public.influencers.blacklisted_by       IS '[059] 블랙리스트 처리 관리자 auth_id (soft ref → admins.auth_id)';
COMMENT ON COLUMN public.influencers.blacklist_reason_code IS '[059] 블랙리스트 사유 코드 (lookup_values kind=blacklist_reason, soft ref)';
COMMENT ON COLUMN public.influencers.blacklist_reason_note IS '[059] 블랙리스트 사유 자유 메모';


-- ============================================================
-- Step 2: influencer_flags 이력 테이블 생성
--   influencers의 인증/블랙리스트 상태 변경 감사 로그.
--   PIPA/APPI 소명 요건 충족을 위해 ON DELETE CASCADE로 인플루언서 삭제 시 함께 제거.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.influencer_flags (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id  uuid        NOT NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  action         text        NOT NULL CHECK (action IN ('verify','unverify','blacklist','unblacklist')),
  reason_code    text,       -- 블랙리스트 사유 코드 (verify/unverify 시 NULL)
  note           text,       -- 자유 메모
  set_by         uuid,       -- 처리 관리자 auth_id (관리자 계정 삭제 후에도 이력 보존)
  set_by_name    text,       -- 처리 관리자 이름 스냅샷 (관리자 삭제돼도 이력 유지)
  set_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.influencer_flags IS '[059] 인플루언서 인증/블랙리스트 상태 변경 이력. PIPA/APPI 소명용 감사 로그.';
COMMENT ON COLUMN public.influencer_flags.action      IS 'verify | unverify | blacklist | unblacklist';
COMMENT ON COLUMN public.influencer_flags.reason_code IS '블랙리스트 사유 코드. verify/unverify 시 NULL. lookup_values kind=blacklist_reason soft ref.';
COMMENT ON COLUMN public.influencer_flags.set_by      IS '처리 관리자 auth_id. 관리자 계정 삭제 후에도 이 행은 보존됨.';
COMMENT ON COLUMN public.influencer_flags.set_by_name IS '처리 당시 관리자 이름 스냅샷. 계정 삭제·이름 변경 후에도 이력 판독 가능.';

-- 조회 최적화 인덱스
CREATE INDEX IF NOT EXISTS idx_influencer_flags_influencer_set_at
  ON public.influencer_flags (influencer_id, set_at DESC);

CREATE INDEX IF NOT EXISTS idx_influencer_flags_action
  ON public.influencer_flags (action);


-- ============================================================
-- Step 3: lookup_values — kind='blacklist_reason' 추가
--   kind CHECK 제약을 먼저 확장한 뒤 seed 데이터 삽입.
-- ============================================================

-- 기존 CHECK 제약 교체 (kind 허용값에 'blacklist_reason' 추가)
-- 현재 DB의 CHECK 제약 상태 (039_seed_reject_reasons.sql 기준):
--   ('channel','category','content_type','ng_item','reject_reason')
-- → 'blacklist_reason' 추가
ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN ('channel','category','content_type','ng_item','reject_reason','blacklist_reason'));

-- blacklist_reason seed (중복 삽입 방지: ON CONFLICT DO NOTHING)
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('blacklist_reason', 'spam',               '스팸 행위',             'スパム行為',              10, true),
  ('blacklist_reason', 'fake_followers',     '팔로워 조작 의심',      'フォロワー操作疑惑',      20, true),
  ('blacklist_reason', 'no_show',            '결과물 미제출 반복',    '成果物未提出の繰り返し',  30, true),
  ('blacklist_reason', 'contract_violation', '규약 위반',             '規約違反',                40, true),
  ('blacklist_reason', 'other',              '기타',                  'その他',                  50, true)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- Step 4: RLS — influencer_flags 테이블
--   일반 인플루언서는 자신의 이력도 조회 불가 (완전 차단).
--   campaign_admin 이상만 접근 허용.
-- ============================================================

ALTER TABLE public.influencer_flags ENABLE ROW LEVEL SECURITY;

-- SELECT: campaign_admin 이상
DROP POLICY IF EXISTS "influencer_flags_select_admin" ON public.influencer_flags;
CREATE POLICY "influencer_flags_select_admin"
  ON public.influencer_flags FOR SELECT
  TO authenticated
  USING (public.is_campaign_admin());

-- INSERT: campaign_admin 이상 (RPC에서 호출 — SECURITY DEFINER라 사실상 직접 호출 불필요지만 방어적으로 설정)
DROP POLICY IF EXISTS "influencer_flags_insert_admin" ON public.influencer_flags;
CREATE POLICY "influencer_flags_insert_admin"
  ON public.influencer_flags FOR INSERT
  TO authenticated
  WITH CHECK (public.is_campaign_admin());

-- UPDATE/DELETE: 이력은 불변. 정책 없음 = 전면 차단


-- ============================================================
-- Step 5: BEFORE UPDATE 트리거 — influencers 상태 컬럼 보호
--   influencers UPDATE 정책은 기존 "본인 or is_admin()" 그대로 유지.
--   단, 상태 8개 컬럼은 campaign_admin 이상이 아닌 일반 사용자가
--   직접 UPDATE하려 하면 트리거에서 에러 발생.
--   (PostgreSQL은 컬럼 레벨 UPDATE 권한을 RLS로 직접 제한 불가 — 트리거 방식 사용)
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_influencer_flag_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 상태 컬럼 8개 중 하나라도 변경된 경우
  IF (
    NEW.is_verified          IS DISTINCT FROM OLD.is_verified OR
    NEW.verified_at          IS DISTINCT FROM OLD.verified_at OR
    NEW.verified_by          IS DISTINCT FROM OLD.verified_by OR
    NEW.is_blacklisted       IS DISTINCT FROM OLD.is_blacklisted OR
    NEW.blacklisted_at       IS DISTINCT FROM OLD.blacklisted_at OR
    NEW.blacklisted_by       IS DISTINCT FROM OLD.blacklisted_by OR
    NEW.blacklist_reason_code IS DISTINCT FROM OLD.blacklist_reason_code OR
    NEW.blacklist_reason_note IS DISTINCT FROM OLD.blacklist_reason_note
  ) THEN
    -- 호출자가 campaign_admin 이상인지 확인
    IF NOT EXISTS (
      SELECT 1 FROM public.admins
       WHERE auth_id = auth.uid()
         AND role IN ('super_admin', 'campaign_admin')
    ) THEN
      RAISE EXCEPTION '인증/블랙리스트 컬럼은 campaign_admin 이상만 변경할 수 있습니다.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_influencer_flag_columns() IS
  '[059] influencers 상태 컬럼(is_verified 등 8개) 변경 시 campaign_admin 이상인지 검증. SECURITY DEFINER.';

DROP TRIGGER IF EXISTS trg_guard_influencer_flag_columns ON public.influencers;
CREATE TRIGGER trg_guard_influencer_flag_columns
  BEFORE UPDATE ON public.influencers
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_influencer_flag_columns();


-- ============================================================
-- Step 6: RPC — set_influencer_verified
--   인플루언서 인증/인증 해제를 원자적으로 수행.
--   influencers 컬럼 UPDATE + influencer_flags INSERT를 단일 트랜잭션으로.
--
--   파라미터:
--     p_target_id  — influencers.id (= auth.users.id)
--     p_verify     — true: 인증 부여 / false: 인증 해제
--     p_note       — 자유 메모 (선택)
--
--   동작:
--     - 호출자가 campaign_admin 이상인지 검증
--     - 현재 상태와 동일 요청이면 no-op (RETURN)
--     - influencers 업데이트 + influencer_flags INSERT
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_influencer_verified(
  p_target_id  uuid,
  p_verify     boolean,
  p_note       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_name text;
  v_current     boolean;
  v_action      text;
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

  -- 2. 대상 현재 상태 조회
  SELECT is_verified INTO v_current
    FROM public.influencers
   WHERE id = p_target_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '인플루언서를 찾을 수 없습니다: %', p_target_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 3. 현재 상태와 동일하면 no-op
  IF v_current = p_verify THEN
    RETURN;
  END IF;

  -- 4. action 결정
  v_action := CASE WHEN p_verify THEN 'verify' ELSE 'unverify' END;

  -- 5. influencers 업데이트
  UPDATE public.influencers
     SET is_verified  = p_verify,
         verified_at  = CASE WHEN p_verify THEN now() ELSE NULL END,
         verified_by  = CASE WHEN p_verify THEN v_caller_id ELSE NULL END
   WHERE id = p_target_id;

  -- 6. 이력 INSERT
  INSERT INTO public.influencer_flags
    (influencer_id, action, reason_code, note, set_by, set_by_name)
  VALUES
    (p_target_id, v_action, NULL, p_note, v_caller_id, v_caller_name);
END;
$$;

COMMENT ON FUNCTION public.set_influencer_verified(uuid, boolean, text) IS
  '[059] 인플루언서 인증 상태 변경 RPC. campaign_admin 이상 전용. influencers UPDATE + influencer_flags INSERT 원자 수행.';

-- RPC 실행 권한: authenticated 사용자만 호출 가능 (내부에서 role 재검증)
REVOKE ALL ON FUNCTION public.set_influencer_verified(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_influencer_verified(uuid, boolean, text) TO authenticated;


-- ============================================================
-- Step 7: RPC — set_influencer_blacklist
--   인플루언서 블랙리스트 마킹/해제를 원자적으로 수행.
--
--   파라미터:
--     p_target_id   — influencers.id
--     p_blacklist   — true: 블랙리스트 추가 / false: 해제
--     p_reason_code — 블랙리스트 사유 코드 (lookup_values.code, 추가 시 필수)
--     p_note        — 자유 메모 (선택)
--
--   동작:
--     - 호출자가 campaign_admin 이상인지 검증
--     - 현재 상태와 동일 요청이면 no-op
--     - 블랙리스트 추가(p_blacklist=true) 시 reason_code 필수
--     - influencers 업데이트 + influencer_flags INSERT
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_influencer_blacklist(
  p_target_id   uuid,
  p_blacklist   boolean,
  p_reason_code text DEFAULT NULL,
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
  v_current     boolean;
  v_action      text;
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

  -- 2. 블랙리스트 추가 시 reason_code 필수
  IF p_blacklist AND (p_reason_code IS NULL OR trim(p_reason_code) = '') THEN
    RAISE EXCEPTION '블랙리스트 추가 시 reason_code가 필요합니다.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. 대상 현재 상태 조회
  SELECT is_blacklisted INTO v_current
    FROM public.influencers
   WHERE id = p_target_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '인플루언서를 찾을 수 없습니다: %', p_target_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 4. 현재 상태와 동일하면 no-op
  IF v_current = p_blacklist THEN
    RETURN;
  END IF;

  -- 5. action 결정
  v_action := CASE WHEN p_blacklist THEN 'blacklist' ELSE 'unblacklist' END;

  -- 6. influencers 업데이트
  UPDATE public.influencers
     SET is_blacklisted       = p_blacklist,
         blacklisted_at       = CASE WHEN p_blacklist THEN now() ELSE NULL END,
         blacklisted_by       = CASE WHEN p_blacklist THEN v_caller_id ELSE NULL END,
         blacklist_reason_code = CASE WHEN p_blacklist THEN p_reason_code ELSE NULL END,
         blacklist_reason_note = CASE WHEN p_blacklist THEN p_note ELSE NULL END
   WHERE id = p_target_id;

  -- 7. 이력 INSERT
  INSERT INTO public.influencer_flags
    (influencer_id, action, reason_code, note, set_by, set_by_name)
  VALUES
    (p_target_id, v_action, p_reason_code, p_note, v_caller_id, v_caller_name);
END;
$$;

COMMENT ON FUNCTION public.set_influencer_blacklist(uuid, boolean, text, text) IS
  '[059] 인플루언서 블랙리스트 상태 변경 RPC. campaign_admin 이상 전용. influencers UPDATE + influencer_flags INSERT 원자 수행.';

REVOKE ALL ON FUNCTION public.set_influencer_blacklist(uuid, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_influencer_blacklist(uuid, boolean, text, text) TO authenticated;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. influencers 신규 컬럼 존재 확인 (8개 모두 표시되어야 함)
-- SELECT column_name, data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'influencers'
--    AND column_name IN (
--      'is_verified','verified_at','verified_by',
--      'is_blacklisted','blacklisted_at','blacklisted_by',
--      'blacklist_reason_code','blacklist_reason_note'
--    )
--  ORDER BY column_name;
-- 기대: 8건

-- 2. influencer_flags 테이블 및 인덱스 확인
-- SELECT tablename, indexname FROM pg_indexes
--  WHERE tablename = 'influencer_flags';
-- 기대: idx_influencer_flags_influencer_set_at, idx_influencer_flags_action 포함

-- 3. lookup_values blacklist_reason seed 확인 (5건)
-- SELECT code, name_ko, name_ja FROM public.lookup_values
--  WHERE kind = 'blacklist_reason'
--  ORDER BY sort_order;
-- 기대: spam / fake_followers / no_show / contract_violation / other

-- 4. BEFORE UPDATE 트리거 등록 확인
-- SELECT trigger_name, event_manipulation, action_timing, action_orientation
--   FROM information_schema.triggers
--  WHERE event_object_table = 'influencers'
--    AND trigger_name = 'trg_guard_influencer_flag_columns';
-- 기대: 1건, UPDATE, BEFORE, ROW

-- 5. RPC 함수 존재 및 SECURITY DEFINER 확인
-- SELECT proname, prosecdef, pronargs
--   FROM pg_proc
--  WHERE proname IN ('set_influencer_verified','set_influencer_blacklist')
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 2건, prosecdef = true

-- 6. influencer_flags RLS 정책 확인
-- SELECT policyname, cmd, qual
--   FROM pg_policies
--  WHERE tablename = 'influencer_flags';
-- 기대: influencer_flags_select_admin (SELECT), influencer_flags_insert_admin (INSERT)

-- 7. RPC 동작 테스트 (개발서버에서 관리자 세션으로 실행)
-- SELECT public.set_influencer_verified(
--   (SELECT id FROM public.influencers LIMIT 1),
--   true,
--   '테스트 인증'
-- );
-- 검증:
-- SELECT id, is_verified, verified_at FROM public.influencers WHERE is_verified = true LIMIT 1;
-- SELECT * FROM public.influencer_flags WHERE action = 'verify' ORDER BY set_at DESC LIMIT 1;


-- ============================================================
-- 롤백 방법 (필요 시 아래 순서로 실행)
-- ============================================================
-- Step 1: RPC 제거
-- DROP FUNCTION IF EXISTS public.set_influencer_verified(uuid, boolean, text);
-- DROP FUNCTION IF EXISTS public.set_influencer_blacklist(uuid, boolean, text, text);
--
-- Step 2: 트리거 + 트리거 함수 제거
-- DROP TRIGGER IF EXISTS trg_guard_influencer_flag_columns ON public.influencers;
-- DROP FUNCTION IF EXISTS public.guard_influencer_flag_columns();
--
-- Step 3: influencer_flags 테이블 제거 (이력 영구 삭제 — 주의)
-- DROP TABLE IF EXISTS public.influencer_flags;
--
-- Step 4: influencers 컬럼 제거
-- ALTER TABLE public.influencers
--   DROP COLUMN IF EXISTS is_verified,
--   DROP COLUMN IF EXISTS verified_at,
--   DROP COLUMN IF EXISTS verified_by,
--   DROP COLUMN IF EXISTS is_blacklisted,
--   DROP COLUMN IF EXISTS blacklisted_at,
--   DROP COLUMN IF EXISTS blacklisted_by,
--   DROP COLUMN IF EXISTS blacklist_reason_code,
--   DROP COLUMN IF EXISTS blacklist_reason_note;
--
-- Step 5: lookup_values seed 제거 (선택적)
-- DELETE FROM public.lookup_values WHERE kind = 'blacklist_reason';
--
-- Step 6: lookup_values kind CHECK 제약 원복 (059 추가분만 제거, reject_reason 유지)
-- ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
-- ALTER TABLE public.lookup_values
--   ADD CONSTRAINT lookup_values_kind_check
--   CHECK (kind IN ('channel','category','content_type','ng_item','reject_reason'));
-- ============================================================
