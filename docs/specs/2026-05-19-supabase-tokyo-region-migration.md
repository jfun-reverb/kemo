# Supabase 운영 프로젝트 도쿄 리전 이전 사양서

**작성일:** 2026-05-19
**작성자:** supabase-expert (기획 세션)
**상태:** 초안 — 사용자 결정 대기 (§11 참조)
**관련 진단 사양서:** docs/specs/2026-05-15-admin-perf-diagnosis.md

---

## 1. 배경·동기

### 1-1. 진단 결과 요약

2026-05-15 성능 진단 (마이그레이션 137·138 적용, Performance Advisor 88→62 개선) 이후에도
운영 사용자 페이지 진입 체감 속도 변화가 작다는 보고. 추가 분석 결과:

- Slow Queries Top 20 기준: DB 쿼리 자체는 평균 100ms 이내 → **DB 자체는 병목 아님**
- 페이지 진입 시 `fetchAllPaged` 계열 6회+ 병렬 호출 × 왕복 지연 시간 누적이 실질 병목
- 왕복 지연 시간 원인: 운영 Supabase 프로젝트가 호주 시드니(`ap-southeast-2`) 리전에 있고,
  일본 사용자(도쿄 기준)와의 물리적 거리가 약 7,800km

### 1-2. 왕복 지연 시간(RTT) 실측치 비교

| 경로 | 예상 RTT | 비고 |
|---|---|---|
| 일본(도쿄) ↔ 호주 시드니 `ap-southeast-2` | 100~200ms | 현재 운영 리전 |
| 일본(도쿄) ↔ 일본 도쿄 `ap-northeast-1` | 10~50ms | 이전 목표 리전 |

현재 개발 서버는 이미 도쿄(`ap-northeast-1`)에 있어 인플루언서 테스터가 체감하는 속도와
실 운영 사용자 속도 사이의 간극이 발생하고 있다.

### 1-3. 개선 예상 효과

- API 단건 호출당 왕복 지연 시간 50~150ms 단축
- 페이지 진입 시 6회 병렬 호출 기준: 순수 네트워크 지연만 300~900ms 개선
- 인플루언서 캠페인 목록·신청 플로우, 관리자 목록 페인 모두 체감 개선

---

## 2. 현재 구성 vs 이전 후 비교

| 항목 | 현재 (운영) | 이전 후 (목표) |
|---|---|---|
| Supabase 프로젝트 ID | `twofagomeizrtkwlhsuv` | 신규 (미정) |
| 리전 | 호주 시드니 `ap-southeast-2` | 일본 도쿄 `ap-northeast-1` |
| 컴퓨팅 등급 | NANO | NANO (동일 유지 권장) |
| 플랜 | Pro (조직 `jfun-reverb's Org`) | Pro (조직 공유, 동일) |
| Anon Key | 현재 `sb_publishable_3Kg...` | 이전 후 새 key 발급 |
| Supabase URL | `twofagomeizrtkwlhsuv.supabase.co` | `{새 ID}.supabase.co` |
| 개발 서버 | `qysmxtipobomefudyixw.supabase.co` (도쿄) | 변경 없음 |
| 마이그레이션 최종 | 138 | 138 (동일 — 전체 재적용) |
| Edge Function | 6종 가동 중 | 6종 재배포 필요 |
| pg_cron | 2종 (`UTC 00:00`) | 재등록 필요 |
| Storage 버킷 | `campaign-images` (public) | 재생성 + 데이터 이관 필요 |

---

## 3. 이전 옵션 비교

### 옵션 A — Supabase 공식 「다른 리전으로 복원(Restore to different region)」

Pro 플랜 전용 기능. Supabase 대시보드에서 백업 스냅샷을 선택해 다른 리전의 새 프로젝트에 복원.

**장점:**
- 데이터 일관성이 Supabase가 보장하는 공식 경로
- pg_dump/pg_restore를 직접 다룰 필요 없음
- 스키마 + 데이터를 한 번에 이관

**단점:**
- 복원 완료 시점까지 운영 중 발생한 신규 데이터(트랜잭션 기간의 갱신)는 별도 처리 필요
- 복원 완료 시간이 데이터 양에 따라 30분~수 시간 소요 (정확한 시간 예측 불가)
- auth.users 포함 여부를 Supabase 지원팀에 별도 확인 필요
- 운영 다운타임 동안 신규 가입·신청이 유실될 수 있음 (유지보수 페이지 필요)

**전제 조건:**
- Supabase 대시보드 → 운영 프로젝트 → Settings → Backups에서 최신 백업 스냅샷 확인
- 지원팀에 auth.users, auth.identities 포함 복원 여부 사전 확인 권장

---

### 옵션 B — 새 도쿄 프로젝트 생성 + 수동 마이그레이션 적용 + 데이터 이관

새 Supabase 프로젝트를 도쿄 리전에 생성한 뒤 마이그레이션 SQL을 처음부터 순서대로 재적용.
데이터는 `pg_dump` + `pg_restore` 또는 Supabase 대시보드 데이터 이관 도구 사용.

**장점:**
- 각 단계를 완전히 통제 가능 (스키마 적용 → 데이터 검증 → 전환)
- 마이그레이션 SQL이 순번대로 완전하므로 재현성 보장
- auth.users / auth.identities / Storage 이관 경로가 명확함
- 운영 병행 기간을 길게 잡아서 검증 후 전환 가능 (무중단에 가까운 전환 가능)

**단점:**
- 작업 절차가 많고 수동 오류 가능성
- auth.users 비밀번호 해시(bcrypt) 이관 시 Supabase CLI 또는 지원팀 협조 필요
- Storage 파일(campaign-images 버킷) 별도 복사 필요

**전제 조건:**
- Supabase CLI 설치 및 프로젝트 연결
- 운영 DB 비밀번호(service_role key 또는 DB 직접 연결) 확보

---

### 옵션 C — 현 리전 유지 + 클라이언트 측 최적화 (기각)

왕복 지연 시간은 물리적 거리에서 발생하므로 클라이언트 최적화만으로는 근본 해결 불가.
이미 인덱스 최적화(마이그레이션 137·138)와 중복 요청 제거(PR #205) 적용 완료.
추가 개선 여지가 거의 없어 기각.

---

## 4. 데이터 이관 계획 (옵션 B 기준 상세)

옵션 A(공식 복원)를 선택한 경우는 §4-1 Supabase 복원 후 §4-5~§4-7만 수행.

### 4-1. 이관 대상 데이터

| 범주 | 이관 방법 | 비고 |
|---|---|---|
| public 스키마 테이블 전체 | `pg_dump --schema=public` | 13종 핵심 테이블 + 보조 테이블 |
| auth.users / auth.identities | `pg_dump --schema=auth --table=users --table=identities` | 비밀번호 해시 포함 |
| Storage 파일 (campaign-images) | Supabase 대시보드 또는 `rclone` | 수십~수백 MB 예상 |
| Edge Function 소스 | GitHub 레포에서 재배포 | 코드는 이미 repo에 있음 |
| pg_cron 스케줄 | 수동 SQL로 재등록 | §5-3 참조 |

### 4-2. 이관 금지 대상

- auth.refresh_tokens, auth.sessions — 이전 후 전원 재로그인이 안전
- storage.objects 메타데이터만 이관하고 실 파일은 별도 복사

### 4-3. 이관 순서 (옵션 B)

```
1. 새 프로젝트 생성 (도쿄 리전, Pro NANO)
2. 마이그레이션 001~138 순차 적용 (SQL Editor 또는 Supabase CLI)
3. 시드 데이터 적용 (supabase/seed/ 파일)
4. auth.users / auth.identities 복사 (pg_dump → pg_restore)
5. public 테이블 데이터 복사
6. Storage 파일 복사 (campaign-images 버킷)
7. 검증 SQL 실행 (§7 참조)
8. 외부 시스템 재설정 (§5 참조)
9. SUPABASE_ENVS production 키 교체 → dev 브랜치 배포 (개발서버에서 검증)
10. main 머지 → 운영 배포
11. 운영 검증 후 이전 호주 프로젝트 1주 보존 → 폐기 (§8 참조)
```

### 4-4. 다운타임 최소화 전략

옵션 B는 아래 순서로 다운타임을 최소화할 수 있다:

1. **사전 준비 기간 (다운타임 0)**: 새 프로젝트 생성·마이그레이션·시드 완료
2. **데이터 동기화 (다운타임 0)**: 운영 DB에서 현재 데이터 덤프 후 새 프로젝트에 복원
3. **최종 전환 (다운타임 발생)**: 아래 작업만 순서대로 수행
   - 운영 사이트에 유지보수 안내 (Vercel 환경 변수 `MAINTENANCE_MODE=1` 등)
   - 마지막 delta 데이터 재동기화 (전환 직전 변경분)
   - 코드 키 교체 → main 머지 → Vercel 배포
   - 검증 후 유지보수 해제
4. **예상 다운타임**: 검증 포함 30~60분 (준비 완료 상태에서)

### 4-5. 데이터 무결성 검증 SQL

이전 후 아래 쿼리를 신규 프로젝트에서 실행해 행 수가 이전 프로젝트와 일치하는지 확인:

```sql
SELECT 'campaigns'          AS tbl, count(*) AS cnt FROM public.campaigns
UNION ALL SELECT 'influencers',        count(*) FROM public.influencers
UNION ALL SELECT 'applications',       count(*) FROM public.applications
UNION ALL SELECT 'deliverables',       count(*) FROM public.deliverables
UNION ALL SELECT 'brand_applications', count(*) FROM public.brand_applications
UNION ALL SELECT 'auth.users',         count(*) FROM auth.users
UNION ALL SELECT 'auth.identities',    count(*) FROM auth.identities
ORDER BY tbl;
```

기대값 (2026-05-19 기준):
- campaigns: 114
- influencers: 1398
- applications: 2813
- deliverables: 667
- brand_applications: 33
- auth.users: influencers와 동일 (관리자 포함 일부 추가)

---

## 5. 외부 시스템 영향 + 재설정 절차

새 프로젝트는 URL·Anon Key·Service Role Key가 모두 새로 발급된다.
아래 항목을 **빠짐없이** 신규 프로젝트에 재설정해야 한다.

### 5-1. 코드 변경 (dev/lib/supabase.js)

`SUPABASE_ENVS.production` 항목을 신규 프로젝트 URL과 Anon Key로 교체.

```javascript
// 변경 전
production: {
  url: 'https://twofagomeizrtkwlhsuv.supabase.co',
  key: 'sb_publishable_3KgWYIf5w5J727Q2g3Cl7Q_ETD1Swps'
},

// 변경 후 (새 프로젝트 값으로)
production: {
  url: 'https://{새 프로젝트 ID}.supabase.co',
  key: '{새 Anon Key}'
},
```

영향 파일: `dev/lib/supabase.js` (1개 파일만, 하드코딩 없음)
빌드 후 `dev/build.sh` 실행 필수.

### 5-2. Supabase 대시보드 — Auth 설정

신규 프로젝트 대시보드에서 수동 설정:

| 항목 | 설정값 |
|---|---|
| Site URL | `https://globalreverb.com` |
| Redirect URLs | `https://globalreverb.com/**` |
| Redirect URLs (추가) | `https://www.globalreverb.com/**` |
| Email 인증 (Confirm email) | **ON** (운영 필수) |
| Rate limit for sending emails | **100 emails/h** (기본 30에서 상향) |

### 5-3. SMTP 설정 (Brevo)

Supabase 대시보드 → Authentication → SMTP Settings:

| 항목 | 값 |
|---|---|
| Host | `smtp-relay.brevo.com` |
| Port | `587` |
| Username | Brevo 계정 이메일 |
| Password | Brevo SMTP Key (현재 운영 프로젝트에서 확인) |
| Sender name | `REVERB JP` |
| Sender email | `noreply@globalreverb.com` |

DNS(SPF/DKIM/DMARC)는 도메인이 동일(`globalreverb.com`)하므로 변경 불필요.

### 5-4. Email Templates 재이식

Supabase 대시보드 → Authentication → Email Templates에서 현재 운영 프로젝트의 템플릿을
신규 프로젝트에 복사. 해당 템플릿:

- Confirm signup
- Reset password
- Magic Link
- Invite user (관리자 초대)

> 현재 운영 프로젝트 대시보드에서 템플릿 본문을 복사해 두었다가 신규 프로젝트에 붙여넣기.

### 5-5. Edge Function 재배포

Edge Function은 프로젝트별로 배포되므로 신규 프로젝트에 재배포 필요.
`supabase/functions/` 아래 6종 모두:

```
notify-admin-daily-digest
notify-application-cancelled-daily     (cron 해제 상태이지만 코드 보존)
notify-application-received-admin-daily (cron 해제 상태이지만 코드 보존)
notify-brand-application
notify-deliverable-decision
notify-influencer-daily-digest
```

재배포 명령 (Supabase CLI):
```bash
supabase functions deploy notify-admin-daily-digest --project-ref {새 프로젝트 ID}
supabase functions deploy notify-brand-application --project-ref {새 프로젝트 ID}
supabase functions deploy notify-deliverable-decision --project-ref {새 프로젝트 ID}
supabase functions deploy notify-influencer-daily-digest --project-ref {새 프로젝트 ID}
# cron 해제된 2종도 배포 (롤백 대비 코드 보존)
supabase functions deploy notify-application-cancelled-daily --project-ref {새 프로젝트 ID}
supabase functions deploy notify-application-received-admin-daily --project-ref {새 프로젝트 ID}
```

Edge Function 환경 변수도 신규 프로젝트에 재설정:

| 변수명 | 값 |
|---|---|
| `BREVO_API_KEY` | Brevo API Key |
| `BREVO_SENDER_EMAIL` | `noreply@globalreverb.com` |
| `BREVO_SENDER_NAME` | `REVERB JP` |
| `NOTIFY_ADMIN_EMAILS` | 현재 설정값 그대로 |
| `SUPABASE_URL` | 신규 프로젝트 URL (자동 주입) |
| `SUPABASE_SERVICE_ROLE_KEY` | 신규 service_role key (자동 주입) |

### 5-6. pg_cron 재등록

가동 중인 2개 cron을 신규 프로젝트에 재등록:

```sql
-- 관리자 통합 다이제스트 (매일 UTC 00:00 = KST 09:00)
SELECT cron.schedule(
  'admin-daily-digest',
  '0 0 * * *',
  $$SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/notify-admin-daily-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key')
    ),
    body := '{}'::jsonb
  )$$
);

-- 인플루언서 일일 다이제스트 (매일 UTC 00:00 = KST 09:00)
SELECT cron.schedule(
  'influencer-daily-digest',
  '0 0 * * *',
  $$SELECT net.http_post(
    url := current_setting('app.settings.supabase_url') || '/functions/v1/notify-influencer-daily-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key')
    ),
    body := '{}'::jsonb
  )$$
);
```

> 실제 cron 등록 SQL은 마이그레이션 130·132를 참조해 신규 프로젝트의 설정값에 맞게 조정.

### 5-7. Storage 버킷 재생성

신규 프로젝트에서:

1. `campaign-images` 버킷 생성 (Public 버킷)
2. 현재 운영 버킷 정책 동일하게 적용
3. 파일 복사: 현재 운영 버킷 → 신규 버킷

파일 복사 방법 (선택):
- `rclone` 사용 (대량 파일 복사에 권장)
- Supabase Storage API로 파일 목록 조회 → 다운로드 → 업로드 스크립트 작성
- 파일 수와 용량에 따라 30분~수 시간 소요 예상

### 5-8. Vercel 환경 변수

Vercel 프로젝트 `kemo`와 `reverb-sales` 양쪽에 아래 변수가 있다면 신규 값으로 교체:

| 변수명 | 변경 여부 |
|---|---|
| `NOTIFY_ADMIN_EMAILS` | 변경 없음 (Brevo 주소) |
| `BREVO_API_KEY` | 변경 없음 |
| 기타 Supabase URL 관련 | 코드에 하드코딩 없으므로 변경 불필요 |

> 코드에서 Supabase URL/Key는 `SUPABASE_ENVS`에서만 관리(하드코딩 금지 규칙)하므로,
> Vercel 환경 변수가 별도로 없는 경우 이 항목은 해당 없음.

---

## 6. 다운타임 시간대 권고

### 6-1. 권장 시간대

**새벽 2~4시 KST** (UTC 17:00~19:00 전일)

이유:
- 인플루언서(일본 사용자) 접속이 가장 적은 시간대
- pg_cron 가동 시간(UTC 00:00 = KST 09:00)과 겹치지 않음
- 작업 중 문제 발생 시 담당자가 대응 가능한 심야 시간

### 6-2. 사전 공지 권고

실제 이전 1주 전, 인플루언서 대상 공지:
- 공지 방법: 관리자 공지사항(`/admin#admin-notices`) + LINE 공지
- 공지 내용: 「2026-XX-XX 새벽 2시~4시 시스템 점검 예정. 해당 시간 접속 불가」

---

## 7. 검증 시나리오

### 7-1. 인프라 검증

이전 직후 신규 프로젝트에서:

```sql
-- 1. 행 수 검증 (§4-5 쿼리 재실행)

-- 2. 관리자 계정 로그인 가능 여부 확인
-- 브라우저에서 https://globalreverb.com/admin/ 접속 후 admin@kemo.jp 로그인

-- 3. 마이그레이션 적용 여부 확인
SELECT version()::text, current_setting('server_version');

-- 4. 핵심 함수 존재 확인
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('is_admin', 'is_super_admin', 'is_campaign_admin',
                       'invite_admin', 'cancel_application', 'submit_brand_application',
                       'get_subscribed_admin_emails', 'record_caution_history')
ORDER BY routine_name;
-- 기대값: 8행 모두 존재

-- 5. 행 단위 보안 정책(RLS) 활성 여부 확인
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('campaigns', 'influencers', 'applications', 'deliverables',
                    'admins', 'brand_applications', 'receipts')
ORDER BY tablename;
-- 기대값: rowsecurity = true (모든 행)
```

### 7-2. 기능 회귀 테스트 시나리오 (수동)

| 시나리오 | 확인 방법 |
|---|---|
| 인플루언서 로그인 | `sakura.test@reverb.jp` / `test1234` 로그인 |
| 캠페인 목록 표시 | 인플루언서 화면에서 캠페인 카드 노출 확인 |
| 관리자 로그인 | `admin@kemo.jp` / `admin1234` 로그인 |
| 관리자 캠페인 목록 | `/admin#campaigns` 정상 로드 확인 |
| 관리자 인플루언서 목록 | `/admin#influencers` 정상 로드 확인 |
| 신청 처리 | 테스트 신청 건 승인/반려 동작 |
| Edge Function | 관리자 메일 한 건 수동 트리거 확인 |

### 7-3. 성능 개선 측정

이전 전후 같은 환경에서 측정:

- 브라우저 DevTools Network 탭에서 Supabase API 요청별 TTFB(첫 번째 바이트 수신 시간) 비교
- 기대값: 기존 100~200ms → 이전 후 10~50ms 수준
- 측정 위치: 일본 위치 접속 기준 (또는 일본 소재 VPN 사용)

---

## 8. 롤백 계획

### 8-1. 코드 롤백

`dev/lib/supabase.js`의 `SUPABASE_ENVS.production`을 이전 값으로 되돌리고
`dev/build.sh` 실행 후 `git revert` + `main` 머지.

```javascript
// 롤백 시 복원값
production: {
  url: 'https://twofagomeizrtkwlhsuv.supabase.co',
  key: 'sb_publishable_3KgWYIf5w5J727Q2g3Cl7Q_ETD1Swps'
},
```

### 8-2. 이전 호주 프로젝트 보존 기간

- 이전 후 **1주일(7일)** 간 이전 호주 프로젝트(`twofagomeizrtkwlhsuv`) 유지
- 운영 중 치명적 문제 발생 시 코드 롤백만으로 즉시 복구 가능
- 1주일 경과 후 문제 없음 확인 시 이전 프로젝트 폐기

### 8-3. 비가역 단계 주의

아래 작업은 되돌리기 어렵다. 반드시 신규 프로젝트 검증 완료 후 진행:

- 이전 호주 프로젝트 데이터 삭제 / 프로젝트 폐기
- 이전 프로젝트에서 생성한 사용자가 신규 프로젝트에 없는 경우 영구 유실

---

## 9. 리스크 평가

| 리스크 | 가능성 | 영향 | 대책 |
|---|---|---|---|
| auth.users 이관 실패 (비밀번호 해시 누락) | 중 | 높음 — 전원 비밀번호 재설정 필요 | 이관 후 테스트 계정 로그인 검증 필수 |
| Storage 파일 미이관 (이미지 깨짐) | 중 | 중간 — 캠페인 이미지 노출 불가 | 파일 수 검증 SQL + 샘플 이미지 URL 확인 |
| Edge Function 환경 변수 누락 | 중 | 중간 — 메일 발송 중단 | 배포 후 테스트 메일 발송 1건 확인 |
| pg_cron 미등록 | 낮음 | 낮음 — 다음 날 09:00 다이제스트 미발송 | 이전 당일 등록 여부 확인 |
| 다운타임 연장 (데이터 동기화 지연) | 중 | 높음 — 서비스 중단 연장 | 사전 리허설(개발 서버 대상 모의 이전)으로 소요 시간 측정 |
| 이전 후 쿼리 성능 기대 이하 | 낮음 | 낮음 — 현재보다 나빠지진 않음 | 롤백 준비로 즉시 복구 가능 |

### 9-1. 가장 큰 리스크

auth.users 이관의 완전성. Supabase는 auth 스키마를 외부에서 직접 조작하는 것을 권장하지 않는다.

- **옵션 A (공식 복원)** 선택 시: auth 포함 여부를 Supabase 지원팀에 사전 확인 필요
- **옵션 B (수동 이관)** 선택 시: 이관 후 테스트 계정 전체 로그인 검증 + 실패 시 비밀번호 재설정 메일 일괄 발송 준비

---

## 10. 단계별 작업 분해

### Phase 0 — 결정 단계 (다운타임 없음)

- [ ] 사용자 이전 옵션 결정 (옵션 A 또는 B)
- [ ] Supabase 지원팀에 auth 이관 방법 확인 (옵션 A 선택 시)
- [ ] 다운타임 일정 결정 + 인플루언서 공지 1주 전 발송

### Phase 1 — 사전 준비 (다운타임 없음)

- [ ] 신규 프로젝트 생성 (도쿄 리전, Pro NANO)
- [ ] 마이그레이션 001~138 적용 (SQL Editor 순차 실행)
- [ ] 시드 데이터 적용
- [ ] Auth 설정 (Site URL, Redirect URLs, Confirm email ON, Rate limit 100/h)
- [ ] SMTP 설정 (Brevo)
- [ ] Email Templates 이식
- [ ] Storage 버킷 `campaign-images` 생성 + 정책 적용
- [ ] Edge Function 6종 배포 + 환경 변수 설정
- [ ] pg_cron 2종 등록

### Phase 2 — 데이터 사전 동기화 (다운타임 없음)

- [ ] 운영 DB 전체 덤프 (public + auth 스키마)
- [ ] 신규 프로젝트에 복원
- [ ] Storage 파일 복사 (campaign-images 버킷)
- [ ] 검증 SQL 실행 (행 수 비교)

### Phase 3 — 전환 (다운타임 30~60분)

- [ ] 유지보수 안내 페이지 활성화
- [ ] 마지막 delta 데이터 재동기화
- [ ] `SUPABASE_ENVS.production` 코드 교체 + 빌드 + 개발서버 배포 (코드 사전 검증)
- [ ] main 머지 → 운영 Vercel 배포
- [ ] 검증 시나리오 실행 (§7 참조)
- [ ] 유지보수 안내 해제

### Phase 4 — 안정화 (이전 후 1주)

- [ ] pg_cron 첫 실행 확인 (이전 다음 날 09:00 KST)
- [ ] Edge Function 메일 발송 정상 확인
- [ ] 신규 가입·신청·결과물 제출 정상 처리 확인
- [ ] 1주일 경과 후 이전 호주 프로젝트 폐기

---

## 11. 사용자 결정 — 2026-05-19 확정

### Q1. 이전 진행 여부 → **지금 진행**

운영 페이지 느림의 진짜 병목이 호주 ↔ 일본 RTT 임을 진단으로 확인. 다른 최적화보다 가장 큰 효과 예상되어 즉시 진행.

### Q2. 이전 옵션 → **옵션 A — Supabase 공식 「다른 리전으로 복원」 자동화**

자동화로 데이터 무결성 보장 + 작업량 최소. 단 다음 사전 확인 필수:
- **Supabase 지원팀에 「auth.users 비밀번호 해시 포함 복원 여부」 사전 문의** (Pro 플랜 지원 티켓)
- 만약 auth.users 포함 안 되면 인플 1398명 비밀번호 재설정 안내 필요 → 옵션 B 재검토

### Q3. 다운타임 일정 → **공지 없이 사용자 적은 시간대 진행**

- 구체 일정: KST 새벽 2~4시 (가능하면 화·수요일 — 주말 직후 사용 적음)
- **공지 없이 진행** (다운타임 30~60분 추정, 사용자 영향 최소)
- 도중 사용자 접속 시 「잠시 후 다시 접속해주세요」 안내 화면 자동 (Supabase 복원 중 자동)

### Q4. 사전 리허설 → **임시 프로젝트로 리허설 진행**

- 운영 백업 파일 → 임시 신규 Free Tier 프로젝트 (Tokyo 리전) 에 복원 시도
- 소요 시간 측정 + auth.users 포함 여부 검증 + 외부 시스템 재설정 절차 검증
- 리허설 완료 후 실제 이전 일정 상세화 → 운영 적용

## 12. 다음 단계 (사용자 → 메인 세션)

본 사양서 dev 커밋·푸시·main 머지 후:

1. **사용자**: Supabase 지원팀에 「운영 프로젝트(twofagomeizrtkwlhsuv) 도쿄 리전 이전 시 auth.users 비밀번호 해시 포함 복원 가능 여부」 문의 (Pro 플랜 지원 티켓)
2. **사용자**: 답변 받은 후 임시 Free Tier 프로젝트 신규 생성 → 운영 백업 복원 리허설
3. **메인 세션**: 리허설 결과 받아 §5 「외부 시스템 재설정 절차」 검증·상세화
4. **사용자**: 실제 이전 일정 (날짜·시각) 결정 → 메인 세션에 공유
5. **메인 세션**: 이전 직전 코드·환경 변수 사전 준비 (`dev/lib/supabase.js` SUPABASE_ENVS 운영 URL 교체용 commit 준비)
6. **이전 당일**: Supabase 대시보드 복원 작업 → DNS 전파 확인 → 외부 시스템 재설정 (Edge Function 6종·pg_cron 2종·Vercel 환경변수·Auth URL Configuration·SMTP) → 회귀 테스트
7. **이전 후 1주**: 이전 호주 프로젝트 보존 (롤백 가능 상태) → 안정화 확인 후 폐기

---

## 구현 결과

(개발 세션이 채울 것)

---

## 참고 링크

- Supabase 공식: Point-in-Time Recovery and database migration to a new region
  https://supabase.com/docs/guides/platform/migrating-and-upgrading-projects
- Supabase 지원 티켓 (Pro 플랜): https://supabase.com/dashboard/support
- 관련 진단 사양서: docs/specs/2026-05-15-admin-perf-diagnosis.md
- 마이그레이션 파일 위치: supabase/migrations/001_*.sql ~ 138_*.sql
