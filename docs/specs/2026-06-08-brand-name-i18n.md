# 브랜드명 다국어 표시 정합화

**작성일:** 2026-06-08

> 캠페인 관리 목록에서 같은 브랜드인데 어떤 캠페인은 일본어, 어떤 캠페인은 한국어로 브랜드명이 표시되는 버그를 근본 해결한다. 화면별 언어 우선순위(관리자 한국어>영어>일본어 / 인플루언서 일본어>영어>한국어)로 통일.

## 🚨 전제 정정 (착수 전 반드시 읽을 것)

사용자·초기 진단의 전제 **"브랜드 마스터(brands)는 이름 칸이 1개뿐"** 은 **틀렸다.** 검증 결과:

- `brands` 테이블에는 **이미 `name`(한국어)·`name_ja`(일본어)·`name_en`(영문) 3칸이 존재** (`dev/lib/storage.js` `fetchBrands()` select 절).
- 브랜드 관리 폼에도 **입력칸 3개가 이미 있음** — 「브랜드명(한국어)*」「브랜드명(일본어)」「브랜드명(영문)」 (`dev/js/admin-brand.js` `_collectBrandFormPatch`가 3종 모두 저장).

→ **다국어 칸·입력 폼은 새로 만들 필요 없음.** 진짜 버그는 **캠페인 스냅샷·표시 레이어가 마스터의 3국어를 안 쓰고 단일 텍스트만 본다**는 점.

## 현재 상태 (작성일 2026-06-08 기준)

### 관련 코드·DB·UI 진입점
- **DB**
  - `brands`: `name`(한국어), `name_ja`, `name_en`, `name_normalized`, `brand_seq`, `company_id`. ⚠️ 한국어 칸 이름이 `name`(회사 테이블 `companies`의 `name_ko`와 명명 불일치 — 리네임 금지: `name_normalized` 트리거·채번·검색 등 12곳+ 연쇄).
  - `companies`: `name_ko`(NOT NULL)/`name_ja`/`name_en` (참고 패턴).
  - `campaigns`: `brand`(저장 시점 텍스트 스냅샷, 한국어 칸 복사본), `brand_ko`(현재 전부 빈값 — 죽은 칸), `brand_id` FK.
  - **brands RLS: SELECT `is_admin()`** — 인플루언서(비관리자)는 읽을 수 없음.
- **캠페인 저장 경로 (버그 핵심)**
  - `onCampBrandChange()` (`dev/js/admin.js:3251~`): 브랜드 선택 시 `brand = picked.name`(한국어 칸만 복사), `brand_ko = ''`(항상 빈값).
  - 신규/편집 저장(`admin.js:2446~2450`, `1728~1731`): 한국어 칸만 스냅샷, `name_ja`/`name_en`은 전혀 안 들어감.
- **표시 레이어**
  - 관리자 목록 (`admin.js:360`): `c.brand_ko || c.brand || ''` (사실상 `c.brand`).
  - 인플 카드 (`dev/js/campaign.js:291`), 상세 (`dev/js/application.js:93`), 활동관리 (`application.js:596`), 통계 (`campaign.js:56`), 검색 haystack (`campaign.js:218`).
- **운영 데이터 실측(캠페인 120건)**: `brand_ko` 전부 빈값. `campaigns.brand` 스냅샷에 한국어/영어/일본어 혼재(같은 brand_id에 「ベントン」10건+「벤튼」3건). 대부분 한국어·영어, 일부만 일본어. ※ `brands.name`(마스터)에 일본어가 든 행 수는 **관리자 권한 필요 — 개발 단계에서 실측**.

### 이 제안과 충돌 가능성 있는 기존 동작
- **인플 표시 「항상 마스터 최신」 ↔ brands RLS**: brands가 `is_admin()` SELECT라 인플은 못 읽음. 해결 필요(아래 설계 A안).
- `name_normalized`는 한국어 `name` 기준 트리거 자동계산 + 검색·중복·채번 키 → `name`은 계속 채워져 있어야 안전(NOT NULL 성격 유지).
- `campaigns.brand` 텍스트는 엑셀·검색·통계 distinct가 읽음 → 표시를 조인으로 바꿔도 이 참조처 점검 필요.

### 미해결 백로그·관련 작업
- `docs/specs/2026-06-04-brand-company-linking.md` (브랜드↔회사 일원화, 2026-06-05 운영 배포) — 같은 `admin-brand.js` 영역에서 이미 다국어 칸 저장 정리됨.

## 의심·경우의 수

1. **[데이터] 자동 언어 분류 오분류** — 「마스터에 일본어로 잘못 든 이름」 정리 시 한글/가나 정규식 자동 분류는 음차 브랜드(메디포셀/メディフォセル)·혼합 표기에서 오분류. → **후보 제안 + 사람 검수**로 확정(사용자 결정).
2. **[권한] 인플 RLS** — 위 충돌점. 「항상 최신」 = 인플도 brands 읽기 필요.
3. **[UX] 인플 빈칸 폴백** — 일본어 칸이 비면? → **일본어→영어→한국어** 폴백으로 빈칸 방지(사용자 결정). 일본어 이름이 안 채워진 브랜드는 임시로 한국어가 노출될 수 있음 → 마스터 일본어명 입력 독려.
4. **[표기 시점]** — 사용자 결정 **「항상 마스터 최신」**. 마스터 수정이 과거 캠페인 표기에도 즉시 반영. 스냅샷 컬럼 확장(brand_ja/brand_en) 불필요.
5. **[죽은 칸] `campaigns.brand_ko`** — 전부 빈값. 표시·검색 폴백이 아직 참조 → 청소 대상(별도 PR).

### 현재 구현 충돌점
- 다국어 칸·폼은 이미 구현됨 → 신규 개발 아님, **정합·표시 교체**로 범위 축소.

### 의도 모호점 (해소됨)
- "마스터 칸 일본어" = `brands.name`(마스터) 기준. 개발 단계 실측으로 규모 확정.

## 설계 (사용자 결정 반영)

### A. 표시 = 항상 마스터 최신 (brands 조인) + RLS 개방
- **brands RLS에 SELECT 공개(또는 authenticated) 정책 추가** — 브랜드명은 캠페인에 이미 노출되는 사업자 상호라 민감정보 아님. (마이그레이션 1개, reverb-supabase-expert 검토)
- 캠페인 조회 시 `brand_id`로 brands(`name`, `name_ja`, `name_en`) 조인 → 관리자 목록·인플 화면이 마스터 3국어 사용.
- `campaigns.brand` 스냅샷은 **표시에서 미사용**(검색·엑셀 등 잔존 참조는 점검 후 헬퍼/조인으로 이전 또는 유지).

### B. 표시 우선순위 헬퍼 2종 (`dev/lib/shared.js` 신규)
```
brandLabelAdmin(b)  = b.name (한국어) || b.name_en || b.name_ja || ''
brandLabelInflu(b)  = b.name_ja || b.name_en || b.name (한국어) || ''
```
- 관리자·인플 양쪽 빌드에 포함되는 shared.js에 배치.
- 인자: brands 조인 객체(`{name, name_ja, name_en}`).

### C. 표시 레이어 교체
- 관리자 목록 `admin.js:360` → `brandLabelAdmin`.
- 인플 카드 `campaign.js:291`·상세 `application.js:93`·활동관리 `application.js:596`·통계/검색 → `brandLabelInflu`(검색은 3국어 모두 haystack에 포함).

### D. 마스터 데이터 정정 (후보 제안 + 사람 검수)
- 개발 단계 실측 SQL로 `brands.name`에 일본어(가나/특정 한자) 든 행 추출.
- 자동 분류는 **후보만** 생성, 실제 `name_ja`로 이동은 관리자 검수(검수 화면 또는 사용자 확인 SQL). 무인 일괄 UPDATE 금지.
- `name`(한국어 칸)을 비우면 정규화·검색·채번 깨질 수 있음 → 일본어를 `name_ja`로 복사하되 `name` 처리(한국어명 별도 입력 or 유지)는 검수 시 결정.

## PR 분할 (의존 순서)
> 마이그레이션 번호는 개발 세션이 생성 시점 확정 (플레이스홀더만).

1. **PR 1 — 브랜드 읽기 권한 개방 + 표시 헬퍼 + 표시 교체**
   - 마이그레이션 1개: brands SELECT 공개(또는 authenticated) 정책.
   - `shared.js` 헬퍼 2종.
   - 캠페인 조회(관리자 목록·인플 화면) brands 조인 + 헬퍼로 표시 교체.
   - reverb-supabase-expert(RLS) + reverb-reviewer + qa-tester(인플 응모 플로우 영향).
2. **PR 2 — 마스터 일본어명 정정** (선택): 실측 + 후보 검수 도구/SQL.
3. **PR 3 — 죽은 칸 청소** (선택): `campaigns.brand_ko` 참조 제거.

- `admin.js` 핫스팟 — worktree 병렬 금지, 시퀀셜.

## 약관·개인정보 영향
- 브랜드명은 사업자 상호 — **개인정보 아님, 영향 없음**. brands 읽기 개방도 민감정보 노출 아님(`/약관확인` 불요).

## 사용자 확인 완료 (2026-06-08)
- 인플 폴백: 일본어 → 영어 → 한국어 (빈칸 방지)
- 표기 시점: 항상 마스터 최신
- 마스터 정정: 후보 제안 + 사람 검수

## 구현 결과 (개발 세션이 채울 것)
