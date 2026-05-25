# 코드맵: 인플루언서 앱 (모바일)

> ⚠️ **작업 시작점 지도** — 줄 번호는 자동 생성 초안이라 오차 가능. 실제 수정 전 함수명으로 grep 재확인.
> 생성: 2026-05-20 (병렬 Explore). 갱신 규칙: [README](./README.md)

## 개요
인플루언서 앱은 캠페인 목록 조회·응모·활동관리·프로필 관리·메시지 등 인플루언서 전체 플로우를 담당하는 모바일 웹 앱. 단일 페이지 앱(SPA) 구조로 해시 라우팅 사용.

## 기능 그룹별 함수 인덱스

### 라우팅·앱 부트 (app.js)
- `navigate()` — 페이지 전환·라우팅. 캠페인 카드 클릭·해시 변경 시 활성 페이지 토글 (app.js:29~87)
- `navigateBackFromDetail()` — 캠페인 상세에서 뒤로가기 (app.js:18~27)
- `updateActiveNav()` — 햄버거 메뉴 활성 항목 표시 (app.js:152~158)
- `handleUnsubscribePage()` — 메일 1-click 수신거부 처리 (app.js:91~114)
- `setupPTR()` — Pull-to-Refresh 제스처 (app.js:166~242)
- `init()` — 앱 초기화: 캠페인 로드·세션 복원·비밀번호 복구 감지·URL 라우팅 (app.js:247~395)
- `detectRecoveryUrlEarly()` — 스크립트 로드 직후 비밀번호 재설정 URL 감지 (app.js:6~14)
- popstate / langchange 이벤트 리스너 — 뒤로가기·언어 전환 시 재렌더 (app.js:117~149)

### 회원가입·로그인·비밀번호 재설정 (auth.js)
- `updateGnb()` — GNB 우측 업데이트·햄버거 메뉴 재렌더 (auth.js:5~13)
- `handleSignup()` — 회원가입 폼 제출. 이메일 인증 대기 또는 프로필 생성 (auth.js:15~81)
- `handleLogin()` — 로그인. Supabase 인증·관리자/인플루언서 분기 (auth.js:83~131)
- `handleLogout()` — 로그아웃 (auth.js:133~137)
- `handleForgotPassword()` — 비밀번호 초기화 요청·복구 메일 발송 (auth.js:140~177)
- `handleResetPassword()` — 비밀번호 재설정·정책 검증 (auth.js:179~227)
- `goStep()` — 회원가입 단계 네비게이션 (auth.js:230~264)
- `validatePasswordPolicy()` — 비밀번호 정책 검증 (ui.js:325~336)

### 캠페인 목록·상세·필터 (campaign.js)
- `loadCampaigns()` / `visibleCamps()` — 캠페인 로드·인플 표시 필터(active/scheduled/closed) (campaign.js:20~31)
- `sortByStatusAndDeadline()` — 정렬: 모집중 > 예정 > 완료 (campaign.js:38~47)
- `updateStats()` / `buildChannelFilters()` — 통계·채널 필터 빌드 (campaign.js:52~68)
- `loadCampaignsPage()` / `setCampPageType()` / `setCampPageStatus()` — 캠페인 페이지·필터 (campaign.js:74~128)
- `setupCampPageHeaderAutoHide()` / `toggleCampPageSearch()` — 헤더 자동숨김·검색 (campaign.js:136~208)
- `renderCampaignGrid()` / `buildCampCards()` / `renderCampaigns()` — 그리드·카드 렌더 (campaign.js:210~331)
- `filterCampType()` / `filterCamps()` / `applyHomeFilter()` — 홈 화면 필터 (campaign.js:230~253)

### 캠페인 상세·신청 모달 (application.js)
- `openCampaign()` — 캠페인 상세 페이지: 슬라이드·정보표·가이드·하단 고정 바 (application.js:5~291)
- `openApplyModal()` — 응모 모달 오픈 (application.js:296~309)
- `hasCaution()` / `renderCautionItemsHtml()` / `renderNgItemsHtml()` / `renderApplyCaution()` — 주의사항·NG 렌더 (application.js:311~379)
- `submitApplication()` — 신청 제출: 중복 체크·슬롯 초과 차단·주의사항 스냅샷 저장 (application.js:381~477)
- `handleFloatApply()` — 하단 고정 바 신청 버튼: 필수 정보·팔로워 검증 (application.js:480~541)
- `detectChannelFromUrl()` / `onPostUrlInputChange()` — 게시물 URL 채널 자동 판별 (application.js:698~739)

### 활동관리·결과물 제출 (application.js)
- `openActivityPage()` — 활동관리 페이지: 신청 유형별 섹션 (application.js:559~695)
- `loadDeliverablesForActivity()` — 결과물 로드: 영수증/게시물/리뷰 캡쳐 (application.js:771~819)
- `onActivityCancelClick()` — 활동관리 「취소」 버튼 (application.js:754~766)

### 마이페이지·프로필·신청 관리 (mypage.js)
- `loadMyPage()` — 마이페이지 진입: 프로필 새로고침·배지·응모이력 (mypage.js:4~99)
- `loadMyApplications()` / `renderMyApplyTabs()` / `renderMyApplyList()` — 응모이력 탭·목록 (mypage.js:104~266)
- `refreshMyMsgUnread()` — 메시지 미읽음 배지 (mypage.js:269~280)
- `openCautionCompareModal()` — 주의사항 비교(동의 시점 vs 현재) (mypage.js:309~340)
- `saveProfile()` / `savePaypalInfo()` / `changePassword()` — 프로필·PayPal·비밀번호 저장 (mypage.js:342~413)
- `toggleMarketingEmail()` — 메일 수신 설정 토글 (mypage.js:417~433)
- `openMypageSub()` / `closeMypageSub()` — 서브메뉴 전환 (mypage.js:435~446)
- `openApplyActionModal()` — 응모이력 카드 ⋮ 메뉴 (결과물 제출/응모 취소) (mypage.js:521~558)

### 응모 취소 (mypage.js)
- `_computeCancelPhase()` — 취소 phase 계산(클라이언트) (mypage.js:496~513)
- `openCancelModalFor()` — 취소 페이지: phase별 경고·사유 필터 (mypage.js:575~643)
- `submitCancelApplicationFromPage()` — 취소 제출: phase별 필수 필드 (mypage.js:695~756)
- `openCancelDetailModal()` — 취소된 신청 상세 (mypage.js:758~781)
- `isApplicationCancelled()` — cancelled 상태 판정 (mypage.js:789~792)

### 알림·햄버거 메뉴 (notifications.js)
- `openNavPanel()` / `closeNavPanel()` / `renderNavMenu()` — 햄버거 메뉴 패널 (notifications.js:9~65)
- `startNotifPolling()` / `stopNotifPolling()` / `refreshNotifBadge()` — 알림 배지 30초 폴링 (notifications.js:80~142)
- `openNotifModal()` / `renderNotifModal()` / `onNotifItemClick()` — 알림 모달 (notifications.js:161~236)
- `markAllNotifRead()` — 전체 읽음 (notifications.js:251~256)

### 응모건 메시지 (messaging.js — PR 1)
- `openMessageModal()` / `closeMessageModal()` — 메시지 모달 (messaging.js:17~58)
- `renderMessageThread()` — 메시지 스레드 렌더(카드 형식·마스킹 상태별) (messaging.js:61~119)
- `loadMsgAttachThumb()` / `openMsgLightbox()` — 첨부 signed URL·라이트박스 (messaging.js:122~138)
- `confirmWithdrawMessage()` — 메시지 회수(25분 한도) (messaging.js:141~152)
- `onMsgAttachSelected()` / `removeMsgAttach()` / `renderMsgAttachPreview()` — 첨부 관리 (messaging.js:155~178)
- `sendMessageFromModal()` — 메시지 전송: 첨부 업로드 후 전송 (messaging.js:181~221)

### 공통 UI 유틸 (ui.js)
- `esc()` — HTML 이스케이프(XSS 방지) (ui.js:14~17)
- `markRequired()` / `clearRequired()` — 필수 필드 경고 (ui.js:20~39)
- `cleanUrl()` — 마크다운 링크에서 URL 추출 (ui.js:42~47)
- `friendlyErrorJa()` — 에러 → locale(한/일) 변환 (ui.js:102~120)
- `toast()` / `loading()` / `$()` / `formatDate()` / `formatDateTime()` / `dDayLabel()` — 기본 유틸 (ui.js:122~137)
- `imgThumb()` / `renderCroppedImg()` — 썸네일·이미지 렌더 (ui.js:141~157)
- `getChannelLabel()` / `getLookupLabel()` / `getRecruitTypeLabelJa()` — lookup 라벨 (ui.js:166~198)
- `getStatusBadge()` — 응모 상태 배지 (ui.js:213~227)
- `openModal()` / `closeModal()` / `openImageLightbox()` — 모달 공통 (ui.js:241~275)
- `slideMove()` / `slideTo()` — 이미지 슬라이더 (ui.js:279~298)
- `togglePw()` / `lookupZip()` / `lookupZipProfile()` — 비밀번호·우편번호 (ui.js:338~380)
- 캠페인 이미지 크롭·드래그 일체: `handleCampImgSelect`, `addImagesToList`, `openCropModal`, `applyCrop` 등 (ui.js:471~681)
- 약관 모달: `openLegalModal` / `buildLegalContent` / `toggleAgreeAll` (ui.js:691~742)

## 진입점 / 라우팅 (해시 기반)
```
#home            홈 (캠페인 목록)
#campaigns       캠페인 페이지 (전체·필터·검색)
#detail-{id}     캠페인 상세
#mypage          마이페이지 / #mypage-{sub} 서브메뉴
#activity        활동관리 (영수증·게시물 제출)
#app-cancel      응모 취소
#login #signup #forgot #reset-pw   인증
#unsubscribe?token=...             메일 1-click 수신거부
#admin           관리자 페이지 (별도)
```
`navigate()` 동작: 페이지명 정규화(`detail-123`→`detail`) → 히스토리 기록 → active 클래스 → 페이지별 진입 로직 호출 → 햄버거 메뉴 활성 표시.
초기 라우팅: 비밀번호 복구 플래그 감지 시 `#reset-pw` 강제, 그 외 해시별 진입, 나머지 `#home`.

## 관련 데이터베이스 객체
- **테이블**: campaigns, applications, deliverables, notifications, application_messages, influencers
- **storage.js 주요 함수**: fetchCampaigns, fetchLookups, incrementViewCount, insertApplication, checkDuplicateApplication, countActiveApplications, fetchDeliverablesForUser, insertDraftDeliverable, submitDrafts, updateInfluencer, fetchMyNotifications, fetchApplicationMessages, sendApplicationMessage, cancelApplication, unsubscribeByToken (자세한 목록·줄 번호는 데이터 계층 코드맵 참조)

## 파일 간 의존
- 모든 파일이 **storage.js**(데이터베이스 호출), **shared.js**(richHtml/sanitizeRich/db), **ui.js**(toast/formatDate/라벨)에 의존
- `application.js` → 신청·결과물 함수, 슬라이더, 주의사항 sanitize
- `mypage.js` → 프로필·취소·메시지 미읽음 함수
- `messaging.js` → 메시지 5종 함수 + 첨부 업로드/회수
- `notifications.js` → 알림 5종 함수

## 핵심 데이터 흐름
DOMContentLoaded → `init()` → `navigate()` → storage.js 함수 → Supabase 데이터베이스/원격 호출 함수 → UI 렌더. 전역 상태: `currentUser`, `currentUserProfile`, `allCampaigns`, `_myApps` 등.
