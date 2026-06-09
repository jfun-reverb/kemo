# 관리자 결과물 대리 등록 — 이미 제출된 결과물 사전 안내

**작성일:** 2026-06-09
**작성:** 기획 세션
**관련 기능:** 관리자 결과물 대리 등록 (`/admin#deliverables` → 「대리 등록」 모달)

---

## 배경 (사용자 보고)

운영 담당자가 **제출기간이 지난 응모건**에 대해 "인플루언서가 못 냈겠지" 생각하고 게시물 결과물을 대리 등록하려 했으나, 사실 **인플루언서가 이미 그 게시물을 검수대기 상태로 제출**해 둔 상태였다. 대리 등록 마지막 단계에서 **「대리 등록 실패: 같은 게시물 URL이 이미 등록되어 있습니다.」** 토스트만 뜨고, 담당자는 **그다음 무엇을 해야 할지 몰라 멈췄다.**

핵심: 에러가 "막힌 이유"만 알려주고 "다음 행동"을 안내하지 않는다. 게다가 **다 입력한 뒤 맨 끝에서야** 막힌다. (비개발자 담당자에게 가장 흔한 막힘)

---

## 현재 상태 (2026-06-09 기준 · planning.md 규칙 A)

### 관련 코드·DB·UI 진입점

**모달 로직** — `dev/js/admin-deliverables.js`
- `openAdminProxyModal(presetAppId)` (1413줄): 모달 열 때 **승인된 신청 + 캠페인 + 인플루언서만** 로드. **기존 제출 결과물(`deliverables`)은 조회하지 않음.**
- `_loadAdminProxyApprovedApps()` (1570줄): `applications` status='approved' 전건 + 캠페인·인플 클라이언트 join. deliverables 미포함.
- `selectAdminProxyInf(appId, silent)` (1755줄): 인플루언서(=응모건) 선택 → `_refreshAdminProxyKindOptions(app)` 호출. 종류 드롭다운만 채움(recruit_type 기준), **이미 제출 여부 확인 안 함.**
- `_refreshAdminProxyKindOptions(app)` (1778줄): monitor → 영수증·리뷰이미지 / 그 외 → 게시물 URL 옵션 생성.
- 검수 모달 진입 함수 `openDelivCombined(applicationId)` (865줄)은 **응모건 ID 하나로 검수 모달을 연다** (목록 「검수」 버튼이 이미 이렇게 호출, 563줄). 역방향 `openAdminProxyFromCombined()` (1445줄)도 이미 존재 → **「검수로 이동」 버튼은 같은 패턴으로 구현 가능, 충돌 없음.**

**서버 가드(중복 판정)** — `supabase/migrations/163_admin_proxy_evidence.sql` (현행 RPC `admin_create_deliverable_proxy`)
- `kind='post'` (215~225줄): 같은 `application_id` + `kind='post'` + **같은 `post_url`** 이 이미 있으면 `RAISE EXCEPTION '같은 게시물 URL이 이미 등록되어 있습니다.'` (23505)
- `kind='review_image'` (237~247줄): 같은 `application_id` + `kind='review_image'` + **같은 `post_channel`** 이 이미 있으면 `RAISE EXCEPTION '해당 채널(%)의 리뷰 이미지가 이미 등록되어 있습니다.'` (23505)
- `kind='receipt'`: **중복 가드 없음** (영수증은 여러 건 허용). 즉 영수증은 이 에러가 안 남.

→ **중복 판정 단위가 종류마다 다름**: 게시물=URL 단위, 리뷰이미지=채널 단위, 영수증=막지 않음.

### 이 제안과 충돌 가능성 있는 기존 동작
- **충돌 없음 — 확인 완료.** 신규 동작은 모달에 "조회 + 안내" 단계를 추가할 뿐, 기존 등록 흐름·RPC·DB는 그대로. 「검수로 이동」도 기존 `openDelivCombined` 재사용.
- DB 변경 없음(조회만).

### 미해결 백로그·관련 작업
- `project_admin_proxy_deliverable.md` (대리 등록 운영 출시 완료, 마이그레이션 160·161·163)
- `project_deliverable_post_url_dup_bug.md` (게시물 채널별 1건·재제출=같은 채널 교체. ⚠️후속: 채널별 유니크 정리·중복 정리 — **본 사양의 "중복 판정 단위"는 그 후속 작업의 현 상태에 맞춰 개발 세션이 확정**)

---

## 의심·경우의 수 (planning.md 규칙 B)

1. **부분 제출** (가장 중요): 리뷰어(monitor) 캠페인은 영수증 + 리뷰이미지 2종. **영수증만 냈고 리뷰이미지는 안 냈으면 리뷰이미지 대리 등록은 정상적으로 필요.** → "인플루언서 통째로 막기" 금지, **종류·채널 단위 판정** 필수.
2. **이미 낸 건의 상태**(검수대기/반려/승인)에 따라 담당자 행동이 다름 → 안내에 **상태 같이 표시.**
3. **빈 상태**: 제출 0건이면 안내 박스 미표시 + 정상 진행 (대리 등록 본래 용도 — 막으면 안 됨).
4. **채널 단위**: 게시물·리뷰이미지는 채널마다 1건. 인스타는 냈고 X는 안 냈으면 **X는 대리 등록 가능**해야 함.
5. **영수증은 중복 미차단**: 영수증은 RPC가 안 막으므로 드롭다운 비활성 대상 아님. 단 "이미 영수증 N건 제출됨" 안내는 노출(담당자 인지용).
6. **진입 경로 차이**: 검수 모달에서 「대리 등록」으로 들어온 경우(`openAdminProxyFromCombined`)는 거의 항상 결과물이 있는 응모건 → 안내 박스가 자연스럽게 뜸. 결과물 페인 상단 버튼으로 직접 진입하면 응모건을 새로 고르므로 0건일 수도.
7. **stale 가능성**: 모달 여는 동안 다른 관리자가 결과물을 추가/삭제하면 안내가 과거 상태일 수 있음. → RPC가 최종 방어선이므로 안내는 "사전 보조"일 뿐, 실패 토스트는 그대로 유지(보강).

---

## 제안 / 설계

### 동작 (사용자 확정: "안내 + 「검수로 이동」 버튼까지")

대리 등록 모달에서 **인플루언서(응모건)를 선택한 직후**, 그 `application_id`의 기존 `deliverables`를 조회해 다음을 처리:

#### 1. 안내 박스 (응모건에 제출 결과물이 1건 이상일 때만 표시)
- 위치: 종류 선택 드롭다운 위(또는 인플루언서 입력 아래) 모달 본문 상단.
- 내용:
  - 헤더: 「이미 제출된 결과물이 있습니다」 (경고 톤, 노랑/주황 배너)
  - 종류·채널·상태 요약 목록. 예:
    - 「게시물(Instagram) — 검수대기」
    - 「리뷰이미지(X) — 반려」
    - 「영수증 — 검수대기 (2건)」
  - 행동 안내 한 줄: 「이미 제출된 결과물은 대리 등록 대신 아래 [결과물 검수]에서 승인·반려해 주세요.」
  - **「검수로 이동」 버튼**: `closeAdminProxyModal()` → `openDelivCombined(appId)` (기존 함수 재사용).
- 0건이면 박스 미표시, 기존 흐름 그대로.

#### 2. 종류·채널 드롭다운 표식·비활성 (중복으로 막히는 종류만)
- **게시물**: 이미 제출된 게시물의 **점유 단위**(현행 RPC 기준 = 같은 채널/URL)는 채널 옵션에 「제출됨」 표식 + 비활성. (실제 판정 단위는 개발 세션이 현행 인덱스·RPC에 맞춰 확정 — `post_url` vs 채널)
- **리뷰이미지**: 이미 제출된 **채널**은 채널 옵션에 「제출됨」 표식 + 비활성.
- **영수증**: 중복 미차단 종류 → 비활성 안 함. 안내 박스에만 "N건 제출됨" 표시.
- 모든 채널/종류가 이미 점유되어 더 등록할 게 없으면, 종류 드롭다운에 그 사실 안내(예: 「추가로 대리 등록할 항목 없음 — 검수에서 처리」).

#### 3. 실패 토스트 보강 (최종 방어선)
- 만에 하나 안내를 지나쳐(또는 동시 처리로) RPC 중복 에러가 나도, 토스트 문구에 행동 안내를 덧붙임:
  - 현행: 「같은 게시물 URL이 이미 등록되어 있습니다.」
  - 보강: 「…이미 등록되어 있습니다. 대리 등록 대신 [결과물 검수]에서 처리해 주세요.」 (클라이언트 토스트에서 덧붙이거나 RPC 메시지 수정 중 택1 — RPC 메시지 수정은 마이그레이션 동반이므로, **1차는 클라이언트 토스트에서 덧붙이는 쪽 권장**)

### 데이터 조회
- 신규 또는 재사용 조회 함수(`dev/lib/storage.js`): `application_id` 로 `deliverables` 의 `kind, status, post_channel, post_url, created_at` SELECT. RLS는 `is_admin()` SELECT 허용(기존). DB 변경 없음.
- 모달 로드 시점에 모든 응모건의 deliverables를 미리 받지 말 것(대량). **인플루언서 선택 시 그 응모건 1건만 조회**(가벼움).

### DB 변경
- **없음.** 조회(SELECT)만 추가. (3번 토스트 보강을 RPC 메시지 수정으로 하면 마이그레이션 1개 추가되지만, 1차 권장안은 클라이언트 처리라 DB 무변경.)

### 영향 파일
- `dev/js/admin-deliverables.js` — 인플루언서 선택 시 조회·안내 박스 렌더·드롭다운 표식, 「검수로 이동」 핸들러
- `dev/lib/storage.js` — 응모건 deliverables 조회 함수 (없으면 추가)
- `dev/admin/index.html` (또는 빌드 전 dev HTML) — 안내 박스 컨테이너 요소
- 빌드: `bash dev/build.sh`

---

## PR 분할

단일 PR로 충분 (조회 + 안내 + 드롭다운 표식 + 검수 이동 버튼 + 토스트 보강 한 세트). DB 무변경.

---

## 사용자 확인 필요 (개발 착수 전 점검)

- (확정됨) 안내 수준 = **안내 박스 + 「검수로 이동」 버튼**.
- (개발 세션 판단) 게시물 중복 판정 단위(URL vs 채널) — 현행 인덱스·RPC 상태에 맞춰 확정. `project_deliverable_post_url_dup_bug.md` 후속(채널별 유니크) 진행 여부에 영향받음.

---

## 구현 결과

**구현일:** 2026-06-09
**관련 커밋:** (dev 커밋 예정 — `feat(deliverable): pre-guide existing submissions in admin proxy modal`)

### 초안 대비 변경 사항
- **추가된 것:**
  - `storage.js` 에 `fetchDeliverablesByApplication(appId)` 신규 함수 (기존 `fetchDeliverablesForUser({application_id})` 는 `select('*')`+인플 본인 맥락 이름이라 재사용 대신 관리자용 경량 전용 함수 추가).
  - 안내 박스 CSS(`.admin-proxy-existing-box` 외) — 기존 모달 노랑 경고 박스 톤(`#FEF3C7`/`#FBBF24`) 재사용.
- **빠진 것:** 없음.
- **달라진 것:**
  - 사양서는 게시물 채널 비활성 여부를 "개발 세션 확정"으로 열어뒀음 → **게시물 채널은 비활성하지 않고 「(이미 게시물 제출됨)」 표식만**으로 확정. 리뷰이미지 채널만 비활성.
  - **안내 박스는 검수대기(pending) 결과물만 노출**(2026-06-09 사용자 피드백 반영). 초안은 "제출 1건 이상이면 종류·채널·상태 요약"이었으나, 박스 목적이 "아직 처리 안 된 것을 검수로 보내기"라 이미 승인·반려된 지난 내역은 제외. 상태 칩도 제거(모두 검수대기라 불필요). 채널 드롭다운 비활성/표식은 중복 방지 목적이라 상태 무관하게 전체 deliverables 기준 유지.

### 구현 중 기술 결정 사항
- **게시물 중복 판정 단위 = URL 단위 확정.** 현행 인덱스 `uidx_deliverables_post_url ON deliverables(application_id, kind, post_url) WHERE kind='post'` (마이그레이션 035) + RPC `admin_create_deliverable_proxy` (마이그레이션 163) 의 post 가드가 `(application_id, kind='post', post_url)` 로 막음. 채널 단위가 아님. 게시물 P0 핫픽스(`project_deliverable_post_url_dup_bug`)는 인플 재제출 로직만 바꿨고 인덱스/RPC 중복 단위는 URL 그대로.
  - → 게시물 채널 드롭다운을 비활성하면 "같은 채널 다른 URL"(RPC 가 허용하는 동작)까지 UI 가 과차단하므로, **표식만** 하고 비활성은 안 함. 최종 가드는 RPC.
- **리뷰이미지 = 채널 단위 확정.** 인덱스 `deliverables_review_image_app_channel_uniq ON (application_id, post_channel) WHERE kind='review_image'` (마이그레이션 158) + RPC 가드와 일치 → 이미 제출된 채널 **드롭다운 비활성**.
- **영수증 = 중복 가드 없음** → 비활성·표식 안 함. 안내 박스에 "N건 (검수대기 M건)" 만 표시.
- **조회 시점:** 인플(응모건) 선택 직후 1건만 비동기 조회(fire-and-forget). 모달 전체 응모건 prefetch 안 함(대량 방지). `selectAdminProxyInf` 는 동기 유지하고 `_loadAdminProxyExisting` 만 async.
- **stale 대비:** 안내는 사전 보조일 뿐, RPC 23505 가 최종 방어선. 실패 토스트에 "「결과물 검수」에서 처리" 행동 안내를 덧붙여 보강.
- **DB 변경 없음.**

### 영향 파일
- `dev/lib/storage.js` — `fetchDeliverablesByApplication` 추가
- `dev/js/admin-deliverables.js` — `_loadAdminProxyExisting`/`_renderAdminProxyExistingBox`/`goToDelivReviewFromProxy` 추가, `selectAdminProxyInf`·채널 옵션 2종·폼 리셋 2종·실패 토스트 수정
- `dev/admin/index.html` — `#adminProxyExistingBox` 컨테이너 추가
- `dev/css/admin.css` — `.admin-proxy-existing-box` 스타일 추가
