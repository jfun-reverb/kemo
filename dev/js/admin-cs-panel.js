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
  if (_csSplit && (!conv || conv.key !== _csSplit.key)) csSplitCancel(true);
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


// ── 3-2 건 카드(피그마 a10-03·06·07·07a) ─────────────────────────────
//   펼친 건은 한 번에 하나 — 열린 건·완료 건을 통틀어(D-16). 펼쳐 메모가 보이는 순간 그 건 메모 읽음(D-20)
//   「CS 건 완료」(보라)는 카드 안 완료 양식을 연다 — 메시지의 「응대 완료」(검정)와 서로를 바꾸지 않는다(D-15)
//   항목은 완료 양식 안에서만 고른다(서버에 「진행 중 항목만 저장」하는 함수가 없다 — 562 는 완료 때 함께 저장)
function renderInboxCsPanel() {
  const body = $('inboxCsBody'), title = $('inboxCsTitleText'), add = $('inboxCsAddBtn');
  if (add) add.style.display = (Array.isArray(_csPanelRows) && !_csSplit) ? 'inline-flex' : 'none';
  if (title) title.textContent = `CS 관리${Array.isArray(_csPanelRows) ? ` · 건 ${_csPanelRows.length}` : ''}`;
  if (!body) return;
  if (_csPanelRows === undefined) { body.innerHTML = _csPanelKey ? '<div class="inbox-empty">불러오는 중…</div>' : ''; return; }
  if (_csPanelRows === null) {
    body.innerHTML = '<div class="inbox-empty">CS 건을 불러오지 못했습니다. <button type="button" class="cs-link" onclick="loadInboxCsPanel()">다시 시도</button></div>';
    return;
  }
  if (_csSplit) { body.innerHTML = `<div class="cs-pn-list">${_csSplitCardHtml()}${_csPanelRows.map(r => _csPnLineHtml(r, true)).join('')}</div>`; return; }
  if (!_csPanelRows.length) { body.innerHTML = '<div class="inbox-empty">이 대화에는 아직 CS 건이 없습니다. 「CS 추가」로 회원 글을 골라 건을 만들 수 있습니다.</div>'; return; }
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
function _csPnLineHtml(r, locked) {
  const cat = r.category_code ? csCategoryLabel(r.category_code) : '항목 없음';
  const mid = r.status === 'done'
    ? `${esc(cat)} · 해결 ${esc(csDurationBetween(r.received_at, r.completed_at, r.time_unknown))}`
    : `${esc(cat)} · 접수 ${esc(formatDateTime(r.received_at))} · 메모 ${(_csPn.memo[r.id] || {}).total || 0}`;
  const reopen = (r.status === 'done' && !r.personal_purged_at)
    ? `<button type="button" class="cs-link" onclick="csPnReopen(${jsStr(r.id)})">다시 열기</button>` : '';
  // CS 추가 중에는 다른 건이 접힌 채 잠긴다(4-1 잠금 범위)
  return `<div class="cs-pn-line${locked ? ' cs-pn-locked' : ''}"${locked ? ' aria-disabled="true"' : ''}>${csStatusBadgeHtml(r.status)}<span class="cs-pn-line-main">${mid}</span>${_csPnUnreadDot(r.id)}
    ${locked ? '' : `<button type="button" class="cs-link" onclick="csPnExpand(${jsStr(r.id)})">펼치기</button>${reopen}`}</div>`;
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

// ════════════════════════════════════════════════════════════════════
// 3-3 CS 추가 두 단계(피그마 a10-04·04a · D-12·D-19)
//   ① 대화의 회원 글 체크 → 답장 자리가 「N개 선택됨 · 취소 · 선택 완료」 막대 ② 패널 맨 위 새 건 양식 → 「추가」
//   진행 중: 답장·「FAQ 열람 이력」·「응대 완료」·「숨김 이력」·패널의 다른 건이 잠기고 대화 검색만
//   패널 닫기·다른 대화·탭·메뉴 이동은 「CS 추가를 그만둘까요?」 확인 뒤 취소(아래 가로채기)
//   🔴 메시지 화면 파일은 체크 칸 자리 표시(data-cs-member)와 다시 그린 뒤 부르는 한 줄, 답장·응대 완료 막기만 고쳤다
// ════════════════════════════════════════════════════════════════════
let _csSplit = null;   // {key, step, selected:Set, starts:Set, busy}

function csSplitActive() { return !!_csSplit; }

function startInboxCsSplit() {
  if (!Array.isArray(_csPanelRows) || !_csPanelKey || _csSplit) return;
  // 다른 건의 시작 글 = 각 건에 붙은 가장 이른 글(message_ids 는 시각 순) — 고를 수 없다
  const starts = new Set(_csPanelRows.map(r => (r.message_ids || [])[0]).filter(Boolean));
  _csSplit = { key: _csPanelKey, step: 1, selected: new Set(), starts, busy: false };
  _csSplitApplyLock();
  renderInboxCsPanel();
  const thread = $('inboxMsgThread');
  if (thread) csSplitDecorateThread(thread);
}

// 체크 칸 — 렌더 함수 끝에서도 불린다(검색·30초 갱신으로 다시 그려도 고른 상태가 남는다)
function csSplitDecorateThread(thread) {
  if (!thread || thread.id !== 'inboxMsgThread') return;
  thread.querySelectorAll('.cs-split-check').forEach(el => el.remove());
  thread.classList.toggle('cs-splitting', !!_csSplit);
  if (!_csSplit) return;
  thread.querySelectorAll('.msg-row[data-cs-member="1"]').forEach(row => {
    const id = row.getAttribute('data-msg-id');
    const isStart = _csSplit.starts.has(id);
    const label = document.createElement('label');
    label.className = 'cs-split-check' + (isStart ? ' disabled' : '');
    label.title = isStart ? '다른 건의 시작 글 — 고를 수 없음' : '이 글을 새 CS 건에 넣기';
    label.innerHTML = `<input type="checkbox"${_csSplit.selected.has(id) ? ' checked' : ''}${(isStart || _csSplit.step !== 1) ? ' disabled' : ''}>`
      + (isStart ? '<span class="cs-split-start">다른 건의 시작 글</span>' : '');
    label.querySelector('input').addEventListener('change', (e) => {
      if (e.target.checked) _csSplit.selected.add(id); else _csSplit.selected.delete(id);
      _csSplitRenderBar();
    });
    row.append(label);   // 회원 글 줄은 row-reverse 라 마지막 자식이 맨 왼쪽(말풍선 앞)에 온다
  });
  // 대화 영역이 통째로 다시 그려졌으면(잠금 막대가 사라짐) 잠금을 다시 건다
  if (!$('csSplitBar')) _csSplitApplyLock();
}

// 잠금 — 보라 안내 막대(대화 머리 아래·검색 줄 위) · 행동 줄 단추 잠금 · 답장 자리 → 선택 막대
function _csSplitApplyLock() {
  const view = $('inboxThreadView');
  if (!view) return;
  const bar = view.querySelector('.adm-msg-actionbar');
  if (bar && !$('csSplitGuide')) bar.insertAdjacentHTML('beforebegin', '<div id="csSplitGuide" class="cs-split-guide"></div>');
  if (bar) bar.querySelectorAll('button').forEach(b => {
    if (!b.hasAttribute('data-cs-was-disabled')) b.setAttribute('data-cs-was-disabled', b.disabled ? '1' : '0');
    b.disabled = true;
  });
  const composer = $('inboxComposer');
  if (composer) {
    composer.style.display = 'none';
    if (!$('csSplitBar')) composer.insertAdjacentHTML('afterend', '<div id="csSplitBar" class="cs-split-bar"></div>');
  }
  _csSplitRenderBar();
}

function _csSplitRemoveLock() {
  const g = $('csSplitGuide'); if (g) g.remove();
  const b = $('csSplitBar'); if (b) b.remove();
  const composer = $('inboxComposer'); if (composer) composer.style.display = '';
  document.querySelectorAll('#inboxThreadView [data-cs-was-disabled]').forEach(btn => {
    btn.disabled = btn.getAttribute('data-cs-was-disabled') === '1';
    btn.removeAttribute('data-cs-was-disabled');
  });
  const thread = $('inboxMsgThread');
  if (thread) csSplitDecorateThread(thread);
}

function _csSplitRenderBar() {
  const guide = $('csSplitGuide'), bar = $('csSplitBar');
  if (!_csSplit) return;
  if (guide) guide.textContent = _csSplit.step === 1 ? '새 CS 건에 넣을 회원 글을 고르세요' : '오른쪽 새 건 양식을 채워 「추가」를 누르세요';
  if (!bar) return;
  const n = _csSplit.selected.size;
  bar.innerHTML = _csSplit.step === 1
    ? `<span class="cs-split-count">회원 글 ${n}개 선택됨</span><span style="flex:1"></span>
       <button type="button" class="btn btn-ghost btn-sm" onclick="csSplitCancelAsk()">취소</button>
       <button type="button" class="btn btn-primary btn-sm cs-btn-complete" onclick="csSplitNext()"${n ? '' : ' disabled'}>선택 완료</button>`
    : '<span class="cs-split-locked"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">lock</span> CS 추가 중에는 답장을 쓸 수 없습니다</span>';
}

function csSplitNext() {
  if (!_csSplit || !_csSplit.selected.size) return;
  _csSplit.step = 2;
  _csSplitRenderBar();
  renderInboxCsPanel();
  csSplitDecorateThread($('inboxMsgThread'));   // 체크 칸 잠금
}
function csSplitBack() {
  if (!_csSplit) return;
  _csSplit.step = 1;
  _csSplitRenderBar();
  renderInboxCsPanel();
  csSplitDecorateThread($('inboxMsgThread'));
}
async function csSplitCancelAsk() {
  if (!(await showConfirm('CS 추가를 그만둘까요? 고른 글과 쓰던 내용은 사라집니다.'))) return;
  csSplitCancel();
}
// silent — 대화가 바뀌어 이미 떠난 경우(확인 창 없이)
function csSplitCancel(silent) {
  if (!_csSplit) return;
  _csSplit = null;
  _csSplitRemoveLock();
  if (!silent) renderInboxCsPanel();
}

// 고른 글 중 가장 이른 글 = 접수 시각 · 문의 요약 기본값(D-12) — 서버도 같은 규칙으로 만든다(563 cs_split_case)
function _csSplitFirstMsg() {
  const msgs = (typeof _admMsgCurrentMsgs !== 'undefined' && Array.isArray(_admMsgCurrentMsgs)) ? _admMsgCurrentMsgs : [];
  return msgs.filter(m => _csSplit.selected.has(m.id))
    .sort((a, b) => new Date(a.created_at) - new Date(b.created_at))[0] || null;
}

// 패널 맨 위 카드 — 1단계 안내 / 2단계 새 건 양식(a10-04a)
function _csSplitCardHtml() {
  if (_csSplit.step === 1) {
    return `<div class="cs-pn-card cs-split-card"><div class="cs-cd-complete-head"><span class="material-icons-round notranslate" translate="no" style="font-size:17px">add_circle</span> CS 추가</div>
      <div class="cs-summary-note">왼쪽 대화에서 이 건에 넣을 회원 글을 고르고 아래 「선택 완료」를 누르세요. 운영팀 글은 고를 수 없습니다.</div>
      <div style="display:flex;justify-content:flex-end"><button type="button" class="btn btn-ghost btn-sm" onclick="csSplitCancelAsk()">취소</button></div></div>`;
  }
  const first = _csSplitFirstMsg();
  const tr = (first && first.translate_status === 'done' && first.body_translated) ? `<div class="cs-pn-sum-tr">${esc(first.body_translated)}</div>` : '';
  return `<div class="cs-pn-card cs-split-card"><div class="cs-cd-complete-head"><span class="material-icons-round notranslate" translate="no" style="font-size:17px">add_circle</span> 새 CS 건 · 회원 글 ${_csSplit.selected.size}개</div>
    <div class="cs-field-label">문의 요약 <span class="cs-cd-sec-sub">가장 이른 글 — 추가한 뒤 고칠 수 있음</span></div>
    <div class="cs-pn-summary"><div class="cs-pn-sum-text">${esc((first && first.body) || '—')}</div>${tr}</div>
    <div class="cs-field-label">접수 ${esc(first ? formatDateTime(first.created_at) : '—')}</div>
    <label class="cs-field-label" for="csSplitCategory">항목 <span class="cs-cd-sec-sub">선택 — 완료할 때 골라도 됩니다</span></label>
    <select id="csSplitCategory" class="form-input cs-field">${csCategoryOptionsHtml(_csSplit.category || '')}</select>
    <label class="cs-field-label" for="csSplitComment">첫 메모 <span class="cs-cd-sec-sub">선택 · 담당자끼리만 봅니다</span></label>
    <textarea id="csSplitComment" class="form-input" rows="2" placeholder="메모 입력…">${esc(_csSplit.comment || '')}</textarea>
    <div style="display:flex;justify-content:space-between;gap:6px;margin-top:4px">
      <button type="button" class="btn btn-ghost btn-sm" onclick="csSplitBack()">다시 고르기</button>
      <span style="display:flex;gap:6px"><button type="button" class="btn btn-ghost btn-sm" onclick="csSplitCancelAsk()">취소</button>
      <button type="button" id="csSplitAddBtn" class="btn btn-primary btn-sm cs-btn-complete" onclick="csSplitSubmit()"${_csSplit.busy ? ' disabled' : ''}>추가</button></span></div></div>`;
}

async function csSplitSubmit() {
  if (!_csSplit || _csSplit.busy || !_csSplit.selected.size) return;
  const st = _csSplit;
  st.category = ($('csSplitCategory') || {}).value || '';
  st.comment = (($('csSplitComment') || {}).value || '').trim();
  st.busy = true;
  const btn = $('csSplitAddBtn');
  if (btn) { btn.disabled = true; btn.textContent = '처리 중…'; }
  try {
    const newId = await csSplitCase(Array.from(st.selected), st.category || null, st.comment || null);
    if (_csSplit !== st) return;   // 그사이 그만두었으면 화면을 건드리지 않는다
    csSplitCancel(true);
    toast('새 CS 건을 추가했습니다', 'success');
    _csPn.expanded = newId || null;
    await loadInboxCsPanel();
  } catch (e) {
    st.busy = false;
    toast(csErrorText(e), 'error');
    if (_csSplit === st) renderInboxCsPanel();
  }
}

// 그만둘지 묻기 — CS 추가 중에 다른 대화·탭·패널 닫기·메뉴를 누르면 먼저 확인하고, 그만두면 그 누름을 다시 보낸다
(function () {
  const SEL = '#inboxCampaigns, #inboxThreads, #inboxKindTabBar, .inbox-camps-fold, .inbox-cs-close, #inboxCsToggle, .admin-si, #btnOpenCsHistory, .inbox-col-camps .inbox-col-header, .inbox-col-threads .inbox-col-header, #inboxGenHead';
  let replaying = false;
  document.addEventListener('click', async (e) => {
    if (!_csSplit || replaying) return;
    const hit = e.target.closest && e.target.closest(SEL);
    if (!hit) return;
    e.preventDefault();
    e.stopPropagation();
    if (!(await showConfirm('CS 추가를 그만둘까요? 고른 글과 쓰던 내용은 사라집니다.'))) return;
    csSplitCancel();
    // 확인을 기다리는 사이 목록이 다시 그려졌으면(30초 갱신) 그 요소는 떨어져 나갔다 — 다시 누르게 안내
    if (!document.contains(e.target)) { toast('CS 추가를 그만뒀습니다. 가려던 곳을 다시 눌러 주세요'); return; }
    replaying = true;
    try { e.target.click(); } finally { replaying = false; }
  }, true);
  // 2단계에서 쓰던 항목·첫 메모를 기억(패널을 다시 그려도 남게)
  const body = document.getElementById('inboxCsBody');
  if (body) body.addEventListener('input', (e) => {
    if (!_csSplit) return;
    if (e.target.id === 'csSplitComment') _csSplit.comment = e.target.value;
    if (e.target.id === 'csSplitCategory') _csSplit.category = e.target.value;
  });
  if (body) body.addEventListener('change', (e) => { if (_csSplit && e.target.id === 'csSplitCategory') _csSplit.category = e.target.value; });
})();
