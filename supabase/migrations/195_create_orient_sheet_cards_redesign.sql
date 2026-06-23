-- ============================================================
-- 195_create_orient_sheet_cards_redesign.sql
-- 2026-06-23
--
-- 목적:
--   §15-11 "1 링크 다형식·cards 배열" 재설계에 따라 create_orient_sheet 를
--   최소 시그니처(brand_id, application_id)로 재정의한다.
--   - 기존 4인자 함수(192): 카드별 form_type·product 단일 결정 전제. 폐기.
--   - 신규 2인자 함수(195): 발급 시 form_type 미결정. data = brand prefill + 빈 cards 배열.
--     카드 추가·형식 선택은 브랜드가 작성 폼에서 수행.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md
--   §15-11 (1 링크 다형식·cards 배열), §11 (data jsonb 스키마)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 익명 토큰 함수 3종(get/save/submit) 존재
--   192_create_orient_sheet_with_prefill.sql — DROP 대상(4인자)
--   194_orient_redesign_form_type_and_drop_set_type.sql — form_type CHECK 3종, set_orient_form_type DROP
--
-- 변경 내용:
--   [A] DROP FUNCTION public.create_orient_sheet(uuid, uuid, text, integer)  ← 192의 4인자
--   [B] CREATE FUNCTION public.create_orient_sheet(p_brand_id uuid, p_application_id uuid DEFAULT NULL)
--       - 가드: is_admin() — campaign_manager 포함 전체 관리자(190/192 동일)
--       - 브랜드 존재 검증
--       - application_id 연결 시: brand_id 정합 + brand.name(또는 brand_applications.brand_name) prefill
--       - application_id 미연결 시: brands.name 조회해 brand.name prefill
--       - form_type 컬럼 = NULL (cards 배열 안 각 카드가 결정 — §15-11)
--       - data 초기값: {"brand":{"name":"…","intro":"","official_accounts":""},"cards":[]}
--       - INSERT: token·token_expires_at(+30일)·status='draft'·created_by=auth.uid()
--       - 반환: jsonb {success, id, token, token_expires_at}
--
-- 187 함수 3종(get/save/submit) 영향 검토:
--   - data가 jsonb라 cards 구조로 바뀌어도 함수 자체는 data를 투명하게 전달 → 변경 불필요.
--   - initial_values (get_orient_sheet): brand_applications.form_type/total_qty/total_jpy/products 반환.
--     cards 배열 구조에서도 "연결 신청 참고값"으로 유효 → 변경 불필요.
--   ⚠️ 후속 메모:
--     폼 재작성(PR 이후) 시 initial_values.products를 순회해 cards를 초기화하는
--     클라이언트 로직 필요(현재는 cards=[] 빈 배열로 발급, 브랜드가 직접 추가).
--
-- 기존 호출 호환성:
--   storage.js createOrientSheet(brandId, applicationId, formType, productIdx) 함수를
--   신규 2인자(brandId, applicationId)로 맞춰 수정(195와 동시 적용).
--   admin-orient.js 발급 모달 호출부는 폼·관리자 재작성 PR에서 정리.
--
-- 운영 데이터 영향:
--   DROP + CREATE이므로 기존 orient_sheets 행에는 영향 없음.
--   orient_sheets.form_type 컬럼은 여전히 NULL 허용 — 기존 행 유효.
--   개발서버 dev DB 테스트 행 정리: DELETE FROM orient_sheets; (파일 아님, 수동 실행)
--
-- 적용 순서:
--   186 → 187 → 188 → 189 → 190 → 191 → 192 → 193 → 194 → 이 파일(195)
--
-- 롤백:
--   1. DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid);
--   2. 192_create_orient_sheet_with_prefill.sql 을 SQL Editor에서 재실행(BEGIN~COMMIT 전체).
-- ============================================================

BEGIN;


-- ============================================================
-- A. 기존 4인자 함수 제거 (192에서 정의한 함수)
--    PostgREST rpc 오버로드 모호성 방지를 위해 신규 CREATE 전 DROP.
-- ============================================================
DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text, integer);


-- ============================================================
-- B. create_orient_sheet — 2인자 버전(§15-11 재설계)
--    - form_type = NULL: 발급 시 미결정. 카드마다 form_type 결정(data.cards[].form_type).
--    - data 초기값: brand prefill + 빈 cards 배열.
--    - 제품 prefill 없음: 카드 추가·제품 입력은 브랜드가 작성 폼에서 수행(후속 PR).
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_exists  boolean;
  v_app_brand_id  uuid;
  v_brand_name    text;   -- prefill용 브랜드명
  v_new_id        uuid;
  v_new_token     uuid;
  v_expires_at    timestamptz;
  v_init_data     jsonb;
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

  -- ── brand.name prefill 결정 ──────────────────────────────────────────
  -- 우선순위: brand_applications.brand_name(연결 신청 스냅샷) > brands.name(마스터)
  IF p_application_id IS NOT NULL THEN
    -- 연결 신청에서 brand_id 정합 + brand_name 조회
    SELECT ba.brand_id, ba.brand_name
      INTO v_app_brand_id, v_brand_name
      FROM public.brand_applications ba
     WHERE ba.id = p_application_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    -- brand_id 정합 검증
    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object('success', false, 'reason', 'brand_mismatch');
    END IF;

    -- brand_name 이 없으면 brands.name 으로 폴백
    IF v_brand_name IS NULL OR v_brand_name = '' THEN
      SELECT name INTO v_brand_name FROM public.brands WHERE id = p_brand_id;
    END IF;

  ELSE
    -- 신청 미연결: brands.name 조회
    SELECT name INTO v_brand_name FROM public.brands WHERE id = p_brand_id;
  END IF;

  -- ── data 초기값 구성 ─────────────────────────────────────────────────
  -- §15-11 data 구조: {brand:{name,intro,official_accounts}, cards:[]}
  -- cards 는 빈 배열 — 브랜드가 폼에서 카드를 추가(후속 PR)
  v_init_data := jsonb_build_object(
    'brand', jsonb_build_object(
      'name',              COALESCE(v_brand_name, ''),
      'intro',             '',
      'official_accounts', ''
    ),
    'cards', '[]'::jsonb
  );

  -- ── INSERT ────────────────────────────────────────────────────────────
  v_new_id     := gen_random_uuid();
  v_new_token  := gen_random_uuid();
  v_expires_at := now() + interval '30 days';

  INSERT INTO public.orient_sheets (
    id,
    brand_id,
    application_id,
    form_type,        -- NULL: §15-11 재설계 — cards 배열 안 각 카드가 form_type 결정
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
    NULL,             -- form_type 미결정(발급 시), cards[].form_type 이 실질 데이터
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
    'token_expires_at', v_expires_at
  );
END;
$$;

-- 기본 PUBLIC EXECUTE 권한 회수 후 authenticated(관리자)에게만 명시 부여
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid) IS
  '[195] 오리엔시트 발급(§15-11 "1 링크 다형식·cards 배열" 재설계). '
  'is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_brand_id 필수. p_application_id 선택(연결 시 brand_id 정합 + brand_name prefill). '
  'form_type = NULL(카드마다 결정). '
  'data 초기값 = {brand:{name,intro,official_accounts}, cards:[]}. '
  'token_expires_at = now()+30일, status=draft. SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
