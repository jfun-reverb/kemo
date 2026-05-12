# notify-application-cancelled-daily

응모 취소 **일일 요약 메일** Edge Function.

## 개요

- **트리거**: pg_cron 매일 UTC 00:00 (= 한국시간 오전 9시) `net.http_post`
- **윈도우**: 전일 한국시간 0시~24시 동안 `cancel_phase != 'recruit'` 인 취소 행
- **수신자**: `get_subscribed_admin_emails('application_cancel')` ∪ env `NOTIFY_ADMIN_EMAILS`
- **언어**: KO
- **0건 처리**: 메일 미발송 + `application_cancel_digest_runs.status = 'skipped_no_data'` 로그
- **중복 방지**: `application_cancel_digest_runs.digest_date` UNIQUE → 같은 날짜 재실행은 즉시 단락

## 환경변수 (Edge Functions Secrets)

| 키 | 비고 |
|---|---|
| `SUPABASE_URL` | 자동 주입 |
| `SUPABASE_SERVICE_ROLE_KEY` | 자동 주입 |
| `BREVO_API_KEY` | 환경별 1회 등록 필수 |
| `NOTIFY_ADMIN_EMAILS` | 외부 수신자 콤마 구분 (옵션) |
| `PUBLIC_ADMIN_URL` | 기본 `https://globalreverb.com/admin/` |
| `BREVO_SENDER_EMAIL` | 기본 `noreply@globalreverb.com` |
| `BREVO_SENDER_NAME` | 운영 `REVERB JP` / 개발 `REVERB JP [DEV]` |

## 템플릿

- 원본: `docs/email-templates/application-cancelled-daily.{html,row.html,preview.html}`
- 미러: `_templates/application-cancelled-daily.{html,row.html}` (sync 스크립트가 복사)

배포 전 반드시 `bash scripts/sync-email-templates.sh` 실행.

## pg_cron 등록 (양 서버 SQL Editor 1회)

```sql
SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',                          -- UTC 00:00 = KST 09:00
  $$
  SELECT net.http_post(
    url := current_setting('app.functions_url', false) || '/notify-application-cancelled-daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.functions_jwt', false)
    ),
    body := '{}'::jsonb
  );
  $$
);
```

> `app.functions_url` / `app.functions_jwt` 는 환경별 GUC. 양 서버 각각
> `ALTER DATABASE postgres SET app.functions_url = 'https://<ref>.functions.supabase.co'` 등으로 설정.

## 배포

```bash
bash scripts/sync-email-templates.sh

# 개발
supabase functions deploy notify-application-cancelled-daily \
  --project-ref qysmxtipobomefudyixw

# 운영
supabase functions deploy notify-application-cancelled-daily \
  --project-ref twofagomeizrtkwlhsuv
```

## 수동 테스트

```bash
# 개발 서버에서 호출 — 어제 KST 윈도우 자동 계산
curl -X POST \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  https://qysmxtipobomefudyixw.functions.supabase.co/notify-application-cancelled-daily \
  -d '{}'
```

응답 예:

```json
{
  "ok": true,
  "digestDate": "2026-05-11",
  "cancelled_count": 3,
  "recipients_count": 2
}
```

같은 날짜 재호출 시:

```json
{
  "ok": true,
  "skipped": true,
  "reason": "already_processed",
  "digestDate": "2026-05-11",
  "prior": { "id": "...", "status": "sent", "ran_at": "2026-05-12T00:00:01Z" }
}
```

## 관련 파일

- 마이그레이션: `supabase/migrations/113_application_cancel_digest_infra.sql`
- 템플릿 원본: `docs/email-templates/application-cancelled-daily.*`
- 동기화 스크립트: `scripts/sync-email-templates.sh`
- 사양서: `docs/specs/2026-05-11-application-cancel.md` §6 (2026-05-12 재작성)
- HANDOFF: `docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md` §7
