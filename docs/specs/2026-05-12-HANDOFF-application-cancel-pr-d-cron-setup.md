# HANDOFF — 응모 취소 일일 요약 메일 운영 배포 절차

> **작성일**: 2026-05-12
> **대상 작업**: A-PR-D — 응모 취소 일일 요약 메일
> **본 PR의 코드 변경**: dev 머지 단계 — 코드/마이그레이션/Edge Function/템플릿/카탈로그
> **본 HANDOFF의 대상**: dev → main 머지 + 운영 배포 시 **운영자가 수동 실행할 SQL·CLI**

---

## 1. 본 PR이 포함하는 변경

| 영역 | 파일 |
|---|---|
| 마이그레이션 | `supabase/migrations/113_application_cancel_digest_infra.sql` |
| Edge Function | `supabase/functions/notify-application-cancelled-daily/{index.ts,README.md,_templates/}` |
| 메일 템플릿 원본 | `docs/email-templates/application-cancelled-daily.{html,row.html,preview.html}` |
| 카탈로그 카드 | `docs/email-templates/index.html` (⑫ 추가) |
| sync 스크립트 | `scripts/sync-email-templates.sh` (`notify-application-cancelled-daily` 그룹 추가) |

**dev 푸시 시점에 개발 서버에 자동 적용되는 것**: 없음 (마이그레이션·Edge Function·pg_cron 모두 수동 실행).

---

## 2. 개발 서버 적용 절차

### 2-1. 마이그레이션 실행
Supabase 개발 프로젝트(`qysmxtipobomefudyixw`) SQL Editor 에서
`supabase/migrations/113_application_cancel_digest_infra.sql` 본문 실행.

검증:
```sql
-- cancel_application 본문에 INSERT INTO public.admin_notices 가 있는지
\df+ public.cancel_application

-- 신규 테이블 존재 + RLS 활성
SELECT relname, relrowsecurity FROM pg_class
 WHERE relname = 'application_cancel_digest_runs';

-- 부분 인덱스 존재
SELECT indexdef FROM pg_indexes
 WHERE indexname = 'idx_applications_cancelled_at';
```

### 2-2. Edge Function 배포

```bash
# 템플릿 sync (변경 없으면 unchanged 출력)
bash scripts/sync-email-templates.sh

# 개발 환경 배포
supabase functions deploy notify-application-cancelled-daily \
  --project-ref qysmxtipobomefudyixw
```

### 2-3. 환경변수(Secrets) — 개발 환경 1회

```bash
supabase secrets set BREVO_API_KEY=<dev_key>          --project-ref qysmxtipobomefudyixw
supabase secrets set BREVO_SENDER_NAME='REVERB JP [DEV]' --project-ref qysmxtipobomefudyixw
supabase secrets set PUBLIC_ADMIN_URL='https://dev.globalreverb.com/admin/' --project-ref qysmxtipobomefudyixw
# 필요 시
supabase secrets set NOTIFY_ADMIN_EMAILS='admin@kemo.jp,marketing@jfun.co.kr' \
  --project-ref qysmxtipobomefudyixw
```

### 2-4. pg_cron 등록 (개발 환경)

개발 서버 SQL Editor 에서 한 번만 실행. `app.functions_url` 와 `app.functions_jwt` 는
환경별 GUC — 먼저 설정해야 한다.

```sql
-- 환경별 GUC 설정 (개발 프로젝트)
ALTER DATABASE postgres SET app.functions_url
  TO 'https://qysmxtipobomefudyixw.functions.supabase.co';
ALTER DATABASE postgres SET app.functions_jwt
  TO '<DEV_SERVICE_ROLE_JWT>';

-- 동일 세션에서 SHOW app.functions_url; 로 확인 안 됨 (다음 connection 부터 적용).
-- pg_cron 워커가 다음 호출 시점에 새 값으로 읽음.

-- 신규 cron job 등록
SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',
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

> ⚠️ `app.functions_jwt` 에는 **service_role JWT** 를 넣는다. anon 키로는 Edge Function 호출 차단됨.

### 2-5. 수동 호출 검증

```bash
curl -X POST \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
  -H "Content-Type: application/json" \
  https://qysmxtipobomefudyixw.functions.supabase.co/notify-application-cancelled-daily \
  -d '{}'
```

기대 응답 (전일 윈도우에 취소 0건일 때):
```json
{"ok":true,"skipped":true,"reason":"no_data","digestDate":"2026-05-11","duplicate":false}
```

검증:
```sql
SELECT * FROM public.application_cancel_digest_runs ORDER BY ran_at DESC LIMIT 3;
```

같은 날짜로 즉시 재호출 시 `already_processed` 단락 확인:
```json
{"ok":true,"skipped":true,"reason":"already_processed","digestDate":"2026-05-11","prior":{...}}
```

---

## 3. 운영 서버 적용 절차 (dev → main 머지 직후)

운영 프로젝트 ref: `twofagomeizrtkwlhsuv`

### 3-1. 마이그레이션 실행
운영 SQL Editor 에서 `113_application_cancel_digest_infra.sql` 실행.

### 3-2. Edge Function 배포

```bash
bash scripts/sync-email-templates.sh
supabase functions deploy notify-application-cancelled-daily \
  --project-ref twofagomeizrtkwlhsuv
```

### 3-3. 환경변수

```bash
supabase secrets set BREVO_API_KEY=<prod_key>          --project-ref twofagomeizrtkwlhsuv
supabase secrets set BREVO_SENDER_NAME='REVERB JP'     --project-ref twofagomeizrtkwlhsuv
supabase secrets set PUBLIC_ADMIN_URL='https://globalreverb.com/admin/' --project-ref twofagomeizrtkwlhsuv
# 필요 시
supabase secrets set NOTIFY_ADMIN_EMAILS='admin@kemo.jp,marketing@jfun.co.kr' \
  --project-ref twofagomeizrtkwlhsuv
```

### 3-4. pg_cron 등록 (운영)

```sql
ALTER DATABASE postgres SET app.functions_url
  TO 'https://twofagomeizrtkwlhsuv.functions.supabase.co';
ALTER DATABASE postgres SET app.functions_jwt
  TO '<PROD_SERVICE_ROLE_JWT>';

SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',
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

### 3-5. 관리자 메일 수신 설정 (운영 — 운영팀 별도 단계)

운영 관리자 계정 페이지(`/admin#admin-accounts`) 에서 본인 행 「설정」 버튼 →
모달에서 「응모 취소 알림」 체크박스 ON. 최소 1명 이상 ON 권장.

수신자 0명인 상태에서 cron 이 돌면 `application_cancel_digest_runs.status = 'failed'`
로그 + `no recipients` 메시지로 종료 (메일 미발송).

---

## 4. 롤백 절차

### 4-1. cron 해제
```sql
SELECT cron.unschedule('application-cancel-daily-digest');
```

### 4-2. Edge Function 비활성 (선택)
Dashboard → Edge Functions → notify-application-cancelled-daily → Pause.

### 4-3. 마이그레이션 롤백
```sql
BEGIN;

-- 인덱스
DROP INDEX IF EXISTS public.idx_applications_cancelled_at;

-- 로그 테이블 (이력 데이터 함께 손실 — 사전 백업 권장)
DROP TABLE IF EXISTS public.application_cancel_digest_runs;

-- cancel_application 원격 호출 함수 본문은 104 본문으로 CREATE OR REPLACE 수동 복원
-- (admin_notices INSERT 블록 제거)
-- 직접 복원 시 104_application_cancellation.sql 본문 §3 참조

COMMIT;
```

> ⚠️ 이미 등록된 `admin_notices` 행은 보존 (UI에서 수동 정리 가능).

---

## 5. 모니터링 포인트

| 신호 | 조치 |
|---|---|
| `application_cancel_digest_runs.status = 'failed'` | error_message 확인 → Brevo·SMTP 키 점검 |
| `status = 'sent'` 가 며칠째 누락 | cron 실행 자체가 안 됨 → `SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;` |
| 같은 날짜 중복 호출 | UNIQUE 충돌로 자동 차단. Edge Function 로그에서 `already_processed` 단락 메시지 |
| `cancelled_count = 0` 인데 메일이 옴 | 코드 오류 — Edge Function 0건 분기(`skipped_no_data`) 확인 |

---

## 6. 관련 사양

- `docs/specs/2026-05-11-application-cancel.md` §6 (2026-05-12 일일 요약 패턴으로 재작성)
- `docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md` §7
- `supabase/functions/notify-application-cancelled-daily/README.md`
