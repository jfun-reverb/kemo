# 캠페인 운영 상세 — 진행현황 화면 확장 + 운영현황 연결

**작성일:** 2026-06-12
**작성 세션:** 기획/설계
**참고:** 챌린저스(타사) 캠페인 전용 페이지 스크린샷 4종 (개요/참여현황/인사이트/비용)

---

## 배경 (사용자 요청)

운영현황(`brand-ops`) → 브랜드 카드 → 브랜드 상세 화면의 **캠페인 미니카드 「상세」 버튼**을 누르면, 그 캠페인의 **운영 데이터 전용 화면**이 나오길 원함. 챌린저스 화면을 참고로 제시.

---

## 현재 상태 (작성일 기준 — 규칙 A)

### 관련 코드·DB·UI 진입점

- **운영현황 미니카드 「상세」 버튼** (`dev/js/admin-brand-ops.js:420`): 현재 `openCampPreviewModal(c.id)` 호출 = **인플루언서가 보는 광고 프리뷰 모달**(`dev/js/admin.js:2207`). 운영 데이터 화면이 아님.
- **이미 존재하는 캠페인 단위 운영 화면**: `camp-applicants` 페인(제목 「신청자 목록」 = 통칭 "캠페인 진행현황").
  - HTML: `dev/admin/index.html:960` `#adminPane-camp-applicants` (admin-pane-list). 헤더 `#campApplicantsTitle`·`#campApplicantsSlots`, 카드 `#campApplicantsSubtitle`·`#campApplicantsStats`, 테이블 `#campApplicantsBody`(이름·SNS·합계·신청사유·신청일·상태·OT·결과물·처리).
  - 진입 함수: `openCampApplicants(campId, campTitle)` (`dev/js/admin-applications.js:22`).
  - **유일 진입점**: 캠페인 관리 목록 표의 「신청/모집」 칸 `○ / ○명` 버튼 (`dev/js/admin.js:380`). 운영현황에서는 진입 불가.
  - 로드 함수 `loadCampApplicants()` 가 이미 fetch 하는 것: `fetchApplications({campaign_id})`, `allCampaigns.find()`(campaigns 행 전체), `fetchDeliverablesByCampaign()`, `fetchInfluencers()`.
- **운영현황 미니카드가 이미 보유한 데이터** (`get_brand_ops_detail` RPC, 마이그레이션 149·150): 승인 수(`approved_app_count`)·모집인원(`slots`)·제출 인플(`deliv_submitted_inf`)·결과물 총계/승인(`deliv_total`/`deliv_approved`)·기간(`recruit_start`/`deadline`/`purchase_*`/`visit_*`/`submission_end`)·채널·타입·썸네일.
- **개요·비용 카드 데이터 출처**:
  - 개요(제품 정보·기간·모집현황): `campaigns` 행 (`product_price` 컬럼 존재 — 002, 채널·기간·썸네일 모두 행에 있음).
  - 비용(견적·운영비): `campaigns.source_application_id`(088) → `brand_applications`의 `final_quote_krw`/`estimated_krw`/`products jsonb`(운영비). 연결 신청이 있을 때만 존재.

### 이 제안과 충돌 가능성 있는 기존 동작

- **충돌 1 — 진입 출처 분기**: `camp-applicants`는 현재 캠페인 관리 목록에서만 진입. 운영현황에서도 진입을 추가하면, **뒤로가기 목적지가 출처에 따라 달라져야** 함(운영현황 브랜드 상세 vs 캠페인 관리 목록). 현재 `openCampApplicants(campId, campTitle)`에는 출처 인자가 없음.
- **충돌 2 — 「상세」 버튼 의미 변경**: 운영현황 미니카드 「상세」가 현재는 인플 프리뷰(`openCampPreviewModal`). 이걸 진행현황으로 바꾸면, 인플 프리뷰 진입 경로가 운영현황에서 사라짐. (인플 프리뷰는 캠페인 관리 목록의 캠페인 제목 클릭으로 여전히 진입 가능 → 경로 단절 없음.)
- 충돌 없음 확인 — 데이터/권한: 진행현황은 이미 모든 관리자 접근. 비용 카드만 신규로 권한 분기 추가.

### 미해결 백로그·관련 작업

- 성별·연령 정책(마이그레이션 미착수) — 챌린저스 인사이트 탭의 성별·연령 분포는 우리 데이터 없음. (메모리 `project_challengers_benchmark_specs`)
- Qoo10 랭킹 모니터링 — 약관 게이트로 ⛔보류. (메모리 `project_qoo10_ranking_monitoring`)
- 관리자 모달/페인 stale 방지 `refreshPane` (`.claude/rules/quality.md`).

---

## 의심·경우의 수 (규칙 B)

### 깨질 수 있는 경우의 수

1. **데이터 부재 (데이터)** — 챌린저스 인사이트 탭(성별 12.4%·연령 43.8%)·랭킹 분석(Qoo10 3위)은 우리 DB에 컬럼 자체가 없음. 그대로 따라 만들면 영구 빈 화면. → **이번 범위에서 제외.** 인사이트는 성별·연령 정책 진행 후 별도 탭.
2. **진입·이탈 경로 (UX)** — 운영현황→진행현황 진입 시 뒤로가기가 캠페인 관리로 가버리면 사용자가 길을 잃음. 출처 인자 + 헤더 뒤로가기 버튼 분기 필요. 브라우저 뒤로가기(popstate)도 동일하게 동작해야 함.
3. **비용 데이터 빈 상태 (데이터·UX)** — 직접 등록 캠페인(신청 미연결)은 견적·운영비가 NULL. 비용 카드를 항상 그리면 「₩0 / 견적 없음」이 떠 오해. → **연결 신청이 있을 때만 비용 카드 렌더**, 없으면 카드 자체를 숨김.
4. **권한별 시각 차이 (권한)** — 비용(견적·운영비)은 민감. `campaign_manager`에게 노출하면 정보 과다. → 비용 카드는 `is_campaign_admin()` 이상(`isCampaignAdminOrAbove` 클라 헬퍼)일 때만 렌더. ⚠️ 단 이는 화면 표시 제한 수준이며, 실제 차단은 `brand_applications` 행 단위 보안 정책(RLS)이 담당(이미 `is_admin()` SELECT).
5. **대량 신청 (기술)** — 진행현황은 이미 lazy-load(50건씩, `mountLazyList`). 상단 요약 카드는 캠페인 1행 + 결과물 집계라 부하 없음. 결과물 집계는 이미 `fetchDeliverablesByCampaign` 1회로 끝.

### 현재 구현과 어긋나는 지점

- 위 「충돌 1·2」가 유일. 둘 다 진입 인자 추가 + 「상세」 onclick 교체로 해소. 데이터/RLS 변경 없음.

### 의도 모호점 (확정됨)

- 화면 방식 = 기존 진행현황 확장 (사용자 확정 2026-06-12).
- 비용 = 포함, 권한 분기 (사용자 확정 2026-06-12).
- 인사이트(성별·연령·랭킹) = 데이터 없어 제외 (이번 범위 밖).

---

## 권고

새 화면 신설 없이, **`camp-applicants`(진행현황) 페인 상단에 「개요」「비용」 요약 카드를 추가**하고, 운영현황 미니카드 「상세」를 이 화면으로 연결한다(진입 출처 인자 추가). DB·RLS 변경이 없어 회귀 위험이 가장 낮다. 인사이트는 데이터가 갖춰진 뒤 탭으로 증설.

---

## 설계

### 1. 진입 연결 + 출처 분기

- `openCampApplicants(campId, campTitle, from)` — 세 번째 인자 `from` 추가 (`'campaigns'` 기본 / `'brand-ops'`).
  - 운영현황 미니카드 「상세」: `openCampPreviewModal(...)` → `openCampApplicants(c.id, c.title, 'brand-ops')` 로 교체 (`admin-brand-ops.js:420`).
  - 캠페인 관리 목록 `○/○명` 버튼: 기존 호출에 `'campaigns'` 명시(또는 기본값).
- 진행현황 헤더 뒤로가기 버튼: `from === 'brand-ops'` 면 「← 운영 현황」(브랜드 상세 복귀, `_brandOpsDetailId` 유지), 아니면 「← 캠페인 관리」.
  - 운영현황 복귀 시 `switchAdminPane('brand-ops-detail')` + `loadBrandOpsDetail()` (브랜드 상세가 미니카드 stale 안 되게 재로드).
- 진입 출처는 모듈 변수 `_campApplicantsFrom` 에 저장(해시/popstate 대응).

### 2. 상단 「캠페인 개요」 요약 카드 (좌측)

챌린저스 「캠페인 개요」 좌측 카드를 우리 데이터로:

- 썸네일(`img1`) + 채널 라벨 + 제품명(`product_ko`||`product`) + 캠페인 번호(`campaign_no`) + 판매가(`product_price`)
- 챌린지 유형 = 모집 타입 한글(리뷰어/기프팅/방문형)
- 기간: 모집(`recruit_start`~`deadline`) / 리뷰어=구매(`purchase_*`) · 방문형=방문(`visit_*`) / 결과물 제출(`submission_end`)

### 3. 상단 「모집·결과물 현황」 요약 카드 (우측)

- 모집현황 진행바: 승인 수 / `slots` (예: `12 / 30명 40%`). 이미 `campApplicantsSlots`·`campApplicantsStats`가 보유한 수치 재구성.
- 결과물 제출률(제출 인플/승인 인플) · 결과물 승인률(승인 결과물/제출 결과물) — `fetchDeliverablesByCampaign` 집계로 산출(미니카드와 동일 정의).
- 보조 수치: 신청 N명 · 승인 N명 · 심사중 N명 (기존 stats 흡수).

### 4. 상단 「비용」 요약 카드 (조건부)

- **렌더 조건**: `campaigns.source_application_id` 존재 + `isCampaignAdminOrAbove()`. 둘 중 하나라도 불충족이면 카드 숨김.
- 표시: 견적(`final_quote_krw`||`estimated_krw`) · 인당 운영비(연결 신청 `products`에서 산출) · (가능하면) 견적 대비 진행. 정확한 산식은 기존 「브랜드 신청 상세」 모달의 견적 표시 로직 재사용.
- 「견적서 보기」가 있으면 링크(`quote_sent_url`).
- 연결 신청 1건 추가 조회: `fetchBrandApplication(source_application_id)` 또는 운영현황 진입 시 이미 로드된 `_brandOpsDetailData`에서 찾기.

### 5. 범위 밖 (이번 PR 제외)

- 인사이트(성별·연령·시간대·랭킹) 탭 — 데이터 부재.
- 참여 목록의 인증사진 썸네일 컬럼 등 챌린저스 고유 표현 — 기존 결과물 셀로 충분.

### DB 변경

- **없음.** 신규 컬럼·테이블·함수·행 단위 보안 정책 추가 없음. 기존 컬럼(`product_price`/`source_application_id`)·기존 RPC·기존 fetch 조합으로 구현.

---

## PR 분할 (개발 세션 판단)

- **PR 1 — 진입 연결 + 개요·현황 요약 카드**: `openCampApplicants` 출처 인자 + 운영현황 「상세」 연결 교체 + 헤더 뒤로가기 분기 + 개요/현황 카드 2종. (DB 무변경)
- **PR 2 — 비용 요약 카드**: 권한·연결 조건부 비용 카드 + 견적 산식 재사용. (DB 무변경)
- 두 PR 모두 같은 화면을 건드리므로 한 PR로 묶어도 무방. 개발 세션이 규모로 판단.

---

## 사용자 확인 필요

- (확정) 화면 방식 = 진행현황 확장 / 비용 포함(권한 분기).
- 추가 확인 후보 (개발 착수 전 선택):
  - 운영현황 「상세」를 진행현황으로 바꾸면 **인플 프리뷰는 캠페인 관리에서만** 진입 가능해짐 — 이대로 OK인지.
  - 비용 카드 「견적 대비 진행」 게이지를 넣을지(데이터 산식 복잡), 단순 견적·운영비 숫자만 표시할지.

---

## 구현 결과 (개발 세션이 채울 것)

**구현일:**
**관련 커밋:**

### 초안 대비 변경 사항
- 추가된 것:
- 빠진 것:
- 달라진 것:

### 구현 중 기술 결정 사항
-
