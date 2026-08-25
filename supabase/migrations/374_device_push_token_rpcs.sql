-- ============================================================
-- 374_device_push_token_rpcs.sql
-- 2026-06-22 (마지막 수정 2026-08-21 — 번호 재배정·실행 권한 회수 추가)
--
-- ⚠️ 적용 이력 — 「이걸 아직 안 돌렸나?」를 파일 이름으로 판단하지 말 것
--   이 파일은 **번호가 두 번 바뀌었다**: 처음 193 → 333 → 374.
--   개발 브랜치가 그 번호들을 먼저 써서 파일 이름이 겹쳤기 때문이다(332 는 일별 방문자수).
--   ★ 개발 데이터베이스: **전부 적용됨** (2026-08-25 파일 통째로 재실행 완료). 처음엔 옛 193 번호로 들어갔고,
--      뒤에 더한 REVOKE 네 줄만 빠져 있었는데 2026-08-25 에 함께 넣었다. 더 돌릴 것 없다.
--      (적용 이력은 파일 이름이 아니라 데이터베이스에만 있어, 이름만 보면 안 돌린 것처럼 보인다.
--       확인하려면 `register_push_token 함수` 가 있는지 직접 조회할 것.)
--   ★ 운영 데이터베이스: **아직 안 들어갔다.** iOS 푸시를 운영에 켤 때 373·374 순서로 적용.
--   ✅ **2026-08-25 해소** — REVOKE 네 줄은 2026-08-21 에 파일에만 더해져 있었고 개발 데이터베이스에는
--      안 들어가 있었다(그동안 두 함수가 비로그인에게도 열려 있었다 — 안쪽 가드가 막아 실피해는 없지만
--      「막히는 것」과 「부를 수 없는 것」은 다르다). 파일을 통째로 다시 돌려 닫았다. 적용 전후 실측:
--        적용 전  {=X/postgres, postgres, anon, authenticated, service_role}   ← 맨 앞 =X/ 가 PUBLIC(모두)
--        적용 후  {postgres, authenticated, service_role}                       ← PUBLIC·anon 사라짐
--      ⚠️ **`has_function_privilege` 로는 이 차이가 안 보인다**(PUBLIC 이 남아 있으면 로그인·비로그인 둘 다 true).
--         `p.proacl::text` 의 **맨 앞 `=X/`** 유무를 볼 것.
--      이 파일은 통째로 다시 돌려도 안전하다(함수는 CREATE OR REPLACE, 권한 문장도 여러 번 돌려도 결과가 같다).
--
-- 목적:
--   기기 푸시 토큰 등록·해지 RPC 2개.
--   373_device_push_tokens.sql 이 먼저 적용되어 있어야 함.
--
-- 변경 내용:
--   [A] register_push_token(p_token, p_platform) — authenticated GRANT
--       - 로그인 사용자의 기기 토큰 등록 또는 갱신 (UPSERT)
--       - 같은 token 이 이미 다른 user_id 로 등록되어 있어도 현재 로그인 사용자로 덮어씀
--         (계정 전환 시 이전 사용자 알림 차단 목적)
--       🔴 **이 덮어쓰기는 「토큰 주인 바꾸기」이고, 발송을 만드는 순간 실제 피해가 된다.**
--          자세한 내용은 이 파일 아래 [A] 본문의 UPSERT 위 주석을 읽을 것. 요약하면 —
--          남의 기기 토큰 값을 아는 로그인 회원이 그것을 자기 것으로 가져갈 수 있고,
--          원래 주인은 알림을 못 받는다. 계정 전환과 데이터상 구분되지 않아 코드로 못 막는다.
--          지금 위험이 낮은 이유 둘 중 하나가 「발송 기능이 없다」인데, 그건 통제가 아니라
--          **기능의 부재**다 — 발송을 만드는 사람이 이 사실을 모르면 그날 사라진다.
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
  --
  --   ⚠️ 알아 둘 성질 — **이 갱신은 「토큰 주인 바꾸기」다.**
  --     로그인한 회원이 **남의 기기 토큰 값을 알아내 넘기면 그 토큰을 자기 것으로 가져갈 수 있고,
  --     그러면 원래 주인은 알림을 못 받는다.** 계정 전환과 데이터상 구분되지 않아 안쪽 검사로는
  --     막을 수 없다(막으면 계정 전환이 깨진다).
  --     지금 실제 위험이 낮은 이유 두 가지 —
  --       ① 토큰은 어느 조회 경로로도 남에게 안 나간다(표 조회 정책 = 본인 행 또는 관리자,
  --          토큰을 돌려주는 함수 없음). 값을 모르면 시도 자체가 불가능하다.
  --       ② **발송 백엔드가 아직 없다** — 못 받을 알림이 애초에 없다.
  --     🔴 **발송을 만들 때 이 성질을 다시 볼 것.** 그때부터는 「알림 못 받게 만들기」가 실제 피해다.
  --        선택지: 주인이 바뀔 때 기록을 남겨 추적 가능하게 / 같은 토큰의 주인 변경 빈도 제한.
  --     (해지 함수는 반대로 `AND user_id = v_user_id` 로 본인 것만 지운다 — 그쪽은 문제없다.)
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
  '[374] 기기 APNs 푸시 토큰 등록/갱신. SECURITY DEFINER — device_push_tokens RLS 우회 경유. '
  '같은 token 으로 계정 전환 시 user_id 를 현재 로그인 사용자로 갱신해 이전 사용자 알림 차단.';

-- ⚠️ 실행 권한은 **회수 먼저, 부여 나중**.
--   Postgres 는 새 함수에 **PUBLIC(모두)** 실행 권한을 기본으로 준다. GRANT 만 적으면
--   「authenticated 에게만 열었다」고 읽히지만 실제로는 **비로그인(anon)도 부를 수 있다.**
--   이 함수들은 SECURITY DEFINER 라 그대로 두면 안 된다(안쪽 auth.uid() NULL 가드가 막아 주긴
--   하지만, 막는 것과 부를 수 없는 것은 다르다).
--   ⚠️ `has_function_privilege` 로 보면 회수 여부가 안 드러난다 — 확인하려면 `proacl::text` 를 볼 것.
--   🔴 **되돌릴 일이 생겨도 REVOKE 를 GRANT 로 뒤집지 말 것.** 이 두 함수의 올바른 상태는
--      **`authenticated` 하나뿐**이다 — PUBLIC·anon 은 애초에 열려 있으면 안 되는 것이었고,
--      Postgres 기본값 때문에 실수로 열려 있었을 뿐이다. 그대로 뒤집으면 **원래 없던
--      비로그인 접근을 새로 여는** 셈이라, 되돌리기가 원래보다 나쁜 상태를 만든다.
--      (2026-08-21 다른 세션이 375 에서 같은 함정을 실제로 겪었다 — 넷 중 셋은 원래부터
--       로그인 전용이었는데 되돌리기 안내가 「GRANT 로 바꾸면 된다」로 적혀 있었다.)
REVOKE ALL ON FUNCTION public.register_push_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_push_token(text, text) FROM anon;
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
  '[374] 기기 APNs 푸시 토큰 해지 (로그아웃·알림 권한 철회 시 호출). '
  'SECURITY DEFINER — 본인(auth.uid()) 소유 토큰만 DELETE. 타인 토큰은 WHERE 불일치로 무시.';

REVOKE ALL ON FUNCTION public.revoke_push_token(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_push_token(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.revoke_push_token(text) TO authenticated;


COMMIT;
