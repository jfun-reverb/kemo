# REVERB JP — 프로젝트 컨텍스트 (Global Influencer Seeding, KR-JP)

> 이 문서는 프로젝트의 **비즈니스/법률/보안 전체 맥락**을 기술합니다. 모든 기능 개발·리뷰·감사는 이 문서의 원칙을 참조합니다. 변경 시 `.claude/rules/*.md`와 `CLAUDE.md`에도 반영해야 합니다.

---

## 1. 서비스 개요
- **서비스명**: 한-일 크로스보더 인플루언서 시딩 플랫폼 (REVERB JP)
- **모델**: 한국 브랜드(광고주)가 캠페인 등록 → 일본 거주 인플루언서가 신청 → 선정 → 제품 국제배송(KR→JP) → SNS(Instagram/TikTok/X/YouTube/Qoo10) 콘텐츠 업로드 → 검수 → 정산
- **운영사**: 株式会社ジェイファン (JFUN Corp.) — 본사 서울
- **주요 엔드유저**: 브랜드(한국어), 인플루언서(일본어), 관리자(한국어)

### 핵심 프로세스
0. **광고주(브랜드) 인테이크**: `sales.globalreverb.com` 신청 폼(reviewer/seeding) → 관리자 검수·견적 확정 → 계약 → 캠페인 등록으로 연결 (2026-04-20 추가)
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
- **국외 이전 동의**: 일본 거주자 데이터를 **호주 시드니**(Supabase 운영 — AWS Sydney 리전)로 이전함에 대한 **명시적 동의 필수**. 현재 `influencers.terms_agreed_at`, `privacy_agreed_at`에서 포괄 동의 기록 중. 추후 "국외 이전" 별도 동의 항목 분리 예정.
- **처리위탁 업체** (개인정보처리방침 §처리위탁 반영 대상):
  - **Supabase Inc.** (미국 법인 / 데이터 처리 리전: 호주 시드니 AWS) — DB, Auth, Storage, Email Confirmation
  - **Vercel Inc.** (미국) — 정적 호스팅, 엣지 함수
  - **Brevo (Sendinblue SA)** (프랑스, EU) — 트랜잭션 메일 발송 (SMTP 릴레이)
  - 각 업체별로 위탁 사항·위탁 기간·국외 이전 경유지 명시 필요
- **비밀번호**: 일방향 해시 (Supabase Auth bcrypt 10 rounds)
- **민감 정보 양방향 암호화**: 계좌/PayPal 이메일/주소 등은 저장 전 암호화 예정 (현재 평문 저장 — 추후 `pgcrypto` 또는 AES 래퍼 도입)
- **접근 로그 1년 이상 보관**: 관리자 페이지 접근·개인정보 조회/수정 이력 기록. 신규 `access_logs` 테이블 필요.
- **민감 항목 변경 잠금 (운영, migration 075, 2026-04-29)**: closed 캠페인의 주의사항(`caution_items`)/참여방법(`participation_steps`) 변경을 데이터베이스 트리거로 차단 + 캠페인 편집 시 경고 모달(`#sensitiveChangeModal`) 표시 (d79ad39). 신청자에게 영향이 큰 항목의 사후 변경을 막아 사후 분쟁 방지. 인플루언서 개인정보 변경 없음
- **[dev 검증 중] 민감 항목 변경 audit 테이블 (migration 077, 2026-04-30, 운영 미배포)**: `campaign_caution_history` — 캠페인의 주의사항/참여방법 변경을 트리거로 자동 기록(누가/언제/어느 필드/이전·이후 값). SELECT는 super_admin 한정(`is_super_admin()` 행 단위 보안 정책(RLS)), INSERT는 원격 호출 함수(RPC) 경유. 인플루언서 개인정보 자체는 보유하지 않으므로 한국 개인정보 보호법(PIPA)·일본 개인정보보호법(APPI) 영향 무관(운영 감사용)
- **주의사항 동의 보존 (운영, migration 067·069, 2026-04-23)**: 인플루언서가 캠페인 신청 시 표시되는 주의사항(예: PR 태그 의무, 네거티브 리뷰 금지, 일본 내 배송지 한정, 게시 기한 준수, 게시물 3개월 유지)에 단일 체크박스로 동의 → `applications.caution_agreed_at`(timestamptz) + `applications.caution_snapshot`(jsonb v2: `{version, campaign_id, set_id, items, agreed_lang, snapshot_at}`) 저장. 캠페인의 `caution_items` 스냅샷을 신청 시점 그대로 보존하므로 번들(`caution_sets`) 수정 후에도 기존 신청 데이터는 영향 없음. 동의 시각·내용은 인플루언서 활동 로그 — 신청 기록 보유 기간과 동일(탈퇴 시 파기)
- **결과물 영수증 구매정보 관리자 화면 마스킹**(2026-04-30): 관리자 결과물 검수 모달에서 영수증의 `purchase_date`(구매일)·`purchase_amount`(구매금액) 노출 제거. 인플루언서 본인 화면(재제출 폼)에서는 그대로 유지. 개인정보 최소 노출 정책 강화 방향이라 약관 변경 불필요

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

### 3-4. 브랜드 인테이크 & Edge Functions (2026-04-20 추가)
- **신규 개인정보 수집 채널**: `brand_applications` 테이블은 인플루언서 데이터와 **별개**의 광고주 개인정보 수집 채널. 수집 항목: 담당자 이름·전화·이메일·세금계산서 이메일(reviewer). 사업자등록증 이미지 및 `brand-docs` Storage 버킷은 2026-04-21(migration 057)에 수집·저장 중단
- **Edge Function**: `notify-brand-application` (Supabase Functions) — `brand_applications` INSERT 후 클라이언트가 호출 → `admins.receive_brand_notify=true` + env `NOTIFY_ADMIN_EMAILS` 합산 대상에게 Brevo SMTP 경유 알림 메일 발송
- **서브도메인**: `sales.globalreverb.com` / `sales-dev.globalreverb.com` (별도 Vercel 프로젝트 `reverb-sales`, Root Directory=`sales/`). `noindex/nofollow` 메타 유지(검색 노출 차단). 별도 favicon으로 STAGING DEV 아이콘 누수 방지
- **PIPA/APPI 일관성**: 광고주 데이터도 호주 시드니 AWS 리전(Supabase 운영)으로 국외 이전됨 → PRIVACY §5 반영 필요 (docs/PRIVACY_{kr,ja}.md §5 광고주 항목 포함됨)
- **처리위탁 범위**: Edge Function·Storage 모두 Supabase Inc. 위탁 내. 별도 수탁사 추가 없음 (2026-04-20 결정)
- **광고주 자유 입력란**(운영, migration 068, 2026-04-23): `brand_applications.request_note text NULL` — 신청 폼 「기타/요청사항」 자유 입력. `submit_brand_application()` 원격 호출 함수(RPC)에 `p_request_note` 파라미터 추가. 외부 노출 형식 변경이지만 신규 수집 항목 아님 — 약관 영향 없음. 자유 입력란이라 광고주가 본인 외 제3자 정보를 입력할 위험은 운영 가이드(폼 안내 문구)로 대응
- **신청번호 포맷 (운영)**: 서버 트리거가 v1 `JFUN-{Q|N}-YYYYMMDD-NNN`(reviewer=Q, seeding=N, 연도 4자리 숫자) 채번 — `brand_applications.application_no` UNIQUE
- **[dev 검증 중] 신청번호 포맷 v2 (migration 078, 2026-05-04, 운영 미배포)**: 채번을 v2 `JFUN-{R|S}-YYMMDD-NNN`(reviewer=R, seeding=S, 연도 2자리 숫자)로 단축·표준화 + v1 데이터 일괄 변환. 외부 노출 형식 변경이지만 광고주 개인정보 수집 범위는 무관 — 약관 영향 없음
- **광고주 신청 단계에 카톡방 생성 추가**(2026-04-30 migration 076): `paid` 와 `done` 사이에 `kakao_room_created` 단계 추가 (입금 확인 후 카카오 단톡방 개설 가시화). 카카오 단톡방은 운영팀 ↔ 광고주 내부 운영 채널로 운영, 광고주 개인정보를 카카오 측에 위탁 저장하지 않음 → PRIVACY 처리위탁 추가 불필요. 광고주를 단톡방에 초대할 때는 별도 동의 안내 권장(현재 운영 가이드 단계)

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

Brand Applications (2026-04-20 구현):
  - id UUID
  - application_no TEXT UNIQUE (운영: 자동 채번 v1 `JFUN-{Q|N}-YYYYMMDD-NNN` — reviewer=Q, seeding=N. [dev 검증 중] migration 078: v2 `JFUN-{R|S}-YYMMDD-NNN`로 단축, 운영 미배포)
  - form_type TEXT (reviewer|seeding)
  - brand_name, contact_name, phone, email TEXT
  - billing_email TEXT (reviewer 전용, 세금계산서)
  - request_note TEXT (migration 068, 2026-04-23 — 신청자 자유 입력 「기타/요청사항」)
  - products JSONB (상품 배열 1~50)
  - total_jpy, total_qty, estimated_krw NUMERIC (서버 트리거 재계산)
  - final_quote_krw NUMERIC (관리자 확정)
  - status TEXT (10단계 운영: new→reviewing→quoted→paid→kakao_room_created→orient_sheet_sent→schedule_sent→campaign_registered→done / rejected)
  - admin_memo TEXT
  - version INT (낙관적 락)
  - 보관 정책: 계약 미체결 6개월 / 계약 체결 5년 (PRIVACY §6.1 참조)
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

## 7. 현재 구현 상태 체크 (2026-04-20 기준)

### ✅ 구현됨
- Supabase Auth (PKCE, 비밀번호 재설정, 초대 플로우)
- RLS 정책 (campaigns/influencers/applications/admins/receipts/deliverables/brand_applications/lookup_values/participation_sets)
- 이메일 동의 기록 (terms/privacy/marketing agreed_at)
- 개발/운영 환경 완전 분리
- 인플루언서 페이지 일본어 기본 + 한국어 토글(개발서버)
- 관리자 페이지 한국어 (2단 고정 레이아웃, 목록 페인 sticky thead 통일)
- 우편번호 7자리/도도부현 드롭다운
- PayPal 이메일 필드 (계좌 대체)
- 이미지 Supabase Storage (`campaign-images` 버킷)
- **광고주 신청 인테이크 (2026-04-20)**: `sales.globalreverb.com` 서브도메인, `brand_applications` 테이블, `notify-brand-application` Edge Function, 관리자 검수 페인, `admins.receive_brand_notify` 수신자 토글
- **익명 접수 RPC (2026-04-20, migration 056)**: `submit_brand_application()` SECURITY DEFINER RPC로 anon INSERT 경로 안정화. 직접 INSERT 시 42501 RLS 충돌 회피
- **캠페인 번호 `CAMP-YYYY-NNNN` (2026-04-20, migration 055)**: JST 연도별 4자리 순차 채번. `campaigns.campaign_no` UNIQUE + `campaigns_yearly_counter` + BEFORE INSERT 트리거. 기존 캠페인 backfill 완료(dev 5건, prod 51건). 캠페인·신청·결과물 3개 페인 검색창이 `campaign_no` 매칭
- **결과물 엑셀 내보내기 (2026-04-20)**: 캠페인 더보기 메뉴 → 결과물 엑셀(ExcelJS, 영수증 이미지 셀 임베드 + URL 하이퍼링크). CORS 안전 `Image→Canvas→JPEG` 변환
- **배송지 도도부현 분포 도넛 (2026-04-21)**: 대시보드 Top 10 + 未登録/海外 분포 차트. 47개 현 한국어 매핑 `Chart.js` 도넛
- **UI 라벨 `광고주 신청` → `브랜드 서베이` (2026-04-20)**: 사이드바/페인 헤더/tooltip만 교체. 내부 용어·DB(`brand_applications`)·라우트(`#brand-applications`)·함수명은 **모두 "광고주 신청" 그대로 유지**
- **Sales 페이지 리디자인 (2026-04-20/21)**: 랜딩 hero/cards/contact/footer + stats chips 폴리시, reviewer/seeding intro 개편(샘플 이미지·통계 칩), 브랜드 로고 클릭 시 홈 이동
- **관리자 공지사항 시스템 (2026-04-22, migration 063)**: `admin_notices` + `admin_notice_reads` 테이블 + `upsert_admin_notice_read` RPC, 사이드바 최상단 메뉴 + 미읽음 배지, 카테고리 4종(system_update/release/warning/general), 핀 고정, Quill 에디터, 로그인 시 미읽음 팝업
- **인플루언서 verify/violation/블랙리스트 (2026-04-22, migration 059~062)**: `influencer_flags` 이력 테이블, 8종 storage API, 증빙 파일 업로드(`influencer-flag-evidence` 비공개 버킷, 10MB, image/PDF), 위반·블랙 사유 lookup 통합, 상태 관리 카드 + 관리자 이력 타임라인
- **브랜드 서베이 9단계 파이프라인 (2026-04-22, migration 064/065)**: `new→reviewing→schedule_sent→quoted→orient_sheet_sent→campaign_registered→paid→done` / `rejected`. 대시보드 깔때기·도넛·KPI 모두 동기화. "완료" → "최종완료" 라벨링
- **엑셀 내보내기 확장 (2026-04-22)**: 캠페인별 신청자 엑셀(17컬럼 전 상태) + 브랜드 서베이 엑셀 + `formatPhoneDisplay` KR/JP 번호 정규화
- **관리자 리스트 캠페인 multi-select + cascade 필터 (2026-04-22)**: 신청·결과물·캠페인별 신청자 페인. 캠페인 다중 선택 드롭다운 + 타입/kind cascade
- **Vercel Pro 업그레이드 (2026-04-22)**: Hobby 100/day → Pro Team 6,000/day, 동시 빌드 복수, Fast Data Transfer 1 TB/월, Function Duration 1000 GB-Hrs/월. 과거 Hobby Queue 경합·Disconnect 재발 우려 해소
- **주의사항 동의 시스템 (2026-04-23, PR #124, migration 067·069)**: 인플루언서가 캠페인 신청 시 캠페인의 주의사항(예: PR 태그 의무, 네거티브 리뷰 금지, 일본 내 배송지 한정, 게시 기한 준수, 게시물 3개월 유지)에 단일 체크박스로 동의 → `applications.caution_agreed_at`(timestamptz) + `applications.caution_snapshot`(jsonb) 저장. 캠페인의 `caution_items` 스냅샷을 신청 시점 그대로 보존하므로 번들 수정 후에도 기존 신청 데이터는 영향 없음. 응모이력 항목에 동의 시각 작은 배지 노출
- **주의사항 번들 (2026-04-23, migration 069)**: `caution_sets` 테이블 — 주의사항 본문(한·일 양언어) + 선택적 링크 묶음, 모집 타입(`recruit_types[]`) 태깅. 캠페인 등록 폼에서 번들 선택 시 `campaigns.caution_items` jsonb로 스냅샷 복사 + `caution_set_id` 외래 키(FK) ON DELETE SET NULL 로 원본 참조. 번들 수정해도 기존 캠페인 영향 없음 — 참여방법 번들(`participation_sets`) 패턴 미러링
- **광고주 신청 자유 입력란 (2026-04-23, PR #124, migration 068)**: `brand_applications.request_note text NULL` 컬럼 + sales 폼 「기타/요청사항」 입력란 + 관리자 리스트 미리보기 컬럼 + 접수 알림 메일 본문에 포함. `submit_brand_application()` 원격 호출 함수(RPC)에 `p_request_note` 파라미터 추가. 자유 텍스트라 신규 수집 항목 분류 아님 — 약관 영향 없음
- **캠페인 폼 날짜 입력 개편 (2026-04-27, PR #129, migration 072)**: `recruit_start date NULL` 신규 컬럼 + flatpickr range picker 3개 통합(모집/게시/구매·방문) + scheduled→active 자동 전환(`autoOpenCampaigns` mirrors `autoCloseCampaigns`) + 모집 종료 시 결과물 마감 +14일 자동 제안 + 구매·방문 기간을 모집~제출 마감 윈도우로 자동 clamp + 과거 시작일 경고 캘린더 인라인 + monitor 한정 콘텐츠 종류 자동 필터링 + 모집 타입·인원·카테고리 "기본 정보" 섹션 이동 + 미리보기 모달 `掲載期限` 행 제거. 기존 행 `recruit_start IS NULL` 폴백은 인플루언서 화면에서 종전대로 "오늘 ~ 마감" 표시
- **공지사항 draft/published 상태 분리 (2026-04-27, PR #126, migration 071)**: `admin_notices.status text NOT NULL DEFAULT 'draft' CHECK (draft|published)` + `published_at`/`published_by`/`published_by_name`. RLS SELECT는 `published OR is_super_admin() OR created_by=auth.uid()` (draft는 작성자/super 한정). 노출 채널 4개(사이드바 배지·로그인 팝업·대시보드 카드·목록 default)는 published 만 카운트. 편집 모달 모드별 푸터 버튼 분기, 보기 모달 푸터에 작성자/super 한정 `[지금 게시]`/`[게시 회수]`. 미읽음 팝업 "확인" → "상세 보기" 단일 버튼 통일
- **브랜드 서베이 단계 표시 순서 재정렬 (2026-04-27, PR #127)**: 깔때기·드롭다운·통계·`BRAND_APP_STATUS_ORDER`·`BRAND_STATUS_ORDER_FOR_FUNNEL` 표시 순서를 `new → reviewing → quoted → paid → orient_sheet_sent → schedule_sent → campaign_registered → done / rejected` 로 변경(이전: 입금이 거의 마지막에 위치). DB 데이터·status 값은 그대로
- **sales 신청 완료 화면 실 IBK 계좌 (2026-04-27, PR #128)**: reviewer 페이지 Page 3 입금 안내 블록 placeholder `우리은행 1005-XXX-XXXXXX` → 실 계좌 `기업은행 077-156976-01-055`(예금주 (주)제이펀). 라벨은 KO/JA 양언어, 값은 KO-only. 시딩 폼은 종전대로 계좌 표시 없음
- **광고주 메일 템플릿 분리 (2026-04-27, PR #125)**: 메일 3종(`brand-admin-notify`, `brand-ack-reviewer`, `brand-ack-seeding`) HTML을 Edge Function 인라인 → `docs/email-templates/`(SoT) + `_templates/`(미러) 분리. `scripts/sync-email-templates.sh`로 동기화 (`cmp -s` diff). 카탈로그 페이지 `docs/email-templates/index.html`(활성 5종 + 미구현 7종, 인라인 미리보기). 메일 내용·발송 동작은 동일

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
- 브랜드 분리 테이블(`brands`) — 정식 계약 체결 후 엔터티화. `brand_applications`(인테이크)와는 별개 성격
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
- 2026-04-20: 광고주 신청 시스템(`brand_applications`/`brand-docs`/`notify-brand-application`) 도입 — §3-4, §4, §7 반영. `reward_note`, 일본어 용어 표준화(来店→訪問, Reviewer→レビュアー) 반영. 핵심 프로세스 0번 단계 추가.
- 2026-04-21: §7에 2026-04-20/21 배포분 반영 — (1) `CAMP-YYYY-NNNN` 캠페인 번호(migration 055), (2) 익명 접수 RPC `submit_brand_application()`(migration 056)로 anon INSERT 경로 안정화, (3) 결과물 엑셀 내보내기(ExcelJS 이미지 임베드), (4) 대시보드 배송지 도도부현 분포 도넛, (5) 광고주 신청 UI 라벨 → "브랜드 서베이"(내부 용어·DB·라우트는 그대로), (6) Sales 페이지 리디자인. `.claude/commands/배포진단.md` skill + reviewer/typo 가드 hooks도 운영 도구로 정식 등록.
- 2026-04-21(이후): 브랜드 서베이 현황 대시보드(`/admin#brand-dashboard`) 추가 + sales 페이지 Vercel Web Analytics 연동 + **사업자등록증 수집 기능 전면 제거**(migration 057: `business_license_path` 컬럼 DROP + `brand-docs` Storage 버킷 삭제 + RPC 파라미터 하위호환 유지). PRIVACY §2.2/§5/§9에서 사업자등록증 관련 수집·보관 항목 삭제.
- 2026-04-23: PR #124 — 인플루언서 신청 모달 주의사항 동의(migration 067) + 주의사항 번들 시스템(migration 069, `caution_sets` 테이블, 캠페인 폼에서 번들 선택 시 스냅샷 복사) + 광고주 자유 입력란(migration 068, `brand_applications.request_note`) 일괄 도입. 인플루언서 신청 데이터에 `caution_agreed_at`/`caution_snapshot` 추가(활동 로그 — 신청 기록 보유 기간과 동일, 탈퇴 시 파기), 광고주 신청에 `request_note` 추가(자유 텍스트라 신규 수집 항목 아님). PRIVACY/TERMS 영향 없음(동의 로그 보유 기간만 PRIVACY §2.1 표에 명시 추가).

- 2026-04-22: 대규모 기능 묶음 + 인프라 업그레이드 — (1) **관리자 공지사항 시스템** (`/admin#admin-notices`, migration 063 + `admin_notices`·`admin_notice_reads` 테이블, 미읽음 배지, 카테고리 4종, 핀 고정, 로그인 팝업), (2) **인플루언서 verify/violation/블랙리스트 관리** (migration 059~062, `influencer_flags` 이력 테이블, 증빙 파일 업로드 비공개 버킷 `influencer-flag-evidence`), (3) **브랜드 서베이 9단계 상태 파이프라인** (migration 064→8단계·065→9단계 orient_sheet_sent 추가), (4) **엑셀 내보내기 확장** — 캠페인별 신청자 엑셀 + 브랜드 서베이 엑셀 + `formatPhoneDisplay` 포맷 정규화, (5) **관리자 리스트 캠페인 multi-select + cascade 필터** (신청·결과물·캠페인별 신청자 페인), (6) **캠페인 신청자 목록 SNS 전체 표시**, (7) **Vercel Pro 업그레이드** — Hobby 100/day → Pro 6,000/day, 동시 빌드 제한 해소, Fast Data Transfer 1 TB/월. `.claude/commands/공지초안-관리자.md` 슬래시 커맨드(마크다운) 신설 + 기존 `/공지초안`(HTML) deprecated. CI 정리(sales deploy Root Directory 중복 제거, 디버그 step 제거).
- 2026-04-29~30 운영 배포 일괄 — (1) **광고주 신청 단계에 카톡방 생성(`kakao_room_created`) 추가** (migration 076, d860685): `paid` 와 `done` 사이, 입금 확인 후 카카오 단톡방 개설 단계 가시화. 깔때기·드롭다운·통계 표시 순서·CHECK 제약·`BRAND_APP_STATUS_ORDER` 모두 갱신. 카톡방은 내부 운영 채널이라 PRIVACY 처리위탁 추가 무관. (2) **결과물 영수증 구매정보 관리자 화면 마스킹** (0d2b599): 관리자 모달에서 `purchase_date`/`purchase_amount` 노출 제거 (인플루언서 본인 화면은 유지). 개인정보 최소 노출 강화. (3) **캠페인·신청·결과물 표 brand_ko/product_ko 컬럼 분리** (migration 074, 02c432f / 56dcfd4 / 231a638): UI 표시 변경, 개인정보 영향 없음. (4) **민감 항목 변경 잠금 + 경고 모달** (migration 075, d79ad39): closed 캠페인의 `caution_items`/`participation_steps` 변경을 데이터베이스 트리거로 차단 + 캠페인 편집 시 경고 모달 표시. (5) **참여방법/주의사항 편집 모달 분리** (eb78c98 / c5e2cef / 6be9c19): 폼 inline → 별도 모달, bundle summary 한·일 양언어 풀 노출, 미리보기 다국어 토글. (6) **캠페인 상태 도움말 모달** (cdaa146): 캠페인 관리 표 헤더 ⓘ 클릭 시 5단계(draft/scheduled/active/paused/closed) 의미·자동 전이 규칙 안내. (7) **결정 이벤트 트리거 양방향 허용** (migration 073, aea3d7f): `record_deliverable_status_event` 트리거가 `draft↔pending` 양방향 허용 — 결과물 임시저장 후 재제출 흐름 정상화. 모두 인플루언서 개인정보 수집·처리 범위 변경 없음 → PRIVACY/TERMS 변경 불필요. **[dev 검증 중]** 변경 이력 audit 테이블 (migration 077, `campaign_caution_history`): 누가/언제/어느 필드/이전·이후 값을 자동 기록 — 운영 미배포(잠금·경고 모달은 운영 OK, audit 테이블·변경 이력 메뉴만 dev).
- 2026-04-27: PR #125·#126·#127·#128·#129 일괄 운영 배포 — (1) **캠페인 폼 날짜 입력 개편** (PR #129, migration 072) — `recruit_start` 신규 컬럼 + `flatpickr` range picker 3개(모집/게시/구매·방문) + scheduled→active 자동 전환(`autoOpenCampaigns`) + 모집 종료 시 결과물 마감 +14일 자동 제안 + monitor 콘텐츠 종류 자동 필터링 + 모집 타입·인원·카테고리 "기본 정보" 섹션으로 이동 + 미리보기 모달 `掲載期限` 행 제거, (2) **공지사항 draft/published 분리** (PR #126, migration 071) — 작성 즉시 노출되던 동작을 "초안 → 게시" 흐름으로 분리, RLS SELECT는 draft를 작성자/super_admin 한정, 노출 채널 4개(사이드바 배지·로그인 팝업·대시보드 카드·목록 default) published 만 카운트, (3) **공지 미읽음 팝업 UX 정리** — "확인" 버튼 제거 → "상세 보기" 단일 버튼, 등록·수정 후 대시보드 카드 즉시 새로고침, (4) **브랜드 서베이 단계 표시 순서 재정렬** (PR #127) — `new → reviewing → quoted → paid → orient_sheet_sent → schedule_sent → campaign_registered → done / rejected` (이전: 입금이 거의 마지막에 위치, DB 데이터·status 값은 그대로), (5) **sales 신청 완료 화면 실 IBK 계좌 적용** (PR #128) — placeholder `우리은행 1005-XXX-XXXXXX` → 실 계좌 `기업은행 077-156976-01-055`(예금주 (주)제이펀), 시딩 폼은 종전대로 계좌 표시 없음, (6) **광고주 메일 템플릿 분리** (PR #125) — 메일 3종 HTML을 Edge Function 인라인에서 `docs/email-templates/` source of truth + `_templates/` 미러로 분리, `scripts/sync-email-templates.sh` 동기화 스크립트, 카탈로그 페이지 `docs/email-templates/index.html`(활성 5종 + 미구현 7종). 메일 내용·발송 시점은 동일.
