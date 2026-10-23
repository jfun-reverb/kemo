// 브랜드 페이지 — 배송 리스트 엑셀 내려받기·올리기(PC 만)
//   작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S6」 · 사양서 ① §4-2·§4-3 · 결정 D1·D2·D3·D7·D8·D21·D22·D25
//   피그마 Brand 1차 bw05-03(올리기 창) · bw05-03a(반영 전 확인) · bw05-94 ⑦⑧(읽는 중·반영 중)
//   서버(557): get_my_brand_shipping_export(내려받기 — 누를 때 새로 받는다 · 제공 기록 shipping_excel)
//              get_my_brand_shipping_list(올리기 직전 — 줄마다 version 을 여기서 가져온다. 파일의 값은 믿지 않는다)
//              save_my_brand_shipping_rows(「새로 등록」·「바뀜」만 한 번에 — 충돌·취소 줄은 서버가 건너뛰고 skipped 로 돌려준다 D22)
//   🔴 올린 파일은 브라우저 안에서만 읽는다 — 서버로 보내는 것은 줄 번호·택배사(「기타」면 이름)·송장번호·발송일뿐(결정 3).
//      파일·칸 값을 오류 기록·콘솔에 남기지 않는다(브랜드 화면에는 오류 수집이 없다 — 새로 붙일 때도 이 파일의 값은 싣지 말 것)
//   🔴 줄은 「줄 번호」 칸으로만 맞춘다(정렬·행 삭제해도 된다) · 다른 캠페인 파일은 1행 안내 줄의 캠페인 번호로 거부(D21)
//   · 엑셀 빈 송장은 지우기가 아니라 「반영 안 됨」(D1 — 지우기는 화면 「송장 지우기」) · 종료 캠페인은 올리기 단추 없음(D2)
//   · 머리글 이름은 SHIPXL_HEADS(공용 shipping-excel-core.js) 한 곳 — 내려받기·올리기·관리자 송장 양식이 같은 목록을 쓴다(D3)

// 열 목록·상한·파일 읽기·분류는 공용 shipping-excel-core.js(관리자와 함께 쓴다 — 머리글 이름 D3 단일 소스)
const BSX_HEADS = SHIPXL_HEADS;
const BSX_MSG = {
  dlFail: '엑셀을 만들지 못했습니다. 잠시 후 다시 시도해 주십시오.',
  readFail: '파일을 읽지 못했습니다. 이 화면에서 내려받은 .xlsx 파일인지 확인해 주십시오.',
  notXlsx: '.xlsx 파일만 올릴 수 있습니다. CSV 는 받지 않습니다.',
  tooBig: '파일이 5MB 를 넘습니다. 내려받은 파일에서 송장 칸만 채워 올려 주십시오.',
  tooMany: '줄이 2,000줄을 넘습니다. 내려받은 파일을 그대로 써 주십시오.',
  noHead: '「줄 번호」·「택배사」·「송장번호」 머리글을 찾지 못했습니다. 이 화면에서 내려받은 파일을 써 주십시오.',
  noNotice: '맨 위 안내 줄(캠페인 번호)이 없습니다. 이 화면에서 내려받은 파일을 지우지 말고 써 주십시오.',
  otherCampaign: '다른 캠페인의 파일입니다. 이 캠페인 배송 리스트에서 내려받은 파일을 올려 주십시오.',
  listFail: '배송 리스트를 불러오지 못했습니다. 잠시 뒤 다시 시도해 주십시오.',
  applyFail: '반영하지 못했습니다. 잠시 뒤 다시 시도해 주십시오.',
  applied: n => n + '줄을 반영했습니다.'
};
// 반영 안 됨 이유 — 미리 보기(화면 판정) · 결과(서버 skipped.reason) 공용
const BSX_SKIP_TEXT = {
  cancelled: '취소된 분',
  blank: '송장 빈칸 — 지우려면 화면에서 「송장 지우기」',
  no_tracking: '송장번호 없음',
  no_row: '없는 줄',
  carrier: '택배사 이름 확인',
  format_tracking: '형식 오류 — 송장번호는 영문·숫자·하이픈·띄어쓰기 4~40자',
  format_date: '형식 오류 — 발송일(예: 2026-10-20)',
  format_row: '형식 오류 — 줄 번호',
  duplicate: '형식 오류 — 같은 줄 번호가 두 번',
  // 서버 skipped.reason
  not_found: '없는 줄',
  version_conflict: '다른 곳에서 먼저 바뀜 — 다시 내려받아 확인',
  invalid_tracking: '형식 오류 — 송장번호',
  carrier_required: '택배사 이름 확인',
  invalid_carrier: '택배사 이름 확인',
  invalid_shipped_on: '형식 오류 — 발송일(오늘부터 30일 뒤까지)'
};

let _bsxDlBusy = false;
let _bsxModal = null;   // { el, id, step:'pick'|'reading'|'preview'|'applying'|'result', plan, result, prevFocus }

// ── 배송 리스트 패널 머리 단추(brand-shipping.js renderBrandShippingPage 가 부른다) — 모바일은 없음(결정 12)
function brandShippingExcelButtonsHtml(d) {
  if (_bcMobileMq.matches || !d || !(Number((d.counts || {}).total) || 0)) return '';
  return '<div class="bsx-tools">' +
    '<button type="button" class="brand-btn brand-btn-line bsx-btn" data-bsx-act="download"' + (_bsxDlBusy ? ' disabled' : '') + '>' +
      '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">download</span>' + (_bsxDlBusy ? '엑셀 만드는 중…' : '엑셀 내려받기') + '</button>' +
    (d.editable === false ? '' :
      '<button type="button" class="brand-btn bsx-btn" data-bsx-act="upload">' +
        '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">upload_file</span>엑셀로 송장 올리기</button>') +
  '</div>';
}

// ── 공용 조각(공용 파일을 감싼다)
const _bsxStatusText = shipXlStatusText;
const _bsxCarrierCells = shipXlCarrierCells;
function _bsxFileName(d) {
  const p = String(d.product || d.campaign_no || '캠페인').replace(/[\\/:*?"<>|]/g, '').trim() || '캠페인';
  return '배송리스트_' + p + '_' + _brYmd(new Date()) + '.xlsx';   // 결과물 엑셀(결과물_{제품명}_{YYYYMMDD})과 같은 모양
}
function _bsxNoticeText(campaignNo) { return shipXlNoticeText(campaignNo, false); }

// ── 내려받기(bw05-02 「엑셀 내려받기」) — 누를 때 새로 받는다(제공 기록 shipping_excel 은 서버가 남긴다)
async function brandShippingExcelDownload() {
  const id = _bsList && _bsList.id;
  if (_bsxDlBusy || !id) return;
  _bsxDlBusy = true;
  _bsRerenderIfShown();
  try {
    const [, res] = await Promise.all([_brLoadExcelJS(), brandRpc('get_my_brand_shipping_export', { p_campaign_id: id })]);
    const d = res && !res.error ? res.data : null;
    if (d && d.success === false) { brandToast(brandShippingSuspended(d) ? BRAND_SHIP_MSG.suspendedToast : BRAND_SHIP_MSG.notFound, { error: true }); loadBrandShippingPage(id); return; }
    if (!d || d.success !== true || !d.campaign_no) throw new Error('export');
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('배송 리스트');
    ws.getCell('A1').value = _bsxNoticeText(d.campaign_no);
    ws.getCell('A1').font = { color: { argb: 'FF71717A' } };
    ws.addRow(BSX_HEADS.map(h => h.label)).font = { bold: true };   // 2행 — addRow 로 넣는다(빈 줄로 두면 첫 데이터 줄이 이 자리에 들어간다)
    (Array.isArray(d.rows) ? d.rows : []).forEach(r => {
      const cancelled = r.status === 'cancelled';
      const car = _bsxCarrierCells(r);
      const vals = {
        row_no: r.row_no != null ? r.row_no : '',
        name: _bsName(r),                                 // 탈퇴로 이름이 비면 「탈퇴한 회원」(D25)
        kana: r.name_kana || '',
        zip: cancelled ? '' : (r.postal_code || ''),      // 취소 줄은 서버가 이미 비운다 — 두 번 지킨다
        addr: cancelled ? '' : (r.address || ''),
        phone: cancelled ? '' : (r.phone || ''),          // 회원이 적은 그대로(D24)
        status: _bsxStatusText(r),
        carrier: car[0], other: car[1],
        tracking: r.tracking_no || '',
        shipped_on: r.shipped_on ? String(r.shipped_on).slice(0, 10) : ''
      };
      ws.addRow(BSX_HEADS.map(h => vals[h.key]));
    });
    // 우편번호·전화·송장·발송일은 글자 칸 — 엑셀이 앞 0 을 지우거나 긴 숫자를 지수로 바꾸지 않게
    BSX_HEADS.forEach((h, i) => {
      const col = ws.getColumn(i + 1);
      col.width = h.w;
      if (h.text) col.numFmt = '@';
    });
    const buf = await wb.xlsx.writeBuffer();
    const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = _bsxFileName(d);
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (e) {
    brandToast(BSX_MSG.dlFail, { error: true });
  } finally {
    _bsxDlBusy = false;
    _bsRerenderIfShown();
  }
}

// ── 올린 파일 읽기·분류 — 공용 파일(shipping-excel-core.js)
const BSX_READ_ERR = { not_xlsx: 'notXlsx', too_big: 'tooBig', too_many: 'tooMany', read_fail: 'readFail', no_head: 'noHead', no_notice: 'noNotice', other_campaign: 'otherCampaign' };
// 파일 → { error:문구 } | { rows }
async function _bsxReadFile(file, campaignNo) {
  const res = await shipXlReadFile(file, campaignNo, _brLoadExcelJS);
  return res.error ? { error: BSX_MSG[BSX_READ_ERR[res.error]] || BSX_MSG.readFail } : res;
}
// 파일 줄 × 새로 받은 리스트 → 미리 보기 분류(bw05-03a) — 브랜드 저장 값은 「줄 번호」 + 방금 받은 리스트의 버전
function _bsxPlan(fileRows, list) {
  const plan = shipXlPlan(fileRows, list, { trackingRe: BRAND_SHIP_TRACKING_RE, nameOf: _bsName });
  plan.add.concat(plan.change).forEach(it => {
    it.payload = Object.assign({ row_no: it.rowNo, expected_version: it.cur.version }, it.save);
  });
  return plan;
}

// ── 올리기 창(bw05-03 → 03a → 결과)
function _bsxOpen() {
  const id = _bsList && _bsList.id;
  if (!id || _bsxModal) return;
  const wrap = document.createElement('div');
  wrap.className = 'brand-modal';
  wrap.setAttribute('role', 'dialog');
  wrap.setAttribute('aria-modal', 'true');
  wrap.setAttribute('aria-labelledby', 'bsxTitle');
  _bsxModal = { el: wrap, id, step: 'pick', plan: null, result: null, error: '', prevFocus: document.activeElement };
  wrap.addEventListener('click', _bsxOnClick);
  wrap.addEventListener('change', _bsxOnChange);
  document.addEventListener('keydown', _bsxOnKey, true);
  document.body.appendChild(wrap);
  _bsxRender();
}
function _bsxClose() {
  const m = _bsxModal;
  if (!m || m.step === 'reading' || m.step === 'applying') return;   // 도는 중에는 닫지 않는다
  _bsxModal = null;
  document.removeEventListener('keydown', _bsxOnKey, true);
  m.el.remove();
  if (m.prevFocus && m.prevFocus.isConnected && typeof m.prevFocus.focus === 'function') m.prevFocus.focus();
}
function _bsxOnKey(e) {
  if (!_bsxModal) return;
  if (e.key === 'Escape') { e.stopPropagation(); _bsxClose(); return; }
  if (e.key === 'Tab') {
    const f = Array.from(_bsxModal.el.querySelectorAll('button:not([disabled]), [tabindex="0"]'));
    if (!f.length) { e.preventDefault(); return; }   // 읽는 중·반영 중 — 단추가 모두 꺼져도 창 밖으로 나가지 않게
    const i = f.indexOf(document.activeElement);
    if (i === -1) { e.preventDefault(); f[0].focus(); return; }
    if (e.shiftKey && i === 0) { e.preventDefault(); f[f.length - 1].focus(); }
    else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
  }
}
function _bsxOnClick(e) {
  const m = _bsxModal;
  if (!m) return;
  if (e.target === m.el) { _bsxClose(); return; }
  const b = e.target.closest('[data-bsx-m]');
  if (!b || b.disabled) return;
  const act = b.dataset.bsxM;
  if (act === 'close') { _bsxClose(); return; }
  if (act === 'pick') { const inp = m.el.querySelector('#bsxFile'); if (inp) { inp.value = ''; inp.click(); } return; }
  if (act === 'apply') { _bsxApply(); return; }
}
function _bsxOnChange(e) {
  if (e.target && e.target.id === 'bsxFile' && e.target.files && e.target.files[0]) {
    const f = e.target.files[0];
    e.target.value = '';   // 같은 파일을 다시 골라도 change 가 오게
    _bsxRead(f);
  }
}

async function _bsxRead(file) {
  const m = _bsxModal;
  if (!m || m.step === 'reading' || m.step === 'applying') return;
  m.step = 'reading'; m.error = ''; m.plan = null;
  _bsxRender();
  let list = null, err = '';
  try {
    // 줄마다 version 은 지금 새로 받은 리스트에서(작업표 S6) — 파일 읽기와 함께
    const res = await brandRpc('get_my_brand_shipping_list', { p_campaign_id: m.id });
    const d = res && !res.error ? res.data : null;
    if (brandShippingSuspended(d)) err = BRAND_SHIP_MSG.suspendedToast;
    else if (!d || d.success !== true || !d.campaign_no) err = BSX_MSG.listFail;
    else if (d.editable === false) err = BRAND_SHIP_MSG.ended;
    else list = d;
    if (list) {
      const parsed = await _bsxReadFile(file, list.campaign_no);
      if (parsed.error) err = parsed.error;
      else m.plan = _bsxPlan(parsed.rows, list);
    }
  } catch (e2) { err = BSX_MSG.readFail; }
  if (_bsxModal !== m) return;
  m.step = err ? 'pick' : 'preview';
  m.error = err;
  _bsxRender();
}

async function _bsxApply() {
  const m = _bsxModal;
  if (!m || m.step !== 'preview' || !m.plan) return;
  const items = m.plan.add.concat(m.plan.change);
  if (!items.length) return;
  m.step = 'applying';
  _bsxRender();
  let res = null;
  try {
    const r = await brandRpc('save_my_brand_shipping_rows', { p_campaign_id: m.id, p_rows: items.map(it => it.payload) });
    if (!r.error && r.data) res = r.data;
  } catch (e) { res = null; }
  if (_bsxModal !== m) return;
  if (!res) { m.step = 'preview'; _bsxRender(); brandToast(BSX_MSG.applyFail, { error: true }); return; }
  if (res.success !== true) {
    m.step = 'result'; _bsxClose();
    brandToast(brandShippingSuspended(res) ? BRAND_SHIP_MSG.suspendedToast
      : res.reason === 'campaign_ended' ? BRAND_SHIP_MSG.ended : BRAND_SHIP_MSG.notFound, { error: true });
    loadBrandShippingPage(m.id);
    return;
  }
  const saved = Array.isArray(res.saved) ? res.saved : [];
  const skipped = Array.isArray(res.skipped) ? res.skipped : [];
  if (saved.length) brandTouchActivity();   // 저장 성공 — 「마지막 접속」 기록
  loadBrandShippingPage(m.id);
  if (!skipped.length) {
    m.step = 'result'; _bsxClose();
    brandToast(BSX_MSG.applied(saved.length));
    return;
  }
  // 반영되지 않은 줄(D22) — 화면 목록으로만(D8 — 파일로 주지 않는다)
  const nameOf = new Map(items.map(it => [it.rowNo, it.name]));
  m.result = {
    saved: saved.length,
    skipped: skipped.map(s => ({ rowNo: s.row_no, name: nameOf.get(Number(s.row_no)) || '', reason: s.reason }))
  };
  m.step = 'result';
  _bsxRender();
}

function _bsxSkipListHtml(list) {
  return '<div class="bsx-scroll"><table class="bsx-table"><thead><tr><th class="w-no">줄 번호</th><th>이름</th><th>이유</th></tr></thead><tbody>' +
    list.map(s => '<tr><td class="c-center">' + brandEsc(String(s.rowNo || '') || '—') + (s.excelRow && !s.rowNo ? '<div class="bsx-sub">엑셀 ' + s.excelRow + '행</div>' : '') + '</td>' +
      '<td>' + (brandEsc(s.name) || '—') + '</td><td>' + brandEsc(BSX_SKIP_TEXT[s.reason] || '반영 안 됨') + '</td></tr>').join('') +
    '</tbody></table></div>';
}
function _bsxRender() {
  const m = _bsxModal;
  if (!m) return;
  const prevAct = document.activeElement && m.el.contains(document.activeElement) ? document.activeElement.dataset.bsxM : null;
  const btn = (act, label, cls, dis) => '<button type="button" class="brand-btn' + (cls ? ' ' + cls : '') + '" data-bsx-m="' + act + '"' + (dis ? ' disabled' : '') + '>' + label + '</button>';
  let body = '', actions = '';
  if (m.step === 'pick' || m.step === 'reading') {
    const reading = m.step === 'reading';
    body =
      '<div class="brand-modal-card bsx-guide"><ol class="bsx-steps">' +
        '<li>「엑셀 내려받기」로 받은 파일에서 「택배사」·「송장번호」(필요하면 「발송일」) 칸만 채웁니다.</li>' +
        '<li>목록에 없는 택배사는 「택배사」 칸에 「기타」, 옆 「택배사 이름(기타일 때)」 칸에 이름을 적습니다.</li>' +
        '<li>줄은 「줄 번호」로 맞춥니다. 정렬하거나 줄을 지워도 되지만, 맨 위 안내 줄과 「줄 번호」 칸은 그대로 두십시오.</li>' +
      '</ol></div>' +
      '<p class="bsx-limit">송장번호는 내려받은 파일의 글자 칸에 그대로 적어 주십시오(숫자 칸으로 바꾸면 앞자리 0 이 사라질 수 있습니다). .xlsx 만 · 5MB · 2,000줄까지. 파일은 이 화면에서만 읽고 서버에 올리지 않습니다 — 줄 번호·택배사·송장번호·발송일만 저장합니다.</p>' +
      (m.error ? '<p class="bsx-error" role="alert">' + brandEsc(m.error) + '</p>' : '') +
      (reading ? '<p class="bsx-busy" role="status" aria-live="polite">파일을 읽는 중…</p>' : '') +
      '<input type="file" id="bsxFile" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" hidden>';
    actions = btn('close', '취소', 'brand-btn-line', reading) + btn('pick', reading ? '읽는 중…' : '파일 고르기', '', reading);
  } else if (m.step === 'preview' || m.step === 'applying') {
    const p = m.plan;
    const n = p.add.length + p.change.length;
    const applying = m.step === 'applying';
    const items = p.add.map(it => Object.assign({ kind: 'add' }, it)).concat(p.change.map(it => Object.assign({ kind: 'change' }, it)))
      .sort((a, b) => a.rowNo - b.rowNo);
    body =
      '<div class="bsx-counts">' +
        '<div class="bsx-count"><span>새로 등록</span><b>' + p.add.length + '</b></div>' +
        '<div class="bsx-count' + (p.change.length ? ' is-change' : '') + '"><span>바뀜</span><b>' + p.change.length + '</b></div>' +
        '<div class="bsx-count"><span>그대로</span><b>' + p.same.length + '</b></div>' +
        '<div class="bsx-count' + (p.skip.length ? ' is-skip' : '') + '"><span>반영 안 됨</span><b>' + p.skip.length + '</b></div>' +
      '</div>' +
      (items.length ? '<h3 class="bsx-h">반영할 줄 ' + n + '</h3><div class="bsx-scroll"><table class="bsx-table"><thead><tr><th class="w-no">줄 번호</th><th>이름</th><th>택배사</th><th>송장번호</th></tr></thead><tbody>' +
        items.map(it => '<tr><td class="c-center">' + it.rowNo + '</td><td>' + brandEsc(it.name) + ' ' +
          (it.kind === 'change' ? '<span class="bs-badge is-pending">바뀜</span>' : '<span class="bs-badge is-new">새로 등록</span>') + '</td>' +
          '<td>' + brandEsc(it.carrierName) + '</td>' +
          '<td class="bs-track">' + (it.kind === 'change' && it.prev !== it.tracking ? '<s class="bsx-prev">' + brandEsc(it.prev) + '</s> → ' : '') + brandEsc(it.tracking) + '</td></tr>').join('') +
        '</tbody></table></div>' : '<p class="bsx-none">반영할 줄이 없습니다. 바뀐 송장이 없거나 모두 「반영 안 됨」입니다.</p>') +
      (p.skip.length ? '<h3 class="bsx-h">반영 안 됨 ' + p.skip.length + ' — 이 줄은 건너뜁니다</h3>' + _bsxSkipListHtml(p.skip) : '') +
      (applying ? '<p class="bsx-busy" role="status" aria-live="polite">반영하는 중…</p>' : '');
    actions = btn('pick', '다른 파일 고르기', 'brand-btn-line', applying) + btn('close', '취소', 'brand-btn-line', applying) +
      btn('apply', applying ? '반영하는 중…' : n + '줄 반영하기', '', applying || !n) +
      '<input type="file" id="bsxFile" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" hidden>';
  } else if (m.step === 'result') {
    const r = m.result;
    body = '<p class="bsx-result">' + r.saved + '줄을 반영했습니다. 아래 ' + r.skipped.length + '줄은 반영되지 않았습니다 — 화면에서 확인해 주십시오.</p>' +
      '<h3 class="bsx-h">반영되지 않은 줄 ' + r.skipped.length + '</h3>' + _bsxSkipListHtml(r.skipped);
    actions = btn('close', '닫기', '', false);
  }
  m.el.innerHTML = '<div class="brand-modal-box is-card bsx-modal">' +
    '<h2 id="bsxTitle">' + (m.step === 'result' ? '반영 결과' : m.step === 'pick' || m.step === 'reading' ? '엑셀로 송장 올리기' : '반영 전 확인') + '</h2>' +
    body + '<div class="brand-modal-actions is-right">' + actions + '</div></div>';
  // 초점 — 같은 단추가 있으면 그 자리, 없으면 주 단추(없으면 첫 단추)
  const keep = prevAct && m.el.querySelector('[data-bsx-m="' + prevAct + '"]:not([disabled])');
  const main = keep || m.el.querySelector('[data-bsx-m="apply"]:not([disabled]), [data-bsx-m="pick"]:not([disabled])') || m.el.querySelector('[data-bsx-m]:not([disabled])');
  if (main) main.focus();
  else { const box = m.el.querySelector('.bsx-modal'); if (box) { box.setAttribute('tabindex', '-1'); box.focus(); } }
}

// 패널 단추(위임)
document.addEventListener('click', (e) => {
  const el = e.target.closest('#brandPageHost [data-bsx-act]');
  if (!el || el.disabled) return;
  if (el.dataset.bsxAct === 'download') { brandShippingExcelDownload(); return; }
  if (el.dataset.bsxAct === 'upload') { _bsxOpen(); return; }
});
// 다른 화면으로 가거나(로그아웃 포함) 모바일 폭이 되면 열린 창을 닫는다 — 반영 중이면 그대로 두고 결과를 기다린다
function _bsxCloseOnLeave() {
  const m = _bsxModal;
  if (!m || m.step === 'applying') return;
  if (_bsCurrentId() === m.id && brandAuthed && !_bcMobileMq.matches) return;
  m.step = 'result';   // 읽는 중이어도 닫는다(_bsxRead 는 _bsxModal !== m 이면 결과를 버린다)
  _bsxClose();
}
window.addEventListener('hashchange', _bsxCloseOnLeave);
_bcMobileMq.addEventListener('change', _bsxCloseOnLeave);
// 브랜드를 바꾸면 열린 올리기 창을 닫는다(다른 브랜드 캠페인에 반영되지 않게 — 도는 중이면 결과만 버린다)
onBrandChanged(() => {
  if (_bcAutoSwitching || !_bsxModal) return;
  const m = _bsxModal;
  m.step = 'result';
  _bsxClose();
});
