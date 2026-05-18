-- ============================================================
-- 129_remove_post_deadline.sql
-- 2026-05-18
--
-- 목적:
--   campaigns.post_deadline 컬럼 완전 제거.
--   자동 비노출(post_deadline 경과 시) 동작을 폐기하고
--   운영자 「캠페인 노출」 토글 ON/OFF 로 수동 제어하는 모델로 전환.
--
-- 사양서: docs/specs/2026-05-13-campaign-visibility-toggle.md
--
-- 사전 결정 사항 (사용자 확인 완료):
--   1. 097 (status 5단계 재설계) 은 운영 DB 에 이미 적용된 상태 — 별도 작업 없음
--   2. expired 35건 (운영 DB) 은 그대로 보존 — 자연 상태 복귀 UPDATE 실행 안 함
--   3. submission_end NULL 백필 안 함 (35건 모두 expired 라 인플 화면 비노출 유지)
--
-- 변경 내용:
--   [단계 1] 의존 함수 재정의 — get_brand_ops_detail
--            120 마이그레이션의 함수가 post_deadline 컬럼을 SELECT 함.
--            컬럼 DROP 전에 함수에서 해당 항목 제거 필수.
--   [단계 2] campaigns.post_deadline 컬럼 DROP
--            (의존성 없으므로 CASCADE 불필요)
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 컬럼 부재 확인
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'campaigns' AND column_name = 'post_deadline';
--   -- 기대값: 0 row
--
--   -- [2] 함수 정상 동작 확인 (운영 현황 페인 회귀 방지)
--   SELECT count(*) FROM public.get_brand_ops_overview(NULL);
--   -- 기대값: 에러 없이 행 수 반환
--
--   -- [3] expired 캠페인 그대로 유지됐는지 확인 (운영=35건)
--   SELECT status, count(*) FROM public.campaigns GROUP BY status ORDER BY status;
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;


-- ============================================================
-- 단계 1: 의존 함수 재정의 — get_brand_ops_detail
--   변경점:
--     campaigns 서브쿼리 2곳에서 'post_deadline', c.post_deadline 항목 제거.
--     반환 jsonb 구조의 campaigns 배열 항목 수: 11 → 10.
--     클라이언트가 post_deadline 키 부재를 허용하도록 코드도 함께 수정됨
--     (dev/js/admin-brand.js 의 브랜드 상세 페인 렌더 부분).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_brand_ops_detail(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand        public.brands%ROWTYPE;
  v_company      jsonb;
  v_applications jsonb;
  v_external_camps jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_brand FROM public.brands WHERE id = p_brand_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'brand_not_found' USING ERRCODE = '22023';
  END IF;

  -- 소속 회사 (선택)
  IF v_brand.company_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id',       co.id,
             'name_ko',  co.name_ko,
             'name_ja',  co.name_ja
           )
      INTO v_company
      FROM public.companies co
     WHERE co.id = v_brand.company_id;
  ELSE
    v_company := NULL;
  END IF;

  -- 신청 목록 (신청 내부에 캠페인 배열)
  SELECT COALESCE(jsonb_agg(app_row ORDER BY app_row->>'created_at' DESC), '[]'::jsonb)
    INTO v_applications
    FROM (
      SELECT jsonb_build_object(
               'id',               ba.id,
               'application_no',   ba.application_no,
               'form_type',        ba.form_type,
               'status',           ba.status,
               'final_quote_krw',  ba.final_quote_krw,
               'estimated_krw',    ba.estimated_krw,
               'created_at',       ba.created_at,
               'updated_at',       ba.updated_at,
               'campaigns',        (
                 SELECT COALESCE(jsonb_agg(jsonb_build_object(
                          'id',           c.id,
                          'campaign_no',  c.campaign_no,
                          'title',        c.title,
                          'brand_ko',     c.brand_ko,
                          'product_ko',   c.product_ko,
                          'status',       c.status,
                          'recruit_type', c.recruit_type,
                          'slots',        c.slots,
                          'deadline',     c.deadline,
                          'updated_at',   c.updated_at
                        ) ORDER BY c.created_at), '[]'::jsonb)
                 FROM public.campaigns c
                 WHERE c.source_application_id = ba.id
               )
             ) AS app_row
        FROM public.brand_applications ba
       WHERE ba.brand_id = p_brand_id
    ) sub;

  -- 외부 캠페인 (source_application_id IS NULL, brand 직접 등록)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id',           c.id,
           'campaign_no',  c.campaign_no,
           'title',        c.title,
           'brand_ko',     c.brand_ko,
           'product_ko',   c.product_ko,
           'status',       c.status,
           'recruit_type', c.recruit_type,
           'slots',        c.slots,
           'deadline',     c.deadline,
           'updated_at',   c.updated_at
         ) ORDER BY c.created_at), '[]'::jsonb)
    INTO v_external_camps
    FROM public.campaigns c
   WHERE c.brand_id = p_brand_id
     AND c.source_application_id IS NULL;

  RETURN jsonb_build_object(
    'brand', jsonb_build_object(
      'id',         v_brand.id,
      'brand_seq',  v_brand.brand_seq,
      'brand_no',   v_brand.brand_no,
      'name',       v_brand.name,
      'name_ja',    v_brand.name_ja,
      'company_id', v_brand.company_id,
      'updated_at', v_brand.updated_at
    ),
    'company',          v_company,
    'applications',     v_applications,
    'external_campaigns', v_external_camps
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_ops_detail(uuid) IS
  '[120 → 129] 브랜드 상세 페인용 — 신청 + 각 신청의 캠페인 + 외부 캠페인을 jsonb 통합 반환. is_admin() 가드. 129에서 post_deadline 항목 제거.';


-- ============================================================
-- 단계 2: campaigns.post_deadline 컬럼 DROP
--   의존성: get_brand_ops_detail 함수만 단계 1에서 재정의 완료.
--   그 외 트리거·뷰·외래 키 의존성 없음 (사전 점검 완료).
-- ============================================================

ALTER TABLE public.campaigns DROP COLUMN IF EXISTS post_deadline;


COMMIT;


-- ============================================================
-- 검증 NOTICE (트랜잭션 외부 — SQL Editor 에서 실행 결과 확인용)
-- ============================================================
DO $$
BEGIN
  RAISE NOTICE '[129] post_deadline 컬럼 DROP 완료';
  RAISE NOTICE '[129] get_brand_ops_detail 함수 재정의 완료 (post_deadline 항목 제거)';
END;
$$;


-- ============================================================
-- 롤백 (적용 취소 시 아래 실행)
-- 주의:
--   - post_deadline 컬럼의 옛 데이터는 복구 불가 (운영 적용 전 백업 권장)
--   - 함수만 원복하고 컬럼은 새로 추가 (기본값 NULL)
-- ============================================================
/*

BEGIN;

-- [1] 컬럼 재추가 (기본값 NULL)
ALTER TABLE public.campaigns ADD COLUMN IF NOT EXISTS post_deadline date;

-- [2] get_brand_ops_detail 함수 원복 (120 정의)
--   120 마이그레이션 파일 201~310행 그대로 재실행

COMMIT;

*/
