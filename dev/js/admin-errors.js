// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-errors.js
// ═════════════════════════════════════════════════════════════════
//   사용자(인플루언서) 앱 오류 로그 페인 (#adminPane-errors, 마이그레이션 165).
//   · 목록: 상태/앱/기간 필터 + 검색 + lazy-load (loadClientErrors)
//   · 상세 모달: 전체 메시지·스택·발생 정보 + 해결/무시/메모 (openClientErrorDetail)
//   · 사이드바 미해결(open) 건수 배지 (updateClientErrorBadge)
//   loadClientErrors 는 switchAdminPane(admin-core.js) loaders 가 호출 → 전역 유지.
//   상세는 표시용 마스킹된 데이터만 다룸(개인정보는 수집 단계에서 이미 마스킹).
// ═════════════════════════════════════════════════════════════════

var clientErrorsLazy = null;
const CLIENT_ERRORS_PAGE_SIZE = 50;
var _clientErrorsCache = [];   // 현재 목록 (상세 모달이 id로 조회)
var _currentClientErrorId = null;  // 상세 모달이 처리 중인 오류 id

// 상태 한국어 라벨 + 색
const CLIENT_ERR_STATUS = {
  open:     { ko: '미해결', color: '#C33',     bg: '#FFF5F5' },
  resolved: { ko: '해결됨', color: '#2D7A3E',  bg: '#E4F5E8' },
  ignored:  { ko: '무시',   color: 'var(--muted)', bg: 'var(--surface-dim)' },
};
const CLIENT_ERR_KIND_KO = { unhandled: '미처리 예외', rejection: '비동기 거부', handled: '처리된 오류' };
const CLIENT_ERR_SOURCE_KO = { influencer: '인플루언서', admin: '관리자' };

function _clientErrStatusBadge(status) {
  const s = CLIENT_ERR_STATUS[status] || CLIENT_ERR_STATUS.open;
  return `<span style="display:inline-block;background:${s.bg};color:${s.color};font-size:11px;font-weight:700;padding:2px 8px;border-radius:4px">${s.ko}</span>`;
}

async function loadClientErrors() {
  const status = $('errFilterStatus') ? $('errFilterStatus').value : 'open';
  const source = $('errFilterSource') ? $('errFilterSource').value : '';
  const days   = $('errFilterDays') ? $('errFilterDays').value : '';
  const searchQ = ($('errSearch') ? $('errSearch').value : '').trim().toLowerCase();

  const filters = {};
  if (status) filters.status = status;
  if (source) filters.source = source;
  if (days) {
    const d = new Date();
    d.setDate(d.getDate() - parseInt(days, 10));
    filters.since = d.toISOString();
  }

  let rows = await fetchClientErrors(filters);
  _clientErrorsCache = rows;
  if (searchQ) {
    rows = rows.filter(r => matchSearchTokens(searchQ, [r.message, r.error_code, r.page_hash, r.context]));
  }

  const countEl = $('errTotalCount');
  if (countEl) countEl.textContent = `총 ${rows.length}건`;

  updateClientErrorBadge();

  const body = $('errTableBody');
  if (!body) return;

  const renderRow = (r) => {
    const kindKo = CLIENT_ERR_KIND_KO[r.kind] || r.kind || '';
    const srcKo = CLIENT_ERR_SOURCE_KO[r.source] || r.source || '';
    const msgShort = (r.message || '').length > 90 ? (r.message || '').slice(0, 90) + '…' : (r.message || '');
    return `<tr data-id="${esc(r.id)}">
      <td>${_clientErrStatusBadge(r.status)}</td>
      <td style="max-width:380px">
        <div style="font-size:13px;color:var(--ink);word-break:break-word;cursor:pointer" onclick="openClientErrorDetail('${esc(r.id)}')">${esc(msgShort) || '—'}</div>
        <div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(kindKo)} · ${esc(srcKo)}${r.page_hash ? ' · ' + esc(r.page_hash) : ''}</div>
      </td>
      <td style="font-size:11px;color:var(--muted)">${r.error_code ? esc(r.error_code) : '—'}</td>
      <td style="text-align:center;font-weight:700;color:${r.occurrence_count > 10 ? 'var(--red)' : 'var(--ink)'}">${r.occurrence_count || 1}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDateTime(r.last_seen_at)}</td>
      <td><button class="btn btn-ghost btn-xs" onclick="openClientErrorDetail('${esc(r.id)}')">상세</button></td>
    </tr>`;
  };

  if (clientErrorsLazy) clientErrorsLazy.destroy();
  clientErrorsLazy = mountLazyList({
    tbody: body,
    scrollRoot: body.closest('.admin-table-wrap'),
    rows,
    renderRow,
    pageSize: CLIENT_ERRORS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:32px">최근 보고된 오류가 없습니다</td></tr>',
  });
}

// 사이드바 미해결(open) 건수 배지
async function updateClientErrorBadge() {
  const badge = $('adminErrorsBadge');
  if (!badge) return;
  const n = await fetchClientErrorOpenCount();
  if (n > 0) { badge.textContent = n > 99 ? '99+' : String(n); badge.style.display = ''; }
  else { badge.style.display = 'none'; }
}

// 상세 모달
function openClientErrorDetail(id) {
  const r = _clientErrorsCache.find(x => x.id === id);
  if (!r) { toast('오류 정보를 찾을 수 없습니다', 'warn'); return; }
  _currentClientErrorId = id;
  const kindKo = CLIENT_ERR_KIND_KO[r.kind] || r.kind || '';
  const srcKo = CLIENT_ERR_SOURCE_KO[r.source] || r.source || '';
  const body = $('clientErrorDetailBody');
  if (body) {
    body.innerHTML = `
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px">
        ${_clientErrStatusBadge(r.status)}
        <span style="font-size:12px;color:var(--muted)">${esc(kindKo)} · ${esc(srcKo)} · ${r.occurrence_count || 1}회 발생</span>
      </div>
      <div class="admin-detail-row"><div class="admin-detail-label">메시지</div><div style="word-break:break-word;color:var(--ink)">${esc(r.message) || '—'}</div></div>
      ${r.error_code ? `<div class="admin-detail-row"><div class="admin-detail-label">코드</div><div>${esc(r.error_code)}</div></div>` : ''}
      ${r.page_hash ? `<div class="admin-detail-row"><div class="admin-detail-label">발생 화면</div><div>${esc(r.page_hash)}</div></div>` : ''}
      ${r.context ? `<div class="admin-detail-row"><div class="admin-detail-label">맥락</div><div>${esc(r.context)}</div></div>` : ''}
      <div class="admin-detail-row"><div class="admin-detail-label">최초 발생</div><div>${formatDateTime(r.first_seen_at)}</div></div>
      <div class="admin-detail-row"><div class="admin-detail-label">최근 발생</div><div>${formatDateTime(r.last_seen_at)}</div></div>
      ${r.user_agent ? `<div class="admin-detail-row"><div class="admin-detail-label">브라우저</div><div style="font-size:11px;color:var(--muted);word-break:break-all">${esc(r.user_agent)}</div></div>` : ''}
      ${r.stack ? `<div class="admin-detail-row"><div class="admin-detail-label">스택</div><pre style="white-space:pre-wrap;word-break:break-word;font-size:11px;color:var(--muted);background:var(--surface-dim);padding:8px;border-radius:6px;max-height:240px;overflow:auto;margin:0">${esc(r.stack)}</pre></div>` : ''}
      ${r.resolved_by ? `<div class="admin-detail-row"><div class="admin-detail-label">처리</div><div style="font-size:12px;color:var(--muted)">${formatDateTime(r.resolved_at)}${r.resolve_note ? ' · ' + esc(r.resolve_note) : ''}</div></div>` : ''}
      <div style="margin-top:8px">
        <label style="font-size:12px;color:var(--muted);display:block;margin-bottom:4px">처리 메모 (선택)</label>
        <input type="text" id="clientErrorNote" class="admin-input" placeholder="예: 재현 확인 후 수정 완료" value="${esc(r.resolve_note || '')}" style="width:100%">
      </div>
    `;
  }
  // 상태에 따라 버튼 노출 (open → 해결/무시, 그 외 → 미해결로 되돌리기)
  const actions = $('clientErrorDetailActions');
  if (actions) {
    if (r.status === 'open') {
      actions.innerHTML = `
        <button class="btn btn-ghost" onclick="closeModal('clientErrorDetailModal')">닫기</button>
        <button class="btn btn-ghost" style="color:var(--muted)" onclick="resolveClientErrorAction('ignored')">무시</button>
        <button class="btn btn-green" onclick="resolveClientErrorAction('resolved')">해결됨</button>`;
    } else {
      actions.innerHTML = `
        <button class="btn btn-ghost" onclick="closeModal('clientErrorDetailModal')">닫기</button>
        <button class="btn btn-primary" onclick="resolveClientErrorAction('open')">미해결로 되돌리기</button>`;
    }
  }
  openModal('clientErrorDetailModal');
}

async function resolveClientErrorAction(status) {
  if (!_currentClientErrorId) return;
  const note = $('clientErrorNote') ? $('clientErrorNote').value.trim() : '';
  const ok = await resolveClientError(_currentClientErrorId, status, note);
  if (!ok) { toast('처리에 실패했습니다', 'error'); return; }
  const msgs = { resolved: '해결됨으로 처리했습니다', ignored: '무시 처리했습니다', open: '미해결로 되돌렸습니다' };
  toast(msgs[status] || '처리했습니다', status === 'resolved' ? 'success' : '');
  closeModal('clientErrorDetailModal');
  _currentClientErrorId = null;
  await refreshPane('errors');
}
