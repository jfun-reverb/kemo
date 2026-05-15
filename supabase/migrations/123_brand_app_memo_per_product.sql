-- ============================================================
-- 123_brand_app_memo_per_product.sql
-- 브랜드 서베이 다중 메모를 제품별로 확장
--
-- 배경:
--   080 에서 brand_application_memos (신청 단위 multi-entry) 도입.
--   122 에서 brand_applications.admin_memo (단일) → products[i].admin_memo (제품별 단일) 이전.
--   이제 운영의 multi-entry 패턴을 제품별로 확장 — 각 제품마다 N개 메모.
--
-- 변경 범위:
--   (1) brand_application_memos.product_idx integer NOT NULL DEFAULT 0 컬럼 추가
--       (광고주 신청은 제품 순서 변경 기능이 없어 idx 사용 안전 — 기획 결정)
--   (2) (application_id, product_idx, created_at DESC) 인덱스 추가
--   (3) record_brand_application_memo_history() 트리거 함수 갱신:
--       new_value / old_value jsonb 에 product_idx 키 추가
--       → 변경 이력 모달에서 "[제품 N] 메모 추가/수정/삭제" 표시 가능
--   (4) 백필: 122 의 products[i].admin_memo 단일 텍스트 → brand_application_memos INSERT
--       각 admin_memo 키가 있는 product 마다 1 row (product_idx=i, author_name='(legacy)')
--   (5) 백필 후: products 배열에서 admin_memo 키 제거 (이중 출처 정리)
--
-- 운영 DB 적용 가이드:
--   운영 DB 는 마이그레이션 122 미적용 상태 (admin_memo 컬럼 그대로).
--   운영 DB 적용 순서:
--     a. 122 먼저 실행 (admin_memo → products[0].admin_memo 백필 + 컬럼 DROP + 트리거/RPC 갱신)
--     b. 이어서 123 실행 (이 파일)
--   양 마이그레이션 모두 멱등(idempotent). SQL Editor 한 세션에서 차례로 붙여넣기.
--
-- 사양서: docs/specs/2026-05-13-brand-app-product-admin-memo.md
-- 작성일: 2026-05-14
-- ============================================================


-- ============================================================
-- SECTION 1. brand_application_memos.product_idx 컬럼 추가
-- ============================================================
ALTER TABLE public.brand_application_memos
  ADD COLUMN IF NOT EXISTS product_idx integer NOT NULL DEFAULT 0
    CHECK (product_idx >= 0 AND product_idx < 100);

COMMENT ON COLUMN public.brand_application_memos.product_idx IS
  '[123] 메모가 가리키는 제품 인덱스 (brand_applications.products 배열 순번). 기존 행은 DEFAULT 0 (제품 1번)으로 백필됨. 제품 순서 변경 기능 도입 시 안정적 키로 마이그레이션 필요.';


-- ============================================================
-- SECTION 2. (application_id, product_idx, created_at DESC) 인덱스
--   모달이 (app_id, product_idx) 페어로 필터링 + 최신순 정렬용
-- ============================================================
CREATE INDEX IF NOT EXISTS brand_application_memos_app_product_created_idx
  ON public.brand_application_memos (application_id, product_idx, created_at DESC);

-- 기존 (application_id, created_at DESC) 인덱스(080)는 신청 단위 조회에 여전히 필요
-- → 제거하지 않음 (변경 이력 모달의 시간순 통합 조회용)


-- ============================================================
-- SECTION 3. record_brand_application_memo_history() 트리거 함수 갱신
--   new_value / old_value jsonb 에 product_idx 키 추가
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_brand_application_memo_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_actor_id   uuid;
  v_actor_name text;
  v_app_id     uuid;
BEGIN
  v_actor_id := auth.uid();

  IF v_actor_id IS NOT NULL THEN
    SELECT name INTO v_actor_name
    FROM public.admins
    WHERE auth_id = v_actor_id
    LIMIT 1;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_app_id := OLD.application_id;
  ELSE
    v_app_id := NEW.application_id;
  END IF;

  -- INSERT → memo_added
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES (
      v_app_id,
      v_actor_id,
      v_actor_name,
      'memo_added',
      NULL,
      jsonb_build_object(
        'id',          NEW.id,
        'text',        NEW.text,
        'author_id',   NEW.author_id,
        'author_name', NEW.author_name,
        'product_idx', NEW.product_idx,
        'created_at',  NEW.created_at
      )
    );

  -- UPDATE → text 변경 시에만 memo_edited
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.text IS DISTINCT FROM OLD.text THEN
      INSERT INTO public.brand_application_history
        (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
      VALUES (
        v_app_id,
        v_actor_id,
        v_actor_name,
        'memo_edited',
        jsonb_build_object(
          'id',          OLD.id,
          'text',        OLD.text,
          'author_id',   OLD.author_id,
          'author_name', OLD.author_name,
          'product_idx', OLD.product_idx,
          'updated_at',  OLD.updated_at
        ),
        jsonb_build_object(
          'id',          NEW.id,
          'text',        NEW.text,
          'author_id',   NEW.author_id,
          'author_name', NEW.author_name,
          'product_idx', NEW.product_idx,
          'updated_at',  NEW.updated_at
        )
      );
    END IF;

  -- DELETE → memo_deleted
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES (
      v_app_id,
      v_actor_id,
      v_actor_name,
      'memo_deleted',
      jsonb_build_object(
        'id',          OLD.id,
        'text',        OLD.text,
        'author_id',   OLD.author_id,
        'author_name', OLD.author_name,
        'product_idx', OLD.product_idx,
        'created_at',  OLD.created_at
      ),
      NULL
    );
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.record_brand_application_memo_history IS
  '[081+123] brand_application_memos AFTER INSERT/UPDATE/DELETE 트리거. memo_added/memo_edited/memo_deleted 행을 brand_application_history 에 자동 기록. 123: jsonb 페이로드에 product_idx 추가.';

-- 트리거 자체는 081 에서 이미 바인딩 — 함수만 재정의하면 동작 갱신됨


-- ============================================================
-- SECTION 4. products[i].admin_memo → brand_application_memos 백필
--   122 적용된 환경: products jsonb 안의 admin_memo 키들을 brand_application_memos 로 이전.
--   122 미적용 환경(운영): products[i].admin_memo 가 없으므로 백필 0건 (멱등).
--
--   백필 INSERT 는 SECTION 3 갱신된 트리거를 거치며 history 행도 자동 기록되지만
--   author_id=NULL 이라 변경자 불명으로 기록됨 — legacy 데이터 흔적.
--
--   created_at 타임스탬프 정책 (080 legacy 마이그레이션과 동일):
--     COALESCE(brand_applications.updated_at, .created_at, now())
--     → 메모 작성 시점이 아닌 신청서 최종 수정 시점 근사. now() 보다 의미 있음
--     (마이그레이션 적용 시각으로 일괄 찍히면 "방금 만든 메모" 처럼 오해 가능).
-- ============================================================
INSERT INTO public.brand_application_memos
  (application_id, author_id, author_name, text, product_idx, created_at, updated_at)
SELECT
  b.id,
  NULL,
  '(legacy)',
  elem->>'admin_memo',
  ordinality::integer - 1,    -- jsonb_array_elements WITH ORDINALITY 는 1-base → 0-base 변환
  COALESCE(b.updated_at, b.created_at, now()),
  COALESCE(b.updated_at, b.created_at, now())
FROM public.brand_applications b,
     LATERAL jsonb_array_elements(b.products) WITH ORDINALITY AS arr(elem, ordinality)
WHERE elem ? 'admin_memo'
  AND elem->>'admin_memo' IS NOT NULL
  AND trim(elem->>'admin_memo') <> '';


-- ============================================================
-- SECTION 5. products 배열에서 admin_memo 키 제거 (이중 출처 정리)
--   백필 후 products[i].admin_memo 는 더 이상 신뢰 소스 아님.
--   brand_application_memos 가 유일한 메모 저장소.
--
--   ⚠ products UPDATE 는 record_brand_application_history (079+122) 트리거를 발화시켜
--     brand_application_history 에 field_name='products' 행 1건이 추가로 INSERT 됨.
--     변경 이력 모달에서 "메타 정리" 성격의 행으로 노출됨 — 의미 없는 노이즈로 보일 수 있으나
--     트리거 무력화 없이 진행 (트리거 일관성·감사 무결성 우선).
-- ============================================================
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(elem - 'admin_memo' ORDER BY ord)
  FROM jsonb_array_elements(products) WITH ORDINALITY AS arr(elem, ord)
)
WHERE products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(products) AS elem2
    WHERE elem2 ? 'admin_memo'
  );

-- 운영 DB 에는 products[i].admin_memo 가 없으므로 WHERE 절이 0건 — 안전


-- ============================================================
-- SECTION 6. PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (개발/운영 DB 적용 후 SQL Editor 에서 실행)
-- ============================================================
/*

-- [V1] product_idx 컬럼 존재 확인
SELECT column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name='brand_application_memos'
  AND column_name='product_idx';
-- product_idx | integer | 0 | NO

-- [V2] 새 인덱스 존재 확인
SELECT indexname
FROM pg_indexes
WHERE tablename='brand_application_memos'
  AND indexname='brand_application_memos_app_product_created_idx';
-- 1행 반환되어야 함

-- [V3] 트리거 함수 갱신 확인 (product_idx 키 포함되어야 함)
SELECT CASE WHEN prosrc LIKE '%product_idx%' THEN 1 ELSE 0 END AS trigger_has_product_idx
FROM pg_proc
WHERE proname='record_brand_application_memo_history'
  AND pronamespace='public'::regnamespace;
-- 1

-- [V4] products[i].admin_memo 키 제거 확인 (0 이어야 함)
SELECT COUNT(*) AS rows_with_product_admin_memo
FROM public.brand_applications b,
     LATERAL jsonb_array_elements(b.products) AS elem
WHERE elem ? 'admin_memo';
-- 0

-- [V5] 백필된 메모 행 개수 (개발 DB 기대: 14 — 마이그레이션 122 V0-COUNT 결과와 일치)
SELECT COUNT(*) AS backfilled_legacy_memos
FROM public.brand_application_memos
WHERE author_name='(legacy)'
  AND created_at >= (now() - interval '1 hour');   -- 방금 백필된 행
-- 14 (개발), 운영은 0 또는 운영 admin_memo 보유 건수

-- [V6] 백필 결과 샘플 5건
SELECT id, application_id, product_idx, author_name, left(text, 60) AS text_preview, created_at
FROM public.brand_application_memos
WHERE author_name='(legacy)'
ORDER BY created_at DESC
LIMIT 5;

-- [V7] memo_added 히스토리 행에 product_idx 포함 확인 (방금 백필이 트리거 거쳤다면 14건)
SELECT COUNT(*) AS memo_added_history_rows
FROM public.brand_application_history
WHERE field_name='memo_added'
  AND new_value ? 'product_idx'
  AND changed_at >= (now() - interval '1 hour');
-- 14 (개발), 운영은 0 또는 운영 admin_memo 보유 건수

*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

-- 1. legacy 백필 메모 행 삭제 (이번 마이그레이션에서 INSERT 된 것)
DELETE FROM public.brand_application_memos
WHERE author_name='(legacy)'
  AND created_at >= '(마이그레이션 적용 시각 직전)'::timestamptz;

-- 2. products[i].admin_memo 복구 (brand_application_memos 의 product_idx=0 최신 메모만 복구)
--    주의: 메모 N개 누적된 행은 가장 최신 1건만 복구. 완전 복구 불가능
UPDATE public.brand_applications b
SET products = (
  SELECT jsonb_agg(
    CASE
      WHEN ord - 1 = m.product_idx THEN
        elem || jsonb_build_object('admin_memo', m.text)
      ELSE elem
    END
    ORDER BY ord
  )
  FROM jsonb_array_elements(b.products) WITH ORDINALITY AS arr(elem, ord)
  LEFT JOIN LATERAL (
    SELECT DISTINCT ON (product_idx) text, product_idx
    FROM public.brand_application_memos
    WHERE application_id = b.id
    ORDER BY product_idx, created_at DESC
  ) m ON true
)
WHERE EXISTS (
  SELECT 1 FROM public.brand_application_memos m2 WHERE m2.application_id = b.id
);

-- 3. 트리거 함수 복구 (081 파일 내용 재실행)

-- 4. 인덱스 제거
DROP INDEX IF EXISTS public.brand_application_memos_app_product_created_idx;

-- 5. product_idx 컬럼 제거
ALTER TABLE public.brand_application_memos
  DROP COLUMN IF EXISTS product_idx;

NOTIFY pgrst, 'reload schema';

*/
