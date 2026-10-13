-- =============================================================================
-- 521_client_error_daily.sql
-- 오류 로그 — 날짜·환경별 횟수 표(client_error_daily) + 환경 이름 분류 함수
--
-- 사양서 : docs/specs/2026-10-12-error-log-env-distribution.md (설계 ②)
-- 작업표 : docs/specs/2026-10-12-error-log-env-distribution-breakdown.md 조각 D1
-- 짝     : 522 (도입일·identity_at·조회 함수·수집 함수 재정의). 이 파일이 먼저다.
-- 대상   : 개발서버 먼저 → 검증 → 운영서버
-- 위험도 : 낮음 — 새 표 하나와 순수 계산 함수 하나. 아직 아무도 쓰지 않는다
--          (수집 함수 report_client_error 에 연결하는 것은 522). 기존 표·함수·정책 무변경.
--
-- 편집기 경고: 뜸 — 무해 (아래 「DROP POLICY IF EXISTS」 단어 때문. 같은 이름으로 곧바로 다시 만든다.
--             새 표라 지워질 정책이 애초에 없다). 행 단위 보안은 같은 파일에서 켠다.
--
-- ── 표 ──────────────────────────────────────────────────────────────────────
--   client_error_daily(error_log_id, day, env, count)
--     · error_log_id : client_error_logs.id 참조, 오류 행을 지우면 함께 삭제(ON DELETE CASCADE)
--     · day          : 일본 표준시 날짜 (일별 방문자수 332 와 같은 기준)
--     · env          : 아래 _client_error_env_label() 이 만든 「OS · 브라우저」 이름
--     · count        : 그 날 그 환경에서 난 횟수
--     · 기본 키 (error_log_id, day, env)
--   조회 정책은 관리자(is_admin()), 쓰기 정책은 없음 — 함수(522 의 수집·합치기 함수)만 쓴다.
--   client_error_logs 와 같은 형태라 표 권한(grant)은 건드리지 않는다(행 단위 보안이 막는다).
--   🔴 이 표는 마이그레이션 522 의 수집 함수가 채운다. 522 를 적용하기 전에는 계속 비어 있다.
--
-- ── 환경 이름 목록 (🔴 한 번 정하면 고정 — 이름을 바꾸면 옛 이름과 새 이름이 따로 쌓인다) ──
--   형식 「OS · 브라우저」. OS 는 6종, 브라우저는 아래 표.
--     OS      : iOS(아이폰·아이패드·아이팟) / Android / Windows / macOS / Linux / 기타
--     브라우저 : LINE · Instagram · Facebook      (앱 안 브라우저, 가장 먼저 본다)
--               앱 안 브라우저                    (iOS: 아이폰 UA 에 Safari 표식이 없음 / Android: '; wv)' 표식)
--               Chrome(iOS 는 CriOS) · Safari · Edge(iOS 는 EdgiOS) · Samsung · Firefox(iOS 는 FxiOS)
--               기타                              (Opera 포함, 위에 안 걸린 것)
--   예) 'iOS · Safari' / 'iOS · Chrome' / 'Android · Samsung' / 'macOS · Chrome' / 'Windows · Edge'
--   OS 접두 없는 고정 이름 둘:
--     '봇'         — 검색·광고 수집 로봇(meta-externalads 등)
--     '알 수 없음' — 브라우저 문자열이 NULL·빈 값
--
-- ── 판별 순서 (위에서부터 처음 맞는 것) ─────────────────────────────────────────
--   1) 빈 값                                   → '알 수 없음'
--   2) 봇                                      → '봇'
--      ⚠️ 지시된 순서(앱 → 크롬 → 일반 브라우저 → 봇 → 기타)와 다르다. 이유: Googlebot 처럼
--         봇이 UA 안에 Chrome/Safari 표식을 넣어 일반 브라우저로 읽히기 때문. 봇 판별 정규식은
--         Cubot(휴대폰 이름) 같은 오탐을 피하려고 「bot 앞이 영문자가 아니거나 bot/ 형태」로 좁혔다.
--   3) 앱 안 브라우저: LINE → Instagram → Facebook(FBAN·FBAV·FB_IAB)
--   4) OS 판정 (iOS → Android → Windows → macOS → Linux → 기타)
--   5) iOS : CriOS → FxiOS → EdgiOS → 'safari' 표식 있음(Safari) → 없음('앱 안 브라우저')
--      기타 : Android '; wv)' → 'Edge' → 'Samsung' → Opera('기타') → Firefox → Chrome/Chromium → Safari → '기타'
--
-- ── 「우리 아이폰 앱」 표식은 없다 (생략) ───────────────────────────────────────────
--   저장소(dev/, 오류 수집 코드) 어디에도 우리 앱이 User-Agent 에 붙이는 표식이 없다
--   (appendUserAgent 류 설정 0건 확인). 그래서 따로 이름을 두지 않고, 아이폰 UA 에 Safari 표식이
--   없는 모든 경우를 'iOS · 앱 안 브라우저' 하나로 묶는다 — 우리 앱의 웹뷰도 여기로 들어올
--   가능성이 높다(표본: iPhone ... Mobile/15E148 뒤에 Safari 표식 없음). 앱이 표식을 붙이게 되면
--   이 함수에 갈래를 더하되, 그 전 줄은 옛 이름으로 남는다(이름 고정 원칙).
--   ⚠️ 홈 화면에 추가한 웹앱(독립 실행 모드)도 Safari 표식이 없어 같은 이름으로 읽힌다.
--   ⚠️ 아이패드는 기본이 「Macintosh」를 자칭해 'macOS · Safari' 로 읽힌다(알려진 한계 — 분류는 대략값).
--
-- ── 롤백 ──────────────────────────────────────────────────────────────────
--   DROP TABLE IF EXISTS public.client_error_daily;
--   DROP FUNCTION IF EXISTS public._client_error_env_label(text);
--   (522 를 이미 적용했다면 522 를 먼저 되돌려야 한다 — 522 의 함수들이 이 표·함수를 부른다.
--    522 롤백 방법은 522 머리말 참조.)
-- =============================================================================

BEGIN;

-- ── 1. 표 ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.client_error_daily (
  error_log_id uuid    NOT NULL REFERENCES public.client_error_logs(id) ON DELETE CASCADE,
  day          date    NOT NULL,                 -- 일본 표준시 날짜
  env          text    NOT NULL,                 -- _client_error_env_label() 이 만든 이름
  count        integer NOT NULL DEFAULT 1 CHECK (count >= 0),
  PRIMARY KEY (error_log_id, day, env)
);

-- 기간 조회(get_client_error_counts, 522)가 날짜로 먼저 좁힌다. 기본 키는 error_log_id 가 앞이라 별도 인덱스.
CREATE INDEX IF NOT EXISTS client_error_daily_day_idx
  ON public.client_error_daily (day);

COMMENT ON TABLE public.client_error_daily IS
  '[521] 오류 로그 날짜(일본 표준시)·환경(OS · 브라우저 이름)별 횟수. 오류 행을 지우면 함께 지워진다. '
  '쓰기는 report_client_error·resolve_client_error(522) 만. 개인과 이어지지 않는 분류 이름별 합계.';

ALTER TABLE public.client_error_daily ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ced_select_admin ON public.client_error_daily;
CREATE POLICY ced_select_admin ON public.client_error_daily
  FOR SELECT USING ((SELECT public.is_admin()));
-- INSERT/UPDATE/DELETE 정책 없음 → SECURITY DEFINER 함수만 쓴다.

-- ── 2. 환경 이름 분류 함수 (순수 계산 — 표를 읽지 않는다) ─────────────────────────
CREATE OR REPLACE FUNCTION public._client_error_env_label(p_user_agent text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $fn$
DECLARE
  v_ua text := lower(btrim(coalesce(p_user_agent, '')));
  v_os text;
BEGIN
  -- 1) 빈 값
  IF v_ua = '' THEN
    RETURN '알 수 없음';
  END IF;

  -- 2) 봇 (일반 브라우저 표식을 흉내 내는 봇이 있어 브라우저보다 먼저 본다)
  IF v_ua ~ '[a-z]bot/|(^|[^a-z])bot([^a-z]|$)|crawler|spider|slurp|meta-external|facebookexternalhit|headlesschrome|lighthouse' THEN
    RETURN '봇';
  END IF;

  -- 4) OS (3 보다 먼저 계산해 둔다 — 이름 앞에 붙인다)
  v_os := CASE
    WHEN v_ua ~ 'iphone|ipad|ipod' THEN 'iOS'
    WHEN v_ua LIKE '%android%'     THEN 'Android'
    WHEN v_ua LIKE '%windows%'     THEN 'Windows'
    WHEN v_ua ~ 'macintosh|mac os x' THEN 'macOS'   -- ⚠️ iOS UA 에도 'Mac OS X' 가 있어 iOS 를 위에서 먼저 거른다
    WHEN v_ua LIKE '%linux%'       THEN 'Linux'
    ELSE '기타'
  END;

  -- 3) 앱 안 브라우저
  IF v_ua ~ '(^|[ (;])line/' THEN
    RETURN v_os || ' · LINE';
  END IF;
  IF v_ua LIKE '%instagram%' THEN
    RETURN v_os || ' · Instagram';
  END IF;
  IF v_ua ~ 'fban|fbav|fb_iab' THEN
    RETURN v_os || ' · Facebook';
  END IF;

  -- 5) iOS — 모든 iOS 브라우저는 같은 엔진이라 별도 표식(CriOS 등)으로 가른다
  IF v_os = 'iOS' THEN
    IF v_ua LIKE '%crios/%'  THEN RETURN 'iOS · Chrome';  END IF;
    IF v_ua LIKE '%fxios/%'  THEN RETURN 'iOS · Firefox'; END IF;
    IF v_ua LIKE '%edgios/%' THEN RETURN 'iOS · Edge';    END IF;
    IF v_ua LIKE '%safari%'  THEN RETURN 'iOS · Safari';  END IF;
    RETURN 'iOS · 앱 안 브라우저';   -- Safari 표식 없음 — 앱 웹뷰(우리 앱 포함 추정)·홈 화면 웹앱
  END IF;

  -- 5) 그 밖 OS
  IF v_os = 'Android' AND v_ua LIKE '%; wv)%' THEN
    RETURN 'Android · 앱 안 브라우저';
  END IF;
  IF v_ua ~ '(^|[ (;])(edg|edga|edge)/' THEN RETURN v_os || ' · Edge';    END IF;
  IF v_ua LIKE '%samsungbrowser%'       THEN RETURN v_os || ' · Samsung'; END IF;
  IF v_ua ~ '(^|[ (;])opr/|opera'       THEN RETURN v_os || ' · 기타';    END IF;
  IF v_ua LIKE '%firefox/%'             THEN RETURN v_os || ' · Firefox'; END IF;
  IF v_ua ~ 'chrome/|chromium/'         THEN RETURN v_os || ' · Chrome';  END IF;
  IF v_ua LIKE '%safari/%'              THEN RETURN v_os || ' · Safari';  END IF;
  RETURN v_os || ' · 기타';
END;
$fn$;

COMMENT ON FUNCTION public._client_error_env_label(text) IS
  '[521] 브라우저 문자열 → 「OS · 브라우저」 이름(대략값). 순수 계산, 표를 읽지 않는다. '
  '이름 목록·판별 순서는 521 파일 머리말. 🔴 이름을 바꾸면 옛 이름과 새 이름이 따로 쌓인다. '
  '수집 함수(522)가 부른다 — 화면은 분류하지 않는다. 실행 권한은 정의자(postgres)만(두 방향 회수).';

-- 실행 권한 — 369·370 의 두 방향 회수. PUBLIC 부여와 anon/authenticated 개별 부여는 서로를 못 걷는다.
REVOKE ALL ON FUNCTION public._client_error_env_label(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._client_error_env_label(text) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL 편집기 — 1단계씩. 결과를 확인한 뒤 다음 단계로)
-- ============================================================
--
-- 1단계 — 표가 생겼고 행 단위 보안이 켜졌는지, 조회 정책만 있는지:
--   SELECT c.relname, c.relrowsecurity,
--          (SELECT array_agg(p.polname || ':' || p.polcmd) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
--     FROM pg_class c
--    WHERE c.oid = 'public.client_error_daily'::regclass;
--   → relrowsecurity = true / policies = {ced_select_admin:r}
--
-- 2단계 — 분류 함수 표본 (표본 15개. 기대 이름이 오른쪽 주석과 같아야 한다):
--   SELECT s.label AS 표본, public._client_error_env_label(s.ua) AS 결과
--     FROM (VALUES
--       ('아이폰 크롬(개발 실측)', 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/153.0.8010.24 Mobile/15E148 Safari/604.1'),               -- iOS · Chrome
--       ('아이폰 Safari 표식 없음(개발 실측)', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'),                                -- iOS · 앱 안 브라우저
--       ('아이폰 사파리', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),                           -- iOS · Safari
--       ('맥 크롬', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'),                                                  -- macOS · Chrome
--       ('윈도우 크롬', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'),                                                    -- Windows · Chrome
--       ('윈도우 엣지', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0'),                                     -- Windows · Edge
--       ('안드로이드 크롬', 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36'),                                          -- Android · Chrome
--       ('안드로이드 삼성', 'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36'),                      -- Android · Samsung
--       ('안드로이드 파이어폭스', 'Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 Firefox/131.0'),                                                                                      -- Android · Firefox
--       ('안드로이드 웹뷰', 'Mozilla/5.0 (Linux; Android 13; SM-A536N Build/TP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36'),            -- Android · 앱 안 브라우저
--       ('LINE 아이폰', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari Line/14.9.0'),                                  -- iOS · LINE
--       ('인스타그램 아이폰', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/22A3354 Instagram 350.0.0.10.100 (iPhone14,2; iOS 18_0)'), -- iOS · Instagram
--       ('메타 광고 수집 봇', 'meta-externalads/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)'),                                                                      -- 봇
--       ('구글봇(Chrome 표식 포함)', 'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'), -- 봇
--       ('빈 값', '')                                                                                                                                                                           -- 알 수 없음
--     ) AS s(label, ua);
--   (NULL 도 '알 수 없음': SELECT public._client_error_env_label(NULL);)
--
-- 3단계 — 실행 권한 두 방향 모두 회수됐는지 (맨 앞 '=X/' 가 없고 anon·authenticated 항목이 없어야 한다):
--   SELECT p.oid::regprocedure AS fn, p.proacl::text AS acl
--     FROM pg_proc p
--    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_client_error_env_label';
--   → acl 에 '=X/' 로 시작하는 항목 없음, anon=/authenticated= 없음 (postgres=X/postgres 등만)
--
-- ⚠️ 이 단계까지는 수집에 아무 영향이 없다 — 522 를 적용해야 표가 채워지기 시작한다.
-- ============================================================
