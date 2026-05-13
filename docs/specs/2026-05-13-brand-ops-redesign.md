# 관리자 페이지 — 회사·브랜드·신청·캠페인 통합 관리(운영 현황) 재설계 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: 개발 착수 전 (미구현)
- **PR 분할**: 4개 (PR1: DB / PR2: 회사 관리 / PR3: 운영 현황 / PR4: 브랜드 상세)

---

## 1. 배경 및 목표

### 현재 문제
관리자 페이지에서 「회사 > 브랜드 > 신청 > 캠페인」 4단 계층을 추적·관리하기 어려움. 캠페인 관리·브랜드 서베이·대시보드가 분산되어 있어:
- 어떤 브랜드의 어떤 신청에서 어떤 캠페인이 진행 중인지 확인이 어려움
- 캠페인 모집률·결과물 제출률을 한눈에 보기 어려움
- 「추가 캠페인이 필요한지」 / 「모집기간을 늘려야 하는지」 판단 정보가 흩어져 있음

### 목표
- **운영 현황** 신규 페인 — 브랜드 카드 그리드로 진행 상태를 한 화면에 표시
- **회사** 엔티티 신설 — 1개 회사가 여러 브랜드를 보유하는 구조 지원
- **브랜드 상세 드릴다운** — 신청·캠페인 계층을 정확히 추적
- **핵심 지표** — 모집률·결과물 제출률·D-3 임박·7일 취소 추세

---

## 2. 최종 결정 사항

| 항목 | 결정 |
|---|---|
| 회사 채번 | **도입 안 함** — 사업자번호(business_no, NULL 허용)로 식별 |
| 기존 브랜드 회사 매핑 | **이름 유사도 자동 매핑 + 나머지 미분류** |
| 브랜드 카드 상세 열기 | **별도 페이지로 이동** (`/admin#brand-ops-detail?bid=xxx`) |
| 사이드바 | **운영 현황 + 회사 관리 둘 다 신규 추가** |
| 대시보드 「최근 신청」 | **대시보드에서 제거** → 운영 현황으로 이관 |
| 모집기간 연장 기능 | **이번 작업에서 제외** (추후 결정) |
| 계층 채번 v2 (B0023-A001-C002) | **이번 작업과 함께 운영 배포** |
| 핵심 지표 | 모집률 / 결과물 제출률 / D-3 임박 / 7일 취소 |

---

## 3. 사이드바 구조 (변경 후)

```
공지사항
대시보드             ← 거시 KPI/차트 전용으로 정리 (최근 신청 제거)
운영 현황            ← 신규 (실무 추적)
캠페인
  ├ 캠페인 관리
  ├ 신청 관리
  └ 결과물 관리
브랜드 서베이
  ├ 현황 (브랜드 대시보드)
  ├ 회사 관리         ← 신규
  ├ 브랜드 관리
  └ 신청 목록
회원관리
  └ 인플루언서
관리자 설정
인플루언서 화면
로그아웃
```

### 대시보드와 운영 현황 역할 분리
- **대시보드**: 회원수·캠페인수·신청수 KPI / 가입추이 차트 / 도도부현 분포 / 프로필 완성률 — 경영지표 전용
- **운영 현황**: 브랜드 카드 그리드 / 진행 캠페인 상태 / 액션 가이드 — 실무 추적 전용
- 「최근 신청」 섹션은 대시보드에서 운영 현황으로 이관

---

## 4. DB 변경

### 4-1. 회사 테이블 신설 (마이그레이션 118)

**파일**: `supabase/migrations/118_companies_master.sql`

```sql
CREATE TABLE public.companies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ko               text NOT NULL,
  name_ja               text,
  name_en               text,
  name_normalized       text UNIQUE NOT NULL,   -- lower(trim) 자동 계산
  business_no           text,                   -- 사업자등록번호 (NULL 허용)
  address               text,
  homepage_url          text,
  contact_name          text,
  contact_email         text,
  contact_phone         text,
  billing_email         text,
  billing_address       text,
  memo                  text,
  status                text NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'archived')),
  total_brands          integer NOT NULL DEFAULT 0,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

ALTER TABLE public.brands
  ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL;

CREATE INDEX brands_company_id_idx ON public.brands (company_id);

-- 행 단위 보안 정책
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
CREATE POLICY companies_select_admin ON public.companies
  FOR SELECT USING (public.is_admin());
CREATE POLICY companies_cud_admin ON public.companies
  FOR ALL USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

-- name_normalized 자동 계산 트리거
-- (lower(trim(coalesce(name_ko, ''))))
-- total_brands 집계 트리거 (brands AFTER INSERT/DELETE/UPDATE OF company_id)
```

### 4-2. 브랜드 → 회사 백필 (마이그레이션 119)

**파일**: `supabase/migrations/119_companies_backfill.sql`

**로직**:
1. brands 테이블에서 `name_normalized` 동일 그룹을 회사로 묶기
2. 각 그룹의 첫 브랜드 정보를 토대로 companies 행 생성
3. 같은 그룹의 모든 brand에 동일 `company_id` 할당
4. 매칭 애매한 경우(단일 brand만 있는 경우)는 `company_id = NULL` 유지 → 운영자가 수동 정리

```sql
-- 의사 코드
WITH grouped AS (
  SELECT lower(trim(name_ko)) AS norm, array_agg(id) AS brand_ids
  FROM brands GROUP BY lower(trim(name_ko))
  HAVING COUNT(*) >= 2  -- 2개 이상 묶인 경우만 자동 생성
)
INSERT INTO companies (name_ko, name_normalized) ...
UPDATE brands SET company_id = ... WHERE id = ANY(brand_ids);
```

### 4-3. 운영 현황 집계 원격 함수 (마이그레이션 120)

**파일**: `supabase/migrations/120_get_brand_ops_overview_rpc.sql`

`get_brand_ops_overview(p_company_id uuid DEFAULT NULL)` — 회사 필터별로 모든 브랜드의 4지표 집계:

반환 컬럼:
- `brand_id`, `brand_seq`, `brand_name_ko`, `brand_name_ja`
- `company_id`, `company_name_ko`
- `open_applications`, `active_campaigns`
- `slots_total`, `approved_total`, `recruit_rate`
- `deliverable_total`, `deliverable_approved`, `deliverable_rate`
- `d3_count` (deadline ≤ 3일, status='active'), `cancel_7d`
- `last_activity_at`, `alert_level` (normal / caution / warning / danger)

`SECURITY DEFINER + SET search_path = '' + is_admin()` 가드.

브랜드 상세용 별도 함수도 같이: `get_brand_ops_detail(p_brand_id uuid)` — 신청·캠페인 리스트 반환.

### 4-4. 계층 채번 v2 운영 배포 (088~090)

현재 dev에만 적용된 마이그레이션 088~090을 운영 DB에 적용. 채번 형식 `B0023-A001-C002` / 외부 캠페인 `B0023-C001` 사용.

**적용 순서** (PR1과 함께):
1. 운영 DB 백업
2. 088 → 089 → 090 순차 적용
3. legacy_no 매핑 검증 (`numbering_legacy_map`)
4. 카운터 시퀀스 정상 동작 확인

---

## 5. 운영 현황 페인 (신규)

**라우트**: `/admin#brand-ops`  
**라벨**: "운영 현황"

### 5-1. 상단 헤더

```
┌──────────────────────────────────────────────────────────────────────┐
│ 운영 현황                                            [엑셀] [새로고침]│
│                                                                      │
│ 회사: [전체 ▾]    상태: [● 진행중만 ○ 전체]    정렬: [경고 우선 ▾]   │
│ 검색: [_____________________________________________]                │
└──────────────────────────────────────────────────────────────────────┘
```

- 회사 드롭다운: 전체 / 회사명 / 미분류 브랜드
- 상태 토글: 진행중만(active+scheduled 캠페인 보유) / 전체
- 정렬: 경고 우선 / 진행 캠페인 수 / 최근 갱신
- 검색: 회사명·브랜드명·캠페인명·캠페인번호 통합

### 5-2. 브랜드 카드 (3~4열 반응형)

```
┌─────────────────────────────────────────────┐
│ ㈜케모 ・ B0023                              │
│ 브랜드명 한국어 / 브랜드명 日本              │
│ ─────────────────────────────────────────── │
│ 진행 신청  3건    진행 캠페인  5개          │
│ 모집률         ████████░░  78%  (32/41명)   │
│ 결과물 제출    ██████░░░░  65%  (21/32)     │
│ ⚠ D-3 임박  2개  |  ⚠ 7일 취소  3건         │
│ 마지막 활동: 2시간 전          [상세 보기 →]│
└─────────────────────────────────────────────┘
```

### 5-3. 카드 상태별 시각 강조

| 상태 | 좌측 보더 | 배지 | 조건 |
|---|---|---|---|
| 정상 | 회색 | 없음 | 아래 조건 미해당 |
| 주의 | 노랑 | 主意 | 모집률 < 50% AND deadline ≥ 7일 |
| 경고 | 주황 | 要対応 | D-3 임박 1개 이상 |
| 위험 | 빨강 + 펄스 | 緊急 | D-1 임박 OR 7일 취소 ≥ 5건 OR (모집률 < 30% AND deadline < 7일) |

### 5-4. 최근 신청 섹션 (대시보드에서 이관)

브랜드 카드 그리드 아래에 「최근 인플루언서 신청」 테이블 추가:
- 기존 대시보드의 `loadDashboardRecentApps` 함수 그대로 가져옴
- 최근 10건, 브랜드명·캠페인명·인플루언서·상태·신청일

---

## 6. 회사 관리 페인 (신규)

**라우트**: `/admin#companies`  
**라벨**: "회사 관리"

### 6-1. 리스트 화면

표 컬럼: 회사명(한)·회사명(일)·사업자번호·소속 브랜드 수·연락처·상태·작업

- 정렬: 회사명 / 브랜드 수 / 최근 수정
- 검색: 회사명 + 사업자번호
- 필터: 상태(active/archived)
- 우측 상단: 「+ 회사 추가」 버튼

### 6-2. 회사 추가/수정 모달

필드:
- 회사명 한국어 (필수)
- 회사명 일본어 (선택)
- 사업자등록번호 (선택)
- 주소 / 홈페이지
- 담당자 이름·이메일·전화
- 세금계산서 이메일·주소
- 메모

### 6-3. 브랜드 할당 모달

회사 행에서 「소속 브랜드 N개」 클릭 시 모달:
- 현재 소속 브랜드 리스트
- 「+ 브랜드 추가」 — 미분류 브랜드 또는 다른 회사 브랜드를 이 회사로 이동
- 브랜드 제거 (브랜드의 `company_id`를 NULL로)

---

## 7. 브랜드 상세 페인 (신규)

**라우트**: `/admin#brand-ops-detail?bid={brand_id}`  
**라벨**: 동적 (브랜드명)

### 7-1. 화면 구조

```
┌──────────────────────────────────────────────────────────────────┐
│  ← 운영 현황으로                                                  │
│                                                                  │
│  ㈜케모  >  브랜드명 한국어                                       │
│  [브랜드 정보 수정] [회사 변경] [캠페인 직접 등록] [엑셀 다운]    │
│ ──────────────────────────────────────────────────────────────── │
│  [요약 KPI 바 — 6칸: 진행신청/진행캠페인/모집률/제출률/D-3/취소7일]│
│ ──────────────────────────────────────────────────────────────── │
│                                                                  │
│  ▾ 신청 #1   B0023-A001  reviewer  견적전달  ¥120,000 (3캠페인) │
│      ├ 캠페인 미니카드 #1                                        │
│      ├ 캠페인 미니카드 #2                                        │
│      └ 캠페인 미니카드 #3   [+ 이 신청에 캠페인 추가]           │
│                                                                  │
│  ▾ 신청 #2   B0023-A002  seeding  최종완료  ¥80,000 (2캠페인)   │
│  ▸ 신청 #3   B0023-A003  reviewer  검수대기  (0캠페인)          │
│                                                                  │
│ ──────────────────────────────────────────────────────────────── │
│  외부 캠페인 (신청 없이 직접 등록)                                │
│      ├ B0023-C001 미니카드                                       │
│      └ B0023-C002 미니카드                                       │
└──────────────────────────────────────────────────────────────────┘
```

### 7-2. 신청 행 (아코디언)

기본은 진행 중인 신청(`status != 'done'`, `status != 'rejected'`)만 펼침. 종료된 신청은 접힘.

신청 헤더에 표시:
- 신청번호 (계층 채번)
- 폼타입 (reviewer / seeding)
- 상태 라벨
- 확정 견적 (`final_quote_krw`)
- 해당 신청에서 생성된 캠페인 개수

### 7-3. 캠페인 미니카드

```
┌────────────────────────────────────────────────────────────┐
│ B0023-A001-C002  active  [모집중]                          │
│ [상품 한국어명]                                            │
│ ─────────────────────────────────────────────────────────  │
│ 모집  ████████░░  8/10명 (80%)                             │
│ 결과물 ██████░░░░  5/8 승인 (3 검수대기, 0 반려)            │
│ ─────────────────────────────────────────────────────────  │
│ D-2 모집마감 (5/15)  |  D-12 결과물마감 (5/25)             │
│ 최근 7일: 신청 +12, 취소 1, 반려 0                          │
│ ─────────────────────────────────────────────────────────  │
│ [상세] [편집] [신청자] [복제]                              │
└────────────────────────────────────────────────────────────┘
```

빠른 액션 4개 (모집기간 연장은 이번 작업에서 제외):
- 상세: 기존 캠페인 미리보기 모달
- 편집: `/admin#edit-campaign?id=xxx`
- 신청자: `/admin#camp-applicants?cid=xxx`
- 복제: 기존 복제 모달 호출 (`source_application_id` 자동 승계)

---

## 8. 단계별 구현 계획 (PR 4개)

### PR 1 — DB 기반 (마이그레이션 4종)
**범위**:
- 088~090 계층 채번 운영 배포
- 118 회사 테이블 + brands.company_id 추가
- 119 브랜드 → 회사 백필 (이름 유사도)
- 120 `get_brand_ops_overview` / `get_brand_ops_detail` 원격 함수

**작업 절차**:
1. 운영 DB 백업
2. 개발 DB에 088~090, 118~120 순차 적용
3. SQL 검증 (회사 자동 생성·미분류 비율·집계 결과 일치)
4. PR-1 dev 머지
5. 운영 DB SQL Editor에 동일 적용
6. 운영 검증

**검증 SQL**:
```sql
-- 회사 자동 생성 결과
SELECT COUNT(*) FROM companies;
-- 미분류 브랜드 비율
SELECT COUNT(*) FILTER (WHERE company_id IS NULL) AS unassigned,
       COUNT(*) AS total FROM brands;
-- 운영 현황 집계 함수 동작
SELECT * FROM get_brand_ops_overview() LIMIT 5;
```

---

### PR 2 — 회사 관리 페인 (CRUD UI)
**의존성**: PR 1 운영 배포 완료

**범위**:
- 사이드바 「회사 관리」 메뉴 추가 (브랜드 서베이 그룹 안)
- `adminPane-companies` 페인 + 리스트 + CRUD 모달
- `dev/lib/storage.js`: `fetchCompanies`, `upsertCompany`, `assignCompanyToBrand`
- `dev/js/admin-brand.js` 또는 신규 `dev/js/admin-company.js`
- `dev/lib/shared.js`의 `PANE_REFRESHERS`에 `companies` 등록

**검증**:
- 회사 추가/수정/아카이브
- 브랜드 할당 모달 동작
- 미분류 브랜드 → 회사 할당 후 운영 현황 즉시 갱신

---

### PR 3 — 운영 현황 페인 (브랜드 카드 그리드)
**의존성**: PR 1, PR 2 완료

**범위**:
- 사이드바 「운영 현황」 메뉴 추가 (대시보드 다음)
- `adminPane-brand-ops` 페인
- 회사 드롭다운·상태 토글·정렬·검색
- 브랜드 카드 그리드 (4상태 시각 강조)
- 최근 신청 섹션 (대시보드에서 이관)
- **대시보드의 최근 신청 영역 제거**
- 카드 클릭 → `/admin#brand-ops-detail?bid=xxx` 이동 (PR4 페인)

**파일**:
- `dev/admin/index.html` — 사이드바·페인 컨테이너 추가, 대시보드 「최근 신청」 영역 제거
- `dev/js/admin.js` — 라우팅·렌더 함수 (admin.js 핫스팟 주의 — 시퀀셜 작업)
- `dev/css/admin.css` — 카드 그리드·진행바·경고 배지
- `dev/lib/storage.js` — `getBrandOpsOverview` 추가

---

### PR 4 — 브랜드 상세 페인 (드릴다운)
**의존성**: PR 3

**범위**:
- `adminPane-brand-ops-detail` 페인
- 신청 아코디언 + 캠페인 미니카드
- 빠른 액션 4종 (상세/편집/신청자/복제 — 기존 함수 재사용)
- 외부 캠페인(신청 없이 등록된 것) 별도 섹션
- URL 해시 파싱 (`?bid=xxx`) 및 새로고침 복원

**파일**:
- `dev/admin/index.html` — 페인 컨테이너 추가
- `dev/js/admin.js` — 드릴다운 렌더
- `dev/admin/app.js` — 해시 파싱·복원
- `dev/lib/storage.js` — `getBrandOpsDetail` 추가

**검증**:
- 모집률·제출률이 SQL 직접 집계와 일치
- 「+ 캠페인 추가」 시 `source_application_id` 자동 채워짐
- 외부 캠페인 섹션이 신청 없이 등록된 캠페인만 표시

---

## 9. 영향 파일 목록

### DB
- `supabase/migrations/088~090` 운영 적용 (코드 변경 없음)
- `supabase/migrations/118_companies_master.sql` (신규)
- `supabase/migrations/119_companies_backfill.sql` (신규)
- `supabase/migrations/120_brand_ops_rpc.sql` (신규)

### 클라이언트
- `dev/admin/index.html` — 사이드바·페인 컨테이너 3개 추가, 대시보드 「최근 신청」 제거
- `dev/admin/app.js` — 페인 라우팅·해시 복원
- `dev/js/admin.js` (핫스팟 ⚠) — 페인 렌더·라우팅 핸들러
- `dev/js/admin-brand.js` 또는 신규 `dev/js/admin-company.js` — 회사 CRUD
- `dev/lib/storage.js` — 6개 신규 함수 (`fetchCompanies`, `upsertCompany`, `assignCompanyToBrand`, `archiveCompany`, `getBrandOpsOverview`, `getBrandOpsDetail`)
- `dev/lib/shared.js` — `PANE_REFRESHERS`에 `companies`, `brand-ops`, `brand-ops-detail` 등록
- `dev/css/admin.css` — 카드 그리드·미니카드·진행바 스타일
- `dev/build.sh` — 신규 JS 파일 분리 시 등록 필수

---

## 10. 검증 계획

### 회귀 시나리오
1. 운영 현황 진입 → 회사 필터 → 브랜드 카드 표시 → 카드 클릭 → 별도 페이지로 상세 이동
2. 브랜드 상세에서 신청 아코디언 펼침 → 캠페인 미니카드 → 「편집」 빠른 액션 → 기존 페인 정상 동작
3. 회사 관리에서 회사 추가 → 미분류 브랜드 할당 → 운영 현황 회사 필터에 즉시 반영
4. 모집률·제출률·D-3·취소7일이 SQL 직접 집계와 일치
5. 대시보드에서 「최근 신청」 영역 제거 확인 / 운영 현황 하단에 동일 데이터 표시
6. 계층 채번 v2 (`B0023-A001-C002`) 운영 표시 + legacy 채번도 호환

### 권한 검증
- super_admin / campaign_admin / campaign_manager 각각으로 회사 CRUD 테스트
- 회사 SELECT는 모든 관리자, CUD는 campaign_admin 이상

### 1000-row cap 대응
- `get_brand_ops_overview` 는 서버 집계라 cap 회피
- 브랜드 상세에서 캠페인 1000개 초과 시 페이지네이션 (현재는 운영 데이터상 발생 불가)

---

## 11. 사용자 트레이닝 / 운영 안내

새 화면 도입 후 운영자에게 안내가 필요한 내용:
1. 「운영 현황」이 매일 첫 화면으로 권장됨
2. 미분류 브랜드는 회사 관리에서 수동 할당 필요
3. 「최근 신청」은 대시보드에서 운영 현황으로 이동
4. 캠페인 번호 표시가 `B0023-A001-C002` 로 변경됨 (legacy 번호도 병기)

---

## 12. 작업 시작 절차 (개발 세션용)

### PR 1 — DB 기반 시작
1. `git pull origin dev` — 최신 동기화
2. `ls supabase/migrations/ | tail -5` — 마이그레이션 번호 최신값 확인 (118부터 시작)
3. 회사 테이블 마이그레이션 (118) 작성 → 개발 DB 적용
4. 백필 마이그레이션 (119) 작성 → 개발 DB 적용 → 결과 검증
5. 원격 함수 마이그레이션 (120) 작성 → 개발 DB 적용 → 결과 검증
6. 운영 DB 백업 후 088~090 + 118~120 순차 적용
7. reverb-supabase-expert + reverb-reviewer 호출

### PR 2~4 진행
- 각 PR마다 dev 검증 → reverb-reviewer 호출 → dev 머지 → 사용자 확인 후 운영 배포

---

## 13. 제외 항목 (이번 작업 범위 밖)

- **모집기간 연장** 빠른 액션 — 추후 필요해지면 별도 사양
- 모집기간 변경 audit 테이블
- 외부 마켓 API 연동 (가격체크 자동화 등)
- 회사 단위 매출 집계·세금계산서 자동화 (향후)
- 회사·브랜드 로고 이미지 업로드 (필요 시 추가)
- 운영 현황 알림 푸시 (D-3 임박 자동 메일 등)

---

## 14. 리스크 / 애매한 부분

| 리스크 | 영향 | 대응 |
|---|---|---|
| 백필 휴리스틱 오매칭 | 다른 회사의 브랜드가 한 회사로 묶일 수 있음 | 2개 이상 동명만 자동, 그 외 NULL. 운영자 수동 정리 |
| 088~090 운영 배포 실패 | 채번 충돌·트리거 오작동 | 사전 백업 + 단계 적용 + 검증 SQL |
| admin.js 핫스팟 충돌 | 다른 세션과 동시 작업 시 충돌 | `.claude/rules/multi-session.md` 준수 — 시퀀셜 작업 |
| `legacy_no` ↔ 신규 채번 표시 혼동 | 운영자가 어느 번호로 검색해야 할지 헷갈림 | UI에 둘 다 표시 + 검색은 둘 다 매칭 |
| 미분류 브랜드 다수 발생 | 운영 현황에 「미분류」가 많음 | 회사 관리 페인에서 일괄 정리 도구 제공 (PR2) |
