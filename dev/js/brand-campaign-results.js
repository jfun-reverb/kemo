// 브랜드 페이지 — 캠페인 상세 「결과물」 영역(2단계)
//   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 14」 · 피그마 05-1 구역 bw05-01a·01d·01e·01f·04·93
//   서버 함수 brand-campaign-results(purpose:'view' — 줄·세 숫자 / 'receipt' — 영수증 「열기」 때 하나씩 1시간, 조각 5b)
//   🔴 줄·열·끈 열 판정은 관리자 리포트·공유 화면과 같은 원본(report-rows.js) — buildReportRows · _reportExtToRow(rules:'campaign') ·
//      reportColumnsFor · reportShareColDraw · reportIsLinkable. 사본을 만들지 않는다.
//   🔴 끈 열은 서버가 비워 보낸다(화면에서 숨기기만 하지 않는다). 세 숫자는 서버 값 그대로(따로 세지 않는다).
//   🔴 상태 셋 — 불러오는 중 · 오류(「다시 시도」) · 준비 중(공개 꺼짐). 조회 실패를 「준비 중」으로 그리지 않는다.
//   🔴 view 응답의 receipt_url 은 저장값 그대로(비공개 통 경로 또는 옛 공개 주소) — 그대로 링크·이미지에 넣지 않는다.
//      영수증 「열기」는 누를 때 receipt 갈래로 그 한 장의 임시 주소를 받는다(열 때마다 새로 — 1시간 지나도 다시 열린다).
//   ⚠️ 이 페이지에서 뺀 열: 캠페인 번호·캠페인명·구매기간 — 한 캠페인 화면이라 머리·일정에 이미 있다. 「No.」는 열 고르기와 상관없이
//      늘 맨 앞(정렬 뒤 차례 — 피그마 bw05-01a·01e·01f). 이름(한자)·후리가나는 「이름」 한 칸으로 합쳐 「No.」 바로 뒤에 그린다.
//   🔴 외부 줄인지 브랜드가 알 수 없게(사양서 16-5 15번 ④ — 2026-10-22): 「구분」 칸·외부 문구·나눠 적기 없음 · 외부 줄에 값이 없는
//      칸도 REVERB 빈칸과 같은 「-」 · 줄 차례는 보이는 날짜 열의 가장 이른 날(_brSortRows) · 외부 줄에 값이 없는 열은 외부 줄이 있으면
//      그리지 않는다(_brExtLockedCol — 판정 정본은 서버, 서버가 열을 빼기 전까지의 화면 방어).
//   엑셀(조각 15): purpose:'excel' 한 번 — 영수증만 서버가 7일 서명(올린 사람 대조 551), 줄·열은 화면과 같은 _brBuildRowsCols ·
//      A1 안내(S27) · 파일 이름 「결과물_{제품명}_{YYYYMMDD}.xlsx」(S5) · 열람·내려받기 제공 기록은 서버 함수가 남긴다(배송 리스트 작업표 조각 R1 — 기록 실패면 응답 reason:'record_failed' → 기존 실패 문구). 열람 정지(S24)는 서버가 아직 안 준다(조각 4c) — 응답 reason:'suspended' · 요약 results_suspended 로 그린다.

const BRAND_RES_PAGE = 20;
const BRAND_RES_MSG = {
  loadFailTitle: '결과물을 불러오지 못했습니다',
  loadFailDesc: '인터넷 연결을 확인한 뒤 다시 시도해 주십시오. 계속되면 담당자에게 문의해 주십시오.',
  emptyTitle: '아직 제출된 결과물이 없습니다',
  emptyDesc: '인플루언서가 결과물을 내면 여기에 나타납니다.',
  countsNote: '세 숫자는 결과물 「건」 기준이라 아래 표의 사람 수와 다를 수 있습니다',
  suspendedDesc: '결과물 숫자와 표는 열람이 정지된 동안 보이지 않습니다',
  suspendedTitle: '결과물 열람이 정지되었습니다',
  suspendedBody: '이용약관에 따라 정지되었습니다. 자세한 사유는 등록된 이메일을 확인해 주십시오. 궁금한 점은 REVERB 운영팀 담당자에게 문의해 주십시오. 모집 현황·일정은 그대로 볼 수 있습니다.',
  note: '표시 항목은 담당자가 고른 열만 보입니다. 결과물을 제출한 분이 모두 나오며, 「상태」로 검수 진행을 구분합니다.',
  photoFailTitle: '사진을 열지 못했습니다',
  photoFailDesc: '창을 닫고 「열기」를 다시 눌러 주십시오(사진 주소는 열 때마다 새로 받습니다).'
};
const BRAND_RES_SKIP_COLS = ['no', 'campaign_no', 'campaign_name', 'purchase_period', 'account_id'];

let _brRes = null;   // { id, state:'loading'|'error'|'off'|'suspended'|'ok', rows, cols, counts, updatedAt, page, delivs }
let _brResSeq = 0;

// 열람 정지인가 — 요약(results_suspended) 또는 조회 응답(reason:'suspended'). 4c 전에는 늘 거짓
function brandResultsSuspended(c) {
  return !!(c && c.results_suspended) || !!(_brRes && c && _brRes.id === c.id && _brRes.state === 'suspended');
}
// 「결과물 게시」 칸 값 — 공개 켜짐이면 「검수 완료 / 참여 합계」(S11), 아니면 null(「-」)
function brandResultPostedText(c) {
  if (!c || !c.results_public || brandResultsSuspended(c) || c.result_posted == null) return null;
  return (Number(c.result_posted) || 0) + ' / ' + (Number(c.approved_count) || 0);
}
function brandResultPostedPct(c) {
  const t = Number(c && c.approved_count) || 0;
  if (brandResultPostedText(c) == null || t <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((Number(c.result_posted) || 0) / t * 100)));
}

// 응답 → 줄·열 — 화면(view)과 엑셀(excel)이 **같은 함수**로 만든다(「화면보다 많이 싣지 않는다」 — 조각 15)
function _brBuildRowsCols(b, camp) {
  const camps = (b.campaign_rows || []).map(x => ({ id: x.id, campaign_no: x.campaign_no, title: x.title }));
  const delivs = Array.isArray(b.deliverables) ? b.deliverables : [];
  let rows = buildReportRows(delivs, camps, b.users || {});
  const ext = (b.ext_rows || []).filter(reportExtRowSubmitted).map(x => _reportExtToRow(Object.assign({ account_id: '' }, x), null,
    { rules: 'campaign', campaign: { campaign_no: camp.campaign_no || '', campaign_name: camp.product || '' } }));
  rows = rows.concat(ext);
  rows.forEach(x => { x.account_id = ''; });   // 계정 ID 는 서버가 안 보낸다 — 열 자체를 비운다
  const chosen = Array.isArray(b.columns) ? b.columns : null;
  const hasExt = ext.length > 0;
  const cols = reportColumnsFor(rows).filter(c => BRAND_RES_SKIP_COLS.indexOf(c.key) === -1 && !(hasExt && _brExtLockedCol(c)) &&
    reportShareColDraw(c, chosen, rows));
  rows = _brSortRows(rows, cols);
  rows.forEach((x, i) => { x.no = i + 1; });
  return { rows, cols, delivs };
}
// 외부 줄에 값이 없는 열(사양서 ④ ⓓ) — 이름·후리가나·구매기간·구매일·큐텐·엣코스메를 뺀 채널의 계정·결과물·업로드 날짜
function _brExtLockedCol(c) {
  if (['name_kanji', 'name_kana', 'purchase_period', 'purchase_date'].indexOf(c.key) !== -1) return true;
  return !!c.ch && c.ch !== 'qoo10' && c.ch !== 'cosme';
}
// 줄 차례(사양서 ④ ⓒ) — 그리는 날짜 열 중 가장 이른 날 순 · 날짜 없는 줄은 맨 뒤 ·
// 같은 날짜끼리는 보이는 칸 값으로 만든 해시 순(외부·REVERB 출처순이 되지 않게 — 이름·신청일로 정렬하지 않는다)
function _brDateMs(v) {
  if (!v) return null;
  const s = String(v);
  const d = new Date(/^\d{4}-\d{2}-\d{2}$/.test(s) ? s + 'T00:00:00+09:00' : s);
  return isNaN(d.getTime()) ? null : d.getTime();
}
//   링크·주소 칸은 빼고 만든다 — 영수증 값이 화면(저장 경로)과 엑셀(그때 서명한 주소)에서 달라 차례가 어긋나지 않게
function _brRowHash(r, cols) {
  const t = cols.filter(c => !c.acct && !/_url$/.test(c.key)).map(c => String(r[c.key] == null ? '' : r[c.key])).join('\u0001');
  let h = 2166136261;
  for (let i = 0; i < t.length; i++) { h ^= t.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function _brSortRows(rows, cols) {
  const dateCols = cols.filter(c => c.key === 'purchase_date' || /_at$/.test(c.key));
  const keyed = rows.map(r => {
    const ms = dateCols.map(c => _brDateMs(r[c.key])).filter(x => x != null);
    return { r, d: ms.length ? Math.min.apply(null, ms) : Infinity, h: _brRowHash(r, cols) };
  });
  keyed.sort((a, b) => (a.d - b.d) || (a.h - b.h) || 0);
  return keyed.map(k => k.r);
}

// ── 불러오기 — 상세가 「ok」가 되면 부른다
async function loadBrandCampaignResults(id) {
  const seq = ++_brResSeq;
  if (!_brRes || _brRes.id !== id || _brRes.state !== 'ok') _brRes = { id, state: 'loading' };
  _brResRerender();
  const r = await brandCallFunction('brand-campaign-results', { campaign_id: id, purpose: 'view' }, { auth: true });
  if (seq !== _brResSeq) return;
  const b = r && r.body;
  if (!b || b.success !== true) { _brRes = { id, state: 'error' }; _brResRerender(); return; }
  if (b.ready !== true) { _brRes = { id, state: b.reason === 'suspended' ? 'suspended' : 'off' }; _brResRerender(); return; }
  const { rows, cols, delivs } = _brBuildRowsCols(b, (_bcDetail && _bcDetail.id === id && _bcDetail.camp) || {});
  _brRes = { id, state: 'ok', rows, cols, counts: b.counts || {}, updatedAt: b.updated_at || null, page: 0, delivs };
  _brResRerender();
}
function _brResRerender() {
  const sec = document.getElementById('bcResultSection');
  if (!sec || !_bcDetail || !_brRes || _bcDetail.id !== _brRes.id) return;
  sec.outerHTML = brandResultSectionHtml(_bcDetail.camp);
  if (typeof _bcRerenderStatsIfShown === 'function') _bcRerenderStatsIfShown();
  // 배송 리스트 「결과물 보기」로 왔으면 결과물을 받은 뒤 한 번만 그 칸으로 내린다(불러오는 중에는 칸 높이가 바뀌어 기다린다)
  if (_brScrollTarget === _brRes.id && _brRes.state !== 'loading') {
    _brScrollTarget = null;
    const now = document.getElementById('bcResultSection');
    if (now) now.scrollIntoView({ block: 'start', behavior: 'smooth' });
  }
}
// 배송 리스트(brand-shipping.js)의 「결과물 보기」가 상세로 가기 전에 부른다 — 그 캠페인 상세의 결과물 칸으로 내릴 표시
let _brScrollTarget = null;
function brandScrollToResultsOnce(id) { _brScrollTarget = id; }

// ── 그리기
function _brShortDate(v) {
  if (!v) return '';
  const s = String(v);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s.slice(5, 7) + '/' + s.slice(8, 10);
  const d = new Date(s);
  return isNaN(d.getTime()) ? '' : _brandPad2(d.getMonth() + 1) + '/' + _brandPad2(d.getDate());
}
function _brDash() { return '<span class="brand-dash">-</span>'; }
function _brStatusCell(s) {
  const cls = s === '인증성공' ? 'is-ok' : s === '인증샷 제출중' ? 'is-wait' : '';
  return s ? '<span class="br-st ' + cls + '">' + brandEsc(s) + '</span>' : _brDash();
}
// 게시물·인증샷 칸 — http(s) 일 때만 새 탭 「열기」, 아니면 글자 그대로(reportIsLinkable — 공유 화면과 같은 판정)
function _brLinkCell(v) {
  const list = String(v || '').split(/\r?\n/).map(u => u.trim()).filter(Boolean);
  if (!list.length) return _brDash();
  return list.map((u, i) => reportIsLinkable(u)
    ? '<a class="br-link" href="' + brandEsc(u) + '" target="_blank" rel="noopener">' + (list.length > 1 ? '열기 ' + (i + 1) : '열기') + ' <span aria-hidden="true">↗</span></a>'
    : '<span class="br-raw">' + brandEsc(u) + '</span>').join(' · ');
}
// 영수증 칸 — 값이 있으면 「열기」(누를 때 서명 — S26). REVERB 줄은 결과물 번호로, 외부 줄은 http(s) 주소일 때만 그대로.
//   🔴 단추 모양은 두 갈래가 같다(외부 줄인지 화면 요소로 드러나지 않게) — 갈래는 누를 때 줄 값으로 가른다
function _brReceiptCell(r, rowIdx) {
  if (!r.receipt_url) return _brDash();
  const btn = (i, n) => '<button type="button" class="br-link" data-br-act="photo" data-row="' + rowIdx + '"' +
    (n > 1 ? ' data-i="' + i + '"' : '') + '>' + (n > 1 ? '열기 ' + (i + 1) : '열기') + '</button>';
  if (!r._ext) return btn(0, 1);
  const list = String(r.receipt_url).split(/\r?\n/).map(u => u.trim()).filter(reportIsLinkable);
  return list.length ? list.map((u, i) => btn(i, list.length)).join(' · ') : _brDash();
}
function _brCellHtml(r, c, rowIdx) {
  const v = r[c.key];
  if (c.key === 'name_kanji') {
    const t = [r.name_kanji, r.name_kana].filter(Boolean).join(' ');
    return t ? brandEsc(t) : _brDash();
  }
  if (c.key === 'status') return _brStatusCell(v);
  if (c.key === 'receipt_url') return _brReceiptCell(r, rowIdx);
  if (c.ch && /_url$/.test(c.key)) {
    const more = (c.ch === 'etc' && r.ch_etc_more > 0) ? ' <span class="br-more">외 ' + r.ch_etc_more + '건</span>' : '';
    return _brLinkCell(v) + more;
  }
  if (c.acct) {
    if (!v) return _brDash();
    const txt = r[c.key + '_text'] || v;
    return reportIsLinkable(v) ? '<a class="br-link" href="' + brandEsc(v) + '" target="_blank" rel="noopener">' + brandEsc(txt) + '</a>' : brandEsc(txt);
  }
  if (c.key === 'amount') return (v === '' || v === null || v === undefined) ? _brDash() : '¥' + Number(v).toLocaleString('ja-JP');
  if (c.key === 'purchase_date' || /_at$/.test(c.key)) return _brShortDate(v) || _brDash();
  const t = v === null || v === undefined ? '' : String(v);
  return t ? brandEsc(t) : _brDash();
}
// 이름 두 칸은 「이름」 한 칸으로(피그마) — 후리가나 칸은 그리지 않고 한자 칸에 합친다. 한자 칸이 꺼졌으면 후리가나 칸이 「이름」
function _brDrawCols(cols) {
  const hasKanji = cols.some(c => c.key === 'name_kanji');
  const out = cols.filter(c => !(hasKanji && c.key === 'name_kana')).map(c =>
    (c.key === 'name_kanji' || c.key === 'name_kana') ? Object.assign({}, c, { label: '이름', key: 'name_kanji' }) : c);
  // 「이름」은 「No.」 바로 뒤 — 나머지 차례는 reportColumnsFor 그대로
  const i = out.findIndex(c => c.key === 'name_kanji');
  if (i > 0) out.unshift(out.splice(i, 1)[0]);
  return out;
}
function _brTableHtml(st) {
  const cols = _brDrawCols(st.cols);
  const start = st.page * BRAND_RES_PAGE;
  const slice = st.rows.slice(start, start + BRAND_RES_PAGE);
  const head = '<th>No.</th>' + cols.map(c => '<th>' + brandEsc(c.label.replace(/\s*\(URL\)$/, '')) + '</th>').join('');
  const body = slice.map((r, i) => '<tr><td>' + r.no + '</td>' +
    cols.map(c => '<td>' + _brCellHtml(r, c, start + i) + '</td>').join('') + '</tr>').join('');
  return '<div class="br-table-scroll"><table class="br-table"><thead><tr>' + head + '</tr></thead><tbody>' + body + '</tbody></table></div>';
}
function _brPagerHtml(st) {
  const n = st.rows.length;
  if (n <= BRAND_RES_PAGE) return '';
  const pages = Math.ceil(n / BRAND_RES_PAGE), p = st.page;
  const from = p * BRAND_RES_PAGE + 1, to = Math.min(n, (p + 1) * BRAND_RES_PAGE);
  let btns = '<button type="button" class="br-page" data-br-act="page" data-page="' + (p - 1) + '"' + (p === 0 ? ' disabled' : '') + ' aria-label="이전 쪽">‹</button>';
  for (let i = 0; i < pages; i++) {
    btns += '<button type="button" class="br-page' + (i === p ? ' is-on' : '') + '" data-br-act="page" data-page="' + i + '"' + (i === p ? ' aria-current="page"' : '') + '>' + (i + 1) + '</button>';
  }
  btns += '<button type="button" class="br-page" data-br-act="page" data-page="' + (p + 1) + '"' + (p >= pages - 1 ? ' disabled' : '') + ' aria-label="다음 쪽">›</button>';
  return '<div class="br-pager"><span>' + from + '–' + to + ' / ' + n + '줄 · ' + BRAND_RES_PAGE + '줄씩</span><div class="br-pages">' + btns + '</div></div>';
}
function brandResultSectionHtml(c) {
  const st = (_brRes && c && _brRes.id === c.id) ? _brRes : { state: 'loading' };
  const open = '<section class="bc-card" id="bcResultSection"><h2 class="bc-card-title">결과물</h2>';
  if (brandResultsSuspended(c)) {
    return open + '<p class="bc-card-desc">' + brandEsc(BRAND_RES_MSG.suspendedDesc) + '</p>' +
      '<div class="bc-result-empty"><p class="bc-result-title">' + brandEsc(BRAND_RES_MSG.suspendedTitle) + '</p>' +
      '<p class="bc-result-desc">' + brandEsc(BRAND_RES_MSG.suspendedBody) + '</p></div></section>';
  }
  if (st.state === 'loading') return open + '<div class="bo-state" aria-busy="true"><p class="bo-state-desc">불러오는 중…</p></div></section>';
  if (st.state === 'error') {
    return open + '<div class="bo-state" role="alert"><span class="bo-state-icon is-error" aria-hidden="true">!</span>' +
      '<p class="bo-state-title">' + brandEsc(BRAND_RES_MSG.loadFailTitle) + '</p><p class="bo-state-desc">' + brandEsc(BRAND_RES_MSG.loadFailDesc) + '</p>' +
      '<button type="button" class="brand-btn bo-state-btn" data-br-act="retry">다시 시도</button></div></section>';
  }
  if (st.state === 'off') {
    return open + '<p class="bc-card-desc">결과물 숫자는 결과가 공개되면 보입니다</p>' +
      '<div class="bc-result-empty"><p class="bc-result-title">' + brandEsc(BRAND_CAMP_MSG.resultTitle) + '</p>' +
      '<p class="bc-result-desc">' + brandEsc(BRAND_CAMP_MSG.resultDesc) + '</p></div></section>';
  }
  const k = st.counts || {};
  const num = (label, v) => '<div class="br-count"><span>' + brandEsc(label) + '</span><b>' + (Number(v) || 0) + '</b></div>';
  const rows = st.rows;
  const buyN = rows.filter(r => r.receipt_uploaded_at).length, revN = rows.filter(reportRowHasResult).length;   // 공유 화면 요약과 같은 함수
  return open +
    '<div class="br-counts">' + num('제출', k.submitted) + num('검수 완료', k.approved) + num('검수 대기', k.pending) + '</div>' +
    '<p class="br-counts-note">' + brandEsc(BRAND_RES_MSG.countsNote) + '</p>' +
    '<div class="br-meta"><span>업데이트 ' + brandEsc(brandFormatDateTime(st.updatedAt) || '-') + ' · 인원 ' + rows.length + '명 · 구매 ' + buyN + ' · 결과물 ' + revN + '</span>' +
      (rows.length ? '<button type="button" class="brand-btn br-excel" data-br-act="excel"' + (_brExcelBusy ? ' disabled' : '') + '>' +
        '<span aria-hidden="true">↓</span> ' + (_brExcelBusy ? '엑셀 만드는 중…' : '엑셀 내려받기') + '</button>' : '') + '</div>' +
    (rows.length
      ? _brTableHtml(st) + _brPagerHtml(st) + '<p class="br-note">' + brandEsc(BRAND_RES_MSG.note) + '</p>'
      : '<div class="bc-result-empty"><p class="bc-result-title">' + brandEsc(BRAND_RES_MSG.emptyTitle) + '</p><p class="bc-result-desc">' + brandEsc(BRAND_RES_MSG.emptyDesc) + '</p></div>') +
    '</section>';
}

// ── 엑셀(조각 15 · 피그마 bw05-93 ①③) — 내려받는 순간 purpose:'excel' 로 새로 받는다(영수증 7일 링크가 그때 만들어진다)
const BRAND_RES_EXCEL_FAIL = '엑셀을 만들지 못했습니다. 잠시 후 다시 시도해 주십시오.';
let _brExcelBusy = false;
function _brLoadExcelJS() {
  if (window.ExcelJS) return Promise.resolve();
  return new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js';   // 공유 화면(report.html)과 같은 판
    s.onload = res; s.onerror = () => rej(new Error('exceljs'));
    document.head.appendChild(s);
  });
}
function _brYmd(d) { return d.getFullYear() + _brandPad2(d.getMonth() + 1) + _brandPad2(d.getDate()); }
// 엑셀 칸 값 — 화면과 같은 열, 값은 글자·숫자(링크는 주소 그대로 — http(s) 만)
function _brExcelValue(r, c) {
  const v = r[c.key];
  if (c.key === 'name_kanji') return [r.name_kanji, r.name_kana].filter(Boolean).join(' ');
  if (c.key === 'amount') return (v === '' || v === null || v === undefined) ? '' : Number(v);
  if (c.key === 'receipt_url' || (c.ch && /_url$/.test(c.key)) || c.acct) {
    const list = String(v || '').split(/\r?\n/).map(u => u.trim()).filter(Boolean);
    if (c.key === 'receipt_url') return list.filter(reportIsLinkable).join('\n');   // 서명 못 한 영수증(경로)은 싣지 않는다
    return list.join('\n');
  }
  if (c.key === 'purchase_date') return v ? brandFormatDate(v) : '';
  if (/_at$/.test(c.key)) return v ? brandFormatDateTime(v) : '';
  return v === null || v === undefined ? '' : String(v);
}
async function brandCampaignResultsExcel(btn) {
  if (_brExcelBusy || !_brRes || _brRes.state !== 'ok') return;
  const id = _brRes.id;
  const camp = (_bcDetail && _bcDetail.id === id && _bcDetail.camp) || {};
  _brExcelBusy = true;
  if (btn) { btn.disabled = true; btn.innerHTML = '<span aria-hidden="true">↓</span> 엑셀 만드는 중…'; }
  try {
    const [, res] = await Promise.all([_brLoadExcelJS(), brandCallFunction('brand-campaign-results', { campaign_id: id, purpose: 'excel' }, { auth: true })]);
    const b = res && res.body;
    if (!b || b.success !== true || b.ready !== true) throw new Error('not_ready');
    const { rows, cols } = _brBuildRowsCols(b, camp);
    const drawn = _brDrawCols(cols);
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('결과물');
    const today = new Date();
    // A1 안내(S27) — 머리글은 2행부터
    ws.getCell('A1').value = '「구매 영수증 (URL)」 링크는 내려받은 날(' + brandFormatDate(today.toISOString()) + ')부터 7일 동안만 열립니다. 지나면 브랜드 페이지에서 엑셀을 다시 내려받아 주십시오.';
    ws.getCell('A1').font = { color: { argb: 'FF71717A' } };
    const heads = ['No.'].concat(drawn.map(c => c.label));
    ws.addRow([]);   // 2행 자리(아래에서 채운다)
    ws.getRow(2).values = heads;
    ws.getRow(2).font = { bold: true };
    rows.forEach(r => ws.addRow([r.no].concat(drawn.map(c => _brExcelValue(r, c)))));
    ws.columns.forEach((col, i) => { col.width = i === 0 ? 6 : Math.max(10, Math.round(parseInt((drawn[i - 1] || {}).w || '120', 10) / 8)); });
    const buf = await wb.xlsx.writeBuffer();
    const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = '결과물_' + (String(camp.product || camp.campaign_no || '캠페인').replace(/[\\/:*?"<>|]/g, '').trim() || '캠페인') + '_' + _brYmd(today) + '.xlsx';   // S5
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (e) {
    brandToast(BRAND_RES_EXCEL_FAIL, { error: true });
  } finally {
    _brExcelBusy = false;
    const cur = document.querySelector('#bcResultSection [data-br-act="excel"]');
    if (cur) { cur.disabled = false; cur.innerHTML = '<span aria-hidden="true">↓</span> 엑셀 내려받기'; }
  }
}

// ── 영수증 사진 창(bw05-04) — 누를 때 그 한 장을 서명받는다(S26). 확대(누르기·휠)·이동(끌기), 바깥·Esc 로 닫기
let _brLb = null;
function _brLbClose() {
  if (!_brLb) return;
  document.removeEventListener('keydown', _brLb.onKey, true);
  _brLb.wrap.remove();
  const back = _brLb.back; _brLb = null;
  // 누른 단추가 그사이 다시 그려져 떨어졌으면 결과물 칸으로(초점이 사라지지 않게)
  if (back && back.isConnected && back.focus) back.focus();
  else { const sec = document.getElementById('bcResultSection'); if (sec) { sec.setAttribute('tabindex', '-1'); sec.focus(); } }
}
function _brLbOpen(caption, getUrl, back) {
  _brLbClose();
  const wrap = document.createElement('div');
  wrap.className = 'br-lb';
  wrap.setAttribute('role', 'dialog'); wrap.setAttribute('aria-modal', 'true'); wrap.setAttribute('aria-label', '영수증 사진');
  wrap.innerHTML = '<div class="br-lb-box"><div class="br-lb-head"><span>' + brandEsc(caption) + '</span>' +
    '<button type="button" class="br-lb-x" data-br-lb="close" aria-label="닫기">×</button></div>' +
    '<div class="br-lb-body"><p class="br-lb-wait">사진을 여는 중…</p></div></div>';
  const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); _brLbClose(); } };
  _brLb = { wrap, onKey, back };
  wrap.addEventListener('click', (e) => { if (e.target === wrap || (e.target.closest && e.target.closest('[data-br-lb="close"]'))) _brLbClose(); });
  document.addEventListener('keydown', onKey, true);
  document.body.appendChild(wrap);
  wrap.querySelector('.br-lb-x').focus();
  const mine = _brLb;
  const fail = () => {
    if (_brLb !== mine) return;
    wrap.querySelector('.br-lb-body').innerHTML = '<div class="br-lb-fail"><p class="br-lb-fail-title">' + brandEsc(BRAND_RES_MSG.photoFailTitle) + '</p>' +
      '<p>' + brandEsc(BRAND_RES_MSG.photoFailDesc) + '</p><button type="button" class="brand-btn brand-btn-line" data-br-lb="close">닫기</button></div>';
  };
  Promise.resolve().then(getUrl).then((url) => {
    if (_brLb !== mine) return;
    if (!url) { fail(); return; }
    const body = wrap.querySelector('.br-lb-body');
    body.innerHTML = '<img class="br-lb-img" alt="' + brandEsc(caption) + '" draggable="false">';
    const img = body.querySelector('img');
    _brLbZoom(body, img);
    img.onerror = fail;
    img.src = url;
  }, fail);
}
function _brLbZoom(box, img) {
  let scale = 1, x = 0, y = 0, drag = null;
  const apply = () => { img.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + scale + ')'; img.classList.toggle('is-zoom', scale > 1); };
  img.addEventListener('click', () => { if (drag && drag.moved) return; scale = scale > 1 ? 1 : 2; if (scale === 1) { x = 0; y = 0; } apply(); });
  box.addEventListener('wheel', (e) => { e.preventDefault(); scale = Math.max(1, Math.min(5, scale * (e.deltaY < 0 ? 1.15 : 1 / 1.15))); if (scale === 1) { x = 0; y = 0; } apply(); }, { passive: false });
  img.addEventListener('pointerdown', (e) => { if (scale <= 1) return; drag = { sx: e.clientX - x, sy: e.clientY - y, moved: false }; img.setPointerCapture(e.pointerId); });
  img.addEventListener('pointermove', (e) => { if (!drag || !img.hasPointerCapture(e.pointerId)) return; x = e.clientX - drag.sx; y = e.clientY - drag.sy; drag.moved = true; apply(); });
  img.addEventListener('pointerup', () => { setTimeout(() => { drag = null; }, 0); });
}
// REVERB 줄의 영수증 결과물 번호 — 그 응모의 영수증 결과물 중 표에 쓴 값과 같은 것(buildReportRows 가 고른 최신 건)
function _brReceiptDeliverableId(r) {
  const list = (_brRes && _brRes.delivs) || [];
  const m = list.find(d => d && d.kind === 'receipt' && d.application_id === r._application_id && d.receipt_url === r.receipt_url);
  return m ? m.id : null;
}
async function _brSignReceipt(campaignId, deliverableId) {
  if (!deliverableId) return null;
  const res = await brandCallFunction('brand-campaign-results', { campaign_id: campaignId, purpose: 'receipt', deliverable_id: deliverableId }, { auth: true });
  const b = res && res.body;
  return (b && b.success === true && typeof b.url === 'string' && reportIsLinkable(b.url)) ? b.url : null;
}

// ── 단추(위임)
document.addEventListener('click', (e) => {
  const el = e.target.closest && e.target.closest('#brandPageHost [data-br-act]');
  if (!el || el.disabled || !_brRes) return;
  const act = el.dataset.brAct;
  if (act === 'retry') { el.disabled = true; loadBrandCampaignResults(_brRes.id); return; }
  if (act === 'excel') { brandCampaignResultsExcel(el); return; }
  if (act === 'page') {
    const p = Number(el.dataset.page);
    if (!isNaN(p) && _brRes.rows && p >= 0 && p * BRAND_RES_PAGE < _brRes.rows.length) {
      _brRes.page = p; _brResRerender();
      const sec = document.getElementById('bcResultSection');
      if (sec) sec.scrollIntoView({ block: 'start', behavior: 'smooth' });
      const cur = sec && sec.querySelector('.br-page.is-on');   // 다시 그린 쪽 단추로 초점(키보드로 이어 넘길 수 있게)
      if (cur) cur.focus({ preventScroll: true });
    }
    return;
  }
  const r = _brRes.rows && _brRes.rows[Number(el.dataset.row)];
  if (!r) return;
  // 창 제목 「영수증 · 이름 · 구매일」(피그마 bw05-04) — 값이 있는 것만, 외부 줄인지 드러내지 않는다
  //   그리는 열의 값만 쓴다(꺼지거나 잠긴 열의 값이 창 제목으로 새지 않게)
  const drawn = (_brRes.cols || []).map(c => c.key);
  const on = (k) => drawn.indexOf(k) !== -1;
  const name = [on('name_kanji') ? r.name_kanji : '', on('name_kana') ? r.name_kana : ''].filter(Boolean).join(' ');
  const day = _brShortDate((on('purchase_date') && r.purchase_date) || (on('receipt_uploaded_at') && r.receipt_uploaded_at) || '');
  const who = ['영수증', name, day].filter(Boolean).join(' · ');
  if (act !== 'photo') return;
  if (r._ext) {
    const list = String(r.receipt_url || '').split(/\r?\n/).map(u => u.trim()).filter(reportIsLinkable);
    const u = list[Number(el.dataset.i) || 0];
    _brLbOpen(who, () => (reportIsLinkable(u) ? u : null), el);
  } else {
    const campaignId = _brRes.id, did = _brReceiptDeliverableId(r);
    _brLbOpen(who, () => _brSignReceipt(campaignId, did), el);
  }
});
