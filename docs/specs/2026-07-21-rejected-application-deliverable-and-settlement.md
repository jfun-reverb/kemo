# 반려·취소된 신청의 결과물 검수 자동 제외 + 정산 자동 보류

**작성일:** 2026-07-21
**작성 세션:** 고문 (설계는 reverb-planner 2회 검증)
**발단:** 운영 캠페인 B0035-C009 — 신청 승인 0명인데 게시물 결과물 8건이 "검수대기"로 떠 있는 모순 화면 제보

---

## 배경 (운영 데이터에서 확인)

- 신청이 한 번 **승인(approved)** 되면 인플루언서가 결과물(게시물/영수증)을 제출할 수 있다.
- 관리자가 나중에 그 신청을 **반려(rejected)** 또는 **취소(cancelled)** 로 되돌려도, 이미 제출된 결과물(`deliverables`)은 그대로 남는다.
- 결과물 검수 목록(`fetchDeliverables`)은 결과물 자신의 status만 보고 뽑아서, 신청이 반려됐는지 안 본다 → 반려된 신청의 결과물이 "검수대기"로 계속 뜬다.
- **실제 사례 (운영):** 캠페인 `B0035-C009` (`ビタミンCセラム 30ml_画像提供の投稿案件`, 현재 노출종료). 신청 30건 전부 rejected(2026-06-19 관리자 '에리코'가 일괄 반려), 승인 집계(`applied_count`) 0. 그런데 게시물 결과물 8건(인플루언서 6명, 2026-05-25~05-31 제출)이 검수대기로 남음. → 5월에 승인돼 결과물까지 냈던 건을 6월에 일괄 반려한 결과. **시스템 정합성 버그가 아니라 운영 조치의 잔존물.**

---

## 현재 상태 (규칙 A — 2026-07-21 검증)

### 신청 status를 결과물 단위로 아는 법
- `fetchDeliverables` (`dev/lib/storage.js:705`) 의 SELECT 는 `application_id, user_id, campaign_id` + `campaigns` 조인만. **`applications` 조인 없음** → 결과물 행에 신청 status가 안 실려온다.
- `fetchDeliverablesByCampaign` (`dev/lib/storage.js:906`) 도 동일.
- 결과물의 `application_id` 는 `applications.id` 를 가리키는 외래 키 → PostgREST 임베드 `applications:application_id (status)` 로 한 컬럼만 끌어오면 된다. **스키마 변경 불필요.**

### 인증 상태 판정 경로 (3개 독립 경로 — 한 곳만 고치면 숫자 어긋남)
1. **화면 경로**: `buildDeliverableGroups` (`dev/js/admin-deliverables.js:443`) → `computeCertStatus` (`:534`). 그룹 객체(`g`)에 신청 status 필드 없음 → 여기에 `g.application_status` 를 심는 게 최소 침습점. 공유처: 결과물 관리 목록 · 인증 상태 열(`certStatusBadge:559`) · `countCertSuccess`(`:519`) → 캠페인 진행현황·운영현황 미니카드 진행바.
2. **엑셀 경로 (별도 구현)**: `_excelCertStatusKo`/`_excelCertStatusMonitorKo` (`dev/js/admin-excel.js:131·151`) 는 `computeCertStatus` 를 안 쓰고 자체 재현 → **따로 고쳐야 숫자 일치.**
3. **사이드바 배지 (별도 카운트)**: `fetchPendingDeliverableCount` (`dev/lib/storage.js:681`) 가 `deliverables.status='pending'` 을 직접 센다 → 신청 status 무관 → **이 경로도 손봐야 B0035-C009의 8건이 배지에서 빠진다.**

### 인플루언서 측은 이미 신청 status 기준 (변경 불필요)
- 응모이력 카드(`dev/js/mypage.js:226-228`): `approved` 만 활동관리, `rejected` 는 캠페인 상세, `cancelled` 은 진입 차단. 결과물 배지도 `approved` 일 때만 렌더 → 인플루언서 화면은 신규 문구 불필요. **이 기능은 관리자 측 전용.**

### 신청 status 변경 트리거 (정산 자동 보류의 핵심 자산)
- `applications` 에 `trg_application_status_event` (`AFTER UPDATE OF status ON applications`, 마이그레이션 131) 가 이미 있음. 관리자 반려·본인 취소·자동 낙첨 모든 경로가 `applications.status` 를 UPDATE → 이 트리거 계열이 전부 발동. → **정산 자동 보류를 "신청 status 변경 트리거"로 걸면 모든 경로 자동 커버.** 기존 트리거는 안 건드리고 별개 트리거 추가.

### 관리자 반려 진입점 (가드 대상)
- `updateAppStatus(appId, status)` (`dev/js/admin-applications.js:577`) 가 승인/미승인/되돌리기 전부 처리. 신청 관리 목록·캠페인 신청자 뷰 두 화면이 모두 호출.
- **관리자 UI에는 신청을 `cancelled` 로 만드는 버튼이 없다** — 관리자는 `rejected`(미승인)·`pending`(되돌리기)만. `cancelled` 는 본인 취소 전용.
- → **관리자 가드 대상 = `approved→rejected` + `approved→pending`(되돌리기).**

### 정산 구조 (자동 보류 관련)
- 정산 자동 생성(`backfill_settlements`)은 `settlement_settings.cutoff_at` 이 NULL(현재) → **자동 생성 0건.** 현재 자동 보류 대상 데이터 거의 없음(정식 런칭 대비 선반영).
- `settlements_select_own` (마이그레이션 240) = `influencer_id=auth.uid() AND is_settlement_public()`, 현재 `influencer_visible=false`(잠금) → **본인도 자기 정산행 조회 0건.**
- `settlement_events` RLS SELECT = `has_permission('settlement.view','read')` (관리자 전용) → 자동 보류 감사 이력 인플 미노출.
- `mark_settlement_hold(id, version, memo)` (마이그레이션 223): pending·paid→on_hold, **알림 없음**, `memo` 저장. `mark_settlement_revert(id, version, memo)` (224): on_hold→pending.
- 본인 취소 `cancel_application` RPC (마이그레이션 104): 결과물 1건이라도 `approved` 면 차단(`deliverable_already_approved`). **paid 정산 = 결과물 전부 승인 → 본인 취소는 이미 구조적으로 차단됨.**
- 캠페인 종료 자동 낙첨 (마이그레이션 176): `WHERE status='pending'` 만 대상, approved 미변경 → paid/approved 와 안 겹침.

### 이 제안과 충돌 가능성 있는 기존 동작
- **충돌 없음 — 확인 완료.** `computeCertStatus` 앞단에 제외 분기를 넣으면 기존 3종(success/submitting/none) 판정 무변경. 엑셀·사이드바 배지는 별도 경로라 각각 손봄. 정산 자동 보류는 별개 트리거라 기존 트리거 무변경.

---

## 의심·경우의 수 (규칙 B)

### 결과물 검수 자동 제외
1. **재승인 되돌리기 자동 복원**: 결과물 status를 안 바꾸고 신청 status를 매번 참조 → `rejected→approved` 되돌리면 자동으로 검수 대상 복귀. **단 조건**: 되돌리기 후 결과물 페인·배지·진행바가 재조회돼야 즉시 반영. 신청 "되돌리기" 저장이 결과물 페인/배지를 갱신하는지 확인 필요.
2. **이미 승인(approved)된 결과물을 신청 반려**: 화면·엑셀·목록은 매 렌더 재계산이라 즉시 "검수 불필요"로 빠짐(안전). 이미 정산행이 생성됐다면(=paid) → 가드 (A)가 반려를 차단하므로 도달 자체를 막음.
3. **대량(캠페인 전체 수백 건)**: `buildDeliverableGroups` 그룹 Map + 지연 렌더라 클라 필터 O(n) 문제 없음. 임베드 조인은 결과물 1건당 1컬럼이라 응답 크기 미미.
4. **UX(필수)**: 완전 숨김만 하면 "낸 게 왜 사라졌지" 혼란, 항상 보이면 지저분 → **"검수 불필요 포함" 토글 기본 켜짐**(회색 배지로 보임) + 끄면 숨김. 균형점.
5. **감사용 계정(is_audit)**: 기존 격리 유지 위에 신청 status 제외를 얹음(직교). 감사용으로 승인→반려 시뮬레이션 시 이 분기도 검증 대상.
6. **권한(campaign_manager)**: `applications` SELECT 가 `is_admin()` 이라 campaign_manager 도 신청 status 임베드 조회 가능 → 판정 동작. 새 버튼/CUD 없음이라 권한 사고 없음.

### 정산 자동 보류 + 가드
1. **송금완료(paid) 자동 환수 위험**: 자동 on_hold(환수)는 오반려 시 되돌리기 어려운 금전 사고 → **paid는 자동 보류 안 함.** 대신 가드 (A)로 반려 자체를 차단.
2. **재승인 시 정산 비대칭**: 결과물은 자동 복원되나 정산은 상태를 실제로 바꿈 → **정산은 수동 복원.** 관리자 의도 보류를 재승인이 덮어쓰는 사고 방지. 정산 화면 안내 버튼으로 비대칭을 UX로 메움.
3. **인플루언서 미노출 누수**: 자동 보류·가드 어디서도 `notifications` INSERT 없음. 정산 잠금(`influencer_visible=false`)+감사 이력 관리자 전용 → **인플에게 새는 경로 0. 확인 완료.**
4. **의도 모호점 해소**: "취소"는 관리자 UI에 없음(본인 취소 전용) → 관리자 가드는 `rejected`·되돌리기만.

---

## 설계

### PR 1 — 결과물 검수 자동 제외 + 사이드바 배지 (데이터베이스 변경 없음)

**신청 status 취득**: `fetchDeliverables`·`fetchDeliverablesByCampaign` 에 임베드 `applications:application_id (status)` 추가. `buildDeliverableGroups` 에서 `g.application_status = d.applications?.status` 세팅 + 헬퍼 `isCertExcluded(g)` = `['rejected','cancelled'].includes(g.application_status)`.

**"검수 불필요" 판정을 넣을 모든 지점** (한 곳 누락 시 숫자 어긋남):
1. 결과물 검수 목록(`renderDeliverablesList`) + "총 N건" — **"검수 불필요 포함" 토글 기본 켜짐**(회색 배지로 보임), 끄면 숨김
2. 인증 상태 열(`computeCertStatus`/`certStatusBadge`) — 제외 그룹은 회색 "검수 불필요" 반환(success/none 앞단 분기)
3. 결과물/영수증 상태 카운트 배지 드롭다운 — 제외 그룹 빼기
4. 사이드바 "검수대기" 배지(`fetchPendingDeliverableCount`) — 반려·취소 신청 결과물 제외
5. 캠페인 진행현황 인증성공률 진행바(`renderCampOpsSummary`) — 같은 소스라 자동, 검증만
6. 운영현황 미니카드 인증성공률(`hydrateCampCertBars`/`countCertSuccess`) — 자동, 검증만
7. 엑셀 인증 상태(`_excelCertStatusKo`/`_excelCertStatusMonitorKo`) — 별도 경로, 제외 처리 삽입
8. 운영현황 "제출률" 진행바(`get_brand_ops_detail` 서버 RPC) — **이번엔 보류**. 1·2단계 개발서버 검증 후 필요성 판단(후속)

### PR 2 — 정산 자동 보류 + 신청 반려/취소 가드 2종

**자동 보류 트리거** (신규, RPC 호출 아님):
- `auto_hold_settlement_on_app_reject()` — `AFTER UPDATE OF status ON applications`, `SECURITY DEFINER`, `SET search_path=''`. 발동: `OLD.status='approved' AND NEW.status IN ('rejected','cancelled')`.
- 해당 `application_id` 의 settlements `FOR UPDATE` 잠금 후:
  - `pending` → `on_hold`, `version=version+1`, `memo='신청 반려로 자동 보류'` + `settlement_events(action='hold', prev='pending', next='on_hold', actor=auth.uid(), memo='신청 반려로 자동 보류')`
  - `paid` → **안 건드림** (가드 A가 도달 자체를 차단, 우회 도달해도 자동 환수 금지)
  - `on_hold`/`cancelled`/정산행 없음 → no-op(멱등)
- RPC를 트리거에서 호출하지 않는 이유: `mark_settlement_hold` 는 `has_permission` 가드+version 인자 필요 → 트리거(actor가 인플일 수 있는 문맥)엔 부적합. 트리거가 직접 UPDATE+events INSERT.
- **감사 구분**: `settlement_events.action` CHECK 확장 안 함. 고정 memo `"신청 반려로 자동 보류"` 로 정산 화면에서 `memo LIKE '%자동 보류%'` 필터/구분.

**재승인 복원 (수동 + 안내)**: `rejected→approved` 시 정산 자동 복원 안 함. 관리자 정산 화면에서 `memo LIKE '%자동 보류%'` + `status='on_hold'` 건에 "신청 반려로 자동 보류됐던 건 — 복원할까요?" 버튼(`mark_settlement_revert` 호출).

**가드 (A) — 송금완료(paid) 정산 걸린 신청 반려/되돌리기 = 완전 차단**:
- **UI 층** (`updateAppStatus`, `rejected`·되돌리기 진입 시): 해당 신청에 `status='paid'` 정산 존재 조회 → 있으면 경고 모달("이미 송금 완료된 정산이 있어 미승인/되돌리기 할 수 없습니다") + `return`(서버 미도달)
- **서버 층** (BEFORE UPDATE 트리거, 우회 방어): `guard_reject_with_paid_settlement()` — `BEFORE UPDATE OF status ON applications`, `OLD.status='approved' AND NEW.status IN ('rejected','cancelled','pending')` AND paid 정산 존재 → `RAISE EXCEPTION`. 자동 낙첨(pending만)은 안 걸림.

**가드 (B) — 결과물 제출된 신청 반려/취소/되돌리기 = 확인 알럿** (UI만):
- (A) 통과 후 `fetchDeliverablesByApplication(appId)` (`dev/lib/storage.js:920`, 이미 존재·경량)로 draft 제외 결과물 존재·최근 `submitted_at` 조회 → 있으면 확인 모달 "◯월◯일 제출된 결과물이 있습니다. 그래도 미승인/되돌리기 하시겠습니까?" → 확인 시 진행. 없으면 바로 처리.
- 우선순위: (A) 차단 먼저 → paid면 (B) 도달 안 함. paid 아니고 결과물만 있으면 (B) 확인. 결과물 없으면 즉시 처리.
- **되돌리기(approved→pending)도 (B) 확인 대상** (사용자 확정 2026-07-21).

---

## PR 분할

- **PR 1 — 결과물 검수 자동 제외 + 사이드바 배지** (`feat`, 마이그레이션 0개): 위 지점 1~7. → **B0035-C009 화면·배지 모순 해소.**
- **PR 2 — 정산 자동 보류 + 반려 가드 2종** (`feat`, 마이그레이션 2개):
  - 마이그레이션 ① 자동 보류 트리거 함수+트리거 (`AFTER UPDATE`, pending→on_hold, 고정 memo, paid 미변경)
  - 마이그레이션 ② paid 반려 차단 트리거 함수+트리거 (`BEFORE UPDATE`)
  - (①② 파일을 1개로 합칠지 2개로 나눌지는 **개발 세션 재량**. 둘 다 `applications` status 트리거)
  - `updateAppStatus` UI 가드 (A)(B) + 정산 화면 memo 필터·복원 버튼
- **배포**: PR 1·PR 2 둘 다 개발서버 검증 후 **함께 운영 배포** (순서 종속 없음).

### 영향 파일
- **PR 1**: `dev/lib/storage.js`(fetchDeliverables·fetchDeliverablesByCampaign 임베드, fetchPendingDeliverableCount) / `dev/js/admin-deliverables.js`(buildDeliverableGroups·computeCertStatus·certStatusBadge·renderDeliverablesList·토글) / `dev/js/admin-excel.js`(_excelCertStatus*) / `dev/index.html`(관리자 — 토글 체크박스). 진행바(admin-brand-ops.js·admin-applications.js)는 소스 공유라 자동, 검증만
- **PR 2**: `supabase/migrations/*`(트리거 2개) / `dev/js/admin-applications.js`(updateAppStatus 가드 A·B, 반려 전 정산·결과물 조회) / `dev/js/admin-settlements.js`(자동 보류 memo 필터·배지, 재승인 복원 안내 버튼) / `dev/lib/storage.js`(신청별 paid 정산 존재 조회 헬퍼 1개)

---

## 검증 시나리오 (개발서버)

**PR 1**: 승인→결과물 제출→반려 시 ①회색 "검수 불필요" 배지로 보임(토글 기본 켜짐) ②토글 끄면 목록에서 사라짐 ③인증성공률·진행바 감소 ④사이드바 배지 감소 ⑤엑셀 셀 "검수 불필요" ⑥재승인 시 자동 복귀. 감사용 계정으로 1회. campaign_manager 권한에서도 조회 확인.

**PR 2**:
1. 자동 보류: pending 정산 더미 → 관리자 미승인 → `on_hold` + `settlement_events(action='hold', memo='신청 반려로 자동 보류')` + **인플 알림 0·본인 조회 0**
2. 가드 (A): paid 정산 더미 → 미승인 시도 → UI 경고 + 반려 안 됨. 직접 SQL로 `approved→rejected` UPDATE → 서버 트리거 `RAISE`(우회 방어). 자동 낙첨(pending)은 정상 동작 확인
3. 가드 (B): 결과물(검수중) 있는 신청 미승인·되돌리기 → "◯월◯일 제출된 결과물…" 확인 모달 → 확인 시 진행 + 결과물 검수불필요 + 정산 자동 보류. 결과물 0건은 즉시 처리
4. 재승인 복원: 자동 보류된 건 재승인 → 정산 `on_hold` 유지 + 정산 화면 복원 버튼 → 클릭 시 `mark_settlement_revert` 로 pending 복귀
5. 본인 취소 경로: 결과물 승인 있는 신청 본인 취소 시도 → 기존 `deliverable_already_approved` 차단 확인. 결과물 미승인 본인 취소 → 정산행 없어 자동 보류 no-op
6. 멱등·권한: 같은 신청 반려 재실행 시 중복 events 없음. campaign_manager는 정산 화면·RPC 차단 유지

---

## B0035-C009 운영 건 — 자동 해소

**PR 1 배포만으로 자동 해소** (별도 데이터 조치 불필요). 신청 30건 전부 rejected → 결과물 8건이 "검수 불필요"로 분류, 인증성공/진행바 제외, 사이드바 배지 -8. 결과물 DB status(pending)는 보존 → 되돌리면 자동 복귀. 정산은 이 캠페인에 생성된 행이 없을 것(cutoff NULL)이라 PR 2와 무관.

---

## 사용자 확정 사항 (2026-07-21)

| 항목 | 결정 |
|---|---|
| 판정 방식 | 신청 status 기준 자동 제외 (결과물 데이터 불변, 재승인 시 자동 복원) |
| 목록 표시 | "검수 불필요 포함" 토글, **기본 켜짐** (회색 배지로 보이되 끄면 숨김) |
| 사이드바 검수대기 배지 | 이번에 함께 정합 |
| 운영현황 제출률 진행바 | 이번 보류 (1·2단계 검증 후 판단) |
| 정산 자동 보류 | 이번에 함께. 인플루언서 알림·내역 미노출(잠금 유지), 관리자만 관리 |
| 재승인 시 정산 | 수동 복원 + 안내 표시 |
| 감사 구분 | 데이터베이스 제약 미확장, 고정 메모 "신청 반려로 자동 보류" 로 필터 |
| 송금완료(paid) 건 반려/되돌리기 | 완전 차단 — 화면 + 서버 둘 다 |
| 결과물 제출된 건 반려/취소/되돌리기 | 확인 알럿 "◯월◯일 제출된 결과물이 있습니다" 후 진행 |
| 배포 | PR 1·2 개발서버 검증 후 함께 운영 배포 |
| 마이그레이션 파일 분할 | 개발 세션 재량 (1개 통합 vs 2개 분리) |

---

## 구현 결과 (개발 세션이 채울 것)

**구현일:**
**관련 커밋 / PR:**

### 초안 대비 변경 사항
- 추가된 것:
- 빠진 것(+이유):
- 달라진 것:

### 구현 중 기술 결정 사항
- (마이그레이션 번호·트리거 구조·헬퍼 등)
