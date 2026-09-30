# 📋 작업 분해표 — 정산 송금 수수료·총지출 기록 (2단계: 송금 묶음·수수료 기록·조회, D-1~D-5)

**사양서:** `docs/specs/2026-09-30-settlement-transfer-fee-record.md`
**분해일:** 2026-09-30 / **총 작업 조각:** 17개(0~17, 8 결번) · **병렬 가능:** 2개(조각 0, 10) · **순차 필수:** 15개
**범위 밖:** 1단계(D-6 회차 엑셀 — #1797 개발서버 반영 완료), 3단계(시트 반영 — 별도 사양서)

> 아래 표·칸·함수 이름 중 사양서에 이름이 없던 것은 **제안 이름**이다(개발 세션이 확정). 단 **같은 이름을 쓰는 자리(서버 함수 ↔ `storage.js` ↔ 오류 문구 등록)는 한 세트로 함께** 정한다.

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| P1 | ~~1단계(D-6) 병합 뒤 화면 조각 착수~~ ✅ **충족** — #1797 `dev` 병합(2026-09-30) | 2단계 화면 조각이 같은 `dev/js/admin-settlements.js` | (해소) |
| P2 | **10/6 일반 문의 창구 운영 반영(마이그레이션 475~482) 뒤**에 이 사양서의 마이그레이션 4개 번호를 잡는다 | 사양서 「착수 전 알아야 할 것」(개발↔운영 대조 단순화). ⚠️ `dev` 에는 이미 **483** 까지 있다(483 은 운영 적용됨) — 새 번호는 그 뒤 | 1 (번호 확정 시점) |
| P3 | **`/약관확인` 1회** — 결론이 「방침 개정 불필요」인지 확인 | 사양서 「의심」 9번. 페이팔 거래번호·수수료는 회사 내부 기록, 회원 화면 변화 없음 → 불필요로 보이나 확인 전제 | 17 (운영 배포) |
| P4 | 조각 1~7(데이터베이스)은 **한 세션이 순차로** | 순차 번호 파일 + 같은 함수 여러 번 재정의 | 1~7 |

---

## ⚠️ 사양서 stale 점검 (2026-09-30 코드 확인)

| # | 사양서(또는 요청문)가 적은 것 | 실제 코드 | 영향 |
|---|---|---|---|
| S1 | 현재 원본: `register_past_settlements` 339 · `mark_settlement_paid` 343 · `mark_settlements_paid_bulk` 416 · `mark_settlement_revert` 416 · `correct_settlement_payment` 341 · 보류·취소 223 | **일치.** 정의 파일: register 233·262·300·324·**339** / paid 222·241·339·**343** / bulk 340·343·**416** / revert 224·**416** / correct **341** / hold·cancel **223** | 없음 |
| S2 | 오류 코드는 「화면 번역 함수 두 곳(`ui.js` friendlyError · `shared.js`)」 | 🔴 **관리자 한국어 번역은 `dev/js/admin-core.js` `friendlyError`**(약 131행). `ui.js` 는 `friendlyErrorJa`(**인플루언서 일본어**). `shared.js` `APP_ERROR_EXPECTED_PATTERNS` 는 번역이 아니라 **「의도된 거부」 분류**. 관리자 오류 로그 표시 문구는 `dev/js/admin-errors.js` | 등록 자리 = **`admin-core.js` friendlyError + `shared.js` APP_ERROR_EXPECTED_PATTERNS (+ 선택 `admin-errors.js`)**. ⚠️ `friendlyError` 는 한글이 섞인 메시지를 그대로 보여주고, `not found` 같은 일반 규칙이 앞에 있어 **새 코드 규칙은 일반 규칙보다 먼저** |
| S3 | 확인 창 = `openPayoutSendSelectedModal` 확장 | 🔴 실제 처리는 **공용 창 하나**: `_openBulkPayModal` → `settlementBulkPayModal`(`dev/admin/index.html`, z-index 615) → `confirmSettlementBulkPay`. **진입점이 다섯**: ①`openSettlementBulkPayModal`(정산 목록 선택) ②`pastUnregRegister`(과거 미등록 — `mode` paid/pending) ③`openPayoutSendOneModal`(지급 준비 건별) ④`openPayoutSendModal`(사람·회차 묶음) ⑤`openPayoutSendSelectedModal` | **①③④도 같은 창이라 함께 새 함수로** — 처리 함수가 하나라 유리. 다섯 진입점이 넘기는 행 모양이 달라(`_payoutRows` / `_settlements` / `_pastUnregById`) **공통 항목으로 정규화** 필요 |
| S4 | (암묵) `register_past_settlements` 의 `'pending'` 은 그대로 | 같은 `confirmSettlementBulkPay` 가 `ctx.mode==='pending'` 이면 `'pending'` 호출 | 창을 바꿀 때 **정산대기 추가 분기 보존** |
| S5 | (없음) | `fetchSettlements`(`dev/lib/storage.js`)는 **열 목록 명시형** — 새 칸을 안 적으면 오류 없이 빈 값. **조회문 문자열 안 주석 금지**(PGRST100 → 화면 통째 빔) | 조각 9 계약 |
| S6 | 불변식 「건 `paid_amount_jpy` = 연결 금액」 | 지금 NULL 은 「계산값과 같음」 뜻(416 일괄이 NULL 명시). 화면이 NULL 이면 「계산 금액 그대로」 표시 | 새 함수는 **항상 숫자**(NULL 금지). `settlementEffectiveAmount` 는 양쪽 처리 |
| S7 | 회차별 합계는 서버 함수로 | 회차 규칙 `payoutDueDate`(`dev/lib/shared.js`) **한 벌**, 주석 「계산은 이 함수 하나로만」 | 서버 집계는 **SQL 사본**이 생긴다(판정 두 벌) → 조각 7·16 에 「두 벌」 경고. `cert_at` NULL 은 「지급일 기록 없음」 |
| S8 | 보류 해제 이력 번호 = `settlement_events.id` | **uuid**(217) | 연결 표 표시 칸은 uuid 외래 키 |
| S9 | (없음) | 기록·정정 버튼마다 `settlementBulkLocked()` 게이트(지금 `SETTLEMENT_BULK_UNLOCKED = true`) | 새 경로도 같은 게이트 |
| S10 | (없음) | `_payoutUnaccounted` 는 「서버가 건너뛴다」 전제의 보정 | `paid` 경로에선 불필요, `pending` 경로에선 유지 |

---

## 한눈에 보는 의존 순서

```
P2 번호 시점 확인
0 약관 확인 ∥ 1 수수료 규칙(DB①)
1 → 2 묶음 구조(DB②) → 3 판정 헬퍼+339 재정의(DB③) → 4 새 기록 함수(DB③) → 5 정정·보류 해제(DB③) → 6 옛 경로 거부(DB③) → 7 조회 함수(DB④)
7 → 9 storage.js 래퍼 → 11 확인 창 → 12 단건·정정 모달 → 13 수수료 설정 → 14 송금 내역 화면 → 15 합계 탭
9 → 10 오류 문구 등록 ∥ 11~15
15 → 16 문서 → 17 배포(개발 DB→개발 화면→운영 DB→운영 화면→첫 기록) → Notion
```

---

## 작업 조각 표

| # | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 0 | 약관 영향 확인 | `docs/{TERMS,PRIVACY}_*.md`(읽기) | 「개정 불필요/필요」 결론 1줄 | 없음 | ✅ 1과 | 기획·고문 |
| 1 | 수수료 규칙 표+이력+조회·수정 함수 | 새 마이그레이션 ① | `settlement_fee_rule`·`…_history`·`get_settlement_fee_rule()`·`update_settlement_fee_rule(…)` | P2 | ✅ 0과 | 개발(DB) |
| 2 | 송금 묶음·연결·묶음 이력 표 + 정산 행 「현재 묶음」 칸 | 새 마이그레이션 ② | `settlement_transfers`·`settlement_transfer_items`·`settlement_transfer_events`·`settlements.current_transfer_id` | 1 | ✗ | 개발(DB) |
| 3 | 미등록 판정 공용 헬퍼 + 339 재정의 | 새 마이그레이션 ③ | `_settlement_register_judge(uuid[])` → (응모, 판정, 사유) | 2 | ✗ | 개발(DB) |
| 4 | 새 기록 함수(한 트랜잭션·건너뛰지 않음) | 마이그레이션 ③ | `record_settlement_transfers(jsonb)` | 3 | ✗ | 개발(DB) |
| 5 | 묶음 정정 + 341 재정의 + 416 보류 해제 재정의 | 마이그레이션 ③ | `correct_settlement_transfer(…)`·341·416 | 4 | ✗ | 개발(DB) |
| 6 | 옛 송금완료 경로 셋 — 도입일 뒤 거부 | 마이그레이션 ③ | `_settlement_transfer_intro_at()` + 343·416 일괄·339(`'paid'`만) 거부 `payout_bundle_required` | 5 | ✗ | 개발(DB) |
| 7 | 조회 함수 넷 | 새 마이그레이션 ④ | 목록·월별·회차별·수수료 기록 없음 | 6 | ✗ | 개발(DB) |
| 8 | (결번 — 검증은 각 조각 완료 정의에 포함) | — | — | — | — | — |
| 9 | `storage.js` 래퍼 | `dev/lib/storage.js`(핫스팟) | 함수 8개 + `fetchSettlements` 열 추가 | 7 | ✗ | 개발 |
| 10 | 오류 문구 등록 | `dev/js/admin-core.js`·`dev/lib/shared.js`(핫스팟)·`dev/js/admin-errors.js` | 코드 목록 전부 한국어 문구 | 9 | ✅ 11~15와 | 개발 |
| 11 | 확인 창 개편(다섯 진입점 공용) | `dev/js/admin-settlements.js`(+ `dev/admin/index.html` 최소) | 사람별 묶음·나누기·송금일·건별 금액·수수료·합계 | 9 | ✗ | 개발 |
| 12 | 단건 송금완료 전환 + 기록 정정 모달 송금일 잠금 | `admin-settlements.js` | 단건 = 묶음 1개 / 현재 묶음 있으면 날짜 칸 잠금 | 11 | ✗ | 개발 |
| 13 | 「수수료 설정」 모달 | `admin-settlements.js`(+ 진입 단추 `index.html`) | 규칙 조회·수정·이력 | 12 | ✗ | 개발 |
| 14 | 넷째 화면 「송금 내역」 목록+엑셀+묶음 정정 | `admin-settlements.js`·`dev/admin/index.html` | 배타 짝 4방향 + 목록·펼침·기간 필터·엑셀 | 13 | ✗ | 개발 |
| 15 | 월별·회차별·「수수료 기록 없음」 | `admin-settlements.js` | 서버 집계만 그림 | 14 | ✗ | 개발 |
| 16 | 문서 갱신 | `CLAUDE.md`·`docs/FEATURE_SPEC.md`·사양서 「구현 결과」 | 현재 원본 번호 교체·경고 | 15 | ✗ | 개발 |
| 17 | 배포(데이터베이스 먼저) + 첫 기록 + Notion | SQL 편집기·병합 요청·Notion | 운영에서 도입일 성립 확인 | 16, P3 | ✗ | 개발+사용자 |

---

## 조각별 상세

### 조각 0 — 약관 영향 확인
- **하는 일**: `/약관확인`. 확인 대상 — 약관 제13조 2항(수수료 회사 부담, `docs/TERMS_kr.md`·`_ja.md` 120행 부근), 방침의 정산 처리 항목에 「페이팔 거래번호」가 새 수집 항목으로 읽히는지.
- **산출 계약**: 「개정 불필요」 또는 「필요 — 어느 조항」 한 줄을 사양서 「구현 결과」 또는 병합 요청 본문에.
- **완료 정의**: 결론 한 줄이 기록돼 있다.
- **주의**: 개정 필요로 나오면 조각 17 이 시행일 규칙(`.claude/rules/release-timing.md`)을 탄다.
- ✅ **결과(2026-09-30, 기획 `/약관확인`) — 개정 불필요.**
  - 약관 제13조 2항(수수료·세금 회사 부담, 회원은 전액 수령)과 맞는다. 수수료 규칙을 바꿔도 회원이 받는 금액은 안 바뀐다.
  - 방침: 회원에게서 새로 **수집**하는 항목이 없다(송금 묶음·페이팔 거래번호는 회사가 송금하며 생기는 기록). 방침 §6.1 「세무 신고 관련 자료(리워드 지급 내역, 영수증) 5년」에 들어간다. 새 외부 서비스·국외 이전 없음, 회원 화면·메일 변화 없음 → 공고·재동의 불필요.
  - 탈퇴 파기: 묶음에 페이팔 주소를 두지 않으므로(사양서 D-1) 363 의 두 곳 그대로. 묶음이 남기는 회원 식별은 회원 id 뿐이고 정산 행과 같은 보관 방식이다.
  - ⚠️ 이 변경과 별개로 관찰한 것(판단은 사용자·고문): 3단계 원천인 운영 지급 시트(구글 드라이브)에 회원 이메일·페이팔 주소가 있고 탭 이름 4개가 회원 이메일이다. 방침 §4 처리위탁의 Google LLC 는 자동 번역 용도로만 적혀 있다 — 운영팀 업무 도구로서의 표기가 필요한지는 이 사양서 범위 밖.

### 조각 1 — 수수료 규칙 표 + 이력 + 조회·수정 함수 (마이그레이션 ①)
- **산출 계약**
  - 표 `settlement_fee_rule`(한 줄, `id=1`): `rate_percent numeric NOT NULL`(초기 4.1) · `fixed_jpy integer NOT NULL`(초기 50) · `rounding text NOT NULL CHECK (rounding IN ('round','floor','ceil'))`(초기 `round`) · `updated_at` · `updated_by`. 범위 검사(`rate_percent` 0~100, `fixed_jpy` ≥ 0).
  - 표 `settlement_fee_rule_history`(추가만): 이전·새 값 3종 · `actor` · `at`.
  - 행 단위 보안 정책: 조회 `has_permission('settlement.view','read')`, **쓰기 정책 없음**.
  - `get_settlement_fee_rule()` — `settlement.view` 읽기 가드.
  - `update_settlement_fee_rule(p_rate_percent numeric, p_fixed_jpy integer, p_rounding text)` — `has_permission('settlement.pay','write')`, 이력 한 줄, 거부 코드 `fee_rule_invalid`.
  - 전부 `SECURITY DEFINER` + `SET search_path = ''`. 실행 권한: `REVOKE … FROM PUBLIC` **와** `REVOKE … FROM anon` 둘 다, `GRANT … TO authenticated`.
- **선행**: P2
- **완료 정의**: 개발 데이터베이스 적용 뒤 **로그인한 관리자 브라우저**에서 두 함수 각 1회 — 조회가 4.1/50/round, 수정 뒤 이력 1행. 캠페인 매니저로 부르면 거부.
- **필요 검문소**: `reverb-supabase-expert`
- **주의·롤백**: 새 표·함수뿐이라 `DROP` 으로 되돌림. SQL 편집기는 서비스 키라 권한 분기가 안 돈다 — 브라우저로 확인.

### 조각 2 — 송금 묶음·연결·묶음 이력 표 + 「현재 묶음」 칸 (마이그레이션 ②)
- **산출 계약**
  - `settlement_transfers`(송금 묶음 = 페이팔 거래 1건): `id uuid` · `sent_at timestamptz NOT NULL`(🔴 송금일의 정본) · `influencer_id uuid NOT NULL` · `sent_total_jpy bigint NOT NULL`(서버 계산) · `fee_jpy bigint NOT NULL` · `fee_rate_percent`·`fee_fixed_jpy`·`fee_rounding`(규칙 스냅샷) · `fee_manual boolean NOT NULL` · `paypal_txn_id text NULL` · `memo` · `source text NOT NULL CHECK (source IN ('app','sheet_backfill'))` · `recorded_by` · `recorded_at` · `version integer`. 🔴 **페이팔 주소 칸을 두지 않는다**(363 파기 대상이 두 곳뿐).
  - `settlement_transfer_items`(연결): `transfer_id` 외래 키 · `settlement_id` 외래 키(**ON DELETE RESTRICT**) · `amount_jpy bigint NOT NULL CHECK (>0)` · `created_at` · `revert_event_id uuid NULL` → `settlement_events(id)`. **NULL = 「현재 송금 기록」**, 값 = 「그 보류 해제 이력에 속한 옛 송금」. 부분 유일 색인 `(settlement_id) WHERE revert_event_id IS NULL`. `(transfer_id, settlement_id)` 유일.
  - `settlement_transfer_events`(묶음 이력, 추가만): `transfer_id` · `action` · 이전·새 값 jsonb · `actor` · `at`.
  - `settlements.current_transfer_id uuid NULL` → `settlement_transfers(id)`.
  - 세 표 모두 조회 `has_permission('settlement.view','read')`, 쓰기 정책 없음.
- **선행**: 1
- **완료 정의**: 기존 `settlements` 행 전부 `current_transfer_id` NULL, 새 표 0행. 관리자 브라우저에서 새 표 조회가 오류 없이 0건.
- **필요 검문소**: `reverb-supabase-expert`
- **주의**: 🔴 불변식(현재 묶음 있으면 건 `paid_at` = 묶음 `sent_at`, 건 `paid_amount_jpy` = 현재 연결 금액)은 **표 제약으로 못 건다** — 조각 4·5 함수가 지킨다. 위반을 세는 점검 조회를 마이그레이션 주석으로(조각 17에서 돌림).

### 조각 3 — 미등록 판정 공용 헬퍼 + `register_past_settlements` 재정의 (마이그레이션 ③)
- **산출 계약**
  - `_settlement_register_judge(p_application_ids uuid[])` RETURNS TABLE(`application_id`, `ok boolean`, `reason text`, `amount_jpy`, `influencer_id`, `campaign_id`, `cert_at`, `paypal_email` …). 사유: `not_candidate` · `already_registered` · `amount_issue` · `paypal_missing`. 판정 근거는 `_settlement_cert_candidates()`(현재 원본 **455**) + 339 의 금액·페이팔 판정과 **글자 그대로 같게**. 실행 권한 없음(내부 전용).
  - `register_past_settlements` — **베이스 339**, 판정만 헬퍼로 교체. 반환 모양·「건너뛰기」 동작 **그대로**.
- **선행**: 2
- **완료 정의**: 재정의 전후 같은 응모 목록을 `'pending'` 으로 넣었을 때 반환 건수가 같다. 헬퍼 사유가 네 종류로 갈린다.
- **필요 검문소**: `reverb-supabase-expert`(339 가 현재 원본 — 324·300 베이스 금지)
- **주의**: 옛 함수는 여전히 건너뛰고, **사유로 올려 거부**하는 것은 새 함수(조각 4)만.

### 조각 4 — 새 기록 함수 (마이그레이션 ③)
- **산출 계약**
  - `record_settlement_transfers(p_bundles jsonb) RETURNS jsonb`
  - 입력: `[{ settlement_ids: uuid[], application_ids: uuid[], item_amounts: {"<id>": 금액}, sent_at, fee_jpy|null, paypal_txn_id|null, memo, source: 'app'|'sheet_backfill' }, …]`
  - 동작: ①정산대기 건 잠금(`DISTINCT … ORDER BY` — 340 방식) ②미등록 응모는 조각 3 헬퍼로 판정 후 정산 행 생성 ③연결 행(금액 = 입력값, 비우면 `amount_jpy`) ④`sent_total_jpy` = 연결 합 ⑤수수료 = 입력값이면 그 값 + `fee_manual=true`(**계산값과 같아도 켠다**), 비우면 `round/floor/ceil(합 × 비율/100 + 고정액)` + 스냅샷 ⑥건 `status='paid'`, `paid_at = sent_at`, **`paid_amount_jpy = 연결 금액(숫자)`**, `paypal_email` = 최신값, `current_transfer_id` = 묶음 ⑦`settlement_events` 에 건마다 `pay`(미등록은 `create`+`pay`) ⑧묶음 이력 `create`.
  - 🔴 **건너뛰지 않는다**: 거부 사유 `bundle_paypal_missing` · `bundle_not_pending` · `bundle_not_found` · `bundle_not_candidate` · `bundle_amount_issue` · `bundle_empty` · `bundle_duplicate_item` · `bundle_amount_invalid` · `sent_at_in_future`. 하나라도 걸리면 **아무것도 쓰지 않고** `{ok:false, failures:[{bundle_index, settlement_id|application_id, reason}]}`.
  - 성공: `{ok:true, transfer_ids:[…], settlement_count, fee_total}`. 가드 `has_permission('settlement.pay','write')`. 🔴 인플루언서 알림 없음(343).
- **선행**: 3
- **완료 정의**(개발 데이터베이스, 관리자 브라우저): ①정산대기 2건 + 미등록 1건 한 묶음 → 묶음 1·연결 3·건 3개 `paid`·`current_transfer_id` 채워짐 ②수수료 비우고 ¥3,000 → 173엔 ③페이팔 없는 건을 섞으면 `ok:false` 이고 **어떤 행도 안 생김** ④같은 건 재기록 시 `bundle_not_pending`.
- **필요 검문소**: `reverb-supabase-expert`, `reverb-reviewer`
- **주의**: 🔴 예외를 던지면 사유 목록을 돌려줄 수 없다 — 권장은 **「전부 잠그고 검사 → 실패면 쓰기 전에 반환 → 통과면 쓰기」**. 쓰기 도중 예상 밖 오류는 예외로 전체 롤백. **부분 기록이 남는 경로는 없어야** 한다.

### 조각 5 — 묶음 정정 + 341 재정의 + 416 재정의 (마이그레이션 ③)
- **산출 계약**
  - `correct_settlement_transfer(p_transfer_id uuid, p_version integer, p_sent_at timestamptz, p_fee_jpy bigint, p_paypal_txn_id text, p_memo text)` — NULL 은 「안 고침」, 버전 충돌 `-1`. 송금일을 고치면 **`current_transfer_id = 이 묶음`인 건들의 `paid_at` 만** 함께. 수수료를 넘기면 `fee_manual=true`. 이력 `settlement_transfer_events`.
  - `correct_settlement_payment` — **베이스 341**, 시그니처 불변. ①건에 `current_transfer_id` 가 있고 `p_paid_at` 이 현재 값과 다르면 거부 `paid_at_owned_by_transfer` ②금액을 바꾸면 **현재 연결 금액도** 함께 → 묶음 합 재계산 → `fee_manual=false` 면 스냅샷으로 수수료 재계산, `true` 면 그대로 ③`current_transfer_id` 가 없으면 종전대로.
  - `mark_settlement_revert` — **베이스 416**, 시그니처 불변. 이력 INSERT 에 `RETURNING id INTO v_event_id` → 그 건의 현재 연결을 `revert_event_id = v_event_id` 로 → `current_transfer_id = NULL`. **연결 행을 지우지 않는다**.
- **선행**: 4
- **완료 정의**: ①341 로 금액 정정 → 연결 금액·묶음 합·(자동이면) 수수료가 함께 바뀜 ②341 로 날짜 변경 시 `paid_at_owned_by_transfer` ③묶음 송금일 정정 → 건 `paid_at` 따라옴 ④보류 → 보류 해제 → `current_transfer_id` NULL, 연결은 남고 `revert_event_id` 가 방금 이력 id ⑤그 건을 다시 보내면 연결 두 개 — 유일 색인 위반 없음.
- **필요 검문소**: `reverb-supabase-expert`(341·416 현재 원본), `reverb-reviewer`
- **주의**: `settlement_events.action` 검사 제약(341 이 7종)은 **안 넓힌다**(묶음 이력은 별도 표). 넓혀야 하면 베이스 341.

### 조각 6 — 옛 송금완료 경로 셋 도입일 뒤 거부 (마이그레이션 ③ 끝)
- **산출 계약**
  - `_settlement_transfer_intro_at() RETURNS timestamptz` = `MIN(recorded_at) FROM settlement_transfers WHERE source='app'`. 실행 권한 없음.
  - `mark_settlement_paid`(베이스 **343**) · `mark_settlements_paid_bulk`(베이스 **416**) · `register_past_settlements`(조각 3 판, **`'paid'` 만**) 맨 앞: 도입일이 NULL 이 아니면 `RAISE EXCEPTION 'payout_bundle_required: …'`. 모두 `CREATE OR REPLACE`(권한 보존), 삭제 안 함.
- **선행**: 5
- **완료 정의**: ①묶음 0개(`source='app'`)면 세 옛 경로가 지금처럼 동작 ②`source='app'` 묶음 1개 뒤 세 옛 경로 `paid` 호출이 `payout_bundle_required` ③`'pending'` 은 계속 성공 ④`sheet_backfill` 묶음만 있으면 거부 **안** 켜짐.
- **필요 검문소**: `reverb-supabase-expert`
- **주의**: 🔴 **운영에서 SQL 편집기로 새 함수를 시험 호출하지 말 것** — `source='app'` 묶음 한 줄이면 옛 화면의 「선택한 건 보냄」·단건 송금완료가 전부 막힌다. 개발서버도 시험 뒤엔 옛 화면이 막히므로 옛 경로 확인은 시험 전에.

### 조각 7 — 조회 함수 넷 (마이그레이션 ④)
- **산출 계약**(모두 `settlement.view` 읽기 가드, `authenticated` 만 실행)
  - `get_settlement_transfers(p_from date, p_to date)` — 묶음 1줄 + 포함 건 jsonb(캠페인·원래 지급 예정일·연결 금액·연결 종류) + 「금액이 바뀌었는데 수수료는 손으로 고친 값」 표시. 고유 정렬(`sent_at, id`).
  - `get_settlement_transfer_monthly(p_from, p_to)` — 송금일 **일본 시각** 기준 달별.
  - `get_settlement_transfer_by_round(p_from, p_to)` — 🔴 보낸 금액은 **건의 원래 회차**, 수수료는 **묶음 안 가장 늦은 원래 회차**에 통째로. 회차 헬퍼 `_settlement_payout_due(cert_at timestamptz) RETURNS date`(`payoutDueDate` 의 SQL 사본). `cert_at` NULL 은 「지급일 기록 없음」.
  - `get_settlement_transfer_unrecorded()` — `paid_at IS NOT NULL AND current_transfer_id IS NULL` 건수·보낸 금액(`COALESCE(paid_amount_jpy, amount_jpy)`).
  - 합계는 **저장값만** 더한다.
- **선행**: 6
- **완료 정의**: 월별 수수료 합 = 목록 수수료 합 = 회차별 수수료 합, 「기록 없음」 건수 = 개발서버 옛 송금완료 건수.
- **필요 검문소**: `reverb-supabase-expert`
- **주의**: 🔴 회차 판정 **두 벌**(`payoutDueDate` · `_settlement_payout_due`) — 두 파일에 서로 가리키는 주석. 원격 호출도 1,000행에서 잘린다 → 조각 9 에서 `fetchAllPaged` + 고유 정렬.

### 조각 9 — `storage.js` 래퍼
- **산출 계약**: `fetchSettlementFeeRule()` · `updateSettlementFeeRule(ratePercent, fixedJpy, rounding)` · `recordSettlementTransfers(bundles)` → `{ok, failures|transferIds}` · `correctSettlementTransfer(id, version, sentAt, feeJpy, txnId, memo)` · `fetchSettlementTransfers(from, to)`(`fetchAllPaged`) · `fetchSettlementTransferMonthly(from,to)` · `fetchSettlementTransferByRound(from,to)` · `fetchSettlementTransferUnrecorded()`. **조회 실패 `null`, 0건 `[]`**. `fetchSettlements` 열 목록에 `current_transfer_id`(조회문 안 주석 금지). 빈 문자열 → `null`.
- **선행**: 7
- **완료 정의**: 관리자 콘솔에서 여덟 함수 각 1회 기대 모양, 정산 목록이 그대로 뜬다.
- **필요 검문소**: `reverb-reviewer`

### 조각 10 — 오류 문구 등록
- **담당 파일**: `dev/js/admin-core.js`(`friendlyError`, **일반 규칙보다 앞**) · `dev/lib/shared.js`(`APP_ERROR_EXPECTED_PATTERNS`) · `dev/js/admin-errors.js`(선택)
- **산출 계약**: `payout_bundle_required` → 「송금 기록 방식이 바뀌었습니다. 화면을 새로 고친 뒤 다시 기록해 주세요.」 · `paid_at_owned_by_transfer` → 「이 건의 송금일은 「송금 내역」에서 송금 단위로 고칩니다.」 · `fee_rule_invalid` · `bundle_*` 9종 · `sent_at_in_future`.
- **선행**: 9 · **병렬**: 11~15 와 가능
- **완료 정의**: 옛 탭 시나리오에서 한국어 「새로 고쳐 주세요」가 뜬다.

### 조각 11 — 확인 창 개편 (다섯 진입점 공용)
- **담당 파일**: `dev/js/admin-settlements.js` · `dev/admin/index.html`(최소 — 창 본문은 동적 생성 권장)
- **산출 계약**
  - 다섯 진입점(S3)의 행을 공통 항목 `{kind:'settlement'|'unregistered', settlementId, applicationId, influencerId, name, paypal, amount, due, campaignLabel}` 로 정규화해 `_bulkPayCtx.items`.
  - `mode==='pending'` 은 **지금 창·지금 동작 그대로**.
  - `paid` 새 창: 사람마다 묶음 1개 기본 · 「나누기」 · 묶음별 송금일(기본 오늘, 일본 시각) · 건별 보낸 금액 · 묶음 합 · 수수료(서버 규칙으로 **미리보기만**, 고친 칸 표시) · 총지출 · 전체 합계 · 거래번호(선택)·메모.
  - 페이팔 미등록 건은 **선택에서 빼고 「보낼 수 없음」**.
  - 저장 = `recordSettlementTransfers` **한 번**. `ok:false` 면 사유별 안내 + 목록 새로 받기 — 창을 닫지 않는다. 성공이면 `_settlementRefreshKeepingView(ctx.from)`.
  - `settlementBulkLocked()` 게이트 유지.
- **선행**: 9
- **완료 정의**(개발서버, 좌표 클릭으로 보이게): ①「선택한 건 보냄」으로 2명 → 묶음 2개 ②「나누기」로 묶음 2개 → 수수료 50엔이 두 번 ③수수료 고친 묶음 `fee_manual=true` ④다섯 진입점 모두 같은 창 ⑤과거 미등록 「정산대기 추가」는 종전 창·동작.
- **필요 검문소**: `reverb-reviewer`, `reverb-qa-tester` 권장(단일 세션)
- **주의**: 🔴 수수료 계산식 사본 금지. 30명 이상이면 수수료 칸은 기본 읽기 표시, 고칠 때만 입력.

### 조각 12 — 단건 송금완료 전환 + 기록 정정 모달 송금일 잠금
- **산출 계약**: 단건 「송금완료」(`markSettlementPaid` 호출 자리)를 `recordSettlementTransfers([{settlement_ids:[id], …}])` 로. 기존 금액·날짜 입력은 연결 금액·송금일로, 수수료 칸 추가. 기록 정정 모달(`openSettlementCorrectModal`·`confirmSettlementCorrect`): `current_transfer_id` 가 있으면 **날짜 칸 잠금 + 「송금일은 송금 내역에서」**, 금액만.
- **선행**: 11
- **완료 정의**: 행 「송금완료」로 1건 → 묶음 1개. 그 건 「기록 정정」에서 날짜 잠김·금액만 바뀌며 묶음 합이 따라 바뀐다. 도입 전 송금완료 건은 날짜 칸이 열려 있다.
- **필요 검문소**: `reverb-reviewer`

### 조각 13 — 「수수료 설정」 모달
- **산출 계약**: 정산 관리 상단 「수수료 설정」 → 비율(%)·고정액(엔)·끝수 처리(반올림/버림/올림) + 최근 이력. 저장은 `settlement.pay` 쓰기 권한자만(아니면 **숨기지 않고 비활성** + 「변경 권한이 없습니다」). 「이미 기록한 송금은 바뀌지 않습니다」 고정 안내. 저장 뒤 `refreshPane('settlements')`.
- **선행**: 12
- **완료 정의**: 4.1 → 4.0 저장 후 새 기록 자동 수수료가 바뀌고 이전 묶음은 그대로. 이력 한 줄.

### 조각 14 — 넷째 화면 「송금 내역」
- **담당 파일**: `admin-settlements.js` · `dev/admin/index.html`(`settlementTransferView` 컨테이너 + 진입 단추)
- **산출 계약**
  - `openTransferHistoryView()` / `closeTransferHistoryView()`. 🔴 **배타 짝 4방향**: 이 함수가 목록·미등록·지급 준비를 닫고, `showUnregisteredTab`·`openPayoutPrepView`·목록 켜기 경로(`hideUnregisteredTab`)·`closePayoutPrepView`·`enterSettlementsWithView`·진입 로더가 이 화면을 닫는다. `_settlementEntryView` 값 `'transfers'` 추가. `applySettlementSharedFilterMode` — 공용 필터 줄은 이 화면에서 감춘다(사용자 확인 2).
  - 목록: 송금일·받는 사람(이름·`settlements.paypal_email` 스냅샷)·건수·보낸 금액·수수료(고친 값 표시)·총지출·거래번호, 펼치면 포함 건. 기간 필터. 엑셀(송금 내역 + 포함 건 시트).
  - 묶음 「정정」 → `correctSettlementTransfer` 모달, 저장 뒤 목록 갱신.
  - 조회 실패(`null`) 「불러오지 못했습니다 — 보낸 것이 없다는 뜻이 아닙니다」, 0건 별도 문구.
- **선행**: 13
- **완료 정의**: 「송금 내역」 ↔ 지급 준비 ↔ 미등록 ↔ 정산 목록을 어떤 순서로 오가도 **한 화면만** 보인다. 묶음 송금일 정정 → 포함 건 `paid_at` 도 바뀐다. 엑셀 수수료 합 = 화면 합.
- **필요 검문소**: `reverb-reviewer`, `reverb-qa-tester` 권장
- **주의**: 🔴 짝 하나라도 빠지면 두 화면이 겹친다(2026-08-18·19 실제 사고). 메인 뷰 `flex` 높이 짝도 같은 방식으로.

### 조각 15 — 월별·회차별·「수수료 기록 없음」
- **산출 계약**: 「송금 내역」 안 보기 전환(목록/월별/회차별). 회차별 머리에 「수수료는 묶음 안 가장 늦은 회차에 통째로 — 송금일 기준은 월별」. 「수수료 기록 없음」: 건수·보낸 금액만, **0엔으로 더하지 않음**, 「도입 전 송금 — 3단계에서 시트로 채웁니다」.
- **선행**: 14
- **완료 정의**: 월별·회차별·목록 수수료 합이 같은 기간에서 같다. 「기록 없음」 건수 = 조각 7 결과.

### 조각 16 — 문서
- **산출 계약**: `CLAUDE.md` 「정산」 절 — 현재 원본 번호 교체, 도입일 거부·「운영에서 새 함수 시험 호출 금지」, 회차 판정 두 벌, 확인 창 진입점 다섯. `docs/FEATURE_SPEC.md`. 사양서 「구현 결과」. ⚠️ 규칙 파일은 고문에게.
- **완료 정의**: 코드 커밋과 **같은 커밋**.

### 조각 17 — 배포
- **순서**(🔴 데이터베이스 먼저·화면 나중): ①개발 데이터베이스 ①~④ → 개발 화면 병합 → 개발서버 검증 ②운영 데이터베이스 ①~④(묶음 0개라 옛 화면 정상) ③운영 화면 병합(골라 담기 필요 여부 확인) ④새 화면으로 **첫 송금 기록** → 도입일 성립 → 옛 탭 거부 확인 ⑤불변식 점검 조회 0건 ⑥Notion 「정산 관리」 갱신.
- **선행**: 16, P3
- **완료 정의**: 운영 `_settlement_transfer_intro_at()` NULL 아님, 불변식 위반 0건, 옛 탭 「새로 고쳐 주세요」.
- **주의**: 🔴 운영 SQL 편집기에서 `record_settlement_transfers` 시험 호출 금지. 롤백 — 화면만 되돌리면 도입일이 섰을 때 옛 화면이 전부 막힌다 → 조각 6 거부 조항부터 되돌리는(343·416·339 재적용) 마이그레이션을 먼저.

---

## ⚠️ 공유 지점 경고
- **`dev/js/admin-settlements.js`** — 조각 11~15 전부. 같은 파일이라 순차.
- **`dev/lib/storage.js`·`dev/lib/shared.js`·`dev/admin/index.html`·`dev/js/admin-core.js`** — 핫스팟. 조각 9·10·14 만, 병렬 분기 금지.
- **확인 창 하나에 진입점 다섯**(S3) — 한 진입점만 바꾸면 나머지 넷은 도입일 뒤 막힌다.
- **옛 경로 거부의 발동 조건이 데이터**(`source='app'` 묶음 존재) — 시험 호출 한 번이 스위치를 켠다.
- **회차 판정 두 벌**(`payoutDueDate` · `_settlement_payout_due`).
- **불변식 지키는 자리**: 조각 4 · 5(341·416·묶음 정정) · 3단계 반영 함수(범위 밖).
- **페이팔 주소는 묶음에 두지 않는다**(363) — 엑셀·화면은 `settlements.paypal_email` 스냅샷.

## 🧭 배분 제안
- **개발 세션 A(한 세션)**: 조각 1→2→3→4→5→6→7→9 (데이터베이스 + 래퍼) — P2(10/6 뒤) 이후.
- **기획/고문**: 조각 0(`/약관확인`) — 조각 1과 동시에.
- **개발 세션 A 계속**: 조각 10→11→12→13→14→15→16→17. 조각 10은 짧아 별도 세션 불필요.
- ⚠️ 데이터베이스 조각을 두 세션으로 나누지 말 것 — 같은 함수(339·341·416)를 연달아 재정의한다.

### 사용자 결정 (2026-09-30)
1. **거부 방식 = 먼저 검사 후 기록** — 모든 건을 잠그고 검사해 하나라도 걸리면 아무것도 쓰지 않고 건별 사유(이름·사유)를 돌려준다(조각 4 권장 방식 확정)
2. **「송금 내역」 화면의 공용 필터 줄(캠페인·검색·정산 목록 엑셀) = 감추기** — 이 화면 전용 기간 필터·엑셀만(조각 14)
