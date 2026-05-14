# 사양서: 브랜드 서베이 신청 목록 상태별 탭 UI

> **작성일**: 2026-05-12
> **작성 세션**: 기획/설계
> **상태**: 사양 확정
> **모델 패턴**: 기준 데이터 페인(`/admin#lookups`)의 가로 탭 UI 미러링 — 핑크 밑줄(`#E8344E`) + 굵은 글자 + 비활성 회색
> **예상 PR 분할**: 1개

---

## 1. 결정 요약 (2026-05-12)

| 항목 | 결정 |
|---|---|
| 탭 구성 | **전체 + 10단계 모두 (11개 탭)** — 가로 한 줄 |
| 탭 순서 | 영업 워크플로 순서: 전체 → 신규접수 → 검수중 → 견적전달 → 입금완료 → 카톡방생성 → OT시트전송 → 일정전송 → 캠페인등록 → 최종완료 → 거절 |
| 건수 표시 | 탭 라벨 옆 괄호: 「신규접수(3)」 |
| 기본 활성 탭 | **「전체」** |
| 0건 단계 탭 | **회색·0건 표시** (탭 자체는 유지, 클릭 시 빈 목록) |
| 기존 「상태 필터 드롭다운」 | **제거** — 탭이 완전 대체. 폼타입·기간·검색 필터는 그대로 유지 |
| 가로 폭 부족 시 | 페인 가로 폭이 좁으면 탭 영역 가로 스크롤 허용 (overflow-x:auto). 줄바꿈은 안 함 |

---

## 2. 탭 라벨 매핑

| 상태 code | 한국어 라벨 |
|---|---|
| (전체 — 필터 없음) | **전체** |
| `new` | 신규접수 |
| `reviewing` | 검수중 |
| `quoted` | 견적전달 |
| `paid` | 입금완료 |
| `kakao_room_created` | 카톡방생성 |
| `orient_sheet_sent` | OT시트전송 |
| `schedule_sent` | 일정전송 |
| `campaign_registered` | 캠페인등록 |
| `done` | 최종완료 |
| `rejected` | 거절 |

> 기존 코드의 `BRAND_APP_STATUS_ORDER` 배열 순서와 일관성 맞춤. 라벨은 브랜드 서베이 현황 대시보드 깔때기에 쓰던 한국어 그대로.

---

## 3. UI 사양

### 3-1. 탭 마크업 위치

- 페인 헤더 영역(`/admin#brand-applications`) 하단, 기존 「폼타입·기간·검색」 필터 줄 **위**에 탭 영역 신규 삽입
- 마크업 패턴: 기준 데이터 페인의 탭 마크업과 동일한 클래스/구조 재사용(`.admin-tabs` 또는 페인 내부 탭 패턴)
- 「상태 필터 드롭다운」 마크업(`<select>` 요소) 제거

### 3-2. 시각 스타일

기준 데이터 페인과 동일:
- 활성 탭: 핑크 글자 + 핑크 밑줄(`border-bottom:2px solid #E8344E`) + 굵은 글자
- 비활성 탭: 회색 글자 + 밑줄 없음 + 호버 시 옅은 회색 배경
- 건수 괄호: 작은 글자 + 회색 (활성 탭에서도 본문보다는 옅게)
- 0건 탭: 글자 색을 더 옅게(`#aaa`) — 「회색·0건 표시」 결정 반영

### 3-3. 동작

- 탭 클릭 → 해당 상태의 신청만 목록에 표시 + 페인 sentinel 리셋(IntersectionObserver lazy-load 호환)
- 「전체」 클릭 → 모든 상태 표시
- 다른 필터(폼타입·기간·검색)와 **AND 결합**
- URL 해시 쿼리 동기화 (선택 — 별도 결정 사항). 권장: `/admin#brand-applications?status=new`로 진입 시 해당 탭 자동 활성. 명시되지 않으면 기본값 「전체」
- 건수는 **현재 폼타입·기간·검색 필터 적용 후** 계산 (탭 = 상태 분포, 다른 필터는 모집단 좁힘)
- 페인 데이터 새로고침 시 탭 건수도 함께 갱신 (`refreshPane('brand-applications')` 안에서 처리)

### 3-4. 「전체」 탭 건수 처리

- 「전체(N)」 N은 다른 필터(폼타입·기간·검색) 적용 후 모든 행의 합계
- 다른 필터가 없으면 `brand_applications` 전체 건수

---

## 4. 영향 파일

- `dev/admin/index.html` — 브랜드 서베이 페인 영역
  - 기존 상태 드롭다운 `<select>` 제거
  - 탭 마크업 영역 추가 (기준 데이터 페인 탭 클래스 재사용)
- `dev/js/admin.js` 또는 `dev/js/admin-brand.js` (브랜드 서베이 영역이 어느 파일에 있는지에 따름)
  - 탭 렌더링 함수 신규 — `renderBrandAppStatusTabs(applications)`
  - 탭 활성 상태 관리 (현재 선택 상태를 페인 상태에 보관)
  - 건수 계산 — 현재 폼타입·기간·검색 필터 적용 후 상태별 group by
  - 기존 상태 드롭다운 이벤트 핸들러 제거
  - `BRAND_APP_STATUS_ORDER` 배열 그대로 사용 (탭 순서와 일관)
  - URL 해시 쿼리 파싱 (선택)
- `dev/css/admin.css`
  - 기준 데이터 페인 탭 스타일이 공통 클래스로 분리돼 있으면 재사용
  - 분리 안 되어 있으면 본 PR에서 공통 클래스로 추출 후 양쪽에서 사용

---

## 5. 충돌 점검 (다른 진행 일감과의 관계)

- **관리자 메일 수신 분리 (B)**: 관리자 계정 페인 — 영역 다름. 충돌 없음
- **응모 취소 (A) PR-C**: 신청 관리 페인 — 다른 페인. 충돌 없음
- **NG 사항 번들화 (C)**: 캠페인 폼·기준 데이터 NG 탭 — 다른 영역. 충돌 없음
- **브랜드 서베이 모집비 (D)**: 같은 페인(`/admin#brand-applications`)이지만 영역 다름 (D는 신규 등록·수정 모달, 본 일감은 페인 상단 탭) — **같은 파일 다른 영역**, rebase 가능. **개발1이 D를 진행 중이면 본 일감을 D PR에 합치거나 별도 PR로 진행 후 rebase**

### 5-1. D 일감과의 합류 권장 여부

본 일감을 **D PR에 합치는 게 효율적**일 수 있음 — 둘 다 같은 페인 영역(`dev/admin/index.html` 브랜드 서베이 부분, `dev/js/admin-brand.js`)이고 변경 규모가 작음. 개발1 판단 권장.

---

## 6. QA 시나리오 (개발서버 → reverb-qa-tester light)

1. 페인 진입 → 「전체」 탭 활성 + 전체 건수 정확
2. 「신규접수(N)」 탭 클릭 → status='new' 만 노출 + 다른 탭은 비활성
3. 폼타입 필터 적용 → 탭 건수가 그 필터 모집단으로 좁혀짐
4. 검색어 입력 → 탭 건수가 검색 결과 모집단으로 좁혀짐
5. 0건 탭(예: 카톡방생성(0)) 회색 표시 + 클릭 시 빈 목록 + 「데이터가 없습니다」 안내
6. 가로 폭 좁은 환경 (브라우저 윈도우 1280px 등)에서 탭이 잘리지 않고 가로 스크롤
7. URL `/admin#brand-applications?status=quoted`로 직접 진입 → 「견적전달」 탭 활성 (URL 쿼리 동기화 구현 시)
8. 상세 모달에서 상태 변경 후 페인 복귀 → 탭 건수 자동 갱신
9. 엑셀 내보내기 — 현재 탭 필터 적용된 데이터만 또는 전체? 결정 필요 — 권장: **현재 탭 필터 적용 데이터만** (운영자가 보는 그대로 다운로드)

---

## 7. 약관·정책 영향

- 관리자 페이지 UI 변경 — 인플루언서·광고주 데이터 처리 변동 없음
- 약관·개인정보처리방침 영향 없음

---

## 8. 롤백 절차

1. `dev/admin/index.html`에서 탭 마크업 제거 + 상태 드롭다운 마크업 복원
2. `dev/js/admin.js`(또는 admin-brand.js)에서 탭 함수 제거 + 드롭다운 이벤트 복원
3. CSS 공통 클래스 분리했다면 그대로 두고 기준 데이터 페인 영향 없는지 확인
4. `git revert` 본 PR

---

## 9. 시작 절차

```bash
cd ~/Documents/projects/reverb-jp
git checkout dev
git pull origin dev

# 개발1의 D 일감(브랜드 서베이 모집비) 진행 상태 확인
git log --oneline -5
# 같은 페인 영역이라 합류 여부 개발1과 짧게 합의

# 합류하면 같은 PR로 진행, 별도 PR이면 D 머지 후 rebase
```

---

## 10. 미해결 / 후속

### 10-1. 확정 (2026-05-12)
- 탭 구성 11개 (전체 + 10단계)
- 기본 활성: 전체
- 0건 단계: 회색·0건 표시
- 기존 드롭다운: 제거

### 10-2. 작업자 판단 사항 (사양 외)
- URL 해시 쿼리 동기화 — 권장하지만 본 PR 범위 결정은 작업자 재량
- 엑셀 내보내기가 현재 탭 필터를 반영할지 — 권장 「반영」, 운영팀 의견 반영 가능
- 탭 영역 가로 스크롤 대신 「더보기 ▾」 드롭다운으로 일부 탭 접기 — 가로 스크롤 권장(접근성·발견성). 작업자 판단

---

## 11. 긴급 보강 — stale 상태 방어 (2026-05-12 PR #182 머지 후 회귀 대응)

### 11-1. 회귀 증상
- dev 일반 브라우저에서 `/admin#brand-applications` 새로고침 시 메인 영역 공백(사이드바만 표시)
- 시크릿 창 = 정상. 일반 창에서 `localStorage.clear(); sessionStorage.clear(); location.reload()` 후 복구
- 운영 배포 차단 조건 — 본 보강 머지 + 일반 브라우저 직접 검증 통과 전 dev → main 통합 PR 작성 금지

### 11-2. 본 세션이 코드 베이스에서 확인한 사실
- `dev/js/admin-brand.js`는 `localStorage`·`sessionStorage` **호출 0건** (grep 검증)
- `dev/js/` 전 영역에서 brand·status·admin·filter 관련 localStorage 호출 0건
- `sessionStorage` 사용은 `reverb.recovery`(비밀번호 재설정 플래그)만 — 브랜드 서베이와 무관
- `admin-brand.js:75` — `bar` null 가드 이미 적용 (`if (!bar) return;`)
- `admin-brand.js:1393-1396` — hash 파싱 + `BRAND_APP_STATUS_TABS.some()` 화이트리스트 검증 이미 적용
- 즉 개발1 요청 보강 1~3 중 일부는 이미 코드에 존재

### 11-3. 의심 원인 (우선순위 순)
1. **브라우저 JS·HTML 캐시** — 일반 창은 옛 JS·HTML 캐시 사용, 시크릿 창은 캐시 없음. PR #182 머지 직후 캐시된 옛 admin/index.html이 옛 JS 함수 시그니처로 새 admin-brand.js 호출 → 함수 누락 throw → 페인 진입 중단. `localStorage.clear()` 자체보다 `location.reload()`가 cache-bust 효과로 복구됐을 가능성
2. **Supabase Auth 토큰** — Supabase JS SDK가 자체적으로 localStorage 사용 (`sb-*-auth-token` 키). 만료 토큰이 fetch에서 401 → `fetchBrandApplications` throw → 메인 페인 공백. `localStorage.clear()`로 토큰 삭제 → 재로그인 → 정상 복구. 사용자 묘사와 부합
3. **`fetchBrandApplications` / `fetchBrandAppHistoryCounts` / `fetchBrandAppMemoSummaries` 셋 중 하나가 throw** — `Promise.all(...)` 안에서 throw하면 `loadBrandApplications` 전체 중단. try/catch 없음
4. **다른 PR(#184·#187·#188·#189·#190)에서 도입된 코드의 stale 영향** — 본 세션이 그 영역 미점검

### 11-4. 보강 항목 (개발1 또는 다른 개발 세션이 코드 작업으로 수행)

#### A. `loadBrandApplications` 전체 try/catch 감싸기 (필수)
```js
async function loadBrandApplications() {
  var tbody = $('brandAppTableBody');
  if (tbody) tbody.innerHTML = '<tr>...스피너...</tr>';

  try {
    // 기존 hash 파싱 + fetch + 렌더 로직
    var hashStatus = parseHashQuery('status');
    if (hashStatus) {
      if (!BRAND_APP_STATUS_TABS.some(function(t){ return t.code === hashStatus; })) {
        // 화이트리스트 미통과 — 옛/잘못된 hash. 강제 정리
        _brandAppActiveStatusTab = null;
        history.replaceState(null, '', '#brand-applications');
      } else {
        _brandAppActiveStatusTab = hashStatus;
      }
    }

    var [apps, counts, memoSummaries] = await Promise.all([
      fetchBrandApplications(),
      fetchBrandAppHistoryCounts(),
      fetchBrandAppMemoSummaries()
    ]);
    _brandApps = apps || [];
    _brandAppHistoryCounts = counts || {};
    _brandAppMemoSummaries = memoSummaries || {};
    renderBrandApplicationsList();
    refreshBrandAppBadge();
  } catch (err) {
    console.error('[brand-applications] load failed:', err);
    if (tbody) {
      tbody.innerHTML = '<tr><td colspan="24" style="text-align:center;color:#c33;padding:24px">'
        + '신청 목록을 불러오지 못했습니다. 새로고침 또는 재로그인 후 다시 시도해 주세요.'
        + '<br><button onclick="location.reload()" class="btn btn-primary" style="margin-top:8px">새로고침</button>'
        + '</td></tr>';
    }
    // 탭 바도 안전 렌더 (모든 카운트 0)
    try { renderBrandAppStatusTabs({}); } catch(e) {}
  }
}
```

#### B. `parseHashQuery` 화이트리스트 미통과 시 hash 강제 정리 (필수)
- 위 A 안에 포함됨
- 옛 status 값이 hash에 남아있는 사용자도 새 코드로 자연 정합

#### C. `renderBrandAppStatusTabs` baseCounts null 기본값 보장 (보강)
```js
function renderBrandAppStatusTabs(baseCounts) {
  var bar = $('brandAppStatusTabBar');
  if (!bar) return;
  baseCounts = baseCounts || {};   // ← 추가 (이미 76행 `baseCounts || {}` 있으나 명시적 디폴트 추가)
  ...
}
```

#### D. `_brandApps`·`_brandAppHistoryCounts`·`_brandAppMemoSummaries` null 안전 (보강)
- `_brandApps = apps || [];` 패턴 적용 — `apps`가 null 반환 시 `_brandApps.slice()` throw 차단
- `getFilteredBrandApps()` 첫 줄 `var list = (_brandApps || []).slice();`로 더 단단하게

#### E. 캐시 무효화 — 빌드 산출물 cache-busting (선택, 별도 작업)
- 본 PR 범위 외. 다만 회귀 근본 원인일 가능성 매우 높음
- `dev/build.sh`가 빌드 산출물 `index.html`/`admin/index.html`에 JS·CSS `?v={빌드시각}` 쿼리 자동 부여하도록 별도 일감으로 검토 권장
- 또는 운영 배포 직후 사용자에게 「Ctrl+Shift+R로 강제 새로고침」 안내

### 11-5. 검증 시나리오 (보강 머지 후)
1. 일반 브라우저에서 `/admin#brand-applications` 새로고침 → 정상 (메인 영역 공백 아님)
2. 콘솔에서 `history.replaceState(null, '', '#brand-applications?status=under_review_old')`로 옛 hash 주입 → 새로고침 → 화이트리스트 미통과로 hash 정리 + 「전체」 탭 활성 + 정상 렌더
3. 콘솔에서 Supabase 토큰 임의 손상 (`localStorage.setItem('sb-...-auth-token', 'invalid')`) → 새로고침 → fetch 실패하지만 페인 안에 빨간 에러 + 「새로고침」 버튼 노출 (전체 화면 공백 아님)
4. 시크릿 창에서도 정상 (현재 정상이라 회귀 없음)
5. localStorage·sessionStorage 모두 비운 상태에서도 정상 (현재 정상이라 회귀 없음)

### 11-6. 운영 배포 차단 조건
- 11-4 A·B·C·D 보강 머지 완료
- 11-5 검증 시나리오 모두 통과 확인
- 11-5의 5번까지 통과 후에만 dev → main 통합 PR 작성

### 11-7. 본 보강과 다른 일감(D·E·F)·진행 PR의 관계
- 본 보강은 E 사양서(본 문서)의 §3-3 URL 쿼리 동기화 동작 안전성 강화 — E 코드 보강
- D(브랜드 서베이 모집비), F(미니 에디터 이미지) 등 후속 사양은 영향 없음
- PR #184·#187·#188·#189·#190 등 다른 후속 PR은 본 보강과 충돌 없음 — 같은 파일 안 다른 함수
- 보강은 단일 hotfix PR로 신속 진행 권장
