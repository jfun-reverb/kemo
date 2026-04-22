-- ============================================================
-- 062_influencer_flag_evidence.sql
-- influencer_flags 위반 기록에 증빙 파일 첨부 지원
--
-- 배경:
--   059: influencer_flags 테이블 + verify/unverify/blacklist/unblacklist
--   060: violation 액션 + record_influencer_violation RPC
--   061: violation 행 사후 수정(update_influencer_violation) + 감사 컬럼
--   이번: 관리자가 위반 등록/수정 시 증빙 이미지·PDF를 복수 첨부.
--         저장 경로를 influencer_flags.evidence_paths(text[])에 배열로 보관.
--         실제 파일은 비공개 버킷 'influencer-flag-evidence'에 저장,
--         관리자만 signed URL로 열람.
--
-- 변경 사항:
--   1. influencer_flags.evidence_paths text[] 컬럼 추가
--   2. Storage 버킷 'influencer-flag-evidence' 생성 (비공개)
--   3. Storage RLS 정책 — 관리자만 CRUD
--   4. RPC record_influencer_violation 시그니처 확장
--      (uuid, text, text) → (uuid, text, text, text[])
--   5. RPC update_influencer_violation 시그니처 확장
--      (uuid, text, text) → (uuid, text, text, text[])
--      p_evidence_paths NULL = 미변경, '{}'(빈 배열) = 전체 삭제
--
-- 스코프 밖:
--   - set_influencer_blacklist 의 증빙 첨부 (위반만 이번 범위)
--   - 파일 이동 로직 (tmp → flag_id) : 클라이언트에서 flag_id로
--     직접 경로 구성 후 업로드하는 방식으로 단순화
--
-- rollback:
--   -- Step 1: 확장 RPC 제거 → 061 시그니처로 재생성
--   DROP FUNCTION IF EXISTS public.record_influencer_violation(uuid, text, text, text[]);
--   DROP FUNCTION IF EXISTS public.update_influencer_violation(uuid, text, text, text[]);
--   -- (061 원본 시그니처 복원은 이 파일 하단 롤백 섹션 참조)
--
--   -- Step 2: Storage 정책 제거
--   DROP POLICY IF EXISTS "flag_evidence_admin_select" ON storage.objects;
--   DROP POLICY IF EXISTS "flag_evidence_admin_insert" ON storage.objects;
--   DROP POLICY IF EXISTS "flag_evidence_admin_update" ON storage.objects;
--   DROP POLICY IF EXISTS "flag_evidence_admin_delete" ON storage.objects;
--
--   -- Step 3: 버킷 삭제 (오브젝트 먼저 비워야 함)
--   DELETE FROM storage.objects WHERE bucket_id = 'influencer-flag-evidence';
--   DELETE FROM storage.buckets WHERE id = 'influencer-flag-evidence';
--
--   -- Step 4: 컬럼 제거
--   ALTER TABLE public.influencer_flags
--     DROP COLUMN IF EXISTS evidence_paths;
-- ============================================================


-- ============================================================
-- Step 1: influencer_flags — evidence_paths 컬럼 추가
--   text[] — Storage 경로 배열 (버킷 상대 경로)
--   DEFAULT '{}'::text[] — 기존 행 자동으로 빈 배열로 수렴
--   NOT NULL — NULL 허용하지 않아 클라이언트 null 체크 불필요
-- ============================================================

ALTER TABLE public.influencer_flags
  ADD COLUMN IF NOT EXISTS evidence_paths text[] NOT NULL DEFAULT '{}'::text[];

COMMENT ON COLUMN public.influencer_flags.evidence_paths IS
  '[062] 증빙 파일 Storage 경로 배열. 버킷=influencer-flag-evidence, '
  '경로 규칙: {flag_id}/{uuid}.{ext}. violation 행 전용 (verify/blacklist 등은 빈 배열).';


-- ============================================================
-- Step 2: Storage 버킷 생성 — influencer-flag-evidence
--   public = false : 비공개 버킷 (getPublicUrl 사용 불가)
--   관리자만 createSignedUrl 로 열람
--
--   허용 MIME (file_size_limit / allowed_mime_types):
--     이미지: image/jpeg, image/png, image/webp, image/gif
--     문서  : application/pdf
--   단일 파일 최대 크기: 10 MB (brand-docs 버킷과 동일)
-- ============================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'influencer-flag-evidence',
  'influencer-flag-evidence',
  false,
  10485760,   -- 10 MB
  ARRAY[
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/webp',
    'image/gif',
    'application/pdf'
  ]
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ============================================================
-- Step 3: Storage RLS 정책 — influencer-flag-evidence 버킷
--   관리자(is_campaign_admin() = campaign_admin 이상)만 CRUD 허용.
--   인플루언서(authenticated) 및 anon은 전면 차단.
--
--   Supabase Storage RLS는 storage.objects 테이블 정책으로 관리.
--   bucket_id 컬럼으로 버킷별 정책 분리.
-- ============================================================

-- SELECT (다운로드·signed URL 생성 사전 경로 확인)
DROP POLICY IF EXISTS "flag_evidence_admin_select" ON storage.objects;
CREATE POLICY "flag_evidence_admin_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'influencer-flag-evidence'
    AND public.is_campaign_admin()
  );

-- INSERT (업로드)
DROP POLICY IF EXISTS "flag_evidence_admin_insert" ON storage.objects;
CREATE POLICY "flag_evidence_admin_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'influencer-flag-evidence'
    AND public.is_campaign_admin()
  );

-- UPDATE (덮어쓰기 upsert 대응)
DROP POLICY IF EXISTS "flag_evidence_admin_update" ON storage.objects;
CREATE POLICY "flag_evidence_admin_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'influencer-flag-evidence'
    AND public.is_campaign_admin()
  )
  WITH CHECK (
    bucket_id = 'influencer-flag-evidence'
    AND public.is_campaign_admin()
  );

-- DELETE (첨부 파일 제거)
DROP POLICY IF EXISTS "flag_evidence_admin_delete" ON storage.objects;
CREATE POLICY "flag_evidence_admin_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'influencer-flag-evidence'
    AND public.is_campaign_admin()
  );


-- ============================================================
-- Step 4: RPC — record_influencer_violation 시그니처 확장
--   (060 기존 시그니처 DROP → 새 시그니처로 재생성)
--
--   변경점:
--     + p_evidence_paths text[] DEFAULT NULL
--       NULL이면 빈 배열({})로 저장. 명시적 배열 전달 시 그대로 저장.
--
--   불변 사항 (060과 동일):
--     - campaign_admin 이상만 호출 가능
--     - p_reason_code 빈 문자열 금지
--     - 대상 인플루언서 존재 확인
--     - influencers 테이블 변경 없음 (이력 기록 전용)
-- ============================================================

-- 060 시그니처(3인자) 먼저 제거 후 새 시그니처(4인자) 등록
DROP FUNCTION IF EXISTS public.record_influencer_violation(uuid, text, text);

CREATE OR REPLACE FUNCTION public.record_influencer_violation(
  p_target_id      uuid,
  p_reason_code    text,
  p_note           text    DEFAULT NULL,
  p_evidence_paths text[]  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller_id    uuid;
  v_caller_name  text;
  v_exists       boolean;
  v_paths        text[];
BEGIN
  -- 1. 호출자 검증: campaign_admin 이상
  v_caller_id := auth.uid();
  SELECT name INTO v_caller_name
    FROM public.admins
   WHERE auth_id = v_caller_id
     AND role IN ('super_admin', 'campaign_admin');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_admin 이상 권한이 필요합니다.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 2. reason_code 필수 검증
  IF p_reason_code IS NULL OR trim(p_reason_code) = '' THEN
    RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. 대상 인플루언서 존재 확인
  SELECT EXISTS (
    SELECT 1 FROM public.influencers WHERE id = p_target_id
  ) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION '인플루언서를 찾을 수 없습니다: %', p_target_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 4. evidence_paths: NULL이면 빈 배열로 처리
  v_paths := COALESCE(p_evidence_paths, '{}'::text[]);

  -- 5. influencer_flags에 violation 이력 INSERT
  INSERT INTO public.influencer_flags
    (influencer_id, action, reason_code, note, evidence_paths, set_by, set_by_name)
  VALUES
    (p_target_id, 'violation', trim(p_reason_code), p_note, v_paths, v_caller_id, v_caller_name);
END;
$$;

COMMENT ON FUNCTION public.record_influencer_violation(uuid, text, text, text[]) IS
  '[060/062] 인플루언서 위반 이력 기록 RPC. campaign_admin 이상 전용. '
  'influencer_flags INSERT 전용, influencers 테이블 변경 없음. '
  'p_evidence_paths: Storage 경로 배열, NULL이면 빈 배열로 저장.';

REVOKE ALL ON FUNCTION public.record_influencer_violation(uuid, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_influencer_violation(uuid, text, text, text[]) TO authenticated;


-- ============================================================
-- Step 5: RPC — update_influencer_violation 시그니처 확장
--   (061 기존 시그니처 DROP → 새 시그니처로 재생성)
--
--   변경점:
--     + p_evidence_paths text[] DEFAULT NULL
--       NULL    = evidence_paths 미변경 (reason_code/note만 수정)
--       '{}'    = 빈 배열로 갱신 (기존 첨부 전체 제거 의도)
--       array[] = 해당 배열로 교체
--
--   불변 사항 (061과 동일):
--     - campaign_admin 이상만 호출 가능
--     - action='violation' 행만 수정 가능
--     - p_reason_code 빈 문자열 금지
--     - 원본(set_at/set_by/set_by_name) 불변
--     - 수정 시 updated_at/updated_by/updated_by_name 자동 기록
-- ============================================================

-- 061 시그니처(3인자) 먼저 제거
DROP FUNCTION IF EXISTS public.update_influencer_violation(uuid, text, text);

CREATE OR REPLACE FUNCTION public.update_influencer_violation(
  p_flag_id        uuid,
  p_reason_code    text,
  p_note           text    DEFAULT NULL,
  p_evidence_paths text[]  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller_id    uuid;
  v_caller_name  text;
  v_flag_action  text;
BEGIN
  -- 1. 호출자 검증: campaign_admin 이상
  v_caller_id := auth.uid();
  SELECT name INTO v_caller_name
    FROM public.admins
   WHERE auth_id = v_caller_id
     AND role IN ('super_admin', 'campaign_admin');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_admin 이상 권한이 필요합니다.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 2. 대상 행 존재 + action 검증
  SELECT action INTO v_flag_action
    FROM public.influencer_flags
   WHERE id = p_flag_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '수정할 이력 행을 찾을 수 없습니다: %', p_flag_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_flag_action <> 'violation' THEN
    RAISE EXCEPTION 'violation 행만 수정할 수 있습니다. (요청된 action: %)', v_flag_action
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. reason_code 필수 검증
  IF p_reason_code IS NULL OR trim(p_reason_code) = '' THEN
    RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 4. UPDATE
  --    p_evidence_paths IS NULL  → evidence_paths 컬럼 그대로 유지 (COALESCE 없이 조건 분기)
  --    p_evidence_paths IS NOT NULL (빈 배열 포함) → 해당 값으로 교체
  UPDATE public.influencer_flags
     SET reason_code     = trim(p_reason_code),
         note            = p_note,
         evidence_paths  = CASE
                             WHEN p_evidence_paths IS NULL THEN evidence_paths  -- 미변경
                             ELSE p_evidence_paths                               -- 교체
                           END,
         updated_at      = now(),
         updated_by      = v_caller_id,
         updated_by_name = v_caller_name
   WHERE id = p_flag_id
     AND action = 'violation';  -- RLS와 동일 조건 (이중 방어)
END;
$$;

COMMENT ON FUNCTION public.update_influencer_violation(uuid, text, text, text[]) IS
  '[061/062] influencer_flags violation 행 사후 수정 RPC. campaign_admin 이상 전용. '
  'p_evidence_paths: NULL=미변경, 빈배열=전체삭제, 배열=교체. '
  '원본(set_at/set_by) 불변, 감사 컬럼(updated_at/by/by_name) 기록.';

REVOKE ALL ON FUNCTION public.update_influencer_violation(uuid, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_influencer_violation(uuid, text, text, text[]) TO authenticated;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 실행)
-- ============================================================

-- 1. evidence_paths 컬럼 존재 + 타입 + DEFAULT 확인
-- SELECT column_name, data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'influencer_flags'
--    AND column_name  = 'evidence_paths';
-- 기대: data_type='ARRAY', column_default='{}'::text[], is_nullable='NO'

-- 2. 버킷 존재 + 비공개 확인
-- SELECT id, name, public, file_size_limit, allowed_mime_types
--   FROM storage.buckets
--  WHERE id = 'influencer-flag-evidence';
-- 기대: 1건, public=false, file_size_limit=10485760

-- 3. Storage 정책 4개 존재 확인
-- SELECT policyname, operation
--   FROM storage.policies
--  WHERE bucket_id = 'influencer-flag-evidence'
--  ORDER BY operation;
-- 기대: flag_evidence_admin_delete(DELETE), flag_evidence_admin_insert(INSERT),
--       flag_evidence_admin_select(SELECT), flag_evidence_admin_update(UPDATE)

-- 4. RPC 시그니처 확인 (4인자, SECURITY DEFINER)
-- SELECT proname, prosecdef, pronargs,
--        pg_get_function_arguments(oid) AS args
--   FROM pg_proc
--  WHERE proname IN ('record_influencer_violation','update_influencer_violation')
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 각 1건, prosecdef=true, pronargs=4
--       args에 'p_evidence_paths text[] DEFAULT NULL' 포함

-- 5. record_influencer_violation 동작 테스트 (개발서버, campaign_admin 이상 세션)
-- SELECT public.record_influencer_violation(
--   (SELECT id FROM public.influencers LIMIT 1),
--   'guideline_breach',
--   '증빙 첨부 기능 테스트',
--   ARRAY['test-flag-id/sample-uuid.jpg']
-- );
-- 검증:
-- SELECT id, action, reason_code, evidence_paths, set_by_name
--   FROM public.influencer_flags
--  WHERE action = 'violation'
--  ORDER BY set_at DESC LIMIT 1;
-- 기대: evidence_paths = '{test-flag-id/sample-uuid.jpg}'

-- 6. update_influencer_violation — evidence_paths NULL(미변경) vs 빈배열(삭제) 테스트
-- DO $$
-- DECLARE v_flag_id uuid;
-- BEGIN
--   -- 위 테스트에서 생성된 행 ID 조회
--   SELECT id INTO v_flag_id FROM public.influencer_flags
--    WHERE action = 'violation' ORDER BY set_at DESC LIMIT 1;
--
--   -- NULL 전달: evidence_paths 유지되어야 함
--   PERFORM public.update_influencer_violation(v_flag_id, 'guideline_breach', '수정테스트-경로유지', NULL);
--   -- 확인: evidence_paths = '{test-flag-id/sample-uuid.jpg}'
--
--   -- 빈 배열 전달: evidence_paths = '{}' 가 되어야 함
--   PERFORM public.update_influencer_violation(v_flag_id, 'guideline_breach', '수정테스트-경로삭제', '{}');
--   -- 확인: evidence_paths = '{}'
-- END;
-- $$;


-- ============================================================
-- 롤백 방법 (필요 시 아래 순서로 실행)
-- ============================================================
--
-- Step 1: 확장 RPC 제거
-- DROP FUNCTION IF EXISTS public.record_influencer_violation(uuid, text, text, text[]);
-- DROP FUNCTION IF EXISTS public.update_influencer_violation(uuid, text, text, text[]);
--
-- Step 2: 061/060 원본 시그니처(3인자) 복원
-- (아래 코드를 그대로 실행하면 062 이전 상태로 돌아감)
--
-- CREATE OR REPLACE FUNCTION public.record_influencer_violation(
--   p_target_id   uuid,
--   p_reason_code text,
--   p_note        text DEFAULT NULL
-- )
-- RETURNS void
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- DECLARE
--   v_caller_id uuid; v_caller_name text; v_exists boolean;
-- BEGIN
--   v_caller_id := auth.uid();
--   SELECT name INTO v_caller_name FROM public.admins
--    WHERE auth_id = v_caller_id AND role IN ('super_admin','campaign_admin');
--   IF NOT FOUND THEN RAISE EXCEPTION 'campaign_admin 이상 권한이 필요합니다.' USING ERRCODE='insufficient_privilege'; END IF;
--   IF p_reason_code IS NULL OR trim(p_reason_code)='' THEN RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.' USING ERRCODE='check_violation'; END IF;
--   SELECT EXISTS(SELECT 1 FROM public.influencers WHERE id=p_target_id) INTO v_exists;
--   IF NOT v_exists THEN RAISE EXCEPTION '인플루언서를 찾을 수 없습니다: %',p_target_id USING ERRCODE='no_data_found'; END IF;
--   INSERT INTO public.influencer_flags(influencer_id,action,reason_code,note,set_by,set_by_name)
--   VALUES(p_target_id,'violation',trim(p_reason_code),p_note,v_caller_id,v_caller_name);
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.record_influencer_violation(uuid,text,text) FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.record_influencer_violation(uuid,text,text) TO authenticated;
--
-- CREATE OR REPLACE FUNCTION public.update_influencer_violation(
--   p_flag_id     uuid,
--   p_reason_code text,
--   p_note        text DEFAULT NULL
-- )
-- RETURNS void
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- DECLARE
--   v_caller_id uuid; v_caller_name text; v_flag_action text;
-- BEGIN
--   v_caller_id := auth.uid();
--   SELECT name INTO v_caller_name FROM public.admins
--    WHERE auth_id = v_caller_id AND role IN ('super_admin','campaign_admin');
--   IF NOT FOUND THEN RAISE EXCEPTION 'campaign_admin 이상 권한이 필요합니다.' USING ERRCODE='insufficient_privilege'; END IF;
--   SELECT action INTO v_flag_action FROM public.influencer_flags WHERE id=p_flag_id;
--   IF NOT FOUND THEN RAISE EXCEPTION '수정할 이력 행을 찾을 수 없습니다: %',p_flag_id USING ERRCODE='no_data_found'; END IF;
--   IF v_flag_action<>'violation' THEN RAISE EXCEPTION 'violation 행만 수정할 수 있습니다. (요청된 action: %)',v_flag_action USING ERRCODE='check_violation'; END IF;
--   IF p_reason_code IS NULL OR trim(p_reason_code)='' THEN RAISE EXCEPTION '위반 사유 코드(p_reason_code)는 필수입니다.' USING ERRCODE='check_violation'; END IF;
--   UPDATE public.influencer_flags
--      SET reason_code=trim(p_reason_code), note=p_note,
--          updated_at=now(), updated_by=v_caller_id, updated_by_name=v_caller_name
--    WHERE id=p_flag_id AND action='violation';
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.update_influencer_violation(uuid,text,text) FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.update_influencer_violation(uuid,text,text) TO authenticated;
--
-- Step 3: Storage 정책 제거
-- DROP POLICY IF EXISTS "flag_evidence_admin_select" ON storage.objects;
-- DROP POLICY IF EXISTS "flag_evidence_admin_insert" ON storage.objects;
-- DROP POLICY IF EXISTS "flag_evidence_admin_update" ON storage.objects;
-- DROP POLICY IF EXISTS "flag_evidence_admin_delete" ON storage.objects;
--
-- Step 4: 버킷 삭제 (오브젝트 먼저 비워야 함)
-- DELETE FROM storage.objects WHERE bucket_id = 'influencer-flag-evidence';
-- DELETE FROM storage.buckets WHERE id = 'influencer-flag-evidence';
--
-- Step 5: 컬럼 제거 (기존 evidence_paths 데이터 영구 삭제)
-- ALTER TABLE public.influencer_flags DROP COLUMN IF EXISTS evidence_paths;
-- ============================================================
