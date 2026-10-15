---
description: 최소 팔로워수 정책 — 채널 묶음별 갈래 셋, 화면·홍보 메일 SQL 두 곳 판정, 표시 다섯 곳(묶음 규칙)
paths:
  - "dev/lib/shared.js"
  - "dev/js/application.js"
  - "dev/js/admin.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/messaging.js"
  - "dev/js/report-rows.js"
  - "dev/lib/i18n/ja.js"
  - "dev/lib/i18n/ko.js"
  - "supabase/functions/notify-campaign-promo-digest/**"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "supabase/functions/notify-deliverable-decision/**"
  - "supabase/migrations/*follower*"
  - "supabase/migrations/*promo*"
  - "supabase/migrations/*faq*"
  - "supabase/migrations/*revoke_internal*"
---

# 최소 팔로워수 정책 (CLAUDE.md Rules 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **최소 팔로워수 정책 — 채널 묶음에 따라 갈래 셋**(마이그레이션 384·385): **채널 1개**=그 채널로 검사 / **「또는」**(`channel_match='or'`)=**모집 채널 중 하나라도** 넘으면 통과 / **「그리고」**(`='and'`)=**채널마다 따로** — `campaigns.min_followers_by_channel`(jsonb). `recruit_type='monitor'` 는 **건너뛴다**(저장 때 `min_followers`·`primary_channel` 이 0·`null`, 채널별 칸도 `{}`). ⚠️ **채널 1개를 별도 갈래로 둔 이유** — 하나인데 `and` 로 저장되면 빈 칸을 읽어 **검사가 통째로 사라진다**. ⚠️ **빈 채널별 칸은 「검사 안 함」이지 0이 아니다**(화면에 「제한 없음」). ⚠️ **입력칸은 팔로워 값을 가진 네 채널만**(Instagram·X·TikTok·YouTube) — **Qoo10 은 Instagram 값을 빌린다**(`campaignMinFollowersByChannel`. 🔴 저장 칸을 직접 읽으면 화면은 「제한 없음」인데 실제로는 막힌다). **LIPS·@cosme 는 값이 항상 0** 이라 칸을 만들면 아무도 통과 못 한다(지금은 리뷰어형 전용이라 건너뜀 — **그 안전판이 사라지면 문제**).
  - 🔴 **같은 판정이 두 곳에 산다** — 화면 `dev/lib/shared.js`(`campaignFollowerKind`·`meetsMinFollowers`·`minFollowersDisplay`)와 홍보 메일 SQL(`_meets_min_followers`, 현재 원본 **387**). **한쪽만 고치면 메일은 오는데 응모는 막히고 오류는 없다.** 🔴 **387 은 옛 8인자를 `DROP` 했는데 그때 141 의 회수(`FROM PUBLIC, anon`)도 사라진다** — 387 이 다시 건다. ⚠️ 「일부러 안 닫은 셋」은 **369·370 정리에서 뺐다**는 뜻이지 **회수가 없다는 뜻이 아니다** 🔴 `get_promo_digest_targets`(현재 원본 **471**, 베이스 417→387→360)는 **반드시 `CREATE OR REPLACE`** — `DROP` 후 `CREATE` 하면 375 의 회수가 풀려 회원 누구나 남의 이메일·수신거부 토큰을 받는다.
  - ⚠️ **화면 표시는 `minFollowersDisplay` 가 재료만 주고 문구는 각 화면이 만든다**(관리자 빌드엔 `t()` 없음) — **다섯 곳을 함께**: ①인플 캠페인 상세(`minFollowersDetailLines`) ②응모 차단 문구(`followerBlockMessage`) ③관리자 폼·미리보기(`admin.js`) ④**삭제된 캠페인 상세**(`deletedCampMinFollowersCell`) ⑤**FAQ 자동응답**(`_buildFaqCtx` + 본문, 마이그레이션 386). ⚠️ **메일에는 이 조건을 쓰는 곳이 없다**. ⚠️ 경위·팝업 3건 1,000 → 0 조치는 `docs/specs/2026-08-27-min-followers-channel-match.md`
