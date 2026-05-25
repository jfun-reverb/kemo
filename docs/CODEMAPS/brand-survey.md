# 코드맵: 광고주 서베이 (admin-brand.js + sales/)

> ⚠️ **작업 시작점 지도** — 줄 번호는 자동 생성 초안이라 오차 가능. 실제 수정 전 함수명으로 grep 재확인.
> 생성: 2026-05-20 (병렬 Explore). 갱신 규칙: [README](./README.md)

## 개요
`admin-brand.js`(약 3,675줄)는 관리자용 광고주 신청 관리 시스템으로, 신청 목록·현황 대시보드·브랜드 마스터·내부 메모·변경 이력을 관리한다. `sales/` 폴더의 HTML 폼(reviewer.html, seeding.html)은 영업 채널에서 익명 신청을 받으며 `submit_brand_application` 원격 호출 함수로 직접 INSERT 한다.

## 기능 그룹별 함수 인덱스

### 신청 목록·필터·정렬
- `loadBrandApplications()` — 신청 목록 초기화 및 캐시 로드 (목록 진입점) (admin-brand.js:1438~1483)
- `renderBrandApplicationsList()` — 필터·정렬 적용 후 테이블 재렌더 (admin-brand.js:1564~1667)
- `getFilteredBrandApps()` — 폼·기간·상태·검색 필터 및 정렬 결과 반환 (admin-brand.js:1498~1562)
- `resetBrandAppFilters()` — 필터 및 정렬 초기화 (admin-brand.js:1669~1686)
- `toggleBrandAppSort()` — 필드별 정렬 토글 (admin-brand.js:1717~1725)
- `setupBrandAppDateRange()` — flatpickr 기간 선택 마운트 (admin-brand.js:1689~1715)

### 상태 탭 및 배지 (10단계 파이프라인)
- `BRAND_APP_STATUS_TABS[]` — 상태 탭 순서·라벨 정의 (admin-brand.js:31~43)
- `BRAND_APP_STATUS{}` — 상태 라벨·색상 맵 (admin-brand.js:119~130)
- `renderBrandAppStatusTabs()` — 상태 탭 바 렌더·건수 표시 (admin-brand.js:73~93)
- `brandAppStatusBadge()` — 상태 배지 HTML (admin-brand.js:132~135)
- `quickChangeBrandAppStatus()` — 리스트에서 즉시 상태 변경·낙관적 락 (admin-brand.js:233~256)
- `quickChangeBrandAppProductStatus()` — 제품별 상태 변경 (admin-brand.js:199~230)

### 현황 대시보드
- `loadBrandDashboard()` — 대시보드 데이터 로드 및 렌더 (admin-brand.js:561~567)
- `renderBrandDashboard()` — 대시보드 전체 섹션 렌더 (admin-brand.js:581~590)
- `renderBrandKPIs()` — 전체·폼별·월별·대기·완료·평균 처리일·견적 합계 (admin-brand.js:610~655)
- `renderBrandFunnel()` — 전환 깔때기 (admin-brand.js:657~707)
- `renderBrandFormDonut()` / `renderBrandStatusDonut()` — 폼·상태 도넛 (admin-brand.js:709~803)
- `renderBrandTrendChart()` — 일별 추이 바 차트 (admin-brand.js:805~843)
- `renderBrandRecent()` / `renderBrandLongPending()` — 최근 5건 / 장기 대기 (admin-brand.js:852~906)

### 브랜드 마스터
- `loadBrandsPane()` / `renderBrandsList()` — 브랜드 목록 (admin-brand.js:955~1012)
- `openBrandDetailModal()` / `closeBrandDetailModal()` — 브랜드 상세 모달 (admin-brand.js:1014~1039)
- `renderBrandDetailFormHtml()` — 기본·담당자·콘텐츠·메모·신청 내역 섹션 (admin-brand.js:1200~1285)
- `renderBrandContactsRows()` / `addBrandContact()` / `removeBrandContact()` / `setBrandPrimaryContact()` — 담당자 행 관리 (admin-brand.js:1288~1334)
- `saveBrandDetail()` — 브랜드 정보 저장 (admin-brand.js:1374~1383)
- `openNewBrandModal()` / `submitNewBrand()` — 신규 브랜드 등록 (admin-brand.js:1388~1431)
- `renderBrandAppBundleCard()` / `toggleBrandAppBundleCard()` — 신청 내역 카드 (admin-brand.js:1090~1198)

### 신청 등록·수정 (관리자 직접)
- `openNewBrandAppModal()` / `closeNewBrandAppModal()` — 신규 신청 등록 모달 (admin-brand.js:2116~2159)
- `openBrandAppEditModal()` — 신청 수정 모달·prefill·폼 종류 잠금 (admin-brand.js:2062~2114)
- `onNbaFormTypeChange()` / `loadNbaBrandSelect()` / `setNbaBrandMode()` / `onNbaBrandChange()` — 폼 종류·브랜드 선택 (admin-brand.js:2161~2269)
- `addNbaProductRow()` / `removeNbaProductRow()` / `_collectNbaProducts()` — 제품 행 관리 (admin-brand.js:2285~2348)
- `submitNewBrandApp()` — 신규/수정 신청 저장·낙관적 락 (admin-brand.js:2350~2462)

### 신청 행 렌더 (제품 단위 평탄화)
- `renderBrandAppFlatRow()` — 신청 1건 = 제품 N행 평탄화 (admin-brand.js:1864~2033)
- `fmtKrw()` / `fmtDate()` — 통화·날짜 포맷 (admin-brand.js:295~308)
- `renderProductUrlCell()` / `copyBrandProductUrl()` — 제품 URL 셀·복사 (admin-brand.js:1773~1790, 512~514)

### 내부 메모 (제품별)
- `openBrandAppMemoModal()` / `closeBrandAppMemoModal()` / `loadBrandAppMemoList()` / `renderBrandAppMemoList()` — 메모 모달 (admin-brand.js:2467~2538)
- `submitNewBrandAppMemo()` / `enterBrandAppMemoEdit()` / `confirmBrandAppMemoEdit()` / `deleteBrandAppMemoConfirm()` — 메모 CRUD (admin-brand.js:2540~2603)
- `renderMemoCellInner()` / `renderProductMemoDisplay()` / `openBrandAppMemoModalFromCell()` — 메모 셀 (admin-brand.js:2621~2667)

### 변경 이력
- `openBrandAppHistoryModal()` / `closeBrandAppHistoryModal()` — 이력 모달 (admin-brand.js:2036~2053)
- `renderBrandAppHistoryTableHtml()` — 이력 테이블 (제품 sub-field 펼침) (admin-brand.js:2716~2788)
- `toggleBrandAppRowMenu()` — 행 더보기 메뉴 (수정/이력) (admin-brand.js:920~945)

### 인라인 편집 (일정 4종 + 견적·입금)
- `DATE_CELL_CONFIG{}` — 일정 셀 설정 맵 (모집·배송·선정·제출 4종) (admin-brand.js:2826~2831)
- `enterDateRangeEdit()` / `enterDateSingleEdit()` / `confirmDateRangeEdit()` / `confirmDateSingleEdit()` / `_saveDateEdit()` — 일정 인라인 편집 (admin-brand.js:2849~3009)
- `enterRecruitFeeEdit()` / `confirmRecruitFeeEdit()` — 모집비 (admin-brand.js:3118~3199)
- `enterTransferFeeEdit()` / `confirmTransferFeeEdit()` — 이체수수료 (admin-brand.js:3023~3104)
- `enterQuoteSentEdit()` / `confirmQuoteSentEdit()` — 견적서 날짜·URL (admin-brand.js:3220~3308)
- `enterOrientSheetSentEdit()` / `confirmOrientSheetSentEdit()` — 오리엔시트 URL (admin-brand.js:3527~3591)
- `enterPaidAtEdit()` / `confirmPaidAtEdit()` — 입금 날짜 (admin-brand.js:3596~3675)

### 입금 정보·가격체크
- `renderBrandAppPaymentFlagsCell()` / `toggleBrandAppProductPaymentFlag()` / `refreshBrandAppPaymentFlags()` — 4종 입금 칩(모집·상품·이체·무료) (admin-brand.js:3347~3437)
- `renderBrandAppPriceCheckCell()` / `onBrandAppPriceCheckChange()` — 가격체크 드롭다운 (admin-brand.js:3462~3515)

### 엑셀·유틸
- `exportBrandApplicationsExcel()` — 필터·정렬 결과를 xlsx 다운로드 (admin-brand.js:311~488)
- `BRAND_QUOTE_CONST{}` / `calcBrandAppFinalKrw()` — 환율(JPY→KRW)·부가세 계산 (admin-brand.js:1758~1770)
- `_flattenAppsToProducts()` — 신청을 제품 단위로 평탄화 (대시보드·통계) (admin-brand.js:594~608)
- `normalizeBrandUrlInput()` / `safeBrandUrl()` — URL 정규화·안전성 검증 (admin-brand.js:272~293)

### 메모리 캐시
`_brandApps[]`, `_brandAppSort{}`, `_brandAppCurrentId`, `_brandAppActiveStatusTab`, `_brandDashApps[]`, `_brandsCache[]`, `_editingBrandAppId`, `_nbaBrandMode` 등 (admin-brand.js 상단)

## 진입점 / 라우팅
- **#brand-applications** (UI 라벨 "브랜드 서베이") → `loadBrandApplications()`. 탭 쿼리 `?status=new|reviewing|...`
- **#brand-dashboard** → `loadBrandDashboard()`
- **brand-detail-modal** → `openBrandDetailModal(id)`
- **newBrandAppModal** → `openNewBrandAppModal()`
- **brandAppHistoryModal** → `openBrandAppHistoryModal(id)`
- **brandAppMemoModal** → `openBrandAppMemoModal(id, productIdx)`

## 관련 데이터베이스 객체

### 주요 테이블
- `brand_applications` — 광고주 신청 (form_type·status 10단계·products jsonb·견적·payment_flags·version)
- `brands` / `companies` — 브랜드·회사 마스터 (4단 계층: 회사>브랜드>신청>캠페인)
- `brand_application_memos` / `brand_application_memo_reads` — 제품별 메모·읽음 기록
- `brand_application_history` — 신청 변경 감사 (트리거 자동)

### 원격 호출 함수(RPC)
- `submit_brand_application(...)` — 익명 신청 제출 (SECURITY DEFINER, BYPASSRLS) — sales/ 폼이 호출
- `admin_create_brand_application(...)` — 관리자 신청 생성
- `get_brand_app_memo_summaries()` / `mark_brand_app_memos_read(...)` — 메모 요약·읽음
- `refresh_brand_app_product_payment_flags(...)` — 입금 플래그 재계산
- `get_brand_ops_overview(...)` / `get_brand_ops_detail(...)` — 운영 현황 집계
- `link_campaign_to_application(...)` / `unlink_campaign_from_application(...)` — 캠페인↔신청 연결/해제

### 자동 트리거
products 변경 시 estimated_krw·total_jpy·total_qty 재계산, payment_flags 자동 설정, 변경 이력 기록

## 영역 간 의존
- **admin.js**: esc(), $(), toast(), currentUser, formatPhoneDisplay(), loadExcelJS(), mountLazyList(), getMultiFilterValues(), switchAdminPane(), openMsgModal()
- **shared.js**: db, retryWithRefresh(), fetchAllPaged()
- **라이브러리**: ExcelJS, flatpickr, Chart.js, Material Icons

## sales/ 신청 폼
- **파일**: `index.html`(랜딩, 폼 선택), `reviewer.html`(리뷰어 신청), `seeding.html`(나노 시딩 신청), `vercel.json`
- **익명 INSERT 경로**: `sb.rpc('submit_brand_application', { p_form_type, p_brand_name, p_contact_name, p_phone, p_email, p_products, p_billing_email, p_request_note })` → 신청번호 반환
- **동작**: 인증 불필요(anon), SECURITY DEFINER 로 RLS 우회, 신청번호 자동 채번, 트리거가 견적 재계산, 중복 신청 시 23505
- **별도 Vercel 프로젝트** `reverb-sales` (Root Directory=`sales/`), `sales.globalreverb.com` / `sales-dev.globalreverb.com`. UI 한국어, robots noindex, 파일 업로드 없음(텍스트만)
