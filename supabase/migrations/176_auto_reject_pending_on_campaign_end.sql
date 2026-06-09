-- ============================================================
-- 176_auto_reject_pending_on_campaign_end.sql
-- 2026-06-09
--
-- 목적:
--   캠페인 status 가 ended(종료) 또는 expired(노출마감) 로 변경될 때
--   해당 캠페인의 pending 신청을 자동으로 rejected 처리한다.
--   인플루언서 앱 알림·메일은 의도적으로 발생시키지 않는다.
--
-- 설계 근거:
--   ① trg_application_status_event (마이그레이션 131·154):
--       - applications.status 변경 시 발화. rejected 전이는 application_events
--         'reject' audit 를 INSERT 함 (정상 기록, 무한루프 없음: campaigns → applications 단방향).
--       - notifications INSERT 는 NEW.status='approved' 케이스에만 발생 → rejected 전이는 알림 없음.
--   ② 인플루언서 일일 다이제스트 메일 (notify-influencer-daily-digest):
--       - reviewed_at >= 어제KST 조건으로 잡음.
--       - auto_reject 는 reviewed_at = NULL 로 두어 메일 자동 제외.
--   ③ closed(모집마감)는 대상 아님 — 모집이 마감됐어도 심사는 가능(영업일 기준 처리).
--       ended/expired 만 처리.
--
-- 변경 내용:
--   (1) applications 테이블에 auto_reject_reason text 컬럼 추가
--       NULL = 일반(수동 포함) / 'campaign_ended' / 'campaign_expired'
--   (2) 트리거 함수 public.reject_pending_on_campaign_end() 생성
--       AFTER UPDATE OF status ON campaigns 에서 발화 → pending 일괄 rejected
--   (3) 트리거 trg_reject_pending_on_campaign_end 등록
--
-- 주의 포인트:
--   - WHERE status='pending' 으로 approved/rejected/cancelled 행 절대 건드리지 않음.
--     (당첨자를 낙첨 처리하는 사고 방지)
--   - SECURITY DEFINER + SET search_path='' 필수 (.claude/rules/security.md)
--   - reviewed_version(낙관적 락) 은 시스템 자동 처리라 갱신하지 않음.
--   - 연쇄 트리거: campaigns UPDATE → applications UPDATE → trg_application_status_event
--     → application_events INSERT ('reject' audit) 만 발생, 알림 없음.
--
-- 백필: 별도 177_auto_reject_pending_backfill.sql 참조.
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_reject_pending_on_campaign_end ON public.campaigns;
--   DROP FUNCTION IF EXISTS public.reject_pending_on_campaign_end();
--   ALTER TABLE public.applications DROP COLUMN IF EXISTS auto_reject_reason;
-- ============================================================

BEGIN;


-- ============================================================
-- (1) auto_reject_reason 컬럼 추가
--     NULL     = 일반 신청 (관리자 수동 처리 포함)
--     'campaign_ended'   = 캠페인 ended 전이로 인한 자동 낙첨
--     'campaign_expired' = 캠페인 expired 전이로 인한 자동 낙첨
-- ============================================================
ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS auto_reject_reason text;

COMMENT ON COLUMN public.applications.auto_reject_reason IS
  '자동 낙첨 식별자. '
  'NULL = 일반(관리자 수동 포함). '
  '''campaign_ended'' = 캠페인 종료(ended) 전이로 인한 자동 낙첨. '
  '''campaign_expired'' = 캠페인 노출마감(expired) 전이로 인한 자동 낙첨. '
  '마이그레이션 176 추가.';


-- ============================================================
-- (2) 트리거 함수: reject_pending_on_campaign_end
--     campaigns.status 가 ended/expired 로 변경될 때
--     해당 캠페인의 pending 신청을 일괄 rejected 처리.
--
--     알림·메일 비발생 이유:
--       - trg_application_status_event 는 rejected 전이에서 notifications INSERT 를 하지 않음.
--       - reviewed_at = NULL 로 설정하여 인플루언서 일일 다이제스트 메일 조건(gte 어제KST)에서 제외.
-- ============================================================
CREATE OR REPLACE FUNCTION public.reject_pending_on_campaign_end()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  -- ended 또는 expired 로 새로 전환된 경우에만 처리.
  -- COALESCE(OLD.status,'') 로 OLD.status 가 NULL 인 엣지케이스도 안전하게 처리.
  IF NEW.status IN ('ended', 'expired')
     AND COALESCE(OLD.status, '') NOT IN ('ended', 'expired')
  THEN
    UPDATE public.applications
      SET status             = 'rejected',
          auto_reject_reason = CASE NEW.status
                                 WHEN 'ended'   THEN 'campaign_ended'
                                 ELSE                'campaign_expired'
                               END,
          reviewed_by        = '시스템(캠페인 종료)',
          -- reviewed_at = NULL: 어제KST 비교 조건에서 자동 제외 → 다이제스트 메일 미발송.
          reviewed_at        = NULL
      WHERE campaign_id = NEW.id
        AND status      = 'pending';
        -- approved / rejected / cancelled 는 WHERE 조건으로 완전 보호.
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.reject_pending_on_campaign_end() IS
  '[176] campaigns.status 가 ended/expired 로 전환될 때 '
  '해당 캠페인의 pending 신청을 자동으로 rejected 처리. '
  'reviewed_at=NULL 로 인플루언서 다이제스트 메일 제외. '
  'SECURITY DEFINER — 트리거에서만 호출.';


-- ============================================================
-- (3) 트리거 등록
--     AFTER UPDATE OF status ON campaigns
--     → 행 단위(FOR EACH ROW) 로 발화
-- ============================================================
DROP TRIGGER IF EXISTS trg_reject_pending_on_campaign_end ON public.campaigns;

CREATE TRIGGER trg_reject_pending_on_campaign_end
  AFTER UPDATE OF status ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_pending_on_campaign_end();

COMMENT ON TRIGGER trg_reject_pending_on_campaign_end ON public.campaigns IS
  '[176] campaigns.status → ended/expired 전이 시 pending 신청 자동 낙첨 트리거.';


COMMIT;
