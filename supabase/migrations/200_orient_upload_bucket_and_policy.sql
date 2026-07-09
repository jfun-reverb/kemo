-- =============================================================================
-- 마이그레이션 200: orient-images Storage 버킷 + 익명 업로드 정책
-- 제목    : 브랜드 셀프 오리엔시트 예시 이미지·파일 업로드 인프라 (PR 1)
-- 의존    : 186 (orient_sheets 테이블)
--            187 (save_orient_draft·submit_orient_sheet·get_orient_sheet 토큰 함수 패턴)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-06-26
-- 브랜치  : feature/orient-form-cards
-- 위험도  : 낮음
--           - 신규 버킷·헬퍼 함수·정책 추가만 (기존 테이블·함수 수정 없음)
--           - orient_sheets 행 단위 보안 정책(RLS) 무변경
--           - 기존 버킷(campaign-images 등) 영향 없음
-- 멱등성  : INSERT INTO storage.buckets ON CONFLICT DO UPDATE
--            DROP POLICY IF EXISTS → CREATE POLICY
--            CREATE OR REPLACE FUNCTION
--
-- 변경 요약:
--
--   [A] 헬퍼 함수  public.orient_token_can_upload(p_token text) → boolean
--       - SECURITY DEFINER: 익명(anon)이 직접 조회할 수 없는 orient_sheets를
--         소유자(postgres) 권한으로 우회 검증
--       - p_token이 UUID 형식이 아니면 내부 예외 블록에서 잡아 false 반환
--         (정책 평가 오류가 밖으로 전파되지 않음)
--       - 유효 조건: token 존재 + status IN ('draft','submitted') + 만료 전
--       - SET search_path='': 보안 규칙 필수 (공개 schema 탈취 방어)
--       - GRANT EXECUTE to anon: INSERT 정책 평가 중 익명이 이 함수를 호출해야 함
--
--   [B] Storage 버킷 orient-images 생성 (멱등)
--       - public=true  : /storage/v1/object/public/orient-images/… URL 공개 읽기 허용
--       - 파일 크기    : 최대 10 MB (= 10,485,760 바이트)
--       - 허용 MIME    : 이미지(jpeg·png·webp) + 문서(pdf·docx·xlsx·pptx)
--                        ※ image/svg+xml·text/html 제외 (XSS·코드 삽입 위험)
--
--   [C] Storage 행 단위 보안 정책 2개
--       - INSERT (익명 anon): 유효 토큰 폴더({token}/…)에만 업로드 허용
--       - SELECT (익명 + 인증 authenticated): 공개 읽기
--       - UPDATE·DELETE 정책은 익명에게 미부여 (업로드 전용)
--         ※ 잘못 올린 파일 정리는 대시보드 수동 제거 또는 후속 마이그레이션에서 추가
--
-- 롤백 방법 (주석):
--   -- 1. 행 단위 보안 정책 제거
--   DROP POLICY IF EXISTS "orient_images_anon_insert"   ON storage.objects;
--   DROP POLICY IF EXISTS "orient_images_public_select" ON storage.objects;
--   -- 2. 버킷 내 파일 먼저 삭제 후 버킷 제거 (데이터 소실 주의)
--   --    대시보드 Storage > orient-images > 전체 삭제 후:
--   DELETE FROM storage.objects WHERE bucket_id = 'orient-images';
--   DELETE FROM storage.buckets WHERE id        = 'orient-images';
--   -- 3. 헬퍼 함수 제거
--   DROP FUNCTION IF EXISTS public.orient_token_can_upload(text);
-- =============================================================================

BEGIN;


-- ============================================================
-- A. 헬퍼 함수: public.orient_token_can_upload(p_token text)
--
--   배경 — "왜 헬퍼 함수가 필요한가":
--     orient_sheets 테이블은 익명(anon)에게 SELECT 정책이 0개(186 설계 의도).
--     Storage INSERT 행 단위 보안 정책 표현식에서 익명 세션이 직접
--     EXISTS (SELECT … FROM public.orient_sheets …) 를 실행하면
--     orient_sheets의 행 단위 보안 정책에 막혀 항상 false가 되어 모든 업로드가 차단됨.
--     이 함수를 SECURITY DEFINER로 만들면 함수 소유자(postgres) 권한으로 조회하므로
--     익명의 SELECT 차단을 우회하는 것이 의도된 정상 동작.
--
--   파라미터 타입 text (uuid 아님)  — 3가지 이유:
--     1. storage.foldername(name) 반환 배열의 원소 타입이 text.
--        정책 표현식에서 text 값을 uuid로 캐스팅하면 형식 불일치 시
--        PostgreSQL이 예외를 던지고 정책 평가 전체가 실패함.
--     2. 함수가 text로 받으면 예외를 함수 내부에서 잡을 수 있음.
--     3. 정책 표현식이 단순해짐:
--        public.orient_token_can_upload((storage.foldername(name))[1])
--        처럼 text를 그대로 넘기면 되므로 캐스팅 오류 노출 없음.
--
--   NULL 처리:
--     - p_token IS NULL: NULL::uuid는 오류 없이 NULL 반환.
--                         WHERE token = NULL → 0행 → false. 예외 블록 불필요.
--     - p_token = '' 또는 비-UUID 문자열:
--                         ::uuid 캐스팅 시 invalid_text_representation(22P02) 발생.
--                         EXCEPTION 블록이 잡아 false 반환.
--                         오류가 정책으로 전파되지 않음.
--
--   storage.foldername(name) 동작 참고:
--     경로 '{token}/{파일명}'에서 마지막 원소(파일명)를 제외한 배열 반환.
--     예: 'abc-uuid/img123.jpg' → ARRAY['abc-uuid'] → [1] = 'abc-uuid'
--         'a/b/c.pdf'           → ARRAY['a', 'b']   → [1] = 'a'
--         'only-filename.jpg'   → ARRAY[]            → [1] = NULL → false 반환
--     PostgreSQL 배열은 1부터 시작하므로 [1]이 첫 번째 폴더.
--
--   STABLE 표시:
--     DB를 읽지만 수정하지 않으며, 같은 트랜잭션 내 동일 입력에 동일 결과.
--     파일 1개 업로드 = INSERT 1건 = 단일 트랜잭션이므로 캐싱 부작용 없음.
-- ============================================================

CREATE OR REPLACE FUNCTION public.orient_token_can_upload(p_token text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_token_uuid uuid;
  v_valid      boolean;
BEGIN
  -- ① UUID 형식 검증
  --   잘못된 형식(빈 문자열, 비-UUID 경로, 직접 접근 시도 등)이 올 때
  --   ::uuid 캐스팅이 invalid_text_representation(22P02) 오류를 던짐.
  --   EXCEPTION 블록이 잡아 false를 반환하므로 오류가 정책으로 전파되지 않음.
  BEGIN
    v_token_uuid := p_token::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      RETURN false;
    WHEN OTHERS THEN
      -- 예상치 못한 캐스팅 오류도 방어적으로 false 반환
      RETURN false;
  END;

  -- ② orient_sheets 테이블에서 토큰 유효성 확인
  --   SECURITY DEFINER이므로 소유자(postgres) 권한으로 조회.
  --   익명(anon) 행 단위 보안 정책 우회가 이 함수의 설계 의도.
  --   schema 한정자(public.) 필수 — SET search_path='' 적용 중이므로
  --   스키마 없이 쓰면 "relation not found" 오류 발생.
  SELECT EXISTS (
    SELECT 1
      FROM public.orient_sheets
     WHERE token = v_token_uuid
       AND status IN ('draft', 'submitted')
       AND (
             token_expires_at IS NULL
          OR token_expires_at > now()
           )
  ) INTO v_valid;

  RETURN COALESCE(v_valid, false);
END;
$$;

-- 기본 PUBLIC EXECUTE 권한 REVOKE 후 필요한 역할만 명시 GRANT
--   anon        : INSERT 정책 평가 중 익명 세션이 이 함수를 호출해야 함 (필수)
--   authenticated: 향후 관리자 업로드 정책 추가 시 대비
REVOKE EXECUTE ON FUNCTION public.orient_token_can_upload(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.orient_token_can_upload(text) TO anon, authenticated;

COMMENT ON FUNCTION public.orient_token_can_upload(text) IS
  '[200] orient-images 버킷 익명 업로드 행 단위 보안 정책용 토큰 유효성 검증 헬퍼. '
  'SECURITY DEFINER — 익명(anon) 세션이 직접 조회할 수 없는 orient_sheets를 '
  '소유자 권한으로 우회 조회하는 것이 설계 의도. '
  'p_token이 UUID 형식이 아니면 내부 EXCEPTION 블록에서 false 반환(오류 전파 차단). '
  '유효 조건: 토큰 존재 + status IN (draft,submitted) + 만료 전. '
  'STABLE·SET search_path="" 적용.';


-- ============================================================
-- B. Storage 버킷 orient-images 생성
--
--   public=true:
--     /storage/v1/object/public/orient-images/{경로} URL로
--     인증 없이 파일을 읽을 수 있음 (오리엔시트 폼에서 업로드한 이미지 직접 표시용).
--     행 단위 보안 정책의 SELECT 정책과 이중으로 공개 읽기를 보장.
--
--   파일 크기 제한: 10 MB = 10,485,760 바이트
--
--   허용 MIME 타입 (8종):
--     이미지: image/jpeg, image/jpg(일부 클라이언트 전송 형식), image/png, image/webp
--     문서  : application/pdf
--              application/vnd.openxmlformats-officedocument.wordprocessingml.document  (docx)
--              application/vnd.openxmlformats-officedocument.spreadsheetml.sheet        (xlsx)
--              application/vnd.openxmlformats-officedocument.presentationml.presentation (pptx)
--     제외  : image/svg+xml — SVG는 <script> 태그를 포함할 수 있어 XSS 위험
--              text/html    — HTML 코드 직접 삽입 위험
--
--   ON CONFLICT (id) DO UPDATE:
--     동일 버킷 id가 이미 있으면 설정값을 최신으로 덮어씀 (멱등).
--     개발서버·운영서버 각각 한 번씩 실행해도 무해.
-- ============================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'orient-images',
  'orient-images',
  true,          -- 공개 읽기 버킷
  10485760,      -- 10 MB = 10 * 1024 * 1024 바이트
  ARRAY[
    'image/jpeg',
    'image/jpg',   -- 일부 브라우저·클라이언트가 image/jpeg 대신 전송하는 형식
    'image/png',
    'image/webp',
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',   -- docx
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',         -- xlsx
    'application/vnd.openxmlformats-officedocument.presentationml.presentation'  -- pptx
  ]
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ============================================================
-- C. Storage 행 단위 보안 정책
--
--   배경 — storage.foldername(name) 동작:
--     Supabase Storage 객체 경로(name 컬럼)를 '/'로 분할한 배열 반환.
--     단, 마지막 원소(파일명)는 포함하지 않음.
--
--     경로 예시:
--       '{uuid-token}/abc123.jpg'   → ['uuid-token']  → [1] = 'uuid-token'
--       '{uuid-token}/sub/file.pdf' → ['uuid-token', 'sub'] → [1] = 'uuid-token'
--       'root-only.jpg'             → []              → [1] = NULL
--
--     PostgreSQL 배열은 1부터 시작 인덱스를 사용.
--     [1] = NULL이면 orient_token_can_upload(NULL)이 false 반환.
--
--   INSERT 정책 평가 흐름:
--     1. 익명(anon) 클라이언트가 orient-images/{token}/{파일명} 경로에 PUT
--     2. WITH CHECK 식 평가:
--        - bucket_id = 'orient-images' : 버킷 일치 확인
--        - public.orient_token_can_upload((storage.foldername(name))[1]):
--            첫 번째 폴더 문자열(text)을 함수에 전달
--            → 함수 내부: UUID 캐스팅 시도 → orient_sheets 토큰 조회
--            → true이면 업로드 허용, false이면 거부(HTTP 403)
--     3. 정책 통과 시 Supabase Storage가 허용 MIME·파일 크기도 추가 검증
--        (allowed_mime_types·file_size_limit 버킷 설정 기준)
--
--   멱등성: DROP POLICY IF EXISTS → CREATE POLICY 패턴 (163·144 선례)
-- ============================================================

-- ---- C-1. INSERT — 익명(anon) 토큰 검증 업로드 ----
--   익명 클라이언트가 유효한 토큰 폴더에만 파일을 올릴 수 있도록 제한.
--   잘못된 토큰·만료 토큰·소비된 토큰 폴더에는 403 반환.
DROP POLICY IF EXISTS "orient_images_anon_insert" ON storage.objects;
CREATE POLICY "orient_images_anon_insert"
  ON storage.objects
  FOR INSERT
  TO anon
  WITH CHECK (
    bucket_id = 'orient-images'
    AND public.orient_token_can_upload((storage.foldername(name))[1])
  );

-- ---- C-2. SELECT — 공개 읽기 (익명 + 인증 모두 허용) ----
--   버킷 public=true이므로 공개 URL(/object/public/…)은 정책 없이도 읽기 가능.
--   그러나 PostgREST API(/object/{bucket}/…)를 통한 직접 조회나 목록 나열에도
--   명시 정책이 필요하므로 추가. 버킷 공개와 이중으로 읽기를 보장.
--   ※ 의도된 설계: 버킷 전체 목록 열람을 허용(폴더별 제한 없음). 공개 읽기 버킷이고
--      경로가 추측 불가 UUID 토큰 폴더라 노출 위험이 낮으며, 기존 campaign-images
--      공개 버킷 패턴과 동일. (폴더별 제한이 필요해지면 INSERT 정책처럼
--      orient_token_can_upload 조건을 USING 에 추가 가능하나 SELECT마다 DB 조회 비용 발생)
DROP POLICY IF EXISTS "orient_images_public_select" ON storage.objects;
CREATE POLICY "orient_images_public_select"
  ON storage.objects
  FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'orient-images');

-- ---- UPDATE / DELETE 정책 ----
--   익명(anon)에게 UPDATE·DELETE 권한 미부여 (업로드만 허용).
--   인증(authenticated) 관리자의 파일 정리·삭제는 후속 마이그레이션에서 추가 예정.
--   ※ 잘못 올린 파일의 긴급 삭제:
--      대시보드 > Storage > orient-images 에서 직접 수동 삭제 가능.


-- PostgREST 스키마 캐시 재로드 (신규 함수·정책 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;


-- =============================================================================
-- 적용 안내 (개발서버·운영서버 각각 SQL Editor에서 실행)
--
--   개발서버 SQL Editor:
--     https://supabase.com/dashboard/project/qysmxtipobomefudyixw/sql/new
--   운영서버 SQL Editor:
--     https://supabase.com/dashboard/project/nrwtujmlbktxjgdwlpjj/sql/new
--
--   실행 순서:
--     이 파일 전체 → Run → 아래 검증 SQL 단계별 실행
--
-- =============================================================================
--
-- 검증 SQL (1단계씩 순차 실행 — 결과 확인 후 다음 단계 진행)
--
-- ▶ 1단계: 헬퍼 함수 생성 확인
-- SELECT proname,
--        pg_get_function_arguments(oid) AS args,
--        pg_get_function_result(oid)    AS ret,
--        prosecdef                      AS security_definer,
--        proconfig                      AS config
--   FROM pg_proc
--  WHERE proname        = 'orient_token_can_upload'
--    AND pronamespace   = 'public'::regnamespace;
-- 기대: 1행, args='p_token text', ret='boolean',
--       security_definer=true, config에 'search_path=' 포함
--
-- ▶ 2단계: 버킷 생성 확인 (1단계 결과 OK 후 실행)
-- SELECT id,
--        name,
--        public,
--        file_size_limit,
--        array_length(allowed_mime_types, 1) AS mime_count,
--        allowed_mime_types
--   FROM storage.buckets
--  WHERE id = 'orient-images';
-- 기대: 1행, public=true, file_size_limit=10485760, mime_count=8
--
-- ▶ 3단계: 행 단위 보안 정책 2개 확인 (2단계 결과 OK 후 실행)
-- SELECT policyname, cmd, roles::text
--   FROM pg_policies
--  WHERE schemaname = 'storage'
--    AND tablename  = 'objects'
--    AND policyname LIKE 'orient_images_%';
-- 기대: 2행 — orient_images_anon_insert(INSERT/anon),
--              orient_images_public_select(SELECT/anon+authenticated)
--
-- ▶ 4단계: 스모크 테스트 — 비-UUID 입력 안전 (3단계 결과 OK 후 실행)
-- SELECT public.orient_token_can_upload('not-a-uuid')       AS should_be_false_1,
--        public.orient_token_can_upload('')                  AS should_be_false_2,
--        public.orient_token_can_upload(NULL)                AS should_be_false_3,
--        public.orient_token_can_upload('00000000-0000-0000-0000-000000000000') AS should_be_false_4;
-- 기대: 모두 false (예외 발생 없이)
--
-- ▶ 5단계: 스모크 테스트 — 실제 토큰 (4단계 결과 OK 후 실행)
--   개발 DB에서 orient_sheets 행 1개의 token을 확인 후 대입:
-- SELECT token, status, token_expires_at
--   FROM public.orient_sheets
--  WHERE status IN ('draft', 'submitted')
--  LIMIT 1;
--   → 위 결과의 token 값을 아래에 대입(따옴표 안에 ::text 넣지 말 것):
-- SELECT public.orient_token_can_upload('<위 token 값>');
-- 기대: true
--
-- ▶ 6단계: consumed / 만료 토큰 = false 확인 (5단계 결과 OK 후 실행)
--   상태가 consumed이거나 token_expires_at이 과거인 행이 있다면:
-- SELECT public.orient_token_can_upload(token::text)
--   FROM public.orient_sheets
--  WHERE status = 'consumed'
--  LIMIT 1;
-- 기대: false (없으면 이 단계 생략)
--
-- =============================================================================
