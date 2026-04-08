# REVERB JP — 기능정의서

> 일본 시장 대상 인플루언서 체험단(리뷰어/기프팅) 모집 플랫폼
> 최종 업데이트: 2026-04-08

---

## 1. 시스템 개요

| 항목        | 내용                                    |
| ----------- | --------------------------------------- |
| 서비스명    | REVERB JP                               |
| 대상 시장   | 일본                                    |
| 사용자 유형 | 인플루언서 (모바일), 관리자 (PC)        |
| 기술 스택   | HTML/CSS/JS (vanilla), Supabase, Vercel |
| UI 언어     | 일본어                                  |

---

## 2. 인플루언서 앱 (모바일 480px)

### 2.1 회원가입

| ID      | 기능             | 상세                                                        |
| ------- | ---------------- | ----------------------------------------------------------- |
| INF-001 | 1단계 가입 폼    | 이름 한자, 이름 가나, 이메일, 비밀번호, 비밀번호 확인       |
| INF-002 | 유효성 검증      | 이름 필수, 비밀번호 8자 이상, 비밀번호 일치 확인            |
| INF-003 | 자동 프로필 생성 | auth.users 생성 시 influencers 레코드 자동 생성 (DB 트리거) |
| INF-004 | 추가 정보 입력   | SNS 계정, 주소, 전화, 은행정보는 마이페이지에서 별도 입력   |

### 2.2 로그인/인증

| ID      | 기능               | 상세                                                          |
| ------- | ------------------ | ------------------------------------------------------------- |
| INF-010 | 이메일 로그인      | 이메일 + 비밀번호 인증                                        |
| INF-011 | 세션 복원          | 페이지 로드 시 기존 세션 자동 복원                            |
| INF-012 | 로그아웃           | 세션 클리어 후 홈으로 이동                                    |
| INF-013 | 관리자 감지        | 로그인 시 admins 테이블 확인, 관리자면 admin 페이지 자동 오픈 |
| INF-014 | 프로필 미존재 폴백 | 로그인 시 influencers 레코드 없으면 자동 생성                 |
| INF-015 | 비밀번호 재설정 | 이메일 입력 → Supabase 재설정 메일 발송 → 앱 내 새 비밀번호 설정 |

### 2.3 캠페인 목록 (홈)

| ID      | 기능                | 상세                                                |
| ------- | ------------------- | --------------------------------------------------- |
| INF-020 | 캠페인 그리드       | active/scheduled 캠페인 카드 목록                   |
| INF-021 | 상태 배지           | NEW, 募集中(모집중), 近日公開(예정), 募集終了(마감) |
| INF-022 | 카테고리 그라데이션 | beauty, food, fashion, health, other별 배경색       |
| INF-023 | 통계 표시           | 총 캠페인 수, 브랜드 수 실시간 표시                 |
| INF-024 | 정렬                | order_index → created_at 순                        |

### 2.4 캠페인 탐색/필터

| ID      | 기능          | 상세                                    |
| ------- | ------------- | --------------------------------------- |
| INF-030 | 채널 필터     | Instagram, X, TikTok, YouTube, Qoo10 탭 |
| INF-031 | 모집유형 필터 | 모니터(리뷰어) / 기프팅                 |

### 2.5 캠페인 상세

| ID      | 기능          | 상세                                                         |
| ------- | ------------- | ------------------------------------------------------------ |
| INF-040 | 이미지 캐러셀 | 메인 이미지 + 최대 8장 슬라이드, 인디케이터 + 번호 표시      |
| INF-041 | 상품 정보     | 상품명, 가격, 보수 금액, 무상 제공 표시                      |
| INF-042 | 모집 조건     | 모집유형, 채널, 콘텐츠 유형, 기간, 정원, 당선발표, 투고 기한 |
| INF-043 | 참가 방법     | 3단계 안내 (응모 → SNS 리뷰 투고 → LINE으로 링크 전송)     |
| INF-044 | 가이드라인    | 브랜드 어필포인트, 해시태그, 멘션                            |
| INF-045 | 촬영 가이드   | 사진/영상 촬영 안내                                          |
| INF-046 | NG 사항       | 금지 행위/표현 목록                                          |
| INF-047 | 주의사항      | 기한 준수, 가이드라인 준수, 6개월 게시 유지 등 고정 안내     |
| INF-048 | 외부 링크     | 상품 페이지, LINE(@586mnjoc), Instagram(@reverb_jp) CTA 카드 |

### 2.6 캠페인 신청

| ID      | 기능              | 상세                                                       |
| ------- | ----------------- | ---------------------------------------------------------- |
| INF-050 | 비로그인 안내     | 미로그인 시 로그인 프롬프트 오버레이 표시                  |
| INF-051 | 필수정보 사전체크 | 캠페인 채널에 맞는 SNS ID, 배송지, 전화번호, 은행계좌 확인 |
| INF-052 | 미비정보 안내     | 부족한 정보 목록을 경고 오버레이로 표시, 마이페이지로 유도 |
| INF-053 | 신청 모달         | 동기 메시지 입력                                           |
| INF-054 | 배송지 입력       | 프로필에서 자동 입력, 수정 가능                            |
| INF-055 | PR 태그 동의      | #PR 태그 사용 동의 체크박스                                |
| INF-056 | 중복 신청 방지    | 동일 캠페인 재신청 차단 (DB 조회)                          |
| INF-057 | 신청 카운트       | campaigns.applied_count 자동 증가                          |
| INF-058 | 신청 완료 후      | 상세 페이지 새로고침, 버튼 "응募済み"로 변경               |

### 2.7 마이페이지

| ID      | 기능          | 상세                                                |
| ------- | ------------- | --------------------------------------------------- |
| INF-060 | 프로필 아바타 | 이름 첫 글자 표시                                   |
| INF-061 | 기본 정보 탭  | 이름(한자/가나), 카테고리, LINE ID, 자기소개        |
| INF-062 | SNS 계정 탭   | Instagram, X, TikTok, YouTube (ID + 팔로워 수)      |
| INF-063 | 주소 탭       | 우편번호, 도도부현, 시구정촌, 건물                  |
| INF-064 | 전화번호 탭   | 전화번호                                            |
| INF-065 | 은행 정보 탭  | 은행명, 지점, 계좌유형(普通/当座), 계좌번호, 예금주 |
| INF-066 | 신청 내역 탭  | 캠페인별 신청 상태 (審査中/承認/非承認)             |
| INF-067 | 비밀번호 변경 | 현재 비밀번호 → 새 비밀번호 확인                   |

### 2.8 내비게이션

| ID      | 기능     | 상세                           |
| ------- | -------- | ------------------------------ |
| INF-070 | 바텀탭바 | 홈 / キャンペーン / マイページ |

---

## 3. 관리자 앱 (PC 전체폭)

### 3.1 대시보드

| ID      | 기능           | 상세                                               |
| ------- | -------------- | -------------------------------------------------- |
| ADM-001 | KPI 카드       | 총 캠페인 수, 인플루언서 수, 신청 수, 승인 수      |
| ADM-002 | 최근 신청      | 최근 8건 테이블 (인플루언서명, 캠페인, 날짜, 상태) |
| ADM-003 | 빠른 승인/거절 | 테이블 내 인라인 액션 버튼                         |

### 3.2 캠페인 관리

| ID      | 기능        | 상세                                                                                     |
| ------- | ----------- | ---------------------------------------------------------------------------------------- |
| ADM-010 | 캠페인 목록 | 유형별 필터 (전체/모니터/기프팅)                                                         |
| ADM-011 | 캠페인 생성 | 25+ 필드 입력 폼 (기본/가격/모집/소셜/컨텐츠/가이드라인/이미지)                          |
| ADM-012 | 캠페인 수정 | 모든 필드 + 이미지 관리                                                                  |
| ADM-013 | 캠페인 복제 | 기존 캠페인 전체 복사 (이미지 포함)                                                      |
| ADM-014 | 캠페인 삭제 | 캠페인명 입력 확인 모달 + 관련 신청 연쇄 삭제 (campaign_admin 이상만)                    |
| ADM-015 | 순서 변경   | 화살표 버튼으로 order_index 변경                                                         |
| ADM-016 | 상태 관리   | draft(準備) → scheduled(近日公開) → active(募集中) → paused(一時停止) → closed(마감) |
| ADM-017 | 상태 토글   | 상태 배지 클릭으로 순환 변경                                                             |

### 3.3 이미지 관리

| ID      | 기능                | 상세                                    |
| ------- | ------------------- | --------------------------------------- |
| ADM-020 | 드래그앤드롭 업로드 | HTML5 네이티브 드래그앤드롭             |
| ADM-021 | 이미지 크롭         | 크롭 모달 + 미리보기                    |
| ADM-022 | 이미지 미리보기     | 그리드 뷰, 메인 이미지 표시             |
| ADM-023 | 이미지 다운로드     | 개별 이미지 다운로드                    |
| ADM-024 | 이미지 삭제         | 개별 이미지 제거                        |
| ADM-025 | 스토리지            | Supabase Storage (campaign-images 버킷) |

### 3.4 신청 관리

| ID      | 기능            | 상세                                                  |
| ------- | --------------- | ----------------------------------------------------- |
| ADM-030 | 신청 목록       | 유형별 필터 (전체/모니터/기프팅), 캠페인별 카드 뷰    |
| ADM-031 | 캠페인별 신청자 | 총 신청/심사중/승인 수 표시, 상태 필터                |
| ADM-032 | 신청자 상세     | 이름, 이메일, Instagram ID, 팔로워, 신청 메시지, 날짜 |
| ADM-033 | 상태 변경       | pending → approved / rejected                        |
| ADM-034 | 대기 알림       | 사이드바 신청 관리에 pending 건수 배지 표시           |

### 3.5 인플루언서 관리

| ID      | 기능            | 상세                                                                      |
| ------- | --------------- | ------------------------------------------------------------------------- |
| ADM-040 | 인플루언서 목록 | 채널별 탭 (전체/Instagram/X/TikTok/YouTube), 채널별 등록자 수 표시        |
| ADM-041 | 전체 보기       | 모든 SNS 팔로워 + 합계, LINE, 배송지 등록여부, 계좌 등록여부 표시         |
| ADM-042 | 채널별 보기     | 해당 채널 ID + 팔로워 수, 팔로워순 정렬                                   |
| ADM-043 | 상세 페이지     | 기본정보, SNS(총 팔로워), 연락처, 배송지, 계좌, 신청이력 표시 (읽기 전용) |
| ADM-044 | 관리자 배지     | 관리자 계정 식별 표시                                                     |

### 3.6 관리자 계정 관리

| ID      | 기능        | 상세                                                   |
| ------- | ----------- | ------------------------------------------------------ |
| ADM-050 | 관리자 목록 | 이메일, 이름, 역할, 생성일 표시                        |
| ADM-051 | 관리자 추가 | 이메일, 비밀번호, 이름, 역할 입력 (super_admin만 가능) |
| ADM-052 | 관리자 수정 | 이름, 역할 변경                                        |
| ADM-053 | 관리자 삭제 | 확인 후 삭제 (auth.users 연쇄 삭제)                    |
| ADM-054 | 내 계정     | 이름 변경, 비밀번호 변경, 역할 확인 (읽기 전용)        |

---

## 4. 권한 체계

### 4.1 역할 정의

| 역할             | 설명              | 권한                               |
| ---------------- | ----------------- | ---------------------------------- |
| super_admin      | 최고 관리자       | 모든 기능 + 관리자 계정 CRUD       |
| campaign_admin   | 캠페인 관리자     | 캠페인/신청/인플루언서 관리        |
| campaign_manager | 캠페인 매니저     | 캠페인/신청 조회 및 제한적 관리    |
| influencer       | 인플루언서 (기본) | 캠페인 조회/신청, 본인 프로필 관리 |

### 4.2 RLS (Row Level Security) 정책

| 테이블                    | SELECT                     | INSERT                  | UPDATE              | DELETE        |
| ------------------------- | -------------------------- | ----------------------- | ------------------- | ------------- |
| campaigns                 | 공개 (전체)                | admin만                 | admin만             | admin만       |
| influencers               | admin: 전체 / 유저: 본인만 | 본인 or 인증 사용자     | admin or 본인       | admin만       |
| applications              | admin: 전체 / 유저: 본인만 | 인증 사용자 (본인)      | admin만             | admin만       |
| admins                    | admin만                    | super_admin or 최초 1명 | super_admin or 본인 | super_admin만 |
| storage (campaign-images) | 공개                       | admin만                 | admin만             | admin만       |

---

## 5. 데이터베이스 스키마

### 5.1 campaigns

| 컬럼          | 타입            | 설명                                        |
| ------------- | --------------- | ------------------------------------------- |
| id            | uuid (PK)       | 자동 생성                                   |
| title         | text (NOT NULL) | 캠페인명                                    |
| brand         | text            | 브랜드명                                    |
| product       | text            | 상품명                                      |
| product_url   | text            | 상품 페이지 URL                             |
| product_price | bigint          | 상품 가격 (엔)                              |
| type          | text            | 캠페인 등급 (nano/micro/macro)              |
| channel       | text            | 플랫폼 (instagram/x/tiktok/youtube/qoo10)   |
| category      | text            | 카테고리 (beauty/food/fashion/health/other) |
| recruit_type  | text            | 모집유형 (monitor/gifting)                  |
| content_types | text            | 콘텐츠 유형 (쉼표 구분)                     |
| emoji         | text            | 카테고리 이모지                             |
| reward        | bigint          | 보수 금액 (엔)                              |
| slots         | integer         | 모집 정원                                   |
| applied_count | integer         | 현재 신청 수                                |
| deadline      | date            | 신청 마감일                                 |
| post_deadline | date            | 게시 기한                                   |
| post_days     | integer         | 상품 수령 후 게시 기한 (일)                 |
| order_index   | integer         | 표시 순서                                   |
| image_url     | text            | 메인 이미지 URL                             |
| img1~img8     | text            | 추가 이미지 URL (최대 8장)                  |
| description   | text            | 캠페인 설명                                 |
| hashtags      | text            | 필수 해시태그 (쉼표 구분)                   |
| mentions      | text            | 필수 멘션 (쉼표 구분)                       |
| appeal        | text            | 브랜드 어필 포인트                          |
| guide         | text            | 촬영/게시 가이드라인                        |
| ng            | text            | NG 사항                                     |
| status        | text            | 상태 (draft/scheduled/active/paused/closed) |
| created_at    | timestamptz     | 생성일                                      |

### 5.2 influencers

| 컬럼                                                        | 타입            | 설명          |
| ----------------------------------------------------------- | --------------- | ------------- |
| id                                                          | uuid (PK)       | auth user ID  |
| email                                                       | text (NOT NULL) | 이메일        |
| name                                                        | text            | 표시명        |
| name_kanji                                                  | text            | 한자 이름     |
| name_kana                                                   | text            | 가나 이름     |
| ig / ig_followers                                           | text / integer  | Instagram     |
| x / x_followers                                             | text / integer  | X (Twitter)   |
| tiktok / tiktok_followers                                   | text / integer  | TikTok        |
| youtube / youtube_followers                                 | text / integer  | YouTube       |
| followers                                                   | integer         | 총 팔로워 수  |
| line_id                                                     | text            | LINE ID       |
| category                                                    | text            | 활동 카테고리 |
| bio                                                         | text            | 자기소개      |
| zip, prefecture, city, building, address                    | text            | 주소          |
| phone                                                       | text            | 전화번호      |
| bank_name, bank_branch, bank_type, bank_number, bank_holder | text            | 은행 정보     |
| created_at                                                  | timestamptz     | 가입일        |

### 5.3 applications

| 컬럼            | 타입        | 설명                             |
| --------------- | ----------- | -------------------------------- |
| id              | uuid (PK)   | 자동 생성                        |
| user_id         | uuid (FK)   | influencers.id 참조              |
| user_email      | text        | 신청자 이메일                    |
| user_name       | text        | 신청자 이름                      |
| user_ig / ig_id | text        | Instagram ID                     |
| user_followers  | integer     | 신청 시점 팔로워 수              |
| campaign_id     | uuid (FK)   | campaigns.id 참조                |
| message         | text        | 신청 메시지                      |
| address         | text        | 배송 주소                        |
| status          | text        | 상태 (pending/approved/rejected) |
| created_at      | timestamptz | 신청일                           |

### 5.4 admins

| 컬럼       | 타입          | 설명                                               |
| ---------- | ------------- | -------------------------------------------------- |
| id         | uuid (PK)     | 자동 생성                                          |
| auth_id    | uuid (FK)     | auth.users.id (CASCADE)                            |
| email      | text (UNIQUE) | 이메일                                             |
| name       | text          | 이름                                               |
| role       | text          | 역할 (super_admin/campaign_admin/campaign_manager) |
| created_at | timestamptz   | 생성일                                             |

---

## 6. DB 함수 및 트리거

| 함수명                 | 용도                                       |
| ---------------------- | ------------------------------------------ |
| is_admin()             | 현재 사용자의 관리자 여부 확인             |
| is_super_admin()       | super_admin 여부 확인                      |
| handle_new_user()      | 회원가입 시 influencers 자동 생성 (트리거) |
| create_admin()         | 새 관리자 계정 생성 (super_admin 전용)     |
| reset_admin_password() | 관리자 비밀번호 리셋 (super_admin 전용)    |

---

## 7. 화면 구성

```
인플루언서 앱 (모바일 480px)
├── 홈 (캠페인 목록)
│   ├── 채널 필터 탭
│   ├── 모집유형 필터
│   └── 캠페인 카드 그리드
├── 캠페인 상세
│   ├── 이미지 캐러셀
│   ├── 상품/모집 정보
│   ├── 참가 방법 (3 STEP)
│   ├── 가이드라인/NG/주의사항
│   ├── LINE + Instagram CTA
│   ├── 필수정보 체크 오버레이
│   └── 신청 모달
├── 마이페이지
│   ├── 프로필 편집 (기본/SNS/주소/전화/은행/신청내역)
│   └── 비밀번호 변경
├── 로그인
└── 회원가입 (1단계: 이름+이메일+비밀번호)

관리자 앱 (PC 전체폭)
├── 대시보드 (KPI + 최근 신청)
├── キャンペーン管理 (캠페인 관리)
│   ├── 목록/필터
│   ├── 생성/수정 폼
│   └── 이미지 관리
├── 応募管理 (신청 관리)
│   ├── 캠페인별 신청 목록
│   └── 승인/거절 처리
├── インフルエンサー管理 (인플루언서 관리)
│   ├── 목록/필터
│   └── 상세 모달
├── 管理者設定 (관리자 설정)
│   ├── 관리자 목록/CRUD
│   └── 내 계정
└── ← 戻る (뒤로가기)
```

---

## 8. 모바일 레이아웃 정책

| 항목 | 규칙 |
|------|------|
| 앱 쉘 고정 | `#appShell`은 `position:fixed; top:0; bottom:0`으로 뷰포트에 고정 |
| body 스크롤 차단 | `html, body`에 `height:100%; overflow:hidden` |
| 콘텐츠 스크롤 | `.page.active` 내부에서만 스크롤 (`flex:1; overflow-y:auto`) |
| GNB/탭바 고정 | `flex-shrink:0`으로 상단/하단 고정, 페이지가 나머지 공간 차지 |
| 키보드 대응 | `visualViewport` API로 앱 쉘 높이 실시간 조절 |
| input 확대 방지 | `font-size:16px` 이상 필수 + `maximum-scale=1.0` |
| 높이 단위 | `100vh`/`100dvh` 대신 `position:fixed + top:0/bottom:0` 사용 |
| URL 해시 | 캠페인 상세는 `#detail-{id}` 형식으로 새로고침 시 복원 가능 |
| 페이지 초기화 | HTML에 기본 active 클래스 없음 → DOMContentLoaded에서 해시 기반 활성화 |

---

## 9. 시드 데이터

### 9.1 캠페인 (6건)

| 브랜드    | 상품               | 카테고리 | 채널             | 유형    | 가격    | 보수    | 정원 |
| --------- | ------------------ | -------- | ---------------- | ------- | ------- | ------- | ---- |
| INNISFREE | Green Tea Serum    | Beauty   | Instagram        | Monitor | ¥3,200 | -       | 25   |
| Round Lab | Birch Toner        | Beauty   | Instagram        | Monitor | ¥4,500 | -       | 20   |
| DR.G      | Cushion Foundation | Beauty   | Instagram        | Monitor | ¥3,800 | ¥1,000 | 15   |
| MEDIHEAL  | Mask Pack          | Beauty   | Instagram/TikTok | Gifting | ¥2,000 | -       | 30   |
| PERIPERA  | Lip Tint           | Beauty   | Instagram/TikTok | Gifting | ¥1,500 | ¥500   | 20   |
| BIBIGO    | Dumplings          | Food     | Qoo10            | Gifting | ¥1,200 | ¥2,000 | 10   |

### 9.2 테스트 인플루언서 (3명)

| 이메일                | 이름       | 카테고리 | 주력 채널   | 팔로워 | 비밀번호 |
| --------------------- | ---------- | -------- | ----------- | ------ | -------- |
| sakura.test@reverb.jp | 佐藤さくら | Beauty   | Instagram   | 12,500 | test1234 |
| yui.test@reverb.jp    | 田中ゆい   | Food     | TikTok      | 45,000 | test1234 |
| haruka.test@reverb.jp | 鈴木はるか | Fashion  | Instagram+X | 22,000 | test1234 |
