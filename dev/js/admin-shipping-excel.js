// ════════════════════════════════════════════════════════════════════
// 시딩형 「배송 리스트」 탭 — 송장 양식 내려받기 · 엑셀로 송장 올리기(관리자)
//   피그마 Admin 1차 a05-09a(전달 뒤) — 「엑셀로 송장 올리기」는 브랜드 bw05-03(→ 03a → 결과)과 같은 단계
//   결정(2026-10-23 기획 kemo-7d 경유 사용자 결정): 내려받기는 우편번호·주소·전화를 뺀 「송장 양식」만(D10 의 이유 유지) ·
//     빈 송장은 반영 안 함(D1 — 지우기는 줄 모달 「송장 지우기」) · 전달 뒤에만 · 종료 캠페인도 관리자는 허용 ·
//     「바뀜」 줄에 지금 값을 누가·언제 넣었는지 표시(오래된 파일이 브랜드가 방금 고친 송장을 덮는 것을 반영 전에 보게)
//   파일 읽기·분류는 공용 shipping-excel-core.js(브랜드와 한 벌) · 저장은 557 admin_save_shipping_rows(줄 열쇠 = 응모 번호 + 버전)
//   🔴 올린 파일은 브라우저 안에서만 읽는다 — 서버로 보내는 것은 응모 번호·택배사·송장·발송일뿐. 파일·칸 값을 콘솔·오류 기록에 싣지 않는다
//   🔴 버전은 파일이 아니라 올리는 순간 새로 받은 admin_get_campaign_shipping 에서(화면 보관 _shipCtx 를 쓰지 않는다)
//   🔴 송장 양식 내려받기는 관리자 엑셀 관문 _excelInternalGate 를 지난다(이름이 들어 있다 — 개발서버 기록 + 「사내용」 첫 줄)
//   단추는 admin-shipping.js renderCampShipping 이 shipXlAdminButtonsHtml(d) 로 그린다
// ════════════════════════════════════════════════════════════════════

var _shipXlModal = null;     // { campId, campaignNo, step:'pick'|'reading'|'preview'|'applying'|'result', plan, result, error }
var _shipXlDlBusy = false;

const SHIP_XL_READ_MSG = {
  not_xlsx: '.xlsx 파일만 올릴 수 있습니다. CSV 는 받지 않습니다.',
  too_big: '파일이 5MB 를 넘습니다. 송장 양식에서 송장 칸만 채워 올려 주세요.',
  too_many: '줄이 2,000줄을 넘습니다. 내려받은 송장 양식을 그대로 써 주세요.',
  read_fail: '파일을 읽지 못했습니다. 「송장 양식 내려받기」로 받은 .xlsx 파일인지 확인해 주세요.',
  no_head: '「줄 번호」·「택배사」·「송장번호」 머리글을 찾지 못했습니다. 「송장 양식 내려받기」로 받은 파일을 써 주세요.',
  no_notice: '맨 위 안내 줄(캠페인 번호)이 없습니다. 내려받은 양식의 안내 줄을 지우지 말고 써 주세요.',
  other_campaign: '다른 캠페인의 파일입니다. 이 캠페인에서 내려받은 양식을 올려 주세요.'
};
// 반영 안 됨 이유 — 미리 보기(공용 분류) · 결과(서버 skipped.reason) 공용
const SHIP_XL_SKIP_TEXT = {
  cancelled: '선정 취소된 분',
  blank: '송장 빈칸 — 지우려면 줄의 「수정」 → 「송장 지우기」',
  no_tracking: '송장번호 없음',
  no_row: '없는 줄',
  carrier: '택배사 이름 확인(목록 이름 또는 「기타」 + 이름)',
  format_tracking: '형식 오류 — 송장번호는 영문·숫자·하이픈·띄어쓰기 4~40자',
  format_date: '형식 오류 — 발송일(예: 2026-10-20)',
  format_row: '형식 오류 — 줄 번호',
  duplicate: '같은 줄 번호가 두 번',
  // 서버 skipped.reason(557)
  not_found: '없는 줄',
  version_conflict: '그사이 다른 곳에서 먼저 바뀜 — 목록을 확인한 뒤 다시 올려 주세요',
  invalid_tracking: '형식 오류 — 송장번호',
  carrier_required: '택배사 이름 확인',
  invalid_carrier: '택배사 이름 확인(목록에서 꺼진 택배사이거나 「기타」 이름이 50자 초과)',
  invalid_shipped_on: '형식 오류 — 발송일(오늘부터 30일 뒤까지)'
};

function _shipXlName(r) { return r.withdrawn ? '탈퇴한 회원' : (r.name || ''); }   // D25
function _shipXlYmd(dt) { return dt.getFullYear() + String(dt.getMonth() + 1).padStart(2, '0') + String(dt.getDate()).padStart(2, '0'); }

// ── 탭 머리 단추 — 전달 뒤 · 쓰기 권한 · 삭제 아님(줄 「수정」 단추와 같은 재료). 종료 캠페인도 그린다
function shipXlAdminButtonsHtml(d) {
  if (!d || d.success === false || !d.delivered_at || !d.can_write || d.deleted) return '';
  if (!Array.isArray(d.rows) || !d.rows.length) return '';
  return '<button type="button" class="btn btn-ghost btn-sm" style="flex-shrink:0"' + (_shipXlDlBusy ? ' disabled' : '') + ' onclick="downloadShipXlTemplate()" title="줄 번호·이름·택배사·송장번호·발송일만 든 양식(주소·전화번호 없음)">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">download</span> ' + (_shipXlDlBusy ? '양식 만드는 중…' : '송장 양식 내려받기') + '</button>'
    + '<button type="button" class="btn btn-ghost btn-sm" style="flex-shrink:0" onclick="openShipXlUpload()">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">upload_file</span> 엑셀로 송장 올리기</button>';
}

// ── 송장 양식 내려받기 — 누를 때 새로 받는다. 우편번호·주소·전화번호 열은 넣지 않는다
async function downloadShipXlTemplate() {
  const campId = _shipCtx && _shipCtx.campaignId;
  if (!campId || _shipXlDlBusy) return;
  _shipXlDlBusy = true;
  renderCampShipping();
  try {
    const [, d] = await Promise.all([loadExcelJS(), fetchCampaignShipping(campId)]);
    if (!d || d.success === false || !d.campaign_no) throw new Error('shipping');
    if (!d.delivered_at) { toast('전달한 뒤에만 송장 양식을 내려받을 수 있습니다.', 'error'); return; }
    const heads = SHIPXL_HEADS.filter(h => !h.pii);
    const rows = Array.isArray(d.rows) ? d.rows.filter(r => r.row_no != null) : [];
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('송장 양식');
    ws.getCell('A1').value = shipXlNoticeText(d.campaign_no, true);
    ws.getCell('A1').font = { color: { argb: 'FF71717A' } };
    ws.addRow(heads.map(h => h.label)).font = { bold: true };   // 2행(관문이 「사내용」 줄을 끼우면 3행)
    rows.forEach(r => {
      const car = shipXlCarrierCells(r);
      const vals = {
        row_no: r.row_no, name: _shipXlName(r), kana: r.withdrawn ? '' : (r.name_kana || ''),
        status: shipXlStatusText(r), carrier: car[0], other: car[1],
        tracking: r.tracking_no || '', shipped_on: r.shipped_on ? String(r.shipped_on).slice(0, 10) : ''
      };
      ws.addRow(heads.map(h => vals[h.key]));
    });
    // 송장·발송일은 글자 칸 — 엑셀이 앞 0 을 지우거나 긴 숫자를 지수로 바꾸지 않게
    heads.forEach((h, i) => {
      const col = ws.getColumn(i + 1);
      col.width = h.w;
      if (h.text) col.numFmt = '@';
    });
    if (!(await _excelInternalGate(wb, '엑셀 · 배송 송장 양식', rows.length, { campaign_no: d.campaign_no }))) return;
    const buf = await wb.xlsx.writeBuffer();
    const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const camp = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns.find(c => c.id === campId) : null;
    const p = String((camp && (camp.product_ko || camp.product)) || d.campaign_no).replace(/[\\/:*?"<>|]/g, '').trim().slice(0, 40) || d.campaign_no;
    const a = document.createElement('a');
    a.href = url;
    a.download = '송장양식_' + p + '_' + _shipXlYmd(new Date()) + '.xlsx';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (e) {
    toast('송장 양식을 만들지 못했습니다. 잠시 뒤 다시 시도해 주세요.', 'error');
  } finally {
    _shipXlDlBusy = false;
    if (_shipCtx && _shipCtx.campaignId === campId) renderCampShipping();
  }
}

// ── 올리기 모달(고르기 → 읽는 중 → 반영 전 확인 → 반영 중 → 결과)
function openShipXlUpload() {
  const d = _shipCtx && _shipCtx.data;
  if (!d || !d.delivered_at || !d.can_write || d.deleted || _shipXlModal) return;
  _shipXlModal = { campId: _shipCtx.campaignId, campaignNo: d.campaign_no, step: 'pick', plan: null, result: null, error: '' };
  _shipEnsureModal('shipXlModal', '엑셀로 송장 올리기', 720);
  _shipXlRender();
  openModal('shipXlModal');
}

function closeShipXlUpload() {
  const m = _shipXlModal;
  if (m && (m.step === 'reading' || m.step === 'applying')) return;   // 도는 중에는 닫지 않는다
  _shipXlModal = null;
  if (document.getElementById('shipXlModal')) closeModal('shipXlModal');
}
// ESC — 공용 처리기(ui.js)는 그냥 closeModal 로 닫는다. 도는 중이면 그보다 먼저(붙잡는 단계) 막고, 아니면 상태도 함께 비운다
document.addEventListener('keydown', function (e) {
  if (e.key !== 'Escape' || !_shipXlModal) return;
  const el = document.getElementById('shipXlModal');
  if (!el || !el.classList.contains('open')) return;
  e.stopImmediatePropagation();
  closeShipXlUpload();
}, true);

function _shipXlPickFile() {
  const inp = document.getElementById('shipXlFile');
  if (inp) { inp.value = ''; inp.click(); }
}
function _shipXlOnFile(inp) {
  const f = inp && inp.files && inp.files[0];
  if (!f) return;
  inp.value = '';   // 같은 파일을 다시 골라도 change 가 오게
  _shipXlRead(f);
}

async function _shipXlRead(file) {
  const m = _shipXlModal;
  if (!m || m.step === 'reading' || m.step === 'applying') return;
  m.step = 'reading'; m.error = ''; m.plan = null;
  _shipXlRender();
  let err = '';
  try {
    // 줄마다 버전은 지금 새로 받은 리스트에서 — 파일 읽기와 함께
    const d = await fetchCampaignShipping(m.campId);
    if (!d || d.success === false || !d.campaign_no) err = '배송 리스트를 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.';
    else if (d.deleted) err = '삭제된(보관 중인) 캠페인입니다. 송장을 넣을 수 없습니다.';
    else if (!d.can_write) err = '송장을 넣을 권한이 없습니다.';
    else {
      const parsed = await shipXlReadFile(file, d.campaign_no, loadExcelJS);
      if (parsed.error) err = SHIP_XL_READ_MSG[parsed.error] || SHIP_XL_READ_MSG.read_fail;
      else m.plan = shipXlPlan(parsed.rows, d, { trackingRe: SHIP_TRACKING_RE, nameOf: _shipXlName });
    }
  } catch (e) { err = SHIP_XL_READ_MSG.read_fail; }
  if (_shipXlModal !== m) return;
  m.step = err ? 'pick' : 'preview';
  m.error = err;
  _shipXlRender();
}

async function _shipXlApply() {
  const m = _shipXlModal;
  if (!m || m.step !== 'preview' || !m.plan) return;
  // 모달을 연 뒤 다른 캠페인으로 옮겼으면 반영하지 않는다
  if (currentCampApplicantId !== m.campId) { m.step = 'result'; closeShipXlUpload(); toast('다른 캠페인으로 옮겨 반영하지 않았습니다.', 'error'); return; }
  const items = m.plan.add.concat(m.plan.change);
  if (!items.length) return;
  m.step = 'applying';
  _shipXlRender();
  let res = null, failMsg = '';
  try {
    res = await saveShippingRows(m.campId, items.map(it => Object.assign({
      application_id: it.cur.application_id,
      expected_version: it.cur.version == null ? null : it.cur.version
    }, it.save)));
  } catch (e) {
    res = null;
    failMsg = (e && e.code === '42501') ? friendlyError(e.message) : '';
  }
  if (_shipXlModal !== m) return;
  if (!res) { m.step = 'preview'; _shipXlRender(); toast(failMsg || '반영하지 못했습니다. 잠시 뒤 다시 시도해 주세요.', 'error'); return; }
  if (res.ok === false) {
    m.step = 'result'; closeShipXlUpload();
    toast(res.reason === 'not_gifting' ? '시딩형 캠페인이 아닙니다.' : '캠페인을 찾지 못했습니다.', 'error');
    await refreshPane('camp-applicants');
    return;
  }
  const saved = Array.isArray(res.saved) ? res.saved : [];
  const skipped = Array.isArray(res.skipped) ? res.skipped : [];
  await refreshPane('camp-applicants');
  if (_shipXlModal !== m) return;
  if (!skipped.length) {
    m.step = 'result'; closeShipXlUpload();
    toast(saved.length + '줄을 반영했습니다.');
    return;
  }
  // 반영되지 않은 줄 — 서버는 응모 번호로 돌려준다 → 보낸 줄에서 줄 번호·이름을 다시 찾는다
  const byApp = new Map(items.map(it => [String(it.cur.application_id), it]));
  m.result = {
    saved: saved.length,
    skipped: skipped.map(s => {
      const it = byApp.get(String(s.application_id));
      return { rowNo: it ? it.rowNo : '', name: it ? it.name : '', reason: s.reason };
    })
  };
  m.step = 'result';
  _shipXlRender();
}

// 「바뀜」 줄 — 지금 값을 누가·언제 넣었는지(결정 Q6)
function _shipXlCurBy(cur) {
  if (!cur || !cur.updated_by_kind) return '';
  const who = (cur.updated_by_kind === 'brand' ? '브랜드' : '운영팀') + (cur.updated_by_name ? ' ' + cur.updated_by_name : '');
  return who + (cur.updated_at ? ' · ' + formatDateTime(cur.updated_at) : '');
}

function _shipXlSkipTable(list) {
  return '<div class="admin-table-wrap" style="max-height:220px;overflow:auto"><table class="data-table"><thead><tr><th style="width:70px">줄 번호</th><th>이름</th><th>이유</th></tr></thead><tbody>'
    + list.map(s => '<tr><td>' + (esc(String(s.rowNo || '')) || '—') + (s.excelRow && !s.rowNo ? '<div style="font-size:10px;color:var(--muted)">엑셀 ' + s.excelRow + '행</div>' : '') + '</td>'
      + '<td>' + (esc(s.name) || '—') + '</td><td>' + esc(SHIP_XL_SKIP_TEXT[s.reason] || '반영 안 됨') + '</td></tr>').join('')
    + '</tbody></table></div>';
}

function _shipXlCountBox(label, n, tone) {
  const color = tone === 'warn' ? '#C2410C' : tone === 'alert' ? '#B91C1C' : 'var(--ink)';
  const bg = tone === 'warn' ? '#FFF7ED' : tone === 'alert' ? '#FEF2F2' : 'var(--surface-container-low, #F7F7F8)';
  return '<div style="flex:1;padding:10px 12px;border-radius:10px;background:' + bg + '"><div style="font-size:11px;color:var(--muted)">' + label + '</div>'
    + '<div style="font-size:18px;font-weight:700;color:' + color + '">' + n + '</div></div>';
}

function _shipXlRender() {
  const m = _shipXlModal;
  const el = document.getElementById('shipXlModal');
  if (!m || !el) return;
  const body = el.querySelector('.ship-modal-body');
  const foot = el.querySelector('.ship-modal-foot');
  const title = el.querySelector('.ship-modal-title');
  const closeX = el.querySelector('.modal-close-btn');
  const busy = m.step === 'reading' || m.step === 'applying';
  if (closeX) { closeX.setAttribute('onclick', 'closeShipXlUpload()'); closeX.disabled = busy; }
  const fileInput = '<input type="file" id="shipXlFile" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" hidden onchange="_shipXlOnFile(this)">';
  const btn = (onclick, label, primary, dis) => '<button type="button" class="btn ' + (primary ? 'btn-primary' : 'btn-ghost') + '"' + (dis ? ' disabled' : '') + ' onclick="' + onclick + '">' + label + '</button>';
  if (m.step === 'pick' || m.step === 'reading') {
    title.textContent = '엑셀로 송장 올리기';
    const reading = m.step === 'reading';
    body.innerHTML =
      '<ol style="margin:0 0 12px;padding:12px 14px 12px 32px;border-radius:10px;background:var(--surface-container-low, #F7F7F8);font-size:13px;line-height:1.8;color:var(--ink)">'
      + '<li>「송장 양식 내려받기」로 받은 파일에서 「택배사」·「송장번호」(필요하면 「발송일」) 칸만 채웁니다. 브랜드가 브랜드 페이지에서 내려받은 배송 리스트 엑셀도 올릴 수 있습니다.</li>'
      + '<li>목록에 없는 택배사는 「택배사」 칸에 「기타」, 옆 「택배사 이름(기타일 때)」 칸에 이름을 적습니다.</li>'
      + '<li>줄은 「줄 번호」로 맞춥니다. 정렬하거나 줄을 지워도 되지만, 맨 위 안내 줄과 「줄 번호」 칸은 그대로 두세요.</li>'
      + '</ol>'
      + '<div style="font-size:12px;color:var(--muted);line-height:1.7">송장 칸이 빈 줄은 반영하지 않습니다(송장을 지우려면 줄의 「수정」 → 「송장 지우기」). .xlsx 만 · 5MB · 2,000줄까지. 파일은 이 화면에서만 읽고 서버에 올리지 않습니다 — 택배사·송장번호·발송일만 저장합니다.</div>'
      + (m.error ? '<div role="alert" style="margin-top:12px;padding:10px 12px;border-radius:10px;background:#FEF2F2;color:#B91C1C;font-size:12px">' + esc(m.error) + '</div>' : '')
      + (reading ? '<div role="status" aria-live="polite" style="margin-top:12px;font-size:12px;color:var(--muted)"><span class="spinner"></span> 파일을 읽는 중…</div>' : '')
      + fileInput;
    foot.innerHTML = btn('closeShipXlUpload()', '취소', false, reading) + btn('_shipXlPickFile()', reading ? '읽는 중…' : '파일 고르기', true, reading);
    return;
  }
  if (m.step === 'preview' || m.step === 'applying') {
    title.textContent = '반영 전 확인';
    const p = m.plan;
    const n = p.add.length + p.change.length;
    const applying = m.step === 'applying';
    const items = p.add.map(it => Object.assign({ kind: 'add' }, it)).concat(p.change.map(it => Object.assign({ kind: 'change' }, it)))
      .sort((a, b) => a.rowNo - b.rowNo);
    const badge = (kind) => kind === 'change'
      ? '<span style="font-size:10px;font-weight:700;padding:1px 6px;border-radius:999px;white-space:nowrap;background:#FFF7ED;color:#C2410C">바뀜</span>'
      : '<span style="font-size:10px;font-weight:700;padding:1px 6px;border-radius:999px;white-space:nowrap;background:#EEF2FF;color:#4338CA">새로 등록</span>';
    body.innerHTML =
      '<div style="display:flex;gap:8px;margin-bottom:14px">'
      + _shipXlCountBox('새로 등록', p.add.length) + _shipXlCountBox('바뀜', p.change.length, p.change.length ? 'warn' : '')
      + _shipXlCountBox('그대로', p.same.length) + _shipXlCountBox('반영 안 됨', p.skip.length, p.skip.length ? 'alert' : '')
      + '</div>'
      + (p.change.length ? '<div style="margin-bottom:10px;font-size:12px;color:#C2410C">「바뀜」 줄은 지금 저장된 송장을 덮어씁니다. 「지금 값」에서 누가 언제 넣었는지 확인한 뒤 반영해 주세요.</div>' : '')
      + (items.length
        ? '<div style="font-size:13px;font-weight:700;margin-bottom:6px">반영할 줄 ' + n + '</div>'
          + '<div class="admin-table-wrap" style="max-height:280px;overflow:auto"><table class="data-table"><thead><tr><th style="width:70px">줄 번호</th><th>이름</th><th>택배사</th><th>송장번호</th><th>지금 값</th></tr></thead><tbody>'
          + items.map(it => '<tr><td>' + it.rowNo + '</td><td>' + esc(it.name) + ' ' + badge(it.kind) + '</td>'
              + '<td>' + esc(it.carrierName) + '</td>'
              + '<td style="font-family:monospace">' + (it.kind === 'change' && it.prev !== it.tracking ? '<s style="color:var(--muted)">' + esc(it.prev) + '</s> → ' : '') + esc(it.tracking) + '</td>'
              + '<td style="font-size:11px;color:var(--muted)">' + (it.kind === 'change' ? (esc(_shipXlCurBy(it.cur)) || '—') : '—') + '</td></tr>').join('')
          + '</tbody></table></div>'
        : '<div style="padding:16px;text-align:center;font-size:13px;color:var(--muted)">반영할 줄이 없습니다. 바뀐 송장이 없거나 모두 「반영 안 됨」입니다.</div>')
      + (p.skip.length ? '<div style="font-size:13px;font-weight:700;margin:14px 0 6px">반영 안 됨 ' + p.skip.length + ' — 이 줄은 건너뜁니다</div>' + _shipXlSkipTable(p.skip) : '')
      + (applying ? '<div role="status" aria-live="polite" style="margin-top:12px;font-size:12px;color:var(--muted)"><span class="spinner"></span> 반영하는 중…</div>' : '')
      + fileInput;
    foot.innerHTML = btn('_shipXlPickFile()', '다른 파일 고르기', false, applying) + btn('closeShipXlUpload()', '취소', false, applying)
      + btn('_shipXlApply()', applying ? '반영하는 중…' : n + '줄 반영하기', true, applying || !n);
    return;
  }
  if (m.step === 'result') {
    title.textContent = '반영 결과';
    const r = m.result;
    body.innerHTML = '<div style="font-size:13px;margin-bottom:12px">' + r.saved + '줄을 반영했습니다. 아래 ' + r.skipped.length + '줄은 반영되지 않았습니다 — 표에서 확인해 주세요.</div>'
      + '<div style="font-size:13px;font-weight:700;margin-bottom:6px">반영되지 않은 줄 ' + r.skipped.length + '</div>' + _shipXlSkipTable(r.skipped);
    foot.innerHTML = btn('closeShipXlUpload()', '닫기', true, false);
  }
}
