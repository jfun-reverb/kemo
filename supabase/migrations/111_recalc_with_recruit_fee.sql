-- ============================================================
-- 111_recalc_with_recruit_fee.sql
-- brand_applications 견적 트리거에 모집비(recruit_fee_krw) 합산 추가
-- 작성일: 2026-05-12
-- ============================================================
-- 배경:
--   052의 recalc_brand_application_totals() 트리거는 reviewer 공식에서
--     supply = total_jpy × 10 + total_qty × 2500
--   처럼 1인당 이체수수료 2500을 고정값으로 사용하고
--   products[i].recruit_fee_krw 는 무시하여
--   관리자가 모집비를 입력해도 estimated_krw 에 반영되지 않았다.
--   (관리자 페인 「예상 견적」 컬럼 툴팁에 "모집비는 미포함"으로 명시되어 있었음.)
--
--   클라이언트(admin-brand.js)는 이미 모집비를 카드 모달 등에서 합산하지만
--   DB 컬럼이 동기화되지 않아 페인 표·합계는 모집비 없는 옛 값.
--
-- 해결:
--   recalc_brand_application_totals() 함수를 CREATE OR REPLACE 로 재정의.
--   reviewer 공식을
--     supply = Σ(price × qty × 10)
--            + Σ(qty × recruit_fee_krw)
--            + Σ(qty × transfer_fee_krw)
--   로 변경. transfer_fee_krw 도 1인당 2500 고정에서 sum 으로 전환 (092
--   트리거가 reviewer 신청 INSERT 시 기본값 2500 을 채우므로 기존 데이터는
--   결과 동일).
--
-- 기존 데이터 호환:
--   - reviewer 행: recruit_fee_krw 미입력 → COALESCE(0). transfer_fee_krw
--     = 2500 (092 기본값). 결과적으로 옛 공식과 동일한 supply 값.
--   - seeding 행: 분기 진입 없음. 영향 없음.
--   - 백필 UPDATE 불필요.
--
-- 영향 분석:
--   - 트리거 자체(trg_brand_app_recalc) 재정의 불필요. CREATE OR REPLACE
--     FUNCTION 만으로 효과.
--   - final_quote_krw (확정 견적) 컬럼은 별개. 관리자 수동 입력.
--   - 클라이언트 표시 코드(admin-brand.js)는 a.estimated_krw 그대로
--     렌더 → 트리거 갱신만으로 자동 동기화.
--   - 092 트리거(fill_reviewer_transfer_fee)는 그대로 유효.
--
-- 사양: docs/specs/2026-05-12-brand-recruit-fee-in-quote.md
--
-- supabase-expert 검토 후 추가 사항:
--   - 기존 trg_brand_app_recalc 는 BEFORE INSERT 전용 → UPDATE 시 미동작.
--     UPDATE OF products, form_type 으로 확장. status·admin_memo 변경
--     같은 무관 컬럼 UPDATE 에서는 발동 안 함 (성능·복잡도 최소화).
--   - 함수 교체 + 트리거 재정의를 BEGIN/COMMIT 으로 감싸 부분 실패 시
--     원자성 보장.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.recalc_brand_application_totals()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_total_jpy       numeric := 0;
  v_total_qty       integer := 0;
  v_recruit_total   numeric := 0;
  v_transfer_total  numeric := 0;
  v_supply          numeric := 0;
  v_vat             numeric := 0;
  v_item            jsonb;
BEGIN
  BEGIN
    FOR v_item IN SELECT jsonb_array_elements(NEW.products)
    LOOP
      v_total_jpy      := v_total_jpy
                         + COALESCE((v_item->>'price')::numeric, 0)
                         * COALESCE((v_item->>'qty')::numeric, 0);
      v_total_qty      := v_total_qty
                         + COALESCE((v_item->>'qty')::integer, 0);
      v_recruit_total  := v_recruit_total
                         + COALESCE((v_item->>'qty')::numeric, 0)
                         * COALESCE((v_item->>'recruit_fee_krw')::numeric, 0);
      -- transfer_fee_krw 폴백:
      --   092 트리거(fill_reviewer_transfer_fee)가 reviewer 신청 INSERT 시 2500 을
      --   채우지만, PostgreSQL BEFORE 트리거는 이름 사전순으로 실행되므로
      --   trg_brand_app_recalc(b)가 trg_fill_reviewer_transfer_fee(f) 보다 먼저
      --   실행된다. 즉 INSERT 시점에 본 함수가 products 를 읽을 때는 092 가
      --   아직 키를 채우기 전이라 (v_item->>'transfer_fee_krw') = NULL.
      --   reviewer 일 때 폴백 2500 으로 사전 합산해 092 가 채우는 값과
      --   일치하도록 한다. UPDATE 시점에는 키가 이미 있어 폴백 미사용.
      --   seeding 은 분기 진입 안 하므로 폴백 0 이어도 무관.
      v_transfer_total := v_transfer_total
                         + COALESCE((v_item->>'qty')::numeric, 0)
                         * COALESCE(
                             (v_item->>'transfer_fee_krw')::numeric,
                             CASE WHEN NEW.form_type = 'reviewer' THEN 2500 ELSE 0 END
                           );
    END LOOP;

    NEW.total_jpy := v_total_jpy;
    NEW.total_qty := v_total_qty;

    IF NEW.form_type = 'reviewer' THEN
      -- 새 공식 (안 A):
      --   supply = 상품 합계(원) + 모집비 합계(원) + 이체수수료 합계(원)
      --   vat = floor(supply × 0.1)
      --   estimated_krw = supply + vat
      v_supply := (v_total_jpy * 10) + v_recruit_total + v_transfer_total;
      v_vat    := floor(v_supply * 0.1);
      NEW.estimated_krw := v_supply + v_vat;
    ELSE
      -- seeding 은 별도 견적 필요 (수동 협의)
      NEW.estimated_krw := 0;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- 데이터 형식 오류 등 예외 시 클라이언트 값 유지
    RAISE WARNING '[111] recalc_brand_application_totals: 재계산 실패, 클라이언트 값 유지. error=%', SQLERRM;
  END;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.recalc_brand_application_totals IS
  '[111] brand_applications BEFORE INSERT/UPDATE 트리거. reviewer 공식에 products[i].recruit_fee_krw 와 transfer_fee_krw 를 sum 으로 합산. 052의 고정 2500 공식을 교체. seeding 영향 없음.';


-- ============================================================
-- 트리거 재정의: BEFORE INSERT → BEFORE INSERT OR UPDATE OF products,form_type
-- 052 는 INSERT 전용으로 등록되어 있어 UPDATE 시점에 estimated_krw 가
-- 갱신되지 않는 버그가 있었다. 모집비 인라인 편집 후 저장 시 자동 동기화
-- 되도록 UPDATE 이벤트를 추가한다. status / admin_memo 등 무관 컬럼
-- UPDATE 는 발동하지 않도록 컬럼 한정.
-- ============================================================
DROP TRIGGER IF EXISTS trg_brand_app_recalc ON public.brand_applications;
CREATE TRIGGER trg_brand_app_recalc
  BEFORE INSERT OR UPDATE OF products, form_type
  ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.recalc_brand_application_totals();


COMMIT;


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 실행)
-- ============================================================
/*
-- [V1] 함수 본문 갱신 확인
SELECT prosrc ILIKE '%recruit_fee_krw%' AS has_recruit,
       prosrc ILIKE '%transfer_fee_krw%' AS has_transfer
FROM pg_proc WHERE proname='recalc_brand_application_totals';
-- 두 컬럼 모두 true

-- [V2] 기존 reviewer 행 호환 검증 (UPDATE 전후 비교)
-- ※ 운영 데이터 영향을 피하려면 read-only 비교 권장
SELECT id, total_jpy, total_qty, estimated_krw
FROM brand_applications
WHERE form_type='reviewer' AND status='new'
ORDER BY created_at DESC
LIMIT 3;
-- 같은 행을 같은 products 값으로 UPDATE → estimated_krw 변화 없는지 확인 가능

-- [V3] 모집비 추가 시 합산 검증 (ROLLBACK 권장)
BEGIN;
UPDATE brand_applications
SET products = jsonb_set(
  products,
  '{0,recruit_fee_krw}',
  '5000'::jsonb
)
WHERE id = '<TEST_ID>' AND form_type='reviewer';
SELECT estimated_krw FROM brand_applications WHERE id = '<TEST_ID>';
-- 옛 estimated_krw + qty × 5000 × 1.1 (VAT) 증가 확인
ROLLBACK;

-- [V4] seeding 영향 없음 확인
SELECT estimated_krw FROM brand_applications
WHERE form_type='seeding' LIMIT 5;
-- 모두 0
*/


-- [V5] 트리거 이벤트 확장 확인
SELECT tgname, pg_get_triggerdef(oid) AS def
FROM pg_trigger
WHERE tgrelid='public.brand_applications'::regclass
  AND tgname='trg_brand_app_recalc';
-- def 본문에 'INSERT OR UPDATE OF products, form_type' 포함되어야 함


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*
BEGIN;
-- 052 의 원본 본문으로 되돌림
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
    FOR v_item IN SELECT jsonb_array_elements(NEW.products)
    LOOP
      v_total_jpy := v_total_jpy + COALESCE((v_item->>'price')::numeric, 0)
                                  * COALESCE((v_item->>'qty')::numeric, 0);
      v_total_qty := v_total_qty + COALESCE((v_item->>'qty')::integer, 0);
    END LOOP;
    NEW.total_jpy := v_total_jpy;
    NEW.total_qty := v_total_qty;
    IF NEW.form_type = 'reviewer' THEN
      v_supply          := v_total_jpy * 10 + v_total_qty * 2500;
      v_vat             := floor(v_supply * 0.1);
      NEW.estimated_krw := v_supply + v_vat;
    ELSE
      NEW.estimated_krw := 0;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[052-rollback] recalc_brand_application_totals: 재계산 실패. error=%', SQLERRM;
  END;
  RETURN NEW;
END;
$$;
-- 트리거를 052 원본 INSERT 전용으로 되돌림
DROP TRIGGER IF EXISTS trg_brand_app_recalc ON public.brand_applications;
CREATE TRIGGER trg_brand_app_recalc
  BEFORE INSERT ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.recalc_brand_application_totals();
COMMIT;
*/
