# 관리자 응모건 메시지 — 「내가 보낸 순」 정렬 + 달력 기간 필터

**작성일:** 2026-06-04
**작성 세션:** 기획/설계
**상태:** 초안 (사용자 정책 확정, 개발 미착수)

---

## 배경 (사용자 요청)

> "메시지 기능에서 관리자 담당자가 최근에 내가 보낸 메시지를 찾는 데 어려움이 있다. 메시지 목록이 많아지면서 **내가 최근에 보낸 대화를 찾고 싶다**."
> "최근 메시지 순을 **날짜로도 선택**할 수 있게 가능한가?"

받은편지함 대화가 쌓이면서, 관리자 담당자가 **자기가 최근 답장 보낸 대화**를 다시 찾기 어렵다. 또 기간을 상대값(6개월 등)이 아니라 **달력으로 정확히 지정**해 그 기간 대화만 보고 싶다.

**사용자 확정 정책 (AskUserQuestion 4회):**
1. "내가 보낸"의 범위 = **로그인한 본인 관리자**가 보낸 것만 (담당자별로 자기 발신 추적)
2. 형태 = 받은편지함에 **「내가 보낸 순」 정렬 필터 추가** (기존 목록 구조 유지, 보는 순서만 추가)
3. 캠페인 구분 = **캠페인 구분 없이 전체에서 모아보기** + 각 대화 카드에 **캠페인명·브랜드 라벨 표시**, 좌측 캠페인 목록은 **그대로 유지**
4. 날짜 = **달력으로 기간 지정**(○월○일 ~ ○월○일 범위 선택)

---

## 현재 상태 (작성일 2026-06-04 기준 — planning.md 규칙 A)

### 관련 코드·DB·UI 진입점

**받은편지함 3단 페인** (`dev/js/admin-messaging.js`, `#adminPane-messages`, HTML `dev/admin/index.html` 1185~1258)
- 구조: 좌 `#inboxCampaigns`(캠페인 목록) → 중 `#inboxThreads`(선택 캠페인의 대화 상대 목록) → 우 `#inboxThreadView`(대화 내용)
- 로드: `loadMessagesInbox()` (58) → `refreshInboxData()` → `renderInboxCampaignList()` (143) / `renderInboxThreadList()` (202)
- **현재 정렬**: `_inboxSort` — 「최근 메시지순」 또는 「미응대 우선」 2종. 기준 컬럼은 `last_message_at`(발신자 무관)
- **현재 기간 필터**: `fetchAdminMessageThreads({sinceMonths:6})` — 상대 기간(기본 6개월). 달력 절대 날짜 지정 없음
- 검색: 중 패널 인플 이름·이메일·캠페인명 / 우 패널 대화 내용 텍스트
- 일괄발송 「발송 이력」 탭(`#inboxTabBroadcasts`)은 별도 — 일괄 그룹 전용

**데이터 접근** (`dev/lib/storage.js`)
- `fetchAdminMessageThreads(opts)` (2697) — 뷰 `application_message_summary` 조회, `message_count>0` + `last_message_at` 내림차순 + 최근 N개월
- `fetchMessagePreviews(appIds)` (2729) — `application_messages` 직접 조회, 대화별 **최근 1건** 미리보기({body, sender_kind, created_at})
- `fetchAdminMessageUnreadCounts()` (2684) — 본인 미열람 count 맵

**DB**
- 뷰 `application_message_summary`(security_invoker): `application_id`·`influencer_id`·`campaign_id`·`message_count`·`unread_for_influencer`·`unresolved_for_admin_team`·`last_message_at`. ❌ **발신자별(본인 admin) 마지막 발신 시각 컬럼 없음**
- 테이블 `application_messages`: `sender_kind`('influencer'|'admin')·`sender_id`(발신 관리자 auth id)·`sender_name`·`created_at`·`broadcast_id`. RLS SELECT 본인 응모건 또는 `is_admin()` → **관리자는 본인 발신 메시지 직접 조회 가능**

### 이 제안과 충돌 가능성 있는 기존 동작
- **정렬을 바꾸지 않고 추가** — 기존 「최근 메시지순/미응대 우선」은 그대로 두고 「내가 보낸 순」을 옵션으로 추가. 응대 관리 흐름(미응대 우선)을 깨지 않음.
- 좌측 캠페인 목록·일괄발송 탭은 변경 없음.
- 받은편지함 lazy-load(IntersectionObserver) 패턴 — 정렬·필터 변경 시 **sentinel 리셋 필수**(`.claude/rules` 관리자 리스트 규칙).

### 미해결 백로그·관련 작업
- 응모건 메시지 본체: `docs/specs/2026-05-15-application-messaging.md` (운영 배포 완료 2026-05-28, 메모리 [[project_message_faq_realdata]])
- 일괄발송 PR3/3-1: `bulk-redesign` worktree, 마이그레이션 167·168·169 선점·운영 보류 ([[project_bulk_message_pr3]])

---

## 의심·경우의 수 (planning.md 규칙 B)

1. **(기술) 본인 마지막 발신 시각 산출** — 뷰에 없음. 두 가지 방법:
   - (A, 권장 1차) **DB 변경 없음** — `storage.js` 새 함수로 `application_messages` 에서 `sender_id = 본인` 행의 `application_id`별 최신 `created_at` 집계(클라에서 dedupe). 관리자 SELECT 권한 있음.
   - (B) 새 원격 호출 함수(RPC) `get_admin_sent_threads(from, to)` — 본인 발신 대화 + 캠페인 join + 최신 발신 시각을 서버에서 한 번에. 데이터 많아져 (A) 성능 저하 시 승격.
2. **(UX 필수) 좌측 캠페인 선택과의 충돌** — 「내가 보낸 순」은 전체 평면이라 캠페인 선택이 무의미. 켜면 좌측을 **흐리게(비활성) + 「전체 대화에서 내가 보낸 순으로 표시 중」 안내**, 다른 정렬로 바꾸면 캠페인 선택 복귀. 좌측을 없애지 않음(사용자 확정).
3. **(UX) 빈 상태** — 신규 담당자처럼 본인이 한 번도 안 보낸 경우 목록 0건 → 「아직 보낸 대화가 없습니다」 안내 문구 필수(텅 빈 화면 금지).
4. **(데이터) 일괄발송 포함 여부** — 일괄발송도 `sender_id=본인`이면 본인 발신으로 잡힘 → **포함**. 명시(혼동 방지). 회수된 메시지는 마스킹 규칙 따름.
5. **(성능) 평면 목록 길이** — 캠페인 무관 전체라 길어질 수 있음 → lazy-load 유지 + 날짜 범위 필터로 자연 축소.
6. **(UX) 날짜 범위 기준 컬럼** — 날짜 필터가 「대화의 마지막 메시지 시각」 기준인지 「본인 발신 시각」 기준인지. 정렬 모드와 일관되게: 「내가 보낸 순」 모드에선 본인 발신 시각 기준, 그 외 모드에선 `last_message_at` 기준 권장.
7. **(권한·환경) 본인 식별** — `auth.uid()` = 현재 로그인 관리자. campaign_manager 도 메시지 발신 가능하므로 모든 관리자 등급에서 동작해야.

### 현재 구현과 충돌하는 지점
- 확인된 직접 충돌 없음. 정렬·필터 추가형이라 기존 데이터·RLS·트리거 영향 없음. (1차 방법 A 채택 시 DB 무변경)

### 의도 모호점
- 날짜 범위 필터를 **모든 정렬 모드 공통**으로 둘지, 「내가 보낸 순」에만 둘지 — 공통(일반 기간 필터)로 두는 게 자연스러움(아래 설계 반영). 구현 중 사용자 재확인 가능.

---

## 제안 / 설계

### 기능 1 — 「내가 보낸 순」 정렬 필터
- 받은편지함 정렬 선택지에 **「내가 보낸 순」** 추가 (기존 「최근 메시지순」·「미응대 우선」과 나란히)
- 선택 시:
  - 좌측 캠페인 선택 무시 → **전체 대화 중 본인(`auth.uid()`)이 발신한 적 있는 대화만**, **본인 마지막 발신 시각 내림차순**
  - 중 패널 각 대화 카드에 **캠페인명 + 브랜드 라벨** 한 줄 추가(평면 목록 식별)
  - 좌측 캠페인 목록은 흐리게 + 안내 문구, 다른 정렬 복귀 시 정상화
- 본인 발신 시각: 1차 **방법 A(클라 집계, DB 무변경)**

### 기능 2 — 달력 기간 필터
- 받은편지함 상단에 **flatpickr 기간 선택**(시작일~종료일) 추가
- 기존 상대 기간(6개월 등)과 공존 또는 대체(구현 시 단순화 판단) — 기본은 기존 6개월 유지, 사용자가 달력으로 범위 지정 시 그 범위 우선
- 기준 컬럼: 「내가 보낸 순」 모드 = 본인 발신 시각 / 그 외 = `last_message_at`
- 구현: `fetchAdminMessageThreads` 에 `fromIso`/`toIso` 파라미터 추가(`application_message_summary.last_message_at` 에 `.gte/.lte`) — DB 무변경

### 공통
- 정렬·날짜 변경 시 **lazy-load sentinel 리셋** 필수
- 빈 상태 안내 문구

### PR 분할
- **PR 1 — 「내가 보낸 순」 정렬 + 캠페인 라벨** (`admin-messaging.js`, `storage.js`). DB 무변경(방법 A).
- **PR 2 — 달력 기간 필터** (`admin-messaging.js`, `storage.js`, flatpickr). DB 무변경.
- 두 기능 모두 받은편지함 필터 영역이라 한 사이클에 묶어도 무방. UI 변경이므로 reverb-planner 사전 호출 + reverb-qa-tester Light(S5+S6).
- ⚠️ 마이그레이션은 1차 설계상 **불필요**. 방법 B(RPC) 승격 시에만 채번(167 메인 / 168·169 bulk-redesign / 170 brand-company-linking 사양서 예정 — 구현 시점 `ls migrations` 확인).

---

## 사용자 확인 필요 (개발 착수 전 — 경미)
- 달력 기간 필터를 모든 정렬 모드 공통으로 둘지(권장: 공통). 미응답 시 공통으로 진행.

---

## 구현 결과

**구현일:** 2026-06-04
**관련 커밋·PR:** feature/admin-msg-sent-filter (dev PR)

### 초안 대비 변경 사항
- 추가된 것: 없음 (사양서 설계 그대로)
- 빠진 것: 없음
- 달라진 것: PR 1·2를 **한 사이클에 묶어** 구현. 달력 기간 필터는 기존 상대기간 select와 **공존**(달력 지정 시 우선, 기본 6개월 유지)

### 구현 중 기술 결정 사항
- **본인 발신 시각 = 방법 A(클라 집계, DB 무변경)**: `fetchAdminSentAtMap()`이 `application_messages`에서 `sender_id=auth.uid()`+`sender_kind='admin'` created_at 내림차순 → application_id별 최신 Map. 일괄발송도 본인 발신이면 포함
- **날짜 기준 = `last_message_at` 모든 모드 공통**(1차 단순화). sent 모드 카드 표시·정렬 시각만 본인 발신 시각
- **lazy-load 무관**: 받은편지함 중 패널은 전체 innerHTML 교체 → sentinel 리셋 불필요
- sent 모드: `_inboxSelectedCampaign=null`(평면) + 좌측 `inbox-camp-disabled`(흐리게)+안내, 다른 정렬 복귀 시 정상화
- 달력: flatpickr range(loadMessagesInbox 1회 init), 2개 선택 fromIso(00:00)/toIso(23:59), clear 시 null. campaign_manager 포함 전 관리자 동작
