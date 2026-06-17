# 관리자 목록 표 — 열 너비 드래그 조정 기능

**작성일:** 2026-06-17
**상태:** 기획 대기 (다른 세션에서 `reverb-planner`로 설계 후 구현 예정)
**작성 주체:** 고문 세션 (요청·현재 상태·반대론자 분석까지. 본 설계는 기획 세션이 이어서 채움)
**사용자 요청:** "표의 열 너비를 사용자(관리자)가 핸들로 드래그해서 조정하는 기능을 추가할 수 있나?"
**사용자 결정:** "기획부터 진행 (설계서 작성)" — 다른 세션에서 이어감.

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

## 설계해야 할 결정 포인트 (기획 세션 = reverb-planner가 다룰 것)

1. **레이아웃 방식**: `table-layout:auto` 유지 + 드래그로 th width 직접 세팅 **vs** `table-layout:fixed` 전환(+colgroup). 각 장단점, 기존 min-width·CSS 고정열·sticky·가로 스크롤과의 정합.
2. **드래그 핸들 UX**: th 우측 경계 핸들(커서 col-resize), mousedown/move/up. 정렬 클릭과 영역 분리. 최소/최대 너비 제한. 더블클릭 자동맞춤(선택).
3. **저장·복원**: localStorage 페인별·열별 저장 → 진입/새로고침 시 복원. 키 설계(페인id + `data-col`). 기본값 복귀 버튼.
4. **재렌더 정합**: lazy-load tbody 재렌더 시 width 유지 방식(thead th / colgroup / td 재적용).
5. **적용 범위**: 신청 관리 한 표 시범 → 공통 헬퍼(`initColumnResize(paneId, tableEl)`)로 8개 페인 확장. 페인별 sticky·고정열 처리.
6. **충돌·엣지케이스**: sticky 1·2열 resize, 가로 스크롤 중 드래그 좌표 보정, 관리자 PC 전용(모바일 제외), 권한 차이 없음(전 관리자 공통), 공유 PC localStorage 섞임.
7. **대안 검토**: 열 표시/숨김 토글, 프리셋 너비 등 더 단순한 대안의 ROI.

---

## 진행 방향 (고문 권고)
- 전체 일괄 도입보다 **신청 관리 한 표 시범**(table-layout:fixed 전환 + 드래그 핸들 + localStorage 저장)으로 검증 후 확장 권장.
- 시범 전에 **열 너비 관리 3곳 분산을 단일 소스로 정리**(colgroup 또는 일관된 한 곳)하는 선행 PR이 깔끔.
- DB 변경 없음 전제(UI 환경설정 = localStorage).

## PR 분할 (초안 — 기획이 확정)
- (선행) 신청 관리 표 너비 관리 단일화 + `table-layout:fixed` 전환
- (PR 1) 신청 관리 한 표 드래그 resize + localStorage 저장/복원 + 기본값 복귀
- (PR 2) 공통 헬퍼화 → 나머지 페인 확장

## 사용자 확인 필요 (기획 세션이 AskUserQuestion으로)
- 적용 범위: 신청 관리만 / 전체 8개 표
- 저장: 영구(localStorage) / 세션만
- 대안(표시·숨김 토글·프리셋) 대비 드래그 resize가 정말 필요한지

## 구현 결과 (개발 세션이 채울 것)
_(미착수)_

---

## 참고: 이번 세션(2026-06-17) 관련 열 너비 작업 — dev 미배포(운영 대기)
> 본 기능 착수 전 아래 변경들의 운영 배포 여부를 먼저 정리할 것. 운영(`main`)은 `480eb2b`(PR #526)까지, dev는 그 이후 2커밋이 미배포.
- `73674a0` — 신청 사유 셀 `max-width` 200→280px (`msgCell`, admin-core.js, 공용)
- `655f4ad` — 신청 관리 표 10개 열 min-width 부여(합 1690 = `data-table min-width`) + 제품 셀 120/220→200/260
- (그 앞 `2f99b5f`까지는 운영 배포 완료 — 캠페인 상태 필터·보기 초기화·미리보기 버튼·열/라벨 정리·CSS 인라인 분리 등)
