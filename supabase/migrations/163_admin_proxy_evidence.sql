-- =============================================================================
-- 마이그레이션 163: 관리자 대리 등록 증빙 파일 첨부
-- 제목    : admin proxy deliverable — 증빙 파일 경로 배열 컬럼 추가 + RPC 확장
-- 의존    : 160 (admin_create_deliverable_proxy 원본)
--           161 (admin_create_deliverable_proxy 본문 정정 — 사유 라벨 노출)
--           162 (review_image 채널 지정)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-06-01
-- PR      : PR 5 — 관리자 결과물 대리 등록 증빙 첨부
-- 위험도  : 낮음
--           - 컬럼 추가 (DEFAULT '{}', 기존 행 영향 없음)
--           - RPC 재생성 (DROP + CREATE — 인자 수 변경으로 오버로드 충돌 방지)
--           - Storage 버킷 정책 추가 (신규 버킷 `admin-proxy-evidence` 전제)
-- 멱등성  : ADD COLUMN IF NOT EXISTS, DROP FUNCTION IF EXISTS (시그니처 명시),
--           CREATE OR REPLACE FUNCTION, DROP POLICY IF EXISTS + CREATE POLICY
--
-- 변경 요약:
--   deliverables.submitted_by_admin_evidence text[] DEFAULT '{}'
--     → 대리 등록 시 첨부한 증빙 파일의 Storage 경로 배열
--       (`admin-proxy-evidence` 버킷 기준 경로)
--
--   admin_create_deliverable_proxy (10인자 → 11인자)
--     → p_evidence_paths text[] DEFAULT '{}' 파라미터 추가
--     → INSERT 시 submitted_by_admin_evidence 컬럼에 값 주입
--     → 기존 10인자 함수 DROP 후 11인자 버전 재생성 (오버로드 충돌 방지)
--
--   admin_revoke_proxy_deliverable (반환 타입 void → text[])
--     → DELETE 전에 submitted_by_admin_evidence 조회해서 반환
--     → 클라이언트가 반환된 경로 배열로 Storage 파일 별도 삭제 처리
--     → 기존 void 반환 함수 DROP 후 text[] 반환 버전 재생성
--
--   Storage 행 단위 보안 정책 (`admin-proxy-evidence` 버킷):
--     SELECT / INSERT : is_campaign_admin() 이상 (campaign_manager 제외)
--     DELETE         : is_super_admin() 전용 (회수 흐름과 일치)
--     ※ 버킷 자체는 Supabase 대시보드에서 수동 생성 필요
--        (비공개 버킷, 파일 크기 10MB, MIME: image/*, application/pdf)
--
-- 롤백 방법 (주석):
--   -- 1. 11인자 함수 제거
--   DROP FUNCTION IF EXISTS public.admin_create_deliverable_proxy(uuid,text,text,text,text,text,date,numeric,text,text,text[]);
--
--   -- 2. 161 버전(10인자)으로 복원 — 마이그레이션 161 본문 그대로 재실행
--
--   -- 3. text[] 반환 함수 제거
--   DROP FUNCTION IF EXISTS public.admin_revoke_proxy_deliverable(uuid,text);
--
--   -- 4. 160 버전(void 반환)으로 복원 — 마이그레이션 160 §섹션7 본문 재실행
--
--   -- 5. Storage 정책 제거
--   DROP POLICY IF EXISTS "admin_proxy_evidence_select" ON storage.objects;
--   DROP POLICY IF EXISTS "admin_proxy_evidence_insert" ON storage.objects;
--   DROP POLICY IF EXISTS "admin_proxy_evidence_delete" ON storage.objects;
--
--   -- 6. 컬럼 제거 (데이터 소실 주의 — 운영 적용 전 반드시 Storage 파일 백업)
--   ALTER TABLE public.deliverables
--     DROP COLUMN IF EXISTS submitted_by_admin_evidence;
-- =============================================================================

BEGIN;

-- ============================================================
-- 섹션 1: deliverables 컬럼 추가 — submitted_by_admin_evidence
--
--   타입  : text[] (Storage 경로 문자열 배열)
--   DEFAULT: '{}' (기존 행은 빈 배열, 백필 불필요)
--   NULL  : 허용 (증빙 미첨부 시 NULL도 허용 — 클라이언트는 빈 배열 전송)
--   패턴  : influencer_flags.evidence_paths 와 동일 구조
-- ============================================================

ALTER TABLE public.deliverables
  ADD COLUMN IF NOT EXISTS submitted_by_admin_evidence text[] DEFAULT '{}';

COMMENT ON COLUMN public.deliverables.submitted_by_admin_evidence IS
  '관리자 대리 등록 시 첨부한 증빙 파일 경로 배열. '
  '`admin-proxy-evidence` Storage 버킷 기준 상대 경로. '
  'NULL 또는 빈 배열이면 증빙 미첨부. '
  'influencer_flags.evidence_paths 와 동일 패턴.';


-- ============================================================
-- 섹션 2: admin_create_deliverable_proxy — 10인자 DROP 후 11인자 재생성
--
--   DROP 대상 시그니처 (마이그레이션 160·161의 공통 시그니처):
--     (uuid, text, text, text, text, text, date, numeric, text, text)
--   신규 시그니처 (163):
--     (uuid, text, text, text, text, text, date, numeric, text, text, text[])
--
--   p_evidence_paths 는 DEFAULT '{}' 로 선언하여
--   기존 클라이언트 코드가 인자를 생략해도 빈 배열로 동작 (하위 호환).
--   단, PostgreSQL 함수 오버로드는 인자 수 기준이므로
--   10인자 버전을 명시 DROP 하지 않으면 동일 이름 다른 인자 수로 공존 가능하나
--   REVOKE/GRANT 및 클라이언트 호출 시 혼동 방지를 위해 명시 DROP 권장.
-- ============================================================

DROP FUNCTION IF EXISTS public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text
);

CREATE OR REPLACE FUNCTION public.admin_create_deliverable_proxy(
  p_application_id         uuid,
  p_kind                   text,           -- 'receipt' | 'post' | 'review_image'
  p_post_channel           text,           -- post / review_image 일 때 필수
  p_image_url              text,           -- receipt / review_image 일 때 필수 (Storage URL)
  p_post_url               text,           -- post 일 때 필수
  p_order_number           text,           -- receipt 일 때 필수
  p_purchase_date          date,           -- receipt 일 때 필수
  p_purchase_amount        numeric,        -- receipt 일 때 필수
  p_reason_code            text,           -- 사유 코드 (필수, admin_proxy_reason.code)
  p_reason                 text,           -- 사유 자유 메모 (선택, 운영 내부 — 인플 알림 미포함)
  p_evidence_paths         text[] DEFAULT '{}'  -- 163 신규: 증빙 파일 경로 배열
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin_id        uuid;
  v_app_status      text;
  v_app_user_id     uuid;
  v_app_campaign_id uuid;
  v_deliverable_id  uuid;
  v_reason_label    text;   -- 161에서 추가: 인플 알림용 사유 라벨 (lookup_values.name_ja)
BEGIN

  -- ① 권한 가드: campaign_admin 이상만 허용
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. campaign_admin 이상 권한이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 호출 관리자의 admins.id 조회
  SELECT id
    INTO v_admin_id
    FROM public.admins
   WHERE auth_id = auth.uid();

  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION '관리자 계정 정보를 찾을 수 없습니다. 관리자 목록을 확인해 주세요.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ③ 사유 코드 필수 검증
  IF p_reason_code IS NULL OR trim(p_reason_code) = '' THEN
    RAISE EXCEPTION '사유 코드는 필수 입력 항목입니다.'
      USING ERRCODE = '22023';
  END IF;

  -- ③-b 사유 코드가 실제 활성 lookup에 존재하는지 확인 + 일본어 라벨 동시 조회 (161 정책 유지)
  SELECT name_ja
    INTO v_reason_label
    FROM public.lookup_values
   WHERE kind = 'admin_proxy_reason'
     AND code = p_reason_code
     AND active = true
   LIMIT 1;

  IF v_reason_label IS NULL THEN
    RAISE EXCEPTION '유효하지 않은 사유 코드입니다: %', p_reason_code
      USING ERRCODE = '22023';
  END IF;

  -- ④ 신청 검증 (행 잠금 — 동시 대리 등록 충돌 방지)
  SELECT status, user_id, campaign_id
    INTO v_app_status, v_app_user_id, v_app_campaign_id
    FROM public.applications
   WHERE id = p_application_id
   FOR UPDATE;

  IF v_app_status IS NULL THEN
    RAISE EXCEPTION '신청 정보를 찾을 수 없습니다.'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_app_status <> 'approved' THEN
    RAISE EXCEPTION '승인된 신청에만 대리 등록이 가능합니다. 현재 신청 상태: %', v_app_status
      USING ERRCODE = 'P0001';
  END IF;

  -- ⑤ kind 값 유효성 검증
  IF p_kind NOT IN ('receipt', 'post', 'review_image') THEN
    RAISE EXCEPTION '유효하지 않은 결과물 종류입니다: %. receipt, post, review_image 중 하나를 선택해 주세요.', p_kind
      USING ERRCODE = '22023';
  END IF;

  -- ⑥ kind별 필수 필드 검증
  IF p_kind = 'receipt' THEN
    IF p_image_url IS NULL OR trim(p_image_url) = '' THEN
      RAISE EXCEPTION '영수증 이미지 URL은 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;
    IF p_order_number IS NULL OR trim(p_order_number) = '' THEN
      RAISE EXCEPTION '주문번호는 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;
    IF p_purchase_date IS NULL THEN
      RAISE EXCEPTION '구매일은 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;
    IF p_purchase_amount IS NULL OR p_purchase_amount <= 0 THEN
      RAISE EXCEPTION '구매금액은 0보다 큰 값이어야 합니다.'
        USING ERRCODE = '22023';
    END IF;

  ELSIF p_kind = 'post' THEN
    IF p_post_url IS NULL OR trim(p_post_url) = '' THEN
      RAISE EXCEPTION '게시물 URL은 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;
    IF p_post_channel IS NULL OR trim(p_post_channel) = '' THEN
      RAISE EXCEPTION '채널 정보는 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;

    -- post URL 중복 사전 체크 (uidx_deliverables_post_url 위반 전 친화적 에러)
    IF EXISTS (
      SELECT 1
        FROM public.deliverables
       WHERE application_id = p_application_id
         AND kind = 'post'
         AND post_url = p_post_url
    ) THEN
      RAISE EXCEPTION '같은 게시물 URL이 이미 등록되어 있습니다.'
        USING ERRCODE = '23505';
    END IF;

  ELSIF p_kind = 'review_image' THEN
    IF p_image_url IS NULL OR trim(p_image_url) = '' THEN
      RAISE EXCEPTION '리뷰 이미지 URL은 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;
    IF p_post_channel IS NULL OR trim(p_post_channel) = '' THEN
      RAISE EXCEPTION '채널 정보는 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;

    -- 채널 중복 사전 체크 (deliverables_review_image_app_channel_uniq 위반 전 친화적 에러)
    IF EXISTS (
      SELECT 1
        FROM public.deliverables
       WHERE application_id = p_application_id
         AND kind = 'review_image'
         AND post_channel = p_post_channel
    ) THEN
      RAISE EXCEPTION '해당 채널(%)의 리뷰 이미지가 이미 등록되어 있습니다.', p_post_channel
        USING ERRCODE = '23505';
    END IF;
  END IF;

  -- ⑦ deliverables INSERT — status='approved', 대리 등록 필드 + 증빙 경로 배열 동시 기록
  --    p_reason (자유 메모)는 deliverables 컬럼에만 저장 (운영 내부, 관리자 검수 모달 노출)
  --    인플 알림 body에는 v_reason_label (사유 라벨)만 노출 (161 정책 유지)
  --    submitted_by_admin_evidence: NULL 방지를 위해 COALESCE로 빈 배열 보장
  INSERT INTO public.deliverables (
    application_id,
    campaign_id,
    user_id,
    kind,
    post_channel,
    receipt_url,
    post_url,
    order_number,
    purchase_date,
    purchase_amount,
    status,
    reviewed_by,
    reviewed_at,
    submitted_at,
    submitted_by_admin,
    submitted_by_admin_reason_code,
    submitted_by_admin_reason,
    submitted_by_admin_at,
    submitted_by_admin_evidence
  )
  VALUES (
    p_application_id,
    v_app_campaign_id,
    v_app_user_id,
    p_kind,
    CASE WHEN p_kind IN ('post', 'review_image') THEN p_post_channel ELSE NULL END,
    CASE WHEN p_kind IN ('receipt', 'review_image') THEN p_image_url ELSE NULL END,
    CASE WHEN p_kind = 'post' THEN p_post_url ELSE NULL END,
    CASE WHEN p_kind = 'receipt' THEN p_order_number ELSE NULL END,
    CASE WHEN p_kind = 'receipt' THEN p_purchase_date ELSE NULL END,
    CASE WHEN p_kind = 'receipt' THEN p_purchase_amount ELSE NULL END,
    'approved',       -- 대리 등록은 즉시 승인 상태
    auth.uid(),       -- reviewed_by: 호출 관리자 auth.uid()
    now(),
    now(),
    v_admin_id,       -- submitted_by_admin: 호출 관리자 admins.id
    p_reason_code,
    p_reason,         -- 운영 내부 메모 (인플 미노출)
    now(),
    COALESCE(p_evidence_paths, '{}')  -- 163 신규: 증빙 경로 배열, NULL 보호
  )
  RETURNING id INTO v_deliverable_id;

  -- ⑧ 감사(audit) 로그 — deliverable_events에 admin_proxy_submit 기록
  --    actor_id: auth.uid() (auth.users.id, admins 아님)
  INSERT INTO public.deliverable_events (
    deliverable_id,
    actor_id,
    action,
    from_status,
    to_status
  )
  VALUES (
    v_deliverable_id,
    auth.uid(),
    'admin_proxy_submit',
    NULL,        -- 신규 생성이므로 이전 상태 없음
    'approved'
  );

  -- ⑨ 인플루언서 알림 INSERT — 사유 라벨만 노출 (161 정책 유지)
  --    kind='deliverable_proxy_submitted' — 앱에서 활동관리로 이동
  INSERT INTO public.notifications (
    user_id,
    kind,
    ref_table,
    ref_id,
    title,
    body
  )
  VALUES (
    v_app_user_id,
    'deliverable_proxy_submitted',
    'deliverables',
    v_deliverable_id,
    '結果物が登録されました',
    '運営側で結果物を登録・承認しました。理由: ' || v_reason_label
  );

  RETURN v_deliverable_id;

END;
$$;

-- GRANT: authenticated(관리자)만 실행 가능. 내부에서 is_campaign_admin() 재검증.
REVOKE ALL ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text, text[]
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text, text[]
) TO authenticated;


-- ============================================================
-- 섹션 3: admin_revoke_proxy_deliverable — void 반환 DROP 후 text[] 반환 재생성
--
--   반환 타입 변경: void → text[]
--     DELETE 전에 submitted_by_admin_evidence 를 SELECT 해서 반환.
--     클라이언트가 반환된 경로 배열로 Storage 파일을 별도 삭제.
--     증빙이 없었으면 빈 배열('{}') 반환.
--
--   PostgreSQL에서 반환 타입 변경은 CREATE OR REPLACE 로 불가 (타입 불일치 오류).
--   따라서 기존 void 반환 함수를 명시 DROP 후 text[] 반환으로 재생성.
--
--   기존 void 반환 시그니처 (160):
--     admin_revoke_proxy_deliverable(uuid, text) RETURNS void
--   신규 text[] 반환 시그니처 (163):
--     admin_revoke_proxy_deliverable(uuid, text) RETURNS text[]
--   → 인자 시그니처 동일하므로 반드시 DROP 먼저.
-- ============================================================

DROP FUNCTION IF EXISTS public.admin_revoke_proxy_deliverable(uuid, text);

CREATE OR REPLACE FUNCTION public.admin_revoke_proxy_deliverable(
  p_deliverable_id  uuid,
  p_reason          text    -- 회수 사유 (기록용, NULL 허용)
)
RETURNS text[]              -- 163 신규: 삭제된 증빙 파일 경로 배열 반환 (없으면 '{}')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submitted_by_admin      uuid;
  v_user_id                 uuid;
  v_kind                    text;
  v_post_channel            text;
  v_evidence_paths          text[];   -- 163 신규: 삭제 전 증빙 경로 배열 보존용
BEGIN

  -- ① 권한 가드: super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. super_admin 권한이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 대상 행 검증 + 행 잠금 + 증빙 경로 배열 동시 조회 (163 신규)
  SELECT submitted_by_admin, user_id, kind, post_channel,
         COALESCE(submitted_by_admin_evidence, '{}')
    INTO v_submitted_by_admin, v_user_id, v_kind, v_post_channel,
         v_evidence_paths
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물 정보를 찾을 수 없습니다.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ③ 대리 등록 행만 회수 가능
  IF v_submitted_by_admin IS NULL THEN
    RAISE EXCEPTION '대리 등록된 결과물만 회수할 수 있습니다. 인플루언서 본인이 제출한 결과물은 회수 대상이 아닙니다.'
      USING ERRCODE = 'P0001';
  END IF;

  -- ④ 감사 로그 먼저 기록 (DELETE 후에는 deliverable_id 참조 불가)
  --    deliverable_events.deliverable_id FK는 ON DELETE CASCADE이므로
  --    deliverable 삭제 시 이 이벤트 행도 함께 삭제됨에 유의.
  --    영구 감사가 필요하다면 별도 audit 테이블 분리를 권장.
  INSERT INTO public.deliverable_events (
    deliverable_id,
    actor_id,
    action,
    from_status,
    to_status,
    reason
  )
  VALUES (
    p_deliverable_id,
    auth.uid(),
    'admin_proxy_revoke',
    'approved',   -- 대리 등록 행은 항상 approved 상태
    NULL,         -- 회수 후 상태 없음 (행 삭제)
    p_reason
  );

  -- ⑤ 결과물 행 삭제 (CASCADE로 deliverable_events도 삭제됨)
  DELETE FROM public.deliverables
   WHERE id = p_deliverable_id;

  -- ⑥ 인플루언서 알림은 발송하지 않음 (160 정책 유지)
  --    회수는 운영 내부 처리 빈도가 낮고, 인플에게 혼란을 줄 수 있음.

  -- ⑦ 삭제된 증빙 파일 경로 배열 반환 — 클라이언트가 Storage 파일 별도 삭제
  --    증빙이 없었으면 빈 배열('{}') 반환
  RETURN v_evidence_paths;

END;
$$;

-- GRANT: authenticated(관리자) 실행 허용. 내부에서 is_super_admin() 재검증.
REVOKE ALL ON FUNCTION public.admin_revoke_proxy_deliverable(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_revoke_proxy_deliverable(uuid, text)
  TO authenticated;


COMMIT;


-- ============================================================
-- 섹션 4: Storage 버킷 행 단위 보안 정책 — admin-proxy-evidence
--
--   ※ 버킷 생성은 Supabase 대시보드에서 수동으로 수행 필요:
--     - 버킷 이름: admin-proxy-evidence
--     - 공개 여부: 비공개 (Private)
--     - 허용 MIME 타입: image/jpeg, image/png, image/webp, image/gif, application/pdf
--     - 파일 크기 제한: 10MB
--
--   정책 설계:
--     SELECT / INSERT : is_campaign_admin() 이상 (campaign_manager 접근 불가)
--     DELETE          : is_super_admin() 전용 (회수 흐름과 권한 일치)
--     UPDATE          : 미부여 (덮어쓰기 방지 — 증거 변조 차단, 수정은 삭제 후 재업로드)
--
--   참고: influencer-flag-evidence 버킷 정책 패턴을 기반으로
--         권한 함수만 is_super_admin() → is_campaign_admin() 으로 조정
--
--   멱등성: DROP POLICY IF EXISTS → CREATE POLICY 패턴
-- ============================================================

-- SELECT 정책: campaign_admin 이상 — 증빙 파일 다운로드·미리보기
DROP POLICY IF EXISTS "admin_proxy_evidence_select" ON storage.objects;
CREATE POLICY "admin_proxy_evidence_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'admin-proxy-evidence'
    AND public.is_campaign_admin()
  );

-- INSERT 정책: campaign_admin 이상 — 증빙 파일 업로드
DROP POLICY IF EXISTS "admin_proxy_evidence_insert" ON storage.objects;
CREATE POLICY "admin_proxy_evidence_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'admin-proxy-evidence'
    AND public.is_campaign_admin()
  );

-- DELETE 정책: super_admin 전용 — 회수 시 Storage 파일 삭제
DROP POLICY IF EXISTS "admin_proxy_evidence_delete" ON storage.objects;
CREATE POLICY "admin_proxy_evidence_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'admin-proxy-evidence'
    AND public.is_super_admin()
  );


-- =============================================================================
-- 검증 SQL (SQL Editor에서 1단계씩 순차 실행)
--
-- [1단계] 컬럼 추가 확인
-- SELECT column_name, data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'deliverables'
--    AND column_name  = 'submitted_by_admin_evidence';
-- 기대: 1행 — data_type='ARRAY', column_default="'{}'::text[]", is_nullable='YES'
--
-- [2단계] 11인자 RPC 시그니처 확인 (1단계 확인 후 실행)
-- SELECT proname, pg_get_function_arguments(oid) AS args, pg_get_function_result(oid) AS ret
--   FROM pg_proc
--  WHERE proname = 'admin_create_deliverable_proxy'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1행 — args에 'p_evidence_paths text[] DEFAULT ...' 포함, ret='uuid'
-- (10인자 버전이 추가로 조회되면 DROP이 실패한 것 — 수동 DROP 필요)
--
-- [3단계] text[] 반환 RPC 시그니처 확인 (2단계 확인 후 실행)
-- SELECT proname, pg_get_function_arguments(oid) AS args, pg_get_function_result(oid) AS ret
--   FROM pg_proc
--  WHERE proname = 'admin_revoke_proxy_deliverable'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1행 — ret='text[]' (void이면 DROP 실패 — 수동 DROP 필요)
--
-- [4단계] Storage 정책 확인 (3단계 확인 후 실행)
-- SELECT policyname, cmd, roles, qual
--   FROM pg_policies
--  WHERE schemaname = 'storage'
--    AND tablename  = 'objects'
--    AND policyname LIKE 'admin_proxy_evidence_%';
-- 기대: 3행 — select(campaign_admin) / insert(campaign_admin) / delete(super_admin)
-- =============================================================================
