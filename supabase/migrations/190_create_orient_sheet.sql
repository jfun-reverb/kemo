-- ============================================================
-- 190_create_orient_sheet.sql
-- 2026-06-19
--
-- 목적:
--   브랜드 셀프 오리엔시트 발급 함수(관리자 전용) 신규 생성.
--   campaign_manager 포함 전체 관리자(is_admin())가 브랜드에게
--   토큰 링크를 발급하는 기능.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §6, §8(PR 3)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 익명 함수 3종 존재
--
-- 변경 내용:
--   [A] create_orient_sheet(p_brand_id, p_application_id, p_form_type) → jsonb
--       - SECURITY DEFINER + SET search_path=''
--       - 가드: is_admin() (campaign_manager 포함 전체 관리자)
--       - brand 존재 검증
--       - application_id 연결 시: 같은 brand_id 정합 검증 + form_type 승계
--       - form_type 결정: COALESCE(p_form_type, 신청.form_type) → NULL 가능
--       - form_type이 NULL 아니면 reviewer/seeding 검증
--       - INSERT: token(DEFAULT gen_random_uuid)·token_expires_at=now()+30일·created_by=auth.uid()·status='draft'
--       - 반환: {success:true, id, token, token_expires_at, form_type}
--       - GRANT TO authenticated (anon 아님)
--
-- RLS 정합:
--   186에서 INSERT 정책은 is_campaign_admin() 이상(WITH CHECK)이나,
--   본 함수는 SECURITY DEFINER라 RLS를 우회해 직접 INSERT한다.
--   is_admin() 가드가 campaign_manager(발급)와 campaign_admin/super_admin(발급+CUD)을
--   모두 포함하므로 186 INSERT 정책의 is_campaign_admin() 요건보다 넓다.
--   사용자 확정(2026-06-19): 발급 권한은 campaign_manager 포함 전체 관리자로 확정.
--   → is_admin() 가드만으로 방어, RLS 정책 변경 불필요
--     (직접 INSERT가 아닌 RPC 경유이므로 INSERT 정책과 무관).
--
-- 운영 데이터 영향:
--   신규 함수이므로 기존 데이터 영향 없음.
--
-- 적용 순서:
--   186 → 187 → 188 → 189 → 이 파일(190)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text);
-- ============================================================

BEGIN;


-- ============================================================
-- A. create_orient_sheet(p_brand_id uuid, p_application_id uuid, p_form_type text)
--    관리자가 브랜드에게 오리엔시트 토큰 링크를 발급하는 함수.
--    - is_admin(): campaign_manager·campaign_admin·super_admin 모두 포함
--    - p_application_id: 신청 연결 선택 (NULL 허용)
--    - p_form_type: 명시 시 우선, 미지정(NULL)+신청 연결이면 신청.form_type 승계
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid    DEFAULT NULL,
  p_form_type       text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_exists   boolean;
  v_app_brand_id   uuid;
  v_app_form_type  text;
  v_resolved_type  text;
  v_new_id         uuid;
  v_new_token      uuid;
  v_expires_at     timestamptz;
BEGIN
  -- 권한 가드: campaign_manager 포함 전체 관리자
  -- is_admin() = admins 테이블에 auth.uid() 행이 존재하는지 검사
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 로그인 필요)' USING ERRCODE = '42501';
  END IF;

  -- 브랜드 존재 검증
  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id)
    INTO v_brand_exists;

  IF NOT v_brand_exists THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_not_found');
  END IF;

  -- application_id 연결 시 검증
  IF p_application_id IS NOT NULL THEN
    -- 신청 행에서 brand_id·form_type 조회
    SELECT brand_id, form_type
      INTO v_app_brand_id, v_app_form_type
      FROM public.brand_applications
     WHERE id = p_application_id;

    -- 신청 행 미존재
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    -- brand_id 정합 검증: 신청의 브랜드와 발급 대상 브랜드가 달라서는 안 됨
    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object(
        'success', false,
        'reason',  'brand_mismatch'
      );
    END IF;

    -- form_type 결정: 명시값(p_form_type) 우선, 미지정이면 신청에서 승계
    v_resolved_type := COALESCE(p_form_type, v_app_form_type);
  ELSE
    -- 신청 미연결: p_form_type 그대로(NULL 가능 — 브랜드가 0단계에서 선택)
    v_resolved_type := p_form_type;
  END IF;

  -- form_type 값 검증 (NULL이면 허용 — 0단계에서 브랜드가 선택)
  IF v_resolved_type IS NOT NULL AND v_resolved_type NOT IN ('reviewer', 'seeding') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_form_type');
  END IF;

  -- INSERT: token·token_expires_at은 DB DEFAULT 또는 여기서 명시 생성
  v_new_id    := gen_random_uuid();
  v_new_token := gen_random_uuid();
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
    '{}',
    0
  );

  RETURN jsonb_build_object(
    'success',         true,
    'id',              v_new_id,
    'token',           v_new_token,
    'token_expires_at', v_expires_at,
    'form_type',       v_resolved_type
  );
END;
$$;

-- 기본 PUBLIC EXECUTE 권한 회수 후 authenticated(관리자)에게만 명시 부여
-- anon에게는 부여하지 않음 — 관리자 전용 발급 함수
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid, text) IS
  '[190] 오리엔시트 발급. is_admin() 가드 — campaign_manager 포함 전체 관리자 호출 가능. '
  'p_brand_id 필수. p_application_id 선택(연결 시 brand_id 정합+form_type 승계). '
  'p_form_type 명시 시 우선, 미지정+신청 연결이면 신청.form_type 승계, 둘 다 없으면 NULL(브랜드 0단계 선택). '
  'token_expires_at = now()+30일, status=draft. '
  'SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
