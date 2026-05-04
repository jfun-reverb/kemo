-- ============================================================
-- 078_brand_app_no_format_v2.sql
-- brand_applications.application_no 채번 포맷 변경
--
-- 변경 전: JFUN-Q-YYYYMMDD-NNN (reviewer) / JFUN-N-YYYYMMDD-NNN (seeding)
-- 변경 후: JFUN-R-YYMMDD-NNN  (reviewer) / JFUN-S-YYMMDD-NNN  (seeding)
--   - Q → R, N → S
--   - 연도 4자리 → 2자리 (YYYYMMDD → YYMMDD)
--
-- 기존 데이터: 모두 일괄 UPDATE (외부 공유 참조 리스크 인지 후 사용자 확정)
-- 카운터: brand_app_daily_counter (day, form_type) 키 변경 없음 — 영향 없음
-- 트리거: BEFORE INSERT 바인딩 변경 없음 — 함수 교체만으로 적용됨
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. 채번 함수 교체 (CREATE OR REPLACE)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_brand_application_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_jst_day  date;
  v_prefix   text;
  v_seq      integer;
  v_no       text;
BEGIN
  -- NEW.application_no가 이미 세팅되어 있으면 덮어쓰지 않음 (관리자 수동 지정 안전장치)
  IF NEW.application_no IS NOT NULL AND NEW.application_no <> '' THEN
    RETURN NEW;
  END IF;

  -- JST 기준 날짜 산출 (서버 타임존 의존 금지)
  v_jst_day := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- 폼 종류별 접두 결정 (v2: Q→R, N→S)
  v_prefix := CASE NEW.form_type
    WHEN 'reviewer' THEN 'R'
    WHEN 'seeding'  THEN 'S'
    ELSE 'X'  -- CHECK constraint에서 이미 걸러지나 방어 코드 유지
  END;

  -- 일자+폼타입별 카운터를 atomic하게 증가 (키 구조 변경 없음)
  INSERT INTO public.brand_app_daily_counter (day, form_type, seq)
  VALUES (v_jst_day, NEW.form_type, 1)
  ON CONFLICT (day, form_type)
  DO UPDATE SET seq = public.brand_app_daily_counter.seq + 1
  RETURNING seq INTO v_seq;

  -- 접수번호 조합: JFUN-{R|S}-YYMMDD-NNN (v2)
  v_no := 'JFUN-' || v_prefix || '-'
          || to_char(v_jst_day, 'YYMMDD') || '-'
          || lpad(v_seq::text, 3, '0');

  NEW.application_no := v_no;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_application_no IS
  '[078] brand_applications BEFORE INSERT 트리거. JST 기준 일자+폼타입별 카운터를 atomic 증가하여 접수번호 생성. v2: reviewer=R, seeding=S, 연도 2자리(YYMMDD).';


-- ────────────────────────────────────────────────────────────
-- 2. 기존 데이터 일괄 UPDATE
--    JFUN-Q-20YYMMDD-NNN → JFUN-R-YYMMDD-NNN
--    JFUN-N-20YYMMDD-NNN → JFUN-S-YYMMDD-NNN
--
--    2026년 이전 데이터도 안전하게 처리:
--      '^JFUN-Q-20' 매칭 → 'JFUN-R-' 로 교체 (앞 "20" 2자리 제거 효과)
--      '^JFUN-N-20' 매칭 → 'JFUN-S-' 로 교체
--    2030년 이후 데이터는 이 마이그레이션 실행 전에 존재하지 않으므로 안전함.
-- ────────────────────────────────────────────────────────────
UPDATE public.brand_applications
SET application_no = regexp_replace(application_no, '^JFUN-Q-20', 'JFUN-R-')
WHERE application_no LIKE 'JFUN-Q-%';

UPDATE public.brand_applications
SET application_no = regexp_replace(application_no, '^JFUN-N-20', 'JFUN-S-')
WHERE application_no LIKE 'JFUN-N-%';


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 적용 후 SQL Editor에서 직접 실행
-- ════════════════════════════════════════════════════════════
/*
-- 1. 새 포맷 건수 확인 (R/S 포맷이 0 이상)
SELECT
  COUNT(*) FILTER (WHERE application_no LIKE 'JFUN-R-%') AS reviewer_new,
  COUNT(*) FILTER (WHERE application_no LIKE 'JFUN-S-%') AS seeding_new,
  COUNT(*) FILTER (WHERE application_no LIKE 'JFUN-Q-%') AS reviewer_old,  -- 반드시 0
  COUNT(*) FILTER (WHERE application_no LIKE 'JFUN-N-%') AS seeding_old    -- 반드시 0
FROM public.brand_applications;

-- 2. 구 포맷이 남아 있지 않음을 확인 (0건이어야 함)
SELECT application_no FROM public.brand_applications
WHERE application_no ~ '^JFUN-[QN]-';

-- 3. 새 포맷 샘플 조회
SELECT id, form_type, application_no, created_at
FROM public.brand_applications
ORDER BY created_at DESC
LIMIT 10;

-- 4. 트리거 함수 정의 확인 (v_prefix 'R'/'S' 포함 여부)
SELECT prosrc FROM pg_proc WHERE proname = 'generate_brand_application_no';

-- 5. UNIQUE 제약 중복 없음 확인 (결과 0건이어야 함)
SELECT application_no, COUNT(*) AS cnt
FROM public.brand_applications
GROUP BY application_no
HAVING COUNT(*) > 1;
*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 순서대로 실행
-- ════════════════════════════════════════════════════════════
/*
-- STEP 1. 함수를 v1 포맷으로 복구
CREATE OR REPLACE FUNCTION public.generate_brand_application_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_jst_day  date;
  v_prefix   text;
  v_seq      integer;
  v_no       text;
BEGIN
  IF NEW.application_no IS NOT NULL AND NEW.application_no <> '' THEN
    RETURN NEW;
  END IF;
  v_jst_day := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_prefix := CASE NEW.form_type
    WHEN 'reviewer' THEN 'Q'
    WHEN 'seeding'  THEN 'N'
    ELSE 'X'
  END;
  INSERT INTO public.brand_app_daily_counter (day, form_type, seq)
  VALUES (v_jst_day, NEW.form_type, 1)
  ON CONFLICT (day, form_type)
  DO UPDATE SET seq = public.brand_app_daily_counter.seq + 1
  RETURNING seq INTO v_seq;
  v_no := 'JFUN-' || v_prefix || '-'
          || to_char(v_jst_day, 'YYYYMMDD') || '-'
          || lpad(v_seq::text, 3, '0');
  NEW.application_no := v_no;
  RETURN NEW;
END;
$$;

-- STEP 2. 데이터 롤백 (R→Q, S→N, YYMMDD→YYYYMMDD)
--   주의: 2026년 기준이므로 YY='26' → '2026' 복원
UPDATE public.brand_applications
SET application_no = regexp_replace(
  regexp_replace(application_no, '^JFUN-R-', 'JFUN-Q-'),
  '^(JFUN-Q-)(\d{6}-)',
  '\g<1>20\2'
)
WHERE application_no LIKE 'JFUN-R-%';

UPDATE public.brand_applications
SET application_no = regexp_replace(
  regexp_replace(application_no, '^JFUN-S-', 'JFUN-N-'),
  '^(JFUN-N-)(\d{6}-)',
  '\g<1>20\2'
)
WHERE application_no LIKE 'JFUN-S-%';

COMMENT ON FUNCTION public.generate_brand_application_no IS
  '[052] brand_applications BEFORE INSERT 트리거. JST 기준 일자+폼타입별 카운터를 atomic 증가하여 접수번호 생성.';
*/
