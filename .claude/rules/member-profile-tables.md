---
description: 회원 표(influencers)·연령 정책·위반 기록 — 가입 트리거·본인 수정 잠금(492)·응모 연령 게이트와 얽힘(묶음 규칙)
paths:
  - "dev/js/auth.js"
  - "dev/js/application.js"
  - "dev/js/mypage.js"
  - "dev/js/admin-influencers.js"
  - "dev/js/admin-excel.js"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "supabase/migrations/*influencer*"
  - "supabase/migrations/*signup*"
  - "supabase/migrations/*age_*"
  - "supabase/migrations/*guard_influencer*"
  - "supabase/migrations/325_*"
  - "supabase/migrations/179_*"
---

# 회원 표·연령 정책·위반 기록 (CLAUDE.md 「인플루언서·관리자」 표 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- `influencers` — 인플루언서 프로필. `name`, SNS 계정+팔로워, 주소, `paypal_email`, `primary_sns`, `terms_agreed_at`, `privacy_agreed_at`, `marketing_opt_in` 등. 홍보 메일용: `unsubscribe_token uuid UNIQUE`(수신거부·클릭 추적용 영구 토큰), `marketing_unsubscribed_at`(재구독 시 NULL). **연령 정책(180)**: `birthdate date NULL`(만 18세 판정, 본인 수정 잠금 트리거 `lock_influencer_birthdate`), `gender text NULL CHECK(male/female/other/undisclosed)`(UI 라벨 男性/女性/その他/回答しない), `age_consent_at timestamptz NULL`(185 — 수집 동의 시각). ⚠️ **채우는 자리가 둘이다** — **382 부터 신규 가입자는 가입 트리거가 `privacy_agreed_at` 과 같은 시각으로 즉시 채운다**(방침 §2.1 「회원가입·필수」 항목). 🔴 그래서 **신규 가입자에게는 응모 시점 연령 게이트가 다시는 안 뜬다**(그 게이트는 「생년월일·성별이 빌 때」만 뜬다). 382 이전 가입자는 종전대로 응모 게이트가 채운다. 🔴 **회원 본인의 직접 UPDATE 로는 `email`·약관/개인정보/마케팅 동의 시각·`created_at` 변경과 `marketing_opt_in` 켜기가 거부된다**(492 `trg_guard_influencer_owner_locked_columns` — 판정 `current_user='authenticated'`, **반드시 SECURITY INVOKER**. `age_consent_at` 은 비었을 때만 서버 시각으로, 이미 있으면 조용히 옛 값 유지). 이 칸을 고치는 새 기능은 SECURITY DEFINER 함수를 거칠 것. `is_audit boolean NOT NULL DEFAULT false`(마이그레이션 179) — 감사용 계정, 응모수·슬롯·`applied_count`·KPI·운영현황·엑셀에서 격리. partial index `WHERE is_audit=true`
- `age_policy_settings` — 연령 정책 시행일 단일행(마이그레이션 180). `id=1`, `effective_date date NULL`(NULL=차단 비활성), `updated_at`/`updated_by`. RLS SELECT `is_admin()` / UPDATE `is_super_admin()`. 트리거 `check_age_policy`(응모 BEFORE INSERT — 시행일 이후 birthdate NULL/18세 미만이면 P0002, 관리자 예외) + 헬퍼 `calc_age_kst(date)`. 사양서 `docs/specs/2026-05-27-age-minor-policy.md` PR 1
- `influencer_flags` — 마킹 이력. `influencer_id`, `action`(verify/violation/blacklist/clear), `reasons text[]`, `memo`, `evidence_paths text[]`, `updated_at/by/by_name`. 위반 행만 UPDATE. **방침 「위반 기록 3년 보관」 집행**: `purge_old_influencer_flags()` 가 `set_at` 36개월 경과 행 삭제(pg_cron `influencer-flags-retention-daily`, 04:00). 🔴 **행만 지우고 증빙 파일은 안 지운다** — 325 가 경로를 `influencer_flag_evidence_purge_queue` 에 **쌓아 두게만** 했고(조회·완료처리 함수는 최고 관리자 전용), **큐를 소비하는 화면은 아직 없다.** 「파기 완료」가 아니라 **「추적 근거만 보존」** — 방침 문구에 「집행 완료」로 적지 말 것
