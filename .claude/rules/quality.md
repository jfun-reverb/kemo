---
description: 코드 품질 가드레일
globs: "dev/**/*.js,dev/**/*.css,dev/**/*.html"
---

# 품질 규칙

## 디버그/불필요 코드
- 커밋 전 console.log, console.error, debugger, alert 모두 제거
- 주석 처리된 코드 블록 남기지 않기
- TODO 주석은 구체적인 설명 필수 (예: `// TODO: RLS정책 추가 필요`)

## 함수/구조
- 함수는 50줄 이하로 유지; 초과 시 분리
- 깊은 중첩 최대 3단계; 조기 반환(early return) 사용
- 에러를 조용히 무시하지 않기; try-catch에서 최소한 console.error 또는 showToast로 사용자 알림

## 코드 중복
- 3회 이상 사용되는 로직은 공통 함수로 분리
- UI 유틸리티: dev/js/ui.js에 추가 (showToast, showModal, formatDate 등)
- DB 함수: dev/lib/storage.js에 추가
- 전역 상태: dev/lib/shared.js에 추가

## 하드코딩 금지
- DOM 인덱스(`querySelectorAll()[N]`) 사용 금지; 이름/ID/속성 기반으로 요소를 찾을 것
- 사이드바/탭 전환 시 `switchAdminPane('pane', null)`처럼 pane 이름만 전달, 함수 내부에서 자동 매핑
- 매직 넘버(의미 없는 숫자) 대신 의미 있는 변수명이나 매핑 객체 사용

## 네이밍
- 함수명: camelCase (fetchCampaigns, renderCampaignCard)
- CSS 클래스: kebab-case (campaign-card, bottom-tab)
- ID: camelCase 또는 kebab-case (page-home, #appShell)
- 상수: UPPER_SNAKE_CASE (SUPABASE_URL, ADMIN_EMAIL)
