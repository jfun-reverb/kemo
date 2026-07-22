# 캠페인 삭제 복구 (soft delete) — 30일 보관 후 자동 완전삭제

**작성일:** 2026-07-22
**상태:** 설계 확정 (사용자 결정 완료) · 구현 착수 전
**요청자:** jfun@jfun.co.kr

> 관리자가 실수로 삭제한 캠페인을 되돌릴 수 있게, 완전 삭제 대신 30일간 "보관 삭제"(soft delete)한 뒤 서버가 자동으로 완전삭제한다. **개인정보(인플루언서 신청·주소·결과물)는 현행처럼 즉시 파기**하고, **캠페인 메타데이터(제목·설정)만 30일 보관**한다 — 개인정보 파기 원칙 준수 방향.

---

## 현재 상태 (2026-07-22 기준, 코드 직접 확인)

### 관련 코드·DB·UI 진입점
- **삭제 실행**: `dev/js/admin.js:1951` `deleteCampaign(campId, campTitle)` → 캠페인명 재입력 확인 모달 → `executeDeleteCampaign`(1986행). 권한 = **캠페인 관리자(campaign_admin) 이상**(campaign_manager 차단).
- **실제 삭제 동작**(admin.js 1998~2002행): ① `applications`를 `campaign_id`로 먼저 완전 삭제 → ② `campaigns` 행 완전 삭제. **복구 경로 없음**(hard delete).
- **삭제 차단 트리거**(마이그레이션 251 `settlement_delete_guard`): `applications`·`campaigns`·`influencers` BEFORE DELETE 트리거. **정산(settlements) 기록이 걸린 신청이 포함되면 삭제를 막음**(`settlement_exists_cannot_delete`). 즉 현재는 "정산 있으면 차단, 없으면 신청까지 완전 삭제".
- **캠페인 조회 접근 정책(RLS)**(마이그레이션 001 `campaigns_select_public`): `USING (true)` — anon 포함 누구나 전체 캠페인 읽기 가능. 인플루언서 화면에서 안 보이는 건 접근 정책이 아니라 **클라이언트 상태 필터**(`dev/js/campaign.js` — active/scheduled/closed/ended만 노출).
- **캠페인 상태 6단계**: draft → scheduled → active → closed → ended, + expired(노출 토글 OFF 전용). 전이 규칙 `CAMP_STATUS_TRANSITIONS`·`computeCampaignStatus`가 복잡하게 얽힘.
- **자동 상태 전이**: `autoOpenCampaigns`/`autoCloseCampaigns`가 `fetchCampaigns` 시 실행.
- **채번**: `trg_campaign_no`(마이그레이션 090)는 INSERT 시에만 채번. 행을 남겨두면 `campaign_no` 보존.
- **캠페인 관리 상태 탭**: 최근 도입한 `campStatusTabBar`(전체/준비/모집예정/모집중/모집마감/종료/노출종료).

### 이 제안과 충돌 가능성 있는 기존 동작
- **RLS가 공개(true)** — soft delete로 캠페인 행을 남기면 인플 앱이 여전히 읽을 수 있음 → 클라 필터 + 조회 함수에서 `deleted_at IS NULL` 제외 필요.
- **자동 상태 전이** — 보관 중 캠페인이 `autoOpenCampaigns`로 active 부활하면 안 됨 → 전이 대상에서 `deleted_at IS NOT NULL` 제외.
- **정산 차단 트리거** — 현행 유지(정산 있으면 삭제 차단). soft delete도 개인정보(신청)를 즉시 파기하므로 동일 트리거가 그대로 방어선.

### 미해결 백로그·관련 작업
- soft archive 선례: `companies.status='archived'`, 감사용 흔적 청소 RPC, `delete_brand`.
- 캠페인 관리 상태 탭(방금 도입) 옆에 「삭제됨」 탭 추가 형태.

---

## 의심·경우의 수 (반대론자 모드)

### 깨질 수 있는 경우의 수
1. **복구해도 신청은 안 돌아옴 (UX·데이터, 사용자 인지 완료)** — 개인정보 즉시 파기 방식이라, 복구 시 캠페인 설정만 되살아나고 응모자·신청·결과물은 이미 없다. → **삭제 확인창에 "복구해도 신청 내역은 되돌릴 수 없습니다" 명시**로 실수 방지. 실무상 실수 삭제는 신청 적은 준비/예정 캠페인이 대부분이라 영향 작음.
2. **인플 화면·마이페이지 노출 (권한·환경)** — 보관 중 캠페인이 인플 목록·상세·응모이력·정산 화면에 뜨면 안 됨. 단 개인정보(신청)를 이미 파기했으므로 인플 응모이력엔 애초에 그 신청이 없다. 캠페인 조회 경로(목록·상세·직접 해시 `#detail-{id}`)만 `deleted_at IS NULL` 제외 필요.
3. **자동 상태 전이 부활 (동시성·배치)** — `autoOpenCampaigns`/`autoCloseCampaigns`가 보관 중 캠페인을 건드리면 상태가 바뀜. 전이 쿼리에 `deleted_at IS NULL` 조건 필수.
4. **완전삭제 시 정산 트리거 (엣지케이스)** — 자동/수동 완전삭제(캠페인 행 hard delete)가 정산 걸린 캠페인이면 트리거가 막을 수 있음. 단 정산 있으면 애초에 보관 삭제 단계에서 차단되므로 보관 목록에 정산 캠페인이 없음 → 완전삭제 대상에도 없음. 정합.
5. **채번·번호 충돌 (데이터)** — 복구 시 `campaign_no` 유지(행을 안 지웠으니 자동 보존). 완전삭제 후 같은 번호 재사용 안 함(카운터는 단조 증가).
6. **관리자 목록 오염 (UX)** — 일반 캠페인 관리 목록·대시보드 KPI·운영현황에 보관 중 캠페인이 섞이면 안 됨. 기본 조회는 `deleted_at IS NULL`만, 「삭제됨」 탭에서만 보관분 노출.

### 현재 구현과 충돌
- 위 2·3·6 (RLS 공개·자동 전이·목록 집계)을 반드시 함께 손봐야 함. 빠뜨리면 보관 캠페인이 화면에 노출되거나 자동 부활.

### 의도 모호점 — 확인 완료
- "일정기간" → **30일**(사용자 확정).
- "삭제 시 신청 데이터" → **개인정보 즉시 파기, 캠페인 메타만 보관**(사용자 확정, 약관 검토 결과 반영).

---

## 설계

### 사용자 확정 결정 요약
| 항목 | 결정 |
|---|---|
| 보관 기간 | 30일, 이후 서버 자동 완전삭제(한국·일본 표준시 기준) |
| 개인정보(신청·주소·결과물) | 삭제 즉시 파기(현행 유지) |
| 보관 대상 | 캠페인 행(메타데이터)만 |
| 정산 걸린 캠페인 | 삭제 차단(기존 트리거 유지) |
| 복구 화면 | 캠페인 목록 「삭제됨」 탭 |
| 권한 | 보관삭제·복구=campaign_admin, 완전삭제=super_admin |
| 개인정보처리방침 | 큰 수정 불필요(개인정보 즉시 파기라 현행 파기 조항과 정합). 배포 전 변호사 최종 확인 권장 |

### DB 변경 (마이그레이션 여러 개 — 번호는 개발 착수 시 확정, 상대순서만 기재)

- **① 컬럼 추가**: `campaigns.deleted_at timestamptz NULL`(+ `deleted_by uuid NULL` 감사용). NULL=활성, 값 있으면 보관 중. 부분 인덱스 `WHERE deleted_at IS NOT NULL`.
- **② 보관 삭제 함수** `soft_delete_campaign(p_campaign_id)`:
  - 가드 `is_campaign_admin()`. 정산 걸린 신청 있으면 거부(기존 트리거와 동일 판정 재현 또는 트리거에 위임).
  - **개인정보 즉시 파기**: 그 캠페인의 `applications`·`deliverables`(+연관 Storage 파일 경로 반환)를 완전 삭제(현행 executeDeleteCampaign 로직).
  - `campaigns.deleted_at = now()`, `deleted_by = auth.uid()` 세팅(행은 남김).
- **③ 복구 함수** `restore_campaign(p_campaign_id)`: 가드 `is_campaign_admin()`. `deleted_at = NULL`. 상태는 원래 값 보존(직교 컬럼이라 자동). 복구 후 상태 재계산은 `computeCampaignStatus`가 처리.
- **④ 완전삭제 함수** `purge_campaign(p_campaign_id)`: 가드 `is_super_admin()`. 캠페인 행 hard delete(연관 개인정보는 이미 파기됨).
- **⑤ 자동 완전삭제 배치**: `purge_expired_deleted_campaigns()` + pg_cron 일 1회(한국·일본 표준시 새벽). `deleted_at < now() - interval '30 days'` 캠페인 행 삭제. 마이그레이션 166 pg_cron 선례.
- **⑥ 접근 정책·조회**: 인플 조회 경로가 `deleted_at IS NULL`만 보게. 캠페인 조회 RLS는 공개(true)라 앱단 필터가 1차 방어선이지만, 가능하면 인플 노출 함수/뷰에서 서버측 제외.
- 상대순서: ①컬럼 → ②③④ 함수 → ⑤ pg_cron → ⑥ 조회 필터. (①이 먼저, ⑤는 ②④ 후)

### 클라이언트 변경
- **삭제 동작 교체**(`dev/js/admin.js` `executeDeleteCampaign`): hard delete → `soft_delete_campaign` RPC 호출. **확인 모달 문구 변경**: 「이 캠페인을 삭제합니다. 30일간 「삭제됨」 탭에 보관되며 그 안에 복구할 수 있습니다. **단 응모자·신청 내역은 즉시 삭제되어 복구해도 되돌릴 수 없습니다.** 30일 후 자동으로 완전 삭제됩니다.」 + 캠페인명 재입력 유지.
- **「삭제됨」 탭**: `campStatusTabBar`에 탭 추가(전체 탭 집계에서는 제외). 이 탭 선택 시 `deleted_at IS NOT NULL` 캠페인만. 행 동작은 **복구**(campaign_admin)·**완전삭제**(super_admin, 재확인) 2개만(편집·상태변경·미리보기 등은 숨김). 삭제일·자동삭제 예정일(삭제일+30일) 표시.
- **일반 목록·집계 제외**: `fetchCampaigns` 및 대시보드·운영현황·자동 전이가 `deleted_at IS NULL`만. 「삭제됨」 탭만 예외.
- **인플 화면 차단**: `dev/js/campaign.js` 목록·상세·`#detail-{id}` 직접 진입에서 `deleted_at` 있는 캠페인 제외.

### 개인정보처리방침
- 개인정보를 즉시 파기하므로 §6 파기 조항과 정합 — **필수 수정 없음**. (should) "관리자가 캠페인을 삭제하면 관련 신청·결과물은 즉시 파기된다" 취지를 §6 또는 삭제 안내에 한 줄 반영 검토. 배포 전 **변호사 최종 확인** 권장.

---

## PR 분할

| 순서 | 범위 | 담당 산출물 |
|---|---|---|
| PR 1 — DB 기반 | 컬럼 + 보관삭제·복구·완전삭제 함수 + pg_cron + 조회 필터 | `supabase/migrations/*` (번호 착수 시 확정), `dev/lib/storage.js` 함수 |
| PR 2 — 관리자 화면 | 삭제 동작 교체·확인 문구, 「삭제됨」 탭, 목록·집계 제외 | `dev/js/admin.js`, `dev/admin/index.html` |
| PR 3 — 인플 노출 차단 + 검증 | `campaign.js` 필터, 자동 전이 제외 검증, (선택) 방침 문구 | `dev/js/campaign.js`, `docs/PRIVACY_*.md` |

- PR 1이 먼저(함수·컬럼 없으면 화면이 못 붙음). PR 2·3은 PR 1 개발서버 적용 후.
- admin.js를 PR 2에서 크게 건드리므로, 요청 1(변경 이력)과 동시 수정 금지 — 순차.

---

## 사용자 확인 필요
- 설계 자체는 확정(위 결정표). 구현 착수 승인만 남음.
- 배포 전 개인정보처리방침 문구 반영 여부(변호사 확인)는 PR 3 시점 재확인.

---

## 구현 결과 (개발 세션이 채울 것)
_(마이그레이션 번호·실제 함수 시그니처·초안 대비 변경 사항을 여기 기록)_
