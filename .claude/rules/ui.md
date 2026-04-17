---
description: UI 레이아웃 및 일본어 규칙
globs: "dev/**/*.html,dev/css/*.css,dev/js/*.js"
---

# UI/레이아웃 규칙

## 레이아웃 분리 (절대 혼동 금지)
- **인플루언서 페이지** (dev/index.html): 모바일 전용 max-width 480px, #appShell 내부, GNB + 우측 슬라이드 햄버거 메뉴
- **관리자 페이지** (dev/admin/index.html): PC 전체폭, #appShell 밖, 사이드바 네비게이션
- 관리자 페이지에 모바일 쉘 절대 적용 금지
- 인플루언서 페이지에 PC 전체폭 레이아웃 절대 적용 금지
- 바텀탭은 제거됨 (2026-04 햄버거 메뉴로 대체, 키보드 간섭 제거 목적)

## 인플루언서 앱 구조
- SPA 라우팅: `navigate()` 함수로 페이지 전환 (dev/js/app.js)
- 페이지: #page-home, #page-campaigns, #page-legal, #page-detail, #page-activity, #page-login, #page-forgot, #page-reset-pw, #page-signup, #page-mypage
- GNB: 상단 네비게이션 (로그인/회원가입 버튼 + 우측 햄버거 ☰)
- 햄버거 메뉴 패널(#navPanel, 렌더: `renderNavMenu()` in dev/js/notifications.js)
  - 헤더: Admin 버튼(관리자만) + 언어 토글(日本語/한국어) + 닫기
  - 로그인 시: 홈 / 캠페인 / 마이페이지 + 서브메뉴 6종(응모이력·기본정보·SNS·배송지·PayPal·비밀번호) / 알림(배지) / 로그아웃
  - 비로그인 시: 홈 / 캠페인 / 로그인 / 회원가입

## 관리자 앱 구조
- 2단 고정 레이아웃: 좌측 사이드바 + 우측 메인 (각각 독립 스크롤, 상단 GNB 없음)
- 사이드바 상단: Reverb 로고 + 접기 토글
- 사이드바 메뉴 영역: 대시보드 → 캠페인(관리/신청/결과물) → 회원관리(인플루언서) → 관리자설정(기준데이터[super_admin 한정]/관리자계정) → 접속자 프로필(#sidebarAdminProfile → my-account)
- 사이드바 하단(border-top 구분): 인플루언서 화면 / 로그아웃 (2개만)
- 관리자 페인: #adminPane-dashboard, #adminPane-campaigns 등 (add-campaign/edit-campaign은 서브 페인)
- **목록 페인 (campaigns/applications/deliverables)**: `admin-pane-list` 클래스 사용. flex column 구조로 제목+필터 고정, 카드 헤더 고정, thead sticky, tbody만 스크롤
- **목록 페인 HTML 구조 통일 필수**: 3개 페인의 HTML 구조(admin-sticky-header → admin-card → admin-card-header → admin-table-wrap → table)가 반드시 동일해야 함. 래퍼 div 추가/제거 시 3개 모두 확인

## UI 텍스트 언어 규칙
- 인플루언서 페이지: 일본어 (한국어/영어 금지)
- 관리자 페이지: 한국어 (일본어/영어 금지)
- 코드 주석: 한국어 (일본어 금지)
- HTML lang="ja" 유지
- 날짜 포맷: `ja-JP` 로케일 사용
- 상태 표시 예시: 募集中(active), 準備中(draft), 近日公開(scheduled), 締切(closed)

## 아이콘 규칙
- 이모지 사용 금지 — OS별로 다르게 보이므로 Material Icons Round 사용
- 아이콘에는 반드시 `translate="no"` + `notranslate` 클래스 추가 (브라우저 번역 시 깨짐 방지)
- 예시: `<span class="material-icons-round notranslate" translate="no">icon_name</span>`
- 토스트 메시지에 이모지/아이콘 넣지 않기 (텍스트만)
- DB에 저장된 emoji 필드(캠페인 카테고리 등)는 예외로 허용

## CSS 파일 대응
- 공통 스타일: dev/css/base.css (변수, 리셋), dev/css/components.css (버튼, 카드, 모달)
- 기능별 스타일: campaign.css, auth.css, mypage.css
- 관리자 전용: dev/css/admin.css
- 새 CSS 추가 시 build.sh에 파일 등록 필요
