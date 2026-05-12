# HANDOFF — 응모 취소 일일 요약 메일 운영 배포 절차

> **작성일**: 2026-05-12 (2026-05-12 dev 검증 후 갱신)
> **대상 작업**: A-PR-D — 응모 취소 일일 요약 메일
> **본 PR의 코드 변경**: dev 머지 완료
> **본 HANDOFF의 대상**: 운영자가 양 서버(개발·운영)에 수동 실행해야 하는 SQL·CLI

---

## 0. 개발 서버 검증 결과 (2026-05-12)

| 항목 | 결과 |
|---|---|
| 마이그레이션 113 적용 | ✅ |
| Edge Function 배포 (`v3`, templates.ts 인라인) | ✅ |
| 환경변수 등록: BREVO_SENDER_NAME, PUBLIC_ADMIN_URL | ✅ (BREVO_API_KEY 는 메일 미발송 결정으로 생략) |
| pg_net + pg_cron + supabase_vault 확장 | ✅ |
| Vault 비밀 (`edge_function_jwt`) 등록 | ✅ |
| Edge Function 수동 호출 검증 | ✅ (취소 1건·수신자 1명 식별, BREVO 없어 `failed` 로그 정상 기록) |
| cron 등록 (`application-cancel-daily-digest`, `0 0 * * *`) | ✅ active=true |

운영 적용 시 본 검증 결과로 안전성 확보. 동일 절차를 운영 프로젝트에 1회 적용.

---

## 1. 본 PR이 포함하는 변경

| 영역 | 파일 |
|---|---|
| 마이그레이션 | `supabase/migrations/113_application_cancel_digest_infra.sql` |
| Edge Function | `supabase/functions/notify-application-cancelled-daily/{index.ts,templates.ts,README.md,_templates/}` |
| 메일 템플릿 원본 | `docs/email-templates/application-cancelled-daily.{html,row.html,preview.html}` |
| 카탈로그 카드 | `docs/email-templates/index.html` (⑫ 추가) |
| sync 스크립트 | `scripts/sync-email-templates.sh` (`notify-application-cancelled-daily` 그룹 + templates.ts 자동 생성 분기) |

> ⚠️ `_templates/*.html` 은 Supabase CLI 가 함수 번들에 포함시키지 않는다.
> `scripts/sync-email-templates.sh` 가 `templates.ts` 를 ES 모듈로 자동 생성하고 `index.ts` 가 `import { TEMPLATES } from "./templates.ts"` 로 읽는다. `_templates/` 디렉토리는 source-of-truth 백업용으로만 유지.

---

## 2. 양 서버 공통 사전 활성화 (확장)

각 환경의 Supabase Dashboard → **Database → Extensions** 에서 다음 3개 토글 ON (대부분 기본 활성화돼 있음. 미활성 시 1회 토글):

- `pg_net` — Edge Function HTTP 호출용
- `pg_cron` — 일일 스케줄 발화용
- `supabase_vault` — service_role JWT 안전 저장용

확인:
```sql
SELECT extname FROM pg_extension WHERE extname IN ('pg_net','pg_cron','supabase_vault');
```
3행이면 OK.

---

## 3. 개발 서버 적용 절차 (완료됨 — 참조용)

운영 절차의 견본. 이미 적용 완료.

### 3-1. 마이그레이션 실행
Supabase 개발 프로젝트(`qysmxtipobomefudyixw`) SQL Editor 에서
`supabase/migrations/113_application_cancel_digest_infra.sql` 본문 실행.

검증:
```sql
SELECT pg_get_functiondef('public.cancel_application'::regproc) LIKE '%admin_notices%';
-- → true

SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'application_cancel_digest_runs';
-- → application_cancel_digest_runs | true

SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_applications_cancelled_at';
-- → 부분 인덱스 정의 표시
```

### 3-2. Edge Function 배포

```bash
bash scripts/sync-email-templates.sh     # _templates → templates.ts 자동 생성
supabase functions deploy notify-application-cancelled-daily \
  --project-ref qysmxtipobomefudyixw
```

### 3-3. 환경변수(Secrets)

```bash
supabase secrets set BREVO_SENDER_NAME='REVERB JP [DEV]' \
  PUBLIC_ADMIN_URL='https://dev.globalreverb.com/admin/' \
  --project-ref qysmxtipobomefudyixw

# 개발서버 메일 발송 안 함 → BREVO_API_KEY 미설정
# 필요해지면:
# supabase secrets set BREVO_API_KEY=<dev_key> --project-ref qysmxtipobomefudyixw
```

### 3-4. Vault 비밀 저장 (service_role JWT)

Dashboard → Project Settings → API → **`service_role`** 키(`eyJ...` 형식) 복사 후:

```sql
SELECT vault.create_secret(
  '<여기에_DEV_SERVICE_ROLE_JWT_붙여넣기>',
  'edge_function_jwt',
  'Service role JWT used by pg_cron to invoke Edge Functions'
);

-- 저장 확인 (값은 안 보임)
SELECT name, description FROM vault.secrets WHERE name = 'edge_function_jwt';
```

> Supabase 호스팅 환경은 `ALTER DATABASE postgres SET ...` 권한 없음. Vault 가 권장 패턴.

### 3-5. 수동 검증 호출

```sql
SELECT net.http_post(
  url := 'https://qysmxtipobomefudyixw.functions.supabase.co/notify-application-cancelled-daily',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || (
      SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
    )
  ),
  body := '{}'::jsonb
);

-- 2~3초 대기 후
SELECT id, status_code, content::text FROM net._http_response ORDER BY created DESC LIMIT 1;
SELECT * FROM public.application_cancel_digest_runs ORDER BY ran_at DESC LIMIT 3;
```

기대 응답:
- 윈도우 내 취소 0건 → `status_code=200`, `content={"ok":true,"skipped":true,"reason":"no_data",...}`
- 취소 있고 BREVO 없음 → `status_code=500`, `content={"error":"BREVO_API_KEY not configured","stage":"send"}` + digest_runs `status='failed'`
- 같은 날짜 재호출 → `status_code=200`, `reason="already_processed"`

### 3-6. pg_cron 등록

```sql
SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',                            -- 매일 UTC 00:00 = 한국시간 09:00
  $$
  SELECT net.http_post(
    url := 'https://qysmxtipobomefudyixw.functions.supabase.co/notify-application-cancelled-daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
      )
    ),
    body := '{}'::jsonb
  );
  $$
);

SELECT jobid, jobname, schedule, active FROM cron.job
 WHERE jobname = 'application-cancel-daily-digest';
-- active=true 1행 확인
```

---

## 4. 운영 서버 적용 절차 (dev → main 머지 직후)

운영 프로젝트 ref: `twofagomeizrtkwlhsuv`

개발 절차와 거의 동일. 차이점만 강조:

### 4-1. 마이그레이션 실행
운영 SQL Editor 에서 `113_application_cancel_digest_infra.sql` 실행. §3-1 동일 검증.

### 4-2. Edge Function 배포

```bash
bash scripts/sync-email-templates.sh
supabase functions deploy notify-application-cancelled-daily \
  --project-ref twofagomeizrtkwlhsuv
```

### 4-3. 환경변수 (운영은 BREVO_API_KEY 필수)

```bash
supabase secrets set BREVO_API_KEY=<prod_brevo_api_key> \
  BREVO_SENDER_NAME='REVERB JP' \
  PUBLIC_ADMIN_URL='https://globalreverb.com/admin/' \
  --project-ref twofagomeizrtkwlhsuv

# 외부 수신자 (옵션)
# supabase secrets set NOTIFY_ADMIN_EMAILS='admin@kemo.jp,marketing@jfun.co.kr' \
#   --project-ref twofagomeizrtkwlhsuv
```

### 4-4. Vault 비밀 저장

Dashboard → 운영 프로젝트 → Project Settings → API → **`service_role`** 키 복사.

운영 SQL Editor:
```sql
SELECT vault.create_secret(
  '<여기에_PROD_SERVICE_ROLE_JWT_붙여넣기>',
  'edge_function_jwt',
  'Service role JWT used by pg_cron to invoke Edge Functions'
);
```

### 4-5. 수동 검증 호출

```sql
SELECT net.http_post(
  url := 'https://twofagomeizrtkwlhsuv.functions.supabase.co/notify-application-cancelled-daily',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || (
      SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
    )
  ),
  body := '{}'::jsonb
);

-- 응답 확인
SELECT id, status_code, content::text FROM net._http_response ORDER BY created DESC LIMIT 1;
SELECT * FROM public.application_cancel_digest_runs ORDER BY ran_at DESC LIMIT 3;
```

운영은 BREVO_API_KEY 설정돼 있으니:
- 전일 취소 0건 → `skipped_no_data`
- 1건 이상 → 메일 1통 실제 발송 + `status='sent'` 로그 (운영자 메일함 도착 확인)

### 4-6. pg_cron 등록

```sql
SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',
  $$
  SELECT net.http_post(
    url := 'https://twofagomeizrtkwlhsuv.functions.supabase.co/notify-application-cancelled-daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'edge_function_jwt' LIMIT 1
      )
    ),
    body := '{}'::jsonb
  );
  $$
);
```

### 4-7. 관리자 메일 수신 설정 (운영팀 별도 단계)

운영 관리자 계정 페이지(`/admin#admin-accounts`) 에서 본인 행 「설정」 버튼 →
모달에서 「응모 취소 알림」 체크박스 ON. 최소 1명 이상 ON 권장.

수신자 0명인 상태에서 cron 이 돌면 `application_cancel_digest_runs.status = 'failed'`
로그 + `no recipients` 메시지로 종료 (메일 미발송).

---

## 5. 롤백 절차

### 5-1. cron 해제
```sql
SELECT cron.unschedule('application-cancel-daily-digest');
```

### 5-2. Vault 비밀 삭제 (선택 — 다른 cron 이 공유 사용 안 하면)
```sql
DELETE FROM vault.secrets WHERE name = 'edge_function_jwt';
```

### 5-3. Edge Function 비활성 (선택)
Dashboard → Edge Functions → notify-application-cancelled-daily → Pause.

### 5-4. 마이그레이션 롤백
```sql
BEGIN;

-- 인덱스
DROP INDEX IF EXISTS public.idx_applications_cancelled_at;

-- 로그 테이블 (이력 데이터 함께 손실 — 사전 백업 권장)
DROP TABLE IF EXISTS public.application_cancel_digest_runs;

-- cancel_application 원격 호출 함수는 104 본문으로 CREATE OR REPLACE 수동 복원
-- (admin_notices INSERT 블록 제거). 104_application_cancellation.sql §3 참조.

COMMIT;
```

> ⚠️ 이미 등록된 `admin_notices` 행은 보존 (UI에서 수동 정리 가능).

---

## 6. 모니터링 포인트

| 신호 | 조치 |
|---|---|
| `application_cancel_digest_runs.status = 'failed'` | error_message 확인 → BREVO_API_KEY / 수신자 / Brevo 한도 점검 |
| `status = 'sent'` 가 며칠째 누락 | cron 실행 자체가 안 됨. `SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;` 로 발화 이력 확인 |
| 같은 날짜 중복 호출 | UNIQUE 충돌로 자동 차단. 함수 응답 `reason="already_processed"` |
| `cancelled_count = 0` 인데 메일이 옴 | 코드 오류. 0건 분기(`skipped_no_data`)가 동작 안 한 경우 |
| Vault 비밀 누락 | cron 발화 시 net._http_response 에 401/500. `SELECT name FROM vault.secrets WHERE name = 'edge_function_jwt';` 로 확인 |

---

## 7. 관련 사양

- `docs/specs/2026-05-11-application-cancel.md` §6 (2026-05-12 일일 요약 패턴으로 재작성)
- `docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md` §7
- `supabase/functions/notify-application-cancelled-daily/README.md`

---

## 8. 변경 이력

- **2026-05-12 초안** — ALTER DATABASE 패턴(GUC) 가정
- **2026-05-12 갱신** — 개발 서버 검증 결과 반영. ALTER DATABASE 권한 거부 발견 → Vault 패턴 전환. `_templates/` 번들 누락 발견 → templates.ts 인라인 패턴 적용. PostgREST FK 임베드 실패 발견 → 캠페인 배치 조회로 교체.
