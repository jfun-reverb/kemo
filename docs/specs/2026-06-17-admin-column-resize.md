# 관리자 목록 표 — 열 너비 드래그 조정 기능

**작성일:** 2026-06-17
**상태:** 기획 완료 (설계 확정 — 개발 세션 착수 가능)
**작성 주체:** 고문 세션(요청·현재 상태·반대론자 분석) → 기획 세션(설계 확정, 2026-06-17)
**사용자 요청:** "표의 열 너비를 사용자(관리자)가 핸들로 드래그해서 조정하는 기능을 추가할 수 있나?"

### 사용자 결정 (2026-06-17 기획 세션 대화)
1. **기능 방향**: 드래그 너비 조정만이 아니라 → **열 숨김 토글 + 드래그 너비 조정 둘 다** (실제 불편이 "안 쓰는 열이 자리 차지" + "상황·사람마다 원하는 너비가 다름" 두 가지였음)
2. **단계**: 둘 다 한 번에 구현 (열 숨김 먼저·드래그 나중 단계안은 채택 안 함)
3. **적용 범위**: **신청 관리 표 1개 시범 → 공통 헬퍼로 8개 확장**
4. **저장**: 브라우저 영구(localStorage). 공유 PC 시 관리자 간 설정 공유(섞임)는 수용
5. **레이아웃**: colgroup(열 너비를 한 곳에서 관리하는 표 구조) + 고정 레이아웃(`table-layout:fixed`) 전환. 긴 셀 말줄임(…)은 드래그로 재확대 가능하므로 수용

---

## 현재 상태 (2026-06-17 기준, 코드 확인 완료)

### 관련 코드·UI 진입점
- **관리자 목록 표 8개 페인**: 신청 관리(`#adminPane-applications`, thead id=`appTableHead`), 결과물 관리(`#adminPane-deliverables`), 캠페인 관리(`#adminPane-campaigns`), 인플루언서(`#adminPane-influencers`), 브랜드 서베이(`#adminPane-brand-applications`) 등. `dev/admin/index.html`의 thead + 각 `dev/js/admin-*.js`의 행 렌더.
- 공통 클래스 `.data-table`, 래퍼 `.admin-table-wrap`. CSS는 `dev/css/admin.css`.
- **신청 관리 표 현재 구조** (이번 세션에 정비함):
  - `table-layout` 명시 없음(기본 `auto`)
  - thead 각 th에 인라인 `min-width` (합계 정확히 **1690px**: 캠페인240·채널110·브랜드120·제품240·모집기간170·인플180·신청사유310·신청일110·상태90·처리120)
  - `admin.css`: `#adminPane-applications .data-table{min-width:1690px}` + `th:nth-child(1){width:380px}`(캠페인)·`th:nth-child(2){width:150px}`(채널) 고정열
  - `#adminPane-applications .admin-table-wrap{overflow-x:auto}` → 가로 스크롤
  - sticky thead(`top:0`), 일부 페인은 1·2열도 sticky(브랜드 서베이)
  - ⚠️ **열 너비 관리 포인트가 3곳으로 분산**: ① thead th min-width ② admin.css `data-table{min-width}` ③ admin.css `th:nth-child` 고정열. 캠페인·채널은 ③이, 나머지는 ①이 실질 결정.
- **목록 렌더**: IntersectionObserver lazy-load(sentinel 점진 렌더). 필터·검색·정렬 변경 시 tbody 재렌더.
- **빌드**: `dev/` 소스 → `build.sh` concat → `admin/index.html` 인라인. ES 모듈 아님(전역 스코프 1개).
- **저장 수단**: localStorage 프로젝트 곳곳 사용 중. DB 변경은 피하는 방향(UI 환경설정이라).

### 이 제안과 충돌 가능성 있는 기존 동작
- **열 너비 관리 3곳 분산**(위 ⚠️) — resize 도입 시 어느 소스가 우선인지 정리 안 하면 드래그값이 CSS 고정열/`min-width`와 경합.
- **헤더 정렬 클릭**(▲▼ `onclick="toggleAppSort()"`) — resize 핸들과 클릭 영역이 겹치면 너비 조정하려다 정렬이 토글됨.
- **sticky thead / sticky 1·2열** — resize 핸들의 position·z-index가 sticky와 간섭 가능.
- **lazy-load 재렌더** — tbody 재생성 시 조정한 너비 유지 방식 결정 필요(thead th width 기반 or colgroup이면 유지, td 인라인이면 재적용).

### 미해결 백로그·관련 작업
- 이번 세션(2026-06-17) 열 너비 조정들이 **운영 미배포로 dev에 누적**(아래 「참고」 참조). 본 기능 착수 전 그 변경들의 운영 배포 여부 먼저 정리 권장.

---

## 의심·경우의 수 (반대론자 모드 — 고문 세션 1차 분석)

1. **구조 충돌(기술)** — resize는 통상 `table-layout:fixed` + 명시 width(또는 colgroup) 위에서 안정적. 현재 `auto` + `min-width` + CSS 고정열 혼재 상태에 얹으면 동작 예측 불가. → `table-layout:fixed` 전환 + 너비 관리 단일화가 선행 과제.
2. **저장·영속성(UX, 필수)** — 드래그 너비를 저장 안 하면 **새로고침마다 초기화** → "조정해도 사라진다" 불만 직결. localStorage 페인별·열별 저장 필요. 공유 PC면 관리자끼리 설정이 섞임(브라우저 단위 저장의 한계).
3. **헤더 클릭 충돌(UX)** — 정렬 화살표 클릭 vs resize 핸들 드래그 영역 분리 필수. 핸들은 th 우측 경계 좁은 띠(커서 `col-resize`)로 한정.
4. **다중 표 확장 비용** — 목록 표 8개, 열 구성·sticky·고정열이 페인마다 달라 전체 적용 작업량 큼. 공통 헬퍼화 필요.
5. **열 식별 안정성(데이터)** — 저장 키를 `nth-child` 인덱스로 잡으면 열 추가·순서 변경 시 깨짐. `data-col` 속성 기반 권장.
6. **ROI** — 관리자가 소수면, 지금처럼 개발이 적정 너비를 세팅하는 편이 더 단순할 수 있음. 「열 표시/숨김 토글」이나 「프리셋 너비 몇 종」 같은 더 가벼운 대안이 ROI가 나을 가능성 검토.

---

## 확정 설계 (기획 세션, 2026-06-17)

기획 세션 재검증에서 사양서 1차 분석을 보강한 **추가 사실 2건**:
- 1·2열은 thead 인라인 `min-width`(캠페인 240·채널 110)와 admin.css 고정값(캠페인 **380**·채널 **150**)이 **서로 달라** 실 렌더폭 ≈1870px ≠ 선언 1690px. 「3곳 분산」의 실제 경합.
- 2열(채널) sticky `left:380px`가 **1열 너비에 하드코딩 종속** → 1열을 줄이면 2열 위치가 어긋남(resize 시 동적 갱신 필수 엣지케이스).

### 1. 레이아웃 — colgroup + `table-layout:fixed` (선행 단일화)
- 신청 관리 표 thead 위에 `<colgroup>` 추가, 각 `<col data-col="...">`가 열 너비의 **단일 소스**. th 인라인 `min-width`·`nth-child` 고정열·`data-table{min-width}` 3분산을 colgroup 1곳으로 정리.
- `table-layout:fixed` 전환. 긴 셀(신청 사유·제품)은 `overflow:hidden;text-overflow:ellipsis`로 말줄임 — 기존 `msgCell`(신청 사유 `max-width:280px`, admin-core.js)과 정합 점검.
- **왜 fixed인가**: 드래그·열 숨김은 본질적으로 "고정 너비" 모델 위에서만 예측 가능. `auto`는 브라우저가 내용 기반으로 너비를 재계산해 설정값을 무시(사양서 의심 1번이 현실화).

### 2. 열 식별자 — `data-col` (nth-child 금지)
- 각 `<col>`·핸들·숨김 토글이 의미 기반 안정 키 사용(`campaign`/`channel`/`brand`/`product`/`deadline`/`influencer`/`reason`/`created`/`status`/`action`). 열 추가·순서 변경에도 저장값 안 깨짐.

### 3. 드래그 너비 조정
- 각 th 우측 경계에 `position:absolute;right:0;width:6px;cursor:col-resize` 핸들 div. `mousedown`에서 `stopPropagation`으로 정렬 화살표(▲▼) 클릭 차단 → 영역 분리.
- `mousedown` 시 `startX`·시작 너비 저장 → `mousemove`는 `delta=clientX-startX`만 사용(가로 스크롤 보정 불필요). admin-core.js 모달 드래그 인프라(`:740~810`) 패턴 차용.
- 최소 60px / 최대 800px 클램프. 더블클릭 자동맞춤은 **백로그**(fixed에서 내용폭 측정 까다로움).

### 4. 열 숨김 토글
- 표 카드 헤더 우측("보기 초기화" 버튼 패턴 옆)에 「열 선택」 메뉴 — 열별 체크박스로 표시/숨김. 숨김 열은 `<col>`·thead th·tbody td 모두 `display:none`(또는 colgroup 너비 0 + 셀 숨김). 최소 1개 열은 항상 표시(전부 숨김 방지).
- 숨김 상태도 localStorage 저장(너비와 같은 키 묶음).

### 5. 고정열 sticky 연쇄 갱신
- 2열 이후 sticky `left`를 admin.css 하드코딩(`left:380px`) 대신 **CSS 변수**(`--sticky-left-2` 등)로. resize·숨김 후 JS가 누적합으로 `--sticky-left-N` 재계산. 신청·결과물=고정열 2개, 브랜드 서베이=1개, 나머지=0개.

### 6. 저장·복원
- 키 `reverb.admin.colstate.{paneId}` → `{ widths:{colId:px}, hidden:[colId...] }` 한 묶음. localStorage 영구.
- 페인 진입 시 1회 `applyColumnState(paneId)` 호출 → colgroup 너비·숨김 적용 + sticky 변수 갱신.
- **재렌더 정합**: colgroup은 thead/tbody 밖이라 lazy-load tbody 재렌더에 **자동 유지**(td 인라인 재적용 불필요). 숨김 td만 재렌더 시 `data-col` 기준으로 `display:none` 재적용.
- 「열 너비·표시 초기화」 버튼으로 기본값 복귀.

### 7. 공통 헬퍼 (확장 대비)
- `initColumnResize(tableEl, { paneId, stickyCount, minW, maxW })` + `applyColumnState(paneId)` 를 admin-core.js(다른 admin-* 보다 앞)에 작성.
- thead 비균질 대응: colgroup 있는 표만 대상. `lookupTableHead`처럼 JS 동적 생성 thead는 colgroup도 JS로 생성 → **2차 확장에서 페인별 개별 처리**.

### 충돌·엣지·범위
- 관리자 PC 전용(터치 이벤트 미지원 OK), 권한 차이 없음(전 관리자 공통, 행 단위 보안 정책·DB 무관).
- 빈 상태/로딩(spinner colspan 행)도 colgroup 너비는 thead 기준이라 영향 없음.
- 공유 PC localStorage 섞임 = 수용(환경설정 수준, 위험 낮음).

---

## PR 분할 (확정)

| 단계 | 내용 | 주요 파일 | DB |
|---|---|---|---|
| **선행** | 신청 관리 표 너비 단일화 — colgroup + `data-col` + `table-layout:fixed` + sticky CSS 변수화. 셀 말줄임 정합 | `dev/admin/index.html`(신청 thead colgroup), `dev/css/admin.css`(#adminPane-applications) | 없음 |
| **PR 1 (시범)** | 신청 관리 1표: 드래그 핸들 + 열 숨김 토글 + localStorage 저장/복원 + 초기화 버튼 | `dev/js/admin-core.js`(헬퍼 `initColumnResize`/`applyColumnState`), `dev/admin/index.html`(카드 헤더 「열 선택」·「초기화」), `dev/css/admin.css`(핸들·메뉴), `dev/js/admin-applications.js`(진입 시 적용 호출) | 없음 |
| **PR 2 (확장)** | 공통 헬퍼로 나머지 7개 페인 — 정적 thead colgroup 부여, 동적 thead는 JS colgroup 생성 | `dev/admin/index.html`, `dev/js/admin-*.js`, `dev/css/admin.css` | 없음 |

- 의존성: 선행 → PR 1 → PR 2. 각 단계 dev 검증 후 다음.
- ⚠️ **핫스팟 주의**: PR 2는 `admin.js`·`admin-deliverables.js` 등 다중 페인 파일 → worktree 병렬 분기 금지(`admin.js` 충돌 100%), **시퀀셜 PR**만. PR 1·2는 같은 세션 순차.
- 빌드: `dev/` 소스 수정 후 `build.sh` concat 필수(신규 파일 없음 — 기존 파일 수정만).

## 구현 결과 (개발 세션이 채울 것)
_(미착수)_

---

## 참고: 이번 세션(2026-06-17) 관련 열 너비 작업 — dev 미배포(운영 대기)
> 본 기능 착수 전 아래 변경들의 운영 배포 여부를 먼저 정리할 것. 운영(`main`)은 `480eb2b`(PR #526)까지, dev는 그 이후 2커밋이 미배포.
- `73674a0` — 신청 사유 셀 `max-width` 200→280px (`msgCell`, admin-core.js, 공용)
- `655f4ad` — 신청 관리 표 10개 열 min-width 부여(합 1690 = `data-table min-width`) + 제품 셀 120/220→200/260
- (그 앞 `2f99b5f`까지는 운영 배포 완료 — 캠페인 상태 필터·보기 초기화·미리보기 버튼·열/라벨 정리·CSS 인라인 분리 등)
