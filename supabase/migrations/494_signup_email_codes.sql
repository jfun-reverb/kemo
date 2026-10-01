-- ============================================================
-- 494_signup_email_codes.sql
-- 회원가입 이메일 인증번호 — 조각 D2 「번호 표 + 미인증 삭제 실행 기록 표」
--   선행: 493 (설정 표)
--
-- ============================================================
-- 🔴 해시 규격 — 이 파일이 정본이다. Edge Function(발송·확인)과 관문(497)이 모두 따른다
-- ============================================================
--   ① email_hash  = sha256 16진수 64자( lower(btrim(email)) ).
--        SQL : encode(extensions.digest(lower(btrim(p_email)), 'sha256'), 'hex')
--        JS  : sha256hex(email.trim().toLowerCase())   — 243·361 과 같은 형태
--      ⚠️ JS 의 trim/toLowerCase 와 SQL 의 btrim/lower 는 ASCII 이메일에서 같다.
--         더하기 주소(a+1@…)는 정규화하지 않는다(361 과 같은 결정).
--   ② code_hash   = sha256 16진수 64자. 6자리 번호는 100만 가지뿐이라 해시만으로는 쉽게 되돌려진다 →
--        **서버 비밀값을 섞는 것을 권고**: sha256hex(PEPPER + ':' + email_hash + ':' + code).
--        DB 는 이 값을 계산하지 않고 **받은 값끼리 비교만** 한다(발송·확인 함수가 같은 식을 쓸 것).
--   ③ ticket_hash = sha256 16진수 64자( 확인증 원문 ). **비밀값을 섞지 않는다** —
--        관문(497 _signup_ticket_consume)이 SQL 안에서 extensions.digest(원문,'sha256') 로 직접 계산해 대조한다.
--        확인증은 256비트 난수(예: 32바이트 → 64자 16진수)여야 한다.
--   원문 이메일·원문 번호·원문 확인증은 어디에도 저장하지 않는다.
--
-- 롤백
--   DROP TABLE IF EXISTS public.unverified_account_purge_runs;
--   DROP TABLE IF EXISTS public.signup_email_codes;
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.signup_email_codes (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email_hash        text        NOT NULL CHECK (email_hash ~ '^[0-9a-f]{64}$'),
  code_hash         text        NOT NULL CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at        timestamptz NOT NULL,
  attempts          integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  verified_at       timestamptz,
  ticket_hash       text        CHECK (ticket_hash IS NULL OR ticket_hash ~ '^[0-9a-f]{64}$'),
  ticket_expires_at timestamptz,
  ticket_used_at    timestamptz,
  invalidated_at    timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.signup_email_codes IS
  '[494] 가입 이메일 인증번호 기록. 원문 이메일·번호·확인증 미저장(sha256 해시만 — 규격은 파일 머리말). '
  '새 번호를 보내면 새 행 + 같은 주소의 이전 행은 invalidated_at(덮어쓰지 않음 — 재발송을 세려면 행이 남아야 한다). '
  '행 단위 보안 정책 켜고 정책 없음 — 서버 함수 전용. 30일(설정 표) 뒤 정기 삭제(496).';

CREATE INDEX IF NOT EXISTS idx_signup_email_codes_email_created
  ON public.signup_email_codes (email_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_signup_email_codes_created
  ON public.signup_email_codes (created_at);
CREATE UNIQUE INDEX IF NOT EXISTS uq_signup_email_codes_ticket_hash
  ON public.signup_email_codes (ticket_hash) WHERE ticket_hash IS NOT NULL;

ALTER TABLE public.signup_email_codes ENABLE ROW LEVEL SECURITY;
-- 정책 없음(의도).

-- ── 미인증 계정 정기 삭제 실행 기록 (한 실행 = 한 행) ───────────────
CREATE TABLE IF NOT EXISTS public.unverified_account_purge_runs (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at         timestamptz NOT NULL DEFAULT now(),
  deleted_count  integer     NOT NULL DEFAULT 0,
  skipped_count  integer     NOT NULL DEFAULT 0,
  skipped_ids    uuid[]      NOT NULL DEFAULT '{}',
  error_message  text
);

COMMENT ON TABLE public.unverified_account_purge_runs IS
  '[494] 미인증 계정 정기 삭제(498) 실행 기록. 지운 건수·건너뛴 건수·건너뛴 계정 고유번호. '
  '관리자 조회만(화면 없음, SQL 편집기). 쓰기 정책 없음 — 정의자 권한 함수가 넣는다.';

ALTER TABLE public.unverified_account_purge_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "unverified_purge_runs_select_admin" ON public.unverified_account_purge_runs;
CREATE POLICY "unverified_purge_runs_select_admin"
  ON public.unverified_account_purge_runs FOR SELECT
  USING ((SELECT public.is_admin()));   -- 415 방식(행마다 평가 방지)

COMMIT;

-- ------------------------------------------------------------
-- 검증
-- ------------------------------------------------------------
-- [1] 칸·색인·정책
-- SELECT indexname FROM pg_indexes WHERE tablename = 'signup_email_codes';   -- 기본 키 + 3
-- SELECT tablename, policyname, cmd FROM pg_policies
--  WHERE tablename IN ('signup_email_codes','unverified_account_purge_runs');  -- 실행 기록 SELECT 1개만
-- [2] 공개 키·로그인 회원으로 조회하면 0행 — 실제 브라우저로
