---
description: 응모건 메시지(회원 쪽) — 페이지 재사용·취소 응모 읽기 전용·자동 번역 파이프라인(묶음 규칙)
paths:
  - "dev/js/messaging.js"
  - "dev/js/admin-messaging.js"
  - "dev/js/app.js"
  - "dev/js/notifications.js"
  - "dev/js/mypage.js"
  - "dev/lib/storage.js"
  - "dev/lib/image-compress.js"
  - "supabase/functions/translate-message/**"
  - "supabase/migrations/*message*"
  - "docs/PRIVACY_*"
---

# 응모건 메시지(회원 쪽) (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **응모건 메시지**: 응모이력 카드 메시지 버튼(미읽음 배지) → 게시판형 **페이지**(`#page-messages`, 해시 `#messages-{id}` — 모달이면 키보드가 가린다. `#appShell` 키보드 패턴). **취소(cancelled) 응모는 읽기만** — 읽고 배지도 지워지지만 작성 줄 자리에 안내(`messaging.cancelledReadOnly`), 「직접 문의」도 막고 **전환 기록을 안 남긴다**. 🔴 **진입 자체를 막으면 안 된다** — 관리자 메시지·알림은 계속 와 **막다른 길**이 되고 배지가 영영 안 지워진다. ⚠️ **페이지 재사용**이라 **정상 응모로 재진입하면 작성 줄을 반드시 되돌린다**. ⚠️ 화면 단 규칙 — `send_application_message` 에는 취소 차단이 없다. 텍스트+이미지(자동 압축/HEIC 변환, 최대 5장), 25분 내 본인 회수, 숨김·회수는 가림. 마스킹은 서버(`get_application_messages` RPC). 진입 `openMessagesPage(appId, from)`·이탈 `cleanupMessagesPage()`(navigate 훅). `dev/js/messaging.js`. **자동 번역 병기**(마이그레이션 235): INSERT → 웹훅(Dashboard 수동) → `translate-message` → Google Cloud Translation v2 → `body_translated`/`translated_lang`/`translate_status`. 번역문 위·원문 아래(인플=일본어, 관리자=한국어 + 미리보기·검색도 번역본). NULL/failed/과거는 원문만(발송·조회 안 막음), 마스킹 행은 번역본도 NULL. secrets `GOOGLE_TRANSLATE_API_KEY`. 사양서 `docs/specs/2026-07-13-message-translation.md`. 방침 반영(`docs/PRIVACY_{kr,ja}.md` §4·§5)
