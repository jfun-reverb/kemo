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
// 카드 화면 상태(3-2) — expanded: 펼친 건 하나(D-16) · completing: 완료 양식을 연 건 · drafts: 건별 쓰던 완료 양식 값
//   memo: 건 id → {total, unread} · read: 이번에 펼쳐 읽음 처리한 건 · lastReply: 미리 채움 ③ 결과
let _csPn = { expanded: null, completing: null, editingSummary: null, summaryDraft: null, more: {}, drafts: {}, memo: {}, read: {}, busy: false, lastReply: {} };

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
    _csPn = { expanded: null, completing: null, editingSummary: null, summaryDraft: null, more: {}, drafts: {}, memo: {}, read: {}, busy: false, lastReply: {} };
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
  if (Array.isArray(rows) && rows.length) {
    const memo = await fetchCsCommentSummaries(rows.map(r => r.id));
    if (my !== _csPanelSeq || conv.key !== _csPanelKey) return;
    _csPn.memo = memo || {};
    // 처음 펼칠 건 = 접수가 가장 늦은 열린 건(D-16). 이미 펼친 건이 아직 있으면 그대로
    if (!_csPn.expanded || !rows.some(r => r.id === _csPn.expanded)) {
      const open = rows.filter(r => r.status !== 'done');
      _csPn.expanded = open.length ? open[open.length - 1].id : null;
    }
  }
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
  if (_csPanelOpen && Array.isArray(_csPanelRows)) renderInboxCsPanel();   // 닫힌 채 그린 카드에 메모를 이제 붙인다
}

// CS 추가(두 단계)는 조각 3-3 — 단추는 그때까지 숨긴다(renderInboxCsPanel)
function startInboxCsSplit() { toast('CS 추가는 다음 작업에서 열립니다'); }

// ── 3-2 건 카드(피그마 a10-03·06·07·07a) ─────────────────────────────
//   펼친 건은 한 번에 하나 — 열린 건·완료 건을 통틀어(D-16). 펼쳐 메모가 보이는 순간 그 건 메모 읽음(D-20)
//   「CS 건 완료」(보라)는 카드 안 완료 양식을 연다 — 메시지의 「응대 완료」(검정)와 서로를 바꾸지 않는다(D-15)
//   항목은 완료 양식 안에서만 고른다(서버에 「진행 중 항목만 저장」하는 함수가 없다 — 562 는 완료 때 함께 저장)
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
  body.innerHTML = `<div class="cs-pn-list">${_csPanelRows.map(r => r.id === _csPn.expanded ? _csPnCardHtml(r) : _csPnLineHtml(r)).join('')}</div>`;
  _csPnAfterRender();
}

// 그린 뒤 — 쓰던 완료 양식 값을 되살리고, 펼친 건 메모를 붙인다(처음 펼칠 때만 읽음)
function _csPnAfterRender() {
  const r = (_csPanelRows || []).find(x => x.id === _csPn.expanded);
  if (!r) return;
  const d = _csPn.drafts[r.id];
  if (_csPn.completing === r.id && d) {
    if (d.cat != null && $('csPnCategory')) $('csPnCategory').value = d.cat;
    if (d.resp != null && $('csPnResponse')) $('csPnResponse').value = d.resp;
  }
  const el = $('csPnMemo');
  // 🔴 패널이 닫혀 있으면 메모를 붙이지 않는다 — 보이지 않는 자리에서 읽음 처리되면 안 된다(D-20)
  if (!el || !_csPanelOpen) return;
  const first = !_csPn.read[r.id];
  _csPn.read[r.id] = true;
  csMountComments(r.id, el, { purged: !!r.personal_purged_at, markRead: first, onChanged: () => _csPnRefreshMemo(r.id) })
    .then(() => { if (first) _csPnRefreshMemo(r.id); });
}

async function _csPnRefreshMemo(caseId) {
  const sum = await fetchCsCommentSummaries([caseId]);
  if (!sum) return;
  _csPn.memo[caseId] = sum[caseId] || { total: 0, unread: 0 };
  // 펼친 카드는 다시 그리지 않는다(쓰던 메모가 지워진다) — 접힌 줄의 숫자만 다음 그리기 때 반영
}

function _csPnUnreadDot(id) {
  const n = (_csPn.memo[id] || {}).unread || 0;
  return n ? `<span class="cs-memo-cell-dot cs-pn-dot" title="안 읽은 메모 ${n}개">${n > 99 ? '99+' : n}</span>` : '';
}

// 접힌 줄 — 완료: 항목 · 해결 시간 · 다시 열기 / 열린 건: 항목 · 접수 · 메모 N
function _csPnLineHtml(r) {
  const cat = r.category_code ? csCategoryLabel(r.category_code) : '항목 없음';
  const mid = r.status === 'done'
    ? `${esc(cat)} · 해결 ${esc(csDurationBetween(r.received_at, r.completed_at, r.time_unknown))}`
    : `${esc(cat)} · 접수 ${esc(formatDateTime(r.received_at))} · 메모 ${(_csPn.memo[r.id] || {}).total || 0}`;
  const reopen = (r.status === 'done' && !r.personal_purged_at)
    ? `<button type="button" class="cs-link" onclick="csPnReopen(${jsStr(r.id)})">다시 열기</button>` : '';
  return `<div class="cs-pn-line">${csStatusBadgeHtml(r.status)}<span class="cs-pn-line-main">${mid}</span>${_csPnUnreadDot(r.id)}
    <button type="button" class="cs-link" onclick="csPnExpand(${jsStr(r.id)})">펼치기</button>${reopen}</div>`;
}

// 펼친 카드
function _csPnCardHtml(r) {
  const done = r.status === 'done', purged = !!r.personal_purged_at, completing = _csPn.completing === r.id;
  const head = `<div class="cs-pn-head">${csStatusBadgeHtml(r.status)}${r.previous_case_id ? '<span class="cs-tag">재문의</span>' : ''}
    <span class="cs-pn-times">접수 ${esc(r.time_unknown ? formatDate(r.received_at) : formatDateTime(r.received_at))}
    · 첫 답장 ${esc(r.first_reply_at ? csDurationBetween(r.received_at, r.first_reply_at, r.time_unknown) : '—')}</span>
    <button type="button" class="cs-link" style="margin-left:auto" onclick="csPnExpand(null)">접기</button></div>`;
  if (purged) return `<div class="cs-pn-card">${head}<div class="cs-cd-purged">개인정보가 정리된 건입니다. 항목·시각만 남아 있습니다.</div></div>`;
  const statusSeg = done ? '' : `<div class="cs-pn-row"><span class="cs-field-label">진행현황</span><span class="cs-seg-wrap">${['in_progress', 'needs_check'].map(st =>
    `<button type="button" class="cs-seg${r.status === st ? ' on' : ''}" onclick="csPnSetStatus(${jsStr(r.id)},'${st}')">${CS_STATUS_LABEL_KO[st]}</button>`).join('')}</span></div>`;
  const memoN = (_csPn.memo[r.id] || {}).total || 0;
  const memo = completing
    ? `<div class="cs-pn-memo-fold">확인 필요 메모 ${memoN} — 완료한 뒤에도 남습니다</div>`
    : `<div class="cs-pn-memo-title">확인 필요 메모 ${memoN}</div><div id="csPnMemo"></div>
       <div class="cs-pn-memo-note">담당자끼리만 봅니다 · 회원에게 보이지 않음</div>`;
  const tail = done ? _csPnDoneHtml(r)
    : completing ? _csPnCompleteHtml(r)
    : `<button type="button" class="btn btn-primary btn-sm cs-btn-complete cs-pn-complete-btn" onclick="csPnStartComplete(${jsStr(r.id)})">
        <span class="material-icons-round notranslate" translate="no" style="font-size:16px">task_alt</span> CS 건 완료</button>`;
  return `<div class="cs-pn-card${completing ? ' completing' : ''}">${head}${_csPnSummaryHtml(r)}${statusSeg}${done ? tail : ''}${memo}${done ? '' : tail}</div>`;
}

// 문의 요약 — 원문·번역 각 한 줄 + 「더 보기」, 연필 = 「요약 수정」(D-12)
function _csPnSummaryHtml(r) {
  if (_csPn.editingSummary === r.id) {
    const v = (_csPn.summaryDraft != null) ? _csPn.summaryDraft : (r.summary_text || '');
    return `<div class="cs-pn-summary"><textarea id="csPnSummaryInput" class="form-input" rows="3">${esc(v)}</textarea>
      <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:6px">
        <button type="button" class="btn btn-ghost btn-xs" onclick="csPnEditSummary(null)">취소</button>
        <button type="button" class="btn btn-primary btn-xs" onclick="csPnSaveSummary(${jsStr(r.id)})">요약 저장</button></div></div>`;
  }
  const more = !!_csPn.more[r.id];
  const tr = r.summary_translated ? `<div class="cs-pn-sum-tr${more ? '' : ' clamp'}">${esc(r.summary_translated)}</div>` : '';
  return `<div class="cs-pn-summary"><div class="cs-pn-sum-row">
      <span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--muted)">format_quote</span>
      <div style="flex:1;min-width:0"><div class="cs-pn-sum-text${more ? '' : ' clamp'}">${esc(r.summary_text || '—')}</div>${tr}</div>
      <button type="button" class="cs-pn-icon-btn" title="요약 수정" aria-label="요약 수정" onclick="csPnEditSummary(${jsStr(r.id)})"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit</span></button></div>
    <div style="display:flex;gap:8px;align-items:center">${r.summary_edited ? '<span class="cs-edited" style="margin-left:0">수정됨</span>' : ''}
      <button type="button" class="cs-link" style="font-size:11.5px" onclick="csPnToggleMore(${jsStr(r.id)})">${more ? '접기' : '더 보기'}</button></div></div>`;
}

// 완료 양식(a10-07) — 2-0 공용 부품. 미리 채움 ①~④ 는 csResponsePrefill 한 곳
function _csPnCompleteHtml(r) {
  const lr = _csPn.lastReply[r.id];
  const hint = (!r.response_body && lr && lr.body)
    ? `<div class="cs-summary-note">마지막 운영팀 답장(${esc(formatDateTime(lr.created_at))})으로 미리 채웠습니다 · 「감사합니다」처럼 짧게 끝났으면 왼쪽 대화에서 실제 안내 글을 복사해 넣으세요 · 어느 언어로 써도 자동 번역</div>` : '';
  return `<div class="cs-cd-complete cs-pn-complete">
    <div class="cs-cd-complete-head"><span class="material-icons-round notranslate" translate="no" style="font-size:17px">task_alt</span> CS 건 완료</div>
    <div class="cs-summary-note" style="margin-bottom:6px">항목과 대응 안내 내용을 채워 저장하면 완료됩니다. 왼쪽 대화는 그대로 보이니 필요한 글을 복사해 고칠 수 있습니다.</div>
    ${csCompleteFormHtml(r, csResponsePrefill(r, lr), 'csPn')}${hint}
    <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:8px">
      <button type="button" class="btn btn-ghost btn-sm" onclick="csPnCancelComplete()">취소</button>
      <button type="button" id="csPnSaveBtn" class="btn btn-primary btn-sm cs-btn-complete" onclick="csPnSaveComplete(${jsStr(r.id)})">완료 저장</button></div></div>`;
}

// 펼친 완료 건 — 저장 값·해결 시간·완료한 사람 + 다시 열기
function _csPnDoneHtml(r) {
  const tr = r.response_translated ? `<div class="cs-memo-trans"><span class="cs-memo-trans-tag">번역</span>${esc(r.response_translated)}</div>` : '';
  return `<div class="cs-pn-done">
    <div class="cs-summary-note">항목 <strong style="color:var(--ink)">${esc(csCategoryLabel(r.category_code) || '—')}</strong>
      · 완료 ${esc(r.completed_at ? formatDateTime(r.completed_at) : '—')} (해결 ${esc(csDurationBetween(r.received_at, r.completed_at, r.time_unknown))})
      · ${esc(r.completed_by_name || '—')}</div>
    <div class="cs-cd-box" style="margin:6px 0"><div class="cs-memo-text">${esc(r.response_body || '—')}</div>${tr}</div>
    <button type="button" class="btn btn-ghost btn-xs" onclick="csPnReopen(${jsStr(r.id)})">다시 열기</button></div>`;
}

// ── 카드 동작 ─────────────────────────────────────────────
function _csPnRow(id) { return (_csPanelRows || []).find(r => r.id === id) || null; }
function _csPnHasDraft() {
  const d = _csPn.completing && _csPn.drafts[_csPn.completing];
  return !!(d && ((d.resp || '').trim() || d.cat));
}

// 펼치기(null = 모두 접기) — 쓰던 완료 양식이 있으면 버릴지 묻는다(a10-07 주의)
async function csPnExpand(id) {
  if (_csPn.completing && _csPn.completing !== id && _csPnHasDraft()) {
    if (!(await showConfirm('쓰던 완료 양식이 있습니다. 버리고 다른 건을 펼칠까요?'))) return;
  }
  if (_csPn.completing !== id) { delete _csPn.drafts[_csPn.completing]; _csPn.completing = null; }
  _csPn.expanded = id;
  _csPn.editingSummary = null;
  renderInboxCsPanel();
}
function csPnToggleMore(id) { _csPn.more[id] = !_csPn.more[id]; renderInboxCsPanel(); }
function csPnEditSummary(id) {
  _csPn.editingSummary = id;
  _csPn.summaryDraft = null;
  renderInboxCsPanel();
  if (id && $('csPnSummaryInput')) $('csPnSummaryInput').focus();
}

// 쓰기 공용 — 연타 잠금 · 성공하면 onOk(상태 정리)를 먼저 하고 패널을 다시 읽는다 · 실패·충돌도 다시 읽고 쓰던 양식 값은 남긴다
//   🔴 저장 중 다른 대화로 옮기면 새 대화의 상태(_csPn)는 건드리지 않는다(대화 키 대조) · 잠금은 다시 읽은 뒤 푼다(옛 version 연타 방지)
async function _csPnWrite(fn, okMsg, onOk) {
  if (_csPn.busy) return false;
  const key = _csPanelKey, st = _csPn;
  st.busy = true;
  let ok = false;
  try {
    await fn();
    ok = true;
    if (okMsg) toast(okMsg, 'success');
  } catch (e) {
    toast(csErrorText(e), 'error');
  }
  if (key === _csPanelKey && st === _csPn) {
    if (ok && onOk) onOk();
    await loadInboxCsPanel();
  }
  st.busy = false;
  return ok;
}

async function csPnSetStatus(id, status) {
  const r = _csPnRow(id);
  if (!r || r.status === status) return;
  await _csPnWrite(() => csSetCaseStatus(r.id, r.version, status), `진행현황을 「${CS_STATUS_LABEL_KO[status]}」(으)로 바꿨습니다`);
}

async function csPnSaveSummary(id) {
  const r = _csPnRow(id);
  const v = (($('csPnSummaryInput') || {}).value || '').trim();
  if (!r) return;
  if (!v) { toast(CS_ERROR_TEXT_KO.summary_required, 'error'); return; }
  await _csPnWrite(() => csUpdateCaseSummary(r.id, r.version, v), '문의 요약을 고쳤습니다',
    () => { _csPn.editingSummary = null; _csPn.summaryDraft = null; });
}

// 「CS 건 완료」 — 카드 안 양식을 연다. 미리 채움 ③(마지막 운영팀 답장)이 필요하면 먼저 받아 둔다
async function csPnStartComplete(id) {
  const r = _csPnRow(id);
  if (!r) return;
  if (csNeedsStaffReplyPrefill(r) && !(id in _csPn.lastReply)) _csPn.lastReply[id] = await fetchCsLastStaffReply(r);
  _csPn.completing = id;
  _csPn.drafts[id] = _csPn.drafts[id] || {};
  renderInboxCsPanel();
}
function csPnCancelComplete() {
  delete _csPn.drafts[_csPn.completing];
  _csPn.completing = null;
  renderInboxCsPanel();
}

// 완료 저장 — 빈 칸은 빨갛게 표시하고 저장 안 함(a10-07a) · 저장 중 「처리 중…」 잠금 · 실패하면 양식을 닫지 않는다
async function csPnSaveComplete(id) {
  const r = _csPnRow(id);
  if (!r) return;
  const f = csReadCompleteForm(r, 'csPn');
  if (!f.ok) { toast('빨갛게 표시된 칸을 채워 주세요', 'error'); return; }
  const btn = $('csPnSaveBtn');
  if (btn) { btn.disabled = true; btn.textContent = '처리 중…'; }
  await _csPnWrite(() => csCompleteCase(r.id, r.version, f.category, f.response, f.completedAt), 'CS 건을 완료했습니다',
    () => { delete _csPn.drafts[id]; _csPn.completing = null; _csPn.expanded = null; });
}

async function csPnReopen(id) {
  const r = _csPnRow(id);
  if (!r) return;
  if (!(await showConfirm('이 CS 건을 다시 열까요? 진행현황이 「진행중」으로 돌아가고, 다시 완료할 때 해결 시간이 새로 계산됩니다.'))) return;
  await _csPnWrite(() => csReopenCase(r.id, r.version), 'CS 건을 다시 열었습니다', () => { _csPn.expanded = id; });
}

// 쓰던 완료 양식 값을 건별로 기억 — 다시 그려도(진행현황·메모·패널 다시 읽기) 남는다
(function () {
  const body = document.getElementById('inboxCsBody');
  if (!body) return;
  body.addEventListener('input', (e) => {
    const id = _csPn.completing;
    if (!id) return;
    const d = _csPn.drafts[id] = _csPn.drafts[id] || {};
    if (e.target.id === 'csPnResponse') d.resp = e.target.value;
  });
  body.addEventListener('input', (e) => { if (e.target.id === 'csPnSummaryInput') _csPn.summaryDraft = e.target.value; });
  body.addEventListener('change', (e) => {
    const id = _csPn.completing;
    if (id && e.target.id === 'csPnCategory') (_csPn.drafts[id] = _csPn.drafts[id] || {}).cat = e.target.value;
  });
})();
