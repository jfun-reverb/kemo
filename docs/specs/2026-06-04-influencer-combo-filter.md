# 인플루언서 관리 — 주소지 + 채널 + 팔로워 조합 필터

**작성일:** 2026-06-04
**작성 세션:** 기획/설계
**상태:** 초안 (사용자 정책 확정, 개발 미착수)

---

## 배경 (사용자 요청)

운영서버에서 "주소지 오사카 + 인스타 팔로워 1000명 초과 인플루언서가 몇 명인지" 같은 조건별 집계를 매번 SQL로 돌려야 했음. 자주 필요하므로 **인플루언서 관리 화면에 주소지·채널·팔로워 조합 필터**를 넣어 화면에서 바로 거르고 인원수를 보고 싶다는 요청 (2026-06-04).

**사용자 확정 정책 (AskUserQuestion 5회):**
1. 팔로워 = **최소~최대 범위** 입력
2. 주소지(도도부현) = **여러 곳 동시 선택**(다중), 「未登録」·「海外」도 선택지 포함
3. 채널 = '전체'일 때 팔로워 기준 = **모든 채널 합계 팔로워**
4. **엑셀 내보내기 포함** — 필터 적용 결과를 엑셀로 내려받기
5. 엑셀 범위 = **기본은 계정+SNS**(모든 관리자), **민감정보 추가 열(전화·LINE·PayPal·상세주소)은 캠페인 관리자(campaign_admin) 이상**이 「민감정보 포함」 선택 시에만

---

## 현재 상태 (작성일 2026-06-04 기준 — planning.md 규칙 A)

### 관련 코드·UI 진입점

**인플루언서 목록 페인** (`dev/admin/index.html` 832~894, `dev/js/admin-influencers.js`)
- 현재 필터: SNS 채널 `#infChannelFilter`(all/instagram/x/tiktok/youtube) + 인증 `#infFilterVerifiedSelect`(all/verified/unverified) + 위반 `#infFilterViolationSelect`(all/clean/has/blacklist) + 통합검색 `#infSearch`(이름·SNS·이메일)
- 필터 적용: `renderInfluencersPane()` (43~68) — **클라이언트 in-memory `.filter()`**, 모든 조건 AND
- 데이터: `loadAdminInfluencers()` (28) → `fetchInfluencers()` 전건 로드(`range` pagination, `select('*')`) → `infUsersCache` 전역 캐시. **모든 컬럼 로드됨**(prefecture·city·ig/x/tiktok/youtube·*_followers·primary_sns 포함)
- **채널 필터는 거름이 아니라 보기 전환(탭)** — `switchInfTabFromSelect()` (79) → `renderInfTable(filtered, currentInfTab)`. all=10컬럼 전체, 채널 선택 시 그 채널 등록자(`u[fKey] > 0`)만 7컬럼. `fKey`={instagram:'ig_followers', x:'x_followers', tiktok:'tiktok_followers', youtube:'youtube_followers'}
- lazy-load: `infLazy` + `mountLazyList()`(`dev/js/ui.js` 799), pageSize 80. 필터 변경 시 `infLazy.destroy()` 후 재생성 + 스크롤 리셋
- 필터 초기화: `resetInfluencerFilters()` (70~77)
- 검색 헬퍼: `matchSearchTokens()` (`dev/lib/shared.js` 304) — 공백 토큰 AND
- 다중 선택 UI 헬퍼: `admin-core.js` 공용 「다중필터」 패턴 존재(재사용 후보)

**데이터 형식**
- `prefecture text` — 일본어 raw(`大阪府`·`東京都`·`北海道`). 끝자 都/道/府/県 로 일본 판별
- `ig_followers`·`x_followers`·`tiktok_followers`·`youtube_followers` 모두 `integer DEFAULT 0`
- 도도부현 한국어 라벨: `PREFECTURE_KO`(`dev/js/admin-dashboard.js` 159~172, 47개). 현재 대시보드 도넛에만 사용 → **재사용 가능**(전역). 일본 판별·海外 분리 로직도 `admin-dashboard.js` 배송지 분포 집계에 있음(재사용)

### 이 제안과 충돌 가능성 있는 기존 동작
- 클라 in-memory 필터라 **DB·RLS·트리거 무변경**. `renderInfluencersPane()` 의 `.filter()` 에 조건 3개 추가 + UI 칸 추가 + 초기화 함수 추가가 전부.
- 채널 필터가 "탭 전환"이라 팔로워 범위 필터는 **선택 채널 기준**으로 묶임(전체=합계). 채널 전환 시 컬럼 구조가 바뀌는 기존 동작 유지.
- lazy-load sentinel — 새 필터 변경에도 `infLazy.destroy()` 재생성 경로 타게 해야(누락 시 stale 목록).

### 미해결 백로그·관련 작업
- 대시보드 배송지 도도부현 분포(`admin-dashboard.js`) — 같은 `prefecture`·`PREFECTURE_KO` 사용. 라벨/판별 로직 공용화 기회.

---

## 의심·경우의 수 (planning.md 규칙 B)

1. **(데이터) 합계 팔로워 계산** — `ig+x+tiktok+youtube_followers`, 각 NULL은 0 처리. (LIPS·@cosme는 팔로워 컬럼 없음 → 합계에서 제외, 명시)
2. **(데이터) 海外·未登録 판별** — `prefecture` 가 NULL/빈값 = 「未登録」, 47개 도도부현 목록에 없는 비어있지 않은 값 = 「海外」. dashboard 판별 로직 재사용해 일관성 유지.
3. **(데이터) 표기 흔들림** — 과거 데이터에 `大阪`(府 누락) 등이 있으면 다중 선택 정확 매칭에서 빠질 수 있음. 도도부현 옵션은 `PREFECTURE_KO` 키(정식 표기) 기준 → 비정식 표기는 「海外」로 잘못 분류될 위험. 개발 시 운영 DB `prefecture` distinct 값 점검 권고.
4. **(UX 필수) 결과 인원수 표시** — 사용자 원 니즈가 "몇 명". 필터 적용 결과 **「N명」 카운트를 sticky-header 에 표시** 의무(현재 약함). 빈 결과 시 「조건에 맞는 인플루언서가 없습니다」 안내.
5. **(UX) 채널 '전체' + 팔로워 범위** — 합계 기준임을 화면에 명시(예: 팔로워 칸 옆 「합계 기준」 보조 라벨). 채널 선택 시 「○○ 팔로워 기준」으로 라벨 변경.
6. **(UX) 다중 선택 UI** — `<select multiple>` 은 조작 불편 → `admin-core.js` 다중필터(체크박스 드롭다운) 패턴 재사용 권장. 선택한 지역은 칩/요약으로 표시.
7. **(UX) 필터 칸 증가** — 관리자 PC 전폭이라 가로 공간 여유. sticky-header 한 줄에 배치하되 넘치면 2줄 래핑 허용.
8. **(성능) 합계·범위 비교는 클라 계산** — 현재 전건 캐시(수천 명) 규모에선 무리 없음. 1만 명+ 로 커지면 서버 쿼리 전환 검토(현재 불필요).

### 현재 구현과 충돌하는 지점
- 확인된 직접 충돌 없음. 추가형 필터, DB 무변경.

9. **(보안 ⚠️ 중요) 민감정보 열 권한은 현재 「표시 제한」 수준** — `fetchInfluencers()` 가 `select('*')` 로 전건 로드하므로 `phone`·`paypal_email`·상세주소가 **이미 모든 관리자(campaign_manager 포함) 브라우저 메모리에 내려와 있음**(influencers RLS = `is_admin()` 전체 SELECT). 따라서 "민감정보 열은 campaign_admin 이상"은 **엑셀 출력 시 클라 표시/권한 분기**일 뿐, 데이터 자체 차단은 아님. 진짜 컬럼 차단이 필요하면 RLS/뷰 컬럼 마스킹(별도 과제). 본 작업 범위에서는 클라 권한 분기로 구현하되 이 한계를 PR 본문·reviewer 체크에 명시.

### 의도 모호점
- (해소됨) 엑셀 내보내기·권한 범위 모두 확정.

---

## 제안 / 설계

### UI 추가 (`dev/admin/index.html` 인플루언서 sticky-header)
1. **주소지(도도부현) 다중 선택** `#infPrefectureFilter` — 체크박스 드롭다운(admin-core 다중필터 재사용). 47개(PREFECTURE_KO 한국어 라벨) + 「未登録」 + 「海外」. 선택 지역 칩 요약.
2. **팔로워 범위** `#infFollowersMin` / `#infFollowersMax` — 숫자 2칸. 비우면 하한/상한 무제한. 기준은 채널 선택값(전체=합계). 옆에 「(채널명) 팔로워 기준」 보조 라벨.
3. **결과 인원수** — sticky-header 에 「N명」 표시(필터 적용 후 `filtered.length`).

### 필터 로직 (`admin-influencers.js` `renderInfluencersPane()` 의 `.filter()` 에 추가)
```
// 주소지(다중): 선택 없으면 통과
if (prefSel.length) {
  const key = classifyPrefecture(u.prefecture); // 정식 도도부현 | '未登録' | '海外'
  if (!prefSel.includes(key)) return false;
}
// 팔로워 범위: 채널 기준 컬럼(전체=합계)
const fv = followerValueByChannel(u, currentInfTab); // all → ig+x+tiktok+youtube
if (minF != null && fv < minF) return false;
if (maxF != null && fv > maxF) return false;
```
- `classifyPrefecture()`·`followerValueByChannel()` 공용 헬퍼는 `shared.js` 또는 `admin-core.js`(대시보드 판별 로직과 통합)
- `resetInfluencerFilters()` 에 신규 필터 초기화 추가
- 필터 변경 핸들러도 기존 `rerenderInfluencersFromCache()` 재사용 → lazy 재생성 경로 그대로

### 엑셀 내보내기 (확정)
- 인플 목록 sticky-header 에 **「엑셀 다운로드」 버튼** — 현재 **필터가 적용된 결과**만 내보냄(화면에 보이는 대상 = 엑셀 대상).
- 포맷: 기존 `_excel*` 헬퍼(ExcelJS CDN lazy-load) 재사용 → `.xlsx`. (인플 목록은 이미지 없어 가벼움)
- **기본 열(모든 관리자)**: 이름(한자)·이름(가나)·이메일·대표SNS·인스타 핸들/팔로워·X 핸들/팔로워·틱톡 핸들/팔로워·유튜브 핸들/팔로워·합계 팔로워·도도부현·시군구·등록일. (SNS 핸들 → 공식 URL 변환은 기존 신청자 엑셀 패턴 따름)
- **민감정보 추가 열**: `is_campaign_admin()` 이상일 때만 버튼 옆에 **「민감정보 포함」 체크박스** 노출 → 체크 시 전화번호·LINE 아이디·PayPal 이메일·상세주소(zip/building/address) 열 추가. campaign_manager 에게는 체크박스 자체를 숨김.
- 대량 가드: 기존 엑셀 헬퍼의 confirm()·쿨다운·동시진행 lock 패턴 준수.
- ⚠️ 위 「의심 9번」 보안 한계 명시.

### PR 분할
- **PR 1 — 주소지(다중) + 팔로워 범위 필터 + 결과 인원수 표시** (`admin/index.html`, `admin-influencers.js`, 헬퍼 공용화). DB 무변경.
- **PR 2 — 필터 결과 엑셀 내보내기 + 권한별 민감정보 열** (`admin-influencers.js`, `_excel*` 재사용). PR 1 과 같은 사이클 가능.
- UI 변경 → reverb-planner 사전 호출(본 사양서로 갈음 가능) + reverb-qa-tester Light(S5+S6). 엑셀 권한 분기는 super_admin/campaign_admin/campaign_manager 3등급 각각 확인.
- ⚠️ **마이그레이션 불필요**(클라 in-memory 필터 + 클라 엑셀 생성).

---

## 사용자 확인 필요 (개발 착수 전)
- (해소됨) 모든 정책 확정. 추가 결정 없음.

---

## 구현 결과 (개발 세션이 채울 것)

**구현일:** 2026-06-05 (PR 1만)
**관련 커밋·PR:** (PR 1 — dev 머지 후 기록)

### 초안 대비 변경 사항
- 추가된 것: 없음 (초안 PR 1 설계 그대로)
- 빠진 것: **PR 2(필터 결과 엑셀 내보내기 + 권한별 민감정보 열)는 이번 사이클 미착수** — 별도 PR로 진행 예정
- 달라진 것:
  - 결과 인원수는 사양서가 「sticky-header 표시 의무」라 했으나, 기존에 카드 헤더의 `#infTotalCount`가 이미 "N명 표시 (전체 N명)" 형식으로 존재하여 **그대로 재사용**(중복 표시 회피). 필터 활성 시 초기화 버튼이 함께 노출됨.

### 구현 중 기술 결정 사항
- **공용 헬퍼 위치**: `classifyPrefecture(pref)` + `followerValueByChannel(u, ch)`를 `admin-core.js`(다중필터 섹션, `getMultiFilterValues` 직후)에 배치. `PREFECTURE_KO`(admin-dashboard.js, 빌드상 뒤)는 `typeof` 가드 + 런타임 호출이라 안전(reviewer Warning 1: 페인 진입 시점엔 전 스크립트 로드 완료 → 실질 위험 없음 확인).
- **다중필터 재사용**: 기존 일괄발송 `bulkPrefectureMulti`와 동일하게 `syncMultiFilter`(searchable) 사용. 단 인플 필터는 PREFECTURE_KO 47개 + 「未登録」 + 「海外」 옵션을 추가(일괄발송은 서버 RPC 매칭이라 未登録/海外 미포함). value는 일본어 정식 키(`大阪府`)·`未登録`·`海外`.
- **합계 팔로워 정의**: `ig+x+tiktok+youtube_followers`, 각 NULL=0. LIPS·@cosme는 팔로워 컬럼 없어 합계 제외. 채널 선택값(`currentInfTab`) 기준이며 'all'이면 합계.
- **운영 DB prefecture distinct 점검**: 미수행(개발 세션이 운영 DB 직접 쿼리 안 함). 비정식 표기(`大阪` 등 府 누락)는 `海外`로 분류되는 한계 존재 — 사양서 「의심 3번」대로 운영 실데이터 검증 권고로 남김.
- **백로그(reviewer Warning 2)**: 추후 채널 드롭다운에 LIPS·@cosme 추가 시 `followerValueByChannel` map에 없어 합계 폴백 → 그때 함께 처리.
