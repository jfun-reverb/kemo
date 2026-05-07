# REVERB JP — 기능정의서

> 일본 시장 대상 인플루언서 체험단(리뷰어/기프팅/방문형) 모집 플랫폼 + 광고주 신청 인테이크
> 최종 업데이트: 2026-05-07 (v10)
>
> **v10 개정 (2026-04-25~30 운영 배포분, ~migration 076)**
> - §5.5 `brand_applications.status` 10단계 확장 (`kakao_room_created` 추가, migration 076)
> - §22.6 — 브랜드 서베이 상태 전이 9 → 10단계 (`kakao_room_created` 입금 ↔ 단톡방 개설 가시화)
> - §31 신규 — 캠페인 상태 도움말 모달 (관리 표 헤더 ⓘ)
> - §32 신규 — 캠페인·신청·결과물 표 brand_ko / product_ko 컬럼 분리 + 검색 매칭 (migration 074)
> - §33 — 민감 항목 변경 잠금(migration 075) + 경고 모달 (`#sensitiveChangeModal`, d79ad39)
> - §34 신규 — 참여방법/주의사항 편집 모달 분리 + bundle summary 한·일 양언어 + 미리보기 다국어
> - §35 신규 — 결과물 영수증 구매정보 관리자 화면 마스킹 (`purchase_date`/`purchase_amount`)
> - §36 신규 — 결정 이벤트 트리거 `draft↔pending` 양방향 허용 (migration 073)
> - §37 신규 — 사이드바 결과물 관리 메뉴 pending 배지
>
> **[dev 검증 중] (운영 미배포 — 077~097)**
> - §5.5 신청번호 포맷 v2 (`JFUN-{R|S}-YYMMDD-NNN`, migration 078, 2026-05-04) — 운영은 v1 `JFUN-{Q|N}-YYYYMMDD-NNN` 유지
> - §5.11 신규 — `campaign_caution_history` audit 테이블 (migration 077, 2026-04-30)
> - §33 — audit 테이블·변경 이력 메뉴 부분 (migration 077). 모달 markup·잠금(migration 075)은 운영 OK
> - 캠페인 상태 재설계 — `paused` 제거 + `expired`(노출마감) 신규 (migration 097, 2026-05-07)
> - 계층 채번 시스템 — `B{}-A{}-C{}` (migration 088~090, 2026-05-04)
>
> **v9 개정 (2026-04-22 배포분)**
> - §5 DB 스키마 — `admin_notices`/`admin_notice_reads`/`influencer_flags` 3개 테이블 추가, `brand_applications.status` 9단계 확장
> - §27 신규 — 관리자 공지사항 시스템 (migration 063, 사이드바 최상단 메뉴 + 미읽음 배지 + 로그인 팝업)
> - §28 신규 — 인플루언서 verify/violation/블랙리스트 관리 (migration 059~062, 증빙 파일 업로드)
> - §22.6 — 브랜드 서베이 상태 전이 9단계 파이프라인 (migration 064/065)
> - ADM-063~069 신규 — 엑셀 3종·필터 multi-select/cascade·SNS 전체 표시·전화번호 정규화
> - §29 신규 — Vercel Pro 업그레이드 (Hobby→Pro Team, 6000/day, 동시 빌드 복수)
>
> **v8 개정 (2026-04-21 오후 배포분)**
> - §22 migration 057 — 사업자등록증 수집·Storage 버킷·`business_license_path` 컬럼 완전 제거
> - §22.5b 브랜드 서베이 "현황 대시보드" 페인 신규 (사이드바 그룹화)
> - §22.8 Vercel Web Analytics (sales 3개 페이지, 쿠키 미사용)
> - §25.6 관리자 리스트 IntersectionObserver lazy-load 전면 확장
> - §25.7 PostgREST 1000-row cap 우회 pagination
> - INF-021 캠페인 카드 배지 재배치 (募集中 top-left, NEW top-right)

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
| INF-020 | 캠페인 그리드       | active + scheduled + closed(게시기한 남은 경우) 캠페인 카드 목록 |
| INF-021 | 상태 배지           | NEW, 募集中(모집중), 近日公開(예정), 募集締切(모집마감/게시기한 남음), 募集終了(정원 초과). **2026-04-21 배치 재조정** (9364b07/82b377b/32bc19d): 이미지 **좌상단에 `募集中`** (solid 배경, 단일 flex row로 이미지 대비 보장), **우상단에 `NEW`**, 콘텐츠 종류 아래에 `{applied}/{slots}名` 슬롯 카운트 |
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
| INF-048 | 외부 링크     | 상품 페이지, LINE(@reverb.jp), Instagram(@reverb_jp) CTA 카드 |

### 2.6 캠페인 신청

| ID      | 기능              | 상세                                                       |
| ------- | ----------------- | ---------------------------------------------------------- |
| INF-050 | 비로그인 안내     | 미로그인 시 로그인 프롬프트 오버레이 표시                  |
| INF-051 | 필수정보 사전체크 | 캠페인 채널에 맞는 SNS ID, 배송지(zip+prefecture+city), 전화번호, PayPal 이메일 확인 |
| INF-052 | 미비정보 안내     | 부족한 정보 목록을 경고 오버레이로 표시, 마이페이지로 유도 |
| INF-053 | 신청 모달         | 동기 메시지 입력                                           |
| INF-054 | 배송지 입력       | 프로필에서 자동 입력, 수정 가능                            |
| INF-055 | PR 태그 동의      | #PR 태그 사용 동의 체크박스                                |
| INF-056 | 중복 신청 방지    | 동일 캠페인 재신청 차단 (DB 조회)                          |
| INF-056a| 모집마감 신청 차단 | closed 상태 캠페인은 신청 버튼 「募集締切」+ 비활성화      |
| INF-057 | 신청 카운트       | campaigns.applied_count 자동 증가                          |
| INF-058 | 신청 완료 후      | 상세 페이지 새로고침, 버튼 "응募済み"로 변경               |

### 2.7 마이페이지 (리스트 → 상세 네비게이션)

| ID      | 기능            | 상세                                                |
| ------- | --------------- | --------------------------------------------------- |
| INF-060 | 프로필 헤더     | 아바타(이름 첫 글자) + 이름 + SNS핸들               |
| INF-061 | 메뉴 리스트     | 応募履歴, 基本情報, SNSアカウント, 配送先, PayPal, パスワード変更, ログアウト |
| INF-062 | 상세 서브페이지 | 각 메뉴 클릭 시 ← 뒤로가기 + 타이틀 헤더의 상세 페이지로 전환 |
| INF-063 | 기본 정보       | 이름(한자/가나), 카테고리(일본어), LINE ID, 자기소개 |
| INF-064 | SNS 계정        | Instagram, X, TikTok, YouTube (ID + 팔로워 수)      |
| INF-065 | 배송지          | 우편번호, 도도부현, 시구정촌, 건물, 전화번호        |
| INF-066 | PayPal          | PayPal 수취용 이메일 주소 (정산 송금 용도) |
| INF-067 | 신청 내역       | 캠페인별 신청 상태 (審査中/承認/非承認)             |
| INF-068 | 비밀번호 변경   | 현재 비밀번호 → 새 비밀번호 확인                   |
| INF-069 | 退会            | 리스트 하단 좌측 작은 텍스트, 확인 후 안내          |

### 2.8 GNB (상단 네비게이션)

| ID      | 기능            | 상세                                                                 |
| ------- | --------------- | -------------------------------------------------------------------- |
| INF-070 | 비로그인 상태   | Log In / Sign Up 버튼 표시                                           |
| INF-071 | 로그인 상태     | Log In/Sign Up 버튼 없음. 홈/캠페인/마이페이지/알림/로그아웃은 우측 햄버거 ☰ 메뉴로 |
| INF-072 | 관리자 로그인   | Admin 버튼만 표시 (관리자 페이지 같은 탭에서 전환)                   |

### 2.9 내비게이션

| ID      | 기능           | 상세                                                                        |
| ------- | -------------- | --------------------------------------------------------------------------- |
| INF-080 | 햄버거 메뉴    | 홈 / キャンペーン / マイページ / 通知(미읽음 배지 9+) / ログアウト (우측 슬라이드 패널, 인증 페이지에선 숨김) |
| INF-081 | 바텀탭 (deprecated) | 2026-04 햄버거 메뉴로 대체. 키보드 간섭 제거 목적                          |

---

## 3. 관리자 앱 (PC 전체폭)

### 3.0 사이드바 네비게이션

| ID      | 기능            | 상세                                                       |
| ------- | --------------- | ---------------------------------------------------------- |
| ADM-000 | 사이드바        | Material Icons Round 아이콘 + 텍스트 메뉴. **2단 고정 레이아웃**(사이드바+메인 독립 스크롤, 상단 GNB 없음) |
| ADM-001 | 접기/펼치기     | 햄버거 버튼(menu/menu_open)으로 토글, 접힌 상태에서 아이콘만 표시 (56px) |
| ADM-002 | 새로고침 안정화 | visibility:hidden cloak 기법으로 깜빡임 완전 방지, 서브패널 새로고침 시 부모 패널로 리다이렉트 |
| ADM-003 | data-pane 라우팅 | 사이드바 메뉴에 data-pane 속성으로 안정적 패널 전환           |
| ADM-004 | 신규등록 제거   | 사이드바에서 신규등록 메뉴 제거 (캠페인 관리 내 버튼으로 통합) |
| ADM-005 | pending 배지    | 신청 관리/광고주 신청/결과물 관리 메뉴에 pending 건수 배지 상시 표시 |
| ADM-006 | 브랜드 서베이 메뉴 그룹 | **상위 그룹 "브랜드 서베이"** 아래 2개 서브메뉴 (2026-04-21 분리): ① `insights` 아이콘 + **현황 대시보드** (`#brand-dashboard`, 신규) / ② `storefront` 아이콘 + **신청 목록** (`#brand-applications`, 기존). 내부 용어·DB·라우트·함수명은 `광고주 신청`/`brand_applications` 그대로 유지. 모든 관리자 접근 가능. §22 참조 |
| ADM-007 | 프로필 엔트리 위치 | 사이드바 하단에 접속자 프로필(`#sidebarAdminProfile` → `my-account`), 그 아래 footer(인플루언서 화면/로그아웃). 중복 "내 계정" 메뉴 제거 |
| ADM-008 | 목록 페인 통일   | campaigns/applications/deliverables/camp-applicants/influencers/lookups/admin-accounts/brand-applications 8개 페인이 `admin-pane-list` 클래스 공유. sticky thead + tbody만 스크롤. §25 참조 |

### 3.1 대시보드

| ID      | 기능              | 상세                                                          |
| ------- | ----------------- | ------------------------------------------------------------- |
| ADM-010 | KPI 카드          | 총 캠페인 수, 인플루언서 수, 신청 수, 승인 수                 |
| ADM-011 | 회원가입 추이     | Chart.js 막대 차트, 7일/30일/전체 기간 필터 전환 (기본 30일)  |
| ADM-012 | 신규 가입 KPI     | 오늘 가입 수, 이번주 가입 수 (기간 표시)                      |
| ADM-013 | 프로필 완성률     | SNS(Instagram/X/TikTok/YouTube 개별), 배송지, PayPal 등록률 바 |
| ADM-014 | 최근 신청         | 최근 8건 테이블 (인플루언서명, 캠페인, 날짜, 상태)            |
| ADM-015 | 빠른 승인/거절    | 테이블 내 인라인 액션 버튼                                    |
| ADM-016 | 배송지 도도부현 분포 | `회원가입 현황`과 `최근 신청` 사이 신규 카드. 대시보드가 이미 `fetchInfluencers()`로 로드한 users 배열을 재사용해 `computePrefectureStats(users)`로 클라이언트 집계(중복 쿼리 없음) → Top N(`TOP_PREFECTURE_LIMIT=10`) + 未登録 + 海外. Chart.js 도넛(높이 260px, `_addressDistChart` destroy→재생성으로 메모리 릭 방지), 47개 도도부현 한국어 라벨 매핑(東京都→도쿄도 등), 범례 `라벨 N명 (N.N%)`. 옵션 객체는 `buildAddressChartOptions(stats)`로 분리, catch 시 `console.error`로 집계 오류 노출 |

### 3.2 캠페인 관리

| ID      | 기능            | 상세                                                                       |
| ------- | --------------- | -------------------------------------------------------------------------- |
| ADM-020 | 캠페인 목록     | 썸네일(+이미지수) + 캠페인명/브랜드 + 게시마감 D-day                       |
| ADM-021 | 상태/타입 필터  | 드롭다운 (전체 상태/준비/모집예정/모집중/일시정지/종료, 전체 타입/리뷰어/기프팅) |
| ADM-022 | 검색            | 캠페인명 + 브랜드명 실시간 검색                                            |
| ADM-023 | 헤더 정렬       | 조회/신청/등록일/수정일 ▲▼ 토글 (클릭 시 asc↔desc)                        |
| ADM-024 | 순서 변경 모드  | "순서 변경" 버튼 → 필터/정렬 초기화, ↑↓ 활성화, "순서 변경 완료"로 전환   |
| ADM-025 | 조회수 표시     | campaigns.view_count, 캠페인 상세 열 때 +1 자동 증가                       |
| ADM-026 | D-day 라벨      | 모집마감/게시마감 날짜 옆에 D-day 색상 표시 (빨강/노랑/회색)               |
| ADM-027 | 상태 드롭다운   | 상태 배지 클릭 시 5개 상태 선택 드롭다운 (한글 + ▾ 화살표)                 |
| ADM-028 | 캠페인 생성     | 25+ 필드 입력 폼 (기본/가격/모집/소셜/콘텐츠/가이드라인/이미지)            |
| ADM-029 | 마감일 검증     | post_deadline >= deadline 필수, 인라인 경고 + 저장 차단                    |
| ADM-030 | 캠페인 수정     | 모든 필드 + 이미지 관리 + 마감일 검증                                      |
| ADM-031 | 캠페인 복제     | 기존 캠페인 전체 복사 (이미지 포함)                                        |
| ADM-032 | 캠페인 삭제     | 캠페인명 입력 확인 모달 + 관련 신청 연쇄 삭제                              |
| ADM-033 | 자동 상태 종료  | deadline 경과 시 active → closed 자동 변경 (캠페인 로드 시 클라이언트 체크) |
| ADM-034 | 마감일 경과 active 차단 | deadline 지난 캠페인은 모집중으로 저장/변경 불가 (편집폼, 상태 드롭다운 모두) |
| ADM-035 | 버튼 피드백     | hover: 색상/쉐도우 변경, active: scale 눌림 효과                           |
| ADM-036 | 순서변경 피드백 | 이동된 행 핑크색 하이라이트 0.6초 애니메이션                               |
| ADM-037 | 캠페인 미리보기 | 캠페인 제목 클릭 시 모바일 크기(480px) 프리뷰 모달 표시, 편집 버튼 포함 (목록/신청관리/대시보드에서 사용) |
| ADM-037a | 폼 실시간 미리보기 | 등록/편집 폼 우측에 **인라인 카드**(iframe 아님) 미리보기 사이드바. 모든 폼 signal(제목/채널/이미지/reward_note/Quill 리치 에디터/참여단계 DOM 재구성) 반영. Quill lazy init 훅 + 이미지 업로드 상태/에러 표면화. §24 참조 |
| ADM-038 | 타입 라벨 통일  | 캠페인 목록에서 [리뷰어]/[기프팅] 타입 라벨 + 제목 형식으로 통일            |
| ADM-039 | 인라인 스피너   | 테이블, 대시보드 KPI, 차트 영역에 인라인 스피너 로딩 (전체화면 오버레이 제거) |
| ADM-060 | 캠페인 번호     | `CAMP-YYYY-NNNN` 형식(JST 연도별 4자리 순차, 연도 바뀌면 0001 리셋). 신규 INSERT 시 BEFORE INSERT 트리거 `generate_campaign_no()` 자동 채번(SECURITY DEFINER + search_path ''). 캠페인 목록 브랜드 라인 뒤에 monospace 표기(` · CAMP-2026-0001`), 편집 페인 헤더에 **클릭 시 클립보드 복사** 핑크 배지. 기존 레코드는 `created_at` 순으로 backfill 완료(dev 5건/prod 51건, 2026-04-20). 컬럼: `campaigns.campaign_no` UNIQUE NOT NULL. (ID 040~049는 §3.5 인플루언서 관리에서 사용 중이라 060대 부여) |
| ADM-061 | 결과물 엑셀 내보내기 | 캠페인 더보기 메뉴(목록 행) → `결과물 엑셀` 항목. ExcelJS CDN lazy-load → 해당 캠페인 결과물 전체 → xlsx 다운로드. 영수증(`kind='receipt'`) 이미지는 `Image→Canvas→JPEG`(CORS 안전) 셀 임베드, 게시물(`kind='post'`)은 URL 하이퍼링크. 컬럼 순서: 인플루언서/채널/제출일/영수증 이미지/URL/상태/반려사유 등 |
| ADM-062 | campaign_no 검색 | 캠페인/신청/결과물 3개 페인 검색창 확장 — 제목·브랜드 외에 `campaign_no`도 매칭. 결과물 검색은 캠페인 타이틀/브랜드/`campaign_no`까지 포괄 |
| ADM-063 | 신청자 엑셀 내보내기 (2026-04-22) | 캠페인 더보기 메뉴 `신청자 엑셀` — `exportCampaignApplicationsExcel(campId)`. 전 상태(pending/approved/rejected) 17컬럼(신청일·상태·이름·이메일·연락처·IG/TT/X/YT 계정+팔로워·배송지·메시지·심사일·리뷰어). `formatPhoneDisplay` + 한국어 상태 라벨. 파일명 `applicants-{campaign_no|title}-YYYYMMDD.xlsx` |
| ADM-064 | 브랜드 서베이 엑셀 내보내기 (2026-04-22) | 브랜드 서베이 페인 헤더 다운로드 버튼 — 신청일·신청번호·폼타입·업체/브랜드명·담당자·이메일·연락처·세금계산서 주소·예상견적·상태. `getFilteredBrandApps` 헬퍼로 리스트·엑셀 데이터 소스 공유 |
| ADM-065 | 전화번호 표시 포맷 (2026-04-22) | `formatPhoneDisplay` in `ui.js` — KR/JP 번호 정규화(11자리 3-4-4, 10자리 02/03/06 → 2-4-4 else 3-3-4, `+81`/`+82` 지원). 인플루언서 상세 모달·브랜드 앱 리스트·상세에 적용. 매칭 실패 시 원문 폴백 |
| ADM-066 | 캠페인 multi-select + cascade 필터 (2026-04-22) | 신청 관리·결과물 관리·캠페인별 신청자 페인에 캠페인 다중 선택 드롭다운. 캠페인 선택 시 타입/kind 옵션 자동 cascade로 좁혀짐. `[CAMP-YYYY-NNNN] 제목` 라벨. 신청 관리에선 맨 왼쪽 위치 |
| ADM-067 | 캠페인 신청자 SNS 전체 표시 (2026-04-22) | `renderAppCampList` 행에 IG/TT/X/YT 4개 채널 핸들+팔로워 모두 표시(이전: primary_channel 단일). 멀티채널 캠페인에서 심사 판단 용이 |
| ADM-068 | 캠페인 행 브랜드 라인 중복 제거 (2026-04-22) | 캠페인 목록 행의 브랜드 라인에서 `CAMP-XXXX` 중복 표시 제거(편집 페인 헤더 핑크 배지에만 표시) |
| ADM-069 | 관리자 공지사항 (2026-04-22, §27) | 사이드바 최상단 "공지사항" 메뉴 + 미읽음 배지. §27 참조 |
| ADM-070 | 캠페인 폼 날짜 입력 개편 (2026-04-27, §30) | flatpickr range picker 3개 통합 + `recruit_start` 신규 + 자동 시작/종료 + monitor 콘텐츠 필터 + 기본 정보 섹션 재배치. §30 참조 |
| ADM-071 | 캠페인 자동 시작 (2026-04-27) | scheduled 상태 캠페인의 `recruit_start` 가 도래하면 active로 자동 전환. `fetchCampaigns` 호출 시 `autoOpenCampaigns()` → `autoCloseCampaigns()` 순차 실행으로 시작·종료 동시 처리 |

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

| ID      | 기능                | 상세                                                              |
| ------- | ------------------- | ----------------------------------------------------------------- |
| ADM-030 | 신청 테이블         | 캠페인 썸네일 + 캠페인명, 타입/상태/검색 필터, 상태별 정렬        |
| ADM-031 | 캠페인별 신청자     | 총 신청/심사중/승인 수 표시, 상태 필터                            |
| ADM-032 | 인플루언서 상세 모달 | 신청 관리에서 이름 클릭 시 프로필 상세 모달 표시                  |
| ADM-033 | 상태 변경           | pending → approved / rejected, reviewed_by + reviewed_at 자동 기록 |
| ADM-034 | 되돌리기            | approved/rejected → pending 복귀, reviewed_by/reviewed_at 초기화  |
| ADM-035 | 대기 알림           | 사이드바 신청 관리에 pending 건수 배지 항상 표시 (ADM-005 참조)   |
| ADM-036 | 에러 처리           | friendlyError() 한국어 에러 메시지 변환 + 에러 코드 표시          |

### 3.5 인플루언서 관리

| ID      | 기능            | 상세                                                                      |
| ------- | --------------- | ------------------------------------------------------------------------- |
| ADM-040 | 인플루언서 목록 | 채널별 탭 (전체/Instagram/X/TikTok/YouTube), 채널별 등록자 수 표시        |
| ADM-041 | 전체 보기       | 모든 SNS 팔로워 + 합계, LINE, 배송지 등록여부, PayPal 등록여부 표시       |
| ADM-042 | 채널별 보기     | 해당 채널 ID + 팔로워 수, 팔로워순 정렬                                   |
| ADM-043 | 상세 페이지     | 기본정보, SNS(총 팔로워), 연락처, 배송지, PayPal, 신청이력 표시 (읽기 전용) |
| ADM-044 | 관리자 배지     | 관리자 계정 식별 표시                                                     |
| ADM-045 | 인증·위반·블랙 배지 + 관리 (2026-04-22, §28) | 이름 옆 배지(블랙 단독 OR 인증+위반N), 상세 모달 내 상태 관리 카드 + 관리자 이력 타임라인 + 증빙 파일. 목록 헤더에 채널·인증·위반 드롭다운 3종 + 통합 검색 |

### 3.6 관리자 계정 관리

| ID      | 기능        | 상세                                                   |
| ------- | ----------- | ------------------------------------------------------ |
| ADM-050 | 관리자 목록 | 이메일, 이름, 역할, 생성일 표시                        |
| ADM-051 | 관리자 초대 | **초대 방식**: 이메일+이름+역할 입력 → `invite_admin` RPC로 auth.users + identities 생성 → 클라이언트가 `resetPasswordForEmail()` 호출 → 받은 사람이 메일 링크로 비밀번호 설정 (super_admin만 가능). 기존 인플루언서 이메일이면 자동으로 관리자 권한 승격 (프로필 유지). `create_admin()`은 deprecated |
| ADM-052 | 관리자 수정 | 이름, 역할 변경                                        |
| ADM-053 | 관리자 삭제 (2택) | **권한만 해제**(`remove_admin_role`): admins 행만 제거, 인플루언서 계정·데이터 유지 / **완전 삭제**(`delete_admin_completely`): applications, receipts(Stage 7→deliverables), admins, influencers, identities, auth.users cascade. 자기 자신 삭제 차단 |
| ADM-054 | 내 계정     | 이름 변경, 비밀번호 변경, 역할 확인 (읽기 전용)        |
| ADM-055 | 설문 메일받기 토글 | `admins.receive_brand_notify` — 광고주 신청 접수 시 `notify-brand-application` Edge Function이 참조해 알림 메일 수신 대상을 결정. 관리자 계정 리스트에서 행별 토글로 on/off. 기본 false. env `NOTIFY_ADMIN_EMAILS` 외부 이메일과 합산(중복 제거). DB 조회 실패 시 env만 폴백 |

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
| brand_applications        | admin만                    | **anon·authenticated은 `submit_brand_application()` RPC 경유 필수** (직접 INSERT는 42501) | admin만 | admin만 |
| brand_app_daily_counter   | admin만 (SECURITY DEFINER) | SECURITY DEFINER 트리거 전용 | — | — |
| campaigns_yearly_counter  | admin만                    | SECURITY DEFINER 트리거 전용 (`generate_campaign_no()`) | — | — |
| storage (campaign-images) | 공개                       | admin만                 | admin만             | admin만       |

---

## 5. 데이터베이스 스키마

### 5.1 campaigns

| 컬럼          | 타입            | 설명                                        |
| ------------- | --------------- | ------------------------------------------- |
| id            | uuid (PK)       | 자동 생성                                   |
| campaign_no   | text UNIQUE NOT NULL | `CAMP-YYYY-NNNN`(JST 연도별 4자리, BEFORE INSERT 트리거 자동 채번, ADM-060 참조) |
| title         | text (NOT NULL) | 캠페인명                                    |
| brand         | text            | 브랜드명 (일본어 표기)                      |
| brand_ko      | text            | 브랜드 한국어명 (migration 074, 2026-04-30 — 관리자 표 한국어 컬럼 분리·검색 매칭) |
| product       | text            | 상품명 (일본어 표기)                        |
| product_ko    | text            | 상품 한국어명 (migration 074, 2026-04-30)   |
| product_url   | text            | 상품 페이지 URL                             |
| product_price | bigint          | 상품 가격 (엔)                              |
| type          | text            | 캠페인 등급 (nano/micro/macro)              |
| channel       | text            | 플랫폼 (instagram/x/tiktok/youtube/qoo10, 콤마 구분 멀티) |
| channel_match | text            | `'or'`/`'and'` (채널 2개 이상일 때 상세 pill 구분자, 기본 `'or'`. 자격 검증엔 영향 없음) |
| primary_channel | text          | 팔로워 검증 기준 채널 코드 (NULL=첫 번째 채널로 폴백). §10 참조 |
| category      | text            | 카테고리 (beauty/food/fashion/health/other) |
| recruit_type  | text            | 모집유형 (monitor/gifting/visit)            |
| content_types | text            | 콘텐츠 유형 (쉼표 구분)                     |
| emoji         | text            | 카테고리 이모지                             |
| reward        | bigint          | 보수 금액 (엔)                              |
| reward_note   | text            | 리워드 금액 외 추가 안내(지급 조건·정산 시점·수수료). NULL 허용, 인플루언서 상세 리워드 row에 노출. §23 참조 |
| slots         | integer         | 모집 정원                                   |
| min_followers | integer         | 최소 팔로워수 (primary_channel 기준)        |
| applied_count | integer         | 현재 신청 수                                |
| recruit_start | date NULL       | 모집 시작일 (2026-04-27, migration 072). NULL 허용 — 인플루언서 화면에서 NULL이면 "오늘 ~ deadline"으로 폴백. scheduled 상태 캠페인의 `recruit_start` 도래 시 `autoOpenCampaigns`가 active로 자동 전환 |
| deadline      | date            | 신청 마감일                                 |
| post_deadline | date            | 게시 기한                                   |
| post_days     | integer         | 상품 수령 후 게시 기한 (일)                 |
| submission_end | date           | 결과물 제출 마감 (없으면 post_deadline 폴백) |
| purchase_start/end | date        | monitor 전용 구매 기간                      |
| visit_start/end | date          | visit 전용 방문 기간                        |
| winner_announce_at | timestamptz | 당첨자 발표 예정일                          |
| order_index   | integer         | 표시 순서                                   |
| image_url     | text            | 메인 이미지 URL                             |
| img1~img8     | text            | 추가 이미지 URL (최대 8장)                  |
| description   | text            | 캠페인 설명 (리치 HTML)                     |
| hashtags      | text            | 필수 해시태그 (쉼표 구분)                   |
| mentions      | text            | 필수 멘션 (쉼표 구분)                       |
| appeal        | text            | 브랜드 어필 포인트 (리치 HTML)              |
| guide         | text            | 촬영/게시 가이드라인 (리치 HTML)            |
| ng            | text            | NG 사항 (리치 HTML)                         |
| participation_set_id | uuid FK  | `participation_sets.id` ON DELETE SET NULL (§18) |
| participation_steps | jsonb     | 참여방법 스냅샷 (§18)                       |
| caution_set_id | uuid FK        | `caution_sets.id` ON DELETE SET NULL (migration 069, 주의사항 번들 원본 참조 — §38) |
| caution_items | jsonb NOT NULL DEFAULT '[]' | 주의사항 항목 스냅샷 (migration 069 — 캠페인 저장 시 번들에서 복사, 번들 수정해도 기존 캠페인 영향 없음) |
| view_count    | integer         | 조회수 (상세 페이지 열 때 +1)               |
| status        | text            | 상태 (draft/scheduled/active/paused/closed) |
| created_at    | timestamptz     | 생성일                                      |
| updated_at    | timestamptz     | 수정일                                      |

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
| paypal_email                                                | text            | PayPal 수취 이메일 (정산용). bank_* 컬럼은 deprecated(유지, 미사용) |
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
| reviewed_by     | text        | 처리한 관리자 이름               |
| reviewed_at     | timestamptz | 처리 일시                        |
| reviewed_version | integer    | 낙관적 락(동시 처리 충돌 차단)   |
| oriented_at     | timestamptz | OT(오리엔테이션) 발송 체크 시각 (gifting/visit 승인 건에 한함) |
| caution_agreed_at | timestamptz NULL | 주의사항 동의 시각 (migration 067·069, 신청 시점) |
| caution_snapshot | jsonb NULL | 주의사항 동의 시점 items 통째 보존 (v2: `{version, campaign_id, set_id, items, agreed_lang, snapshot_at}`. v1 lookup_codes/labels 스냅샷도 관리자 뷰어에서 하위호환) |
| created_at      | timestamptz | 신청일                           |

### 5.4 admins

| 컬럼       | 타입          | 설명                                               |
| ---------- | ------------- | -------------------------------------------------- |
| id         | uuid (PK)     | 자동 생성                                          |
| auth_id    | uuid (FK)     | auth.users.id (CASCADE)                            |
| email      | text (UNIQUE) | 이메일                                             |
| name       | text          | 이름                                               |
| role       | text          | 역할 (super_admin/campaign_admin/campaign_manager) |
| receive_brand_notify | boolean | 광고주 신청 접수 알림 메일 수신 여부 (기본 false, §22 참조) |
| created_at | timestamptz   | 생성일                                             |

### 5.5 brand_applications (광고주 신청 폼 — §22)

| 컬럼                  | 타입        | 설명 |
|-----------------------|-------------|------|
| id                    | uuid (PK)   | 자동 생성 |
| application_no        | text UNIQUE | **운영 (~migration 076)**: v1 `JFUN-Q-YYYYMMDD-NNN`(reviewer) / `JFUN-N-YYYYMMDD-NNN`(seeding) 자동 채번 (JST 기준, SECURITY DEFINER 트리거, 연도 4자리 숫자). **[dev 검증 중] migration 078** (2026-05-04, 운영 미배포): v2 `JFUN-{R|S}-YYMMDD-NNN`로 단축 — Q→R, N→S, 연도 2자리 숫자, 기존 데이터 일괄 변환 |
| form_type             | text        | `reviewer`(Qoo10 리뷰어) / `seeding`(나노 인플루언서 시딩) |
| brand_name, contact_name, phone, email | text | 브랜드·담당자 기본 정보 |
| billing_email         | text        | 세금계산서용 이메일 (reviewer 전용) |
| request_note          | text NULL   | 신청자 자유 입력 「기타/요청사항」 (migration 068, 2026-04-23) |
| products              | jsonb       | 상품 배열 `[{name,url,price,qty,category},...]` 1~50개 |
| total_jpy             | numeric     | 서버 재계산: Σ(price × qty) |
| total_qty             | integer     | 서버 재계산: Σ(qty) |
| estimated_krw         | numeric     | 서버 재계산 — reviewer=`total_jpy*10 + total_qty*2500 + VAT(10%)`, seeding=`0` |
| final_quote_krw       | numeric     | 관리자 수동 입력 확정 견적 (KRW) |
| quote_sent_at         | timestamptz | 견적서 발송 체크 시각 |
| status                | text        | 10단계 (§22.6): `new`→`reviewing`→`quoted`→`paid`→`kakao_room_created`→`orient_sheet_sent`→`schedule_sent`→`campaign_registered`→`done`/`rejected`. **2026-04-30 (d860685)**: `kakao_room_created` 추가 (9→10단계). CHECK 제약 갱신 |
| admin_memo            | text        | 관리자 내부 메모 |
| reviewed_by           | uuid FK     | auth.users.id (ON DELETE SET NULL) |
| reviewed_at           | timestamptz | 검수자/시각 |
| version               | integer     | 낙관적 락. BEFORE UPDATE 트리거로 자동 증가 |
| created_at, updated_at | timestamptz | BEFORE UPDATE 트리거로 updated_at 자동 갱신 |

### 5.6 campaigns_yearly_counter (migration 055)

| 컬럼 | 타입        | 설명 |
|------|-------------|------|
| year | integer PK  | JST 연도 (예: 2026) |
| seq  | integer     | 해당 연도 채번 카운터 |

`generate_campaign_no()` 트리거 전용. SECURITY DEFINER + `search_path ''`. 관리자 SELECT만 허용(anon/authenticated 차단). 연도별 ON CONFLICT UPDATE로 seq 증가 후 `CAMP-YYYY-NNNN` 포맷.

### 5.7 admin_notices (migration 063)

| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid PK | 자동 생성 |
| category | text | `system_update` / `release` / `warning` / `general` (CHECK) |
| title | text NOT NULL | 공지 제목 |
| body_html | text | Quill 리치 HTML (XSS 저장+렌더 이중 sanitize) |
| pin | boolean | 상단 고정 여부 (기본 false) |
| created_by | uuid FK | `admins.auth_id` |
| created_by_name | text | 스냅샷 |
| created_at, updated_at | timestamptz | BEFORE UPDATE 트리거로 updated_at 자동 |

RLS: SELECT는 `is_admin()`, INSERT/UPDATE/DELETE는 `campaign_admin` 이상.

### 5.8 admin_notice_reads (migration 063)

| 컬럼 | 타입 | 설명 |
|------|------|------|
| admin_id | uuid FK | `admins.auth_id` |
| notice_id | uuid FK | `admin_notices.id` |
| read_at | timestamptz | UNIQUE(admin_id, notice_id) |

관리자별 읽음 기록. `upsert_admin_notice_read(p_notice_id)` RPC로 한 건씩 upsert. 미읽음 카운트 = `admin_notices.count - 본인 admin_notice_reads.count`.

### 5.9 influencer_flags (migration 059/060/061/062)

| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid PK | 자동 생성 |
| influencer_id | uuid FK | `influencers.id` |
| action | text | `verify` / `violation` / `blacklist` / `clear` (CHECK, 060에서 violation 추가) |
| reasons | text[] | `blacklist_reason` ∪ `violation_reason` lookup code 배열 |
| memo | text | 자유 입력 |
| evidence_paths | text[] | `influencer-flag-evidence` 비공개 버킷 경로들 (062 추가) |
| created_by, created_by_name | uuid, text | 최초 기록 관리자 |
| created_at | timestamptz | 기록 시각 |
| updated_by, updated_by_name, updated_at | uuid, text, timestamptz | 위반 행 편집 이력 (061 추가) |

RLS: SELECT는 `is_admin()`, INSERT/UPDATE/DELETE는 전용 RPC 전용. **UPDATE는 `action='violation'` 행만 허용** (061). RPC: `set_influencer_verified` / `set_influencer_blacklist` / `record_influencer_violation` / `update_influencer_violation`. `p_evidence_paths` 파라미터 규칙: `null`=미변경, `[]`=전체 삭제, 배열=교체.

### 5.10 brand_app_daily_counter

| 컬럼 | 타입 | 설명 |
|------|------|------|
| day  | date | JST 기준 일자 |
| form_type | text | reviewer/seeding |
| seq  | integer | 당일 해당 폼타입 채번 카운터 |
| PK   | (day, form_type) | |

### 5.11 [dev 검증 중] campaign_caution_history (migration 077, 2026-04-30, 운영 미배포)

| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid PK | 자동 생성 |
| campaign_id | uuid FK | `campaigns.id` ON DELETE CASCADE |
| changed_by | uuid | `auth.users.id` (ON DELETE SET NULL) |
| changed_by_name | text | 변경 시점 관리자 이름 스냅샷 (관리자 계정 삭제 후에도 누가 바꿨는지 보존) |
| changed_at | timestamptz | 기본 now() |
| caution_set_id_prev / caution_set_id_next | uuid | 주의사항 번들 변경 전·후 ID |
| caution_items_prev / caution_items_next | jsonb | 주의사항 항목 변경 전·후 스냅샷 |
| participation_set_id_prev / participation_set_id_next | uuid | 참여방법 번들 변경 전·후 ID |
| participation_steps_prev / participation_steps_next | jsonb | 참여방법 단계 변경 전·후 스냅샷 |
| app_count_at_change | integer | 변경 시점 pending+approved 신청자 수 (영향 범위 추적용) |
| bypass_warning_ack | boolean | `#sensitiveChangeModal` 경고 모달 통과 여부 |

목적: 캠페인의 민감 항목(주의사항·참여방법) 변경 audit. 신청자 영향이 큰 항목이므로 누가/언제/어느 필드를 어떻게 바꿨는지 추적 가능해야 함 (§33).

행 단위 보안 정책(RLS): **SELECT는 `is_super_admin()` 한정** (일반 admin·인플루언서 모두 비공개). INSERT/UPDATE/DELETE 정책 미정의 — `record_caution_history()` SECURITY DEFINER 원격 호출 함수(RPC) 경유 INSERT 만 허용 (campaign_admin 이상 가드, `SET search_path = ''`). 인덱스: `(campaign_id, changed_at DESC)`.

조회 진입점:
- 캠페인 더보기 메뉴 「변경 이력」 (super_admin 한정) → 타임라인 모달
- 인플루언서 응모이력의 「現在の文言と比較」 토글 → v2 스냅샷 ↔ 현재 비교

영향: PROJECT_CONTEXT §2-1에 audit 테이블 1줄 보강. 인플루언서 개인정보를 보유하지 않으므로 한국 개인정보 보호법(PIPA)·일본 개인정보보호법(APPI) 영향 무관 (운영 감사용).

채번 트리거 전용. anon·authenticated 접근 차단, 관리자 SELECT만 허용.

---

## 6. DB 함수 및 트리거

| 함수명                 | 용도                                       |
| ---------------------- | ------------------------------------------ |
| is_admin()             | 현재 사용자의 관리자 여부 확인             |
| is_super_admin()       | super_admin 여부 확인                      |
| is_campaign_admin()    | campaign_admin 이상 여부 확인              |
| handle_new_user()      | 회원가입 시 influencers 자동 생성 (트리거) |
| invite_admin()         | **관리자 초대** (super_admin 전용) — auth.users + identities 생성, 기존 인플루언서 자동 승격. 클라이언트는 직후 `resetPasswordForEmail` 호출 |
| remove_admin_role()    | 관리자 권한만 해제 (admins 행 제거, 인플루언서 계정 유지) |
| delete_admin_completely() | 관리자 완전 삭제 (applications/receipts/admins/influencers/identities/auth.users cascade, 자기 자신 차단) |
| create_admin()         | **deprecated** (migration 032). 호출 시 예외 — `invite_admin` 사용 |
| generate_campaign_no() | `campaigns` BEFORE INSERT 트리거. JST 연도 파생 → `campaigns_yearly_counter` ON CONFLICT UPDATE → `campaign_no` = `CAMP-YYYY-NNNN` 포맷 세팅. SECURITY DEFINER + `search_path ''` (migration 055) |
| submit_brand_application(payload jsonb, license_path text) | **익명 접수 RPC** — sales 페이지 brand_applications 인서트. SECURITY DEFINER + `BYPASSRLS=true`. anon/authenticated 호출 가능. 반환 `{id, application_no}`. 클라이언트는 `.insert().select()` 대신 `.rpc()` 사용 필수 (직접 INSERT는 42501 RLS 오류). 서버 트리거가 application_no 채번 + products 재계산 (migration 056) |
| friendlyError()        | Supabase 에러를 한국어 메시지 + 에러 코드로 변환 (admin.js) |
| getStatusBadgeKo()     | 관리자 페이지 한국어 상태 뱃지 생성 (admin.js) |
| reset_admin_password() | 관리자 비밀번호 리셋 (super_admin 전용)    |
| incrementViewCount()   | 캠페인 조회수 +1 (클라이언트, storage.js)  |
| autoCloseCampaigns()   | 마감일 경과 캠페인 자동 종료 (storage.js)  |
| validateDeadlines()    | 게시마감 >= 모집마감 인라인 검증 (admin.js) |
| dDayLabel()            | D-day 색상 라벨 생성 (ui.js)               |
| formatDateTime()       | 날짜+시:분 포맷 (ui.js)                    |

---

## 7. 화면 구성

```
인플루언서 앱 (모바일 480px)
├── GNB (비로그인: Log In/Sign Up, 관리자: Admin 버튼)
├── 홈 (캠페인 목록)
│   ├── 채널 필터 탭
│   ├── 모집유형 필터
│   └── 캠페인 카드 그리드
├── 캠페인 상세 (조회수 자동 카운트)
│   ├── 이미지 캐러셀
│   ├── 상품/모집 정보
│   ├── 참가 방법 (3 STEP)
│   ├── 가이드라인/NG/주의사항
│   ├── LINE + Instagram CTA
│   ├── 필수정보 체크 오버레이
│   └── 신청 모달
├── 마이페이지 (리스트 → 상세 네비게이션)
│   ├── 프로필 헤더 (아바타 + 이름)
│   ├── 메뉴 리스트 (応募履歴/基本情報/SNS/配送先/PayPal/PW変更/ログアウト)
│   ├── 각 메뉴 → 상세 서브페이지 (← 뒤로가기)
│   └── 退会 (하단 좌측 작은 텍스트)
├── 로그인
└── 회원가입 (1단계: 이름+이메일+비밀번호)
[GNB 우측 햄버거 메뉴: 홈 / キャンペーン / マイページ / 通知 / ログアウト]

관리자 앱 (PC 전체폭, 2단 고정 레이아웃: 사이드바 + 메인 독립 스크롤)
├── 사이드바 (접기/펼치기 토글, Material Icons, data-pane 라우팅, pending 배지)
│   └── 하단 footer: 접속자 프로필 → 내 계정 / 인플루언서 화면 / 로그아웃
├── 페이지 로딩 (visibility:hidden cloak, 인라인 스피너)
├── 대시보드
│   ├── KPI 카드 (캠페인/인플루언서/신청/승인)
│   ├── 회원가입 추이 차트 (7일/30일/전체)
│   ├── 오늘/이번주 가입 KPI
│   ├── 프로필 완성률 (SNS별/배송지/PayPal)
│   └── 최근 신청 테이블
├── 캠페인 관리
│   ├── 필터 (상태/타입 드롭다운 + 검색)
│   ├── 헤더 정렬 (조회/신청/등록일/수정일 ▲▼)
│   ├── 순서 변경 모드 (버튼 토글)
│   ├── 상태 드롭다운 변경
│   ├── D-day 라벨 (게시/모집 마감)
│   ├── 캠페인 미리보기 모달 (모바일 480px 프리뷰 + 편집 버튼)
│   ├── 생성/수정 폼 (마감일 검증)
│   ├── 자동 상태 종료 (deadline 경과)
│   └── 이미지 관리
├── 신청 관리
│   ├── 테이블 UI (썸네일, 필터, 검색, 상태 정렬)
│   ├── 인플루언서 상세 모달
│   ├── 승인/거절 처리 (reviewed_by/reviewed_at 기록)
│   └── 되돌리기 (pending 복귀)
├── 인플루언서 관리
│   ├── 목록/필터
│   └── 상세 모달
├── 광고주 신청 관리 (§22)
│   ├── 리스트 (폼타입/상태/기간/검색 필터, pending 배지)
│   ├── 상세 모달 (제품 테이블, final_quote_krw)
│   └── 상태 전이 (new→reviewing→quoted→paid→done/rejected)
└── 관리자 설정
    ├── 기준 데이터 관리 (lookups)
    ├── 관리자 목록/CRUD + 설문 메일받기 토글 (§22)
    └── 내 계정

광고주 신청 앱 (sales.globalreverb.com, 별도 Vercel 프로젝트)
├── / (choice landing — 리뷰어 모집 / 시딩 선택)
├── /reviewer (Qoo10 리뷰어 모집 폼)
└── /seeding (나노 인플루언서 시딩 폼)
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

### 9.1 테스트 인플루언서 (3명)

| 이메일                | 이름       | 카테고리 | 주력 채널   | 팔로워 | 비밀번호 |
| --------------------- | ---------- | -------- | ----------- | ------ | -------- |
| sakura.test@reverb.jp | 佐藤さくら | Beauty   | Instagram   | 12,500 | test1234 |
| yui.test@reverb.jp    | 田中ゆい   | Food     | TikTok      | 45,000 | test1234 |
| haruka.test@reverb.jp | 鈴木はるか | Fashion  | Instagram+X | 22,000 | test1234 |

---

## 10. 캠페인 신청 조건 — 최소 팔로워수 정책

### 10.1 현재 정책 (2026-04-13 변경: OR → 기준 채널 단일)

**방식: 기준 채널 단일 검증**
- 캠페인 등록 시 선택한 채널 중 1개를 **기준 채널(primary_channel)**로 지정
- 회원의 해당 기준 채널 팔로워수가 `min_followers` 이상이면 신청 가능
- 다른 채널의 팔로워수는 검증에 사용되지 않음
- 예시: 캠페인 채널=[Instagram, X], 기준 채널=Instagram, `min_followers`=5000
  - Instagram 7,000 → 신청 가능 (X는 무관)
  - Instagram 3,000 + X 9,000 → 차단 (기준 채널 미달)

### 10.2 스키마
- `campaigns.channel` (text, 콤마 구분): `"instagram,x"` 형식으로 복수 채널 저장
- `campaigns.primary_channel` (text): 팔로워 검증 기준 채널 코드 (NULL이면 첫 번째 채널로 폴백)
- `campaigns.min_followers` (int): 기준 채널의 최소 팔로워수
- `influencers.ig_followers / x_followers / tiktok_followers / youtube_followers`: 채널별 팔로워 수

### 10.3 구현 위치
- 검증 로직: `dev/js/application.js` (openApplyFlow 함수 내 팔로워 체크 블록)
- 관리자 폼: 채널 체크박스 변경 시 기준 채널 셀렉트 옵션 자동 갱신
- Qoo10은 Instagram 팔로워를 참조

### 10.4 정책 변경 배경 (2026-04-13 OR→단일)
- OR 방식의 단점: 캠페인 의도와 다른 채널의 팔로워로 통과되어 광고 효과 왜곡 가능
- 광고주가 특정 채널(예: Instagram) 노출을 원하는 경우, 그 채널에서의 영향력만 검증해야 함
- 기준 채널 단일 방식: 명확한 광고 목적에 부합, 회원에게도 어떤 채널이 평가되는지 명시적

### 10.5 마이그레이션
- 026_campaigns_primary_channel.sql: `primary_channel` 컬럼 추가
- 기존 `min_followers > 0` 캠페인은 `channel`의 첫 번째 값을 자동으로 기준 채널로 설정

### 10.6 향후 확장안 (참고용)

**A. 채널별 최소치**
- `campaigns.min_followers_by_channel` (JSON): `{"instagram": 10000, "x": 5000}`
- 채널마다 다른 기준이 필요한 캠페인 대응

**B. AND 옵션 추가**
- `campaigns.follower_policy: 'primary' | 'all'` 컬럼 추가
- 'all' 선택 시 선택 채널 **전부**가 `min_followers` 이상이어야 통과

---

## 11. 홈 푸터 (인플루언서 페이지)

메인 페이지 하단에 회사 정보 및 법적 링크 영역을 노출합니다.

### 11.1 노출 정보
- 회사명: 株式会社ジェイファン
- 所在地: ソウル市 衿川区 加山デジタル1路 128 STX V-Tower 1201号
- 代表者: ジュ・ヒョンホ
- お問い合わせ: 公式LINE @reverb.jp

### 11.2 링크
- 会社紹介 / 利用規約 / 個人情報処理方針 — 클릭 시 슬라이드업 모달(`#legalModal`)에서 내용 표시
- 利用規約 / 個人情報処理方針 일본어 번역은 준비 중(시행 예정일 2026-05-01)

### 11.3 SNS 아이콘
- Instagram, X (인라인 SVG) — 실제 공식 계정 URL은 운영 시 업데이트 필요

### 11.4 구현 파일
- HTML: `dev/index.html` `#page-home` 내 `.site-footer`
- CSS: `dev/css/components.css` `.site-footer`, `#legalModal`
- JS: `dev/js/ui.js` `openLegalModal()`, `closeLegalModal()`, `buildLegalContent()`

---

## 12. 성능 최적화 (2026-04-13 적용)

### 12.1 리소스 로드
- preconnect: Supabase, Google Fonts, jsDelivr
- CropperJS는 관리자 번들에만 포함 (인플루언서 번들에서 제거, 50KB 절감)
- Noto Sans JP: 2개 → 필요 weight 4개(400/500/700/900)로 최적화
- Noto Sans KR: 인플루언서 번들에서 제거 (일본어 전용)

### 12.2 이미지 최적화
- `loading="lazy"` `decoding="async"` 적용 위치
  - 홈 캠페인 카드
  - 캠페인 상세 캐러셀 2번째 슬라이드부터
  - 마이페이지 응모이력 썸네일
  - 관리자 캠페인/신청 썸네일
- `imgThumb(url, width, quality)` 헬퍼 (`dev/js/ui.js`)
  - `/storage/v1/object/public/` → `/storage/v1/render/image/public/?width=&quality=&resize=cover`
  - Supabase Pro 플랜의 Image Transformation 활용
  - 실패 시 `onerror` → 원본 URL 폴백 (`data-orig` 속성)
- 용도별 width: 홈 카드 480, 캐러셀 960(q=80), 마이페이지 240, 관리자 160

---

## 13. 캠페인 채널 멀티 선택 (2026-04-13)

### 13.1 스키마
- `campaigns.channel` (text): 콤마 구분 문자열로 복수 채널 저장 — 예 `"instagram,x"`
- 기존 단일값 캠페인과 하위 호환

### 13.2 관리자 폼
- 채널: 체크박스 그룹(Instagram/X/Qoo10/TikTok/YouTube)
- 옵션 "Instagram + X" 삭제 — 두 채널 체크로 동일 효과
- 저장: 체크된 값들을 콤마로 조인
- 신규 등록 시 최소 1개 채널 선택 검증

### 13.3 인플루언서 필터·라벨
- 홈 채널 칩은 `camps.flatMap(c => c.channel.split(','))`로 동적 생성
- 필터 매칭: `channels.includes(currentFilter)`
- `getChannelLabel(ch)`: 콤마 분리 후 " + "로 조인 (예: "Instagram + X")

---

## 14. 이용약관 및 개인정보 처리방침

- 원본 문서: `docs/TERMS.md`, `docs/PRIVACY.md`
- 최종 확정일: 2026-04-13 세션
- 시행 예정일: 2026-05-01
- 준거법: 대한민국법 · 관할 서울중앙지방법원
- 개인정보 보호책임자: 김영근 이사 (younggeun.kim@jfun.co.kr)
- 배포 전 필수 작업: 일본 현지 법무 검토(APPI·特定商取引法·景品表示法·ステマ告示) + 일본어 번역본 작성

---

## 15. 캠페인 모집 타입 (recruit_type)

| 코드 | 한국어 | 일본어 | 설명 |
|---|---|---|---|
| `monitor` | 리뷰어 | レビュアー | 회원이 제품을 직접 구입 → 영수증 등록 → 리워드 지급 |
| `gifting` | 기프팅 | ギフティング | 회사가 제품을 무상 제공 → 회원이 콘텐츠 게시 |
| `visit` | 방문형 | 訪問 | 지정된 오프라인 매장·팝업스토어 직접 방문 → 체험 → 콘텐츠 게시 |

> **2026-04-16 일본어 용어 표준화**: `来店 → 訪問`, 영문 "Reviewer" 탭 라벨 → `レビュアー`. 자세한 매핑은 §26 참조.

### 라벨 헬퍼 (`dev/js/ui.js`)
- `getRecruitTypeLabelJa(t)` — 인플루언서 페이지 라벨 (レビュアー / ギフティング / 訪問)
- `getRecruitTypeBadgeKo(t)` — 관리자 한국어 배지 (큰 사이즈)
- `getRecruitTypeBadgeKoSm(t)` — 관리자 한국어 배지 (작은 사이즈, 9px)

### 색상 컨벤션
- 리뷰어: blue
- 기프팅: gold
- 방문형: green

### 영향 받는 위치
- 관리자 등록/편집 폼 라디오 버튼 (3개)
- 관리자 캠페인/신청 관리 필터 드롭다운
- 인플루언서 캠페인 목록 상단 탭(すべて / レビュアー / ギフティング / 訪問)
- 응모이력 라벨, 캠페인 카드 라벨

### 향후 검토
- 방문형 캠페인의 추가 필드 — 매장 주소, 운영 시간, 예약 방법 등 캠페인 등록 폼에 별도 항목 필요할 수 있음

---

## 16. 기준 데이터 관리 (lookup_values)

캠페인에서 사용하는 4종류 기준 데이터를 통합 관리하는 메뉴입니다.

### 16.1 대상 데이터
| kind | 한국어 | 일본어 라벨 예 | 비고 |
|---|---|---|---|
| `channel` | 채널 | Instagram / X(Twitter) / Qoo10 / TikTok / YouTube | 모집 타입(recruit_types[])과 연동 |
| `category` | 카테고리 | 뷰티/푸드/패션/헬스/기타 | 캠페인 분류 |
| `content_type` | 콘텐츠 종류 | 피드/릴스/스토리/쇼츠/동영상/이미지 | 캠페인 등록 시 복수 선택 |
| `ng_item` | NG 사항 | 경쟁사 노출 금지 등 | 프리셋. 캠페인 등록 폼의 NG textarea에 클릭으로 삽입 |

### 16.2 스키마 (`lookup_values`)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id | uuid | PK |
| kind | text | channel / category / content_type / ng_item |
| code | text | 영문 식별자 (자동 생성, UI 비공개) |
| name_ko | text | 한국어 명칭 (필수) |
| name_ja | text | 일본어 명칭 (필수) |
| sort_order | int | 정렬 순서 |
| active | boolean | false면 신규 등록 폼에서 숨김 |
| recruit_types | text[] | channel 전용. monitor/gifting/visit 중 1개 이상 |
| created_at / updated_at | timestamptz | updated_at은 트리거로 자동 갱신 |

UNIQUE 제약: `(kind, code)`

### 16.3 권한 (RLS)
- SELECT: 인증·익명 모두 가능 (익명은 active만)
- INSERT/UPDATE/DELETE: `is_campaign_admin()` (campaign_admin 또는 super_admin)

### 16.4 관리자 UI
- 사이드바 메뉴 "기준 데이터" — campaign_admin 이상에게만 노출
- 종류별 4개 탭 (채널 / 카테고리 / 콘텐츠 종류 / NG 사항)
- 행: 한국어명(채널은 모집 타입 배지 함께) / 일본어명 / 활성 토글 / 편집 / 삭제
- "순서 변경" 토글 버튼 — 모드 진입 시 ↑↓ 컬럼 표시, 다른 액션 숨김 (캠페인 관리와 동일 UX)
- 추가/편집 모달: 한국어·일본어 명칭 필수, 채널이면 모집 타입 체크박스 (1개 이상 필수)
- 삭제: 사용 중이면 토스트로 차단, 미사용이면 커스텀 confirm 모달 → hard delete

### 16.5 코드(code) 정책
- 운영자가 직접 입력하지 않음 (UI에 노출하지 않음)
- 등록 시 한국어·일본어 명칭에서 자동 슬러그 생성 (`generateLookupCode`)
- 영문/숫자가 거의 없으면 `kind-랜덤6자리` 형태로 폴백
- 코드 변경이 필요한 경우 SQL로 직접 처리 (기존 캠페인 데이터 매칭이 깨질 위험 때문)

### 16.6 캐싱
- `fetchLookups(kind)` — 활성 항목만, 메모리 캐시 사용 (캠페인 등록 폼·인플루언서 페이지)
- `fetchLookupsAll(kind)` — 비활성 포함, 캐시 미사용 (관리자 화면)
- CUD 시 해당 kind 캐시 invalidate

### 16.7 향후 통합 작업 (Pending)
- 캠페인 등록/편집 폼의 채널·카테고리·콘텐츠 체크박스를 `lookup_values` 조회 결과로 동적 렌더링
- 캠페인 폼에서 모집 타입 선택 시 → 채널 체크박스를 `recruit_types` 일치하는 것만 표시
- 인플루언서 페이지 채널 라벨/필터를 `lookup_values`로 전환
- NG 프리셋: 캠페인 등록 폼에 "프리셋 추가" 버튼 → 클릭 시 NG textarea에 일본어 본문 삽입


## 17. 비밀번호 정책

### 17.1 강도 규칙 (회원가입·비밀번호 변경 공통)
- **최소 길이**: 8자 이상
- **필수 조합**: 영문 소문자 + 특수문자 (최소)
- **권장 조합**: 영문 대소문자 + 숫자 + 특수문자 중 2개 이상
- **사용 가능 특수문자**: `!@#$%^&*()_+-=[]{}|;:,.<>?` 등 일반적인 ASCII 기호
- **유출 비번 차단**: Supabase Auth의 HIBP(Have I Been Pwned) 검사 활성 — 유출 이력 있는 비밀번호는 가입·변경 모두 차단
- 클라이언트 검증(`dev/js/auth.js`)과 Supabase Auth 정책 이중 적용

### 17.2 변경 시 추가 제약
- **현재 비밀번호와 동일 금지** — 새 비밀번호가 기존과 같으면 거부
- **새 비밀번호 ≠ 새 비밀번호 확인** 시 거부
- 변경 성공 시 토스트 안내 + 세션 유지 (재로그인 불필요)

### 17.3 보기/가리기 토글 (UI)
모든 비밀번호 input(`type="password"`) 우측에 눈 아이콘 토글 버튼 노출. 인플루언서·관리자 페이지 전체 적용.

| 위치                                | input ID                                       |
|-------------------------------------|------------------------------------------------|
| 인플루언서 — 로그인                 | `loginPw`                                      |
| 인플루언서 — 회원가입               | `signupPw`, `signupPw2`                        |
| 인플루언서 — 비밀번호 재설정        | `resetPwNew`, `resetPwConfirm`                 |
| 인플루언서 — 마이페이지 비번 변경   | `currentPw`, `newPw`, `newPw2`                 |
| 관리자 — 내 계정 비번 변경          | `myAdminCurrentPw`, `myAdminNewPw`, `myAdminNewPw2` |
| 관리자 — 비밀번호 초기화 모달       | `resetPwNew` (admin)                           |

- 구현 헬퍼: `dev/js/ui.js`의 `togglePw(inputId, btn)` — 클릭 시 `type` 속성을 `password ↔ text` 토글, 아이콘은 눈/눈 가림 SVG 전환
- CSS: `.pw-wrap`(상대위치 컨테이너) + `.pw-toggle`(우측 절대배치 버튼)

### 17.4 가입 시 기존 이메일 처리
- 이미 가입된 이메일로 재가입 시도하면 **계정 열거 방지**(`SECURITY` 규칙)에 따라 구체적 에러 노출 금지
- 일본어 안내: "이미 등록된 이메일입니다. 로그인하거나 비밀번호 재설정을 이용해주세요" 수준의 일반적 메시지만 표기

### 17.5 관리자 비밀번호 초기화 (super_admin 전용)
두 가지 경로 제공 (`/admin#admin-accounts` → 관리자 행 액션 메뉴):
- **메일로 재설정 링크 발송** — `auth.resetPasswordForEmail()` 호출 → 대상자가 메일 링크로 직접 새 비밀번호 설정 (권장)
- **수동 비밀번호 지정** — 모달에서 8자 이상 새 비밀번호 입력 → `reset_admin_password(target_auth_id, new_password)` RPC 호출
  - DB 함수는 `SECURITY DEFINER`로 정의, `extensions.crypt`/`extensions.gen_salt(\047bf\047, 10)` 사용 (search_path=`""` 환경에서 pgcrypto 호출)
  - 자기 자신 비밀번호 수동 초기화 차단 — "내 계정" 메뉴의 비밀번호 변경 사용

### 17.6 저장·전송
- 평문 비밀번호는 **절대 DB·로그·토스트에 저장/노출 금지**
- bcrypt 라운드 10 (`extensions.gen_salt(\047bf\047, 10)`) — Supabase Auth 기본값과 일치
- HTTPS 전제 (운영·개발 양 환경 Vercel SSL)

---

## 18. 참여방법 번들 (participation_sets) — 2026-04-15

### 18.1 개요
캠페인 상세의 "참가방법 STEP 1~N" 영역을 재사용 가능한 **번들**로 관리.
이전: 캠페인마다 동일한 단계를 반복 입력 → 현재: 번들 1개 만들고 캠페인에서 선택만.

### 18.2 데이터 모델
- **`participation_sets`** 테이블
  - `id uuid PK`, `name_ko`, `name_ja` (UNIQUE name_ko)
  - `recruit_types text[]` — monitor/gifting/visit 복수 가능. 빈 배열=전 타입 공통
  - `steps jsonb` — `[{title_ko, title_ja, desc_ko, desc_ja}, ...]`, 1~6개 권장 (앱 레벨 소프트 제약)
  - `sort_order int`, `active bool`, `created_at`, `updated_at` (트리거 자동 갱신)
- **`campaigns` 추가 컬럼**
  - `participation_set_id uuid` FK → `participation_sets.id` `ON DELETE SET NULL`
  - `participation_steps jsonb` — 저장 시점 steps 스냅샷

### 18.3 스냅샷 원칙
- 캠페인 저장 시 선택한 번들의 `steps`를 `campaigns.participation_steps`로 **복사**
- 이후 번들 수정 → 기존 캠페인 영향 **없음**
- 신규 캠페인부터 새 번들 내용 적용
- 캠페인 폼에서 단계 인라인 편집 → 해당 캠페인 스냅샷만 변경, 번들 원본 유지

### 18.4 관리자 UI (`/admin#lookups` → 참여방법 탭)
- 권한: `campaign_admin` 이상 (SELECT/INSERT/UPDATE/DELETE 모두)
- 목록: 번들명/모집타입 태그/단계 수/활성 토글/순서 변경
- 편집 모달: 각 단계 `title_ko/title_ja/desc_ko/desc_ja` 입력, ↑↓/삭제 버튼, 1~6개
- 폰트 크기: 단계 입력은 13px (본 섹션이 밀집 폼이라 가독성 조정)

### 18.5 캠페인 폼 통합
- 모집 타입 선택 → `recruit_types` 매칭 + 전 타입 공통 번들 드롭다운 필터링
- 번들 선택 시 `participation_steps` 자동 채움
- **인라인 수정**: 각 단계 입력 가능 (이 캠페인 스냅샷에만 적용)
- **번들 다시 불러오기** 버튼: 인라인 수정 전 원본 번들로 리셋 (저장 전에만 유효)

### 18.6 인플루언서 렌더링
- 캠페인 상세 "참가방법" 섹션:
  - `camp.participation_steps` 있으면 그대로 렌더링
  - 없으면 (2026-04-15 이전 캠페인) legacy 하드코딩 단계 fallback
- 일본어 (`title_ja`, `desc_ja`)만 노출

### 18.7 RLS
- SELECT: `is_admin()` (인플루언서는 `campaigns.participation_steps` 스냅샷으로만 간접 접근)
- INSERT/UPDATE/DELETE: `is_campaign_admin()`

### 18.8 마이그레이션·시드
- Migration: `supabase/migrations/033_create_participation_sets.sql`
- Seed: `supabase/seed/participation_sets.sql` (리뷰어/기프팅/방문형 기본 3건, 각 3단계)
- 재실행 안전 (`ON CONFLICT (name_ko) DO NOTHING`)

---

## 19. 캠페인 채널 매칭 표시 (channel_match) — 2026-04-15

### 19.1 배경
멀티채널 캠페인에서 인플루언서 상세 페이지에 채널 pill을 어떤 구분자로 연결할지 캠페인별 설정.
**자격 검증 로직에는 영향 없음** — §10의 `primary_channel` 단일 검증과 무관 (channel_match는 표시용 구분자 전용).

### 19.2 데이터
- `campaigns.channel_match text DEFAULT 'or' CHECK (channel_match IN ('or','and'))`

### 19.3 관리자 폼
- 채널 체크박스 **2개 이상 선택**된 경우에만 `or`/`&` 라디오 노출
- 채널 1개면 라디오 숨김, 값은 기본 `'or'` 유지

### 19.4 인플루언서 상세 렌더링
- 채널 pill 사이에 구분자 표시:
  - `or` → 텍스트 `or`
  - `and` → 텍스트 `&`
- 예: `Instagram or TikTok` / `Instagram & X`

### 19.5 카드 표시
- 카드에서는 공간 절약을 위해 **첫 채널 + `+N`** 형식 고정 (channel_match 무시)
- 상세 진입 시에만 구분자 기반 풀 렌더

---

## 20. 캠페인 카드 배지 레이아웃 — 2026-04-15 (2026-04-21 재배치)

### 20.1 변경 배경
이전 카드: 이미지 위에 `募集中` + 모집타입 배지 중첩 → 정보 밀집도 과다, 모집 마감 임박을 인식하기 어려움.
개편: 이미지 위/제목 위/콘텐츠 종류 아래로 **위치별 역할 분리**.

**2026-04-21 추가 재배치** (커밋 9364b07/82b377b/32bc19d): `募集中` pill을 이미지 **좌상단**으로 상향 배치(solid 배경 — 이미지와 대비 확보), `NEW`는 **우상단**으로 이동해 `募集中`과 단일 flex row로 정렬. 슬롯 카운트(`{applied}/{slots}名`)는 콘텐츠 종류 아래로 이동.

### 20.2 배지 위치 규칙 (2026-04-21 기준)

| 위치 | 배지 | 조건 |
|---|---|---|
| 이미지 좌상단 | `募集中` pill | `status=active` 시 항상 표시 (solid 배경, 이미지 위 대비 확보) |
| 이미지 우상단 | `NEW` | 등록 7일 이내 (`募集中`과 단일 flex row로 정렬) |
| 제목 위 (우) | `締切間近` | `deadline` 경과까지 5일 미만 **OR** 잔여 slots ≤ 30% |
| 콘텐츠 종류 아래 | `모집타입` pill | 항상 표시 (리뷰어/기프팅/방문형) |
| 콘텐츠 종류 아래 | `{applied}/{slots}名` | 진행중 캠페인 항상 표시 |
| 이미지 좌하단 | 첫 채널 + `+N` | 채널 복수 시 `+N` 표기 (`dev/js/campaign.js` `left:8px`) |

### 20.3 `締切間近` 판정 로직
- deadline 기준 D-day 5 미만 **또는** `(slots - applied) / slots ≤ 0.3`
- 둘 중 하나라도 참이면 표시 (OR 조건)
- 독립 배지 (`募集中`과 병존 가능)

### 20.4 `{applied}/{slots}名` 규칙
- `applications` 중 `status='approved'` 카운트를 `applied`로 사용
- `slots`는 캠페인 정의값
- 진행중 캠페인에서 **항상** 표시 (이전: 特정 조건에서만)

### 20.5 구현 위치
- 카드 렌더: `dev/js/campaign.js` 의 카드 생성 함수
- 스타일: `dev/css/campaign.css`

---

## 21. 다국어 대응 (i18n) — 2026-04-16

### 21.1 개요
인플루언서 앱(모바일)에 한국어(KO)/일본어(JA) 토글을 제공. 기본값은 일본어(ja).
개발서버(`dev.globalreverb.com`)에서만 동작하며 운영 배포는 테스터 검증 후 결정.

### 21.2 아키텍처
- **키-값 사전**: `dev/lib/i18n/ja.js` (일본어), `dev/lib/i18n/ko.js` (한국어)
- **런타임**: `dev/lib/i18n/index.js` — `getLang()`, `setLang()`, `t(key)`, `applyI18n()`
- **HTML 정적 바인딩**: `data-i18n="key"` (textContent), `data-i18n-html="key"` (innerHTML, `<br>` 허용)
- **JS 동적 바인딩**: `t('key')` 헬퍼 또는 `t('key', {var: val})` 플레이스홀더
- **언어 저장**: `localStorage('reverb.lang')`, 기본값 `ja`
- **navigator.language 자동 감지**: 사용 안 함 (명시적 토글만)

### 21.3 Phase 1 범위 (2026-04-13)
| 영역 | 키 프리픽스 | 파일 |
|---|---|---|
| GNB / 홈 | `gnb.*`, `home.*` | `dev/js/app.js`, `dev/index.html` |
| 인증 (로그인/가입/재설정) | `auth.*` | `dev/js/auth.js` |
| 마이페이지 메뉴·프로필·SNS·배송·PayPal | `mypage.*` | `dev/js/mypage.js` |
| 캠페인 목록 탭 | `campaign.*` | `dev/js/campaign.js` |

### 21.4 Phase 2 범위 (2026-04-16)
| 영역 | 키 프리픽스 | 파일 | 추가된 키 수 |
|---|---|---|---|
| 캠페인 상세 라벨 | `detail.*` | `dev/js/campaign.js`, `dev/index.html` | ~12 |
| 신청 모달 | `apply.*` | `dev/js/application.js` | ~10 |
| 활동관리 (영수증·게시URL) | `activity.*` | `dev/js/application.js`, `dev/js/mypage.js` | ~20 |
| 배송/심사 상태 배지 | `delivStatus.*` | `dev/js/application.js` | ~3 |
| 알림 | `notif.*` | `dev/js/app.js` | ~3 |
| DB 에러 메시지 로케일 대응 | — | `dev/js/ui.js` (`friendlyErrorJa`) | ~8 |

**Phase 2 상세 변경:**
- `application.js` ~40개 하드코딩 일본어 문자열 → `t()` 헬퍼로 전환
- `mypage.js` 활동관리 라벨 일부 → `t()` 전환
- `ui.js`에 `friendlyErrorJa(code, lang)` 함수 추가 — Supabase 에러 코드를 ko/ja 매핑
- `dev/index.html` 내 `#page-activity` 영역에 `data-i18n` 속성 추가

### 21.5 DB 에러 메시지 로케일 대응
- **기존**: Supabase 에러가 영어 raw 메시지로 토스트 노출
- **변경**: `friendlyErrorJa(errorCode, getLang())` → ko/ja 매핑된 사용자 친화 메시지 반환
- **적용 범위**: `submitReceipt`, `submitPostUrl`, `submitApplication`, `saveProfile` (마이페이지)
- **매핑 위치**: `dev/js/ui.js`

### 21.6 언어 전환 흐름
```
사용자가 마이페이지 → 언어 메뉴에서 KO/JA 선택
  ↓
setLang('ko' 또는 'ja')
  ↓
localStorage('reverb.lang') 저장
  ↓
applyI18n() 실행 — DOM 전체에서 data-i18n/data-i18n-html 스캔
  ↓
현재 페이지의 모든 라벨이 선택 언어로 전환
  ↓
JS 동적 영역(토스트, 모달 등)은 다음 렌더링 시 t() 통해 반영
```

### 21.7 Phase 1 + 2 통합 커버리지
| 페이지/영역 | Phase 1 | Phase 2 | 미대응 |
|---|---|---|---|
| GNB / 홈 | ✅ | — | — |
| 인증 (로그인/가입/재설정) | ✅ | — | — |
| 마이페이지 (메뉴·프로필·SNS·배송·PayPal) | ✅ | — | — |
| 캠페인 목록 | ✅ | — | — |
| 캠페인 상세 라벨 | — | ✅ | — |
| 신청 모달 | — | ✅ | — |
| 활동관리 | — | ✅ | — |
| 알림 | — | ✅ | — |
| DB 에러 토스트 | — | ✅ | — |
| 푸터 / 약관 모달 | — | — | ⚠️ 미대응 |
| 관리자 페이지 | — | — | 대상 아님 (한국어 고정) |

### 21.8 구현 시 규칙
- 새 UI 문자열 추가 시 **반드시** `ja.js` + `ko.js` 양쪽에 키 추가
- HTML에 일본어 직접 쓰기 금지 — `data-i18n` 또는 `t()` 사용
- 키 네이밍: `영역.항목` 점(dot) 구분 (예: `detail.recruitType`, `apply.loginRequired`)
- 번역 없는 키 호출 시 키 이름 그대로 fallback (개발 중 누락 감지용)
- i18n 파일은 `dev/lib/i18n/` 에만 위치 (다른 파일에 번역 사전 하드코딩 금지)

---

## 22. 광고주 신청 시스템 (Brand Applications) — 2026-04-20

> **2026-04-20 UI 라벨 변경**: 사이드바/페인 헤더/tooltip 표기는 "**브랜드 서베이**"로 변경. 내부 용어·DB(`brand_applications`)·라우트(`#brand-applications`)·함수명·문서 용어는 `광고주 신청` 그대로 유지 (검색·코드 참조 혼란 방지).

### 22.1 개요
광고주(브랜드)가 비공개 랜딩(`sales.globalreverb.com`)에서 **Qoo10 리뷰어 모집** 또는 **나노 인플루언서 시딩** 신청을 접수 → 관리자 검수 → 견적 확정 → 정산 단계로 이어지는 영업 인테이크 플로우.

### 22.2 신청 앱 (sales)
- **배포**: 별도 Vercel 프로젝트 `reverb-sales`, Root Directory=`sales/`. 도메인 `sales.globalreverb.com` / `sales-dev.globalreverb.com`. `cleanUrls=true` + catch-all rewrite (`/reviewer` → `reviewer.html`)
- **SEO 차단**: 모든 `sales/*.html`에 `<meta name="robots" content="noindex,nofollow">` + 별도 favicon(STAGING DEV 파비콘 누수 방지)
- **UI 언어**: 한국어 (광고주 대상)
- **choice landing** (`/`) — **2026-04-20/21 리디자인**: hero/cards/contact/footer 개편 + stats chips 추가. `/reviewer`(JFUN-R, 2026-05-04 이전 JFUN-Q) 또는 `/seeding`(JFUN-S, 이전 JFUN-N) 선택
- **reviewer 폼**: Qoo10 리뷰어 모집 — 상품 복수 입력(최대 50), 실시간 견적(엔×10 + 2500×인원 + VAT 10%), 세금계산서 이메일. **2026-04-21 intro 리디자인**: Qoo10 리뷰 샘플 이미지 + 브랜드 로고 클릭 시 홈 이동. 2026-04-21 이후 사업자등록증 업로드 제거(migration 057)
- **seeding 폼**: 나노 인플루언서 시딩 — 상품 정보만, 견적은 수동 협의(estimated_krw=0). **2026-04-21 intro 리디자인**: 시딩 샘플 이미지 2종 + 브랜드 로고 홈 링크
- **제출 경로**: 클라이언트는 `supabase.rpc('submit_brand_application', {payload, p_business_license_path})` 호출. **2026-04-21부터 `p_business_license_path`는 하위호환용 무효 인자** — RPC 서명은 유지하되 값이 컬럼에 쓰이지 않음(migration 057로 컬럼·버킷 삭제). 클라이언트는 `null` 전달 권장. 직접 `.insert().select()` 금지

### 22.3 DB (migration 052/053/054/056/057)
- `brand_applications` 테이블 (§5.5), `brand_app_daily_counter` 채번 테이블 (§5.7)
- `admins.receive_brand_notify boolean DEFAULT false` (§5.4)
- Storage: `brand-docs` 버킷은 migration 057에서 제거됨 (사업자등록증 수집 중단)
- RLS: SELECT/UPDATE/DELETE는 `is_admin()`만. **익명 INSERT는 `submit_brand_application()` RPC(SECURITY DEFINER + BYPASSRLS) 전용 경로**로 수행 — 직접 INSERT는 `42501 new row violates row-level security policy` 발생 (migration 056, d20ad73). `brand_app_daily_counter`는 SECURITY DEFINER 트리거 전용
- 트리거:
  - `generate_brand_application_no` (BEFORE INSERT) — JST 기준 v1 `JFUN-{Q|N}-YYYYMMDD-NNN` 채번 (운영, ~migration 076). **[dev 검증 중] migration 078** (2026-05-04, 운영 미배포): v2 `JFUN-{R|S}-YYMMDD-NNN`로 단축, 기존 데이터 일괄 변환
  - `recalc_brand_application_totals` (BEFORE INSERT) — products 배열에서 합계·견적 서버 재계산. 실패 시 WARNING + 클라이언트 값 유지
  - `brand_applications_touch` (BEFORE UPDATE) — updated_at + version 자동 증가

### 22.4 알림 메일 (Edge Function)
- `supabase/functions/notify-brand-application/index.ts`
- **트리거**: 클라이언트가 brand_applications INSERT 직후 Edge Function 직접 호출
- **수신자**: `admins.receive_brand_notify=true` 이메일 + env `NOTIFY_ADMIN_EMAILS`(콤마 구분) 외부 이메일 합산(중복 제거)
- **폴백**: admins 조회 실패 시 env만 사용
- **발송**: Brevo SMTP 경유, 발신 `noreply@globalreverb.com`
- **내용**: 접수번호/폼타입/브랜드명/담당자/견적 요약 + 관리자 페이지 링크

### 22.5 관리자 페인 — 신청 목록 (`/admin#brand-applications`)
- **권한**: `is_admin()` (모든 관리자)
- **리스트**: `admin-pane-list` 공통 구조. 필터(폼타입/상태/기간/브랜드명 검색, multi-filter 스타일 통일), pending(new) 배지, 오래된 순 정렬. **lazy-load 적용** (IntersectionObserver sentinel, 2026-04-21 cbb4396)
- **상세 모달**: 제품 테이블(name/url/price/qty), `final_quote_krw` 수동 입력, `quote_sent_at` 체크, `admin_memo` 텍스트, 상태 드롭다운, "되돌리기"(new 복귀). **사업자등록증 다운로드 섹션은 2026-04-21 제거** (migration 057)
- **낙관적 락**: `version` 불일치 시 "이미 처리됨" 토스트로 저장 차단
- **URL 화이트리스트**: 상품 url 렌더 시 `http://`/`https://` 만 `href` 로 렌더(기타 스킴은 평문)

### 22.5b 관리자 페인 — 현황 대시보드 (`/admin#brand-dashboard`) — 2026-04-21 신규
- **권한**: `is_admin()` (모든 관리자)
- **목적**: brand_applications 집계 KPI + 차트로 영업 인테이크 현황을 한 화면에 표시
- **렌더 소스**: `brand_applications` 클라이언트 집계 (신청 목록과 동일 데이터셋 공유)
- **구성 요소** (구현 기준):
  - **KPI 8개**: 전체 / 리뷰어(Q) / 시딩(N) / 이번달 / 검수대기(new) / 견적전달(quoted) / 완료(paid·done) / 평균 처리일
  - **견적 합계**: 예상 견적(`estimated_krw`) 합 / 확정 견적(`final_quote_krw`) 합
  - **전환 깔때기**: new→reviewing→quoted→paid→done 각 단계 도달률 (파이프라인 시각화)
  - **도넛 차트 2개**: 폼 타입별 분포(리뷰어 vs 시딩) + 상태별 분포
  - **일별 추이 바차트**: 7일/30일/90일 토글 (Chart.js)
  - **최근 신청 리스트**: 최근 5건 (상세 모달 링크)
  - **장기 대기 리스트**: `new` 상태 3일 이상 유지된 건
  - **Vercel Web Analytics 링크 카드**: 외부 대시보드 바로가기 (sales 페이지 방문 지표, §22.8)
- **사이드바 엔트리**: `insights` 아이콘 + "현황 대시보드" (커밋 3ec4215)

### 22.6 상태 전이 — 10단계 파이프라인 (2026-04-22 확장, 2026-04-27 표시 순서 재정렬, 2026-04-30 `kakao_room_created` 추가)

**표시 순서 (2026-04-30, d860685 — `kakao_room_created` 추가)**:
```
new → reviewing → quoted → paid → kakao_room_created → orient_sheet_sent → schedule_sent → campaign_registered → done(최종완료)

rejected: any stage → rejected 로 분기 가능 (reviewing 이후 어느 단계에서든)
되돌리기: any stage → new 로 복귀 가능 (실수 되돌림)
```

> **2026-04-30 변경 이유**: 운영팀이 입금 확인 후 카카오 단톡방을 개설하는 단계가 별도 가시화되지 않아 추적이 어려웠음. `paid` 와 `done` 사이에 `kakao_room_created` 단계 추가로 단톡방 개설 완료 여부를 명시적으로 관리. CHECK 제약·`BRAND_APP_STATUS_ORDER`·`BRAND_STATUS_ORDER_FOR_FUNNEL`·KPI `finalSum` 필터 모두 갱신.

> **2026-04-27 변경 이유**: 입금이 워크플로 거의 마지막에 위치한 이전 표시 순서가 영업팀의 실제 흐름과 어긋났음. **DB 데이터·status 값은 그대로**, 표시 순서·상수만 재정렬.

**확장 이력:**
- migration 064 (2026-04-22): `schedule_sent`, `campaign_registered` 추가 (8단계)
- migration 065 (2026-04-22): `orient_sheet_sent` 추가 (9단계)
- 2026-04-27 (PR #127): 표시 순서 재정렬 (DB 마이그레이션 없음, 클라이언트 상수만 변경)
- 2026-04-30 (d860685): `kakao_room_created` 추가 (10단계, `paid` ↔ `orient_sheet_sent` 사이). CHECK constraint 확장.

**코드 동기화 포인트** (추가 상태 도입 시 함께 수정):
- `BRAND_APP_STATUS` / `_ORDER` / `_LABEL_KO` / `_COLOR` 상수
- `FUNNEL_STAGES` / `ORDER_FOR_FUNNEL` 대시보드 깔때기 계산
- 도넛 key 리스트
- multi-filter 옵션 배열
- KPI `finalSum` 필터: `['quoted', 'orient_sheet_sent', 'campaign_registered', 'paid', 'done']`
- 대시보드 라벨: "접수→완료" → "접수→최종완료"

### 22.7 보안·법률 주의
- 광고주 제출 데이터는 **별개 개인정보 수집 채널** — 한국 PIPA / 일본 APPI 관점에서 인플루언서 데이터와 분리 관리 (PROJECT_CONTEXT §3-4)
- 파일 업로드(사업자등록증 등) 수집은 migration 057에서 중단 — 현재는 텍스트 입력만 수집
- PRIVACY §2.2/§6.1에 광고주 수집 조항·보유기간 명시됨 — 2026-04-21 개정으로 사업자등록증 관련 조항 삭제 완료

### 22.8 Vercel Web Analytics (2026-04-21 도입, 커밋 2318063)
- sales 3개 페이지(`index`/`reviewer`/`seeding`)에 `/_vercel/insights/script.js` 주입 → 페이지뷰 트래킹
- **쿠키 미사용** 방식(Vercel Web Analytics 기본) — 개인식별정보 수집 없음
- 용도: reverb-sales Vercel 프로젝트의 랜딩/폼 도달률·이탈률 분석
- PRIVACY 영향: 쿠키 사용 없으므로 §8 별도 고지 의무 없음. 기존 "자동 수집(서비스 이용 분석)" 범위 내

---

## 23. 캠페인 리워드 안내 (`reward_note`) — 2026-04-20

### 23.1 목적
`campaigns.reward` 금액 외 지급 조건·정산 시점·수수료 등 자유 텍스트 안내. 인플루언서가 리워드를 받기 전 꼭 알아야 할 맥락을 제공.

### 23.2 스키마 (migration 051)
- `campaigns.reward_note text` (NULL 허용, 앱 레벨 maxlength 500자)

### 23.3 관리자 폼
- 캠페인 등록/편집 폼 "모집조건" 섹션, `reward` 입력 바로 아래 행
- 플레이스홀더: "지급 조건·정산 시점·수수료 등 (선택)"

### 23.4 인플루언서 렌더링
- 캠페인 상세 info 테이블 내 **리워드 row에 함께** 표시 (별도 row가 아님 — 2026-04-20 `refactor(detail)` 변경, e16749a)
- 평문 줄바꿈 → `<br>` 변환 (다른 리치 필드와 달리 Quill 미사용)

---

## 24. 캠페인 폼 실시간 미리보기 사이드바 — 2026-04-20

### 24.1 배경
기존 "캠페인 미리보기 모달"(ADM-037)은 목록에서 열어야만 확인 가능. 등록/편집 폼 작성 도중 결과를 확인하려면 저장 후 재열람 필요 → 편집 효율 저하.

### 24.2 구조
- 관리자 등록/편집 폼(`#adminPane-add-campaign`, `#adminPane-edit-campaign`) 우측에 **인라인 카드** 사이드바 (iframe 아님 — 4bd192c에서 iframe → 직접 호출 전환)
- 모바일 480px 프레임 안에서 실제 인플루언서 상세 컴포넌트 재사용
- `_previewState: {mode: 'new'|'edit', cached...}` 전역 상태로 폼 입력값 수집 → 실시간 렌더

### 24.3 반영 signal
- 기본 필드: title, brand, product, channel, channel_match, recruit_type, reward, `reward_note`, slots, min_followers, deadline 등
- 이미지: drop/crop 업로드 직후 미리보기 즉시 갱신 (base64 → 서버 URL 교체 시점도 감지)
- 리치 필드: Quill editor `text-change` 이벤트에 lazy 훅 부착 (`__previewHooked` 플래그로 중복 방지)
- 참여방법 단계 DOM 재구성 시 MutationObserver로 감지
- product_url: 링크 블록으로 렌더 (3823648)

### 24.4 모바일 레이아웃 잠금 해제
- 인플루언서 페이지의 `position:fixed + top/bottom` 모바일 쉘이 미리보기에도 적용되면 컨테이너 높이 폭주 → 미리보기 컨텍스트에서만 쉘 잠금 해제 (822ac6c)

### 24.5 로그인/CTA 숨김
- 미리보기 내부에선 `data-preview-hide` 속성 달린 로그인/회원가입 CTA 숨김 처리 (70f75fd)

---

## 25. 관리자 앱 2단 고정 레이아웃 — 2026-04-20

### 25.1 개요
기존 상단 GNB + 스크롤 컨테이너 1개 구조 → **사이드바 + 메인 2단 고정**, 각각 독립 스크롤. 상단 GNB 제거.

### 25.2 사이드바
- 로고 + 접기 토글 (56px 축소)
- 메뉴 섹션: 대시보드 → 캠페인(관리/신청/결과물) → **브랜드 서베이(현황 대시보드/신청 목록)** → 회원관리(인플루언서) → 관리자 설정(기준 데이터[super_admin 한정]/관리자 계정) — 2026-04-21 "브랜드 서베이" 그룹 분리(커밋 3ec4215)
- **하단 footer (border-top 구분)**:
  - 접속자 프로필 `#sidebarAdminProfile` → `my-account` 라우팅 (중복 "내 계정" 메뉴 제거)
  - 인플루언서 화면으로 전환
  - 로그아웃

### 25.3 메인 영역 — 목록 페인 통일
- `admin-pane-list` 공통 클래스 (flex column): 제목/필터 고정 + 카드 헤더 고정 + `thead sticky` + `tbody` overflow-y
- 대상 8개 페인: campaigns / applications / deliverables / camp-applicants / influencers / lookups / admin-accounts / **brand-applications**
- HTML 구조(`admin-sticky-header → admin-card → admin-card-header → admin-table-wrap → table`)는 8개 모두 동일 — 래퍼 조작 시 8개 동시 확인 필수
- `border-collapse: separate` + `table-wrap` 하단 `border-radius`로 스크롤 내용 clip

### 25.4 대시보드/폼 페인은 자연 스크롤
- `adminPane-dashboard`, `add-campaign`, `edit-campaign`, `influencer-detail`, `my-account`은 목록 아님 → `admin-pane-list` 미적용

### 25.5 성능 최적화
- 대시보드 데이터 병렬 로딩(Promise.all)
- 목록 페인 lazy-load — 탭 전환 시점에 최초 fetch

### 25.6 관리자 리스트 IntersectionObserver 지연 렌더 — 2026-04-21 신규
- **문제**: 관리자 목록 페인이 데이터셋 증가에 따라 resize·필터 변경 시 stuttering 발생 (한 번에 모든 행을 DOM에 그리는 기존 구조)
- **해법**: `IntersectionObserver` 기반 sentinel 패턴 — 페이지 뷰포트 진입 시점에 다음 chunk를 DOM에 추가
- **적용 범위** (2026-04-21 점진 확장):
  - Phase 1: influencers (커밋 79a98c6)
  - Phase 2: applications, deliverables (커밋 8520430 — 동일 커밋에서 `influencers` 캐싱도 추가)
  - Phase 3: campaigns, camp-applicants, brand-applications (커밋 cbb4396)
- **캐시 계층**: `renderAppCampList`가 campaigns/applications/influencers 결과를 in-memory 캐시로 재사용 (커밋 4e34f3c)
- **주의**: 필터·검색·정렬 재실행 시 sentinel 리셋 필요

### 25.7 PostgREST 1000-row cap 우회 — 2026-04-21 (커밋 245e3f5)
- **증상**: 대시보드 KPI가 `influencers`/`applications` 건수에서 정확히 1000에 고정 → Supabase PostgREST 기본 응답 상한
- **조치**: `storage.js`의 fetch 함수에 pagination loop 도입 — `range(from, from+999)` 반복 후 합산
- **대상 함수**: `fetchInfluencers`, `fetchApplications`, `fetchDeliverables` 등 집계용 fetch
- **향후**: 특정 페이지는 서버 사이드 count + 페이지 단위 로드로 전환 예정

---

## 26. 일본어 용어 표준화 — 2026-04-16

### 26.1 변경 매핑
| 이전 | 이후 | 적용 범위 |
|------|------|-----------|
| `来店`(visit) | `訪問` | 모집타입 라벨 전체 (`getRecruitTypeLabelJa`, 카드/상세/탭) |
| 영문 `Reviewer` | `レビュアー` | 인플루언서 페이지 탭 + 라벨 (일관성 확보) |

### 26.2 영향 파일
- `dev/js/ui.js` — `getRecruitTypeLabelJa()` 라벨 매핑
- `dev/lib/i18n/ja.js` / `dev/lib/i18n/ko.js` — 탭 라벨 키
- `dev/index.html` — 캠페인 목록 탭 UI
- sales 앱의 reviewer 카피 — `sales/index.html` 등

### 26.3 근거
- 커밋 `b0fa825` — `i18n(jp): replace 来店 with 訪問 and English "Reviewer" with レビュアー`
- 배경: 일본어 UI 일관성 — 한자 2자 통일 + 카타카나 음역 사용. 방문형이라도 "訪問"이 표준 표기

---

## 27. 관리자 공지사항 시스템 — 2026-04-22 (migration 063), 2026-04-27 draft/published 분리 (migration 071)

### 27.1 개요
관리자들 사이의 시스템 변경·긴급 경고·일반 안내를 앱 내에서 공유하는 공지 보드. 이메일/슬랙 의존 없이 관리자 페이지 접속 시 즉시 확인 가능. **2026-04-27부터 작성과 게시를 분리**해서 미완성 공지가 실수로 노출되는 사고 방지.

### 27.2 DB (§5.7 / §5.8)
- `admin_notices`: category/title/body_html/pin/created_by/* + **`status text NOT NULL DEFAULT 'draft' CHECK (draft|published)`·`published_at timestamptz`·`published_by uuid`·`published_by_name text` (migration 071)**
- `admin_notice_reads`: 관리자별 읽음 기록 UNIQUE(admin_id, notice_id)
- RPC: `upsert_admin_notice_read(p_notice_id)` — 한 건씩 read_at 기록
- **RLS SELECT (071 변경)**: `published OR is_super_admin() OR created_by=auth.uid()` — draft는 작성자 본인 + super_admin 만 조회 가능

### 27.3 사이드바 메뉴
- 사이드바 **최상단** "공지사항" 메뉴 (`/admin#admin-notices`)
- **미읽음 배지**: 본인 읽음 기록 차집합. 9+면 `9+` 표시 — **published만 카운트** (draft는 배지 미반영)
- 아이콘: Material Icon `campaign` (이모지 금지 — 2026-04-22 reviewer 지적으로 push_pin도 Material Icon으로 교체)

### 27.4 리스트 페인
- 필터: 카테고리(4종) + 핀 고정 여부 + **게시 상태 필터**(전체 / 게시 / 초안, 2026-04-27 추가) + 검색(제목·본문 plain text)
- 기본 default 필터: published만 (전체 토글 시 본인·super 조건 충족 draft도 노출)
- 정렬: 핀 고정 우선 → 최신순
- 각 행: 카테고리 pill / **게시 상태 배지(draft/published)** / 제목 / 작성자 / 작성일 / 읽음 체크 표시

### 27.5 편집 모달 (2026-04-27 모드별 푸터 버튼 분기)
- Quill rich text editor + **HTML source 토글** (raw HTML 직접 편집)
- 카테고리 라디오 4종 + 핀 체크박스
- XSS 방어: DOMPurify 저장+렌더 이중 sanitize
- **푸터 버튼 분기 (071)**:
  - **신규 / draft 편집 모드**: `[초안 저장]` (status='draft' 유지) / `[게시하기]` (status='published' + published_at/by 기록)
  - **published 편집 모드**: `[게시 유지하며 저장]` (status='published' 유지) / `[초안으로 되돌리고 저장]` (status='draft' 회귀, 안전 우선이라 메인)
- 재게시 시 `admin_notice_reads` 자동 리셋 안 함 — 미읽음 카운트는 **최초 published 시점** 기준

### 27.6 조회 모달 + 대시보드 카드
- 조회 모달: 카테고리 pill + 제목 + 작성자/일시 + body_html 렌더
- **푸터 버튼 (071)**: 작성자 본인 / super_admin 만 노출
  - draft 보기: `[지금 게시]` (status=published 전환)
  - published 보기: `[게시 회수]` (status=draft 회귀)
- 대시보드 최근 3건 카드 (`/admin#dashboard`) — **published 만 노출**
- 카드 갱신: 공지 등록·수정·게시 상태 변경 시 즉시 새로고침 (acec056)
- **로그인 시 미읽음 팝업**: 관리자 세션 복원 직후 `admin_notice_reads` 대비 미읽음 건 존재 시 모달로 강제 노출 — **published 만 카운트**
- **미읽음 팝업 UX (2026-04-27)**: "확인" 버튼 제거 → **"상세 보기" 단일 버튼**으로 통일. 상세 페이지 진입 시 자동 읽음 처리. 미읽음 항목에서 상세로 이동하는 버튼 추가

### 27.7 관련 슬래시 커맨드
- `/공지초안-관리자` (2026-04-22 신설, 마크다운 출력) — 최근 main 머지 or PR or 키워드 기반으로 공지 초안 자동 작성
- `/공지초안` (Deprecated, HTML/Quill 출력) — Markdown 붙여넣기가 깨질 때 폴백

---

## 28. 인플루언서 verify / violation / 블랙리스트 관리 — 2026-04-22 (migration 059~062)

### 28.1 개요
인플루언서를 공식 인증(verify), 반복 위반 기록(violation), 블랙리스트(blacklist) 3개 축으로 관리자 마킹하는 번들 기능. 신청 심사 시 참고 + 재승인 차단에 활용.

### 28.2 DB (§5.9)
- `influencer_flags` 이력 테이블 (action·reasons·memo·evidence_paths)
- `influencers` 파생 컬럼: `verified_at`, `blacklisted_at`, `blacklist_reasons text[]` 등 (059)
- 증빙 파일 버킷: `influencer-flag-evidence` (비공개, 10MB, image/PDF, 관리자 CRUD)
- 사유 lookup: `blacklist_reason` + `violation_reason` 2개 kind (시드)

### 28.3 RPC (8종)
- `set_influencer_verified(p_influencer_id, p_verified)` — 인증 토글
- `set_influencer_blacklist(p_influencer_id, p_reasons, p_memo, p_evidence_paths)` — 블랙 등록
- `set_influencer_blacklist` (clear) — p_reasons=null로 해제
- `record_influencer_violation(p_influencer_id, p_reasons, p_memo, p_evidence_paths)` — 위반 행 추가
- `update_influencer_violation(p_flag_id, p_reasons, p_memo, p_evidence_paths)` — 위반 행 편집 (061 신규)
- storage.js 래퍼: `setInfluencerVerified` / `setInfluencerBlacklist` / `recordInfluencerViolation` / `updateInfluencerViolation` / `fetchInfluencerFlags` / `fetchViolationCountsByInfluencer` / `fetchBlacklistReasons` / `fetchViolationReasons`

### 28.4 관리자 UI
- **인플루언서 목록 sticky-header 재구성**: 기존 SNS 탭 제거. 채널·인증·위반 드롭다운 3종 + 통합 검색(이름·이메일·IG/TT/X/YT 핸들) + 초기화
- **이름 옆 배지**: 블랙리스트일 땐 블랙 단독, 아니면 `인증 + 위반 N` (1 이상만 회색)
- **상세 화면 모달** (`influencerFullDetailModal`):
  - 상태 관리 카드: 인증 토글 / 위반 등록 / 블랙리스트 등록·해제 (한 모달에서 완결)
  - 관리자 이력 카드: 사유별 누적 pill + 타임라인 + 위반 행 `edit` 아이콘 → `influencerFlagEditModal`
  - 증빙 40×40 썸네일 렌더 + 클릭 시 라이트박스 확대
- **사유 풀**: `blacklist_reason ∪ violation_reason` 합집합을 체크박스로 노출, 라벨 조회는 두 lookup 모두 검색

### 28.5 증빙 파일 업로드 (062)
- 버킷 `influencer-flag-evidence` (비공개, 10MB, image/PDF)
- RPC `p_evidence_paths` 규칙: `null`=미변경, `[]`=전체 삭제, 배열=교체
- 관리자 signed URL로만 열람 (외부 공유 금지 — 만료됨)

---

## 29. 인프라 — Vercel Pro 업그레이드 (2026-04-22)

### 29.1 Hobby → Pro 전환 이유
- Hobby 100/day 일일 배포 한도 근접 회귀 발생 (dev/main 양 프로젝트 + preview + CLI 모두 같은 풀)
- 동시 빌드 1개 한도로 인한 Queue 경합 빈번 (reverb vs reverb-sales)
- Hobby는 Support 티켓 제출 불가 → 장애 대응 의존성

### 29.2 Pro 플랜 특성 (Team 기준)
- **일일 배포 한도**: 6,000개 (Hobby 100의 60배)
- **동시 빌드**: 복수 병렬 (경합 해소)
- **Fast Data Transfer**: 1 TB/월 (Hobby 100 GB 대비 10배)
- **Function Duration**: 1000 GB-Hrs/월
- **Edge Requests**: 10M/월
- **Preview Protection·Password Protection** 사용 가능
- Support 티켓 제출 가능

### 29.3 운영 영향
- 과거 "Queued 장기간"·"Disconnect/Reconnect 트리거" 재발 시 **다른 원인** 우선 의심 (브랜치 protection, CI 동시성, webhook 누락)
- Rolling window 한도는 동일 패턴이나 실질 발생 빈도 현저히 감소
- Token scope 규칙은 동일 (팀 범위, Full Account 금지)

### 29.4 문서 영향
- `~/.claude/CLAUDE.md` Hobby 섹션 → Pro 기준으로 교체
- `.claude/commands/배포진단.md` Step 3·5·문제 매트릭스의 Hobby 언급 Pro 기준 재작성

---

## 30. 캠페인 폼 날짜 입력 개편 — 2026-04-27 (PR #129, migration 072)

### 30.1 배경
이전 캠페인 등록·편집 폼은 단일 `<input type="date">` 4~6개(모집 마감·게시 마감·구매 시작·구매 종료·방문 시작·방문 종료)가 흩어져 있었음. 운영 측면 문제:
- 시작/종료가 분리돼 있어 관리자가 같은 기간을 두 번 입력
- 모집이 언제부터 노출될지 명시할 수 없어, 등록 즉시 노출 또는 status='scheduled' 수동 토글에 의존
- 의존관계 (구매·방문이 모집~제출 윈도우 안에 들어가야 함) 검증 없음
- 과거 날짜 입력 시 별도 토스트만 떠서 어느 행 문제인지 모호

### 30.2 변경 요약
| 항목 | 변경 전 | 변경 후 |
|---|---|---|
| 모집 시작일 | 없음 (등록 즉시 노출) | `recruit_start date NULL` 신규 (migration 072) |
| 모집 입력 | `deadline` 단일 | `recruit_start ~ deadline` flatpickr range |
| 게시 입력 | `post_deadline` 단일 | `post_deadline` 단일 (라벨만 정리, 미리보기 모달에서 행 제거) |
| 구매 입력 | `purchase_start` + `purchase_end` 2개 | `purchase_start~end` flatpickr range |
| 방문 입력 | `visit_start` + `visit_end` 2개 | `visit_start~end` flatpickr range |
| 결과물 마감 | 수동 입력 | 모집 종료일 선택 시 +14일 자동 제안 (수정 가능) |
| 의존관계 검증 | 없음 | 구매·방문 기간을 모집 시작 ~ 결과물 제출 마감 윈도우로 자동 clamp |
| 과거 날짜 경고 | 별도 토스트 | 캘린더 팝업 안 인라인, 행별 스코프 |
| 모집 타입·인원 | "모집 조건" 섹션 | "기본 정보" 섹션 (라벨 분리) |
| 카테고리 | "모집 조건" 섹션 | "기본 정보" 섹션 |
| 콘텐츠 종류 (monitor) | 모든 lookup 노출 | monitor 한정 영상/이미지 lookup만 자동 필터링 |

### 30.3 자동 상태 전환
- `autoOpenCampaigns()` 신규 — `autoCloseCampaigns()` 미러링
- scheduled 상태 캠페인의 `recruit_start <= now()` 이면 active 로 flip
- `fetchCampaigns` 호출 시 `autoOpenCampaigns()` → `autoCloseCampaigns()` 순차 실행 — 시작·종료를 한 번에 처리해서 deadline 이미 지난 캠페인은 active로 잠시도 안 가고 바로 closed

### 30.4 flatpickr 사용
- ko locale, `dateFormat: 'Y-m-d'`, `mode: 'range'`
- onChange 핸들러로 원본 hidden input(`recruit_start`/`deadline`/`purchase_start`/...)에 sync
- sticky popup (스크롤해도 picker가 따라가지 않음 — 행 옆에 고정)
- 행마다 별도 플래그(`data-warned`)로 과거 시작일 경고 1회만 표시

### 30.5 monitor 한정 콘텐츠 종류 필터링
- `renderContentTypeCheckboxes(recruitType)` 시그니처 추가
- `recruitType === 'monitor'` 일 때 영상/이미지 lookup 코드만 필터
- `filterChannelsByRecruitType()` 가 콘텐츠 리스트도 재렌더 — 모집 타입 변경(monitor → gifting/visit) 시 전체 lookup 복원
- monitor가 기존 저장된 `content_types` 코드를 자동으로 제거하면 `console.warn` 으로 dropped 라벨 출력 (dev 환경에서 가시성 확보)

### 30.6 기존 행 호환
- `recruit_start IS NULL` 행은 인플루언서 화면에서 종전대로 "오늘 ~ deadline" 으로 폴백 렌더
- 자동 시작 트리거 대상이 아니므로(NULL 비교) 기존 active/scheduled 캠페인 status 변동 없음
- 신규 등록부터 채워주면 됨 (관리자 가이드)

### 30.7 영향 파일
- `supabase/migrations/072_*.sql` — `ALTER TABLE campaigns ADD COLUMN recruit_start date NULL`
- `dev/admin/index.html` — 폼 마크업 (3개 .fp-range input + 섹션 재구성)
- `dev/js/admin.js` — flatpickr init, range sync, clamp, monitor 필터, 자동 시작 호출
- `dev/lib/storage.js` — `fetchCampaigns` 가 `autoOpenCampaigns` 호출 추가
- `dev/css/admin.css` — flatpickr 스타일 + 캘린더 팝업 인라인 경고

### 30.8 근거
- PR #129 (11개 커밋) — `b3b8d19` ~ `721ecaa` (2026-04-27)
- migration 072 — `recruit_start` 컬럼 추가

---

## 31. 캠페인 상태 도움말 모달 — 2026-04-30 (cdaa146)

### 31.1 배경
- 캠페인 관리 표 헤더 「상태」 컬럼이 5단계(`draft`/`scheduled`/`active`/`paused`/`closed`)인데, 상태별 의미와 자동 전이 규칙(예: `recruit_start` 도래 시 `scheduled→active`, `deadline` 경과 시 `active→closed`)을 담당자가 헷갈려 함
- 관리자 사이트에 별도 도움말 페이지 없이 표 안에서 즉시 조회 가능해야 함

### 31.2 UI
- 캠페인 관리 표 헤더의 「상태」 라벨 옆에 `info` Material Icon (translate="no")
- 클릭 시 모달 오픈 — 5단계 각각 라벨/색상 배지 + 의미 1문장 + 자동 전이 규칙 설명
- 모달 내 "닫기" 버튼 + 외부 영역 클릭/ESC로 닫기

### 31.3 영향 파일
- `dev/admin/index.html` — 헤더 ⓘ 마크업 + 모달 마크업
- `dev/js/admin.js` — 클릭 핸들러
- `dev/css/admin.css` — 모달 스타일

---

## 32. 캠페인·신청·결과물 표 brand_ko/product_ko 컬럼 분리 — 2026-04-30

### 32.1 배경
- 기존에 캠페인 표에 단일 "브랜드/상품" 라인 한 줄로 표시했음
- 검색·정렬·필터 시 브랜드명만으로 좁히고 싶거나 상품명만으로 좁히고 싶은 운영 요청 다수

### 32.2 변경 요약
- 캠페인 관리·신청 관리·캠페인별 신청자 페인 표가 `brand_ko`(브랜드 한국어명)·`product_ko`(상품 한국어명) **별도 컬럼**으로 분리
- 검색창은 캠페인명·`brand_ko`·`product_ko` 모두 매칭
- 컬럼 폭은 다른 컬럼이 좁아지지 않게 일정 너비 캡 적용 (CSS `max-width` + `text-overflow: ellipsis`)
- dynamic thead (필터 조합에 따라 컬럼 토글)도 분리 컬럼 기준으로 갱신

### 32.3 영향 파일
- `dev/admin/index.html` — 표 마크업 컬럼 분할
- `dev/js/admin.js` — `renderCampList` / `renderAppCampList` / `renderApplications` / `renderDeliverables` 컬럼 빌더
- `dev/css/admin.css` — 컬럼 너비 캡

### 32.4 근거
- 02c432f / 56dcfd4 / 231a638 / b56faf5 / 2d23eea / 4496cf2 (2026-04-29~30)

---

## 33. 민감 항목 변경 잠금 + 경고 모달 — 2026-04-29 (운영: migration 075 + d79ad39 / [dev 검증 중] migration 077)

### 33.1 배경
- 캠페인 등록 후 신청자가 들어온 상태에서 `caution_items`(주의사항)·`participation_steps`(참여방법) 같은 민감 항목을 관리자가 수정하면 이미 동의·신청한 인플루언서에게 영향 가능
- 변경 추적이 없어서 누가 언제 어느 필드를 어떻게 바꿨는지 사후 확인 불가

### 33.2 경고 모달 (`#sensitiveChangeModal`) — 운영
- 캠페인 편집 폼에서 `caution_items` / `participation_steps` 변경 감지 시 저장 직전 모달 노출
- 모달 본문: 변경 항목 요약 + "신청자에게 영향이 있을 수 있습니다" 경고 + "계속 저장" / "취소" 버튼
- dev 소스에 정식 마크업 연결 (이전: 일부 환경에서 모달이 누락된 채 저장 진행)

### 33.3 잠금 (migration 075) — 운영
- closed 캠페인의 `caution_items`/`participation_steps` 변경을 데이터베이스 트리거로 차단 (closed 상태 진입 후에는 수정 불가, 새로 캠페인 만들어야 함)
- 활성·일시정지 캠페인은 §33.2 모달 통과로 변경 가능

### 33.4 [dev 검증 중] audit 테이블 — `campaign_caution_history` (migration 077, 운영 미배포)
- 운영은 잠금(075)·모달(d79ad39)까지 적용 + audit 테이블은 dev 한정 (자세한 스키마는 §5.11 참조)
- INSERT는 `record_caution_history()` 원격 호출 함수(RPC) 경유 (수동 INSERT 차단)
- SELECT는 `is_super_admin()` 행 단위 보안 정책(RLS) — 일반 admin·인플루언서 모두 비공개

### 33.5 영향 파일
- `supabase/migrations/075_lock_caution_participation_on_closed.sql` — closed 캠페인 잠금 트리거 (운영)
- `dev/admin/index.html` — `#sensitiveChangeModal` 마크업 (운영)
- `dev/js/admin.js` — 변경 감지 + 모달 호출 (운영)
- `supabase/migrations/077_campaign_caution_history.sql` — audit 테이블 + RPC ([dev 검증 중])

---

## 34. 참여방법/주의사항 편집 모달 분리 — 2026-04-26 (eb78c98 / c5e2cef / 6be9c19)

### 34.1 배경
- 기존: 캠페인 폼 내부에 참여방법·주의사항 편집 영역이 inline 으로 펼쳐짐 → 폼이 길어지고 스크롤 깊이가 깊어짐
- bundle summary 카드의 다국어(한·일) 표시가 일부만 노출되어 가독성 떨어짐
- 미리보기에서 `注意事項` 한·일 토글 부재

### 34.2 변경
- 참여방법·주의사항 편집 영역을 캠페인 폼 외부 모달로 분리
- 카드 헤더에 「편집」 버튼 1개로 정리 (이전: inline 토글)
- bundle summary 카드는 한·일 양언어 풀 노출 + 카드 헤더 정렬 일관화
- 미리보기 모달에 `注意事項` 한·일 토글 버튼 추가 (다국어 대응 §21 연장선)

### 34.3 영향 파일
- `dev/admin/index.html` — 모달 마크업, 카드 헤더
- `dev/js/admin.js` — 모달 open/close, bundle summary 렌더
- `dev/css/admin.css` — 모달·카드 스타일

---

## 35. 결과물 영수증 구매정보 관리자 화면 마스킹 — 2026-04-30 (0d2b599)

### 35.1 배경
- 인플루언서가 결과물(영수증) 제출 시 입력하는 `purchase_date`(구매일)·`purchase_amount`(구매금액)는 인플루언서 자기 거래 정보
- 관리자 검수에는 영수증 이미지 자체와 캠페인 적합성만 필요. 구매일·구매금액은 검수에 본질적이지 않음
- 개인정보 최소 노출 정책 (PROJECT_CONTEXT §2-1)

### 35.2 변경
- 관리자 결과물 검수 모달에서 `purchase_date`/`purchase_amount` 표시 라인 제거
- 인플루언서 본인 화면(재제출 폼)에서는 그대로 유지 — 본인은 자기 정보 보고 수정 가능
- DB 컬럼 자체는 보존 (다른 분석·정산 용도 가능성)

### 35.3 영향 파일
- `dev/js/admin.js` — `renderDeliverableModal` 영수증 영역 표시 라인 제거

---

## 36. 결정 이벤트 트리거 양방향 허용 — 2026-04-26 (aea3d7f)

### 36.1 배경
- `record_deliverable_status_event` 트리거가 `pending → draft` 단방향 전이만 허용했음 (이전 의도: 일단 검수 대기 큐에 들어간 결과물은 임시저장으로 되돌릴 수 없음)
- 실제 운영에서 인플루언서가 `pending` 제출 후 본인 실수로 `draft` 로 되돌려 재편집하고 싶은 사례 발생 → 막혀서 운영팀이 수동 우회 처리

### 36.2 변경
- 트리거 조건 보강: `draft↔pending` **양방향** 모두 정상 전이로 인정
- 다른 상태 전이(approved/rejected) 정합성 검사는 그대로 유지

### 36.3 영향 파일
- `supabase/migrations/aea3d7f` 또는 인라인 패치 — 트리거 함수 재정의

---

## 37. 사이드바 결과물 관리 메뉴 pending 배지 — 2026-04-26 (e53a522)

### 37.1 배경
- 사이드바의 「결과물 관리」 메뉴에서 검수 대기 결과물(pending)이 몇 건인지 확인하려면 페인을 열어야 했음
- 인플루언서 알림 배지(햄버거 ☰)와 동일한 시각 패턴으로 통일

### 37.2 변경
- 사이드바 「결과물 관리」 메뉴 라벨 옆에 pending 결과물 건수 배지 표시
- 9+ 처리 (10건 이상이면 "9+")
- `fetchPendingDeliverableCount()` 함수로 카운트 조회 → 인플루언서 빌드에도 동일 함수 포함 (b1937c9)

### 37.3 영향 파일
- `dev/admin/index.html` — 메뉴 마크업에 배지 span
- `dev/js/admin.js` — 카운트 페치 + 배지 갱신
- `dev/lib/storage.js` — `fetchPendingDeliverableCount` 추가

---

## 38. 주의사항 번들 (caution_sets) — 2026-04-23 (migration 069)

### 38.1 개요
- 캠페인별로 「PR 태그 의무, 네거티브 리뷰 금지, 일본 내 배송지 한정, 게시 기한 준수, 게시물 3개월 유지」 같은 주의사항을 일관되게 표시·동의받기 위해 번들 시스템 도입
- 참여방법 번들(`participation_sets`, §18) 패턴 완전 미러링

### 38.2 데이터 모델 (`caution_sets`)
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid PK | 자동 생성 |
| name_ko / name_ja | text | 번들 이름 (한·일) |
| recruit_types | text[] | 모집 타입 태깅 (`monitor`/`gifting`/`visit`) — 캠페인 폼 드롭다운 필터 |
| items | jsonb | 본문 항목 배열 — `[{text_ko, text_ja, link_url?, link_label_ko?, link_label_ja?, text_after_ko?, text_after_ja?}, ...]` |
| sort_order | integer | 표시 순서 |
| active | boolean | 활성/비활성 토글 |
| created_at, updated_at | timestamptz | 표준 |

### 38.3 스냅샷 원칙
- 캠페인 저장 시 `caution_sets.items` → `campaigns.caution_items` jsonb 통째 복사
- `campaigns.caution_set_id` 외래 키(FK) ON DELETE SET NULL — 번들 삭제해도 캠페인 스냅샷 유지
- 번들 수정 시 기존 캠페인 스냅샷은 변경되지 않음 (사후 분쟁 방지)

### 38.4 관리자 UI
- `/admin#lookups` → 「주의사항」 탭 (campaign_admin 이상)
- 번들 CRUD + 순서 변경 모드 + 활성 토글
- 캠페인 등록/편집 폼 콘텐츠 가이드 섹션 하단에 "주의사항" 영역 — 번들 드롭다운(`recruit_type` 필터, 빈 `recruit_types[]` 번들은 모든 타입에 노출) + "번들 다시 불러오기" 버튼 + 인라인 items 편집(본문 한·일, 선택적 링크 — 5-button mini editor) — §34에서 별도 모달로 분리됨

### 38.5 미니 에디터 (link bubble popover)
- 본문 한·일 입력은 미니 리치 에디터(5-button: bold/italic/link-add/list/clear) — 링크 바늘 popover로 URL·라벨 입력
- 이미지 태그는 저장 시 제거 (base64 폭증 방지)
- DOMPurify 저장+렌더 이중 sanitize

### 38.6 행 단위 보안 정책(RLS)
- SELECT 관리자(`is_admin()`) 한정 — 인플루언서는 `campaigns.caution_items` 스냅샷 경유로만 노출
- INSERT/UPDATE/DELETE는 `campaign_admin` 이상

### 38.7 마이그레이션·시드
- migration 069 (`069_create_caution_sets.sql`) — 테이블 + RLS + 기본 시드 5건
- 기본 시드 키: `pr_tag_required` / `no_negative_review` / `delivery_address_jp_only` / `post_within_deadline` / `keep_post_3months`
- 067의 lookup `kind='caution'` 5건은 069 도입 후 미참조 (추후 마이그레이션에서 정리 예정)

---

## 39. 캠페인 신청 주의사항 동의 — 2026-04-23 (migration 067·069, PR #124)

### 39.1 개요
- 인플루언서가 캠페인 신청 시 캠페인의 주의사항(`caution_items`)에 동의해야 신청 완료
- 동의 시각·내용을 신청 데이터에 저장 (사후 분쟁 시 증거)
- 일본 스테스 마케팅 규제(소비자청 가이드라인) 대응 강화

### 39.2 인플루언서 화면
- 캠페인의 `caution_items`가 있으면 ① 캠페인 상세 「주의 사항」 섹션과 ② 신청 모달 상단 빨간 박스 양쪽에 렌더
- 신청 모달 하단 단일 체크박스 「全ての注意事項を確認しました」 (한국어 토글 시 "모든 주의사항을 확인했습니다") + 미체크 시 신청 차단
- 응모이력 항목에 동의 시각 작은 배지 노출

### 39.3 동의 데이터 저장 (§5.3 applications)
- `caution_agreed_at timestamptz NULL` — 동의 시각
- `caution_snapshot jsonb NULL` v2 구조: `{version:2, campaign_id, set_id, items, agreed_lang, snapshot_at}`
- v1 구조(`{version:1, lookup_codes, labels, custom_html, ...}`) 스냅샷도 관리자 뷰어에서 하위호환

### 39.4 관리자 화면
- 신청 행 메시지 셀에 「주의사항 동의 ✓ {시각}」 작은 배지 (`msgCell` 헬퍼)
- 배지 클릭 시 v1/v2 분기 스냅샷 모달 — 캠페인 신청 관리·캠페인별 신청자·대시보드 최근 신청 3개 페인 자동 적용

### 39.5 영향 파일
- `supabase/migrations/067_caution_consent.sql` — `applications.caution_agreed_at`/`caution_snapshot` 컬럼 추가 + v1 lookup 시드
- `supabase/migrations/069_create_caution_sets.sql` — `caution_sets` 테이블 + `campaigns.caution_set_id`/`caution_items`
- `dev/js/application.js` — 신청 모달 주의사항 박스 + 체크박스 + 동의 저장
- `dev/js/campaign.js` — 캠페인 상세 「주의 사항」 섹션
- `dev/js/admin.js` — 신청 행 동의 배지 + 스냅샷 모달

### 39.6 약관·개인정보처리방침 영향
- 동의 시각·스냅샷은 인플루언서 활동 로그 — 신청 기록 보유 기간과 동일(탈퇴 시 파기)
- PRIVACY §2.1 회원정보 표에 「캠페인 신청 시 주의사항 동의 시각·스냅샷」 1행 추가
- TERMS 본문에는 명시적 보강 불필요 (캠페인 가이드라인 준수 의무 조항으로 이미 커버)
