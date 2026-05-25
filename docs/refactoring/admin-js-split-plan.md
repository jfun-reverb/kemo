# admin.js 분할 계획 (admin-js-split-plan)

> `dev/js/admin.js`(약 9,545줄, 함수 249개)를 페인 단위 파일로 점진 분리하기 위한 계획.
> 작성: 2026-05-20 (고문 세션, 읽기 전용 실측 기반). 실제 분리·커밋은 개발 세션.
> 관련 코드맵: [`docs/CODEMAPS/admin-app.md`](../CODEMAPS/admin-app.md)

---

## 1. 왜 분할이 "기술적으로는 쉬운가" — 결정적 사실

`dev/build.sh` 의 관리자 빌드는 **ES 모듈이 아니라 단순 이어붙이기(concat)** 다:

```
ADMIN_JS_FILES=("lib/supabase.js" "lib/shared.js" "lib/storage.js" "js/ui.js" "js/admin-brand.js" "js/admin.js" "admin/app.js")
```

이 파일들을 순서대로 `cat` 해서 하나의 `admin/index.html` 인라인 스크립트로 만든다. 따라서:

- **파일을 쪼개도 런타임은 동일한 단일 전역 스코프**다. `import`/`export` 재배선이 전혀 필요 없다.
- 함수 선언(`function foo()`)은 호이스팅되므로 **파일 순서와 무관하게** 서로 호출 가능하다.
- `admin-brand.js`(함수 119개)가 **이미 이 방식으로 admin.js 에서 분리되어 정상 작동** 중이다 — 검증된 선례.

즉 분리의 본질은 **"함수·전용 상태를 잘라 새 파일로 옮기고 `build.sh` 목록에 추가"** 가 거의 전부다.

---

## 2. 진짜 비용 — 위험 3종

### 위험 A: 모듈 수준 상태 변수 100개의 소속 분류
파일 최상위 `let`/`const`/`var` 가 100개. 여러 페인이 공유하는 것(CORE)과 한 페인 전용을 구분해 올바른 파일에 둬야 한다. 잘못 옮기면 다른 페인에서 `undefined` 참조. → §5 분류표로 사전 정리.

### 위험 B: 시간상 사각지대(TDZ, Temporal Dead Zone)
`let`/`const` 는 함수와 달리 호이스팅돼도 **선언 줄 이전에 접근하면 에러**다. 이어붙이기 순서상 `admin-brand.js` 가 `admin.js` 보다 먼저 로드되므로, 만약 새로 만든 페인 파일이 **최상위(함수 밖)에서** 다른 파일의 `const` 를 참조하면 깨진다.
- **안전 규칙**: 페인 파일의 최상위 코드는 다른 파일의 `let`/`const` 를 참조하지 않는다. 공유 상수·상태는 모두 **`admin-core.js` 로 모아 이어붙이기 순서 맨 앞**에 둔다. 함수 *내부* 참조는 실행 시점에 이미 선언돼 있으므로 안전.

### 위험 C: HTML onclick 강결합 182개
`dev/admin/index.html` 에 `onclick=` 가 182개. 전역 함수명을 직접 부른다. **함수를 옮기는 건 OK(전역 스코프 유지), 이름 변경은 금지.** 옮긴 뒤 잔존 참조를 grep 으로 전수 확인해야 한다.

---

## 3. 분리 전략 — 빅뱅 금지, 페인 점진

`admin-brand.js` 가 증명한 안전 경로를 따른다. **한 번에 하나의 페인**만 분리하는 PR 을 반복한다.

### Phase 0 (선행 필수): `admin-core.js` 추출
공유 헬퍼 + 공유 상태를 먼저 떼어 **이어붙이기 순서 맨 앞**(admin-brand.js 보다도 앞)에 둔다. 이걸 먼저 해야 이후 페인 파일들이 TDZ 걱정 없이 공유 자원을 참조한다.
- 대상 함수(CORE): `switchAdminPane`, `initMultiFilters`, `syncMultiFilter`/`createMultiFilter`/`getMultiFilterValues`/`resetMultiFilter`, `friendlyError`, `loadAdminEmails`/`isAdminEmail`/`adminBadge`, `formatReviewer`/`msgCell`/`openMsgModal`/`consentBadge`/`openCautionConsentModal`, `showConfirm`/`resolveConfirmModal`, `initTagInput`/`addTag`/`syncTagValue`/`loadTagsFromValue`, `openImageLightbox`/`closeImageLightbox`
- 대상 상태(CORE): `_adminEmails`(264), `_multiFiltersInitialized`(277), `_cautionConsentCache`(501), `_confirmResolver`(1649), `currentAdminInfo`(4419)
- 빌드 순서 변경: `("...storage.js" "js/ui.js" "js/admin-core.js" "js/admin-brand.js" "js/admin.js" ...)`

### Phase 1 (저위험 — 독립적, 작은 페인부터)
| 순서 | 페인 | 새 파일 | 비고 |
|---|---|---|---|
| 1 | MY-ACCOUNT | `admin/my-account.js` | 가장 작음. 함수 3~4개 + 사이드바 프로필 |
| 2 | ADMIN-NOTICES | `admin/notices.js` | 자기 완결적. Quill 인스턴스 전용 |
| 3 | LOOKUPS | `admin/lookups.js` | 기준 데이터 + 번들 3종(pset/cset/nset) — 분량 있으나 독립적 |
| 4 | DASHBOARD | `admin/dashboard.js` | Chart.js 차트. `loadAdminData` 는 부트와 얽혀 주의 |

### Phase 2 (중위험)
| 순서 | 페인 | 새 파일 | 비고 |
|---|---|---|---|
| 5 | DELIVERABLES | `admin/deliverables.js` | 검수 모달 + 라이트박스 + 영수증 |
| 6 | INFLUENCERS | `admin/influencers.js` | 목록 + 상세 + 인증/위반/블랙 + 파일 업로드 |
| 7 | CAMP-APPLICANTS | `admin/camp-applicants.js` | 신청자 페인 (OT + 결과물 셀) |
| 8 | APPLICATIONS | `admin/applications.js` | `renderAppCampList` 캐시 공유 주의 |

### Phase 3 (고위험 — 가장 크고 얽힘, 맨 마지막)
| 순서 | 페인 | 새 파일 | 비고 |
|---|---|---|---|
| 9 | CAMPAIGNS · LIST | `admin/campaigns-list.js` | 필터·정렬·복제·삭제·미리보기 |
| 10 | CAMPAIGNS · FORM | `admin/campaigns-form.js` | Quill·flatpickr·민감 변경·번들 폼 통합·brand 셀렉트. 분량 최대 |
| - | EXCEL (공유 유틸) | `admin/excel.js` | 캠페인 목록/신청/결과물 export 공용. Phase 2~3 사이 적절히 |

---

## 4. 각 분리 PR 검증 체크리스트 (페인마다 반복)

```
□ 대상 페인의 함수 전부 새 파일로 이동 (이름 변경 금지)
□ 대상 페인 전용 상태 변수 이동 (§5 분류표 확인), 공유 변수는 admin-core.js 에 둠
□ 이동한 함수가 참조하는 다른 페인 함수/변수가 있으면: 그게 CORE 인지 확인. 아니면 이동 보류
□ dev/build.sh 의 ADMIN_JS_FILES 에 새 파일 등록 (순서: admin-core 다음, 페인 파일들)
□ 새 파일 최상위에서 타 파일 let/const 참조 없음 (TDZ 방어)
□ grep 으로 잔존 참조 확인: 옮긴 함수명이 admin.js 에 호출부만 남고 정의는 없는지
□ grep "onclick=" dev/admin/index.html 의 해당 함수 호출이 여전히 전역에서 잡히는지
□ bash dev/build.sh 에러 없음
□ reverb-reviewer (잔존 참조·stale 호출 전수 체크) — 분할은 누락 위험 높아 필수
□ reverb-qa-tester Light 모드 (해당 페인 클릭·모달·필터 동작)
```

---

## 5. 상태 변수 100개 페인별 소속 분류 (줄 번호는 분할 시점 재확인)

> ⚠️ 줄 번호는 2026-05-20 기준. 분할 전 `grep -nE "^(let|const|var) " dev/js/admin.js` 로 재확인.

### CORE → `admin-core.js`
`_adminEmails`(264), `_multiFiltersInitialized`(277), `_cautionConsentCache`(501), `_confirmResolver`(1649), `currentAdminInfo`(4419)

### CAMPAIGNS · LIST → `admin/campaigns-list.js`
`adminCampSortKey`/`adminCampSortDir`(446-447), `adminReorderMode`(755), `campsLazy`(823), `CAMPS_PAGE_SIZE`(824), `_currentFilteredCamps`(828)

### CAMPAIGNS · FORM → `admin/campaigns-form.js`
`RICH_EDITOR_IDS`(1049), `richEditors`(1050), `_sensitiveChangeResolver`(1373), `_cautionHistoryState`(1471), `editCampImgData`(1628), `editCampImgChanged`(1629), `_editCampOriginal`(1634), `CAMP_DATE_WARN_TARGETS`(1803), `_campRangePickers`/`_campSinglePickers`(1816-1817), `RANGE_KIND_HIDDEN_IDS`(1818), `_previewState`(2649), `_miniEditorLinkPopover`(5435), `_miniEditorImagePopover`(5571), 번들 폼 상태 `_psetState`/`_psetCache`(5919-5920)·`_csetState`/`_csetCache`(6067-6068)·`_nsetState`/`_nsetCache`(6203-6204), `_campBundleModalReturn`(6352), `_campBrandsCache`(8792), `_campAppsCache`(8793)

### CAMP-APPLICANTS → `admin/camp-applicants.js`
`currentCampApplicantId`(3020), `campApplicantsLazy`(3032), `CAMP_APPLICANTS_PAGE_SIZE`(3033)

### INFLUENCERS → `admin/influencers.js`
`currentInfTab`(3201), `infUsersCache`(3203), `_infViolationCounts`(3204), `infSortKey`/`infSortDir`(3269-3270), `infLazy`(3332), `INF_PAGE_SIZE`(3333), `_currentDetailInfluencer`(3554), `_blacklistReasonsCache`(3555), `_violationReasonsCache`(3556), `_cancelReasonsCache`(3557), `CANCEL_PHASE_LABEL_KO`(3560), `_pendingFlagFiles`(3583), `_editingKeptPaths`(3584), `_editingNewFiles`(3585), `_editingKeptUrlMap`(3646), `_currentFlagsCache`(3771), `_editingFlagId`(3866)

### APPLICATIONS → `admin/applications.js`
`currentAppTypeTab`(4042), `currentAppCampId`(4043), `appSortKey`/`appSortDir`(4054-4055), `appLazy`(4089), `APP_PAGE_SIZE`(4090), `_appListCache`(4091)

### ADMIN-ACCOUNTS → `admin/admin-accounts.js`
`_adminEmailKindsCache`(4444), `_adminEmailSubsEditingId`(4510), `_adminEmailSubsModalKinds`(4512)

### LOOKUPS → `admin/lookups.js`
`LOOKUP_KIND_LABEL_KO`(4585), `_currentLookupKind`(4586), `RECRUIT_TYPE_LABEL_KO`(4697), `_lookupReorderMode`(4698), `_formCfg`(4703), `RECRUIT_TYPES_ALL`(5024), `RECRUIT_TYPE_LABEL_JA`(5025), `_psetCurrentSteps`(5026), `MAX_PSET_STEPS`(5027), `_csetCurrentItems`(5197), `MAX_CSET_ITEMS`(5198), `_nsetCurrentItems`(5745), `MAX_NSET_ITEMS`(5746)
> 주의: 번들(pset/cset/nset)은 LOOKUPS(기준 데이터 관리)와 CAMPAIGNS·FORM(캠페인 폼 내 번들 선택) **양쪽에서 쓰인다.** `_pset…/_cset…/_nset…CurrentItems`·`MAX_…` 는 기준 데이터 편집용, `_psetState/_psetCache` 류는 캠페인 폼용. 분할 시 이 경계를 먼저 grep 으로 확정할 것 — 두 페인이 같은 변수를 공유하면 그 변수는 CORE 또는 공용 번들 파일로.

### DASHBOARD → `admin/dashboard.js`
`_allUsers`(6662), `_signupChart`(6663), `_addressDistChart`(6664), `PREFECTURE_KO`(6667), `ADDRESS_DIST_COLORS`(6683)

### DELIVERABLES → `admin/deliverables.js`
`_delivCache`(6901), `_delivDetailCurrent`(6902), `_delivSort`(6903), `delivLazy`(6960), `DELIV_PAGE_SIZE`(6961), `_delivRejectCtx`(7335), `_delivCombinedRefreshAppId`(7437)

### EXCEL (공유) → `admin/excel.js`
`_excelJsLoading`(7776), `_selectedCampIds`(7866), `_exportInProgress`(7869), `_lastExportAt`(7870), `EXPORT_COOLDOWN_MS`(7871)

### ADMIN-NOTICES → `admin/notices.js`
`_adminNoticesCache`(9080), `_adminNoticeCurrent`(9081), `_adminNoticeQuill`(9082), `ADMIN_NOTICE_CAT_LABEL`(9084), `ADMIN_NOTICE_CAT_STYLE`(9090)

---

## 6. 난이도 종합

| 측면 | 난이도 | 근거 |
|---|---|---|
| 기술 메커니즘 | **하** | concat 빌드, import/export 불필요, admin-brand.js 선례 |
| 페인 경계 식별 | **하** | SECTION 주석 + 코드맵으로 이미 매핑됨 |
| 상태 변수 분류 | **중** | 100개. §5 표로 대부분 해소, 번들 공유 경계만 주의 |
| 회귀 검증 | **중~상** | onclick 182개 + 함수 간 호출. PR 마다 grep + reviewer + qa Light 필수 |
| 캠페인 폼 분리 (Phase 3) | **상** | 최대 분량 + 번들/Quill/flatpickr 얽힘. 맨 마지막 |

**결론**: 한 번에 다 하면 "상", **페인 1개씩 점진**이면 각 PR 은 "하~중". 총 11~12개 PR(Phase 0 + 페인 10개 + excel). admin-brand.js 가 이미 깔아둔 길을 따라가면 안전하다.
