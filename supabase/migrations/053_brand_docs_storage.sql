-- ============================================================
-- migration: 053_brand_docs_storage
-- purpose  : 광고주 신청 폼 시스템 PR-2 — 사업자등록증 Storage 버킷
--            - brand-docs 버킷 생성 (비공개, 10MB, PDF/JPEG/PNG)
--            - anon·authenticated INSERT 가능 (광고주 파일 업로드)
--            - SELECT/UPDATE/DELETE는 관리자(is_admin())만 가능
--            - 업로드 경로: {YYYY}/{MM}/{client_uuid}/license.{ext}
--              (client_uuid는 클라이언트가 crypto.randomUUID()로 생성)
--            - DB: brand_applications.business_license_path에 전체 경로 저장
--
-- 적용 순서:
--   1. 개발 DB (qysmxtipobomefudyixw.supabase.co) 먼저 적용 후 검증
--   2. 운영 DB (twofagomeizrtkwlhsuv.supabase.co) 적용
--
-- rollback: 이 파일 맨 아래 ROLLBACK 블록 참조
-- ============================================================


-- ============================================================
-- 1. brand-docs 버킷 생성
--    idempotent: ON CONFLICT DO UPDATE로 파일 제한·MIME 타입 갱신 보장.
--    public = false: 직접 URL 공개 불가, 관리자 signed URL로만 접근.
-- ============================================================
INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'brand-docs',
  'brand-docs',
  false,
  10485760,   -- 10MB
  ARRAY['application/pdf', 'image/jpeg', 'image/png']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ============================================================
-- 2. Storage RLS 정책
--    storage.objects 테이블은 Supabase가 기본으로 RLS를 활성화해두므로
--    ALTER TABLE ... ENABLE ROW LEVEL SECURITY 불필요.
--
--    정책명 prefix: brand_docs_ (기존 campaign_images_ 와 충돌 방지)
-- ============================================================

-- idempotent 재적용을 위해 기존 정책을 먼저 DROP (PostgreSQL은 CREATE POLICY IF NOT EXISTS 미지원)
DROP POLICY IF EXISTS "brand_docs_insert" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_select" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_update" ON storage.objects;
DROP POLICY IF EXISTS "brand_docs_delete" ON storage.objects;

-- ── INSERT: anon·authenticated 허용 ──────────────────────────
-- 경로 규칙 강제:
--   (storage.foldername(name))[1] ~ '^\d{4}$'  → YYYY 폴더
--   (storage.foldername(name))[2] ~ '^\d{2}$'  → MM 폴더
-- UUID 3번째 폴더는 형식 검증 생략
--   (crypto.randomUUID() 사용을 전제로 신뢰, 버킷 수준 MIME/크기 제한이 1차 방어)
CREATE POLICY "brand_docs_insert"
  ON storage.objects FOR INSERT
  TO anon, authenticated
  WITH CHECK (
    bucket_id = 'brand-docs'
    AND (storage.foldername(name))[1] ~ '^\d{4}$'
    AND (storage.foldername(name))[2] ~ '^\d{2}$'
  );

-- ── SELECT: 관리자만 (signed URL 발급 용도) ──────────────────
CREATE POLICY "brand_docs_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'brand-docs'
    AND public.is_admin()
  );

-- ── UPDATE: 관리자만 ─────────────────────────────────────────
CREATE POLICY "brand_docs_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'brand-docs'
    AND public.is_admin()
  );

-- ── DELETE: 관리자만 ─────────────────────────────────────────
CREATE POLICY "brand_docs_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'brand-docs'
    AND public.is_admin()
  );

-- anon의 SELECT/UPDATE/DELETE는 명시적 정책 없음 = 기본 deny (추가 작업 불필요)


-- ============================================================
-- 적용 명령 안내
-- 개발서버: Supabase Dashboard(qysmxtipobomefudyixw) SQL Editor에 붙여넣어 실행
-- 운영서버: 개발 검증 완료 후 twofagomeizrtkwlhsuv SQL Editor에 동일하게 실행
-- ============================================================


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- -- 1. 버킷 존재 확인
-- SELECT id, name, public, file_size_limit, allowed_mime_types
-- FROM storage.buckets
-- WHERE id = 'brand-docs';
-- -- 기대값: public=false, file_size_limit=10485760,
-- --         allowed_mime_types={application/pdf,image/jpeg,image/png}

-- -- 2. RLS 정책 목록 확인
-- SELECT policyname, cmd, roles
-- FROM pg_policies
-- WHERE schemaname = 'storage'
--   AND tablename  = 'objects'
--   AND policyname LIKE 'brand_docs_%';
-- -- 기대값: brand_docs_insert(INSERT), brand_docs_select(SELECT),
-- --         brand_docs_update(UPDATE), brand_docs_delete(DELETE) 4개

-- -- 3. anon INSERT 경로 정규식 검증 (SQL만으로 경로 파싱 확인)
-- SELECT
--   (storage.foldername('2026/04/550e8400-e29b-41d4-a716-446655440000/license.pdf'))[1] AS year_folder,
--   (storage.foldername('2026/04/550e8400-e29b-41d4-a716-446655440000/license.pdf'))[2] AS month_folder,
--   (storage.foldername('2026/04/550e8400-e29b-41d4-a716-446655440000/license.pdf'))[1] ~ '^\d{4}$' AS year_ok,
--   (storage.foldername('2026/04/550e8400-e29b-41d4-a716-446655440000/license.pdf'))[2] ~ '^\d{2}$' AS month_ok;
-- -- 기대값: year_folder='2026', month_folder='04', year_ok=true, month_ok=true

-- -- 4. 잘못된 경로 차단 확인 (정규식 불일치 예시)
-- SELECT
--   (storage.foldername('bad/04/uuid/license.pdf'))[1] ~ '^\d{4}$' AS bad_year,   -- false
--   (storage.foldername('2026/4/uuid/license.pdf'))[2]  ~ '^\d{2}$' AS bad_month; -- false (1자리)


-- ============================================================
-- ROLLBACK
-- 주의: 버킷 삭제 전에 업로드된 파일을 수동으로 먼저 정리해야 합니다.
--   Supabase Dashboard → Storage → brand-docs → 파일 전체 삭제 (또는 supabase storage rm)
--   파일이 남은 상태로 버킷을 삭제하면 storage.objects 고아 레코드가 남을 수 있습니다.
-- ============================================================
-- DROP POLICY IF EXISTS "brand_docs_delete" ON storage.objects;
-- DROP POLICY IF EXISTS "brand_docs_update" ON storage.objects;
-- DROP POLICY IF EXISTS "brand_docs_select" ON storage.objects;
-- DROP POLICY IF EXISTS "brand_docs_insert" ON storage.objects;
-- DELETE FROM storage.buckets WHERE id = 'brand-docs';
