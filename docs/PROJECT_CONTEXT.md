# REVERB JP — 프로젝트 컨텍스트 (Global Influencer Seeding, KR-JP)

> 이 문서는 프로젝트의 **비즈니스/법률/보안 전체 맥락**을 기술합니다. 모든 기능 개발·리뷰·감사는 이 문서의 원칙을 참조합니다. 변경 시 `.claude/rules/*.md`와 `CLAUDE.md`에도 반영해야 합니다.

---

## 1. 서비스 개요
- **서비스명**: 한-일 크로스보더 인플루언서 시딩 플랫폼 (REVERB JP)
- **모델**: 한국 브랜드(광고주)가 캠페인 등록 → 일본 거주 인플루언서가 신청 → 선정 → 제품 국제배송(KR→JP) → SNS(Instagram/TikTok/X/YouTube/Qoo10) 콘텐츠 업로드 → 검수 → 정산
- **운영사**: 株式会社ジェイファン (JFUN Corp.) — 본사 서울
- **주요 엔드유저**: 브랜드(한국어), 인플루언서(일본어), 관리자(한국어)

### 핵심 프로세스
1. 캠페인 등록 (관리자/브랜드)
2. 인플루언서 신청 → 선정 (reviewed_by/at)
3. 제품 배송 (한국 → 일본, tracking_number)
4. 콘텐츠 업로드 (인스타그램/틱톡 등)
5. 검수 (리뷰, 수정 요청)
6. 정산 (현재 수동, 추후 자동화)

---

## 2. 법률·보안 준수 사항 (Security & Compliance)

### 2-1. 개인정보 보호
- **한국 PIPA** (개인정보 보호법) + **일본 APPI** (個人情報保護法) **이중 준수**
- **국외 이전 동의**: 일본 거주자 데이터를 한국(Supabase 운영)으로 이전함에 대한 **명시적 동의 필수**. 현재 `influencers.terms_agreed_at`, `privacy_agreed_at`에서 포괄 동의 기록 중. 추후 "국외 이전" 별도 동의 항목 분리 예정.
- **비밀번호**: 일방향 해시 (Supabase Auth bcrypt 10 rounds)
- **민감 정보 양방향 암호화**: 계좌/PayPal 이메일/주소 등은 저장 전 암호화 예정 (현재 평문 저장 — 추후 `pgcrypto` 또는 AES 래퍼 도입)
- **접근 로그 1년 이상 보관**: 관리자 페이지 접근·개인정보 조회/수정 이력 기록. 신규 `access_logs` 테이블 필요.

### 2-2. 인증 강화
- **관리자 2FA**: 현재 미구현. Supabase MFA 활성 예정 (TOTP).
- **권한 체크**: RLS + `is_admin()`/`is_super_admin()` 함수. JWT 하드코딩 금지.

### 2-3. 웹 접근성 (장애인차별금지법)
- **WAI-ARIA**: 의미 있는 `role`, `aria-label`, `aria-live` 등 추가
- **이미지 대체 텍스트**: 모든 `<img>`에 의미 있는 `alt` 또는 장식용이면 `alt=""` 명시
- **키보드 접근성**: 모든 인터랙티브 요소 Tab 가능, 포커스 표시
- **색 대비**: WCAG AA 기준 (명도대비 4.5:1 이상)
- 현재 일부 미흡 → 점진 개선

---

## 3. 비즈니스 로직 & 법적 제약

### 3-1. 일본 스테스 마케팅 규제 (뒷광고)
- **일본 소비자청(CAA) 가이드라인** 준수
- 결과물 등록 시 **#PR, #広告, #プロモーション 중 하나 필수 표기**
- 검수 단계에서 태그 존재 확인 후 승인 (자동화 검사 + 수동 확인 이중)
- 미표기 시 경고 + 수정 요청 플로우
- 구현 지점: `receipts`/콘텐츠 업로드 검수 단계

### 3-2. 글로벌 정산 및 세무 (한-일 조세조약)
- **원천징수 기본 22%** (일본 비거주자 대상)
- **거주자 증명서**(居住者証明書) 제출 시 **조세조약 적용 세율**로 가변 (예: 10% 또는 면제)
- **환율**: KRW(브랜드 집행) ↔ JPY(인플루언서 수령). 일일 환율 기록 필수.
- 스키마 필드: `base_amount_krw`, `tax_rate`, `tax_amount`, `exchange_rate_krw_jpy`, `exchange_rate_date`, `final_jpy_amount`
- 현재 **수동 운영**. 추후 PortOne/PayPal API 자동화 예정 → **모듈화 설계 필수**.

### 3-3. 저작권 / 2차 활용
- 콘텐츠 등록 시 **브랜드의 2차 활용(마케팅 용도 재사용) 동의** 별도 체크박스
- 동의 범위: 기간, 매체, 지역 명시
- `applications` 또는 `receipts`에 `secondary_use_agreed_at`, `secondary_use_scope` 컬럼 필요

---

## 4. 데이터 모델 설계 가이드

### 현재 스키마 + 추후 보강 필요
```
Users (influencers):
  - country_code CHAR(2) (NEW)
  - language_pref TEXT (ja/ko) (NEW, default: ja)
  - address_json JSONB (일본 우편번호 7자리, 도도부현 포함) — 현재 분리 컬럼
  - social_metrics JSONB (이미 분리 컬럼으로 존재: ig_followers 등)
  - consent_scope JSONB (국외이전/마케팅/2차활용 각각) (NEW)

Campaigns:
  - brand_id UUID (NEW, 브랜드 테이블 분리 시)
  - product_info JSONB (product, product_url, product_price)
  - shipping_guide TEXT (국제배송 안내)
  - guide_images JSONB (img1~img8)

Participations (applications):
  - status ENUM (pending/approved/rejected/shipped/working/completed) — 확장 필요
  - tracking_number TEXT (NEW, 국제배송 추적)

Settlements (NEW 테이블):
  - id UUID
  - application_id UUID FK
  - base_amount_krw BIGINT
  - tax_rate NUMERIC
  - tax_amount_krw BIGINT
  - exchange_rate NUMERIC
  - exchange_rate_date DATE
  - final_jpy_amount BIGINT
  - payment_provider TEXT (paypal/portone 등)
  - payment_status ENUM
  - paid_at TIMESTAMPTZ

Access Logs (NEW 테이블):
  - id UUID
  - actor_id UUID (관리자 auth_id)
  - action TEXT (view/update/delete)
  - target_table TEXT
  - target_id UUID
  - pii_accessed JSONB (어떤 필드 접근했는지)
  - ip INET, user_agent TEXT
  - created_at TIMESTAMPTZ
  - 보관 정책: 최소 **1년**, 초과 시 아카이브
```

---

## 5. UI/UX 요구사항

### 5-1. 다국어 (i18n)
- **브랜드/관리자 페이지**: 한국어 기본
- **인플루언서 페이지**: 일본어 기본, 한국어 토글 지원(현재 개발서버만)
- i18n 엔진: `dev/lib/i18n/` (ja/ko/index.js), `data-i18n="key"` 속성 + `t()` 헬퍼

### 5-2. 일본 특화 UI
- **우편번호**: 7자리 (예: 150-0001), `-` 자동 포맷, 주소 자동완성
- **도도부현**: 47개 드롭다운 (이미 구현)
- **전화번호**: 090-XXXX-XXXX / 080-XXXX-XXXX 포맷
- **가나 이름**: 후리가나 별도 입력 필드 (배송지 인식용)

---

## 6. 에이전트 수행 지침

### 6-1. 공통 원칙
1. **모든 코드는 2026년 현재 최신 보안 표준과 법령(PIPA/APPI/CAA)을 준수**
2. **개인정보 포함 DB 스키마 설계 시 `access_logs` 등 감사 로그 테이블 동반**
3. **정산/결제 관련 기능은 반드시 모듈화** (PortOne/PayPal 교체 가능한 구조)
4. **일본 규제(스테스 마케팅, 세무)를 계획 단계에서 필수 검토**

### 6-2. 신규 기능 기획 시 체크리스트
- [ ] 개인정보 수집/처리인가? → 동의 범위 명시 + access_logs 기록
- [ ] 국외 데이터 이전 관련인가? → 별도 동의 확인
- [ ] 결제/정산 관련인가? → 모듈화 + 원천징수/환율 고려
- [ ] 콘텐츠 검수 관련인가? → 스테스 표기(#PR/#広告) 자동 확인
- [ ] 관리자 기능인가? → 2FA 체크 + 권한 RLS 검증
- [ ] 웹 접근성 준수하는가? → aria-*, alt, 키보드 Tab 순서

---

## 7. 현재 구현 상태 체크 (2026-04-14 기준)

### ✅ 구현됨
- Supabase Auth (PKCE, 비밀번호 재설정, 초대 플로우)
- RLS 정책 6개 테이블
- 이메일 동의 기록 (terms/privacy/marketing agreed_at)
- 개발/운영 환경 완전 분리
- 인플루언서 페이지 일본어 기본 + 한국어 토글(개발서버)
- 관리자 페이지 한국어
- 우편번호 7자리/도도부현 드롭다운
- PayPal 이메일 필드 (계좌 대체)
- 이미지 Supabase Storage (`campaign-images` 버킷)

### ⚠️ 부분 구현
- 개인정보 양방향 암호화 (평문 저장 중)
- 국외이전 동의 (포괄 동의에 포함, 별도 분리 필요)
- 2차 활용 저작권 동의 (marketing_opt_in과 분리 필요)
- 웹 접근성 (일부 aria 속성, alt 미비)

### ❌ 미구현 (우선순위 필요)
- 관리자 2FA (Supabase MFA 활성)
- `access_logs` 테이블 및 관리자 PII 접근 감사
- 스테스 표기(#PR/#広告) 자동 검사
- 정산 시스템 (원천징수 22% + 환율 + 거주자 증명)
- PortOne/PayPal API 모듈 설계
- 국제배송 tracking_number 플로우
- 브랜드 분리 테이블(`brands`)
- 2차 활용 동의 별도 플로우

---

## 8. 참고 문서
- `CLAUDE.md` — 프로젝트 전반 규칙
- `.claude/rules/security.md` — 보안 규칙
- `.claude/rules/supabase.md` — DB/Auth 규칙
- `.claude/rules/git.md` — Git/배포 규칙
- `docs/FEATURE_SPEC.md` — 기능 명세
- `docs/TERMS_*.md`, `docs/PRIVACY_*.md` — 약관/개인정보처리방침

---

## 9. 문서 개정 이력
- 2026-04-14: 초기 작성 (글로벌 시딩 플랫폼 법률/보안 맥락 통합)
