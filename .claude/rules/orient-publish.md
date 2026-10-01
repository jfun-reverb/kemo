---
description: 오리엔시트 → 캠페인 발행·기존 캠페인 연결·구매 가이드 모드 — 관리자 캠페인 폼(admin.js)과 얽힌 부분(묶음 규칙)
paths:
  - "dev/js/admin-orient.js"
  - "dev/js/admin.js"
  - "dev/js/admin-core.js"
  - "dev/lib/shared.js"
  - "dev/js/application.js"
  - "dev/admin/index.html"
  - "dev/lib/storage.js"
  - "supabase/migrations/*orient*"
  - "supabase/migrations/*purchase_guide*"
---

# 오리엔시트 → 캠페인 발행·연결·구매 가이드 (CLAUDE.md 오리엔시트 절에서 옮겨 옴 — 2026-10-01 조각 D′)

> 마지막 줄 「구매 가이드」는 원래 「구간 요금·구매 가이드·칸 정리(마이그레이션 442~448 — ★운영 완료) · **새 구조 전용**」 아래 항목이다(옛 시트에는 해당 없음). 그 부모 덩어리는 `orient-sheet.md` 에 있다.
- 관리자 발급·조회 페인(`/admin#orient-sheets`, `dev/js/admin-orient.js`): 발급 모달(브랜드[신청 연결 잠김] + **형식 라디오·시딩 채널**(424) — 옛 구조는 옛 시트 읽기 전용 + **모집비 직접 지정 칸**(447), `create_orient_sheet` 5인자) + 상세 모달(`data.cards` 순회) + 목록 「모집 형식」(`osCardsSummary`). **자동 채움 발행**: 「이 카드로 발행」(제출됨·미발행만) → `applyOrientCardPrefill`(한국어는 `_ko` 칸, 일본어 칸은 비움) → `add-campaign` 폼 → `addCampaign` 일본어 게이트(가이드 비면 매니저 차단·campaign_admin 은 사유 적고 긴급 발행) → `mark_orient_card_consumed`(196, `data.cards[i].campaign_id`·전 카드 시 `status=consumed`). 가구매=`proxy_purchase=true`. 발행 권한 `is_admin()`, 긴급 우회만 `isCampaignAdminOrAbove()`.
  - 🔴 **판매가(`sale.price_regular`)는 캠페인 어느 칸에도 자동으로 안 들어간다** — `product_price`(리뷰어형 **지급 상한**)·`reward_note`(**인플루언서 화면 노출**)에 들어가면 확인 안 된 브랜드 값이 송금액을 좌우하고 한국어가 일본어 화면에 실린다. **제품 금액은 담당자가 직접** — 판매가는 상세 모달에 표시된다(**그 표시를 지우면 값을 볼 데가 없어진다**). **리뷰어형인데 제품 금액이 0이면 확인창**(`confirmMonitorWithoutPrice`, 막지 않음). ⚠️ 그 확인창은 **세 경로 모두**(`addCampaign`·`saveCampaignEdit`·`duplicateCampaign`)에서 — 앞의 둘만이면 **금액 0 캠페인을 복제해 늘리는 길**이 남는다. 시딩·방문형은 대상 아님(`reward` 기준). 0으로 발행하면 ①페이백 상한 안내가 안 뜨고 ②정산 자동 등록에서 빠진다(「과거 미등록」엔 나타남).
  - **기존 캠페인 연결·해제**(마이그레이션 237·238·239): 「이 카드로 발행」 → `#orientPublishModal`(신규 / 기존 연결). 연결(`osConfirmLink`→`link_orient_card_to_campaign`)은 이 시트 브랜드 캠페인만(`allCampaigns`, 딥링크 시 `fetchCampaigns` 폴백), 서버가 **브랜드·모집 형식 일치·전역 중복**을 검증(`brand_mismatch`/`recruit_type_mismatch`/`campaign_already_linked`). 🔴 **모집 형식**(마이그레이션 464, 현재 원본 **464**, 베이스 237): 리뷰어→`monitor`+가구매 아님 / 가구매→`monitor`+가구매 / 시딩→`gifting` — 리뷰어·가구매는 `recruit_type` 이 같아 **`proxy_purchase` 로만 가른다**. 방문형은 어느 카드로도 안 붙는다. 목록(`osRenderLinkList`)도 같은 매핑(`OS_CARD_CAMPAIGN_TYPE`)(우회 버튼 없음). 카드에 `linked_existing:true`. 해제(`unlink_orient_card`)는 마커만 제거·`consumed`→`submitted`. ⚠️ `delete_orient_sheet` 는 `linked_existing:true` 카드의 캠페인을 **삭제 대상에서 제외**(따로 만든 캠페인 보호)
  - **구매 가이드**: 리뷰어 카드 자율/지정 라디오(`purchase_guide.mode` free|fixed, 지정이면 `options` — **리뷰 가이드와 같은 서식 편집기 값**. 관리자 상세 `osPgOptionsHtml` 정화, 자동 채움 `osStripHtml`) + 추가 옵션(`sale.extra_markets` lips·cosme). 자동 채움이 `purchase_guide_mode`(444)에 옮기고. 🔴 **`campaigns.purchase_guide_mode` 에 값이 있고 리뷰어형일 때만** 「캠페인 설명」 칸 이름이 「구매 가이드」(`campaignDescSectionLabel`, shared.js — 폼·미리보기·상세 공용). **NULL = 옛 판** — 기본값·NOT NULL 을 걸면 운영 캠페인 전부가 새 판이 된다. 🔴 **새로 만드는 캠페인은 전부 새 판이다** — 등록 폼 기본 자율구매, 복제·오리엔시트 발행도 값이 없으면 `'free'`. 편집 폼 「고르지 않음(예전 방식)」은 **값이 빈 옛 캠페인에서만**. 선택은 **라디오**(`newCampPgMode`·`editCampPgMode`) — `getCampPgMode`/`setCampPgMode`(admin.js)로만. 변경 이력 화이트리스트에 일부러 안 넣었다. ⚠️ 추가 옵션 채널이 `lookup_values` 에서 비활성이면(개발서버 LIPS) 주황 경고(`osWarnDroppedPrefillChannels`) — 운영 LIPS·@cosme 는 활성
