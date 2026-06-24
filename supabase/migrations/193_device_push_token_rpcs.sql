-- ============================================================
-- 193_device_push_token_rpcs.sql
-- 2026-06-22
--
-- 목적:
--   기기 푸시 토큰 등록·해지 RPC 2개.
--   192_device_push_tokens.sql 이 먼저 적용되어 있어야 함.
--
-- 변경 내용:
--   [A] register_push_token(p_token, p_platform) — authenticated GRANT
--       - 로그인 사용자의 기기 토큰 등록 또는 갱신 (UPSERT)
--       - 같은 token 이 이미 다른 user_id 로 등록되어 있어도 현재 로그인 사용자로 덮어씀
--         (계정 전환 시 이전 사용자 알림 차단 목적)
--   [B] revoke_push_token(p_token) — authenticated GRANT
--       - 본인 소유 토큰만 DELETE (타인 토큰 삭제 차단)
--       - 로그아웃 / 알림 권한 철회 시 호출
--
-- 보안:
--   - 두 함수 모두 SECURITY DEFINER + SET search_path = ''
--   - auth.uid() NULL 체크로 비로그인 호출 차단
--   - revoke 는 WHERE user_id = auth.uid() 가드로 타인 토큰 삭제 불가
--
-- 행 단위 보안 정책 영향:
--   device_push_tokens 의 INSERT/UPDATE/DELETE 는 RLS 정책 없음(Default Deny).
--   SECURITY DEFINER 함수가 RLS 우회 경로 역할을 하므로 직접 DML 은 여전히 차단됨.
--
-- 경우의 수 처리:
--   1. 여러 기기: 같은 user_id 로 token 이 여러 개 존재 가능 → 각 기기 독립 관리 (정상)
--   2. 계정 전환: 같은 token 에 다른 user_id 가 등록 시 → UPSERT 로 user_id 갱신
--      이전 사용자 입장에서 해당 토큰으로 알림이 안 감 (기기는 1명만)
--   3. 토큰 갱신: APNs 가 새 토큰을 발급하면 → 앱이 register 재호출 → last_seen_at 갱신
--   4. 로그아웃 정리: revoke 호출 → 행 DELETE → 발송 대상에서 즉시 제외
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.register_push_token(text, text);
--   DROP FUNCTION IF EXISTS public.revoke_push_token(text);
-- ============================================================

BEGIN;


-- ============================================================
-- A. register_push_token — 토큰 등록 / 갱신 (UPSERT)
-- ============================================================
CREATE OR REPLACE FUNCTION public.register_push_token(
  p_token    text,
  p_platform text DEFAULT 'ios'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_id      uuid;
BEGIN
  -- 로그인 필수 가드
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'register_push_token: login required'
      USING ERRCODE = '42501';
  END IF;

  -- 입력 검증
  IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
    RAISE EXCEPTION 'register_push_token: token must not be empty'
      USING ERRCODE = '22023';
  END IF;

  IF p_platform NOT IN ('ios') THEN
    RAISE EXCEPTION 'register_push_token: unsupported platform %', p_platform
      USING ERRCODE = '22023';
  END IF;

  -- UPSERT:
  --   token 이 이미 있으면 → user_id·last_seen_at·revoked_at(NULL 로 재활성) 갱신
  --   없으면 → INSERT
  --
  --   user_id 를 갱신하는 이유:
  --     같은 기기에서 계정 전환 시 기존 토큰이 이전 사용자 ID 로 남아 있으면
  --     로그아웃한 사용자에게 알림이 전송될 수 있음. 등록 시점 로그인 사용자로 덮어써서 차단.
  INSERT INTO public.device_push_tokens (user_id, token, platform, created_at, last_seen_at, revoked_at)
  VALUES (v_user_id, p_token, p_platform, now(), now(), NULL)
  ON CONFLICT (token) DO UPDATE
    SET user_id      = EXCLUDED.user_id,
        platform     = EXCLUDED.platform,
        last_seen_at = now(),
        revoked_at   = NULL   -- 이전에 해지됐던 토큰도 재활성
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.register_push_token(text, text) IS
  '[193] 기기 APNs 푸시 토큰 등록/갱신. SECURITY DEFINER — device_push_tokens RLS 우회 경유. '
  '같은 token 으로 계정 전환 시 user_id 를 현재 로그인 사용자로 갱신해 이전 사용자 알림 차단.';

GRANT EXECUTE ON FUNCTION public.register_push_token(text, text) TO authenticated;


-- ============================================================
-- B. revoke_push_token — 토큰 해지 (본인 소유만 DELETE)
-- ============================================================
CREATE OR REPLACE FUNCTION public.revoke_push_token(
  p_token text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  -- 로그인 필수 가드
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'revoke_push_token: login required'
      USING ERRCODE = '42501';
  END IF;

  -- 입력 검증
  IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
    RAISE EXCEPTION 'revoke_push_token: token must not be empty'
      USING ERRCODE = '22023';
  END IF;

  -- 본인 소유 토큰만 삭제 (SECURITY DEFINER 환경에서 user_id 가드 필수)
  -- 타인 토큰에 해당하는 경우 WHERE 불일치로 0행 삭제 → 오류 없이 종료 (열거 방지)
  DELETE FROM public.device_push_tokens
    WHERE token   = p_token
      AND user_id = v_user_id;

  -- DELETE 이유: 로그아웃 후 토큰 흔적을 남길 필요 없음.
  --   감사 목적이 필요해지면 revoked_at = now() 소프트 삭제로 전환 가능.
  --   현재는 발송 백엔드가 없어 감사 로그 부재가 문제 없음.
END;
$$;

COMMENT ON FUNCTION public.revoke_push_token(text) IS
  '[193] 기기 APNs 푸시 토큰 해지 (로그아웃·알림 권한 철회 시 호출). '
  'SECURITY DEFINER — 본인(auth.uid()) 소유 토큰만 DELETE. 타인 토큰은 WHERE 불일치로 무시.';

GRANT EXECUTE ON FUNCTION public.revoke_push_token(text) TO authenticated;


COMMIT;
