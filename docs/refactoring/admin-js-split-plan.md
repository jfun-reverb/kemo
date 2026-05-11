# `dev/js/admin.js` 페인 단위 분리 계획

> **작성일**: 2026-05-08
> **상태**: 대기 (`feature/deliverable-mail` dev 머지 완료 후 시작)
> **현재 admin.js 크기**: 10,214줄, 401개 함수
> **HTML 인라인 onclick 호출**: 162곳

---

## 1. 결정 사항 (2026-05-08)

- **분리 방식**: A안 (페인 단위) — 사이드바 메뉴 1:1로 약 20개 파일 분할
- **시작 시점**: `feature/deliverable-mail`이 dev에 머지된 후 (검수 완료 대기)
- **PR 분할**: Phase 별 12 PR (잎 페인 → 광역 헬퍼 역순)
- **문서 저장**: 본 파일에만. Claude 메모리에는 별도 표시 없음 (다음 세션에서 사용자가 "admin.js 분리 시작" 지시 시 본 문서 참조)

---

## 2. 왜 분리하는가

- vanilla JS + 단일 concat 빌드라 동작상 문제는 없으나, 검색·수정 비용과 함수명 충돌 위험 누적
- 페인이 12개 이상 한 파일에 집약 → 한 페인 작업 중 무관한 페인 함수를 깨먹는 사고 빈발
- `feature/deliverable-mail` 같은 격리 브랜치가 admin.js 한 곳에 집중 변경되면 머지 시 충돌 폭탄
- 운영팀 보고용 변경 이력에서 "어느 페인이 바뀌었나"를 파일명으로 즉시 설명 가능해짐

---

## 3. 현황 진단 (사전 점검 결과)

### 빌드 모델
- `dev/build.sh`가 단순 concat. 모듈 시스템 없음 → 전역 스코프 그대로
- 함수 이름만 유지하면 분리 비용 거의 0

### HTML 인라인 호출 162곳
- `onclick="loadCampApplicants()"`, `onclick="renderBrandApplicationsList()"` 등
- 함수가 어느 파일에 있든 전역에 살아 있어야 함 → **함수 이름 변경 절대 금지**

### 발견된 별건 버그
- `dev/lib/shared.js`의 `PANE_REFRESHERS['campaigns']`가 `loadCampaigns`(인플루언서용 함수)를 가리킴 → 관리자 페인에서 작동 안 함. 올바른 함수는 `loadAdminCampaigns`. 분리 작업 사전 정리 단계(Phase 0)에서 함께 수정.

### 광역 공유 헬퍼 / 상태
- **거의 모든 페인 사용**: `switchAdminPane`, `friendlyError`, `initMultiFilters`, `createMultiFilter` / `getMultiFilterValues` / `syncMultiFilter`, `highlightFilter`, `updateFilterResetBtn`, `resetMultiFilter`, `updateTableScrollHeight`, `_adminEmails` / `loadAdminEmails` / `isAdminEmail` / `adminBadge`, `formatReviewer`, `consentBadge` / `openCautionConsentModal`, `msgCell` / `openMsgModal`, `openImageLightbox`
- **캠페인 폼 광역**: `_formCfg`, 채널·콘텐츠·카테고리 동적 렌더, Quill 헬퍼, flatpickr setup, 번들(pset/cset) 캠페인 폼 통합, `_campRangePickers` / `_campSinglePickers` (다른 페인 전환 시 닫기 위해 `switchAdminPane`이 직접 참조)
- **인플루언서 페인 광역**: `_currentDetailInfluencer`, `_currentFlagsCache`, `_blacklistReasonsCache`, 파일 업로드 헬퍼들
- **결과물 페인**: `_delivCache`, `refreshDelivSidebarBadge`, `openImageLightbox` (인플루언서 위반 증빙도 호출)
- **광고주 4페인 캐시 공유**: `_brandApps`, `_brandAppHistoryCache`, `_brandAppMemoModalCache`, `_campBrandsCache`, `_brandFormContacts`
- **공지**: `loadAdminData`(대시보드)가 `refreshAdminNoticeBadge` / `renderDashboardNotices` / `showAdminUnreadNoticesIfAny`를 직접 호출

---

## 4. 추천: A안 페인 단위 (`dev/js/admin/` 디렉토리)

```
dev/js/admin/
  core.js                    # switchAdminPane, friendlyError, multi-filter,
                             #   updateTableScrollHeight, formatReviewer,
                             #   consentBadge, msgCell, openImageLightbox,
                             #   copyTextToClipboard, _adminEmails, isAdminEmail
  dashboard.js               # loadAdminData, KPI, 차트, 도넛, 회원가입 추이
  campaigns-list.js          # 캠페인 목록·정렬·드롭다운·더보기·미리보기
  campaigns-form.js          # 등록/편집 + Quill + flatpickr + pset/cset 통합
                             #   (가장 큼, ~3,000줄)
  camp-applicants.js         # 캠페인별 신청자 페인
  applications.js            # 신청 관리 (renderAppCampList 캐시)
  deliverables.js            # 결과물 검수 페인
  influencers.js             # 인플루언서 목록 + 상세 모달 + verify/violation/blacklist
  lookups.js                 # 기준 데이터 (LOOKUP_KIND_*, RECRUIT_TYPE_*)
  participation-sets.js      # 참여방법 번들
  caution-sets.js            # 주의사항 번들 (미니 에디터 + 링크 팝오버)
  admin-accounts.js          # 관리자 계정 + isCampaignAdminOrAbove + applyLookupMenuVisibility
  my-account.js              # 본인 계정 + updateSidebarProfile
  brand-applications.js      # 브랜드 서베이 리스트·필터·인라인 셀 편집
  brand-applications-form.js # 신규 신청 모달 + 브랜드 select/new 분기
  brand-dashboard.js         # 브랜드 서베이 현황 (KPI, funnel, donut, trend)
  brands.js                  # 브랜드 마스터 페인
  date-cells.js              # 인라인 날짜 셀 편집 (브랜드 페인 의존부 분리)
  excel.js                   # ExcelJS lazy-load + 4종 export 함수
  admin-notices.js           # 공지사항 페인 + 대시보드 카드 + 미읽음 팝업
```

---

## 5. 단계별 분리 순서 (12 PR)

### Phase 0 — 사전 정리 (필수 선행, 1 PR)
1. 워킹 카피 modified 정리
   - `dev/js/admin.js M`
   - `docs/service-flow.html M`
   - `supabase/seed/test_influencers_staging.sql M`
   - `supabase/migrations/084_security_advisor_cleanup.sql ??` (신규)
   - 작업 의도별로 분리 커밋하거나 stash. 분리 작업 진입 전 admin.js를 깨끗한 HEAD 기준으로
2. `shared.js`의 `PANE_REFRESHERS['campaigns']` 버그 수정 (`loadCampaigns` → `loadAdminCampaigns`)
3. 파일 헤더에 페인 경계 주석 보강 (분리 직전 마지막 단일 파일 스냅샷용)

### Phase 1 — 잎 페인 4개 (각 1 PR, 총 4 PR)
다른 페인이 호출 안 함 + 변경 빈도 낮은 페인부터.

| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-1 | `admin-notices.js` | ~370 |
| PR-2 | `excel.js` | ~580 |
| PR-3 | `lookups.js` + `participation-sets.js` + `caution-sets.js` | ~1,170 |
| PR-4 | `my-account.js` + `admin-accounts.js` | ~250 |

### Phase 2 — 광고주(브랜드 서베이) 5파일 (1 PR로 묶음)
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-5 | `brand-applications.js` + `brand-applications-form.js` + `brand-dashboard.js` + `brands.js` + `date-cells.js` | ~2,200 |

**주의**: 4페인이 캐시 공유. 상태 변수는 `brand-applications.js` 1곳에만 두고 다른 파일이 typeof 가드로 접근.

### Phase 3 — 결과물 / 캠페인별 신청자
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-6 | `deliverables.js` | ~700 |
| PR-7 | `camp-applicants.js` | ~190 |

### Phase 4 — 인플루언서
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-8 | `influencers.js` | ~750 |

### Phase 5 — 신청 관리
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-9 | `applications.js` | ~230 |

### Phase 6 — 캠페인 (가장 큼)
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-10a | `campaigns-list.js` | ~700 |
| PR-10b | `campaigns-form.js` | ~3,000 (단일 PR 한도) |

PR-10b가 너무 크면 sub-step으로 추가 분할 검토:
- (a) flatpickr setup
- (b) Quill + 민감 변경 잠금
- (c) pset/cset 캠페인 폼 통합
- (d) 저장 함수 4개

### Phase 7 — 대시보드 + 코어 (마지막)
| PR | 파일 | 추정 줄 수 |
|---|---|---|
| PR-11 | `dashboard.js` + `core.js` | ~600 |

**총 12 PR** (PR-10b 추가 분할 시 16 PR 가능)

---

## 6. 빌드 순서 권고 (`build.sh`의 `ADMIN_JS_FILES`)

```
lib/supabase.js
lib/shared.js
lib/storage.js
js/ui.js
js/admin/core.js              # 모든 페인보다 앞
js/admin/dashboard.js
js/admin/admin-notices.js
js/admin/lookups.js
js/admin/participation-sets.js
js/admin/caution-sets.js
js/admin/excel.js
js/admin/campaigns-list.js
js/admin/campaigns-form.js    # _campRangePickers 등 const 선언 포함
js/admin/camp-applicants.js
js/admin/applications.js
js/admin/influencers.js
js/admin/deliverables.js
js/admin/date-cells.js
js/admin/brands.js
js/admin/brand-applications.js
js/admin/brand-applications-form.js
js/admin/brand-dashboard.js
js/admin/admin-accounts.js
js/admin/my-account.js
admin/app.js                  # 부트스트랩 init() — 항상 마지막
```

원칙:
- `core.js`는 ui.js 직후, 모든 페인 파일보다 앞
- `admin/app.js`는 항상 맨 마지막 (DOMContentLoaded 핸들러)
- 함수 선언은 호이스팅되지만 `const`/`let` 초기값은 호이스팅 안 됨 → 파일 순서로 보장

---

## 7. reverb-reviewer 회귀 체크리스트 (각 PR 직전 필수)

### 전역 함수 누락
- [ ] 빌드 산출물 `admin/index.html`에 함수가 1회씩만 정의 (양쪽 파일에 남는 사고 빈발)
- [ ] HTML 162곳 onclick 함수명이 모두 빌드 결과에 살아 있음
  ```bash
  grep -E "onclick=\"([a-zA-Z_]+)\(" dev/admin/index.html | \
    sed -E 's/.*onclick="([a-zA-Z_]+)\(.*/\1/' | sort -u
  ```
- [ ] `dev/admin/app.js`에서 typeof 가드 없이 호출하는 이름들이 살아 있음 (`registerImgList`, `fetchCampaigns/Influencers/Applications`, `applyLookupMenuVisibility`, `updateSidebarProfile`)

### stale 참조 (가드 추가 필요)
- [ ] `loadAdminData` → `refreshAdminNoticeBadge` / `renderDashboardNotices` / `showAdminUnreadNoticesIfAny` / `refreshDelivSidebarBadge` / `fetchViolationCountsByInfluencer`
- [ ] `switchAdminPane`의 loaders 객체
- [ ] `saveCampaignEdit` / `addCampaign` → `loadAdminCampaigns`

### `refreshPane` / `PANE_REFRESHERS` 매핑
- [ ] `shared.js`의 `'campaigns': loadCampaigns` 버그 수정 (Phase 0에서)
- [ ] 새 페인 분리 시 `PANE_REFRESHERS`에 매핑 추가 (모달 있는 페인만)

### 상태 변수 중복 선언
- [ ] grep으로 양쪽 파일 잔존 확인:
  - `_adminEmails`, `_currentDetailInfluencer`, `_brandApps`
  - `campImgData` (ui.js와 충돌 주의)
  - `_psetState`, `_csetState`, `_delivCache`, `_adminNoticesCache`

### 빌드 산출물
- [ ] `cd dev && bash build.sh` 에러 0
- [ ] 빌드 산출물 줄 수 ±50 이내 (대량 누락 방지)

### 함수 인덱스 비교
- [ ] 분리 전후 함수 이름 집합 동일성 (총 401개 → 같은 401개)
  ```bash
  grep -E "^(async )?function " dev/js/admin.js dev/js/admin/*.js | \
    awk '{print $NF}' | sort
  ```

---

## 8. 개발서버 회귀 시나리오 (각 Phase 끝 — reverb-qa-tester 호출)

- [ ] 사이드바 12개 메뉴 클릭 시 각 페인 첫 로드 정상
- [ ] 캠페인 등록 → 저장 → 목록 복귀 시 새 행 표시
- [ ] 캠페인 편집 → flatpickr 3종 정상 mount → 저장 → 목록 그 행 갱신
- [ ] 신청 1건 승인 → 신청 페인 상태 변경 + 캠페인별 신청자 페인 결과물 셀 갱신
- [ ] 결과물 1건 반려 → 인플루언서 알림 모달 (운영서버 검증 시)
- [ ] 인플루언서 위반 등록 → 증빙 업로드 → 상세 모달 갱신 → 라이트박스 열림
- [ ] 광고주 신청 인라인 셀 편집(날짜·견적·메모) 5종 모두 저장 후 셀 복원
- [ ] 공지 발행 → 다른 관리자 계정 로그인 시 미읽음 팝업
- [ ] 관리자 추가 → 초대 메일 → 비밀번호 설정
- [ ] 페인별 모달 저장 직후 목록·배지 갱신(`refreshPane` 동작)
- [ ] 사이드바 접기/펼치기, 페인 새로고침, 브라우저 뒤로/앞으로

---

## 9. 리스크 및 대응

| 리스크 | 영향 | 대응 |
|---|---|---|
| HTML onclick 162곳이 함수 이름에 강결합 | 한 글자만 바꿔도 즉시 깨짐 | 분리 중 이름 변경 금지. 이름 변경은 별도 PR |
| 상태 변수 중복 선언 (`var`는 에러 안 남) | 캐시 무효화 회귀 | grep으로 양쪽 파일 확인 |
| `switchAdminPane`이 페인 setup 함수 직접 참조 | 빌드 순서 잘못되면 동작 이상 | `init()`에서만 호출 → 부트스트랩이 마지막인 한 안전 |
| `feature/deliverable-mail` 충돌 | 머지 시 admin.js 라인 어긋남 | **머지 후 시작으로 결정 → 충돌 0** |
| git blame 손실 | IDE에서 한눈에 안 보임 | `git log --follow`로 추적 가능. 첫 분리 PR에서 leaf 페인 1개 `git mv` 트라이얼 |
| 다른 세션 동시 작업 | admin.js 동시 수정 시 거대 충돌 | `.claude/rules/multi-session.md` 단일 워크트리 원칙. "분리 작업 중 admin.js 동결" 공지 |

---

## 10. 보안 / 운영 영향

- DB / 마이그레이션 / 행 단위 보안 정책: **변경 없음**. 순수 클라이언트 코드 분리
- anon key 노출 / 권한 함수(`is_admin()` / `is_super_admin()`): 호출 위치만 이동, 호출 사라지지 않는지 grep 확인
- 운영 사용자 세션: 빌드 산출물 단일 `<script>` 통합 그대로 유지. 캐시 무효화는 `VERSION` 코멘트로 동작 → 운영 배포 시 사용자 새로고침 1회로 갱신

---

## 11. 다시 시작할 때 (체크리스트)

`feature/deliverable-mail`이 dev에 머지된 후:

1. `git checkout dev && git pull origin dev` (메인 폴더에서)
2. 새 worktree 생성: `/새세션 admin-split` (`.claude/rules/multi-session.md` 참조)
3. 본 문서 §5 Phase 0부터 순차 진행
4. 각 PR마다 `reverb-reviewer` 호출 의무
5. Phase 1, 2, 3 끝날 때마다 `reverb-qa-tester` 호출 권장
6. 운영 배포는 dev 검증 후 사용자에게 `AskUserQuestion`으로 확인 (`.claude/rules/git.md`)

---

## 12. 미해결 / 나중에 결정할 것

- `feature/deliverable-mail`이 dev/js/admin.js를 직접 수정했는지: 머지 시점에 `git diff main..feature/deliverable-mail -- dev/js/admin.js`로 확인
- PR-10b(`campaigns-form.js` 약 3,000줄)를 그대로 둘지 4 PR로 추가 분할할지: Phase 6 진입 전 시점에 판단
- 안정화 후 2차 단계: 공용 패턴(인라인 셀 편집, 모달 헬퍼, 다중 선택 필터)을 `core.js`에서 별도 공용 파일로 추출 (C안 일부 적용)
- 분리 작업 중 admin.js를 건드리는 다른 PR 동결 여부: 작업 시작 시 사용자에게 확인
