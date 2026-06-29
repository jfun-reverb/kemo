-- ============================================================
-- 186_orient_sheets_table.sql
-- 2026-06-18
--
-- 목적:
--   브랜드 셀프 오리엔시트 전용 테이블 신규 생성.
--   브랜드사(광고주)에게 토큰 링크를 보내 로그인 없이 캠페인 콘텐츠
--   정보(오리엔시트)를 작성·제출하게 하는 기능의 데이터 모델 기반.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §4, §8(PR 1)
--
-- 변경 내용:
--   [A] orient_sheets 테이블 신규 생성
--       - brands.id 기준(brand_id 필수 NOT NULL)
--       - brand_applications.id 선택 연결(application_id NULL 허용)
--       - 토큰(token): UUID UNIQUE — 로그인 없는 작성 링크 식별자
--       - data jsonb: 오리엔시트 전체 내용(작성 폼 필드 전체)
--       - status: draft(작성중) → submitted(브랜드 제출) → consumed(캠페인 발행됨) | expired(만료)
--       - version: 낙관적 락(동시 편집 충돌 감지)
--       - token_expires_at: 발급 +30일 (NULL이면 만료 없음)
--       - campaign_id: 발행 후 1:1 역참조(소비 완료 후 관리자가 채움)
--
--   [B] 인덱스
--       - token UNIQUE 인덱스
--       - brand_id, application_id, status, campaign_id 보조 인덱스
--
--   [C] 행 단위 보안 정책(RLS)
--       - SELECT: is_admin() 이상 (관리자 전체 조회)
--       - INSERT: is_campaign_admin() 이상 (발급 권한)
--       - UPDATE: is_campaign_admin() 이상 (상태 변경·소비 처리)
--       - DELETE: is_super_admin() 이상 (운영 긴급 시만)
--       - 익명(anon)은 테이블 직접 접근 0 — 187의 토큰 함수로만 접근
--
-- 행 단위 보안 정책 관련:
--   is_admin() / is_campaign_admin() / is_super_admin() 함수는 기존 정의 사용.
--   anon은 이 테이블에 어떤 정책도 없어 완전 차단.
--
-- 운영 데이터 영향:
--   신규 테이블이므로 기존 데이터 영향 없음.
--
-- 적용 순서:
--   1. 이 파일(186) 먼저 적용
--   2. 187_orient_sheets_functions.sql 적용
--
-- 롤백:
--   DROP TABLE IF EXISTS public.orient_sheets CASCADE;
-- ============================================================

BEGIN;


-- ============================================================
-- A. orient_sheets 테이블 신규 생성
-- ============================================================
CREATE TABLE IF NOT EXISTS public.orient_sheets (
  id               uuid        NOT NULL DEFAULT gen_random_uuid(),
  -- ON DELETE RESTRICT 명시: 오리엔시트가 남아 있으면 브랜드 삭제 차단(발행된 오리엔시트 이력 보호).
  --   ⚠️ PR 3에서 delete_brand RPC(마이그레이션 174)에 orient_sheets 카운트 체크를 추가해야
  --      "연결 0건만 삭제" 가드가 이 외래 키와 정합. (현재 delete_brand는 orient_sheets를 세지 않음)
  brand_id         uuid        NOT NULL REFERENCES public.brands(id) ON DELETE RESTRICT,
  application_id   uuid        NULL     REFERENCES public.brand_applications(id) ON DELETE SET NULL,
  token            uuid        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  form_type        text        NULL
                   CHECK (form_type IS NULL OR form_type IN ('reviewer', 'seeding')),
  data             jsonb       NOT NULL DEFAULT '{}',
  status           text        NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft', 'submitted', 'consumed', 'expired')),
  campaign_id      uuid        NULL     REFERENCES public.campaigns(id) ON DELETE SET NULL,
  token_expires_at timestamptz NULL,
  submitted_at     timestamptz NULL,
  consumed_at      timestamptz NULL,
  version          integer     NOT NULL DEFAULT 0,
  created_by       uuid        NULL     REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT orient_sheets_pkey PRIMARY KEY (id)
);

COMMENT ON TABLE public.orient_sheets IS
  '[186] 브랜드 셀프 오리엔시트 전용 테이블. '
  '브랜드사가 토큰 링크로 캠페인 콘텐츠 정보를 작성·제출하는 기능의 데이터 저장소. '
  '1장 = 제품 1개 = 모집 건 1개(1:1). 익명(anon)은 토큰 함수로만 접근.';

COMMENT ON COLUMN public.orient_sheets.id              IS '[186] 행 기본 키 (UUID v4).';
COMMENT ON COLUMN public.orient_sheets.brand_id        IS '[186] 브랜드 마스터(brands.id) 참조. 오리엔시트는 브랜드 기준으로 발급.';
COMMENT ON COLUMN public.orient_sheets.application_id  IS '[186] 광고주 신청(brand_applications.id) 선택 연결. NULL이면 신청 없이 생성.';
COMMENT ON COLUMN public.orient_sheets.token           IS '[186] 로그인 없는 작성 링크 식별자(UUID v4). 브랜드 담당자에게 전달하는 토큰. UNIQUE 보장.';
COMMENT ON COLUMN public.orient_sheets.form_type       IS '[186] reviewer | seeding. 신청 연결 건은 신청서에서 승계, 미연결 건은 관리자가 지정.';
COMMENT ON COLUMN public.orient_sheets.data            IS '[186] 오리엔시트 전체 입력 내용 (모집정보·브랜드정보·제품정보·채널가이드 등). 브라우저 폼 구조 그대로 저장.';
COMMENT ON COLUMN public.orient_sheets.status          IS '[186] 상태 전이: draft(작성중) → submitted(브랜드 제출) → consumed(캠페인 발행됨) | expired(만료).';
COMMENT ON COLUMN public.orient_sheets.campaign_id     IS '[186] 발행 완료 후 연결된 캠페인(campaigns.id). mark_orient_consumed RPC가 채움.';
COMMENT ON COLUMN public.orient_sheets.token_expires_at IS '[186] 토큰 만료 시각. 발급 시 +30일로 설정 권장. NULL이면 만료 없음.';
COMMENT ON COLUMN public.orient_sheets.submitted_at    IS '[186] 브랜드가 제출(submit_orient_sheet)한 시각. status=submitted 전이 시 기록.';
COMMENT ON COLUMN public.orient_sheets.consumed_at     IS '[186] 관리자가 캠페인 발행(mark_orient_consumed)한 시각. status=consumed 전이 시 기록.';
COMMENT ON COLUMN public.orient_sheets.version         IS '[186] 낙관적 락 버전. 저장·제출 시 일치해야 함. 불일치 시 충돌 반환.';
COMMENT ON COLUMN public.orient_sheets.created_by      IS '[186] 이 오리엔시트 링크를 발급한 관리자(auth.users.id).';
COMMENT ON COLUMN public.orient_sheets.created_at      IS '[186] 레코드 생성 시각.';
COMMENT ON COLUMN public.orient_sheets.updated_at      IS '[186] 마지막 수정 시각. 저장·제출·소비 시 갱신.';


-- ============================================================
-- B. 인덱스
--   - token은 CREATE TABLE의 UNIQUE 제약으로 이미 인덱스 생성됨
--   - 나머지는 조회 성능용 보조 인덱스
-- ============================================================

-- brand_id: 브랜드별 오리엔시트 목록 조회
CREATE INDEX IF NOT EXISTS idx_orient_sheets_brand_id
  ON public.orient_sheets (brand_id);

-- application_id: 신청 연결 건 조회 (NULL 포함)
CREATE INDEX IF NOT EXISTS idx_orient_sheets_application_id
  ON public.orient_sheets (application_id)
  WHERE application_id IS NOT NULL;

-- status: 상태별 필터링 (draft/submitted 등 관리 목록)
CREATE INDEX IF NOT EXISTS idx_orient_sheets_status
  ON public.orient_sheets (status);

-- campaign_id: 발행된 캠페인에서 역참조
CREATE INDEX IF NOT EXISTS idx_orient_sheets_campaign_id
  ON public.orient_sheets (campaign_id)
  WHERE campaign_id IS NOT NULL;


-- ============================================================
-- C. 행 단위 보안 정책(RLS) 활성화 및 정책 등록
--   익명(anon)에게는 어떠한 정책도 부여하지 않음 → 완전 차단.
--   익명 접근은 오직 187의 토큰 함수(SECURITY DEFINER)로만.
-- ============================================================
ALTER TABLE public.orient_sheets ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자 전체 조회 (campaign_manager 이상)
CREATE POLICY "orient_sheets_select_admin"
  ON public.orient_sheets
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: campaign_admin 이상만 오리엔시트 발급 가능
CREATE POLICY "orient_sheets_insert_campaign_admin"
  ON public.orient_sheets
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_campaign_admin());

-- UPDATE: campaign_admin 이상만 상태 변경·소비 처리 가능
CREATE POLICY "orient_sheets_update_campaign_admin"
  ON public.orient_sheets
  FOR UPDATE
  TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

-- DELETE: super_admin 한정 (운영 긴급 삭제만)
CREATE POLICY "orient_sheets_delete_super_admin"
  ON public.orient_sheets
  FOR DELETE
  TO authenticated
  USING (public.is_super_admin());


-- ============================================================
-- D. updated_at 자동 갱신 트리거
--   기존 테이블(admin_notices·deliverables·brand_applications 등)과 동일하게
--   BEFORE UPDATE 트리거로 updated_at을 자동 갱신한다(테이블별 touch 함수 패턴).
--   이로써 187 익명 함수에서 updated_at을 수동 SET 하지 않아도 일관 갱신.
-- ============================================================
CREATE OR REPLACE FUNCTION public.touch_orient_sheets_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- 트리거 함수는 트리거로만 발동(직접 EXECUTE 불필요) → PUBLIC EXECUTE 회수
REVOKE ALL ON FUNCTION public.touch_orient_sheets_updated_at() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_orient_sheets_updated_at ON public.orient_sheets;
CREATE TRIGGER trg_orient_sheets_updated_at
  BEFORE UPDATE ON public.orient_sheets
  FOR EACH ROW EXECUTE FUNCTION public.touch_orient_sheets_updated_at();


-- PostgREST 스키마 캐시 재로드 (186 단독 적용 시에도 새 테이블 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;
