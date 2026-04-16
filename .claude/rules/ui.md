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
- 페이지: #page-home, #page-campaigns, #page-detail, #page-login, #page-signup, #page-mypage
- GNB: 상단 네비게이션 (로그인/회원가입 버튼 + 우측 햄버거 ☰)
- 햄버거 메뉴 항목: 홈 / 캠페인 / 마이페이지 / 알림(배지) / 로그아웃 (비로그인은 로그인·회원가입)

## 관리자 앱 구조
- 사이드바 네비게이션: dashboard/campaigns/applications/deliverables/influencers/lookups(super_admin 한정)/admin-accounts/my-account (신규등록 메뉴는 제거 — `+ 신규 캠페인` 버튼으로만 진입)
- 관리자 페인: #pane-dashboard, #pane-campaigns 등 (add-campaign/edit-campaign은 서브 페인)
- 고정 헤더: 다크 배경 (#2D1F2B), 로고, 관리자 정보, 로그아웃

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
