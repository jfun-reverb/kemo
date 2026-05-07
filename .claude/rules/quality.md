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

## 관리자 모달 페인 갱신 (필수)
- 관리자 페이지에서 **수정·편집·삭제·토글** 동작이 가능한 모달의 저장 함수는 끝에서 반드시 해당 페인 목록·집계를 다시 그려야 한다.
- `dev/lib/shared.js`의 공통 헬퍼 **`refreshPane(paneId)`** 사용. 페인 ID(`influencers` / `brand-applications` / `admin-notices` / `lookups` / `admin-accounts` / `camp-applicants` / `deliverables` / `campaigns`)와 갱신 함수 매핑은 `PANE_REFRESHERS`에 등록되어 있다.
- 새 페인을 만들면 `PANE_REFRESHERS`에 한 행 추가 + 모든 신규 모달 저장 함수에 `await refreshPane(...)` 호출 한 줄 추가.
- 직접 `loadXxx()` / `renderXxx()` 호출도 허용하지만, 새 모달이 생길 때마다 누락 패턴이 반복되었으므로 신규 코드는 헬퍼를 우선한다.
- reverb-reviewer 에이전트는 모달 저장 함수에 `refreshPane` 또는 동등한 list 재렌더 호출 누락 여부를 체크한다.

**Why:** 모달이 닫혀도 뒤의 목록·배지가 stale 상태로 남아 「방금 변경한 게 안 보이는」 사용자 보고가 반복 발생. 헬퍼 통일로 회귀 방지.
