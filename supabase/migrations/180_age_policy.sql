-- ============================================================
-- 180_age_policy.sql
-- (당초 179로 작성했으나 동시 진행 세션이 179_audit_influencer_account 선점 → 180 재채번)
-- 2026-06-15
--
-- 목적:
--   연령 정책 (만 18세 이상) + 성별 수집 — DB/서버 판정 레이어.
--   PR 1 — 클라이언트 UI (가입폼·응모모달·마이페이지·관리자) 는 PR 2~4에서.
--
-- 확정 요구사항 (사양서 docs/specs/2026-05-27-age-minor-policy.md §0-1):
--   ① influencers 에 birthdate date NULL, gender text NULL 컬럼 추가
--   ② 서버 만 나이 헬퍼 함수 (KST/JST 기준)
--   ③ 생년월일 수정 잠금: 본인은 최초 입력(NULL→값) 1회만, 이후 값 변경 불가.
--      관리자(is_admin())는 항상 변경 가능.
--   ④ 응모 차단 (18세 미만 OR birthdate 없음): 시행일 게이트 포함, 기본 비활성.
--      시행일 미정이므로 이 SQL 단계에서는 age_policy_effective_date = NULL.
--      PR 5 (약관·통지·시행일 확정) 단계에서 날짜를 채워 차단을 활성화.
--
-- 시행일 게이트 설계:
--   age_policy_settings 테이블 1행에 effective_date date NULL 을 보관.
--   차단 트리거(check_age_policy)가 매 INSERT 전 이 값을 조회해
--   "현재 날짜(KST) >= effective_date" 일 때만 차단 실행.
--   NULL 이면 무조건 통과(비활성 상태).
--   시행일 확정 = 단순 UPDATE 1행으로 족함.
--
-- 응모 INSERT 경로 확인 (2026-06-15):
--   insertApplication() → db.from('applications').insert(app)
--   → 행 단위 보안 정책(RLS) "applications_insert_own" WITH CHECK(auth.uid()=user_id) 경유.
--   RPC 없이 직접 INSERT. 따라서 차단은 BEFORE INSERT 트리거로 구현.
--   (monitor slots 차단(048)과 동일 패턴)
--
-- 기존 행 단위 보안 정책 영향:
--   influencers: "influencers_update_allow" — USING/WITH CHECK 모두
--     (is_admin() OR auth.uid()=id). 컬럼 단위 제어가 없으므로
--     본인이 birthdate 를 초기값 NULL→값 변경 후 재변경도 RLS 상 통과.
--     → 트리거로 추가 보호 (③).
--
-- 변경 요약:
--   [A] influencers 컬럼 2종 추가
--   [B] age_policy_settings 단일행 설정 테이블
--   [C] calc_age_kst(birthdate date) — 만 나이 헬퍼 (KST=JST 기준)
--   [D] check_age_policy() — 응모 차단 트리거 함수 (시행일 게이트 포함)
--   [E] trg_age_policy BEFORE INSERT ON applications
--   [F] lock_influencer_birthdate() — 생년월일 수정 잠금 트리거 함수
--   [G] trg_lock_influencer_birthdate BEFORE UPDATE ON influencers
--
-- 행 단위 보안 정책:
--   birthdate, gender: 기존 influencers 정책 자동 적용 (본인 SELECT/UPDATE, 관리자 SELECT).
--   age_policy_settings: SELECT is_admin(), UPDATE is_super_admin() 만.
--
-- 운영 데이터 영향:
--   - influencers 컬럼 추가: NULL 기본값. 기존 1,400행 무변경.
--   - age_policy_settings: 1행 INSERT (effective_date = NULL → 차단 비활성).
--   - applications 트리거: BEFORE INSERT만. 기존 행에 영향 없음.
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_age_policy ON public.applications;
--   DROP FUNCTION IF EXISTS public.check_age_policy();
--   DROP TRIGGER IF EXISTS trg_lock_influencer_birthdate ON public.influencers;
--   DROP FUNCTION IF EXISTS public.lock_influencer_birthdate();
--   DROP FUNCTION IF EXISTS public.calc_age_kst(date);
--   DROP TABLE IF EXISTS public.age_policy_settings;
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS gender;
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS birthdate;
-- ============================================================

BEGIN;

-- ============================================================
-- [A] influencers 컬럼 2종 추가
-- ============================================================

ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS birthdate date NULL;

COMMENT ON COLUMN public.influencers.birthdate IS
  '생년월일. 만 18세 판정 기준. 최초 입력(NULL→값) 후 본인 수정 불가(트리거 180-G).';

ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS gender text NULL;

-- gender CHECK 제약: 기존 마이그레이션 패턴(DROP IF EXISTS → ADD)으로 멱등성 보장
ALTER TABLE public.influencers
  DROP CONSTRAINT IF EXISTS influencers_gender_check;
ALTER TABLE public.influencers
  ADD CONSTRAINT influencers_gender_check
    CHECK (gender IN ('male', 'female', 'other', 'undisclosed'));

COMMENT ON COLUMN public.influencers.gender IS
  '성별. male/female/other/undisclosed 4종. UI 라벨 日本語: 男性/女性/その他/回答しない.';

-- ============================================================
-- [B] age_policy_settings — 시행일 단일행 설정 테이블
--
-- 설계 비교:
--   A안) 함수 내 상수(CONSTANT date := '2026-09-01') — 변경마다 함수 재배포 필요.
--   B안) 이 테이블 1행 (채택) — UPDATE 1줄로 시행일 변경, PR 5에서 날짜 채움.
--   C안) lookup_values 기존 테이블 재사용 — kind/code 패턴이 맞지 않아 가독성 저하.
--   → B안 채택: 변경 이력(updated_at, updated_by) + 낮은 복잡도.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.age_policy_settings (
  id                 integer         PRIMARY KEY DEFAULT 1
                                     CONSTRAINT age_policy_settings_singleton
                                       CHECK (id = 1),  -- 항상 1행만
  effective_date     date            NULL,               -- NULL = 차단 비활성
  description        text            NULL,
  updated_at         timestamptz     NOT NULL DEFAULT now(),
  updated_by         uuid            NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.age_policy_settings IS
  '연령 정책 시행일 설정. 항상 1행. effective_date=NULL 이면 차단 비활성.';
COMMENT ON COLUMN public.age_policy_settings.effective_date IS
  '연령 정책 시행일(KST). 이 날짜 이후 응모 시 birthdate 없음 / 18세 미만이면 차단.
   NULL = 시행 전(차단 비활성). PR 5에서 확정 시행일로 UPDATE.';

-- 초기 1행 INSERT (effective_date = NULL → 차단 비활성)
INSERT INTO public.age_policy_settings (id, effective_date, description)
VALUES (1, NULL, '초기값 — 시행일 미정. PR 5(약관 통지 완료 후)에서 날짜를 채울 것.')
ON CONFLICT (id) DO NOTHING;

-- 행 단위 보안 정책
ALTER TABLE public.age_policy_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "age_policy_settings_select" ON public.age_policy_settings;
CREATE POLICY "age_policy_settings_select"
  ON public.age_policy_settings FOR SELECT
  TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS "age_policy_settings_update" ON public.age_policy_settings;
CREATE POLICY "age_policy_settings_update"
  ON public.age_policy_settings FOR UPDATE
  TO authenticated
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());

-- ============================================================
-- [C] calc_age_kst(p_birthdate date) — 만 나이 헬퍼
--
-- KST(UTC+9) = JST(일본 표준시). Supabase DB 시각은 UTC.
-- 오늘 KST 날짜: (now() AT TIME ZONE 'Asia/Tokyo')::date
-- 만 나이: 올해 생일이 지났으면 (올해 - 생년), 아직이면 (올해 - 생년 - 1)
-- ============================================================

CREATE OR REPLACE FUNCTION public.calc_age_kst(p_birthdate date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    date_part('year', age(
      (now() AT TIME ZONE 'Asia/Tokyo')::date,
      p_birthdate
    ))::integer;
$$;

COMMENT ON FUNCTION public.calc_age_kst(date) IS
  '생년월일로 만 나이(KST/JST 기준) 계산. STABLE(동일 TX 내 같은 입력 → 같은 결과).
   사용처: check_age_policy 트리거, 향후 관리자 목록 나이 표시.';

GRANT EXECUTE ON FUNCTION public.calc_age_kst(date) TO authenticated;

-- ============================================================
-- [D] check_age_policy() — 응모 차단 트리거 함수
--
-- 실행 조건:
--   1. age_policy_settings.effective_date IS NULL → 무조건 통과 (비활성)
--   2. (today KST) < effective_date → 시행 전 → 통과
--   3. effective_date 이후:
--      a. influencers.birthdate IS NULL → 차단 (생년월일 미입력)
--      b. calc_age_kst(birthdate) < 18 → 차단 (18세 미만)
--      c. 그 외 → 통과
--
-- 주의:
--   - 관리자(admins 테이블 존재)가 직접 INSERT 하는 경우는 없음(관리자용 applications
--     직접 INSERT 경로가 없고, 관리자는 인플루언서 응모를 대리 처리하지 않음).
--     혹시를 대비해 is_admin() 체크로 관리자는 시행일 이후도 통과.
--   - 클라이언트 check 와 이중화: 클라(handleFloatApply)는 UX용, 이 트리거가 최종 방어선.
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_age_policy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_effective_date  date;
  v_today_kst       date;
  v_birthdate       date;
  v_age             integer;
BEGIN
  -- 관리자는 이 차단 대상 아님
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 시행일 조회 (단일행)
  SELECT effective_date
    INTO v_effective_date
    FROM public.age_policy_settings
   WHERE id = 1;

  -- effective_date = NULL → 차단 비활성, 통과
  IF v_effective_date IS NULL THEN
    RETURN NEW;
  END IF;

  -- 오늘 KST 날짜
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- 시행일 전 → 통과
  IF v_today_kst < v_effective_date THEN
    RETURN NEW;
  END IF;

  -- 시행일 이후: birthdate 확인
  SELECT birthdate
    INTO v_birthdate
    FROM public.influencers
   WHERE id = NEW.user_id;

  IF v_birthdate IS NULL THEN
    RAISE EXCEPTION '응모하려면 먼저 생년월일을 입력해 주세요 (연령 정책 2026)'
      USING ERRCODE = 'P0002';
  END IF;

  v_age := public.calc_age_kst(v_birthdate);

  IF v_age < 18 THEN
    RAISE EXCEPTION '본 서비스는 만 18세 이상만 응모할 수 있습니다 (현재 만 %세)'
      , v_age
      USING ERRCODE = 'P0002';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.check_age_policy() IS
  '[180] 응모 연령 차단 트리거 함수. BEFORE INSERT ON applications.
   시행일(age_policy_settings.effective_date) NULL 이면 전원 통과.
   시행일 이후: birthdate NULL 또는 18세 미만이면 P0002 RAISE.
   오류 코드 P0002 — 클라이언트는 이 코드로 "생년월일 입력" 안내 모달 노출.';

-- ============================================================
-- [E] trg_age_policy — 응모 BEFORE INSERT 트리거
-- ============================================================

DROP TRIGGER IF EXISTS trg_age_policy ON public.applications;
CREATE TRIGGER trg_age_policy
  BEFORE INSERT ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.check_age_policy();

-- ============================================================
-- [F] lock_influencer_birthdate() — 생년월일 수정 잠금 트리거 함수
--
-- 규칙 (사양서 §0-1 ②):
--   - 본인이 birthdate 를 NULL 에서 값으로 처음 입력: 허용.
--   - 본인이 이미 있는 birthdate 를 다른 값으로 변경: 차단.
--   - 관리자(is_admin()): 항상 변경 허용.
--
-- 구현:
--   OLD.birthdate IS NOT NULL (이미 값이 있음) AND
--   OLD.birthdate IS DISTINCT FROM NEW.birthdate (값이 바뀌려 함) AND
--   NOT is_admin() → RAISE
--
-- 기존 influencers UPDATE 행 단위 보안 정책과의 관계:
--   RLS "influencers_update_allow" 는 "is_admin() OR auth.uid()=id" 전체 허용.
--   이 트리거가 그 위에 추가 컬럼 단위 제약을 가함.
-- ============================================================

CREATE OR REPLACE FUNCTION public.lock_influencer_birthdate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 관리자는 항상 변경 허용
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- birthdate 가 이미 입력된 상태에서 다른 값으로 바꾸려 하면 차단
  IF OLD.birthdate IS NOT NULL
    AND OLD.birthdate IS DISTINCT FROM NEW.birthdate
  THEN
    RAISE EXCEPTION '생년월일은 최초 입력 후 변경할 수 없습니다. 수정이 필요하면 관리자에게 문의하세요.'
      USING ERRCODE = 'P0003';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.lock_influencer_birthdate() IS
  '[180] 생년월일 수정 잠금 트리거 함수. BEFORE UPDATE ON influencers.
   본인은 NULL→값 최초 입력만 허용, 값→다른값 변경은 P0003 RAISE.
   관리자는 항상 변경 가능.';

-- ============================================================
-- [G] trg_lock_influencer_birthdate — influencers BEFORE UPDATE 트리거
-- ============================================================

DROP TRIGGER IF EXISTS trg_lock_influencer_birthdate ON public.influencers;
CREATE TRIGGER trg_lock_influencer_birthdate
  BEFORE UPDATE ON public.influencers
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_influencer_birthdate();

-- ============================================================
-- 검증 쿼리 (SQL Editor 실행용 — 이 주석 안의 쿼리를 단계별로 실행)
--
-- 1단계 — 컬럼 존재 확인:
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'influencers'
--      AND column_name IN ('birthdate', 'gender')
--    ORDER BY column_name;
--   → birthdate date nullable, gender text nullable 2행 기대
--
-- 2단계 — 설정 테이블 확인:
--   SELECT id, effective_date, description, updated_at FROM public.age_policy_settings;
--   → 1행, effective_date = NULL
--
-- 3단계 — 헬퍼 함수 만 나이 계산 확인:
--   SELECT public.calc_age_kst('2000-06-15'::date) AS age_26,
--          public.calc_age_kst('2009-06-16'::date) AS age_16,
--          public.calc_age_kst('2008-06-14'::date) AS age_17;
--   → 26, 16, 17 (KST 기준 2026-06-15 실행 시)
--
-- 4단계 — 트리거 존재 확인:
--   SELECT trigger_name, event_manipulation, event_object_table
--     FROM information_schema.triggers
--    WHERE trigger_schema = 'public'
--      AND trigger_name IN ('trg_age_policy', 'trg_lock_influencer_birthdate');
--   → 2행 기대
--
-- 5단계 — 차단 비활성 상태 스모크 (실제 응모 RLS 통과 여부는 클라에서 확인):
--   -- effective_date = NULL 이면 P0002 안 나야 함
--   SELECT public.check_age_policy();  -- 트리거 함수 직접 호출은 불가, 트리거 의존.
--   -- 대신: SELECT effective_date FROM public.age_policy_settings WHERE id=1;
--   -- 결과가 NULL 이면 비활성 확인 완료.
-- ============================================================

COMMIT;
