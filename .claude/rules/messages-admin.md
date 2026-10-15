---
description: 응모건 메시지 — 표·함수·일괄 발송·후속 발송 사슬·회원 배지 조회 시간 초과
paths:
  - "dev/js/admin-messaging.js"
  - "dev/js/messaging.js"
  - "supabase/migrations/*message*"
  - "supabase/migrations/*broadcast*"
  - "supabase/migrations/*bulk*"
---

# 응모건 메시지 (관리자·서버) (CLAUDE.md 에서 옮겨 옴 — 2026-10-15)

#### 응모건 메시지 (인플루언서 ↔ 관리자, 마이그레이션 144·145)
**현재 원본 번호**
- `send_application_message` — **509**(베이스 323. `CREATE OR REPLACE` 로만) · 「응모 끝나고 90일이면 회원은 못 씀」 판정은 **`_application_message_writable`(509) 한 곳**(종료 시각은 `_application_message_ended_at`) — 회원 화면은 `get_my_application_message_status()`(509, 본인 응모 전부 jsonb)로 「지난 문의」를 가른다. 🔴 90일을 화면에서 계산하지 않는다. 배포는 509 먼저

> 응모건 단위 양방향 메시지 — 받은편지함 3단 페인 `#adminPane-messages`·강제 숨김/복구·응대 완료·알림 `message_received`. **캠페인 단위 일괄 발송도 운영 가동 중** — 대상 필터 + 발송 이력·일괄 회수. 관리자 로직 `dev/js/admin-messaging.js`. 사양서 `docs/specs/2026-05-15-application-messaging.md`·`docs/specs/2026-06-02-bulk-message-target-redesign.md`
> 🔴 **약관 게이트가 언제·무엇을 근거로 풀렸는지 어디에도 없다** — 개인정보처리방침은 **「문의하기」(인플루언서 → 운영팀) 기준으로** 갱신됐고, **관리자 → 인플루언서 일괄 발송까지 덮는지는 확인되지 않았다.** 판단이 필요하면 `/약관확인`
> ⚠️ 첨부·임의 다중선택(3페인 체크박스)·메일 지연 큐(PR 4)는 **미구현**
  - **후속 발송 — 「같은 조건으로, 아직 안 받은 사람에게만」**(마이그레이션 388~391·393): 진입점은 **발송 이력 상세의 「아직 안 받은 대상에게 추가 발송」 버튼**. ⚠️ **못 누를 때도 감추지 않고 회색으로 두고 이유를 말한다**. 창은 **두 수를 같이** 말한다(N건 중 아직 안 받은 M건). 🔴 **「명」이 아니라 「건」이다**(한 사람이 여러 건). 한도 200건을 넘으면 **막지 않고** 남은 건수를 말한 뒤 200건을 보내고 **방금 만들어진 발송을 연다** — 🔴 「이 발송에서 다시 누르세요」는 **틀린 안내**(보내는 순간 사슬의 마지막이 아니게 되어 회색이 된다). ⚠️ 조건 스냅샷은 **그대로** 넘겨 부모의 판을 물려받는다(새로 찍으면 사슬의 판 표시가 깨진다). ⚠️ 발송 뒤 `refreshInboxData()` 도 부른다(미응대 배지). ⚠️ **「전체 회수」는 사슬을 안 따라간다** — `withdraw_broadcast`(167)는 발송 1건만, 추가 발송은 각각 회수(확인창이 말한다). 토대: `application_message_broadcasts.parent_broadcast_id` 로 사슬을 잇고 대상 고르기가 **사슬 전체가 이미 보낸 응모건을 뺀다**(`resolve_bulk_recipients` 의 `p_exclude_broadcast_id`). ⚠️ **응모건 단위로 뺀다**(사람 단위면 다른 캠페인 건까지 빠진다). ⚠️ **「이미 받은 사람」에 새 표를 안 만든다** — `application_messages` 의 `broadcast_id` 가 이미 그 기록이다. 🔴 **사슬은 줄이어야 하고 서버가 거부로 강제한다**(`send_application_message_bulk` — 현재 원본 **417**, 베이스 390. 417 이 부모 행에 `FOR UPDATE` 잠금 — 3종 — ①남의 발송 ②사슬의 마지막이 아님 ③부모가 회수됨). 🔴 **②는 자손 전체를 본다** — 한 겹만 보면 「1차 → 2차(회수) → 3차」에서 1차가 통과해 형제가 생기고 **겹쳐 받는다**. ⚠️ **「마지막 세기」와 「뺄 집합」은 기준이 다르다** — 마지막 세기는 회수된 것을 **건너뛰고**, 뺄 집합은 회수된 발송의 수신자도 **뺀다**(회수는 가리는 것). ⚠️ **「마지막」은 시각이 아니라 깊이로 센다**. ⚠️ 판 표시 `v`(`BULK_FILTER_VERSION`, admin-messaging.js) — **화면 열쇠말을 고치면 사람이 올려야 한다**(안 올리면 옛 이력 조건이 조용히 잘못 재현). 판 0 이력은 막지 않는다. 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md`
- **회원 배지 조회 시간 초과**(사양서 `docs/specs/2026-09-02-influencer-unread-badge-timeout.md`): ①`fetchInfluencerUnreadMessageThreads` 는 **실패 `null`, 0건 `[]`** 이고 실패 때 지난 값을 유지한다. ②세 표의 관리자 정책 `is_admin()` 이 **행마다** 평가돼 느렸다 → **415** 가 그 세 SELECT 정책을 `(SELECT public.is_admin())` 로 감쌌다(137 이 `auth.uid()` 에 한 방식). ⚠️ **감싸지 않은 `is_admin()` 정책이 운영에 84개 더 있다** — 같은 증상이면 이 방식으로. ⚠️ 회원 역할 실행 계획은 SQL 편집기에서 **`set local role authenticated`** 를 넣어야 정책이 평가된다
- `application_messages` — `application_id` FK CASCADE(**475 부터 비어 있을 수 있다** — 아래 일반 문의 행은 `influencer_id` 만 가진다. 검사 제약 `application_messages_owner_exactly_one` 이 둘 중 정확히 하나를 강제), `sender_kind`(influencer|admin), `body`, `attachments jsonb`, `read_by_influencer_at`, 강제숨김 4컬럼, 본인회수 2컬럼, 메일큐 3컬럼, `broadcast_id` FK. RLS SELECT 본인 응모건 또는 `is_admin()`, INSERT/UPDATE 는 RPC 만
- 부속 테이블: `application_message_admin_reads` / `application_message_resolutions` / `application_message_broadcasts` / `application_message_hide_history`(append-only super_admin)
- 뷰 `application_message_summary`(security_invoker) + RPC: `get_application_messages`(역할별 4종 마스킹. ⚠️ **326 으로 `sender_id` 추가** — **관리자가 부를 때만** 채운다. 없으면 **다른 관리자 메시지에도 「회수」 버튼이 떠 누르면 반드시 실패**. ⚠️ 개별 회수(`withdraw_own_message`)에는 **최고 관리자 예외가 없다** — 일괄 회수의 예외를 옮기면 버튼만 뜨고 실패한다)·`send_application_message`(rate limit 100/h + 자동응대 + 관리자 발신 시 `message_received`)·`mark_application_messages_read`·`withdraw_own_message`(25분)·`mark_application_resolved`·`hide_application_message`(campaign_admin)·`unhide_application_message`(super_admin). 모두 SECURITY DEFINER
- lookup `message_hide_reason` 7종 + Storage 버킷 `application-message-attachments`(비공개). 첨부는 클라 압축(`dev/lib/image-compress.js`, HEIC→JPEG/2048px) 후 업로드
