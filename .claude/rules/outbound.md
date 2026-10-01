---
description: 아웃바운드 인플루언서 명단 — 별도 표·권한 outbound.view·이미지 통(묶음 규칙)
paths:
  - "dev/js/admin-outbound.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "supabase/migrations/*outbound*"
---

# 아웃바운드 인플루언서 명단 (CLAUDE.md 「인플루언서·관리자」 표 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- `outbound_influencers` — 아웃바운드 시딩·타이업 명단(영업팀 직접 컨택, 마이그레이션 226). `influencers`와 물리 분리. 컬럼: `name_ko`/`account_id`·분류(`series_code`/`category_code`/`tier_code`)·채널4·가격5(`price_feed`/`reels`/`story`/`tiktok`/`secondary` `bigint NULL`=미상, 내부전용)·운영(`contact_channel`/`agency`/`nego_memo`/`availability CHECK(available/unavailable/adjusting)`)·`rep_image_path`/`rep_posts jsonb`/`content_consent`·`is_active`. **RLS SELECT/INSERT/UPDATE/DELETE 전부 `has_permission('outbound.view',...)`**(⚠️`is_admin()` 금지 — campaign_manager 차단). 기준데이터 `lookup_values` kind 3종(`ob_series`/`ob_category`/`ob_tier`) — **세분→계열 매핑은 `OB_CATEGORY_SERIES` 코드 상수**(health→life·tech→other). 권한 `menu.outbound`/`outbound.view`. Storage 버킷 `outbound-influencer-images`(공개 읽기·관리자 쓰기 — ⚠️ `has_permission` 을 storage 정책에 쓴 최초 사례). 시드 `outbound_influencers_import.sql` 은 BEGIN/DELETE ALL/INSERT/COMMIT 멱등. 사양서 `docs/specs/2026-07-08-influencer-recommendation.md`
