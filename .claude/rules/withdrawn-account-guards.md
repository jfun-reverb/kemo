---
description: 탈퇴 확정 계정 차단 장치 — 프로필 수정·응모 삽입·행사 예약·결과물 제출을 서버가 막고 화면이 로그아웃시킨다(묶음 규칙)
paths:
  - "supabase/migrations/*withdraw*"
  - "supabase/migrations/*deadline_guard*"
  - "supabase/migrations/*event_ticket*"
  - "supabase/migrations/180_*"
  - "dev/js/auth.js"
  - "dev/js/app.js"
  - "dev/js/ui.js"
  - "dev/lib/shared.js"
  - "dev/js/admin-errors.js"
  - "dev/js/application.js"
  - "dev/js/event-ticket.js"
  - "dev/js/admin-event.js"
  - "dev/event-scan.html"
  - "dev/js/admin-influencers.js"
---

# 탈퇴 확정 계정 차단 (CLAUDE.md 회원 탈퇴 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **탈퇴 확정 계정 차단**(358 판정 함수 · 359 차단 장치 — 작업 8): 열린 세션으로 프로필을 다시 채워 **파기가 무효**가 되는 구멍을 닫는다. 막는 곳 셋 = **①프로필 수정(`influencers`) ②응모 삽입 ③행사 예약(삽입·수정)**.
  - ★ **판정이 둘이다** — `login_blocked`(확정만, 로그아웃 기준) / `write_blocked`(확정 **또는 예정일 경과**, 서버 차단 기준). 🔴 **합치면 안 된다** — 예정일 경과·예약 실행 전 구간의 회원을 로그아웃시키면 **탈퇴 취소 버튼에 닿지 못한다**. 서버가 두 값을 함께 계산한다(기기 시계로 갈리지 않게)
  - ⚠️ **부호는 `<=`** — 예약 실행(352)과 문자 그대로 같아야 한다. `<` 면 예정일 당일 배치 전까지 응모가 열리고 그 응모가 살아 있는 채 파기된다
  - 🔴 **차단 장치 셋 모두에 통과 조항 둘**(`auth.uid() IS NULL`·`is_admin()`). **지우면 파기가 자기 자신에게 막혀 확정이 무한 롤백**되고, 관리자 겸직 회원은 **영구 반신불수**가 된다
  - 🔴 **행사 장치는 「대기자 승격(`waitlist`→`confirmed`)은 무조건 통과」 조항이 따로 있다** — 그 수정은 **취소한 사람의 로그인 정보로** 실행돼, 막으면 **남의 취소까지 롤백**되고 **영구히 막힌다**(좌석은 새벽 배치가 정리)
  - ⚠️ **현장 입장 확인은 상태 필터로 안 빠진다**(상태 `confirmed` 유지, 시각만 변경) — **관리자 통과 조항**으로 지나간다
  - ⚠️ 트리거 `trg_account_withdrawn_guard` — 알파벳 순으로 **연령·마감보다 먼저** 실행돼 **마감 가드(272)보다 앞**이라 「마감 지남」이라는 엉뚱한 이유가 뜨지 않는다. ⚠️ 359 헤더의 「352 가 생년월일도 비운다」는 틀렸다 — **352 는 생년월일·성별을 안 비운다**(C-9). 순서는 그대로 지킨다
  - ⚠️ **안 막는 것 = 응모건 메시지 발송**(막으면 운영팀에 닿을 수단이 0 — **구멍임을 인정, 작업 2에서 재판단**) · **응모 취소**(의도). **결과물 제출·수정은 422 가 막는다**(C-7, 같은 패턴·통과 조항. ⚠️ **INSERT OR UPDATE** — 재제출은 UPDATE 라 INSERT 만 막으면 3종 중 2종이 통과). 🔴 **확정 회원의 두 번째 탈퇴 신청도 422 가 막는다**(C-6 — `withdrawal_requests` 삽입 트리거 `already_withdrawn`, 통과 조항 없음. 357 의 신청 함수는 활성 신청만 본다. 거부 코드는 `account_withdrawn` 과 같은 두 곳[ui.js·shared.js]에 등록. 관리자 카드는 확정 회원에게 「대신 신청」을 안 그린다)
  - 화면: `enforceWithdrawalLogout()`(auth.js)이 부팅·로그인 시 확정 계정을 로그아웃시키고 **로그인 화면에 사라지지 않는 안내**를 남긴다. ⚠️ 조회 실패는 **아무것도 안 한다**(서버가 최종 방어선). 거부 코드 `account_withdrawn` 은 **ui.js 와 shared.js 두 곳에 등록해야 한 세트**다
