# 관리자 인플루언서 연령·성별 분포 대시보드

**작성일:** 2026-06-22
**상태:** 기획 완료 · 구현 미착수 (데이터 수집 대기)

> 연령 정책(만 18세, 2026-06-22 운영 출시)으로 수집되는 `influencers.birthdate`·`gender`를 관리자 대시보드에 분포 차트로 시각화. 사용자 요청 "전체현황에서 연령·성별 대시보드".

---

## 현재 상태 (2026-06-22 기준)

### 관련 코드·DB·UI 진입점

**기존 차트·대시보드 (재사용)**
- `dev/js/admin-dashboard.js`
  - `loadAdminData(preloaded)` — 대시보드 단일 진입점. `Promise.all([fetchCampaigns, fetchInfluencers, fetchApplications])` 전건 로드 → **감사용 격리**(`const statsUsers = users.filter(u=>!u.is_audit)`) 후 각 렌더 함수에 `statsUsers` 전달. 신규 차트도 같은 `statsUsers`를 받으면 **추가 조회 0회 + 감사용 자동 제외**.
  - `renderAddressDistribution(users)` + `buildAddressChartOptions(stats)` — **도넛 차트 복제 대상**. 범례 `라벨 N명 (XX.X%)`, 빈 상태(`addressDistEmpty`/`addressDistLoading`), `_addressDistChart.destroy()` 후 재생성.
  - `PREFECTURE_KO` / `ADDRESS_DIST_COLORS` — 색상 팔레트 재사용. 도넛의 `未登録/海外` 회색 패턴을 「미등록/응답 안 함」에 차용.
  - `renderSignupChart` / `switchSignupPeriod` — 막대 차트 + 기간 토글 패턴.
  - `renderProfileCompletion` — 가로 막대 HTML 직조(수집률 표시에 참고).
  - `_allUsers` 전역 — 기간 토글 재렌더 캐시.
- `dev/admin/index.html` 대시보드 카드 마크업 — `회원가입 추이`+`프로필 완성률` grid, `배송지 분포` full-width 카드(`admin-card`+`admin-card-header`+canvas+empty/loading). 신규 카드는 이 형식 복제.

**연령·성별 헬퍼·DB**
- `dev/lib/shared.js` — `AGE_POLICY_MIN_AGE=18`, `calcAgeFromBirthdate(str)` (KST 만 나이, `YYYY-MM-DD` 정규식, 미매칭/빈값=null). `genderLabel(code)`(일/한 토글용 — 관리자는 한국어 고정이라 별도 한국어 매핑 필요: 남성/여성/그 외/응답 안 함).
- `dev/lib/storage.js` — `fetchInfluencers(opts)` `select('*')`+`fetchAllPaged`(1000행 cap 우회 전건). `birthdate`·`gender`가 `*`에 포함돼 이미 클라 메모리에 있음. `computePrefectureStats(users, limit)` — 순수 집계 함수 패턴(쿼리 없이 배열만 받음) = **연령·성별 집계 함수의 모델**.
- DB: `birthdate date NULL`·`gender text CHECK(male/female/other/undisclosed)`·`age_consent_at`(마이그레이션 180·185, 운영 적용 완료). 서버 `calc_age_kst(date)`(트리거용). **전체 ~1,450명 전원 NULL** — 6/22 신규 가입 + 7/22 시행 후 응모 게이트로 점진 누적.

### 이 제안과 충돌 가능성 있는 기존 동작
- **충돌 없음 — 4개 영역 확인.** 신규 차트는 `loadAdminData`에 렌더 호출 한 줄 + 신규 HTML 카드 + 신규 집계 함수만 추가. 기존 KPI·차트·격리 로직과 데이터 경로 안 겹침(같은 `statsUsers` 읽기만).
- 대시보드 카드는 목록 페인 7개 구조 통일 규칙(`.claude/rules/ui.md`) 대상 아님(`admin-pane-list` 미적용 자연 스크롤) → 자유 추가 가능.

### 미해결 백로그·관련 작업
- 연령 정책 허브: `docs/specs/2026-05-27-age-minor-policy.md`, 메모리 `project_age_policy`(운영 출시 완료, 시행 2026-07-22).
- 관리자 권한 매트릭스(`docs/specs/2026-06-15-admin-permission-matrix.md`) **갭1**: campaign_manager가 인플루언서 민감정보에 서버 접근 가능(화면만 숨김). `fetchInfluencers`가 `select('*')`라 birthdate/gender도 전 관리자 클라 메모리에 이미 존재 — 분포 통계 노출은 이 갭과 같은 성질(별도 RLS 과제, 본 사양 범위 밖).

---

## 의심·경우의 수

### 1. 깨질 수 있는 경우의 수

**데이터 (최대 리스크 — 현재 0건)**
- 전원 NULL 상태에서 차트가 텅 비거나 "미등록 100%" 1조각 → 운영자 "고장났나?" 오해. → **수집률(등록 %) KPI를 차트 위에 배치, 0건이면 차트 대신 「아직 수집 전」 안내** 필수.
- 소표본 비율 왜곡(등록 5명인데 "20대 80%") → 운영·보고 오도. → **분모(등록 N명) 항상 병기**, 표본 30명 미만 「참고용」 캡션, 비율보다 실수(명) 강조.

**UX (필수)**
- 빈 상태 인지: 0건 단순 빈 캔버스는 사고 → `addressDistEmpty` 패턴 복제.
- 「미등록(NULL)」 vs 「응답 안 함(undisclosed)」 혼동 → **별도 조각 구분**(미등록=회색, 응답 안 함=연회색). 합치면 "성별 미상"이 부풀려 보임.

**권한·환경**
- campaign_manager 노출: 분포는 집계값이라 직접 노출 아님. 소표본(「30대 여성 1명」) 재식별 위험은 표본 적을 때만 → 1단계 전 관리자 노출 + 소표본 캡션 완화.
- 개발(테스트 계정 입력 있을 수 있음) vs 운영(0건) — 검증 시 양쪽(빈 상태/데이터 있는 상태) 모두 확인.

**기술**
- 감사용 격리 누락(신규 차트에 `users` 전건 전달) → 통계 오염. **반드시 `statsUsers` 전달**.
- 비정상 birthdate(미래 날짜·음수·150세) → `calcAgeFromBirthdate`는 음수도 반환 → 집계 시 `age<0`·비현실값은 「미등록/이상치」로 분류.

### 2. 현재 구현 충돌점
- 확인 완료, 충돌 없음 (기존 `statsUsers`를 읽기만).

### 3. 의도 모호점 (→ 사용자 확인으로 해소됨)
- "전체현황" 위치 → **관리자 대시보드 확정**.
- 연령 구간 → **마케팅 구간 확정**.
- 분석 범위 → **연령×성별 교차 포함 확정**.

---

## 제안 / 설계

### 위치: 관리자 대시보드(`#dashboard`)에 카드 1개 추가 (확정)
- 배송지 분포 도넛 아래 full-width 「회원 연령·성별 분포」 카드. `loadAdminData`가 이미 전건 로드 → 추가 쿼리 0.

### 차트 구성
헤더 우측: `등록 N/전체 M명 · 수집률 XX%`

1. **수집률 KPI (상단 띠)** — `생년월일 등록 X%` / `성별 등록 Y%` 가로 막대(`renderProfileCompletion` 패턴). **초기 핵심 지표**(분포는 표본 부족, 수집 진척이 먼저).
2. **연령대 막대** — 마케팅 구간 `18-24 / 25-29 / 30-34 / 35-39 / 40-49 / 50세 이상` + **「미등록」 별도 막대**. 만 18세 미만 구간 없음(정책상 0이어야 정상 — 나오면 이상 신호, 「18세 미만은 정책상 0」 캡션).
3. **성별 도넛** — `남성 / 여성 / 그 외 / 응답 안 함 / 미등록` **5조각**(응답 안 함 ≠ 미등록 분리). 색상 `ADDRESS_DIST_COLORS` 재사용.
4. **연령×성별 교차표 (범위 확정 — 교차 포함)** — 행=연령대 마케팅 구간, 열=성별 4종(+미등록), 칸=인원수. **비율(%)이 아니라 실수(명) 중심**(소표본 칸 1~2명 왜곡 방지). 표본 30명 미만이면 표 상단 「표본이 적어 참고용」 캡션. 누적 가로 막대 또는 단순 표 — 구현 시 가독성 높은 쪽 택(권장: 단순 표, 칸 0명은 `-` 표기).

### 집계 방식: 클라이언트 메모리 집계 (확정 — 신규 DB 없음)
- 신규 함수 `computeAgeGenderStats(users)` (`storage.js`, `computePrefectureStats` 옆) + 렌더 `renderAgeGenderDistribution(users)` (`admin-dashboard.js`). **DB 변경·마이그레이션 없음**. 감사용 격리 자동 상속(`statsUsers`).
- 반환 예시:
  ```
  {
    total: M, ageRegistered: N1, genderRegistered: N2,
    ageBuckets: [{label:'18-24', count}, ... {label:'미등록', count}],
    gender: { male, female, other, undisclosed, unregistered },
    cross: { '18-24': {male, female, other, undisclosed, unregistered}, ... }  // 교차표
  }
  ```
- (회원 1만 명 초과로 화면이 무거워지면 서버 집계 RPC로 전환 — 백로그. 현 1,450명엔 클라 집계로 충분.)

### 빈 상태 / 초기 수집률 UX
- 등록 0건(현재): 차트 숨김 + 「아직 생년월일·성별 데이터가 수집되지 않았습니다. 신규 가입과 응모 시 점진 수집됩니다」. 수집률 0%.
- 소표본(1~29명): 차트 그리되 「표본 N명 — 참고용」 캡션, 실수(명) 강조.
- 로딩: `addressDistLoading` 스피너 복제.

---

## PR 분할
단일 PR로 충분(대시보드 카드 + 집계 함수 + 렌더 함수, DB 무변경). `build.sh` 신규 파일 없음(기존 파일 수정만) → `bash dev/build.sh`만.
- 수정 파일: `dev/admin/index.html`(카드 마크업) · `dev/lib/storage.js`(`computeAgeGenderStats`) · `dev/js/admin-dashboard.js`(`renderAgeGenderDistribution` + `loadAdminData` 호출 한 줄).
- `admin.js` 핫스팟 무관 → 단일 작업이면 시퀀셜로 충분.

## 착수 시점 권고
데이터가 0건이라 **빈 상태·수집률 중심으로 지금 구현해도 무방**(시행 후 자연스럽게 분포가 채워짐). 단 사용자가 "기획만 먼저"로 보류 → 구현 착수는 별도 결정. 7/22 시행 후 어느 정도 쌓이면 분포·교차표가 의미를 갖는다.

## 사용자 확인 필요
- (해소됨) 위치=관리자 대시보드 / 연령 구간=마케팅 구간 / 범위=연령×성별 교차 포함.
- 남은 확인: 착수 시점(지금 vs 데이터 쌓인 뒤).

## 구현 결과
**구현일:** 2026-06-22 / **관련 커밋:** feature/age-gender-dashboard (dev PR)

### 초안 대비 변경 사항
- 추가된 것: 설계대로 전부 구현(수집률 막대·연령대 막대·성별 도넛·연령×성별 교차표·빈 상태·소표본 캡션).
- 빠진 것: 없음.
- 달라진 것: 없음(설계 그대로). 데이터 0건이라 현재 운영에선 「아직 수집 전」 안내만 노출.

### 구현 중 기술 결정 사항
- `dev/lib/storage.js` `computeAgeGenderStats(users)` — 순수 집계(`computePrefectureStats` 패턴). 연령 버킷: `null/age<18/age>120`은 분류 제외(미등록 또는 이상치), 18-24/25-29/30-34/35-39/40-49/50+. **미등록(생년월일 NULL)** vs **이상치(생년월일 있으나 18세 미만/비현실)** 분리. 성별 `unregistered` = male/female/other/undisclosed 외. 교차 `cross[버킷|미등록][성별]`. 만나이는 `calcAgeFromBirthdate`(KST, shared.js).
- `dev/js/admin-dashboard.js` `renderAgeGenderDistribution(statsUsers)` — 연령 막대=Chart.js bar(미등록/이상치 회색), 성별 도넛=`buildAddressChartOptions({total})` 재사용(분모=전체), 교차표=HTML 테이블(0은 `-`, DB 문자열 미삽입이라 esc 불필요). 전역 `_ageDistChart`/`_genderDistChart`(재생성 전 destroy). `loadAdminData`에서 `statsUsers`(감사용 격리) 전달.
- `dev/admin/index.html` — 「회원 연령·성별 분포」 카드(배송지 분포 카드 다음). DOM 8종.
- **DB 변경 없음**(기존 birthdate/gender 컬럼·클라 in-memory 집계).
- [via planner] 설계 / [via reviewer] GO(감사용 격리·버킷 경계·교차 합 정합·DOM 일치·빈상태 destroy 확인). qa 권장 light.

### 후속 백로그
- 🟡 **번들 오염(무해)**: `computeAgeGenderStats`·`AGE_GENDER_BUCKETS`가 `storage.js`에 있어 인플루언서 앱 번들에도 포함됨(개인정보 노출 0·집계 함수일 뿐). 기존 `computePrefectureStats`도 동일 위치라 일관적. 정리하려면 `admin-dashboard.js`/`admin-core.js`로 이동(별도 리팩터링, `computePrefectureStats`와 함께).
- 데이터 누적 후(7/22 시행 이후) 분포·교차표가 의미를 가짐. 현재는 수집률·빈 상태 중심.
