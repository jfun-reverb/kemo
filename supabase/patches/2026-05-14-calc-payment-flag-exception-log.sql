-- ============================================================
-- 2026-05-14-calc-payment-flag-exception-log.sql
-- calc_brand_app_product_payment_flag 함수 EXCEPTION 로그 노출
--
-- 배경:
--   2026-05-14 sales 폼에서 들어온 B0049-A001 신청의 products[0] 가
--   transfer_fee_krw=2500 인데 payment_flags.transfer=false 로 저장됨.
--   원인 진단 중 calc_brand_app_product_payment_flag 함수의 EXCEPTION
--   WHEN OTHERS catch-all 이 silent 하게 false 4개를 반환하는 것이
--   확인됨. 다른 운영 행과 anon RPC 재현 시도는 모두 정상 동작.
--
--   추측 원인은 클라이언트 jsonb 안에 보이지 않는 특수 문자(​ 등)
--   가 transfer_fee_krw 값에 섞여 numeric 캐스팅 실패. 그러나 행 삭제
--   후 재현 불가.
--
-- 변경:
--   EXCEPTION WHEN OTHERS 블록에 RAISE WARNING 1줄 추가 →
--   SQLERRM + 입력 p_item 을 Supabase 로그에 기록. silent fallback 유지
--   (트리거 실행 자체는 깨지지 않음).
--
-- 함수 시그니처·반환 타입·LANGUAGE·STABLE·search_path 변경 없음.
-- CREATE OR REPLACE FUNCTION 이라 멱등.
--
-- 적용 순서:
--   1. 개발 DB (qysmxtipobomefudyixw) SQL Editor 에서 실행
--   2. 정상 적용 확인 후 운영 DB (twofagomeizrtkwlhsuv) 에 동일 실행
--
-- ROLLBACK:
--   원래 함수 본문 (117_brand_app_product_payment_flags.sql) 의
--   CREATE OR REPLACE FUNCTION 부분을 다시 실행하면 됨.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.calc_brand_app_product_payment_flag(p_item jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  v_qty      numeric;
  v_recruit  numeric;
  v_product  numeric;
  v_transfer numeric;
BEGIN
  v_qty      := COALESCE(NULLIF(p_item->>'qty',              '')::numeric, 0);
  v_recruit  := COALESCE(NULLIF(p_item->>'recruit_fee_krw',  '')::numeric, 0);
  v_product  := COALESCE(NULLIF(p_item->>'price',            '')::numeric, 0);
  v_transfer := COALESCE(NULLIF(p_item->>'transfer_fee_krw', '')::numeric, 0);

  RETURN jsonb_build_object(
    'recruit',  (v_qty * v_recruit)  > 0,
    'product',  (v_qty * v_product)  > 0,
    'transfer', (v_qty * v_transfer) > 0,
    'free',     false
  );
EXCEPTION
  WHEN OTHERS THEN
    -- 2026-05-14: silent false fallback 이 진단 어렵게 만든 사례 발생.
    -- 동작 자체는 유지(false 4개 반환)하되 SQLERRM + 입력을 로그에 노출.
    RAISE WARNING 'calc_brand_app_product_payment_flag fallback: % (SQLSTATE=%, input=%)',
      SQLERRM, SQLSTATE, p_item;
    RETURN jsonb_build_object(
      'recruit',  false,
      'product',  false,
      'transfer', false,
      'free',     false
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ============================================================
-- 검증 SQL (적용 후 별도 실행)
-- ============================================================
/*

-- [V1] 함수 본문에 RAISE WARNING 포함 확인
SELECT pg_get_functiondef(oid) LIKE '%RAISE WARNING%'
  FROM pg_proc
 WHERE proname='calc_brand_app_product_payment_flag'
   AND pronamespace='public'::regnamespace;

-- [V2] 정상 입력 — 동작 변화 없음(여전히 transfer=true)
SELECT public.calc_brand_app_product_payment_flag(
  '{"qty":10,"price":1000,"transfer_fee_krw":2500}'::jsonb
);
-- 기대: {"free":false,"product":true,"recruit":false,"transfer":true}

-- [V3] 예외 유발 입력 — WARNING 발생 + false 4개 반환
SELECT public.calc_brand_app_product_payment_flag(
  '{"qty":"abc","price":1000,"transfer_fee_krw":2500}'::jsonb
);
-- 기대: {"free":false,"product":false,"recruit":false,"transfer":false}
-- 동시에 메시지 패널에 WARNING 'calc_brand_app_product_payment_flag fallback: invalid input syntax for type numeric: "abc" ...' 표시

*/


-- ============================================================
-- ROLLBACK SQL (필요 시)
-- ============================================================
/*

BEGIN;

CREATE OR REPLACE FUNCTION public.calc_brand_app_product_payment_flag(p_item jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  v_qty      numeric;
  v_recruit  numeric;
  v_product  numeric;
  v_transfer numeric;
BEGIN
  v_qty      := COALESCE(NULLIF(p_item->>'qty',              '')::numeric, 0);
  v_recruit  := COALESCE(NULLIF(p_item->>'recruit_fee_krw',  '')::numeric, 0);
  v_product  := COALESCE(NULLIF(p_item->>'price',            '')::numeric, 0);
  v_transfer := COALESCE(NULLIF(p_item->>'transfer_fee_krw', '')::numeric, 0);

  RETURN jsonb_build_object(
    'recruit',  (v_qty * v_recruit)  > 0,
    'product',  (v_qty * v_product)  > 0,
    'transfer', (v_qty * v_transfer) > 0,
    'free',     false
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('recruit', false, 'product', false, 'transfer', false, 'free', false);
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;

*/
