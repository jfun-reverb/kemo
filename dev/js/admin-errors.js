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

// 「정상 거부」 배지 (마이그레이션 308) — 마감 지남·정원 초과·중복 응모처럼 **결함이 아닌**
//   서버의 의도적 거절. 기록은 남기되(거절이 갑자기 늘어나는 것도 신호다) 진짜 결함과
//   눈으로 갈라 볼 수 있게 표시한다. 사이드바 배지 숫자에는 포함되지 않는다.
function _clientErrExpectedBadge(r) {
  if (!r || !r.is_expected) return '';
  return `<span style="display:inline-block;background:var(--surface-dim);color:var(--muted);font-size:10px;font-weight:700;padding:1px 6px;border-radius:4px;margin-left:4px">정상 거부</span>`;
}

async function loadClientErrors() {
  const status = $('errFilterStatus') ? $('errFilterStatus').value : 'open';
  const source = $('errFilterSource') ? $('errFilterSource').value : '';
  const days   = $('errFilterDays') ? $('errFilterDays').value : '';
  const searchQ = ($('errSearch') ? $('errSearch').value : '').trim().toLowerCase();

  // 「종류」 필터 — 기본은 「예상 못 한 오류만」(빈 값 = 전체). 정상 거부가 목록을 채우면
  //   진짜 결함이 묻히므로, 처음 화면은 결함만 보이게 둔다.
  const expected = $('errFilterExpected') ? $('errFilterExpected').value : 'real';

  const filters = {};
  if (status) filters.status = status;
  if (source) filters.source = source;
  if (expected === 'real')     filters.expected = false;
  else if (expected === 'expected') filters.expected = true;
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
        <div style="font-size:13px;color:var(--ink);word-break:break-word;cursor:pointer" onclick="openClientErrorDetail('${esc(r.id)}')">${esc(msgShort) || '—'}${_clientErrExpectedBadge(r)}</div>
        <div style="font-size:10px;color:var(--muted);margin-top:2px">${r.context ? '<b>' + esc(r.context) + '</b> · ' : ''}${esc(kindKo)} · ${esc(srcKo)}${r.page_hash ? ' · ' + esc(r.page_hash) : ''}</div>
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

// 사이드바 오류 배지 클릭 → 다른 필터 초기화 후 「미해결(open)」만 (기준: openDelivPendingReview)
function openErrorsOpen() {
  const st = document.getElementById('errFilterStatus'); if (st) st.value = 'open';
  const src = document.getElementById('errFilterSource'); if (src) src.value = '';
  const dys = document.getElementById('errFilterDays'); if (dys) dys.value = '';
  // 배지 숫자는 「예상 못 한 오류」만 센다 — 눌러서 열리는 목록도 같은 기준이어야
  // 「배지 3인데 목록은 12건」 같은 어긋남이 안 생긴다.
  const exp = document.getElementById('errFilterExpected'); if (exp) exp.value = 'real';
  const sch = document.getElementById('errSearch'); if (sch) sch.value = '';
  if (typeof navAdminPaneReload === 'function') navAdminPaneReload('errors');
  else loadClientErrors();
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
        ${_clientErrStatusBadge(r.status)}${_clientErrExpectedBadge(r)}
        <span style="font-size:12px;color:var(--muted)">${esc(kindKo)} · ${esc(srcKo)} · ${r.occurrence_count || 1}회 발생</span>
      </div>
      ${r.is_expected ? `<div style="font-size:12px;color:var(--muted);background:var(--surface-dim);padding:8px 10px;border-radius:6px;margin-bottom:10px">서버가 <b>의도적으로 거절</b>한 건입니다(마감 지남·정원 초과·중복 등). 결함이 아니므로 조치는 필요 없지만, 같은 거절이 갑자기 늘면 화면 안내가 부족하다는 신호일 수 있습니다.</div>` : ''}
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

// ══════════════════════════════════════════════════════════════════
// 「조용히 죽는 관리자 화면」 감지 결과 표시 (마이그레이션 334·335)
//
// ▶ 왜 이 화면인가
//   접근 허가에 막힌 조회는 **오류가 아니라 빈 결과**라 오류 로그에 한 줄도 안 남는다.
//   2026-08-07 사고가 그래서 11일간 안 보였다. 「앱이 조용히 실패한 것」을 모아 보는
//   자리가 여기라, 성격이 가장 가깝다(사양서 §5 ③ 사용자 결정).
//
// ▶ 표시 규칙은 채널 어긋남 경보(admin-core.js)와 같다 — 부팅 시 1회 조회 ·
//   사이드바 아이콘 교체 · **0건이면 아무것도 안 그림** · 드래그 가능 모달.
// ══════════════════════════════════════════════════════════════════

// null = 아직 조회 안 함 / [] = 막힌 표 없음.
// ⚠️ 이 둘을 합치면 안 된다 — 조회 실패를 「이상 없음」으로 그리는 순간 이 장치가 죽는다.
let _blockedTableRows = null;

// 띄워둔 채 조치를 따라갈 수 있게 드래그·크기 조정 대상으로 등록.
//   ⚠️ 목록 자체(admin-core.js)는 안 건드린다 — 그 파일은 여러 기능이 몰리는 자리라
//      여기서 add 로 얹는다(admin-core.js 가 먼저 읽히므로 이 시점에 이미 있다).
if (typeof DRAGGABLE_ADMIN_MODALS !== 'undefined') DRAGGABLE_ADMIN_MODALS.add('blockedTablesModal');

// 조회 자체가 실패했나. ⚠️ 실패를 「막힌 표 없음」으로 그리면 **이 장치가 막으려던
//   실패를 장치 자신이 재현한다** — 감지가 죽은 것과 이상이 없는 것이 화면에서 같아진다.
let _blockedTableFetchFailed = false;

async function refreshBlockedTableIndicators() {
  const rows = await fetchBlockedAdminTables();
  if (rows === null) {
    // 조회 실패 — 이전 결과를 지우지 않는다(있었다면 계속 보여준다).
    _blockedTableFetchFailed = true;
  } else {
    _blockedTableFetchFailed = false;
    _blockedTableRows = rows;
  }
  applyBlockedTableIndicators();
}

// 캐시된 결과로 표시만 갱신한다(재조회 없음).
function applyBlockedTableIndicators() {
  const rows = _blockedTableRows || [];
  const failed = _blockedTableFetchFailed;
  // 실패했으면 결과가 0건이어도 「이상 없음」으로 그리지 않는다.
  const has = rows.length > 0 || failed;
  const severe = rows.some(function(r) { return r.grade === 'A'; });

  // 사이드바 — 아이콘 자체를 경고 모양으로 바꾼다.
  //   ⚠️ 접힌 사이드바에서는 아이콘만 보이므로 옆에 표시를 붙이면 안 보인다.
  //   ⚠️ 원래 아이콘은 dataset 에 보관 — 하드코딩하면 나중에 메뉴 아이콘을 바꿀 때 stale.
  const item = document.getElementById('adminErrorsSi');
  if (item) {
    const icon = item.querySelector('.si-icon');
    if (icon) {
      if (!icon.dataset.baseIcon) icon.dataset.baseIcon = (icon.textContent || 'bug_report').trim();
      if (has) {
        icon.textContent = failed ? 'help_outline' : 'report_problem';
        icon.style.color = failed ? '#6B7280' : (severe ? '#C33' : '#B8741A');
        item.title = failed
          ? '막힌 표를 확인하지 못했습니다 — 감지 자체가 실패한 상태입니다'
          : `관리자가 못 읽게 된 표 ${rows.length}건 — 이 화면에서 조치 방법을 볼 수 있습니다`;
      } else {
        icon.textContent = icon.dataset.baseIcon;
        icon.style.color = '';
        item.title = '';
      }
    }
  }

  // 페인 제목 옆 버튼 — 0건이면 버튼째 감춘다.
  const btn = document.getElementById('blockedTablesBtn');
  if (!btn) return;
  btn.style.display = has ? 'inline-flex' : 'none';
  if (!has) return;
  if (failed) {
    btn.style.background  = '#F3F4F6';
    btn.style.borderColor = '#9CA3AF';
    btn.style.color       = '#374151';
    btn.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">help_outline</span> 확인 실패';
    return;
  }
  btn.style.background   = severe ? '#FFF5F5' : '#FEF3C7';
  btn.style.borderColor  = severe ? '#C33'    : '#FBBF24';
  btn.style.color        = severe ? '#C33'    : '#92400E';
  btn.innerHTML = `<span class="material-icons-round notranslate" translate="no" style="font-size:15px">report_problem</span> 못 읽는 표 ${rows.length}건`;
}

async function openBlockedTableModal() {
  const body = document.getElementById('blockedTablesModalBody');
  const overlay = document.getElementById('blockedTablesModal');
  if (!body || !overlay) return;
  overlay.classList.add('open');
  if (_blockedTableRows === null) {
    body.innerHTML = '<div style="padding:16px;text-align:center;color:var(--muted);font-size:13px">확인 중…</div>';
    await refreshBlockedTableIndicators();
  }
  body.innerHTML = blockedTablesModalHtml(_blockedTableRows || []);
}

function closeBlockedTableModal() {
  const overlay = document.getElementById('blockedTablesModal');
  if (overlay) overlay.classList.remove('open');
}

// 등급별 「그래서 뭘 해야 하나」.
//   ⚠️ 「이 표가 막혔다」만 띄우면 관리자는 아무것도 못 하고 경고는 무시된다.
//      특히 **미확인은 그리는 등급**이라 안내가 없으면 그 화면에서 할 일이 없어진다.
function blockedTableFixHtml(r) {
  const cmd = `node scripts/check-table-readers.mjs --tables ${r.table_name} --record`;
  if (r.grade === 'unverified') {
    return `<div style="font-size:12px;color:var(--ink);line-height:1.7">
      <b>아직 코드 점검을 안 돌렸습니다.</b> 이 표를 코드가 아직 읽는지 모르는 상태라
      「고쳐야 할 표」인지 「이미 다 옮긴 표」인지 정해지지 않았습니다.
      <div style="margin-top:6px">개발자에게 아래를 실행해 달라고 요청하세요. 그러면 이 항목이
      <b>「조치 필요」</b>로 바뀌거나, 문제가 없으면 <b>목록에서 사라집니다</b>.</div>
      <div style="margin-top:6px;padding:8px 10px;background:#F6F7F9;border-radius:8px;font-family:monospace;font-size:11px">${esc(cmd)}</div>
    </div>`;
  }
  if (r.grade === 'B') {
    return `<div style="font-size:12px;color:var(--ink);line-height:1.7">
      <b>대체 통로(<code>${esc(r.substitute_view || '')}</code>)는 이미 있는데, 아직 원본 표를 직접 읽는 코드가 남았습니다.</b>
      <div style="margin-top:6px">그 자리들이 지금 <b>빈 결과</b>를 받고 있을 수 있습니다 —
      오류가 안 나서 화면에는 「데이터 없음」으로만 보입니다. 아래 목록의 자리를 대체 통로로 바꿔야 합니다.</div>
    </div>`;
  }
  // A — 사유 두 갈래
  const why = r.a_reason === 'no_policy'
    ? '이 표에는 <b>조회 허가가 하나도 없습니다.</b> 관리자는 물론 본인 행조차 아무도 못 읽습니다.'
    : '이 표에는 <b>관리자용 조회 허가가 없습니다.</b>';
  return `<div style="font-size:12px;color:var(--ink);line-height:1.7">
    ${why}
    <div style="margin-top:6px">읽을 통로가 아예 없으므로 <b>관리자용 허가를 만들거나 가림막 통로(뷰)를 만들어야</b> 합니다.
    개발자에게 이 항목을 그대로 전달하세요.</div>
  </div>`;
}

function blockedTableRowHtml(r) {
  const badge = {
    A: ['#C33', '#FFF5F5', '조치 필요 — 읽을 통로 없음'],
    B: ['#B8741A', '#FEF3C7', '조치 필요 — 옮기다 만 자리 있음'],
    unverified: ['#6B7280', '#F3F4F6', '확인 안 됨'],
  }[r.grade] || ['#6B7280', '#F3F4F6', esc(String(r.grade || ''))];  // 폴백도 이스케이프(다른 자리와 일관되게)

  // ⚠️ 「확인 안 됨」을 0곳으로 그리면 안 된다 — 안 돌려서 0곳인 것과 돌려서 0곳인 것은
  //    다르다(이 프로젝트가 반복해 당한 「조회 실패와 0건 혼동」과 같은 함정).
  const sitesText = (r.grade === 'unverified' || r.reading_sites === null || r.reading_sites === undefined)
    ? '<span style="color:var(--muted)">확인 안 됨</span>'
    : `${Number(r.reading_sites)}곳`;

  const sites = Array.isArray(r.sites) ? r.sites : [];
  const siteList = sites.length
    ? `<div style="margin-top:8px;font-size:11px;font-family:monospace;color:var(--muted);line-height:1.8">
         ${sites.map(s => esc(`${s.file || ''}:${s.line || ''}`)).join('<br>')}
       </div>`
    : '';

  return `<div style="border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:12px">
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
      <span style="font-family:monospace;font-weight:700;font-size:13px">${esc(r.table_name)}</span>
      <span style="font-size:11px;font-weight:700;color:${badge[0]};background:${badge[1]};padding:2px 8px;border-radius:999px">${badge[2]}</span>
      <span style="font-size:11px;color:var(--muted)">아직 읽는 자리 ${sitesText}</span>
    </div>
    ${siteList}
    <div style="margin-top:10px;padding-top:10px;border-top:1px dashed var(--line)">${blockedTableFixHtml(r)}</div>
  </div>`;
}

function blockedTablesModalHtml(rows) {
  // ⚠️ 조회 실패를 「막힌 표 없음」으로 그리면 안 된다 — 감지가 죽은 것과 이상이 없는 것이
  //    같아 보이면, 정작 감지가 고장 났을 때 아무도 모른다.
  if (_blockedTableFetchFailed) {
    return `<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">
      <b style="color:var(--ink)">막힌 표를 확인하지 못했습니다.</b><br>
      감지 자체가 실패한 상태라 <b>이상이 없다는 뜻이 아닙니다</b>.<br>
      잠시 뒤 새로고침해도 같으면 개발자에게 알려 주세요.
    </div>`;
  }
  if (!rows.length) {
    return '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">지금은 막힌 표가 없습니다.</div>';
  }
  // 심한 것부터 — A → B → 미확인
  const order = { A: 0, B: 1, unverified: 2 };
  const sorted = rows.slice().sort((a, b) =>
    (order[a.grade] ?? 9) - (order[b.grade] ?? 9) || String(a.table_name).localeCompare(String(b.table_name)));

  return `<div style="font-size:12px;color:var(--muted);line-height:1.7;margin-bottom:14px">
      데이터 접근 허가가 바뀌면서 <b>관리자 화면이 읽을 수 없게 된 표</b>입니다.
      막힌 조회는 오류가 아니라 <b>빈 결과</b>를 돌려주기 때문에 오류 로그에 남지 않고,
      화면에는 그냥 「데이터 없음」으로 보입니다 — 그래서 따로 찾아 보여줍니다.
    </div>
    ${sorted.map(blockedTableRowHtml).join('')}`;
}
