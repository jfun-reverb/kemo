-- ============================================================
-- P-090-rollback.sql
-- 계층 채번 시스템 완전 롤백 (088+089+090 일괄)
--
-- 용도: 패치 (one-off) — 088~090 적용 후 치명적 문제 발생 시 복구
-- 실행 환경: 운영서버 또는 개발서버 SQL Editor
--
-- 전제:
--   - pg_dump 백업이 완료된 상태여야 함
--   - 롤백 후 트래픽이 재유입되므로 롤백 직후 기능 검증 필수
--
-- 실행 순서:
--   1. 이 파일 전체 실행 (BEGIN..COMMIT)
--   2. CAMP-YYYY-NNNN / JFUN-R/S 포맷이 복원됐는지 확인
--   3. 관리자 페이지에서 신청/캠페인 목록 번호 표시 확인
--
-- 주의:
--   - legacy_no 컬럼이 없으면 원번 복원 불가 (legacy_no 컬럼은 090 이후도 유지)
--   - brands.brand_seq, 카운터 테이블은 모두 DROP (재마이그레이션 시 재생성)
--
-- 작성일: 2026-05-04
-- ============================================================


BEGIN;


-- ============================================================
-- PHASE 1: 트리거/함수 제거 (090 산출물)
-- ============================================================

DROP TRIGGER IF EXISTS trg_brand_app_no ON public.brand_applications;
DROP TRIGGER IF EXISTS trg_campaign_no  ON public.campaigns;
DROP TRIGGER IF EXISTS trg_brand_seq    ON public.brands;

DROP FUNCTION IF EXISTS public.generate_brand_application_no();
DROP FUNCTION IF EXISTS public.generate_campaign_no();
DROP FUNCTION IF EXISTS public.generate_brand_seq();


-- ============================================================
-- PHASE 2: 번호 원복 (089 산출물)
--   legacy_no → application_no / campaign_no 복원
-- ============================================================

UPDATE public.brand_applications
SET application_no = legacy_no
WHERE legacy_no IS NOT NULL
  AND application_no <> legacy_no;

UPDATE public.campaigns
SET campaign_no = legacy_no
WHERE legacy_no IS NOT NULL
  AND campaign_no <> legacy_no;

-- 카운터 초기화
DELETE FROM public.brand_external_campaign_counter;
DELETE FROM public.application_campaign_counter;
DELETE FROM public.brand_application_counter;

-- brand_seq 초기화
UPDATE public.brands SET brand_seq = NULL;
UPDATE public.brand_seq_counter SET seq = 0 WHERE id = 1;

-- campaigns FK 컬럼 초기화
UPDATE public.campaigns SET brand_id = NULL, source_application_id = NULL;

-- legacy_no 초기화 (088 이전 상태)
UPDATE public.brand_applications SET legacy_no = NULL;
UPDATE public.campaigns           SET legacy_no = NULL;

-- 매핑 테이블 비우기
DELETE FROM public.numbering_legacy_map;


-- ============================================================
-- PHASE 3: 스키마 원복 (088 산출물)
-- ============================================================

-- campaigns 컬럼 제거
ALTER TABLE public.campaigns
  DROP COLUMN IF EXISTS brand_id,
  DROP COLUMN IF EXISTS source_application_id,
  DROP COLUMN IF EXISTS legacy_no;

-- brand_applications 컬럼 제거
ALTER TABLE public.brand_applications
  DROP COLUMN IF EXISTS legacy_no;

-- brands 컬럼 제거
ALTER TABLE public.brands
  DROP COLUMN IF EXISTS brand_seq;

-- 카운터/매핑 테이블 DROP
DROP TABLE IF EXISTS public.numbering_legacy_map;
DROP TABLE IF EXISTS public.brand_external_campaign_counter;
DROP TABLE IF EXISTS public.application_campaign_counter;
DROP TABLE IF EXISTS public.brand_application_counter;
DROP TABLE IF EXISTS public.brand_seq_counter;


-- ============================================================
-- PHASE 4: 055/078 버전 트리거 함수 복원
-- ============================================================

-- [A] 078 버전: generate_brand_application_no (JFUN-R/S-YYMMDD-NNN)
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
    WHEN 'reviewer' THEN 'R'
    WHEN 'seeding'  THEN 'S'
    ELSE 'X'
  END;
  INSERT INTO public.brand_app_daily_counter (day, form_type, seq)
  VALUES (v_jst_day, NEW.form_type, 1)
  ON CONFLICT (day, form_type)
  DO UPDATE SET seq = public.brand_app_daily_counter.seq + 1
  RETURNING seq INTO v_seq;
  v_no := 'JFUN-' || v_prefix || '-'
          || to_char(v_jst_day, 'YYMMDD') || '-'
          || lpad(v_seq::text, 3, '0');
  NEW.application_no := v_no;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_application_no IS
  '[078-restored] brand_applications BEFORE INSERT 트리거. JST 기준 JFUN-R/S-YYMMDD-NNN 채번. 090 롤백으로 복원됨.';

REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_brand_application_no() FROM anon;

DROP TRIGGER IF EXISTS trg_brand_app_no ON public.brand_applications;
CREATE TRIGGER trg_brand_app_no
  BEFORE INSERT ON public.brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.generate_brand_application_no();


-- [B] 055 버전: generate_campaign_no (CAMP-YYYY-NNNN)
CREATE OR REPLACE FUNCTION public.generate_campaign_no()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_year integer;
  v_seq  integer;
BEGIN
  IF NEW.campaign_no IS NOT NULL AND NEW.campaign_no <> '' THEN
    RETURN NEW;
  END IF;
  v_year := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Tokyo'))::integer;
  INSERT INTO public.campaigns_yearly_counter (year, seq)
  VALUES (v_year, 1)
  ON CONFLICT (year)
  DO UPDATE SET seq = public.campaigns_yearly_counter.seq + 1
  RETURNING seq INTO v_seq;
  NEW.campaign_no := 'CAMP-' || v_year::text || '-' || lpad(v_seq::text, 4, '0');
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_campaign_no IS
  '[055-restored] campaigns BEFORE INSERT 트리거. JST 연도별 CAMP-YYYY-NNNN 채번. 090 롤백으로 복원됨.';

REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM authenticated;
REVOKE ALL ON FUNCTION public.generate_campaign_no() FROM anon;

DROP TRIGGER IF EXISTS trg_campaign_no ON public.campaigns;
CREATE TRIGGER trg_campaign_no
  BEFORE INSERT ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public.generate_campaign_no();


-- ============================================================
-- 검증
-- ============================================================

-- application_no 구 포맷 확인
DO $$
DECLARE v_new integer;
BEGIN
  SELECT count(*) INTO v_new
  FROM public.brand_applications
  WHERE application_no SIMILAR TO 'B[0-9]{4}-A[0-9]{3}';
  IF v_new > 0 THEN
    RAISE EXCEPTION '[P-090-rollback] 새 포맷 application_no % 건 남아있음. 롤백 실패.', v_new;
  END IF;
END; $$;

-- campaign_no 구 포맷 확인
DO $$
DECLARE v_new integer;
BEGIN
  SELECT count(*) INTO v_new
  FROM public.campaigns
  WHERE campaign_no SIMILAR TO 'B[0-9]{4}-(A[0-9]{3}-)?C[0-9]{3}';
  IF v_new > 0 THEN
    RAISE EXCEPTION '[P-090-rollback] 새 포맷 campaign_no % 건 남아있음. 롤백 실패.', v_new;
  END IF;
END; $$;


NOTIFY pgrst, 'reload schema';


COMMIT;
