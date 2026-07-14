# 서비스 건강도 점검 리포트 — 2026-07-14

**모드:** 심층 풀스윕 (사용자 요청)
**직전 점검:** 2026-06-02 (약 6주 경과, 그 사이 주요 기능 다수 머지 — 풀스윕 트리거 충족)
**점검 브랜치:** dev (58d88a1) / main(7cf60e6)이 dev 머지 후 최신, dev↔main 정합
**마이그레이션:** 파일 232개(번호 001~239, 결번 4구간)

---

## 점검한 차원 / 점검 안 한 차원

| # | 차원 | 상태 |
|---|---|---|
| 1 | 기능 회귀 (핵심 플로우) | ✅ 완료 (Playwright) |
| 2 | 죽은·중복·충돌 코드 + 정합성 미러 | ✅ 완료 |
| 3 | 정책 정합성 (약관·개인정보처리방침) | 🟡 부분 — `/약관확인` 별도 실행 권장 (아래 플래그만 기록) |
| 4 | DB 건강도 | ✅ 완료 |
| 5 | 문서 정합성 | ✅ 완료 |
| 6 | 보안 (RLS·시크릿·익명 접근면·CORS) | ✅ 완료 |
| 7 | 성능 | ✅ 완료 |
| 8 | 외부 시스템 정합성 | ✅ 완료 (자동 확인분) + 📋 사람 체크리스트 |
| 9 | UI·UX 정합성 (화면 실물) | ✅ 완료 (Playwright) |

---

## 🔴 우선 조치 (확실 · 영향 큼)

### A. [차원 4] 정산 권한 "잠금"의 재현성 결함 — 마이그레이션에 없는 수동 개입
- 마이그레이션 220·221은 `campaign_admin`에게 `settlement.view`/`settlement.pay`/`menu.settlements`를 **`write`**로 시드한다.
- 그런데 운영은 메모리 기록상 campaign_admin도 **`hidden`으로 잠긴** 상태(super_admin만 정산 노출).
- 이 차이를 만드는 마이그레이션이 217~239 어디에도 없음 → **운영 배포 시 SQL Editor에서 수동 UPDATE로 잠금을 걸었고, 그게 파일에 안 남음.**
- **위험:** 개발서버를 마이그레이션으로 재구축하면 campaign_admin이 정산에 `write` 접근 가능한 상태로 시작 → 운영/개발 어긋남(drift). 정식 런칭 시 권한 해제 절차도 파일 근거가 없음.
- **✅ 운영 DB 실조회 결과(2026-07-14) — 확정:**
  | role | feature_key | access_level | default_level |
  |---|---|---|---|
  | campaign_admin | settlement.view/pay·menu.settlements | **hidden** | **write** |
  | campaign_manager | (동일 3종) | hidden | hidden |
- **⚠️ 실조회로 드러난 추가 위험(예상보다 큼):** `campaign_admin`의 기본값(default_level)이 **`write`** → 최고 관리자(super_admin)가 권한 관리 화면 「기본값 복원」을 누르면 정산이 `write`로 되돌아가 **campaign_admin에게 정산 메뉴가 노출됨**. (개인정보 차단은 baseline이 hidden이라 복원해도 유지되지만, 정산은 baseline이 write라 복원 시 잠금 해제 — CLAUDE.md "정책 변경 시 default_level도 함께 UPDATE" 규칙이 정산엔 안 지켜짐.)
- **조치(개발 세션):** 정식 런칭 전까지 잠금 유지하려면 ①현재값 `hidden` 재현 마이그레이션 + ②`default_level`도 `hidden`으로 맞추기(복원 버튼 방어). 런칭 시 둘 다 write로.

### B. [차원 2] 채널 라벨 폴백이 DB와 어긋남 (lips·@cosme 누락) + 라벨 로직 4벌 중복
- `dev/js/ui.js:192` `CHANNEL_LABEL_FALLBACK` = **5종**(instagram·x·qoo10·tiktok·youtube). DB lookup_values(channel)는 **7종**(+lips·cosme, 마이그 157). → **직접 검증 완료**.
- `getChannelLabel`(ui.js:198)은 캐시 미로드 경로에서 이 폴백으로 강등 → lips/@cosme 캠페인이 raw 코드('lips'/'cosme')로 노출될 수 있음.
- 같은 "채널 코드→라벨" 변환이 최소 4벌 각자 구현: `ui.js:getChannelLabel`(5종), `application.js:getChannelLabelLocal`(7종), `admin-orient.js:OS_CH_LABEL`, `admin-brand.js:CH_LABEL`. 한쪽만 갱신돼 실제로 drift 발생 중.
- **조치:** ui.js 폴백에 lips/cosme 추가 + shared.js 단일 헬퍼로 통합.

### C. [차원 4] 관리자 판정 함수 search_path 규칙 불일치
- `is_admin()`·`is_super_admin()`·`reset_admin_password()`·`create_admin()`이 마이그 023의 `ALTER FUNCTION`으로 `SET search_path = 'public, pg_temp'`로 덮여, 프로젝트 규칙 `SET search_path = ''`와 불일치.
- 마이그 210이 `is_campaign_admin()`만 `''`로 고쳤고, 일부는 놓침.
- **✅ 운영 DB 실조회 결과(2026-07-14):** 실제 위반은 **`is_admin`·`is_super_admin` 2개뿐**. `create_admin`·`reset_admin_password`·`is_campaign_admin`·`has_permission`은 이미 `search_path=""`(정상). → 서브에이전트가 create_admin·reset_admin_password도 위반이라 추정한 건 **오탐**(아래 오탐 기록).
- **위험도 낮음**(본문이 `public.` 스키마 명시 참조, `'public,pg_temp'`는 완전 mutable 아님) 그러나 자체 규칙 위반. 조치: `ALTER FUNCTION public.is_admin() SET search_path=''` + `is_super_admin()` 동일(개발 세션).

---

## 🟡 정리·개선 (확실 · 영향 중간)

### D. [차원 5] CLAUDE.md stale 서술 6건 (모두 확실)
1. 아웃바운드 화면전환 드롭다운 위치: "사이드바 하단" → 실제는 **최상단(로고 아래)** (커밋 6fc336d).
2. 아웃바운드 목록 컬럼: "계정 열·주채널 팔로워 단일 열" → 실제는 **계정 열 삭제·채널별 팔로워 4열** (커밋 02b6ed9·baf83fb).
3. 메시지 자동 번역: "dev — 운영 미배포" → 실제 **운영 빌드에 이관됨(기능은 잠금)** (커밋 dacd9cb).
4. 개인정보처리방침 Google 위탁: "운영 배포 전 필수(PR3)" → **이미 완료** (커밋 0b83ea0, 시행 2026-07-22).

### E. [차원 5] CODEMAPS 전반 미갱신 (재생성 권장)
- `docs/CODEMAPS/admin-app.md`·README가 여전히 "admin.js 단일 파일 9,545줄·분리 진행 중"으로 서술 → 실제는 페인 ~20개 파일로 분리 완료(2026-05-25).
- `data-layer.md`에 `settlements`·`outbound_influencers`·`orient_sheets`·`role_permissions` 등 최근 대형 테이블 **0건 언급**.
- 면책("시작점 지도")이 있어 심각도는 낮으나 실질 가치 크게 하락.

### F. [차원 2] 죽은 코드 22개 (호출 0건 — 주요 10개 직접 재검증 완료)
- storage.js: `insertReceipt`·`fetchReceipts`·`appendPostSubmission`·`insertPostDeliverable`·`fetchOrientSheetsByApplication`·`fetchUnreadAdminNotices`·`deleteFlagEvidenceFiles`
- application.js: `loadReceipts`(별칭 잔재)
- ui.js: `getChannelBadge`·`lookupZip`·`previewSlideImgs`·`toggleOptional`·`toggleEditCH`·`toggleEditCT`·`getLookupLabelsJoined`
- campaign.js: `filterCampType`·`getCampBg`
- admin-brand.js: `_uniformProductValue`·`brandAppStatusBadge`·`brandAppStatusSelect`
- admin-deliverables.js: `certStatusLabelKo`
- ⚠️ `shared.js:canWrite`는 정의만 있고 호출 0 — 단 "동적 권한 write 게이트 미완성 스텁"일 가능성(오탐 주의, 제거 전 확인). write 레벨 권한이 아직 화면 어디에도 안 걸림을 시사.

### H. [차원 9] 로그인 화면 비밀번호 입력칸 한국어 번역 누락 (확실)
- 인플루언서 로그인 화면(`/#login`) 언어를 한국어로 토글해도 비밀번호 입력칸 안내문(placeholder)만 일본어 `パスワードを入力` 고정. 나머지 라벨은 한국어 정상.
- `data-i18n`이 placeholder 속성에는 매핑 누락 추정 → `dev/lib/i18n/ko.js` + 해당 input placeholder 키 점검. (i18n은 개발서버 한정이라 운영 영향은 없음, Minor.)

### I. [차원 9/데이터] 개발서버 아웃바운드 명단 50명 (운영은 917명)
- 화면 실물에서 아웃바운드 명단 상단 카운트가 "총 50명" — 운영은 917명 재이관 완료됐으나 개발서버 `outbound_influencers`는 옛 50명 상태로 보임(UI 버그 아님, 데이터 적재 상태).
- 메모리엔 "개발서버 검증 후 되돌림·운영에만 등록"이라 의도된 상태일 수 있음 → 개발팀 확인 항목(추정).

### G. [차원 7] 성능 개선 여지
1. **Chart.js·Quill 초기 동기 로드** (admin/index.html:45-50, defer/async 없음) → 대시보드·에디터 미방문 화면에서도 블로킹 로드. 동적 로드로 전환 권장(효과 가장 큼). ExcelJS·Tesseract·heic2any는 이미 지연 로드 정상.
2. **admin-brand-ops `hydrateCampCertBars` N+1** (admin-brand-ops.js:290) — 캠페인 미니카드마다 개별 결과물 조회. 집계 RPC 1회로 축소 권장.
3. **admin-orient 목록 lazy-load 누락** (admin-orient.js:172, `mountLazyList` 미사용) + `fetchOrientSheets`가 목록용인데 전체 `data` JSON 블롭까지 로드(storage.js:3636). 시트 대량 누적 시 무거워짐.
4. **`fetchBrandAppHistoryCounts`** (storage.js:2389) — 유일하게 range 루프 대신 `.limit(100000)` → PostgREST 1000행 cap에 잘려 이력 배지가 축소 표시될 수 있음(추정).

---

## 🟢 이상 없음 (확인 완료)

- **[차원 6] 시크릿 노출 0건** — service_role/JWT/SMTP·API 키 리터럴 커밋 없음, `.env` 미추적. 클라이언트는 공개 키(anon 등가)만.
- **[차원 6] Edge Function CORS 정상** — 브라우저 직접 호출 함수는 `notify-orient-sheet` 1개뿐, CORS 헤더+OPTIONS 완비. 나머지 9개는 웹훅/cron이라 CORS 불필요.
- **[차원 4] 신규 테이블 RLS 완비** — settlements·settlement_events·settlement_settings·outbound_influencers 4종 전부 RLS 정책 정의. outbound는 `has_permission('outbound.view')`로 campaign_manager 차단.
- **[차원 4] settlement_events는 RESTRICT** — deliverable_events CASCADE 감사 유실 선례를 의도적으로 회피.
- **[차원 4] lookup_values 코드상 의미 중복 없음** — 과거 @cosme 중복은 마이그 193에서 병합 완료. (단 운영 수기 추가분은 실조회 필요 — 아래 SQL)
- **[차원 4] 마이그레이션 결번 4구간(030·070·085·133~136)은 전부 정상적 번호 관리 부작용** — 데이터 손실 아님. 132→137은 기획서 번호 선점 사례(planning.md 규칙의 실증).
- **[차원 2] 잔존 참조(stale reference) 0건** — 신규 파일 호출 식별자 전량 심볼표 대조, 미해결 없음.
- **[차원 2] OB_CATEGORY_SERIES·ADMIN_PERMISSION_CATALOG·UPCOMING_FEATURES 미러 DB와 정합.**
- **[차원 1] 핵심 플로우 콘솔 에러 0건** — 인플(홈·로그인·캠페인 상세·로그아웃) 5/6 PASS(응모 모달은 개발서버 모집중 캠페인 0건이라 SKIP), 관리자(로그인·대시보드·캠페인·신청·결과물) 5/5 PASS.
- **[차원 9] 채널 라벨 실물 정상** — 캠페인 목록·상세·기준데이터에서 LIPS·@cosme 정상 표기, raw 코드 노출 없음(B의 폴백 drift는 캐시 로드 경로라 실물 미노출). 아웃바운드·정산(super_admin 노출·campaign_admin 숨김 정상)·오리엔시트 화면 렌더 정상, 빈 상태 문구·STAGING 배지 정상.

---

## ✅ 운영 DB 실조회 완료 (2026-07-14 사용자 실행)

| # | 조회 | 결과 |
|---|---|---|
| 1 | 정산 권한 (role_permissions) | **campaign_admin 3종 access_level=hidden / default_level=write 확정** → 위 A(잠금 재현성 결함 + 복원 버튼 위험) |
| 2 | 관리자 판정 함수 search_path | **is_admin·is_super_admin 2개만 `public, pg_temp`(위반)**, 나머지 4개는 `''`(정상) → 위 C, 오탐 2건 걸러냄 |
| 3 | lookup_values 의미 중복 | **0행 — 중복 없음(클린)** |

## 📋 대시보드 사람 체크리스트 (차원 8)

- Brevo 월 쿼터(20,000/월, 갱신 16일) 잔량 + IP 화이트리스트 **Deactivated** 유지
- Auth Confirm email(운영 ON·개발 OFF), Rate limit(운영 100/h·개발 30/h)
- pg_cron 실제 가동: `SELECT * FROM cron.job` — 마이그에 있는 3건(brand-daily-digest·campaign-promo·flags-retention) 외 **관리자/인플 일일 다이제스트 cron이 마이그에 없음** → 대시보드 수동 등록 여부 확인
- Database Webhooks: `notify-orient-submitted`(orient_sheets UPDATE)·`translate-message`(application_messages INSERT) 양 서버 등록 확인
- Edge Function secrets(BREVO_API_KEY·GOOGLE_TRANSLATE_API_KEY·PUBLIC_SALES_URL) 양 서버 설정
- Supabase Billing 미납 경고(메모리 백로그 항목) 확인

---

## 정책(차원 3) — `/약관확인` + 딥리서치 완료

### ✅ 변경 불필요 (이미 정합)
- **메시지 번역 Google 위탁**: 개인정보처리방침 §4(위탁)·§5(국외이전)에 Google LLC 반영됨(시행 7/22).
- **정산(엔화 수동 송금)**: 약관 제13조가 완전 커버. 변경 없음.

### ⚠️ 아웃바운드 명단 917명 — 딥리서치 결론(APPI/PIPA 1차 자료)
운영 DB에 미가입 인플루언서 917명 실데이터 적재 상태. 딥리서치(개인정보보호위원회 FAQ·대법원 2014다235080 등) 결과:

1. **공개 SNS 정보도 양국 모두 '개인정보'** — 일본 APPI는 GDPR과 달리 공개정보 일반 예외가 없음. 한국도 대법원 판례상 공개정보도 보호 대상.
2. **내부 보유(현재)는 적법 가능** — APPI 제21조상 취득 이용목적을 **개인정보처리방침에 사전 공표하면 개별 통지 면제**(웹사이트 게재로 충족). → **방침에 "영업 목적 인플루언서 정보 수집·보유" 이용목적 공표 + 삭제·정정 요구 창구**가 양국 이중 준수의 핵심. 917명이 이미 적재됐으므로 공표 우선.
3. **⚠️ 브랜드에 명단 제공(5단계 브랜드 뷰, 미착수)은 난이도 급상승** — APPI 제27조 '제3자 제공'이라 원칙 사전 동의(옵트인). 옵트아웃은 개인정보보호위원회(PPC) 신고+공표 필수이고 실무상 잘 수리 안 됨. 요배려정보(민감정보) 섞이면 옵트아웃 자체 불가. → **5단계 설계 전 반드시 법률 자문**.
4. **영업 자체 작성 정보(단가·협상 메모·연락 채널)는 공개정보 예외 적용 안 됨** — 별개 취급 대상.

**미해결(변호사 확인 필요):** PIPA 역외적용·한일 관할 우선순위, '공동이용' 스킴 활용 가능성, 한국 이익형량 심사의 B2B 상업 이용 통과 여부.

**결론:** 지금 당장 must 0건. **내부 보유는 방침에 이용목적 공표만 추가하면 적법 가능(우선순위 높음·법률 자문 후 문구 확정)**. 브랜드 제공은 5단계 착수 시 법률 자문 전제.

---

## 오탐 기록
- **[차원 4] search_path 위반 함수 과대 추정**: 서브에이전트(supabase-expert)는 마이그레이션 파일 기준으로 `is_admin`·`is_super_admin`·`create_admin`·`reset_admin_password` 4~5개가 위반이라 추정했으나, 운영 DB 실조회 결과 **실제 위반은 `is_admin`·`is_super_admin` 2개뿐**. `create_admin`·`reset_admin_password`는 이후 어딘가에서 `''`로 재정의돼 이미 정상. → 마이그레이션 파일 정적 분석의 한계(이후 재정의를 못 따라감), 실조회로 걸러냄.
- 그 외 직접 검증한 채널 라벨 폴백·죽은 코드 10개·마이그 결번·정산 권한 잠금은 모두 사실 확인.

## 발견 → 백로그 연결
- A(정산 권한 재현성) → 개발 세션 즉시 인계 후보 + `project_influencer_settlement` 메모리 갱신
- B(채널 라벨 drift) → 개발 세션 인계 (버그성)
- C(search_path) → 개발 세션 인계 (마이그레이션 보강)
- D·E(문서 stale) → 개발 세션이 CLAUDE.md·CODEMAPS 갱신
- F(죽은 코드) → 개발 세션 정리 (canWrite 제외 확인 후)
- G(성능) → 백로그 (즉시성 낮음)
