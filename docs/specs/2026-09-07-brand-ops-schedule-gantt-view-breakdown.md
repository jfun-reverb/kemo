# 📋 작업 분해표 — 운영현황 「일정」 뷰 (캠페인 간트차트)

**사양서:** `docs/specs/2026-09-07-brand-ops-schedule-gantt-view.md`
**분해일:** 2026-09-07
**총 작업 조각:** 7개 · **병렬 가능:** 0개 · **순차 필수:** 7개
**데이터베이스 변경:** 0 (마이그레이션 없음) · **PR:** 1개 (사양서 「단계」 유지)

> 기획 에이전트가 사양서와 코드를 대조해 분해한 뒤, 개발 세션이 운영 실측(S0)을 채웠다(2026-09-07).

---

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

| # | 선결 조건 | 근거 | 막는 조각 | 상태 |
|---|---|---|---|---|
| **S0** | **운영 실측 3종** — ①상태별 캠페인 수 ②대상 집합의 결과물 총 행 수 ③마감일(`deadline`)이 빈 캠페인 유무 | 사양서 「착수 전 알아야 할 것」 1·4번, 의심 3·4 | 작업 4·5 | ✅ **완료 — 아래 「운영 실측」** |
| **S1** | **하루 폭 픽셀 값 확정** — 12주(84일)가 약 900픽셀 안에 들 값 | 사양서 설계 4 (「개발 세션이 정함」) | 작업 3 | 개발 세션이 정함 — **10px**(84일 = 840px) 로 시작, 브라우저 확인 뒤 조정 |
| **S2** | **회사 필터를 캠페인 행에 어떻게 거는가** — 캠페인 표에는 회사 값이 없다(`brand_id` 만). 브랜드→회사 매핑은 `_brandOpsCache`(브랜드 집계 행)의 `brand_id`→`company_id` 로 만들 수 있으나, **`brand_id` 가 빈 캠페인**을 어디에 둘지 사양서에 없다 | 결정 9(「회사 필터는 두 뷰 공용」)는 정해졌으나 적용 방식이 미정 | 작업 2 | 권장안 채택 — 회사를 고르면 그 회사 브랜드의 캠페인만, **브랜드가 빈 캠페인은 「전체」에서만** 보인다. 「구현 결과」에 적는다 |
| **S3** | **검색이 일정 뷰에서 무엇을 훑는가** — 브랜드 뷰 검색은 브랜드명·회사명·브랜드번호를 훑는다(`renderBrandOpsCards`). 일정 뷰의 행은 캠페인이라 **훑을 대상이 다르다** | 같은 결정 9 | 작업 2 | 권장안 채택 — **캠페인명·캠페인 번호·브랜드명** |

> S2·S3 는 행 수가 달라지는 결정이라 검증 시나리오 2 의 대조 기준에 영향을 준다. 위 채택안을 「구현 결과」에 남긴다.

### 운영 실측 (S0, 2026-09-07 — `deleted_at IS NULL`)

| 항목 | 값 | 뜻 |
|---|---|---|
| 상태별 캠페인 | active 9 · closed 30 · **scheduled 0** · draft 1 · ended 126 · expired 42 | 기본 대상 **39행**, 「종료 포함」 **207행** |
| 결과물 행 | 기본 3상태 **821행** · 종료 포함 5상태 **3,334행** | 1,000행 페이징 최대 4회. 200개 단위 id 조각은 종료 포함이라도 2조각 |
| `deadline` 빈 캠페인 | **0** | 모집 막대 예외 ㄴ(「마감 없음」)은 앞으로를 위한 조항 — 시나리오 10 은 개발서버 시험 캠페인으로 |
| `recruit_start` 빈 + `first_active_at` 빈(draft 제외) | **0** | 예외 ㄱ 마커도 현재 대상 0 |
| `submission_end` 빈(draft 제외) | **36** | 제출 막대 없는 행이 실제로 있다 — ②는 조건대로 안 그린다 |
| `selection_start` 있는 캠페인 | **11** | 선정 보조 막대 실제 대상 |
| 리뷰어형 「구매 기간 ≠ 모집 기간」(NULL 비교 제외) | 0 | ⚠️ `CLAUDE.md` 의 「두 줄 31」과 다르다 — 그쪽은 화면 갈래 판정(`campaignPeriodRowKind`, NULL 포함) 기준. 시나리오 3 대상은 **화면 갈래로 다시 센다** |

---

## ⚠️ 사양서 stale 점검 (규칙 A — 코드 직접 확인 결과)

사양서 「착수 전 알아야 할 것」의 코드 쪽 항목을 실제로 확인했다. **6건이 사실과 다르거나 사양서에 없다.**

### 🔴 1. 빌드 순서 서술이 틀렸다 (사양서 「착수 전」 3번째 줄)

사양서: 「`brandLabelAdmin`·`channelChipsHtml` 이 `admin.js` 에 있으므로 빌드 순서상 `admin-brand-ops.js` 보다 **뒤**다」 → **둘 다 admin.js 에 없다.**

| 이름 | 실제 파일 | `admin-brand-ops.js` 기준 | 종류 |
|---|---|---|---|
| `brandLabelAdmin` | `dev/lib/shared.js` | **앞** | 함수 선언 |
| `campaignPeriodRowKind` | `dev/lib/shared.js` | **앞** | 함수 선언 |
| `channelChipsHtml` | `dev/js/ui.js` | **앞** | 함수 선언 |
| `dDayLabel` · `formatDate` | `dev/js/ui.js` | **앞** | 함수 선언 |
| `hydrateCampCertBars` · `_brandOpsAuditIds` · `BRAND_OPS_CAMP_STATUS_KO` · `BRAND_OPS_CAMP_STATUS_COLOR` | `dev/js/admin-brand-ops.js` | **같은 파일** | 앞 셋은 함수/`var`, 뒤 둘은 `var` |
| `countCertSuccess` · `buildDeliverableGroups` | `dev/js/admin-deliverables.js` | **뒤** | 함수 선언 |
| `openCampApplicants` | `dev/js/admin-applications.js` | **뒤** | 함수 선언 |
| `openEditCampaign` | `dev/js/admin.js` | **뒤** | 함수 선언 |
| `isCampaignAdminOrAbove` | `dev/js/admin-accounts.js` | **뒤** | 함수 선언 |

⚠️ **실무 결론은 사양서와 같다** — 빌드가 한 덩어리 이어붙이기라 **함수 선언은 전부 앞으로 끌어올려진다(hoisting)**. 위 「뒤」 넷은 전부 함수 선언이므로 렌더 시점에 부를 수 있다. **순서에 걸리는 것은 `var`/`const` 로 만든 값**이다 — 새로 만드는 상수를 `admin-brand-ops.js` 밖에 두고 이 파일의 즉시 실행부에서 읽으면 그때 죽는다.

### 🔴 2. `fetchDeliverables` — 캠페인 id **배열** 필터는 **없다**. 그리고 **실패와 0건을 구분하지 못한다**

`dev/lib/storage.js` `fetchDeliverables(filters)` 확인 결과:

- **현재 인자 3개**: `filters.status` · `filters.kind` · `filters.campaign_id`(단일, `.eq()`). **배열 필터 없음** → 사양서대로 인자를 더해야 한다.
- **이름 겹침 없음** — `campaignIds` 는 위 셋과 안 겹친다.
- **`fetchAllPaged` 를 쓴다** ✅ (1,000행 페이지 반복).
- 🔴 **실패에도 `[]` 를 돌려준다**(`catch(e){ … return []; }`). 사양서 §2 는 「`null`(실패)과 `[]`(0건) 구분」을 요구한다 — 지금 함수로는 **원리적으로 불가능**하다. 반환 규약을 바꾸면 기존 호출부(결과물 관리·엑셀 등)가 전부 `[]` 를 전제하므로 **손대면 안 된다.**
  → **일정 뷰 전용 조회 함수를 하나 더 만든다**(`fetchDeliverablesByCampaignIds(ids)` — 실패에 `null`, 0건에 `[]`. `fetchCampaignDeliverableCounts` 가 같은 규약을 이미 쓴다). 「조각 하나라도 실패하면 그 회차 전체 실패」도 그 함수 안에서 지킨다.
- ⚠️ 임베드 `campaigns:campaign_id (…)` 에 인증 성공 판정에 필요한 값(`recruit_type`·`channel`·`channel_match`·`proxy_purchase`)이 전부 들어 있다(아래 5-② 참조).

### 3. 선정 기간 표시 조건 4곳 — 원문 확인 완료, 주석에 경로 목록 있음 ✅

네 곳이 **글자 그대로 같다**. 정본은 `dev/js/application.js`(그 자리 주석이 나머지 셋을 나열한다).

| # | 파일 · 이름 | 조건 원문 |
|---|---|---|
| ① | `dev/js/application.js` (캠페인 상세 정보표) | `(camp.recruit_type === 'gifting' \|\| (camp.recruit_type === 'visit' && (!isEvent \|\| isSelEvent))) && (camp.selection_start \|\| camp.selection_end)` |
| ② | `dev/js/admin.js` `renderCampPreview` (`kSelectionPeriod`) | `(camp.recruit_type === 'gifting' \|\| (camp.recruit_type === 'visit' && (!isEventPreview \|\| isSelEventPreview))) && (camp.selection_start \|\| camp.selection_end)` |
| ③ | `dev/js/admin-applications.js` `selRange` | `((camp.recruit_type === 'gifting' \|\| (camp.recruit_type === 'visit' && (!isEvent \|\| isSelEvent))) && (camp.selection_start \|\| camp.selection_end))` |
| ④ | `dev/js/admin-excel.js` `pickSelection` | `var wants = (c.recruit_type === 'gifting') \|\| (c.recruit_type === 'visit' && (!isEvt \|\| isSel));` |

- 행사 판정은 공용 헬퍼 `isEventCampaign(camp)` · `isSelectionEvent(camp)`(`typeof … === 'function'` 방어 호출). 새 자리도 같은 방식.
- ⚠️ 네 곳 주석이 공통으로 **「캠페인 목록의 「선정기간」 열은 이 넷이 아니다」**라고 못박는다(`buildCampRow` 의 `periodRangeCell` — 모집 형식을 안 본다). **그 열을 베끼면 안 된다.**
- 「5곳째」는 정확하다 — 새 자리를 더하고 **네 곳 주석에 이 파일 경로를 추가**(작업 7).

### 🔴 4. 「항상 보이는 가로 스크롤바」 선례는 `dev/css/admin.css` 에 **없다**

실제 위치: **`dev/report.html` 안 인라인 `<style>` 의 `.tblwrap`** (2026-09-04).

```
.tblwrap{overflow:scroll;flex:1;min-height:0}
.tblwrap::-webkit-scrollbar{height:12px;width:12px}
.tblwrap::-webkit-scrollbar-track{background:#f1f1f1;border-radius:6px}
.tblwrap::-webkit-scrollbar-thumb{background:#b8b8b8;border-radius:6px;border:2px solid #f1f1f1}
.tblwrap::-webkit-scrollbar-thumb:hover{background:#999}
```

`dev/report.html` 은 자립형 단독 페이지라 `admin.css` 를 안 읽는다 → **재사용 불가, 새 클래스로 옮겨 적는다.** ⚠️ `admin.css` 의 기존 스크롤바 규칙은 전부 **반대 방향**(`.admin-side-scroll` = 마우스 올릴 때만 / `.status-tab-bar` = 완전 숨김). **왜 반대인지 주석**을 남길 것.

### 🔴 5. 사양서에 없는 함정 5건 (전부 조용히 틀리는 유형)

1. **`fetchCampaignsForAdminList()`(가벼운 목록 조회)를 쓰면 안 된다.** `ADMIN_LIST_COLUMNS` 에 **`proxy_purchase`·`first_active_at`·`brand_id` 가 없다.** 쓰면 ①가구매 캠페인 인증 성공이 0 에서 굳고 ②모집 막대 예외 ㄱ이 죽고 ③회사 필터 매핑(S2)이 불가능해진다 — **셋 다 오류 없이 조용히**. 사양서대로 `fetchCampaigns()` 를 쓴다.
2. **`buildDeliverableGroups` 는 결과물 행의 임베드(`d.campaigns`)를 캠페인 맵보다 먼저 쓴다** — `const camp = d.campaigns || campMap.get(d.campaign_id) || null;`. 즉 `countCertSuccess(delivs, camp)` 에 넘긴 `camp` 는 결과물이 1건이라도 있으면 무시된다. 임베드에 판정 값이 전부 있어 안전하다. 결과물 0건이면 인증 성공도 0 이라 어느 쪽이든 같다.
3. **`loadBrandOpsRecentApps()` 가 이미 `fetchCampaigns()`·`fetchInfluencers()`·`fetchApplications()` 전건을 부른다.** 일정 뷰가 `fetchCampaigns()` 를 또 부르면 같은 화면에서 전건 조회가 두 번(자동 상태 전이도 두 번). **한 번 받아 나눠 쓸 것.**
4. **`_brandOpsAuditIds` 는 지금 브랜드 상세(`loadBrandOpsDetail`)에서만 채워진다.** 일정 뷰가 `loadBrandOps` 에서 채우면 두 화면이 같은 전역 값을 공유한다. 값은 같은 집합이라 실해는 낮지만 **채우는 자리가 둘**이 되므로 주석을 남길 것.
5. **`#adminPane-brand-ops` 에는 `admin-pane-list` 클래스가 없다**(`class="admin-pane"`). 간트의 「왼쪽 열 고정 + 시간축만 가로 스크롤」은 **이 페인 안에 자체 구조로** 만든다. ⚠️ 페인에 `admin-pane-list` 를 붙이면 아래 「최근 신청」 표의 배치가 함께 바뀐다 — 붙이지 말 것.

### 6. 나머지 확인 (사양서와 일치 ✅)

| 항목 | 확인 결과 |
|---|---|
| `PANE_REFRESHERS['brand-ops']` | **등록돼 있다** → `loadBrandOps()`. ⚠️ 진입 로더 `switchAdminPane` 의 `loaders` 맵에도 `'brand-ops': loadBrandOps` 가 따로 있다(`admin-core.js`) — 두 곳 다 `loadBrandOps` 라 등록 변경 불필요 |
| 현재 `loadBrandOps()` | ①`fetchCompanies({status:'all'})` → 회사 드롭다운 ②`getBrandOpsOverview(null)` → `_brandOpsCache` ③`renderBrandOpsCards()` ④`loadBrandOpsRecentApps()` |
| 필터 바 요소 id | `brandOpsCompanyFilter` · `brandOpsSortFilter` · `brandOpsSearch` · `brandOpsTotalCount`. **넷 다 인라인 핸들러가 `renderBrandOpsCards()` 를 직접 부른다** → 현재 뷰로 갈라 주는 중계 함수로 바꿔야 한다 |
| 카드 그리드 컨테이너 | `<div id="brandOpsGrid" class="brand-ops-grid">` (필터 바 바깥, 「최근 신청」 카드 위) |
| `status-tab-bar` 패턴 | HTML 은 빈 `<div class="status-tab-bar">` 만 두고 JS 가 채운다. 화면 전환용 선례는 `#campDetailTabBar` + `_campDetailTab`(캠페인 진행현황 신청자/결과물 탭) |
| 정산 페인 뷰 배타 전환 | 실제로는 **두 쌍**: `showUnregisteredTab()`/`hideUnregisteredTab()` + `openPayoutPrepView()`/`closePayoutPrepView()`, 진입 화면 지정 `_settlementEntryView` + `enterSettlementsWithView(view)`. 「켜는 함수가 나머지를 끄는 짝」 원칙은 그대로 |
| `countCertSuccess(delivs, camp)` | 시그니처 확인 ✅. `camp` 없으면 0, 안에서 `buildDeliverableGroups(delivs, new Map([[camp.id, camp]]))` → `computeCertStatus(g)==='success'` 수 |
| `dDayLabel(d)` | 안에서 `new Date(d)` 로 파싱한다 — 기존 공용 헬퍼라 그대로 쓴다(한국·일본은 같은 날). 「`new Date` 파싱 금지」는 **새로 만드는 `ganttDayOffset` 에만** 적용 |
| 빌드 파일 등록 | **새 파일이 없다** → `dev/build.sh` 변경 불필요 |

---

## 한눈에 보는 의존 순서

```
S0(운영 실측 ✅) ┐
S1(하루 폭)      ├→
S2·S3(필터 규칙) ┘

작업 1 (조회 계층)
      ↓
작업 2 (페인 마크업·뷰 전환·필터)
      ↓
작업 3 (시간축·날짜 변환)        ← S1
      ↓
작업 4 (막대·마커)               ← S0③
      ↓
작업 5 (왼쪽 열·숫자·결과물 조회) ← S0①②
      ↓
작업 6 (CSS)
      ↓
작업 7 (문서·주석 5곳째)
```

**병렬 없음.** 작업 2·4·5 가 `dev/js/admin-brand-ops.js` 를 함께 만지고, 작업 2·6 이 `dev/admin/index.html`·`dev/css/admin.css` 를 함께 만진다.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 결과물 조회 계층 — 캠페인 여러 건 묶어 받기 | `dev/lib/storage.js` | `fetchDeliverablesByCampaignIds(ids)` (실패 `null` / 0건 `[]`) · `fetchDeliverables(filters.campaignIds)` | 없음 | ✗ | 개발 |
| 2 | 페인 마크업 · 뷰 전환 · 필터 중계 | `dev/admin/index.html` · `dev/js/admin-brand-ops.js` | DOM id 6종 · `showBrandOpsSchedule()`/`showBrandOpsCards()` · `renderBrandOpsCurrentView()` · `_brandOpsView` · `_brandOpsIncludeEnded` | 1, S2, S3 | ✗ | 개발 |
| 3 | 시간축 — 날짜→위치 변환 · 눈금 · 이동 | `dev/js/admin-brand-ops.js` | `ganttDayOffset(baseYmd, ymd)` · `ganttTodayYmd()` · `_ganttBaseYmd` · `ganttShift(weeks)`/`ganttToday()` · `renderGanttAxis()` | 2, S1 | ✗ | 개발 |
| 4 | 막대 · 마커 · 범위 밖 처리 | `dev/js/admin-brand-ops.js` | `ganttSegmentsFor(camp)` → 요소 배열 · `renderGanttTrack(camp)` | 3, S0③ | ✗ | 개발 |
| 5 | 왼쪽 고정 열 · 숫자 3종 · 결과물 묶음 조회 | `dev/js/admin-brand-ops.js` | `_brandOpsDelivCache` · `loadScheduleDeliverables(ids)` · `renderScheduleRow(camp)` | 4, S0①②, 1 | ✗ | 개발 |
| 6 | CSS — 격자 · 고정 열 · 항상 보이는 가로 스크롤바 | `dev/css/admin.css` | `.gantt-*` 클래스 집합 | 2·4·5 (클래스 이름 확정 뒤) | ✗ | 개발 |
| 7 | 문서 · 선정 기간 조건 주석 5곳째 | `CLAUDE.md` · `dev/js/application.js` · `dev/js/admin.js` · `dev/js/admin-applications.js` · `dev/js/admin-excel.js` · (배포 뒤) Notion | 주석 4곳에 새 경로 추가 | 5 | ✗ | 개발 |

---

## 조각별 상세

### 작업 1 — 결과물 조회 계층: 캠페인 여러 건 묶어 받기

- **하는 일:** 캠페인 id 배열로 결과물을 한 번에 받는 길을 낸다. **실패와 0건을 구분해서** 돌려준다(사양서 §2 요구).
- **담당 파일:** `dev/lib/storage.js`
- **산출 계약:**
  - `fetchDeliverables(filters)` 에 인자 하나 추가 — `filters.campaignIds`(배열) → `q.in('campaign_id', ids)`. 기존 인자 3종과 이름이 안 겹친다. 인자를 안 주면 동작이 종전과 같다.
  - **새 함수 `fetchDeliverablesByCampaignIds(ids)`** — 200개씩 잘라 위 함수를 **차례로** 부르고 합친다. **조각 하나라도 실패하면 `null`**, 전부 성공하고 0건이면 `[]`.
- **선행 의존:** 없음.
- **완료 정의:**
  - 관리자 콘솔에서 `fetchDeliverablesByCampaignIds([id1, id2])` 가 **그 두 캠페인 행만** 돌려준다.
  - `fetchDeliverables({status:'pending'})` 결과 건수가 **변경 전과 같다** — 기존 결과물 관리 화면 무영향.
  - 존재하지 않는 id 만 넣으면 `[]`, 조회를 일부러 막으면 `null`.
  - 빌드 통과.
- **필요 검문소:** `reverb-reviewer`(리뷰 요청 시 「기존 호출부 무영향」 지목). 데이터베이스 변경이 없어 `reverb-supabase-expert` 는 불필요.
- **주의·롤백:** 🔴 **`fetchDeliverables` 의 반환 규약(실패에도 `[]`)을 바꾸지 말 것.** 실패 구분은 **새 함수 안에서만** 한다. 되돌릴 범위는 이 파일 한 곳.

### 작업 2 — 페인 마크업 · 뷰 전환 · 필터 중계

- **하는 일:** 운영현황 페인에 「일정 | 브랜드」 전환 탭·「종료 포함」·시간축 이동 단추·일정 뷰 컨테이너를 넣고, 기존 필터가 **현재 뷰로 갈라 그리게** 바꾼다.
- **담당 파일:** `dev/admin/index.html`(`#adminPane-brand-ops` 안) · `dev/js/admin-brand-ops.js`
- **산출 계약:**
  - DOM id — `brandOpsViewTabBar`(빈 `div.status-tab-bar`, JS 가 채움) · `brandOpsScheduleWrap` · `brandOpsScheduleRows` · `brandOpsAxis` · `brandOpsIncludeEnded` · `brandOpsRangeNav`
  - 상태 — `_brandOpsView`(`'schedule'`|`'cards'`, 기본 `'schedule'`) · `_brandOpsIncludeEnded`(기본 `false`)
  - 함수 — `showBrandOpsSchedule()` / `showBrandOpsCards()`(**서로를 끄는 짝**) · `renderBrandOpsCurrentView()`(필터 인라인 핸들러가 부를 단일 진입점) · `brandOpsScheduleCampaigns()`(대상 집합 + 회사·검색 필터 + 정렬)
  - `localStorage` 열쇠말 — `reverb.brandOps.view`
- **선행 의존:** 작업 1 · S2 · S3.
- **완료 정의 → 검증 시나리오 1 · 2 · 9**
  - 시나리오 1: `reverb.brandOps.view` 를 지운 뒤 진입 → 「일정」이 기본. 「브랜드」로 바꾸면 카드가 그대로 뜨고 **두 뷰가 겹쳐 보이지 않는다.** 다시 진입하면 「브랜드」가 기억된다.
  - 시나리오 2: 행 수 = 캠페인 관리 상태 탭 「모집예정+모집중+모집마감」 합(운영 기준 39). 「종료 포함」을 켜면 「종료+노출종료」만큼 는다(운영 207).
  - 시나리오 9: 새로고침 단추·`refreshPane('brand-ops')` 뒤에도 현재 뷰가 유지된다.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:**
  - ⚠️ 기존 필터 4개의 인라인 핸들러가 `renderBrandOpsCards()` 를 직접 부른다 — 그대로 두면 일정 뷰에서 필터를 바꿔도 카드만 다시 그려진다(오류 없음). **전부 `renderBrandOpsCurrentView()` 로.**
  - ⚠️ 정렬 드롭다운은 브랜드 뷰 전용이라 일정 뷰에서 숨긴다(결정 8). 「종료 포함」은 일정 뷰에서만(결정 9).
  - ⚠️ 페인에 `admin-pane-list` 를 붙이지 말 것(stale 점검 5-⑤).
  - ⚠️ `loadBrandOps()` 가 `fetchCampaigns()` 를 **한 번만** 부르고 「최근 신청」과 일정 뷰가 나눠 쓴다(stale 점검 5-③).

### 작업 3 — 시간축: 날짜→위치 변환 · 눈금 · 좌우 이동

- **하는 일:** 날짜 문자열을 정수 일수로 바꾸는 함수 하나를 두고, 그 위에 주 눈금·월 이름표·오늘 세로선·좌우 이동을 얹는다.
- **담당 파일:** `dev/js/admin-brand-ops.js`
- **산출 계약:**
  - `ganttDayOffset(baseYmd, ymd)` → 정수 일수. 두 `연-월-일` 문자열을 연·월·일 정수로 잘라 `Date.UTC` 차이로 계산. `new Date('2026-09-07')` 파싱 금지.
  - `ganttTodayYmd()` → 기기 로컬 연·월·일 문자열. `ganttYmdFromTimestamp(ts)` → 시각 값(`first_active_at`)을 **일본 표준시**로 잘라 `연-월-일`.
  - `_ganttBaseYmd` · `GANTT_DAY_PX`(S1) · `GANTT_RANGE = {before: 14, after: 70}`
  - `ganttShift(weeks)` · `ganttToday()` · `renderGanttAxis()`
- **선행 의존:** 작업 2 · S1.
- **완료 정의 → 검증 시나리오 7(앞부분)** — ‹ › 4주 이동·「오늘」 복귀·오늘 세로선 위치·월요일 경계 눈금. `ganttDayOffset('2026-09-07','2026-09-08') === 1`, 같은 날 `0`, 월·연 경계 통과(콘솔 확인).
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** ⚠️ 눈금 표기(`9월`·`9/7`)는 `formatDate` 규칙 밖(사양서 설계 4). 툴팁·마커 날짜만 `formatDate`.

### 작업 4 — 막대 · 마커 · 범위 밖 처리

- **하는 일:** 캠페인 한 건에서 「그릴 것 목록」을 만들고(구간 이름·시작일·끝일), 표시 범위와 겹치는 만큼 그린다. 겹치는 것이 없으면 가장자리 마커, 목록이 비면 「날짜 없음」.
- **담당 파일:** `dev/js/admin-brand-ops.js`
- **산출 계약:**
  - `ganttSegmentsFor(camp)` → `[{name, startYmd, endYmd|null, lane:'main'|'sub', ink:'strong'|'mid'|'weak', point:boolean}]`
  - `renderGanttTrack(camp)` → 시간축 칸 HTML(막대·마커·D-day 배지·툴팁·`role="img"`+`aria-label`)
- **선행 의존:** 작업 3 · S0③.
- **완료 정의 → 검증 시나리오 3 · 4 · 7(뒷부분) · 10**
  - 시나리오 3: 리뷰어형 `split` 1건 = 모집 + 구매 보조 + 제출. `merged` 1건 = 보조 막대 없음.
  - 시나리오 4: `visit`+선정 없음 = 「방문」 한 줄 / `visitMerged`+선정 없음 = 없음 / `visit`+선정 있음 = 두 줄 / `visitMerged`+선정 있음 = 「선정」 한 줄 / 시딩형 선정 있음 = 「선정」, 없음 = 없음.
  - 시나리오 7 뒷부분: 범위 밖 캠페인이 가장자리 마커로 보이고 빈 줄이 하나도 없다.
  - 시나리오 10: 마감일 빈 캠페인 「마감 없음」(운영 0건 → 개발서버 시험 캠페인으로).
- **필요 검문소:** `reverb-reviewer` · **브라우저 눈 확인 필수**(`browser-qa.md` — 겹침·잘림·톱니는 코드로 안 보인다).
- **주의·롤백:**
  - 🔴 `campaignPeriodRowKind` 갈래는 **이름으로 지목**(`=== 'split'`, `=== 'visit'`). 부정 조건 금지.
  - 🔴 선정 막대(⑤) 조건은 갈래로 가를 수 없다 — stale 점검 3번 표 ①의 조건식을 **글자 그대로** 옮기고 `isEventCampaign`·`isSelectionEvent` 를 부른다.
  - ⚠️ 예외 ㄷ(「날짜 없음」)은 그릴 것 목록이 비었는지로만 본다.
  - ⚠️ D-3 이하는 `dDayLabel` 배지 색으로만 강조(결정 11).

### 작업 5 — 왼쪽 고정 열 · 숫자 3종 · 결과물 묶음 조회

- **하는 일:** 행마다 캠페인·브랜드·형식·채널·상태·숫자 3종·편집 단추를 그리고, 결과물을 대상 집합 단위로 받아 캠페인별로 나눠 제출·인증 숫자를 채운다.
- **담당 파일:** `dev/js/admin-brand-ops.js`
- **산출 계약:** `_brandOpsDelivCache`(대상 집합 열쇠 → 결과물 배열 또는 `null`) · `loadScheduleDeliverables(ids)` · `renderScheduleRow(camp)` · `_brandOpsApprCounts`(`fetchCampaignApplicationCounts()` 결과)
- **선행 의존:** 작업 4 · 작업 1 · S0①②.
- **완료 정의 → 검증 시나리오 5 · 6 · 8 · 9(뒷부분)**
  - 시나리오 5: 숫자 3종이 같은 캠페인의 **브랜드 상세 미니카드·캠페인 진행현황 요약**과 일치. 감사용 계정이 응모한 캠페인으로 1건 확인.
  - 시나리오 6: 매니저 계정으로 「편집」 단추 없음·캠페인명 클릭 됨(**사용자에게 로그인 부탁 — 비밀번호 입력 금지**).
  - 시나리오 8: 결과물 조회를 막으면 제출·인증 두 칸 「—」, 승인/모집 숫자와 막대는 남는다. 조각 크기를 임시로 5로 낮춰 2조각 이상 만든 뒤 한 조각만 막아 **전체가 「—」**인지.
  - 시나리오 9 뒷부분: 결과물 하나 승인·반려 뒤 새로고침 단추 → 제출·인증 숫자가 새 값.
- **필요 검문소:** `reverb-reviewer` · **브라우저 눈 확인 필수**.
- **주의·롤백:**
  - 🔴 `loadBrandOps()` 로 다시 들어오면 `_brandOpsDelivCache` 를 비운다.
  - 🔴 `fetchCampaigns()` 를 쓴다(`fetchCampaignsForAdminList()` 금지 — stale 점검 5-①).
  - ⚠️ 감사용 계정은 제출·인증 두 값에서 화면이 뺀다. `_brandOpsAuditIds` 채우는 자리가 둘이 되므로 주석(stale 점검 5-④).
  - ⚠️ 조회 실패(`null`)와 0건(`[]`) 구분 — 실패는 「—」, 0건은 「0/N」.
  - ⚠️ 「제출/승인」은 승인 0 이면 「—」. 「인증」 분모는 **모집인원**(결정 5).

### 작업 6 — CSS: 격자 · 고정 열 · 항상 보이는 가로 스크롤바

- **하는 일:** 왼쪽 열 고정 + 시간축만 가로 스크롤, 주 눈금 격자, 막대·마커·톱니 모양, 스크롤바 상시 표시.
- **담당 파일:** `dev/css/admin.css`
- **산출 계약:** `.gantt-wrap` · `.gantt-left` · `.gantt-scroll` · `.gantt-axis` · `.gantt-track` · `.gantt-bar`(농도 3단) · `.gantt-marker` · `.gantt-today`
- **선행 의존:** 작업 2·4·5.
- **완료 정의 → 검증 시나리오 7** — 가로 스크롤바가 마우스를 안 올려도 보인다(맥 크롬). 폭을 줄이고 사이드바를 접었다 펴도 왼쪽 열 고정.
- **필요 검문소:** `reverb-reviewer` · **브라우저 눈 확인 필수**.
- **주의·롤백:**
  - 🔴 선례는 `admin.css` 에 없다 — `dev/report.html` 의 인라인 `.tblwrap` 을 옮겨 적는다(stale 점검 4).
  - ⚠️ 기존 스크롤바 규칙과 **방향이 반대**다 — 왜 반대인지 주석.
  - ⚠️ 틀린 선택자는 조용히 버려진다(`:has()` 중첩 등). 브라우저에서 규칙이 살아 있는지 확인.

### 작업 7 — 문서 · 선정 기간 조건 주석 5곳째

- **하는 일:** 선정 기간 조건이 다섯 곳임을 네 곳 주석에 적고, `CLAUDE.md` 「운영 현황 페인」 항목을 **같은 커밋에** 갱신한다.
- **담당 파일:** `dev/js/application.js`(정본 주석) · `dev/js/admin.js` · `dev/js/admin-applications.js` · `dev/js/admin-excel.js` · `CLAUDE.md` · (운영 배포 뒤) Notion 「관리자 가이드 — 운영 현황」
- **산출 계약:** 네 곳 주석 「네 곳」 → 「다섯 곳」 + 새 경로(`dev/js/admin-brand-ops.js` 의 선정 막대). `CLAUDE.md` 에 뷰 2종·인증 성공을 화면에서 계산한다는 사실·5곳째.
- **선행 의존:** 작업 5.
- **완료 정의:** 네 파일 주석에 새 경로가 있고, `CLAUDE.md` 갱신이 기능 커밋과 같은 커밋에 있다.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** ⚠️ 주석만 고친다 — 조건식을 건드리지 말 것. ⚠️ 「캠페인 목록의 「선정기간」 열은 이 넷이 아니다」 문장을 지우지 말 것. ⚠️ Notion 은 운영 배포 뒤(`notion-sync.md`).

---

## ⚠️ 공유 지점 경고 (충돌 주의)

| 파일 | 만지는 조각 | 성격 |
|---|---|---|
| **`dev/js/admin-brand-ops.js`** | 2·3·4·5 (**4개**) | 이 작업의 중심 |
| **`dev/admin/index.html`** | 2 (·6 이 클래스 이름 맞춤) | 🔴 핫스팟 파일(`multi-session.md`) |
| **`dev/css/admin.css`** | 6 (·2 가 클래스 자리) | 관리자 화면 공용 |
| **`dev/lib/storage.js`** | 1 | 🔴 핫스팟 파일 |
| `dev/js/admin.js` · `application.js` · `admin-applications.js` · `admin-excel.js` | 7 (**주석만**) | `admin.js` 는 핫스팟이지만 주석 한 줄이라 위험 낮음 |

🔴 **병렬 금지 — 1명 순차.** `admin-brand-ops.js` 한 파일에 네 조각이 몰려 있고, `storage.js`·`admin/index.html` 은 핫스팟 파일이다.

⚠️ `dev/build.sh` 는 안 건드린다(새 파일 없음). ⚠️ 이 작업이 도는 동안 다른 세션이 캠페인 목록·결과물 관리·정산을 만지면 `admin.js`·`admin/index.html` 에서 부딪힌다.

---

## 🧭 배분 제안

**개발 1명 · 순차 7조각.** 병렬 이득이 없다.

1. **S0 ✅ · S1·S2·S3 채택안**으로 착수.
2. **작업 1 → 2 까지 하고 한 번 멈춰 사용자에게 보인다.** 「일정 뷰가 뜨고 행 수가 맞는다」까지 확인되면 나머지는 그리기라 되돌릴 일이 적다.
3. **작업 3 → 4 → 5** 를 이어서 하고, 4·5 는 반드시 브라우저로 눈 확인.
4. **작업 6 → 7** 로 마무리하고, 커밋 직전 `reverb-reviewer` 호출 후 개발서버 배포. 운영 배포는 사용자 확인(`git.md`).

⚠️ **작업 5 의 시나리오 5(숫자 대조)가 이 작업의 진짜 검문소다.** 같은 숫자를 세 화면이 각각 계산하므로, 어긋나면 그리기를 다듬지 말고 **계산 자리부터** 본다.
