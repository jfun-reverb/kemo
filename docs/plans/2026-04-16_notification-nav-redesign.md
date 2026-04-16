# 인플루언서 앱 네비게이션 재편 + 알림 UI 구현 계획

> **Date**: 2026-04-16
> **Status**: 기획 확정, 다른 세션에서 Step 1부터 구현 예정
> **DB 변경**: 없음 (037_create_notifications 이미 적용됨)

---

## 1. 요구사항

- 인플루언서 모바일 앱의 **바텀탭 제거** (마이페이지 입력폼에서 키보드 올라올 때 입력 영역 확보 목적)
- **상단 GNB**에 햄버거 메뉴로 메뉴 이전
- **알림 기능 추가** (결과물 관련 3종: deliverable_rejected / deliverable_changed / deliverable_approved)
- 알림 읽음 처리: 클릭 시 자동 읽음

## 2. 확정 설계

### 2-1. GNB 구조 (56px, 높이 유지)
```
┌────────────────────────────────────────────┐
│ [REVERB]                 Admin  ☰³ │   ← 햄버거에 숫자 배지
└────────────────────────────────────────────┘
```
- 좌측: 로고
- 우측: Admin 버튼(관리자만) + 햄버거 아이콘 + 미읽음 숫자 배지(10+는 `9+`)
- 비로그인 시: 로그인/회원가입 버튼은 햄버거 메뉴 패널 내부로 이동 (또는 GNB 우측 유지 — Step 7에서 결정)

### 2-2. 햄버거 메뉴 패널 (우측 슬라이드)
```
┌────────────────────────────────────────────┐
│  ホーム                                    │
│  キャンペーン                               │
│  マイページ                                │
│  通知                                3 ● │   ← 알림 항목에도 배지
│  ログアウト                                │
└────────────────────────────────────────────┘
```
- 각 메뉴 클릭 → 해당 페이지 이동 + 패널 자동 닫힘
- 알림 배지: 미읽음 0건이면 숨김

### 2-3. 알림 슬라이드업 모달
- `通知` 메뉴 클릭 → 하단→상단 풀스크린 모달 오픈
- 리스트: 제목 / 본문 / 시각 / 종류별 아이콘·색상
- 항목 클릭 → `markNotificationRead()` + 해당 활동관리 화면으로 이동 + 모달 닫기
- 상단 "모두 읽음" 버튼 (미읽음 0건이면 비활성)
- 빈 상태: 일러스트 + "未読の通知はありません"
- limit 30건 (무한스크롤 생략)

### 2-4. 엣지 케이스
- **비로그인**: 햄버거 메뉴 패널에 로그인/회원가입 항목만 표시 (홈/캠페인은 GNB 좌측 로고 클릭 또는 메뉴 유지 판단 Step 7)
- **관리자 로그인**: 알림 아이콘 배지 숨김 (관리자는 인플루언서 알림 수신 안 함)
- **로그아웃**: 배지·메뉴 즉시 갱신
- **인증 화면** (login/signup/forgot/reset-pw): 햄버거 숨김 (로고만 유지)
- **다중 탭**: 모달 오픈 시마다 재fetch (실시간 동기화는 생략)
- **네트워크 실패**: 배지 미표시 (조용히 실패)
- **iOS 노치**: `padding-top: env(safe-area-inset-top)` 적용

## 3. 영향 파일

### 수정
- `dev/index.html` — GNB 구조 재작성, 바텀탭 제거, 햄버거 패널 + 알림 모달 DOM 추가
- `dev/css/base.css` — `--tab-h: 0` 또는 변수 제거
- `dev/css/components.css` — 바텀탭 스타일 제거, GNB/햄버거/메뉴 패널/알림 모달 스타일 추가
- `dev/css/campaign.css` — `calc(var(--tab-h) + ...)` 수정
- `dev/css/mypage.css` — 동일, 알림섹션 스타일 제거
- `dev/js/app.js` — navigateTab/updateTabBar 제거, `updateActiveNav(page)` 신규, 인증 페이지 햄버거 숨김 로직
- `dev/js/auth.js` — `updateGnb()` 확장 (햄버거·배지 렌더)
- `dev/js/mypage.js` — `mypageNotifSection` 제거, 알림 렌더 로직을 `notifications.js`로 이관
- `dev/lib/i18n/{ja,ko}.js` — `menu.*` 키 추가 (개발서버 한정)
- `dev/build.sh` — 신규 JS 파일 등록

### 신규
- `dev/js/notifications.js` — 모달 오픈/렌더/읽음 처리 로직 분리
- (옵션) `dev/css/notifications.css` — components.css에 병합 가능

### DB
- 변경 없음. `notifications` 테이블 + RLS + 트리거 완료, `storage.js`에 `fetchMyNotifications` / `markNotificationRead` / `markAllNotificationsRead` 이미 존재

## 4. 구현 순서 (8 Step, 각 Step 단위 검증 권장)

### Step 1. CSS 변수 완화
- `--tab-h: 64px` → `0` 로 변경
- 의존처 (`campaign.css`, `mypage.css`, `components.css`의 footer/detailFloatBar/legal-page-body)에서 padding 정상 계산 확인
- 빌드 → 개발서버 시각 확인

### Step 2. 바텀탭 DOM/JS 제거
- `index.html` L862~874 `.bottom-tab` `<nav>` 삭제
- `app.js` L59~63, L90~100 `navigateTab` / `updateTabBar` / tabBar 숨김 로직 제거
- `auth.js` `updateGnb()`의 `tabMypage` 참조 제거
- grep: `bottom-tab`, `tab-item`, `tabBar`, `navigateTab`, `updateTabBar` 잔존 참조 0건 확인

### Step 3. GNB 햄버거 + 우측 슬라이드 메뉴 패널
- GNB 우측에 `☰` 버튼 추가
- `<aside id="navPanel">` DOM 추가 (우측 슬라이드)
- 메뉴 항목: ホーム / キャンペーン / マイページ / 通知 / ログアウト
- 각 항목 클릭 → `navigate()` + 패널 닫기
- 활성 페이지 하이라이트 (`updateActiveNav` 함수)
- 비로그인/관리자 분기

### Step 4. 햄버거 배지 (미읽음 카운트)
- `refreshNotifBadge()` 함수 신규 (`dev/js/notifications.js`)
- 호출 시점: `onAuthStateChange` (SIGNED_IN), 페이지 전환, 모달 오픈·닫기
- 배지 DOM: `<span class="notif-badge">3</span>` (미읽음 0건 시 `.hidden`)
- 메뉴 패널 내 `通知` 항목 옆에도 동일 배지

### Step 5. 알림 슬라이드업 모달
- `<section id="notifModal">` DOM 추가 (bottom-sheet 스타일)
- `openNotifModal()` / `closeNotifModal()` 구현
- 목록 렌더: 기존 `loadMypageNotifications` 로직 이식
- 항목 클릭: `markNotificationRead(id)` + 이동 처리
- "모두 읽음" 버튼: `markAllNotificationsRead()`
- 빈 상태 UI

### Step 6. 마이페이지 알림섹션 제거
- `mypageNotifSection` DOM 제거
- `loadMypageNotifications` 호출처 정리 (mypage.js → notifications.js 이관)
- 마이페이지 상단 여백 조정

### Step 7. 엣지 케이스 보정
- 인증 페이지에서 햄버거 숨김
- `env(safe-area-inset-top)` 적용 확인
- 관리자 계정에서 알림 배지·메뉴 숨김
- 비로그인 메뉴 패널 항목 결정 (로그인/회원가입만? 홈/캠페인도?)
- 로그아웃 후 배지 즉시 사라지는지 확인
- iOS Safari 실기 확인

### Step 8. 빌드·배포
- `cd dev && bash build.sh`
- 개발서버 푸시 → qa-tester 회귀 → dev → main PR
- i18n 키 추가분은 개발서버 한정이므로 cherry-pick 여부 확인

## 5. 검증 시나리오 (Step 7~8 사이)

1. [ ] 비로그인 홈 접속 → 로고 + 햄버거 (메뉴 패널 내 로그인/가입)
2. [ ] 로그인 → 햄버거에 배지(숫자) 노출
3. [ ] 햄버거 클릭 → 우측 슬라이드 패널 오픈
4. [ ] 패널에서 ホーム/キャンペーン/マイページ 전환 정상
5. [ ] 패널 `通知` 항목 옆에도 배지 표시
6. [ ] 알림 모달 오픈 → 3건 렌더 (rejected/changed/approved 아이콘 구분)
7. [ ] 알림 클릭 → 읽음 처리 + 활동관리로 이동 + 배지 카운트 -1
8. [ ] "모두 읽음" → 배지 0 + 숨김
9. [ ] 알림 0건 상태 → 빈 상태 UI
10. [ ] 캠페인 상세 진입·뒤로가기 정상
11. [ ] 마이페이지 입력폼 포커스 → 키보드 올라왔을 때 입력 영역 확장 확인
12. [ ] 관리자 계정 로그인 → 알림 배지·메뉴 숨김, Admin 버튼만
13. [ ] 인증 화면(login/signup/forgot/reset-pw)에서 햄버거 숨김
14. [ ] iOS Safari safe-area 상단 여백 정상
15. [ ] 로그아웃 즉시 배지·메뉴 갱신

## 6. 리스크

- `--tab-h` 의존처 누락 시 바닥 여백이 남거나 콘텐츠 가림
- 캠페인 상세의 `#detailFloatBar` `bottom: var(--tab-h)` → `bottom: 0`으로 바뀌면 터치 오입력 위험 → 실기 확인 필요
- 비로그인 메뉴 패널 UX 미확정 (Step 7에서 최종 결정)
- i18n 키 추가는 main 머지 대상 아닌지 확인 (dev 한정 기능)

## 7. 필수 에이전트 호출

- `reverb-reviewer` — commit 직전
- `reverb-qa-tester` — 배포 전 E2E
- `reverb-supabase-expert` — DB 변경 없으므로 생략

## 8. 다음 세션 시작 방법

```
docs/plans/2026-04-16_notification-nav-redesign.md 계획대로 Step 1부터 구현 시작해줘
```

또는 특정 Step만:
```
docs/plans/2026-04-16_notification-nav-redesign.md §4 Step 3만 먼저 진행
```
