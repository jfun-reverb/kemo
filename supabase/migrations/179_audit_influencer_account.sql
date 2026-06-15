-- ============================================================
-- 179_audit_influencer_account.sql
-- 감사용 인플루언서 계정 메커니즘 — PR A: 데이터베이스 단계
--
-- 목적:
--   운영서버에서 관리자가 인플루언서 동선을 시뮬레이션할 수 있는
--   감사용 계정 메커니즘을 DB 레벨로 구현한다.
--   실 운영 데이터(통계·슬롯·엑셀 산출물)에 흔적·영향 0.
--
-- 포함 내용:
--   1. influencers.is_audit 컬럼 + partial index
--   2. get_campaign_application_counts() RPC 재정의 (마이그레이션 151 재정의)
--   3. check_monitor_slots() + recompute_campaign_applied_count() 재정의
--      → 슬롯/applied_count 집계에서 감사용 응모 격리
--   4. purge_audit_data_all()      — 전체 흔적 제거 RPC (super_admin 한정)
--   5. purge_audit_data_for_campaign() — 캠페인별 흔적 제거 RPC (super_admin 한정)
--   6. 공용 감사용 인플루언서 계정 시드 (auth.users + auth.identities + influencers)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.purge_audit_data_for_campaign(uuid);
--   DROP FUNCTION IF EXISTS public.purge_audit_data_all();
--   -- check_monitor_slots / recompute_campaign_applied_count / get_campaign_application_counts
--   -- 는 각각 048, 058, 151 마이그레이션 내용으로 다시 CREATE OR REPLACE 하면 됨
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS is_audit;
--   DROP INDEX IF EXISTS idx_influencers_is_audit;
--   -- 시드 계정 롤백 (순서 중요 — influencers → identities → users):
--   DELETE FROM public.influencers WHERE email = 'audit.test@reverb.jp';
--   DELETE FROM auth.identities
--     WHERE user_id = (SELECT id FROM auth.users WHERE email = 'audit.test@reverb.jp');
--   DELETE FROM auth.users WHERE email = 'audit.test@reverb.jp';
-- ============================================================


-- ============================================================
-- 1. influencers.is_audit 컬럼 추가
-- ============================================================

ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS is_audit boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.influencers.is_audit IS
  '감사용 계정 여부. true이면 응모·결과물·통계·엑셀 산출물에서 격리됨. '
  '운영팀 본인이 인플루언서 동선을 시뮬레이션할 때 사용하는 계정에만 설정. '
  '감사용 응모는 모집 슬롯·응모수·진행 현황 집계에 포함되지 않는다.';

-- partial index: 감사용 계정은 전체 인플루언서 중 극소수이므로 partial index로 비용 최소화
CREATE INDEX IF NOT EXISTS idx_influencers_is_audit
  ON public.influencers (id)
  WHERE is_audit = true;


-- ============================================================
-- 2. get_campaign_application_counts() RPC 재정의
--    원본: 마이그레이션 151_campaign_application_counts.sql
--    변경: JOIN influencers + WHERE is_audit = false 추가
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_campaign_application_counts()
RETURNS TABLE(
  campaign_id uuid,
  total       bigint,
  approved    bigint,
  pending     bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 관리자 전용 함수 — 비관리자 접근 차단
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    a.campaign_id,
    COUNT(*)                                FILTER (WHERE a.status <> 'cancelled') AS total,
    COUNT(*) FILTER (WHERE a.status = 'approved') AS approved,
    COUNT(*) FILTER (WHERE a.status = 'pending')  AS pending
  FROM public.applications a
  JOIN public.influencers i ON i.id = a.user_id  -- [179] 감사용 격리를 위해 JOIN 추가
  WHERE i.is_audit = false                        -- [179] 감사용 응모 제외
  GROUP BY a.campaign_id;
END;
$$;

-- 기존 151 권한 정책 유지
REVOKE ALL ON FUNCTION public.get_campaign_application_counts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_campaign_application_counts() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_campaign_application_counts() TO authenticated;


-- ============================================================
-- 3a. check_monitor_slots() 재정의
--    원본: 마이그레이션 048_monitor_slots_guard.sql
--    변경: 현재 신청수 카운트 시 감사용(is_audit=true) 응모 제외
--
--    조사 결과 (슬롯 격리 확인):
--    - monitor(리뷰어) 캠페인의 슬롯 차단은 DB BEFORE INSERT 트리거
--      (trg_monitor_slots_guard → check_monitor_slots)로 구현됨
--    - 현재 로직은 status IN ('pending','approved') 카운트 기준
--    - 감사용 계정이 응모하면 이 카운트에 포함되어 실 인플루언서 응모가
--      차단될 수 있으므로, 감사용 응모를 카운트에서 제외하도록 재정의
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_monitor_slots()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type text;
  v_slots        int;
  v_current      int;
  v_is_audit     boolean;
BEGIN
  -- 감사용 계정의 응모이면 슬롯 검증 건너뜀 (슬롯 소진하지 않음)
  SELECT i.is_audit INTO v_is_audit
    FROM public.influencers i
   WHERE i.id = NEW.user_id;

  IF COALESCE(v_is_audit, false) = true THEN
    RETURN NEW;  -- [179] 감사용 응모는 슬롯 차단 없이 통과
  END IF;

  -- FOR UPDATE: 동시 INSERT 시 campaigns 행에 row lock → 레이스 컨디션 방어
  SELECT c.recruit_type, c.slots
    INTO v_recruit_type, v_slots
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id
     FOR UPDATE;

  -- 리뷰어(monitor)가 아니거나 slots 미설정이면 통과
  IF v_recruit_type IS DISTINCT FROM 'monitor' OR COALESCE(v_slots, 0) <= 0 THEN
    RETURN NEW;
  END IF;

  -- 현재 신청수 카운트 (pending + approved — rejected·감사용 제외)
  SELECT COUNT(*)
    INTO v_current
    FROM public.applications a
    JOIN public.influencers i ON i.id = a.user_id  -- [179] 감사용 격리
   WHERE a.campaign_id = NEW.campaign_id
     AND a.status IN ('pending', 'approved')
     AND i.is_audit = false;                       -- [179] 감사용 응모 제외

  IF v_current >= v_slots THEN
    RAISE EXCEPTION '모집 정원이 마감되었습니다 (slots: %, current: %)', v_slots, v_current
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- 트리거는 이미 048에서 등록됨 — 재등록으로 함수 교체만 반영
DROP TRIGGER IF EXISTS trg_monitor_slots_guard ON public.applications;
CREATE TRIGGER trg_monitor_slots_guard
  BEFORE INSERT ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.check_monitor_slots();


-- ============================================================
-- 3b. recompute_campaign_applied_count() 재정의
--    원본: 마이그레이션 058_applied_count_trigger.sql
--    변경: 카운트에서 is_audit = true 응모 제외
--    (campaigns.applied_count = 인플루언서 앱 카드에 표시되는 "N명 신청" 숫자)
-- ============================================================

CREATE OR REPLACE FUNCTION public.recompute_campaign_applied_count(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*)
    INTO v_count
    FROM public.applications a
    JOIN public.influencers i ON i.id = a.user_id  -- [179] 감사용 격리
   WHERE a.campaign_id = p_campaign_id
     AND a.status IN ('pending', 'approved')
     AND i.is_audit = false;                       -- [179] 감사용 응모 제외

  UPDATE public.campaigns
     SET applied_count = v_count
   WHERE id = p_campaign_id;
END;
$$;

COMMENT ON FUNCTION public.recompute_campaign_applied_count(uuid) IS
  '[058/179] campaign_id 하나의 applied_count를 applications 집계(pending+approved, '
  '감사용 제외)로 재계산. SECURITY DEFINER — 트리거 함수에서만 호출.';


-- ============================================================
-- 4. purge_audit_data_all() — 전체 흔적 제거 RPC
-- ============================================================
--
-- cascade 관계 정리 (마이그레이션 코드 직접 확인 결과):
--
-- [applications DELETE 시 cascade 대상 — FK ON DELETE CASCADE 확인]
--   - deliverables            035: application_id FK ON DELETE CASCADE → OK
--   - deliverable_events      035: deliverable_id FK ON DELETE CASCADE (deliverables 통해 cascade)
--   - receipt_edit_history    128: deliverable_id FK ON DELETE CASCADE (deliverables 통해 cascade)
--   - application_events      131: application_id FK ON DELETE CASCADE → OK
--   - application_messages    144: application_id FK ON DELETE CASCADE → OK
--   - application_message_admin_reads  144: message_id FK ON DELETE CASCADE (messages 통해 cascade)
--   - application_message_resolutions  144: application_id FK ON DELETE CASCADE → OK
--   - application_message_hide_history 144: message_id FK ON DELETE CASCADE (messages 통해 cascade)
--     ⚠️ application_message_hide_history는 super_admin 내부 감사 테이블이지만
--        message_id → application_messages → applications 의 cascade chain 위에 있으므로
--        applications DELETE 시 함께 삭제됨. 감사용 계정 데이터이므로 허용.
--   - faq_interactions        146: application_id FK ON DELETE SET NULL → 행 유지, application_id만 NULL
--
-- [influencers 기준 직접 cascade 대상 — user_id/influencer_id FK 확인]
--   - campaign_promo_digest_sent     139: influencer_id FK ON DELETE CASCADE → OK
--   - campaign_promo_exposure        139: influencer_id FK ON DELETE CASCADE → OK
--   - campaign_promo_email_clicks    139: influencer_id FK ON DELETE CASCADE → OK
--   - policy_notice_log (153)        153: influencer_id FK ON DELETE CASCADE → OK
--   - client_error_logs (165)        165: user_id FK ON DELETE SET NULL → 행 유지
--
-- [별도 명시 DELETE 필요한 테이블]
--   - notifications  037: user_id → auth.users(id) ON DELETE CASCADE
--     → auth.users를 건드리지 않으므로 자동 삭제 안 됨. 명시적 DELETE 필요.
--   - faq_interactions 146: influencer_id → auth.users(id) ON DELETE CASCADE
--     → 감사용 계정은 auth.users를 삭제하지 않으므로 명시적 DELETE 필요.
--     (application_id SET NULL으로 행은 남겨두므로 influencer_id로 직접 DELETE)
--
-- [Storage 첨부 파일 — cascade 불가, 클라이언트가 후속 삭제해야 함]
--   - application-message-attachments 버킷: path = applications/{app_id}/{message_id}/...
--   - deliverables 결과물 이미지: campaign-images/receipts/... (영수증 이미지)
--   → 이 함수는 삭제 전 path를 수집해 반환값에 포함. 클라이언트가 후속 삭제.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_audit_data_all()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_audit_ids      uuid[];
  v_app_ids        uuid[];
  v_del_app_count  int;
  v_del_notif_count int;
  v_del_faq_count  int;
  v_msg_attach_paths text[];
  v_receipt_paths    text[];
BEGIN
  -- super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)' USING ERRCODE = '42501';
  END IF;

  -- 감사용 계정 ID 수집
  SELECT array_agg(id) INTO v_audit_ids
    FROM public.influencers
   WHERE is_audit = true;

  IF v_audit_ids IS NULL OR cardinality(v_audit_ids) = 0 THEN
    RETURN jsonb_build_object('status', 'no_audit_account');
  END IF;

  -- 감사용 계정의 응모건 ID 수집 (Storage path 수집 + 삭제 범위 파악용)
  SELECT array_agg(id) INTO v_app_ids
    FROM public.applications
   WHERE user_id = ANY(v_audit_ids);

  -- ① Storage 파일 path 수집 (클라이언트가 후속 삭제할 수 있도록 반환)
  --    응모건 메시지 첨부 파일
  -- ⚠️ attachments는 [{path, name, size, mime}] 객체 배열(144 정의)이므로
  --    jsonb_array_elements + ->>'path'로 path만 추출 (text 추출 함수 사용 금지)
  SELECT array_agg(DISTINCT elem->>'path')
    INTO v_msg_attach_paths
  FROM public.application_messages am,
       jsonb_array_elements(
         COALESCE(am.attachments, '[]'::jsonb)
       ) AS elem
  WHERE am.application_id = ANY(v_app_ids)
    AND elem->>'path' IS NOT NULL;

  --    영수증 이미지 (receipt_url)
  SELECT array_agg(DISTINCT d.receipt_url)
    INTO v_receipt_paths
    FROM public.deliverables d
   WHERE d.application_id = ANY(v_app_ids)
     AND d.receipt_url IS NOT NULL;

  -- ② notifications 명시적 DELETE (auth.users cascade 미적용)
  DELETE FROM public.notifications
   WHERE user_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_notif_count = ROW_COUNT;

  -- ③ faq_interactions 명시적 DELETE (influencer_id 기준, auth.users cascade 미적용)
  DELETE FROM public.faq_interactions
   WHERE influencer_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_faq_count = ROW_COUNT;

  -- ④ applications DELETE
  --    → deliverables, deliverable_events, receipt_edit_history,
  --      application_events, application_messages,
  --      application_message_admin_reads, application_message_resolutions,
  --      application_message_hide_history 모두 cascade
  DELETE FROM public.applications
   WHERE user_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_app_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',            'ok',
    'audit_account_count', cardinality(v_audit_ids),
    'deleted', jsonb_build_object(
      'applications',  v_del_app_count,
      'notifications', v_del_notif_count,
      'faq_interactions', v_del_faq_count
    ),
    'storage_paths_to_delete', jsonb_build_object(
      'message_attachments', COALESCE(to_jsonb(v_msg_attach_paths), '[]'::jsonb),
      'receipt_images',      COALESCE(to_jsonb(v_receipt_paths),    '[]'::jsonb)
    )
  );
END;
$$;

COMMENT ON FUNCTION public.purge_audit_data_all() IS
  '[179] 모든 감사용 계정(is_audit=true)의 응모·결과물·알림·메시지·FAQ 이력을 삭제. '
  'super_admin 전용. 반환값의 storage_paths_to_delete를 참조해 클라이언트가 Storage 파일도 삭제할 것.';

REVOKE ALL ON FUNCTION public.purge_audit_data_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purge_audit_data_all() TO authenticated;


-- ============================================================
-- 5. purge_audit_data_for_campaign() — 캠페인별 흔적 제거 RPC
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_audit_data_for_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_audit_ids       uuid[];
  v_app_ids         uuid[];
  v_del_app_count   int;
  v_del_notif_count int;
  v_msg_attach_paths text[];
  v_receipt_paths    text[];
BEGIN
  -- super_admin 전용
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)' USING ERRCODE = '42501';
  END IF;

  -- 감사용 계정 ID 수집
  SELECT array_agg(id) INTO v_audit_ids
    FROM public.influencers
   WHERE is_audit = true;

  IF v_audit_ids IS NULL OR cardinality(v_audit_ids) = 0 THEN
    RETURN jsonb_build_object('status', 'no_audit_account');
  END IF;

  -- 해당 캠페인의 감사용 응모건 ID 수집
  SELECT array_agg(id) INTO v_app_ids
    FROM public.applications
   WHERE campaign_id = p_campaign_id
     AND user_id = ANY(v_audit_ids);

  IF v_app_ids IS NULL OR cardinality(v_app_ids) = 0 THEN
    RETURN jsonb_build_object(
      'status',      'ok',
      'campaign_id', p_campaign_id,
      'deleted', jsonb_build_object('applications', 0, 'notifications', 0)
    );
  END IF;

  -- ① Storage 파일 path 수집
  -- ⚠️ attachments는 [{path, name, size, mime}] 객체 배열(144 정의)이므로
  --    jsonb_array_elements + ->>'path'로 path만 추출 (text 추출 함수 사용 금지)
  SELECT array_agg(DISTINCT elem->>'path')
    INTO v_msg_attach_paths
  FROM public.application_messages am,
       jsonb_array_elements(
         COALESCE(am.attachments, '[]'::jsonb)
       ) AS elem
  WHERE am.application_id = ANY(v_app_ids)
    AND elem->>'path' IS NOT NULL;

  SELECT array_agg(DISTINCT d.receipt_url)
    INTO v_receipt_paths
    FROM public.deliverables d
   WHERE d.application_id = ANY(v_app_ids)
     AND d.receipt_url IS NOT NULL;

  -- ② 해당 캠페인 감사용 응모건의 notifications 삭제
  --    (notifications.ref_table = 'applications' AND ref_id = ANY(v_app_ids) 건)
  DELETE FROM public.notifications
   WHERE user_id = ANY(v_audit_ids)
     AND (
       ref_id = ANY(v_app_ids)   -- 응모건 직접 참조 알림
       OR (
         ref_table = 'deliverables'
         AND ref_id IN (
           SELECT id FROM public.deliverables
            WHERE application_id = ANY(v_app_ids)
         )
       )
     );
  GET DIAGNOSTICS v_del_notif_count = ROW_COUNT;

  -- faq_interactions는 의도적으로 정리하지 않음:
  --   campaign_id 컬럼이 없어 캠페인 단위 삭제 불가. 여기서 influencer_id로 지우면
  --   다른 캠페인 열람 이력까지 삭제됨. 응모건 cascade로 application_id만 SET NULL 처리되고
  --   FAQ 측정 통계는 전체 청소(purge_audit_data_all)에서만 제거된다.

  -- ③ applications DELETE → cascade로 하위 테이블 모두 정리
  DELETE FROM public.applications
   WHERE id = ANY(v_app_ids);
  GET DIAGNOSTICS v_del_app_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',      'ok',
    'campaign_id', p_campaign_id,
    'deleted', jsonb_build_object(
      'applications',  v_del_app_count,
      'notifications', v_del_notif_count
    ),
    'storage_paths_to_delete', jsonb_build_object(
      'message_attachments', COALESCE(to_jsonb(v_msg_attach_paths), '[]'::jsonb),
      'receipt_images',      COALESCE(to_jsonb(v_receipt_paths),    '[]'::jsonb)
    )
  );
END;
$$;

COMMENT ON FUNCTION public.purge_audit_data_for_campaign(uuid) IS
  '[179] 특정 캠페인(p_campaign_id)에서 감사용 계정(is_audit=true)이 만든 '
  '응모·결과물·메시지·알림을 삭제. super_admin 전용. '
  '반환값의 storage_paths_to_delete를 참조해 클라이언트가 Storage 파일도 삭제할 것.';

REVOKE ALL ON FUNCTION public.purge_audit_data_for_campaign(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purge_audit_data_for_campaign(uuid) TO authenticated;


-- ============================================================
-- 6. 공용 감사용 인플루언서 계정 시드
-- ============================================================
--
-- ⚠️ 환경별 이메일 설정:
--   - 개발서버: audit.test@reverb.jp  (아래 SQL 그대로 사용)
--   - 운영서버: 운영 적용 시 이메일을 실제 감사용 메일 주소로 변경할 것
--     예: audit@globalreverb.com 또는 super_admin 본인 이메일 별칭
--   - 이메일을 바꿀 때는 아래 4곳 모두 변경:
--     ① DO 블록 상단 SELECT ... WHERE email = ... (존재 확인 조건절)
--     ② auth.users INSERT email 값 + raw_user_meta_data 안 email
--     ③ auth.identities INSERT identity_data jsonb 안 email
--     ④ influencers UPSERT email 값
--
-- ⚠️ 비밀번호:
--   - 아래 시드는 'AuditReverb2026!' 로 설정됨 (bcrypt round 10)
--   - 운영 적용 시 반드시 강력한 비밀번호로 변경하거나,
--     적용 후 관리자 페이지에서 초대 메일 발송(resetPasswordForEmail)로 재설정할 것
--
-- ⚠️ influencers 자동 생성 트리거 (마이그레이션 014):
--   - auth.users INSERT 시 handle_new_user() 트리거가 실행되어
--     influencers 행이 자동 생성됨 (id, email, created_at만 채움)
--   - 따라서 auth.users INSERT 후 influencers를 INSERT하면 충돌(PK 중복) 발생
--   - 아래 시드는 auth.users INSERT → 트리거 자동 생성된 influencers 행을
--     UPDATE로 is_audit=true + 프로필 세팅하는 방식으로 작성
--   - ON CONFLICT (id) DO UPDATE 패턴을 사용해 멱등성 확보
--
-- ⚠️ 멱등성:
--   - 이미 같은 이메일이 존재하면 auth.users는 ON CONFLICT (email) DO NOTHING
--   - auth.identities는 ON CONFLICT (provider, provider_id) DO NOTHING
--   - influencers는 ON CONFLICT (id) DO UPDATE로 프로필 갱신
-- ============================================================

DO $$
DECLARE
  v_audit_uid uuid;
  v_existing_uid uuid;
BEGIN
  -- 이미 동일 이메일의 auth.users 행이 있는지 확인
  SELECT id INTO v_existing_uid
    FROM auth.users
   WHERE email = 'audit.test@reverb.jp';

  IF v_existing_uid IS NOT NULL THEN
    -- 이미 존재 → auth.users/identities는 건너뛰고 influencers만 갱신
    v_audit_uid := v_existing_uid;

  ELSE
    -- 신규 생성
    v_audit_uid := gen_random_uuid();

    -- auth.users 행 삽입
    -- supabase.md 「Auth 레코드 완전성」 준수:
    --   email_confirmed_at = now()     (NULL이면 로그인 차단)
    --   raw_app_meta_data              (provider 필수)
    --   raw_user_meta_data             (sub, email, email_verified 필수)
    --   token 필드들                   (NULL 금지, 빈 문자열 필수)
    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      created_at,
      updated_at,
      raw_app_meta_data,
      raw_user_meta_data,
      confirmation_token,
      recovery_token,
      email_change_token_new,
      email_change,
      phone_change,
      phone_change_token,
      reauthentication_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_audit_uid,
      'authenticated',
      'authenticated',
      'audit.test@reverb.jp',
      extensions.crypt('AuditReverb2026!', extensions.gen_salt('bf', 10)),
      now(),
      now(),
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object(
        'sub',            v_audit_uid::text,
        'email',          'audit.test@reverb.jp',
        'email_verified', true,
        'phone_verified', false
      ),
      '',  -- confirmation_token
      '',  -- recovery_token
      '',  -- email_change_token_new
      '',  -- email_change
      '',  -- phone_change
      '',  -- phone_change_token
      ''   -- reauthentication_token
    );

    -- auth.identities 행 삽입 (없으면 로그인 불가)
    INSERT INTO auth.identities (
      id,                  -- [179 fix] 프로젝트 선례(029·031·012) 일치 — 일부 Supabase 버전은 NOT NULL/무DEFAULT
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    ) VALUES (
      gen_random_uuid(),   -- [179 fix] identities 행 자체 PK
      v_audit_uid::text,
      v_audit_uid,
      jsonb_build_object(
        'sub',   v_audit_uid::text,
        'email', 'audit.test@reverb.jp',
        'email_verified', true
      ),
      'email',
      now(),
      now(),
      now()
    ) ON CONFLICT (provider, provider_id) DO NOTHING;

  END IF;

  -- influencers 행 갱신 (트리거 자동 생성 행 + is_audit 설정)
  -- 트리거가 생성한 행에 is_audit=true + 프로필 세팅
  INSERT INTO public.influencers (
    id,
    email,
    name,
    name_kanji,
    name_kana,
    is_audit,
    terms_agreed_at,
    privacy_agreed_at,
    created_at
  ) VALUES (
    v_audit_uid,
    'audit.test@reverb.jp',
    '監査用',
    '監査用',
    'かんさよう',
    true,
    now(),
    now(),
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    name           = EXCLUDED.name,
    name_kanji     = EXCLUDED.name_kanji,
    name_kana      = EXCLUDED.name_kana,
    is_audit       = true,
    terms_agreed_at   = COALESCE(public.influencers.terms_agreed_at, now()),
    privacy_agreed_at = COALESCE(public.influencers.privacy_agreed_at, now());

END $$;


-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor에서 1단계씩 실행)
-- ============================================================

-- 1단계: is_audit 컬럼 추가 확인
-- SELECT column_name, data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name = 'influencers'
--    AND column_name = 'is_audit';
-- 기대: boolean, false, NO

-- 2단계: 시드 계정 생성 확인
-- SELECT u.email, u.email_confirmed_at IS NOT NULL AS confirmed,
--        i.is_audit, i.name_kanji
--   FROM auth.users u
--   JOIN public.influencers i ON i.id = u.id
--  WHERE u.email = 'audit.test@reverb.jp';
-- 기대: confirmed=true, is_audit=true, name_kanji='監査用'

-- 3단계: auth.identities 행 확인
-- SELECT provider, provider_id
--   FROM auth.identities
--  WHERE user_id = (SELECT id FROM auth.users WHERE email = 'audit.test@reverb.jp');
-- 기대: provider='email', provider_id=<uuid>

-- 4단계: get_campaign_application_counts RPC 확인 (감사용 응모 제외 여부)
-- SELECT * FROM public.get_campaign_application_counts() LIMIT 5;
-- 기대: 감사용 계정 응모건 미포함, 일반 집계와 동일

-- 5단계: 슬롯 트리거 함수 존재 확인
-- SELECT proname, prosecdef FROM pg_proc
--  WHERE proname IN ('check_monitor_slots', 'recompute_campaign_applied_count')
--    AND pronamespace = 'public'::regnamespace;
-- 기대: 2건, prosecdef = true
