---
description: 캠페인 홍보 메일 — 신규·마감 임박 창·채널 문지기·실행 권한 회수 순서(묶음 규칙)
paths:
  - "supabase/functions/notify-campaign-promo-digest/**"
  - "dev/lib/shared.js"
  - "supabase/migrations/*promo*"
  - "supabase/migrations/*first_active*"
  - "supabase/migrations/*follower*"
  - "supabase/migrations/417_*"
  - "supabase/migrations/259_*"
---

# 캠페인 홍보 메일 (CLAUDE.md 메일 파이프라인 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **캠페인 홍보 메일** (`notify-campaign-promo-digest`): pg_cron 월·목 09:00. 🔴 **신규 = 모집 시작(`first_active_at`, 도쿄 날짜)이 발송일-13 ~ 발송일이고 마감이 다음 발송일 뒤이거나 없음 / 마감 임박 = 마감이 발송일(당일 포함) ~ 다음 발송일**(471. 다음 발송일은 `_promo_next_send_date` **한 벌**. 종류 값 `deadline_d1`·변수 `d1` 은 옛 이름). `first_active_at` 은 **삽입 때도** 기록(470). `marketing_opt_in=true` + 자격 맞는 인플루언서에게 1통씩(노출 최대 2회·클릭하면 제외), 첫 배치에서 `campaign_promo` 토글 관리자에게도. 🔴 **채널 문지기가 따로 있다** — `get_promo_digest_targets`(현재 원본 **471** — 141→143→259→321→360→387→417→471. ⚠️ **375 는 권한만 손댔다**. 풀 `get_promo_digest_campaign_pool` 도 471)가 **네 채널(instagram·tiktok·x·youtube)만** 안다 → **Qoo10·LIPS·@cosme 만 쓰는 캠페인은 대상이 아니다**. ⚠️ **결함이 아니라 결정이다** — 프로필에 그 칸이 없어 더하면 **채널 없는 사람에게도 나간다**. ⚠️ `_meets_min_followers` 를 고쳐도 문지기 때문에 **효과가 절반만 난다.** 🔴 **그 함수를 고칠 때** — 375 가 실행 권한을 회수했다(전엔 **로그인한 회원 누구나** 남의 이메일·이름·**수신거부 토큰**을 받아 남의 수신 설정을 끌 수 있었다). **`CREATE OR REPLACE` 는 권한 보존, `DROP` 후 `CREATE` 는 회수가 풀린다**(오류 없음). 375 순서는 **부여 먼저, 회수 나중**(`GRANT … TO postgres, service_role` → `REVOKE … FROM PUBLIC` → `REVOKE … FROM anon, authenticated`) — **회수만 넣으면 홍보 메일이 죽는다.** 두 줄인 이유는 「함수 실행 권한」 항목. 사양서 `docs/specs/2026-05-27-admin-promo-email-subscription.md`
