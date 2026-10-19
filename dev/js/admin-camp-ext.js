// ════════════════════════════════════════════════════════════════════
// 캠페인 외부 결과 파일 — 진행현황 결과물 탭(작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 12」)
//   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ①(캠페인에 첨부) · ③(보이는 줄 — 제출한 줄만) · ④(낱말) · ⑦(모집 현황 외부 N명)
//   서버 546: attach_campaign_ext_source · detach_campaign_ext_source · get_campaign_ext_sources
//   · 파일 읽기는 리포트 붙이기와 같은 함수(REPORT_PARSERS.pointail — report-parsers.js)
//   · 외부 줄은 _reportExtToRow(r, src, {rules:'campaign', campaign}) + reportExtRowSubmitted 로만 만든다(report-rows.js 한 곳)
//   · 권한 menu.reports — 숨김이면 카드 없음 · 쓰기가 아니면 단추 없음(서버도 같은 판정)
//   · 🔴 캠페인에 붙인 파일은 리포트 공유 링크로 새지 않는다(545·410 은 report_id 로만 찾는다)
//   · ⚠️ 서버에 546 이 아직 없으면({missing:true}) 카드를 조용히 숨긴다 — 운영은 「사전」 단계에 546 과 함께
// ════════════════════════════════════════════════════════════════════

var _campExt = { campaignId: null, data: null };

function _campExtCanRead() { return !((typeof isHidden === 'function') && isHidden('menu.reports')); }
function _campExtCanWrite() { return (typeof canWrite === 'function') && canWrite('menu.reports'); }

// 진행현황을 열 때마다(loadCampApplicants) 부른다 — 기다리지 않는다
async function loadCampExtSources(campaignId) {
  const box = document.getElementById('campExtBox');
  const cnt = document.getElementById('campOpsExtCount');
  if (cnt) { cnt.style.display = 'none'; cnt.textContent = ''; }
  if (!box) return;
  _campExt = { campaignId: campaignId, data: null };
  box.dataset.ready = '';
  box.style.display = 'none';   // 앞 캠페인 카드가 응답 전까지 남지 않게
  if (!campaignId || !_campExtCanRead()) { box.innerHTML = ''; return; }
  const data = await fetchCampaignExtSources(campaignId);
  if (campaignId !== currentCampApplicantId) return;   // 그사이 다른 캠페인
  if (data && data.missing) { box.dataset.ready = ''; box.style.display = 'none'; box.innerHTML = ''; return; }
  _campExt.data = data;
  _renderCampExtBox();
  box.dataset.ready = '1';
  if (typeof applyCampDetailTabVisibility === 'function') applyCampDetailTabVisibility();
}

function _campExtCampaign() {
  const c = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns))
    ? allCampaigns.find(function (x) { return x.id === _campExt.campaignId; }) : null;
  return c || {};
}

// 모집 현황 아래 「외부 N명」 — 카드가 응답보다 늦게 그려져도 renderCampOpsSummary 가 다시 부른다
function campExtFillCount() {
  const cnt = document.getElementById('campOpsExtCount');
  if (!cnt) return;
  const d = _campExt.data;
  const n = (d && !d.missing && _campExt.campaignId === currentCampApplicantId && Array.isArray(d.ext_rows)) ? d.ext_rows.length : 0;
  if (n) { cnt.textContent = '외부 ' + n + '명'; cnt.style.display = ''; } else { cnt.textContent = ''; cnt.style.display = 'none'; }
}

function _renderCampExtBox() {
  const box = document.getElementById('campExtBox');
  if (!box) return;
  const data = _campExt.data;
  const canW = _campExtCanWrite();
  const head = '<div class="admin-card-header"><span class="admin-card-title">외부 결과 파일</span>'
    + '<span style="font-size:12px;color:var(--muted)">다른 서비스(포인테일)에서 모집한 분의 결과 — 브랜드 공개를 켜면 브랜드 페이지에 「외부 참가자」로 보입니다</span>'
    + (canW ? '<button type="button" class="btn btn-ghost btn-sm" style="margin-left:auto" onclick="openCampExtAttachModal()"><span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">upload_file</span> 파일 붙이기</button>' : '')
    + '</div>';
  if (!data) {
    box.innerHTML = head + '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">외부 결과 파일을 불러오지 못했습니다</div>';
    return;
  }
  const sources = Array.isArray(data.sources) ? data.sources : [];
  const rows = Array.isArray(data.ext_rows) ? data.ext_rows : [];
  campExtFillCount();
  if (!sources.length) {
    box.innerHTML = head + '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">붙인 외부 결과 파일이 없습니다</div>';
    return;
  }
  const srcById = {}; sources.forEach(function (s) { srcById[s.id] = s; });
  const camp = _campExtCampaign();
  const submitted = rows.filter(reportExtRowSubmitted);
  const std = submitted.map(function (r) {
    const row = _reportExtToRow(r, srcById[r.source_id], { rules: 'campaign', campaign: { campaign_no: camp.campaign_no || '', campaign_name: camp.title || '' } });
    row._member_no = r.member_no;
    return row;
  });
  const link = function (v) {
    const list = String(v || '').split(/\r?\n/).map(function (u) { return u.trim(); }).filter(Boolean);
    if (!list.length) return '<span style="color:var(--muted)">-</span>';
    return list.map(function (u, i) {
      return reportIsLinkable(u) ? '<a href="' + esc(u) + '" target="_blank" rel="noopener">' + (list.length > 1 ? '열기 ' + (i + 1) : '열기') + ' ↗</a>' : esc(u);
    }).join(' · ');
  };
  const d = function (v) { return v ? esc(formatDate(v)) : '<span style="color:var(--muted)">-</span>'; };
  const statusCell = function (s) {
    const color = s === '인증성공' ? 'var(--green)' : (s === '인증샷 제출중' ? '#d97706' : 'var(--muted)');
    return '<span style="font-weight:600;color:' + color + '">' + esc(s || '-') + '</span>';
  };
  box.innerHTML = head
    + '<div style="padding:12px 16px;display:flex;flex-direction:column;gap:6px">'
    + sources.map(function (s) {
        return '<div style="display:flex;align-items:center;gap:10px;font-size:12.5px;border:1px solid var(--line);border-radius:8px;padding:8px 12px">'
          + '<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">description</span>'
          + '<div style="flex:1;min-width:0"><strong>' + esc(s.ext_campaign_no) + ' ' + esc(s.ext_campaign_name) + '</strong>'
            + ' <span style="color:var(--muted)">· ' + (Number(s.row_count) || 0) + '명</span>'
            + '<div style="font-size:11px;color:var(--muted)">' + esc(s.file_name || '') + ' · ' + esc(formatDateTime(s.attached_at)) + (s.attached_by_name ? ' · ' + esc(s.attached_by_name) : '') + '</div></div>'
          + (canW ? '<button type="button" class="btn btn-ghost btn-xs" onclick="openCampExtAttachModal(\'' + esc(s.id) + '\')">업데이트</button>'
                  + '<button type="button" class="btn btn-ghost btn-xs" style="color:var(--red)" onclick="detachCampExtSource(\'' + esc(s.id) + '\')">떼기</button>' : '')
          + '</div>';
      }).join('')
    + '</div>'
    + '<div style="padding:0 16px 6px;font-size:12px;color:var(--muted)">제출한 외부 줄 ' + std.length + '명'
      + (rows.length > std.length ? ' (증빙이 없는 ' + (rows.length - std.length) + '명은 브랜드에게도 보이지 않습니다)' : '') + '</div>'
    + (std.length ? '<div class="admin-table-wrap" style="max-height:360px"><table class="data-table"><thead><tr>'
        + '<th>구분</th><th>상태</th><th>주문 번호</th><th style="text-align:right">구매금액</th><th>영수증</th><th>영수증 날짜</th><th>큐텐 결과물</th><th>큐텐 날짜</th><th>엣코스메 결과물</th><th>엣코스메 날짜</th>'
        + '</tr></thead><tbody>'
        + std.map(function (r) {
            return '<tr><td style="white-space:nowrap">외부 · ' + esc(r._member_no || '') + '</td>'
              + '<td>' + statusCell(r.status) + '</td>'
              + '<td>' + esc(r.order_no || '-') + '</td>'
              + '<td style="text-align:right">' + (r.amount === '' || r.amount === null || r.amount === undefined ? '-' : '¥' + Number(r.amount).toLocaleString('ja-JP')) + '</td>'
              + '<td>' + link(r.receipt_url) + '</td><td>' + d(r.receipt_uploaded_at) + '</td>'
              + '<td>' + link(r.ch_qoo10_url) + '</td><td>' + d(r.ch_qoo10_at) + '</td>'
              + '<td>' + link(r.ch_cosme_url) + '</td><td>' + d(r.ch_cosme_at) + '</td></tr>';
          }).join('')
        + '</tbody></table></div>' : '');
}

// ── 붙이기·업데이트 창 — 리포트 붙이기와 같은 파일 읽기 ──
var _campExtForm = null;   // {sourceId, extNo, extName, fileName, parsed, busy, error}
function closeCampExtAttachModal() { const m = document.getElementById('campExtAttachModal'); if (m) m.remove(); _campExtForm = null; }
function openCampExtAttachModal(sourceId) {
  if (!_campExtCanWrite() || !_campExt.campaignId) return;
  closeCampExtAttachModal();
  const src = sourceId && _campExt.data ? (_campExt.data.sources || []).find(function (s) { return s.id === sourceId; }) : null;
  _campExtForm = { sourceId: src ? src.id : null, extNo: src ? src.ext_campaign_no : '', extName: src ? src.ext_campaign_name : '', fileName: '', parsed: null, busy: false, error: '' };
  const wrap = document.createElement('div');
  wrap.id = 'campExtAttachModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:560px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><div class="modal-title">${src ? '외부 결과 파일 업데이트' : '외부 결과 파일 붙이기'}</div>
        <button class="modal-close" onclick="closeCampExtAttachModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" id="campExtAttachBody" style="overflow-y:auto"></div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="closeCampExtAttachModal()">취소</button>
        <button class="btn btn-primary" id="btnCampExtSubmit" onclick="submitCampExtAttach()" disabled>${src ? '업데이트' : '붙이기'}</button>
      </div>
    </div>`;
  (document.getElementById('page-admin') || document.body).appendChild(wrap);
  _renderCampExtForm();
}
function _renderCampExtForm() {
  const f = _campExtForm; const body = document.getElementById('campExtAttachBody');
  if (!f || !body) return;
  // 처음 한 번만 칸을 그린다 — 다시 그리면 파일 칸이 「선택된 파일 없음」으로 돌아가고 입력 초점도 끊긴다
  if (!document.getElementById('campExtFileStatus')) {
    const locked = !!f.sourceId;
    body.innerHTML = `
      <div class="form-group"><label class="form-label">서비스</label><div style="font-size:13px">포인테일</div></div>
      <div style="display:grid;grid-template-columns:1fr 2fr;gap:10px">
        <div class="form-group"><label class="form-label">외부 캠페인 번호</label>
          <input type="text" class="form-input" id="campExtNo" value="${esc(f.extNo)}" ${locked ? 'readonly' : ''} oninput="_campExtSet('extNo', this.value)" placeholder="102905"></div>
        <div class="form-group"><label class="form-label">외부 캠페인 이름</label>
          <input type="text" class="form-input" id="campExtName" value="${esc(f.extName)}" oninput="_campExtSet('extName', this.value)" placeholder="포인테일 캠페인 이름"></div>
      </div>
      <div class="form-group"><label class="form-label">결과 파일 (.xlsx)</label>
        <input type="file" accept=".xlsx" onchange="_campExtFile(this)">
        <div id="campExtFileStatus"></div>
      </div>
      <p style="font-size:11px;color:var(--muted);margin:6px 0 0;line-height:1.7">${locked ? '<strong>업데이트하면 이 파일의 이전 참가자 줄이 전부 새 파일로 바뀝니다.</strong><br>' : ''}파일은 이 브라우저에서 읽어 <strong>참가자 줄만</strong> 저장합니다. 원본 파일은 저장하지 않습니다. 같은 외부 번호로 다시 붙이면 그 파일이 갱신됩니다.</p>`;
  }
  const st = document.getElementById('campExtFileStatus');
  if (st) st.innerHTML = f.busy ? '<div style="font-size:12px;color:var(--muted);margin-top:6px">읽는 중…</div>'
    : f.error ? '<div style="font-size:12px;color:var(--red);margin-top:6px">' + esc(f.error) + '</div>'
    : f.parsed ? '<div style="font-size:12px;color:var(--green);margin-top:6px">' + esc(f.fileName) + ' — 참가자 ' + f.parsed.rows.length + '명을 읽었습니다</div>' : '';
  const no = document.getElementById('campExtNo');
  if (no && !no.value && f.extNo) no.value = f.extNo;   // 파일 이름에서 번호를 채운 경우
  _campExtSyncSubmit();
}
function _campExtSet(key, val) { if (_campExtForm) { _campExtForm[key] = val; _campExtSyncSubmit(); } }
function _campExtSyncSubmit() {
  const f = _campExtForm; const btn = document.getElementById('btnCampExtSubmit');
  if (btn) btn.disabled = !(f && f.parsed && String(f.extNo || '').trim() && String(f.extName || '').trim() && !f.busy);
}
async function _campExtFile(input) {
  const f = _campExtForm; const file = input && input.files && input.files[0];
  if (!f || !file) return;
  f.fileName = file.name; f.busy = true; f.error = ''; f.parsed = null;
  _renderCampExtForm();
  try {
    const res = await REPORT_PARSERS.pointail(await file.arrayBuffer());
    if (!res.ok) f.error = res.reason || '읽지 못했습니다';
    else {
      f.parsed = res;
      if (!String(f.extNo || '').trim()) { const m = file.name.match(/_(\d{4,})/); if (m) f.extNo = m[1]; }
    }
  } catch (e) { f.error = '읽는 중 오류 — ' + ((e && e.message) || e); }
  f.busy = false;
  _renderCampExtForm();
}
async function submitCampExtAttach() {
  const f = _campExtForm;
  if (!f || !f.parsed) return;
  const extNo = String(f.extNo).trim(), extName = String(f.extName).trim();
  const dup = !f.sourceId && _campExt.data && (_campExt.data.sources || []).some(function (s) { return s.ext_campaign_no === extNo; });
  if (f.sourceId || dup) {
    if (!window.confirm('「' + extNo + '」 파일을 새 파일로 업데이트합니다.\n이전 참가자 줄은 전부 바뀝니다(브랜드 공개 중이면 브랜드 페이지에도 바로 반영됩니다). 계속할까요?')) return;
  }
  const btn = document.getElementById('btnCampExtSubmit'); if (btn) { btn.disabled = true; btn.textContent = '저장 중…'; }
  try {
    await attachCampaignExtSource(_campExt.campaignId, extNo, extName, f.fileName, f.parsed.rows);
    closeCampExtAttachModal();
    toast((f.sourceId || dup) ? '업데이트했습니다' : '붙였습니다');
    await refreshPane('camp-applicants');
  } catch (e) {
    toast('저장하지 못했습니다 — ' + ((e && e.message) || e), 'error');
    if (btn) { btn.disabled = false; btn.textContent = f.sourceId ? '업데이트' : '붙이기'; }
  }
}
async function detachCampExtSource(sourceId) {
  const s = _campExt.data && (_campExt.data.sources || []).find(function (x) { return x.id === sourceId; });
  const label = s ? (s.ext_campaign_no + ' ' + s.ext_campaign_name) : '이 파일';
  if (!window.confirm('「' + label + '」 파일을 뗍니다.\n그 참가자 줄이 진행현황·브랜드 페이지에서 사라집니다(되돌리려면 파일을 다시 붙입니다). 계속할까요?')) return;
  try { await detachCampaignExtSource(sourceId); toast('뗐습니다'); await refreshPane('camp-applicants'); }
  catch (e) { toast('떼지 못했습니다 — ' + ((e && e.message) || e), 'error'); }
}

// ── 결과물 엑셀에 「외부 참가자」 시트를 더한다 — 실패·첨부 없음이면 아무것도 안 한다 ──
async function excelAppendCampaignExtSheet(wb, camp) {
  if (!wb || !camp || !camp.id || !_campExtCanRead()) return;
  const data = await fetchCampaignExtSources(camp.id);
  if (!data || data.missing || !Array.isArray(data.sources) || !data.sources.length) return;
  const srcById = {}; data.sources.forEach(function (s) { srcById[s.id] = s; });
  const rows = (data.ext_rows || []).filter(reportExtRowSubmitted);
  if (!rows.length) return;
  const ws = wb.addWorksheet('외부 참가자');
  ws.columns = [
    { header: '구분', key: 'src', width: 12 }, { header: '회원번호', key: 'member_no', width: 14 }, { header: '외부 캠페인', key: 'ext', width: 28 },
    { header: '상태', key: 'status', width: 14 }, { header: '주문 번호', key: 'order_no', width: 18 }, { header: '구매금액', key: 'amount', width: 12 },
    { header: '영수증', key: 'receipt_url', width: 40 }, { header: '영수증 날짜', key: 'receipt_at', width: 14 },
    { header: '큐텐 결과물', key: 'qoo10', width: 40 }, { header: '큐텐 날짜', key: 'qoo10_at', width: 14 },
    { header: '엣코스메 결과물', key: 'cosme', width: 40 }, { header: '엣코스메 날짜', key: 'cosme_at', width: 14 },
  ];
  ws.getRow(1).font = { bold: true };
  rows.forEach(function (r) {
    const src = srcById[r.source_id] || {};
    const s = _reportExtToRow(r, src, { rules: 'campaign', campaign: { campaign_no: camp.campaign_no || '', campaign_name: camp.title || '' } });
    ws.addRow({
      src: s.src, member_no: r.member_no || '', ext: (src.ext_campaign_no || '') + ' ' + (src.ext_campaign_name || ''),
      status: s.status || '', order_no: s.order_no || '',
      amount: (s.amount === '' || s.amount === null || s.amount === undefined) ? '' : Number(s.amount),
      receipt_url: s.receipt_url || '', receipt_at: s.receipt_uploaded_at ? formatDate(s.receipt_uploaded_at) : '',
      qoo10: s.ch_qoo10_url || '', qoo10_at: s.ch_qoo10_at ? formatDate(s.ch_qoo10_at) : '',
      cosme: s.ch_cosme_url || '', cosme_at: s.ch_cosme_at ? formatDate(s.ch_cosme_at) : '',
    });
  });
}
