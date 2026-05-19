-- ============================================================
-- 142_promo_digest_cron.sql
-- 2026-05-19
--
-- 목적:
--   캠페인 홍보 메일 pg_cron 등록.
--   PR 5 — PR 1~4 운영 배포 완료 후 적용.
--
-- 사양서:
--   docs/specs/2026-05-19-campaign-promo-email.md §3-4, §17-2, §17-11
--
-- 발송 주기:
--   매주 월요일·목요일 09:00 KST (= UTC 00:00)
--   cron 표현식: '0 0 * * 1,4'
--   (§17-2 확정 — 일일 발송에서 주 2회로 변경)
--
-- 주의:
--   - 이 파일은 PR 1~4 (마이그레이션 139~141 + Edge Function + 인플 페이지) 운영 배포 완료 후 적용
--   - PR 1~4 없이 이 cron 을 먼저 등록하면 Edge Function 미배포 상태에서 호출 → 에러
--   - 개발서버는 PR 1~3 개발 배포 완료 후 검증용으로 먼저 등록 가능
--
-- 적용 순서:
--   1. 개발서버 (검증용, PR 1~3 배포 완료 후):
--      SQL Editor 실행 → 익일 09:00 KST 인박스 검증
--   2. 운영서버 (PR 1~4 운영 배포 완료 후):
--      SQL Editor 실행 → 다음 월·목 09:00 KST 첫 자동 발송 확인
--
-- 롤백:
--   SELECT cron.unschedule('campaign-promo-digest-weekly');
-- ============================================================

-- ============================================================
-- pg_cron 등록 — 주 2회 (월·목) 09:00 KST
-- ============================================================
SELECT cron.schedule(
  'campaign-promo-digest-weekly',   -- 기존 cron 이 있으면 이름으로 덮어씀
  '0 0 * * 1,4',                    -- 월요일(1)·목요일(4) UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url     := current_setting('app.supabase_url') || '/functions/v1/notify-campaign-promo-digest',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || current_setting('app.supabase_service_role_key')
    ),
    body    := jsonb_build_object('source', 'cron')::text
  );
  $$
);
