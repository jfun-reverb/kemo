# 캠페인 생성 폼 — 서베이 신청 연동 자리 정리 (안전 숨김)

**작성일:** 2026-07-15
**작성 주체:** 기획 세션
**성격:** 기능 정리(UI 숨김) — DB 변경 없음
**관련 배경:** 브랜드 서베이 공개 제출이 중단(마이그레이션 206, `brand_survey_settings.submissions_open=false`)되어 신규 서베이 신청이 사실상 안 들어오는 상태. 캠페인 생성 폼의 '서베이 신청 연쇄 드롭다운'이 빈 껍데기가 되어가므로 신규 폼에서 정리한다. 단 기존 연결 데이터·견적 비용 카드는 100% 보존한다.

---

## 현재 상태 (2026-07-15 기준, 코드 직접 확인)

### 관련 코드·DB·UI 진입점

**① 캠페인 폼의 '서베이 신청 연쇄 드롭다운'** (`dev/js/admin.js`)
- 진입: 브랜드 `<select>` 의 `onCampBrandChange('new'|'edit')`
  - HTML: `dev/admin/index.html:346`(edit), `:624`(new)
- `onCampBrandChange(prefix)` — `admin.js:3466`: 브랜드 없으면 `#{prefix}CampSourceAppContainer` 숨김, 있으면 표시 후 `loadCampSourceAppSelect(prefix, brandId)` 호출 (`:3479~3489`)
- `loadCampSourceAppSelect(prefix, brandId, currentAppId)` — `admin.js:3508`: `fetchBrandApplicationsByBrand(brandId)` 로 신청 목록 로드 → 숨김 native `<select>` `#{prefix}CampSourceAppId` + 커스텀 패널(`.custom-srcapp-option`) 렌더
- 커스텀 드롭다운 보조: `_srcApp*` 시리즈 — `admin.js:3545~3720`
- 캐시: `_campBrandsCache`, `_campAppsCache` — `admin.js:3441~3442`

**② 저장 흐름 — `campaigns.source_application_id`(신청 연결, 외래 키)**
- 편집 읽기: `const sourceAppId = $('editCampSourceAppId')?.value || null;` — `admin.js:1736` → `source_application_id: sourceAppId || null` — `:1771`
- 신규 읽기: `const sourceAppId = $('newCampSourceAppId')?.value || null;` — `admin.js:2583` → `:2640`
- 편집 폼 진입 시 기존 값 복원: `loadCampBrandSelect('edit', ...)` 후 `loadCampSourceAppSelect('edit', camp.brand_id, camp.source_application_id || '')` — `admin.js:594~598`

**③ 신청 연결의 유일한 소비처 — 진행현황 '비용 카드'** (`dev/js/admin-applications.js`)
- `appendCampOpsCostCard(camp)` — `:234`: `isCampaignAdminOrAbove()` + `camp.source_application_id` 존재 시에만, `fetchBrandApplicationById(...)` 로 신청 조회
- `campOpsCostCard(app)` — `:247`: 확정/예상 견적·운영비(Σ 수량×모집비)·견적서 링크 렌더
- (grep 전수 확인) `source_application_id` 를 읽는 곳은 이 비용 카드 + 편집 폼 복원(admin.js:594~597) **두 곳뿐**

**④ ⚠️ 오리엔시트 신규 발행 경로가 이 요소를 내부 사용** (`dev/js/admin-orient.js`)
- `applyOrientCardPrefill(...)` — `admin-orient.js:1106~`: 오리엔시트 카드로 캠페인 발행 시 `switchAdminPane('add-campaign')` 후 폼 값 주입. **이 중 `admin-orient.js:1118~1121` 에서 시트의 `application_id` 를 `newCampSourceAppId` 에 넣고 `_srcAppSyncTrigger('new')` 호출** → 오리엔시트에 연결된 신청이 있으면 발행 캠페인의 `source_application_id` 로 승계됨
- 현재 오리엔시트 발급 UI는 신청 연결이 비활성(`admin-orient.js:1193~1195`)이라 실무상 `application_id` 대부분 NULL이지만, **코드 경로는 살아있다**

### 이 제안과 충돌 가능성 있는 기존 동작
- **오리엔시트 발행 경로(④)** 가 숨김 대상 요소(`newCampSourceAppId`)를 채운다 → 눈에 보이는 UI만 숨기고 **숨김 native select 요소 자체는 반드시 유지**해야 발행 시 신청 승계가 안 깨진다.
- **편집 저장 null 덮어쓰기 함정** — `editCampSourceAppId` 요소를 제거하면 `admin.js:1736` 의 `$('editCampSourceAppId')?.value` 가 undefined→null이 되어, 기존에 연결됐던 캠페인을 편집·저장하는 순간 연결이 파괴된다. 요소 유지 + 값 복원 로직(`:594~598`) 유지가 필수.

### 미해결 백로그·관련 작업
- 서베이 유입 개선·공개 차단: 메모리 `project_brand_survey_future` (공개 제출 차단만 운영 완료)
- 오리엔시트↔캠페인 연동(발행·기존 연결): 메모리 `project_orient_sheet` (운영 완료)
- **견적/비용을 새 캠페인에 붙이는 대체 경로 = 불필요 (2026-07-15 사용자 결정)** — 견적의 본거지는 브랜드 서베이 신청 화면(`brand_applications`: `final_quote_krw`·`quote_sent_url`·모집비). 캠페인 비용 카드는 그 복제 표시일 뿐이라, 서베이 입구를 막아도 견적을 캠페인 쪽에 새로 붙일 필요가 없다. 견적은 브랜드 화면에서 관리·열람.

---

## 의심·경우의 수 (반대론자 모드)

### 깨질 수 있는 경우의 수
1. **(충돌·최중요) 오리엔시트 발행 시 신청 승계 단절** — 숨김 native select `newCampSourceAppId` 를 요소째 제거하면 `applyOrientCardPrefill` 의 값 주입(admin-orient.js:1118)이 갈 곳을 잃는다. → **native select 요소는 남기고, 눈에 보이는 커스텀 패널·트리거만 숨긴다.**
2. **(데이터) 편집 저장 시 기존 연결 null 덮어쓰기** — 편집 폼에서 요소를 없애면 저장이 기존 값을 빈 값으로 덮어씀. → 요소 유지 + 로드 시 값 복원(`admin.js:594~598`) 유지 → 저장 경로가 기존 값을 그대로 다시 씀.
3. **(UX) 편집 시 관리자가 연결을 못 봄** — 비용 카드는 뜨는데 편집 폼엔 아무 표시가 없으면 "이 견적이 왜 붙었지?" 혼란. → 기존 연결이 있는 캠페인 편집 시 **읽기 전용 라벨**(예: 「연결된 서베이 신청: {신청번호}」)로 보여주되 변경 UI는 숨김.
4. **(빈 상태) 이미 서베이 0건인 브랜드** — 현재도 0건이면 "선택 안 함" 옵션만 남는 빈 껍데기. → 숨김으로 자연 해소.
5. **(권한) campaign_manager** — 비용 카드는 campaign_admin 이상만 표시(`isCampaignAdminOrAbove`), 서베이 연결 자체는 권한 무관. 이 변경은 권한 경계에 영향 없음.

### 현재 구현과 충돌하는 지점
- 위 경우의 수 1·2가 실제 충돌점. **핵심 대응: hidden native select + 저장 로직 + 컬럼 + 비용 카드는 건드리지 않고, "눈에 보이는 선택 UI"만 숨긴다.**

### 의도 모호점 (사용자 확인 완료)
- "정리" 범위 = **신규 폼은 숨김 / 편집 폼은 기존 연결 보존** (2026-07-15 사용자 「안전 숨김」 선택)
- 견적 대체 = **이번 범위 아님** (별도)

---

## 설계

### 핵심 원칙
> **DB·저장 로직·비용 카드·hidden native select 는 그대로 두고, 관리자가 서베이 신청을 "새로 고르는" 눈에 보이는 UI만 숨긴다.**

이러면 4개 경로가 모두 안전:
| 경로 | 결과 |
|---|---|
| 수동 신규 캠페인 | 서베이 UI 없음 → `source_application_id = null` (원래도 안 고르면 null) |
| 오리엔시트 발행 캠페인 | hidden select에 `application_id` 주입 유지 → 신청 승계 정상 |
| 기존 연결 캠페인 편집·저장 | 값 복원→저장 그대로 → 연결 보존 |
| 진행현황 비용 카드 | 컬럼·로직 무변경 → 기존 견적 그대로 표시 |

### 변경 지점 (개발 세션 착수 시)
1. **신규 폼** — `onCampBrandChange('new')`(`admin.js:3479~`)에서 브랜드 선택 시 `newCampSourceAppContainer` 의 **커스텀 선택 UI를 표시하지 않음**. hidden `<select id="newCampSourceAppId">` 는 DOM에 유지(값은 빈 상태 또는 오리엔시트 주입값).
   - 오리엔시트 발행(`applyOrientCardPrefill`)이 hidden select에 값을 넣는 경로는 **그대로 동작해야 함** → 발행 시 화면 표시는 불필요(값만 있으면 됨).
2. **편집 폼** — `onCampBrandChange('edit')`/편집 진입(`admin.js:594~598`):
   - `camp.source_application_id` **있으면**: 읽기 전용 라벨(「연결된 서베이 신청: {application_no}」)만 표시, 변경 드롭다운은 숨김. hidden select에 값 유지 → 저장 보존.
   - **없으면**: 서베이 영역 완전 숨김.
3. **저장 로직·컬럼·비용 카드**: 무변경.
   - **진행현황 '비용 카드'(`admin-applications.js:234~`)는 그대로 유지** (2026-07-15 사용자 결정 「그대로 둔다」). 기존 서베이 연결 캠페인엔 견적 카드가 계속 뜨고, 새 캠페인은 연결이 없어 자연히 안 뜬다. 제거하지 않음.
4. (선택) 커스텀 드롭다운 보조 함수(`_srcApp*`)·`fetchBrandApplicationsByBrand` 는 오리엔시트 발행/편집 복원에서 여전히 참조될 수 있으니 **삭제하지 않음**. 신규 폼에서 호출만 건너뜀.

### DB 변경
- **없음.** 마이그레이션 없음. `source_application_id` 컬럼·비용 카드 로직 그대로.

### 개발 착수 전 확인 스텝 (권장)
- 개발서버 데이터베이스에서 서베이 연결 건수 확인:
  ```sql
  SELECT count(*) FROM campaigns WHERE source_application_id IS NOT NULL;
  ```
- 0건이면 편집 폼 보존 처리는 안전망 성격(그래도 함정 방지 위해 요소 유지 원칙은 지킴). 여러 건이면 경우의 수 2·3 대응이 실제로 중요.

---

## PR 분할
- 단일 PR로 충분(DB 무변경·`admin.js` 국소 수정). `admin.js` 핫스팟이므로 다른 캠페인 폼 작업과 동시 진행 금지(시퀀셜).

---

## 사용자 확인 필요 (전부 확인 완료, 2026-07-15)
- ✅ 정리 방식 = **안전 숨김**(기존 연결 보존)
- ✅ 견적 대체 경로 = **안 만듦**. 견적의 본거지는 브랜드 서베이 신청 화면. 캠페인에 견적을 새로 붙일 필요 없음.
- ✅ 진행현황 비용 카드 = **그대로 둠**. 기존 연결 캠페인에만 표시·새 캠페인엔 자연히 안 뜸. 제거하지 않음.

→ **범위 확정: `admin.js` 캠페인 폼의 서베이 선택 UI만 신규 숨김 + 편집 보존. 그 외(견적·비용 카드·DB) 무변경. 마이그레이션 없음.**

---

## 구현 결과

**구현일:** 2026-07-15
**관련 커밋/브랜치:** `feature/campaign-form-hide-survey-link` (dev PR)
**DB 변경:** 없음 (마이그레이션 0)

### 초안 대비 변경 사항
- **추가된 것**:
  - 신규 헬퍼 `renderSurveyLinkReadonly(prefix)` (`dev/js/admin.js`) — 커스텀 선택 UI(`.custom-srcapp-trigger`·`.custom-srcapp-panel`)를 항상 숨기고, hidden native select에 값이 있으면 읽기전용 라벨(`#{prefix}CampSourceAppReadonly`)에 「연결된 서베이 신청: {신청번호·타입·상태}」를 `textContent`로 표시. 컨테이너 표시/숨김을 이 함수로 일원화.
  - 편집·신규 컨테이너에 읽기전용 라벨 `<div class="custom-srcapp-readonly" id="{edit|new}CampSourceAppReadonly">` + CSS `.custom-srcapp-readonly`.
- **달라진 것**:
  - `onCampBrandChange(prefix)` — 브랜드 선택 시 커스텀 선택 UI를 표시하지 않음. hidden native select 옵션은 `loadCampSourceAppSelect`로 **계속 로드**(오리엔시트 발행 승계·연결 라벨용). 산발적 `sourceWrap.style.display` 직접 조작 제거 → `renderSurveyLinkReadonly`로 일원화.
  - 편집 로드(`openEditCampaign`) — 값 복원(`loadCampSourceAppSelect('edit', brand_id, source_application_id)`)은 유지, 직접 `srcWrap.style.display=''` 제거. 표시는 `onCampBrandChange('edit')` 내부의 `renderSurveyLinkReadonly`가 처리.
  - 오리엔 발행(`applyOrientCardPrefill`, `admin-orient.js`) — `osSetVal('newCampSourceAppId', appId)` 뒤 `_srcAppSyncTrigger('new')` → `renderSurveyLinkReadonly('new')`로 교체(승계 신청을 읽기전용 라벨로 표시).
  - 신규 브랜드 힌트 문구를 서베이 언급 없이 「브랜드를 선택하면 캠페인 번호가 자동 채번됩니다.」로 정리.
- **빠진 것**: 없음.

### 구현 중 기술 결정 사항
- 커스텀 선택 UI 숨김은 **JS(`renderSurveyLinkReadonly`)에서 처리**(전역 CSS `display:none` 대신) — 컨테이너를 여는 유일 경로가 이 함수라 깜빡임 없음 + 의도가 코드에 co-locate.
- 저장 로직·`source_application_id` 컬럼·진행현황 비용 카드(`appendCampOpsCostCard`)·`_srcApp*` 보조 함수는 **무변경**. `_srcApp*`은 트리거/패널이 숨겨져 시각적으로 죽지만 호출돼도 무해(삭제 시 오리엔·편집 복원 참조 깨질 위험이라 유지).
- 편집에서 브랜드를 다른 값으로 바꾸면 옛 신청 id가 새 브랜드 옵션에 없어 native select가 ''로 떨어져 라벨이 사라짐 — 이번 변경 이전과 동일한 기존 동작(회귀 아님).
