-- =============================================================================
-- 마이그레이션 332: 일별 방문자수 집계
-- 제목    : site_daily_visits 테이블 + record_site_visit() RPC
-- 의존    : 없음 (신규 인프라, 기존 테이블과 독립)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-08-18
-- 위험도  : 낮음 — 신규 테이블/RPC, 기존 행·정책·트리거 무변경
-- 멱등성  : CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--           DROP FUNCTION IF EXISTS(시그니처 명시) + CREATE FUNCTION,
--           DROP POLICY IF EXISTS + CREATE POLICY
--
-- 변경 요약:
--   [신규] public.site_daily_visits — (일본 표준시 날짜, 앱 구분) 단위 방문 집계
--   [신규] RPC record_site_visit(p_app, p_is_new_visitor) — anon+authenticated 호출
--
-- 확정된 설계 (사용자 결정 — 263_increment_campaign_view.sql 을 그대로 본뜸):
--   1. 우리 데이터베이스에 직접 집계 (Vercel 통계 미사용)
--   2. 브라우저 단위 하루 1회 = 방문자 1명 (판정은 클라이언트, 서버는 결과만 받음)
--   3. 인플루언서 사이트만 집계. 관리자·광고주 폼은 지금은 기록하지 않지만
--      나중에 추가할 수 있도록 앱 구분 칸(app)은 미리 둔다.
--   4. 봇 방어(자동화 브라우저 표시·화면 노출 시에만 호출)는 클라이언트 몫 —
--      이 마이그레이션 범위 밖.
--   5. 도입 이전 구간 백필 없음 — 화면은 이 표가 생긴 날짜부터만 그린다.
--
-- 개인정보 설계 — 저장하지 않는 것:
--   IP, 기기정보(User-Agent 등), 세션/사용자 식별자를 단 한 칸도 저장하지 않는다.
--   "새 방문자인가"는 브라우저(로컬 스토리지 등)가 판정해 불리언 하나로만 넘기고,
--   그 판정 근거(무엇으로 식별했는지)는 서버에 도달하지 않는다.
--   → 이 표 자체는 개인정보처리방침상 "개인정보"에 해당하지 않는 집계 수치만 가진다.
--
-- 날짜는 반드시 서버가 만든다 (클라이언트 신뢰 안 함):
--   클라이언트가 "오늘 날짜"를 함께 보내면, 그 값을 조작해 과거 날짜의 집계를
--   임의로 부풀릴 수 있다. 이 함수는 p_app·p_is_new_visitor 두 값만 인자로 받고,
--   집계 대상 날짜는 함수 내부에서 서버 시각을 KST(+09:00, 일본과 동일 오프셋)로
--   변환해 직접 계산한다.
--
-- 하루 상한(rate limit)을 넣지 않은 이유:
--   사용자는 "가벼운 방어"를 선택했고 상한은 선택하지 않았다. 넣지 않는 편이
--   이 결정에 부합한다고 판단해 넣지 않았다.
--   ⚠️ 한계: 이 표는 개인 식별자를 전혀 저장하지 않으므로, 서버 쪽에서는
--   "같은 브라우저가 반복 호출하는 도배"와 "정상적인 새 방문 다수"를 구분할
--   방법이 없다(구분하려면 식별자를 저장해야 하는데 그건 이 설계의 전제와 충돌).
--   도배가 실제로 관측되면 이후 마이그레이션에서 상한·쿨다운을 추가로 검토한다.
--
-- pg_advisory_xact_lock 을 쓰지 않은 이유:
--   이 함수의 쓰기는 (날짜, 앱) 유일 키 기준 UPSERT(INSERT ... ON CONFLICT DO UPDATE)
--   한 번뿐이다. UPSERT 는 PostgreSQL 이 행 잠금으로 이미 원자적으로 처리하므로
--   추가 잠금이 필요 없다. 여기에 advisory 잠금을 걸면 하루치 방문 트래픽 전체가
--   "한 번에 한 요청만" 순으로 직렬화되어, 방문이 몰리는 시간대에 그 자체가
--   병목·지연의 원인이 된다 — 조회수 집계(263)와 달리 이 표는 행 자체가
--   (날짜, 앱) 조합만큼만 존재해 경합이 잦으므로 특히 위험하다.
--
-- 보존 기간 자동 정리를 만들지 않은 이유:
--   하루에 (앱 개수)만큼의 행만 쌓이는 구조라(현재는 하루 1행) 저장 용량 문제가
--   사실상 없고, 자동 삭제를 두면 과거 방문 추이를 나중에 다시 볼 수 없게 된다.
--   influencer_flags(166)·admin_password_reset_requests(243) 같은 개인정보 보존기간
--   집행과는 성격이 다르다(이 표엔 애초에 개인정보가 없다) — 정리 배치를 두지 않는다.
--
-- 안전성 메모:
--   - 관리자·감사용 계정 제외는 263 과 동일 판단(운영자 확인 열람·시뮬레이션 계정은
--     방문 지표가 아님). 단, 이 함수는 anon(비로그인) 호출도 받으므로 auth.uid() 가
--     NULL 이면 두 제외 검사를 건너뛰고 정상 집계한다(263 과 동일 분기 구조).
--   - 앱 구분 값이 화이트리스트 밖이면 예외를 던지지 않고 조용히 종료한다.
--     방문 집계 실패가 화면 오류로 사용자에게 노출되면 안 되기 때문
--     (클라이언트 호출부는 이 RPC 를 fire-and-forget 으로 다뤄야 한다).
--
-- ⚠️ 검증 함정 (SQL 편집기로 못 잡는 부분):
--   관리자 계정 제외(admins 테이블) · 감사용 계정 제외(influencers.is_audit) 판정은
--   auth.uid() 값에 의존한다. Supabase 대시보드 SQL 편집기는 서비스 권한(service_role)
--   으로 실행되어 auth.uid() 가 NULL 인 채로 돈다 — 즉 "관리자 계정으로 로그인해
--   호출하면 집계에서 빠지는지"는 SQL 편집기로는 검증할 수 없고, 실제 로그인
--   세션(브라우저)으로만 검증 가능하다.
--
-- 롤백 방법:
--   DROP FUNCTION IF EXISTS public.record_site_visit(text, boolean);
--   DROP TABLE IF EXISTS public.site_daily_visits CASCADE;
-- =============================================================================

BEGIN;

-- ── 테이블 ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.site_daily_visits (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 집계 기준 날짜 (일본 표준시, +09:00). 서버가 now() 로 직접 계산해 채운다.
  visit_date      date        NOT NULL,

  -- 앱 구분. 현재는 influencer 만 실사용, 나머지는 향후 확장 대비 칸만 미리 둠.
  app             text        NOT NULL DEFAULT 'influencer'
                                CHECK (app IN ('influencer', 'admin', 'sales')),

  -- 방문자수 — 브라우저 단위 하루 1회(p_is_new_visitor=true)만 누적
  visitor_count   integer     NOT NULL DEFAULT 0,

  -- 열람 횟수(보조 지표) — 새 방문이든 재방문이든 호출마다 누적.
  -- 화면에는 지금 쓰지 않지만, 나중에 필요해질 때 다시 계산할 수 없으므로 저장만 해 둔다.
  page_view_count integer     NOT NULL DEFAULT 0,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT site_daily_visits_date_app_uniq UNIQUE (visit_date, app)
);

CREATE INDEX IF NOT EXISTS site_daily_visits_date_idx
  ON public.site_daily_visits (visit_date DESC);

COMMENT ON TABLE public.site_daily_visits IS
  '일별 방문자수 집계. 개인 식별 가능한 값(IP·기기정보·사용자 식별자)은 저장하지 않는다. 도입 이전 구간 백필 없음 — 이 표가 생긴 날짜부터만 유효.';
COMMENT ON COLUMN public.site_daily_visits.visit_date IS '집계 기준 날짜(KST, +09:00). 서버가 now() 로 계산 — 클라이언트가 보낸 날짜를 신뢰하지 않는다.';
COMMENT ON COLUMN public.site_daily_visits.visitor_count IS '브라우저 단위 하루 1회를 방문자 1명으로 카운트.';
COMMENT ON COLUMN public.site_daily_visits.page_view_count IS '보조 지표(열람 횟수) — 현재 화면 미사용, 저장만 함.';

-- ── 행 단위 보안 정책(RLS) ────────────────────────────────────────────────────

ALTER TABLE public.site_daily_visits ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만
DROP POLICY IF EXISTS sdv_select_admin ON public.site_daily_visits;
CREATE POLICY sdv_select_admin ON public.site_daily_visits
  FOR SELECT USING (public.is_admin());

-- INSERT/UPDATE 직접 정책 없음 → record_site_visit() RPC 경유만 허용
-- (client_error_logs, 마이그레이션 165 와 동일 형태)

-- ── RPC: record_site_visit ───────────────────────────────────────────────────
-- anon + authenticated 양쪽 호출 가능. 날짜 계산은 서버가 전담.

DROP FUNCTION IF EXISTS public.record_site_visit(text, boolean);

CREATE FUNCTION public.record_site_visit(p_app text, p_is_new_visitor boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_date  date;
BEGIN
  -- 앱 구분 화이트리스트 검사 — 밖이면 조용히 종료(오류를 던져 화면을 막지 않음)
  IF p_app IS NULL OR p_app NOT IN ('influencer', 'admin', 'sales') THEN
    RETURN;
  END IF;

  IF v_uid IS NOT NULL THEN
    -- 관리자 열람 제외 (운영자가 확인차 여는 것은 방문 지표가 아님, 263 과 동일 판단)
    IF EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = v_uid) THEN
      RETURN;
    END IF;
    -- 감사용 계정 제외 (운영팀 시뮬레이션 계정 — 179·181·263 과 동일 기준)
    IF EXISTS (
      SELECT 1 FROM public.influencers i
       WHERE i.id = v_uid AND i.is_audit = true
    ) THEN
      RETURN;
    END IF;
  END IF;

  -- 집계 기준 날짜는 서버가 계산 (클라이언트가 보낸 날짜는 받지 않음 — 조작 방지)
  v_date := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- 원자적 UPSERT — (visit_date, app) 유일 제약으로 동시 요청도 안전
  INSERT INTO public.site_daily_visits (visit_date, app, visitor_count, page_view_count)
  VALUES (
    v_date,
    p_app,
    CASE WHEN p_is_new_visitor THEN 1 ELSE 0 END,
    1
  )
  ON CONFLICT (visit_date, app) DO UPDATE
     SET visitor_count   = public.site_daily_visits.visitor_count
                            + CASE WHEN p_is_new_visitor THEN 1 ELSE 0 END,
         page_view_count = public.site_daily_visits.page_view_count + 1,
         updated_at      = now();
END;
$$;

COMMENT ON FUNCTION public.record_site_visit(text, boolean) IS
  '일별 방문자수·열람 횟수 기록. 비로그인·인플루언서가 호출(브라우저가 새 방문 여부를 판정해 넘김). 관리자·감사용 계정 열람은 집계 제외. 앱 구분값이 화이트리스트 밖이면 조용히 종료.';

REVOKE ALL ON FUNCTION public.record_site_visit(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_site_visit(text, boolean) TO anon, authenticated;

-- updated_at 자동 갱신은 UPSERT 문 안에서 직접 세팅하므로 별도 트리거 불필요.

-- PostgREST schema cache 즉시 재로드 (신규 테이블·함수 노출)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- =============================================================================
-- 적용 후 확인용 조회문 (SQL 편집기에서 1단계씩 실행 — 여러 개를 한 번에 쏟지 말 것)
-- =============================================================================

-- [1] 표·정책이 정상 생성됐는지
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema = 'public' AND table_name = 'site_daily_visits';
--
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname = 'public' AND tablename = 'site_daily_visits';

-- [2] 함수가 정상 생성됐는지 + 실행 권한 확인
-- SELECT proname, prosecdef FROM pg_proc WHERE proname = 'record_site_visit';
--
-- SELECT grantee, privilege_type FROM information_schema.role_routine_grants
--  WHERE routine_name = 'record_site_visit';

-- [3] 함수 스모크 호출 (비로그인 상태로 실행돼야 정상 — SQL 편집기는 서비스 권한이라
--     auth.uid() 가 NULL 로 돌아 "비로그인 방문"과 동일하게 동작한다. 이건 검증 가능)
-- SELECT public.record_site_visit('influencer', true);
-- SELECT * FROM public.site_daily_visits WHERE visit_date = (now() AT TIME ZONE 'Asia/Tokyo')::date;
-- -- visitor_count=1, page_view_count=1 이어야 정상
--
-- SELECT public.record_site_visit('influencer', false);
-- SELECT * FROM public.site_daily_visits WHERE visit_date = (now() AT TIME ZONE 'Asia/Tokyo')::date;
-- -- visitor_count=1(불변), page_view_count=2 이어야 정상
--
-- SELECT public.record_site_visit('not_a_real_app', true);
-- -- 오류 없이 조용히 아무 일도 없어야 정상(화이트리스트 밖은 무시)

-- ⚠️ [4] 관리자·감사용 계정 제외 판정은 이 조회문들로 검증할 수 없다.
--     SQL 편집기는 서비스 권한(service_role)으로 실행돼 auth.uid() 가 항상 NULL 이라,
--     "관리자로 로그인한 브라우저에서 호출하면 집계가 안 늘어나는지"는
--     실제 로그인 세션(브라우저)에서만 확인 가능하다.

-- 테스트로 만든 행 정리 (검증 끝난 뒤 실행)
-- DELETE FROM public.site_daily_visits WHERE visit_date = (now() AT TIME ZONE 'Asia/Tokyo')::date;
-- =============================================================================
