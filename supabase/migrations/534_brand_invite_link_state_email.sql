-- ============================================================
-- 534_brand_invite_link_state_email.sql
-- 브랜드 멤버 관리 화면 — 작업 4a: 초대 링크 판정 함수가 발급일·(새 이메일 초대의) 이메일을 돌려준다
--   작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 「작업 4a」 (결정 S0-2·S0-5)
--
-- 목적
--   get_brand_invite_link_state(p_link_id) 의 state='valid' 응답에
--     · issued_at  (초대 줄 issued_at — w01-03 「받은 날」) — new·existing 두 갈래 모두
--     · email      (초대 줄 email — w01-02b 읽기 전용 이메일 칸) — recipient='new' 일 때만
--   를 더한다. existing 갈래와 {state:'invalid'} 에는 email 을 싣지 않는다(w01-03 은 로그인한 계정 이메일을 쓴다 — S0-5).
--
-- 베이스: 현재 원본 532 (supabase/migrations/532_brand_recipient_self_functions.sql 의 get_brand_invite_link_state)
--   → 이 파일이 새 원본 534. 판정·예외 1·2 갈래·브랜드 이름·inviter_name·expires_at 은 532 글자 그대로.
--   바뀐 곳은 마지막 jsonb_build_object 두 칸(issued_at, email) 과 COMMENT 뿐이다.
--
-- 🔴 DROP 하지 않는다 — CREATE OR REPLACE 로만. 532 가 건 실행 권한(anon·authenticated 부여 + PUBLIC 회수)이 그대로 남는다.
--    그래도 파일 끝에 같은 GRANT/REVOKE 를 다시 적었다(멱등, 531~533 관례).
--
-- 배포 순서
--   1) 530~533 이 이미 들어가 있어야 한다(함수가 brand_invites·_brand_invite_acceptable·_brand_email_owner 를 쓴다).
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 작업 4(화면)보다 먼저.
--   3) 🔴 운영 적용 순서: 526 → 527 → 528 → 530 → 531 → 532 → 533 → 534 한 묶음 (개발서버만, 운영 보류 중).
--
-- 보안 판단
--   링크 소지자(= 메일을 받은 사람, 전달받은 사람 포함)에게 새 이메일 초대의 이메일을 주는 것은 사용자 결정이다
--   (피그마 w01-02b 읽기 전용 이메일 칸 — 작업표 S0-2, 2026-10-15). 링크 번호(uuid)가 사실상 비밀 값이다.
--   existing 갈래는 이메일을 싣지 않아 「이 이메일이 브랜드 계정이다」가 드러나지 않는다.
--
-- 롤백: 532_brand_recipient_self_functions.sql 의 get_brand_invite_link_state 정의(551~605행 부근)를 다시 실행한다.
--       (CREATE OR REPLACE 라 권한은 그대로. DROP 불필요)
--
-- 확인 조회 (사용자가 개발 SQL 편집기에서 한 단계씩 실행 — 결과를 보고 다음 단계로)
--   ① 실행 권한 확인 — 맨 앞 `=X/` 없음(PUBLIC 회수), anon·authenticated 모두 실행 가능이어야 한다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND p.proname = 'get_brand_invite_link_state';
--       → acl 이 `=X/` 로 시작하지 않고, anon_can = true, auth_can = true
--
--   ② 없는 링크 번호 → 한 칸짜리 invalid
--     SELECT public.get_brand_invite_link_state(gen_random_uuid());
--       → {"state": "invalid"}
--
--   ③ (개발서버에 대기 초대가 있을 때만 — 읽기 전용, 시험 데이터를 만들지 않는다) 대기 초대의 링크 번호와 갈래 후보 보기
--     SELECT i.link_id, i.recipient_kind, i.email, i.issued_at, i.expires_at
--       FROM public.brand_invites i
--      WHERE i.status = 'pending' AND i.expires_at > now()
--      ORDER BY i.issued_at DESC LIMIT 10;
--       → 줄이 없으면 여기서 끝(화면 시험 때 초대를 만든 뒤 다시).
--
--   ④ ③ 의 link_id 하나를 넣어 호출 (recipient_kind 가 'brand' 인 줄 → existing, 아니면 보통 new)
--     SELECT public.get_brand_invite_link_state('여기에-link_id');
--       → recipient = new      : brand_name, inviter_name, issued_at, expires_at, email 이 모두 있다
--       → recipient = existing : brand_name, inviter_name, issued_at, expires_at 만 있고 email 키가 없다
--
--   ⑤ (선택) 갈래별 email 유무를 한 번에 — 안쪽 판정과 같은 함수를 줄마다 부른다
--     SELECT i.recipient_kind,
--            r->>'recipient'      AS recipient,
--            (r ? 'email')        AS has_email,
--            (r ? 'issued_at')    AS has_issued_at
--       FROM public.brand_invites i,
--            LATERAL (SELECT public.get_brand_invite_link_state(i.link_id) AS r) s
--      WHERE i.status = 'pending' AND i.expires_at > now() AND r->>'state' = 'valid';
--       → recipient='new' 는 has_email=true, 'existing' 은 false, has_issued_at 은 모두 true
-- ============================================================

BEGIN;

-- ── 1. 링크 판정 (재정의 — 베이스 532, 아래 둘만 다르다: issued_at 칸 추가 · new 일 때만 email 칸 추가) ──
CREATE OR REPLACE FUNCTION public.get_brand_invite_link_state(p_link_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv       public.brand_invites%ROWTYPE;
  v_acct      public.brand_accounts%ROWTYPE;
  v_owner     jsonb;
  v_recipient text;
  v_brand     text;
  v_result    jsonb;
BEGIN
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND OR NOT public._brand_invite_acceptable(v_inv.id, NULL, true) THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  IF v_inv.recipient_kind = 'brand' THEN
    v_recipient := 'existing';
  ELSE
    v_owner := public._brand_email_owner(v_inv.email, NULL);
    IF v_owner->>'kind' = 'none' THEN
      v_recipient := 'new';
    ELSE
      SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = NULLIF(v_owner->>'auth_id', '')::uuid;
      IF FOUND AND v_acct.created_via_invite_id = v_inv.id AND v_acct.password_set_at IS NULL THEN
        v_recipient := 'new';        -- 예외 1: 같은 초대의 재시도 — 새 이메일 경로를 이어간다
      ELSE
        v_recipient := 'existing';   -- 예외 2(S0-4): 비밀번호를 정한 브랜드 계정 — 로그인해서 수락
      END IF;
    END IF;
  END IF;

  SELECT b.name INTO v_brand FROM public.brands b WHERE b.id = v_inv.brand_id;

  v_result := jsonb_build_object(
    'state',        'valid',
    'recipient',    v_recipient,
    'brand_name',   v_brand,
    'inviter_name', v_inv.inviter_name,
    'issued_at',    v_inv.issued_at,      -- 534: w01-03 「받은 날」 (두 갈래 모두)
    'expires_at',   v_inv.expires_at
  );

  -- 534: 새 이메일 초대일 때만 초대 줄의 이메일을 싣는다(w01-02b 읽기 전용 칸). existing 에는 싣지 않는다.
  IF v_recipient = 'new' THEN
    v_result := v_result || jsonb_build_object('email', v_inv.email);
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_brand_invite_link_state(uuid) IS
  '[534] 초대 메일 링크 판정(비로그인 가능). 수락 가능이면 {state:valid, recipient:new|existing, brand_name, inviter_name, issued_at, expires_at} + recipient=new 일 때만 email, 아니면 {state:invalid} 한 칸. 판정은 _brand_invite_acceptable(id, NULL, true). 링크 소지자에게 브랜드·보낸 사람 이름을 주는 것은 의도된 예외(작업표 어긋남 3번). 링크 소지자에게 새 이메일 초대의 이메일을 주는 것은 사용자 결정(피그마 w01-02b 읽기 전용 이메일 칸 — 작업표 S0-2, 2026-10-15). 전달받은 사람에게도 보인다. 베이스 532.';

-- ── 2. 실행 권한 (532 와 같은 상태를 다시 적는다 — 멱등) ──
GRANT  EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;
