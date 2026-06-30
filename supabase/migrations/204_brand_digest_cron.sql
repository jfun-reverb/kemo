-- ============================================================
-- 204_brand_digest_cron.sql
-- 2026-06-30
--
-- 목적:
--   브랜드 일일 보고(notify-brand-daily-digest) pg_cron 등록.
--   오리엔시트 제출 알림 PR2 의 자동 발송 스케줄.
--
-- 사양서:
--   docs/specs/2026-06-30-orient-submit-notification.md §3 ⑨, §10 PR2
--
-- 발송 주기:
--   매일 09:00 KST (= UTC 00:00)  cron 표현식 '0 0 * * *'
--
-- 호출 방식 (기존 다이제스트 cron 선례 142 와 동일):
--   - URL : https://<project-ref>.functions.supabase.co/notify-brand-daily-digest
--   - 인증: vault.decrypted_secrets 의 'edge_function_jwt' (service_role JWT)
--   - body: {'source':'cron'}  (Edge Function 은 source 미지정 시 'cron' 기본 처리)
--
-- ⚠️ URL 의 project-ref 는 환경마다 다르다 — 실행 환경에 맞게 교체:
--   - 운영(production, 도쿄): nrwtujmlbktxjgdwlpjj   ← 아래 기본값
--   - 개발(staging, 도쿄)   : qysmxtipobomefudyixw
--
-- 적용 이력:
--   - 운영: 2026-06-30 SQL Editor 실행 완료 (job 'brand-daily-digest-0900kst', active=true).
--     PR1·PR2 운영 배포(마이그202·203 + Edge Function 2개 + 웹훅 + 수동 발송 검증) 직후 등록.
--   - 개발: 미등록(dev BREVO 키 없음 — feedback_dev_no_mail_test). 필요 시 위 dev ref 로 교체 실행.
--
-- 롤백:
--   SELECT cron.unschedule('brand-daily-digest-0900kst');
-- ============================================================

SELECT cron.schedule(
  'brand-daily-digest-0900kst',     -- 같은 이름이면 기존 schedule 을 덮어씀
  '0 0 * * *',                      -- 매일 UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url     := 'https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/notify-brand-daily-digest',
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
