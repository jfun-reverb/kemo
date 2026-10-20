// ════════════════════════════════════════════════════════════════════
// admin-cs-history.js — CS 이력 관리 페인(#adminPane-cs-history) · 건 상세 모달 · 수기 등록 모달
//   작업표 조각 2-1~2-3(갈래 B). 공용 부품은 admin-cs-common.js, 데이터는 storage.js 「CS 이력 관리」 절
// ════════════════════════════════════════════════════════════════════

const CS_KIND_LABEL_KO = { monitor: '리뷰어', gifting: '기프팅', visit: '방문형', service: '서비스' };
const CS_ORIGIN_LABEL_KO = { backfill: '과거 이관', sheet: '시트 이관' };   // 담당자 칸 — 완료한 사람이 없을 때
const CS_HIST_PAGE_SIZE = 60;
const CS_HIST_COLS = 13;   // 표 머리 열 수 — 빈 상태 colspan 과 맞춘다

let _csHistRows = [];       // 이번 기간 전체(필터 전)
let _csHistMemo = {};       // 건 id → {total, unread}
let _csHistLazy = null;
let _csHistSeq = 0;          // 기간을 빠르게 바꿀 때 늦게 온 옛 응답이 새 결과를 덮지 않게
let _csHistMemoFailed = false;

// 분류 — 앱 건은 캠페인 모집 형식(서비스 문의는 「서비스」), 수기 건은 등록 값
function csCaseKind(r) {
  if (!r) return '';
  if (r.source === 'service_inquiry') return 'service';
  if (r.source === 'campaign_inquiry') return r.recruit_type || '';
  return r.manual_category || r.recruit_type || '';
}
function csCaseMemberName(r) {
  if (r.influencer_name) return r.influencer_name;
  if (r.manual_name) return r.manual_name;
  return (r.influencer_id || csIsManual(r)) ? '' : '삭제된 회원';
}
function csCaseMemberEmail(r) { return r.influencer_email || r.manual_email || ''; }

function _csHistSinceIso() {
  const m = Number(($('csHistSince') || {}).value || 3);
  if (!m) return null;
  const d = new Date();
  d.setMonth(d.getMonth() - m);
  return d.toISOString();
}

async function loadCsHistoryPane() {
  const tbody = $('csHistTbody');
  if (!tbody) return;
  if (!csHistoryEnabled()) {
    tbody.innerHTML = `<tr><td colspan="${CS_HIST_COLS}" style="text-align:center;color:var(--muted);padding:40px">CS 이력 관리는 아직 개발서버에서만 쓸 수 있습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = `<tr><td colspan="${CS_HIST_COLS}" style="text-align:center;color:var(--muted);padding:40px">불러오는 중…</td></tr>`;
  const seq = ++_csHistSeq;
  const from = _csHistSinceIso();
  const [rows, summary] = await Promise.all([fetchCsCases(from, null), fetchCsSummary(from, null), csLoadCategories()]);
  if (seq !== _csHistSeq) return;
  _csHistFillCategoryFilter();
  if (rows === null) {
    _csHistRows = [];
    tbody.innerHTML = `<tr><td colspan="${CS_HIST_COLS}" style="text-align:center;color:var(--red);padding:40px">CS 이력을 불러오지 못했습니다. 메시지 메뉴 권한을 확인하고 다시 열어 주세요.</td></tr>`;
    renderCsHistorySummary(null);
    return;
  }
  _csHistRows = rows;
  const memo = await fetchCsCommentSummaries(null);
  if (seq !== _csHistSeq) return;
  _csHistMemoFailed = memo === null;      // 실패를 「메모 없음」으로 그리지 않는다
  _csHistMemo = memo || {};
  renderCsHistorySummary(summary);
  renderCsHistoryTable();
}

// 항목 필터 선택지 — 미분류(과거)도 거를 수 있게 넣는다(고르는 자리가 아니라 거르는 자리)
function _csHistFillCategoryFilter() {
  const sel = $('csHistCategory');
  if (!sel) return;
  const cur = sel.value;
  sel.innerHTML = '<option value="">전체</option><option value="__none">항목 없음</option>' +
    (_csCategories || []).map(c => `<option value="${esc(c.code)}">${esc(c.name_ko)}</option>`).join('');
  sel.value = cur;
}

function _csHistFiltered() {
  const v = id => (($(id) || {}).value || '');
  const st = v('csHistStatus'), cat = v('csHistCategory'), src = v('csHistSource'), kind = v('csHistKind');
  const q = v('csHistSearch').trim().toLowerCase();
  return _csHistRows.filter(r => {
    if (st && r.status !== st) return false;
    if (cat === '__none' ? !!r.category_code : (cat && r.category_code !== cat)) return false;
    if (src && r.source !== src) return false;
    if (kind && csCaseKind(r) !== kind) return false;
    if (q && ![csCaseMemberName(r), csCaseMemberEmail(r), r.campaign_title].filter(Boolean).join(' ').toLowerCase().includes(q)) return false;
    return true;
  });
}

function renderCsHistoryTable() {
  const tbody = $('csHistTbody');
  if (!tbody) return;
  const list = _csHistFiltered();
  const cnt = $('csHistCount');
  if (cnt) cnt.textContent = `${list.length}건` + (list.length !== _csHistRows.length ? ` / 기간 안 ${_csHistRows.length}건` : '');
  if (_csHistLazy) _csHistLazy.destroy();
  _csHistLazy = mountLazyList({
    tbody,
    scrollRoot: tbody.closest('.admin-table-wrap'),
    rows: list,
    renderRow: _csHistRowHtml,
    pageSize: CS_HIST_PAGE_SIZE,
    emptyHtml: `<tr><td colspan="${CS_HIST_COLS}" style="text-align:center;color:var(--muted);padding:40px">조건에 맞는 CS 건이 없습니다</td></tr>`
  });
}

// 문의 요약 — 원문 / 한국어 번역 한 줄씩 줄여서(D-12). 고친 요약이면 「수정됨」
function _csHistSummaryCell(r) {
  if (r.personal_purged_at || (!r.summary_text && !r.summary_translated)) return '<span style="color:var(--muted)">—</span>';
  const ko = (r.summary_translated_lang === 'ko' && r.summary_translated) ? r.summary_translated : '';
  const parts = [r.summary_text, ko].filter(Boolean).map(t => esc(String(t).split('\n')[0]));
  return `<span class="cs-hist-summary">${parts.join(' / ')}</span>${r.summary_edited ? '<span class="cs-edited">수정됨</span>' : ''}`;
}

// 메모 칸(D-20) — 오리엔시트 메모 칸 모양. 🔴 회색(메모 없음)이어도 누르면 건 상세(S-10)
function _csHistMemoCell(r) {
  const m = _csHistMemo[r.id] || { total: 0, unread: 0 };
  const tip = _csHistMemoFailed ? '메모 수를 불러오지 못했습니다 — 눌러서 건 상세 열기'
    : m.total ? `메모 ${m.total}개${m.unread ? ` · 안 읽음 ${m.unread}개` : ''}` : '메모 없음 — 눌러서 건 상세 열기';
  return `<button type="button" class="cs-memo-cell" title="${esc(tip)}" onclick="event.stopPropagation();csHistOpenDetail(${jsStr(r.id)})">`
    + `<span class="material-icons-round notranslate" translate="no" style="font-size:19px;color:${m.total ? '#161618' : '#dcdce0'}">sticky_note_2</span>`
    + (m.unread ? `<span class="cs-memo-cell-dot">${m.unread > 99 ? '99+' : m.unread}</span>` : '')
    + (_csHistMemoFailed ? '<span class="cs-memo-cell-dot cs-memo-cell-err">!</span>' : '')
    + '</button>';
}

// 같은 대화 칸 — 재문의면 이전 건 연결, 아니면 같은 대화 건 수(1 이면 「—」)
function _csHistSameCell(r) {
  if (r.previous_case_id) {
    return `<button type="button" class="cs-link" title="이전 건 #${esc(String(r.previous_case_no || ''))} 열기" onclick="event.stopPropagation();csHistOpenDetail(${jsStr(r.previous_case_id)})">재문의</button>`;
  }
  return Number(r.same_conversation_count) > 1 ? esc(String(r.same_conversation_count)) : '<span style="color:var(--muted)">—</span>';
}

function _csHistRowHtml(r) {
  // 담당자 = 완료한 사람. 비어 있으면 만들어진 경위가 이관이면 그 이름, 실시간이면 「—」
  const who = r.completed_by_name ? esc(r.completed_by_name)
    : `<span style="color:var(--muted)">${esc(CS_ORIGIN_LABEL_KO[r.origin] || '—')}</span>`;
  const at = r.time_unknown ? formatDate(r.received_at) : formatDateTime(r.received_at);
  return `<tr class="cs-hist-row" data-id="${esc(r.id)}" onclick="csHistRowClick(${jsStr(r.id)})">
    <td>${esc(String(r.case_no))}</td>
    <td style="white-space:nowrap">${esc(at)}</td>
    <td><span class="cs-source-pill">${esc(CS_SOURCE_LABEL_KO[r.source] || r.source)}</span></td>
    <td>${esc(CS_KIND_LABEL_KO[csCaseKind(r)] || '—')}</td>
    <td class="cs-hist-ellipsis" title="${esc(r.campaign_title || '')}">${r.source_deleted ? '<span style="color:var(--muted)">원본 대화 삭제됨</span>' : esc(r.campaign_title || '—')}</td>
    <td class="cs-hist-ellipsis">${esc(csCaseMemberName(r) || '—')}</td>
    <td class="cs-hist-ellipsis">${esc(csCaseMemberEmail(r) || '—')}</td>
    <td>${r.category_code ? esc(csCategoryLabel(r.category_code)) : '<span style="color:var(--muted)">—</span>'}</td>
    <td class="cs-hist-summary-td" onclick="event.stopPropagation();csHistOpenDetail(${jsStr(r.id)})">${_csHistSummaryCell(r)}</td>
    <td>${csStatusBadgeHtml(r.status)}</td>
    <td style="white-space:nowrap">${who}</td>
    <td>${_csHistSameCell(r)}</td>
    <td>${_csHistMemoCell(r)}</td>
  </tr>`;
}

// 행 누름 — 앱 건(원본 대화가 있으면) → 그 대화 / 수기 건·원본 삭제 건 → 건 상세 모달
function csHistRowClick(caseId) {
  const r = _csHistRows.find(x => x.id === caseId);
  if (!r) return;
  if (csIsManual(r) || r.source_deleted) { csHistOpenDetail(caseId); return; }
  csHistOpenConversation(r);
}

// 메시지 화면의 그 대화로 — 메시지 화면 공개 함수·상태만 쓴다(admin-messaging.js 는 고치지 않는다 — 작업표 공유 지점)
//   🔴 순서: 메시지 화면 로드(loadMessagesInbox)가 **끝난 뒤** 탭·대화를 연다 — 먼저 열면 로드가 선택을 지운다
//   서비스 문의: 대화가 목록 밖(기간·닫힘)이어도 열리게 회원을 먼저 넣는다(openGeneralInboxThread 는 목록에 없으면 그 값을 쓴다)
//   캠페인 문의: 캠페인을 골라 두지 않으면 화면이 캠페인 목록 단계로 돌아간다(updateInboxStage)
async function csHistOpenConversation(r) {
  await switchAdminPane('messages');
  if (r.general_thread_id) {
    switchInboxTab('general');                    // 안에서 switchInboxKind 가 선택을 비운다 — 그 뒤에 넣는다
    _admMsgGeneralId = r.influencer_id || null;
    await openGeneralInboxThread(r.general_thread_id);
  } else if (r.application_id) {
    switchInboxTab('app');
    _inboxSelectedCampaign = r.campaign_id || null;
    renderInboxCampaignList();
    renderInboxThreadList();
    await openInboxThread(r.application_id);
  }
}

function csHistOpenDetail(caseId) { openCsCaseDetail(caseId); }

// 수기 등록·편집 모달은 조각 2-3
function openCsManualModal(caseId) {
  if (typeof openCsManualForm === 'function') { openCsManualForm(caseId); return; }
  toast('수기 등록은 다음 작업에서 열립니다');
}

// ── 요약 넷(a10-08) — 항목별 건수 · 응답 시간 · 해결 시간 · 진행현황·출처 ──────────
function renderCsHistorySummary(sm) {
  const el = $('csHistSummary');
  if (!el) return;
  if (!sm) { el.innerHTML = '<div class="cs-summary-card" style="grid-column:1/-1;color:var(--red)">요약을 불러오지 못했습니다</div>'; return; }
  el.innerHTML = _csSumCategoryCard(sm) + _csSumTimeCard(sm, 'response') + _csSumTimeCard(sm, 'resolve') + _csSumStatusCard(sm);
}

function _csSumCategoryCard(sm) {
  const by = sm.by_category || {};
  // 항목 전부(끈 것 제외 · 건이 있으면 보임) + 항목 없음 — 많은 순
  const codes = new Set((_csCategories || []).filter(c => c.active).map(c => c.code));
  Object.keys(by).forEach(k => codes.add(k));
  const rows = Array.from(codes).map(k => ({ k, n: Number(by[k] || 0) }))
    .sort((a, b) => (a.k === CS_LEGACY_CATEGORY) - (b.k === CS_LEGACY_CATEGORY) || (a.k === '') - (b.k === '') || b.n - a.n);
  const max = Math.max(1, ...rows.map(r => r.n));
  const bars = rows.map(r => {
    const label = r.k === '' ? '항목 없음(진행 중)' : csCategoryLabel(r.k);
    const grey = r.k === '' || r.k === CS_LEGACY_CATEGORY;
    return `<div class="cs-bar-row"><span class="cs-bar-label">${esc(label)}</span>
      <span class="cs-bar-track"><span class="cs-bar${grey ? ' cs-bar-grey' : ''}" style="width:${r.n ? Math.max(2, Math.round(r.n / max * 100)) : 0}%"></span></span>
      <span class="cs-bar-n">${r.n}</span></div>`;
  }).join('');
  return `<div class="cs-summary-card"><div class="cs-summary-title">항목별 건수 · 기간 안 ${Number(sm.total || 0)}건</div>${bars}</div>`;
}

function _csSumTimeCard(sm, kind) {
  const t = sm[kind] || {};
  const title = kind === 'response' ? '응답 시간 · 접수 → 첫 답장' : '해결 시간 · 접수 → CS 건 완료';
  const avgKey = kind + '_avg_sec';
  const per = Object.entries(sm.by_category_time || {})
    .filter(([k, v]) => k && v && v[avgKey] != null)
    .map(([k, v]) => `${csCategoryLabel(k)} ${csFormatDuration(v[avgKey])}`).join(' · ');
  const note = kind === 'response' ? '「시간 미상」·첫 답장 없는 건 제외' : '진행 중·「시간 미상」 건 제외';
  return `<div class="cs-summary-card"><div class="cs-summary-title">${title}</div>
    <div class="cs-summary-big">평균 ${esc(csFormatDuration(t.avg_sec))}</div>
    <div class="cs-summary-mid">중앙값 ${esc(csFormatDuration(t.median_sec))}</div>
    ${per ? `<div class="cs-summary-note">항목별 평균: ${esc(per)}</div>` : ''}
    <div class="cs-summary-note">${note} · 계산한 건 ${Number(t.count || 0)}건</div></div>`;
}

function _csSumStatusCard(sm) {
  const st = sm.by_status || {}, src = sm.by_source || {};
  const badges = ['needs_check', 'in_progress', 'done'].map(s =>
    csStatusBadgeHtml(s).replace('</span>', ` ${Number(st[s] || 0)}</span>`)).join(' ');
  const srcs = Object.keys(CS_SOURCE_LABEL_KO).map(k => `${CS_SOURCE_LABEL_KO[k]} ${Number(src[k] || 0)}`).join(' · ');
  return `<div class="cs-summary-card"><div class="cs-summary-title">진행현황 · 출처</div>
    <div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px">${badges}</div>
    <div class="cs-summary-note">${esc(srcs)}</div></div>`;
}

// 진입 단추(메시지 제목 줄) — 개발서버에서만. 스크립트가 본문 끝에 붙으므로 이 시점에 단추가 있다
(function () {
  const b = document.getElementById('btnOpenCsHistory');
  if (b && csHistoryEnabled()) b.style.display = 'inline-flex';
})();

// ════════════════════════════════════════════════════════════════════
// 건 상세 모달(#csCaseDetailModal — 작업표 2-2 · 피그마 a10-08a)
//   왼쪽 = CS 관리(정보 · 문의 요약 · 완료 양식 / 완료한 건은 저장 값 + 「다시 열기」), 오른쪽 = 확인 필요 메모
//   순서: 조회 → 그리기 → 메모 읽음(읽음 결과로 다시 그리지 않는다 — 오리엔시트 상세 선례)
//   진행현황 바꾸기(진행중 ↔ 확인필요)는 완료 양식과 별개 — 누르는 즉시 저장(D-20)
// ════════════════════════════════════════════════════════════════════
let _csCd = null;   // {row, lastReply, editingSummary}
let _csCdSeq = 0;   // 모달을 연 채 다른 건을 빠르게 열 때(재문의 연결) 늦게 온 옛 응답이 새 건 화면을 덮지 않게

function ensureCsCaseDetailModal() {
  if ($('csCaseDetailModal')) return;
  const el = document.createElement('div');
  el.className = 'modal-overlay';
  el.id = 'csCaseDetailModal';
  el.innerHTML = `<div class="modal cs-cd-modal">
    <div class="modal-header"><h2 id="csCdTitle">CS 건</h2>
      <button type="button" class="modal-close-btn" onclick="closeModal('csCaseDetailModal')" aria-label="닫기"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
    <div class="cs-cd-body">
      <div class="cs-cd-left"><div id="csCdLeft"></div><div id="csCdFoot" class="cs-cd-foot"></div></div>
      <div class="cs-cd-right">
        <div class="cs-cd-memo-title"><span class="material-icons-round notranslate" translate="no" style="font-size:17px">sticky_note_2</span>
          확인 필요 메모 <span class="cs-cd-memo-sub">· 관리자만 보입니다</span></div>
        <div id="csCdUnreadNote" class="cs-cd-unread" style="display:none"></div>
        <div id="csCdMemo"></div>
      </div>
    </div></div>`;
  document.body.appendChild(el);
}

async function openCsCaseDetail(caseId) {
  if (!caseId) return;
  const my = ++_csCdSeq;
  _csCd = null;                     // 열리는 동안 앞 건의 단추가 앞 건 version 으로 쓰지 않게
  ensureCsCaseDetailModal();
  openModal('csCaseDetailModal');
  $('csCdTitle').textContent = 'CS 건';
  $('csCdLeft').innerHTML = '<div class="cs-memo-loading">불러오는 중…</div>';
  $('csCdFoot').innerHTML = '';
  $('csCdMemo').innerHTML = '';
  const [row] = await Promise.all([fetchCsCase(caseId), csLoadCategories()]);
  if (my !== _csCdSeq) return;
  if (row === null) { $('csCdLeft').innerHTML = '<div class="cs-memo-error">CS 건을 불러오지 못했습니다. 다시 열어 주세요.</div>'; return; }
  if (row === false) { $('csCdLeft').innerHTML = '<div class="cs-memo-error">CS 건을 찾을 수 없습니다.</div>'; return; }
  const lastReply = (row.status !== 'done' && csNeedsStaffReplyPrefill(row)) ? await fetchCsLastStaffReply(row) : null;
  if (my !== _csCdSeq) return;
  _csCd = { row, lastReply, editingSummary: false, busy: false };
  _csCdRender();
  await _csCdMountMemo(true, my);
}

// 메모 — 연 순간 그 건 메모 전부 읽음(D-20). 「새」는 연 순간의 상태로 남긴다
//   ⚠️ csMountComments 는 조회 → 그리기 → 읽음을 한 번에 돈다 — 그 사이에 다른 건으로 바뀌는 것은 앞뒤에서만 막는다
async function _csCdMountMemo(markRead, my) {
  const r = _csCd && _csCd.row;
  if (!r) return;
  const sum = await fetchCsCommentSummaries([r.id]);
  if (my !== _csCdSeq) return;
  const unread = (sum && sum[r.id] && sum[r.id].unread) || 0;
  const note = $('csCdUnreadNote');
  if (note) { note.style.display = unread ? '' : 'none'; note.textContent = `아직 안 읽은 메모 ${unread}개 — 이 창을 열면 읽음이 됩니다`; }
  await csMountComments(r.id, $('csCdMemo'), { purged: !!r.personal_purged_at, markRead, onChanged: () => csHistPatchMemo(r.id) });
  if (markRead && my === _csCdSeq) csHistPatchMemo(r.id);
}

// 표의 그 행 메모 칸만 다시 계산(모달 뒤 표 — 전체를 다시 그리면 스크롤이 맨 위로 간다)
async function csHistPatchMemo(caseId) {
  const sum = await fetchCsCommentSummaries([caseId]);
  if (!sum) return;
  _csHistMemo[caseId] = sum[caseId] || { total: 0, unread: 0 };
  const row = _csHistRows.find(x => x.id === caseId);
  if (row && _csHistLazy) _csHistLazy.patchRow(caseId, _csHistRowHtml(row));
}

function _csCdRender() {
  const r = _csCd.row;
  $('csCdTitle').innerHTML = `CS 건 #${esc(String(r.case_no))} ${csStatusBadgeHtml(r.status)}`
    + (r.previous_case_id ? ' <span class="cs-tag">재문의</span>' : '');
  $('csCdLeft').innerHTML = _csCdHeadHtml(r) + _csCdSummaryHtml(r) + _csCdManualHtml(r)
    + (r.personal_purged_at ? '<div class="cs-cd-purged">개인정보가 정리된 건입니다. 항목·시각만 남아 있고 고칠 수 없습니다.</div>'
      : (r.status === 'done' ? _csCdDoneHtml(r) : _csCdOpenHtml(r)));
  $('csCdFoot').innerHTML = _csCdFootHtml(r);
}

// 맨 위 — 캠페인(모집 형식 배지) · 회원 · 정보 3칸(분류 배지가 없으면 「분류」 칸을 더해 4칸 — D-20)
function _csCdHeadHtml(r) {
  const kind = csCaseKind(r);
  const hasBadge = !!(r.campaign_title && r.recruit_type);
  const camp = r.campaign_title
    ? `${hasBadge ? `<span class="badge badge-blue" style="font-size:10px;margin-right:6px">${esc(CS_KIND_LABEL_KO[r.recruit_type] || r.recruit_type)}</span>` : ''}<strong>${esc(r.campaign_title)}</strong>`
    : (r.source_deleted ? '<span style="color:var(--muted)">원본 대화 삭제됨</span>' : '<span style="color:var(--muted)">—</span>');
  const name = csCaseMemberName(r), mail = csCaseMemberEmail(r);
  const at = iso => iso ? (r.time_unknown ? formatDate(iso) : formatDateTime(iso)) : '—';
  const reply = r.first_reply_at ? `${formatDateTime(r.first_reply_at)} (${csDurationBetween(r.received_at, r.first_reply_at, r.time_unknown)})` : '—';
  const cells = [['출처', CS_SOURCE_LABEL_KO[r.source] || r.source], ['접수', at(r.received_at)], ['첫 답장', reply]];
  if (!hasBadge) cells.push(['분류', CS_KIND_LABEL_KO[kind] || '—']);
  return `<div class="cs-cd-label">캠페인</div><div class="cs-cd-camp">${camp}</div>
    <div class="cs-cd-label">회원</div><div class="cs-cd-member">${esc(name || '—')}${mail ? ` · ${esc(mail)}` : ''}</div>
    <div class="cs-cd-info" style="grid-template-columns:repeat(${cells.length},1fr)">${cells.map(([k, v]) =>
      `<div><div class="cs-cd-label">${k}</div><div class="cs-cd-val">${esc(v)}</div></div>`).join('')}</div>`;
}

// 문의 요약 — 원문 + 번역 · 「요약 수정」(D-12)
function _csCdSummaryHtml(r) {
  if (r.personal_purged_at) return '';
  const head = `<div class="cs-cd-sec-title">문의 요약 <span class="cs-cd-sec-sub">그 건을 연 회원 글 · 고칠 수 있음</span>
    ${r.summary_edited ? '<span class="cs-edited">수정됨</span>' : ''}
    ${_csCd.editingSummary ? '' : `<button type="button" class="btn btn-ghost btn-xs" style="margin-left:auto" onclick="csCdEditSummary(true)">요약 수정</button>`}</div>`;
  if (_csCd.editingSummary) {
    return head + `<textarea id="csCdSummaryInput" class="form-input" rows="3">${esc(r.summary_text || '')}</textarea>
      <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:6px">
        <button type="button" class="btn btn-ghost btn-sm" onclick="csCdEditSummary(false)">취소</button>
        <button type="button" class="btn btn-primary btn-sm" onclick="csCdSaveSummary()">요약 저장</button></div>`;
  }
  const tr = r.summary_translated ? `<div class="cs-memo-trans"><span class="cs-memo-trans-tag">번역</span>${esc(r.summary_translated)}</div>` : '';
  return head + `<div class="cs-cd-box"><div class="cs-memo-text">${esc(r.summary_text || '—')}</div>${tr}</div>`;
}

// 수기 건 — 등록 때 적은 문의·대응 내용(일·한)을 그대로 보여 준다(고치기는 「편집」)
function _csCdManualHtml(r) {
  if (!csIsManual(r) || r.personal_purged_at) return '';
  const pair = (label, ko, ja) => (ko || ja) ? `<div class="cs-cd-sec-title">${label}</div><div class="cs-cd-box">
    ${ko ? `<div class="cs-memo-text"><span class="cs-memo-trans-tag">한국어</span>${esc(ko)}</div>` : ''}
    ${ja ? `<div class="cs-memo-text"><span class="cs-memo-trans-tag">일본어</span>${esc(ja)}</div>` : ''}</div>` : '';
  return pair('문의 내용', r.manual_inquiry_ko, r.manual_inquiry_ja) + pair('대응 내용', r.manual_response_ko, r.manual_response_ja);
}

// 열린 건 — 완료 양식 + 진행현황 바꾸기(별개, 즉시 저장)
function _csCdOpenHtml(r) {
  const seg = ['in_progress', 'needs_check'].map(s =>
    `<button type="button" class="cs-seg${r.status === s ? ' on' : ''}" onclick="csCdSetStatus('${s}')"${r.status === s ? ' aria-pressed="true"' : ''}>${CS_STATUS_LABEL_KO[s]}</button>`).join('');
  const lr = _csCd.lastReply;
  const hint = (!r.response_body && !csIsManual(r) && lr && lr.body)
    ? `<div class="cs-summary-note">마지막 운영팀 답장(${esc(formatDateTime(lr.created_at))})으로 미리 채웠습니다 · 짧게 끝났으면 「대화 열기」로 대화를 보며 고치세요 · 어느 언어로 써도 자동 번역</div>` : '';
  return `<div class="cs-cd-complete">
    <div class="cs-cd-complete-head"><span class="material-icons-round notranslate" translate="no" style="font-size:17px">task_alt</span>
      CS 건 완료 <span class="cs-cd-sec-sub">항목·대응 안내 내용을 채워 저장하면 완료</span>
      <span style="margin-left:auto;display:flex;align-items:center;gap:6px"><span class="cs-field-label">진행현황</span><span class="cs-seg-wrap">${seg}</span></span></div>
    ${csCompleteFormHtml(r, csResponsePrefill(r, lr), 'csCd')}${hint}</div>`;
}

// 완료한 건 — 저장 값 + 해결 시간 + 완료한 사람 · 「다시 열기」는 바닥 줄
function _csCdDoneHtml(r) {
  const tr = r.response_translated ? `<div class="cs-memo-trans"><span class="cs-memo-trans-tag">번역</span>${esc(r.response_translated)}</div>` : '';
  return `<div class="cs-cd-complete cs-cd-done">
    <div class="cs-cd-info" style="grid-template-columns:repeat(3,1fr)">
      <div><div class="cs-cd-label">항목</div><div class="cs-cd-val">${esc(csCategoryLabel(r.category_code) || '—')}</div></div>
      <div><div class="cs-cd-label">완료 일시 (해결 시간)</div><div class="cs-cd-val">${esc(r.completed_at ? formatDateTime(r.completed_at) : '—')} (${esc(csDurationBetween(r.received_at, r.completed_at, r.time_unknown))})</div></div>
      <div><div class="cs-cd-label">완료한 사람</div><div class="cs-cd-val">${esc(r.completed_by_name || CS_ORIGIN_LABEL_KO[r.origin] || '—')}</div></div></div>
    <div class="cs-cd-label" style="margin-top:8px">대응 안내 내용</div>
    <div class="cs-cd-box"><div class="cs-memo-text">${esc(r.response_body || '—')}</div>${tr}</div></div>`;
}

function _csCdFootHtml(r) {
  const left = r.personal_purged_at ? '' : csIsManual(r)
    ? `<button type="button" class="btn btn-ghost btn-sm" onclick="csCdEdit()">편집</button>`
    : (r.source_deleted ? '' : `<button type="button" class="btn btn-ghost btn-sm" onclick="csCdOpenConversation()">대화 열기 →</button>`);
  const purged = !!r.personal_purged_at;
  const right = purged ? '' : (r.status === 'done'
    ? `<button type="button" class="btn btn-ghost btn-sm" onclick="csCdReopen()">다시 열기</button>`
    : `<button type="button" id="csCdSaveBtn" class="btn btn-primary btn-sm cs-btn-complete" onclick="csCdComplete()">완료 저장</button>`);
  return `<div>${left}</div><div style="display:flex;gap:6px"><button type="button" class="btn btn-ghost btn-sm" onclick="closeModal('csCaseDetailModal')">닫기</button>${right}</div>`;
}

// 저장 뒤 — 그 건을 다시 읽어 그리고 표를 다시 그린다.
//   🔴 쓰던 완료 양식·요약 수정 칸은 늘 되살린다(진행현황 바꾸기는 양식과 독립 — D-20). 완료한 건은 양식이 없어 건너뛴다
//   keepSummaryEdit 이면 요약 수정 칸을 연 채로 둔다(요약 저장이 충돌로 실패했을 때)
async function _csCdReload(keepSummaryEdit) {
  if (!_csCd) return;
  const my = _csCdSeq, id = _csCd.row.id;
  const kept = { cat: ($('csCdCategory') || {}).value, resp: ($('csCdResponse') || {}).value,
    at: ($('csCdCompletedAt') || {}).value, sum: ($('csCdSummaryInput') || {}).value };
  const row = await fetchCsCase(id);
  if (my !== _csCdSeq || !_csCd || _csCd.row.id !== id) return;
  if (!row) {
    // 옛 version 으로 다시 그리면 다음 저장이 가짜 충돌이 된다 — 닫고 다시 열게 한다
    toast('저장했지만 최신 내용을 다시 불러오지 못했습니다. 창을 닫고 다시 열어 주세요', 'error');
    $('csCdFoot').innerHTML = `<div></div><button type="button" class="btn btn-ghost btn-sm" onclick="closeModal('csCaseDetailModal')">닫기</button>`;
    return;
  }
  _csCd.row = row;
  _csCd.editingSummary = !!keepSummaryEdit;
  _csCdRender();
  if ($('csCdCategory')) {
    if (kept.cat) $('csCdCategory').value = kept.cat;
    if (kept.resp != null) $('csCdResponse').value = kept.resp;
    if (kept.at && $('csCdCompletedAt')) $('csCdCompletedAt').value = kept.at;
  }
  if (keepSummaryEdit && kept.sum != null && $('csCdSummaryInput')) $('csCdSummaryInput').value = kept.sum;
  await refreshPane('cs-history');
}

// 쓰기 공용 — 연타 잠금 · 실패하면 문구 토스트 · 동시 저장 충돌이면 최신으로 다시 읽고 입력값은 남긴다
async function _csCdWrite(fn, okMsg) {
  if (!_csCd || _csCd.busy) return false;
  _csCd.busy = true;
  try {
    await fn();
    if (okMsg) toast(okMsg, 'success');
    _csCd.busy = false;
    await _csCdReload(false);
    return true;
  } catch (e) {
    if (_csCd) _csCd.busy = false;
    toast(csErrorText(e), 'error');
    if (csErrorCode(e) === 'version_conflict') await _csCdReload(!!(_csCd && _csCd.editingSummary));
    return false;
  }
}

function csCdEditSummary(on) {
  if (!_csCd) return;
  _csCd.editingSummary = !!on;
  _csCdRender();
  if (on && $('csCdSummaryInput')) $('csCdSummaryInput').focus();
}
async function csCdSaveSummary() {
  const r = _csCd && _csCd.row;
  const v = (($('csCdSummaryInput') || {}).value || '').trim();
  if (!r) return;
  if (!v) { toast(CS_ERROR_TEXT_KO.summary_required, 'error'); return; }
  await _csCdWrite(() => csUpdateCaseSummary(r.id, r.version, v), '문의 요약을 고쳤습니다');
}

async function csCdSetStatus(status) {
  const r = _csCd && _csCd.row;
  if (!r || r.status === status) return;
  await _csCdWrite(() => csSetCaseStatus(r.id, r.version, status), `진행현황을 「${CS_STATUS_LABEL_KO[status]}」(으)로 바꿨습니다`);
}

// 완료 저장 — 빈 칸은 빨갛게 표시하고 저장 안 함(D-17 · a10-07a). 저장 중엔 단추 잠금
async function csCdComplete() {
  const r = _csCd && _csCd.row;
  if (!r) return;
  const f = csReadCompleteForm(r, 'csCd');
  if (!f.ok) { toast('빨갛게 표시된 칸을 채워 주세요', 'error'); return; }
  const btn = $('csCdSaveBtn');
  if (btn) { btn.disabled = true; btn.textContent = '처리 중…'; }
  const ok = await _csCdWrite(() => csCompleteCase(r.id, r.version, f.category, f.response, f.completedAt), 'CS 건을 완료했습니다');
  if (!ok && $('csCdSaveBtn')) { $('csCdSaveBtn').disabled = false; $('csCdSaveBtn').textContent = '완료 저장'; }
}

async function csCdReopen() {
  const r = _csCd && _csCd.row;
  if (!r) return;
  const ok = await showConfirm('이 CS 건을 다시 열까요? 진행현황이 「진행중」으로 돌아가고, 다시 완료할 때 해결 시간이 새로 계산됩니다.');
  if (!ok) return;
  await _csCdWrite(() => csReopenCase(r.id, r.version), 'CS 건을 다시 열었습니다');
}

function csCdOpenConversation() {
  const r = _csCd && _csCd.row;
  if (!r) return;
  closeModal('csCaseDetailModal');
  csHistOpenConversation(r);
}

// 수기 건 「편집」 — 편집 모달은 조각 2-3
function csCdEdit() {
  const r = _csCd && _csCd.row;
  if (!r) return;
  openCsManualModal(r.id);
}
