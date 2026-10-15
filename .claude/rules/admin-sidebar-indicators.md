---
description: 관리자 사이드바 경고 아이콘·배지 자리 규칙 — 여러 감지 장치가 같은 자리를 건드리면 나중 것이 이긴다(묶음 규칙)
paths:
  - "dev/js/admin-core.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-dashboard.js"
  - "dev/js/admin.js"
  - "dev/js/admin-errors.js"
  - "dev/js/admin-influencers.js"
  - "dev/js/admin-lookups.js"
  - "dev/admin/index.html"
---

# 관리자 사이드바 경고 아이콘 (CLAUDE.md 회원 탈퇴 절 「관리자 화면」에서 옮겨 옴 — 2026-10-01 조각 D′)
  - ⚠️ **사이드바 아이콘은 항목마다 하나의 장치만** — 채널 감지(`adminDelivSi`·`adminLookupsSi`)·막힌 표(`adminErrorsSi`)와 겹치지 않게. 둘이 건드리면 나중 것이 덮어쓴다
  - ⚠️ **아이콘이 찬 항목에 또 얹어야 하면 「빈 자리」를 쓴다**. 항목 하나에 자리가 셋: **`.si-icon`(아이콘)** · **`.admin-si-badge`(숫자)** · **덧붙이는 요소**. ⚠️ 「결과물 관리」의 세 번째 자리 점(「올려두고 미제출」)은 없앴다 — 그 감지는 제목 옆 버튼으로만 남았다. **자리가 셋이라는 사실과 아래 경고는 유효하다.** 🔴 **「재입힘 목록에 넣으면 된다」만으로는 부족하다** — `refreshDelivSidebarBadge` 가 innerHTML 을 통째로 다시 써 **재입힘은 필수지만**, **같은 자리(아이콘)를 건드리면 나중에 도는 쪽이 이긴다.** 자리를 나누는 것이 먼저다
