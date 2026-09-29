-- ════════════════════════════════════════════════════════════════════
-- migration 473: campaign-images 「회원 영수증 올리기」 정책을 저장소로 옮겨 적는다
--                (동작 변경 없음 — 정의처 되찾기)
-- ────────────────────────────────────────────────────────────────────
-- 사양서: docs/specs/2026-09-29-storage-bucket-listing-lockdown.md §3-4 (마이그레이션 B)
--
-- 왜: 정책 `receipts_insert_authenticated` 는 운영·개발 데이터베이스에 있는데
--     **저장소 마이그레이션 어디에도 정의가 없다**(대시보드에서 손으로 만든 것으로
--     보인다). 새 환경을 만들면 회원이 영수증을 못 올리게 되고, 누가 이 정책을
--     고쳐도 기록이 남지 않는다.
--
-- 단계 0 조회(2026-09-29, 사양서 §10): 운영·개발 **둘 다** 아래와 글자 그대로
--   같은 정의로 이미 있다 → 이 파일을 적용해도 두 곳 모두 동작이 바뀌지 않는다.
--     receipts_insert_authenticated | INSERT | {authenticated}
--     WITH CHECK ((bucket_id = 'campaign-images') AND ((storage.foldername(name))[1] = 'receipts'))
--
-- ⚠️ 이 정책은 회원 누구나 `receipts/` 폴더에 파일을 넣게 한다(본인 폴더 제한 없음).
--    좁히는 것은 이 사양서 범위 밖 — 그대로 옮겨 적기만 한다.
--
-- 순서: 474(조회 정책 교체)보다 먼저 적용한다(사양서 §3-5).
--
-- ── 롤백 ─────────────────────────────────────────────────────────────
--   이 파일은 이미 있던 정의를 다시 쓸 뿐이라 되돌릴 대상이 없다.
--   (정책 자체를 없애면 회원 영수증 올리기가 막히므로 DROP 만 하는 롤백은 하지 말 것)
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DROP POLICY IF EXISTS "receipts_insert_authenticated" ON storage.objects;

CREATE POLICY "receipts_insert_authenticated"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'campaign-images' AND (storage.foldername(name))[1] = 'receipts');

COMMENT ON POLICY "receipts_insert_authenticated" ON storage.objects IS
  '[473] 대시보드에서 만들어져 저장소에 정의가 없던 정책을 글자 그대로 옮겨 적음(동작 무변경). '
  '회원이 campaign-images/receipts/ 에 영수증·인증샷을 올리는 유일한 넣기 정책 — 지우면 회원 제출이 막힌다.';

COMMIT;

-- 검증 — 정의 확인(메타데이터라 SQL 편집기로 충분)
--   SELECT policyname, cmd, roles::text, with_check FROM pg_policies
--    WHERE schemaname='storage' AND tablename='objects' AND policyname='receipts_insert_authenticated';
--   기대: INSERT · {authenticated} · 위 CHECK 와 같은 식
