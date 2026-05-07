# notify-deliverable-decision

결과물(deliverables) 검수 알림 메일 자동 발송 Edge Function.

## 트리거
Supabase Database Webhook — `notifications` 테이블의 `INSERT` 이벤트.

- `kind='deliverable_approved'` → 결과물 승인 메일
- `kind='deliverable_rejected'` → 결과물 비승인 메일 (반려 사유 포함)
- `kind='deliverable_changed'` (되돌리기) → 메일 미발송, 알림 패널만 (운영팀 결정)
- 그 외 kind → 무시 (화이트리스트 `MAIL_KINDS`)

## 멱등성
`notifications.mail_sent_at` 컬럼(094 마이그레이션)으로 중복 발송 차단:
1. 페이로드의 `mail_sent_at` 이 채워져 있으면 즉시 종료
2. 발송 직전 DB 재조회로 race 방지
3. Brevo 200 응답 후에만 `mail_sent_at = now()` 마킹
4. 실패 시 `NULL` 유지 → 운영자가 수동 SQL 로 재발송 가능

## 환경변수 (Edge Functions Secrets)

| 키 | 필수 | 설명 |
|---|---|---|
| `BREVO_API_KEY` | ✅ | Brevo Transactional API 키 |
| `BREVO_SENDER_EMAIL` | | 발신자 이메일 (기본 `noreply@globalreverb.com`) |
| `BREVO_SENDER_NAME` | | 발신자 이름 (기본 `REVERB JP` / 개발은 `REVERB JP [DEV]`) |
| `PUBLIC_SITE_URL` | | 인플루언서 사이트 URL (기본 `https://globalreverb.com`) |
| `SUPABASE_URL` | ✅ | 자동 주입 (Supabase Edge Functions runtime) |
| `SUPABASE_SERVICE_ROLE_KEY` | ✅ | 자동 주입 |

## 메일 템플릿

원본은 `docs/email-templates/`. 배포 직전에 `scripts/sync-email-templates.sh` 로 `_templates/` 동기화.

- `deliverable-receipt-approved.html` / `deliverable-receipt-rejected.html`
- `deliverable-review-image-approved.html` / `deliverable-review-image-rejected.html`
- `deliverable-post-approved.html` / `deliverable-post-rejected.html`

공통 placeholder: `{{influencer_name}}`, `{{campaign_title}}`, `{{campaign_brand}}`, `{{submitted_at}}`, `{{reviewed_at}}`, `{{reject_reason_block}}`, `{{post_url}}`, `{{post_channel}}`, `{{activity_link}}`, `{{site_url}}`, `{{help_line_url}}`.

## 배포 절차

```bash
# 1. 템플릿 동기화 (_templates 갱신)
bash scripts/sync-email-templates.sh

# 2. 개발서버 함수 배포
supabase functions deploy notify-deliverable-decision --project-ref qysmxtipobomefudyixw

# 3. 운영서버 함수 배포
supabase functions deploy notify-deliverable-decision --project-ref twofagomeizrtkwlhsuv

# 4. 비밀값 (각 환경별 1회만)
supabase secrets set BREVO_API_KEY=xxx --project-ref <ref>
supabase secrets set BREVO_SENDER_NAME='REVERB JP [DEV]' --project-ref qysmxtipobomefudyixw
```

## Webhook 등록 (Supabase Dashboard)

`Database → Webhooks → Create`:

- Name: `notify-deliverable-decision`
- Table: `notifications`
- Events: `INSERT`
- Type: `Supabase Edge Functions`
- Edge Function: `notify-deliverable-decision`
- HTTP Method: `POST`

## 운영 적용 직전 점검 (소급 발송 폭주 방지)

운영 DB 에서 Webhook 활성화 직전 반드시 실행:

```sql
-- 누적된 미발송 알림을 일괄 마킹 (소급 메일 발송 차단)
UPDATE public.notifications
SET mail_sent_at = now()
WHERE mail_sent_at IS NULL;
```

이 SQL 을 실행하지 않은 채 Webhook 활성화 시, 누적된 모든 결과물 알림이 일제히 메일 발송될 위험.

## 관련 마이그레이션
- `094_notifications_mail_sent_at.sql` — `mail_sent_at` 컬럼 + partial index
- `096_notify_deliverable_approved.sql` — `notify_deliverable_status()` 트리거에 approved 분기 + kind별 일본어 제목 추가
