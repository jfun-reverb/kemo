-- ============================================================
-- 079_brand_application_history.sql
-- brand_applications 변경 이력 자동 기록
--
-- 추적 대상: status / admin_memo / quote_sent_at / final_quote_krw / products
-- 추적 제외: total_jpy, total_qty, estimated_krw, version, updated_at,
--            reviewed_by, reviewed_at (status 변화로 간접 표현)
--
-- 트리거: AFTER UPDATE — UPDATE 성공 후에만 기록 (실패 시 롤백 자동)
-- 보안: SELECT is_admin() 전용, CUD는 SECURITY DEFINER 트리거만 허용
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. 이력 테이블
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_application_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid        NOT NULL
                    REFERENCES public.brand_applications(id) ON DELETE CASCADE,
  changed_by      uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_by_name text,         -- 스냅샷: 관리자 삭제 후에도 이름 보존
  changed_at      timestamptz NOT NULL DEFAULT now(),
  field_name      text        NOT NULL
                    CHECK (field_name IN (
                      'status', 'admin_memo', 'quote_sent_at',
                      'final_quote_krw', 'products'
                    )),
  old_value       jsonb,
  new_value       jsonb
);

COMMENT ON TABLE public.brand_application_history IS
  '[079] brand_applications 컬럼별 변경 이력. 트리거 record_brand_application_history() 전용 기록.';

-- ────────────────────────────────────────────────────────────
-- 2. 인덱스 (application_id + 최신순)
-- ────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS brand_application_history_app_changed_idx
  ON public.brand_application_history (application_id, changed_at DESC);

-- ────────────────────────────────────────────────────────────
-- 3. RLS
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.brand_application_history ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만
CREATE POLICY "admin_select_brand_application_history"
  ON public.brand_application_history
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE: 클라이언트 직접 금지 (트리거 SECURITY DEFINER만 허용)
-- 정책 없음 = 암묵적 DENY

-- ────────────────────────────────────────────────────────────
-- 4. 트리거 함수
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_brand_application_history()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_actor_id   uuid;
  v_actor_name text;
BEGIN
  -- 변경 행위자: auth.uid() (NULL 허용 — 시스템/서비스롤 호출 시)
  v_actor_id := auth.uid();

  -- 행위자 이름 스냅샷 (admins 테이블 조회, 없으면 NULL)
  IF v_actor_id IS NOT NULL THEN
    SELECT name INTO v_actor_name
    FROM public.admins
    WHERE auth_id = v_actor_id
    LIMIT 1;
  END IF;

  -- status 변경 감지
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'status', to_jsonb(OLD.status), to_jsonb(NEW.status));
  END IF;

  -- admin_memo 변경 감지
  IF NEW.admin_memo IS DISTINCT FROM OLD.admin_memo THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'admin_memo', to_jsonb(OLD.admin_memo), to_jsonb(NEW.admin_memo));
  END IF;

  -- quote_sent_at 변경 감지
  IF NEW.quote_sent_at IS DISTINCT FROM OLD.quote_sent_at THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'quote_sent_at', to_jsonb(OLD.quote_sent_at), to_jsonb(NEW.quote_sent_at));
  END IF;

  -- final_quote_krw 변경 감지
  IF NEW.final_quote_krw IS DISTINCT FROM OLD.final_quote_krw THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'final_quote_krw', to_jsonb(OLD.final_quote_krw), to_jsonb(NEW.final_quote_krw));
  END IF;

  -- products 변경 감지 (jsonb 통째 비교)
  IF NEW.products IS DISTINCT FROM OLD.products THEN
    INSERT INTO public.brand_application_history
      (application_id, changed_by, changed_by_name, field_name, old_value, new_value)
    VALUES
      (NEW.id, v_actor_id, v_actor_name,
       'products', OLD.products, NEW.products);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_brand_application_history IS
  '[079] brand_applications AFTER UPDATE 트리거. 추적 대상 5개 컬럼을 IS DISTINCT FROM으로 비교하고 변경된 컬럼마다 history row 1개 INSERT. SECURITY DEFINER — 클라이언트 RLS 우회하여 이력 기록.';

-- ────────────────────────────────────────────────────────────
-- 5. 트리거 바인딩
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_brand_app_history ON public.brand_applications;

CREATE TRIGGER trg_brand_app_history
  AFTER UPDATE ON public.brand_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.record_brand_application_history();


-- ════════════════════════════════════════════════════════════
-- [클라이언트 영향 분석]
-- • updateBrandApplication(id, patch, expectedVersion): 변경 불필요
--   트리거가 AFTER UPDATE로 자동 기록 — 클라이언트 코드는 기존 .update() 호출만으로 충분
-- • submit_brand_application RPC: 영향 없음 (INSERT 전용, UPDATE 트리거 미실행)
-- • fetchBrandApplicationHistory(id) 함수를 storage.js에 추가하여 UI에서 조회 필요
--   → SELECT * FROM brand_application_history WHERE application_id = $1 ORDER BY changed_at DESC
-- ════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 DB에서 마이그레이션 적용 후 SQL Editor에서 직접 실행
-- ════════════════════════════════════════════════════════════
/*
-- 사전 준비: 검증에 사용할 신청 ID 확인
SELECT id, status, admin_memo, quote_sent_at, final_quote_krw
FROM public.brand_applications
ORDER BY created_at DESC
LIMIT 3;

-- 1. status + admin_memo + final_quote_krw + products 동시 변경 → 4개 row 기대
UPDATE public.brand_applications
SET
  status          = 'reviewing',
  admin_memo      = '검증용 메모 ' || now()::text,
  final_quote_krw = 99999,
  products        = '[{"name":"test","qty":1,"price_jpy":1000}]'::jsonb
WHERE id = '<검증용_ID>';

-- 이력 조회 (4개 row 기대)
SELECT field_name, old_value, new_value, changed_by_name, changed_at
FROM public.brand_application_history
WHERE application_id = '<검증용_ID>'
ORDER BY changed_at DESC;

-- 2. quote_sent_at 단독 변경 → 1개 row 기대
UPDATE public.brand_applications
SET quote_sent_at = now()
WHERE id = '<검증용_ID>';

SELECT field_name, old_value, new_value
FROM public.brand_application_history
WHERE application_id = '<검증용_ID>'
  AND field_name = 'quote_sent_at'
ORDER BY changed_at DESC
LIMIT 1;

-- 3. 추적 제외 컬럼만 변경 → history row 추가 없음을 확인
-- (version은 낙관적 락 UPDATE 시 항상 증가하므로 history 증가 없어야 함)
SELECT COUNT(*) AS cnt_before FROM public.brand_application_history WHERE application_id = '<검증용_ID>';
UPDATE public.brand_applications SET version = version + 1 WHERE id = '<검증용_ID>';
SELECT COUNT(*) AS cnt_after  FROM public.brand_application_history WHERE application_id = '<검증용_ID>';
-- cnt_before = cnt_after 이어야 함

-- 4. RLS 검증: anon 세션에서 조회 → 0건 (Supabase SQL Editor는 service_role이라 직접 확인 불가)
--    클라이언트에서 로그아웃 상태로 아래 실행 시 0건 확인:
--    const { data } = await db.from('brand_application_history').select('*').limit(5);
--    → data === [] or data === null
--
--    관리자 로그인 상태에서 동일 쿼리 → N건 반환 확인

-- 5. 테이블 및 인덱스 존재 확인
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'brand_application_history';
SELECT indexname FROM pg_indexes WHERE tablename = 'brand_application_history';

-- 6. 트리거 존재 확인
SELECT tgname, tgtype, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.brand_applications'::regclass
  AND tgname = 'trg_brand_app_history';

-- 7. 검증 데이터 정리 (선택)
-- DELETE FROM public.brand_application_history WHERE application_id = '<검증용_ID>';
*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 순서대로 실행
-- ════════════════════════════════════════════════════════════
/*
-- STEP 1. 트리거 제거 (brand_applications 테이블 영향 없어짐)
DROP TRIGGER IF EXISTS trg_brand_app_history ON public.brand_applications;

-- STEP 2. 트리거 함수 제거
DROP FUNCTION IF EXISTS public.record_brand_application_history();

-- STEP 3. 이력 테이블 제거 (데이터 포함 영구 삭제 — 주의)
DROP TABLE IF EXISTS public.brand_application_history;
*/
