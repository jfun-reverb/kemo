-- ============================================================
-- 229_outbound_influencer_images_bucket.sql
-- 인플루언서 추천 도구 1단계-a — 4/4 (Storage 버킷)
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md §B-① 콘텐츠
-- 인계서: docs/specs/2026-07-09-influencer-recommendation-stage1-handoff.md §PR-a 4번 항목
--
-- outbound-influencer-images: outbound_influencers.rep_image_path(대표 이미지)와
--   rep_posts[].thumb_path(대표 게시물 썸네일)가 가리키는 공개 읽기 버킷.
--   경로 패턴: {outbound_influencers.id}/{난수}.{ext}
--   (orient-images 처럼 토큰 검증이 필요한 익명 업로드가 아니라, 업로드 주체가
--   항상 로그인한 관리자이므로 200_orient_upload_bucket_and_policy.sql 의
--   토큰 검증 헬퍼 함수 패턴은 불필요 — has_permission() 직접 사용으로 단순화.)
--
-- 읽기: public(anon+authenticated) — 관리자 페인(imgThumb 재사용, PR 1단계-b)과
--   향후 브랜드 뷰(5단계)가 모두 같은 공개 URL로 이미지를 표시해야 하므로.
-- 쓰기: has_permission('outbound.view', 'write') 이상만(로그인 관리자, anon 불가).
--
-- ⚠️ has_permission() vs is_campaign_admin() 판정 (개발 세션 검증 메모):
--   기존 storage.objects 정책은 is_admin()/is_campaign_admin() 만 써왔다(053/062/
--   144/163 마이그레이션 — has_permission() 을 storage.objects 에 쓴 선례는 없음).
--   그러나 두 함수는 같은 클래스(SECURITY DEFINER + STABLE + public 스키마 테이블
--   조회 + auth.uid())라, storage.objects RLS 표현식이 임의의 boolean 함수를 호출할
--   수 있는 한(기존 선례가 이미 증명) has_permission() 도 동일하게 동작해야 한다 —
--   storage RLS 는 별도 엔진이 아니라 동일 PostgreSQL RLS 메커니즘. 정적으로는
--   차단 요인을 찾지 못했다. 다만 SQL Editor 는 auth.uid() 가 없는 postgres
--   슈퍼유저 세션이라 "함수가 storage 컨텍스트에서 true 를 반환하는지"는 실제
--   로그인 관리자 세션의 업로드 시도(PR 1단계-b 화면 완성 후)로만 최종 확인 가능.
--   → 1단계-b 착수 시 campaign_admin 계정으로 실제 업로드 1회 스모크 테스트 필수.
--   실패 시 폴백: 아래 두 정책의 has_permission('outbound.view','write') 를
--   is_campaign_admin() 으로 교체하는 롤백 스니펫을 파일 하단에 준비해둠.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- A. Storage 버킷 outbound-influencer-images 생성 (멱등)
-- ============================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'outbound-influencer-images',
  'outbound-influencer-images',
  true,          -- 공개 읽기 버킷 (imgThumb 헬퍼 재사용 전제)
  5242880,       -- 5 MB = 5 * 1024 * 1024 바이트
  ARRAY[
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/webp'
  ]
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ============================================================
-- B. Storage 행 단위 보안 정책 (DROP POLICY IF EXISTS → CREATE POLICY, 멱등)
-- ============================================================

-- ---- B-1. SELECT — 공개 읽기 (익명 + 인증 모두) ----
DROP POLICY IF EXISTS "outbound_images_public_select" ON storage.objects;
CREATE POLICY "outbound_images_public_select"
  ON storage.objects
  FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'outbound-influencer-images');

-- ---- B-2. INSERT — 관리자 쓰기(outbound.view write 이상) ----
DROP POLICY IF EXISTS "outbound_images_admin_insert" ON storage.objects;
CREATE POLICY "outbound_images_admin_insert"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'outbound-influencer-images'
    AND public.has_permission('outbound.view', 'write')
  );

-- ---- B-3. UPDATE — 관리자 쓰기(outbound.view write 이상) ----
DROP POLICY IF EXISTS "outbound_images_admin_update" ON storage.objects;
CREATE POLICY "outbound_images_admin_update"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'outbound-influencer-images'
    AND public.has_permission('outbound.view', 'write')
  )
  WITH CHECK (
    bucket_id = 'outbound-influencer-images'
    AND public.has_permission('outbound.view', 'write')
  );

-- ---- B-4. DELETE — 관리자 쓰기(outbound.view write 이상) ----
DROP POLICY IF EXISTS "outbound_images_admin_delete" ON storage.objects;
CREATE POLICY "outbound_images_admin_delete"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'outbound-influencer-images'
    AND public.has_permission('outbound.view', 'write')
  );

NOTIFY pgrst, 'reload schema';

COMMIT;

-- =============================================================================
-- 적용 안내 (개발서버 SQL Editor에서 실행 — 운영은 1단계-a 전체 검증 후 별도 적용)
--   https://supabase.com/dashboard/project/qysmxtipobomefudyixw/sql/new
-- =============================================================================
--
-- 검증 SQL (1단계씩 순차 실행 — 결과 확인 후 다음 단계 진행)
--
-- ▶ 1단계: 버킷 생성 확인
-- SELECT id, name, public, file_size_limit, allowed_mime_types
--   FROM storage.buckets
--  WHERE id = 'outbound-influencer-images';
-- 기대: 1행, public=true, file_size_limit=5242880, mime 4종
--
-- ▶ 2단계: 행 단위 보안 정책 4개 확인 (1단계 결과 OK 후 실행)
-- SELECT policyname, cmd, roles::text
--   FROM pg_policies
--  WHERE schemaname = 'storage'
--    AND tablename  = 'objects'
--    AND policyname LIKE 'outbound_images_%'
--  ORDER BY policyname;
-- 기대: 4행 — select(anon+authenticated) / insert·update·delete(authenticated)
--
-- ▶ 3단계: 실사용 스모크 테스트 (PR 1단계-b 화면에서 campaign_admin 계정으로
--   실제 이미지 1장 업로드 성공 여부 확인 — SQL Editor 만으로는 auth.uid() 가
--   없어 최종 검증 불가, 반드시 로그인 세션에서 확인)
--
-- =============================================================================

-- ============================================================
-- 롤백 (전체)
-- ============================================================
-- DROP POLICY IF EXISTS "outbound_images_admin_delete" ON storage.objects;
-- DROP POLICY IF EXISTS "outbound_images_admin_update" ON storage.objects;
-- DROP POLICY IF EXISTS "outbound_images_admin_insert" ON storage.objects;
-- DROP POLICY IF EXISTS "outbound_images_public_select" ON storage.objects;
-- DELETE FROM storage.objects WHERE bucket_id = 'outbound-influencer-images';
-- DELETE FROM storage.buckets WHERE id = 'outbound-influencer-images';

-- ============================================================
-- 폴백 (has_permission() 이 storage.objects 컨텍스트에서 예상과 다르게 동작할 경우만 실행)
--   기존 admin_proxy_evidence(163)·brand_docs(053) 선례와 동일하게
--   is_campaign_admin() 으로 교체 — campaign_manager 도 쓰기 가능해지는 완화이므로
--   반드시 사용자 확인 후 적용할 것(권한 등급이 outbound.view=hidden 인 매니저에게
--   쓰기가 열리는 회귀).
-- ============================================================
-- DROP POLICY IF EXISTS "outbound_images_admin_insert" ON storage.objects;
-- CREATE POLICY "outbound_images_admin_insert"
--   ON storage.objects FOR INSERT TO authenticated
--   WITH CHECK (bucket_id = 'outbound-influencer-images' AND public.is_campaign_admin());
--
-- DROP POLICY IF EXISTS "outbound_images_admin_update" ON storage.objects;
-- CREATE POLICY "outbound_images_admin_update"
--   ON storage.objects FOR UPDATE TO authenticated
--   USING (bucket_id = 'outbound-influencer-images' AND public.is_campaign_admin())
--   WITH CHECK (bucket_id = 'outbound-influencer-images' AND public.is_campaign_admin());
--
-- DROP POLICY IF EXISTS "outbound_images_admin_delete" ON storage.objects;
-- CREATE POLICY "outbound_images_admin_delete"
--   ON storage.objects FOR DELETE TO authenticated
--   USING (bucket_id = 'outbound-influencer-images' AND public.is_campaign_admin());
