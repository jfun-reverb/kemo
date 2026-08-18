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

// **가장 오래된** 코드 점검 시각(최신이 아니다 — storage.js 주석 참조).
// null = 조회 실패 / {at:null} = 한 번도 점검 안 함 / {at:'…'} = 그 시각
let _blockedTableScan = null;

// 점검이 이만큼 지나면 「초록」을 초록으로 그리지 않는다.
//   ⚠️ 화면의 0건은 「지금 이상 없음」이 아니라 「마지막 점검 때 이상 없었음」이다.
//      점검을 잊으면 화면은 계속 초록인데 실제 상태는 아무도 모른다 — **낡은 초록이
//      늘 빨간 것보다 나쁘다.** 빨간 건 무시라도 하지만 초록은 안심시킨다.
//   ⚠️ 7일로 잡은 근거: 점검은 마이그레이션을 커밋할 때 훅이 상기시키는 구조라
//      마이그레이션이 없는 주에는 아무도 안 돌린다. 한 주가 그 주기의 자연스러운 단위다.
const BLOCKED_SCAN_STALE_DAYS = 7;

// 점검을 다시 돌리는 명령. ⚠️ 안내문에 명령을 함께 적지 않으면 「그래서 뭘 하라는
//   거냐」가 되어 아무도 안 움직인다 — 안내가 아니라 **작업 지시**가 되어야 한다.
const BLOCKED_SCAN_CMD = 'node scripts/check-table-readers.mjs --tables <표이름> --record';
// ⚠️ `<표이름>` 은 그대로 실행하면 실패하는 자리표시자다. 0건 상태에서는 화면이 어느 표를
//    지목해야 할지 모르므로(막힌 표가 없으니) 개발자가 채워야 한다 — 안내에 그 점을 적는다.

// 가장 오래된 점검이 며칠 전인가. 모르면 null.
function blockedScanAgeDays() {
  if (!_blockedTableScan || !_blockedTableScan.at) return null;
  const t = Date.parse(_blockedTableScan.at);
  if (Number.isNaN(t)) return null;
  return Math.floor((Date.now() - t) / 86400000);
}

// 점검 상태 — 'fresh' | 'stale'(오래됨) | 'never'(한 번도 안 함) | 'unknown'(조회 실패)
function blockedScanState() {
  if (_blockedTableScan === null) return 'unknown';
  if (!_blockedTableScan.at) return 'never';
  const d = blockedScanAgeDays();
  // ⚠️ 날짜를 못 읽으면 **「최신」이 아니라 「오래됨」으로** 본다. 모르는 것을 「괜찮다」
  //    쪽으로 기울이면 이 장치가 막으려는 실패(낡은 초록)를 장치 자신이 하는 것이다.
  if (d === null) return 'stale';
  return (d >= BLOCKED_SCAN_STALE_DAYS) ? 'stale' : 'fresh';
}

function blockedScanWhenText() {
  const st = blockedScanState();
  if (st === 'unknown') return '확인 실패';
  if (st === 'never') return '한 번도 점검하지 않음';
  const d = blockedScanAgeDays();
  const when = (typeof formatDateTime === 'function') ? formatDateTime(_blockedTableScan.at) : String(_blockedTableScan.at).slice(0, 16);
  return `${when} (${d === 0 ? '오늘' : d + '일 전'})`;
}

async function refreshBlockedTableIndicators() {
  // 점검 시각도 함께 받는다 — 감지 함수는 통과한 표를 안 돌려주므로
  // 「다 통과했을 때 언제 확인한 것인가」를 그 함수만으로는 알 수 없다.
  _blockedTableScan = await fetchOldestTableScanAt();
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
  const scanState = blockedScanState();
  // ★ 점검이 오래됐거나 한 번도 안 했으면 **0건이어도 그린다.**
  //   「0건이면 아무것도 안 그린다」 원칙과 안 부딪힌다 — 그 원칙은 **조치할 게 없는데
  //   그리는 것**을 막는 것이고, 이건 **조치할 게 있다**(점검을 돌려야 한다).
  //   ⚠️ 이걸 안 넣으면 화면은 영원히 초록이고, 그 초록이 언제 것인지 아무도 모른다.
  // ⚠️ **'unknown'(점검 시각 조회 실패)을 빼면 안 된다.** 빼면 「막힌 표도 없고 언제
  //    점검했는지도 모름」이 「이상 없음」과 화면에서 **완전히 같아진다** — 이 기능이
  //    막으려는 바로 그 실패를 기능 자신이 하는 것이다(리뷰 지적).
  const scanUnknown = (scanState === 'unknown');
  const staleScan = (scanState === 'stale' || scanState === 'never' || scanUnknown);
  // 실패했으면 결과가 0건이어도 「이상 없음」으로 그리지 않는다.
  const has = rows.length > 0 || failed || staleScan;
  const severe = rows.some(function(r) { return r.grade === 'A'; });
  // 실제 막힌 표가 없고 점검만 오래된 상태 — 경고가 아니라 **안내** 색으로 그린다.
  const onlyStale = staleScan && !failed && rows.length === 0;

  // 사이드바 — 아이콘 자체를 경고 모양으로 바꾼다.
  //   ⚠️ 접힌 사이드바에서는 아이콘만 보이므로 옆에 표시를 붙이면 안 보인다.
  //   ⚠️ 원래 아이콘은 dataset 에 보관 — 하드코딩하면 나중에 메뉴 아이콘을 바꿀 때 stale.
  const item = document.getElementById('adminErrorsSi');
  if (item) {
    const icon = item.querySelector('.si-icon');
    if (icon) {
      if (!icon.dataset.baseIcon) icon.dataset.baseIcon = (icon.textContent || 'bug_report').trim();
      if (has) {
        icon.textContent = (failed || onlyStale) ? 'help_outline' : 'report_problem';
        icon.style.color = (failed || onlyStale) ? '#6B7280' : (severe ? '#C33' : '#B8741A');
        item.title = failed
          ? '막힌 표를 확인하지 못했습니다 — 감지 자체가 실패한 상태입니다'
          : (onlyStale
              ? (scanUnknown
                  ? '코드 점검 시각을 확인하지 못했습니다 — 지금 「이상 없음」이 언제 기준인지 알 수 없습니다'
                  : `코드 점검을 ${blockedScanWhenText()} 이후로 안 돌렸습니다 — 지금 「이상 없음」은 그때 기준입니다`)
              : `관리자가 못 읽게 된 표 ${rows.length}건 — 이 화면에서 조치 방법을 볼 수 있습니다`);
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
  if (onlyStale) {
    // 막힌 표는 없는데 **점검이 오래됐다.** 빨강·주황이 아니라 회색 —
    // 「지금 문제가 있다」가 아니라 「지금 상태를 모른다」이기 때문이다.
    btn.style.background  = '#F3F4F6';
    btn.style.borderColor = '#9CA3AF';
    btn.style.color       = '#374151';
    // ⚠️ 세 갈래를 다 적는다. 'unknown' 을 안 가르면 「점검한 지 null일 지남」이 그대로 뜬다.
    const ico = '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">';
    btn.innerHTML = scanUnknown
      ? `${ico}help_outline</span> 점검 시각 확인 실패`
      : (blockedScanState() === 'never'
          ? `${ico}schedule</span> 코드 점검 안 함`
          : `${ico}schedule</span> 점검한 지 ${blockedScanAgeDays()}일 지남`);
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
    // ⚠️ 「막힌 표 없음」만 적으면 **그게 언제 기준인지** 알 수 없다. 점검을 한 달 안
    //    돌려도 화면은 똑같이 「없음」이다. **언제 확인한 것인지를 반드시 함께** 보여준다.
    const st = blockedScanState();
    const stale = (st === 'stale' || st === 'never');
    return `<div style="padding:22px;text-align:center;color:var(--muted);font-size:13px;line-height:1.9">
      <b style="color:var(--ink)">막힌 표가 없습니다.</b><br>
      가장 오래된 코드 점검: <b style="color:${stale ? '#374151' : 'var(--ink)'}">${esc(blockedScanWhenText())}</b>
      ${stale ? `<div style="margin-top:14px;padding:12px 14px;background:#F3F4F6;border-radius:10px;text-align:left;color:var(--ink);font-size:12px;line-height:1.8">
          ⚠️ <b>이 「없음」은 지금이 아니라 그때 기준입니다.</b>
          그 뒤에 데이터 접근 허가가 바뀌었다면 이 화면은 아직 모릅니다.
          <div style="margin-top:8px">개발자에게 아래를 실행해 달라고 요청하세요. <b>&lt;표이름&gt;</b> 자리는 개발자가 채웁니다.</div>
          <div style="margin-top:6px;padding:8px 10px;background:#fff;border-radius:8px;font-family:monospace;font-size:11px">${esc(BLOCKED_SCAN_CMD)}</div>
        </div>` : ''}
    </div>`;
  }
  // 심한 것부터 — A → B → 미확인
  const order = { A: 0, B: 1, unverified: 2 };
  const sorted = rows.slice().sort((a, b) =>
    (order[a.grade] ?? 9) - (order[b.grade] ?? 9) || String(a.table_name).localeCompare(String(b.table_name)));

  return `<div style="font-size:11px;color:var(--muted);margin-bottom:10px">
      가장 오래된 코드 점검: <b>${esc(blockedScanWhenText())}</b>
      <span style="font-size:10px">— 이 시각 이후로는 모든 대상 표가 한 번 이상 확인됐다는 뜻입니다</span>
    </div>
    <div style="font-size:12px;color:var(--muted);line-height:1.7;margin-bottom:14px">
      데이터 접근 허가가 바뀌면서 <b>관리자 화면이 읽을 수 없게 된 표</b>입니다.
      막힌 조회는 오류가 아니라 <b>빈 결과</b>를 돌려주기 때문에 오류 로그에 남지 않고,
      화면에는 그냥 「데이터 없음」으로 보입니다 — 그래서 따로 찾아 보여줍니다.
    </div>
    ${sorted.map(blockedTableRowHtml).join('')}`;
}
