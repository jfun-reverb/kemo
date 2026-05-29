# 결과물 관리 — 상단 필터 재설계
**작성일:** 2026-05-29
**작성 주체:** 기획/설계 세션
**대상 화면:** 관리자 `/admin#deliverables` (결과물 관리 페인)
**관련 규칙:** `.claude/rules/planning.md`(규칙 A·B), `.claude/rules/docs-tracking.md`

---

## 현재 상태 (2026-05-29 기준, 규칙 A)

### 관련 코드·DB·UI 진입점
- 필터·목록 로직: `dev/js/admin-deliverables.js`
  - `renderDeliverablesList()` 65~370줄 — 필터 수집·그룹화·카운트·정렬·렌더
  - `resetDelivFiltersAndSort()` 40~50줄 — 필터/정렬 초기화
  - `passesFilters(g, opts)` 215~234줄 — 「자기 자신 필터 제외 + 나머지 AND」 카운트 패턴
  - `result_status_repr` 계산 190~208줄 — 다중채널 대표 상태(우선순위 반려>검수대기>승인>미제출)
- 검색형 콤보박스(참고 대상): `admin-deliverables.js` 1396~1562줄 — 대리등록의 캠페인/인플 **단일 선택** 콤보박스(`_renderAdminProxyCampList`/`selectAdminProxyCamp` 등). `matchSearchTokens` 기반 실시간 필터.
- 공용 멀티필터 헬퍼: `dev/js/admin-core.js`
  - `createMultiFilter(containerId, allLabel, options, onChange)` 451~512줄 — 체크박스 다중선택 드롭다운. **검색 입력 없음.**
  - `syncMultiFilter` 420~441줄(옵션 변경 시 재생성·선택 보존), `getMultiFilterValues` 513~520줄, `resetMultiFilter` 401~410줄
- 캠페인 멀티필터 어댑터: `dev/js/admin.js` `syncCampMultiFilter()` 94~102줄 — **결과물 관리(`delivCampMulti`)와 신청 관리(`appCampMulti`) 양쪽이 공유**
- 필터 HTML: `dev/admin/index.html` 결과물 관리 페인 상단 (`delivCampMulti`/`delivRecruitTypeMulti`/`delivReceiptStatusMulti`/`delivResultStatusMulti`/`delivSearch`/`delivIncludeMissing`/`delivProxyOnly`)
- CSS: `dev/css/admin.css` (`.mf-btn`/`.mf-drop`/`.mf-item` 멀티필터, 콤보박스 `.item`/`.empty`)

### 현재 필터 동작 (확인된 사실)
| 필터 | 방식 | 문제 |
|---|---|---|
| 캠페인 | 체크박스 다중선택 + 캠페인번호 부제 + 건수 | **검색 없음 → 목록 길면 못 찾음** |
| 모집 타입 | 리뷰어/기프팅/방문형 다중 | — |
| 영수증 상태 | 검수대기/승인/비승인/미제출, **모든 모집타입 일괄** | **기프팅·방문형은 영수증 없어 무조건 '미제출' 집계됨(버그)** |
| 결과물 상태 | 검수대기/승인/비승인/채널미분류/미제출 | **다중채널을 대표상태 1개로 압축 → 반려+검수대기 섞이면 검수대기로 안 걸림** |
| 채널 미분류(`legacy_no_channel`) | 항상 노출 | 채널·업로드 강제 이후 신규 0건. 단 **운영 레거시 385건 존재** |
| 검색 | 인플(이름·가나·이메일) + 캠페인(명·브랜드·번호) 동시 | 캠페인 검색이 콤보박스로 빠지면 중복 |
| 미제출 포함 | 승인됐는데 결과물 0건 신청 노출 | 다중채널 **부분 제출**은 안 잡힘(의미 모호) |
| 대리등록만 | `submitted_by_admin` 있는 그룹 | 점 6 — 현행 유지 |

### 이 제안과 충돌 가능성 있는 기존 동작
- `createMultiFilter`는 **관리자 전역 공용 헬퍼**(캠페인/신청/인플루언서/기준데이터/관리자계정 등 다수 페인이 사용). 검색 기능 추가는 **opt-in 플래그**로만 — 기본 동작 변경 금지(회귀 위험).
- `syncCampMultiFilter` 공유 → 캠페인 검색형 전환 시 **신청 관리(`appCampMulti`)에도 자동 적용**됨. 점 1 「모든 캠페인 드롭다운 통일」 의도와 일치하므로 **의도된 부수효과**(QA 시 신청 관리 화면도 확인).
- 결과물 관리는 이미 운영 중(대리등록 출시 완료). 약관·DB 영향 없음(순수 관리자 UI/클라이언트 필터).
- 동일 레이아웃 구조 일관성 규칙(`feedback_verify_structure_consistency`): 필터 줄 재배치가 `admin-pane-list`의 sticky-header→admin-card→table 구조·스크롤을 깨면 안 됨. 더보기 접이식이 sticky 높이를 바꾸므로 thead sticky·tbody 스크롤 회귀 점검 필수.

### 미해결 백로그·관련 작업
- 메모리 `project_admin_proxy_deliverable.md` — 대리등록 운영 출시 완료(점 6 기준선)
- 메모리 `project_multichannel_deliverable.md` — monitor 채널별 결과물 분리(사양 2). 레거시 `post_channel=NULL` 385건이 채널 미분류의 원인
- 메모리 `project_admin_server_pagination.md` — 관리자 목록 서버 페이지네이션(설계만, 미착수). 본 작업은 **클라이언트 전건 fetch 유지**(현행). 페이지네이션 전환 시 필터 로직 재이식 필요 — 별개 작업

---

## 의심·경우의 수 (규칙 B)

### 1. 캠페인 검색형 다중선택 (점 1·7) — **결정: 검색 + 다중 선택**
- 깨질 가능성 ① 대리등록 콤보박스는 단일 선택 → 「통일」을 단일로 받으면 다중 비교 능력 손실. **(해소: 필터는 다중 유지, 검색 UX만 통일. 폼은 1개 선택이 정상이라 단일 유지 — 동작 차이는 의미상 정당)**
- ② (UX) 검색창이 인플 전용으로 바뀌면 기존에 "캠페인명으로 검색하던" 운영자가 잠깐 헷갈림 → placeholder를 「인플루언서명·이메일 검색」으로 명확히.
- ③ (기술) 100건 초과 캠페인 시 콤보 목록 잘림 → 대리등록처럼 `slice(0,100)` + 검색 좁히기 안내.
- **현재 구현 충돌점:** `syncCampMultiFilter` 공유 → 신청 관리에도 적용(의도됨, 확인 완료).

### 2. 채널 필터 (점 2) — **결정: 별도 채널 드롭다운**
- 깨질 가능성 ① 채널은 모집타입별 가용이 다름(LIPS·@cosme=리뷰어 전용) → 별도 드롭다운이라 조합 폭발은 회피. 단 모집타입 필터와 동시 적용 시 빈 교집합 0건 가능(카운트로 인지 가능).
- ② 기프팅·방문형은 `post_channel` 자동판별 → **NULL(미상) 행은 특정 채널 필터에 안 걸림** → 채널 필터 활성 시 누락. **(처리 규칙 명시: 아래 §설계 3)**
- ③ (UX) 채널 라벨은 `getLookupLabel('channel', code)` 필요 — 캐시 미보장 시 코드 노출(`renderDeliverablesList` 98줄에서 이미 `fetchLookups('channel')` 보장).

### 3. 영수증 미제출 오류 (점 3) — **버그 수정 확정**
- 의도 모호 없음. 기프팅·방문형은 영수증 단계 자체가 없음 → 영수증 상태 **카운트·필터 대상에서 완전 제외**.

### 4. 다중채널 결과물 상태 (점 4·4-1) — **결정: 하나라도 해당(ANY)**
- 깨질 가능성 ① ANY 매칭 시 한 신청이 검수대기·승인 양쪽에 **동시 집계** → 상태별 건수 합 ≠ 총건수. **(의도된 동작 — UI에 "다중채널은 채널 상태별 중복 집계" 안내 한 줄)**
- ② 정렬의 「검수대기 우선」은 대표상태(repr) 기반 유지 → 필터는 ANY, 정렬은 repr. 두 로직이 공존해도 모순 없음(필터=노출 여부, 정렬=순서).
- ③ 채널 미분류(레거시) 385건 존재 → 옵션 완전 삭제 불가. **건수>0일 때만 옵션 노출**.

### 5. 미제출 포함 의미 (점 5) — **결정: 결과물 기준**
- 모호 해소: 「미제출 포함」 토글 = **승인됐는데 결과물 0건인 신청**을 노출(현행 유지). 다중채널 **부분 미제출**은 그룹이 이미 목록에 있으므로, **결과물 상태='미제출'(ANY)** 필터로 잡음. 두 기능 역할 분리 → 토글 tooltip에 명시.

### 6. 기간 필터·레이아웃 (점 8) — **결정: 최근 제출일만 + 기본줄/더보기 접이식**
- 깨질 가능성 ① 구매기간·제출마감은 정렬(▲▼)과 중복 → 추가 안 함(필터 과밀 방지).
- ② 더보기 접이식이 닫혀 있으면 적용된 필터가 안 보임 → **「필터 더보기 (N) ▾」 활성 개수 배지** 필수.
- ③ (UX) 접이식 펼침/접힘으로 sticky-header 높이 변동 → thead sticky·tbody 스크롤 회귀 점검.

---

## 설계

> DB 변경 없음. 전부 클라이언트 필터/렌더 + 공용 헬퍼 opt-in 확장. 영향 파일 4개: `admin-core.js`, `admin.js`(또는 `admin-deliverables.js`), `admin-deliverables.js`, `dev/admin/index.html`, `dev/css/admin.css`.

### 1. 검색형 다중선택 캠페인 콤보박스 공용화 (점 1·7)
- `createMultiFilter`에 **`searchable` opt-in 플래그** 추가(기본 false → 기존 전 페인 무영향).
  - true면 `.mf-drop` 최상단에 검색 input 1개 삽입. 입력 시 `matchSearchTokens(q, [label, subLabel])`로 옵션 행 show/hide(체크 상태·`getMultiFilterValues` 결과 불변).
  - 「전체」 항목은 항상 노출. 매칭 0건이면 "일치하는 캠페인 없음".
- `syncMultiFilter`/`syncCampMultiFilter` 시그니처에 `searchable` 전달. `syncCampMultiFilter`만 `searchable:true`.
- 결과 → `delivCampMulti` + `appCampMulti`(신청 관리) **양쪽 자동 검색형 통일**(점 1 의도).
- 검색창 분리: `renderDeliverablesList` 검색 매칭에서 캠페인 필드 제거 → `matchSearchTokens(search, [inf.name, inf.name_kana, inf.email])`. HTML placeholder 「인플루언서명·이메일 검색」.

### 2. 영수증 상태 — 리뷰어(monitor) 전용 (점 3)
- `passesFilters` 영수증 분기: **monitor 그룹만** 대상. 기프팅·방문형은 영수증 필터·카운트에서 제외.
- `receiptStatusCounts` 집계 루프에서 `g.campaign?.recruit_type === 'monitor'`인 그룹만 합산('none' 포함). 기프팅·방문형은 어떤 영수증 상태에도 안 들어감.
- 영수증 상태 필터 활성 시 기프팅·방문형 그룹은 자동 비노출(영수증 없음). 셀 「—」 현행 유지.

### 3. 채널 필터 신설 (점 2)
- 신규 멀티필터 `delivChannelMulti`(더보기 영역). 옵션 = `fetchLookups('channel')` active 항목(value=code, label=`name_ko`, count).
- 매칭 규칙(그룹 g):
  - monitor: `campaign.channel` split에 선택 채널이 하나라도 포함되면 통과(캠페인 기준).
  - gifting/visit: `g.result?.post_channel`이 선택 채널이면 통과.
  - **채널 미상(post_channel NULL) 행**: 특정 채널 선택 시 비매칭(=숨김). 「전체」면 노출. → 채널 옵션에 **「채널 미상」 값(`__none__`)**을 건수>0일 때만 추가(영수증 처리와 동일 패턴).
- 카운트·`passesFilters`에 `skipChannel` 추가(표준 패턴).

### 4. 결과물 상태 ANY 매칭 + 채널 미분류 조건부 (점 4·4-1·5)
- `passesFilters` 결과물 분기:
  - monitor: 그룹의 채널별 상태 집합 `states`(미제출=none, 레거시=legacy_no_channel 포함) 중 **하나라도 선택값에 들면 통과**.
  - gifting/visit: `g.result?.status`(없으면 none).
- 카운트: 그룹이 가진 **각 상태마다** +1(중복 집계 허용). UI에 안내 문구 1줄.
- 채널 미분류 옵션: `resultStatusCounts.legacy_no_channel > 0`일 때만 옵션 배열에 포함.
- 미제출 포함 토글 tooltip: 「승인됐지만 결과물을 한 건도 제출하지 않은 신청을 함께 표시합니다. (다중채널 일부 미제출은 '결과물 상태=미제출'로 거르세요)」

### 5. 최근 제출일 기간 필터 (점 8-1/8-2)
- 더보기 영역에 flatpickr range 1개(`delivSubmittedRange`). 기준 = 그룹 `latest_submitted_at`.
- 필터: 선택 범위 [start, end] 안의 그룹만(`latest_submitted_at` 날짜 비교, 양끝 포함).
- `resetDelivFiltersAndSort`에 초기화 추가. 구매기간·제출마감은 정렬(▲▼) 유지(추가 안 함).

### 6. 레이아웃 — 기본줄 + 더보기 접이식 (점 8-3)
```
┌─ 결과물 관리 ───────────────────────────────────┐
│ [🔍 캠페인 검색·선택 ▾]  [결과물 상태 ▾]            │
│ [🔍 인플루언서명·이메일 검색 ...............]        │
│ [⚙ 필터 더보기 (N) ▾]              [초기화]        │  ← N = 더보기 영역 활성 필터 수
│                                                  │
│ ── 더보기 펼침(기본 닫힘) ──                        │
│ [모집타입 ▾] [채널 ▾] [영수증 ▾] [최근 제출일 ▾]     │
│ ☐ 미제출 포함   ☐ 대리등록만                        │
└──────────────────────────────────────────────┘
```
- 「필터 더보기」 토글 버튼: 더보기 영역 show/hide. 닫혀 있어도 **활성 필터 수 배지**(모집타입·채널·영수증·기간·미제출·대리등록 중 적용된 개수) 표시.
- 더보기 영역에 활성 필터가 1개라도 있으면 배지 강조(또는 자동 펼침은 하지 않고 배지만 — 사용자 수동 토글 존중).
- sticky-header 안에 기본줄+더보기 모두 배치(접힘 시 높이 축소). thead sticky·tbody 스크롤 회귀 QA.

---

## PR 분할

| PR | 제목 | 범위 | 의존 |
|---|---|---|---|
| PR 1 | 캠페인 검색형 다중선택 공용화 + 검색 인플 분리 | §설계 1 — `createMultiFilter` searchable opt-in, `syncCampMultiFilter` 적용(결과물+신청 양쪽), 검색 매칭 인플 전용 | 없음 |
| PR 2 | 결과물 관리 필터 정확성 | §설계 2(영수증 monitor 전용)·4(결과물 ANY+채널미분류 조건부)·미제출 tooltip(5) | PR 1 |
| PR 3 | 채널 필터 + 최근 제출일 기간 + 레이아웃 재배치 | §설계 3·5·6 — 신규 채널 필터, 기간 필터, 기본줄/더보기 접이식 + CSS | PR 1·2 |

- 각 PR: `bash dev/build.sh` → reverb-reviewer GO → dev 머지. QA는 **Light(관리자 페인 — 컬럼·필터·모달)**. PR 3 머지 후 신청 관리 화면(캠페인 검색형 부수효과)도 함께 확인.
- 운영 배포: 약관·DB 영향 없음. dev 검증 후 운영 배포 여부는 사용자 확인(`.claude/rules/git.md`).
- `createMultiFilter` 변경(PR 1)은 전역 공용 헬퍼 → reviewer가 **모든 호출처 무영향(searchable 기본 false)** 확인 의무.

## 사용자 확인 필요 (확정 완료)
- 캠페인 필터 = 검색 + **다중 선택** ✅
- 채널 = **별도 드롭다운** ✅
- 다중채널 결과물 상태 = **하나라도 해당(ANY)** ✅
- 기간 필터 = **최근 제출일만** ✅
- 레이아웃 = **기본줄 + 더보기 접이식** ✅
- (권고 반영) 점 3 영수증 monitor 전용 / 점 4-1 채널미분류 건수>0만 / 점 5 미제출=결과물 기준 / 점 7 검색=인플 전용

## 구현 결과 (개발 세션이 채울 것)

### PR 1 — 캠페인 검색형 다중선택 공용화 + 검색 인플 분리 (구현 완료)
**구현일:** 2026-05-29
**브랜치:** `feature/deliv-filter-redesign`

#### 초안 대비 변경 사항
- **추가된 것:** 신청 관리(`appSearch`) 검색창도 인플루언서 전용으로 통일(사용자 확인 — 「같이 통일」 선택). 사양서 초안 §설계 1은 결과물 관리 검색창만 명시했으나, `syncCampMultiFilter` 공용 전환으로 `appCampMulti`도 검색형이 되어 일관성 위해 신청 관리 검색에서도 캠페인 필드(`title/brand/brand_ko/product/product_ko/campaign_no`) 제거 + placeholder 변경.
- **빠진 것:** 없음.
- **달라진 것:** 검색창 placeholder를 결과물·신청 양쪽 「인플루언서명 · 이메일 검색」으로 통일.

#### 구현 중 기술 결정 사항
- `createMultiFilter`에 `opts.searchable`/`opts.searchPlaceholder` opt-in 추가(기본 false → 기존 전 페인 무영향). 검색형이면 `.mf-drop` 최상단에 sticky `.mf-search` input + `.mf-search-empty` 안내 삽입.
- **회귀 차단:** 검색 input(`type=search`)이 필터 값에 섞이지 않도록 `getMultiFilterValues`/`resetMultiFilter`/`syncMultiFilter`/`createMultiFilter`의 옵션 셀렉터를 `input[type="checkbox"]:not([value="all"])`로 한정.
- `syncMultiFilter` 옵션 캐시키(`optKey`)에 `'|__search'` 식별자 추가(검색형 컨테이너 재생성 보장, 비검색은 키 불변).
- DB·RLS·약관 영향 없음(순수 관리자 클라이언트 UI).
- reverb-reviewer GO(Warning 2건 반영 후 재검증 GO), qa-tester 권장 light.

### PR 2 — 결과물 관리 필터 정확성 (예정)
### PR 3 — 채널 필터 + 최근 제출일 + 레이아웃 재배치 (예정)
