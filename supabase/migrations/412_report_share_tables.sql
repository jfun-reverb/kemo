-- ============================================================
-- 412. 리포트 공유 — 칸 · 열람 표 · 시도 기록 · 기록 표
-- ============================================================
-- 작업표: 「작업 20」 · 사양서 「공유 링크 잠금」·「결정 변경 — 공유 화면의 열은 관리자가 고른다」
--
-- 🔴 네 표·칸 모두 **쓰기 정책이 없다** — 413 의 함수만 쓴다.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- ① 리포트 본체의 공유 칸
-- ------------------------------------------------------------
ALTER TABLE public.campaign_reports
  ADD COLUMN IF NOT EXISTS share_token            uuid UNIQUE,            -- 링크에 담기는 값. 켤 때 처음 만들고 유지
  ADD COLUMN IF NOT EXISTS share_enabled          boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS share_expires_at       timestamptz,            -- NULL = 무기한. 기본은 켤 때 +90일(확정 결정 19)
  ADD COLUMN IF NOT EXISTS share_password_cipher  bytea,                  -- 411 로 암호화. 🔴 조회 정책으로 열지 않는다(413 reveal 만)
  ADD COLUMN IF NOT EXISTS share_last_viewed_at   timestamptz,
  ADD COLUMN IF NOT EXISTS share_columns          jsonb;                  -- 공유 화면에 내보낼 열 목록(2026-09-04 결정). NULL = 기본(값 없는 열 제외)

COMMENT ON COLUMN public.campaign_reports.share_password_cipher IS
  '[412] 공유 비밀번호 암호문(411 pgp_sym). 원문은 reveal_report_share_password 로만 본다. 표를 직접 읽어도 암호문뿐이다.';
COMMENT ON COLUMN public.campaign_reports.share_columns IS
  '[412] 공유 화면 열 목록(열쇠말 배열). NULL 이면 「값이 하나도 없는 열은 뺀다」 기본. 계정 ID·영수증 주소는 어떤 값이어도 서버가 안 보낸다.';

-- ------------------------------------------------------------
-- ② 열람 표 — 비밀번호를 맞힌 뒤 발급. 🔴 유효기간 필수(없으면 비밀번호를 바꿔도 계속 열린다)
--    표에는 해시만 둔다 — 원문 표는 브라우저가 들고 있고, 표가 새도 그것으로는 못 연다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_report_view_tickets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id   uuid NOT NULL REFERENCES public.campaign_reports(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,
  issued_at   timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS campaign_report_view_tickets_report_idx ON public.campaign_report_view_tickets (report_id);

-- ------------------------------------------------------------
-- ③ 시도 기록 — 🔴 틀린 횟수를 서버에 둔다(화면에서 세면 새로고침 한 번에 초기화)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_report_pw_attempts (
  id            bigserial PRIMARY KEY,
  report_id     uuid NOT NULL REFERENCES public.campaign_reports(id) ON DELETE CASCADE,
  attempted_at  timestamptz NOT NULL DEFAULT now(),
  succeeded     boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS campaign_report_pw_attempts_report_time_idx ON public.campaign_report_pw_attempts (report_id, attempted_at DESC);

-- ------------------------------------------------------------
-- ④ 기록 표 — 누가 언제 열었나·봤나·켰나·껐나(등급으로 막지 않는 대신 흔적으로 본다)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_report_share_events (
  id          bigserial PRIMARY KEY,
  report_id   uuid NOT NULL REFERENCES public.campaign_reports(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('view','pw_reveal','link_on','link_off','pw_reset')),
  actor       uuid,                 -- 관리자 행위는 auth.uid(), 브랜드 열람(view)은 NULL
  actor_name  text,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS campaign_report_share_events_report_idx ON public.campaign_report_share_events (report_id, at DESC);

-- ------------------------------------------------------------
-- ⑤ 행 단위 보안 정책 — 셋 다 켜고, 기록 표만 관리자 읽기. 쓰기 정책은 없다.
--    열람 표·시도 기록은 관리자도 직접 못 읽는다(볼 이유가 없고, 해시라도 밖에 안 낸다).
-- ------------------------------------------------------------
ALTER TABLE public.campaign_report_view_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_report_pw_attempts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_report_share_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_report_share_events_select ON public.campaign_report_share_events;
CREATE POLICY campaign_report_share_events_select ON public.campaign_report_share_events
  FOR SELECT TO authenticated USING (public.has_permission('menu.reports', 'read'));

-- 🔴 campaign_reports 의 조회 정책은 402 그대로(관리자 읽기). share_password_cipher 도 그 정책으로
--    읽히지만 **암호문**이다 — 열쇠는 금고에, 복호는 413 reveal 함수만.

COMMIT;
NOTIFY pgrst, 'reload schema';

/* 검증
SELECT column_name FROM information_schema.columns WHERE table_name='campaign_reports' AND column_name LIKE 'share_%';   -- 6
SELECT tablename, rowsecurity FROM pg_tables WHERE tablename LIKE 'campaign_report_%';                                   -- 전부 true
SELECT tablename, cmd FROM pg_policies WHERE tablename IN ('campaign_report_view_tickets','campaign_report_pw_attempts','campaign_report_share_events');  -- events SELECT 1개뿐
*/
