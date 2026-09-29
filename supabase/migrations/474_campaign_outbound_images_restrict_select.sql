-- ════════════════════════════════════════════════════════════════════
-- migration 474: campaign-images · outbound-influencer-images 조회 정책을 좁힌다
--                (공개 링크 열람은 그대로)
-- ────────────────────────────────────────────────────────────────────
-- 사양서: docs/specs/2026-09-29-storage-bucket-listing-lockdown.md §3-2·§3-3 (마이그레이션 C)
-- 선행: 473(회원 영수증 올리기 정책 옮겨 적기)
--
-- ── 무엇을 바꾸나 ────────────────────────────────────────────────────
--   ① campaign_images_select (311 원본)
--      전: TO authenticated · USING (bucket_id = 'campaign-images')
--      후: TO authenticated · USING (bucket_id = 'campaign-images'
--                                    AND (public.is_admin() OR owner_id = auth.uid()::text))
--      → 회원이 목록을 받으면 **자기가 올린 파일만** 나온다(311 은 로그인만 하면
--        남의 영수증 파일 이름까지 전부 받을 수 있었다 — 가입이 열려 있어 사실상 공개).
--      ⚠️ 회원 조회를 통째로 닫지 않는 이유: 회원 썸네일 저장(`_uploadThumbCopy`,
--        storage.js)이 `upsert: true` 다. 경로가 매번 새 이름(시각+난수)이라 덮어쓸
--        기존 행이 없어 사실상 넣기만 일어나지만, 저장소 내부의 조회 필요 여부는
--        정적 검토로 확정할 수 없어 본인 파일 조회를 남겨 둔다(검증 4 로 실측).
--      ⚠️ `owner_id` 가 비어 있는 옛 파일(운영 1,210개)은 회원 목록에 안 나온다 —
--        회원이 목록을 쓰는 화면은 없다.
--
--   ② outbound_images_public_select (229 원본)
--      전: TO anon, authenticated · USING (bucket_id = 'outbound-influencer-images')
--      후: TO authenticated · USING (bucket_id = 'outbound-influencer-images'
--                                    AND public.has_permission('outbound.view','read'))
--      → 같은 통의 넣기·수정·지우기 정책이 쓰는 권한 열쇠말과 같다(쓰기 대신 읽기 수준).
--        캠페인 매니저(hidden)에게는 닫힌다.
--
-- ── 바뀌지 않는 것 ───────────────────────────────────────────────────
--   성능: 권한 함수는 (SELECT …) 로 감쌌다 — 행마다가 아니라 한 번만 계산(415 와 같은 방식).
--   두 통 모두 public=true 그대로 → /object/public/… 공개 링크는 이 정책과 무관하게 열린다.
--   넣기·수정·지우기 정책은 손대지 않는다.
--
-- ── 롤백 ─────────────────────────────────────────────────────────────
--   BEGIN;
--     DROP POLICY IF EXISTS "campaign_images_select" ON storage.objects;
--     CREATE POLICY "campaign_images_select" ON storage.objects FOR SELECT
--       TO authenticated USING (bucket_id = 'campaign-images');
--     DROP POLICY IF EXISTS "outbound_images_public_select" ON storage.objects;
--     CREATE POLICY "outbound_images_public_select" ON storage.objects FOR SELECT
--       TO anon, authenticated USING (bucket_id = 'outbound-influencer-images');
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DROP POLICY IF EXISTS "campaign_images_select" ON storage.objects;
CREATE POLICY "campaign_images_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'campaign-images' AND ((SELECT public.is_admin()) OR owner_id = (SELECT auth.uid())::text));

DROP POLICY IF EXISTS "outbound_images_public_select" ON storage.objects;
CREATE POLICY "outbound_images_public_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'outbound-influencer-images' AND (SELECT public.has_permission('outbound.view', 'read')));

COMMENT ON POLICY "campaign_images_select" ON storage.objects IS
  '[474] 311(로그인 누구나)에서 관리자 또는 본인이 올린 파일(owner_id)로 좁힘. '
  '회원 썸네일 저장(upsert:true)이 본인 파일 조회에 기대므로 owner 조건을 빼지 말 것. 공개 링크는 무관.';
COMMENT ON POLICY "outbound_images_public_select" ON storage.objects IS
  '[474] 229(비로그인 포함 전원)에서 outbound.view 읽기 권한 관리자로 좁힘. 공개 링크는 무관.';

COMMIT;

-- 검증 — 사양서 §6 검증 4~9. SQL 편집기(서비스 키)로는 정책이 평가되지 않으니
-- 실제 요청·실제 로그인 브라우저로 볼 것.
--
-- ── 개발서버 적용·검증 결과 (2026-09-29) ─────────────────────────────
--   473 적용 → 정의 전·후 글자 동일(동작 무변경) 확인
--   검증 4 「앞」(473 뒤·474 전): 시험 회원 sakura 로 활동관리에서 영수증 「리스트에 추가」
--          → receipts/…gcarjq.jpg + receipts/thumb/…gcarjq.jpg 둘 다 생성, owner_id = 그 회원
--   474 적용 → 두 정책 정의 확인((SELECT …) 감싸기 반영)
--   검증 4 「뒤」: 같은 방법으로 다시 → 원본 + 썸네일(…kozbp5.jpg) 둘 다 생성 ✅
--   검증 5(회원 쪽): 회원 목록 조회 receipts = 7건 = 데이터베이스상 그 회원 소유 7건,
--          다른 회원 18건은 안 보임 ✅ · campaigns 폴더 0건 · 아웃바운드 통 0건
--   (덤) 472 검증 2 회원 쪽: orient-images 최상위·시트 폴더 안 모두 0건 ✅
--   남은 것: 관리자 쪽 대조(검증 5)·검증 6~8 — 관리자 로그인 필요
--   시험 뒤 활동관리 임시 항목은 지워 원상복구(저장소 파일은 남음)
