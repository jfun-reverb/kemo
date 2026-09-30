---
description: 인플루언서 정산 — 정산 표·금액 규칙·상태 변경 함수
paths:
  - "dev/js/admin-settlements.js"
  - "supabase/migrations/*settle*"
  - "supabase/migrations/*payout*"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
---

# 정산 (인플루언서 리워드)

> 인증 성공 → 정산 대기 자동 등록 → PayPal 수동 송금 후 기록 → **관리자만 조회**. 엔화, 원천징수 없음(약관 제13조). 사양서 `docs/specs/2026-06-22-influencer-settlement.md`
- `settlement_events` — 금전 감사 이력(append-only). `settlement_id` **ON DELETE RESTRICT**(정산행은 하드 삭제 대신 cancelled)·`action`(create/pay/hold/cancel/revert)·`prev_status`/`next_status`·`actor`·`memo`·`at`. RLS SELECT `has_permission('settlement.view','read')`, INSERT 함수만
- **정산 금액 출처 = 모집 형식별 분기(마이그레이션 261·262·264)**: `settlements.amount_source`·`reward_part_jpy` 신설(261), **후보 조건 `c.reward > 0` 제거**(262). 금액이 NULL·0 이하면 `amount_issue` 로 사유를 세우고 **INSERT 대상에서 제외** — `settlements.amount_jpy CHECK(>0)` 위반으로 배치 전체가 실패하는 것을 막는다. **264**: 무보수 시딩·방문형(약관 제13조 3항)을 `_settlement_cert_candidates()` 에 `NOT (recruit_type<>'monitor' AND (reward IS NULL OR reward<=0))` 로 **후보에서 제외**(300·318 이 계승). 🔴 **이 항목의 「리뷰어형 = 상시가」는 아래 299·300 이 「영수증 실결제액(상시가를 상한으로)」으로 뒤집었다.** ⚠️ 운영 적용됨. 사양서 `docs/specs/2026-07-23-settlement-reviewer-receipt-amount.md`
- `settlement_settings` — 정산 도입일 싱글톤(id=1, `cutoff_at timestamptz NULL`, 마이그레이션 230). NULL=자동 0건. RLS SELECT `has_permission('settlement.view','read')` / UPDATE `is_super_admin()`(과거분 전체를 좌우하는 스위치). 도입일 이전분은 수동 처리(**무알림**). 조회 `get_past_unregistered_settlements()`(232, 인증성공 판정은 공통 헬퍼 `_settlement_cert_candidates()`로 3곳 공유, 명시적 컷오프 필터·PayPal은 `has_paypal` 불리언만)·처리 `register_past_settlements(uuid[], 'paid'|'pending', memo)`(233, 서버 재검증·멱등·**알림 INSERT 전무**)·정산 페인 「과거 미등록」 뷰(일괄 「송금완료 기록」[확인 모달]/「정산대기 추가」). 사양서 `docs/specs/2026-07-09-settlement-cutoff-past-handling.md`
- **보류 해제는 송금 기록 3칸을 비운다**(마이그레이션 416): `mark_settlement_revert`(on_hold→pending)가 `paid_at`·`paid_by`·`paid_amount_jpy` 를 NULL 로 하고 옛 값을 `settlement_events.memo` 에 「[송금 기록 초기화] 송금일 … · 송금액 …」로 남긴다(안 비우면 지급 준비 합계가 옛 금액으로 잡혀 과소 송금). 🔴 **보류·취소(223)는 그대로 보존한다** — 환수 근거. `paypal_email` 도 보존. `mark_settlements_paid_bulk`(현재 원본 **416**, 베이스 343)는 `paid_amount_jpy = NULL` 명시. 화면 `settlementEffectiveAmount`(shared.js)는 **정산대기 행이면 실제 송금액을 무시**(안전판). ⚠️ 이 두 함수의 베이스는 224·343 이 아니라 **416**
- `storage.js`: `fetchSettlements(opts)`(1000행 페이지네이션)·`backfillSettlements()`·`hasPaidSettlementForApplication(appId)`
