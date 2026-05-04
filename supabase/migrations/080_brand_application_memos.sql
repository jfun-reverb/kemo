-- ============================================================
-- 080_brand_application_memos.sql
-- 브랜드 서베이 신청별 다중 메모 테이블
--
-- 배경: brand_applications.admin_memo (단일 text) → 다중 메모 테이블로 확장
-- - 메모마다 row 1개, 작성자/시간 기록, 수정·삭제 가능 (모든 관리자)
-- - 기존 admin_memo 데이터는 첫 메모 row로 마이그레이션 (legacy row)
-- - admin_memo 컬럼은 즉시 DROP하지 않음 (추후 별도 PR에서 제거)
-- - 079의 brand_application_history 트리거는 admin_memo 변경을 추적 중이나
--   새 brand_application_memos 테이블은 별도 INSERT라 history에 기록 안 됨
--   → 메모 history 추적 필요 시 다음 PR에서 별도 트리거 추가
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. 테이블 생성
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_application_memos (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid        NOT NULL
                    REFERENCES public.brand_applications(id) ON DELETE CASCADE,
  author_id       uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  author_name     text,                              -- 삭제된 관리자 이름 보존용 스냅샷
  text            text        NOT NULL CHECK (length(trim(text)) > 0),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.brand_application_memos IS
  '[080] 브랜드 서베이 신청별 다중 메모. 메모마다 row 1개. admin_memo(legacy) 대체.';

COMMENT ON COLUMN public.brand_application_memos.author_name IS
  '작성 시점 관리자 이름 스냅샷. author_id(auth.users)가 삭제돼도 이름 보존.';

COMMENT ON COLUMN public.brand_application_memos.text IS
  '메모 본문. 공백만으로 구성된 내용은 CHECK 제약으로 차단(trim 적용).';

-- ────────────────────────────────────────────────────────────
-- 2. 인덱스 (application_id + 최신순)
-- ────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS brand_application_memos_app_created_idx
  ON public.brand_application_memos (application_id, created_at DESC);

-- ────────────────────────────────────────────────────────────
-- 3. RLS
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.brand_application_memos ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만
CREATE POLICY "admin_select_brand_application_memos"
  ON public.brand_application_memos
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: 관리자만 (모든 관리자가 타인 신청에도 메모 작성 가능)
CREATE POLICY "admin_insert_brand_application_memos"
  ON public.brand_application_memos
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

-- UPDATE: 관리자만 (단순 정책 — 모든 관리자가 모든 메모 수정 가능)
CREATE POLICY "admin_update_brand_application_memos"
  ON public.brand_application_memos
  FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- DELETE: 관리자만 (단순 정책 — 모든 관리자가 모든 메모 삭제 가능)
CREATE POLICY "admin_delete_brand_application_memos"
  ON public.brand_application_memos
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────
-- 4. updated_at 자동 갱신 트리거
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.touch_brand_application_memos_updated_at()
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

COMMENT ON FUNCTION public.touch_brand_application_memos_updated_at IS
  '[080] brand_application_memos BEFORE UPDATE 트리거. updated_at 자동 갱신.';

DROP TRIGGER IF EXISTS trg_brand_app_memos_updated_at ON public.brand_application_memos;

CREATE TRIGGER trg_brand_app_memos_updated_at
  BEFORE UPDATE ON public.brand_application_memos
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_brand_application_memos_updated_at();

-- ────────────────────────────────────────────────────────────
-- 5. 기존 admin_memo 데이터 마이그레이션
--    조건: admin_memo IS NOT NULL AND trim(admin_memo) <> ''
--    author_id = NULL (legacy 데이터는 작성자 불명)
--    author_name = '(legacy)'
--    created_at = brand_applications.updated_at (최종 수정 시점 근사)
--      → updated_at이 NULL이면 created_at 폴백 (방어적 처리)
-- ────────────────────────────────────────────────────────────
INSERT INTO public.brand_application_memos
  (application_id, author_id, author_name, text, created_at, updated_at)
SELECT
  id,
  NULL,
  '(legacy)',
  admin_memo,
  COALESCE(updated_at, created_at, now()),
  COALESCE(updated_at, created_at, now())
FROM public.brand_applications
WHERE admin_memo IS NOT NULL
  AND trim(admin_memo) <> '';

-- admin_memo 컬럼은 legacy 유지 (추후 PR에서 DROP 예정)
-- DROP COLUMN 시 brand_application_history 트리거의 admin_memo 추적도 함께 정리 필요


-- ════════════════════════════════════════════════════════════
-- [클라이언트 영향 분석]
-- • brand_application_memos 테이블은 RLS 정책만으로 직접 CRUD 가능
--   (RPC 불필요 — is_admin() 인증된 authenticated 사용자가 .from() 직접 호출)
-- • storage.js에 아래 함수 추가 권장:
--   - fetchBrandAppMemos(applicationId)
--       → SELECT * FROM brand_application_memos
--         WHERE application_id = $1 ORDER BY created_at DESC
--   - insertBrandAppMemo(applicationId, text, authorId, authorName)
--       → INSERT INTO brand_application_memos ...
--   - updateBrandAppMemo(memoId, text)
--       → UPDATE brand_application_memos SET text = $2 WHERE id = $1
--   - deleteBrandAppMemo(memoId)
--       → DELETE FROM brand_application_memos WHERE id = $1
-- • 기존 updateBrandApplication() 호출 시 admin_memo 필드 패치는 계속 동작
--   (legacy 컬럼 유지 중이므로 기존 코드 변경 불필요)
-- • brand_application_history 트리거: admin_memo 컬럼 UPDATE 여전히 추적 중
--   새 brand_application_memos INSERT는 history에 기록되지 않음
--   → 메모 변경 이력이 필요하면 별도 트리거를 다음 PR에서 추가
-- ════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 DB에서 마이그레이션 적용 후 SQL Editor에서 직접 실행
-- ════════════════════════════════════════════════════════════
/*
-- 1. 테이블 및 인덱스 존재 확인
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public' AND tablename = 'brand_application_memos';

SELECT indexname
FROM pg_indexes
WHERE tablename = 'brand_application_memos';

-- 2. RLS 정책 확인 (4개 기대: select/insert/update/delete)
SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'brand_application_memos'
ORDER BY cmd;

-- 3. 트리거 확인
SELECT tgname, tgtype, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.brand_application_memos'::regclass;

-- 4. 기존 admin_memo 보유 row 수 vs 신규 테이블 count 일치 확인
SELECT COUNT(*) AS legacy_memo_count
FROM public.brand_applications
WHERE admin_memo IS NOT NULL AND trim(admin_memo) <> '';

SELECT COUNT(*) AS migrated_memo_count
FROM public.brand_application_memos
WHERE author_name = '(legacy)';

-- → legacy_memo_count = migrated_memo_count 이어야 함

-- 5. legacy 메모 내용 샘플 확인
SELECT
  m.application_id,
  m.text,
  m.author_name,
  m.created_at,
  b.admin_memo AS original_admin_memo
FROM public.brand_application_memos m
JOIN public.brand_applications b ON b.id = m.application_id
WHERE m.author_name = '(legacy)'
LIMIT 5;

-- 6. updated_at 트리거 동작 확인
-- (검증용 메모 INSERT 후 UPDATE하여 updated_at 변경 확인)
DO $$
DECLARE
  v_app_id uuid;
  v_memo_id uuid;
  v_created_at timestamptz;
  v_updated_at timestamptz;
BEGIN
  -- 첫 번째 신청 ID 확보
  SELECT id INTO v_app_id FROM public.brand_applications LIMIT 1;
  IF v_app_id IS NULL THEN
    RAISE NOTICE '신청 데이터가 없어 트리거 검증 스킵';
    RETURN;
  END IF;

  -- 검증용 메모 INSERT
  INSERT INTO public.brand_application_memos (application_id, text, author_name)
  VALUES (v_app_id, '트리거 검증용 메모', '(test)')
  RETURNING id, created_at, updated_at INTO v_memo_id, v_created_at, v_updated_at;

  RAISE NOTICE 'INSERT: created_at=%, updated_at=%', v_created_at, v_updated_at;

  -- 1초 대기 후 UPDATE (updated_at 변경 확인)
  PERFORM pg_sleep(1);
  UPDATE public.brand_application_memos SET text = '트리거 검증용 메모 (수정됨)' WHERE id = v_memo_id;
  SELECT updated_at INTO v_updated_at FROM public.brand_application_memos WHERE id = v_memo_id;

  RAISE NOTICE 'UPDATE: updated_at=% (원본 created_at=%보다 커야 함)', v_updated_at, v_created_at;

  -- 검증 데이터 정리
  DELETE FROM public.brand_application_memos WHERE id = v_memo_id;
  RAISE NOTICE '검증 메모 삭제 완료: %', v_memo_id;
END;
$$;

-- 7. RLS 검증 (클라이언트 측 — SQL Editor는 service_role이라 직접 확인 불가)
--    관리자 로그인 상태:
--      const { data } = await db.from('brand_application_memos').select('*').limit(5);
--      → N건 반환 (is_admin() true)
--    비관리자(인플루언서) 로그인 상태:
--      → 0건 반환 (is_admin() false)
--    비로그인(anon):
--      → 0건 또는 error (authenticated 정책만 있으므로 anon 차단)
*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 순서대로 실행
-- admin_memo 컬럼은 DROP하지 않았으므로 롤백 후 기존 단일 메모 기능 즉시 복구
-- ════════════════════════════════════════════════════════════
/*
-- STEP 1. 트리거 제거
DROP TRIGGER IF EXISTS trg_brand_app_memos_updated_at ON public.brand_application_memos;

-- STEP 2. 트리거 함수 제거
DROP FUNCTION IF EXISTS public.touch_brand_application_memos_updated_at();

-- STEP 3. 테이블 DROP (마이그레이션된 legacy 메모 포함 영구 삭제 — 주의)
-- admin_memo 컬럼은 brand_applications에 그대로 남아있어 데이터 유실 없음
DROP TABLE IF EXISTS public.brand_application_memos;
*/
