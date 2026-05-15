-- ============================================================
-- 125_brand_app_memo_reads.sql
-- 브랜드 서베이 메모 — 관리자별 읽음 이력 (admin_notice_reads 패턴 미러)
--
-- 목적:
--   메모 셀의 분홍 카운트 배지를 "총 메모 개수" → "내가 안 읽은 메모 수" 로 전환.
--   모달을 열면 그 (신청, 제품) 페어의 메모를 본인 auth.uid() 로 일괄 read 처리.
--
-- 신규:
--   - brand_application_memo_reads 테이블
--   - 행 단위 보안 정책(RLS)
--   - mark_brand_app_memos_read(p_application_id uuid, p_product_idx integer) 원격 호출 함수
--   - get_brand_app_memo_summaries() 원격 호출 함수 — (신청, 제품) 페어 단위 total/unread/latest
--
-- 참고: 063 admin_notices/admin_notice_reads 패턴과 동일 구조.
--
-- 사양서: docs/specs/2026-05-13-brand-app-product-admin-memo.md
-- 작성일: 2026-05-14
-- ============================================================


-- ============================================================
-- SECTION 1. brand_application_memo_reads 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.brand_application_memo_reads (
  memo_id    uuid        NOT NULL REFERENCES public.brand_application_memos(id) ON DELETE CASCADE,
  auth_id    uuid        NOT NULL,
  read_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (memo_id, auth_id)
);

CREATE INDEX IF NOT EXISTS idx_brand_app_memo_reads_auth
  ON public.brand_application_memo_reads (auth_id);

COMMENT ON TABLE public.brand_application_memo_reads IS
  '[125] brand_application_memos 의 관리자별 읽음 이력. admin_notice_reads(063) 패턴 미러. memo_id FK ON DELETE CASCADE 로 메모 삭제 시 자동 정리.';


-- ============================================================
-- SECTION 2. 행 단위 보안 정책
-- ============================================================
ALTER TABLE public.brand_application_memo_reads ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자 전체 (LEFT JOIN 시 본인 행 필터링은 클라이언트/원격 호출 함수에서)
CREATE POLICY "brand_app_memo_reads_select"
  ON public.brand_application_memo_reads FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: 본인 행만, 관리자만
CREATE POLICY "brand_app_memo_reads_insert"
  ON public.brand_application_memo_reads FOR INSERT
  TO authenticated
  WITH CHECK (auth_id = auth.uid() AND public.is_admin());

-- UPDATE/DELETE 정책 없음 — mark_brand_app_memos_read 원격 호출 함수 전용


-- ============================================================
-- SECTION 3. 원격 호출 함수 — mark_brand_app_memos_read
--   (application_id, product_idx) 페어의 모든 메모를 본인 auth.uid() 로 일괄 UPSERT.
--   모달 진입 시점, 메모 추가/수정 직후 호출.
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_brand_app_memos_read(
  p_application_id uuid,
  p_product_idx    integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_marked  integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[mark_brand_app_memos_read] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION '[mark_brand_app_memos_read] auth.uid() is null'
      USING ERRCODE = '28000';
  END IF;

  -- 그 페어의 모든 메모를 본인 read 로 UPSERT (이미 읽었으면 read_at 갱신)
  WITH ins AS (
    INSERT INTO public.brand_application_memo_reads (memo_id, auth_id, read_at)
    SELECT m.id, v_uid, now()
    FROM public.brand_application_memos m
    WHERE m.application_id = p_application_id
      AND m.product_idx = p_product_idx
    ON CONFLICT (memo_id, auth_id) DO UPDATE
      SET read_at = now()
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_marked FROM ins;

  RETURN COALESCE(v_marked, 0);
END;
$$;

COMMENT ON FUNCTION public.mark_brand_app_memos_read IS
  '[125] (application_id, product_idx) 페어의 모든 메모를 본인 auth.uid() 로 일괄 읽음 처리. 반환: 처리된 행 수.';

REVOKE EXECUTE ON FUNCTION public.mark_brand_app_memos_read(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_brand_app_memos_read(uuid, integer) TO authenticated;


-- ============================================================
-- SECTION 4. 원격 호출 함수 — get_brand_app_memo_summaries
--   (application_id, product_idx) 페어 단위 집계:
--     total_count: 메모 총 개수
--     unread_count: 본인 auth.uid() 기준 안 읽은 메모 수
--     latest_text: 최신 메모 텍스트
--     latest_created_at: 최신 메모 시각
--   클라이언트 fetchBrandAppMemoSummaries 가 단일 round-trip 으로 호출.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_brand_app_memo_summaries()
RETURNS TABLE (
  application_id     uuid,
  product_idx        integer,
  total_count        integer,
  unread_count       integer,
  latest_text        text,
  latest_created_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[get_brand_app_memo_summaries] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH ranked AS (
    SELECT
      m.application_id,
      m.product_idx,
      m.text,
      m.created_at,
      ROW_NUMBER() OVER (PARTITION BY m.application_id, m.product_idx ORDER BY m.created_at DESC) AS rn,
      r.read_at IS NOT NULL AS is_read
    FROM public.brand_application_memos m
    LEFT JOIN public.brand_application_memo_reads r
      ON r.memo_id = m.id AND r.auth_id = v_uid
  )
  SELECT
    ranked.application_id,
    ranked.product_idx,
    count(*)::integer                                          AS total_count,
    sum(CASE WHEN NOT ranked.is_read THEN 1 ELSE 0 END)::integer AS unread_count,
    max(CASE WHEN ranked.rn = 1 THEN ranked.text END)          AS latest_text,
    max(CASE WHEN ranked.rn = 1 THEN ranked.created_at END)    AS latest_created_at
  FROM ranked
  GROUP BY ranked.application_id, ranked.product_idx;
END;
$$;

COMMENT ON FUNCTION public.get_brand_app_memo_summaries IS
  '[125] (application_id, product_idx) 페어 단위 메모 집계. 반환: total_count/unread_count(본인 기준)/latest_text/latest_created_at.';

REVOKE EXECUTE ON FUNCTION public.get_brand_app_memo_summaries() FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_brand_app_memo_summaries() TO authenticated;


-- ============================================================
-- SECTION 5. PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증 SQL (개발/운영 DB 적용 후 SQL Editor 에서 실행)
-- ============================================================
/*

-- [V1] 테이블 존재 확인
SELECT tablename FROM pg_tables
WHERE schemaname='public' AND tablename='brand_application_memo_reads';
-- 1행

-- [V2] 인덱스 존재 확인
SELECT indexname FROM pg_indexes
WHERE tablename='brand_application_memo_reads';
-- 2건 (PK + auth_id)

-- [V3] 행 단위 보안 정책 2건 확인
SELECT policyname, cmd FROM pg_policies
WHERE tablename='brand_application_memo_reads'
ORDER BY cmd;
-- INSERT (insert), SELECT (select)

-- [V4] 원격 호출 함수 2종 등록 확인
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('mark_brand_app_memos_read', 'get_brand_app_memo_summaries')
ORDER BY proname;
-- 2건

-- [V5] get_brand_app_memo_summaries() 동작 확인 — 관리자 로그인 상태에서 실행
--   개발 DB 기대: 14개 페어 행 (legacy 메모 14건이 14개 페어에 분포)
--   각 페어 unread_count = total_count (아직 아무도 안 읽음)
SELECT * FROM public.get_brand_app_memo_summaries() LIMIT 5;

-- [V6] mark_brand_app_memos_read 동작 확인 — 임의 신청·제품 페어로 호출
--   반환: 처리된 행 수 (그 페어 메모 개수와 동일)
-- 예: SELECT public.mark_brand_app_memos_read('<application_id>'::uuid, 0);

*/


-- ============================================================
-- 롤백 SQL
-- ============================================================
/*

DROP FUNCTION IF EXISTS public.get_brand_app_memo_summaries();
DROP FUNCTION IF EXISTS public.mark_brand_app_memos_read(uuid, integer);
DROP TABLE IF EXISTS public.brand_application_memo_reads;

NOTIFY pgrst, 'reload schema';

*/
