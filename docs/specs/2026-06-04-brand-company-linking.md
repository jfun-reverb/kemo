# 브랜드 관리 ↔ 회사 관리 연동 (회사 정보 일원화)

**작성일:** 2026-06-04
**작성 세션:** 기획/설계
**상태:** 초안 (사용자 정책 확정, 개발 미착수)

---

## 배경 (사용자 요청)

> "관리자 페이지에 브랜드 관리 페인과 회사 관리 페인이 있는데, 회사 목록에 필요한 정보를 브랜드 관리 페인에 등록한 것들이 두 개가 매칭이 안 돼 있다."

관리자가 「브랜드 관리」에서 입력한 회사 정보(회사명·사업자등록번호·청구 이메일)가 「회사 관리」 명부(`companies` 표)와 자동으로 이어지지 않아, 같은 회사를 두 곳에 따로 입력해야 하고 서로 어긋난다.

**사용자 확정 정책 (AskUserQuestion 3회):**
1. **우선** 브랜드 관리에 이미 적어둔 회사 정보가 **회사 관리 목록에 나타나야** 한다.
2. 같은 회사명은 **회사 1건으로 묶기** (회사 1 : 브랜드 여러 개).
3. 앞으로는 **회사 정보를 회사 관리 한 곳에서만** 입력. 브랜드 관리에서는 **회사를 드롭다운으로 선택**해 연결하되, 드롭다운에 없으면 **그 자리에서 신규 회사 등록** 가능.

---

## 현재 상태 (작성일 2026-06-04 기준 — planning.md 규칙 A)

### 관련 코드·DB·UI 진입점

**브랜드 관리 페인** (`dev/js/admin-brand.js`)
- 상세 폼 렌더: `renderBrandDetailFormHtml(b, apps)` (1200~)
- 회사명 입력칸: `input('brandFormCompanyName', '회사명', b.company_name, ...)` (1246) — **자유 텍스트**
- 회사 관련 입력칸 3종: `company_name`(회사명), `business_no`(사업자등록번호), `billing_email`(계산서 이메일) — 모두 `brands` 행에 직접 저장
- 폼 수집: `_collectBrandFormPatch()` (1336), 저장: `saveBrandDetail()` (1374)
- 신규 브랜드 인라인 등록 패턴: `openNewBrandModal(callbackPrefix)` (1388) + `submitNewBrand()` (1406) — **이 패턴을 회사 인라인 등록에 그대로 미러링 가능**

**회사 관리 페인** (`dev/js/admin-company.js`, `/admin#companies`)
- 입력 필드 정의: `COMPANY_FIELDS` (120~133) — `name_ko`(필수)·`name_ja`·`name_en`·`business_no`·`homepage_url`·`address`·`contact_name`·`contact_email`·`contact_phone`·`billing_email`·`billing_address`·`memo`
- 회사 CRUD: `openCompanyModal(id)` (135) / `saveCompany()` (176)
- 브랜드 할당: `openBrandAssignModal(companyId)` (243) / `saveBrandAssign()` (301) → `assignBrandsToCompany()` 로 `brands.company_id` 일괄 갱신
- 권한: `canEditCompanies()` — 회사 추가·수정·삭제는 campaign_admin 이상

**데이터 접근** (`dev/lib/storage.js`)
- `fetchCompanies({status, search})` (1888) · `upsertCompany(payload)` (1982, insert/update 겸용) · `assignBrandsToCompany(companyId, brandIds)` (2006) · `archiveCompany` (2023) · `deleteCompanyHard` (2041) · `fetchBrandsForAssign({companyId, unassignedOnly, search})` (2069)
- `fetchBrands` (1842) · `fetchBrandById` (1854) · `updateBrand(id, patch)` (1862) · `insertBrand` (1873)

**DB 스키마**
- `companies` (마이그레이션 118): `id`, `name_ko`(NOT NULL), `name_ja`, `name_en`, `name_normalized`(UNIQUE NOT NULL, `lower(trim(name_ko))` 자동 트리거), `business_no`, `address`, `homepage_url`, `contact_*` 3종, `billing_email`, `billing_address`, `memo`, `status`('active'|'archived'), `total_brands`(자동 트리거 재계산), 감사 컬럼. RLS SELECT `is_admin()`, CUD `is_campaign_admin()` 이상
- `brands` (마이그레이션 082): `name`(NOT NULL)·`name_normalized`(UNIQUE 자동)·`name_ja`·`name_en`·`business_no`·`billing_email`·`company_name`(**자유 텍스트 스냅샷**)·`company_id`(**FK → companies.id, ON DELETE SET NULL, NULL 허용**, 마이그레이션 118 추가)·`contacts jsonb`·`memo`·`status`·`total_applications` 등
- 트리거: `recalc_company_total_brands()` (마이그레이션 118) — `brands` INSERT/UPDATE/DELETE 시 `companies.total_brands` 자동 갱신 ⚠️ **백필 UPDATE 가 이 트리거를 발화시키는지 구현 시 검증 필요**

### 이 제안과 충돌 가능성 있는 기존 동작
- **과거 자동 매칭 백필이 0건이었음** (마이그레이션 119는 `brand_applications.brand_name` ↔ `brands.name_normalized` 매칭이었고, 회사명 기준 매칭이 아니었음). 즉 **company 백필은 신규 작업** — 기존 119와 다른 키(회사명)로 동작.
- **운영 DB 현황(2026-05-18 점검 기준)**: `companies` 0건, `brands` 25건 전부 `company_id = NULL`. ⚠️ 단 이 수치는 점검 시점 값 — **개발 세션이 운영/개발 DB에서 `company_name` 채워진 brands 수·중복·빈칸을 실측 후 백필 설계 확정**할 것.
- `brands.company_name` 은 신청 시점 스냅샷 성격도 있음 → **백필 시 덮어쓰지 않고 보존**, `company_id` 만 채움.
- 캠페인 등록 폼의 brands 드롭다운·신규 brand 인라인 모달(`source_application_id` cascade)은 이번 변경과 별개 영역 — 회사 드롭다운 추가가 브랜드 드롭다운을 건드리지 않음.

### 미해결 백로그·관련 작업
- `docs/specs/2026-05-13-brand-ops-redesign.md` — 회사 관리 페인·운영 현황 페인 도입(PR 2). 본 작업은 그 후속(브랜드↔회사 입력 일원화).
- 메모리 `project_brand_ops_features_doc_backlog.md` — `PANE_REFRESHERS` 에 `brands` 등록 누락 backlog (본 작업에서 함께 처리 권장).

---

## 의심·경우의 수 (planning.md 규칙 B)

### 깨질 수 있는 경우의 수

1. **(데이터) 같은 회사명, 다른 부가정보** — 같은 회사명을 가진 브랜드들의 `business_no`·`billing_email` 이 서로 다르면, 회사 1건에 어느 값을 넣을지 충돌. → 대표값 1개(비어있지 않은 첫 값) 채택, 나머지는 손실되거나 `companies.memo` 에 병기. **정책 확인 필요(아래).**
2. **(데이터) 회사명 빈칸·공백** — `company_name` 이 NULL·빈 문자열·공백뿐인 브랜드는 백필 대상에서 제외(미지정 유지). 빈 회사 1건이 잘못 생기지 않게 가드.
3. **(데이터) 정규화 키 중복** — 이미 `companies` 에 같은 `name_normalized` 회사가 있으면 새로 만들지 말고 재사용(UNIQUE 제약 위반 방지). 백필은 멱등(재실행해도 중복 안 생김)이어야 함.
4. **(기술) total_brands 트리거 발화** — 백필 UPDATE 후 `companies.total_brands` 가 0으로 남으면 목록이 「브랜드 0개」로 오표시. 트리거가 발화 안 하면 백필 끝에 수동 재계산 필요.
5. **(권한·환경) 양 서버 적용** — 백필 마이그레이션은 개발 DB 먼저 → 검증 → 운영 DB. 운영 데이터 건수가 달라 결과가 다름. 백필 결과(생성 회사 수·연결 브랜드 수)를 양쪽에서 각각 확인.
6. **(UX 필수) 드롭다운 길이** — 회사가 수십~수백 개가 되면 단순 `<select>` 스크롤이 불편. 사용자가 일괄발송 작업에서 이미 요구했던 **「입력해서 목록에서 고르는」 검색형 드롭다운**(결과물 관리의 캠페인 선택 방식)을 회사 선택에도 적용 권장. 현재 회사 수가 적어 1차는 단순 select 도 가능하나, 검색형이 미래 안전.
7. **(UX) 신규 회사 등록 후 즉시 반영** — 인라인으로 회사를 만들면 그 회사가 드롭다운에 바로 추가되고 자동 선택돼야 함(`refreshPane` 또는 드롭다운 재로드). 안 그러면 "방금 만든 회사가 안 보인다" 혼란.
8. **(UX) 회사 정보 입력칸 위치 혼란** — 드롭다운으로 바꾼 뒤에도 브랜드 폼에 `business_no`·`billing_email` 입력칸이 남아 있으면, 운영자가 또 거기 적고 회사 명부와 어긋남(지금 문제 재발). 일원화하려면 **브랜드 폼에서 회사 단위 입력칸 제거 또는 읽기전용 표시**가 정합적. **단 이 컬럼들이 브랜드 단위 정보일 가능성도 있어 확인 필요(아래).**

### 현재 구현과 충돌하는 지점
- `brands.company_name` 표시에 의존하는 화면(브랜드 목록·신청 목록·엑셀 내보내기)이 있다면, 드롭다운 전환 후에도 **연결된 회사명(`companies.name_ko`) 우선 + `company_name` 폴백** 으로 표시해 깨지지 않게. 구현 전 `company_name` 참조처 grep 필수.
- 그 외 확인된 충돌 없음 — `company_id` FK·`upsertCompany`·`assignBrandsToCompany` 등 연동에 필요한 함수가 이미 존재.

### 의도 모호점 (사용자 확인 필요)
- **"회사 정보"의 범위** — 사용자가 말한 "회사 목록에 필요한 정보"가 회사명만인지, 사업자등록번호·청구 이메일까지 포함인지. 백필 시 어디까지 회사로 옮길지 결정 필요.
- **부가정보 충돌 처리** — 위 경우의 수 1번.
- **브랜드 폼의 회사 단위 입력칸 처리** — 위 경우의 수 8번.

---

## 제안 / 설계

### 전체 그림

```
[지금]                              [목표]
brands.company_name (글자)          companies (회사 명부, 단일 출처)
brands.business_no                    ↑ name_ko·business_no·billing_email
brands.billing_email                  │ (회사 단위 정보 일원화)
   ↕ 회사 명부와 단절              brands.company_id ──FK──┘ (드롭다운 선택)
                                    brands.company_name = 스냅샷 보존
```

### Part 1 — 기존 데이터 정리 (백필, 마이그레이션 170)

대상: `company_id IS NULL` 이고 `company_name` 이 비어있지 않은 `brands` 행.

절차(멱등 보장):
1. `company_name` 정규화 키(`lower(trim(regexp_replace(company_name,'\s+',' ','g')))`)로 그룹핑.
2. 그룹마다 `companies` 에 같은 `name_normalized` 회사가 있으면 재사용, 없으면 신규 INSERT
   - `name_ko` = 그룹 대표 `company_name` 원문(첫 값)
   - `business_no` / `billing_email` = 그룹 내 비어있지 않은 **첫 값 채택**, 서로 다른 추가 값이 있으면 **`memo` 에 후보 병기**(확정 정책 2번)
3. 그룹 내 모든 brand 의 `company_id` = 해당 회사 id 로 UPDATE (`company_name` 은 보존)
4. `companies.total_brands` 재계산(트리거 미발화 시 명시적 UPDATE)
5. 결과 로그: 생성 회사 수 / 연결 브랜드 수 / 미처리(회사명 빈칸) 수

⚠️ 마이그레이션 번호 **170** (167=메인, 168·169=`bulk-redesign` worktree 선점·운영 보류 중. 본 작업 진행 전 해당 worktree 머지 여부 확인).

### Part 2 — 앞으로의 입력 UX (브랜드 관리 폼 변경)

1. 브랜드 상세 폼의 「회사명」 **자유 텍스트 입력 → 「회사」 드롭다운**으로 교체
   - 항목: 회사 명부(active) 목록 + 「(미지정)」 + 「+ 신규 회사 등록」
   - 선택 시 `brands.company_id` 저장 (`company_name` 은 표시용으로 선택 회사명 동기화 or 보존)
   - 가급적 검색형 드롭다운(결과물 관리 캠페인 선택 패턴 재사용)
2. **신규 회사 인라인 등록** — `openNewCompanyModal(callbackPrefix)` 신설, `openNewBrandModal` 패턴 미러링
   - 최소 `name_ko` 필수 + 선택 필드 → `upsertCompany()` 로 생성 → 드롭다운에 추가·자동 선택
3. 회사 단위 입력칸(`business_no`·`billing_email`) **회사 관리로 일원화**(확정) — 브랜드 폼에서 입력칸 제거, 연결된 회사 정보는 읽기전용 표시. ⚠️ 구현 전 `brands.business_no`·`brands.billing_email` 참조처(엑셀 내보내기·신청 목록 등) grep 후, 회사 값(`companies.*`) 우선 + 브랜드 값 폴백으로 전환.

### PR 분할

- **PR 1 — 기존 회사 정보 회사 명부 백필** (마이그레이션 170). 사용자 「우선」 요구. DB만, UI 무변경. *(개발 세션이 운영/개발 DB 실측 → 백필 SQL 확정 → 양 서버 적용)*
- **PR 2 — 브랜드 관리 회사 드롭다운 + 신규 회사 인라인 등록** (`admin-brand.js`, `admin-company.js` 신규 회사 모달 공용화, `storage.js`). UI 재설계 → reverb-planner 사전 호출 대상.
- **PR 3 — 회사 단위 입력칸 일원화** (확정): 브랜드 폼에서 `business_no`·`billing_email` 입력칸 제거 + 연결 회사 정보 읽기전용 표시 + 참조처 폴백 전환. PR 2 와 같은 사이클에 묶어도 무방.

---

## 확정 정책 (사용자 결정 2026-06-04)

1. **옮길 정보 범위** = 회사명 + 사업자등록번호 + 청구 이메일 (3종 모두 회사 명부로)
2. **같은 회사명·다른 부가정보 충돌** = 비어있지 않은 **첫 값 1개 채택 + 나머지 값은 `companies.memo` 에 기록**(정보 손실 방지). 메모 형식은 사람이 알아볼 수 있게(예: `[자동병합] 사업자번호 후보: 111-11-11111, 222-22-22222`).
3. **드롭다운 전환 후 브랜드 폼의 사업자번호·청구 이메일 칸** = **회사 관리로 일원화** — 브랜드 폼에서 입력칸 제거, 연결된 회사 정보는 **읽기전용 표시**. (PR 3)

---

## 구현 결과 (개발 세션이 채울 것)

**구현일:**
**관련 커밋·PR:**

### 초안 대비 변경 사항
- 추가된 것:
- 빠진 것:
- 달라진 것:

### 구현 중 기술 결정 사항
- (운영/개발 DB 실측 결과, total_brands 트리거 발화 여부, company_name 참조처 grep 결과 등)
