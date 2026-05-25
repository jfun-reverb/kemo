# 관리자 캠페인 관리 화면 속도 개선 (코드 최적화, 서버 이관 없이)

**작성일:** 2026-05-22
**작성 세션:** 고문(메인) 세션 — 진단·기획·검증 담당
**구현 세션:** 개발 세션 (별도 worktree, 시퀀셜)
**관련 에이전트:** reverb-planner(계획 수립 완료)

> 운영서버(Supabase)가 호주 시드니, 사용자는 한/일에서 접속 → 네트워크 왕복 지연(latency)이 큼.
> 당장 서버 이관(호주→일본)은 불가하므로 **코드에서만** 개선한다.

---

## 1. 증상

- 관리자 캠페인 관리 화면(`#adminPane-campaigns`)에서 **검색어를 입력하면 목록이 깜빡거리며, 결과가 나오기까지 한참 걸린다.**
- 화면 진입 자체도 느리다.

## 2. 진단 (코드 추적으로 확정)

| # | 위치 | 문제 |
|---|---|---|
| 1 | `dev/admin/index.html:243` | 검색 input 이 `oninput="filterAdminCampaigns()"` — 매 글자마다 즉시 호출, 입력 지연(debounce) 없음 |
| 2 | `dev/js/admin.js:887` | **(최대 병목)** `const allApps = await fetchApplications();` — `loadAdminCampaigns(useCache)` 의 useCache 분기 밖이라 검색/필터/정렬 때마다 **항상** 신청 전건을 호주 서버에서 재조회. 검색어 6글자 = 신청 전건 6회 재조회 |
| 3 | `dev/lib/storage.js:363` | `fetchApplications` 캐시 계층 없음. `select('*')` + `fetchAllPaged`(1000건씩 반복) |
| 4 | `storage.js:37`, `:363` | `fetchCampaigns`·`fetchApplications` 모두 `select('*')` — 목록 렌더(`buildCampRow`)에 안 쓰는 무거운 jsonb 스냅샷(participation_steps/caution_items/ng_items)·rich text 본문까지 전부 전송 |
| 5 | `dev/js/admin.js:840` | 캠페인 페인 진입 시 `loadAdminCampaigns()`(무인자)가 `fetchCampaigns()` 전건 재조회 |

**깜빡임 메커니즘**: 매 글자마다 `await fetchApplications()`(호주 왕복)가 끝난 뒤에야 목록을 비우고 다시 그림 → 네트워크 대기 동안 멈췄다가 갱신.

### 보강 사실 (planner 확인)
- `fetchApplications()` 는 12군데 호출. 무인자 전건 호출: `admin.js:335`(부트), `:887`(검색마다), `:4112`(대시보드), `:8555`(진행현황), `admin/app.js:79`(부트), `admin-brand-ops.js` 2곳.
- `mountLazyList` 에 `reset(newRows)` 이미 구현됨(`dev/js/ui.js`) — 내부에서 `scrollTop=0` + sentinel 재마운트 수행. destroy→재생성과 기능 동일, 객체·observer 재할당 비용만 절감.
- `allCampaigns` 는 admin.js 전용 전역(인플루언서 앱 무관). 단 `fetchCampaigns` **함수 자체**는 인플루언서 앱·관리자 양쪽 공유.

## 3. 확정된 결정 (사용자 승인 완료, 2026-05-22)

| 항목 | 결정 |
|---|---|
| 개선 범위 | 즉효 3종 + 데이터 다이어트 |
| 다이어트 방식 | **목록 전용 조회 함수 신설** (기존 `fetchCampaigns`/`fetchApplications` 보존 → 인플루언서 앱·타 화면 영향 0, DB 변경 없음) |
| 지연 범위 | **검색창만 0.3초 지연**, 타입/상태 드롭다운은 즉시 |
| 신청 카운트 캐시 갱신 | **캠페인 페인 재진입 시 갱신**(기존 `allCampaigns` 캐시와 동일 정책). 검색/필터/정렬은 캐시 재사용(네트워크 0회) |

## 4. PR 분할 (admin.js 핫스팟 → worktree 병렬 금지, 한 세션 시퀀셜)

### PR 1 — 즉효 3종 (A + B + C). DB 변경 없음.
가장 안전하고 효과 큼. 이것만으로 깜빡임·지연 대부분 해소.

**A. 검색/필터/정렬 시 applications 재조회 제거**
- 대상: `dev/js/admin.js` `loadAdminCampaigns`(840~), `887행`.
- 캠페인 목록용 신청 데이터를 모듈 전역(예: `_campListApps`)에 캐시.
  - `useCache=false`(페인 진입·실데이터 갱신)일 때만 `fetchApplications()` 호출 후 `_campListApps`에 저장.
  - `useCache=true`(검색/필터/정렬)일 때는 `_campListApps` 재사용, 네트워크 0회.
  - 형태 예: `const allApps = useCache ? _campListApps : (_campListApps = await fetchApplications());`
- 검증: 검색 입력 시 네트워크 탭에 applications 요청 0건, 페인 재진입 시 1건.

**B. 검색 입력 debounce (~300ms)**
- 대상: `dev/admin/index.html:243` `oninput`.
- `oninput="debouncedFilterAdminCampaigns()"` 로 교체 + admin.js 에 `const debouncedFilterAdminCampaigns = debounce(filterAdminCampaigns, 300)`.
- debounce 헬퍼가 `dev/js/ui.js` 에 없으면 거기 추가(공통 유틸 규칙).
- 타입/상태 드롭다운(`syncMultiFilter` 의 `() => filterAdminCampaigns()`)은 **즉시 호출 유지**(검색 input 만 debounce).

**C. 목록 재렌더 `reset()` 활용 (destroy/재생성 제거)**
- 대상: `dev/js/admin.js:1041~1049`.
- 검색/필터/정렬(`useCache=true`) + 순서변경 모드 아님일 때: `campsLazy` 살아있으면 `campsLazy.reset(camps)` 로 행만 교체. 인스턴스 없을 때(첫 진입)만 `mountLazyList` 생성. 순서변경 모드 진입/이탈은 기존대로 destroy.
- `_currentFilteredCamps` / `updateCampSelectionUI` 동기화는 reset 경로에서도 동일 호출 유지(현재 1051~1054 setTimeout 유지).
- 검증: 검색 시 체크박스 선택·전체선택 indeterminate 정상, 50건 초과 스크롤 추가 로드(sentinel) 정상.

### PR 2 — 데이터 다이어트 (D). PR 1 검증·배포 후.
- 대상: `dev/lib/storage.js`.
- **목록 전용 함수 신설**:
  - `fetchCampaignsForAdminList()` — 목록 표시·정렬·검색에 필요한 컬럼만 select. 후보 컬럼: `id, title, brand, brand_ko, product, product_ko, campaign_no, recruit_type, status, slots, view_count, created_at, updated_at, order_index, img1~img8, image_url, image_crops, emoji, recruit_start, deadline`. (구현 시 `buildCampRow`·정렬·검색에서 실제 참조하는 컬럼을 grep 으로 전수 확인 후 확정)
  - `fetchApplicationsCountLite()` — `campaign_id, status` 만 select (캠페인별 승인/대기 카운트 전용).
- 기존 `fetchCampaigns`/`fetchApplications` 는 손대지 않음.
- `loadAdminCampaigns` 가 위 두 신설 함수를 쓰도록 교체. **단 `allCampaigns` 를 다른 관리자 화면이 무거운 컬럼까지 기대하며 공유하는지** 반드시 확인(공유하면 별도 캐시 변수 분리 필요).
- DB 변경 없음(마이그레이션 불필요).

## 5. 에이전트 호출 지점

- **reverb-supabase-expert**: PR 2 에서 `storage.js` 쿼리 변경 → 권장(행 단위 보안 정책·페이로드 영향 점검). (집계 뷰/원격 함수 옵션은 미채택이라 마이그레이션 없음)
- **reverb-reviewer**: PR 1·2 각 커밋 직전 필수(stale 참조·LazyList reset 회귀).
- **reverb-qa-tester**: 캠페인 관리는 관리자 핵심 플로우 → PR 1 운영 배포 전 Light(S5+S6) E2E(검색·필터·정렬·순서변경·선택·진행현황 카운트 일치).

## 6. 빌드
- 수정 파일(`admin.js`/`ui.js`/`storage.js`/`admin/index.html`) 모두 기존 등록 → `build.sh` 신규 등록 불필요. 수정 후 `cd dev && bash build.sh` 의무.

## 7. 배포
- PR 1: feature → dev PR → reviewer GO + 빌드 후 dev 머지(Claude 진행 가능). 개발서버 검증 후 운영(dev→main)은 사용자 확인.
- PR 2: PR 1 운영 배포·검증 후 착수.

---

## 구현 결과

**구현일:** PR 1 = 2026-05-22, PR 2 = 2026-05-25
**관련 PR:**
- 개발(dev): PR 1 #266 (feature/campaign-list-perf), PR 2 #268 (feature/campaign-list-diet)
- 운영(main): PR 1 #267 (hotfix/campaign-perf-prod), PR 2 #269 (hotfix/campaign-diet-prod) — dev 통째 머지 대신 소스만 재적용 후 재빌드(보류 기능 분리). 2026-05-25 양쪽 운영 반영 확인 (www.globalreverb.com)
- 운영 검증: PR 1 qa light 7/7 PASS, PR 2 qa light 7/7 PASS (편집 폼 무거운 필드·엑셀 내보내기 회귀 없음)

### 초안 대비 변경 사항
- 추가된 것:
  - `fetchCampaignsForAdminList()` — ADMIN_LIST_COLUMNS 컬럼셋(23개)으로 SELECT, autoOpenCampaigns/autoCloseCampaigns 포함
  - `fetchApplicationsCountLite()` — campaign_id + status 2컬럼만 SELECT
  - `ADMIN_LIST_COLUMNS` 상수 — storage.js 최상단 선언, 목록에서 참조하는 컬럼 전수 분석 후 확정
- 빠진 것: 없음 (사양서 전체 반영)
- 달라진 것:
  - `fetchCampaignsForAdminList` 에서 autoOpenCampaigns/autoCloseCampaigns 호출 포함 (사양서 주석 "전환은 fetchCampaigns 경로에서만"에서 변경 — reviewer 경고 2 해소)
  - `changeCampStatus` 의 `allCampaigns = await fetchCampaigns()` 이중 조회 제거 (reviewer 경고 1 해소)
  - `renderCampaigns(allCampaigns)` dead code 제거 (admin 빌드에 campaign.js 미포함)

### 구현 중 기술 결정 사항
- `allCampaigns` 사용처 전수 분석: buildCampRow, changeCampStatus, moveCampOrder, loadCampApplicants, renderCautionHistoryModal, 엑셀 내보내기 4종 — 무거운 컬럼(participation_steps/caution_items/ng_items/리치텍스트)을 참조하는 곳이 없음을 확인 → 설계 분기 (가) 적용
- autoOpenCampaigns/autoCloseCampaigns 는 status/recruit_start/deadline 만 참조하므로 라이트 컬럼셋에서도 정상 작동 확인
- 마이그레이션 없음 (DB 구조 변경 없이 클라이언트 SELECT 컬럼 조정만)
