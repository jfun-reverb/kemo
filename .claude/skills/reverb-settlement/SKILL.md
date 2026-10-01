---
name: reverb-settlement
description: 정산·송금·수수료·페이팔·회차·지급에 관한 질문에 답하거나, 정산 화면·정산 함수·정산 마이그레이션을 설계·수정·데이터 확인하기 전에 **반드시 먼저 부른다** — 파일을 검색하기 전에. REVERB JP 인플루언서 정산의 정본(규칙 파일·CLAUDE.md 정산 절·사양서)이 어디 있는지와 여는 순서를 알려 준다. 이런 말이 나오면 사용: 정산, 송금, 지급, 페이백, 페이팔(PayPal), 수수료, 송금 묶음, 송금 내역, 회차, 지급 준비, 회차 송금 명단 엑셀, 정산대기·송금완료·보류·취소, 자동 보류, 보류 해제, 미등록(과거 미등록) 정산, 컷오프·도입일, 인증 성공 금액, 영수증 금액·상한(제품 가격), 실제 송금액·송금일 정정, 정산 노출 잠금, 지급대장 대조, 이전 회차 미지급.
---

# REVERB 정산 길잡이

정산 규칙의 **정본은 이 스킬이 아니다.** 이 스킬은 어디를 열어야 하는지만 알려 준다.
여기에 규칙을 베껴 적지 않는다 — 사본이 생기면 한쪽만 고쳐져 어긋난다.

## 1. 먼저 연다 — 순서대로

1. **`.claude/rules/settlement.md` 를 Read 도구로 연다.**
   🔴 셸(`cat`·`sed`·`grep`)로 보면 안 된다 — 그러면 규칙 파일이 주입되지 않는다.
2. **`CLAUDE.md` 의 「### 정산」 절**을 읽는다. 특히:
   - 머리의 **「현재 원본 번호」** 줄 — 정산 함수를 재정의할 때 베이스가 되는 마이그레이션 번호
   - **잠금 상태**(인플루언서 노출 제거·`cutoff_at` 미설정)와 **「송금 묶음·수수료」** 단락
3. 질문이 특정 단계·기능이면 그 사양서의 「구현 결과」를 연다(아래 3절).

## 2. 함께 볼 자리

| 무엇 | 어디 |
|---|---|
| 관리자 정산 화면 | `dev/js/admin-settlements.js` |
| 정산 조회·기록 함수(화면 쪽) | `dev/lib/storage.js` (정산 관련 함수) |
| 회차 판정·금액 헬퍼 | `dev/lib/shared.js` — `payoutDueDate`·`settlementEffectiveAmount` 등 |
| 서버 함수·표 | `supabase/migrations/` — 번호는 CLAUDE.md 「현재 원본 번호」를 따른다 |

⚠️ 같은 판정이 화면과 서버에 **두 벌**인 것이 있다(예: 회차 판정). 한쪽을 고치면 짝을 찾는다 — 짝의 위치는 CLAUDE.md 정산 절에 적혀 있다.

## 3. 관련 사양서 (최근 것부터)

- 송금 묶음·수수료 — `docs/specs/2026-09-30-settlement-transfer-fee-record.md`
- 정산 목록 통합·지급 일정·3단계 송금 기록 — `docs/specs/2026-08-18-settlement-list-unification-and-payout-schedule.md`
- 영수증 실결제액 기준 금액 — `docs/specs/2026-08-05-settlement-receipt-amount-switch.md`
- 반려·취소 신청의 정산 처리 — `docs/specs/2026-07-21-rejected-application-deliverable-and-settlement.md`
- 최초 설계 — `docs/specs/2026-06-22-influencer-settlement.md`

`ls docs/specs | grep -i settlement` 로 전체 목록을 본다.

## 4. 🔴 되돌릴 수 없는 동작

송금 기록·묶음 기록·운영 데이터베이스 시험 호출처럼 **되돌릴 수 없는 것**은, 손대기 전에 반드시
**`CLAUDE.md` 정산 절의 🔴 경고를 직접 읽고** 확인한다. 이 스킬에 요약하지 않는다 — 요약이 낡으면 사고가 난다.
