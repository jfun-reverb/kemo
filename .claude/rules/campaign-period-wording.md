---
description: 캠페인 날짜 문구·페이백 안내 — 판정 헬퍼를 회원 상세와 관리자 미리보기가 같이 쓴다(묶음 규칙)
paths:
  - "dev/lib/shared.js"
  - "dev/js/application.js"
  - "dev/js/admin.js"
  - "dev/js/admin-deliverables.js"
  - "dev/lib/i18n/ja.js"
  - "dev/lib/i18n/ko.js"
---

# 캠페인 날짜 문구·페이백 안내 (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **캠페인 날짜 문구 정리 + 페이백 안내**(데이터베이스 변경 없음): 리뷰어형 기간·마감 표기 정리. 판정 헬퍼 2개(`dev/lib/shared.js`)를 **인플루언서 상세와 관리자 미리보기가 같이 쓴다**(두 벌이면 두 화면이 갈린다).
  - `campaignPeriodRowKind(camp)` → **네 갈래**: `merged`(구매 = 모집 기간) / `split`(불일치) / `monitorNoPurchase`(리뷰어형, 구매 빔) / `none`(**시딩·방문형 전용**). ⚠️ **리뷰어형 세 갈래는 「모집 및 구매 기간」 한 줄**, `split` 만 그 안에 **날짜 두 줄**+「(모집기간)」·「(구매기간)」(`detail.periodTagRecruit`/`…Purchase`) — 구매 마감일이 사라지면 안 된다. 구매 기간 **별도 줄은 없다**(날짜가 두 번 나온다). ⚠️ **`none` 을 구매 빈 리뷰어형과 겸하면** 시딩·방문형에 「구매 기간」이 붙는다. ⚠️ 호출부는 **갈래를 이름으로 지목** — `!== 'split'` 같은 부정 조건은 갈래가 늘 때 조용히 틀린다. ⚠️ 비교는 **날짜 문자열 그대로**(`new Date()` 금지 — 시간대)
  - `campaignSubmissionLabelCode(camp)` → 제출 마감 이름 3갈래(가구매=「영수증 제출 마감일」 / 일반 리뷰어형=「영수증·게시물 인증샷 제출 마감일」 / 시딩·방문형=바꾸지 않음). ⚠️ **번역문이 아니라 코드값만 돌려준다** — 관리자 빌드에는 i18n 파일이 없어 `t()` 가 존재하지 않는다
  - **저장 규칙**: 리뷰어형은 `purchase_start=recruit_start`·`purchase_end=deadline` 으로 저장(`applyMonitorPeriodCopy`) — **신규 등록·복제 두 곳뿐**, 편집 저장은 손대지 않는다(과거 값을 되찾을 길이 없다). 저장 칸은 12곳이 읽어 계속 채운다
  - **관리자 폼**: 리뷰어형이면 구매 기간 입력칸을 숨기되, **저장된 두 기간이 다르면 편집 시 보여준다**. ⚠️ 숨김 기준(`showPurchaseRow`)과 값 비우기 기준(`typeWantsPurchase`)을 **절대 한 변수로 묶지 않는다** — 묶으면 리뷰어형 구매 기간이 통째로 지워진다. ⚠️ `_editCampOriginal` 은 폼을 여는 시점에 **아직 직전 캠페인 것**이라 `applyDeadlineFieldsVisibility` 세 번째 인자로 `camp` 를 직접 넘긴다
  - **페이백 안내**(`campaignPaybackNotice`): 리뷰어형 상세 정보표 위 파란 상자(주의사항 빨강과 구분). 첫 줄은 그려지는 방식에 맞춰 갈린다(`split` 이면 「구매 기간에…」). ⚠️ 줄 이름은 **「구매 기간」**(영수증 마감은 결과물 제출 마감일). 문구는 **두 벌**(인플 `dev/lib/i18n/*.js` · 관리자 `admin.js`)이라 항상 같이 고칠 것
  - **검수 화면 경고**(`receiptPurchaseWindowWarning`, admin-deliverables.js): 구매일이 구매 기간 밖이면 판단 기준(「배송 지연·품절 등 우리 쪽 사정만 승인」)과 빨간 경고. **막지 않는다**. 값이 비면 경고 없음(조회 실패를 위반으로 읽지 않는다)
  - 라벨 칸 폭 **110픽셀**(새 이름이 네 줄로 접혀서). 사양서 `docs/specs/2026-08-06-campaign-period-wording-and-payback-notice.md`
