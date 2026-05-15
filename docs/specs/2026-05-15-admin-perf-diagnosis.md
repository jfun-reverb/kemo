# 관리자 페이지 점진 성능 저하 — 엄밀 진단 사양서

**작성일:** 2026-05-15
**작성자:** 기획 세션
**측정 담당:** 개발 세션 (TBD)
**상태:** 진단 단계 (개선안 사양서는 진단 결과 후 별도 작성)

---

## 1. 배경 / 문제

운영자가 관리자 페이지를 사용하면서 「메뉴 클릭 시 페이지 로딩이 점점 느려진다」고 보고. 사용자 추가 확인:
- **패턴 B**: 며칠~몇 주 단위로 전반적으로 느려짐 (브라우저 새로고침 후에도 비슷)
- **느린 메뉴**: 거의 모든 목록 페인 (캠페인 관리·신청 관리·결과물 관리·캠페인별 신청자·인플루언서 관리·광고주 신청·관리자 계정·기준 데이터). 대시보드는 별 문제 없음

## 2. 가설 (사전 추정)

기획 세션의 사전 추정은 **데이터 누적 + 매 페인 진입 시 전건 fetch** 가 주된 원인. 근거:
- `CLAUDE.md` 규칙: PostgREST 1000-row 한계 대응으로 모든 목록 페인이 `range(from, from+999)` pagination loop로 **전건** fetch 후 클라이언트 IntersectionObserver로 점진 렌더
- 데이터가 늘어날수록 round-trip 수와 JS 메모리 점유가 선형 증가
- IntersectionObserver는 「렌더링」만 지연시키고 「fetch」 비용은 그대로

가설은 강하지만 검증 없이 큰 작업(서버 페이징 전환 = 8개 페인 PR) 들어가면 헛수고 위험. **이 사양서는 가설을 정량 검증하는 측정 절차**.

## 3. 진단 항목 (5종)

### 3-1. 데이터 양 현황 (DB 행 수)

운영 DB에서 측정. 측정 시각·결과를 §6 표에 기록.

```sql
-- 핵심 테이블 행 수
SELECT 'campaigns'         AS tbl, count(*) FROM public.campaigns
UNION ALL SELECT 'applications',     count(*) FROM public.applications
UNION ALL SELECT 'deliverables',     count(*) FROM public.deliverables
UNION ALL SELECT 'receipts',         count(*) FROM public.receipts
UNION ALL SELECT 'influencers',      count(*) FROM public.influencers
UNION ALL SELECT 'brand_applications', count(*) FROM public.brand_applications
UNION ALL SELECT 'admin_notices',    count(*) FROM public.admin_notices
UNION ALL SELECT 'lookup_values',    count(*) FROM public.lookup_values
ORDER BY tbl;

-- 시계열 증가 추이 (최근 6개월·3개월·1개월·1주)
SELECT
  count(*) FILTER (WHERE created_at >= now() - interval '7 days')   AS last_7d,
  count(*) FILTER (WHERE created_at >= now() - interval '30 days')  AS last_30d,
  count(*) FILTER (WHERE created_at >= now() - interval '90 days')  AS last_90d,
  count(*) FILTER (WHERE created_at >= now() - interval '180 days') AS last_180d,
  count(*) AS total
FROM public.applications;
-- influencers, deliverables, brand_applications 동일 패턴 반복
```

### 3-2. 페인 진입 fetch 비용 (네트워크)

Chrome DevTools → Network 탭으로 측정. **운영서버 또는 운영 데이터 가까운 환경**에서.

각 페인을 새 탭에서 처음 진입할 때:
- 발생하는 Supabase REST 요청 **수**
- 총 다운로드 **KB**
- 첫 요청 시작 ~ 마지막 요청 완료까지 **ms**
- 가장 느린 단일 요청 (URL + 응답 시간)

대상 페인 8개:
1. 대시보드 (비교 기준)
2. 캠페인 관리
3. 신청 관리
4. 결과물 관리
5. 캠페인별 신청자
6. 인플루언서 관리
7. 광고주 신청 (브랜드 서베이)
8. 관리자 계정 (의외로 느린지 확인용)

### 3-3. 클라이언트 렌더링 비용 (Performance)

Chrome DevTools → Performance 탭으로 측정. 페인 진입 클릭부터 화면 안정화까지 record.

지표:
- **TTFR** (Time To First Row): 페인 진입~첫 행 그려질 때까지 ms
- **TTI** (Time To Interactive): 페인 진입~사용자 인터랙션 가능까지 ms
- **Long Tasks**: 50ms 이상 메인 스레드 점유 작업 수·합계 시간
- **Scripting / Rendering / Painting** 비율

페인 8개 모두 측정.

### 3-4. 메모리 누수 검증 (헷갈림 방지)

Chrome DevTools → Memory 또는 Performance Monitor.

절차:
1. 새 탭에서 관리자 로그인 → Performance Monitor 열기 (JS heap, DOM Nodes, Listeners)
2. **기준값 기록** (대시보드 진입 직후 안정화 후)
3. 페인 8개를 **순차 5회 왕복** (대시보드 → 캠페인 → 신청 → ... → 광고주 → 다시 대시보드, 5회 반복)
4. 왕복 직후 값 기록
5. 30초 idle 후 다시 기록 (가비지 컬렉션 안정화)

판정:
- JS heap 증가율 < 20% → 누수 없음
- DOM Nodes 5회 왕복 후 비례 증가 → DOM 정리 안 됨 (페인 destroy 없이 hide만)
- Listeners 비례 증가 → 이벤트 리스너 누적 (페인 전환 시 unbind 안 함)

### 3-5. DB 쿼리 비용 (서버 측)

Supabase Dashboard → Database → Query Performance 또는 SQL Editor에서 EXPLAIN ANALYZE.

대상 쿼리 (storage.js의 자주 호출 함수):
- `fetchCampaigns` (관련 join 포함)
- `fetchApplications`
- `fetchDeliverables`
- `fetchInfluencers`
- `fetchBrandApplications`

각 쿼리에 대해:
- Total Cost
- Rows Returned
- Sequential Scan vs Index Scan (Sequential이면 인덱스 누락)
- Buffers (메모리/디스크 I/O)

추가:
- Database → Indexes → 미사용 인덱스·중복 인덱스 점검
- Database → Reports → Slow queries 최근 7일

## 4. 측정 환경

- **운영서버 직접 측정 가능** (REST 호출이라 운영 부하 미미, 단 동시 진단 1명만)
- 회선 throttling 끄기 (실제 사용 환경 측정)
- 캐시 영향 분리: 같은 페인을 ① 새 탭 처음 진입 ② 같은 탭 두 번째 진입 두 번 측정
- 측정 시간대: 트래픽 적은 새벽 권장 (다른 운영자 동시 사용 영향 배제)

## 5. 측정 결과 기록 (개발 세션이 채울 것)

### 5-1. 데이터 양 현황

**측정일:** 2026-05-15 (운영 DB twofagomeizrtkwlhsuv)

| 테이블 | 전체 | 최근 7일 | 최근 30일 | 최근 90일 | 최근 180일 |
|---|---:|---:|---:|---:|---:|
| campaigns | 112 | 33 | 61 | 112 | 112 |
| applications | **2,673** | 829 | 2,671 | 2,673 | 2,673 |
| deliverables | 454 | 312 | 454 | 454 | 454 |
| receipts | 0 | 0 | 0 | 0 | 0 |
| influencers | **1,386** | 109 | 1,378 | 1,386 | 1,386 |
| brand_applications | 33 | 6 | 33 | 33 | 33 |
| admin_notices | 3 | 0 | 3 | 3 | 3 |
| lookup_values | 52 | — | — | — | — |

**관측 요약 (2026-05-15 시점):**
- **applications 2,673 건** → PostgREST 1000-row cap 초과. 클라이언트 range pagination 으로 **3회 round-trip** 필요
- **influencers 1,386 건** → **2회 round-trip**
- deliverables 454·campaigns 112·brand_applications 33 → 모두 1회로 충분
- receipts 는 deliverables 통합 후 미사용 (Stage 7 deliverables 단일화)
- **최근 30일에 데이터 거의 100% 누적** — 시스템 본격 운영 시작 약 30일 전. 누적 증가율이 가파름

### 5-2. 페인 진입 fetch 비용 (운영서버 새 탭 첫 진입)

**측정일:** 2026-05-15 (Chrome DevTools Network 탭, Disable cache ON, No throttling, Fetch/XHR 필터)
**측정자:** 사용자 직접

| 페인 | 요청 수 | 데이터 (KB) | 자원 합계 (KB) | 비고 |
|---|---:|---:|---:|---|
| 대시보드 | **109** | **4,014** | **18,175** | DCL 446ms / Load 623ms / Finish 4.73s. 화면은 빨리 뜨지만 KPI·차트 비동기 fetch 누적 |
| 캠페인 관리 | 28 | 1,092 | 5,979 | campaigns 112 행 |
| 신청 관리 | 52 | **1,737** | 7,791 | applications 2,673 행 — gzip 후 1.7 MB. 3 round-trip 추정 |
| 결과물 관리 | 47 | 971 | 4,794 | deliverables 단일 호출 72.1 KB · 612ms (앞서 측정) |
| 캠페인별 신청자 | 18 | 540 | 1,796 | 캠페인 1개 안의 신청자 |
| 인플루언서 관리 | 17 | 664 | 1,829 | influencers 1,386 행 — 2 round-trip 추정 |
| **광고주 신청** | **14** | 125 | 195 | **🚨 7종 × 2회 = 14 — 중복 fetch 회귀** (모든 fetch 가 2번 발생) |
| 관리자 계정 | 6 | 4.1 | 3.1 | 정상. 관리자 행 적음 |

**중복 fetch 패턴 (광고주 신청 페인, 앞서 캡쳐):**
```
brand_applications?select=...        17.5 KB  391 ms  ← 1회
brand_application_history?select=... 2.6 KB   226 ms  ← 1회
get_brand_app_memo_summaries         1.6 KB   582 ms  ← 1회
brand_applications?select=id&status=eq.new  0.8 KB   191 ms  ← 1회
brand_applications?select=...        17.5 KB  747 ms  ← 2회 (같은 호출 반복)
brand_application_history?select=... 2.6 KB   218 ms  ← 2회
get_brand_app_memo_summaries         1.6 KB   197 ms  ← 2회
brand_applications?select=id&status=eq.new  0.8 KB   189 ms  ← 2회
```

**핵심 발견 (5-2):**
- **대시보드**: 109 requests / 4 MB. 사용자가 "별 문제 없음" 이라고 했지만 실제로는 가장 큰 비용. DCL 446ms 로 화면이 빨리 떠서 체감 안 됨 (숨은 비용)
- **광고주 신청**: 페인 진입 시 모든 fetch 가 2번 발생 — 회귀. 페이로드 자체는 작지만 round-trip 시간 두 배. 즉시 수정 가능
- **신청 관리**: 1.7 MB / 52 requests. applications 2,673 행이 가장 큰 실 작업 데이터
- **인플루언서/캠페인별 신청자/결과물 관리/캠페인 관리**: 모두 500KB~1.7MB 범위. 데이터 누적 시 선형 악화 예상

### 5-3. 클라이언트 렌더링 비용

> 🟡 **측정 대기** — 사용자가 Chrome DevTools → Performance 탭으로 직접 측정 예정.

| 페인 | TTFR (ms) | TTI (ms) | Long Tasks 수 | Long Tasks 합계 ms |
|---|---:|---:|---:|---:|
| 대시보드 | | | | |
| 캠페인 관리 | | | | |
| 신청 관리 | | | | |
| 결과물 관리 | | | | |
| 캠페인별 신청자 | | | | |
| 인플루언서 관리 | | | | |
| 광고주 신청 | | | | |
| 관리자 계정 | | | | |

### 5-4. 메모리 누수 검증

> 🟡 **측정 대기** — 사용자가 Chrome DevTools → Performance Monitor 로 직접 측정 예정.

| 시점 | JS heap (MB) | DOM Nodes | Listeners |
|---|---:|---:|---:|
| 초기 (대시보드 진입 직후) | | | |
| 5회 왕복 직후 | | | |
| 30초 idle 후 | | | |

판정 (사용자 측정 후 작성):
- 누수 여부:
- 누수 의심 페인:
- 의심 원인:

### 5-5. DB 쿼리 비용

**측정일:** 2026-05-15 (운영 DB, EXPLAIN ANALYZE BUFFERS, LIMIT 1000)

| 함수 (쿼리) | Total Cost | Rows | Scan 종류 | 인덱스 사용 | Execution Time | 행 width | 페이로드 추정 |
|---|---:|---:|---|---|---:|---:|---|
| fetchCampaigns | 67.05 | 112 | Seq Scan | ❌ (order_index 인덱스 없음) | 0.79ms | 1,832 B | ~205KB |
| fetchApplications | **552.43** | **2,673** | **Seq Scan** | ❌ (created_at 인덱스 없음) | 19.32ms | 1,967 B | **~5.3MB** (3 round-trip 합산) |
| fetchDeliverables | 68.27 | 451 | Seq Scan + Memoize Index | 부분 (campaigns_pkey 만, deliverables.updated_at 인덱스 없음) | 3.08ms | 178 B | ~80KB |
| fetchInfluencers | 152.24 | **1,386** | Seq Scan | ❌ (created_at 인덱스 없음) | 3.60ms | 630 B | ~870KB (2 round-trip) |
| fetchBrandApplications | 13.34 | 33 | Seq Scan | ❌ (created_at 인덱스 없음) | 0.25ms | 1,421 B | ~47KB |

**Slow queries Top 5 (최근 7일):** 운영 Supabase 의 `pg_stat_statements` 확장 활성 시 Database → Reports → Slow queries 에서 확인. 진단 시점 기준 추후 조회 권장 (이 사양서 측정 범위 밖).

**핵심 발견:**
- **모든 admin list 쿼리가 Seq Scan** — `created_at`/`updated_at`/`order_index` 컬럼 인덱스 누락 5종. 현재 데이터 양에선 캐시 hit + 작은 행 수라 DB 자체 영향은 작지만, 누적 시 선형 악화 (특히 applications)
- **applications 의 진짜 비용은 DB 측이 아닌 페이로드 크기**: Width 1,967 bytes × 2,673 rows ≈ 5.3MB. PostgREST 가 클라이언트로 5MB 를 3번 round-trip 으로 전송. 네트워크 전송 + JSON 파싱 + 클라이언트 정렬·필터·DOM 렌더링이 총 지연의 대부분 차지 (§5-2/§5-3 측정 필요)
- **deliverables 의 LATERAL JOIN 은 효율적** — Memoize 가 캠페인 캐시 412 hits / 39 misses 로 처리. PostgREST embed 패턴 자체는 문제 없음
- **influencers 도 1,386 rows 로 2 round-trip 필요** (PostgREST 1000-row cap). 페이로드 870KB

## 6. 진단 결론 (2026-05-15 — §5-1, §5-2, §5-5 측정 완료)

> §5-3 (Performance TTFR/TTI), §5-4 (Memory) 는 추후 측정 필요. 다만 §5-2 만으로 핵심 회귀가 명확히 드러남.

### 6-1. 가설 적중도 — **부분 적중 + 회귀 발견**

| 사전 가설 | 적중 여부 |
|---|---|
| 데이터 누적 (최근 30일에 99% 폭증) | ✅ 적중 (applications 2,671/30d, influencers 1,378/30d) |
| 전건 fetch (PostgREST 1000-row cap + range pagination) | ✅ 적중 (applications 3 round-trip, influencers 2 round-trip) |
| DB 쿼리 자체가 병목 | ❌ 빗나감 (현재 데이터 양에선 DB Execution 모두 < 20ms, 캐시 hit) |
| **(예상 외) 광고주 신청 페인 중복 fetch 회귀** | 🚨 **발견** — 모든 fetch 가 2번 발생 |
| **(예상 외) 대시보드 109 requests / 4 MB 숨은 비용** | 🚨 **발견** — 사용자 체감 안 되지만 가장 큰 페이로드 |

### 6-2. 주요 병목 (우선순위 순)

1. **🚨 광고주 신청 페인 중복 fetch (회귀)** — 페인 진입 시 brand_applications·brand_application_history·get_brand_app_memo_summaries·status=eq.new 카운트 4종이 모두 2번씩 호출됨. **즉시 수정 가능한 작은 PR**. 마이그레이션 122~126 작업 중 useEffect/IntersectionObserver/loadBrandApplications 호출 흐름이 두 번 트리거되도록 변경됐을 가능성. 코드 추적 필요
2. **🟡 대시보드 109 requests / 4 MB** — KPI 카드 8개·차트·도넛·최근 신청 5건·장기 대기 등이 각각 별도 fetch. 통합 RPC `get_admin_dashboard_summary()` 하나로 묶을 수 있음. 사용자 체감 안 되는 숨은 비용
3. **🟡 신청 관리 1.7 MB / 52 requests** — applications 2,673 행. 현재 client-side 전건 fetch + 정렬·필터. 서버 페이징 + 기본 필터(예: 최근 30일·pending 만) 도입 시 큰 개선
4. **🟢 인덱스 5종 누락** — 현재 데이터 양에선 Seq Scan 빠름 (< 20ms). 데이터 누적 (6개월 후 1만 행+) 대비 인덱스 추가 권장. 작은 마이그레이션
5. **🟢 PostgREST `SELECT *`** — 화면 표시 컬럼만 명시하면 페이로드 50% 이상 감소. 페인별 별도 작업 필요

### 6-3. 추가 발견 — 인덱스 누락 5종 (§5-5)

| 테이블 | 컬럼 | 우선순위 | 누적 시점 |
|---|---|---|---|
| applications | `created_at DESC` | 🔴 높음 | 1~3개월 |
| influencers | `created_at ASC` | 🟡 중간 | 3~6개월 |
| deliverables | `updated_at DESC` | 🟡 중간 | 3~6개월 |
| brand_applications | `created_at DESC` | 🟢 낮음 | 6개월+ |
| campaigns | `order_index NULLS LAST` | 🟢 낮음 | 12개월+ |

### 6-4. 메모리 누수 — **미측정**

§5-4 측정 결과 필요. 현재 8개 페인 모두 destroy 없이 hide/show 만 하므로 DOM/Listeners 누적 가능성 있음 (코드 검토 필요). 사용자 측정 후 결론 보강.

### 6-5. 인덱스 누락 — **있음** (§6-3 5종)

### 6-6. 페인별 진단 요약

| 페인 | 진단 |
|---|---|
| 대시보드 | 🟡 109 reqs / 4 MB — 통합 RPC 권장 |
| 캠페인 관리 | ✅ 정상 (28 reqs / 1 MB) |
| 신청 관리 | 🟡 1.7 MB / 52 reqs — 서버 페이징 권장 |
| 결과물 관리 | ✅ 정상 (47 reqs / 1 MB) |
| 캠페인별 신청자 | ✅ 정상 (18 reqs / 540 KB) |
| 인플루언서 관리 | 🟡 664 KB / 17 reqs — 누적 시 페이징 권장 |
| 광고주 신청 | 🚨 중복 fetch 회귀 — 즉시 수정 |
| 관리자 계정 | ✅ 정상 (6 reqs / 4 KB) |

## 7. 다음 단계 — 우선순위 정렬

진단 결과 기반 작업 백로그 (작은 → 큰 순):

### 7-1. 🚨 즉시 수정 (회귀 — 작은 PR)
**광고주 신청 페인 중복 fetch 제거**
- 영향: 페인 진입 시 round-trip 2배
- 원인 추적: `loadBrandApplications` 호출 흐름 + IntersectionObserver sentinel + 페어 키 summary 캐시 갱신이 두 번 트리거되는 지점 찾기
- 예상 PR 규모: 1~5 라인 수정 (`admin-brand.js` 한 곳)
- 사양서: 별도 사양서 불필요 (회귀 수정)
- **추천 다음 작업 1순위**

### 7-2. 🟢 인덱스 추가 (병행 — 작은 마이그레이션)
**5종 인덱스 추가**
- 영향: 데이터 누적 시 Seq Scan 선형 악화 방지
- 신규 마이그레이션 1개 (예: `127_admin_list_indexes.sql`)
- 운영 적용 시 `CREATE INDEX CONCURRENTLY` 권장 (테이블 잠금 최소화)
- 사양서: 작은 사양서 또는 §7-1 PR 본문에 동시 처리
- **추천 다음 작업 2순위**

### 7-3. 🟡 대시보드 통합 RPC (중간 PR)
**`get_admin_dashboard_summary()` 단일 호출**
- 영향: 대시보드 109 → ~10 requests / 4 MB → ~500 KB 추정
- 신규 RPC + 클라이언트 fetch 통합
- 사양서 필요 (KPI·차트·최근 신청 통합 구조 결정)
- 운영 부담 큼 — 기획 세션에서 별도 사양서 작성 권장

### 7-4. 🟡 신청 관리·인플루언서 서버 페이징 (큰 PR — 단계별 분할)
**8개 페인 중 큰 2개 우선 — 데이터 양 기준**
- 영향: 신청 관리 1.7 MB → 첫 페이지 100 행 ~ 200 KB
- 기본 필터 강제 (예: pending 만 표시 + 「전체 보기」 버튼)
- IntersectionObserver 무한 스크롤 또는 「더 보기」 페이지네이션
- 사양서 필요 — 페인별 UX 결정 (관리자 체감 변화 큼)
- 가장 큰 변경. 7-1, 7-2 우선 처리 후

### 7-5. 🟡 메모리 누수 측정·정리 (§5-4 측정 후 결정)
사용자 §5-4 측정 결과 받으면 분기 결정:
- 누수 있음 → 페인 destroy 로직 추가
- 누수 없음 → 다른 우선순위로 전환

### 7-6. ⏭️ PostgREST `SELECT *` → 명시 컬럼 (페인별 작은 PR)
페이로드 절반 감소 효과. 8개 페인 각각 작은 PR. 7-1 ~ 7-4 완료 후 진행

## 8. 영향 범위 / 운영 부담

- 측정은 **읽기 전용** — 운영에 영향 없음
- 단, 운영서버에서 측정할 땐 다른 관리자 동시 사용 영향 배제 위해 새벽 권장
- 측정 자체는 1~2일 소요 예상 (8 페인 × 5종 항목)

## 9. 의존성 / 사전 준비

- 측정자가 운영 관리자 계정 접근 가능 필요
- Chrome DevTools 사용 가능 환경
- Supabase Dashboard → SQL Editor 접근 (운영 프로젝트)

---

## 구현 결과 (측정 결과)

**측정일:** 2026-05-15
**측정자:** 개발 세션 (Claude Sonnet 4.6 + 사용자 직접 Chrome DevTools)
**측정 환경:** 운영 DB (`twofagomeizrtkwlhsuv`) + 운영서버 (globalreverb.com/admin/)

### 측정 결과 요약
- **데이터 양 (§5-1)**: applications 2,673 / influencers 1,386 / deliverables 454 / campaigns 112 / brand_applications 33. 최근 30일에 99% 누적
- **페인별 fetch (§5-2)**: 8 페인 측정 완료. 대시보드 109 reqs / 4 MB (가장 큼) · 광고주 신청 14 reqs (중복 fetch 회귀 발견) · 신청 관리 1.7 MB
- **DB 쿼리 (§5-5)**: 모든 admin list 가 Seq Scan, Execution Time 모두 < 20ms (캐시 hit). 인덱스 5종 누락
- **🚨 핵심 발견: 광고주 신청 페인 중복 fetch 회귀** — 모든 fetch 가 2번 발생. 즉시 수정 필요

### 가설 대비 발견
- §2 가설 「데이터 누적 + 매 페인 진입 시 전건 fetch」 → **부분 적중 + 회귀 발견**
  - ✅ 데이터 누적·전건 fetch 확인
  - ❌ DB 자체 비용은 작음 (페이로드/네트워크가 큼)
  - 🚨 **예상 외 발견**: 광고주 신청 중복 fetch 회귀 (마이그레이션 122~126 작업 흔적 추정)
  - 🚨 **예상 외 발견**: 대시보드 109 requests 숨은 비용 (체감 안 됨)

### 다음 작업 우선순위 (§7)
1. 🚨 광고주 신청 중복 fetch 즉시 수정 (작은 PR)
2. 🟢 인덱스 5종 추가 마이그레이션 (작은 PR)
3. 🟡 대시보드 통합 RPC (사양서 필요)
4. 🟡 서버 페이징 전환 (사양서 필요)

### 측정 미완료 (사용자 직접)
- §5-3 Performance (TTFR/TTI/Long Tasks) — 시간 여유 있을 때 측정
- §5-4 Memory (5회 왕복 + 30초 idle) — 누수 의심 검증

§6 결론은 §5-3/5-4 결과 없이도 핵심 회귀 발견에 영향 없음. 추후 측정 결과 받으면 §6-4 메모리 결론만 갱신.
