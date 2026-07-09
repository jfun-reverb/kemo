-- ============================================================
-- 192_create_orient_sheet_with_prefill.sql
-- 2026-06-22
--
-- 목적:
--   create_orient_sheet 함수를 4인자로 재정의해 제품 prefill 기능 추가.
--   기존 3인자 함수(190)를 DROP 후 4인자 단일 정의로 교체.
--   PostgREST rpc 호출 시 인자 개수 차이로 생기는 오버로드 모호성 제거.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §11(data 스키마)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 익명 함수 3종 존재
--   190_create_orient_sheet.sql  — 기존 3인자 함수(DROP 대상)
--
-- 변경 내용:
--   [A] DROP FUNCTION public.create_orient_sheet(uuid, uuid, text)  ← 190의 3인자
--   [B] CREATE FUNCTION public.create_orient_sheet(uuid, uuid, text, integer)
--       인자: p_brand_id, p_application_id DEFAULT NULL,
--             p_form_type DEFAULT NULL, p_product_idx DEFAULT NULL
--       추가 로직:
--         (1) 반려 제품 차단:
--               p_application_id + p_product_idx 있을 때
--               products[p_product_idx].status = 'rejected'이면
--               {success:false, reason:'product_rejected'} 반환.
--         (2) 서버 prefill:
--               p_application_id + p_product_idx 있을 때
--               brand_applications.brand_name → data.brand.name
--               products[idx].name → data.product.name
--               form_type='reviewer'이면:
--                 products[idx].url 있으면 → data.product.urls = [{label:'', value:url}]
--                 products[idx].price 있으면 → data.product.prices = [{label:'', value:price(text)}]
--               form_type='seeding'이면: data.product.name만
--               idx 범위 밖이거나 p_product_idx NULL이면 prefill 생략({} INSERT).
--       나머지 로직(권한·brand 존재·application 정합·form_type 결정·INSERT):
--         190 원본 그대로 보존.
--
-- 기존 호출 호환성:
--   storage.js의 기존 3인자 호출(p_product_idx 생략 → DEFAULT NULL)은
--   4인자 함수에서 p_product_idx=NULL로 처리 → prefill 생략 → 190과 동일 동작.
--
-- 반려 제품 차단 판단:
--   products[i].status 키는 트리거(101)가 INSERT 시 자동 채우므로 원칙상 항상 존재.
--   단, 과거 데이터 등 NULL인 경우는 통과(과잉 차단 방지).
--   brand_applications.status(대표값)는 판정에 사용하지 않음:
--     대표값은 여러 제품 중 "가장 진행된 단계"이므로 1개 제품이 rejected여도
--     대표값이 다른 단계일 수 있어 제품 단위 차단 기준으로 적합하지 않음.
--
-- 운영 데이터 영향:
--   DROP + CREATE이므로 기존 orient_sheets 행에는 영향 없음.
--   관리자 UI에서 호출하는 RPC 시그니처 변경(3인자→4인자 오버로드 제거),
--   storage.js 호출은 p_product_idx 생략 시 NULL 폴백으로 기존 동작 보존.
--
-- 적용 순서:
--   186 → 187 → 188 → 189 → 190 → 191 → 이 파일(192)
--
-- 롤백:
--   1. DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text, integer);
--   2. 190_create_orient_sheet.sql 을 SQL Editor에서 재실행(BEGIN~COMMIT 전체).
-- ============================================================

BEGIN;


-- ============================================================
-- A. 기존 3인자 함수 제거 (190에서 정의한 함수)
--    오버로드 공존 → PostgREST rpc 모호성 문제를 막기 위한 선행 DROP.
-- ============================================================
DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text);


-- ============================================================
-- B. create_orient_sheet — 4인자 버전(prefill + 반려 차단 추가)
--    - p_product_idx: 서베이 products 배열 인덱스 (0-based). DEFAULT NULL.
--    - 나머지 인자 및 핵심 로직은 190 원본 그대로 보존.
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid    DEFAULT NULL,
  p_form_type       text    DEFAULT NULL,
  p_product_idx     integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_exists    boolean;
  v_app_brand_id    uuid;
  v_app_form_type   text;
  v_resolved_type   text;
  v_new_id          uuid;
  v_new_token       uuid;
  v_expires_at      timestamptz;

  -- prefill 관련 변수
  v_products        jsonb;       -- brand_applications.products 배열 전체
  v_product         jsonb;       -- products[p_product_idx] 단일 원소
  v_product_status  text;        -- 해당 제품의 status
  v_brand_name      text;        -- brand_applications.brand_name
  v_prod_name       text;        -- products[idx].name
  v_prod_url        text;        -- products[idx].url
  v_prod_price      text;        -- products[idx].price (텍스트화)
  v_init_data       jsonb;       -- INSERT할 data 초기값
BEGIN
  -- ── 권한 가드: campaign_manager 포함 전체 관리자 ──────────────────────
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 로그인 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 브랜드 존재 검증 ─────────────────────────────────────────────────
  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id)
    INTO v_brand_exists;

  IF NOT v_brand_exists THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_not_found');
  END IF;

  -- ── application_id 연결 시 검증 ──────────────────────────────────────
  IF p_application_id IS NOT NULL THEN
    -- 신청 행에서 brand_id·form_type·brand_name·products 조회
    -- SECURITY DEFINER이므로 RLS 우회, BYPASSRLS 없이 직접 SELECT 가능
    SELECT ba.brand_id,
           ba.form_type,
           ba.brand_name,
           ba.products
      INTO v_app_brand_id,
           v_app_form_type,
           v_brand_name,
           v_products
      FROM public.brand_applications ba
     WHERE ba.id = p_application_id;

    -- 신청 행 미존재
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    -- brand_id 정합 검증
    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object(
        'success', false,
        'reason',  'brand_mismatch'
      );
    END IF;

    -- form_type 결정: 명시값(p_form_type) 우선, 미지정이면 신청에서 승계
    v_resolved_type := COALESCE(p_form_type, v_app_form_type);

    -- ── (1) 반려 제품 차단 ──────────────────────────────────────────────
    -- p_product_idx가 있고, 해당 제품의 status = 'rejected'이면 발급 거부.
    -- products가 NULL이거나 idx 범위 밖이면 차단하지 않음(통과).
    -- products[i].status가 NULL인 경우도 통과(과잉 차단 방지).
    IF p_product_idx IS NOT NULL
       AND v_products IS NOT NULL
       AND jsonb_typeof(v_products) = 'array'
       AND p_product_idx >= 0
       AND p_product_idx < jsonb_array_length(v_products)
    THEN
      v_product        := v_products -> p_product_idx;
      v_product_status := v_product ->> 'status';

      IF v_product_status = 'rejected' THEN
        RETURN jsonb_build_object('success', false, 'reason', 'product_rejected');
      END IF;
    END IF;

  ELSE
    -- 신청 미연결: p_form_type 그대로(NULL 가능 — 브랜드가 0단계에서 선택)
    -- p_product_idx는 신청 미연결이면 무시
    v_resolved_type := p_form_type;
  END IF;

  -- ── form_type 값 검증 (NULL이면 허용 — 0단계에서 브랜드가 선택) ───────
  IF v_resolved_type IS NOT NULL AND v_resolved_type NOT IN ('reviewer', 'seeding') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_form_type');
  END IF;

  -- ── (2) 서버 prefill data 구성 ─────────────────────────────────────────
  -- 조건: application_id 연결 + p_product_idx 있음 + 범위 내 + products 배열 유효
  v_init_data := '{}'::jsonb;

  IF p_application_id IS NOT NULL
     AND p_product_idx IS NOT NULL
     AND v_products IS NOT NULL
     AND jsonb_typeof(v_products) = 'array'
     AND p_product_idx >= 0
     AND p_product_idx < jsonb_array_length(v_products)
  THEN
    -- v_product는 반려 체크 블록에서 이미 추출했을 수 있으나,
    -- 신청 미연결 경로에서 여기에 도달하면 NULL이므로 안전하게 재할당.
    v_product   := v_products -> p_product_idx;
    v_prod_name := v_product ->> 'name';

    -- data.brand 구성: brand_name (brand_applications 의 스냅샷)
    -- data.product 구성: name 공통, urls·prices는 reviewer 전용
    IF v_resolved_type = 'reviewer' THEN
      v_prod_url   := v_product ->> 'url';
      v_prod_price := v_product ->> 'price';  -- 텍스트 그대로 사용

      v_init_data := jsonb_build_object(
        'brand', jsonb_build_object(
          'name', COALESCE(v_brand_name, '')
        ),
        'product', jsonb_build_object(
          'name',   COALESCE(v_prod_name, ''),
          'urls',   CASE
                      WHEN v_prod_url IS NOT NULL AND v_prod_url <> ''
                      THEN jsonb_build_array(
                             jsonb_build_object('label', '', 'value', v_prod_url)
                           )
                      ELSE '[]'::jsonb
                    END,
          'prices', CASE
                      WHEN v_prod_price IS NOT NULL AND v_prod_price <> ''
                      THEN jsonb_build_array(
                             jsonb_build_object('label', '', 'value', v_prod_price)
                           )
                      ELSE '[]'::jsonb
                    END
        )
      );

    ELSIF v_resolved_type = 'seeding' THEN
      -- 시딩: 브랜드명 + 제품명만(urls·prices 매핑 없음)
      v_init_data := jsonb_build_object(
        'brand', jsonb_build_object(
          'name', COALESCE(v_brand_name, '')
        ),
        'product', jsonb_build_object(
          'name', COALESCE(v_prod_name, '')
        )
      );

    ELSE
      -- form_type = NULL (0단계에서 브랜드가 선택 예정):
      -- 제품명·브랜드명은 채우되 urls·prices는 빈 배열(타입 미결정)
      v_init_data := jsonb_build_object(
        'brand', jsonb_build_object(
          'name', COALESCE(v_brand_name, '')
        ),
        'product', jsonb_build_object(
          'name', COALESCE(v_prod_name, '')
        )
      );
    END IF;
  END IF;
  -- p_product_idx 조건 미충족이면 v_init_data = '{}' 그대로 → 190과 동일

  -- ── INSERT ────────────────────────────────────────────────────────────
  v_new_id     := gen_random_uuid();
  v_new_token  := gen_random_uuid();
  v_expires_at := now() + interval '30 days';

  INSERT INTO public.orient_sheets (
    id,
    brand_id,
    application_id,
    form_type,
    token,
    token_expires_at,
    created_by,
    status,
    data,
    version
  ) VALUES (
    v_new_id,
    p_brand_id,
    p_application_id,
    v_resolved_type,
    v_new_token,
    v_expires_at,
    auth.uid(),
    'draft',
    v_init_data,
    0
  );

  RETURN jsonb_build_object(
    'success',          true,
    'id',               v_new_id,
    'token',            v_new_token,
    'token_expires_at', v_expires_at,
    'form_type',        v_resolved_type
  );
END;
$$;

-- 기본 PUBLIC EXECUTE 권한 회수 후 authenticated(관리자)에게만 명시 부여
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, integer) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid, text, integer) IS
  '[192] 오리엔시트 발급(190 확장). is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_brand_id 필수. p_application_id 선택(연결 시 brand_id 정합+form_type 승계). '
  'p_form_type 명시 시 우선, 미지정+신청 연결이면 신청.form_type 승계, 둘 다 없으면 NULL. '
  'p_product_idx 지정 시: ①products[idx].status=rejected이면 {success:false, reason:product_rejected} '
  '②brand_name·제품name을 data에 prefill, reviewer이면 urls·prices도 채움. '
  'token_expires_at = now()+30일, status=draft. SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
