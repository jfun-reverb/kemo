# HANDOFF — 운영 현황 재설계 PR 2 (회사 관리 페인)

> **작성일**: 2026-05-18
> **작성 세션**: 기획/설계 (메인 폴더, 코드 미수정)
> **인수인계 대상**: 개발 세션 (`/새세션 brand-ops-pr2` 권장)
> **관련 사양서**: `docs/specs/2026-05-13-brand-ops-redesign.md` §6 (이번 PR 범위)

---

## 0. 한 줄 요약

운영 현황 재설계의 두 번째 PR. **회사 관리 페인 신규 추가** + 미분류 브랜드 일괄 할당 흐름 구현. DB 변경 없음(PR 1에서 완료). 클라이언트 코드만 추가.

---

## 1. 작업 전제 (운영 DB 상태 점검 완료)

2026-05-18 운영 Supabase(`twofagomeizrtkwlhsuv`) 점검 결과:

| 항목 | 결과 |
|---|---|
| 마이그레이션 088~090 (계층 채번 v2) | 적용 완료 |
| 마이그레이션 118 (`companies` 테이블 + `brands.company_id`) | 적용 완료 |
| 마이그레이션 119 (브랜드 → 회사 자동 백필) | 적용 완료 (자동 생성 0건) |
| 마이그레이션 120 (`get_brand_ops_overview` / `get_brand_ops_detail`) | 적용 완료 |
| 마이그레이션 121 (`link_campaign_to_application` / `unlink_campaign_from_application`) | 적용 완료 |
| 운영 회사 수 | **0건** (모두 운영자가 직접 만들어야 함) |
| 운영 미분류 브랜드 | **25/25 (전체)** — 일괄 할당 흐름이 필수 |

→ **DB 작업 0개. 코드 작업만.**

---

## 2. 범위 (PR 2)

### 포함
- 사이드바 「브랜드 서베이」 그룹에 「회사 관리」 메뉴 추가
- `adminPane-companies` 페인 (리스트 + 필터 + 검색)
- 회사 추가/수정 모달 (12 필드, 자동 채우기 없음)
- 브랜드 할당 모달 (다중 체크박스 + 미분류·전체 필터)
- 회사 아카이브·활성화 복귀·hard delete (소속 0건 한정)
- 신규 `dev/js/admin-company.js` 파일 분리
- `dev/lib/storage.js` 함수 5종 추가
- `dev/lib/shared.js` `PANE_REFRESHERS` 에 `companies` 1개 등록
- `dev/build.sh` 에 `admin-company.js` 빌드 등록

### 제외 (별도 PR)
- 운영 현황 페인 (PR 3) — 사양서 §5
- 브랜드 상세 페인 (PR 4) — 사양서 §7
- 「브랜드 관리」 메뉴 (사양서 §3 라벨만 등장, 사양 보강 후 별도 PR)
- 대시보드 「최근 신청」 영역 제거 (PR 3 와 함께 진행)

---

## 3. 영향 파일

| 파일 | 변경 종류 | 비고 |
|---|---|---|
| `dev/admin/index.html` | 수정 | 사이드바 1줄 추가 + 페인 컨테이너 1개 + 모달 2개(추가/수정 + 브랜드 할당) + 미분류 브랜드 인디케이터 |
| `dev/js/admin-company.js` | **신규** | 회사 CRUD·브랜드 할당 로직 (admin-brand.js 패턴 참고) |
| `dev/js/admin.js` | 수정 (최소) | 사이드바 라우팅 1줄 — `companies` 페인 진입 시 `loadCompanies()` 호출 |
| `dev/lib/storage.js` | 수정 | 함수 5종 추가: `fetchCompanies` / `upsertCompany` / `assignBrandsToCompany` / `archiveCompany` / `deleteCompanyHard` |
| `dev/lib/shared.js` | 수정 (1줄) | `PANE_REFRESHERS` 에 `'companies': () => loadCompanies()` 추가 |
| `dev/css/admin.css` | 수정 | 모달·체크박스 리스트 스타일 (기존 admin-pane-list 패턴 재사용 가능, 신규 클래스 최소화) |
| `dev/build.sh` | 수정 | 관리자 빌드 JS 순서에 `js/admin-company.js` 추가 (`js/admin.js` 다음, `admin/app.js` 앞) |

총 **신규 1 파일 + 수정 6 파일**.

---

## 4. 작업 순서 (개발 세션용)

### 4-1. 진입
1. `/새세션 brand-ops-pr2` 호출 → worktree + `feature/brand-ops-pr2` 브랜치 자동 생성
2. `git pull origin dev` 로 최신 동기화
3. `ls supabase/migrations/ | tail -5` 로 다음 마이그레이션 번호 확인 (PR 2는 마이그레이션 추가 없음 — 확인용)

### 4-2. 클라이언트 코드 작업
1. `dev/lib/storage.js` 함수 5종 추가 (시그니처는 사양서 §6-5 참조)
2. `dev/js/admin-company.js` 신규 — `loadCompanies()` / `renderCompanyList()` / `openCompanyModal()` / `openBrandAssignModal()` / `saveCompany()` / `assignBrandsBatch()` / `archiveCompany()` / `deleteCompanyHard()`
3. `dev/admin/index.html` — 사이드바·페인·모달 마크업 (위치는 §5 참조)
4. `dev/js/admin.js` — `companies` 페인 진입 시 `loadCompanies()` 호출 (사이드바 nav switch 안)
5. `dev/lib/shared.js` `PANE_REFRESHERS` 1줄 추가
6. `dev/css/admin.css` — 필요한 스타일만 추가 (재사용 우선)
7. `dev/build.sh` — `admin-company.js` 등록

### 4-3. 빌드·검증
1. `cd dev && bash build.sh`
2. 빌드 산출물 점검: `index.html` / `admin/index.html` 양쪽에 admin-company.js 포함됐는지 (관리자 빌드에만)
3. 개발서버 푸시 후 검증 (사양서 §6-8 시나리오 8건)

### 4-4. 배포 흐름
1. dev 브랜치 푸시 → `dev.globalreverb.com` 자동 배포
2. **개발서버에서 검증** (사양서 §6-8 시나리오 8건 모두 통과)
3. `reverb-reviewer` 호출 (모든 commit 직전 의무)
4. `reverb-qa-tester` light 모드 권장 (관리자 페인 변경)
5. PR `dev → main` 생성
6. 사용자 운영 배포 승인 후 main 머지

---

## 5. 사이드바 삽입 위치 (정확한 행 안내)

`dev/admin/index.html` 의 사이드바는 현재 다음 구조:

```
line 103: <div class="admin-si-lbl">브랜드 서베이</div>
line 104: <div class="admin-si" data-pane="brand-dashboard"> 현황 대시보드</div>
line ???: ← 여기에 「회사 관리」 한 줄 추가
line 106: <div class="admin-si" data-pane="brand-applications"> 신청 목록</div>
```

추가할 마크업:

```html
<div class="admin-si" data-pane="companies" id="adminCompaniesSi"
     onclick="navAdminPaneReload('companies')">
  <span class="si-icon material-icons-round notranslate" translate="no">corporate_fare</span>
  <span class="si-text">회사 관리</span>
</div>
```

- 아이콘 `corporate_fare` Material Icons Round (이모지 금지 규칙 준수)
- `notranslate` + `translate="no"` 의무

페인 컨테이너 추가 위치:
- `<div id="adminPane-brand-dashboard">` 다음, `<div id="adminPane-brand-applications">` 앞

---

## 6. 모달 z-index 충돌 점검

기존 브랜드 서베이 신청 등록 모달(`nbaModal`) 과 동일한 z-index 패턴을 따르되, 회사 관리 모달은 별도 ID 사용 (`companyModal`, `brandAssignModal`).

- 신청 등록 모달 z-index 확인: `dev/css/admin.css` → `.modal-overlay` 표준
- 회사 추가 모달 위에서 브랜드 할당 모달이 열리는 시나리오 없음 (시퀀셜) → 같은 z-index 사용해도 무방

---

## 7. 함수 시그니처 (storage.js)

```js
// 회사 리스트 (필터·검색)
// 반환: [{id, name_ko, name_ja, name_en, business_no, ...,
//        total_brands, status, created_at, updated_at}]
async function fetchCompanies({ status = 'active', search = '' } = {})

// 회사 추가/수정 통합 (id 있으면 UPDATE, 없으면 INSERT)
// payload: {id?, name_ko, name_ja?, name_en?, business_no?, address?,
//           homepage_url?, contact_name?, contact_email?, contact_phone?,
//           billing_email?, billing_address?, memo?}
// 반환: {id}
async function upsertCompany(payload)

// 브랜드 다중 할당 (배치). companyId=null 이면 미분류로 되돌리기 (제거)
// brandIds: 변경 대상 브랜드 UUID 배열
// 반환: {affected: number}
async function assignBrandsToCompany(companyId /* uuid | null */, brandIds /* uuid[] */)

// 아카이브 / 활성화 복귀
// archive=true → status='archived', false → status='active'
async function archiveCompany(companyId, archive)

// hard delete (소속 0건 검증 후)
// 소속 1개 이상이면 함수 안에서 throw (UI 가드와 이중 안전망)
async function deleteCompanyHard(companyId)
```

---

## 8. 검증 시나리오 (사양서 §6-8 발췌)

1. 회사 1건 추가 → 리스트에 즉시 노출
2. 미분류 브랜드 다중 선택 일괄 할당 → 회사 카운트 즉시 갱신 + 미분류 인디케이터 감소
3. 같은 회사명 중복 추가 → 친화적 에러 메시지 (`23505` 핸들링)
4. 회사 편집 → 저장 → 리스트 갱신
5. 소속 1개 회사에 「삭제」 미노출 → 브랜드 제거 후 「삭제」 노출
6. 아카이브 → 기본 필터(active)에서 사라짐, archived 필터에서 보임
7. 권한: campaign_manager 로그인 시 CUD 비활성화
8. 다른 회사 소속 브랜드 이동 → 옛 회사 `total_brands` 자동 감소

---

## 9. 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| `admin.js` 9,464줄 핫스팟 — 다른 세션 동시 작업 시 충돌 | 머지 충돌 | 멀티 세션 운영 규칙(`.claude/rules/multi-session.md`) 준수, 본 PR 진행 중 다른 세션이 admin.js 만지면 보고 |
| `name_normalized` 트리거가 INSERT 만 처리한다고 가정 | 회사명 UPDATE 시 정규화 누락 위험 | 트리거가 `BEFORE INSERT OR UPDATE` 인지 supabase-expert 로 1회 점검 권장 |
| 브랜드 할당 트리거(`trg_brands_company_total_brands`) 가 다중 UPDATE 시 정상 발화 | 카운트 어긋남 | 검증 시나리오 #2, #8 에서 직접 확인 |
| campaign_manager 가 SELECT만 가능한데 UI 가드 누락 시 모달 열림 | 저장은 RLS 차단되지만 UX 혼란 | 모달 열기 직전 권한 체크 + 버튼 disabled |

---

## 10. 에이전트 호출 의무 (배포 전)

- `reverb-reviewer` — commit 직전 필수
- `reverb-supabase-expert` — `lib/storage.js` 수정 시 권장 (RLS·트리거 가정 검증)
- `reverb-qa-tester` — **light 모드** (관리자 페인 변경, 사양서 §6-8 시나리오 자동화)

---

## 11. PR 본문 템플릿

```markdown
## 변경 요약
- 회사 관리 페인 신규 추가 (운영 현황 재설계 PR 2)
- 미분류 브랜드 다중 일괄 할당 흐름
- 신규 `dev/js/admin-company.js` 분리 (admin.js 핫스팟 회피)

## 요청 외 추가 변경
- (없으면 "없음" 명시)

## 관련 사양서
- docs/specs/2026-05-13-brand-ops-redesign.md §6
- docs/specs/2026-05-18-HANDOFF-brand-ops-pr2-company-pane.md (이 문서)

## DB 변경
- 없음 (PR 1 에서 마이그레이션 118~121 + 088~090 완료)

## 검증
- 사양서 §6-8 시나리오 1~8 모두 통과 (개발서버)
```

---

## 12. 작업 완료 후

- 사양서 `docs/specs/2026-05-13-brand-ops-redesign.md` 끝에 **PR 2 구현 결과 섹션 추가** (`.claude/rules/docs-tracking.md` 의무)
- `CLAUDE.md` Features — 관리자 섹션에 「회사 관리(`/admin#companies`)」 한 줄 추가
- 다음 PR 3 (운영 현황 페인) 기획 세션 인계 신호
