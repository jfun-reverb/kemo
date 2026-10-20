// ════════════════════════════════════════════════════════════════════
// admin-cs-panel.js — 메시지 화면 오른쪽 CS 패널(#inboxCsPanel)
//   작업표 조각 3-1~3-3(갈래 C). 공용 부품은 admin-cs-common.js, 데이터는 storage.js 「CS 이력 관리」 절
// ════════════════════════════════════════════════════════════════════

// ── 3-1 패널 열고 닫기 + 캠페인 단 접기 ─────────────────────────────
//   메시지 화면의 updateInboxStage 끝에서 syncInboxCsPanel 이 불린다 — 대화가 바뀌었는지 여기서 판단한다
//   열림 여부(_csPanelOpen)는 대화를 옮겨도 그대로(기본 닫힘) · 대화가 없으면 단추·패널 모두 숨김
let _csPanelOpen = false;
let _csPanelKey = null;      // 'a:<응모 id>' | 'g:<서비스 문의 대화 id>'
let _csPanelRows;            // 그 대화의 CS 건 — 불러오는 중 undefined · 실패 null · 0건 []
let _csPanelSeq = 0;         // 대화를 빠르게 옮길 때 늦게 온 응답을 버린다

function _csPanelConversation() {
  if (_inboxKind === 'general') return _admMsgGeneralThreadId ? { key: 'g:' + _admMsgGeneralThreadId, threadId: _admMsgGeneralThreadId } : null;
  return _admMsgAppId ? { key: 'a:' + _admMsgAppId, applicationId: _admMsgAppId } : null;
}

function syncInboxCsPanel(pane, threadOpen) {
  const btn = $('inboxCsToggle'), panel = $('inboxCsPanel');
  const conv = (threadOpen && csHistoryEnabled()) ? _csPanelConversation() : null;
  if (!conv) {
    if (btn) btn.style.display = 'none';
    if (panel) panel.style.display = 'none';
    pane.classList.remove('stage-cs');
    _csPanelKey = null; _csPanelRows = undefined;
    return;
  }
  if (btn) btn.style.display = 'inline-flex';
  if (panel) panel.style.display = _csPanelOpen ? '' : 'none';
  pane.classList.toggle('stage-cs', _csPanelOpen);
  if (conv.key !== _csPanelKey) {
    _csPanelKey = conv.key;
    _csPanelRows = undefined;
    renderInboxCsToggle();
    renderInboxCsPanel();
    loadInboxCsPanel();
  } else {
    renderInboxCsToggle();
  }
}

async function loadInboxCsPanel() {
  const conv = _csPanelConversation();
  if (!conv) return;
  const my = ++_csPanelSeq;
  const [rows] = await Promise.all([fetchCsCasesForConversation(conv.applicationId || null, conv.threadId || null), csLoadCategories()]);
  if (my !== _csPanelSeq || conv.key !== _csPanelKey) return;
  _csPanelRows = rows;
  renderInboxCsToggle();
  renderInboxCsPanel();
}

// 닫힘: 「CS 관리 · 열린 건 N」 / 열림: 「› CS 관리」(누르면 닫힘) — a10-01·a10-03
function renderInboxCsToggle() {
  const btn = $('inboxCsToggle');
  if (!btn) return;
  const open = Array.isArray(_csPanelRows) ? _csPanelRows.filter(r => r.status !== 'done').length : null;
  btn.classList.toggle('on', _csPanelOpen);
  btn.innerHTML = _csPanelOpen
    ? '<span class="material-icons-round notranslate" translate="no" style="font-size:16px">chevron_right</span> CS 관리'
    : `<span class="material-icons-round notranslate" translate="no" style="font-size:16px">support_agent</span> CS 관리 · 열린 건 ${_csPanelRows === null ? '!' : open == null ? '…' : open}`;
  btn.setAttribute('aria-expanded', _csPanelOpen ? 'true' : 'false');
}

function toggleInboxCsPanel(force) {
  _csPanelOpen = (force === undefined) ? !_csPanelOpen : !!force;
  updateInboxStage();   // → syncInboxCsPanel 이 단계·표시를 맞춘다
}

// 패널 본문 — 건 카드는 3-2 에서. 지금은 건마다 한 줄(누르면 건 상세)
function renderInboxCsPanel() {
  const body = $('inboxCsBody'), title = $('inboxCsTitleText'), add = $('inboxCsAddBtn');
  if (add) add.style.display = 'none';   // CS 추가는 3-3
  if (title) title.textContent = `CS 관리${Array.isArray(_csPanelRows) ? ` · 건 ${_csPanelRows.length}` : ''}`;
  if (!body) return;
  if (_csPanelRows === undefined) { body.innerHTML = _csPanelKey ? '<div class="inbox-empty">불러오는 중…</div>' : ''; return; }
  if (_csPanelRows === null) {
    body.innerHTML = '<div class="inbox-empty">CS 건을 불러오지 못했습니다. <button type="button" class="cs-link" onclick="loadInboxCsPanel()">다시 시도</button></div>';
    return;
  }
  if (!_csPanelRows.length) { body.innerHTML = '<div class="inbox-empty">이 대화에는 아직 CS 건이 없습니다.</div>'; return; }
  body.innerHTML = _csPanelRows.slice().reverse().map(r => `<button type="button" class="cs-panel-line" onclick="openCsCaseDetail(${jsStr(r.id)})">
    ${csStatusBadgeHtml(r.status)}<span class="cs-panel-line-main">${esc(r.category_code ? csCategoryLabel(r.category_code) : '항목 없음')} · 접수 ${esc(formatDateTime(r.received_at))}</span>
    <span class="cs-panel-line-no">#${esc(String(r.case_no))}</span></button>`).join('');
}

// CS 추가(두 단계)는 조각 3-3 — 단추는 그때까지 숨긴다(renderInboxCsPanel)
function startInboxCsSplit() { toast('CS 추가는 다음 작업에서 열립니다'); }
