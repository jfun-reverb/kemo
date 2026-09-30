---
description: 회원 탈퇴 — 신청·상태 전이·예약 실행·예정일 메일
paths:
  - "supabase/functions/notify-withdrawal-scheduled/**"
  - "supabase/functions/purge-withdrawal-*/**"
  - "supabase/migrations/*withdraw*"
  - "supabase/migrations/*purge_withdrawn*"
  - "dev/js/admin-influencers.js"
---

# 회원 탈퇴 (마이그레이션 345~367)

> ★ 회원·관리자 화면 모두 운영에 있고 **회원이 마이페이지에서 직접 탈퇴할 수 있다.** 작업표 `docs/specs/2026-08-19-member-withdrawal-breakdown.md`, 사양서 `docs/specs/2026-08-18-member-withdrawal.md`, 조사 `docs/research/2026-08-19-withdrawal-benchmark.md`. 이력은 `docs/CLAUDE-ARCHIVE.md` §12
> - **예약 6종(운영)**: 재가입 해시 정리 04:30 · 상태 전이 04:45 · 페이팔 파기 05:00 · 영수증·인증샷 파기 05:15 · **메시지 첨부 파기 05:30** · 예정일 메일 09:00 (한국·일본 시각)
> - **개발**은 메일 예약만 제외. 365 는 개발 주소로 바꿔 넣었다 — 그대로 넣으면 **개발 예약이 운영 함수를 매일 부른다**
- `withdrawal_requests` — `status CHECK(pending_payout|scheduled|done|cancelled)` · `reason_code`(**선택**) · `reason_note` · `scheduled_date` · `completed_at`(**파기·재가입 차단 기준점**) · `requested_by_kind(self|admin_proxy|admin_forced)`(356) · `uncancelled_count` · 행사 예약 취소 성공/실패·메일 발송 시각·시도 횟수 칸. **활성 행 유일 색인**은 `pending_payout`·`scheduled` 에만(재신청은 새 줄). RLS 조회 본인+관리자, **쓰기 정책 없음**
- `cancel_withdrawal()`(현재 원본 **356**) — 본인 신청과 **관리자 대행(`admin_proxy`)** 을 되돌린다. ⚠️ **`admin_forced`(약관 제6조 3항)만 거부** — 안 막으면 당사자가 스스로 복구한다. ⚠️ **대행은 5일 변심 유예를 뺏지 않는다**(349 → 356 이 좁힘). `done`·`cancelled` 도 거부. **철회된 응모는 안 되살아난다**(의도)
- **예정일 안내 메일**(351 + Edge Function `notify-withdrawal-scheduled`, 09:00) — 🔴 **회원에게 닿는 유일한 통지다.** ⚠️ **예약은 351 별도 파일, 운영에만**(개발에 넣으면 개발 예약이 운영 함수를 부른다). ⚠️ 메일 실패는 상태 전이를 막지 않는다(시각은 성공 뒤에만). 🔴 **확정(done)되면 대상 조회(`status='scheduled'`)에서 빠져 영영 안 나간다**(재발송 없음). 그래서 **419** 가 점검에 두 줄: 예정인데 안 나감(실패 1회 이상 **또는** **처음 발송 대상이 될 수 있었던 09:00 + 1시간** 경과 — 뒤쪽이 **예약 정지**를 잡는다. 시도 횟수는 행 처리 실패 때만 올라 파이프라인이 멈추면 영원히 0). 🔴 **그 기준은 450·451 이 고쳤다** — 「예정이 된 **날**」로 재면 **09:00 이후 예정이 된 행을 하루 동안 오탐**한다. 450 이 `withdrawal_requests.scheduled_at`(예정이 된 **시각**)을 **세 경로**(`request_withdrawal`·`request_withdrawal_for_member`·`advance_withdrawal_states`)에서 채우고 451 이 판정한다. ⚠️ **450 → 451 순서 고정** · 450 이전 행은 NULL 이라 **옛 식으로 떨어진다**(백필 안 함) / 최근 30일에 못 받은 채 확정됨(**30일 한정** — 안 자르면 경고가 영구히 켜진다). 회원 상세 탈퇴 카드에 메일 상태 한 줄(`withdrawMailLine`). 사양서 `docs/specs/2026-09-18-withdrawal-mail-alert-false-positive.md`
