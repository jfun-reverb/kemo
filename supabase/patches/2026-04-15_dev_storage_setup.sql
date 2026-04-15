-- ============================================
-- 패치: 개발서버 campaign-images Storage 설정
-- 대상: 개발서버만 (qysmxtipobomefudyixw.supabase.co)
--       운영서버(twofagomeizrtkwlhsuv)는 이미 정상 동작 중 — 건드리지 말 것
-- 작성일: 2026-04-15
-- 원인: 개발서버에 campaign-images 버킷 및 Storage RLS 정책이
--       migration 009_create_storage.sql 미적용 상태로 누락됨.
--       버킷이 없으면 upload() 호출이 실패하고 uploadCampImages()의
--       catch 블록이 빈 문자열('')을 반환 → img1~img8이 빈 값으로 저장.
-- ============================================

-- ============================================
-- 사전 확인 쿼리 (적용 전 실행 권장)
-- ============================================
-- SELECT id, name, public FROM storage.buckets WHERE id = 'campaign-images';
-- SELECT policyname, cmd FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects';

-- ============================================
-- 1. campaign-images 버킷 생성
--    - public = true 필수 (getPublicUrl 동작에 필요)
--    - 이미 존재하면 ON CONFLICT DO NOTHING으로 멱등 실행
-- ============================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('campaign-images', 'campaign-images', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- ============================================
-- 2. Storage RLS 정책 — SELECT (전체 공개)
--    누구나 이미지 URL로 조회 가능해야 인플루언서 페이지에서 표시됨
-- ============================================
DROP POLICY IF EXISTS "campaign_images_select" ON storage.objects;
CREATE POLICY "campaign_images_select"
ON storage.objects FOR SELECT
USING (bucket_id = 'campaign-images');

-- ============================================
-- 3. Storage RLS 정책 — INSERT (관리자만)
--    admins 테이블 기반 체크 (is_admin() 함수 미사용 — storage 컨텍스트에서 search_path 이슈 방지)
-- ============================================
DROP POLICY IF EXISTS "campaign_images_insert" ON storage.objects;
CREATE POLICY "campaign_images_insert"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);

-- ============================================
-- 4. Storage RLS 정책 — UPDATE (관리자만)
-- ============================================
DROP POLICY IF EXISTS "campaign_images_update" ON storage.objects;
CREATE POLICY "campaign_images_update"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);

-- ============================================
-- 5. Storage RLS 정책 — DELETE (관리자만)
-- ============================================
DROP POLICY IF EXISTS "campaign_images_delete" ON storage.objects;
CREATE POLICY "campaign_images_delete"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);

-- ============================================
-- 롤백 방법
-- 버킷 및 정책을 모두 제거하려면 아래 주석 블록 실행:
--
-- DROP POLICY IF EXISTS "campaign_images_select" ON storage.objects;
-- DROP POLICY IF EXISTS "campaign_images_insert" ON storage.objects;
-- DROP POLICY IF EXISTS "campaign_images_update" ON storage.objects;
-- DROP POLICY IF EXISTS "campaign_images_delete" ON storage.objects;
-- DELETE FROM storage.buckets WHERE id = 'campaign-images';
-- ============================================

-- ============================================
-- 검증 쿼리 (적용 후 실행)
-- ============================================
-- 1. 버킷 확인
-- SELECT id, name, public FROM storage.buckets WHERE id = 'campaign-images';
-- 기대값: id='campaign-images', name='campaign-images', public=true

-- 2. 정책 확인
-- SELECT policyname, cmd, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'storage' AND tablename = 'objects';
-- 기대값: 4개 정책 (select/insert/update/delete) 존재

-- 3. 업로드 테스트 (관리자 계정으로 로그인 후 캠페인 등록 화면에서 이미지 업로드 시도)
-- 성공 시 storage.objects에 행이 생기고 img1~img8 컬럼에 URL이 저장됨
