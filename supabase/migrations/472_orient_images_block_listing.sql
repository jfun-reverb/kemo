-- ════════════════════════════════════════════════════════════════════
-- migration 472: orient-images 버킷 — 「목록 조회」를 관리자만으로 좁힌다
--                (공개 링크 열람·브랜드 익명 업로드는 그대로)
-- ────────────────────────────────────────────────────────────────────
-- 근거: 2026-09-29 운영 Supabase 보안 점검(Security Advisor) 분류
--       — 「공개 통 목록 조회 허용」 경고 중 실제 위험 1건.
--
-- ── 실측(2026-09-29, 운영, 비로그인 공개 키) ─────────────────────────
--   `POST /storage/v1/object/list/orient-images` → 200, 최상위 폴더 이름이
--   그대로 나온다. 폴더 이름 = 오리엔시트 작성 토큰(uuid 36자, 마이그레이션
--   200 의 경로 규칙 `{token}/{난수}.{ext}`). 토큰이 있으면
--   get_orient_sheet · save_orient_draft · submit_orient_sheet 로 **남의
--   브랜드 시트를 읽고 고칠 수 있다**(발행·만료 시트 제외).
--
--   200 주석은 「경로가 추측 불가 토큰이라 노출 위험이 낮다」고 했지만,
--   목록 조회가 열려 있어 **추측할 필요가 없었다.** 311(campaign-images)이
--   같은 구멍을 2026-08 에 막았는데 이 통만 남아 있었다.
--
-- ── 무엇을 바꾸나 ────────────────────────────────────────────────────
--   SELECT 정책 `orient_images_public_select` 한 개만.
--     전: TO anon, authenticated · USING (bucket_id = 'orient-images')
--     후: TO authenticated        · USING (bucket_id = 'orient-images' AND public.is_admin())
--
--   ⚠️ 311 처럼 `TO authenticated` 로만 좁히지 않는다 — 회원가입이 열려
--      있어 로그인한 회원이면 누구나 목록을 볼 수 있게 되고, 그러면 막은
--      의미가 없다(토큰은 회원이 봐서도 안 된다). 목록을 부르는 코드는
--      저장소 어디에도 없다(작성 폼은 upload + getPublicUrl 만, 관리자
--      화면은 저장된 공개 주소만 쓴다 — 2026-09-29 전수 검색).
--
-- ── 바뀌지 않는 것 ───────────────────────────────────────────────────
--   ① 공개 링크 열람 — 버킷 public=true 는 그대로. /object/public/… 경로는
--      이 행 단위 보안 정책을 거치지 않는다(311 과 같은 근거).
--   ② 브랜드 익명 업로드 — INSERT 정책 `orient_images_anon_insert` 무변경.
--      작성 폼은 `upload(…, { upsert: false })` 라 SELECT 정책이 필요 없다
--      (덮어쓰기[upsert:true]일 때만 SELECT·UPDATE 가 추가로 필요).
--      🔴 **개발서버에서 실제 파일 업로드로 반드시 확인**할 것 — 이
--      가정이 틀리면 브랜드가 예시 이미지를 못 올린다(폼은 주소 직접
--      입력으로 폴백하지만 업로드 칸은 실패로 보인다).
--
-- ── 이미 새어 나간 토큰 ─────────────────────────────────────────────
--   이 마이그레이션은 **앞으로의** 목록 조회만 막는다. 그전에 누가 목록을
--   받아 갔다면 그 토큰은 여전히 유효하다(만료·발행 전까지). 토큰 교체는
--   브랜드가 가진 링크를 끊으므로 별도 판단(이 파일 범위 밖).
--
-- ── 롤백 ─────────────────────────────────────────────────────────────
--   BEGIN;
--     DROP POLICY IF EXISTS "orient_images_public_select" ON storage.objects;
--     CREATE POLICY "orient_images_public_select"
--       ON storage.objects FOR SELECT TO anon, authenticated
--       USING (bucket_id = 'orient-images');
--   COMMIT;
--   -- 200 원본으로 복원 — 익명 목록 조회가 다시 열린다.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DROP POLICY IF EXISTS "orient_images_public_select" ON storage.objects;

CREATE POLICY "orient_images_public_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'orient-images' AND public.is_admin());

COMMENT ON POLICY "orient_images_public_select" ON storage.objects IS
  '[472] 목록·API 조회를 관리자만으로 좁힘(200 원본은 anon·authenticated 전원). '
  '목적: 폴더 이름 = 오리엔시트 작성 토큰 노출 차단(2026-09-29 운영 실측). '
  '버킷 public=true 는 무변경이라 /object/public/ 공개 링크는 계속 열린다. '
  '익명 업로드(INSERT 정책)도 무변경 — upsert:false 업로드는 SELECT 불필요.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 검증 — 1단계씩. ⚠️ 2·3·4 단계는 SQL 편집기로 재현되지 않는다(서비스 키는
--   행 단위 보안 정책을 우회). 실제 HTTP 요청·실제 브라우저로 볼 것.
-- ════════════════════════════════════════════════════════════════════
-- 1단계 — 정책 정의(메타데이터라 SQL 편집기로 충분)
--   SELECT policyname, cmd, roles::text, qual
--     FROM pg_policies
--    WHERE schemaname = 'storage' AND tablename = 'objects'
--      AND policyname LIKE 'orient_images_%';
--   기대: _anon_insert (INSERT, {anon,authenticated}) +
--         _public_select (SELECT, {authenticated}, qual 에 is_admin())
--
-- 2단계 — 비로그인 목록 조회가 빈 배열인가(공개 키만 실어 호출)
--   POST {SUPABASE_URL}/storage/v1/object/list/orient-images
--     headers: apikey / Authorization: Bearer {공개 키}
--     body   : {"prefix":"","limit":10}
--   기대: 200 + []   (적용 전: 폴더 이름 목록)
--
-- 3단계 — 기존 파일 공개 링크가 여전히 열리는가
--   GET {SUPABASE_URL}/storage/v1/object/public/orient-images/{기존 경로}
--   기대: 200 + 이미지 (캐시 우회 인자를 붙여 볼 것)
--
-- 4단계 — 작성 폼에서 실제 파일 업로드(개발서버, 살아 있는 시트 링크)
--   기대: 업로드 성공 + 칸에 파일 표시 + 저장 뒤 관리자 상세에서 링크 열림
--
-- ── 개발서버 적용·검증 결과 (2026-09-29) ─────────────────────────────
--   적용 전: 비로그인 목록 조회 → 작성 토큰 폴더 이름이 그대로 나옴(재현)
--   1단계: anon_insert {anon} · public_select {authenticated} + is_admin() ✅
--   2단계: 비로그인 최상위 목록 [] · 알려진 토큰 폴더 안 목록도 [] ✅
--   3단계: 기존 파일 공개 링크 200 image/jpeg ✅
--   4단계: 비로그인 업로드(x-upsert:false, 살아 있는 토큰) 성공 → 공개 링크 200 ✅
--          가짜 토큰 업로드는 403(INSERT 정책 그대로) ✅
--          (작성 폼과 같은 저장소 호출을 curl 로 실제 파일과 함께 보냄.
--           시험 파일 1개가 개발 draft 시트 폴더에 남아 있다 — 시트 데이터에는 연결 안 됨)
