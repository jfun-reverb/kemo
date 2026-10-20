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

---

## CLAUDE.md 에서 옮겨 온 것 (2026-10-15 — 지시 문서 합계 줄이기)

#### 아웃바운드 인플루언서 명단 (추천 도구 1·2단계 — ★**운영 반영 완료**)
- **별도 입구 URL + 화면 이동 드롭다운**(`/admin/?app=outbound`, `dev/admin/app.js`): 영업팀 전용 모드(아웃바운드·내계정 외 숨김). 전환은 **사이드바 하단 드롭다운**(`#adminScreenSelect`) — `switchAdminScreen(target)`, 현재값은 `setAdminScreenSelect()`. `window._adminAppMode`+`applyOutboundModeUI()`. **보안 경계 아님**(`outbound.view` RLS 서버 강제). 권한 없는 campaign_manager 는 모드 해제+대시보드. 페인 전환 시 쿼리 유지(`pushState('#'+pane)`).
- **명단 관리 페인**(`/admin#outbound`, `dev/js/admin-outbound.js`): globalreverb 미가입 별도 자산 명단. 기존 `influencers` 와 **분리한 신규 테이블**. 「명단 / 조건 추천」 탭. **명단 탭**: 등록/편집 모달(가격은 엔화·내부전용) + 삭제(네이티브 confirm — z-index 회피). 세분→계열 자동(`OB_CATEGORY_SERIES` shared.js). 권한 `outbound.view`(campaign_admin=write/campaign_manager=hidden). 이미지 업로드 검증 완료(마이그229 `has_permission` Storage 정책).
- **조건 추천 탭**(2단계, `runOutboundRecommend`·`outboundRecoScore`·`compareOutboundReco`): 조건 입력 → **DB 변경 없이** 전건 조회 + 클라 계산. **계열 필터 + `is_active=false` 제외** → 점수(`RECO_SCORE`: 등급 정확 +30/인접 +10[`sort_order`], 채널 +20, 예산 내 +20/초과 −20/미상 0). 정렬 ①가용 ②점수 ③팔로워 ④최신. 예산은 모집형식 단가(`price_feed/reels/story/tiktok`)로 판정. N번째 뒤 구분선 + 점수 근거 배지. 3~5단계 미착수. 사양서 `docs/specs/2026-07-08-influencer-recommendation.md` §구현 결과 + HANDOFF `2026-07-09-influencer-recommendation-stage1-handoff.md`
- 🔴 **이 화면의 엑셀도 관리자 엑셀 관문을 지난다**(조각 R2 — 개발서버만): `writeBuffer` 바로 앞 `_excelInternalGate(wb, …)` 한 줄 — 기록 실패면 파일 없음, 성공이면 첫 줄 「사내용」(머리글 한 줄 내려감). 엑셀을 고치거나 새로 만들 때 이 줄을 지키고 넣는다. 상세는 `deliverable-review.md` 「관리자 엑셀 내려받기 관문」
