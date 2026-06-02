-- =============================================================================
-- 마이그레이션 165: 사용자(인플루언서) 앱 에러 수집
-- 제목    : client error logs — 에러 수집 테이블 + RPC 2종
-- 의존    : 없음 (신규 인프라, 기존 테이블과 독립)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-06-02
-- 사양서  : docs/specs/2026-06-02-client-error-reporting.md
-- 위험도  : 낮음 — 신규 테이블/RPC, 기존 행·정책·트리거 무변경
-- 멱등성  : CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--           DROP FUNCTION IF EXISTS (시그니처 명시), CREATE OR REPLACE FUNCTION,
--           DROP POLICY IF EXISTS + CREATE POLICY
--
-- 변경 요약:
--   [신규] public.client_error_logs  — 에러 fingerprint 묶음 테이블
--   [신규] RPC report_client_error() — anon+authenticated 호출, 서버측 2차 마스킹
--   [신규] RPC resolve_client_error()— 관리자 상태 변경(resolved/ignored/open)
--
-- 설계 결정 — UPDATE 정책 vs resolve RPC:
--   사양서 초안은 "UPDATE 정책 또는 RPC" 양쪽을 허용했으나,
--   ① 관리자 상태변경에 `resolved_by`·`resolved_at`·`resolve_note` 3개 필드를
--      한 트랜잭션에서 원자적으로 기록해야 감사 일관성이 보장되며,
--   ② UPDATE 정책으로 두면 클라이언트가 직접 `status='open'`으로 되돌리는 등
--      임의 조작이 가능해지므로
--   → 상태변경 경로는 resolve_client_error() RPC로 단일화.
--      RLS UPDATE 정책은 생성하지 않음.
--
-- 마스킹 설계 — 2차 방어 정규식:
--   클라이언트 1차 마스킹 이후 서버 RPC에서 아래 패턴을 다시 치환:
--   1) 이메일: \S+@\S+\.\S{2,}  → [email]
--   2) 전화번호: \b0\d{9,10}\b | \+81\d{9,10} | \+82\d{9,10} → [phone]
--   3) 우편번호: \d{3}-\d{4} (하이픈 필수, 7자리 ID 과마스킹 방지)  → [zip]
--   4) Bearer 토큰: Bearer\s+\S+  → Bearer [token]
--   5) PostgreSQL 상세값: \(\w+\)=\([^)]*\)  → [col]=[masked]
--   대상 컬럼: message, stack, page_hash
--
-- 롤백 방법:
--   DROP FUNCTION IF EXISTS public.resolve_client_error(uuid, text, text);
--   DROP FUNCTION IF EXISTS public.report_client_error(text, text, text, text, text, text, text, text, text);
--   DROP TABLE IF EXISTS public.client_error_logs CASCADE;
-- =============================================================================

-- ── 테이블 ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.client_error_logs (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 묶음 키: 메시지+위치 정규화 후 클라이언트가 계산한 해시 문자열
  fingerprint      text        NOT NULL,

  -- 발생 앱 구분 (현재 인플루언서 앱만 사용, admin은 향후 PR 5)
  source           text        NOT NULL DEFAULT 'influencer'
                                CHECK (source IN ('influencer', 'admin')),

  -- 수집 경로: 미처리 예외(window.onerror) / Promise reject / 처리된 에러(friendlyErrorJa)
  kind             text        NOT NULL
                                CHECK (kind IN ('unhandled', 'rejection', 'handled')),

  -- 마스킹된 에러 메시지 (최대 1000자 — RPC 내부에서 자름)
  message          text        NOT NULL,

  -- friendlyError의 [ERR_XXX_NNNNN] 코드 (있는 경우만)
  error_code       text,

  -- 마스킹된 스택 트레이스 (최대 4000자 — RPC 내부에서 자름)
  stack            text,

  -- 발생 화면 해시 (#page-mypage, #detail-xxx 등. UUID 등 개인 식별자는 클라에서 마스킹)
  page_hash        text,

  -- 발생 맥락 라벨 (화이트리스트 문자열만 — 예: 'application_submit', 'auth_login')
  context          text,

  -- 브라우저/OS 식별 문자열 (개인 식별 안 됨)
  user_agent       text,

  -- 로그인 사용자 참조 (NULL = anon 또는 인플루언서 탈퇴로 삭제됨)
  user_id          uuid        REFERENCES public.influencers(id) ON DELETE SET NULL,

  -- 같은 fingerprint+status 조합의 누적 발생 횟수
  occurrence_count integer     NOT NULL DEFAULT 1,

  -- 처음 발생 시각 (open 행 기준; resolved 후 재발하면 새 open 행의 first_seen_at이 갱신됨)
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),

  -- 관리자 처리 상태
  status           text        NOT NULL DEFAULT 'open'
                                CHECK (status IN ('open', 'resolved', 'ignored')),

  -- 처리한 관리자 정보 (resolved/ignored 전환 시 RPC가 채움)
  resolved_by      uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at      timestamptz,
  resolve_note     text,

  -- open 상태에서 같은 fingerprint는 1행으로 묶음.
  -- resolved/ignored 된 뒤 재발하면 새로운 open 행이 생성됨.
  UNIQUE (fingerprint, status)
);

-- 관리자 목록 페인 기본 정렬(미해결 오래된 것 먼저)
CREATE INDEX IF NOT EXISTS client_error_logs_status_lastseen_idx
  ON public.client_error_logs (status, last_seen_at DESC);

-- fingerprint 조회 (RPC의 open 행 UPDATE WHERE 절)
CREATE INDEX IF NOT EXISTS client_error_logs_fingerprint_idx
  ON public.client_error_logs (fingerprint);

-- ── 행 단위 보안 정책(RLS) ────────────────────────────────────────────────────

ALTER TABLE public.client_error_logs ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만 (인플루언서는 자기 에러 로그를 볼 필요 없음)
DROP POLICY IF EXISTS cel_select_admin ON public.client_error_logs;
CREATE POLICY cel_select_admin ON public.client_error_logs
  FOR SELECT USING (public.is_admin());

-- INSERT/UPDATE 직접 정책 없음 → report_client_error / resolve_client_error RPC 경유만 허용
-- (SECURITY DEFINER RPC는 정책을 우회(BYPASSRLS 아님)하는 게 아니라
--  함수 소유자(postgres)의 권한으로 실행되므로 별도 RPC-only 정책 불필요)

-- ── RPC: report_client_error ─────────────────────────────────────────────────
-- anon + authenticated 양쪽 호출 가능.
-- 클라이언트 1차 마스킹 이후 서버측 2차 마스킹을 적용하고
-- open fingerprint가 있으면 occurrence_count 증가, 없으면 신규 INSERT.

DROP FUNCTION IF EXISTS public.report_client_error(text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.report_client_error(
  p_fingerprint  text,
  p_source       text    DEFAULT 'influencer',
  p_kind         text    DEFAULT 'unhandled',
  p_message      text    DEFAULT '',
  p_error_code   text    DEFAULT NULL,
  p_stack        text    DEFAULT NULL,
  p_page_hash    text    DEFAULT NULL,
  p_context      text    DEFAULT NULL,
  p_user_agent   text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();  -- 로그인 사용자이면 채워짐, anon이면 NULL
  v_message  text;
  v_stack    text;
  v_pagehash text;
BEGIN
  -- ── 1. 빈값 가드 ──────────────────────────────────────────────────────────
  -- fingerprint 또는 message가 비어 있으면 의미 없는 로그 → 조용히 종료
  IF coalesce(trim(p_fingerprint), '') = '' OR coalesce(trim(p_message), '') = '' THEN
    RETURN;
  END IF;

  -- source / kind 범위 가드 (CHECK 제약과 이중 방어)
  IF p_source NOT IN ('influencer', 'admin') THEN
    RETURN;
  END IF;
  IF p_kind NOT IN ('unhandled', 'rejection', 'handled') THEN
    RETURN;
  END IF;

  -- ── 2. 길이 제한 ─────────────────────────────────────────────────────────
  v_message  := left(p_message,  1000);
  v_stack    := left(p_stack,    4000);
  v_pagehash := left(p_page_hash, 512);

  -- ── 3. 서버측 2차 마스킹 ─────────────────────────────────────────────────
  -- 클라이언트 1차 마스킹을 통과한 잔존 개인정보를 정규식으로 제거.
  -- 적용 대상: message, stack, page_hash

  -- (a) 이메일 패턴: something@domain.tld
  v_message  := regexp_replace(v_message,  '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');
  v_stack    := regexp_replace(v_stack,    '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g');

  -- (b) 전화번호 패턴: 010-xxxx-xxxx / 0xx-xxxx-xxxx / +81xxxxxxxxx / +82xxxxxxxxx
  v_message  := regexp_replace(v_message,  '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');
  v_stack    := regexp_replace(v_stack,    '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '(\+81|\+82|0)\d[\d\-]{8,12}', '[phone]', 'g');

  -- (c) 우편번호 패턴: 123-4567 (하이픈 필수 — 일본 우편번호는 항상 〒123-4567 형태.
  --     하이픈 없는 7자리 연속 숫자는 주문번호·신청번호 등 ID라 과마스킹 방지 위해 제외)
  v_message  := regexp_replace(v_message,  '\d{3}-\d{4}', '[zip]', 'g');
  v_stack    := regexp_replace(v_stack,    '\d{3}-\d{4}', '[zip]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '\d{3}-\d{4}', '[zip]', 'g');

  -- (d) Bearer 토큰: "Bearer eyJxxx..." 형태
  v_message  := regexp_replace(v_message,  'Bearer\s+\S+', 'Bearer [token]', 'g');
  v_stack    := regexp_replace(v_stack,    'Bearer\s+\S+', 'Bearer [token]', 'g');
  v_pagehash := regexp_replace(v_pagehash, 'Bearer\s+\S+', 'Bearer [token]', 'g');

  -- (e) PostgreSQL 상세 오류값: (column)=(value) 패턴
  --     예: "duplicate key value ... (email)=(user@x.com)"
  v_message  := regexp_replace(v_message,  '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');
  v_stack    := regexp_replace(v_stack,    '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');
  v_pagehash := regexp_replace(v_pagehash, '\(\w+\)=\([^)]*\)', '[col]=[masked]', 'g');

  -- ── 4. open fingerprint가 있으면 카운트 증가, 없으면 신규 INSERT ──────────
  UPDATE public.client_error_logs
     SET occurrence_count = occurrence_count + 1,
         last_seen_at     = now()
   WHERE fingerprint = p_fingerprint
     AND status      = 'open';

  IF NOT FOUND THEN
    -- ON CONFLICT: UPDATE 시점과 INSERT 시점 사이에 다른 세션이 먼저 INSERT 하는
    -- 극히 드문 경합을 UNIQUE(fingerprint, status) 제약으로 안전하게 처리
    INSERT INTO public.client_error_logs
      (fingerprint, source, kind, message, error_code,
       stack, page_hash, context, user_agent, user_id)
    VALUES
      (p_fingerprint,
       p_source,
       p_kind,
       v_message,
       p_error_code,
       v_stack,
       v_pagehash,
       left(p_context,    200),
       left(p_user_agent, 512),
       v_uid)
    ON CONFLICT (fingerprint, status) DO UPDATE
      SET occurrence_count = public.client_error_logs.occurrence_count + 1,
          last_seen_at     = now();
  END IF;

END;
$$;

-- anon(비로그인)과 인증 사용자 모두 호출 가능
GRANT EXECUTE ON FUNCTION public.report_client_error(text, text, text, text, text, text, text, text, text)
  TO anon, authenticated;

-- ── RPC: resolve_client_error ────────────────────────────────────────────────
-- 관리자가 에러 행의 상태를 resolved / ignored / open(되돌리기)으로 변경.
-- 설계 결정: UPDATE 정책 대신 RPC로 단일화
--   - resolved_by·resolved_at·resolve_note 3개 필드를 원자적으로 기록
--   - 클라이언트가 직접 status를 임의 조작하는 경로 차단
--   - open으로 되돌릴 때도 resolved_* 필드를 초기화해 감사 일관성 보장

DROP FUNCTION IF EXISTS public.resolve_client_error(uuid, text, text);

CREATE OR REPLACE FUNCTION public.resolve_client_error(
  p_id     uuid,
  p_status text,
  p_note   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 관리자 권한 가드
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  -- 허용 status 가드
  IF p_status NOT IN ('open', 'resolved', 'ignored') THEN
    RAISE EXCEPTION 'invalid status: %', p_status;
  END IF;

  UPDATE public.client_error_logs
     SET status      = p_status,
         resolved_by = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
         resolved_at = CASE WHEN p_status = 'open' THEN NULL ELSE now()      END,
         resolve_note = CASE WHEN p_status = 'open' THEN NULL ELSE p_note    END
   WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_error_log not found: %', p_id;
  END IF;
END;
$$;

-- 관리자만 호출 가능 (is_admin() 내부 가드와 이중 방어)
GRANT EXECUTE ON FUNCTION public.resolve_client_error(uuid, text, text)
  TO authenticated;

-- =============================================================================
-- 스모크 테스트 (개발 DB 적용 후 SQL Editor에서 실행)
-- SELECT public.report_client_error('fp-smoke-test-001', 'influencer', 'handled', 'smoke test error');
-- SELECT id, fingerprint, source, kind, message, status, occurrence_count FROM public.client_error_logs WHERE fingerprint = 'fp-smoke-test-001';
-- =============================================================================
