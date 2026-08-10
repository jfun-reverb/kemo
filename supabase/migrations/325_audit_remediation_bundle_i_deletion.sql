-- ============================================================
-- 325_audit_remediation_bundle_i_deletion.sql
-- 전수조사 후속 조치 — 묶음 I(삭제·파기) 중 데이터베이스 조각 4개(I-1·I-2·I-3·I-6)
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I — 삭제·파기」
--
-- ── 이 파일이 하지 않는 것 ──
--   이 파일은 화면 코드(dev/js/*.js, dev/lib/storage.js)를 전혀 건드리지 않는다.
--   같은 시점에 다른 작업이 그 파일들을 손대고 있어(감사조치 세션 병행), 파일 충돌을
--   피하기 위해 데이터베이스 함수·표만 바꾼다. 화면이 이번에 바뀐 반환값을 실제로
--   써서 저장소(Storage) 파일을 지우려면 화면 쪽 후속 작업이 필요하다 — 각 절 하단에
--   "화면 변경 필요"로 표시했다.
--
-- ── 재정의 기준(전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   soft_delete_campaign         → 255(현재 유일한 원본). 이 파일은 255 베이스.
--   delete_brand                 → 174 → 191(현재 원본). 이 파일은 191 베이스.
--   purge_old_influencer_flags   → 166(현재 유일한 원본). 이 파일은 166 베이스.
--   restore_campaign(256)·purge_campaign(257)·purge_expired_deleted_campaigns(258) 는
--   이 파일에서 손대지 않는다(아래 I-1 절 판단 근거 참고 — 저장소 파일은 반드시
--   soft_delete_campaign 시점에 챙겨야 하고, 그 이후 함수들은 이미 사라진 관계를
--   다시 찾을 수 없다).
--
-- 조각별 요약:
--   I-1 soft_delete_campaign(255) 재정의 — 신청·결과물(개인정보)을 지우기 직전에
--       영수증·리뷰 인증샷·응모건 메시지 첨부의 저장소 경로를 모아 반환값에 담는다.
--       반환 타입 integer → jsonb 로 변경(화면 영향 있음, 아래 참고).
--   I-2 같은 함수 안에서 receipt_edit_history(마이그레이션 253 이후 SET NULL 로
--       살아남는 표)를 이 캠페인 몫만 명시적으로 함께 삭제.
--   I-3 influencer_flags 3년 보존 정기 삭제(purge_old_influencer_flags, 166)가
--       행을 지우기 직전에 증빙 파일 경로를 신규 큐 표(influencer_flag_evidence_
--       purge_queue)에 옮겨 담는다. 이 배치는 예약 실행이라 저장소를 직접 부를 수
--       없으므로(로그인 세션 없음), 실제 저장소 삭제는 이 표를 소비하는 후속
--       화면/실행 수단의 몫으로 남긴다(아래 I-3 절 "화면 변경 필요" 참고).
--   I-6 delete_brand(191) 재정의 — 브랜드 연결 캠페인 수를 셀 때 보관 삭제
--       (deleted_at IS NOT NULL)된 캠페인을 빼도록 수정. 기준 데이터(lookup_values)
--       "사용 중" 판정은 데이터베이스 함수가 아니라 화면 쪽 조회(dev/lib/storage.js
--       isLookupInUse)라서 이 파일 범위 밖 — 아래 I-6 절에 보고만 남긴다.
--
-- 롤백: 각 절 하단 참고. 전체를 한꺼번에 되돌리려면 파일 맨 아래 "전체 롤백" 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- I-1·I-2. soft_delete_campaign 재정의
--   — 저장소 경로 수집(I-1) + 영수증 수정 이력 명시 삭제(I-2)
--
--   ── I-1 판단: "언제 지워야 하나" ──
--   applications(및 cascade 로 함께 사라지는 deliverables·application_messages)는
--   이 함수 안에서 즉시 완전 삭제된다(개인정보 즉시 파기 원칙, 255 설계 그대로).
--   저장소 파일의 경로는 이 관계(어느 응모가 어느 결과물·메시지를 가졌는지)를
--   통해서만 찾을 수 있는데, 그 관계는 이 DELETE 가 끝나는 순간 영원히 사라진다.
--   30일 뒤(또는 관리자가 즉시 누르는) 완전 삭제(purge_campaign, 257)나 자동
--   완전삭제(purge_expired_deleted_campaigns, 258) 시점까지 미루면, 그때는 이미
--   응모·결과물·메시지 행 자체가 없어 "무엇을 지워야 했는지" 조회할 방법이 없다.
--   따라서 저장소 경로 수집은 반드시 이 함수(applications 를 실제로 지우는 바로
--   그 지점) 에서 해야 한다 — 뒤로 미룰 수 있는 선택지가 아니다.
--
--   지우는 것과 남기는 것 (I-1 대상 한정):
--     지운다 — deliverables.receipt_url (kind='receipt'|'review_image' 공용 칸,
--       영수증·리뷰 인증샷 이미지) + application_messages.attachments[].path
--       (응모건 메시지 첨부, 인플루언서 개인정보). 반환값에 경로만 담아 돌려주고
--       실제 storage.objects DELETE 는 이 함수가 하지 않는다(purge_audit_data_all/
--       for_campaign, 179, 과 동일한 "경로만 모아 반환 → 클라이언트가 지운다" 패턴).
--     안 지운다 — campaigns.img1~img8, 콘텐츠 가이드 리치 텍스트에 박힌 이미지
--       (campaign-images/content/) 등 관리자가 올린 캠페인 자산. 이건 개인정보가
--       아니고, 캠페인 행 자체가 30일간 그대로 남아 있는 동안(「삭제됨」 탭에서
--       복구 가능) 여전히 그 캠페인 소속 자산이다 — 지금 지우면 복구해도 이미지가
--       빈 캠페인이 된다. 완전 삭제(purge_campaign/purge_expired_deleted_campaigns)
--       시점에 처리할지는 별도 판단이 필요한 후속 과제로 남긴다(이번 지시 범위 밖).
--
--   ── I-2 판단: "지우는 게 맞나" ──
--   receipt_edit_history 는 마이그레이션 253 에서 deliverable_id 외래키가
--   CASCADE → SET NULL 로 바뀌어, 결과물이 사라져도 행 자체는 남는다(스냅샷 칸
--   4종이 "어느 응모·캠페인·인플루언서였는지"를 계속 식별 가능하게 유지).
--   이 이력 표는 "관리자가 언제 무엇을 고쳤는지"를 남기려는 감사 기록이지만,
--   실제 내용(주문번호·구매일·구매금액 전/후 값)은 결국 "그 인플루언서가 무엇을
--   얼마에 샀는지"를 담은 개인정보다. delete_admin_completely(031→253)가 계정
--   완전삭제 시 바로 이 이유로 SET NULL 로 잔존시키지 않고 명시적으로 DELETE 하는
--   선례가 이미 있다(253 파일 "개인정보 파기 목적" 주석). 캠페인 보관 삭제도
--   그 근거가 되는 응모·결과물을 같은 함수 안에서 즉시 완전 파기하므로, 같은
--   원칙(파기 대상의 근거가 사라졌다면 그 근거를 설명하던 이력도 함께 파기)을
--   그대로 적용한다 — campaign_id_snapshot 기준으로 이 캠페인 몫만 명시 삭제.
--
--   반환 타입 변경(integer → jsonb) — 화면 영향:
--     dev/lib/storage.js 의 softDeleteCampaign(campaignId) 은 현재
--     `const {data} = await db.rpc('soft_delete_campaign', ...); deletedApps = data || 0;`
--     로 정수를 기대한다. 유일한 호출부 dev/js/admin.js executeDeleteCampaign() 은
--     이 반환값을 쓰지 않고 그냥 await 만 하므로 즉시 오류는 나지 않지만, 저장소
--     파일을 실제로 지우려면 storage.js 쪽이 purgeAuditDataAll()/
--     purgeAuditDataForCampaign() 과 같은 패턴으로 다시 작성돼야 한다:
--       1) data.storage_paths_to_delete.message_attachments →
--          이미 버킷 상대경로이므로 그대로 db.storage.from('application-message-
--          attachments').remove([...])
--       2) data.storage_paths_to_delete.receipt_images → 전체 URL 이므로 기존
--          _receiptUrlToStoragePath() 로 변환 후 db.storage.from('campaign-images')
--          .remove([...])
--     이 변환 함수·버킷 상수(MSG_ATTACH_BUCKET)는 storage.js 에 이미 있어 새로
--     만들 필요 없이 그대로 재사용 가능하다.
-- ============================================================

DROP FUNCTION IF EXISTS public.soft_delete_campaign(uuid);

CREATE FUNCTION public.soft_delete_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign               record;
  v_deleted_apps            integer;
  v_deleted_receipt_history integer := 0;
  v_app_ids                 uuid[];
  v_msg_attach_paths        text[];
  v_receipt_paths           text[];
BEGIN
  -- ── 권한 가드 (255 원본과 동일) ─────────────────────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION 'permission_denied: 캠페인 삭제 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 (255 원본과 동일) ──────────────────────
  SELECT id, deleted_at INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '캠페인을 찾을 수 없습니다 (id: %)', p_campaign_id USING ERRCODE = '02000';
  END IF;

  IF v_campaign.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'campaign_already_deleted: 이미 삭제(보관) 처리된 캠페인입니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── [325 I-1] 저장소 경로 수집 — applications 를 지우기 전에 미리 모은다.
  --    (지운 뒤에는 관계가 사라져 무엇을 지워야 했는지 다시는 알 수 없다)
  SELECT array_agg(id) INTO v_app_ids
    FROM public.applications
   WHERE campaign_id = p_campaign_id;

  IF v_app_ids IS NOT NULL AND cardinality(v_app_ids) > 0 THEN
    -- 응모건 메시지 첨부 경로 (attachments 는 [{path,name,size,mime}] 객체 배열, 144)
    SELECT array_agg(DISTINCT elem->>'path')
      INTO v_msg_attach_paths
    FROM public.application_messages am,
         jsonb_array_elements(COALESCE(am.attachments, '[]'::jsonb)) AS elem
    WHERE am.application_id = ANY(v_app_ids)
      AND elem->>'path' IS NOT NULL;

    -- 영수증 + 리뷰 인증샷 이미지 (둘 다 receipt_url 칸을 공용으로 씀)
    SELECT array_agg(DISTINCT d.receipt_url)
      INTO v_receipt_paths
      FROM public.deliverables d
     WHERE d.application_id = ANY(v_app_ids)
       AND d.receipt_url IS NOT NULL;
  END IF;

  -- ── [325 I-2] 이 캠페인 몫 영수증 수정 이력 명시 삭제 ─────────
  --    253 로 CASCADE→SET NULL 전환된 뒤로 결과물이 사라져도 살아남는 표.
  --    파기 대상(응모·결과물)의 근거가 사라지므로 이력도 함께 지운다
  --    (delete_admin_completely, 253, 과 같은 원칙 — 파일 상단 "I-2 판단" 참고).
  DELETE FROM public.receipt_edit_history
   WHERE campaign_id_snapshot = p_campaign_id;
  GET DIAGNOSTICS v_deleted_receipt_history = ROW_COUNT;

  -- ── 개인정보 즉시 파기 (255 원본과 동일) ────────────────────
  -- 정산이 걸린 신청이 있으면 251 트리거가 여기서 예외를 던져 함수 전체가 실패한다.
  DELETE FROM public.applications WHERE campaign_id = p_campaign_id;
  GET DIAGNOSTICS v_deleted_apps = ROW_COUNT;

  -- ── 캠페인 행은 유지, deleted_at 만 세팅(30일 보관 시작) — 255 원본과 동일 ──
  UPDATE public.campaigns
     SET deleted_at = now(),
         deleted_by = auth.uid()
   WHERE id = p_campaign_id;

  RETURN jsonb_build_object(
    'status',      'ok',
    'campaign_id', p_campaign_id,
    'deleted', jsonb_build_object(
      'applications',         v_deleted_apps,
      'receipt_edit_history', v_deleted_receipt_history
    ),
    'storage_paths_to_delete', jsonb_build_object(
      'message_attachments', COALESCE(to_jsonb(v_msg_attach_paths), '[]'::jsonb),
      'receipt_images',      COALESCE(to_jsonb(v_receipt_paths),    '[]'::jsonb)
    )
  );
END;
$$;

COMMENT ON FUNCTION public.soft_delete_campaign(uuid) IS
  '[255, 325 개정] 캠페인 보관 삭제(soft delete). is_campaign_admin() 가드. 이 캠페인의 '
  'applications(+cascade deliverables·application_messages 등)를 즉시 완전 삭제하고 '
  'campaigns.deleted_at/deleted_by 만 세팅해 행은 보존(30일 후 자동 완전삭제, '
  'purge_expired_deleted_campaigns 258). [325] 지우기 직전에 영수증·리뷰 인증샷·메시지 '
  '첨부의 저장소 경로를 모아 반환값에 담고(실제 삭제는 호출측 몫), 이 캠페인 몫 '
  'receipt_edit_history(253 이후 SET NULL 로 잔존하던 표)도 함께 명시 삭제한다. '
  '반환 타입 integer → jsonb 로 변경(화면 후속 작업 필요, 이 함수 상단 주석 참고). '
  '정산 걸린 신청이 있으면 251 트리거가 예외를 던져 원자적으로 전체 실패.';

REVOKE ALL ON FUNCTION public.soft_delete_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.soft_delete_campaign(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- 이 절 롤백:
--   DROP FUNCTION IF EXISTS public.soft_delete_campaign(uuid);
--   -- 그 다음 255_soft_delete_campaign_fn.sql 본문(integer 반환 원본)을 그대로 재실행.
--   -- ⚠️ receipt_edit_history 는 이미 삭제된 행은 되돌릴 수 없다(하드 삭제) — 롤백은
--   --    "이후 호출부터 다시 SET NULL 로 남긴다"는 뜻이지 과거 삭제분 복구가 아니다.


-- ============================================================
-- I-3. influencer_flags 3년 보존 삭제 — 증빙 파일 경로 큐잉
--
--   판단: 이 배치는 pg_cron 이 postgres 역할로 예약 실행한다 — 로그인 세션이
--   없으므로 그 자리에서 Storage 삭제 API(관리자 화면이 쓰는 db.storage.remove())
--   를 부를 방법이 없다("화면이 없다"). 검토한 선택지:
--     (a) pg_net + vault.decrypted_secrets 로 Edge Function 을 직접 호출
--         (이 프로젝트가 이미 캠페인 홍보 메일 등에서 쓰는 검증된 패턴, 142/204).
--         가장 "완결된" 해법이지만 새 Edge Function 코드(supabase/functions/*)가
--         필요하다 — 이번 작업 지시 범위(마이그레이션 파일만)를 벗어난다.
--     (b) 지울 경로를 별도 표에 쌓아 두고, 관리자 화면(super_admin)이 그 표를
--         읽어 저장소에서 지운 뒤 표에서 지운다. 데이터베이스만으로 끝나고,
--         행을 실제로 지우는 시점(=경로를 아직 알 수 있는 유일한 시점)의
--         정보 손실을 막는다 — 이번에 안전하게 끝낼 수 있는 범위.
--   (b)를 택한다. (a)는 화면 작업 없이도 저장소까지 완결되는 더 나은 해법이므로
--   후속 과제로 보고에 남긴다(아래 "화면/후속 실행 수단 변경 필요" 참고).
--
--   ⚠️ 이번에 큐 표까지만 만들고, 그 표를 실제로 비우는 화면/실행 수단은
--   만들지 않는다 — 지시받은 "이번에 다 못 하면 억지로 하지 마라"에 해당.
-- ============================================================

-- 큐 표 — influencer_flags 행이 지워지기 직전에 증빙 파일 경로만 옮겨 담는다.
-- 사람을 식별하는 칸은 담지 않는다(flag_id_snapshot 은 이미 사라진 influencer_flags
-- 행의 id 일 뿐, influencer_id 는 담지 않음 — 저장소에서 지우는 데 필요한 최소 정보만).
CREATE TABLE IF NOT EXISTS public.influencer_flag_evidence_purge_queue (
  id               bigserial PRIMARY KEY,
  flag_id_snapshot uuid        NOT NULL,
  bucket           text        NOT NULL DEFAULT 'influencer-flag-evidence',
  storage_path     text        NOT NULL,
  queued_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.influencer_flag_evidence_purge_queue IS
  '[325 I-3] influencer_flags 3년 보존 정기 삭제(purge_old_influencer_flags, 166)가 '
  '행을 지우기 직전에 증빙 파일(influencer-flag-evidence 버킷) 경로를 옮겨 담는 큐. '
  '이 배치는 예약 실행이라 그 자리에서 저장소 파일을 지울 수 없어, 경로만 보존해 '
  '추적 근거 소실을 막는다. 실제 저장소 삭제는 이 표를 소비하는 후속 관리자 화면 '
  '(또는 pg_net+Edge Function 실행 수단)의 몫 — list_pending_influencer_flag_evidence_'
  'purge()/mark_influencer_flag_evidence_purged() 로 소비. 처리 완료된 행은 남겨두지 '
  '않고 하드 삭제한다(이 표 자체가 새로운 영구 개인정보 저장소가 되지 않도록).';

ALTER TABLE public.influencer_flag_evidence_purge_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "flag_evidence_purge_queue_select" ON public.influencer_flag_evidence_purge_queue;
CREATE POLICY "flag_evidence_purge_queue_select" ON public.influencer_flag_evidence_purge_queue
  FOR SELECT USING (public.is_super_admin());
-- INSERT/UPDATE/DELETE 정책 없음 — 아래 SECURITY DEFINER 함수 2종을 통해서만 쓴다.

CREATE INDEX IF NOT EXISTS idx_flag_evidence_purge_queue_queued_at
  ON public.influencer_flag_evidence_purge_queue (queued_at);

-- ── purge_old_influencer_flags 재정의 — 지우기 직전 큐잉 추가 ──
-- 반환 타입 불변(integer, 삭제된 influencer_flags 행 수) — CREATE OR REPLACE 로 충분.
CREATE OR REPLACE FUNCTION public.purge_old_influencer_flags()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff          timestamptz;
  v_deleted         integer;
  v_queued_evidence integer := 0;
BEGIN
  -- 3년(36개월) 이전 기준 시각. 기산점은 set_at(최초 마킹 시각) — 166 원본과 동일.
  v_cutoff := now() - interval '36 months';

  -- [325 I-3] 지우기 직전에 증빙 파일 경로를 큐 표로 옮겨 담는다.
  -- (지운 뒤에는 이 행이 사라져 어떤 파일이었는지 다시는 알 수 없다)
  WITH expiring AS (
    SELECT id, evidence_paths
      FROM public.influencer_flags
     WHERE set_at < v_cutoff
       AND cardinality(evidence_paths) > 0
  )
  INSERT INTO public.influencer_flag_evidence_purge_queue (flag_id_snapshot, storage_path)
  SELECT e.id, p
    FROM expiring e, unnest(e.evidence_paths) AS p;
  GET DIAGNOSTICS v_queued_evidence = ROW_COUNT;

  DELETE FROM public.influencer_flags
  WHERE set_at < v_cutoff;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_old_influencer_flags] cutoff=% deleted=% rows queued_evidence_paths=%',
    v_cutoff, v_deleted, v_queued_evidence;

  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.purge_old_influencer_flags() IS
  '[166, 325 개정] 개인정보처리방침 3년 보관 정책 집행. influencer_flags.set_at 기준 '
  '36개월 경과 행 삭제. [325] 삭제 직전에 evidence_paths 를 '
  'influencer_flag_evidence_purge_queue 로 옮겨 담아 "어떤 파일이었는지" 추적 근거를 '
  '보존한다(저장소 파일 자체는 이 함수가 지우지 않음 — 예약 실행이라 로그인 세션이 '
  '없어 Storage 삭제 API 를 부를 수 없음). SECURITY DEFINER, cron/postgres 전용. '
  '삭제 건수 반환 + RAISE NOTICE. pg_cron job: influencer-flags-retention-daily.';

REVOKE ALL ON FUNCTION public.purge_old_influencer_flags() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_old_influencer_flags() TO postgres;

-- ── 후속 소비용 RPC 2종 — 관리자 화면(super_admin)이 부를 것을 전제로 미리 만든다.
--    이번 작업 범위(마이그레이션 파일)에서는 이 함수들을 부르는 화면을 만들지 않는다.

-- 아직 저장소에서 안 지운 대기 목록 조회.
CREATE OR REPLACE FUNCTION public.list_pending_influencer_flag_evidence_purge(p_limit integer DEFAULT 200)
RETURNS TABLE (
  id           bigint,
  bucket       text,
  storage_path text,
  queued_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT q.id, q.bucket, q.storage_path, q.queued_at
    FROM public.influencer_flag_evidence_purge_queue q
   ORDER BY q.queued_at ASC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
END;
$$;

COMMENT ON FUNCTION public.list_pending_influencer_flag_evidence_purge(integer) IS
  '[325 I-3] influencer_flag_evidence_purge_queue 에서 아직 저장소 삭제가 안 끝난 '
  '항목을 오래된 순으로 조회. super_admin 전용. 호출측이 각 storage_path 를 실제로 '
  '지운 뒤 mark_influencer_flag_evidence_purged() 로 큐에서 제거할 것.';

REVOKE ALL ON FUNCTION public.list_pending_influencer_flag_evidence_purge(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_pending_influencer_flag_evidence_purge(integer) TO authenticated;

-- 저장소 삭제가 끝난 큐 항목 제거(하드 삭제 — 이 표가 영구 기록이 되지 않도록).
CREATE OR REPLACE FUNCTION public.mark_influencer_flag_evidence_purged(p_ids bigint[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한 없음 (super_admin 한정)' USING ERRCODE = '42501';
  END IF;

  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
    RETURN 0;
  END IF;

  DELETE FROM public.influencer_flag_evidence_purge_queue
   WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.mark_influencer_flag_evidence_purged(bigint[]) IS
  '[325 I-3] 저장소에서 실제로 지운 큐 항목을 표에서 제거. super_admin 전용. '
  '부분 실패 대응 — 실제로 지우기 성공한 id 만 넘기면 나머지는 큐에 남아 다음 '
  '시도에서 재사용된다.';

REVOKE ALL ON FUNCTION public.mark_influencer_flag_evidence_purged(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_influencer_flag_evidence_purged(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- 이 절 롤백:
--   DROP FUNCTION IF EXISTS public.mark_influencer_flag_evidence_purged(bigint[]);
--   DROP FUNCTION IF EXISTS public.list_pending_influencer_flag_evidence_purge(integer);
--   -- purge_old_influencer_flags 는 166_influencer_flags_retention.sql 본문을
--   -- 그대로 재실행하면 큐잉 없는 원본으로 복귀.
--   DROP TABLE IF EXISTS public.influencer_flag_evidence_purge_queue;
--   -- ⚠️ 큐 표를 지우면 아직 저장소에서 못 지운 경로 목록도 함께 사라진다 —
--   --    롤백 전에 남은 행이 있으면 먼저 백업할 것:
--   --    SELECT * FROM public.influencer_flag_evidence_purge_queue;


-- ============================================================
-- I-6. delete_brand 재정의 — 보관 삭제된 캠페인을 카운트에서 제외
--
--   무엇이 문제였나: delete_brand(174→191)의 v_camps 는
--   `SELECT count(*) FROM public.campaigns WHERE brand_id = p_brand_id` 로 deleted_at
--   여부를 보지 않는다. 그래서 30일 보관 중(또는 완전삭제 전)인 캠페인이 있으면
--   "연결된 캠페인이 있다"며 브랜드 삭제가 막힌다 — 화면(관리자)에는 캠페인이 이미
--   사라져 안 보이는데 삭제 버튼만 계속 막히는 어긋남.
--
--   기준 데이터(lookup_values) "사용 중" 판정은 데이터베이스 함수가 아니라
--   dev/lib/storage.js 의 isLookupInUse(row) — 클라이언트에서 campaigns 를 직접
--   COUNT 하는 화면 쪽 조회다. 마찬가지로 deleted_at 을 안 본다는 같은 원인이지만,
--   데이터베이스 함수가 아니므로 이 마이그레이션 파일의 범위 밖이다(화면 변경 필요,
--   아래 참고). fetchCampaignCountsByBrand()/countCampaignsByBrand() 도 같은
--   이유로 화면 쪽 표시용 카운트일 뿐 — 실제 삭제 차단은 이 delete_brand 뿐이므로
--   이 두 함수는 "틀려도 데이터가 안전"(storage.js 주석 그대로)해 이번에 고치지
--   않는다(화면 변경 필요 목록에는 참고용으로 포함).
--
--   반환 타입 불변(jsonb) — CREATE OR REPLACE 로 충분.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_brand(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camps  bigint;
  v_apps   bigint;
  v_sheets bigint;
  v_exists boolean;
BEGIN
  -- 권한: campaign_admin 이상 (174/191 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION '브랜드를 찾을 수 없습니다' USING ERRCODE = '22023';
  END IF;

  -- [325 I-6] 보관 삭제(deleted_at NOT NULL)된 캠페인은 카운트에서 제외.
  -- 30일 뒤 자동 완전삭제되거나 super_admin 이 즉시 완전삭제하면(purge_campaign, 257)
  -- 어차피 행 자체가 사라지므로, 보관 중인 캠페인이 브랜드 삭제를 막을 이유가 없다.
  SELECT count(*) INTO v_camps
    FROM public.campaigns
   WHERE brand_id = p_brand_id
     AND deleted_at IS NULL;
  SELECT count(*) INTO v_apps   FROM public.brand_applications WHERE brand_id = p_brand_id;
  SELECT count(*) INTO v_sheets FROM public.orient_sheets      WHERE brand_id = p_brand_id;

  IF v_camps > 0 OR v_apps > 0 OR v_sheets > 0 THEN
    RAISE EXCEPTION
      '연결된 캠페인 %건, 신청 %건, 오리엔시트 %건이 있어 삭제할 수 없습니다. 병합 기능을 사용하세요.',
      v_camps, v_apps, v_sheets
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.brands WHERE id = p_brand_id;

  RETURN jsonb_build_object('ok', true, 'deleted', p_brand_id);
END;
$$;

COMMENT ON FUNCTION public.delete_brand(uuid) IS
  '[174+191+325] 브랜드 hard delete (연결 0건 한정). campaign_admin 가드. '
  '연결된 캠페인·신청·오리엔시트가 있으면 22023 + 병합 안내. '
  '[325] 캠페인 카운트에서 보관 삭제(deleted_at NOT NULL)된 캠페인 제외 — '
  '이미 사라진 캠페인이 브랜드 삭제를 막지 않도록.';

GRANT EXECUTE ON FUNCTION public.delete_brand(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- 이 절 롤백:
--   191_delete_brand_orient_count.sql 본문(deleted_at 필터 없는 버전)을 그대로 재실행.

COMMIT;

-- ============================================================
-- 검증 SQL (조각별 — 1단계씩 실행·결과 확인 후 다음 단계로. 개발서버 먼저.)
-- ============================================================
/*

-- ── I-1·I-2 검증 ──

-- [1] 함수 시그니처·반환 타입 확인
SELECT routine_name, data_type
  FROM information_schema.routines
 WHERE routine_schema = 'public' AND routine_name = 'soft_delete_campaign';
-- 기대: data_type = 'jsonb' (기존 integer 에서 변경)

-- [2] 스모크 대상 확보 — 영수증/게시물/메시지 첨부가 하나 이상 딸린 캠페인
--     (정산 없는 것) 1건. 개발서버에서 테스트용 캠페인으로 진행할 것.
SELECT c.id, c.title,
       (SELECT count(*) FROM public.applications a WHERE a.campaign_id = c.id) AS app_count,
       (SELECT count(*) FROM public.deliverables d
          JOIN public.applications a2 ON a2.id = d.application_id
         WHERE a2.campaign_id = c.id AND d.receipt_url IS NOT NULL) AS receipt_count
  FROM public.campaigns c
 WHERE c.deleted_at IS NULL
 ORDER BY receipt_count DESC, app_count DESC
 LIMIT 5;

-- [3] 스모크 호출 (앱에서 campaign_admin 로그인 세션으로 — SQL Editor 직접 실행은
--     auth.uid() 가 NULL 이라 permission_denied 로 막힘, 정상)
-- SELECT public.soft_delete_campaign('<위 id>'::uuid);
-- 기대: jsonb, storage_paths_to_delete.receipt_images / message_attachments 에
--       실제 경로가 담겨 있어야 함(그 캠페인에 있었다면)

-- [4] 처리 후 확인 — receipt_edit_history 도 함께 사라졌는지
SELECT count(*) FROM public.receipt_edit_history WHERE campaign_id_snapshot = '<위 id>';
-- 기대: 0

-- [5] applications 0건, campaigns.deleted_at 세팅 확인
SELECT count(*) FROM public.applications WHERE campaign_id = '<위 id>';
SELECT id, deleted_at, deleted_by FROM public.campaigns WHERE id = '<위 id>';
-- 기대: count=0, deleted_at NOT NULL


-- ── I-3 검증 ──

-- [6] 큐 표·함수 생성 확인
SELECT to_regclass('public.influencer_flag_evidence_purge_queue');
SELECT proname FROM pg_proc
 WHERE proname IN ('purge_old_influencer_flags',
                    'list_pending_influencer_flag_evidence_purge',
                    'mark_influencer_flag_evidence_purged')
   AND pronamespace = 'public'::regnamespace;
-- 기대: 표 1건 + 함수 3건

-- [7] 수동 호출(postgres role 로 SQL Editor 에서 직접 실행 가능 — 166 과 동일)
-- SELECT public.purge_old_influencer_flags();
-- 기대: 정수 반환. 현재 3년 이상 된 위반 기록이 없으면 0 (정상 — 아직 검증 못 함)

-- [8] (3년 경과 대상이 있는 경우만) 큐에 실제로 쌓였는지
SELECT * FROM public.influencer_flag_evidence_purge_queue ORDER BY queued_at DESC LIMIT 10;


-- ── I-6 검증 ──

-- [9] 함수 재정의 확인
SELECT prosrc FROM pg_proc WHERE proname = 'delete_brand' AND pronamespace = 'public'::regnamespace;
-- 기대: 'AND deleted_at IS NULL' 문자열 포함

-- [10] 보관 삭제된 캠페인만 있는 브랜드로 삭제 스모크(개발서버, super_admin 세션)
--      먼저 그 브랜드의 캠페인을 soft_delete_campaign 으로 보관 삭제한 뒤:
-- SELECT public.delete_brand('<그 브랜드 id>'::uuid);
-- 기대: ok:true (325 이전에는 "연결된 캠페인 N건" 오류로 막혔을 것)

*/

-- ============================================================
-- 전체 롤백 (조각 4개를 한 번에 되돌릴 때)
-- ============================================================
-- BEGIN;
--   DROP FUNCTION IF EXISTS public.soft_delete_campaign(uuid);
--   -- 255_soft_delete_campaign_fn.sql 본문 재실행 (integer 반환 원본 복원)
--   DROP FUNCTION IF EXISTS public.mark_influencer_flag_evidence_purged(bigint[]);
--   DROP FUNCTION IF EXISTS public.list_pending_influencer_flag_evidence_purge(integer);
--   -- 166_influencer_flags_retention.sql 본문 재실행 (큐잉 없는 원본 복원)
--   DROP TABLE IF EXISTS public.influencer_flag_evidence_purge_queue;
--   -- 191_delete_brand_orient_count.sql 본문 재실행 (deleted_at 필터 없는 원본 복원)
-- COMMIT;
