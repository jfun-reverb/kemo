-- ============================================================
-- 480_purge_audit_data_all_general_inquiry.sql
-- 일반 문의 창구 — 데이터 모델 ⑥ 감사용 흔적 청소에 일반 문의 정리 셋 추가
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-4 ⑦ · §5-5 ⑥
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ⑥)
-- 선행: 475(칸) · 477(응대 완료 표)
--
-- 베이스: 179 (purge_audit_data_all 의 유일한 **정의** 파일. 251·325·398 도 이름이 나오지만
--   전부 주석이고 CREATE FUNCTION 이 없다 — 파일을 뽑아 정의인지 갈라 확인함).
--   179 본문을 통째로 복사하고 아래 셋만 더했다. 다른 조항(super_admin 가드·감사용 없음 조기 반환·
--   notifications·faq_interactions 명시 삭제·응모 삭제·영수증 경로 수집·반환 모양)은 글자 그대로 같다.
--   CREATE OR REPLACE 라 권한(179 의 REVOKE PUBLIC·anon / GRANT authenticated)이 보존된다 — DROP 하지 않는다.
--
-- 왜 「조건 한 줄」이 아닌가(사양서 5-4 ⑦): 이 함수에는 메시지를 지우는 문장이 아예 없고, 응모를 지울 때
--   연쇄 삭제로 함께 사라지는 구조다. 응모 없는 행은 그 연쇄에 안 걸리므로 셋을 모두 더한다.
--   ⓐ 일반 문의 첨부 경로 수집(화면이 저장소 파일을 지운다 — 기존과 같은 방식, 기존 message_attachments 배열에 합침)
--   ⓑ 일반 문의 행 삭제(application_id IS NULL AND influencer_id = ANY(감사용))
--   ⓒ general_inquiry_resolutions 정리
--   캠페인 단위 청소(purge_audit_data_for_campaign)는 대상이 아니다(일반 문의는 캠페인과 무관).
--   알림은 ② 의 user_id 기준 삭제가 이미 general_inquiry 알림까지 지운다(ref_table 무관).
--
-- ── 적용 전후 확인 ──
--   🔴 이 함수는 super_admin 전용이라 SQL 편집기(서비스 키)로는 호출이 거부된다(권한 가드가 사는 증거).
--   [V1] 권한 보존: SELECT p.proacl::text FROM pg_proc p
--         WHERE p.pronamespace='public'::regnamespace AND p.proname='purge_audit_data_all';
--        기대: 맨 앞 =X/ 없음, anon 없음, authenticated 있음
--   [V2] 본문 반영: SELECT prosrc LIKE '%general_inquiry_resolutions%' AND prosrc LIKE '%application_id IS NULL%'
--         FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='purge_audit_data_all'; 기대: t
--   [V3] 🔴 개발서버 실호출(로그인 브라우저, super_admin): 감사용 계정으로 일반 문의를 하나 보낸 뒤
--        await db.rpc('purge_audit_data_all') → 반환 모양이 종전과 같고(status·deleted·storage_paths_to_delete),
--        일반 문의 행·응대 완료 행이 사라지고, 첨부를 올렸다면 그 경로가 message_attachments 에 들어 있어야 한다.
--   [V4] 정리 뒤: SELECT count(*) FROM public.application_messages m JOIN public.influencers i ON i.id=m.influencer_id
--         WHERE i.is_audit;   기대: 0
--
-- ── 되돌리는 방법 ──
--   179 파일의 purge_audit_data_all 정의(CREATE OR REPLACE)를 그대로 다시 실행.
-- ============================================================

BEGIN;

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
  v_general_attach_paths text[];   -- [480] 일반 문의 첨부 경로
  v_del_general_msg_count int;     -- [480] 삭제한 일반 문의 메시지 수(반환 모양 불변이라 반환하지 않는다)
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

  --    [480] 일반 문의(응모 없는 메시지) 첨부 파일 — 응모 삭제의 연쇄로는 안 지워지므로 여기서 따로 수집.
  --    반환 모양을 바꾸지 않으려고 기존 message_attachments 배열에 합친다(중복 제거).
  SELECT array_agg(DISTINCT elem->>'path')
    INTO v_general_attach_paths
  FROM public.application_messages am,
       jsonb_array_elements(
         COALESCE(am.attachments, '[]'::jsonb)
       ) AS elem
  WHERE am.application_id IS NULL
    AND am.influencer_id = ANY(v_audit_ids)
    AND elem->>'path' IS NOT NULL;

  IF v_general_attach_paths IS NOT NULL THEN
    SELECT array_agg(DISTINCT p)
      INTO v_msg_attach_paths
      FROM unnest(COALESCE(v_msg_attach_paths, '{}'::text[]) || v_general_attach_paths) AS p;
  END IF;

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

  -- [480] 일반 문의 정리 — 응모가 없어 ④ 의 연쇄 삭제에 안 걸리는 몫.
  --   ⓑ 메시지 행 삭제(admin_reads·hide_history 는 message_id 외래 키 연쇄로 함께 삭제)
  --   ⓒ 응대 완료 행 삭제(477 — influencer_id 기준. 감사용 계정은 influencers 행을 안 지우므로 명시 삭제 필요)
  DELETE FROM public.application_messages
   WHERE application_id IS NULL
     AND influencer_id = ANY(v_audit_ids);
  GET DIAGNOSTICS v_del_general_msg_count = ROW_COUNT;

  DELETE FROM public.general_inquiry_resolutions
   WHERE influencer_id = ANY(v_audit_ids);

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
  '[179][480] 모든 감사용 계정(is_audit=true)의 응모·결과물·알림·메시지·FAQ 이력을 삭제. '
  'super_admin 전용. 반환값의 storage_paths_to_delete를 참조해 클라이언트가 Storage 파일도 삭제할 것. '
  '[480] 일반 문의(응모 없는 메시지)의 행·첨부 경로·응대 완료 행도 함께 정리(반환 모양 불변 — 첨부 경로는 message_attachments 에 합쳐짐).';

NOTIFY pgrst, 'reload schema';

COMMIT;
