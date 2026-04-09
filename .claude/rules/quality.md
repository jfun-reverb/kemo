---
description: 프로젝트별 코드 품질 규칙
globs: "dev/**/*.js,dev/**/*.css,dev/**/*.html"
---

# 프로젝트 코드 규칙

## 코드 중복
- UI 유틸리티: dev/js/ui.js에 추가 (toast, formatDate, esc 등)
- DB 함수: dev/lib/storage.js에 추가
- 전역 상태: dev/lib/shared.js에 추가

## 네이밍
- 함수명: camelCase (fetchCampaigns, renderCampaignCard)
- CSS 클래스: kebab-case (campaign-card, bottom-tab)
- ID: camelCase 또는 kebab-case (page-home, #appShell)
- 상수: UPPER_SNAKE_CASE (SUPABASE_URL, ADMIN_EMAIL)
