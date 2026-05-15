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

> 🟡 **측정 대기** — 사용자가 Chrome DevTools → Network 탭으로 직접 측정 예정. 측정 결과를 메인 Claude 에게 전달하면 표 채움.

| 페인 | 요청 수 | 총 KB | 총 ms | 가장 느린 요청 (URL · ms) |
|---|---:|---:|---:|---|
| 대시보드 | | | | |
| 캠페인 관리 | | | | |
| 신청 관리 | | | | |
| 결과물 관리 | | | | |
| 캠페인별 신청자 | | | | |
| 인플루언서 관리 | | | | |
| 광고주 신청 | | | | |
| 관리자 계정 | | | | |

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

## 6. 진단 결론 (2026-05-15 1차 — §5-1, §5-5 만으로 추정)

> ⚠️ §5-2/§5-3/§5-4 (브라우저 측정) 결과 받기 전 잠정 결론. 브라우저 측정 후 보강 필요.

### 6-1. 가설 적중도 — **부분 적중**

| 사전 가설 | 적중 여부 |
|---|---|
| 데이터 누적 (최근 30일에 99% 폭증) | ✅ 적중 (applications 2,671/30d, influencers 1,378/30d) |
| 전건 fetch (PostgREST 1000-row cap + range pagination) | ✅ 적중 (applications 3 round-trip, influencers 2 round-trip) |
| DB 쿼리 자체가 병목 | ❌ 빗나감 (현재 데이터 양에선 DB Execution 모두 < 20ms, 캐시 hit) |

### 6-2. 주요 병목 (1차 추정)

1. **applications 페이로드 5.3MB** — Width 1,967 bytes × 2,673 rows. PostgREST `SELECT *` + 3 round-trip 으로 네트워크 전송. 클라이언트 JSON 파싱 + 정렬 + DOM 렌더링이 누적 지연의 주범 추정
2. **influencers 페이로드 870KB** — 2 round-trip
3. **DB Seq Scan 5종** — 누적 시 선형 악화. 현재는 작지만 6개월 후 applications 가 1만 행 넘으면 본격적 부담
4. **PostgREST `SELECT *` 정책** — 화면에 필요한 컬럼만 가져오면 페이로드 50% 이상 감소 가능 (사양서 §3-1 width 1,967 → 화면에 실제 표시되는 컬럼은 ~30개 중 10개 미만)

### 6-3. 추가 발견 — 인덱스 누락 5종

EXPLAIN ANALYZE 결과 모든 admin list 쿼리가 Seq Scan. 다음 인덱스 추가 권장 (데이터 누적 대비):

| 테이블 | 컬럼 | 우선순위 |
|---|---|---|
| applications | `created_at DESC` | 🔴 높음 (2,673 → 누적 빠름) |
| influencers | `created_at ASC` | 🟡 중간 (1,386) |
| deliverables | `updated_at DESC` | 🟡 중간 (454) |
| brand_applications | `created_at DESC` | 🟢 낮음 (33) |
| campaigns | `order_index NULLS LAST` | 🟢 낮음 (112, 정렬용 ↔ id PK 대체 가능) |

### 6-4. 메모리 누수 — 미측정

§5-4 측정 후 결론. 사양서 §3-4 절차 (5회 왕복 → JS heap·DOM Nodes·Listeners) 결과 필요.

### 6-5. 인덱스 누락 — **있음** (§6-3 5종)

## 7. 다음 단계 (진단 결과에 따라 분기)

진단 결과를 본 뒤 기획 세션이 다음 사양서를 작성:

| 진단 결과 | 다음 사양서 |
|---|---|
| 전건 fetch가 핵심 병목 + 데이터 누적 확실 | **서버 페이징 전환** (8개 페인, 단계별 PR 분할) |
| 일부 페인만 심각 + 기본 필터로 해결 가능 | **기본 필터 강제 + 「더 보기」 패턴** (작은 PR 1~2건) |
| 메모리 누수도 함께 발견 | **페인 destroy 로직 추가** (별도 PR) |
| 인덱스 누락 발견 | **DB 인덱스 추가 마이그레이션** (병행) |
| 가설 빗나감 (예: 특정 라이브러리·이미지·외부 호출 병목) | 신규 가설로 재분석 |

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

**측정일:** 2026-05-15 (1차 — §5-1, §5-5 만)
**측정자:** 개발 세션 (Claude Sonnet 4.6 + 사용자)
**측정 환경:** 운영 DB (`twofagomeizrtkwlhsuv`)

### 측정 결과 요약 (1차)
- 데이터 양: applications 2,673 / influencers 1,386 / deliverables 454 / campaigns 112 / brand_applications 33. 최근 30일에 99% 누적
- DB 쿼리: 모든 admin list 가 Seq Scan, 다만 현재 데이터 양에선 Execution Time 모두 < 20ms (캐시 hit)
- **진짜 병목 추정: applications 5.3MB 페이로드** + PostgREST 3 round-trip + 클라이언트 JSON 파싱·렌더링
- 인덱스 누락 5종 발견 (누적 시 선형 악화 대비 필요)

### 가설 대비 발견
- §2 가설 「데이터 누적 + 매 페인 진입 시 전건 fetch」 → **부분 적중**: 데이터 누적·전건 fetch 는 확인. 단 DB 자체가 아닌 **페이로드 크기 + 클라이언트 측 비용** 이 더 큰 비중으로 추정

### 측정 대기 (사용자 직접)
- §5-2 페인별 Network: 사용자 Chrome DevTools 측정 후 결과 전달
- §5-3 클라이언트 Performance (TTFR/TTI/Long Tasks)
- §5-4 메모리 누수 (5회 왕복 + 30초 idle)
- 위 3종 받으면 §6 결론 보강 + §7 분기 확정
