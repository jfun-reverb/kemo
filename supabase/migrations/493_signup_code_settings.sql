-- ============================================================
-- 493_signup_code_settings.sql
-- 회원가입 이메일 인증번호 — 조각 D1 「설정 표 + 스위치 변경 시각 트리거」
--   사양서 docs/specs/2026-10-01-signup-email-code-verification.md (설계 ②)
--   작업표 docs/specs/2026-10-01-signup-email-code-verification-breakdown.md (D1)
--
-- 무엇을 하나
--   인증번호·가입 관문의 모든 수치와 스위치를 **한 줄짜리 표**에 둔다.
--   발송·확인 함수, 두 관문(삽입·고쳐 쓰기), 정기 삭제 예약이 이 표에서 매번 읽는다
--   → 수치를 바꿀 때 배포가 필요 없다(SQL 편집기로 한 줄 UPDATE).
--
-- 스위치(mode)
--   standby = 대기(기본) — 확인증이 없거나 틀려도 가입이 지금처럼 통과(옛 흐름).
--   enforce = 강제 — 확인증 없는 가입·미인증 계정의 확인 메일 재발송/재설정 요청을 거부.
--   🔴 강제 → 대기로도 바꿀 수 있다(사고 대응).
--
-- 🔴 이 표는 행 단위 보안 정책을 켜고 정책을 **만들지 않는다**(서버 함수·서비스 키 전용).
--    가입 관문 트리거는 접속 역할이 supabase_auth_admin 이라 이 표를 직접 못 읽는다 →
--    497 의 정의자 권한 도우미(_signup_read_mode)로 읽는다.
--
-- 롤백
--   DROP TABLE IF EXISTS public.signup_code_settings;
--   DROP FUNCTION IF EXISTS public.signup_code_settings_touch();
--   (497 이 이미 적용돼 있으면 497 의 롤백을 먼저 — 관문이 이 표를 읽는다)
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.signup_code_settings (
  id                        smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  -- 스위치. 기본 대기.
  mode                      text        NOT NULL DEFAULT 'standby'
                                          CHECK (mode IN ('standby', 'enforce')),
  -- 스위치를 마지막으로 바꾼 시각 — 아래 트리거만 쓴다(사람이 넣은 값은 무시). 참고 기록.
  mode_changed_at           timestamptz,
  -- 수치 여덟 — 전부 양의 정수
  code_ttl_seconds          integer     NOT NULL DEFAULT 600   CHECK (code_ttl_seconds > 0),
  resend_cooldown_seconds   integer     NOT NULL DEFAULT 60    CHECK (resend_cooldown_seconds > 0),
  max_attempts              integer     NOT NULL DEFAULT 5     CHECK (max_attempts > 0),
  per_email_hourly_limit    integer     NOT NULL DEFAULT 5     CHECK (per_email_hourly_limit > 0),
  global_hourly_limit       integer     NOT NULL DEFAULT 120   CHECK (global_hourly_limit > 0),
  ticket_ttl_seconds        integer     NOT NULL DEFAULT 900   CHECK (ticket_ttl_seconds > 0),
  code_retention_days       integer     NOT NULL DEFAULT 30    CHECK (code_retention_days > 0),
  unverified_purge_days     integer     NOT NULL DEFAULT 7     CHECK (unverified_purge_days > 0),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.signup_code_settings IS
  '[493] 가입 이메일 인증번호 설정(한 줄, id=1). 스위치 mode(standby/enforce) + 수치 8칸. '
  '행 단위 보안 정책 켜고 정책 없음 — 서버 함수·서비스 키 전용. 바꾸는 것은 SQL 편집기로(화면 없음).';

COMMENT ON COLUMN public.signup_code_settings.mode IS
  'standby=대기(옛 흐름 통과) / enforce=강제(확인증 없는 가입·미인증 재발송·재설정 요청 거부). 기본 standby.';
COMMENT ON COLUMN public.signup_code_settings.mode_changed_at IS
  '스위치가 마지막으로 바뀐 시각. 트리거 trg_signup_code_settings_touch 가 mode 가 바뀔 때만 기록(수동 입력 무시).';
COMMENT ON COLUMN public.signup_code_settings.code_retention_days IS
  '🔴 개인정보처리방침에 일수가 적히는 값(인증번호 기록 해시 보관). 바꾸려면 방침 개정 → 시행 7일 전 공지 → 시행일 뒤에 변경.';
COMMENT ON COLUMN public.signup_code_settings.unverified_purge_days IS
  '🔴 개인정보처리방침에 일수가 적히는 값(미인증 가입 신청 파기 기간). 바꾸려면 방침 개정 → 시행 7일 전 공지 → 시행일 뒤에 변경.';
COMMENT ON COLUMN public.signup_code_settings.global_hourly_limit IS
  '전역 시간당 발송 상한. 운영 최대 몰림(2026-04-16 오픈 시각 238건/시)이 오면 걸린다 — 행사·광고 전에 SQL 로 올릴 것.';

-- 스위치 변경 시각 + 수정 시각. 사람이 넣은 mode_changed_at 은 무시한다.
CREATE OR REPLACE FUNCTION public.signup_code_settings_touch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.mode IS DISTINCT FROM OLD.mode THEN
    NEW.mode_changed_at := now();
  ELSE
    NEW.mode_changed_at := OLD.mode_changed_at;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.signup_code_settings_touch() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.signup_code_settings_touch() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_signup_code_settings_touch ON public.signup_code_settings;
CREATE TRIGGER trg_signup_code_settings_touch
  BEFORE UPDATE ON public.signup_code_settings
  FOR EACH ROW EXECUTE FUNCTION public.signup_code_settings_touch();

ALTER TABLE public.signup_code_settings ENABLE ROW LEVEL SECURITY;
-- 정책 없음(의도) — 서버 함수·서비스 키만 접근.

INSERT INTO public.signup_code_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

COMMIT;

-- ------------------------------------------------------------
-- 검증 (조회·시험 UPDATE — 1단계씩)
-- ------------------------------------------------------------
-- [1] 한 줄·대기여야 한다
-- SELECT * FROM public.signup_code_settings;
-- [2] 수치만 바꾸면 mode_changed_at 이 안 찍힌다 (끝에 되돌림)
-- UPDATE public.signup_code_settings SET max_attempts = 6 WHERE id = 1;
-- SELECT mode_changed_at FROM public.signup_code_settings;   -- NULL 그대로
-- UPDATE public.signup_code_settings SET max_attempts = 5 WHERE id = 1;
-- [3] 스위치를 바꾸면 찍힌다 (끝에 대기로 되돌림 — 시각은 남는다)
-- UPDATE public.signup_code_settings SET mode = 'enforce' WHERE id = 1;
-- UPDATE public.signup_code_settings SET mode = 'standby' WHERE id = 1;
-- [4] 로그인 회원·공개 키로 조회 시 0행(정책 없음) — 실제 브라우저로
