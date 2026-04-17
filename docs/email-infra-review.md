# 이메일 인프라 검토 보고서

> 작성일: 2026-04-09
> 목적: 서비스 이메일 발송 현황 및 대안 검토, 팀 논의용
> **⚠️ 과거 검토 문서**: 2026-04-16 Brevo Free 300/일 → **Starter 20,000/월 ($29)** 로 업그레이드 완료. 아래 "300건/일" 기재는 당시 기준. 현재 운영 플랜은 `CLAUDE.md` §Email/SMTP 참조.

---

## 1. 현황

### 사용 중인 이메일
| 메일 유형 | 발송 시점 | 발송 주체 |
|----------|----------|----------|
| 회원가입 확인 메일 | 신규 회원가입 시 | Supabase Auth |
| 비밀번호 재설정 메일 | 비밀번호 찾기 요청 시 | Supabase Auth |

### 현재 환경
- Supabase **무료 플랜** 사용 중
- 이메일 발송은 Supabase 내장 메일 서버 사용 (Custom SMTP 미설정)
- 메일 템플릿은 Supabase 대시보드에서 관리

---

## 2. Supabase 이메일 발송 제한

### 플랜별 비교

| 항목 | 무료 플랜 | 프로 플랜 ($25/월) |
|------|----------|------------------|
| 시간당 발송 한도 | 3~4건 | 30건 |
| 하루 최대 (이론치) | ~96건 | ~720건 |
| 하루 신규 가입 처리 가능 | 약 60~80명 | 약 600~700명 |
| 접속자 기준 (하루) | 약 500~800명 | 약 5,000~7,000명 |

> 위 수치는 가입/재설정 메일이 하루에 고르게 분산된다는 가정 기준입니다.
> 특정 시간대에 집중되면 시간당 한도에 먼저 도달합니다.

### 무료 플랜의 위험 시나리오
- 프로모션/광고 집행 시 1시간에 5명 이상 가입 → **일부 확인 메일 발송 실패**
- 사용자는 가입했으나 확인 메일을 못 받아 로그인 불가 → **이탈 발생**
- 비밀번호 재설정 요청까지 합치면 여유가 더 줄어듦

---

## 3. 해결 방안

### 방안 A: Supabase 프로 플랜 업그레이드
- **비용**: $25/월
- **효과**: 시간당 30건, 하루 ~720건
- **장점**: 설정 변경 없이 플랜만 변경하면 됨
- **단점**: 하루 접속자 5,000명 초과 시 여전히 부족할 수 있음
- **적합**: 서비스 초기~중기 (하루 접속자 1,000~5,000명)

### 방안 B: Custom SMTP 연동 (무료 플랜에서도 가능)
Supabase 무료 플랜에서도 외부 SMTP 서버를 설정하면 Supabase의 발송 제한을 우회할 수 있습니다.

#### 무료 SMTP 서비스 비교

| 서비스 | 무료 한도 | 특징 | SMTP 지원 |
|--------|----------|------|----------|
| **Brevo** (구 Sendinblue) | **300건/일** | 가장 넉넉한 무료 한도 | O |
| Resend | 100건/일 | 개발자 친화적, 간편한 설정 | O |
| Mailgun | 100건/일 (첫 1개월 5,000건) | 이후 유료 전환 필요 | O |
| SendGrid | 100건/일 | Twilio 계열, 안정적 | O |

#### 설정 방법
```
Supabase 대시보드 → Authentication → SMTP Settings → Enable Custom SMTP

필요 정보:
- SMTP Host (예: smtp-relay.brevo.com)
- Port (587)
- Username (가입 이메일)
- Password (API 키)
- Sender Name / Email
```

- **비용**: 무료
- **효과**: Brevo 기준 하루 300건 (시간당 제한 없음)
- **장점**: Supabase 플랜 변경 없이 무료로 발송량 확대
- **단점**: 외부 서비스 가입 및 초기 설정 필요, 서비스 장애 시 이중 관리
- **적합**: 비용을 최소화하면서 발송량을 늘리고 싶은 경우

### 방안 C: Google Workspace SMTP 연동 — ⭐ 최적안
- 회사에서 Google Workspace Business Standard 사용 중
- Gmail SMTP를 Supabase Custom SMTP에 연동
- **비용**: 추가 비용 없음 (이미 구독 중)
- **하루 한도**: 2,000건/일 (하루 접속자 10,000명+ 대응 가능)
- **장점**:
  - 신규 서비스 가입 불필요
  - 자사 도메인(@jfun.co.kr)으로 발송 → 높은 신뢰도, 스팸 확률 낮음
  - SPF/DKIM 이미 설정되어 있을 가능성 높음
  - Brevo 대비 6배 이상 넉넉한 한도
- **설정 방법**:
  ```
  Supabase 대시보드 → Authentication → SMTP Settings → Enable Custom SMTP

  Host: smtp.gmail.com
  Port: 587
  Username: 발송용 계정 (예: noreply@jfun.co.kr)
  Password: 앱 비밀번호 (Google 계정 → 보안 → 앱 비밀번호 생성)
  Sender Name: REVERB JP
  Sender Email: noreply@jfun.co.kr
  ```
- **사전 확인 사항**:
  - Google 관리자 콘솔에서 SMTP relay 허용 설정 필요할 수 있음
  - 발송용 계정의 2단계 인증 활성화 → 앱 비밀번호 생성 필요
  - 작업 소요: 약 30분

### 방안 D: 스티비(Stibee) 활용 — ❌ 불가
- 현재 팀에서 스티비를 뉴스레터/마케팅 메일에 사용 중
- **확인 결과**: 스티비는 자체 발송 서버만 사용하며, 외부에 SMTP 서버를 제공하지 않음
  - 스티비 = 뉴스레터/마케팅 메일 전용 (구독자 목록 기반 대량 발송)
  - Supabase Auth = 트랜잭션 메일 (회원가입, 비밀번호 등 개별 이벤트 기반)
  - 스티비의 도메인 설정(SPF/DKIM)은 스티비 내부 발송에만 적용됨
- **결론**: Supabase Custom SMTP에 스티비 연동 불가. 별도 SMTP 서비스(Brevo 등) 필요

---

## 4. 권장안

### 단기 ~ 중기 (서비스 런칭 전 ~ 접속자 10,000명, 비용 0원) ⭐
**→ 방안 C: Google Workspace SMTP 연동**
- 이미 사용 중인 Google Workspace 활용, 추가 비용 없음
- 하루 2,000건, 접속자 10,000명까지 대응 가능
- 자사 도메인(@jfun.co.kr) 발송으로 높은 신뢰도
- 작업 소요: 약 30분

### 장기 (접속자 10,000명 이상)
**→ AWS SES 또는 SendGrid + Supabase 프로**
- AWS SES: $0.10/1,000건 (사실상 무제한)
- Google Workspace 한도(2,000건/일) 초과 시 전환
- 가장 안정적이고 확장 가능한 구성

---

## 5. 접속자 규모별 정리

| 하루 접속자 | 예상 메일 | 권장 방안 | 월 비용 |
|-----------|----------|----------|--------|
| ~100명 | ~13건 | Supabase 무료 (주의 필요) | $0 |
| ~500명 | ~50건 | ⭐ Google Workspace SMTP | $0 |
| ~1,000명 | ~100건 | ⭐ Google Workspace SMTP | $0 |
| ~5,000명 | ~500건 | ⭐ Google Workspace SMTP | $0 |
| ~10,000명 | ~1,000건 | ⭐ Google Workspace SMTP | $0 |
| 10,000명+ | 2,000건+ | AWS SES + Supabase 프로 | $25+ |

---

## 6. 서비스 도메인 메일 발송 설정 가이드

> 서비스 도메인(예: reverbseeding.com) 구매 후 진행

### 6.1 최종 발송 구성

| 항목 | 설정값 |
|------|--------|
| SMTP 서버 | smtp.gmail.com (Google Workspace) |
| Port | 587 (TLS) |
| 인증 계정 | noreply@jfun.co.kr (기존 Workspace 계정) |
| Sender Email | noreply@reverbseeding.com |
| Sender Name | REVERB Seeding |
| 하루 발송 한도 | 2,000건 (Google Workspace Business Standard) |

### 6.2 진행 순서

#### Step 1. 도메인 구매
- reverbseeding.com (또는 결정된 도메인) 구매
- 도메인 등록 업체: 가비아, Cafe24, Cloudflare, Google Domains 등

#### Step 2. DNS 레코드 추가
도메인 관리 페이지에서 아래 TXT 레코드 3개를 추가합니다.

| 레코드명 | 타입 | 호스트 | 값 | 용도 |
|---------|------|--------|-----|------|
| SPF | TXT | @ | `v=spf1 include:_spf.google.com ~all` | Google 발송 인증 |
| DKIM | TXT | google._domainkey | Google 관리자 콘솔에서 생성된 값 | 메일 위변조 방지 |
| DMARC | TXT | _dmarc | `v=DMARC1; p=none; rua=mailto:admin@reverbseeding.com` | 메일 정책 설정 |

> SPF: 이 도메인에서 Google을 통해 보내는 메일이 정당한 메일임을 인증
> DKIM: 메일에 디지털 서명을 추가하여 수신자가 위변조 여부를 확인 가능
> DMARC: SPF/DKIM 실패 시 처리 정책을 정의 (처음엔 p=none으로 모니터링)

#### Step 3. Google 관리자 콘솔 설정
1. [admin.google.com](https://admin.google.com) 접속
2. **계정 → 도메인 → 도메인 관리** → reverbseeding.com 추가 (도메인 별칭 또는 보조 도메인)
3. **앱 → Google Workspace → Gmail → 인증** → DKIM 생성 및 활성화
4. **앱 → Google Workspace → Gmail → 라우팅** → SMTP relay 허용 설정 (필요 시)
5. 발송용 계정(noreply@jfun.co.kr)의 **2단계 인증 활성화 → 앱 비밀번호 생성**
   - Google 계정 → 보안 → 2단계 인증 → 앱 비밀번호 → 생성
   - 생성된 16자리 비밀번호를 Supabase SMTP 설정에 사용

#### Step 4. Supabase SMTP 설정
1. Supabase 대시보드 → **Authentication → SMTP Settings**
2. **Enable Custom SMTP** 활성화
3. 아래 정보 입력:
   ```
   Host:         smtp.gmail.com
   Port:         587
   Username:     noreply@jfun.co.kr
   Password:     [Step 3에서 생성한 앱 비밀번호]
   Sender Name:  REVERB Seeding
   Sender Email: noreply@reverbseeding.com
   ```
4. 저장

#### Step 5. 테스트
1. 테스트 계정으로 회원가입 → 확인 메일 수신 확인
2. 비밀번호 재설정 요청 → 재설정 메일 수신 확인
3. 확인 항목:
   - 발신자가 `noreply@reverbseeding.com`으로 표시되는지
   - 스팸함이 아닌 수신함으로 도착하는지
   - 메일 내 링크가 정상 동작하는지 (리다이렉트 URL 확인)
   - 메일 UI가 깨지지 않는지

#### Step 6. Supabase Redirect URL 등록
- Supabase 대시보드 → **Authentication → URL Configuration → Redirect URLs**
- 서비스 도메인 추가: `https://reverbseeding.com` (또는 실제 사용 도메인)
- 비밀번호 재설정 메일의 링크가 서비스 도메인으로 정상 이동하도록 설정

### 6.3 주의사항
- DNS 레코드 반영에 최대 **24~48시간** 소요될 수 있음 (보통 1~2시간 내 반영)
- DKIM 설정 전 메일 발송 시 스팸 처리될 수 있으므로 **모든 DNS 설정 완료 후 테스트** 권장
- Google Workspace에서 도메인 별칭 추가 시 도메인 소유권 인증(TXT 또는 CNAME) 필요
- 앱 비밀번호는 보안에 주의하여 관리 (Supabase 설정에만 사용, 공유 금지)

---

## 7. 논의 사항

1. **즉시 조치**: Google Workspace SMTP 연동 진행 여부 (추가 비용 없음, 작업 30분)
2. **발송 계정**: noreply@jfun.co.kr 계정 생성 또는 기존 계정 중 발송용으로 사용할 계정 결정
3. **관리자 콘솔**: Google 관리자 콘솔에서 SMTP relay 허용 + 앱 비밀번호 생성 담당자
4. **스티비**: 뉴스레터/마케팅 메일 전용으로 계속 사용 (트랜잭션 SMTP 미지원 확인 완료)
5. **메일 템플릿**: Custom SMTP 연동 시 Supabase 기본 템플릿 그대로 사용 가능 (변경 불필요)
