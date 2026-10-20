-- ============================================================
-- 568_cs_comment_attachment_purge_cron.sql
-- CS 메모 첨부 파기 — 매일 예약(서버 함수 purge-cs-comment-attachments 호출)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 「구현 결과」 첨부 파기
--
-- 🔴 **운영 전용 주소**(371 과 같은 방식 — 예약이 운영 함수 주소를 부른다). 개발서버에는 이 파일을 돌리지 않고
--    아래 「개발서버」 줄의 주소로 바꾼 같은 문장을 따로 등록한다(사양서 기록).
-- 🔴 567 과 서버 함수 배포가 **먼저** — 함수가 없으면 예약은 오류 없이 매일 404 를 받는다(net.http_post 는 비동기)
-- 시각: 매일 UTC 21:30 = 한국·일본 06:30 — 기존 예약(18:00~21:15 UTC)과 겹치지 않는 자리
-- 인증: vault.decrypted_secrets 의 'edge_function_jwt'(service_role JWT — 365·371 과 같은 값)
-- 편집기 경고: 안 뜸
-- 롤백: SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'cs-comment-attachment-purge-daily';
-- ============================================================

SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'cs-comment-attachment-purge-daily';

SELECT cron.schedule(
  'cs-comment-attachment-purge-daily',
  '30 21 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://nrwtujmlbktxjgdwlpjj.functions.supabase.co/purge-cs-comment-attachments',
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

-- 개발서버: 위 url 만 https://qysmxtipobomefudyixw.functions.supabase.co/purge-cs-comment-attachments 로 바꿔 등록
