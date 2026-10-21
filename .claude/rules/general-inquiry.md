---
description: 일반 문의 창구 — 서비스 문의 여러 대화·관리자 받은편지함 탭·같은 표에 사는 일반 문의 행
paths:
  - "dev/js/messaging.js"
  - "dev/js/admin-messaging.js"
  - "dev/js/notifications.js"
  - "supabase/migrations/*general_inquiry*"
  - "supabase/migrations/479_*"
  - "supabase/migrations/482_*"
  - "supabase/migrations/483_*"
---

# 일반 문의 창구 (CLAUDE.md 에서 옮겨 옴 — 2026-10-15)

#### 일반 문의 창구 (응모와 무관한 회원 ↔ 운영팀, 마이그레이션 475~483 — ★운영 반영 2026-10-06 · 서비스 문의 여러 대화 504~508 도 운영 반영 — 2026-10-21 운영 카탈로그로 확인)
> 햄버거 「お問い合わせ」 → `#page-inquiry` 탭 둘(「キャンペーンのお問い合わせ」 = 대화가 시작된 응모만 + 「新しくお問い合わせ」 응모 고르기 / 「サービスのお問い合わせ」). 대화 화면은 `#page-messages` 를 **재사용**(`_msgMode` 로 갈림 — 나갈 때 정리 함수가 응모건 모드로 되돌려야 한다). 관리자 받은편지함은 탭 셋(캠페인 문의 / 서비스 문의 / 일괄발송 이력[캠페인관리자 이상]). 사양서 `docs/specs/2026-05-21-general-inquiry-desk.md`(「구현 결과」) · 작업표 `…-breakdown.md`

**현재 원본 번호**
- `send_general_inquiry_message`(6인자) · `reopen_general_inquiry_thread` · 뷰 `general_inquiry_thread_summary` — **508**(베이스 505·505·506. 🔴 발신은 `DROP` 후 `CREATE` 라 실행 권한 회수를 다시 건다) · `update_general_inquiry_thread_title` · `_general_inquiry_open_limit`(상한 5 — 숫자는 여기 한 곳) — **508** 신설
- `get_general_inquiry_messages` · `mark_general_inquiry_messages_read` · `general_inquiry_admin_unread_counts` · `purge_audit_data_all` — **505**(베이스 478·478·478·480. 🔴 앞 셋은 `DROP` 후 `CREATE`) · `close_general_inquiry_thread` · `_general_inquiry_resolve_caller` — **505** 신설.

- **서비스 문의 여러 대화**(504~508, 사양서 `docs/specs/2026-10-06-service-inquiry-threads.md` 맨 위 「🔄 설계 개정」 절 우선 · 작업표 `…-breakdown.md`): 대화 표 `general_inquiry_threads`(열림·닫힘 · 제목 `title`(1~40자, 운영팀만 고침)·제목 번역 · 새 문의 중복 방지 `client_token` · **회원이 여는 열린 대화는 5개까지** — 508) + 메시지 칸 `general_thread_id`(응모 칸이 빈 행은 필수 — 검사 제약) + 뷰 `general_inquiry_thread_summary`(대화 단위). 🔴 **회원·운영팀·닫기·다시 열기가 같은 회원 단위 잠금**을 쓴다. 회원 글은 **회원이 연 그 대화**로 — 닫힌 지 24시간 안이면 다시 열고(상한에 든다), 지났으면 `thread_closed`. 새 문의는 토큰 + 제목 필수(`title_required`·`title_too_long`·`too_many_open_threads`). 대화 id·토큰 둘 다 없는 발신은 **옛 화면 호환 갈래**(후속 정리에서 삭제). 운영팀은 새 대화를 못 만들고, 대화 id 없이 보내면 열린 대화가 정확히 하나일 때만(0 `no_open_thread` · 2+ `thread_required`). 옛 응대 완료 표(477)·옛 뷰(481)는 화면 조각이 다 나갈 때까지 남긴다
- **관리자 받은편지함(서비스 문의 탭)은 대화 한 줄씩**(조각 4): 대화 열쇠가 둘 — `_admMsgGeneralThreadId`(대화) · `_admMsgGeneralId`(그 대화의 회원 — 첨부 경로·숨김 이력용), 늘 함께 차고 함께 빈다. 「응대 완료」 = 대화 닫기(화면이 본 마지막 글 id 를 넘긴다). 🔴 미응대 수 세 자리(사이드바·30초 갱신·탭 괄호)는 모두 `_genNeedsReply`(`fetchGeneralInquiryNeedsReplyCount` — 기간 창 없음, **사람 수가 아니라 대화 수**). 옛 회원 단위 조회 함수 여섯(`fetchAdminGeneralInquiryThreads` 등)은 호출 0건 — 운영 반영 뒤 정리
- **같은 표에 산다** — 일반 문의는 새 표가 아니라 `application_messages` 에 `application_id` NULL + `influencer_id` 로 들어간다. 🔴 **그래서 응모건을 세는 자리가 일반 문의 행을 딸려 올 수 있다** — 479(관리자 안 읽은 수)·480(감사용 청소)·482(탈퇴 파기 셋, `INNER` → `LEFT JOIN`)가 그 자리들을 고쳤다. 새로 메시지를 세는 조회를 만들면 **`application_id IS NOT NULL` 이 필요한지** 먼저 본다
- 회원 정책 넷 + 첨부 경로 판정 `_general_inquiry_path_is_own`(476, 경로 `general/{회원id}/{파일}`) · 응대 완료 `general_inquiry_resolutions`(477) · 함수 다섯(478 — 조회·발송·읽음·응대 완료·관리자 안 읽은 수. 응대 완료 외 넷은 505 로 대체) · 뷰 `general_inquiry_message_summary`(481). ⚠️ **뷰는 메시지 표 기준** — 회원 표 기준이면 관리자의 회원 표 읽기가 312 로 막혀 **관리자에게 빈 뷰**가 된다
- **483 은 이미 운영에 있다**(창구와 별개) — 본인이 보낸 첨부의 조회 정책. 저장소 삭제는 **조회 정책이 보이는 행만** 지우므로, 이게 없으면 「회수」가 성공해도 파일이 남는다(응모건 메시지도 같은 결함이었다). 폴더 소유까지 확인
- 사이드바 메시지 미응대 수는 **두 종류 합산이고 세는 자리가 둘**(`updateInboxSidebarBadge` · 30초 `refreshMsgBadgesLight`) — 한쪽만 고치면 30초 뒤 숫자가 되돌아간다
- 알림은 종류가 `message_received` 그대로이고 **`ref_table='general_inquiry'` 로만 갈린다** — 그 분기가 응모건 분기보다 **앞에** 있어야 한다(`notifications.js`, 뒤에 두면 응모건 화면으로 간다). 탈퇴 화면의 연락 안내는 이 창구로 간다. **로그인할 수 없는 자리**(로그아웃된 확정 회원 안내·가입 실패 안내)는 LINE 유지
