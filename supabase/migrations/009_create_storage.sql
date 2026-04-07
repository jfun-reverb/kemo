-- ============================================
-- REVERB JP — 이미지 저장소 (Supabase Storage)
-- 캠페인 이미지를 Storage에 저장하고 DB에는 URL만 저장
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- ══════════════════════════════════════
-- 1. campaign-images 버킷 생성
-- ══════════════════════════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('campaign-images', 'campaign-images', true)
ON CONFLICT (id) DO NOTHING;

-- ══════════════════════════════════════
-- 2. Storage 정책 — 누구나 이미지 조회 가능
-- ══════════════════════════════════════
CREATE POLICY "campaign_images_select"
ON storage.objects FOR SELECT
USING (bucket_id = 'campaign-images');

-- ══════════════════════════════════════
-- 3. Storage 정책 — 관리자만 업로드/수정/삭제
-- ══════════════════════════════════════
CREATE POLICY "campaign_images_insert"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);

CREATE POLICY "campaign_images_update"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);

CREATE POLICY "campaign_images_delete"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'campaign-images'
  AND EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid())
);
