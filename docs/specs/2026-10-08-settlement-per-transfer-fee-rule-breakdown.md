# 📋 작업 분해표 — 정산 송금별 수수료 요율·고정액 지정

**사양서:** [`2026-10-02-settlement-per-transfer-fee-rule.md`](2026-10-02-settlement-per-transfer-fee-rule.md)
**분해일:** 2026-10-08 (`reverb-planner`, 메인 폴더 `dev` — 마지막 마이그레이션 512)
**총 작업 조각:** 12개 · **병렬 가능:** 4(화면 갈래 S1·U1·U2·U3 은 데이터베이스 갈래 D1~D5 와 동시 진행 가능, 각 갈래 안은 순차) · **순차 필수:** 8

> 확인 기준: 마이그레이션 503~512 에 정산 함수·표 변경 0건(`settlement_transfer|preview_settlement_fees|record_settlement_transfers|correct_settlement` 검색). 사양서가 기준으로 삼은 원본은 지금도 그대로 — 기록 **486** · 미리보기 **488** · 정정·조회 **502** · 시트 소급 **501**. 구현 흔적 없음(`fee_rule_custom` 은 사양서에만).

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| P1 | **정정 창의 기존 「값이 맞음(추정 해제)」 체크 칸과 새 「이 송금 요율 직접 정하기」 체크 칸의 관계.** (사용자 결정 — 아래 「사용자 결정」 표) | 「값이 맞음」을 켜면 값이 같아도 `p_fee_jpy` 를 보낸다(`admin-settlements.js` 4423·4425). 요율까지 보내면 서버가 `bundle_fee_conflict` 로 거부. 사양서 설계 ⓪ R2 는 이 체크 칸을 모른 채 쓰였다 | D5 · U2 |
| P2 | **운영 검증 범위** — 쓰기(기록·정정)를 운영에서 시험할지 | 운영에서 `record_settlement_transfers` 첫 기록 = 도입일. 그 뒤 옛 송금완료 경로 셋이 `payout_bundle_required` 로 거부되고 되돌릴 함수가 없다(CLAUDE.md 정산 절, 486 주석 791줄) | R1 |
| P3 | **엑셀 낱말** — 사양서의 「직접 입력」·「시트 실제값」 vs 화면의 「고친 값」·「지급 시트 실제값」(4045·4051·4398) | 같은 상태가 화면과 엑셀에서 다른 이름(낱말 전파 점검) | U3 |

P1·P3 은 코딩 전, P2 는 R1 직전까지.

---

## ⚠️ 사양서 stale 점검

| # | 사양서가 적은 것 | 실제 | 영향 |
|---|---|---|---|
| S-1 | (마) 「502 의 나머지 그대로」 | 502 첫 관문은 `p_sent_at·p_fee_jpy·p_paypal_txn_id·p_memo` 가 모두 NULL 이면 `nothing_to_correct`(83~86줄). 「아무것도 안 바뀌면 조용히 끝」(130~138줄)도 기존 칸만 비교 | 그대로 두면 **요율만 보내는 정정이 거부되거나 조용히 끝난다** → D5 에서 두 곳 모두 요율 인자·새 칸 반영 |
| S-2 | (나) 「하나만 오면 거부(`bundle_fee_rule_incomplete`)」 | 486 기록 함수는 묶음 검사에서 예외 대신 `failures[]` 에 `{bundle_index, reason}` 을 쌓고 `{ok:false}`(343~347·451~500·639~647줄) | 새 사유 3종도 같은 방식·같은 자리(2단계 묶음 검사). 화면 `BULK_FAILURE_TEXT`(1299)에 3개. 정정 함수는 예외 방식 → `friendlyError`(admin-core.js 138~142 근처)에 3개 |
| S-3 | 정정 창 R2 는 「금액 칸 ↔ 요율 체크」만 | 502 이후 정정 창에 「값이 맞음(추정 해제)」 체크 칸 두 개(4385~4399) | → P1 |
| S-4 | 「엑셀: 수수료 요율·고정액 두 열」(어느 엑셀인지 없음) | 대상은 **송금 내역 엑셀** `exportTransferHistoryExcel`(admin-settlements.js 4309). `admin-excel.js`·회차 송금 명단 `exportPayoutRoundExcel`(2811)엔 수수료 열 없음 | 회차 송금 명단은 범위 밖. 시트1 은 열 폭 배열(4318)·머리글(4321)·합계 줄(4338)·숫자 형식 열 번호 `[5,6,10]`(4339)이 **열 위치로 묶여** 열을 끼우면 넷 다 밀린다 |
| S-5 | 정정 창 「지금 ~입니다」 안내 언급 없음 | `fee_manual` 이 아니면 「자동 계산값」(4398) | 송금별 요율 묶음에도 「자동 계산값」 → 거짓. U2 에 「이 송금 요율로 계산한 값」 갈래 추가(사양서 밖 — 「구현 결과」에 기록) |
| S-6 | ② 「수수료 설정」 글 링크로 설정 창 열기 | 확인 창·정정 창·설정 창 z-index 모두 615(index.html 4297, admin-settlements.js 3606·4361). 설정·정정 창은 처음 열 때 만들어 붙여 **만든 순서에 따라 설정 창이 뒤에 깔릴 수 있다.** 설정 저장 뒤 확인 창 미리보기는 다시 묻지 않는다 | U1·U2 에 「링크로 열 때 설정 창을 앞으로 + 닫히면 미리보기 다시 묻기」 |
| S-7 | (다)·(마) 「DROP 후 CREATE」(새 인자 기본값 미기재) | 화면은 `previewSettlementFees` 로 `p_totals` 하나, `correctSettlementTransfer` 로 인자 6개(storage.js 6621·6552) | 새 인자에 `DEFAULT NULL` → 데이터베이스 먼저 적용해도 옛 화면이 돈다. **옛 서명은 반드시 지운다**(두 벌이면 화면 호출이 모호 오류) |
| S-8 | 설계 ① 「현재 원본」 | CLAUDE.md 정산 절은 정정·조회 3종을 한 줄 「502」 | 조회 셋 중 `get_settlement_transfers` 만 바뀐다 → 그 줄을 쪼갠다(월별·회차별 502 유지). `.claude/rules/settlement.md` 30줄 「`preview_settlement_fees`(488)」도 갱신 → DOC |
| — | 그 밖 | 486·488·501·502 본문, 484 규칙 범위(요율 0~100·고정액 0 이상·끝수 셋), `_settlement_fee_calc(bigint,numeric,integer,text)`, 화면 함수 이름·줄 대조 | **일치 — 충돌 없음**(줄 번호만 밀림. 설정 창은 3591 이 아니라 3600·3622) |

---

## 한눈에 보는 의존 순서

```
[데이터베이스 갈래 — 한 세션·순차]          [화면 갈래 — 한 세션·순차]
D1 칸 추가                                   S1 storage.js 래퍼 + 오류 문구(핫스팟)
 ├→ D2 기록 재정의                            └→ U1 확인 창
 ├→ D3 미리보기 재정의(D1 무관, 순서상 여기)       └→ U2 정정 창
 ├→ D4 조회 재정의                                  └→ U3 송금 내역 표시 + 엑셀
 └→ D5 정정 재정의
            └──────────────┬──────────────┘
                          V1 개발서버 검증(데이터베이스 5개 개발 적용 + 화면)
                           └→ R1 운영 반영(데이터베이스 먼저 → 화면 골라 담기)
                                └→ N1 Notion 실무자 가이드
(DOC: CLAUDE.md·FEATURE_SPEC·settlement.md·사양서 「구현 결과」는 D·U 각 커밋에 같이)
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| D1 | 송금 묶음에 「이 송금만」 칸 | 새 마이그레이션 ① | `settlement_transfers.fee_rule_custom boolean NOT NULL DEFAULT false` | — | ✗(데이터베이스 순차) | 개발(데이터베이스) |
| D2 | 기록 함수에 요율·고정액 | 새 마이그레이션 ② | `record_settlement_transfers(p_bundles jsonb) RETURNS jsonb` — 묶음 키 `fee_rate_percent`·`fee_fixed_jpy`, 실패 사유 3종 | D1 | ✗ | 개발(데이터베이스) |
| D3 | 미리보기 함수에 요율 배열 | 새 마이그레이션 ③ | `preview_settlement_fees(p_totals bigint[], p_rates numeric[] DEFAULT NULL, p_fixeds integer[] DEFAULT NULL, p_roundings text[] DEFAULT NULL) RETURNS jsonb` + 반환 `custom[]` | (D1 무관) | ✗ | 개발(데이터베이스) |
| D4 | 조회에 `fee_rule_custom` | 새 마이그레이션 ④ | `get_settlement_transfers(date,date)` 반환 칸 `fee_rule_custom boolean` | D1 | ✗ | 개발(데이터베이스) |
| D5 | 정정 함수에 요율·고정액 | 새 마이그레이션 ⑤ | `correct_settlement_transfer(…6개, p_fee_rate_percent numeric DEFAULT NULL, p_fee_fixed_jpy integer DEFAULT NULL) RETURNS integer` | D1 · P1 | ✗ | 개발(데이터베이스) |
| S1 | 래퍼·오류 문구 | `dev/lib/storage.js` · `dev/js/admin-core.js` | `previewSettlementFees(totals, opts?)` · `correctSettlementTransfer(…, rate, fixed)` · `friendlyError` 3종 | 계약만 | △ D 갈래와 병렬 가능, **핫스팟이라 다른 작업과 병렬 ✗** | 개발(화면) |
| U1 | 확인 창 체크 칸·요율 칸 | `dev/js/admin-settlements.js` | 묶음 상태 `ruleOn·rate·fixed` · 페이로드 키 · DOM id | S1 | △ D 갈래와 병렬, U2·U3 과 ✗ | 개발(화면) |
| U2 | 정정 창 체크 칸·요율 칸 | 같음 | `_transferCorrectCtx` 확장 · DOM id | U1 · P1 | 같음 | 개발(화면) |
| U3 | 송금 내역 근거 줄 + 엑셀 | 같음 | `_transferRuleText(t)` · `_transferFeeNoteHtml(t)` 확장 · 엑셀 열 | U2 · P3 | 같음 | 개발(화면) |
| V1 | 개발서버 검증 | (코드 없음) | 사양서 완료 기준 1~9 결과 | D1~D5 · U1~U3 | ✗ | 개발 |
| R1 | 운영 반영 | 운영 SQL 편집기 + `dev→main` 골라 담기 | 데이터베이스 5개 → 화면 | V1 · P2 | ✗ | 개발 → **사용자 확인** |
| N1 | 실무자 가이드 | Notion 「관리자 가이드」 정산 페이지 | 화면 이름·단추 「」 그대로 | R1 | ✗ | 개발 |

---

## 조각별 상세

### D1 — `fee_rule_custom` 칸 추가
- **하는 일**: 송금 묶음 표에 「이 송금만 요율을 따로 정했다」를 남길 칸.
- **산출 계약**: `ALTER TABLE public.settlement_transfers ADD COLUMN IF NOT EXISTS fee_rule_custom boolean NOT NULL DEFAULT false;` + COMMENT. 기존 행 전부 false. 행 단위 보안 정책 그대로(485).
- **완료 정의**: 개발 `SELECT count(*) FILTER (WHERE fee_rule_custom), count(*) FROM settlement_transfers;` → 앞 숫자 0
- **검문소**: `reverb-supabase-expert`
- **주의·롤백**: 편집기 경고 안 뜸. `DROP COLUMN` 롤백은 D2·D4·D5 를 먼저 되돌린 뒤에만(경고 뜸, 「이 송금만」 표시가 실제로 사라진다).

### D2 — `record_settlement_transfers` 재정의 (베이스 **486**)
- **산출 계약**
  - 서명 그대로 `record_settlement_transfers(p_bundles jsonb) RETURNS jsonb`, **`CREATE OR REPLACE`**(권한 보존. 3줄 재선언은 멱등).
  - 묶음 키 추가: `fee_rate_percent`(JSON 숫자, 0~100), `fee_fixed_jpy`(JSON 정수, 0 이상). 「없음」 = 「JSON null」(`fee_jpy` 관례).
  - 2단계 묶음 검사 반복문(486 451~500줄)에 `{bundle_index, reason}`:
    - `bundle_fee_rule_incomplete` — 둘 중 하나만
    - `bundle_fee_rule_invalid` — 숫자 아님·범위 밖·고정액 정수 아님(`jsonb_typeof` 먼저 — 캐스트 예외 방지)
    - `bundle_fee_conflict` — `fee_jpy` 와 요율이 함께
  - 쓰기(8단계): 요율이 오면 `v_fee := _settlement_fee_calc(v_total, 요율, 고정액, v_rule.rounding)`, 사본 3칸 = (요율, 고정액, `v_rule.rounding`), `fee_manual=false`, `fee_rule_custom := (요율 <> v_rule.rate_percent OR 고정액 <> v_rule.fixed_jpy)`. **끝수는 비교하지 않는다.** 요율이 없으면 486 그대로 + `fee_rule_custom=false`.
  - 반환 모양 그대로 `{ok, transfer_ids, settlement_count, fee_total}` / `{ok:false, failures}`.
- **완료 정의**(개발서버 관리자 콘솔): ①요율·고정액 묶음 → `fee_manual=false`, 사본 = 넣은 값, 설정과 다르면 `fee_rule_custom=true` ②설정과 같은 값 → `false` ③거부 3종 `ok:false`, 행 수 변화 0
- **검문소**: `reverb-supabase-expert` + 실제 한 번 호출(적용 성공 ≠ 동작 확인)
- **주의·롤백**
  - 🔴 **운영 SQL 편집기·콘솔에서 시험 호출 금지** — 첫 `source='app'` 기록이 곧 도입일.
  - 486 나머지(잠금 순서·미등록 판정·페이팔 재조회·「먼저 전부 검사」)는 글자 그대로.
  - 권장(사양서 밖): `create` 이력 `next` 에 `fee_rule_custom` 추가 — 넣으면 「구현 결과」에 기록.
  - `source='sheet_backfill'` 묶음에도 같은 규칙 허용(501 은 이 함수를 안 쓴다).
  - 편집기 경고 안 뜸. 롤백: 486 4절 블록 `CREATE OR REPLACE` 재적용.

### D3 — `preview_settlement_fees` 재정의 (베이스 **488**)
- **산출 계약**
  - 한 트랜잭션: `DROP FUNCTION IF EXISTS public.preview_settlement_fees(bigint[]);` → `CREATE FUNCTION public.preview_settlement_fees(p_totals bigint[], p_rates numeric[] DEFAULT NULL, p_fixeds integer[] DEFAULT NULL, p_roundings text[] DEFAULT NULL) RETURNS jsonb` → 권한 3줄(PUBLIC·anon 회수, authenticated 부여) + 설명.
  - 원소 NULL → 설정 규칙.
  - 반환 `{rate_percent, fixed_jpy, rounding, fees:[…], custom:[…]}` — `custom[i]` = 요율·고정액이 설정과 다른지(합계 ≤0 이면 NULL).
  - 거부 `bundle_fee_rule_invalid`(22023): 배열 길이 불일치 · 한 자리에 요율·고정액 중 하나만 · 범위 밖 · 끝수가 round/floor/ceil 아님. 가드(`settlement.view` 읽기)·2000개 상한 그대로.
- **완료 정의**: 콘솔 `(await db.rpc('preview_settlement_fees',{p_totals:[3000,7000],p_rates:[4.4,null],p_fixeds:[50,null]})).data` → `fees[0]` = 4.4%+50, `fees[1]` = 설정 규칙, `custom` = `[true,false]`(설정 4.1%+50 일 때). 옛 호출 `{p_totals:[3000]}` 도 성공
- **주의·롤백**: 편집기 경고 뜸 — 무해. 🔴 DROP·CREATE·권한은 **같은 트랜잭션**(나누면 그 사이 공개 실행 권한). 적용 뒤 `proacl` 맨 앞 `=X/` 없음 확인. 롤백: 새 서명 DROP + 488 본문 재생성(권한 포함).

### D4 — `get_settlement_transfers` 재정의 (베이스 **502**)
- **산출 계약**: 한 트랜잭션 `DROP FUNCTION IF EXISTS public.get_settlement_transfers(date, date);` → 502 2-1 블록 그대로 + `fee_rule_jpy` 바로 뒤 `fee_rule_custom boolean`(`t.fee_rule_custom`) → 권한 3줄 + 설명. **월별·회차별 조회는 건드리지 않는다.**
- **완료 정의**: 콘솔 `(await db.rpc('get_settlement_transfers',{p_from:null,p_to:null})).data[0]` 에 `fee_rule_custom`. 나머지 칸(`fee_stale`·`items`·추정 표시)은 502 와 같음
- **주의·롤백**: 편집기 경고 뜸 — 무해. 화면은 칸을 이름으로 읽어 옛 화면도 돈다. 롤백: 502 2-1 블록(한 트랜잭션).

### D5 — `correct_settlement_transfer` 재정의 (베이스 **502**)
- **산출 계약**
  - 한 트랜잭션 `DROP FUNCTION IF EXISTS public.correct_settlement_transfer(uuid, integer, timestamptz, bigint, text, text);` → `CREATE FUNCTION public.correct_settlement_transfer(p_transfer_id uuid, p_version integer, p_sent_at timestamptz, p_fee_jpy bigint, p_paypal_txn_id text, p_memo text, p_fee_rate_percent numeric DEFAULT NULL, p_fee_fixed_jpy integer DEFAULT NULL) RETURNS integer` → 권한 3줄 + 설명. 🔴 **옛 6인자 서명은 반드시 지운다.**
  - `nothing_to_correct` 관문에 새 두 인자 포함(S-1).
  - 검사 순서(예외, 22023): 하나만 `bundle_fee_rule_incomplete` → `p_fee_jpy` 와 함께 `bundle_fee_conflict` → 범위 밖 `bundle_fee_rule_invalid`. 잠금·버전 −1 은 502 그대로.
  - 요율이 오면: 끝수 `COALESCE(v_t.fee_rounding, 설정.rounding)`, 수수료 `_settlement_fee_calc(v_t.sent_total_jpy, 요율, 고정액, 그 끝수)`, 사본 3칸, `fee_manual=false`, `fee_estimated=false`, `fee_rule_custom := 정정 순간 설정과 요율·고정액이 다름`(설정은 이 함수 안에서 `settlement_fee_rule` id=1 을 읽는다).
  - 「아무것도 안 바뀜」 조기 반환에 사본 3칸·`fee_rule_custom` 비교 추가.
  - 이력 `settlement_transfer_events` 'correct' prev/next 에 `fee_rate_percent`·`fee_fixed_jpy`·`fee_rounding`·`fee_rule_custom`. 🔴 **`sent_total_jpy` 는 넣지 않는다**(487 `fee_stale` 판정이 그 칸 유무로 정정 종류를 가른다).
- **완료 정의**(콘솔): ①시트 실제값 묶음(사본 빔)에 설정과 같은 요율 → 사본 채워짐, `fee_rule_custom=false` ②`fee_manual=true` 묶음에 요율 → `fee_manual=false`, 수수료 재계산 ③뒤이어 `correct_settlement_payment` 로 건별 송금액 정정 → **그 요율로** 재계산(486) ④거부 3종 행 변화 0 ⑤이력 prev/next 에 옛 사본
- **주의·롤백**: 결과가 완전히 같으면(사본·수수료·표시 모두) 502 처럼 이력 없이 현재 버전 반환(「구현 결과」에 기록). 요율 소수 자릿수 제한은 484 와 같게(새 제한 없음). 편집기 경고 뜸 — 무해. 롤백: 새 서명 DROP → 502 1절 본문 6인자 CREATE + 권한(한 트랜잭션). ⚠️ 되돌리면 그 사이 정한 `fee_rule_custom` 근거는 칸과 함께 사라지고 사본은 남는다.

### S1 — 래퍼·오류 문구 (핫스팟)
- **담당 파일**: `dev/lib/storage.js`(6548 `correctSettlementTransfer`, 6618 `previewSettlementFees`) · `dev/js/admin-core.js`(`friendlyError` 138~142 근처)
- **산출 계약**
  - `previewSettlementFees(totals, opts)` — `opts = {rates, fixeds, roundings}`(같은 길이 배열, 원소 null 허용). 없으면 지금처럼 `p_totals` 만. 반환 `{rate_percent, fixed_jpy, rounding, fees, custom}` 그대로. 실패 `null`.
  - `correctSettlementTransfer(id, version, sentAt, feeJpy, txnId, memo, feeRatePercent, feeFixedJpy)` — 뒤 둘은 `undefined`/`null` → `null`. **`0` 은 유효한 값.**
  - `recordSettlementTransfers` 는 손대지 않는다(페이로드 통과).
  - `friendlyError` 에 `bundle_fee_rule_incomplete`·`bundle_fee_rule_invalid`·`bundle_fee_conflict` 한국어 문구.
- **완료 정의**: 빌드 성공. 옛 호출부(1228·4431) 그대로 동작
- **검문소**: `reverb-reviewer` — 이름 전파 세 형태 점검(세 함수 이름은 `storage.js` 에만, scripts·자립형 화면 0건)
- **주의**: 🔴 핫스팟 두 파일 — 다른 작업과 worktree 병렬 금지.

### U1 — 확인 창 「수정」
- **담당 파일**: `dev/js/admin-settlements.js` — 묶음 리터럴 두 곳(1093·1278) · `mergeBulkBundle`(1285) · `_bulkBundleFee`(1107) · `feeHtml`(1150) · `_scheduleBulkFeePreview`(1220) · 핸들러(1259~1271) · `BULK_FAILURE_TEXT`(1299) · 저장 페이로드(1359)
- **산출 계약**
  - 묶음 상태 `ruleOn:false, rate:'', fixed:''` — 리터럴 **두 곳 모두**.
  - DOM id `bulkRuleChk_${bi}` · `bulkRate_${bi}` · `bulkFixed_${bi}` · `bulkRateWarn_${bi}`(기존 `bulkTotal_`·`bulkFee_`·`bulkSpend_` 그대로).
  - 새 함수 `onBulkRuleToggle(bi, on)` · `onBulkRuleInput(bi, field, v)`.
  - 페이로드: `ruleOn` 이면 `fee_rate_percent: Number(rate), fee_fixed_jpy: Number(fixed)` 만, `fee_jpy` 는 안 보냄.
  - 미리보기 `previewSettlementFees(totals, {rates, fixeds})` — 끝수는 안 보냄.
- **완료 정의**: 체크 켜면 처음 값 = 설정 규칙(`feePreview.rate_percent·fixed_jpy`) + 금액 칸 잠김 · 요율 바꾸면 300ms 뒤 서버 계산으로 수수료·총지출 갱신 · 10% 초과 경고 줄(막지 않음) · 「자동으로」 = 체크 끔 + 금액 지움 · 금액 넣으면 체크 칸 흐림(R2·R3·R5) · 안내 문구와 「수수료 설정」 링크
- **검문소**: `reverb-reviewer` · `ui-ux-pro-max`(관리자 화면 — Apple 지침 대상 아님)
- **주의**: 진입점 여섯이 모두 이 창 하나(`settlement.md`). 「합치기」 시 사라지는 묶음의 요율 지정은 버리고 남는 쪽 것을 쓴다 — 안내 한 줄 여부는 착수 때. 미리보기 실패 시 처음 값을 비워 두고 직접 입력(0 으로 채우지 않는다 — `Number('')` 함정). 설정 창 링크는 쌓임 순서를 올리고 닫히면 `_scheduleBulkFeePreview()`(S-6).

### U2 — 정정 창
- **담당 파일**: 같은 파일 `openTransferCorrectModal`(4377) · `saveTransferCorrect`(4410)
- **산출 계약**
  - `_transferCorrectCtx` 에 `ruleOn·rate0·fixed0·rounding(사본 끝수|null)`.
  - 처음 값 = 그 묶음 사본(`fee_rate_percent`·`fee_fixed_jpy`), 비었으면 `fetchSettlementFeeRule()`.
  - DOM id `transferCorrectRuleChk` · `transferCorrectRate` · `transferCorrectFixed` · `transferCorrectRateWarn`.
  - 미리보기 `previewSettlementFees([sent_total_jpy], {rates:[r], fixeds:[f], roundings:[사본 끝수|null]})`, 늦은 응답은 순번으로 버림.
  - 저장: 체크 켬이면 `feeArg=null` + `correctSettlementTransfer(…, rate, fixed)`.
  - 안내 문구(4398)에 「이 송금 요율로 계산한 값」 갈래(S-5).
- **완료 정의**: R2(금액을 열 때와 다르게 고치면 체크 칸 흐림) · R3(끄면 값 복귀) · P1 결정대로 「값이 맞음」 동작 · 미리보기 수수료 = 저장 뒤 목록 수수료(사본 빈 묶음은 경우의 수 6 예외) · 「바꾼 칸이 없습니다」(4428) 판정에 체크 켬 포함(체크만 켜고 저장해도 **보낸다**, R1)
- **주의**: 저장 뒤 `refreshPane('settlements')` + `_loadTransferHistory()` 그대로(4440).

### U3 — 송금 내역 근거 줄 + 엑셀
- **담당 파일**: 같은 파일 `_transferFeeNoteHtml`(4043 — 4080·4276·4302 **세 자리가 같은 함수**) · `exportTransferHistoryExcel`(4309)
- **산출 계약**
  - 공용 `_transferRuleText(t)` → `'4.4% + ¥50'`(요율 끝 0 제거, 고정액 `settlementAmountYen`) — 화면·엑셀 공용.
  - 근거 줄: `fee_manual` 이면 기존 줄 + (`fee_rule_custom` 이면 끝에 「(이 송금 요율 …)」) / 아니고 `fee_rule_custom` 이면 「요율 … (이 송금만)」.
  - 엑셀 시트1 「수수료 수정」 열 뒤에 「수수료 요율」·「수수료 고정액」 두 열 — 판정 순서는 사양서 ②, 낱말은 P3.
- **완료 정의**: 목록·월별 상세·회차 상세 세 자리 같은 줄. 엑셀 합계 줄·숫자 형식이 맞는 열에(열 폭·머리글·합계·숫자 형식 열 번호 모두 밀림 반영)
- **주의**: 설정을 나중에 바꿔도 「이 송금만」 그대로 — 저장값 `fee_rule_custom` 만 보고 화면에서 설정과 비교하지 않는다(완료 기준 6).

### V1 — 개발서버 검증
- 개발 데이터베이스에 D1→D5 **한 파일씩**(파일마다 절대경로 + 편집기 경고 한 줄 · SQL 확인 한 단계씩) → 함수마다 관리자 콘솔로 최소 1회 호출 → 화면 병합(개발서버 배포 위임) → 완료 기준 1~9 화면 확인(크롬은 보이게 조작, 드롭다운 예외 절차).
- 완료 정의: 기준 9개 통과/실패 기록 + 사양서 「구현 결과」에 마이그레이션 실제 번호.
- `reverb-qa-tester` 권장(다른 세션이 브라우저 테스트 도구를 안 쓸 때, 단일 세션).

### R1 — 운영 반영
- P2 확인(`SELECT count(*) FROM settlement_transfers WHERE source='app';` 읽기만) → 운영 SQL 편집기 D1→D5 → 권한 조회 → **그다음** 화면만 `dev→main` 골라 담기(문의 창구·가입 인증번호 코드 섞지 않음).
- 🔴 데이터베이스 먼저 — 새 인자 기본값이 있어 옛 화면은 그대로 돈다(S-7). 운영 배포는 **사용자 확인** 뒤. 롤백: 화면 되돌리기 → D5→D2 → D1(필요할 때만).

### N1 — Notion 실무자 가이드
- 정산 페이지에 확인 창·정정 창 체크 칸, 「이 송금만」 표시, 엑셀 두 열. 정확성 게이트(`origin/main` 존재 확인, 단추 이름 「」 그대로).

### DOC — 각 조각 커밋에 같이
- CLAUDE.md 정산 「현재 원본 번호」: 정정·조회 줄 쪼개기(`get_settlement_transfers`·`correct_settlement_transfer` 새 번호 / 월별·회차별 502 유지) + `record_settlement_transfers`·`preview_settlement_fees` 새 번호
- `.claude/rules/settlement.md` 30줄 488 표기
- `docs/FEATURE_SPEC.md`
- 사양서 「구현 결과」(S-5·S-6·D2 이력·D5 조기 반환)

---

## ⚠️ 공유 지점 경고
- **핫스팟**: `dev/lib/storage.js` · `dev/js/admin-core.js`(S1) — 다른 기능 작업과 병렬 ✗.
- **같은 파일 세 조각**: U1·U2·U3 모두 `admin-settlements.js` — 이 기능 안에서 순차.
- **판정 사본**: 「설정과 다른가」는 서버 세 곳(D2·D3·D5)이 같은 식(요율·고정액만, 끝수 제외). 화면은 비교하지 않고 서버 값만 그린다.
- **수수료 식은 `_settlement_fee_calc` 한 곳** — 화면에 식 없음(10% 경고는 입력값 비교일 뿐).
- **열 위치 결합**: 송금 내역 엑셀 시트1(4318·4321·4338·4339).
- **배포 경계**: 함수는 SQL 편집기, 화면은 병합 — 데이터베이스 먼저.
- **도입일 함정**: 운영에서 `record_settlement_transfers` 시험 호출 금지.
- 약관 영향 없음(새 수집 항목 없음). 빌드 목록 변경 없음(`bash dev/build.sh` 만).

## 🧭 배분 제안
- **추천: 개발 세션 1개 순차** — D1→D5 → S1 → U1→U2→U3 → V1 → R1. 데이터베이스 5개와 화면 3조각이 서로를 검증(미리보기 = 저장 값)해야 해 한 사람이 쥐는 편이 어긋남이 적다.
- **서두를 때**: 세션 둘 — ①데이터베이스 D1~D5(마이그레이션 번호를 쥐는 한 세션) ②화면 S1→U3(산출 계약대로 먼저, 개발 데이터베이스 적용 뒤 확인). 파일이 안 겹친다(`supabase/migrations/` 대 `dev/`). V1 부터 합친다.
- S-1·S-2·S-7 은 사양서 취지 안의 구현 정리 — 기획에 다시 묻지 않는다. **사용자 질문은 P1·P2·P3.**

## 사용자 결정 (P1·P2·P3)
| # | 결정 | 일자 |
|---|---|---|
| P1 | **「값이 맞음」 잠금** — 정정 창에서 「이 송금 요율 직접 정하기」를 켜면 「값이 맞음(추정 해제)」 체크를 끄고 흐리게 한다(요율 저장이 서버에서 `fee_estimated=false` 를 함께 처리) | 2026-10-08 |
| P2 | **운영은 읽기만 확인** — 미리보기·목록만 본다. 기록·정정 쓰기는 개발서버 검증으로 갈음(운영 첫 기록 = 도입일 위험 회피) | 2026-10-08 |
| P3 | **화면과 통일** — 엑셀도 「고친 값」·「지급 시트 실제값」(사양서의 「직접 입력」·「시트 실제값」 대신) | 2026-10-08 |

→ 선결 조건 P1·P2·P3 모두 결정됨 — **바로 착수 가능.**
