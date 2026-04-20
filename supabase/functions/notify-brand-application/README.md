# notify-brand-application

광고주 신청 폼(`brand_applications`) INSERT 시 Brevo Transactional API로 2통 이메일 자동 발송하는 Edge Function.

## 발송 대상
1. **관리자** (`NOTIFY_ADMIN_EMAILS`) — 신규 접수 알림 (한국어, 관리자 페이지 딥링크 포함)
2. **브랜드 담당자** (row.email) — 접수 확인 (일본어, 신청번호 + 다음 단계)

## 환경변수 (Secrets)

| 키 | 필수 | 기본값 | 설명 |
|----|------|--------|------|
| `BREVO_API_KEY` | ✅ | — | Brevo Transactional API Key |
| `NOTIFY_ADMIN_EMAILS` | — | `jfun@jfun.co.kr` | 관리자 수신자 (콤마 구분) |
| `PUBLIC_ADMIN_URL` | — | `https://globalreverb.com/admin/` | 관리자 페이지 절대 URL |
| `BREVO_SENDER_EMAIL` | — | `noreply@globalreverb.com` | 발신 이메일 |
| `BREVO_SENDER_NAME` | — | `REVERB JP` | 발신자명 (개발은 `REVERB JP [DEV]` 권장) |

## 배포

### 개발 서버 (qysmxtipobomefudyixw)

```bash
# 함수 배포
supabase functions deploy notify-brand-application --project-ref qysmxtipobomefudyixw

# Secrets 설정
supabase secrets set \
  BREVO_API_KEY=<개발용 Brevo API Key> \
  NOTIFY_ADMIN_EMAILS=jfun@jfun.co.kr \
  PUBLIC_ADMIN_URL=https://dev.globalreverb.com/admin/ \
  BREVO_SENDER_NAME="REVERB JP [DEV]" \
  --project-ref qysmxtipobomefudyixw
```

### 운영 서버 (twofagomeizrtkwlhsuv)

```bash
supabase functions deploy notify-brand-application --project-ref twofagomeizrtkwlhsuv

supabase secrets set \
  BREVO_API_KEY=<운영용 Brevo API Key> \
  NOTIFY_ADMIN_EMAILS=jfun@jfun.co.kr \
  PUBLIC_ADMIN_URL=https://globalreverb.com/admin/ \
  BREVO_SENDER_NAME="REVERB JP" \
  --project-ref twofagomeizrtkwlhsuv
```

## Webhook 연결 (양 서버 각각)

Supabase Dashboard → Database → **Webhooks** → **Create a new hook**

| 항목 | 값 |
|------|----|
| Name | `notify-brand-application` |
| Table | `brand_applications` |
| Events | `Insert` 만 체크 |
| Type | `Supabase Edge Functions` |
| Edge Function | `notify-brand-application` |
| HTTP Method | `POST` |
| HTTP Headers | 기본값 유지 |
| HTTP Params | 없음 |

## 로컬 테스트

```bash
# 로컬 실행
supabase functions serve notify-brand-application --env-file .env.local

# curl 테스트 (payload 예시)
curl -X POST http://localhost:54321/functions/v1/notify-brand-application \
  -H "Content-Type: application/json" \
  -d '{
    "type":"INSERT",
    "table":"brand_applications",
    "schema":"public",
    "record":{
      "id":"11111111-2222-3333-4444-555555555555",
      "application_no":"JFUN-Q-20260420-999",
      "form_type":"reviewer",
      "brand_name":"테스트브랜드",
      "contact_name":"홍길동",
      "phone":"010-1234-5678",
      "email":"test-brand@example.com",
      "billing_email":"billing@example.com",
      "products":[{"name":"테스트 상품","url":"https://example.com","price":5300,"qty":10}],
      "total_jpy":53000,
      "total_qty":10,
      "estimated_krw":611000,
      "created_at":"2026-04-20T10:00:00Z"
    }
  }'
```

## 응답 형식

```json
{ "admin": true, "brand": true, "errors": [] }
```

둘 중 하나라도 실패하면 `errors` 배열에 사유 기록. 둘 다 실패 시 500 응답.

## 모니터링

- Supabase Dashboard → Edge Functions → Logs
- Brevo 대시보드 → Transactional → Statistics (발송량·bounce·complaint)

## 제한 · 주의

- Webhook은 **at-least-once** delivery — 중복 발송 가능성 있음. 현재는 트러스트하고 발생 시 수동 정리. 향후 `brand_applications.notified_at` 컬럼 + idempotency 키로 방어 예정.
- Brevo Starter 쿼터 20,000/월을 Supabase Auth 메일과 공용. 광고주 신청 급증 시 쿼터 잠식 주의.
- 발신 도메인 `globalreverb.com`의 SPF/DKIM/DMARC가 Brevo에 인증돼 있어야 스팸 분류 회피.
