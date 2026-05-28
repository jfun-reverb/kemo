-- =============================================================================
-- 마이그레이션 160: 관리자 결과물 대리 등록·자동 승인
-- 제목    : admin proxy deliverable — 관리자가 인플루언서 대신 결과물을 등록하고 즉시 승인
-- 의존    : 035 (deliverables/deliverable_events 원본)
--           128 (order_number 컬럼)
--           154 (notifications.kind CHECK — application_approved 까지 누적)
--           158 (review_image 채널별 유니크 인덱스)
--           159 (review_image 채널 알림)
-- 대상    : 개발서버 + 운영서버
-- 사양서  : docs/specs/2026-05-28-admin-proxy-deliverable.md
-- 위험도  : 낮음 — 컬럼 추가(NULL 허용)/lookup 시드/CHECK 확장/신규 RPC. 기존 행·정책 무변경.
-- 멱등성  : ADD COLUMN IF NOT EXISTS, ON CONFLICT DO NOTHING,
--           DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT, CREATE INDEX IF NOT EXISTS,
--           CREATE OR REPLACE FUNCTION
-- =============================================================================
--
-- 현재 상태(159 기준) → 적용 후 상태(160)
--   deliverables           : submitted_by_admin* 컬럼 4종 없음 → 추가
--   lookup_values          : admin_proxy_reason kind 없음 → 4건 시드
--   deliverable_events.action CHECK : 5종 (submit/resubmit/approve/reject/revert)
--                                   → 7종 (admin_proxy_submit/admin_proxy_revoke 추가)
--   notifications.kind CHECK        : 6종 (154 누적)
--                                   → 7종 (deliverable_proxy_submitted 추가)
--   인덱스                 : idx_deliverables_proxy 없음 → 추가
--   RPC                    : admin_create_deliverable_proxy 없음 → 신규
--                            admin_revoke_proxy_deliverable 없음 → 신규
--
-- 롤백 방법 (주석):
--   -- 1. RPC 제거
--   DROP FUNCTION IF EXISTS public.admin_create_deliverable_proxy(uuid,text,text,text,text,text,date,numeric,text,text);
--   DROP FUNCTION IF EXISTS public.admin_revoke_proxy_deliverable(uuid,text);
--
--   -- 2. 인덱스 제거
--   DROP INDEX IF EXISTS public.idx_deliverables_proxy;
--
--   -- 3. deliverable_events.action CHECK를 035 원본(5종)으로 복원
--   ALTER TABLE public.deliverable_events
--     DROP CONSTRAINT IF EXISTS deliverable_events_action_check;
--   ALTER TABLE public.deliverable_events
--     ADD CONSTRAINT deliverable_events_action_check
--     CHECK (action IN ('submit','resubmit','approve','reject','revert'));
--
--   -- 4. notifications.kind CHECK를 154 버전(6종)으로 복원
--   ALTER TABLE public.notifications
--     DROP CONSTRAINT IF EXISTS notifications_kind_check;
--   ALTER TABLE public.notifications
--     ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--       'deliverable_rejected',
--       'deliverable_changed',
--       'deliverable_approved',
--       'application_cancelled',
--       'message_received',
--       'application_approved'
--     ));
--
--   -- 5. 컬럼 4종 제거 (데이터 소실 주의 — 실운영 시 신중히)
--   ALTER TABLE public.deliverables
--     DROP COLUMN IF EXISTS submitted_by_admin,
--     DROP COLUMN IF EXISTS submitted_by_admin_reason_code,
--     DROP COLUMN IF EXISTS submitted_by_admin_reason,
--     DROP COLUMN IF EXISTS submitted_by_admin_at;
--
--   -- 6. lookup_values 사유 코드 제거
--   DELETE FROM public.lookup_values WHERE kind = 'admin_proxy_reason';
-- =============================================================================

BEGIN;

-- ============================================================
-- 섹션 1: deliverables 컬럼 4종 추가
--   - submitted_by_admin        : 대리 등록한 관리자 ID (admins.id). NULL = 인플 본인 제출
--   - submitted_by_admin_reason_code : 사유 코드 (lookup_values.kind='admin_proxy_reason')
--   - submitted_by_admin_reason : 자유 메모 (선택)
--   - submitted_by_admin_at     : 대리 등록 시각
--
--   기존 행 영향 없음 — 4개 컬럼 모두 NULL 허용, 백필 불필요
-- ============================================================

ALTER TABLE public.deliverables
  ADD COLUMN IF NOT EXISTS submitted_by_admin           uuid
    REFERENCES public.admins(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_by_admin_reason_code text,
  ADD COLUMN IF NOT EXISTS submitted_by_admin_reason    text,
  ADD COLUMN IF NOT EXISTS submitted_by_admin_at        timestamptz;

COMMENT ON COLUMN public.deliverables.submitted_by_admin IS
  '관리자 대리 등록 시 그 관리자의 admins.id. NULL이면 인플루언서 본인 제출.';
COMMENT ON COLUMN public.deliverables.submitted_by_admin_reason_code IS
  '대리 등록 사유 코드. lookup_values(kind=''admin_proxy_reason'').code 참조 (연결 제약 없음, 소프트 참조).';
COMMENT ON COLUMN public.deliverables.submitted_by_admin_reason IS
  '대리 등록 사유 자유 메모. 선택 입력, NULL 가능.';
COMMENT ON COLUMN public.deliverables.submitted_by_admin_at IS
  '대리 등록 시각. submitted_by_admin IS NOT NULL인 행에서 항상 채워짐.';


-- ============================================================
-- 섹션 2: lookup_values — 사유 코드 4건 시드 (admin_proxy_reason kind)
--   기준 데이터 관리 페인(#lookups)에서 운영자가 추가·수정 가능.
--   ON CONFLICT (kind, code) DO NOTHING — 재실행 안전
-- ============================================================

INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('admin_proxy_reason', 'shipping_delay',      '배송 지연',         '配送遅延',       10, true),
  ('admin_proxy_reason', 'system_error',        '시스템 오류',       'システムエラー', 20, true),
  ('admin_proxy_reason', 'inflexible_deadline', '기간 외 합의 처리', '期間外協議',     30, true),
  ('admin_proxy_reason', 'other',               '기타',              'その他',         90, true)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- 섹션 3: deliverable_events.action CHECK 확장
--
--   현재(035 원본 인라인 CHECK):
--     ('submit','resubmit','approve','reject','revert')
--
--   이후(160):
--     위 5종 + 'admin_proxy_submit' + 'admin_proxy_revoke'
--
--   DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴 — 재실행 안전.
--   PostgreSQL 인라인 CHECK는 자동으로 {테이블}_{컬럼}_check 이름 생성.
--   실제 제약명은 pg_constraint 에서 확인 가능.
-- ============================================================

ALTER TABLE public.deliverable_events
  DROP CONSTRAINT IF EXISTS deliverable_events_action_check;

ALTER TABLE public.deliverable_events
  ADD CONSTRAINT deliverable_events_action_check
  CHECK (action IN (
    'submit',            -- 인플루언서 최초 제출
    'resubmit',          -- 인플루언서 재제출 (반려 후)
    'approve',           -- 관리자 승인
    'reject',            -- 관리자 반려
    'revert',            -- 관리자 되돌리기 (approved/rejected → pending)
    'admin_proxy_submit', -- 관리자 대리 등록·자동 승인
    'admin_proxy_revoke'  -- super_admin 대리 등록 회수 (DELETE + audit)
  ));


-- ============================================================
-- 섹션 4: notifications.kind CHECK 확장
--
--   현재(154 누적 6종):
--     ('deliverable_rejected','deliverable_changed','deliverable_approved',
--      'application_cancelled','message_received','application_approved')
--
--   이후(160):
--     위 6종 + 'deliverable_proxy_submitted'
--       → 인플 알림 모달에서 deliverable_* 패턴과 동일하게 활동관리로 이동
-- ============================================================

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved',
    'deliverable_proxy_submitted'  -- 160 신규: 관리자 대리 등록 시 인플 알림
  ));


-- ============================================================
-- 섹션 5: 부분 인덱스 — 대리 등록 행 필터·조회 가속
--   submitted_by_admin IS NOT NULL 행만 대상 (전체 행의 극소수 예상)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_deliverables_proxy
  ON public.deliverables(submitted_by_admin)
  WHERE submitted_by_admin IS NOT NULL;


-- ============================================================
-- 섹션 6: RPC admin_create_deliverable_proxy
--
--   권한  : is_campaign_admin() 이상 (campaign_manager 차단)
--   동작  : 승인된 신청에 결과물을 대리 등록하고 즉시 approved 상태로 저장.
--           audit(deliverable_events) + 인플 알림 동시 처리.
--   종류별 필수 필드:
--     receipt      : p_image_url, p_order_number, p_purchase_date, p_purchase_amount
--     post         : p_post_url, p_post_channel
--     review_image : p_image_url, p_post_channel
-- ============================================================

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
  p_reason                 text         -- 사유 자유 메모 (선택)
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

  -- ③-b 사유 코드가 실제 활성 lookup에 존재하는지 확인
  IF NOT EXISTS (
    SELECT 1
      FROM public.lookup_values
     WHERE kind = 'admin_proxy_reason'
       AND code = p_reason_code
       AND active = true
  ) THEN
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
    p_reason,
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

  -- ⑨ 인플루언서 알림 INSERT
  --    kind='deliverable_proxy_submitted' — 앱에서 활동관리로 이동 (deliverable_* 패턴 재사용)
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
    '運営側で結果物を登録・承認しました。理由: ' || COALESCE(p_reason, p_reason_code)
  );

  RETURN v_deliverable_id;

END;
$$;

-- GRANT: authenticated 사용자(관리자)만 실행 가능. 내부에서 is_campaign_admin() 재검증.
REVOKE ALL ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_create_deliverable_proxy(
  uuid, text, text, text, text, text, date, numeric, text, text
) TO authenticated;


-- ============================================================
-- 섹션 7: RPC admin_revoke_proxy_deliverable (super_admin 전용)
--
--   목적  : 잘못 대리 등록된 결과물을 회수 (DELETE + audit 1건).
--           일반 관리자의 「되돌리기」는 대리 등록 행에서 비활성 권장.
--           회수 후 데이터 복구는 불가하므로 super_admin 전용.
--
--   설계 결정 — DELETE 채택:
--     현재 deliverables.status CHECK에 'revoked'가 없어 상태 변경 대신 DELETE 사용.
--     audit 로그(deliverable_events)는 CASCADE가 아니므로 deliverable 삭제 시에도
--     FK ON DELETE CASCADE 설정 확인 필요 → 마이그레이션 035에서 CASCADE 확인됨.
--     따라서 audit 기록 영구 보존이 필요하면 추후 audit-only 별도 테이블로 분리 권장.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_revoke_proxy_deliverable(
  p_deliverable_id  uuid,
  p_reason          text   -- 회수 사유 (기록용, NULL 허용)
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submitted_by_admin  uuid;
  v_user_id             uuid;
  v_kind                text;
  v_post_channel        text;
BEGIN

  -- ① 권한 가드: super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. super_admin 권한이 필요합니다.'
      USING ERRCODE = '42501';
  END IF;

  -- ② 대상 행 검증 + 행 잠금
  SELECT submitted_by_admin, user_id, kind, post_channel
    INTO v_submitted_by_admin, v_user_id, v_kind, v_post_channel
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

  -- ⑥ 인플루언서 알림은 발송하지 않음
  --    회수는 운영 내부 처리 빈도가 낮고, 인플에게 혼란을 줄 수 있음.
  --    필요 시 향후 별도 알림 추가 가능.

END;
$$;

-- GRANT: authenticated 사용자 실행 허용. 내부에서 is_super_admin() 재검증.
REVOKE ALL ON FUNCTION public.admin_revoke_proxy_deliverable(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_revoke_proxy_deliverable(uuid, text)
  TO authenticated;


COMMIT;

-- =============================================================================
-- 섹션 9: 적용 후 검증 SQL (SQL Editor에서 1단계씩 순차 실행)
--
-- [1단계] 컬럼 4종 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name   = 'deliverables'
--    AND column_name  LIKE 'submitted_by_admin%'
--  ORDER BY column_name;
-- 기대: 4행 (submitted_by_admin / submitted_by_admin_at /
--             submitted_by_admin_reason / submitted_by_admin_reason_code)
--
-- [2단계] lookup 4건 확인 (1단계 확인 후 실행)
-- SELECT code, name_ko, name_ja, sort_order
--   FROM public.lookup_values
--  WHERE kind = 'admin_proxy_reason'
--  ORDER BY sort_order;
-- 기대: shipping_delay / system_error / inflexible_deadline / other 4행
--
-- [3단계] deliverable_events.action CHECK 갱신 확인 (2단계 확인 후 실행)
-- SELECT pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conname = 'deliverable_events_action_check';
-- 기대: admin_proxy_submit, admin_proxy_revoke 포함된 7종 목록
--
-- [4단계] notifications.kind CHECK 갱신 확인 (3단계 확인 후 실행)
-- SELECT pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conname = 'notifications_kind_check';
-- 기대: deliverable_proxy_submitted 포함된 7종 목록
--
-- [5단계] 인덱스 확인 (4단계 확인 후 실행)
-- SELECT indexname, indexdef
--   FROM pg_indexes
--  WHERE schemaname = 'public'
--    AND indexname  = 'idx_deliverables_proxy';
-- 기대: 1행 (WHERE submitted_by_admin IS NOT NULL 포함)
--
-- [6단계] RPC 시그니처 확인 (5단계 확인 후 실행)
-- SELECT proname, pg_get_function_arguments(oid)
--   FROM pg_proc
--  WHERE proname IN (
--    'admin_create_deliverable_proxy',
--    'admin_revoke_proxy_deliverable'
--  );
-- 기대: 2행 — 각각 10개 인자 / 2개 인자 시그니처
--
-- [7단계] (옵션) 스모크 호출 — 개발 DB 한정
--   승인된(status='approved') 신청 1건의 id를 아래에 넣어 실제 동작 확인.
--
-- SELECT admin_create_deliverable_proxy(
--   '<approved application_id>',   -- 개발 DB의 approved 신청 uuid
--   'receipt',
--   NULL,
--   'https://example.com/test.jpg',
--   NULL,
--   '12341234',
--   '2026-05-28',
--   1000,
--   'shipping_delay',
--   '스모크 테스트'
-- );
--
-- 기대:
--   - uuid 1개 반환
--   - deliverables 1행 INSERT (campaign_id NOT NULL, status='approved', submitted_by_admin NOT NULL)
--   - deliverable_events 1행 INSERT (action='admin_proxy_submit')
--   - notifications 1행 INSERT (kind='deliverable_proxy_submitted', user_id=인플루언서)
--
-- 확인 쿼리:
-- SELECT d.id, d.campaign_id, d.status, d.submitted_by_admin, d.submitted_by_admin_reason_code
--   FROM public.deliverables d
--  WHERE d.submitted_by_admin IS NOT NULL
--  ORDER BY d.submitted_at DESC LIMIT 1;
-- =============================================================================
