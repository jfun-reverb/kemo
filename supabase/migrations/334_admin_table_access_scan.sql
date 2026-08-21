-- ============================================================
-- 334_admin_table_access_scan.sql
-- 「조용히 죽는 관리자 화면」 감지 장치 — 작업 1 (①표)
-- 사양: docs/specs/2026-08-18-blocked-admin-screen-detection.md §3-3·§3-5
-- 작업표: docs/specs/2026-08-18-blocked-admin-screen-detection-breakdown.md 작업 1
--
-- ▶ 이 표가 왜 필요한가
--   1겹(데이터베이스 정책 목록만 보는 감지 함수, 마이그레이션 335)은 「관리자
--   통로가 없는 표」까지만 알 수 있다. 그 표를 **코드가 아직 읽고 있는지**는
--   데이터베이스가 스스로 모른다(사양서 §1-5 ㄴ·ㄷ). 그래서 2겹㉯(적용 후
--   코드 점검 스크립트, 작업 2)가 `dev/` 전체를 세 형태(직접 호출·인자로
--   넘기는 헬퍼·조회문 안쪽 임베드 조인)로 훑어 그 결과를 이 표에 적는다.
--   335 는 이 표를 읽어 등급(A/B/미확인)을 가른다.
--
-- ▶ 「한 번도 점검 안 함」과 「점검했는데 0곳」을 반드시 구분한다
--   행이 없으면 전자(미확인), 행이 있고 reading_sites=0 이면 후자(통과).
--   이 구분이 없으면 선례(마이그레이션 277 채널 어긋남 감지)가 세운 원칙 ④
--   (조회 실패와 0건 구분)를 이 장치가 스스로 어기게 된다.
--
-- ▶ 쓰기 정책을 두지 않는 이유
--   이 표를 쓰는 주체는 사람 관리자 세션이 아니라 **검사 스크립트**(작업 2,
--   `scripts/` 아래)다. 스크립트는 서비스 키로 돈다 — 서비스 키는 행 단위
--   보안 정책(RLS) 자체를 우회하므로 INSERT/UPDATE 정책이 필요 없다. 이
--   저장소의 기존 관행(`client_error_logs`·`admin_daily_digest_runs` 등,
--   "INSERT는 service_role만 우회")을 그대로 따른다.
--
-- ▶ 권한 — SELECT 는 `is_admin()`(관리자 전원). 사양서 §5 ⑤ 확정 근거:
--   이 감지 결과를 보여줄 화면이 오류 로그 화면(#errors, 관리자 전원 열람)
--   이라 기준을 일치시켰다.
--
-- ▶ 롤백
--   DROP TABLE IF EXISTS public.admin_table_access_scan;
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.admin_table_access_scan (
  table_name     text        PRIMARY KEY,

  -- 이 표를 대상으로 2겹㉯ 검사 스크립트가 마지막으로 돈 시각.
  -- ⚠️ 행 자체가 없으면 "한 번도 점검 안 함"(미확인) — scanned_at 은 그 상태를
  --    NULL 로 표현하지 않는다(행이 없다는 사실 자체가 미확인의 신호).
  scanned_at     timestamptz NOT NULL,

  -- 코드(dev/ 전체)에서 이 표를 아직 읽는 자리 수. 세 형태
  -- (①from('이름') ②인자로 받는 헬퍼 ③조회문 안쪽 임베드 조인)를 합산한 값.
  reading_sites  integer     NOT NULL DEFAULT 0
                               CHECK (reading_sites >= 0),

  -- 자리 목록 — [{ "file": "dev/js/admin-deliverables.js", "line": 123,
  --               "form": "embed" }, ...] 형태. 화면 모달이 "아직 읽는 자리"를
  -- 파일:줄로 보여줄 때 쓴다(사양서 §3-3 모달 내용).
  sites          jsonb       NOT NULL DEFAULT '[]'::jsonb,

  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.admin_table_access_scan IS
  '2겹㉯(적용 후 코드 점검 스크립트)가 표별로 "코드가 아직 읽는 자리 수"를 기록. '
  '행이 없으면 미확인(한 번도 점검 안 함), 있고 reading_sites=0 이면 통과(점검했고 '
  '0곳). 쓰기는 검사 스크립트가 서비스 키로 한다 — 쓰기 정책 없음. '
  '마이그레이션 335(detect_blocked_admin_tables)가 이 표를 읽어 등급을 가른다.';

COMMENT ON COLUMN public.admin_table_access_scan.table_name IS
  'public 스키마의 표 이름(고유). pg_class.relname 과 동일한 값.';
COMMENT ON COLUMN public.admin_table_access_scan.scanned_at IS
  '검사 스크립트가 이 표를 마지막으로 훑은 시각. 행 존재 자체가 "점검한 적 있음"의 증거.';
COMMENT ON COLUMN public.admin_table_access_scan.reading_sites IS
  '코드(dev/ 전체)에서 이 표를 아직 읽는 자리 수(세 형태 합산). 0이면 통과 대상.';
COMMENT ON COLUMN public.admin_table_access_scan.sites IS
  '읽는 자리 목록 [{file, line, form}, ...]. 화면 모달의 "아직 읽는 자리" 표시에 사용.';

-- ── 행 단위 보안 정책(RLS) ────────────────────────────────────────────────────

ALTER TABLE public.admin_table_access_scan ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS atas_select_admin ON public.admin_table_access_scan;
CREATE POLICY atas_select_admin ON public.admin_table_access_scan
  FOR SELECT USING (public.is_admin());

-- INSERT/UPDATE/DELETE 직접 정책 없음 → 검사 스크립트가 서비스 키로만 쓴다.
-- (client_error_logs 마이그레이션 165, admin_daily_digest_runs 등과 동일 패턴)

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL 편집기 — 1단계씩 순서대로. 결과 확인 후 다음 단계)
-- ⚠️ 아래 [3]은 서비스 키(SQL 편집기) 세션에서는 항상 통과한다 — 서비스 키는
--    RLS 자체를 우회하기 때문이다. "관리자 아닌 세션에서 막히는지"는 이
--    표만으로는 검증할 수 없고, 마이그레이션 335 의 함수 검증에서 실제
--    로그인 세션으로 확인한다.
-- ============================================================
--
-- [1] 표·정책이 정상 생성됐는지
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema = 'public' AND table_name = 'admin_table_access_scan';
--
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname = 'public' AND tablename = 'admin_table_access_scan';
--  → atas_select_admin (SELECT) 1개만 있어야 한다 (INSERT/UPDATE/DELETE 정책 없음)
--
-- [2] 행 단위 보안이 켜져 있는지
-- SELECT relrowsecurity FROM pg_class WHERE relname = 'admin_table_access_scan';  -- t
--
-- [3] 서비스 키로는 쓰기가 된다(정책이 없어 RLS 로 막히지 않음 — 정상,
--     검사 스크립트가 이 경로로 쓴다). 테스트 후 반드시 지울 것:
-- INSERT INTO public.admin_table_access_scan (table_name, scanned_at, reading_sites, sites)
--   VALUES ('__migration_334_smoke_test__', now(), 0, '[]'::jsonb);
-- SELECT * FROM public.admin_table_access_scan WHERE table_name = '__migration_334_smoke_test__';
-- DELETE FROM public.admin_table_access_scan WHERE table_name = '__migration_334_smoke_test__';
-- ============================================================
