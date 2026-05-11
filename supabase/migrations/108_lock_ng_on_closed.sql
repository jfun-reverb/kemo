-- ============================================================
-- 108_lock_ng_on_closed.sql
-- closed 캠페인의 NG 사항 변경 차단 — migration 075 트리거 함수 확장
-- 작성일: 2026-05-12
-- ============================================================
-- 목적:
--   migration 075에서 closed 캠페인의 caution_items/caution_set_id/
--   participation_steps/participation_set_id 변경을 DB 레벨에서 차단했다.
--   본 마이그레이션은 잠금 대상에 ng_set_id, ng_items 두 컬럼을 추가한다.
--
-- 정책:
--   closed 상태에서 NG 두 컬럼 중 하나라도 변경되면 RAISE EXCEPTION.
--   기존 caution/participation 잠금 조건은 그대로 유지.
--   status='active'→'closed' 전환 중에 NG 값이 함께 변하지 않는 이상 통과
--   (OLD.status='closed' AND NEW.status='closed' 일 때만 차단).
--
-- 영향:
--   기존 데이터 무영향 (BEFORE UPDATE 트리거 교체만).
--   자동 종료(autoCloseCampaigns)는 NG를 건드리지 않아 영향 없음.
--
-- 구현 방식:
--   CREATE OR REPLACE FUNCTION 으로 075의 함수를 재정의.
--   트리거는 DROP → CREATE (함수 시그니처 동일, 이름 유지).
--
-- 롤백:
--   075의 원본 함수 본문으로 되돌리면 됨.
--   DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
--   CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
--   ... (075 원본 참조)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'closed' AND NEW.status = 'closed' THEN
    -- 주의사항 잠금 (migration 075 기존)
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
    THEN
      RAISE EXCEPTION '종료된 캠페인은 주의사항을 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;

    -- 참여방법 잠금 (migration 075 기존)
    IF OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '종료된 캠페인은 참여방법을 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;

    -- NG 사항 잠금 (migration 108 신규)
    IF OLD.ng_set_id IS DISTINCT FROM NEW.ng_set_id
       OR OLD.ng_items::text IS DISTINCT FROM NEW.ng_items::text
    THEN
      RAISE EXCEPTION '모집이 종료된 캠페인의 NG 사항은 변경할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.block_closed_campaign_caution_participation_update() IS
  'closed 캠페인의 caution_items/caution_set_id/participation_steps/participation_set_id/ng_items/ng_set_id 변경 차단 (migration 075+108)';

-- 트리거는 기존 이름 유지 (075와 동일 트리거 이름)
DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
CREATE TRIGGER trg_block_closed_caution_participation
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_closed_campaign_caution_participation_update();

COMMIT;
