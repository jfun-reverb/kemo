// ════════════════════════════════════════════════════════════════════
// SECTION: PRIVACY-LOGS — 관리자 「개인정보 기록」 페인(브랜드 제공 3년 · 접속 1년)
// ════════════════════════════════════════════════════════════════════
// 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 R3」 · 피그마 Admin a13-00·01·02
// 사양서 docs/specs/2026-10-19-personal-data-access-records.md
// 서버 552: admin_get_brand_provision_logs · admin_get_brand_provision_persons · admin_get_data_access_logs(최고 관리자만 — 서버가 막는다)
//
// 🔴 이 페인은 권한 카탈로그 항목이 아니라 **최고 관리자 고정**이다(캠페인 변경 이력과 같다).
//    카탈로그에 없는 열쇠말은 permLevel 이 'write' 라 아무도 안 막히므로 _privacyLogsAllowed() 로 직접 숨기고 막는다.
// 🔴 메뉴·화면·브랜드 상세 「제공 기록」 단추는 _brandAccountEnabled()(개발서버)일 때만 — 운영엔 552 가 없다. 출시(L1) 때 걷는다.
// ⚠️ 로더 이름 loadPrivacyLogsPane 은 admin-core.js switchAdminPane loaders 와 shared.js PANE_REFRESHERS 가 함께 부른다.
// ⚠️ 이 파일은 dev/admin/index.html 에 <script> 태그를 넣지 않는다 — ADMIN_JS_FILES 한 곳에만 등록한다(admin-ad-tracking.js 와 같다).
// · 목록은 서버 커서(before_at + before_id)로 50줄씩 「더 보기」 — 기록이 계속 쌓여 쪽 번호를 쓰지 않는다(552 [J6])
// · 사람 목록은 줄마다 「사람 보기」를 누를 때 따로 받는다(목록 줄에는 사람 수만)
// · 조회 실패(null)는 오류 줄, 0건은 「기록이 없습니다」 — 섞지 않는다
// ════════════════════════════════════════════════════════════════════

// 종류 11개 — brand_provision_logs.action 검사 제약과 같은 목록(552 아홉 + 이용 제한 작업표 제한 4 의 열람 정지·해제 둘)
//   (배송 탭 기록 창 SHIP_LOG_ACTION_TEXT 는 그중 배송 넷)
const PRIVACY_LOG_ACTION_TEXT = {
  shipping_deliver:  '배송 리스트 전달',
  shipping_auto_add: '배송 리스트 자동 추가(새로 승인)',
  shipping_view:     '배송 리스트 열람',
  shipping_excel:    '배송 리스트 엑셀 내려받기',
  results_view:      '결과물 열람',
  results_excel:     '결과물 엑셀 내려받기',
  publish_on:        '결과물 브랜드 공개 켬',
  publish_off:       '결과물 브랜드 공개 끔',
  publish_columns:   '결과물 공개 열 바꿈',
  results_suspend:   '결과물 열람 정지',
  results_unsuspend: '결과물 열람 정지 해제',
};
const PRIVACY_LOG_ACTOR_TEXT = { brand: '브랜드', admin: '운영팀', system: '자동' };
const PRIVACY_LOG_PAGE = 50;

let _plTab = 'provision';      // 'provision' | 'access'
let _plBrand = null;           // { id, name } — 브랜드 상세·배송 기록 창에서 걸러 열었을 때
let _plFilter = {};            // 화면 거르기 칸 값
let _plRows = [];              // 지금까지 받은 줄
let _plHasMore = false;
let _plState = 'loading';      // 'loading' | 'error' | 'ok'
let _plSeq = 0;
let _plMoreBusy = false;

function _privacyLogsAllowed() {
  return (typeof _brandAccountEnabled === 'function') && _brandAccountEnabled()
    && typeof currentAdminInfo !== 'undefined' && !!currentAdminInfo && currentAdminInfo.role === 'super_admin';
}

// 사이드바 항목 — applyLookupMenuVisibility(admin-accounts.js) 끝에서 부른다(권한을 다시 적용하는 길을 모두 탄다)
function applyPrivacyLogsMenuVisibility() {
  const el = document.getElementById('adminPrivacyLogsSi');
  if (el) el.style.display = _privacyLogsAllowed() ? '' : 'none';
}

// 다른 화면에서 걸러 열기 — 브랜드 상세 「제공 기록」 · 배송 탭 기록 창 「개인정보 기록 화면에서 더 보기」
function openPrivacyLogs(opts) {
  const o = opts || {};
  _plTab = 'provision';
  _plFilter = {};
  _plBrand = o.brandId ? { id: o.brandId, name: o.brandName || '' } : null;
  if (typeof navAdminPaneReload === 'function') navAdminPaneReload('privacy-logs');
  else switchAdminPane('privacy-logs', null, true);
}

async function loadPrivacyLogsPane() {
  const pane = document.getElementById('adminPane-privacy-logs');
  if (!pane) return;
  if (!_privacyLogsAllowed()) {
    pane.innerHTML = '';
    if (typeof toast === 'function') toast('개인정보 기록은 최고 관리자만 볼 수 있습니다.', 'error');
    // 주소 해시도 대시보드로 바꿔 둔다(남기면 새로고침마다 거부 안내가 다시 뜬다)
    if (location.hash === '#privacy-logs') history.replaceState(null, '', location.pathname + location.search + '#dashboard');
    return switchAdminPane('dashboard', null, false);
  }
  _plRenderShell();
  await _plReload();
}

function _plTabsHtml() {
  const tab = (key, label) => '<button type="button" class="status-tab-btn' + (_plTab === key ? ' on' : '') + '" onclick="switchPrivacyLogTab(\'' + key + '\')">' + label + '</button>';
  return '<div class="status-tab-bar" role="tablist" style="margin-top:12px;margin-bottom:0">'
    + tab('provision', '브랜드 제공 (3년)') + tab('access', '접속 — 열람·내려받기 (1년)') + '</div>';
}
function _plFiltersHtml() {
  const f = _plFilter;
  const val = k => esc(f[k] || '');
  const group = (label, inner) => '<div class="admin-filter-group"><label>' + label + '</label>' + inner + '</div>';
  const date = (k) => '<input type="date" class="admin-filter" style="width:auto" data-pl-filter="' + k + '" value="' + val(k) + '">';
  let html = group('기간', '<div style="display:flex;align-items:center;gap:4px">' + date('from') + '<span style="color:var(--muted)">~</span>' + date('to') + '</div>');
  if (_plTab === 'provision') {
    html += group('무엇을', '<select class="admin-filter" style="width:auto" data-pl-filter="action"><option value="">전체</option>'
      + Object.keys(PRIVACY_LOG_ACTION_TEXT).map(k => '<option value="' + k + '"' + (f.action === k ? ' selected' : '') + '>' + esc(PRIVACY_LOG_ACTION_TEXT[k]) + '</option>').join('') + '</select>');
    html += group('누가', '<select class="admin-filter" style="width:auto" data-pl-filter="actor_kind"><option value="">전체</option>'
      + Object.keys(PRIVACY_LOG_ACTOR_TEXT).map(k => '<option value="' + k + '"' + (f.actor_kind === k ? ' selected' : '') + '>' + esc(PRIVACY_LOG_ACTOR_TEXT[k]) + '</option>').join('') + '</select>');
    html += group('캠페인 번호', '<input type="text" class="admin-filter" style="width:130px" placeholder="예: B0046-C003" data-pl-filter="campaign_no" value="' + val('campaign_no') + '">');
    html += group('인플루언서 이름', '<input type="text" class="admin-filter" style="width:140px" placeholder="이름 일부" data-pl-filter="person_name" value="' + val('person_name') + '">');
  } else {
    html += group('어디서', '<input type="text" class="admin-filter" style="width:160px" placeholder="화면 이름(정확히)" data-pl-filter="source" value="' + val('source') + '">');
  }
  html += '<div class="admin-filter-group"><label>&nbsp;</label><div style="display:flex;gap:6px">'
    + '<button type="button" class="btn btn-primary btn-sm" onclick="applyPrivacyLogFilters()">검색</button>'
    + '<button type="button" class="btn btn-ghost btn-sm" onclick="resetPrivacyLogFilters()">초기화</button></div></div>';
  const brandChip = (_plTab === 'provision' && _plBrand)
    ? '<div style="margin-top:10px;display:flex;align-items:center;gap:8px;font-size:12px"><span class="badge badge-gray">브랜드: ' + esc(_plBrand.name || '선택한 브랜드') + '</span>'
      + '<button type="button" class="btn btn-ghost btn-xs" onclick="clearPrivacyLogBrand()">브랜드 거르기 해제</button></div>'
    : '';
  return '<div class="admin-filter-bar" style="display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap">' + html + '</div>' + brandChip;
}
function _plRenderShell() {
  const pane = document.getElementById('adminPane-privacy-logs');
  if (!pane) return;
  const desc = _plTab === 'provision'
    ? '브랜드에 인플루언서 정보를 보여 주거나 전한 기록입니다. 일본 개인정보보호법의 제3자 제공 기록으로 3년 보관한 뒤 자동으로 지웁니다.'
    : '운영팀이 개인정보를 열람하거나 내려받은 기록입니다. 1년 보관한 뒤 자동으로 지웁니다.';
  const heads = _plTab === 'provision'
    ? '<th style="width:150px">일시</th><th style="width:160px">브랜드</th><th style="width:110px">캠페인 번호</th><th style="width:170px">누가</th><th>무엇을</th><th>보인 칸</th><th style="width:150px;text-align:right">사람</th>'
    : '<th style="width:150px">일시</th><th style="width:170px">누가</th><th style="width:110px">등급</th><th style="width:200px">어디서</th><th>보인 칸</th><th style="width:90px;text-align:right">사람 수</th>';
  pane.innerHTML =
    '<div class="admin-sticky-header">'
      + '<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px;gap:12px">'
        + '<div style="font-size:16px;font-weight:700;color:var(--ink)">개인정보 기록</div>'
        + '<div style="font-size:12px;color:var(--muted)">최고 관리자만 볼 수 있습니다 · 기록은 고치거나 지울 수 없습니다</div>'
      + '</div>'
      + _plFiltersHtml()
      + _plTabsHtml()
    + '</div>'
    + '<div class="admin-card">'
      + '<div class="admin-card-header"><div style="display:flex;flex-direction:column;gap:2px"><span class="admin-card-title" id="plCardTitle">기록</span>'
        + '<span style="font-size:11px;color:var(--muted)">' + esc(desc) + '</span></div></div>'
      + '<div class="admin-table-wrap"><table class="data-table"><thead><tr>' + heads + '</tr></thead><tbody id="plBody"></tbody></table>'
        + '<div id="plMore" style="padding:12px;text-align:center"></div></div>'
    + '</div>';
}

function _plServerFilters() {
  const f = {};
  Object.keys(_plFilter).forEach(k => { const v = String(_plFilter[k] || '').trim(); if (v) f[k] = v; });
  if (_plTab === 'provision') {
    delete f.source;
    if (_plBrand) f.brand_id = _plBrand.id;
  } else {
    ['action', 'actor_kind', 'campaign_no', 'person_name'].forEach(k => { delete f[k]; });
  }
  f.limit = PRIVACY_LOG_PAGE;
  return f;
}

async function _plReload() {
  const seq = ++_plSeq;
  _plRows = []; _plHasMore = false; _plState = 'loading';
  _plRenderRows();
  const res = await _plFetch(_plServerFilters());
  if (seq !== _plSeq) return;
  if (!res) { _plState = 'error'; _plRenderRows(); return; }
  _plRows = res.rows; _plHasMore = !!res.has_more; _plState = 'ok';
  _plRenderRows();
}
function _plFetch(filters) {
  return _plTab === 'provision' ? fetchBrandProvisionLogs(filters) : fetchDataAccessLogs(filters);
}

async function loadMorePrivacyLogs() {
  if (_plMoreBusy || !_plHasMore || !_plRows.length) return;
  const last = _plRows[_plRows.length - 1];
  const seq = _plSeq;
  _plMoreBusy = true;
  _plRenderMore();
  const f = _plServerFilters();
  f.before_at = last.at; f.before_id = last.id;
  const res = await _plFetch(f);
  _plMoreBusy = false;
  if (seq !== _plSeq) return;
  if (!res) { _plRenderMore(); toast('기록을 더 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.', 'error'); return; }
  _plRows = _plRows.concat(res.rows); _plHasMore = !!res.has_more;
  _plRenderRows();
}

// 「보인 칸」 이름 — 배송 칸 다섯(554 _shipping_provision_columns)은 여기, 결과물 칸은 리포트 열 이름(REPORT_COLS — report-rows.js)
const PRIVACY_LOG_SHIP_COL_TEXT = { name: '이름', name_kana: '이름(가나)', postal_code: '우편번호', address: '주소', phone: '전화번호' };
function _plColLabel(key) {
  if (PRIVACY_LOG_SHIP_COL_TEXT[key]) return PRIVACY_LOG_SHIP_COL_TEXT[key];
  const rc = (typeof REPORT_COLS !== 'undefined' && Array.isArray(REPORT_COLS)) ? REPORT_COLS.find(c => c.key === key) : null;
  return rc ? rc.label : key;
}
// 열람 정지·해제 줄의 칸 = 막은 것(보인 칸이 아니다 — 제한 4 admin_suspend_brand_results 가 넣는 값). 리포트 열 이름과 섞이지 않게 종류로 가른다
const PRIVACY_LOG_SUSPEND_COL_TEXT = { results: '결과물 표', excel: '결과물 엑셀', receipt: '영수증 사진', shipping: '배송 리스트' };
function _plColumnsText(cols, action) {
  if (!Array.isArray(cols) || !cols.length) return '';
  const suspendRow = action === 'results_suspend' || action === 'results_unsuspend';
  return (suspendRow ? '막은 것: ' : '') + cols.map(c => {
    if (typeof c === 'string') return suspendRow ? (PRIVACY_LOG_SUSPEND_COL_TEXT[c] || c) : _plColLabel(c);
    if (c && typeof c === 'object' && ('enabled_before' in c || 'enabled_after' in c)) {
      const n = a => Array.isArray(a) ? a.length : 0;
      return '공개 ' + (c.enabled_before ? '켬' : '끔') + ' → ' + (c.enabled_after ? '켬' : '끔') + ' · 열 ' + n(c.before) + '개 → ' + n(c.after) + '개';
    }
    return '';
  }).filter(Boolean).join(' · ');
}
function _plActorText(l) {
  if (l.actor_kind === 'system') return '자동';
  return (PRIVACY_LOG_ACTOR_TEXT[l.actor_kind] || '') + (l.actor_name ? ' ' + l.actor_name : '');
}
const PRIVACY_LOG_ROLE_TEXT = { super_admin: '최고 관리자', campaign_admin: '캠페인 관리자', campaign_manager: '캠페인 매니저' };

function _plRenderRows() {
  const body = document.getElementById('plBody');
  if (!body) return;
  const colspan = _plTab === 'provision' ? 7 : 6;
  const msg = (t, color) => '<tr><td colspan="' + colspan + '" style="text-align:center;color:' + (color || 'var(--muted)') + ';padding:28px;font-size:13px">' + t + '</td></tr>';
  const title = document.getElementById('plCardTitle');
  if (title) title.textContent = _plState === 'ok' ? '기록 ' + _plRows.length + (_plHasMore ? '+' : '') + '줄' : '기록';
  if (_plState === 'loading') { body.innerHTML = msg('<span class="spinner" style="width:18px;height:18px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span>'); _plRenderMore(); return; }
  if (_plState === 'error') {
    body.innerHTML = msg('기록을 불러오지 못했습니다. <button type="button" class="btn btn-ghost btn-xs" onclick="reloadPrivacyLogs()">다시 시도</button>', 'var(--danger, #c0392b)');
    _plRenderMore(); return;
  }
  if (!_plRows.length) { body.innerHTML = msg('조건에 맞는 기록이 없습니다'); _plRenderMore(); return; }
  if (_plTab === 'provision') {
    body.innerHTML = _plRows.map(l => {
      const btn = l.person_count
        ? '<button type="button" class="btn btn-ghost btn-xs" onclick="togglePrivacyLogPersons(this, ' + jsStr(l.id) + ')">' + l.person_count + '명 · 사람 보기</button>'
        : '<span style="color:var(--muted)">0명</span>';
      return '<tr><td style="white-space:nowrap">' + esc(formatDateTime(l.at)) + '</td>'
        + '<td>' + (esc(l.brand_name || '') || '<span style="color:var(--muted)">—</span>') + '</td>'
        + '<td style="white-space:nowrap">' + (esc(l.campaign_no || '') || '<span style="color:var(--muted)">—</span>') + '</td>'
        + '<td>' + esc(_plActorText(l)) + '</td>'
        + '<td>' + esc(PRIVACY_LOG_ACTION_TEXT[l.action] || l.action || '') + '</td>'
        + '<td style="font-size:12px;color:var(--muted)">' + esc(_plColumnsText(l.columns, l.action)) + '</td>'
        + '<td style="text-align:right">' + btn + '</td></tr>'
        + '<tr class="pl-persons" data-log="' + esc(l.id) + '" style="display:none"><td colspan="7" style="background:var(--surface-container-low, #F7F7F8);font-size:12px;color:var(--muted)"></td></tr>';
    }).join('');
  } else {
    body.innerHTML = _plRows.map(l => '<tr><td style="white-space:nowrap">' + esc(formatDateTime(l.at)) + '</td>'
      + '<td>' + esc(l.actor_name || '') + '</td>'
      + '<td>' + esc(PRIVACY_LOG_ROLE_TEXT[l.actor_role] || l.actor_role || '') + '</td>'
      + '<td>' + esc(l.source || '') + '</td>'
      + '<td style="font-size:12px;color:var(--muted)">' + esc(_plColumnsText(l.columns)) + '</td>'
      + '<td style="text-align:right">' + (Number(l.person_count) || 0) + '명</td></tr>').join('');
  }
  _plRenderMore();
}
function _plRenderMore() {
  const box = document.getElementById('plMore');
  if (!box) return;
  box.innerHTML = (_plState === 'ok' && _plHasMore)
    ? '<button type="button" class="btn btn-ghost btn-sm" onclick="loadMorePrivacyLogs()"' + (_plMoreBusy ? ' disabled' : '') + '>' + (_plMoreBusy ? '불러오는 중…' : '더 보기 (' + PRIVACY_LOG_PAGE + '줄)') + '</button>'
    : '';
}

async function togglePrivacyLogPersons(btn, logId) {
  const row = document.querySelector('#plBody tr.pl-persons[data-log="' + CSS.escape(String(logId)) + '"]');
  if (!row) return;
  const label = btn.dataset.label || btn.textContent;
  btn.dataset.label = label;
  if (row.style.display !== 'none') { row.style.display = 'none'; btn.textContent = label; return; }
  row.style.display = '';
  btn.textContent = '접기';
  const cell = row.firstElementChild;
  if (cell.dataset.loaded === '1') return;
  cell.textContent = '불러오는 중…';
  const persons = await fetchBrandProvisionPersons(logId);
  if (!persons) { cell.textContent = '사람 목록을 불러오지 못했습니다.'; return; }
  cell.dataset.loaded = '1';
  cell.textContent = persons.length ? persons.map(p => p.name || '(이름 없음)').join(' · ') : '사람 목록이 비어 있습니다.';
}

function switchPrivacyLogTab(tab) {
  if (tab === _plTab) return;
  _plReadFilters();   // 입력만 하고 「검색」을 안 누른 값도 탭을 바꾸면서 잃지 않게
  _plTab = tab;
  _plRenderShell();
  _plReload();
}
function _plReadFilters() {
  document.querySelectorAll('#adminPane-privacy-logs [data-pl-filter]').forEach(el => { _plFilter[el.dataset.plFilter] = el.value; });
}
function applyPrivacyLogFilters() {
  _plReadFilters();
  if (_plFilter.from && _plFilter.to && _plFilter.from > _plFilter.to) { toast('기간의 시작이 끝보다 늦습니다.', 'error'); return; }
  _plReload();
}
function resetPrivacyLogFilters() {
  _plFilter = {};
  _plRenderShell();
  _plReload();
}
function clearPrivacyLogBrand() {
  _plReadFilters();
  _plBrand = null;
  _plRenderShell();
  _plReload();
}
function reloadPrivacyLogs() { _plReload(); }

// 고르기 칸은 바로 검색, 글자 칸은 Enter 로 검색
document.addEventListener('change', (e) => {
  const el = e.target.closest && e.target.closest('#adminPane-privacy-logs [data-pl-filter]');
  if (el && (el.tagName === 'SELECT' || el.type === 'date')) applyPrivacyLogFilters();
});
document.addEventListener('keydown', (e) => {
  const el = e.target.closest && e.target.closest('#adminPane-privacy-logs input[data-pl-filter]');
  if (el && e.key === 'Enter') { e.preventDefault(); applyPrivacyLogFilters(); }
});
