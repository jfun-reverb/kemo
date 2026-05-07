-- ============================================================
-- 096_notify_deliverable_approved.sql
-- purpose  : notify_deliverable_status() 트리거에 approved 알림 INSERT 추가
--            (Stage 6에서 "옵션"으로 남겨둔 deliverable_approved 알림을 활성화)
--
-- 배경:
--   - 037_create_notifications.sql 에서 deliverable_approved 종류는 CHECK에
--     포함되었으나, 트리거 함수 내 INSERT 로직이 없어 승인 시 알림이 생성 안 됨.
--   - notify-deliverable-decision Edge Function이 notifications 행을 조회해서
--     메일 발송하므로, approved 상태에서도 알림 행이 존재해야 함.
--   - review_image 추가(093)로 kind='review_image' 승인 시 다른 문구 분기 필요.
--
-- 변경 내용:
--   - notify_deliverable_status() 함수 재정의
--     ① pending/rejected → approved : deliverable_approved 알림 INSERT 추가
--     ② kind별 제목 분기 (receipt/review_image/post 각각 다른 일본어 문구)
--     ③ 기존 ①②③ 분기(rejected/changed/dismiss)는 동일
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행
--   2. 승인 플로우 테스트: deliverables UPDATE status=approved → notifications 확인
--   3. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- rollback:
--   (하단 주석 참고 — 037 원본 함수로 되돌리기)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_deliverable_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_camp_title text;
  v_approved_title text;
BEGIN
  -- 상태가 변하지 않으면 skip
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 캠페인명 조회
  SELECT title INTO v_camp_title FROM public.campaigns WHERE id = NEW.campaign_id;

  -- ① 반려 알림 (pending → rejected, 또는 approved → rejected)
  IF NEW.status = 'rejected' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_rejected',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, 'キャンペーン') || ' — 成果物が差し戻されました',
      NEW.reject_reason
    );

  -- ② 승인 알림 (pending/rejected → approved)
  -- kind별로 다른 제목 사용 (receipt=영수증, review_image=리뷰 이미지, post=게시물)
  ELSIF NEW.status = 'approved' AND OLD.status <> 'approved' THEN
    v_approved_title := CASE NEW.kind
      WHEN 'receipt'       THEN COALESCE(v_camp_title, 'キャンペーン') || ' — レシートが承認されました'
      WHEN 'review_image'  THEN COALESCE(v_camp_title, 'キャンペーン') || ' — レビュー画像が承認されました'
      WHEN 'post'          THEN COALESCE(v_camp_title, 'キャンペーン') || ' — 投稿URLが承認されました'
      ELSE                      COALESCE(v_camp_title, 'キャンペーン') || ' — 成果物が承認されました'
    END;

    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_approved',
      'deliverables',
      NEW.id,
      v_approved_title,
      NULL
    );

  -- ③ 결과 변경 알림 (approved → pending 되돌리기)
  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' AND NEW.status <> 'rejected' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_changed',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, 'キャンペーン') || ' — 審査結果が変更されました',
      '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
    );

  -- ④ 재제출(rejected → pending)일 때: 해당 deliverable의 미읽음 반려 알림 dismiss
  ELSIF OLD.status = 'rejected' AND NEW.status = 'pending' THEN
    UPDATE public.notifications
       SET read_at = now()
     WHERE user_id = NEW.user_id
       AND ref_table = 'deliverables'
       AND ref_id = NEW.id
       AND read_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notify_deliverable_status IS
  '[096] deliverables.status 전이에 따라 notifications 자동 생성·dismiss.
   approved 알림 추가(096), kind별 제목 분기(receipt/review_image/post).
   원본: 037_create_notifications.sql';

COMMIT;


-- ============================================================
-- 검증 쿼리 (적용 후 실행)
-- ============================================================
/*

-- [1] 함수 재정의 확인
SELECT routine_name, routine_definition
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'notify_deliverable_status';

-- [2] approved 알림 INSERT 시뮬레이션 (개발 DB에서만)
--     실제 deliverables 행의 status를 pending → approved로 변경 후 확인
SELECT id, kind, status, created_at
FROM public.notifications
WHERE kind = 'deliverable_approved'
ORDER BY created_at DESC
LIMIT 5;
-- 기대값: 승인 처리 후 1행 생성

*/


-- ============================================================
-- 롤백 (037 원본 함수로 되돌리기)
-- ============================================================
/*

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_deliverable_status()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_camp_title text;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT title INTO v_camp_title FROM public.campaigns WHERE id = NEW.campaign_id;

  IF NEW.status = 'rejected' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_rejected',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, '캠페인') || ' — 成果物が差し戻されました',
      NEW.reject_reason
    );

  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      NEW.user_id,
      'deliverable_changed',
      'deliverables',
      NEW.id,
      COALESCE(v_camp_title, '캠페인') || ' — 審査結果が変更されました',
      '管理者によって結果が変更されました。マイページで詳細をご確認ください。'
    );

  ELSIF OLD.status = 'rejected' AND NEW.status = 'pending' THEN
    UPDATE public.notifications
       SET read_at = now()
     WHERE user_id = NEW.user_id
       AND ref_table = 'deliverables'
       AND ref_id = NEW.id
       AND read_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;

*/
