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
| 「외부 캠페인」 용어 | **「직접 등록 캠페인」으로 변경** |
| 직접 등록 캠페인 → 신청 연결 시 번호 | **새 번호 자동 발급** — 옛 번호는 `legacy_no` 컬럼에 보존 |
| 브랜드 상세에 「신청에 연결」 빠른 액션 | **추가** — 모달에서 이 브랜드의 신청 선택 |
| 신청 연결 해제 (다시 직접 등록 캠페인으로) | **가능** — 동일하게 새 번호 자동 발급 |

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

현재 dev에만 적용된 마이그레이션 088~090을 운영 DB에 적용. 채번 형식 `B0023-A001-C002` / 직접 등록 캠페인 `B0023-C001` 사용.

**적용 순서** (PR1과 함께):
1. 운영 DB 백업
2. 088 → 089 → 090 순차 적용
3. legacy_no 매핑 검증 (`numbering_legacy_map`)
4. 카운터 시퀀스 정상 동작 확인

### 4-5. 캠페인 신청 연결/해제 원격 함수 (마이그레이션 121)

**파일**: `supabase/migrations/121_link_unlink_campaign_application.sql`

직접 등록 캠페인을 신청에 연결하거나 그 반대로 해제할 때 호출하는 원격 함수 2종. 단일 트랜잭션에서 `source_application_id` 변경 + 새 번호 발급 + 옛 번호 `legacy_no` 보존을 한꺼번에 처리.

#### `link_campaign_to_application(p_campaign_id uuid, p_application_id uuid)`
- 가드: `is_campaign_admin()` 이상 + 캠페인이 같은 브랜드의 신청인지 검증
- 동작:
  1. 캠페인 현재 `campaign_no`를 `legacy_no` 컬럼에 추가 (`legacy_no` 이미 값 있으면 콤마 누적)
  2. `source_application_id` = `p_application_id`
  3. `application_campaign_counter`에서 새 시퀀스 발급
  4. `campaign_no` 재설정 (`B{brand_seq}-A{app_seq}-C{new_camp_seq}`)
  5. `numbering_legacy_map`에 매핑 추가
- 반환: `{campaign_id, old_no, new_no, application_no}`

#### `unlink_campaign_from_application(p_campaign_id uuid)`
- 가드: `is_campaign_admin()` 이상
- 동작:
  1. 캠페인 현재 `campaign_no`를 `legacy_no`에 누적 보존
  2. `source_application_id` = NULL
  3. `brand_external_campaign_counter`에서 새 시퀀스 발급
  4. `campaign_no` 재설정 (`B{brand_seq}-C{new_ext_seq}`)
- 반환: `{campaign_id, old_no, new_no}`

#### 동시 편집 충돌 대응
- 캠페인 행 `version` 컬럼 낙관적 락 (기존 패턴 동일)
- 카운터 advisory lock으로 직렬화 (088 패턴 동일)

#### 후속 처리
- 캠페인 번호 변경 시 운영자 알림 토스트 ("B0026-C001 → B0026-A002-C001 로 재발급됨, 옛 번호는 검색에서 매칭됨")
- 이력 audit 테이블 기록 (선택, 추후 별도 사양에서 결정)

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
**위치**: 사이드바 「브랜드 서베이」 그룹 안, 「현황 대시보드」 다음·「신청 목록」 위

### 6-0. PR 2 확정 결정사항 (2026-05-18 기획 세션)

운영 DB 점검(2026-05-18): 자동 생성 회사 0건 / 미분류 브랜드 25/25 (전체). 운영자가 회사를 직접 만들고 브랜드를 일괄 분류해야 하는 상황이라 일괄 할당 흐름이 핵심.

| 분기점 | 결정 | 근거 |
|---|---|---|
| 파일 구조 | **신규 `dev/js/admin-company.js` 분리** | admin.js 9,464줄 핫스팟 회피, admin-split 정책 정합, 회사 도메인 독립 응집도 ↑ |
| 브랜드 할당 흐름 | **회사 모달 안 미분류 브랜드 다중 체크박스** | 25건 일괄 처리 효율 + 사양서 §6-3 기본안 유지 |
| 회사 추가 모달 자동 채우기 | **없음 (빈 폼)** | 회사:신청 1:1 매칭 보장 안 됨 → 잘못 채워질 위험 |
| 아카이브 동작 | **`status='archived'` 상태만 변경, brands.company_id 유지** | 데이터 무결성 + 복구 용이 |
| 회사 삭제 (hard delete) | **소속 브랜드 0건일 때만 허용** | 실수 방지 + 정리 자유도 양립. 외래 키 `ON DELETE SET NULL` 안전망도 있음 |
| `PANE_REFRESHERS` 등록 | **PR 2 는 `companies` 1개만** | brand-ops / brand-ops-detail 은 각 담당 PR 에서 추가 (예약 등록은 죽은 코드 유발) |
| 「브랜드 관리」 메뉴 | **PR 2 범위 제외, 별도 PR** | 사양서 §3 에 라벨만 등장. 필드·모달·역할 미정의 → 사양 보강 후 별도 PR |

### 6-1. 리스트 화면

표 컬럼 (좌→우): 회사명(한국어)·회사명(일본어)·사업자등록번호·**소속 브랜드 수**·담당자·이메일·상태·작업

- **정렬**: 회사명 / 브랜드 수(많은 순) / 최근 수정
- **검색**: 회사명(한국어·일본어) + 사업자등록번호 통합 매칭
- **필터**: 상태(전체 / active / archived) — 기본값 active
- **우측 상단 액션**:
  - 「+ 회사 추가」 버튼 (campaign_admin 이상)
  - 「미분류 브랜드 N개 →」 인디케이터 (회사 미할당 brands 개수, 클릭 시 미분류 브랜드 목록 모달)

표 행 액션 (작업 셀):
- 「편집」 → 회사 추가/수정 모달 재사용
- 「소속 브랜드 N개」 → 브랜드 할당 모달
- 「⋯ 더보기」 → 아카이브 / 활성화 복귀 / 삭제 (조건부)

### 6-2. 회사 추가/수정 모달

기존 브랜드 서베이 신청 등록 모달과 동일한 z-index·디자인 패턴(`nbaModal` 참고).

**필드** (자동 채우기 없음, 모두 수동 입력):

| 라벨 | 컬럼 | 필수 | 비고 |
|---|---|---|---|
| 회사명 (한국어) | `name_ko` | ✓ | 트리거가 `name_normalized` 자동 계산 |
| 회사명 (일본어) | `name_ja` | – | |
| 회사명 (영어) | `name_en` | – | 사양서 신규 추가 |
| 사업자등록번호 | `business_no` | – | NULL 허용. 형식 검증 없음 (한·일 다름) |
| 주소 | `address` | – | textarea 2줄 |
| 홈페이지 | `homepage_url` | – | http/https 스킴 검증 (`normalizeBrandUrlInput` 헬퍼 재사용) |
| 담당자 이름 | `contact_name` | – | |
| 담당자 이메일 | `contact_email` | – | RFC 5322 간이 검증 |
| 담당자 전화 | `contact_phone` | – | `formatPhoneDisplay` 헬퍼 재사용 (KR/JP 정규화) |
| 세금계산서 이메일 | `billing_email` | – | |
| 세금계산서 주소 | `billing_address` | – | textarea 2줄 |
| 메모 | `memo` | – | textarea 3줄 |

저장 시:
- `name_ko` 중복(`name_normalized` UNIQUE 충돌, 에러코드 23505) 검사 → 친화적 에러 메시지 (`"이미 등록된 회사명입니다"`)
- 성공 후 모달 닫고 `refreshPane('companies')` 호출
- 토스트: "회사를 추가했습니다" / "회사 정보를 수정했습니다"

### 6-3. 브랜드 할당 모달

회사 행 「소속 브랜드 N개」 클릭 시 모달 (다중 선택 일괄 처리).

```
┌──────────────────────────────────────────────────────────┐
│ ㈜케모 — 소속 브랜드 관리                       [✕ 닫기]  │
│ ────────────────────────────────────────────────────────  │
│ [현재 소속 브랜드 (3개)]                                  │
│   ✓ 브랜드 A (한국어) / ブランド A (일본어)   [제거]      │
│   ✓ 브랜드 B / ブランド B                     [제거]      │
│   ✓ 브랜드 C / ブランド C                     [제거]      │
│                                                          │
│ [+ 브랜드 추가]                                          │
│   검색: [_____________________]   필터: ○미분류  ●전체    │
│   □ 브랜드 D / ブランド D    (미분류)                    │
│   □ 브랜드 E / ブランド E    (㈜한국 소속)               │
│   □ 브랜드 F / ブランド F    (미분류)                    │
│   ...                                                    │
│                                                          │
│ [취소]                              [선택 N개 일괄 할당]  │
└──────────────────────────────────────────────────────────┘
```

- 「현재 소속 브랜드」 행의 「제거」: 단건 즉시 `company_id = NULL` (확인 모달 없음 — 운영자 학습 부담 최소화)
- 「+ 브랜드 추가」: 다중 체크박스 선택 후 「선택 N개 일괄 할당」 누르면 한 번에 `company_id` 일괄 변경
- 필터 「미분류만 / 전체」: 미분류 브랜드 우선 노출 (25건 일괄 처리 시나리오 대응). 기본값 「미분류」
- 검색: 브랜드명(한국어·일본어) 매칭
- 다른 회사 소속 브랜드를 이동시키면 옛 회사의 `total_brands` 도 자동 갱신 (트리거)

### 6-4. 아카이브 / 삭제 / 활성화 복귀

- **아카이브**: 「⋯ 더보기 → 아카이브」 → 확인 모달 → `status='archived'` 변경. `brands.company_id` 는 그대로 (브랜드는 아카이브된 회사 소속으로 유지)
- **활성화 복귀**: archived 상태에서 「⋯ 더보기 → 활성화 복귀」 → `status='active'` 변경
- **삭제 (hard delete)**:
  - 소속 브랜드 0건일 때만 「⋯ 더보기」에 노출
  - 확인 모달: "이 회사를 완전히 삭제합니다. 복구할 수 없습니다."
  - `DELETE FROM companies WHERE id=...` (외래 키 `ON DELETE SET NULL` 이지만 0건이라 영향 없음)
  - 소속 브랜드 1개 이상이면 메뉴 자체에 노출 안 함 (또는 disabled + 툴팁 "소속 브랜드를 먼저 분리하세요")

### 6-5. 신규 storage.js 함수 5종

`dev/lib/storage.js` 에 추가 (CUD 함수는 `retryWithRefresh` 래퍼 사용):

```js
async function fetchCompanies({ status, search } = {}) { ... }  // 리스트 + 필터·검색
async function upsertCompany(payload) { ... }                   // 추가/수정 통합
async function assignBrandsToCompany(companyId, brandIds) { ... } // 다중 할당 (브랜드 1건 제거 시 companyId=null + brandIds=[brandId])
async function archiveCompany(companyId, archive) { ... }       // archive=true 면 archived, false 면 active 복귀
async function deleteCompanyHard(companyId) { ... }             // 소속 0건 검증 후 hard delete
```

참고: `assignBrandsToCompany(null, [brandId])` 한 형태로 「제거」 동작도 합치는 게 함수 1개로 충분하지만, 가독성을 위해 위 시그니처 유지.

### 6-6. PANE_REFRESHERS 등록

`dev/lib/shared.js` 의 `PANE_REFRESHERS` 객체에 한 줄 추가:

```js
'companies': () => loadCompanies(),
```

회사 관련 모달 저장 함수는 끝에서 모두 `await refreshPane('companies')` 호출 (사양서 `.claude/rules/quality.md` 「관리자 모달 페인 갱신」 규칙 준수).

### 6-7. 권한 검증

- SELECT: 모든 관리자 (`is_admin()` — campaign_manager 포함)
- INSERT/UPDATE/DELETE: `is_campaign_admin()` 이상
- UI 가드: campaign_manager 로그인 시 「+ 회사 추가」 / 「편집」 / 「⋯ 더보기」 모두 disabled 또는 hidden

### 6-8. 검증 시나리오 (개발 세션용)

1. 회사 1건 추가 → 리스트에 즉시 노출, 소속 브랜드 0건 표시
2. 브랜드 할당 모달에서 미분류 브랜드 다중 선택 → 일괄 할당 → 회사 행 「소속 브랜드 N개」 즉시 갱신 + 미분류 인디케이터 카운트 감소
3. 같은 회사명(한국어) 중복 추가 → 에러코드 23505 → 친화적 메시지 노출
4. 회사 편집 → 저장 → 리스트 갱신
5. 소속 브랜드 1개 회사 → 「⋯ 더보기」 에 「삭제」 미노출. 브랜드 제거 후 다시 열면 「삭제」 노출
6. 회사 아카이브 → 기본 필터(active)에서 사라짐, archived 필터에서 보임. 소속 브랜드는 그대로 유지
7. 권한: campaign_manager 로그인 시 CUD 모두 비활성화 + SELECT 만 가능
8. 다른 회사 소속 브랜드를 이동 → 옛 회사의 `total_brands` 자동 감소 (트리거 작동 검증)

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
│  직접 등록 캠페인 (신청 없이 직접 등록)                                │
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

빠른 액션 (모집기간 연장은 이번 작업에서 제외):
- 상세: 기존 캠페인 미리보기 모달
- 편집: `/admin#edit-campaign?id=xxx`
- 신청자: `/admin#camp-applicants?cid=xxx`
- 복제: 기존 복제 모달 호출 (`source_application_id` 자동 승계)
- **신청에 연결** (직접 등록 캠페인에만 표시) — 모달에서 이 브랜드의 신청 목록 중 하나 선택 → `link_campaign_to_application` RPC 호출
- **신청 연결 해제** (신청에 연결된 캠페인에만 표시) — 확인 모달 → `unlink_campaign_from_application` RPC 호출

### 7-4. 신청 연결 모달 (신규)

```
┌─────────────────────────────────────────────────┐
│  신청에 연결                            [✕ 닫기] │
│ ──────────────────────────────────────────────  │
│  현재 캠페인: B0026-C001 [캠페인 제목]           │
│  브랜드: [브랜드 한국어]                         │
│                                                 │
│  연결할 신청 선택:                              │
│  ○ B0026-A001  reviewer  최종완료  ¥120,000    │
│  ● B0026-A002  reviewer  견적전달  ¥80,000     │
│  ○ B0026-A003  seeding   검수대기  -           │
│                                                 │
│  ⚠ 캠페인 번호가 B0026-C001 → B0026-A002-C001  │
│     로 재발급됩니다. 옛 번호는 검색에서 매칭됩니다.│
│                                                 │
│  [취소] [연결]                                  │
└─────────────────────────────────────────────────┘
```

- 신청 목록은 이 브랜드(`brand_id` 일치)의 신청만 표시
- 상태 무관하게 모두 표시 (rejected 신청도 운영자가 의도적으로 연결할 수 있음)
- 확인 클릭 시 토스트로 새 번호 안내 + 미니카드 즉시 재렌더

### 7-5. 신청 연결 해제 확인 모달 (신규)

```
┌─────────────────────────────────────────────────┐
│  신청 연결 해제                          [✕]    │
│ ──────────────────────────────────────────────  │
│  캠페인: B0026-A002-C001 [캠페인 제목]          │
│  현재 신청: B0026-A002                          │
│                                                 │
│  연결 해제 시 직접 등록 캠페인으로 되돌아갑니다.  │
│  캠페인 번호: B0026-A002-C001 → B0026-C00X      │
│  옛 번호는 검색에서 계속 매칭됩니다.             │
│                                                 │
│  [취소] [연결 해제]                             │
└─────────────────────────────────────────────────┘
```

### 7-6. 캠페인 편집 화면의 신청 드롭다운 동작

기존 캠페인 편집 화면(스크린샷 화면)의 「신청」 드롭다운은 그대로 유지하되, **변경 후 저장 시 확인 모달 표시** + 동일 RPC(`link_campaign_to_application` 또는 `unlink_campaign_from_application`) 호출. 두 경로(브랜드 상세 빠른 액션 / 캠페인 편집 화면) 모두 동일한 로직을 거치게 통일.

---

## 8. 단계별 구현 계획 (PR 4개)

### PR 1 — DB 기반 (마이그레이션 5종)
**범위**:
- 088~090 계층 채번 운영 배포
- 118 회사 테이블 + brands.company_id 추가
- 119 브랜드 → 회사 백필 (이름 유사도)
- 120 `get_brand_ops_overview` / `get_brand_ops_detail` 원격 함수
- 121 `link_campaign_to_application` / `unlink_campaign_from_application` 원격 함수

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

### PR 4 — 브랜드 상세 페인 (드릴다운) + 신청 연결/해제
**의존성**: PR 3

**범위**:
- `adminPane-brand-ops-detail` 페인
- 신청 아코디언 + 캠페인 미니카드
- 빠른 액션 6종:
  - 상세/편집/신청자/복제 (기존 함수 재사용)
  - 신청에 연결 (직접 등록 캠페인 한정) — 신규 모달
  - 신청 연결 해제 (신청 연결된 캠페인 한정) — 신규 확인 모달
- 직접 등록 캠페인(신청 없이 등록된 것) 별도 섹션
- 캠페인 편집 화면의 신청 드롭다운도 동일 RPC 사용으로 통일
- URL 해시 파싱 (`?bid=xxx`) 및 새로고침 복원

**파일**:
- `dev/admin/index.html` — 페인 컨테이너 추가, 신청 연결 모달/연결 해제 모달 추가
- `dev/js/admin.js` — 드릴다운 렌더, 모달 핸들러
- `dev/js/admin-brand.js` (또는 신규 admin-ops.js) — 신청에 연결/연결 해제 함수
- `dev/admin/app.js` — 해시 파싱·복원
- `dev/lib/storage.js` — `getBrandOpsDetail`, `linkCampaignToApplication`, `unlinkCampaignFromApplication` 추가

**검증**:
- 모집률·제출률이 SQL 직접 집계와 일치
- 「+ 캠페인 추가」 시 `source_application_id` 자동 채워짐
- 직접 등록 캠페인 섹션이 신청 없이 등록된 캠페인만 표시
- 신청에 연결 후 캠페인 번호가 `B0026-C001 → B0026-A002-C001` 로 재발급되는지
- 옛 번호로 검색해도 매칭되는지 (`legacy_no`)
- 연결 해제 후 직접 등록 캠페인 섹션으로 이동
- 캠페인 편집 화면 「신청」 드롭다운 변경 → 저장 시 확인 모달 → 동일 동작

---

## 9. 영향 파일 목록

### DB
- `supabase/migrations/088~090` 운영 적용 (코드 변경 없음)
- `supabase/migrations/118_companies_master.sql` (신규)
- `supabase/migrations/119_companies_backfill.sql` (신규)
- `supabase/migrations/120_brand_ops_rpc.sql` (신규)
- `supabase/migrations/121_link_unlink_campaign_application.sql` (신규)

### 클라이언트
- `dev/admin/index.html` — 사이드바·페인 컨테이너 3개 추가, 대시보드 「최근 신청」 제거
- `dev/admin/app.js` — 페인 라우팅·해시 복원
- `dev/js/admin.js` (핫스팟 ⚠) — 페인 렌더·라우팅 핸들러
- `dev/js/admin-brand.js` 또는 신규 `dev/js/admin-company.js` — 회사 CRUD
- `dev/lib/storage.js` — 8개 신규 함수 (`fetchCompanies`, `upsertCompany`, `assignCompanyToBrand`, `archiveCompany`, `getBrandOpsOverview`, `getBrandOpsDetail`, `linkCampaignToApplication`, `unlinkCampaignFromApplication`)
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
7. 직접 등록 캠페인 → 신청에 연결: 번호 재발급 + 옛 번호 `legacy_no` 보존 + 검색 호환
8. 신청 연결 해제: 직접 등록 캠페인 섹션으로 이동 + 번호 재발급
9. 캠페인 편집 화면 「신청」 드롭다운 변경 시 저장 확인 모달 + 동일 번호 재발급 동작
10. 옛 캠페인 번호로 검색 시 신규 번호도 함께 매칭 (`legacy_no` 활용)

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

---

## 15. 구현 결과 — PR 1 (DB 기반)

**구현일:** 2026-05-13 ~ 2026-05-14
**관련 커밋:**
- 4469947 feat(db): companies master table + brands.company_id (migration 118)
- 6ee89aa feat(db): companies backfill + brand ops RPCs (migrations 119, 120)
- 3c95972 feat(db): link/unlink campaign-application RPCs (migration 121)
- ab2e4bc fix(db): one-off patch for 089 backfill missing 32 campaigns (운영 적용 중 089 부분 적용 흔적 발견하여 32건 보정)
- a0b274b fix(db): update 084 record_caution_history signature 11→15 (운영 적용 중 109 시그니처 확장 영향 발견)
- 1bf9c16 Merge pull request #203 from jfun-reverb/dev (운영 배포 머지)

### 초안 대비 변경 사항

#### 추가된 것
- 「외부 캠페인」 용어를 **「직접 등록 캠페인」으로 변경** (사양서 §2 의사결정표 기록 완료, §4-5 / §7-3 / §7-4 본문 일괄 적용)
- 마이그레이션 121 본문에 내부 헬퍼 함수 `_accumulate_legacy_no(text, text)` 추가 — link/unlink 두 함수에서 공통으로 호출하는 `legacy_no` 콤마 누적 + 중복 방어 로직 추출. supabase-expert 검증 단계에서 "각 함수 30줄 이상 중복 우려"로 분리 결정

#### 빠진 것
- 사양서 §4-5 「동시 편집 충돌 대응」에 명시했던 **「캠페인 행 `version` 컬럼 낙관적 락」** 도입 보류 — `campaigns` 테이블에 `version` 컬럼이 존재하지 않아 신규 추가가 필요했으나, `pg_advisory_xact_lock(campaign_id)` + `pg_advisory_xact_lock(application_id 또는 brand_id)` 2단 잠금만으로 동시 link/unlink 충돌이 직렬화됨이 supabase-expert 검증에서 확인되어 version 컬럼 추가 불필요로 판단. 사양서 본문의 "version 낙관적 락" 표현은 기획 단계 오기입으로 처리

#### 달라진 것
- 멱등성 동작: 사양서에는 「반환: `{campaign_id, old_no, new_no, application_no}`」 4필드만 명시했으나, 실제 반환에 **`unchanged` 불리언 필드 추가**. 클라이언트가 "이미 연결된 상태입니다" 안내 토스트와 "재발급 완료" 토스트를 구분하기 위함
- `numbering_legacy_map` UPSERT 정책 구체화: 사양서에는 "매핑 추가"라 했으나, PK가 `(entity_type, entity_id)`이므로 ON CONFLICT 시 **`new_no`와 `migrated_at`만 갱신**하고 `legacy_no` 컬럼은 최초 이주 시점 원래 번호(예: `CAMP-2026-0001`)로 고정. `campaigns.legacy_no` 컬럼은 "변경 이력 콤마 누적", `numbering_legacy_map.legacy_no`는 "최초 이주값 고정"으로 역할 분리

### 구현 중 기술 결정 사항

#### 1. advisory lock 순서 고정 (데드락 회피)
- link: `pg_advisory_xact_lock(campaign_id) → pg_advisory_xact_lock(application_id)` 순서
- unlink: `pg_advisory_xact_lock(campaign_id) → pg_advisory_xact_lock(brand_id)` 순서
- 두 함수 모두 첫 번째 잠금이 `campaign_id` 로 동일하므로 같은 캠페인에 동시 link+unlink 호출이 들어와도 데드락 없이 직렬화

#### 2. legacy_no 콤마 누적 중복 방어
- `_accumulate_legacy_no` 헬퍼가 `string_to_array(p_existing, ',')` 후 `ANY()` 매칭으로 중복 추가 차단
- 같은 캠페인이 link → unlink → link 반복돼도 한 번만 누적되므로 콤마 누적이 무한 길어지지 않음
- 부분 문자열 일치 오탐 방어: `'A,B,C'` 안에 `'B'` 추가 시 단순 `position()` 이면 매칭되어 누적 안 됐을 위험이 있었지만, 배열 분리 방식으로 정확히 토큰 단위 매칭

#### 3. 권한 — authenticated GRANT + is_campaign_admin() 가드
- 088~090 트리거 함수는 `REVOKE ALL FROM authenticated` (클라이언트 직접 호출 의미 없음) 패턴
- 121의 link/unlink는 PostgREST `.rpc()` 호출 대상이므로 **`GRANT EXECUTE TO authenticated`** 적용
- 인플루언서(authenticated 이지만 admins 미등록) 호출은 함수 본문 첫 줄 `is_campaign_admin()` 가드에서 42501 반환
- 120 (`get_brand_ops_overview` / `get_brand_ops_detail`) 패턴과 동일

#### 4. brand_id NULL legacy 캠페인 처리
- 088~090 적용 이전에 생성된 레거시 캠페인(`brand_id IS NULL`)은 link/unlink 모두 `RAISE EXCEPTION` 으로 차단(에러코드 22023)
- 이유: `brand_seq` 를 알 수 없어 새 번호 발급 불가. 운영자가 캠페인에 brand 를 먼저 지정해야 함
- 사양서 §7-6 "브랜드 미연결 캠페인" 케이스로 별도 안내 필요

#### 5. SQL Editor 검증 환경
- 개발 DB SQL Editor 는 `auth.uid()` 가 NULL이라 `is_campaign_admin()` false 반환 → 직접 호출이 불가능
- 검증용 패턴: `BEGIN; SELECT set_config('request.jwt.claims', json_build_object('sub', <super_admin_auth_id>)::text, true); ... ROLLBACK;` 로 트랜잭션 한정 JWT 클레임 주입
- DO $$ ... $$ 블록 내 마지막 `RAISE EXCEPTION 'RESULT >> ...'` 트릭으로 결과를 에러 메시지에 담아 보여주면서 자동 ROLLBACK — 검증용 변경이 개발 DB에 남지 않음

### 개발 DB 검증 결과 (2026-05-14)

| 시나리오 | 결과 |
|---|---|
| 함수 3종 생성 + 권한(authenticated만 EXECUTE) | PASS |
| `_accumulate_legacy_no` 4케이스(NULL/누적/중복방어/부분일치 방어) | PASS |
| link — `B0020-C001` → `B0013-A001-C001` + legacy_no 콤마 누적 + map 갱신 | PASS |
| unlink — `B0013-A001-C001` → `B0013-C001` + source_application_id NULL | PASS |
| 멱등성 — 같은 신청 재호출 시 `unchanged:true` 반환 | PASS |
| 권한 가드 — JWT 클레임 미주입 시 42501 차단 | PASS |
| 같은 브랜드 검증 — 다른 brand_id 신청 차단 22023 | PASS |
| ROLLBACK 후 개발 DB 상태 무변경 | 확인 완료 |

### 운영 배포 시점 체크리스트
- [ ] 운영 DB 백업
- [ ] 088 → 089 → 090 → 118 → 119 → 120 → 121 순차 적용
- [ ] 121 적용 직후 `SELECT proname FROM pg_proc WHERE proname IN ('_accumulate_legacy_no','link_campaign_to_application','unlink_campaign_from_application')` 3행 확인
- [ ] 권한 확인: `has_function_privilege('authenticated', 'public.link_campaign_to_application(uuid,uuid)', 'EXECUTE')` true
- [ ] PR 2 (회사 관리 페인) 작업 시작은 운영 배포 완료 이후
