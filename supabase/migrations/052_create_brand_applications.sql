-- ============================================================
-- migration: 052_create_brand_applications
-- purpose  : 광고주(브랜드) 신청 폼 시스템 PR-1 — DB 레이어
--            - brand_applications 테이블 (Qoo10 리뷰어 모집 / 나노 인플루언서 시딩)
--            - brand_app_daily_counter 테이블 (일자별 JST 채번)
--            - application_no 자동 채번 트리거 (JFUN-Q-YYYYMMDD-NNN / JFUN-N-...)
--            - products 배열에서 total_jpy, total_qty, estimated_krw 서버 재계산 트리거
--            - updated_at / version 자동 갱신 트리거
--            - RLS 정책: anon INSERT 허용, 관리자 전체 접근, 카운터는 SECURITY DEFINER 전용
--            - 인덱스, GRANT, COMMENT 포함
--
-- 적용 순서:
--   1. 개발 DB (qysmxtipobomefudyixw.supabase.co) 먼저 적용 후 검증
--   2. 운영 DB (twofagomeizrtkwlhsuv.supabase.co) 적용
--
-- rollback: 이 파일 맨 아래 ROLLBACK 블록 참조
-- ============================================================


-- ============================================================
-- 1. brand_app_daily_counter 테이블
--    일자별·폼타입별 채번 카운터. 트리거의 SECURITY DEFINER 함수에서만 접근.
-- ============================================================
CREATE TABLE IF NOT EXISTS brand_app_daily_counter (
  day       date NOT NULL,
  form_type text NOT NULL,
  seq       integer NOT NULL DEFAULT 0,
  PRIMARY KEY (day, form_type)
);

COMMENT ON TABLE brand_app_daily_counter IS
  '[052] 광고주 신청 폼 일자별(JST) 채번 카운터. 직접 INSERT/UPDATE 금지 — SECURITY DEFINER 트리거에서만 사용.';


-- ============================================================
-- 2. brand_applications 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS brand_applications (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 채번 트리거로 자동 생성 (JFUN-Q-20260420-001 / JFUN-N-20260420-001)
  application_no        text        UNIQUE NOT NULL,

  -- 폼 종류: reviewer(Qoo10 리뷰어 모집) / seeding(나노 인플루언서 시딩)
  form_type             text        NOT NULL CHECK (form_type IN ('reviewer', 'seeding')),

  -- 기본 브랜드 정보
  brand_name            text        NOT NULL,
  contact_name          text        NOT NULL,
  phone                 text        NOT NULL,
  email                 text        NOT NULL,

  -- 세금계산서용 이메일 (reviewer 전용, seeding에서는 NULL 허용)
  billing_email         text,

  -- 신청 상품 목록 (1~50개 배열)
  -- 구조: [{ "name": "상품명", "url": "URL", "price": 1000, "qty": 5, "category": "..." }, ...]
  products              jsonb       NOT NULL CHECK (
                          jsonb_typeof(products) = 'array'
                          AND jsonb_array_length(products) BETWEEN 1 AND 50
                        ),

  -- 합계 (서버 재계산 트리거로 덮어씀)
  total_jpy             numeric,    -- 상품 총액 (엔화)
  total_qty             integer,    -- 총 신청 수량

  -- 예상 견적 (클라이언트 계산값, 서버 재계산 트리거로 덮어씀)
  -- reviewer: supply = total_jpy * 10 + total_qty * 2500, vat = floor(supply * 0.1), estimated_krw = supply + vat
  -- seeding: 0
  estimated_krw         numeric,

  -- 확정 견적 (관리자 수동 입력)
  final_quote_krw       numeric,

  -- 관리자가 견적서를 발송한 시각
  quote_sent_at         timestamptz,

  -- 사업자등록증 Storage path (reviewer 전용)
  -- 경로 형식: 'YYYY/MM/{uuid}/license.ext'
  business_license_path text,

  -- 처리 상태: new → reviewing → quoted → paid → done / rejected
  status                text        NOT NULL DEFAULT 'new'
                          CHECK (status IN ('new', 'reviewing', 'quoted', 'paid', 'done', 'rejected')),

  -- 관리자 메모 (내부용)
  admin_memo            text,

  -- 검수 정보
  -- 검수자: auth.users(id) 직접 참조 (admins.auth_id는 UNIQUE가 아니라 FK 불가. deliverables 패턴과 일치)
  reviewed_by           uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at           timestamptz,

  -- 낙관적 락: 동시 편집 충돌 방지
  version               integer     NOT NULL DEFAULT 0,

  -- 타임스탬프
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE brand_applications IS
  '[052] 광고주(브랜드) 신청 폼 제출 데이터. anon 사용자 INSERT 허용, 검수·견적 확정은 관리자 수동 처리.';
COMMENT ON COLUMN brand_applications.application_no IS
  '자동 채번. JFUN-{Q|N}-YYYYMMDD-NNN 형식. BEFORE INSERT 트리거가 JST 기준으로 생성.';
COMMENT ON COLUMN brand_applications.products IS
  '신청 상품 배열. [{"name":"...","url":"...","price":1000,"qty":5},...]. 1~50개 제한.';
COMMENT ON COLUMN brand_applications.estimated_krw IS
  '클라이언트 계산 예상 견적 (참고용). BEFORE INSERT 트리거가 서버에서 재계산하여 덮어씀.';
COMMENT ON COLUMN brand_applications.final_quote_krw IS
  '관리자가 확정한 최종 견적 금액 (KRW). 클라이언트 estimated_krw와 다를 수 있음.';
COMMENT ON COLUMN brand_applications.version IS
  '낙관적 락용 버전. BEFORE UPDATE 트리거가 자동 증가.';


-- ============================================================
-- 3. 인덱스
-- ============================================================

-- 관리자 목록 조회 기본 정렬 (status + 최신순)
CREATE INDEX IF NOT EXISTS idx_brand_applications_status_created
  ON brand_applications (status, created_at DESC);

-- 폼 종류별 필터
CREATE INDEX IF NOT EXISTS idx_brand_applications_form_type
  ON brand_applications (form_type);

-- 브랜드명 검색
CREATE INDEX IF NOT EXISTS idx_brand_applications_brand_name
  ON brand_applications (brand_name);

-- 이메일 검색 (중복 신청 확인용)
CREATE INDEX IF NOT EXISTS idx_brand_applications_email
  ON brand_applications (email);


-- ============================================================
-- 4. application_no 채번 트리거 함수
--    JST 기준 일자별 카운터를 atomic하게 증가시키고 접수번호를 생성.
--    SECURITY DEFINER: brand_app_daily_counter 직접 접근 권한 없는 anon도 INSERT 가능.
-- ============================================================
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

  -- JST 기준 날짜 산출 (운영서버 Sydney UTC+10, 개발서버 Tokyo UTC+9 — 서버 타임존 의존 금지)
  v_jst_day := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- 폼 종류별 접두 결정
  v_prefix := CASE NEW.form_type
    WHEN 'reviewer' THEN 'Q'
    WHEN 'seeding'  THEN 'N'
    ELSE 'X'  -- CHECK constraint에서 이미 걸러지나 방어 코드 유지
  END;

  -- 일자+폼타입별 카운터를 atomic하게 증가 (INSERT … ON CONFLICT DO UPDATE)
  INSERT INTO public.brand_app_daily_counter (day, form_type, seq)
  VALUES (v_jst_day, NEW.form_type, 1)
  ON CONFLICT (day, form_type)
  DO UPDATE SET seq = public.brand_app_daily_counter.seq + 1
  RETURNING seq INTO v_seq;

  -- 접수번호 조합: JFUN-{Q|N}-YYYYMMDD-001
  v_no := 'JFUN-' || v_prefix || '-'
          || to_char(v_jst_day, 'YYYYMMDD') || '-'
          || lpad(v_seq::text, 3, '0');

  NEW.application_no := v_no;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.generate_brand_application_no IS
  '[052] brand_applications BEFORE INSERT 트리거. JST 기준 일자+폼타입별 카운터를 atomic 증가하여 접수번호 생성.';


DROP TRIGGER IF EXISTS trg_brand_app_no ON brand_applications;
CREATE TRIGGER trg_brand_app_no
  BEFORE INSERT ON brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.generate_brand_application_no();


-- ============================================================
-- 5. products 서버 재계산 트리거 함수
--    클라이언트 조작 방지: INSERT 시 products 배열에서 합계를 서버에서 재계산.
--    재계산 실패(데이터 형식 오류 등) 시 예외를 삼키고 클라이언트 값 유지 (UX 우선).
--    재계산 공식:
--      total_jpy = sum(price * qty)
--      total_qty = sum(qty)
--      reviewer: supply = total_jpy * 10 + total_qty * 2500
--                vat    = floor(supply * 0.1)
--                estimated_krw = supply + vat
--      seeding:  estimated_krw = 0
-- ============================================================
CREATE OR REPLACE FUNCTION public.recalc_brand_application_totals()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_total_jpy  numeric := 0;
  v_total_qty  integer := 0;
  v_supply     numeric := 0;
  v_vat        numeric := 0;
  v_item       jsonb;
BEGIN
  BEGIN
    -- products 배열을 순회하며 합계 계산
    FOR v_item IN SELECT jsonb_array_elements(NEW.products)
    LOOP
      v_total_jpy := v_total_jpy + COALESCE((v_item->>'price')::numeric, 0)
                                  * COALESCE((v_item->>'qty')::numeric, 0);
      v_total_qty := v_total_qty + COALESCE((v_item->>'qty')::integer, 0);
    END LOOP;

    NEW.total_jpy := v_total_jpy;
    NEW.total_qty := v_total_qty;

    -- 폼 종류별 estimated_krw 계산
    IF NEW.form_type = 'reviewer' THEN
      -- 공급가 = 총 상품금액(엔→원 환율 10배) + 이체수수료(2,500원/명)
      v_supply          := v_total_jpy * 10 + v_total_qty * 2500;
      -- 부가세 = 공급가 * 10% (절사)
      v_vat             := floor(v_supply * 0.1);
      NEW.estimated_krw := v_supply + v_vat;
    ELSE
      -- seeding은 별도 견적 필요 (estimated_krw = 0)
      NEW.estimated_krw := 0;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- 데이터 형식 오류 등 예외 발생 시 서버 재계산을 건너뛰고 클라이언트 값 유지
    -- INSERT가 막히는 것보다 클라이언트 값을 신뢰하는 것이 UX상 우선
    RAISE WARNING '[052] recalc_brand_application_totals: 재계산 실패, 클라이언트 값 유지. error=%', SQLERRM;
  END;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.recalc_brand_application_totals IS
  '[052] brand_applications BEFORE INSERT 트리거. products 배열에서 합계 서버 재계산. 실패 시 예외 삼키고 클라이언트 값 유지.';


DROP TRIGGER IF EXISTS trg_brand_app_recalc ON brand_applications;
CREATE TRIGGER trg_brand_app_recalc
  BEFORE INSERT ON brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.recalc_brand_application_totals();


-- ============================================================
-- 6. updated_at / version 자동 갱신 트리거 함수
--    BEFORE UPDATE 시 updated_at = now(), version = OLD.version + 1
-- ============================================================
CREATE OR REPLACE FUNCTION public.brand_applications_touch()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  NEW.version    := OLD.version + 1;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.brand_applications_touch IS
  '[052] brand_applications BEFORE UPDATE 트리거. updated_at 갱신 + 낙관적 락 version 증가.';


DROP TRIGGER IF EXISTS trg_brand_app_touch ON brand_applications;
CREATE TRIGGER trg_brand_app_touch
  BEFORE UPDATE ON brand_applications
  FOR EACH ROW EXECUTE FUNCTION public.brand_applications_touch();


-- ============================================================
-- 7. RLS 정책
-- ============================================================
ALTER TABLE brand_applications      ENABLE ROW LEVEL SECURITY;
ALTER TABLE brand_app_daily_counter ENABLE ROW LEVEL SECURITY;


-- idempotent 재적용을 위해 기존 정책을 먼저 DROP (PostgreSQL은 CREATE POLICY IF NOT EXISTS 미지원)
DROP POLICY IF EXISTS "brand_applications_insert_public" ON brand_applications;
DROP POLICY IF EXISTS "brand_applications_select_admin" ON brand_applications;
DROP POLICY IF EXISTS "brand_applications_update_admin" ON brand_applications;
DROP POLICY IF EXISTS "brand_applications_delete_admin" ON brand_applications;
DROP POLICY IF EXISTS "brand_app_daily_counter_select_admin" ON brand_app_daily_counter;

-- ── brand_applications ──

-- anon·authenticated 모두 INSERT 가능 (비공개 URL 접근자 = 광고주)
-- 데이터 유효성은 CHECK constraint, 채번·재계산은 SECURITY DEFINER 트리거에서 처리
CREATE POLICY "brand_applications_insert_public"
  ON brand_applications FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

-- 관리자: 전체 조회
CREATE POLICY "brand_applications_select_admin"
  ON brand_applications FOR SELECT
  USING (public.is_admin());

-- 관리자: 수정 (상태 변경, 견적 입력, 메모 등)
CREATE POLICY "brand_applications_update_admin"
  ON brand_applications FOR UPDATE
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 관리자: 삭제 (스팸·테스트 제출 정리용)
CREATE POLICY "brand_applications_delete_admin"
  ON brand_applications FOR DELETE
  USING (public.is_admin());


-- ── brand_app_daily_counter ──
-- anon·authenticated 직접 접근 전면 차단 (SECURITY DEFINER 트리거에서만 접근)
-- RLS 활성 + 명시적 정책 없음 = 기본 deny

-- 관리자: 채번 현황 조회 (디버깅 용이성)
CREATE POLICY "brand_app_daily_counter_select_admin"
  ON brand_app_daily_counter FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- 8. GRANT
--    anon·authenticated → brand_applications INSERT만 허용 (최소 권한 원칙)
--    SELECT/UPDATE/DELETE는 RLS 정책의 is_admin()으로만 통제
--    brand_app_daily_counter는 SECURITY DEFINER 트리거 내부 접근이므로 별도 GRANT 불필요
-- ============================================================
GRANT INSERT ON TABLE public.brand_applications TO anon, authenticated;
GRANT SELECT, UPDATE, DELETE ON TABLE public.brand_applications TO authenticated;
-- 주석: authenticated GRANT는 RLS가 실질 통제. 필요 시 향후 관리자 전용 DB Role로 분리 검토.


-- ============================================================
-- 적용 명령 안내
-- 개발서버: 이 파일 내용을 Supabase Dashboard(qysmxtipobomefudyixw) SQL Editor에 붙여넣어 실행
-- 운영서버: 개발 검증 완료 후 twofagomeizrtkwlhsuv SQL Editor에 동일하게 실행
-- ============================================================


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================
-- -- 테이블 존재 확인
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public'
--   AND table_name IN ('brand_applications', 'brand_app_daily_counter');
--
-- -- 채번 + 재계산 테스트 (reviewer)
-- INSERT INTO brand_applications (
--   application_no, form_type, brand_name, contact_name, phone, email,
--   products
-- ) VALUES (
--   '', 'reviewer', '테스트브랜드', '홍길동', '090-0000-0000', 'test@example.com',
--   '[{"name":"테스트상품","price":1000,"qty":3}]'
-- ) RETURNING application_no, total_jpy, total_qty, estimated_krw;
-- -- 기대값: application_no='JFUN-Q-YYYYMMDD-001'
-- --         total_jpy=3000, total_qty=3
-- --         supply=3000*10+3*2500=37500, vat=floor(37500*0.1)=3750, estimated_krw=41250
--
-- -- 채번 카운터 확인
-- SELECT * FROM brand_app_daily_counter ORDER BY day DESC;
--
-- -- seeding 테스트
-- INSERT INTO brand_applications (
--   application_no, form_type, brand_name, contact_name, phone, email,
--   products
-- ) VALUES (
--   '', 'seeding', '시딩브랜드', '김영희', '080-1111-2222', 'seed@example.com',
--   '[{"name":"상품A","price":2000,"qty":10}]'
-- ) RETURNING application_no, total_jpy, total_qty, estimated_krw;
-- -- 기대값: application_no='JFUN-N-YYYYMMDD-001', estimated_krw=0


-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TRIGGER IF EXISTS trg_brand_app_touch   ON brand_applications;
-- DROP TRIGGER IF EXISTS trg_brand_app_recalc  ON brand_applications;
-- DROP TRIGGER IF EXISTS trg_brand_app_no      ON brand_applications;
-- DROP FUNCTION IF EXISTS public.brand_applications_touch();
-- DROP FUNCTION IF EXISTS public.recalc_brand_application_totals();
-- DROP FUNCTION IF EXISTS public.generate_brand_application_no();
-- DROP TABLE IF EXISTS brand_applications CASCADE;
-- DROP TABLE IF EXISTS brand_app_daily_counter CASCADE;
