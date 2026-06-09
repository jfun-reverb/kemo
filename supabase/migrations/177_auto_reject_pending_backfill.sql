-- ============================================================
-- 177_auto_reject_pending_backfill.sql
-- 2026-06-09
--
-- 목적:
--   176 트리거 도입 이전에 이미 ended/expired 상태인 캠페인의
--   pending 신청을 소급하여 일괄 rejected 처리(백필).
--
-- 전제 조건:
--   마이그레이션 176 (auto_reject_reason 컬럼 + 트리거 함수) 적용 완료.
--
-- 설계 근거 (176과 동일):
--   ① rejected 전이는 trg_application_status_event 가 application_events
--     'reject' audit 를 INSERT 함 (정상, 무한루프 없음).
--   ② 알림(notifications) INSERT 없음 — rejected 전이는 알림 조건 불일치.
--   ③ reviewed_at = NULL 로 인플루언서 일일 다이제스트 메일 제외 (필수).
--
-- 멱등성:
--   WHERE a.status='pending' 조건으로 중복 실행 안전.
--   이미 rejected/approved/cancelled 인 행은 절대 건드리지 않음.
--
-- 주의:
--   - 운영 적용 전 반드시 아래 사전 확인 SELECT 를 먼저 실행하여 대상 건수 확인.
--   - 대상 건수가 예상과 크게 다르면 즉시 멈추고 원인 파악.
--
-- 롤백:
--   이 SQL 자체는 롤백이 의미 없음 (이미 누락 처리된 pending 행을 복구하는 것은
--   비즈니스 판단이 필요). 만약 오적용이 발생했다면 개별 application_id 를 확인 후
--   수동으로 status, auto_reject_reason, reviewed_by, reviewed_at 을 되돌릴 것.
-- ============================================================


-- ============================================================
-- [운영 적용 전 반드시 실행] 사전 확인용 SELECT
-- 이 쿼리를 먼저 실행해서 대상 건수를 확인한 뒤 아래 UPDATE 를 진행할 것.
--
-- SELECT count(*)
--   FROM public.applications a
--   JOIN public.campaigns c ON c.id = a.campaign_id
--  WHERE c.status IN ('ended', 'expired')
--    AND a.status = 'pending';
-- ============================================================


BEGIN;

-- ============================================================
-- 백필 UPDATE
-- ended/expired 캠페인의 pending 신청 → rejected (자동 낙첨)
-- ============================================================
UPDATE public.applications a
  SET status             = 'rejected',
      auto_reject_reason = CASE c.status
                             WHEN 'ended'   THEN 'campaign_ended'
                             ELSE                'campaign_expired'
                           END,
      reviewed_by        = '시스템(캠페인 종료)',
      -- reviewed_at = NULL: 다이제스트 메일 어제KST 비교 조건에서 자동 제외.
      -- 이 행들을 메일에 포함시키면 운영 DB 적용 당일 인플루언서에게 낙첨 메일이 대량 발송됨.
      reviewed_at        = NULL
  FROM public.campaigns c
 WHERE a.campaign_id = c.id
   AND c.status IN ('ended', 'expired')
   AND a.status = 'pending';

-- ============================================================
-- [사후 확인용 SELECT — UPDATE 직후 실행]
-- 0 행이 나와야 정상 (남아있는 pending 이 없음).
--
-- SELECT count(*)
--   FROM public.applications a
--   JOIN public.campaigns c ON c.id = a.campaign_id
--  WHERE c.status IN ('ended', 'expired')
--    AND a.status = 'pending';
-- ============================================================

COMMIT;
