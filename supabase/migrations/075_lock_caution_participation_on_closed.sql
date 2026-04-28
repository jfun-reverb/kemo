-- 075_lock_caution_participation_on_closed.sql
-- 2026-04-28
--
-- 목적: 종료(closed) 캠페인의 신청 동의 영향 영역 — 주의사항(caution_items, caution_set_id)
--       및 참여방법(participation_steps, participation_set_id) — 변경을 DB 레벨에서 차단.
-- 배경: 인플루언서 신청 시 「全ての注意事項を確認しました」 단일 체크박스 동의를 받고
--       applications.caution_snapshot 에 시점 스냅샷을 보존한다. 그러나 신청자가 이미 들어온
--       active/closed 캠페인의 caution/participation 을 운영자가 무심코 수정하면 동일 캠페인에서
--       기존 신청자(스냅샷)와 신규 신청자(변경 후 문구)가 서로 다른 문구에 동의한 채 공존한다.
--       클라이언트에서도 게이트하지만, DB 트리거로 이중 차단(클라 우회 방지)한다.
-- 정책: closed 상태에서는 caution/participation 4개 컬럼 변경 시도 시 예외 발생.
--       active/scheduled/draft/paused 등 그 외 상태는 클라이언트 경고 모달이 처리(서버 차단 없음).
--       상태가 closed 로 전환되는 UPDATE(예: status='active'→'closed')는 같은 UPDATE 안에서
--       caution/participation 값이 변하지 않는 한 통과(OLD.status='closed' AND NEW.status='closed' 일 때만 차단).
-- 영향: 기존 데이터 무영향 (BEFORE UPDATE 트리거만 추가). 캠페인 자동 종료(autoCloseCampaigns)는
--       caution/participation 을 건드리지 않으므로 영향 없음.

CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'closed' AND NEW.status = 'closed' THEN
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
       OR OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '종료된 캠페인은 주의사항/참여방법을 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
CREATE TRIGGER trg_block_closed_caution_participation
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_closed_campaign_caution_participation_update();

COMMENT ON FUNCTION public.block_closed_campaign_caution_participation_update() IS
  'closed 캠페인의 caution_items/caution_set_id/participation_steps/participation_set_id 변경 차단 (migration 075)';
