# 코드맵: 관리자 앱 (admin.js)

> ⚠️ **작업 시작점 지도** — 줄 번호는 자동 생성 초안이라 오차 가능(시작·끝 역전 등). 실제 수정 전 함수명으로 grep 재확인.
> 생성: 2026-05-20 (병렬 Explore). 갱신 규칙: [README](./README.md)

## 개요
REVERB 관리자 페이지의 핵심 로직 모음. 페인 단위 분리 진행 중이며 현재는 단일 파일(약 9,545줄)로 운영 중. 캠페인·신청·인플루언서·공지사항·기준 데이터·결과물 검수 등 7개 페인과 광고주(브랜드) 관리 페인 포함.

## 기능 그룹별 함수 인덱스

### 라우팅 / 코어 헬퍼
- `switchAdminPane(pane, el, pushHistory)` — 페인 간 전환 + flatpickr 열기/닫기 + 사이드바 활성 상태 반영 (admin.js:154~265)
- `initMultiFilters()` — 다중선택 필터 상태 초기화 (재호출 방지) (admin.js:282~314)

### 에러 / 캐시 관리
- `friendlyError(msg)` — 데이터베이스/네트워크 에러를 사용자 친화적 한국어로 변환 (admin.js:130~146)
- `loadAdminEmails()` — 관리자 이메일 목록 캐시 로드 (admin.js:269~272)
- `isAdminEmail(email)` — 관리자 이메일 여부 조회 (admin.js:274)
- `adminBadge(email)` — 관리자 배지 HTML 생성 (admin.js:275)

### 공통 셀 헬퍼 (표 렌더)
- `formatReviewer(name)` — 검수자명 포맷 (admin.js:476~481)
- `msgCell(text, app)` — 메시지 셀 (말줄임 표시) (admin.js:483~491)
- `openMsgModal(btn)` — 메시지 전문 모달 열기 (admin.js:493~500)
- `consentBadge(app)` — 주의사항 동의 여부 배지 (admin.js:502~506)
- `openCautionConsentModal(appId)` — 주의사항 동의 내용 조회 모달 (admin.js:508~560)

### 다중선택 필터 (동적 UI)
- `syncMultiFilter(containerId, allLabel, options, onChange)` — 다중선택 필터 옵션·상태 동기화 (admin.js:614~637)
- `syncCampMultiFilter(containerId, sortedCamps, onChange, counts)` — 캠페인 필터용 특화 버전 (admin.js:639~655)
- `createMultiFilter(containerId, allLabel, options, onChange)` — 신규 다중선택 필터 생성 (admin.js:657~717)
- `getMultiFilterValues(containerId)` — 현재 선택된 필터값 배열 조회 (admin.js:719~730)
- `resetMultiFilter(containerId, allLabel)` — 필터 초기화 (admin.js:581~589)
- `updateFilterResetBtn(btnId, multiIds, searchId)` — 초기화 버튼 가시성 갱신 (admin.js:591~596)

### 확인/경고 모달
- `showConfirm(message)` — 확인 모달 표시 (Promise 반환) (admin.js:1654~1660)
- `resolveConfirmModal(ok)` — 확인 모달 해제 (admin.js:1662~1675)

### 태그 입력 (캠페인 해시태그/멘션)
- `initTagInput(wrapId)` — 태그 입력 필드 초기화 (Enter/쉼표 구분 + 금지문자 필터) (admin.js:56~96)
- `addTag(wrapId, targetId, prefix, text)` — 태그 추가 (DOM + 숨김 필드 동기) (admin.js:98~106)
- `syncTagValue(wrapId, targetId, prefix)` — 태그 → 숨김 필드 동기 (admin.js:108~114)
- `loadTagsFromValue(wrapId, targetId, prefix, value)` — 숨김 필드 → 태그 UI 역로드 (admin.js:116~123)

## 페인 단위 진입점

### 대시보드 (Dashboard)
- `loadAdminData(preloaded)` — 캠페인·인플루언서·신청 병렬 로드 + KPI 렌더 + 최근 신청 표 (admin.js:323~404)
- `renderCampaignBreakdown(camps)` — 캠페인 상태·채널별 분포 차트 (admin.js:405~451)
- `renderSignupKPIs(users)` — 회원가입 KPI 렌더 (admin.js:6783~6796)
- `renderSignupChart(users, days)` — 회원가입 추이 라인 차트 (admin.js:6798~6857)
- `renderProfileCompletion(users)` — 프로필 완성률 게이지 (admin.js:6865~6906)
- `renderAddressDistribution(users)` — 배송지 도도부현 분포 Top N (admin.js:6733~6781)

### 캠페인 관리 · 목록
- `loadAdminCampaigns(useCache)` — 캠페인 목록 렌더 + 필터/정렬 적용 (admin.js:831~1051)
- `filterAdminCampaigns()` — 필터 변경 시 목록 새로고침 (admin.js:453)
- `toggleCampSort(key)` — 정렬 키 토글 + 방향 전환 (admin.js:732~741)
- `updateSortArrows()` — 정렬 화살표 시각화 (admin.js:744~758)
- `resetCampSort()` — 기본 정렬(생성순 역순) 복원 (admin.js:455~462)
- `updateTableScrollHeight(paneId)` — 테이블 스크롤 높이 동적 조정 (admin.js:568~579)
- `getCurrentFilteredCamps()` — 현재 필터 적용된 캠페인 배열 (admin.js:829)
- `enterReorderMode()` / `exitReorderMode()` — 재정렬 모드 전환 (admin.js:789~805)

### 캠페인 관리 · 등록/편집
- `openEditCampaign(campId)` — 캠페인 편집 폼 열기 (admin.js:1141~1285)
- `saveCampaignEdit()` — 편집 폼 저장 (민감 변경 잠금 통과 후) (admin.js:2311~2470)
- `saveCampaignNew(prefix)` — 신규 캠페인 저장 (admin.js:4296~4412)
- `duplicateCampaign(campId)` / `deleteCampaign(campId, campTitle)` — 복제/삭제 (admin.js:2476~2578)

### 캠페인 폼 · 날짜 선택기 (flatpickr)
- `setupCampRangePickers()` — 모집 기간(범위) flatpickr 마운트 (admin.js:2188~2265)
- `setupCampSinglePickers()` — 결과물 제출/공개 flatpickr 마운트 (줄 번호 확인 필요)
- `validateCampDateRanges(prefix)` — 범위 유효성 검증 + 경고 (admin.js:1769~1824)
- `syncCampDateMinMax(prefix)` — min/max 속성 동기화 (admin.js:1704~1750)

### 캠페인 폼 · Quill 리치 에디터
- `getRichEditor(id)` / `setRichValue(id, html)` / `getRichValue(id)` — 에디터 인스턴스 관리 (admin.js:1056~1139)

### 캠페인 폼 · 민감 변경 감지/잠금
- `detectSensitiveChange(editPayload)` — 민감 변경 감지 (참여방법/주의사항/NG사항/슬롯) (admin.js:1327~1372)
- `showSensitiveChangeConfirm({...})` — 민감 변경 확인 모달 (admin.js:1374~1461)
- `applyEditFormSensitiveLocks(status)` — closed 캠페인 필드 비활성화 (admin.js:1293~1325)

### 캠페인 폼 · 주의사항 변경 이력
- `openCautionHistoryModal(campId)` — 주의사항 변경 이력 모달 열기 (admin.js:1473~1492)
- `renderCautionHistoryModal()` — 이력 목록 렌더 (admin.js:1494~1613)

### 캠페인 폼 · 참여방법/주의사항 번들
- `populateCampPsetDropdown(prefix, recruitType, currentSetId)` — 참여방법 번들 드롭다운 (admin.js:5948~6005)
- `renderCampSteps(prefix)` / `renderCampBundleSummary(kind, prefix)` — 번들 렌더 (admin.js:6007~6184)
- `populateCampCsetDropdown(prefix, recruitType, currentSetId)` — 주의사항 번들 드롭다운 (admin.js:6076~6100)

### 캠페인 폼 · 브랜드/소스 신청 선택
- `loadCampBrandSelect(prefix, currentBrandId)` — 브랜드 셀렉트 로드 (admin.js:8800~8814)
- `onCampBrandChange(prefix)` — 브랜드 변경 시 소스 신청 초기화 (admin.js:8816~8856)
- `loadCampSourceAppSelect(prefix, brandId, currentAppId)` — 소스 신청 셀렉트 로드 (admin.js:8858~8895)

### 신청 관리
- `loadApplications()` — 신청 관리 페인 로드 (캐시 무효화 + 목록 렌더) (admin.js:4049~4051)
- `renderAppCampList()` — 신청 목록 렌더 (필터/정렬/캐시 포함) (admin.js:4101~4287)
- `toggleAppSort(key)` / `resetAppSort()` — 정렬 토글/초기화 (admin.js:4056~4099)

### 캠페인별 신청자
- `openCampApplicants(campId, campTitle)` — 캠페인별 신청자 페인 열기 (admin.js:3025~3033)
- `loadCampApplicants()` — 캠페인별 신청자 목록 로드 + 렌더 (admin.js:3035~3119)
- `renderOtCell(a, isPostType)` / `onOtToggle(appId, checkbox)` — OT(발송) 체크 (admin.js:3136~3164)
- `renderDelivCell(list, appStatus, ...)` / `isApplicationComplete(...)` — 결과물 제출 현황 셀 (admin.js:3166~3208)

### 인플루언서 관리
- `loadAdminInfluencers()` — 인플루언서 목록 로드 + 필터/정렬/렌더 (admin.js:3210~3407)
- `openInfluencerModal(userId)` / `openInfluencerDetail(userId)` — 상세 모달 열기 (admin.js:3450~3551)
- `onInfluencerVerifyToggle(userId, checkbox)` — 인증 상태 토글 (admin.js:3610~3643)
- `onInfluencerBlacklistToggle(userId, checkbox)` — 블랙리스트 상태 토글 (admin.js:3645~3680)
- `recordInfluencerViolation(userId)` / `openViolationDetail(flagId)` — 위반 기록 추가/조회 (admin.js:3700~3864)
- `handleFlagUpload(input, flagId)` — 증거 파일 선택 + 업로드 (admin.js:3868~3958)

### 결과물 검수
- `loadDeliverables()` — 결과물 페인 로드 (admin.js:6946~6948)
- `refreshDelivSidebarBadge()` — 결과물 검수 대기 배지 갱신 (admin.js:6950~6964)
- `renderDeliverablesList()` — 결과물 목록 렌더 (필터/정렬/lazy 포함) (admin.js:6963~7211)
- `openDelivDetail(id)` / `closeDelivDetail()` — 상세 모달 (admin.js:7213~7300)
- `approveDeliv(id, version)` / `revertDeliv(id, version)` — 승인/취소 (admin.js:7302~7335)
- `openDelivRejectModal(id, version)` / `submitDelivReject()` — 반려 모달/제출 (admin.js:7337~7416)

### 결과물 · 통합 보기/영수증
- `openDelivCombined(applicationId)` — 통합 보기 모달 열기 (admin.js:7439~7445)
- `renderReceiptInfoBlock(d)` — 영수증 정보 블록 렌더 (admin.js:7548~7592)
- `enterReceiptEditMode(id)` / `saveReceiptEdit(id)` — 영수증 편집 (admin.js:7594~7637)
- `toggleReceiptHistory(id)` — 영수증 변경 이력 토글 (admin.js:7639~7677)

### 결과물 · 이미지/타임라인
- `openImageLightbox(url)` / `closeImageLightbox()` — 라이트박스 (admin.js:7419~7437)
- `renderDeliverableEventsTimeline(events, scopeId)` — 변경 이력 타임라인 (admin.js:7679~7713)

### Excel 내보내기
- `exportSelectedCampaignsApplicants(idsOverride)` — 선택 캠페인 신청자 Excel (admin.js:8031~8158)
- `exportSelectedCampaignsDeliverables(idsOverride)` — 선택 캠페인 결과물 Excel (admin.js:8160~8403)
- `exportCampaignApplicationsExcel(campId)` / `exportCampaignDeliverables(campId)` — 단일 캠페인 Excel (admin.js:8405~8798)

### 공지사항 관리
- `loadAdminNotices()` — 공지사항 페인 로드 + 렌더 (admin.js:9114~9120)
- `renderAdminNotices()` — 공지사항 목록 렌더 (필터/검색 포함) (admin.js:9129~9167)
- `openAdminNoticeView(id)` / `openAdminNoticeEdit(id)` — 보기/편집 모달 (admin.js:9169~9295)
- `onPublishFromView()` / `onUnpublishFromView()` — 발행/비발행 (admin.js:9217~9244)
- `onSaveAdminNotice(mode)` / `onDeleteAdminNotice()` — 저장/삭제 (admin.js:9334~9392)

### 기준 데이터 (Lookups) 관리
- `loadLookupsPane()` — 기준 데이터 페인 로드 (admin.js:4592~4603)
- `switchLookupTab(kind, btn)` — 기준 데이터 탭 전환 (admin.js:4605~4617)
- `renderLookupsTable()` — 기준 데이터 테이블 렌더 (admin.js:4619~4670)
- `enterLookupReorderMode()` / `exitLookupReorderMode()` — 재정렬 모드 (admin.js:4855~4895)
- `openLookupAddModal()` / `openLookupEditModal(rowId)` — 모달 (admin.js:4897~4937)
- `submitLookupForm(isNew)` / `deleteLookup(rowId)` — 저장/삭제 (admin.js:4939~5048)

### 참여방법/주의사항/NG 번들
- `renderPsetTable()` / `submitPsetForm(isNew)` / `deletePset(psetId)` — 참여방법 번들 (admin.js:5051~5295)
- `renderCsetTable()` / `submitCsetForm(isNew)` / `deleteCset(csetId)` — 주의사항 번들 (admin.js:5222~5833)
- `renderNgSetTable()` / `submitNgSetForm(isNew)` / `deleteNgSet(ngsetId)` — NG 번들 (admin.js:5741~6032)

### 계정 관리
- `loadMyAdminInfo()` — 본인 정보 페인 로드 (admin.js:6459~6468)
- `saveMyAdminInfo()` — 본인 정보 저장 (admin.js:6471~6482)
- `changeMyAdminPassword()` — 비밀번호 변경 (admin.js:6484~6507)
- `loadAdminAccounts()` — 관리자 계정 목록 로드 (admin.js:4451~4509)
- `saveAdmin()` — 관리자 저장 (invite 원격 호출 함수 호출) (admin.js:6537~6580)
- `executeRemoveRole()` / `executeDeleteCompletely()` — 역할 제거/완전 삭제 (admin.js:6595~6621)
- `executeResetPw()` / `sendResetEmail()` — 비밀번호 초기화 (admin.js:6631~6688)

## 진입점 / 라우팅

### 사이드바 data-pane → 페인 렌더 매핑
`switchAdminPane(pane)` 의 loaders 객체 (admin.js:187~200):
```
dashboard      → loadAdminData(preloaded)
campaigns      → loadAdminCampaigns(useCache)
applications   → loadApplications()
influencers    → loadAdminInfluencers()
deliverables   → loadDeliverables()
admin-notices  → loadAdminNotices()
admin-accounts → loadAdminAccounts()
my-account     → loadMyAdminInfo()
lookups        → loadLookupsPane()
```
(add-campaign / edit-campaign / camp-applicants 는 campaigns 페인의 서브 컨텍스트)

## 관련 데이터베이스 객체

### 주요 테이블
campaigns, applications, influencers, influencer_flags, deliverables, deliverable_events, receipt_edit_history, admins, lookup_values, participation_sets, caution_sets, ng_sets, admin_notices, campaign_caution_history

### storage.js 호출 함수 (주요)
fetchCampaigns, fetchInfluencers, fetchApplications, fetchDeliverables, fetchDeliverablesByCampaign, fetchLookupsAll, fetchParticipationSetsAll, fetchCautionSetsAll, fetchNgSetsAll, setInfluencerVerified, setInfluencerBlacklist, recordInfluencerViolation, updateDeliverableStatus

### 원격 호출 함수(RPC) — 관리자 전용
invite_admin, remove_admin_role, delete_admin_completely, update_receipt_admin, record_caution_history

## 영역 간 의존
- **shared.js**: richHtml, miniRichHtml, sanitizeRich, extractSnsHandle, snsProfileUrl, retryWithRefresh, refreshPane
- **ui.js**: $(), toast(), esc(), formatDate(), formatDateTime(), imgThumb(), getStatusBadgeKo(), mountLazyList()
- **admin-brand.js**: 광고주 관리 함수 일체 (별도 코드맵 참조)
- **외부 라이브러리**: Quill(리치 에디터), flatpickr(날짜 선택기), ExcelJS(Excel 생성), Chart.js(대시보드)

## 주의사항 (유지보수)
1. **HTML onclick 강결합**: HTML 의 onclick 속성이 함수명을 직접 참조 → 리팩토링 시 함수명 변경하면 호출 끊김. grep 으로 잔존 참조 전수 확인 필수.
2. **상태 변수 일원화**: `_adminEmails`, `_currentDetailInfluencer` 등 전역 상태는 단일 파일에서만 선언.
3. **로더 함수 의존성**: `switchAdminPane` 의 loaders 가 각 페인 함수를 이름으로 참조 → 페인 분리 후에도 전역 존재 필요.
4. **모달 저장 함수는 `refreshPane()` 호출 필수** (`.claude/rules/quality.md` 규칙).
5. **flatpickr idempotent**: range/single picker 마운트는 여러 번 호출돼도 안전하게 설계됨.
