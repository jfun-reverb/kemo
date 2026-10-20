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
  return `<tr class="cs-hist-row" data-cs-case="${esc(r.id)}" onclick="csHistRowClick(${jsStr(r.id)})">
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

// 건 상세 모달은 조각 2-2(openCsCaseDetail)
function csHistOpenDetail(caseId) {
  if (typeof openCsCaseDetail === 'function') { openCsCaseDetail(caseId); return; }
  toast('건 상세는 다음 작업에서 열립니다');
}

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
