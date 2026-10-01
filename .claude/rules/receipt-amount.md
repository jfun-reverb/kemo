---
description: 리뷰어형 정산 금액(영수증 실결제액·제품 가격 상한)과 페이백 문구 — 회원 화면·관리자 미리보기·메일이 같은 말을 해야 한다(묶음 규칙)
paths:
  - "dev/js/campaign.js"
  - "dev/js/application.js"
  - "dev/lib/i18n/ja.js"
  - "dev/lib/i18n/ko.js"
  - "dev/js/admin.js"
  - "dev/js/admin-deliverables.js"
  - "supabase/functions/notify-campaign-promo-digest/**"
  - "supabase/functions/notify-influencer-daily-digest/**"
  - "supabase/functions/notify-deliverable-decision/**"
  - "supabase/migrations/*settle*"
  - "supabase/migrations/*receipt*"
  - "supabase/migrations/*faq*"
---

# 리뷰어형 정산 금액·페이백 문구 (CLAUDE.md 정산 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **리뷰어형 정산 금액 = 영수증 실결제액(상시가 상한)**(마이그레이션 299·300·301): **금액 = `floor(LEAST(최신 영수증 purchase_amount, campaigns.product_price))`**(리뷰어형·가구매 동일 / 시딩·방문형은 `reward`). 금액 행은 **인증 판정에 쓰는 바로 그 행**(`receipt_latest`). `amount_source` 에 **`receipt_amount`** 추가(299) + 감사 칸 `receipt_amount_jpy`·`amount_cap_jpy`. ⚠️ **`LEAST()` 는 NULL 을 무시**하므로 두 값이 모두 유효할 때만 호출(안 그러면 「영수증 없음」이 조용히 상시가가 된다). ⚠️ `amount_issue` **조건 3종**(영수증 금액 없음·0 이하 / 상한 없음·0 이하 / **버림 결과 0 이하**) — 세 번째를 빠뜨리면 0.5엔 같은 값이 `CHECK(amount_jpy>0)` 위반으로 **배치 전체를 실패**시킨다. **301**: `deliverables` BEFORE INSERT OR UPDATE 트리거 `trg_receipt_settlement_lock` — 정산이 **송금완료·보류**인 응모에 새 영수증(`kind='receipt'` + `draft`/`pending`) 저장 차단(재제출은 새 행이라 「최신 영수증」이 바뀐다). ⚠️ **취소(cancelled)는 막지 않는다** — 막으면 **영구히 영수증을 못 내는 상태로 굳는다**. 관리자·서비스 키·`approved` 저장은 통과. ⚠️ 트리거 함수는 **`SECURITY DEFINER` 필수** — 인플루언서가 본인 정산 행을 못 봐 차단이 무력화된다.
- **화면 문구는 금액을 약속하지 않는다**: 전체형 **「購入金額をペイバック（最大 ¥N）」**(구매 금액을 페이백, 최대 ¥N) · 축약형 **「ペイバック（最大 ¥N）」**. ⚠️ **제품 가격이 없는 리뷰어형은 「購入金額をペイバック」(상한 없음)** — 카드·상세 머리·하단 바·홍보 메일·관리자 미리보기 **다섯 자리가 같은 말**. 열쇠말 `detail.rewardPaybackNoCap`·`campaign.rewardPaybackNoCap`·미리보기 `paybackNoCap`. ⚠️ 영수증 입력칸 안내(`renderReceiptPayoutNote`)는 **리뷰어형 한정**(방문형 현장 사진은 기준이 다르다). 🔴 **리뷰어형에 현금 리워드(`campaigns.reward`)를 덧붙이지 말 것** — **지급되지 않는 금액을 약속**한다. 승인 안내 메일은 리뷰어형이면 전체형 문구를 쓰는데 **그 조회에 `product_price` 가 있어야** 상한이 안 사라진다. FAQ 「최대 금액인데 적게 들어왔어요」(303)의 「정산 내역 보기」는 잠긴 동안 응모이력으로 간다. 사양서 `docs/specs/2026-08-05-settlement-receipt-amount-switch.md`
- **전수조사 후속 5종(마이그레이션 324)** — 지금은 **잠복 상태**.
  - **영수증 수정 재계산이 모집 형식을 안 봤다**: `update_receipt_admin`(원본 302)이 방문형에도 리뷰어형 계산을 태웠다. 재계산 진입을 `pending AND recruit_type='monitor'` 로 좁혔다 — 시딩·방문형은 **무변경**. ⚠️ 302 의 「송금완료·보류는 수정 차단」과 **「자동 보류」 연속 표현 금지**(화면이 그 문자열로 다른 배지를 그린다)는 그대로
  - **「금액 미확정」이 어느 목록에도 안 떴다**: `get_past_unregistered_settlements` 에 조건 추가 + **`is_pre_cutoff` 반환값 신설**(화면 반영은 후속). ⚠️ **도입일 미설정인 지금은 늘어나는 건수 0**
  - **일괄 「송금완료 기록」의 페이팔 검사**: `register_past_settlements` 가 **막힌 건만 빼고** `skipped_no_paypal_count` 로 알린다(단건 `mark_settlement_paid` 와 같게). ⚠️ 「정산대기 추가」에는 **일부러 안 건다**
  - **`cert_at` 칸 신설**: 인증성공일로 보이던 값이 실은 **등록일**이었다. 두 경로(`backfill_settlements`·`register_past_settlements`) 모두 저장. ⚠️ 값이 없으면 화면은 「기록 없음」 — **등록일로 대신 채우지 않는다**(틀린 날짜가 더 나쁘다). 과거 행은 342 가 되살렸다(`settlement.md` 의 3단계 항목)
  - **페이팔 안내 알림 중복**: 사람 단위(`DISTINCT ON`) + 재발송 **14일 간격**. ⚠️ 잠금 게이트(`is_settlement_public()`, 242) **안에 그대로** 둔다
  - **재제출 → 승인 재계산(327)** — `update_deliverable_status`(원본 **035**): **영수증 승인 시**, 정산이 `pending` 이고 **리뷰어형**일 때만 금액 재계산(상한 `campaigns.product_price` 재조회 — 324 와 같은 규칙). ⚠️ **송금완료·취소·보류는 안 건드린다** — 보류 사유 셋을 구분 못 해 사유와 금액이 어긋난다. 재개는 「보류 해제」 뒤 다음 승인·수정에서. ⚠️ 재계산 실패는 **승인과 함께 롤백**된다
  - ⚠️ **324 도 327 에서 정정 — 「최신 영수증」에 임시저장 제외가 없어** 제출 안 한 `draft` 값으로 금액이 재계산됐다(318 과 같은 유형). **「최신 영수증」 판정 지점은 세 곳**(`_settlement_cert_candidates`·`update_receipt_admin`·`update_deliverable_status`) — 새로 만들 때 같은 기준(`status <> 'draft'` + `ORDER BY submitted_at DESC, updated_at DESC`). ⚠️ `supabase/patches/2026-08-06-PROD-B-settlement.sql` 에는 **옛 정의가 남아 있다** — 다시 돌리면 이 정정이 되돌아간다
