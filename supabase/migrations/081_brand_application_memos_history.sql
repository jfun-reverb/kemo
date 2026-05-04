-- ============================================================
-- 081_brand_application_memos_history.sql
-- brand_application_memos 변경 이력 자동 기록
--
-- 1. brand_application_history.field_name CHECK 제약 확장
--    추가값: memo_added / memo_edited / memo_deleted
-- 2. 트리거 함수 record_brand_application_memo_history()
--    AFTER INSERT/UPDATE/DELETE on brand_application_memos
-- 3. 트리거 trg_brand_app_memo_history 바인딩
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. field_name CHECK 제약 확장
--    기존: ('status', 'admin_memo', 'quote_sent_at', 'final_quote_krw', 'products')
--    추가: 'memo_added', 'memo_edited', 'memo_deleted'
-- ────────────────────────────────────────────────────────────

-- 제약 이름 조회 후 DROP (이름이 자동 생성된 경우 대비, 테이블 정의 기준으로 명칭 확인)
DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM pg_constraint
  WHERE conrelid = 'public.brand_application_history'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%field_name%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.brand_application_history DROP CONSTRAINT %I',
      v_constraint_name
    );
    RAISE NOTICE '기존 CHECK 제약 제거: %', v_constraint_name;
  ELSE
    RAISE NOTICE 'field_name CHECK 제약 없음 — 신규 추가만 진행';
  END IF;
END;
$$;

ALTER TABLE public.brand_application_history
  ADD CONSTRAINT brand_application_history_field_name_check
  CHECK (field_name IN (
    'status', 'admin_memo', 'quote_sent_at', 'final_quote_krw', 'products',
    'memo_added', 'memo_edited', 'memo_deleted'
  ));

COMMENT ON CONSTRAINT brand_application_history_field_name_check
  ON public.brand_application_history IS
  '[081] field_name 허용값. 079 5개 + 081 memo_added/memo_edited/memo_deleted 3개.';

-- ────────────────────────────────────────────────────────────
-- 2. 트리거 함수
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_brand_application_memo_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_actor_id    uuid;
  v_actor_name  text;
  v_app_id      uuid;
BEGIN
  -- 행위자: auth.uid() (NULL 허용 — 서비스롤/시스템 호출 대비)
  v_actor_id := auth.uid();

  IF v_actor_id IS NOT NULL THEN
    SELECT name INTO v_actor_name
    FROM public.admins
    WHERE auth_id = v_actor_id
    LIMIT 1;
  END IF;

  -- application_id: DELETE는 OLD에서, 그 외 NEW에서 취득
  IF TG_OP = 'DELETE' THEN
    v_app_id := OLD.application_id;
  ELSE
    v_app_id := NEW.application_id;
  END IF;

  -- INSERT: 메모 신규 추가 → memo_added
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
        'created_at',  NEW.created_at
      )
    );

  -- UPDATE: text 변경 있을 때만 → memo_edited
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
          'updated_at',  OLD.updated_at
        ),
        jsonb_build_object(
          'id',          NEW.id,
          'text',        NEW.text,
          'author_id',   NEW.author_id,
          'author_name', NEW.author_name,
          'updated_at',  NEW.updated_at
        )
      );
    END IF;

  -- DELETE: 메모 삭제 → memo_deleted
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
        'created_at',  OLD.created_at,
        'updated_at',  OLD.updated_at
      ),
      NULL
    );
  END IF;

  -- DELETE 트리거는 OLD를 반환해야 함, 나머지는 NEW
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.record_brand_application_memo_history IS
  '[081] brand_application_memos AFTER INSERT/UPDATE/DELETE 트리거. '
  'INSERT→memo_added, UPDATE(text 변경 시)→memo_edited, DELETE→memo_deleted 로 '
  'brand_application_history에 기록. SECURITY DEFINER — 클라이언트 RLS 우회하여 이력 기록.';

-- ────────────────────────────────────────────────────────────
-- 3. 트리거 바인딩
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_brand_app_memo_history ON public.brand_application_memos;

CREATE TRIGGER trg_brand_app_memo_history
  AFTER INSERT OR UPDATE OR DELETE ON public.brand_application_memos
  FOR EACH ROW
  EXECUTE FUNCTION public.record_brand_application_memo_history();


-- ════════════════════════════════════════════════════════════
-- [클라이언트 영향 분석]
-- • brand_application_memos CRUD 호출(insertBrandAppMemo 등)은 변경 불필요
--   트리거가 AFTER INSERT/UPDATE/DELETE로 자동 기록
-- • fetchBrandApplicationHistory(id) 는 기존대로 brand_application_history 조회
--   field_name IN ('memo_added','memo_edited','memo_deleted') 필터 추가로
--   메모 이력만 별도 표시 가능 (선택적 UI 개선)
-- ════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 DB SQL Editor에서 직접 실행
-- ════════════════════════════════════════════════════════════
/*
-- 0. CHECK 제약 확장 확인
SELECT conname, pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conrelid = 'public.brand_application_history'::regclass
  AND contype = 'c';
-- memo_added / memo_edited / memo_deleted 포함 여부 확인

-- 1. 트리거 존재 확인
SELECT tgname, tgtype, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.brand_application_memos'::regclass
  AND tgname = 'trg_brand_app_memo_history';

-- 2. 검증용 신청 ID 확보
SELECT id FROM public.brand_applications ORDER BY created_at DESC LIMIT 1;
-- 이하 <app_id> 를 실제 UUID로 교체하여 실행

-- 3. INSERT 검증 → history에 memo_added 1행 기대
INSERT INTO public.brand_application_memos (application_id, text, author_name)
VALUES ('<app_id>', '검증용 메모 - 최초', '(test)');

SELECT field_name, old_value, new_value, changed_by_name, changed_at
FROM public.brand_application_history
WHERE application_id = '<app_id>'
  AND field_name = 'memo_added'
ORDER BY changed_at DESC
LIMIT 1;
-- new_value.text = '검증용 메모 - 최초', old_value IS NULL 확인

-- 4. UPDATE text 변경 → history에 memo_edited 1행 기대
UPDATE public.brand_application_memos
SET text = '검증용 메모 - 수정됨'
WHERE application_id = '<app_id>'
  AND author_name = '(test)';

SELECT field_name, old_value, new_value, changed_at
FROM public.brand_application_history
WHERE application_id = '<app_id>'
  AND field_name = 'memo_edited'
ORDER BY changed_at DESC
LIMIT 1;
-- old_value.text = '검증용 메모 - 최초', new_value.text = '검증용 메모 - 수정됨' 확인

-- 5. UPDATE text 미변경(author_name만 변경) → history row 추가 없음 확인
SELECT COUNT(*) AS cnt_before
FROM public.brand_application_history
WHERE application_id = '<app_id>' AND field_name = 'memo_edited';

UPDATE public.brand_application_memos
SET author_name = '(test-renamed)'
WHERE application_id = '<app_id>'
  AND author_name = '(test)';

SELECT COUNT(*) AS cnt_after
FROM public.brand_application_history
WHERE application_id = '<app_id>' AND field_name = 'memo_edited';
-- cnt_before = cnt_after 이어야 함 (text 미변경이므로 기록 없음)

-- 6. DELETE 검증 → history에 memo_deleted 1행 기대
DELETE FROM public.brand_application_memos
WHERE application_id = '<app_id>'
  AND author_name IN ('(test)', '(test-renamed)');

SELECT field_name, old_value, new_value, changed_at
FROM public.brand_application_history
WHERE application_id = '<app_id>'
  AND field_name = 'memo_deleted'
ORDER BY changed_at DESC
LIMIT 1;
-- old_value.text = '검증용 메모 - 수정됨', new_value IS NULL 확인

-- 7. 검증 이력 정리 (선택)
-- DELETE FROM public.brand_application_history WHERE application_id = '<app_id>';
*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 순서대로 실행
-- ════════════════════════════════════════════════════════════
/*
-- STEP 1. 트리거 제거 (brand_application_memos 테이블 영향 없어짐)
DROP TRIGGER IF EXISTS trg_brand_app_memo_history ON public.brand_application_memos;

-- STEP 2. 트리거 함수 제거
DROP FUNCTION IF EXISTS public.record_brand_application_memo_history();

-- STEP 3. field_name CHECK 제약을 079 원본으로 복원
ALTER TABLE public.brand_application_history
  DROP CONSTRAINT IF EXISTS brand_application_history_field_name_check;

ALTER TABLE public.brand_application_history
  ADD CONSTRAINT brand_application_history_field_name_check
  CHECK (field_name IN (
    'status', 'admin_memo', 'quote_sent_at', 'final_quote_krw', 'products'
  ));

-- STEP 4. memo_added/edited/deleted 이력 데이터 제거 (선택 — 불필요 시 생략)
-- DELETE FROM public.brand_application_history
-- WHERE field_name IN ('memo_added', 'memo_edited', 'memo_deleted');
*/
