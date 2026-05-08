-- ============================================================
-- 101_brand_app_product_status_sync.sql
-- brand_applications.products[i].status 자동 채움 +
-- 신청 대표 status (brand_applications.status) 자동 동기화 트리거
--
-- 배경:
--   Phase B — products[i].status 도입 후 아래 두 가지를 트리거로 자동 처리한다.
--
--   (A) 누락 status 채움:
--     INSERT 또는 products 컬럼 UPDATE 시, 각 원소에 status 키가 없으면
--     NEW.status (신청 단위 상태) 를 복사하여 자동 채운다.
--     sales 폼(anon 경로) 과 관리자 직접 등록 양쪽 모두 자동 커버.
--
--   (B) 신청 대표값 동기화:
--     products[i].status 가 변경될 때 「가장 늦은 단계」 를 계산하여
--     NEW.status 를 자동 갱신한다.
--     → 신청 단위 status 가 legacy 컬럼으로서 항상 최신 상태를 반영하게 됨.
--
-- 단계 순서 정의 (숫자가 클수록 더 진행된 상태):
--   new=0, reviewing=1, quoted=2, paid=3,
--   kakao_room_created=4, orient_sheet_sent=5,
--   schedule_sent=6, campaign_registered=7, done=8
--   rejected: 특수 처리 — 아래 "rejected 처리 규칙" 참조
--
-- rejected 처리 규칙:
--   - 일부 제품만 rejected: 나머지 제품 중 가장 늦은 단계를 대표값으로 사용
--     (rejected 제품은 대표값 계산에서 제외)
--   - 모든 제품이 rejected: 신청 대표값 = 'rejected'
--   - products 가 비어있거나 NULL: 기존 NEW.status 유지 (트리거 무시)
--
-- 성능 최적화:
--   products 컬럼이 실제로 변경된 경우에만 동기화 로직 실행.
--   다른 컬럼(admin_memo, reviewed_at 등)만 변경된 UPDATE 시에는
--   products 비교 결과 동일하면 두 처리 모두 건너뜀.
--   단, INSERT 시에는 항상 실행 (OLD 가 없으므로).
--
-- 트리거 종류: BEFORE INSERT OR UPDATE OF products
--   (UPDATE OF products: products 컬럼이 SET 절에 포함된 경우에만 발동)
--
-- SECURITY:
--   SECURITY INVOKER 사용 — 이 함수는 NEW 레코드만 조작하며
--   다른 테이블에 접근하지 않으므로 DEFINER 불필요.
--   search_path 는 '' 로 고정하여 탈취 방어.
--
-- 적용 환경:
--   개발서버(qysmxtipobomefudyixw) 먼저 적용 → 검증 → 운영서버 적용
--
-- 전제조건:
--   100_backfill_product_status.sql 이 먼저 적용되어 있어야 함.
--
-- 작성일: 2026-05-08
-- ============================================================


-- ============================================================
-- 1. 트리거 함수 생성 / 교체
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_brand_app_product_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY INVOKER
  SET search_path = ''
AS $$
DECLARE
  -- 단계 순서 정의 (숫자가 클수록 더 진행된 상태)
  -- rejected 는 이 배열에 포함하지 않고 별도 처리
  v_order        text[]  := ARRAY[
    'new',
    'reviewing',
    'quoted',
    'paid',
    'kakao_room_created',
    'orient_sheet_sent',
    'schedule_sent',
    'campaign_registered',
    'done'
  ];

  v_elem          jsonb;
  v_elem_status   text;
  v_max_ord       integer := -1;   -- 가장 늦은 단계의 순서 값 (-1 = 초기화)
  v_max_status    text    := NULL;
  v_all_rejected  boolean := true; -- 모든 제품이 rejected 인지 여부
  v_has_products  boolean := false; -- products 배열에 원소가 1개 이상 있는지
  v_ord           integer;
  v_new_products  jsonb   := '[]'::jsonb;
  v_agg           jsonb;
BEGIN
  -- ─────────────────────────────────────────────────────────
  -- 성능 최적화: products 가 실제 변경된 경우에만 처리
  --   INSERT 시 OLD 가 없으므로 항상 처리
  --   UPDATE 시 OLD.products = NEW.products 면 스킵
  -- ─────────────────────────────────────────────────────────
  IF TG_OP = 'UPDATE' AND OLD.products IS NOT DISTINCT FROM NEW.products THEN
    RETURN NEW;
  END IF;

  -- products 가 NULL 이거나 배열 타입이 아니면 기존 NEW 유지
  IF NEW.products IS NULL
    OR jsonb_typeof(NEW.products) <> 'array'
    OR jsonb_array_length(NEW.products) = 0
  THEN
    RETURN NEW;
  END IF;

  -- ─────────────────────────────────────────────────────────
  -- (A) 누락 status 채움 + (B) 대표값 산정을 동시에 처리
  --
  --   배열을 한 번만 순회하여:
  --   - status 키 없는 원소 → NEW.status 를 복사
  --   - 각 원소의 status 를 v_order 배열에서 위치 찾아 v_max_ord 갱신
  --   - rejected 여부 추적
  -- ─────────────────────────────────────────────────────────
  SELECT
    jsonb_agg(
      CASE
        WHEN NOT (elem ? 'status')
          THEN elem || jsonb_build_object('status', COALESCE(NEW.status, 'new'))
        ELSE elem
      END
      ORDER BY ord
    )
  INTO v_agg
  FROM jsonb_array_elements(NEW.products) WITH ORDINALITY AS t(elem, ord);

  -- 집계 결과가 NULL 이면 (배열 처리 실패 방어) 기존 NEW 유지
  IF v_agg IS NULL THEN
    RETURN NEW;
  END IF;

  NEW.products := v_agg;

  -- ─────────────────────────────────────────────────────────
  -- (B) 대표값 산정: 채워진 NEW.products 기준으로 순회
  -- ─────────────────────────────────────────────────────────
  FOR v_elem IN SELECT jsonb_array_elements(NEW.products)
  LOOP
    v_has_products := true;
    v_elem_status  := v_elem->>'status';

    IF v_elem_status IS NULL OR v_elem_status = '' THEN
      -- status 값 자체가 비어 있으면 대표값 계산에서 제외
      CONTINUE;
    END IF;

    IF v_elem_status <> 'rejected' THEN
      -- rejected 가 아닌 원소가 하나라도 있으면 all_rejected = false
      v_all_rejected := false;

      -- v_order 배열에서 해당 status 의 위치(1-based) 탐색
      v_ord := array_position(v_order, v_elem_status);

      -- 인식할 수 없는 status 값은 0 으로 처리 (new 와 동일 취급)
      IF v_ord IS NULL THEN
        v_ord := 0;
      END IF;

      -- 순서 0-based 로 보정 (array_position 은 1부터 시작)
      v_ord := v_ord - 1;

      IF v_ord > v_max_ord THEN
        v_max_ord    := v_ord;
        v_max_status := v_elem_status;
      END IF;
    END IF;
    -- rejected 원소는 v_all_rejected 카운트만 유지, 대표값 계산에서 제외
  END LOOP;

  -- ─────────────────────────────────────────────────────────
  -- 대표값 결정 및 NEW.status 갱신
  -- ─────────────────────────────────────────────────────────
  IF NOT v_has_products THEN
    -- 원소가 없으면 기존 NEW.status 유지 (위에서 이미 체크했으나 이중 방어)
    RETURN NEW;
  END IF;

  IF v_all_rejected THEN
    -- 모든 제품이 rejected → 신청 대표값 = 'rejected'
    NEW.status := 'rejected';
  ELSIF v_max_status IS NOT NULL THEN
    -- 가장 늦은 단계 상태로 신청 대표값 갱신
    NEW.status := v_max_status;
  ELSE
    -- v_max_status 가 NULL (원소는 있으나 모두 빈 status) → 'new' 폴백
    NEW.status := COALESCE(NEW.status, 'new');
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- 예상치 못한 오류 발생 시 예외를 삼키고 기존 NEW 반환 (INSERT/UPDATE 차단 방지)
  RAISE WARNING '[101] sync_brand_app_product_status: 처리 실패, 기존 값 유지. error=%, detail=%',
    SQLERRM, SQLSTATE;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_brand_app_product_status IS
  '[101] brand_applications BEFORE INSERT OR UPDATE OF products 트리거.
  (A) products[i].status 누락 시 NEW.status 또는 new 로 자동 채움.
  (B) 제품 중 가장 늦은 단계를 NEW.status 에 동기화.
  rejected 처리: 일부 rejected = 나머지 중 최대, 전부 rejected = rejected.
  products 미변경 UPDATE 시 스킵(성능).';


-- ============================================================
-- 2. 트리거 등록
--    BEFORE INSERT OR UPDATE OF products — products 컬럼 변경 시에만 발동
--    INSERT 는 항상 발동 (신규 신청, sales 폼 anon 포함)
-- ============================================================
DROP TRIGGER IF EXISTS trg_brand_app_product_status_sync ON public.brand_applications;

CREATE TRIGGER trg_brand_app_product_status_sync
  BEFORE INSERT OR UPDATE OF products
  ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_brand_app_product_status();

COMMENT ON TRIGGER trg_brand_app_product_status_sync ON public.brand_applications IS
  '[101] products 컬럼 INSERT/UPDATE 시 product status 자동 채움 + 신청 대표 status 동기화.';


-- ============================================================
-- 3. 트리거 순서 확인
--    brand_applications 에는 아래 트리거들이 공존한다:
--      trg_brand_app_no        — BEFORE INSERT: 접수번호 채번
--      trg_brand_app_recalc    — BEFORE INSERT: 합계 재계산
--      trg_brand_app_product_status_sync — BEFORE INSERT OR UPDATE OF products
--      trg_brand_app_touch     — BEFORE UPDATE: updated_at, version 증가
--
--    PostgreSQL 은 같은 이벤트 내 여러 BEFORE 트리거를 트리거명 알파벳 순으로 실행.
--    INSERT 시 실행 순서: trg_brand_app_no → trg_brand_app_product_status_sync → trg_brand_app_recalc
--    (n < p < r 순 — 채번 후 status 채움, 그 다음 합계 재계산)
--    UPDATE OF products 시: trg_brand_app_product_status_sync → trg_brand_app_touch
--    (p < t 순 — status 동기화 후 version/updated_at 증가)
--
--    status 동기화가 trg_brand_app_touch 전에 실행되므로
--    version 증가는 정상적으로 1회만 발생한다.
-- ============================================================


-- ============================================================
-- 4. 검증 SQL (적용 후 SQL Editor 에서 실행)
-- ============================================================
/*

-- ──────────────────────────────────────────────
-- [V1] 기존 데이터: 백필 후 status 누락 0건 확인
-- ──────────────────────────────────────────────
SELECT COUNT(*) AS missing_status_after_backfill
FROM public.brand_applications,
     jsonb_array_elements(products) AS elem
WHERE NOT (elem ? 'status');
-- 기대값: 0

-- ──────────────────────────────────────────────
-- [V2] 신청 status vs 제품 대표값 일치 비율
--      (트리거 설치 전 백필된 데이터는 100% 일치해야 함)
-- ──────────────────────────────────────────────
WITH product_max AS (
  SELECT
    ba.id,
    ba.status AS app_status,
    (
      -- products 중 가장 늦은 단계 계산 (rejected 제외)
      SELECT
        CASE
          WHEN BOOL_AND(elem->>'status' = 'rejected') THEN 'rejected'
          ELSE (
            SELECT elem->>'status'
            FROM jsonb_array_elements(ba.products) AS elem
            WHERE elem->>'status' <> 'rejected'
              AND elem ? 'status'
            ORDER BY
              array_position(
                ARRAY['new','reviewing','quoted','paid',
                      'kakao_room_created','orient_sheet_sent',
                      'schedule_sent','campaign_registered','done'],
                elem->>'status'
              ) DESC NULLS LAST
            LIMIT 1
          )
        END
      FROM jsonb_array_elements(ba.products) AS elem
      WHERE elem ? 'status'
    ) AS derived_status
  FROM public.brand_applications AS ba
  WHERE ba.products IS NOT NULL
    AND jsonb_typeof(ba.products) = 'array'
    AND jsonb_array_length(ba.products) > 0
)
SELECT
  COUNT(*)                                             AS total,
  COUNT(*) FILTER (WHERE app_status = derived_status) AS match_count,
  COUNT(*) FILTER (WHERE app_status <> derived_status OR derived_status IS NULL) AS mismatch_count,
  ROUND(
    COUNT(*) FILTER (WHERE app_status = derived_status)::numeric
    / NULLIF(COUNT(*), 0) * 100, 1
  ) AS match_pct
FROM product_max;
-- 백필 직후 기대값: match_pct = 100.0

-- ──────────────────────────────────────────────
-- [V3] 신규 INSERT 단위 테스트 — products[i].status 자동 채움 확인
-- ──────────────────────────────────────────────
-- 아래 INSERT 를 실행하면:
--   1. products[0].status = NULL(키 없음) → 'new' 로 자동 채워져야 함
--   2. NEW.status = 'new' (디폴트) 그대로여야 함
--   (주의: 테스트 후 반드시 DELETE 로 정리)

INSERT INTO public.brand_applications (
  application_no,
  form_type,
  brand_name,
  contact_name,
  phone,
  email,
  products,
  status
) VALUES (
  '',                                          -- 채번 트리거가 자동 생성
  'reviewer',
  '트리거테스트브랜드',
  '홍테스트',
  '090-0000-0001',
  'trigger-test-101@example.com',
  '[{"name":"테스트상품A","price":1000,"qty":2}]',  -- status 키 없음
  'new'
)
RETURNING
  application_no,
  status,
  products;
-- 기대값:
--   application_no = 'JFUN-Q-YYYYMMDD-NNN'
--   status = 'new'
--   products[0].status = 'new' (트리거가 자동 채움)

-- 정리 (실행 후 반드시 삭제)
-- DELETE FROM public.brand_applications WHERE email = 'trigger-test-101@example.com';

-- ──────────────────────────────────────────────
-- [V4] UPDATE 단위 테스트 — products[i].status 변경 시 신청 대표값 동기화 확인
-- ──────────────────────────────────────────────
-- 기존 신청 1건을 선택하여 제품 status 를 변경하고 신청 status 가 동기화되는지 확인.
-- (실제 신청 ID 로 교체 필요)
/*
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(
    CASE
      WHEN idx = 0 THEN elem || '{"status":"quoted"}'::jsonb
      ELSE elem
    END
    ORDER BY idx
  )
  FROM jsonb_array_elements(products) WITH ORDINALITY AS t(elem, idx)
)
WHERE id = '<실제-신청-UUID>'
RETURNING id, status, products;
-- 기대값: status = 'quoted' (제품 중 최대가 quoted 이므로)
*/

-- ──────────────────────────────────────────────
-- [V5] 트리거 등록 확인
-- ──────────────────────────────────────────────
SELECT
  tgname,
  CASE tgtype::integer & 2 WHEN 0 THEN 'AFTER' ELSE 'BEFORE' END AS timing,
  CASE tgtype::integer & 4 WHEN 0 THEN 'FOR EACH STATEMENT' ELSE 'FOR EACH ROW' END AS scope,
  tgenabled,
  pg_get_triggerdef(oid)  AS definition
FROM pg_trigger
WHERE tgrelid = 'public.brand_applications'::regclass
ORDER BY tgname;
-- trg_brand_app_product_status_sync 가 BEFORE, FOR EACH ROW, tgenabled='O' 로 보여야 함

-- ──────────────────────────────────────────────
-- [V6] 다른 컬럼만 UPDATE 시 트리거 미발동 확인 (성능)
-- ──────────────────────────────────────────────
-- admin_memo 만 변경하면 trg_brand_app_product_status_sync 가 발동하지 않아야 한다.
-- (BEFORE UPDATE OF products 이므로 admin_memo UPDATE 는 해당 트리거 범위 밖)
-- trg_brand_app_touch 만 발동하여 version + 1, updated_at 갱신됨을 아래로 확인:
/*
UPDATE public.brand_applications
SET admin_memo = '트리거 미발동 테스트 ' || now()::text
WHERE id = '<실제-신청-UUID>'
RETURNING id, version, updated_at, status, products;
-- 기대값: status, products 변화 없음, version 은 +1
*/

*/


-- ============================================================
-- 롤백 방법
--   트리거와 함수를 제거하면 자동 채움·동기화 기능이 해제된다.
--   이미 채워진 products[i].status 데이터는 그대로 남는다.
--
--   DROP TRIGGER IF EXISTS trg_brand_app_product_status_sync
--     ON public.brand_applications;
--   DROP FUNCTION IF EXISTS public.sync_brand_app_product_status();
-- ============================================================
