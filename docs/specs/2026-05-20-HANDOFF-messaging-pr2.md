# HANDOFF — 응모건 메시지 PR 2 (관리자 발신 + GNB + 알림)

> **작성일**: 2026-05-20 (PR 1 개발서버 배포·검증 완료 직후)
> **인수 대상**: 새 개발 세션 (`/새세션 application-messaging-pr2` 권장)
> **원본 사양서**: `docs/specs/2026-05-15-application-messaging.md` (전 5 PR)
> **PR 1 인수인계**: `docs/specs/2026-05-18-HANDOFF-application-messaging.md`
> **메모리**: `project_messaging_pr1.md`

---

## 0. PR 1 완료 상태 (그대로 두고 PR 2 위에 쌓기)

- **PR #236·237·238·239 모두 dev 머지 + 개발서버 배포 + 개발 DB 적용 완료. qa PASS 6/0**
- 마이그레이션 **144** 개발 DB 적용됨 (테이블 5개 + 마스킹 조회/발송/읽음/회수 RPC + Storage 버킷 + lookup `message_hide_reason` 시드)
- 패치 `supabase/patches/2026-05-20-msg-42702-hotfix.sql` 개발 DB 적용됨 (42702 핫픽스)
- 인플루언서 화면: `dev/js/messaging.js`(모달+라이트박스) + `dev/lib/image-compress.js` + storage.js 함수 7개 + 응모이력 메시지 버튼/배지 + i18n `messaging.*`
- **운영 DB·main 미적용** — 운영 배포는 PR 5 약관 D-7 사전 통지와 함께 (현재 보류)

---

## 1. PR 2 범위 (사양서 §5-3, §5-4, §3-4, §3-5)

PR 1 에서 **의도적으로 PR 2 로 미룬 것 포함**:

| 항목 | 내용 |
|---|---|
| 관리자 사이드바 「메시지」 페인 | 받은편지함 — 미응대 건 배지 + 캠페인·인플루언서 필터 + 미응대/미열람 토글 + 최근 6개월 기본 (§5-4) |
| 응모 행 「메시지」 버튼 | 신청 관리·캠페인별 신청자·결과물 관리 페인 응모 행에 버튼 + 본인 미열람 배지 (§5-3) |
| 관리자 메시지 모달 | 인플 화면과 같은 게시판형, **관리자 답장 가능**. 한국어 UI. 진입 시 자동 읽음 처리 + 응대 완료 마킹 (§5-3) |
| 강제 숨김 / 복구 | campaign_admin 이상 강제 숨김(카테고리+메모), super_admin 복구 + 숨김 이력 패널 (§3-5 ①) |
| **GNB 「メッセージ」 메뉴 (인플)** | §5-2 — PR 1 에서 보류. 전체 미읽음 배지 + 미읽음 우선 응모건 리스트 |
| **알림 `message_received` (인플)** | §5-5 — PR 1 에서 보류. 관리자 답장 시 인플에게 앱 내 알림 |

---

## 2. PR 1 에서 넘어온 필수 선결 작업 (놓치기 쉬움)

### 2-1. `send_application_message` RPC 에 알림(notification) 생성 추가
- 현재 144 의 send RPC 는 **notification INSERT 가 없음**. 관리자가 답장해도 인플에게 앱 내 알림이 안 감
- PR 2 에서 send RPC 수정: `v_sender_kind='admin'` 일 때 `notifications` 에 `kind='message_received'` INSERT (인플루언서 대상)
- 마이그레이션으로 `CREATE OR REPLACE` (patches 아님 — PR 2 정식 마이그레이션)

### 2-2. `notifications` 테이블 kind CHECK 제약 확장 ⚠️
- 현재 `notifications.kind` CHECK 는 `deliverable_rejected / deliverable_changed / deliverable_approved` 만 허용 (추정 — **시작 시 실제 제약 정의 확인 필수**)
- `message_received` 추가하려면 **144 의 lookup_values 제약 확장과 똑같은 패턴**으로 CHECK 제약 DROP+ADD (기존 값 전체 + message_received). 누락 시 23514
- 인플 알림 모달(`dev/js/notifications.js`)에 `message_received` kind 렌더 분기 추가 + 클릭 시 메시지 모달 열기

### 2-3. PR 2 신규 RPC (사양서 §4-3, 144 에 없음)
- `mark_application_resolved(application_id)` — 수동 응대 완료
- `hide_application_message(message_id, reason_code, reason_memo)` — 강제 숨김 (campaign_admin+)
- `unhide_application_message(message_id, reason_memo)` — 복구 (super_admin)
- `get_application_messages` 의 관리자 마스킹(원본+메타) 분기는 PR 1 에 **이미 구현됨** (관리자는 강제숨김·관리자회수 원본 보임)

---

## 3. 구현 메모

- **admin.js 핫스팟 회피**: 관리자 메시지 로직은 신규 `dev/js/admin-messaging.js` 분리 권장 (admin-brand.js 패턴). build.sh ADMIN_JS_FILES 등록
- **마이그레이션 번호**: 시작 직전 `ls supabase/migrations/ | tail -5` 확인. 현재 마지막 144 → **145 부터** (방문자 통계 사양서도 144~ 잡았으나 메시지가 144 선점했으니 방문자 통계는 더 뒤)
- **storage.js 재사용**: PR 1 의 fetchApplicationMessages/sendApplicationMessage/markApplicationMessagesRead 그대로 관리자도 사용 (RPC 가 is_admin 으로 분기). 관리자 전용 추가: hide/unhide/markResolved/adminUnreadCounts(이미 144 에 함수 있음)
- **i18n**: 관리자 UI 는 한국어 (인플 messaging.* 키와 별개로 관리자 화면 텍스트는 한국어 하드코딩 — 관리자 페이지 규칙)
- 미사용 i18n 키 `messaging.unreadBadge`(ja/ko) 는 PR 2 GNB 배지용으로 이미 추가돼 있음

## 4. 검증 교훈 (PR 1 에서)
- **신규 DB 함수는 정적 리뷰·적용 성공만으론 부족 → 1회 실제 스모크 호출 필수** (`feedback_db_function_smoke_test`). PR 1 에서 42702(`column id ambiguous`)가 적용 후 런타임에야 발견됨
- `RETURNS TABLE` OUT 파라미터 vs 본문 컬럼 충돌 → `#variable_conflict use_column`. nested DECLARE 평탄화
- 새 lookup/notifications kind 추가 시 CHECK 제약 확장 동반 필수

## 5. 시작법
1. 메인 폴더에서 `/새세션 application-messaging-pr2`
2. 새 터미널에서 worktree 폴더 진입 → 세션 시작
3. PR 1 처럼 단계 분할: ① DB(마이그레이션 145: send RPC 알림 + notifications kind + hide/unhide/resolve RPC) → ② 관리자 메시지 페인/모달/응모 행 버튼 → ③ GNB 메뉴 + 알림 연동 → reviewer → 개발서버 배포 → qa(full, 관리자 플로우)
4. 각 단계 reverb-supabase-expert(DB)·reverb-reviewer(commit 직전)·reverb-qa-tester(배포 후) 호출
