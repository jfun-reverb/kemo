-- =============================================================================
-- 마이그레이션 161: 관리자 대리 등록 알림 body 정정 — 사유 메모 제거, 사유 라벨만 노출
-- 의존    : 160 (admin_create_deliverable_proxy 원본)
-- 대상    : 개발서버 + 운영서버
-- 위험도  : 낮음 — CREATE OR REPLACE FUNCTION 본문만 교체. 시그니처 동일.
-- 사양서  : docs/specs/2026-05-28-admin-proxy-deliverable.md §6 「인플 화면 표시」
-- =============================================================================
--
-- 문제 (사용자 발견 2026-05-28):
--   마이그레이션 160 의 admin_create_deliverable_proxy RPC 가 알림 body 에
--   `COALESCE(p_reason, p_reason_code)` 패턴으로 자유 메모(p_reason) 를 우선
--   노출. 그러나 사양서 §6 + 사용자 결정에 따르면 사유 메모는 운영 내부
--   정보이므로 인플루언서 화면에는 노출되지 않아야 함 — 사유 라벨(일본어)
--   만 노출하는 것이 정책.
--
-- 정정:
--   1. DECLARE 에 v_reason_label text 변수 추가
--   2. 본문 검증 단계 ③-b 를 lookup_values.name_ja 조회 + 검증 동시 처리 (SELECT INTO 패턴)
--      — v_reason_label IS NULL 이면 RAISE EXCEPTION 22023 (기존 160 의 EXISTS 검증과 의미 동일)
--   3. 알림 INSERT body 의 'COALESCE(p_reason, p_reason_code)' 를 'v_reason_label' 단독 사용으로 변경
--      — v_reason_label 은 ③-b 에서 NULL 이면 이미 RAISE 되므로 본 시점에는 NOT NULL 보장
--      — p_reason 완전 제거 (운영 내부 정보는 deliverables.submitted_by_admin_reason 컬럼에만 보존되어
--        관리자 검수 모달에서만 노출, 인플 알림 미포함)
--   4. 다른 로직(권한·검증·INSERT·audit)은 160 그대로 유지
--
-- 검증:
--   적용 후 임의의 신청에 대리 등록 시도 → notifications 행의 body 가
--   'XXX。理由: 配送遅延' 형태(사유 라벨만)로 저장되는지 SQL Editor 에서 확인.
-- =============================================================================
--
-- 롤백 방법 (주석):
--   마이그레이션 160 본문 그대로 CREATE OR REPLACE FUNCTION 재실행하면
--   p_reason 노출 동작으로 복원됨. 단 사양서 정책 위반이므로 권장 안 함.
-- =============================================================================


CREATE OR REPLACE FUNCTION public.admin_create_deliverable_proxy(
  p_application_id         uuid,
  p_kind                   text,        -- 'receipt' | 'post' | 'review_image'
  p_post_channel           text,        -- post / review_image 일 때 필수
  p_image_url              text,        -- receipt / review_image 일 때 필수 (Storage URL)
  p_post_url               text,        -- post 일 때 필수
  p_order_number           text,        -- receipt 일 때 필수
  p_purchase_date          date,        -- receipt 일 때 필수
  p_purchase_amount        numeric,     -- receipt 일 때 필수
  p_reason_code            text,        -- 사유 코드 (필수, admin_proxy_reason.code)
  p_reason                 text         -- 사유 자유 메모 (선택, 운영 내부 — 인플 알림 미포함)
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
  v_reason_label    text;        -- 161 신규: 인플 알림용 사유 라벨 (lookup_values.name_ja)
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

  -- ③-b 사유 코드가 실제 활성 lookup에 존재하는지 확인 + 161 신규: 일본어 라벨도 동시 조회
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

  -- ⑦ deliverables INSERT — status='approved', 대리 등록 필드 동시 기록
  -- 사유 메모(p_reason) 는 deliverables 컬럼에만 저장 (운영 내부 — 관리자 검수 모달 노출),
  -- 인플 알림 body 에는 노출하지 않음 (161 정정 정책)
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
    submitted_by_admin_at
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
    'approved',        -- 대리 등록은 즉시 승인 상태
    auth.uid(),        -- reviewed_by: 호출 관리자 auth.uid()
    now(),
    now(),
    v_admin_id,        -- submitted_by_admin: 호출 관리자 admins.id
    p_reason_code,
    p_reason,          -- 운영 내부 메모 (인플 미노출)
    now()
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
    NULL,         -- 신규 생성이므로 이전 상태 없음
    'approved'
  );

  -- ⑨ 인플루언서 알림 INSERT — 161 정정: 사유 라벨만 노출, 자유 메모 제거
  --    kind='deliverable_proxy_submitted' — 앱에서 활동관리로 이동 (deliverable_* 패턴 재사용)
  --    body 에는 v_reason_label (lookup_values.name_ja) 만 사용 — p_reason (자유 메모) 절대 포함 X
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

-- 권한 재부여 (CREATE OR REPLACE 시 GRANT 유지되지만 명시적으로 재실행)
REVOKE ALL ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text
) TO authenticated;


-- =============================================================================
-- §검증 — 적용 후 SQL Editor 에서 1단계씩 순차 실행
--
-- [1단계] 함수 본문에 v_reason_label 변수 + COALESCE(p_reason, p_reason_code) 패턴 제거 확인
--   SELECT prosrc LIKE '%v_reason_label%' AS has_label_var,
--          prosrc LIKE '%COALESCE(p_reason%' AS has_old_pattern
--     FROM pg_proc
--    WHERE proname = 'admin_create_deliverable_proxy'
--      AND pronamespace = 'public'::regnamespace;
--   기대값: has_label_var=true, has_old_pattern=false
--
-- [2단계] 권한 가드 RAISE 동작 확인 (postgres role 호출 → 권한 없음 RAISE 정상)
--   SELECT admin_create_deliverable_proxy(
--     '00000000-0000-0000-0000-000000000000',
--     'receipt', NULL, 'https://example.com/test.jpg', NULL,
--     '12341234', '2026-05-28', 1000,
--     'shipping_delay', '스모크 테스트'
--   );
--   기대값: ERROR 42501 권한이 없습니다 (160 동일 동작)
--
-- [3단계] (운영 관리자 컨텍스트에서) 실제 대리 등록 후 알림 body 확인
--   SELECT body FROM notifications
--    WHERE kind = 'deliverable_proxy_submitted'
--    ORDER BY created_at DESC LIMIT 1;
--   기대값: '運営側で結果物を登録・承認しました。理由: 配送遅延' 등 사유 라벨만 (메모 제외)
-- =============================================================================
