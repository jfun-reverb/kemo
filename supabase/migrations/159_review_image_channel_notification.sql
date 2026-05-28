-- ============================================================
-- 159_review_image_channel_notification.sql
-- 2026-05-28
--
-- 목적:
--   notify_deliverable_status() 트리거 함수를 재정의해
--   kind='review_image' 결과물의 승인·반려 알림 본문에
--   채널 라벨(lookup_values.name_ja)을 포함시킨다.
--
--   예)
--     승인: 「「@cosme」のレビュー画像が承認されました」
--     반려: 「「Qoo10」のレビュー画像を差し戻しました」
--
--   채널 라벨(post_channel)이 NULL 이거나 lookup 미스인 경우
--   기존 일반 문구("成果物が…")로 폴백해 레거시 행에도 안전.
--
-- 배경:
--   사양서: docs/specs/2026-05-28-multichannel-deliverable-split.md §8
--   037 이 원본 트리거·함수를 등록했으며, 이후 마이그레이션이
--   함수 본체를 수정하지 않아 kind='review_image' 분기가 없는 상태.
--   본 마이그레이션은 함수만 재정의하며, 트리거(trg_deliverable_notify)
--   는 037 등록 그대로 재사용.
--
-- 변경 내용:
--   - DECLARE 에 v_ch_label text 변수 추가
--   - rejected 분기에 kind='review_image' 서브 분기 추가 (반려 문구)
--   - 결과 변경(approved → 기타) 분기에 kind='review_image' 서브 분기 추가
--   - kind='receipt'·'post' 는 기존 문구 그대로 유지
--   - 재제출(rejected → pending) dismiss 로직 변경 없음
--
-- 선행 의존:
--   - 마이그레이션 037: notifications 테이블·트리거·함수 원본
--   - 마이그레이션 157: LIPS·@cosme 채널 lookup_values 추가
--     (name_ja: '@cosme', 'LIPS' 등)
--   - 마이그레이션 158: deliverables_review_image_app_channel_uniq 인덱스
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버는 PR 2(관리자 검수+알림 라벨) 운영 배포 시점에 함께 적용
--
-- 롤백:
--   아래 §롤백 섹션 참조 — notify_deliverable_status() 를 037 버전으로 복원
-- ============================================================

CREATE OR REPLACE FUNCTION public.notify_deliverable_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_camp_title text;
  v_ch_label   text;  -- 159: 채널별 리뷰 이미지 알림용 채널 라벨 (lookup_values.name_ja)
BEGIN
  -- 상태가 변하지 않으면 skip
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 캠페인명 조회
  SELECT title INTO v_camp_title
    FROM public.campaigns
   WHERE id = NEW.campaign_id;

  -- 159: kind='review_image' 에서 post_channel 이 있을 때 채널 라벨 조회
  --      post_channel 이 NULL 이거나 lookup 미스이면 v_ch_label 은 NULL 유지 → 폴백
  IF NEW.kind = 'review_image' AND NEW.post_channel IS NOT NULL THEN
    SELECT name_ja INTO v_ch_label
      FROM public.lookup_values
     WHERE kind = 'channel'
       AND code = NEW.post_channel
     LIMIT 1;
  END IF;

  -- ① 반려 알림 (pending → rejected, 또는 approved → rejected)
  IF NEW.status = 'rejected' THEN

    -- 159: kind='review_image' + 채널 라벨 있음 → 채널 포함 문구
    IF NEW.kind = 'review_image' AND v_ch_label IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_rejected',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 「' || v_ch_label || '」のレビュー画像を差し戻しました',
        NEW.reject_reason
      );
    ELSE
      -- 기존 문구: 영수증·게시물·채널 없는 레거시 review_image 폴백
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_rejected',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 成果物が差し戻されました',
        NEW.reject_reason
      );
    END IF;

  -- ② 결과 변경 알림 (approved → pending 되돌리기 / approved → rejected)
  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN

    -- 159: kind='review_image' + 채널 라벨 있음 → 채널 포함 문구
    IF NEW.kind = 'review_image' AND v_ch_label IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_changed',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 「' || v_ch_label || '」のレビュー画像の審査結果が変更されました',
        '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
      );
    ELSE
      -- 기존 문구: 영수증·게시물·채널 없는 레거시 review_image 폴백
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_changed',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 審査結果が変更されました',
        '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
      );
    END IF;

  -- ③ 재제출(rejected → pending)일 때: 해당 deliverable의 미읽음 반려 알림 dismiss
  ELSIF OLD.status = 'rejected' AND NEW.status = 'pending' THEN
    UPDATE public.notifications
       SET read_at = now()
     WHERE user_id = NEW.user_id
       AND ref_table = 'deliverables'
       AND ref_id = NEW.id
       AND read_at IS NULL;

  -- ④ 승인 알림 (pending/rejected → approved)
  --    사양서 §8: kind='review_image' 는 채널 라벨 포함
  --    (kind='receipt'·'post' 는 기존 "成果物が承認されました" 문구)
  --    주: 037 원본에는 승인 알림이 없었고 이후 버전에서도 deliverable_approved
  --    는 CHECK 제약에만 있었음 — 여기서 신설하되 kind 분기로 안전하게
  ELSIF (OLD.status IN ('pending', 'rejected')) AND NEW.status = 'approved' THEN

    -- 159: kind='review_image' + 채널 라벨 있음 → 채널 포함 승인 문구
    IF NEW.kind = 'review_image' AND v_ch_label IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_approved',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 「' || v_ch_label || '」のレビュー画像が承認されました',
        NULL
      );
    ELSE
      -- 영수증·게시물·채널 없는 레거시 review_image → 일반 문구
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        NEW.user_id,
        'deliverable_approved',
        'deliverables',
        NEW.id,
        COALESCE(v_camp_title, 'キャンペーン') || ' — 成果物が承認されました',
        NULL
      );
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notify_deliverable_status() IS
  '[037+159] deliverables.status 전이에 따라 notifications 자동 생성·dismiss. '
  '159: kind=review_image + post_channel 있을 때 채널 라벨(lookup_values.name_ja) 포함 문구. '
  'NULL post_channel 또는 lookup 미스 시 기존 일반 문구로 폴백. '
  'SECURITY DEFINER — trg_deliverable_notify(037) 트리거에서만 호출.';


-- ============================================================
-- §검증 — 적용 후 개발서버 SQL Editor에서 1단계씩 실행
--
-- [1단계] 함수 본문에 レビュー画像 포함 여부 확인
--   SELECT pg_get_functiondef('public.notify_deliverable_status()'::regprocedure)
--     ~> 'レビュー画像' 문자열 포함 여부 육안 확인
--
--   또는:
--   SELECT prosrc FROM pg_proc
--    WHERE proname = 'notify_deliverable_status'
--      AND pronamespace = 'public'::regnamespace;
--   -- 기대값: v_ch_label, 「のレビュー画像が承認されました」 등 포함
--
-- [2단계] 트리거가 여전히 연결되어 있는지 확인
--   SELECT tgname, tgfoid::regproc AS func
--     FROM pg_trigger
--    WHERE tgrelid = 'public.deliverables'::regclass
--      AND tgname = 'trg_deliverable_notify';
--   -- 기대값: 1 row, func = notify_deliverable_status
--
-- [3단계] review_image 결과물 반려 시 채널 라벨 포함 알림 생성 확인
--   (개발서버에서 monitor 캠페인의 review_image 행 1개를 approved → rejected 로 변경)
--   UPDATE public.deliverables
--      SET status = 'rejected',
--          reject_reason = 'テスト差し戻し',
--          reviewed_by = auth.uid(),
--          reviewed_at = now()
--    WHERE id = '<review_image 행 UUID — post_channel NOT NULL 인 것>'
--      AND kind = 'review_image';
--
--   SELECT kind, title, body, created_at
--     FROM public.notifications
--    WHERE ref_table = 'deliverables'
--      AND ref_id = '<위 UUID>'
--    ORDER BY created_at DESC LIMIT 3;
--   -- 기대값: title에 「「{채널 라벨}」のレビュー画像を差し戻しました」 포함
--
-- [4단계] post_channel NULL 인 레거시 review_image 폴백 확인
--   UPDATE public.deliverables
--      SET status = 'rejected',
--          reject_reason = 'レガシーテスト'
--    WHERE id = '<post_channel IS NULL 인 review_image 행 UUID>'
--      AND kind = 'review_image';
--
--   SELECT title FROM public.notifications
--    WHERE ref_table = 'deliverables' AND ref_id = '<위 UUID>'
--    ORDER BY created_at DESC LIMIT 1;
--   -- 기대값: 「成果物が差し戻されました」 (채널 없는 폴백)
--
-- ============================================================


-- ============================================================
-- §롤백 — 문제 발생 시 037 버전으로 복원
--
-- BEGIN;
--
-- CREATE OR REPLACE FUNCTION public.notify_deliverable_status()
--   RETURNS trigger
--   LANGUAGE plpgsql
--   SECURITY DEFINER
--   SET search_path = ''
-- AS $rollback$
-- DECLARE
--   v_camp_title text;
-- BEGIN
--   IF OLD.status = NEW.status THEN
--     RETURN NEW;
--   END IF;
--
--   SELECT title INTO v_camp_title FROM public.campaigns WHERE id = NEW.campaign_id;
--
--   IF NEW.status = 'rejected' THEN
--     INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
--     VALUES (
--       NEW.user_id,
--       'deliverable_rejected',
--       'deliverables',
--       NEW.id,
--       COALESCE(v_camp_title, 'キャンペーン') || ' — 成果物が差し戻されました',
--       NEW.reject_reason
--     );
--   ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
--     INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
--     VALUES (
--       NEW.user_id,
--       'deliverable_changed',
--       'deliverables',
--       NEW.id,
--       COALESCE(v_camp_title, 'キャンペーン') || ' — 審査結果が変更されました',
--       '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
--     );
--   ELSIF OLD.status = 'rejected' AND NEW.status = 'pending' THEN
--     UPDATE public.notifications
--        SET read_at = now()
--      WHERE user_id = NEW.user_id
--        AND ref_table = 'deliverables'
--        AND ref_id = NEW.id
--        AND read_at IS NULL;
--   END IF;
--
--   RETURN NEW;
-- END;
-- $rollback$;
--
-- COMMENT ON FUNCTION public.notify_deliverable_status() IS
--   'Stage 6: deliverables.status 전이에 따라 notifications 자동 생성·dismiss.';
--
-- COMMIT;
-- ============================================================
