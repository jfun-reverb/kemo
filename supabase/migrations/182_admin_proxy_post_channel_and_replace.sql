-- =============================================================================
-- 마이그레이션 182: admin_create_deliverable_proxy — post 분기 채널 검증 + 교체
-- 제목    : 게시물(post) 대리 등록에 캠페인 채널 일치 검증 + 반려 게시물 교체 기능 추가
-- 의존    : 035 (deliverables / deliverable_events, post_submissions jsonb 컬럼)
--           160 (admin_create_deliverable_proxy 원본, deliverable_events action 7종)
--           162 (deliverable_events action 9종: channel_assign/channel_unassign 추가)
--           163 (admin_create_deliverable_proxy 11인자 버전, submitted_by_admin_evidence)
-- 대상    : 개발서버 + 운영서버
-- 날짜    : 2026-06-16
-- 사양서  : docs/specs/2026-06-16-post-channel-validation-and-proxy-replace.md
-- 위험도  : 낮음
--           - 함수 재정의만 (DROP + CREATE OR REPLACE). 테이블 구조 변경 없음.
--           - receipt / review_image 분기는 일체 변경하지 않음.
--           - deliverable_events.action CHECK 는 162 기준 9종으로 충분 (신규 값 없음).
--             admin_proxy_submit 은 교체(UPDATE) 경로에서도 그대로 사용.
-- 멱등성  : DROP FUNCTION IF EXISTS (시그니처 명시) + CREATE OR REPLACE FUNCTION
--
-- 변경 요약:
--   admin_create_deliverable_proxy (post 분기만 변경, 시그니처 동일 11인자):
--
--   [추가 1] 캠페인 채널 일치 검증 (서버 최종 방어선)
--     applications.campaign_id → campaigns.channel (콤마 구분 문자열) 조회
--     lower(trim(p_post_channel)) 이 split 배열에 포함되면 통과
--     campaigns.channel 이 NULL 이거나 빈 문자열이면 검증 우회 (레거시 캠페인 보호)
--     불일치 시 RAISE EXCEPTION (ERRCODE='22023')
--
--   [추가 2] 반려·대기 게시물 교체 (무조건 차단 → 채널 기준 교체)
--     같은 application_id + kind='post' + post_channel = p_post_channel 행 조회 FOR UPDATE
--     status = 'approved' → 차단 (승인 결과물 보호)
--     status <> 'approved' (pending/rejected/draft) → UPDATE로 교체:
--       post_url, status='approved', reviewed_by, reviewed_at, submitted_at 갱신
--       reject_reason = NULL (반려 사유 초기화)
--       submitted_by_admin, submitted_by_admin_reason_code, submitted_by_admin_reason,
--       submitted_by_admin_at, submitted_by_admin_evidence 갱신
--       post_submissions 에 새 제출 이력 1건 append
--       version + 1 (낙관적 락)
--     그 행이 없으면 기존 INSERT 경로 그대로 진행 (신규 대리 등록)
--
--   [유지] 다른 채널 행이 같은 post_url 을 가진 경우
--     UPDATE 전 EXISTS 체크로 uidx_deliverables_post_url 위반 사전 차단
--     (application_id + post_url 조합 기준, 현재 교체 대상 행 제외)
--
--   [유지] receipt / review_image 분기는 163 코드 그대로
--   [유지] deliverable_events audit(admin_proxy_submit) + notifications 발송
--          교체(UPDATE) 경로에서도 동일하게 기록 (from_status 는 교체 전 status)
--
-- 롤백 방법:
--   -- 1. 이 마이그레이션으로 생성된 함수 제거
--   DROP FUNCTION IF EXISTS public.admin_create_deliverable_proxy(
--     uuid, text, text, text, text, text, date, numeric, text, text, text[]
--   );
--
--   -- 2. 마이그레이션 163 버전으로 복원 (163_admin_proxy_evidence.sql의 섹션 2 재실행)
-- =============================================================================

BEGIN;

-- ============================================================
-- 섹션 1: admin_create_deliverable_proxy — 11인자 버전 DROP 후 재생성
--
--   DROP 대상 시그니처 (163과 동일):
--     (uuid, text, text, text, text, text, date, numeric, text, text, text[])
--   신규 시그니처 (182): 동일 — post 분기 내부 로직만 변경
--
--   참고:
--     post_submissions 컬럼: 마이그레이션 035에서 jsonb NOT NULL DEFAULT '[]' 로 생성됨.
--                            교체 UPDATE 시 기존 배열에 1건 append 하는 방식으로 처리.
--     version 컬럼          : 마이그레이션 035에서 integer NOT NULL DEFAULT 1 로 생성됨.
--                            교체 UPDATE 시 version + 1 처리.
--     deliverable_events.action CHECK: 마이그레이션 162 기준 9종
--                            (admin_proxy_submit 포함). 신규 값 추가 불필요.
-- ============================================================

DROP FUNCTION IF EXISTS public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text, text[]
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
  p_evidence_paths         text[] DEFAULT '{}'  -- 163: 증빙 파일 경로 배열
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin_id          uuid;
  v_app_status        text;
  v_app_user_id       uuid;
  v_app_campaign_id   uuid;
  v_deliverable_id    uuid;
  v_reason_label      text;   -- 인플 알림용 사유 라벨 (lookup_values.name_ja)

  -- post 분기에서 사용하는 변수
  v_camp_channel      text;   -- campaigns.channel (콤마 구분 문자열)
  v_channel_parts     text[]; -- split 결과 배열
  v_channel_matched   boolean := false;
  v_existing_id       uuid;   -- 같은 채널 기존 게시물 행 id
  v_existing_status   text;   -- 같은 채널 기존 게시물 행 status
  v_existing_subs     jsonb;  -- 같은 채널 기존 게시물 행 post_submissions
  v_prev_status       text;   -- 교체 전 status (audit 기록용)
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

  -- ③-b 사유 코드가 실제 활성 lookup에 존재하는지 확인 + 일본어 라벨 동시 조회
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

  -- ⑥ kind별 필수 필드 검증 + post 분기 채널 일치 검증 및 교체 처리
  IF p_kind = 'receipt' THEN
    -- ──────────────────────────────────────────────────────────────────────────
    -- receipt 분기 — 163과 동일, 변경 없음
    -- ──────────────────────────────────────────────────────────────────────────
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
    -- ──────────────────────────────────────────────────────────────────────────
    -- post 분기 — 182에서 변경된 핵심 영역
    -- ──────────────────────────────────────────────────────────────────────────

    -- [post-a] URL 필수 검증 (163 유지)
    IF p_post_url IS NULL OR trim(p_post_url) = '' THEN
      RAISE EXCEPTION '게시물 URL은 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;

    -- [post-b] 채널 필수 검증 (163 유지)
    IF p_post_channel IS NULL OR trim(p_post_channel) = '' THEN
      RAISE EXCEPTION '채널 정보는 필수 입력 항목입니다.'
        USING ERRCODE = '22023';
    END IF;

    -- ──────────────────────────────────────────────────────────────────────────
    -- [post-c] 캠페인 채널 일치 검증 (182 신규 — 서버 최종 방어선)
    --
    --   campaigns.channel 은 콤마 구분 문자열 (예: "instagram,x", "instagram").
    --   이를 split_part 대신 string_to_array + unnest 로 파싱해 배열로 변환 후
    --   lower(trim(p_post_channel)) 이 포함되는지 검사.
    --
    --   캠페인 채널이 NULL 이거나 빈 문자열이면 검증 우회:
    --     - 레거시 캠페인 (channel 미설정) 또는 채널 제약이 없는 캠페인에서
    --       대리 등록이 차단되는 것을 방지.
    --     - 클라이언트(admin-deliverables.js) 드롭다운이 이미 캠페인 채널로만
    --       제한되어 있어 실무 위험도 낮음.
    -- ──────────────────────────────────────────────────────────────────────────
    SELECT c.channel
      INTO v_camp_channel
      FROM public.campaigns c
     WHERE c.id = v_app_campaign_id;

    -- channel 이 NULL 이 아니고 빈 문자열도 아닐 때만 검증
    IF v_camp_channel IS NOT NULL AND trim(v_camp_channel) <> '' THEN
      -- 콤마 구분 문자열을 배열로 변환 (각 항목 trim + lower)
      SELECT array_agg(lower(trim(ch)))
        INTO v_channel_parts
        FROM unnest(string_to_array(v_camp_channel, ',')) AS ch;

      IF lower(trim(p_post_channel)) = ANY(v_channel_parts) THEN
        v_channel_matched := true;
      END IF;

      IF NOT v_channel_matched THEN
        RAISE EXCEPTION '이 캠페인이 요구하는 채널이 아닙니다: %. 캠페인 요구 채널: %',
          p_post_channel, v_camp_channel
          USING ERRCODE = '22023';
      END IF;
    END IF;

    -- ──────────────────────────────────────────────────────────────────────────
    -- [post-d] 같은 채널 기존 게시물 행 조회 (FOR UPDATE 행 잠금)
    --
    --   storage.js 884줄 주석 참조:
    --     과거 버그로 같은 채널 post 가 여러 행일 수 있어 가장 오래된 1건 선택.
    --   동시 대리 등록 방지: FOR UPDATE 로 행 잠금 (④ applications FOR UPDATE 와 순서 일치).
    -- ──────────────────────────────────────────────────────────────────────────
    SELECT id, status,
           COALESCE(post_submissions, '[]'::jsonb)
      INTO v_existing_id, v_existing_status, v_existing_subs
      FROM public.deliverables
     WHERE application_id = p_application_id
       AND kind = 'post'
       AND lower(trim(post_channel)) = lower(trim(p_post_channel))
     ORDER BY created_at ASC
     LIMIT 1
     FOR UPDATE;

    IF v_existing_id IS NOT NULL THEN
      -- 같은 채널 행 존재 → 분기

      IF v_existing_status = 'approved' THEN
        -- 승인된 게시물은 교체 불가 (승인 결과물 보호)
        RAISE EXCEPTION '이미 승인된 게시물입니다. 교체할 수 없습니다.'
          USING ERRCODE = 'P0001';
      END IF;

      -- ────────────────────────────────────────────────────────────────────
      -- [post-d-i] 교체 전 URL 유니크 충돌 사전 체크
      --
      --   uidx_deliverables_post_url = (application_id, kind, post_url)
      --     WHERE kind='post' AND post_url IS NOT NULL
      --
      --   교체 UPDATE 로 post_url 을 p_post_url 로 변경할 때,
      --   같은 application 의 다른 채널 행이 이미 같은 post_url 을 가지면 위반.
      --   교체 대상 행 자신(v_existing_id)은 제외하고 EXISTS 체크.
      -- ────────────────────────────────────────────────────────────────────
      IF EXISTS (
        SELECT 1
          FROM public.deliverables
         WHERE application_id = p_application_id
           AND kind = 'post'
           AND post_url = p_post_url
           AND id <> v_existing_id   -- 교체 대상 행 자신은 제외
      ) THEN
        RAISE EXCEPTION '같은 링크가 다른 채널 결과물로 이미 등록되어 있습니다.'
          USING ERRCODE = '23505';
      END IF;

      -- ────────────────────────────────────────────────────────────────────
      -- [post-d-ii] 교체 UPDATE
      --   - status = 'approved' (대리 등록은 즉시 승인)
      --   - post_url 갱신
      --   - reject_reason = NULL (반려 사유 초기화)
      --   - reviewed_by / reviewed_at : 호출 관리자
      --   - submitted_at : 교체 시각
      --   - submitted_by_admin 관련 4종 갱신
      --   - submitted_by_admin_evidence : 증빙 경로 배열 (COALESCE로 NULL 방지)
      --   - post_submissions : 기존 배열에 새 제출 이력 1건 append
      --   - version : +1 (낙관적 락)
      -- ────────────────────────────────────────────────────────────────────
      v_prev_status := v_existing_status;  -- audit 기록용으로 교체 전 status 보존

      UPDATE public.deliverables
         SET post_url                      = p_post_url,
             status                        = 'approved',
             reject_reason                 = NULL,
             reject_template_code          = NULL,
             reviewed_by                   = auth.uid(),
             reviewed_at                   = now(),
             submitted_at                  = now(),
             submitted_by_admin            = v_admin_id,
             submitted_by_admin_reason_code = p_reason_code,
             submitted_by_admin_reason     = p_reason,
             submitted_by_admin_at         = now(),
             submitted_by_admin_evidence   = COALESCE(p_evidence_paths, '{}'),
             post_submissions              = v_existing_subs || jsonb_build_array(
                                               jsonb_build_object(
                                                 'url',          p_post_url,
                                                 'channel',      p_post_channel,
                                                 'submitted_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                                               )
                                             ),
             version                       = version + 1
       WHERE id = v_existing_id;

      v_deliverable_id := v_existing_id;

      -- ⑧-교체 감사 로그 — admin_proxy_submit 액션, from_status 는 교체 전 status
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
        v_prev_status,   -- 교체 전 status (pending/rejected/draft)
        'approved'
      );

      -- ⑨-교체 인플루언서 알림 — 163 과 동일하게 발송 유지
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
    END IF;

    -- 같은 채널 행이 없는 경우: 아래 ⑦ INSERT 경로로 진행 (신규 대리 등록)
    -- ──────────────────────────────────────────────────────────────────────────
    -- [post-e] URL 중복 사전 체크 (신규 INSERT 경로 — 163 유지)
    --   교체 분기를 통과한 경우(같은 채널 행 없음) 에만 도달.
    --   다른 채널에서 같은 post_url 을 이미 쓰고 있으면 uidx 위반.
    -- ──────────────────────────────────────────────────────────────────────────
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
    -- ──────────────────────────────────────────────────────────────────────────
    -- review_image 분기 — 163과 동일, 변경 없음
    -- ──────────────────────────────────────────────────────────────────────────
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
  --    (receipt, review_image, post(신규) 공통 INSERT 경로)
  --    p_reason (자유 메모)는 deliverables 컬럼에만 저장 (운영 내부, 관리자 검수 모달 노출)
  --    인플 알림 body에는 v_reason_label (사유 라벨)만 노출 (161 정책 유지)
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
    submitted_by_admin_evidence,
    post_submissions
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
    COALESCE(p_evidence_paths, '{}'),
    -- post 신규 INSERT 시 post_submissions 초기값 — 첫 제출 이력 1건 포함
    CASE WHEN p_kind = 'post' THEN
      jsonb_build_array(
        jsonb_build_object(
          'url',          p_post_url,
          'channel',      p_post_channel,
          'submitted_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
      )
    ELSE '[]'::jsonb
    END
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

COMMIT;


-- =============================================================================
-- 검증 SQL (SQL Editor에서 1단계씩 순차 실행)
--
-- [1단계] 함수 시그니처 확인
-- SELECT proname,
--        pg_get_function_arguments(oid) AS args,
--        pg_get_function_result(oid)    AS ret
--   FROM pg_proc
--  WHERE proname = 'admin_create_deliverable_proxy'
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 1행만 존재 — args에 'p_evidence_paths text[] DEFAULT' 포함, ret='uuid'
-- (11인자 구버전이 2행 조회되면 DROP이 실패한 것 — 수동 DROP 필요)
--
-- [2단계] post 분기 채널 검증 동작 확인 (실제 승인 신청 id 로 교체해 실행)
-- 2단계는 1단계 확인 후 진행
-- SELECT public.admin_create_deliverable_proxy(
--   '<실제_승인된_application_id>',  -- 기프팅/방문형 승인 신청
--   'post',
--   'lips',                          -- 캠페인이 instagram 만 요구하는 경우 — 오류 기대
--   NULL, 'https://lips.example.com/', NULL, NULL, NULL,
--   'system_error', '채널 불일치 테스트', '{}'
-- );
-- 기대: ERROR 22023 "이 캠페인이 요구하는 채널이 아닙니다: lips. 캠페인 요구 채널: instagram"
--
-- [3단계] 반려 게시물 교체 확인
-- 3단계는 2단계 확인 후 진행
-- -- 반려된 post 결과물의 application_id 와 post_channel 을 먼저 조회
-- SELECT d.id, d.application_id, d.post_channel, d.post_url, d.status
--   FROM public.deliverables d
--  WHERE d.kind = 'post' AND d.status = 'rejected'
--  LIMIT 5;
-- -- 위 결과로 application_id 확인 후 대리 등록 교체 시도
-- -- 기대: 기존 행이 UPDATE(status=approved), deliverable_events 1행 추가,
-- --       notifications 1행 추가. 반환값 = 기존 행 id.
-- =============================================================================
