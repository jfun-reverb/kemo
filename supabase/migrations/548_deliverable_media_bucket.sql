-- ============================================================
-- 548_deliverable_media_bucket.sql
-- 2026-10-19 — 영수증 사진 비공개 저장소(통) `deliverable-media` + 정책
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 5」(통·정책 부분 — 서버 함수 brand-campaign-results 는 따로 배포)
--   결정 D1(영수증만 — 리뷰 인증샷은 공개 통 campaign-images 그대로) · S13
--   사양서 docs/specs/2026-07-15-brand-portal.md §4 「영수증 사진 비공개 이전」 ①~③
--
-- 무엇을 하나 (통 하나 · 정책 넷 · 내부 함수 하나 — 표 변경 없음)
--   통   deliverable-media — 비공개(public=false). 공개 주소(/object/public/…)로는 열리지 않는다 — 서명 주소로만.
--   함수 _deliverable_media_owner_ok — 조회 정책의 올린 사람 대조(회원에게 안 보이는 관리자 표를 본다)
--   정책 넣기   : 로그인 회원이 receipts/ 폴더에만 · 🔴 브랜드 계정 거부(앱 메타데이터 account_kind='brand' — 브랜드 계정도 로그인 사용자다)
--   정책 조회   : 관리자 · 올린 본인(owner) · 🔴 그 경로를 가리키는 **자기** 영수증 줄의 회원 — 단 파일을 올린 사람이 그 회원이거나 그 줄을 대리 등록한 관리자일 때만
--                 (receipt_url 은 회원이 직접 쓸 수 있는 칸이라 경로만 맞추면 남의 파일을 볼 수 있다 — 올린 사람 대조가 그 구멍을 막는다. 판정 _deliverable_media_owner_ok)
--   정책 덮어쓰기: 올린 본인 · 관리자 — 썸네일 저장이 upsert:true(474 와 같은 이유 · 관리자가 회원 파일 썸네일을 다시 만들 때)
--   정책 지우기 : 관리자 — 캠페인 보관 삭제·감사용 청소(화면이 관리자 로그인으로 지운다). 탈퇴 파기는 서비스 키라 정책과 무관
--   적용만으로 바뀌는 기존 동작: 없음(아직 아무도 이 통에 올리지 않는다 — 올리는 쪽 전환은 조각 7, 출시 날 ⑤).
--
-- 🔴 운영 반영 — 작업표 「사전」 단계(빈 통이라 무해 · 조각 6 이 통 이름을 쓴다).
--
-- 저장 형식(조각 6·7·8 의 계약)
--   deliverables.receipt_url 에 **이 통 안의 경로**만 적는다 — 지금 올리는 이름은 `receipts/<시각>_<무작위 6자>.jpg`(storage.js — 회원 폴더 없음, 옛 공개 전체 주소와 「://」 유무로 갈린다).
--   🔴 복사 도구(조각 8)는 서비스 키로 올리므로 owner 가 비는데, 그러면 회원이 자기 파일을 못 본다 — 올린 뒤 owner_id 를 그 회원 아이디로 적는다(조각 8 계약).
--   ⚠️ 회원이 자기 임시저장 영수증을 지우는 길이 생기면 지우기 정책(관리자만)을 함께 넓힌다(조각 7). 탈퇴 파기·감사용 청소·캠페인 보관 삭제의 경로 추출은 공개 주소 접두사 기준이라 조각 6 이 통 경로를 받게 고친다.
--   썸네일은 `{첫 칸}/thumb/{나머지}` — 주소 규칙(_thumbPathOf·storageThumbUrl·purge-withdrawal-media withThumbs)과 같다.
--   🔴 브랜드 화면은 저장소 정책이 아니라 서버 함수 brand-campaign-results 가 서명한 주소만 쓴다(브랜드 계정에는 이 통 정책을 열지 않는다).
--
-- 롤백(통이 비어 있을 때만 — 조각 7 이 나가기 전):
--   DROP POLICY IF EXISTS deliverable_media_insert ON storage.objects;
--   DROP POLICY IF EXISTS deliverable_media_select ON storage.objects;
--   DROP POLICY IF EXISTS deliverable_media_update ON storage.objects;
--   DROP POLICY IF EXISTS deliverable_media_delete ON storage.objects;
--   DROP FUNCTION IF EXISTS public._deliverable_media_owner_ok(text, uuid, uuid);
--   통은 대시보드 Storage 에서 비운 뒤 지운다(SQL 로 통 삭제를 막는 경우가 있다).
-- 편집기 경고: 실행 구문에 DROP POLICY IF EXISTS(멱등 재실행용)가 있다. DELETE 없음.
-- ============================================================

BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'deliverable-media',
  'deliverable-media',
  false,         -- 🔴 비공개
  10485760,      -- 10 MB(영수증 원본은 압축하지 않는다 — 「영수증에서 읽기」가 글자를 읽는다)
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 올린 사람 대조 — 회원 본인 또는 그 줄을 대리 등록한 관리자(admins.id → auth_id). 관리자 표는 회원에게 안 보여 정의자 권한으로 본다
CREATE OR REPLACE FUNCTION public._deliverable_media_owner_ok(p_owner text, p_user uuid, p_proxy_admin uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_owner IS NOT NULL AND (
           p_owner = p_user::text
           OR (p_proxy_admin IS NOT NULL
               AND EXISTS (SELECT 1 FROM public.admins a WHERE a.id = p_proxy_admin AND a.auth_id::text = p_owner)));
$$;
-- 정책 안에서 회원 역할로 불리므로 authenticated 에 연다(돌려주는 것은 참·거짓 하나)
GRANT  EXECUTE ON FUNCTION public._deliverable_media_owner_ok(text, uuid, uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._deliverable_media_owner_ok(text, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._deliverable_media_owner_ok(text, uuid, uuid) FROM anon;

-- 넣기 — 로그인 회원 · receipts/ 폴더 · 브랜드 계정 아님
DROP POLICY IF EXISTS deliverable_media_insert ON storage.objects;
CREATE POLICY deliverable_media_insert
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'deliverable-media'
    AND (storage.foldername(name))[1] = 'receipts'
    AND coalesce((SELECT auth.jwt()) -> 'app_metadata' ->> 'account_kind', '') <> 'brand'
  );

-- 조회 — 관리자 · 올린 본인 · 그 경로(또는 그 썸네일)를 가리키는 영수증 줄의 회원
DROP POLICY IF EXISTS deliverable_media_select ON storage.objects;
CREATE POLICY deliverable_media_select
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'deliverable-media'
    AND (
      (SELECT public.is_admin())
      OR owner_id = (SELECT auth.uid())::text
      OR EXISTS (
        SELECT 1 FROM public.deliverables d
         WHERE d.user_id = (SELECT auth.uid())
           AND d.kind = 'receipt'
           AND (d.receipt_url = storage.objects.name
                OR regexp_replace(d.receipt_url, '^([^/]+)/', '\1/thumb/') = storage.objects.name)
           AND public._deliverable_media_owner_ok(storage.objects.owner_id, d.user_id, d.submitted_by_admin)
      )
    )
  );

-- 덮어쓰기 — 올린 본인 · 관리자(썸네일 upsert)
DROP POLICY IF EXISTS deliverable_media_update ON storage.objects;
CREATE POLICY deliverable_media_update
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (bucket_id = 'deliverable-media' AND (owner_id = (SELECT auth.uid())::text OR (SELECT public.is_admin())))
  WITH CHECK (bucket_id = 'deliverable-media' AND (owner_id = (SELECT auth.uid())::text OR (SELECT public.is_admin())));

-- 지우기 — 관리자
DROP POLICY IF EXISTS deliverable_media_delete ON storage.objects;
CREATE POLICY deliverable_media_delete
  ON storage.objects FOR DELETE
  TO authenticated
  USING (bucket_id = 'deliverable-media' AND (SELECT public.is_admin()));

COMMENT ON POLICY deliverable_media_select ON storage.objects IS
  '[548] 비공개 영수증 통 조회 — 관리자·올린 본인·그 영수증 줄의 회원(썸네일 포함). 브랜드는 서버 함수 brand-campaign-results 의 서명 주소로만.';
COMMENT ON POLICY deliverable_media_insert ON storage.objects IS
  '[548] 비공개 영수증 통 넣기 — 로그인 회원이 receipts/ 에만, 브랜드 계정 거부.';

COMMIT;

-- ============================================================
-- 검증
--   [V1] SELECT id, public FROM storage.buckets WHERE id='deliverable-media';  → public=false
--        SELECT policyname, cmd FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname LIKE 'deliverable_media_%';  → 넷
--   [V2] 🔴 로그인 브라우저: 회원으로 receipts/ 에 올리기 성공 · 브랜드 계정으로 올리기 거부 · 공개 주소로 열면 거부 · 서명 주소로 열림
-- ============================================================
