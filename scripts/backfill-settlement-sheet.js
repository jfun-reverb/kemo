// ════════════════════════════════════════════════════════════════════
// 과거 지급 시트를 송금 묶음으로 소급 반영한다 (일회성 — 사양서 docs/specs/2026-10-01-settlement-sheet-backfill.md)
//
// 왜 필요한가
//   소급 함수 `backfill_settlement_transfers_from_sheet`(마이그레이션 501)는 권한 판정에 **로그인**이 필요해
//   SQL 편집기로는 못 부른다. 묶음이 수백 개라 콘솔에서 손으로 나눠 부르면 실수가 난다 —
//   이 도구가 미리보기 → 확인 → 나눠 호출 → 결과 요약을 한 번에 한다.
//
// 어떻게 쓰나
//   1. 관리자 화면(`/admin/`)에 **최고 관리자로 로그인한 채로** 연다
//   2. 개발자 도구 콘솔에 이 파일 내용을 통째로 붙여넣는다 → `sheetBackfill` 함수가 생긴다
//   3. 대조 결과(입력 JSON — 묶음 배열)를 콘솔에서 변수에 넣는다:  const input = [ … ];
//      🔴 **이 파일에 입력을 넣지 않는다** — 이름·이메일·페이팔이 든 개인정보라 저장소에 들어가면 안 된다
//   4. 미리보기:            sheetBackfill(input)                          — 아무것도 안 쓴다
//   5. 한 묶음 먼저(운영):  sheetBackfill(input, { write: true, limit: 1, confirm: '운영 1묶음 기록' })
//      → 송금 내역 화면·조회로 확인한 뒤
//   6. 나머지:              sheetBackfill(input, { write: true, confirm: '운영 N묶음 기록' })   (N = 미리보기가 알려 준 수)
//      🔴 확인 문구 맨 앞은 **지금 붙어 있는 서버**(개발/운영)다 — 다른 서버용 문구를 붙여넣으면 거부된다
//      이미 반영된 묶음은 서버가 건너뛴다 — 몇 번을 돌려도 결과가 같다(5번에서 쓴 묶음도 6번에서 건너뜀)
//
// ⚠️ 개발서버·운영서버에서 **각각** 돌린다(데이터베이스가 서버마다 따로다).
// 🔴 출처는 서버가 항상 sheet_backfill 로 고정한다 — 도입일을 만들지 않는다.
//    **`record_settlement_transfers`(화면 기록 경로)를 대신 부르지 말 것** — 출처 app 한 줄이면 그 순간 도입일이
//    생기고 옛 송금완료 경로 셋이 거부된다(되돌릴 함수 없음).
// 🔴 되돌리는 함수가 없다. 운영에서 쓰기 전에 대상 행을 조회해 저장소 밖에 저장해 둘 것(작업표 P4).
// ⚠️ 같은 건이 두 묶음에 현재 송금으로 들어 있으면 **미리보기 단계에서 거부**한다 — 서버의 같은 검사는 한 번의
//    호출 안에서만 돌아, 나눠 부르면 뒤 묶음이 거부 대신 「이미 반영됨」으로 조용히 건너뛰어진다.
// ⚠️ 서버는 한 번 호출에 넘긴 묶음 중 **하나라도 걸리면 그 호출 전체를 안 쓴다.** 그래서 나눠 부르다 걸리면
//    거기서 멈추고, 앞서 쓴 호출은 그대로 남는다(다시 돌리면 그 묶음들은 건너뛴다).
// ════════════════════════════════════════════════════════════════════
async function sheetBackfill(input, opts) {
  const o = opts || {};
  const CHUNK = Math.max(1, Math.min(Number(o.chunk) || 20, 50));   // 한 번 호출에 보낼 묶음 수 — 잠금 시간을 짧게
  if (typeof db === 'undefined' || !db?.rpc) { console.error('로그인한 관리자 화면에서 돌려 주세요 (db 없음)'); return; }
  if (!Array.isArray(input) || !input.length) { console.error('입력은 묶음 배열이어야 합니다 — const input = [ … ]'); return; }
  // 지금 붙어 있는 서버 — 확인 문구에 넣어 다른 서버용 문구를 막는다
  const envName = (typeof SUPABASE_ENV !== 'undefined' && SUPABASE_ENV === 'production') ? '운영' : '개발';
  const envUrl = typeof SUPABASE_URL !== 'undefined' ? SUPABASE_URL : '(알 수 없음)';
  // 🔴 limit 는 **있으면 1 이상 정수만** — 0·빈 값이 「전체」로 읽히면 안 된다
  if (o.limit !== undefined && !(Number.isInteger(o.limit) && o.limit >= 1)) {
    console.error('limit 는 1 이상의 정수여야 합니다(전체를 쓰려면 limit 를 빼세요). 아무것도 안 썼습니다.'); return;
  }
  // 같은 건이 두 묶음에 현재 송금으로 — 서버 검사는 호출 단위라 여기서 입력 전체를 본다
  const seen = {};
  for (let bi = 0; bi < input.length; bi++) {
    const its = Array.isArray(input[bi].items) ? input[bi].items : [];
    for (let ii = 0; ii < its.length; ii++) {
      const it = its[ii];
      if ((it.link || 'current') !== 'current') continue;
      const key = it.settlement_id ? 's:' + it.settlement_id : 'a:' + it.application_id;
      if (seen[key] !== undefined && seen[key] !== bi) {
        console.error(`[시트 소급] 같은 건이 묶음 ${seen[key]} 와 ${bi} 에 현재 송금으로 들어 있습니다(${key}). 입력을 고쳐 주세요. 아무것도 안 썼습니다.`); return;
      }
      seen[key] = bi;
    }
  }

  // ── 미리보기 ─────────────────────────────────────────────────────
  let items = 0, sent = 0, estDate = 0, estFee = 0, confirmed = 0, oldLinks = 0;
  input.forEach(function (b) {
    const its = Array.isArray(b.items) ? b.items : [];
    items += its.length;
    its.forEach(function (it) {
      sent += Number(it.amount_jpy) || 0;
      if (it.confirmed_by && it.confirm_reason) confirmed += 1;
      if (it.link === 'old') oldLinks += 1;
    });
    if (b.sent_at_estimated) estDate += 1;
    if (b.fee_estimated) estFee += 1;
  });
  const target = o.limit !== undefined ? input.slice(0, o.limit) : input;
  console.log(`[시트 소급] 서버: ${envName} (${envUrl})`);
  console.log(`[시트 소급] 묶음 ${input.length}개 · 건 ${items}개 · 보낸 금액 ¥${sent.toLocaleString('ja-JP')}`
    + ` · 송금일 추정 ${estDate}묶음 · 수수료 추정 ${estFee}묶음 · 확인 표시 ${confirmed}건 · 옛 송금 연결 ${oldLinks}건`);
  console.log(`[시트 소급] 이번 대상 = 앞에서 ${target.length}묶음 (수수료 추정 묶음은 서버가 현재 규칙으로 계산한다)`);

  if (!o.write) {
    console.log(`[시트 소급] 미리보기만 했습니다. 쓰려면: sheetBackfill(input, { write: true${o.limit !== undefined ? ', limit: ' + target.length : ''}, confirm: '${envName} ${target.length}묶음 기록' })`);
    return { preview: true, bundles: target.length };
  }
  if (o.confirm !== `${envName} ${target.length}묶음 기록`) {
    console.error(`[시트 소급] 확인 문구가 다릅니다 — 지금 서버는 ${envName}입니다. confirm: '${envName} ${target.length}묶음 기록' 을 정확히 넣어 주세요. 아무것도 안 썼습니다.`);
    return;
  }

  // ── 쓰기 — CHUNK 묶음씩. 걸리면 멈춘다 ───────────────────────────────
  const written = [], skipped = [];
  for (let start = 0; start < target.length; start += CHUNK) {
    const part = target.slice(start, start + CHUNK);
    const { data, error } = await db.rpc('backfill_settlement_transfers_from_sheet', { p_bundles: part });
    if (error) {
      // 서버 오류의 「묶음 순번」은 이 호출 안의 순번(0부터)이다 — 전체 순번은 start 를 더한다
      console.error(`[시트 소급] 묶음 ${start}~${start + part.length - 1} 호출이 거부됐습니다(이 호출은 아무것도 안 썼습니다). `
        + `오류의 「묶음 순번」에 ${start} 를 더하면 전체 순번입니다.`, error.message || error);
      console.log(`[시트 소급] 여기까지 쓴 묶음 ${written.length}개 · 건너뛴 묶음 ${skipped.length}개. 고친 뒤 같은 입력으로 다시 돌리면 쓴 것은 건너뜁니다.`);
      return { written: written, skipped: skipped, stoppedAt: start, error: error.message || String(error) };
    }
    (data?.written || []).forEach(function (w) { written.push(Object.assign({}, w, { bundle_index: w.bundle_index + start })); });
    (data?.skipped || []).forEach(function (s) { skipped.push(Object.assign({}, s, { bundle_index: s.bundle_index + start })); });
    console.log(`[시트 소급] ${Math.min(start + CHUNK, target.length)}/${target.length} 묶음 처리`);
  }
  console.log(`[시트 소급] 끝 — 쓴 묶음 ${written.length}개 · 이미 반영돼 건너뛴 묶음 ${skipped.length}개`);
  if (skipped.length) console.table(skipped);
  return { written: written, skipped: skipped };
}
console.log('[시트 소급] sheetBackfill(input) 이 준비됐습니다 — 먼저 미리보기부터.');
