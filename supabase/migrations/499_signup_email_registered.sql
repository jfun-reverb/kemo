-- ============================================================
-- 499_signup_email_registered.sql
-- 가입 인증번호 — 「이미 가입된 주소」 판정 도우미 (사용자 결정 2026-10-01)
--   사양서 docs/specs/2026-10-01-signup-email-code-verification.md 설계 ① 변경분
--
-- ▌왜
--   이미 인증 완료 계정이 있는 주소로 「認証する」를 누르면, 번호를 보내 봐야 가입은 실패한다
--   (개발서버 실측 — 사용자가 원인을 모른 채 일반 실패 문구만 봤다). 그래서 발송 함수가
--   **번호 대신 「이미 가입되어 있습니다 → 로그인 / 비밀번호 재설정」 메일**을 보낸다.
--   🔴 화면 응답은 그대로 「sent」 — 가입 여부는 그 메일함 주인만 안다(계정 열거 방지, 완료 기준 10).
--
-- ▌판정
--   인증 완료(email_confirmed_at 있음) 계정이 그 정규화 주소로 있으면 true.
--   · 미인증 계정만 있는 주소는 false — 종전대로 번호를 보내고, 확인 함수(495)가 옛 계정을 정리한다
--   · 탈퇴 확정 회원은 이메일이 자리표시 주소로 바뀌어 있어(396) 일치하지 않는다 → false
--
-- ▌권한 — 🔴 service_role 전용
--   이 함수 자체가 「그 주소가 회원인가」를 답한다. 공개 키·로그인 회원이 부르면 계정 열거가 된다.
--   부여 먼저 → PUBLIC 회수 → anon·authenticated 회수(375 순서).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.signup_email_registered(p_email text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.users u
     WHERE lower(btrim(u.email)) = lower(btrim(coalesce(p_email, '')))
       AND u.email_confirmed_at IS NOT NULL
  );
$$;

COMMENT ON FUNCTION public.signup_email_registered(text) IS
  '[499] 가입 인증번호 발송 함수용 — 그 정규화 주소로 인증 완료 계정이 있으면 true(미인증·탈퇴 자리표시 주소는 false). '
  '🔴 service_role 전용(공개되면 계정 열거).';

GRANT  EXECUTE ON FUNCTION public.signup_email_registered(text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.signup_email_registered(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.signup_email_registered(text) FROM anon, authenticated;

COMMIT;

-- 검증(편집기 = postgres)
-- [1] 권한 — 맨 앞 =X/(PUBLIC) 없음, anon·authenticated 없음
-- SELECT proacl::text FROM pg_proc WHERE proname = 'signup_email_registered';
-- [2] 시험 회원 주소 → true / 없는 주소 → false
-- SELECT public.signup_email_registered('sakura.test@reverb.jp'), public.signup_email_registered('nobody-xyz@example.com');
