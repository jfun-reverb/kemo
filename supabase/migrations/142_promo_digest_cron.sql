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
--
-- 호출 방식은 운영에서 이미 가동 중인 기존 다이제스트 cron 2종
-- (notify-admin-daily-digest / notify-influencer-daily-digest) 패턴을 그대로 따른다:
--   - URL: https://<project-ref>.functions.supabase.co/<function-name>
--   - 인증: vault.decrypted_secrets 의 'edge_function_jwt' (service_role JWT)
--   - body: jsonb (Edge Function 은 source 미지정 시 'cron' 기본 처리)
-- (당초 초안의 current_setting('app.supabase_url') 방식은 운영/개발 DB 에 해당
--  커스텀 설정이 없어 폐기 — 2026-05-20 운영 등록 시 확인)
--
-- ⚠️ URL 의 project-ref 는 환경마다 다르다 — 실행 환경에 맞게 교체:
--   - 운영: twofagomeizrtkwlhsuv
--   - 개발: qysmxtipobomefudyixw
-- ============================================================
SELECT cron.schedule(
  'campaign-promo-digest-weekly',   -- 기존 cron 이 있으면 이름으로 덮어씀
  '0 0 * * 1,4',                    -- 월요일(1)·목요일(4) UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url     := 'https://twofagomeizrtkwlhsuv.functions.supabase.co/notify-campaign-promo-digest',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
      )
    ),
    body    := jsonb_build_object('source', 'cron')
  );
  $$
);
