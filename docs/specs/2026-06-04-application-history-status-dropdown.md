# 인플루언서 응모이력 — 상태 필터 드롭다운화 + 「진행중」 기본 표시

**작성일:** 2026-06-04
**작성 세션:** 기획/설계
**상태:** 초안 (사용자 정책 확정, 개발 미착수)

---

## 배경 (사용자 요청)

> 인플루언서 응모이력에서 전체/심사중/당첨/낙첨/취소 탭을 **응모이력 제목 우측에 드롭다운**으로 선택하게 하고, 응모이력 페이지 **진입 시 심사중과 당첨된 리스트만** 보이게.

**사용자 확정 정책 (AskUserQuestion 1회):**
- 진입 기본 표시 = **「進行中」(심사중+당첨 묶음)** 단독 라벨. 드롭다운에서 기본 선택.

---

## 현재 상태 (작성일 2026-06-04 기준 — planning.md 규칙 A)

### 관련 코드·UI 진입점
**응모이력 화면** (인플루언서 앱, `dev/index.html` 905~927 / `dev/js/mypage.js`)
- 섹션 `#mypage-sub-applications`(905), 제목 `應募履歴`(`.mypage-sub-title`, 908), 탭 컨테이너 `#myApplyTabs`(910), 목록 `#myApplicationsList`(926)
- 제목 헤더 `.mypage-sub-header`(`dev/css/mypage.css` 14) — `display:flex` 이나 현재 우측 요소 공간 없음 → 제목 우측 배치 시 헤더 구조 수정 필요
- 탭 렌더: `renderMyApplyTabs()`(mypage.js 112) — `.apply-tab` div 5개(flex 가로), 각 건수 표시
- 목록·필터: `renderMyApplyList()`(mypage.js 132) — **클라 in-memory 필터**
- 상태 변수: `let _myAppsTab = 'all'`(mypage.js 98) — 기본 'all'

### 상태 값·라벨 (i18n `dev/lib/i18n/{ja,ko}.js`)
| status | 일본어(ja) | 한국어(ko) |
|---|---|---|
| all | すべて | 전체 |
| pending | 審査中 | 심사중 |
| approved | 当選 | 당첨 |
| rejected | 落選 | 낙첨 |
| cancelled | 取消 | 취소 |
- `appHistory.*` 키. 취소(cancelled) 탭 **이미 존재**(라벨·필터·카운트 다 있음)
- 카드 상태 배지: `getStatusBadge()`(ui.js)

### 추가 필터 (탭 아래 별도, 그대로 유지 예정)
- `#myApplyCampStatus`(캠페인상태) / `#myApplyChannel`(채널, 동적) / `#myApplySort`(정렬) — `renderMyApplyList()` 가 함께 적용

### 취소 응모 처리
- 목록 표시됨(취소 탭). 클릭 시 `openCancelDetailModal`(사유 모달). 메시지 진입은 차단(`messaging.js` 78). 카드에 취소일 표시.

### 충돌 가능성
- 단일 선택 구조(`_myAppsTab` 문자열). "심사중+당첨 동시"는 현재 불가 → 묶음 값 도입 필요(아래).
- DB·RLS 무관(클라 필터). 가로탭 div → select 교체 + 기본값·필터 로직만.

### 미해결 백로그
- 응모이력 카드는 메시지 미읽음 배지·활동관리 진입 등과 얽힘([[project_message_faq_realdata]]). 기본 필터 변경이 미읽음 노출에 영향(아래 의심 4).

---

## 의심·경우의 수 (planning.md 규칙 B)

1. **(UX 핵심) 지난 응모가 안 보임** — 기본이 「進行中」이라, 낙첨·취소된 과거 응모가 진입 시 안 보임. 인플루언서가 "내 응모가 사라졌다"고 오해할 수 있음 → **빈 상태/안내에 「すべて表示(전체 보기)」 유도** 또는 드롭다운이 눈에 띄게. 드롭다운에 건수 병기로 다른 상태 존재를 암시.
2. **(UX) 건수 가시성 저하** — 가로탭은 상태별 건수가 한눈에 보였으나 드롭다운은 접힘 → 각 드롭다운 항목 라벨에 **건수 병기**(예: 進行中(8) / 落選(2)) 권장. 동적 갱신 필요.
3. **(UX) 빈 상태** — 진행중 0건(응모는 있으나 다 끝남)일 때 텅 빈 화면 금지 → 「進行中の応募はありません」+ 전체 보기 안내.
4. **(데이터) 메시지 미읽음 노출** — 낙첨 응모에도 운영팀 메시지가 올 수 있는데 기본 진행중만 보이면 그 미읽음 카드를 놓칠 수 있음. (취소는 메시지 차단) → GNB 미읽음 배지는 상태 무관 집계라 진입 유도는 유지됨. 사양 영향 낮음, 메모만.
5. **(i18n) 「進行中」 신규 라벨** — ja `進行中` / ko `진행중` 키 추가. 한국어 토글 시 누락 없게.
6. **(UX 모바일)** 제목 우측 드롭다운 배치 — 480px 폭에서 제목+드롭다운이 한 줄에 들어가야. 길면 제목 줄이거나 드롭다운 폭 제한.
7. **(상태 정의)** 「すべて」=심사중+당첨+낙첨+취소 4개 전부(기존 유지). 「進行中」=심사중+당첨 2개.

### 현재 구현 충돌
- 없음(추가/치환형, 클라 필터). 가로탭 CSS(`.apply-tab*`)는 제거 또는 미사용 처리.

### 의도 모호점
- (해소됨) 묶음 라벨 「進行中」 단독·기본 확정. 건수 병기·빈상태 안내는 권장(아래 설계 반영).

---

## 제안 / 설계

### UI
- `#myApplyTabs`(가로 탭 div) → **`<select>` 드롭다운**으로 교체, **`應募履歴` 제목 우측**에 배치(`.mypage-sub-header` flex `justify-content:space-between` 또는 우측 정렬).
- 드롭다운 항목(순서): **進行中(기본)** / すべて / 審査中 / 当選 / 落選 / 取消 — 각 라벨에 건수 병기(예: `進行中 (8)`).
- 나머지 필터(캠페인상태/채널/정렬)는 현 위치(목록 위) 유지.

### 로직 (`dev/js/mypage.js`)
- `_myAppsTab` 기본값 `'all'` → **`'active2'`**(진행중 묶음 코드, 명명은 구현 재량) 로 변경.
- 필터 로직: 값 → status 배열 매핑
  - `active2`(진행중) → `['pending','approved']`
  - `all` → `['pending','approved','rejected','cancelled']`
  - `pending`/`approved`/`rejected`/`cancelled` → 각 단일
  - `_myApps.filter(a => statuses.includes(a.status))`
- `renderMyApplyTabs()` → 드롭다운 렌더 함수로 변경(건수 계산 재사용). 선택 변경 `onchange` 로 `renderMyApplyList()`.
- 빈 상태: 선택 결과 0건이면 안내 문구 + (진행중일 때) 「すべて表示」 액션.

### i18n
- `appHistory.inProgress` 추가: ja `進行中` / ko `진행중`. 빈상태 문구·전체보기 라벨도 ja/ko.

### PR / 검증
- 단일 PR. 인플루언서 앱 UI 변경 → reverb-planner 사전 검토(본 사양 갈음 가능) + **reverb-qa-tester**(응모이력은 핵심 플로우 — 상태별 표시·진입 기본값·취소 클릭·메시지 진입 확인. Light~Full 판단은 개발 세션).
- ⚠️ **마이그레이션 불필요**(클라 in-memory 필터, DB 무변경).

---

## 사용자 확인 필요 (개발 착수 전 — 경미)
- 드롭다운 항목에 건수 병기 여부(권장: 병기). 빈상태 「전체 보기」 안내 포함 여부(권장: 포함). 미응답 시 권장대로.

---

## 구현 결과

**구현일:** 2026-06-05
**관련 커밋·PR:** feature/apphistory-status-dropdown → dev PR (커밋 해시는 머지 후 기록)
**작업 세션:** 개발 세션2

### 초안 대비 변경 사항
- **추가된 것:**
  - `APP_STATUS_GROUPS` 매핑 상수(`dev/js/mypage.js`) — 드롭다운 값 → status 배열. `all`도 명시 4종 배열 필터로 통일(기존 `_myApps.slice()` → `filter(includes)`), 미정의 값은 `|| APP_STATUS_GROUPS.all` 폴백.
  - 언어 전환(`langchange`) 시 드롭다운 라벨 갱신 리스너(`dev/js/mypage.js`) — select는 JS 동적 렌더라 `applyI18n` 대상이 아니므로 별도 훅 추가. (기존 가로탭은 langchange 시 갱신 안 되던 한계를 개선)
  - i18n 3키: `appHistory.inProgress` / `emptyInProgress` / `showAll` (ja·ko 대칭).
- **빠진 것:** 없음.
- **달라진 것:**
  - 진행중 코드 명명 = `active2`(사양 제안값 그대로).
  - 빈 상태 3분기: `all`=응모 자체 없음(홈 유도) / `active2`=진행중만 없음(「전체 보기」 버튼) / 그 외 단일 상태=`emptyFiltered`.
  - 제목 우측 배치 = `.mypage-sub-header`에 `justify-content:space-between` 인라인 + select `max-width:55%`(480px 폭 한 줄 보장).

### 구현 중 기술 결정 사항
- 가로탭 CSS(`.apply-tabs`/`.apply-tab*` 4줄)는 **제거**(미사용). JS·HTML 잔존 참조 0건 grep 확인.
- 드롭다운 onchange = `_myAppsTab=this.value;renderMyApplyList()` — 사용자 직접 선택은 `this.value`가 곧 selected라 `renderMyApplyTabs()` 재호출 불필요. 단 빈상태 「전체 보기」·취소 후 cancelled 자동이동 등 **프로그램적 전환**은 `renderMyApplyTabs()`로 selected 동기화.
- **건수는 `_myApps` 전체 기준**(2차 필터 캠페인상태/채널/정렬 무시) — 기존 가로탭과 동일. reviewer가 "캠페인 상태 필터 변경 시 건수 미갱신" Warning을 냈으나, 상태별 총 건수가 더 직관적이고 기존 동작과 동일해 **회귀 아님**으로 판정, 미수정.
- DB·RLS·마이그레이션 무변경(클라 in-memory 필터).
