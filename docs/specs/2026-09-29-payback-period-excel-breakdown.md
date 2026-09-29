# 📋 작업 분해표 — 인증 성공일 회차별 페이백 대상 엑셀

**사양서:** `docs/specs/2026-09-29-payback-period-excel.md` / **분해일:** 2026-09-29 / **총 작업 조각:** 6개 · **병렬 가능:** 2개(A 줄기 ‖ B 줄기) · **순차 필수:** 4개(각 줄기 안)

> 데이터베이스 변경 없음 → 마이그레이션 0개, `reverb-supabase-expert` 호출 대상 아님.

---

## 🚦 착수 전 선결 조건

| 번호 | 조건 | 상태 | 막는 조각 |
|---|---|---|---|
| S0 | 사양서 §6 네 항목(엑셀 자리 둘 · 미지급 기본+송금완료 포함 · 회차 규칙 = `payoutDueDate` · B 는 B-0 뒤) | ✅ 전부 사용자 확인 완료(2026-09-29) | 없음 |
| S1 | **B-0(화면 `certSuccessAt` 「또는」 결함 수정)이 개발서버에 반영돼 있을 것** | ⏳ 미착수. 이 사양서 범위 밖(전수조사 3차 ③-3 후속), 이 표에서는 선행 조각 B-0 으로만 둔다 | B-1 · B-2 |

A 줄기는 선결 조건이 없다. 바로 착수할 수 있다.

---

## ⚠️ 사양서 stale 점검 (2026-09-29 코드 직접 대조)

사양서 §1 이 인용한 줄 번호는 거의 다 맞다(`buildPayoutRows` 1781~1819, `payoutDueDate` shared.js 1734~1747, `certSuccessAt` 873~890, 표시용 사슬 471~529, 344:100·129·144 등 확인). 결론을 바꾸는 어긋남은 아래와 같다. **#1·#2 는 사양서 본문에 반영했다**(2026-09-29 §3-A·§4).

| # | 사양서가 말하는 것 | 실제 코드 | 조각에 미치는 영향 |
|---|---|---|---|
| 1 | §4·§1-1: 「A 는 `admin/index.html`(단추)을 고친다」, A·B 가 그 파일을 둘 다 고쳐 **병합은 순차** | A 단추 두 자리(요약 회차 줄 끝, 사람별 화면 머리)와 요약 표 머리의 체크박스는 **전부 자바스크립트 문자열**이다. `renderPayoutSummary`(2002~2030)와 `renderPayoutPersonList`(2473~2514)가 `#payoutSummaryBody` 안에 그린다. `index.html` 의 `settlementPayoutView` 머리에는 「사람으로 찾기」·「정산 목록」 두 단추만 있다(1801~1806) | **A 는 `dev/admin/index.html` 을 안 건드린다.** 그래서 A·B 사이에 겹치는 원본 파일이 없고 병렬로 해도 된다. 남는 겹침은 빌드 산출물과 문서뿐이다(아래 공유 지점) |
| 2 | §3-A 시트 1: 「그 묶음의 행을 `settlementEffectiveAmount` 로 다시 더한다」 | `buildPayoutRows` 가 만드는 지급 행에는 `amount_jpy`·`paid_amount_jpy` 칸이 **없다**. 이미 계산된 `amount` 만 있다(1789·1807). 정산대기 행에 `settlementEffectiveAmount(r)` 를 부르면 `Number(undefined)` 가 되어 **0원**이 나온다(shared.js 2435) | 🔴 합계는 **`r.amount` 를 더한다**(`_payoutSum`, 2092 과 같은 방식). 이 값이 곧 `settlementEffectiveAmount` 결과라 「금액은 그 함수로만」 원칙은 지켜진다. **지급 행에 그 함수를 다시 부르지 말 것** |
| 3 | §3-B: 인증 상태 = 「엑셀 헬퍼 `_excelCertStatusKo` 와 같은 판정」, `admin-excel.js` 공용 헬퍼로 인용 | `_excelCertStatusKo` 는 `admin-excel.js` 가 아니라 `dev/js/report-rows.js:50` 에 있다. 원시값 인자 7개를 받아서 그룹 `g` 에 바로 쓸 수 없다. 화면 판정을 그대로 한국어로 주는 함수는 `certStatusLabelKo(g)`(admin-deliverables.js 819)다 | B 는 **`certStatusLabelKo(g)`** 를 쓴다. 그래야 화면 배지와 글자까지 같다 |
| 4 | §3-A·§5-5: 미등록 조회 실패(`_payoutRows === null`)면 「단추 비활성 + 말풍선」 | 실패하면 요약 화면이 **표를 아예 안 그리고** 안내문만 띄운다(1847~1852). 그래서 회차 줄 단추가 **존재하지 않는다.** 사람별 회차 화면은 요약 표에서만 들어가므로 이 상태로는 닿을 수 없다 | 화면에서는 「비활성」이 아니라 「단추 없음」이 정답이다. 대신 **함수 첫 줄에서 `_payoutRows === null` 이면 거부 알림 + 종료**하는 방어를 둔다. §5-5 는 「엑셀이 나갈 길이 없는지」로 읽고, 개발자 도구 콘솔에서 함수를 직접 불러 거부 알림을 확인한다 |
| 5 | §3-A: 「`PAYOUT_NO_DUE` 줄에는 단추 없음」(요약 화면만) | 요약의 「지급일 기록 없음」 줄 「상세」 → `openPayoutPersonList('__nodue__')` → 사람별 화면 머리가 뜬다(2489). 사양서는 이 머리를 언급하지 않는다 | 사람별 머리 단추는 **`_payoutDueFilter` 가 `null` 이거나 `PAYOUT_NO_DUE` 이면 감춘다**(회차가 없으니 목적 밖이다). 사양서 취지를 연장한 것이므로 「구현 결과」에 기록한다 |
| 6 | §3-A: 사람 정보가 없으면 `ensurePayoutPersonInfo()` 를 기다린 뒤 조회 실패(`null`)를 「확인 실패」로 | `_payoutPersonInfo === null` 은 두 가지를 뜻한다. 「아직 안 불러옴」(지급 준비 진입 때 1857 에서 초기화)과 「조회 실패」다 | 엑셀 함수는 **`null`/`undefined` 면 무조건 `ensurePayoutPersonInfo()` 를 먼저 await** 한다. 그 **뒤에도** `null` 이면 그때를 실패로 판정한다(`openPayoutPersonList` 2332 와 같은 조건) |
| 7 | §3-A: 체크박스는 브라우저에 기억하지 않는다 | 요약 표는 `innerHTML` 로 통째 다시 그려진다(`backToPayoutSummary` 등). 체크 상태를 입력칸에만 두면 되돌아올 때마다 날아간다 | 모듈 변수 **`_payoutExportIncludePaid`** 하나에 둔다. 요약·사람별 두 체크박스가 이 변수를 함께 쓰고, `openPayoutPrepView()` 진입 때 `false` 로 초기화한다. 저장소(`localStorage`)는 쓰지 않는다 |
| 8 | §1-1: 「이메일은 두 출처 모두 원본에 있다」 | 미등록 행 `influencer_email` 은 **원본 표** LEFT JOIN 이라 가림막을 거치지 않는다(344). 정산 행은 가림막 뷰(`fetchInfluencersByIds`, storage.js 1737)를 거친다. 즉 권한 가림은 한쪽에만 적용된다 | A 화면에는 캠페인 매니저가 못 들어온다(`settlement.view` 숨김). 그래서 실제 차이는 없다. 정보로만 남긴다 |
| 9 | §1-1 `index.html` 1802~1808 | 실제 1801~1806 | 사소함 |

---

## 한눈에 보는 의존 순서

```
A 줄기 (dev/js/admin-settlements.js 한 파일)        B 줄기 (dev/js/admin-deliverables.js + dev/admin/index.html)
  A-1 행 값 추가 + 엑셀 함수                          B-0 certSuccessAt 「또는」 수정 (범위 밖 선행)
   └→ A-2 단추·체크박스 (JS 문자열)                    └→ B-1 보이는 목록 저장 + 엑셀 함수
        └→ A-3 개발서버 검증·문서                            └→ B-2 툴바 단추(HTML) + 검증·문서
                    ╲                                      ╱
                     └── dev 병합은 먼저 끝난 쪽부터, 뒤쪽이 산출물·CLAUDE.md 충돌을 해소 ──┘
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| A-1 | 지급 행에 이메일·모집 형식 추가 + 회차 엑셀 함수 | `dev/js/admin-settlements.js` | `buildPayoutRows` 행 새 필드 `email`·`recruitType` / `async function exportPayoutRoundExcel(due, {includePaid})` / 시트 「회차 합계」·「건별」 / 파일명 `payout-{due}-{unpaid\|all}-{건수}-{YYYYMMDD}.xlsx` / 상수 `PAYOUT_LEDGER_WARN_UNTIL = '2026-09-30'` | 없음 | ✅ B 줄기와 병렬 | 개발 1 |
| A-2 | 단추 두 자리 + 「송금완료 포함」 체크박스 두 개 | `dev/js/admin-settlements.js` | 모듈 변수 `_payoutExportIncludePaid` / 함수 `setPayoutExportIncludePaid(checked)` / 요약 체크박스 id `payoutExportIncludePaidSummary` / 사람별 체크박스 id `payoutExportIncludePaidPerson` / 단추 이름 「이 회차 송금 명단 엑셀」 | A-1 | ✗ A-1 과 같은 파일 | 개발 1 |
| A-3 | A 개발서버 검증 + 문서 | (검증) · `docs/specs/…payback-period-excel.md` 「구현 결과」 · `CLAUDE.md` · `docs/FEATURE_SPEC.md` | §5-1~8·12 통과 기록 | A-2 | ✗ | 개발 1 |
| B-0 | 화면 인증 성공일 「또는」 갈래 수정 (범위 밖 선행) | `dev/js/admin-deliverables.js` (`certSuccessAt` 873~890) | `certSuccessAt(g)` 시그니처 불변 · 「또는」이면 서버 455 와 같은 시각 | 없음 | ✅ A 줄기와 병렬 | 개발 2 |
| B-1 | 보이는 목록 저장 + 「보이는 목록 엑셀」 함수 | `dev/js/admin-deliverables.js` | 모듈 변수 `_delivVisibleGroups`(`null`=불러오는 중·실패) / `async function exportDeliverablesViewExcel()` / 시트 「결과물(보이는 목록)」 / 파일명 `deliverables-view-{건수}-{YYYYMMDD}.xlsx` | B-0 | ✗ 같은 파일 | 개발 2 |
| B-2 | 툴바 단추 + B 검증 + 문서 | `dev/admin/index.html`(결과물 툴바 1648~1651 옆) · 문서 3종 | 단추 id `btnDelivViewExcel`, 이름 「보이는 목록 엑셀」, `onclick="exportDeliverablesViewExcel()"` | B-1 | ✗ | 개발 2 |

---

## 조각별 상세

### A-1 — 지급 행에 이메일·모집 형식 추가 + 회차 엑셀 함수

**하는 일**
1. `buildPayoutRows`(1781) 두 갈래에 필드 둘을 **더하기만** 한다.
   - 미등록 행: `email: r.influencer_email || null` · `recruitType: r.recruit_type || null`
   - 정산 행: `email: (s.influencers && s.influencers.email) || null` · `recruitType: camp.recruit_type || null`(`fetchSettlements` 조회문 5585 에 이미 있다)
   - ⚠️ `name`·`nameKana` 는 **건드리지 않는다.** 정산 행 이름을 비워 두고 나중에 채우는 것이 기존 동작이고, `payoutPersonOf` 가 그 전제로 돈다.
2. `exportPayoutRoundExcel(due, {includePaid})` 를 새로 만든다. 자리는 「지급 준비」 절 끝(`groupSettlementsByPerson`·`_payoutSum` 뒤)이다.
   - **가드 순서**: `_payoutRows === null` → 「미등록 건을 불러오지 못해 내보낼 수 없습니다」 알림 후 종료. `!due` 이거나 `due === PAYOUT_NO_DUE` → 종료. `_checkExportAllowed()` → `_markExportStart()` → `try … finally _markExportEnd()`
   - 사람 정보: `_payoutPersonInfo` 가 `null`/`undefined` 면 `await ensurePayoutPersonInfo()`. 그 뒤에도 `null` 이면 이름·페이팔 칸에 「확인 실패」를 적는다(stale #6)
   - 대상: `roundAll = _payoutRows.filter(r => r.due === due)`. `rows = includePaid ? roundAll : roundAll.filter(_payoutUnsent)`. 0건이면 「내보낼 건이 없습니다」 알림 후 종료
   - 회차는 **`r.due` 를 그대로** 쓴다. `payoutDueDate` 를 다시 부르지 않는다
   - 금액은 **`r.amount`** 를 쓴다(stale #2). `r.amountUnknown` 인 행은 금액 칸을 비우고 합계에서 뺀다
3. **시트 1 「회차 합계」**
   - 맨 위 머리 줄: 「지급 예정일 {due} · 회차 전체 N건 / 담은 것 M건({미지급만|송금완료 포함}) · 내려받은 시각 {formatDateTime}」. `due <= PAYOUT_LEDGER_WARN_UNTIL` 이면 한 줄 더 적는다: 「⚠️ 지급대장 대조 전 — 이미 보낸 건이 미지급으로 보일 수 있습니다」
   - ⚠️ `ws.columns` 에 `header` 를 주면 1행이 머리글로 박힌다. 머리 줄을 위에 두려면 **열 너비만 `columns` 로 정하고 머리글 행은 직접 추가**한다(또는 `spliceRows`). 구현 방식은 자유다
   - 열: 이름(한자) · 이름(가나) · 이메일 · PayPal · 건수 · 합계(¥) · 미확정 · 상태
   - 사람 묶음은 `groupSettlementsByPerson(rows)` 결과를 그대로 쓴다. 미지급 묶음은 `dues[due]`, 송금완료 묶음은 `paid` 다. **포함 모드면 한 사람이 두 줄**이 되고, 합치지 않는다
   - 이름 세 갈래: 행 값 → `_payoutPersonInfo[id]` → 거기에도 없으면 「(이름 미상)」 / 조회 실패면 「확인 실패」
   - PayPal: 묶음 안 **정산 행 스냅샷 `paypalEmail` 을 먼저** 쓴다. 현재 값(`_payoutPersonInfo[id].paypal_email`)과 다르면 칸 끝에 「(확인 필요)」를 붙인다. 없으면 「미등록」, 조회 실패면 「확인 실패」. ⚠️ `groupSettlementsByPerson` 의 `person.paypal` 은 **첫 행 기준**이라 이 규칙을 못 지킨다. 묶음 행을 직접 훑어서 정한다
   - 이메일: 묶음 행에서 처음 나오는 비어 있지 않은 값. 출처 값 그대로 적는다(탈퇴 자리표시 주소도 그대로)
4. **시트 2 「건별」**: 이름(한자) · 이름(가나) · 캠페인번호 · 캠페인 · 모집 형식(리뷰어/기프팅/방문형 — `admin-excel.js` 261 의 지역 함수와 같은 한국어 표기) · 인증성공일(`formatDate(certAt)`) · 지급 예정일(`due`) · 금액(¥, 미확정은 빈칸) · 미확정(O) · 상태(미등록/정산대기/송금완료) · 송금완료일(`paidAt` 의 `formatDate`, `recordDateOnly` 면 뒤에 「(기록일)」) · PayPal
5. 이름 칸은 `r.name`/`nameKana` 를 직접 넣는다(`_excelInfluencerNameParts` 는 `name_kanji` 를 기대해서 안 맞는다). `confirmAuditExport` 는 **부르지 않는다**
6. 저장·다운로드·알림 「엑셀 다운로드 완료 (M건)」은 `exportSettlementsExcel`(1369~1379) 방식을 따른다

**산출 계약**: 위 표. 파일명의 `{건수}` 는 **담은 건수 M**(시트 2 행 수)이다. 사양서가 명시하지 않아 여기서 정한다. 「구현 결과」에 기록할 것.
**선행**: 없음
**완료 정의**: 콘솔에서 `exportPayoutRoundExcel('<실제 회차>', {includePaid:false})` 로 파일이 나오고, 시트 2 행 수가 요약 표 그 회차 「미지급」 칸 건수와 같다(§5-2 기본 모드). `{includePaid:true}` 이면 「건수」 열과 같다. 요약 화면에서 사람별 화면을 한 번도 안 연 상태에서 불러도 정산 행 이름과 미등록 행 페이팔이 차 있다(§5-1)
**검문소**: `reverb-reviewer`(커밋 직전)
**주의**: `exportSettlementsExcel` 은 **손대지 않는다**(§5-12). 그 함수가 `Number(s.amount_jpy)` 를 쓰는 것도 이번 범위 밖이다. `dev/lib/shared.js` 에 새 도우미를 넣지 않는다(핵심 공용 파일이라 동시 수정 충돌 위험이 크다).

### A-2 — 단추 두 자리 + 「송금완료 포함」 체크박스 두 개

**하는 일**
1. 모듈 변수 `let _payoutExportIncludePaid = false;` 와 `setPayoutExportIncludePaid(checked)` 를 만든다. `openPayoutPrepView()` 안에서 `_payoutRows` 를 새로 받을 때 `false` 로 초기화한다.
2. **요약 화면**
   - `payoutDueRowHtml`(1915~1916) 마지막 칸 「상세」 옆에 「이 회차 송금 명단 엑셀」 단추를 둔다. `onclick="exportPayoutRoundExcel('${esc(due)}', {includePaid:_payoutExportIncludePaid})"`
   - 머리글 마지막 `<th>`(2015)에 체크박스 `id="payoutExportIncludePaidSummary"` + 라벨 「송금완료 포함」을 둔다. `onchange="setPayoutExportIncludePaid(this.checked)"`, `checked` 는 변수값으로 그린다
   - 마지막 열 너비(지금 70px)를 단추·체크박스가 들어가게 넓힌다. ⚠️ 2010~2013 주석 규칙대로 **머리글·회차 줄·「지급일 기록 없음」 줄 셋을 함께** 본다. 구역 머리의 `colspan="7"` 은 열 수가 안 바뀌므로 그대로 둔다
   - `payoutNoDueSectionHtml` 줄에는 단추를 두지 **않는다**
3. **사람별 화면**
   - `renderPayoutPersonList` 고정 머리(2496~2506 검색칸 묶음)에 같은 이름의 단추와 체크박스 `id="payoutExportIncludePaidPerson"` 을 둔다
   - `_payoutDueFilter` 가 `null` 이거나 `PAYOUT_NO_DUE` 면 **둘 다 그리지 않는다**(stale #5)
   - 머리는 한 번만 그려진다(검색 입력 때 다시 안 그림). 그래서 단추의 `onclick` 은 그리는 순간의 회차를 문자열로 넣어도 된다
4. 단추 말풍선: 「이 회차의 송금 명단을 내려받습니다. 검색어·회원별/캠페인별 보기와 상관없이 회차 전체가 대상입니다」. 사람별 화면에서 검색해 둔 채로 누르면 **화면보다 많은 사람이 나오는 것**이 정상이다. 이 점을 적어 두지 않으면 결함으로 오해받는다

**산출 계약**: 위 id·함수 이름. 버튼 클래스는 `btn btn-ghost btn-xs`(옆 「상세」와 같게). 아이콘은 Material Icons + `translate="no"`
**선행**: A-1
**완료 정의**: 요약 표 모든 회차 줄에 단추가 보이고, 「지급일 기록 없음」 줄에는 없다. 사람별 「전체 기간」과 「지급일 기록 없음」 화면에서는 단추·체크박스가 안 보인다(§5-7). 요약에서 체크를 켜고 → 상세 → 뒤로 돌아와도 체크가 유지된다. 지급 준비에 새로 들어오면 꺼져 있다
**검문소**: `reverb-reviewer`
**주의**: 이 문자열 템플릿 **안의 HTML 주석에는 역따옴표를 쓰지 말 것**(2494~2495 에 적힌 실제 사고. 파일 전체가 깨진다).

### A-3 — A 개발서버 검증 + 문서

**하는 일**: 빌드(`bash dev/build.sh`) → 병합 요청 → 개발서버에서 실제 로그인 브라우저로 사양서 §5 의 1·2·3·4·5·6·7·8·12 를 확인한다. 좌표로 누르고 스크롤해 사용자가 보면서 따라올 수 있게 한다(`.claude/rules/browser-qa.md`). 그다음 같은 커밋에 사양서 「구현 결과」, `CLAUDE.md` 정산 절(지급 준비에 회차 엑셀 한 줄 — 시트 둘, 금액은 `r.amount`, 요약 단추·사람별 단추, 체크박스 변수), `docs/FEATURE_SPEC.md` 를 갱신한다.
**완료 정의**:
- §5-1: 요약에서 바로 뽑은 파일에 이름·페이팔 빈칸이 없다
- §5-2: 두 모드 모두 행 수·합계가 요약 표 칸과 같다
- §5-3: 파일명 `-unpaid`/`-all` 과 머리 줄 문구가 체크 상태와 같다
- §5-4: 미확정 행 금액이 빈칸이고 합계에서 빠지며 「¥0」이 0곳이다
- §5-5: stale #4 기준. 요청 차단 시 요약 표가 안 그려져 단추가 없다. 콘솔 직접 호출은 거부 알림이 뜬다
- §5-6: 2026-09-30 이하 회차에만 경고 줄이 있다
- §5-7: 단추 감춤이 맞다
- §5-8: 캠페인 매니저 진입 불가가 그대로다
- §5-12: 기존 정산 엑셀이 종전 16열 그대로다
**검문소**: `reverb-reviewer` → `reverb-qa-tester` light. 다른 세션이 브라우저 테스트 도구를 안 쓸 때 단일 세션에서, 사용자가 시작한다.
**주의**: 개발서버 미등록 데이터가 적으면 §5-4(미확정)·§5-6(경고 구간) 회차가 없을 수 있다. 없으면 「해당 데이터 없음」으로 기록하고, 운영 배포 뒤 운영 화면에서 파일만 뽑아 확인한다(쓰기 동작 없음).

### B-0 — 화면 인증 성공일 「또는」 갈래 수정 (범위 밖 선행)

**하는 일**: `certSuccessAt(g)`(873)가 채널 갈래(`_certChannelKind(g.campaign)` — `single`/`and`/`or`)를 보게 한다. 서버 `_settlement_cert_candidates`(현재 원본 **455**, 377~406)와 같은 규칙이어야 한다.
- 가구매: 영수증 승인 시각(그대로)
- 리뷰어형 `or`: 영수증 승인 시각이 없거나 승인 채널이 0개면 `null`. 아니면 **max(영수증, 승인된 채널들의 가장 이른 승인 시각)**
- 시딩·방문형 `or`: 승인 채널이 0개면 `null`. 아니면 **승인된 채널들의 가장 이른 승인 시각**
- `and`·`single`: 지금 그대로(가장 늦은 시각, 하나라도 비면 `null`)
- 주석의 「서버 원본 331」을 455 로 고친다

**산출 계약**: 시그니처 `certSuccessAt(g)` 불변. 반환은 ISO 문자열 또는 `null`
**선행**: 없음
**완료 정의**: 개발서버에서 「또는」 캠페인 중 채널 하나만 승인된 인증성공 응모의 「인증 성공일」 칸이 빈칸이 아니고, 그 날짜가 정산 화면 「인증성공일」과 같다(같은 PC). 결과물 관리와 캠페인 진행현황 결과물 탭(`admin-applications.js` 751·775 가 같은 함수를 부른다)의 기간 필터에 그 건이 걸린다. `and` 캠페인 표시는 바뀌지 않는다
**검문소**: `reverb-reviewer`
**주의**:
- ⚠️ 서버의 `MIN(...) FILTER` 는 승인됐지만 **승인 시각이 빈** 행을 건너뛰고, `GREATEST` 는 NULL 을 무시한다. 옛 결과물처럼 승인 시각이 빈 승인 행이 섞이면 화면이 서버와 달라질 수 있다. 규칙을 서버와 같게 맞추거나, 다르게 두면 그 이유를 주석에 적는다
- 채널 판정은 `campaignFollowerKind`(shared.js 1033)를 부르는 `_certChannelKind` 를 그대로 쓴다. **사본을 만들지 않는다**
- 이 판정은 `CLAUDE.md` 「인증 성공일 컬럼」 서술(「가장 늦은 것」)과 어긋나게 된다. 같은 커밋에 그 절을 고친다
- 「같은 판정이 여러 곳에 있다」 목록(엑셀·메일)은 `certSuccessAt` 이 아니라 `computeCertStatus` 계열이라 이번 대상이 아니다. 다만 `report-rows.js` 가 인증 성공일을 따로 계산하는 자리가 있는지 한 번 확인한다

### B-1 — 보이는 목록 저장 + 「보이는 목록 엑셀」 함수

**하는 일**
1. `renderDeliverablesList`(260) 시작 부분(스피너를 그리는 263 직후)에서 `_delivVisibleGroups = null`. 정렬이 끝난 뒤(597 `applyDelivSortIndicators()` 앞뒤)에 `_delivVisibleGroups = filtered.slice()` 로 잡는다. `passesFilters`(건수 집계용)는 **쓰지 않는다**. 「대리 등록만」이 그쪽에 없다
2. `exportDeliverablesViewExcel()`
   - `_delivVisibleGroups === null` 이면 「목록을 불러오는 중입니다」 알림 후 종료. 0건이면 「내보낼 건이 없습니다」
   - 가드 `_checkExportAllowed`/`_markExportStart`/`_markExportEnd` + `loadExcelJS`. **`confirmAuditExport` 는 부르지 않는다**(§3-B)
   - 열: 이름(한자) · 이름(가나) · 이메일 · 캠페인번호 · 캠페인 · 모집 형식 · 채널 · 감사용 · 인증 상태(`certStatusLabelKo(g)` — stale #3) · 인증 성공일(`certSuccessAt(g)` → `formatDate`, 빈칸 허용) · 구매금액(¥) · 상한(¥) · 최근 제출일 · 영수증 상태 · 결과물 상태 · 대리 등록
   - 값 출처: 이름·이메일·감사용 = `g.influencer`(`name`/`name_kana`/`email`/`is_audit`). 채널 = 리뷰어형은 `g.campaign.channel` 목록, 그 밖은 `g.result.post_channel`, 둘 다 `getLookupLabel` 로 한국어화. 구매금액·상한 = 리뷰어형만 `g.receipt.purchase_amount`·`g.campaign.product_price`. ⚠️ `Number(null)` 이 0 이므로 **null 검사를 먼저** 한다. 결과물 상태 = 리뷰어형은 `result_status_repr`, 그 밖은 `g.result.status`. 대리 등록 = 그룹 결과물 중 `submitted_by_admin` 이 하나라도 있으면 O(표시 사슬 522~526 과 같은 판정)
   - 회차·지급 예정일 열은 **넣지 않는다**
   - 시트 「결과물(보이는 목록)」, 파일명 `deliverables-view-{행 수}-{YYYYMMDD}.xlsx`, 완료 알림 「엑셀 다운로드 완료 (N건)」

**산출 계약**: 위 표. 함수 자리는 사양서 §4 대로 `admin-deliverables.js` 다. `admin-excel.js` 로 옮기면 그 파일도 공유 지점이 되므로 옮기지 않는다
**선행**: B-0
**완료 정의**: 콘솔에서 `exportDeliverablesViewExcel()` 을 부르면 파일이 나오고, 행 수가 화면 「총 N건」(`delivTotalCount`)과 같다. 감사용 확인 창이 **뜨지 않는다**(§5-10 일부)
**검문소**: `reverb-reviewer`
**주의**:
- 화면은 점진 렌더라 아직 안 그려진 행도 `filtered` 에는 있다. 「화면에 보이는」은 **필터 결과 전체**라는 뜻이다(스크롤로 그려진 것만이 아니다)
- 기존 캠페인 결과물 엑셀 둘(`admin-excel.js` 561·1032)은 손대지 않는다(§5-12)

### B-2 — 툴바 단추 + B 검증 + 문서

**하는 일**: `dev/admin/index.html` 결과물 툴바 「보기 초기화」 묶음(1648~1651) 옆에 `admin-filter-group` 하나를 추가한다. 내용은 `<label>&nbsp;</label>` + 단추 `id="btnDelivViewExcel"` 「보이는 목록 엑셀」, 말풍선은 사양서 §3-B 첫 단락 문구 「지금 화면에 보이는 신청을 그대로 내려받습니다. 페이백 지급 명단은 정산 관리 → 지급 준비에서」. 「보기 초기화」는 기본 숨김(`display:none`)이지만 이 단추는 **항상 보인다**. 빌드 → 병합 요청 → 개발서버 검증 → 문서(사양서 「구현 결과」 · `CLAUDE.md` 결과물 관리 절의 「엑셀은 이 필터를 안 따라간다」 서술을 **고쳐 쓴다**(덧붙이지 않는다) · `FEATURE_SPEC.md`)
**완료 정의**:
- §5-9: 캠페인 매니저로 뽑으면 이메일이 빈칸이고 오류가 없다
- §5-10: 기간·탭·검색·「대리 등록만」을 걸었을 때 화면 건수와 엑셀 행 수가 같고 감사용 확인 창이 없다
- §5-11: 정산 후보에 드는 「또는」 캠페인 인증성공 건 하나의 B 「인증 성공일」 = A 시트 2 「인증성공일」(같은 PC)
- §5-12: 캠페인 결과물 엑셀 둘이 종전 그대로다
**검문소**: `reverb-reviewer` → `reverb-qa-tester` light(사용자가 시작, 단일 세션)
**주의**: §5-11 은 **A 가 개발서버에 먼저 있어야** 대조할 수 있다. B-2 검증을 A-3 뒤에 두거나, A 가 늦으면 정산 목록 화면 「인증성공일」로 대신 대조하고 그렇게 했다고 기록한다.

---

## ⚠️ 공유 지점 경고

| 공유 지점 | 누가 | 위험 | 처리 |
|---|---|---|---|
| 빌드 산출물 `admin/index.html`(루트) | A-3 · B-2 둘 다 빌드 | 두 병합 요청이 같은 산출물을 바꿔 **충돌이 100% 난다** | 뒤에 병합하는 쪽이 `origin/dev` 를 받아 **다시 빌드**해서 푼다. 산출물을 손으로 합치지 않는다 |
| `CLAUDE.md` | A-3(정산 절) · B-0·B-2(결과물 관리 절) | 다른 절이라 자동 병합될 가능성이 높지만 줄이 가까우면 충돌 | 뒤쪽이 받아서 푼다 |
| `docs/FEATURE_SPEC.md` · 사양서 「구현 결과」 | A-3 · B-2 | 같은 절에 동시 기록하면 충돌 | 사양서 「구현 결과」 안에 **「A」·「B」 소제목을 나눠** 각자 자기 칸만 쓴다 |
| `dev/admin/index.html`(원본) | **B-2 만** | stale #1 로 A 는 안 건드린다 | 겹침 없음. A 가 이 파일에 단추를 넣고 싶어지면 멈추고 조율한다(요약 표 머리가 이미 자바스크립트 안에 있으니 그 자리에 둘 것) |
| `dev/js/admin-deliverables.js` | B-0 · B-1 | 같은 파일 | 한 세션이 차례로 한다 |
| `dev/lib/shared.js` · `dev/lib/storage.js` | 아무도 | 핵심 공용 파일 | **이번 작업에서 고치지 않는다.** 필요해 보이면 멈추고 알린다 |
| 모집 형식 한국어 표기 | A-1 · B-1 (+ `admin-excel.js` 261 의 지역 함수) | 한국어 표기가 세 곳이 된다 | 이번엔 각자 지역 함수로 둔다. 세 번째가 생기는 시점이라 공용화는 후속으로 적어 둔다(`.claude/rules/quality.md`) |

---

## 🧭 배분 제안

- **개발 세션 1 — A 줄기(A-1 → A-2 → A-3)**: 파일 하나(`admin-settlements.js`)라 한 병합 요청으로 묶어도 된다. 선결 조건이 없어 **지금 착수할 수 있다.** 운영 배포 순서 제약도 없다. 데이터베이스 변경이 없고, 도입일·4단계와도 무관하다.
- **개발 세션 2 — B 줄기(B-0 → B-1 → B-2)**: B-0 은 전수조사 3차 후속이지만 파일이 같아 같은 세션이 먼저 처리하는 것이 자연스럽다. B-0 을 **별도 병합 요청**으로 먼저 개발서버에 반영한 뒤 B-1·B-2 를 올린다. B-0 만으로도 결과물 관리·캠페인 진행현황 화면의 날짜가 바뀌므로 따로 검증할 가치가 있다.
- 두 세션은 **작업 폴더(worktree)를 따로** 쓴다(고문이 메인 폴더에 있을 수 있음). 병합은 먼저 끝난 쪽부터, 뒤쪽이 산출물을 다시 빌드한다.
- 혼자 시퀀셜로 한다면 권장 순서는 **A → B-0 → B**다. A 가 먼저 있어야 B 의 §5-11 대조가 온전하다.
- 운영 배포는 A·B 각각 사용자 확인을 받는다. 두 줄기 모두 약관·개인정보 영향은 없다(사양서 §7).

### 구현 중 결정해서 「구현 결과」에 적을 것 (사용자 확인까지는 불필요)
1. 파일명 `{건수}` = 담은 건수 M(A)
2. 체크박스 상태는 모듈 변수 하나로 두 화면이 공유하고, 지급 준비에 들어올 때 초기화한다(stale #7)
3. 사람별 「지급일 기록 없음」 화면에서도 단추를 감춘다(stale #5)
4. B-0 에서 승인 시각이 빈 승인 행을 서버와 똑같이 다룰지 여부

---

## 구현 결과 (개발 세션이 채울 것 — A·B 소제목을 나눠 각자 기록)
### A
### B
