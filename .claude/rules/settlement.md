---
description: 인플루언서 정산 — 정산 표·금액 규칙·상태 변경 함수
paths:
  - "dev/js/admin-settlements.js"
  - "supabase/migrations/*settle*"
  - "supabase/migrations/*payout*"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "dev/js/admin-applications.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-permissions.js"
  - "dev/js/notifications.js"
  - "dev/js/mypage.js"
  - "supabase/migrations/*admin_view*"
  - "supabase/migrations/*pii*"
  - "supabase/migrations/*reject*"
---

# 정산 (인플루언서 리워드)

> 인증 성공 → 정산 대기 자동 등록 → PayPal 수동 송금 후 기록 → **관리자만 조회**. 엔화, 원천징수 없음(약관 제13조). 사양서 `docs/specs/2026-06-22-influencer-settlement.md`
- `settlement_events` — 금전 감사 이력(append-only). `settlement_id` **ON DELETE RESTRICT**(정산행은 하드 삭제 대신 cancelled)·`action`(create/pay/hold/cancel/revert)·`prev_status`/`next_status`·`actor`·`memo`·`at`. RLS SELECT `has_permission('settlement.view','read')`, INSERT 함수만
- **정산 금액 출처 = 모집 형식별 분기(마이그레이션 261·262·264)**: `settlements.amount_source`·`reward_part_jpy` 신설(261), **후보 조건 `c.reward > 0` 제거**(262). 금액이 NULL·0 이하면 `amount_issue` 로 사유를 세우고 **INSERT 대상에서 제외** — `settlements.amount_jpy CHECK(>0)` 위반으로 배치 전체가 실패하는 것을 막는다. **264**: 무보수 시딩·방문형(약관 제13조 3항)을 `_settlement_cert_candidates()` 에 `NOT (recruit_type<>'monitor' AND (reward IS NULL OR reward<=0))` 로 **후보에서 제외**(300·318 이 계승). 🔴 **이 항목의 「리뷰어형 = 상시가」는 아래 299·300 이 「영수증 실결제액(상시가를 상한으로)」으로 뒤집었다.** ⚠️ 운영 적용됨. 사양서 `docs/specs/2026-07-23-settlement-reviewer-receipt-amount.md`
- `settlement_settings` — 정산 도입일 싱글톤(id=1, `cutoff_at timestamptz NULL`, 마이그레이션 230). NULL=자동 0건. RLS SELECT `has_permission('settlement.view','read')` / UPDATE `is_super_admin()`(과거분 전체를 좌우하는 스위치). 도입일 이전분은 수동 처리(**무알림**). 조회 `get_past_unregistered_settlements()`(232, 인증성공 판정은 공통 헬퍼 `_settlement_cert_candidates()`로 3곳 공유, 명시적 컷오프 필터·PayPal은 `has_paypal` 불리언만)·처리 `register_past_settlements(uuid[], 'paid'|'pending', memo)`(233, 서버 재검증·멱등·**알림 INSERT 전무**)·정산 페인 「과거 미등록」 뷰(일괄 「송금완료 기록」[확인 모달]/「정산대기 추가」). 사양서 `docs/specs/2026-07-09-settlement-cutoff-past-handling.md`
- **보류 해제는 송금 기록 3칸을 비운다**(마이그레이션 416): `mark_settlement_revert`(on_hold→pending)가 `paid_at`·`paid_by`·`paid_amount_jpy` 를 NULL 로 하고 옛 값을 `settlement_events.memo` 에 「[송금 기록 초기화] 송금일 … · 송금액 …」로 남긴다(안 비우면 지급 준비 합계가 옛 금액으로 잡혀 과소 송금). 🔴 **보류·취소(223)는 그대로 보존한다** — 환수 근거. `paypal_email` 도 보존. `mark_settlements_paid_bulk`(현재 원본 **416**, 베이스 343)는 `paid_amount_jpy = NULL` 명시. 화면 `settlementEffectiveAmount`(shared.js)는 **정산대기 행이면 실제 송금액을 무시**(안전판). ⚠️ 이 두 함수의 베이스는 224·343 이 아니라 **416**
- `storage.js`: `fetchSettlements(opts)`(1000행 페이지네이션)·`backfillSettlements()`·`hasPaidSettlementForApplication(appId)`

## CLAUDE.md 에서 옮겨 온 것 (2026-10-01 조각 D′)
- 페이팔 송금 1건 = `settlement_transfers` 1줄, 건과는 `settlement_transfer_items`, 건의 현재 묶음은 `settlements.current_transfer_id`. 🔴 **현재 묶음이 있으면 건의 송금일·보낸 금액은 묶음이 정본** — 건에서 날짜를 바꾸면 `paid_at_owned_by_transfer`
- 수수료 계산식은 `_settlement_fee_calc` **한 곳**, 화면은 `preview_settlement_fees`(현재 원본 **515** — 묶음별 요율·고정액·끝수 선택 배열)로 묻는다 — 화면에 식을 두지 않는다.
- **회차 상세 「지급 완료」 줄의 「금액 정정」·「송금 정정」·「이력」**(`_payoutPaidActionsHtml` — 사람별·캠페인별 펼침 **두 곳이 이 함수 하나**). 🔴 저장 뒤 `refreshPane` 만 부르면 회차 상세가 안 바뀐다 — 두 정정 창은 `from` 을 들고 `_settlementRefreshKeepingView` 로 다시 그린다. 회차 상세에서 연 송금 묶음 행은 `_transferRows` 에 넣지 않는다(송금 내역 엑셀이 그 캐시를 쓴다). **송금 이력 창**(`openTransferHistoryModal`, `settlement_transfer_events`) — 칸 구성이 마이그레이션마다 달라 없는 칸은 안 그리고 NULL 은 「—」
- **송금별 요율「이 송금 요율 직접 정하기」**(513~517): 확인 창·정정 창 체크 칸 — 동작 정본은 사양서 `2026-10-02-settlement-per-transfer-fee-rule.md` 설계 ⓪. 🔴 화면에는 **수수료 금액 입력 칸이 없다**(2026-10-08 사용자 결정 — 체크 칸 「직접 지정」 옆 요율·고정액만. 서버는 금액 인자를 아직 받는다 · `bundle_fee_conflict` 는 둘을 함께 보낼 때의 방어선). 정정 창은 요율 체크를 켜면 「값이 맞음(추정 해제)」을 끄고 흐리게(작업표 결정 P1 — 요율 저장이 추정 표시를 함께 지운다). 기록은 설정 끝수, 정정은 **사본 끝수**(비었으면 설정). 「설정과 다른가」 판정은 서버 세 곳(514·515·517)이 요율·고정액만 — 「이 송금만」 여부는 `fee_rule_custom` 저장값만 본다(`_transferFeeNoteHtml`·엑셀 `_transferRuleExcelCells`). 색(높으면 파랑·낮으면 빨강)만 그 송금 기록 당시 설정과 화면이 비교한다(`_feeRuleAt` — 수수료 설정 변경 이력). 「고친 값」 표시는 없앴다. ⚠️ 오류 문구 `bundle_fee_rule_invalid` 는 `fee_rule_invalid` 를 글자로 품어 `friendlyError` 에서 **그 줄보다 앞**에 둔다 묶음 표엔 **페이팔 주소 칸이 없다**(363 파기 대상을 늘리지 않으려고)
- 🔴 **회차 판정 두 벌** — 서버 `_settlement_payout_due`(487) · 화면 `payoutDueDate`(shared.js). 함께 고칠 것
- **과거 지급 시트 소급**(500~502, 사양서 `docs/specs/2026-10-01-settlement-sheet-backfill.md`): `backfill_settlement_transfers_from_sheet`(501) — 출처 `sheet_backfill` 고정(도입일 안 만듦) · 페이팔로 막지 않음(정산 행엔 **시트 주소**) · 이미 송금완료 건의 비교 금액은 `COALESCE(paid_amount_jpy, amount_jpy)`(그 칸은 비어 있는 게 정상) · 후보 아닌 미등록은 판정 헬퍼가 회원·캠페인을 비워 주므로 `applications` 에서 읽는다. 부르는 곳은 콘솔 도구 `scripts/backfill-settlement-sheet.js` 뿐
  - 묶음 표 `sent_at_estimated`·`fee_estimated`(500) = 「추정」 배지. 정정(502)에서 그 칸에 값이 오면 지운다 — 🔴 **같은 수수료면 `fee_manual` 을 건드리지 않는다**(「값이 맞음」이 「고친 값」을 만들면 안 된다)
  - 🔴 **시트 합산 탭의 실제 수수료는 규칙 사본 3칸을 비운 채 저장**한다 — 486 `correct_settlement_payment` 는 사본이 다 있을 때만 수수료를 다시 계산하므로, 채우면 건별 금액 정정 때 시트 실제값이 덮인다. 화면은 이것을 「지급 시트 실제값」으로 적는다
  - 고친 수수료의 근거 줄 「규칙 계산 ¥A · 차이 ±¥B」 — 규칙 계산값은 조회(502)의 `fee_rule_jpy`(서버가 사본으로 계산). **화면에서 식으로 다시 계산하지 않는다**
- ⚠️ 확인 창 진입점은 **여섯**(목록 선택 · 미등록 · 지급 준비 건별 · 사람·회차 · 선택한 건 · 행 「송금 완료」) — 모두 `_bulkItemFrom*` 로 공통 항목을 만들어 한 창을 쓴다. 「정산대기 추가」만 옛 창
- ⚠️ 정산 화면은 **넷이 서로 배타**(정산 목록·미등록·지급 준비·송금 내역) — 새 화면·경로를 만들면 `_hideTransferView` 짝부터. 페인 맨 위 **공통 탭 줄**(회차별[=지급 준비]·사람별·송금 내역·정산 목록)의 현재 탭은 `refreshSettlementNav()` 가 **화면 상태로 계산**한다 — 화면을 켜고 끄는 함수는 끝에서 그것을 부른다(빠지면 탭이 거짓말을 한다)
- `settlements` — 정산 1건 = 응모 1건(`application_id UNIQUE`). `influencer_id`/`campaign_id`·`amount_jpy bigint`(생성 시점 스냅샷 — **모집 형식별 출처**: 리뷰어형=`min(최신 영수증 purchase_amount, campaigns.product_price)` 절사(299·300) / 시딩·방문형=`campaigns.reward`. ⚠️ 리뷰어형은 `reward` 를 **쓰지 않는다** — 화면·메일에 현금 리워드를 덧붙이면 지급 안 되는 금액을 약속한다)·`status CHECK(pending|paid|on_hold|cancelled)`·`paypal_email`(스냅샷)·`paid_at`/`paid_by`/`memo`/`version`. 환수는 `on_hold`+메모. RLS SELECT `has_permission('settlement.view','read')`(campaign_manager 는 API 조회도 차단). INSERT/UPDATE 는 SECURITY DEFINER 함수만. 🔴 `settlements.paypal_email` 은 가림막 뷰(212·213)를 **거치지 않는 직접 칸** — campaign_manager 에게 `settlement.view` 를 여는 순간 `influencer.sensitive_pii` 와 **무관하게** PayPal 이 노출된다
- **실제 송금 기록 (3단계, 마이그레이션 338~342)**: 일괄 기록 + 실제 송금일·금액. 사양서 `docs/specs/2026-08-18-settlement-list-unification-and-payout-schedule.md` · 인수인계 `…-settlement-stage3-handoff.md`
  - `settlements.paid_amount_jpy`(338) — **실제로 보낸 금액**. 계산값(`amount_jpy`)은 그대로(스냅샷을 덮으면 근거를 설명 못 한다). 합계는 **반드시 `settlementEffectiveAmount()`**(shared.js) — ⚠️ `amount_jpy` 로만 찾으면 지급 준비 화면이 `r.amount` 로 옮겨 담아 더하는 네 곳을 놓친다
  - `mark_settlement_paid`·`register_past_settlements` 에 송금일·송금액 인자(339)
  - **`mark_settlements_paid_bulk`(340)** — 일괄 송금완료. **건너뛴 사유 3종을 각각 반환**(페이팔 미등록·이미 처리됨·사라진 행). ⚠️ **신설 함수라 241 의 알림 잠금이 저절로 안 따라온다** — `is_settlement_public()` 게이트를 명시했다. 빠뜨리면 **이 함수로 노출 잠금이 우회**된다
  - **`correct_settlement_payment`(341)** — 송금완료 건의 **송금일·송금액만** 정정(알림 없음). ⚠️ `settlement_events.action` 에 **`correct` 를 함께 넓힌다**(302 의 6종 → 7종) — 안 넓히면 정정 트랜잭션 전체가 실패한다. **베이스는 302**
  - **`cert_at` 백필(342)** — 과거 행의 진짜 인증일을 되살렸다. ⚠️ **`cert_at` 하나만** 채운다(`paid_at` 정정 안 함)
  - **「선택한 건 보냄」** — 지급 준비 화면 체크박스(원래 합계 대조 전용)로 일괄 기록. ⚠️ 선택에 **정산 행이 있는 건과 없는 건이 섞여** 함수가 둘로 갈린다(`markSettlementsPaidBulk`/`registerPastSettlements`) — 한쪽만 부르면 절반만 기록된다. 확인 창은 사람별 이름·페이팔·건수·금액과 **페이팔이 없어 건너뛸 사람**을 보여준다
  - ⚠️ **화면 셋(정산 목록·미등록·지급 준비)은 서로 배타여야 한다** — 켜는 함수마다 **나머지를 닫는 짝**을 둔다. ⚠️ 미등록을 켤 때 메인 뷰 `flex` 를 `0 0 auto` 로 낮춘다(안 그러면 빈 껍데기가 화면 절반을 먹는다) — `1` 로 되돌리는 짝이 `hideUnregisteredTab()` 에 있다
  - ⚠️ **진입 화면은 부르는 쪽이 정한다**(`_settlementEntryView`) — 진입 로더가 마지막에 지급 준비를 켜므로 필터만 걸고 들어오면 조용히 덮인다. 값은 **실제로 이동하는 순간에만** 건다
- **관리자 정산 페인**(`/admin#settlements`, `dev/js/admin-settlements.js`): 진입 시 `backfillSettlements()` best-effort → 목록. 상태 탭 5종(`status-tab-bar`) + 캠페인 다중필터(`settlementCampMulti` — `syncCampMultiFilter` 재사용)·검색·엑셀. 행 버튼: **pending**=송금완료·보류·취소 / **paid**=보류(환수) / **on_hold**=보류 해제·취소 / **cancelled**=없음. 낙관적 락 충돌 시 RPC `-1`→「이미 처리됨」. 「이력」 모달(`get_settlement_events`) — **입력한 사유는 여기서만 보인다.** `menu.settlements` 는 campaign_admin=write·campaign_manager=hidden. **상한 적용 근거를 함께 보여준다** — 「영수증 ¥3,500 → 상한 적용」(엑셀도 영수증금액·상한·상한적용 3열). 판정 `settlementCapApplied` / 표시 `settlementAmountNote`. ⚠️ `Number(null)` 이 0 이라 **null 검사를 먼저** — 299 이전 행은 두 칸이 비어 있다. 영수증 수정 저장 후 **정산 페인도 갱신**(`refreshPane('settlements')`) — 302 이후 그 저장이 정산 상태를 바꿀 수 있다
- **정산 상태 변경 RPC 4종**(마이그레이션 222·223·224, SECURITY DEFINER·`has_permission('settlement.pay','write')`·version 충돌 시 -1): `mark_settlement_paid`(현재 원본 **486**, pending→paid, paypal_email 재조회·미등록이면 차단·events action='pay'. ⚠️ `settlement_paid` 알림 발행은 343 에서 제거) / `mark_settlement_hold`(pending·paid→on_hold, paid_* 보존) / `mark_settlement_cancel`(pending·on_hold→cancelled, paid는 먼저 보류) / `mark_settlement_revert`(224, on_hold→pending). 상태 전이: pending→paid/on_hold/cancelled, paid→on_hold, on_hold→pending/cancelled, cancelled=종료. storage.js `markSettlementPaid`/`markSettlementHold`/`markSettlementCancel`/`markSettlementRevert`(id, version, memo)
- **정산 자동 보류 + 반려 가드 2종**(마이그레이션 246·247 **+ 320**): 신청이 반려·취소되면 연결 정산이 `pending` 일 때 자동 `on_hold`(고정 memo `신청 반려로 자동 보류`, action='hold', `paid` 미변경). 「자동 보류(신청 반려)」 배지(`memo LIKE '%자동 보류%'`) — 복원은 `mark_settlement_revert`. 트리거 `auto_hold_settlement_on_app_reject`(AFTER UPDATE OF status) + `guard_reject_with_paid_settlement`(BEFORE UPDATE, 247 — 송금완료 정산이 있으면 반려·되돌리기 `RAISE 22023`). 화면 가드 `updateAppStatus` → `guardRejectOrRevert`(송금완료면 차단 / 제출 결과물 있으면 확인). **인플루언서 미노출**. ⚠️ **발동 조건은 320 이 현행** — `WHEN (NEW.status IN ('rejected','cancelled') AND OLD.status IS DISTINCT FROM NEW.status)`. `OLD.status='approved'` 를 요구하면 **「승인 → 되돌리기 → 미승인」 두 단계로 우회**돼 **되돌릴 수 없는 「송금완료 기록」 버튼이 활성**으로 남는다. 심사중에서 바로 가는 경로는 조기 반환. **앞으로만 막는다** — 과거분은 320 파일 하단 조회로 사람이 처리. 사양서 `docs/specs/2026-07-21-rejected-application-deliverable-and-settlement.md`
