// ════════════════════════════════════════════════════════════════════
// 캠페인 외부 결과 파일 — 진행현황 결과물 탭(작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 12」)
//   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ①(캠페인에 첨부) · ③(보이는 줄 — 제출한 줄만) · ④(낱말) · ⑦(모집 현황 외부 N명)
//   디자인 피그마 a05-06(카드) · a05-06a(붙이기) · a05-06b(업데이트 확인) · a05-06c(삭제 확인)
//   서버 546: attach_campaign_ext_source · detach_campaign_ext_source · get_campaign_ext_sources
//   · 파일 읽기는 리포트 붙이기와 같은 함수(REPORT_PARSERS.pointail — report-parsers.js)
//   · 외부 줄은 카드에 표로 그리지 않는다 — 아래 결과물 표가 섞어 그린다(campExtRowsChanged — 그 표 쪽이 정의)
//   · 권한 menu.reports — 숨김이면 카드 없음 · 쓰기가 아니면 단추 없음(서버도 같은 판정)
//   · 🔴 캠페인에 붙인 파일은 리포트 공유 링크로 새지 않는다(545·410 은 report_id 로만 찾는다)
//   · ⚠️ 서버에 546 이 아직 없으면 data = {missing:true} 로 두고 카드를 조용히 숨긴다 — 운영은 「사전」 단계에 546 과 함께
//   · data 의 뜻: null = 아직 못 받음·조회 실패 / {missing:true} = 서버에 546 없음 / {sources, ext_rows} = 받음
// ════════════════════════════════════════════════════════════════════

var _campExt = { campaignId: null, data: null };
var _campExtSeq = 0;   // 같은 캠페인 조회가 겹치면 늦게 온 옛 응답을 버린다

function _campExtCanRead() { return !((typeof isHidden === 'function') && isHidden('menu.reports')); }
function _campExtCanWrite() { return (typeof canWrite === 'function') && canWrite('menu.reports'); }
// 외부 줄이 바뀌었다고 결과물 표에 알린다 — 정의가 없으면(표 쪽 미병합) 아무 일도 안 한다
function _campExtNotify() { if (typeof campExtRowsChanged === 'function') campExtRowsChanged(); }

// 진행현황을 열 때마다(loadCampApplicants) 부른다 — 기다리지 않는다
async function loadCampExtSources(campaignId) {
  const box = document.getElementById('campExtBox');
  const cnt = document.getElementById('campOpsExtCount');
  const same = _campExt.campaignId === campaignId;
  // 같은 캠페인을 다시 부를 때(저장·삭제 뒤)는 받던 값을 응답 전까지 둔다 — 아래 표에서 외부 줄이 깜빡 빠지지 않게
  _campExt = { campaignId: campaignId, data: same ? _campExt.data : null };
  const seq = ++_campExtSeq;
  if (!same) {
    if (cnt) { cnt.style.display = 'none'; cnt.textContent = ''; }
    if (box) { box.dataset.ready = ''; box.style.display = 'none'; }   // 앞 캠페인 카드가 응답 전까지 남지 않게
  }
  if (!box || !campaignId || !_campExtCanRead()) {
    _campExt.data = null;
    if (box) { box.dataset.ready = ''; box.style.display = 'none'; box.innerHTML = ''; }
    _campExtNotify();
    return;
  }
  const data = await fetchCampaignExtSources(campaignId);
  if (seq !== _campExtSeq || campaignId !== currentCampApplicantId) return;   // 그사이 다른 조회·다른 캠페인
  if (data && data.missing) {
    _campExt.data = { missing: true };
    box.dataset.ready = ''; box.style.display = 'none'; box.innerHTML = '';
    if (cnt) { cnt.style.display = 'none'; cnt.textContent = ''; }
    if (typeof applyCampDetailTabVisibility === 'function') applyCampDetailTabVisibility();
    _campExtNotify();
    return;
  }
  _campExt.data = data;
  _renderCampExtBox();
  box.dataset.ready = '1';
  if (typeof applyCampDetailTabVisibility === 'function') applyCampDetailTabVisibility();
  _campExtNotify();
}

// 모집 현황 아래 「외부 N명」 — 카드가 응답보다 늦게 그려져도 renderCampOpsSummary 가 다시 부른다
function campExtFillCount() {
  const cnt = document.getElementById('campOpsExtCount');
  if (!cnt) return;
  const d = _campExt.data;
  const n = (d && !d.missing && _campExt.campaignId === currentCampApplicantId && Array.isArray(d.ext_rows)) ? d.ext_rows.length : 0;
  if (n) { cnt.textContent = '외부 ' + n + '명'; cnt.style.display = ''; } else { cnt.textContent = ''; cnt.style.display = 'none'; }
}

// 서비스 이름 — 「포인테일 (스토어링크)」의 괄호 앞만(카드 줄은 짧게)
function _campExtServiceLabel(code) {
  const s = (typeof REPORT_SERVICES !== 'undefined' ? REPORT_SERVICES : []).find(function (x) { return x.code === code; });
  return s ? String(s.label).replace(/\s*\(.*\)\s*$/, '') : (code || '');
}
function _campExtSourceRows(sourceId) {
  const d = _campExt.data;
  return (d && Array.isArray(d.ext_rows)) ? d.ext_rows.filter(function (r) { return r.source_id === sourceId; }) : [];
}
function _campExtFindSource(pred) {
  const d = _campExt.data;
  return (d && Array.isArray(d.sources)) ? (d.sources.find(pred) || null) : null;
}

function _renderCampExtBox() {
  const box = document.getElementById('campExtBox');
  if (!box) return;
  const data = _campExt.data;
  const canW = _campExtCanWrite();
  const sources = (data && Array.isArray(data.sources)) ? data.sources : [];
  const head = '<div class="admin-card-header" style="gap:8px">'
    + '<span class="admin-card-title">외부 결과 파일</span>'
    + '<span style="font-size:12px;color:var(--muted)">' + (data ? '(' + sources.length + ') · ' : '') + '다른 서비스(포인테일) 결과 엑셀 — 이 캠페인의 결과물로 함께 셉니다</span>'
    + (canW ? '<button type="button" class="btn btn-ghost btn-sm" style="margin-left:auto" onclick="openCampExtAttachModal()">+ 외부 결과 파일 붙이기</button>' : '')
    + '</div>';
  if (!data) {
    box.innerHTML = head + '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">외부 결과 파일을 불러오지 못했습니다</div>';
    return;
  }
  campExtFillCount();
  if (!sources.length) {
    box.innerHTML = head + '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">붙인 외부 결과 파일이 없습니다</div>';
    return;
  }
  const muted = function (t) { return '<span style="color:var(--muted)">' + t + '</span>'; };
  box.innerHTML = head
    + '<div style="padding:0 16px 14px;display:flex;flex-direction:column;gap:6px">'
    + sources.map(function (s) {
        const rows = _campExtSourceRows(s.id);
        const total = rows.length || (Number(s.row_count) || 0);
        const proof = rows.filter(reportExtRowSubmitted).length;
        const who = [s.attached_by_name || '', s.attached_at ? formatDateTime(s.attached_at) : ''].filter(Boolean).join(' · ');
        return '<div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap;font-size:12.5px;background:var(--bg);border-radius:8px;padding:10px 14px">'
          + '<strong>' + esc(_campExtServiceLabel(s.service_code)) + '</strong>'
          + '<span>외부 캠페인 ' + esc(s.ext_campaign_no || '') + (s.ext_campaign_name ? ' · ' + esc(s.ext_campaign_name) : '') + '</span>'
          + (s.file_name ? muted(esc(s.file_name)) : '')
          + '<span>참가자 ' + total + '명 (증빙 있음 ' + proof + ')</span>'
          + (who ? muted(esc(who)) : '')
          + (canW ? '<span style="margin-left:auto;display:flex;gap:6px">'
              + '<button type="button" class="btn btn-ghost btn-sm" onclick="openCampExtAttachModal(\'' + esc(s.id) + '\')">업데이트</button>'
              + '<button type="button" class="btn btn-ghost btn-sm" style="color:var(--red);border-color:var(--red)" onclick="detachCampExtSource(\'' + esc(s.id) + '\')">삭제</button>'
              + '</span>' : '')
          + '</div>';
      }).join('')
    + '</div>';
}

// ── 붙이기·업데이트 창(a05-06a) — 리포트 붙이기와 같은 파일 읽기 ──
var _campExtForm = null;   // {sourceId, service, extNo, extName, fileName, parsed, busy, error}
function closeCampExtAttachModal() {
  _campExtCloseConfirm(false);
  const m = document.getElementById('campExtAttachModal'); if (m) m.remove();
  _campExtForm = null;
}
function openCampExtAttachModal(sourceId) {
  if (!_campExtCanWrite() || !_campExt.campaignId) return;
  closeCampExtAttachModal();
  const src = sourceId ? _campExtFindSource(function (s) { return s.id === sourceId; }) : null;
  const services = (typeof REPORT_SERVICES !== 'undefined') ? REPORT_SERVICES : [];
  _campExtForm = {
    sourceId: src ? src.id : null, service: (src && src.service_code) || (services[0] && services[0].code) || 'pointail',
    extNo: src ? (src.ext_campaign_no || '') : '', extName: src ? (src.ext_campaign_name || '') : '',
    fileName: '', parsed: null, busy: false, error: ''
  };
  const wrap = document.createElement('div');
  wrap.id = 'campExtAttachModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:520px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><div class="modal-title">외부 결과 파일 붙이기</div>
        <button class="modal-close" onclick="closeCampExtAttachModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" id="campExtAttachBody" style="overflow-y:auto"></div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="closeCampExtAttachModal()">닫기</button>
        <button class="btn btn-primary" id="btnCampExtSubmit" onclick="submitCampExtAttach()" disabled>붙이기</button>
      </div>
    </div>`;
  (document.getElementById('page-admin') || document.body).appendChild(wrap);
  _renderCampExtForm();
}
function _renderCampExtForm() {
  const f = _campExtForm; const body = document.getElementById('campExtAttachBody');
  if (!f || !body) return;
  // 처음 한 번만 칸을 그린다 — 다시 그리면 파일 칸이 비워지고 입력 초점도 끊긴다
  if (!document.getElementById('campExtFileStatus')) {
    const locked = !!f.sourceId;   // 업데이트로 열면 번호를 바꾸지 않는다(번호가 곧 어느 파일인지)
    const services = (typeof REPORT_SERVICES !== 'undefined') ? REPORT_SERVICES : [];
    // ⚠️ 서비스는 지금 포인테일 하나 — 저장 함수(546)가 서비스를 받지 않아 고르기는 보여 주기만 한다
    const opts = services.map(function (s) { return '<option value="' + esc(s.code) + '"' + (s.code === f.service ? ' selected' : '') + '>' + esc(s.label) + '</option>'; }).join('');
    body.innerHTML = `
      <div class="form-group"><label class="form-label">서비스</label>
        <select class="form-input" onchange="_campExtSet('service', this.value)">${opts}</select></div>
      <div class="form-group"><label class="form-label">외부 캠페인 번호</label>
        <input type="text" class="form-input" id="campExtNo" value="${esc(f.extNo)}" ${locked ? 'readonly' : ''} oninput="_campExtSet('extNo', this.value)" placeholder="비우면 파일 이름의 숫자로 채웁니다"></div>
      <div class="form-group"><label class="form-label">외부 캠페인 이름</label>
        <input type="text" class="form-input" id="campExtName" value="${esc(f.extName)}" oninput="_campExtSet('extName', this.value)"></div>
      <div class="form-group"><label class="form-label">파일 (.xlsx 하나)</label>
        <label class="form-input" style="display:flex;align-items:center;gap:12px;cursor:pointer">
          <span id="campExtFileName" style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted)">파일을 고르세요</span>
          <span style="color:var(--ink);font-size:13px;white-space:nowrap">「파일 고르기」</span>
          <input type="file" accept=".xlsx" style="display:none" onchange="_campExtFile(this)">
        </label>
      </div>
      <div id="campExtFileStatus"></div>
      <p style="font-size:12px;color:var(--muted);margin:12px 0 0;line-height:1.7">붙인 줄은 이 캠페인의 결과물로 셉니다(증빙 있음 = 제출, 미션 완료 = 인증성공). 같은 외부 캠페인 번호로 다시 붙이면 기존 줄을 모두 바꿉니다. 「브랜드 공개」가 켜져 있으면 브랜드 화면에도 바로 보입니다(계정 ID 는 보이지 않습니다).</p>`;
  }
  const fn = document.getElementById('campExtFileName');
  if (fn) { fn.textContent = f.fileName || '파일을 고르세요'; fn.style.color = f.fileName ? 'var(--ink)' : 'var(--muted)'; }
  const st = document.getElementById('campExtFileStatus');
  if (st) st.innerHTML = f.busy ? '<div style="font-size:12px;color:var(--muted);margin-top:4px">읽는 중…</div>'
    : f.error ? '<div style="font-size:12.5px;color:var(--red);margin-top:4px;line-height:1.6">' + esc(f.error) + '</div>'
    : f.parsed ? _campExtParsedBoxHtml(f.parsed) : '';
  const no = document.getElementById('campExtNo');
  if (no && !no.value && f.extNo) no.value = f.extNo;   // 파일 이름에서 번호를 채운 경우
  _campExtSyncSubmit();
}
// 읽은 결과 연보라 상자 — 구매는 파서 요약, 큐텐 리뷰·@cosme 는 사람 수(한 사람이 글·사진 둘 다 있어도 한 명)
function _campExtParsedBoxHtml(p) {
  const rows = Array.isArray(p.rows) ? p.rows : [];
  const sm = p.summary || {};
  const has = function (v) { return v !== null && v !== undefined && String(v).trim() !== ''; };
  const buy = Number(sm.buyers) || 0;
  const qoo10 = rows.filter(function (r) { return has(r.review_kind); }).length;
  const cosme = rows.filter(function (r) { return has(r.cosme_urls) || has(r.cosme_at); }).length;
  const masked = Number(sm.maskedAccounts) || 0;
  return '<div style="margin-top:4px;padding:12px 14px;border-radius:8px;background:#F3F0FF;font-size:13px;line-height:1.6">'
    + '<div style="color:var(--ink)">파일을 읽었습니다 — 참가자 ' + rows.length + '명 (구매 ' + buy + ' · 큐텐 리뷰 ' + qoo10 + ' · @cosme ' + cosme + ')</div>'
    + '<div style="font-size:12px;color:var(--muted)">이 중 포인테일이 이미 가려 보낸 계정 ID ' + masked + '명</div>'
    + '</div>';
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
    if (_campExtForm !== f) return;   // 그사이 창을 닫았다
    if (!res.ok) f.error = res.reason || '읽지 못했습니다';
    else {
      f.parsed = res;
      if (!String(f.extNo || '').trim()) { const m = file.name.match(/_(\d{4,})/); if (m) f.extNo = m[1]; }
    }
  } catch (e) { f.error = '읽는 중 오류 — ' + ((e && e.message) || e); }
  f.busy = false;
  _renderCampExtForm();
}

// ── 확인 창(a05-06b 업데이트 · a05-06c 삭제) — 붙이기 창 위에 겹쳐 뜨므로 z-index 를 하나 높인다 ──
//   (ESC 처리기 ui.js 는 z-index 가 가장 높은 창을 닫는다 — 같으면 아래 붙이기 창이 먼저 닫힌다)
var _campExtConfirmResolve = null;
function _campExtCloseConfirm(ok) {
  const m = document.getElementById('campExtConfirmModal'); if (m) m.remove();
  const r = _campExtConfirmResolve; _campExtConfirmResolve = null;
  if (r) r(!!ok);
}
function _campExtConfirm(opts) {
  _campExtCloseConfirm(false);
  return new Promise(function (resolve) {
    _campExtConfirmResolve = resolve;
    const wrap = document.createElement('div');
    wrap.id = 'campExtConfirmModal';
    wrap.className = 'modal-overlay open';
    wrap.style.zIndex = '510';
    const okStyle = opts.danger ? ' style="background:var(--red);border-color:var(--red)"' : '';
    wrap.innerHTML = `
      <div class="modal" style="max-width:540px;width:94vw;border-radius:16px;margin:auto">
        <div class="modal-header"><div class="modal-title">${esc(opts.title)}</div></div>
        <div class="modal-body">
          <div style="font-size:12.5px;color:var(--muted);line-height:1.6;margin-bottom:10px">${esc(opts.meta)}</div>
          <div style="font-size:13.5px;color:var(--ink);line-height:1.7">${esc(opts.body)}</div>
        </div>
        <div class="modal-footer">
          <button class="btn btn-ghost" onclick="_campExtCloseConfirm(false)">취소</button>
          <button class="btn btn-primary"${okStyle} onclick="_campExtCloseConfirm(true)">${esc(opts.ok)}</button>
        </div>
      </div>`;
    (document.getElementById('page-admin') || document.body).appendChild(wrap);
    // ESC(ui.js 공용 처리기)는 open 표시만 뗀다 — 그때도 「취소」로 끝내 기다리는 흐름을 푼다(공용 파일은 건드리지 않는다)
    new MutationObserver(function (_, obs) {
      if (!wrap.classList.contains('open')) { obs.disconnect(); if (wrap.isConnected) _campExtCloseConfirm(false); }
    }).observe(wrap, { attributes: true, attributeFilter: ['class'] });
  });
}

// 브랜드 공개가 켜졌는지 — 문구 한 줄을 붙일지만 정한다. 조회 실패면(개발서버) 켜진 쪽으로 본다(경고를 빠뜨리지 않게)
async function _campExtBrandPublishOn(campaignId) {
  if (!((typeof _brandAccountEnabled === 'function') && _brandAccountEnabled())) return false;   // 운영 — 브랜드 화면 없음
  const d = (typeof fetchCampaignBrandPublish === 'function') ? await fetchCampaignBrandPublish(campaignId) : null;
  return d ? !!d.enabled : true;
}

async function submitCampExtAttach() {
  const f = _campExtForm;
  if (!f || !f.parsed) return;
  const extNo = String(f.extNo).trim(), extName = String(f.extName).trim();
  // 같은 번호의 파일이 이미 있으면 업데이트(16-5 15번 ②) — 「업데이트」로 열었든 새로 붙였든 같은 확인 창
  const old = f.sourceId ? _campExtFindSource(function (s) { return s.id === f.sourceId; })
    : _campExtFindSource(function (s) { return s.ext_campaign_no === extNo; });
  if (old) {
    const btn0 = document.getElementById('btnCampExtSubmit'); if (btn0) btn0.disabled = true;
    const oldRows = _campExtSourceRows(old.id);
    const oldN = oldRows.length || (Number(old.row_count) || 0);
    const newRows = f.parsed.rows || [];
    // 추가·삭제는 회원번호로 비교한다(번호가 빈 줄은 비교에서 빠진다)
    const key = function (r) { return String((r && r.member_no) || '').trim(); };
    const oldSet = new Set(oldRows.map(key).filter(Boolean));
    const newSet = new Set(newRows.map(key).filter(Boolean));
    let added = 0, removed = 0;
    newSet.forEach(function (k) { if (!oldSet.has(k)) added++; });
    oldSet.forEach(function (k) { if (!newSet.has(k)) removed++; });
    const pubOn = await _campExtBrandPublishOn(_campExt.campaignId);
    if (_campExtForm !== f) return;
    const ok = await _campExtConfirm({
      title: '외부 결과 파일을 새 파일로 바꾸시겠습니까?',
      meta: '외부 캠페인 번호 ' + (old.ext_campaign_no || extNo) + ' · 지금 파일 ' + (old.file_name || '-') + '(' + oldN + '줄) → 새 파일 ' + (f.fileName || '-') + '(' + newRows.length + '줄)',
      body: '바뀌는 것: 줄 ' + newRows.length + '개로 교체(' + added + '줄 추가 · ' + removed + '줄 삭제)'
        + (pubOn ? ' · 브랜드 화면의 결과물 표와 모집 현황 숫자도 함께 바뀝니다.' : '.'),
      ok: '업데이트'
    });
    _campExtSyncSubmit();
    if (!ok || _campExtForm !== f) return;
  }
  const btn = document.getElementById('btnCampExtSubmit'); if (btn) { btn.disabled = true; btn.textContent = '저장 중…'; }
  try {
    await attachCampaignExtSource(_campExt.campaignId, extNo, extName, f.fileName, f.parsed.rows);
    closeCampExtAttachModal();
    toast(old ? '업데이트했습니다' : '붙였습니다');
    await refreshPane('camp-applicants');
  } catch (e) {
    toast('저장하지 못했습니다 — ' + ((e && e.message) || e), 'error');
    if (btn) { btn.textContent = '붙이기'; _campExtSyncSubmit(); }
  }
}
async function detachCampExtSource(sourceId) {
  if (!_campExtCanWrite()) return;
  const s = _campExtFindSource(function (x) { return x.id === sourceId; });
  const n = s ? (_campExtSourceRows(s.id).length || (Number(s.row_count) || 0)) : 0;
  const ok = await _campExtConfirm({
    title: '외부 결과 파일을 삭제하시겠습니까?',
    meta: '외부 캠페인 번호 ' + ((s && s.ext_campaign_no) || '-') + ' · ' + ((s && s.file_name) || '-') + '(' + n + '줄)',
    body: '삭제하면 이 파일의 참가자 줄 ' + n + '개가 진행현황과 브랜드 화면에서 사라지고, 브랜드 화면의 숫자에서도 빠집니다. 파일은 다시 붙일 수 있습니다.',
    ok: '삭제', danger: true
  });
  if (!ok) return;
  try { await detachCampaignExtSource(sourceId); toast('삭제했습니다'); await refreshPane('camp-applicants'); }
  catch (e) { toast('삭제하지 못했습니다 — ' + ((e && e.message) || e), 'error'); }
}
