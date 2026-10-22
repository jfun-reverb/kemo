-- ============================================================
-- 581_brand_restriction_tables.sql
-- 브랜드 계정 이용 제한 · 결과물 열람 정지 — 제한 1: 표 셋 + 판정 내부 함수 셋 (사양서 4-1 · 5-1 · 5-7 · 작업표 기본값 4)
-- 사양서: docs/specs/2026-10-21-brand-account-restriction.md · 작업표 docs/specs/2026-10-21-brand-account-restriction-breakdown.md 「제한 1」
--
-- 왜: 관리자가 브랜드 계정 하나의 이용을 제한하고(계정 전체 — F1), 브랜드 하나의 결과물 열람을 정지한다(F2).
--   그 상태를 담을 표와 「지금 걸려 있나」 판정을 한 곳에 둔다. 🔴 이 파일만으로는 **아무 동작도 안 바뀐다** — 아무 함수도 아직 부르지 않는다
--   (제한 2·3 이 관문에 판정을 넣고, 제한 4 가 쓰기·조회 함수를 만든다).
--
-- 만드는 것
--   1) brand_account_restrictions — 한 줄 = 한 번의 제한(계정 단위)
--      · until_date NULL = 「해제할 때까지」, 날짜 = 그 날(일본 날짜) 당일까지 막힘(A2)
--      · lifted_* · close_reason 은 **관리자가 닫았을 때만**(손으로 해제 lifted / 기간 바꾸기 period_changed — A1). 기간이 끝난 줄은 비운 채 둔다(A3)
--      · prev_id — 기간 바꾸기로 이어진 앞 줄
--      · 「지금 걸려 있는 줄은 계정마다 하나」(A4)는 날짜 비교가 들어가 색인으로 못 막는다 → 제한 4 의 걸기 함수가 같은 계정 잠금 + 판정으로 막는다
--   2) brand_results_suspensions — 한 줄 = 한 번의 정지(브랜드 단위, 기간 없음). 브랜드마다 풀지 않은 줄 하나(부분 고유 색인)
--   3) brand_sanction_mail_claims — 메일 선점(「알림 1건 = 메일 1통」). 같은 원본 줄 · 같은 종류에 한 줄
--   4) _brand_active_restriction_id(p_auth_id uuid) → uuid | NULL — 🔴 「지금 제한 중」 판정식은 **여기 한 곳**(A3). 인자는 계정 번호(남의 계정도 판정 —
--      큐텐 관문·메일 받는 사람·겹침 확인). 줄 번호가 필요한 자리(겹침 확인·상태 조회·해제)가 있어 번호를 돌려준다
--      + _brand_account_restricted(p_auth_id uuid) → boolean — 위 함수를 감싼 참/거짓(작업표 계약 이름). 식을 복사하지 않는다
--   5) _brand_active_suspension(p_brand_id uuid) → jsonb {id, include_shipping} | NULL — 🔴 정지 판정 한 곳
--
-- 외래 키를 안 거는 칸: auth_id·brand_id·created_by·lifted_by — 계정·브랜드·관리자가 지워져도 제재 이력은 남긴다(제공 기록 552 와 같은 방식).
--   보관 기간·탈퇴 뒤 처리는 작업표 S3(`/약관확인`)가 정한다 — 정리가 필요하면 후속 조각.
--   ⚠️ 그래서 브랜드 병합(merge_brands)·삭제(delete_brand)는 정지 줄을 옮기거나 지우지 않는다 — 흡수된 브랜드의 정지 줄은 그 브랜드 번호에 남는다
--      (흡수된 쪽은 사라져 아무도 그 번호로 판정받지 않는다). 🔴 **정지 중인 브랜드가 흡수되면 정지가 옮겨 가지 않아 사실상 풀린다** —
--      병합 거부 또는 정지 이동은 후속 결정(기획 세션에 알림 · 이 파일은 그대로).
--
-- 표 권한: 세 표 모두 행 단위 보안 켬 · 정책 없음 · anon·authenticated·service_role 표 권한 전부 회수(552 [J7] + 서비스 키) — 읽기·쓰기는 정의자 권한 함수로만, 브랜드 계정은 못 읽는다.
-- 판정 함수 실행 권한: postgres 만(호출자 검사 없는 함수 — PUBLIC·anon·authenticated·service_role 모두 회수). 부르는 쪽은 SECURITY DEFINER 함수라 소유자 권한으로 돈다.
--
-- 편집기 경고: 안 뜸(DROP 없음).
-- 롤백(제한 2~4 를 먼저 되돌린다 — 판정 함수를 부르는 자리가 생긴 뒤에는 그쪽부터):
--   DROP FUNCTION public._brand_active_suspension(uuid), public._brand_account_restricted(uuid), public._brand_active_restriction_id(uuid);
--   DROP TABLE public.brand_sanction_mail_claims, public.brand_results_suspensions, public.brand_account_restrictions;  -- 줄 0건일 때만(제재 이력)
-- ============================================================
BEGIN;

-- ── 1. 계정 이용 제한 표 ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_account_restrictions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id         uuid        NOT NULL,                     -- 브랜드 계정(auth.users.id) — 외래 키 없음(머리말)
  reason_code     text        NOT NULL CHECK (reason_code IN ('terms_8', 'account_sharing', 'other')),
  reason_note     text        NOT NULL CHECK (btrim(reason_note) <> ''),   -- 메일에 그대로 들어간다(F4)
  until_date      date,                                     -- NULL = 해제할 때까지 · 날짜 = 그 날(일본 날짜) 당일까지
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  lifted_by       uuid,
  lifted_by_name  text,
  lifted_at       timestamptz,
  close_reason    text        CHECK (close_reason IN ('lifted', 'period_changed')),
  prev_id         uuid        REFERENCES public.brand_account_restrictions(id) ON DELETE SET NULL,
  -- 닫힌 시각과 닫힌 까닭은 함께 있거나 함께 없다(기간이 끝난 줄은 둘 다 비어 있다)
  CONSTRAINT brand_account_restrictions_close_pair CHECK ((lifted_at IS NULL) = (close_reason IS NULL))
);

COMMENT ON TABLE public.brand_account_restrictions IS
  '[581] 브랜드 계정 이용 제한 이력(한 줄 = 한 번). 지금 제한 중 판정은 _brand_account_restricted 한 곳. lifted_*·close_reason 은 관리자가 닫을 때만(해제 lifted / 기간 바꾸기 period_changed — 새 줄 prev_id 로 이어짐). 기간이 끝난 줄은 비운 채 둔다. 외래 키 없음(계정이 지워져도 남김). 읽기·쓰기는 정의자 권한 함수만.';

CREATE INDEX IF NOT EXISTS idx_brand_account_restrictions_auth
  ON public.brand_account_restrictions (auth_id, created_at DESC);

-- ── 2. 결과물 열람 정지 표 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_results_suspensions (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id         uuid        NOT NULL,                    -- 외래 키 없음(머리말)
  reason_code      text        NOT NULL CHECK (reason_code IN ('terms_8', 'other')),
  reason_note      text        NOT NULL CHECK (btrim(reason_note) <> ''),
  include_shipping boolean     NOT NULL DEFAULT false,      -- F2 — 배송 리스트도 막는가(기본 꺼짐)
  created_by       uuid,
  created_by_name  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  lifted_by        uuid,
  lifted_by_name   text,
  lifted_at        timestamptz
);

COMMENT ON TABLE public.brand_results_suspensions IS
  '[581] 브랜드 결과물 열람 정지 이력(한 줄 = 한 번, 기간 없음). 지금 정지 중 = lifted_at 이 빈 줄 — 판정은 _brand_active_suspension 한 곳. 브랜드마다 풀지 않은 줄 하나(부분 고유 색인). 외래 키 없음. 읽기·쓰기는 정의자 권한 함수만.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_brand_results_suspensions_active
  ON public.brand_results_suspensions (brand_id) WHERE lifted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_brand_results_suspensions_brand
  ON public.brand_results_suspensions (brand_id, created_at DESC);

-- ── 3. 메일 선점 표 ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_sanction_mail_claims (
  ref_kind   text        NOT NULL CHECK (ref_kind IN ('restriction', 'suspension')),
  ref_id     uuid        NOT NULL,                          -- 위 두 표의 줄 번호(종류에 따라)
  mail_kind  text        NOT NULL CHECK (mail_kind IN ('account_restrict', 'account_period', 'account_lift', 'results_suspend', 'results_lift')),
  claimed_by uuid,                                          -- 선점을 부른 관리자
  claimed_at timestamptz NOT NULL DEFAULT now(),
  sent_at    timestamptz,
  ok         boolean,
  failed     jsonb       CHECK (failed IS NULL OR jsonb_typeof(failed) = 'array'),
  PRIMARY KEY (ref_kind, ref_id, mail_kind),
  -- 계정 메일 셋은 제한 줄, 브랜드 메일 둘은 정지 줄에만
  CONSTRAINT brand_sanction_mail_claims_kind_pair CHECK (
    (ref_kind = 'restriction' AND mail_kind IN ('account_restrict', 'account_period', 'account_lift'))
    OR (ref_kind = 'suspension' AND mail_kind IN ('results_suspend', 'results_lift'))
  )
);

COMMENT ON TABLE public.brand_sanction_mail_claims IS
  '[581] 이용 제한·열람 정지 알림 메일 선점(알림 1건 = 메일 1통). 같은 원본 줄·같은 종류에 한 줄 — 선점 줄 삽입이 곧 발송 권리. 쓰기는 제한 4 의 서비스 함수(선점·결과 기록)만.';

-- ── 4. 행 단위 보안 · 표 권한 — 정책 없음, 로그인 역할 표 권한 회수 ──────────
ALTER TABLE public.brand_account_restrictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_results_suspensions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_sanction_mail_claims ENABLE ROW LEVEL SECURITY;

-- 서비스 키도 회수한다 — 서버 함수는 제한 4 의 정의자 권한 함수(service_*)를 거쳐서만 읽고 쓴다(검토 반영 · 552 보다 한 단계 좁다)
REVOKE ALL ON public.brand_account_restrictions FROM anon, authenticated, service_role;
REVOKE ALL ON public.brand_results_suspensions  FROM anon, authenticated, service_role;
REVOKE ALL ON public.brand_sanction_mail_claims FROM anon, authenticated, service_role;

-- ── 5. 판정 내부 함수 셋 ────────────────────────────────────────
-- 🔴 「지금 제한 중」 판정식은 여기 한 곳(A3). 일본 날짜 오늘이 끝나는 날 이하면 아직 제한(당일 포함 — A2).
--    줄 번호가 필요한 자리(겹침 확인·상태 조회·해제·기간 바꾸기)는 이 함수를, 참/거짓만 필요한 자리는 아래 _brand_account_restricted 를 부른다.
CREATE OR REPLACE FUNCTION public._brand_active_restriction_id(p_auth_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.id
    FROM public.brand_account_restrictions r
   WHERE r.auth_id = p_auth_id
     AND r.lifted_at IS NULL
     AND (r.until_date IS NULL OR r.until_date >= (now() AT TIME ZONE 'Asia/Tokyo')::date)
   ORDER BY r.created_at DESC
   LIMIT 1;
$$;

COMMENT ON FUNCTION public._brand_active_restriction_id(uuid) IS
  '[581] 브랜드 계정의 지금 걸려 있는 이용 제한 줄 번호(없으면 NULL) — 판정식 한 곳(A3). 풀지 않았고 (끝나는 날 없음 또는 끝나는 날 ≥ 일본 날짜 오늘). 실행 권한 postgres 만(호출자 검사 없음).';

CREATE OR REPLACE FUNCTION public._brand_account_restricted(p_auth_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public._brand_active_restriction_id(p_auth_id) IS NOT NULL;
$$;

COMMENT ON FUNCTION public._brand_account_restricted(uuid) IS
  '[581] 브랜드 계정이 지금 이용 제한 중인가(참/거짓) — 판정은 _brand_active_restriction_id 에 있다. 인자 NULL 이면 거짓. 실행 권한 postgres 만(호출자 검사 없음).';

-- 🔴 정지 판정 한 곳. 풀지 않은 줄이 있으면 {id, include_shipping}, 없으면 NULL.
CREATE OR REPLACE FUNCTION public._brand_active_suspension(p_brand_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object('id', s.id, 'include_shipping', s.include_shipping)
    FROM public.brand_results_suspensions s
   WHERE s.brand_id = p_brand_id
     AND s.lifted_at IS NULL
   LIMIT 1;
$$;

COMMENT ON FUNCTION public._brand_active_suspension(uuid) IS
  '[581] 브랜드 결과물 열람 정지 중이면 {id, include_shipping}, 아니면 NULL — 판정 한 곳. 실행 권한 postgres 만(호출자 검사 없음).';

-- 실행 권한: postgres 먼저 부여 → PUBLIC 회수 → 로그인 역할·서비스 키 회수(두 방향 — CLAUDE.md 「함수 실행 권한」)
GRANT  EXECUTE ON FUNCTION public._brand_active_restriction_id(uuid) TO postgres;
GRANT  EXECUTE ON FUNCTION public._brand_account_restricted(uuid) TO postgres;
GRANT  EXECUTE ON FUNCTION public._brand_active_suspension(uuid)  TO postgres;
REVOKE EXECUTE ON FUNCTION public._brand_active_restriction_id(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_account_restricted(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_active_suspension(uuid)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_active_restriction_id(uuid) FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_account_restricted(uuid) FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_active_suspension(uuid)  FROM anon, authenticated, service_role;

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '581', '581_brand_restriction_tables.sql');
COMMIT;
