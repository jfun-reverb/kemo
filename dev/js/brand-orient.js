// 브랜드 페이지 — 오리엔시트 목록(04) + 「가려던 시트」 장치
//   (작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 조각 5 · 결정 1~7·기본값 4·7·9)
//   피그마 bw04-00(리스트)·00a(카드)·00b(실패)·00c(0건)·00d(표 전체)·00e(고른 탭 0건)·bm04-00(모바일)
//   🔴 상태는 서버 판정(view_status — _orient_brand_view_status)만 쓴다. 화면에서 기한·등록을 다시 판정하지 않는다(사본 금지).
//   🔴 조회 실패(null)와 0건([])을 구분한다 — 실패를 「받은 시트 없음」으로 그리지 않는다.

const BRAND_ORIENT_MSG = {
  loadFailTitle: '오리엔시트 목록을 불러오지 못했습니다',                                          // bw04-00b
  loadFailDesc: '인터넷 연결을 확인한 뒤 다시 시도해 주십시오. 계속되면 담당자에게 문의해 주십시오.',
  emptyTitle: '아직 받은 오리엔시트가 없습니다',                                                    // bw04-00c
  emptyDesc: '담당자가 오리엔시트를 보내 드리면 여기에 나타납니다. 메일로도 알려 드립니다.',
  cannotOpen: '이 오리엔시트를 볼 수 없습니다.',   // 가려던 시트가 내 브랜드 것이 아님(문구는 기획 확인 대기 — 작업표 조각 5)
  openFail: '오리엔시트를 열지 못했습니다. 잠시 후 다시 시도해 주십시오.'   // 가려던 시트 확인 호출 실패(같은 문체로 임시)
};

// 상태 이름표 한 곳(결정 1) — 리스트 글자·카드 배지·모바일이 모두 이것을 쓴다.
//   ⚠️ 피그마 리스트는 「작성중」(붙임)·카드는 「작성 중」 — 탭 이름과 같은 「작성 중」 하나로 맞췄다.
const BRAND_ORIENT_STATUS = {
  new:        { label: '신규',          cls: 'is-new' },
  editing:    { label: '작성 중',       cls: 'is-editing' },
  submitted:  { label: '제출됨',        cls: 'is-submitted' },
  registered: { label: '캠페인 등록됨', cls: 'is-registered' },
  expired:    { label: '만료',          cls: 'is-expired' }
};
const BRAND_ORIENT_TABS = [
  { key: 'all', label: '전체' },
  { key: 'editing', label: '작성 중' },
  { key: 'submitted', label: '제출됨' },
  { key: 'registered', label: '캠페인 등록됨' },
  { key: 'expired', label: '만료' }
];
// 고른 탭 0건(bw04-00e) — 피그마는 「제출됨」 예시만 있다. 나머지 탭은 같은 문체로(기획 확인 대기)
const BRAND_ORIENT_TAB_EMPTY = {
  editing: { title: '작성 중인 오리엔시트가 없습니다', desc: '새 오리엔시트를 받으면 여기에 나타납니다. 「전체」 탭에서 모든 오리엔시트를 볼 수 있습니다.' },
  submitted: { title: '제출된 오리엔시트가 없습니다', desc: '작성을 마치고 「제출하기」를 누르면 여기에 나타납니다. 「전체」 탭에서 모든 오리엔시트를 볼 수 있습니다.' },
  registered: { title: '캠페인이 등록된 오리엔시트가 없습니다', desc: '운영팀이 캠페인을 등록하면 여기에 나타납니다. 「전체」 탭에서 모든 오리엔시트를 볼 수 있습니다.' },
  expired: { title: '만료된 오리엔시트가 없습니다', desc: '작성 기한이 지난 오리엔시트가 여기에 나타납니다. 「전체」 탭에서 모든 오리엔시트를 볼 수 있습니다.' }
};
// 시딩 채널 표기 — 견적서(_orient_compute_quote)·작성 폼과 같은 하이픈 표기
const BRAND_ORIENT_CHANNEL = {
  instagram_feed: '인스타그램-피드', instagram_reels: '인스타그램-릴스', x: 'X', tiktok: '틱톡', youtube: '유튜브'
};
const BRAND_ORIENT_MARKET = { lips: 'LIPS', cosme: '@cosme' };

const BRAND_ORIENT_VIEW_KEY = 'reverb.brandOrient.view';        // 기본값 9 — 이 기기에 기억
const BRAND_ORIENT_TARGET_KEY = 'reverb.brandOrientTarget';     // 기본값 7 — 세션 저장소 {kind:'sheet'|'token', value}

let _brandOrientList;          // undefined 불러오는 중 · null 실패 · { brandId, serverNow, sheets }
let _brandOrientTab = 'all';
let _brandOrientView = _brandOrientReadView();
let _brandOrientLoadSeq = 0;
const _brandOrientMobileMq = window.matchMedia('(max-width: 600px)');

function _brandOrientReadView() {
  try { return localStorage.getItem(BRAND_ORIENT_VIEW_KEY) === 'card' ? 'card' : 'list'; } catch (e) { return 'list'; }
}
function _brandOrientSaveView(v) {
  try { localStorage.setItem(BRAND_ORIENT_VIEW_KEY, v); } catch (e) { /* 저장소 막힘 — 이번 화면만 */ }
}
// 모바일(bm04-00)은 카드 보기만
function _brandOrientEffectiveView() { return _brandOrientMobileMq.matches ? 'card' : _brandOrientView; }

// 탭 소속 한 곳 — 「신규」는 「작성 중」 탭에 든다(결정 1). 탭 숫자와 목록이 같은 배열·같은 함수에서 나온다(00e).
function brandOrientInTab(row, tab) {
  if (tab === 'all') return true;
  if (tab === 'editing') return row.view_status === 'new' || row.view_status === 'editing';
  return row.view_status === tab;
}

// ── 표시 조각
function _boDash() { return '<span class="brand-dash">-</span>'; }
function _boTypeText(r) {
  if (r.layout === 'old') return '이전 양식';   // 결정 4
  return r.form_type === 'reviewer' ? '리뷰어' : r.form_type === 'seeding' ? '시딩' : '';
}
function _boChannelText(r) {
  if (r.layout === 'old') return '';
  if (r.form_type === 'reviewer') return 'Qoo10';   // 리뷰어 = 판매처(bw04-00d)
  return BRAND_ORIENT_CHANNEL[r.channel] || r.channel || '';
}
function _boMarketsText(r) {
  const m = Array.isArray(r.extra_markets) ? r.extra_markets : [];
  return m.map(k => BRAND_ORIENT_MARKET[k] || k).join(' · ');
}
function _boStatusLabel(r) {
  const s = BRAND_ORIENT_STATUS[r.view_status] || BRAND_ORIENT_STATUS.expired;
  // 옛 구조 일부 등록 — 「캠페인 등록됨 (n/m)」(결정 4)
  if (r.view_status === 'registered' && r.layout === 'old' && r.card_count > 1 && r.registered_count < r.card_count) {
    return s.label + ' (' + r.registered_count + '/' + r.card_count + ')';
  }
  return s.label;
}
// 남은 날 — 일본 날짜 기준(서버 시각 server_now). 기한 안 시트(신규·작성 중·제출됨)에만 붙인다
const _boDayFmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit' });
function _boDayNo(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return null;
  return Math.round(Date.parse(_boDayFmt.format(d) + 'T00:00:00Z') / 86400000);
}
function _boDLeft(r, serverNow) {
  if (!r.deadline_at || !['new', 'editing', 'submitted'].includes(r.view_status)) return null;
  const a = _boDayNo(serverNow || new Date().toISOString()), b = _boDayNo(r.deadline_at);
  if (a == null || b == null || b < a) return null;
  return 'D-' + (b - a);
}
// 「최근 수정」 — 이름(없으면 시각만) + 시각. 결정 2
function _boEditedHtml(r, short) {
  if (!r.last_edited_at) return '';
  const name = r.last_edited_by_name ? brandEsc(r.last_edited_by_name) : '';
  const when = short ? _boShortDateTime(r.last_edited_at) : brandFormatDateTime(r.last_edited_at);
  return (name ? '<span class="bo-edited-name">' + name + '</span>' : '') + '<span class="bo-edited-at">' + brandEsc(when) + '</span>';
}
function _boShortDateTime(iso) { const s = brandFormatDateTime(iso); return s ? s.slice(5) : ''; }   // 09/17 15:58
// 제출된 뒤 고쳐 두고 다시 제출 안 함 — 상태는 「제출됨」 그대로 + 작은 표시(결정 5 — 피그마에 그림 없음)
function _boDraftMark(r) {
  return r.view_status === 'submitted' && r.has_unsubmitted_draft ? '<span class="bo-draft-mark">수정 중</span>' : '';
}

// ── 그리기
function _brandOrientHeadHtml() {
  return '<div class="brand-page-head"><div><h1>오리엔시트</h1>' +
    '<p>담당자가 보내 드린 오리엔시트를 작성하고 내역을 확인할 수 있습니다.</p></div></div>';
}

function _brandOrientTabsHtml(sheets) {
  const has = Array.isArray(sheets);
  return '<div class="bo-tabs" id="brandOrientTabs" role="tablist" aria-label="오리엔시트 상태">' +
    BRAND_ORIENT_TABS.map(t => {
      const on = t.key === _brandOrientTab;
      const n = has ? sheets.filter(r => brandOrientInTab(r, t.key)).length : null;
      return '<button type="button" role="tab" class="bo-tab' + (on ? ' is-on' : '') + '" aria-selected="' + on + '" data-bo-act="tab" data-tab="' + t.key + '">' +
        '<span class="bo-tab-name">' + brandEsc(t.label) + '</span>' +
        (n != null ? '<span class="bo-tab-count">' + n + '</span>' : '') + '</button>';
    }).join('') + '</div>';
}

function _brandOrientViewToggleHtml() {
  const v = _brandOrientView;
  const b = (key, label, icon) => '<button type="button" class="bo-view-btn' + (v === key ? ' is-on' : '') + '" aria-pressed="' + (v === key) + '" data-bo-act="view-' + key + '">' +
    '<span class="bo-view-icon ' + icon + '" aria-hidden="true"><i></i><i></i><i></i><i></i></span>' + label + '</button>';
  return '<div class="bo-view" role="group" aria-label="보기 방식">' + b('list', '리스트', 'is-list') + b('card', '카드', 'is-card') + '</div>';
}

function _brandOrientStateHtml(kind, title, desc, withRetry) {
  return '<div class="bo-state" ' + (kind === 'error' ? 'role="alert"' : '') + '>' +
    '<span class="bo-state-icon is-' + kind + '" aria-hidden="true">' +
      (kind === 'error' ? '!' : '<span class="material-icons-round notranslate" translate="no">checklist</span>') + '</span>' +
    '<p class="bo-state-title">' + brandEsc(title) + '</p>' +
    '<p class="bo-state-desc">' + brandEsc(desc) + '</p>' +
    (withRetry ? '<button type="button" class="brand-btn bo-state-btn" data-bo-act="retry">다시 시도</button>' : '') +
  '</div>';
}

function _brandOrientRowsHtml(rows, serverNow) {
  const body = rows.map(r => {
    const st = r.view_status;
    const d = _boDLeft(r, serverNow);
    const isNew = st === 'new';
    const goods = r.goods_code ? brandEsc(r.goods_code) : _boDash();
    return '<tr class="bo-row' + (isNew ? ' is-new' : '') + (st === 'expired' ? ' is-expired' : '') + '" data-bo-act="open" data-sheet-id="' + brandEsc(r.id) + '"' +
      (isNew ? ' tabindex="0" aria-label="' + brandEsc((r.orient_no || '') + ' 작성 시작') + '"' : '') + '>' +
      '<td data-label="오리엔시트 번호">' + brandEsc(r.orient_no || '') + '</td>' +
      '<td class="c-center" data-label="모집 형식">' + (brandEsc(_boTypeText(r)) || _boDash()) + '</td>' +
      '<td data-label="게시 채널">' + (brandEsc(_boChannelText(r)) || _boDash()) + '</td>' +
      '<td data-label="추가 옵션">' + (brandEsc(_boMarketsText(r)) || _boDash()) + '</td>' +
      '<td class="c-center" data-label="상품 번호">' + goods + '</td>' +
      '<td class="c-center" data-label="상태">' + brandEsc(_boStatusLabel(r)) + _boDraftMark(r) + '</td>' +
      '<td data-label="발급일">' + (brandEsc(brandFormatDate(r.issued_at)) || _boDash()) + '</td>' +
      '<td data-label="작성기한">' + (brandEsc(brandFormatDate(r.deadline_at)) || _boDash()) + (d ? '<span class="bo-dleft">' + d + '</span>' : '') + '</td>' +
      '<td data-label="제출일시">' + (brandEsc(brandFormatDateTime(r.last_submitted_at)) || _boDash()) + '</td>' +
      '<td data-label="최근 수정">' + (_boEditedHtml(r, false) || _boDash()) + '</td>' +
      '<td class="c-act" data-label="관리">' + (isNew ? _boDash() :
        '<button type="button" class="bo-detail-btn" data-bo-act="open" data-sheet-id="' + brandEsc(r.id) + '">상세</button>') + '</td>' +
    '</tr>';
  }).join('');
  return '<div class="bo-table-scroll"><table class="bo-table">' +
    '<thead><tr><th class="w-no">오리엔시트 번호</th><th class="w-type">모집 형식</th><th class="w-ch">게시 채널</th><th class="w-opt">추가 옵션</th>' +
    '<th class="w-goods">상품 번호</th><th class="w-st">상태</th><th class="w-iss">발급일</th><th class="w-dl">작성기한</th>' +
    '<th class="w-sub">제출일시</th><th class="w-ed">최근 수정</th><th class="w-act">관리</th></tr></thead>' +
    '<tbody>' + body + '</tbody></table></div>';
}

function _boCardInfo(label, valueHtml) {
  return '<div class="bo-card-info-row"><span class="bo-card-info-label">' + brandEsc(label) + '</span><span class="bo-card-info-val">' + valueHtml + '</span></div>';
}
function _brandOrientCardsHtml(rows, serverNow) {
  return '<div class="bo-cards">' + rows.map(r => {
    const st = r.view_status;
    const s = BRAND_ORIENT_STATUS[st] || BRAND_ORIENT_STATUS.expired;
    const d = _boDLeft(r, serverNow);
    const typeCh = [_boTypeText(r), _boChannelText(r)].filter(Boolean).join(' · ');
    const markets = _boMarketsText(r);
    let sub = '';
    if (st === 'expired') sub = '기한이 지나 작성할 수 없습니다';
    else if (r.goods_code) sub = '상품번호 ' + r.goods_code;
    const deadline = brandEsc(brandFormatDate(r.deadline_at)) + (d ? '<span class="bo-dleft is-card">' + d + '</span>' : '');
    // 정보 줄 — 피그마 bw04-00a·bm04-00 의 상태별 조합
    const info = [];
    if (markets) info.push(_boCardInfo('추가 옵션', brandEsc(markets)));
    if (st === 'new') { info.push(_boCardInfo('발급일', brandEsc(brandFormatDate(r.issued_at)))); info.push(_boCardInfo('작성 기한', deadline)); }
    else if (st === 'editing') { info.push(_boCardInfo('작성 기한', deadline)); }
    else if (st === 'submitted') { info.push(_boCardInfo('제출', brandEsc(brandFormatDateTime(r.last_submitted_at)) + _boDraftMark(r))); }
    else if (st === 'registered') { info.push(_boCardInfo('발급일', brandEsc(brandFormatDate(r.issued_at)))); if (r.last_submitted_at) info.push(_boCardInfo('제출', brandEsc(brandFormatDateTime(r.last_submitted_at)))); }
    else if (st === 'expired') { info.push(_boCardInfo('작성 기한', brandEsc(brandFormatDate(r.deadline_at)))); }
    if ((st === 'editing' || st === 'submitted') && r.last_edited_at) info.push(_boCardInfo('최근 수정', _boEditedHtml(r, true)));
    return '<article class="bo-card' + (st === 'expired' ? ' is-expired' : '') + '">' +
      '<button type="button" class="bo-card-hit" data-bo-act="open" data-sheet-id="' + brandEsc(r.id) + '" aria-label="' + brandEsc((r.orient_no || '') + ' ' + _boStatusLabel(r) + ' 열기') + '"></button>' +
      '<div class="bo-card-top"><span class="bo-card-no">' + brandEsc(r.orient_no || '') + '</span>' +
        '<span class="bo-badge ' + s.cls + '">' + brandEsc(_boStatusLabel(r)) + '</span></div>' +
      '<div class="bo-card-title"><div><p class="bo-card-name">' + brandEsc(typeCh) + '</p>' +
        (sub ? '<p class="bo-card-sub">' + brandEsc(sub) + '</p>' : '') + '</div>' +
        '<span class="bo-card-chev" aria-hidden="true">›</span></div>' +
      (info.length ? '<div class="bo-card-info">' + info.join('') + '</div>' : '') +
      (st === 'new' ? '<button type="button" class="bo-start-btn" data-bo-act="start" data-sheet-id="' + brandEsc(r.id) + '">작성 시작</button>' : '') +
    '</article>';
  }).join('') + '</div>';
}

function renderBrandOrient(host) {
  const d = _brandOrientList;
  const loading = d === undefined || (d && d.brandId !== getCurrentBrandId());
  const sheets = (!loading && d) ? d.sheets : null;
  const view = _brandOrientEffectiveView();
  let body;
  let shownCount = null;
  if (loading) body = '<div class="bo-state" aria-busy="true"><p class="bo-state-desc">불러오는 중…</p></div>';
  else if (d === null) body = _brandOrientStateHtml('error', BRAND_ORIENT_MSG.loadFailTitle, BRAND_ORIENT_MSG.loadFailDesc, true);
  else if (!sheets.length) body = _brandOrientStateHtml('empty', BRAND_ORIENT_MSG.emptyTitle, BRAND_ORIENT_MSG.emptyDesc, false);
  else {
    const rows = sheets.filter(r => brandOrientInTab(r, _brandOrientTab));
    shownCount = rows.length;
    if (!rows.length) {
      const e = BRAND_ORIENT_TAB_EMPTY[_brandOrientTab] || BRAND_ORIENT_TAB_EMPTY.editing;
      body = _brandOrientStateHtml('empty', e.title, e.desc, false);
    } else {
      body = view === 'card' ? _brandOrientCardsHtml(rows, d.serverNow) : _brandOrientRowsHtml(rows, d.serverNow);
    }
  }
  host.innerHTML = '<div id="brandOrientPage" class="bo-page">' + _brandOrientHeadHtml() +
    _brandOrientTabsHtml(sheets) +
    '<section class="bo-panel" aria-label="오리엔시트 목록">' +
      '<div class="bo-panel-head"><h2>오리엔시트 목록' + (shownCount != null ? '<span class="bo-tab-count">' + shownCount + '</span>' : '') + '</h2>' +
        _brandOrientViewToggleHtml() + '</div>' +
      '<div id="brandOrientList" class="bo-list is-' + view + '">' + body + '</div>' +
    '</section></div>';
}

function _rerenderOrientIfShown() {
  if (location.hash !== '#orient' || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (!host) return;
  // 탭·보기 단추에 있던 초점을 다시 그린 뒤에도 같은 단추로 돌린다(Tab 이동이 끊기지 않게)
  const a = document.activeElement;
  const keep = a && host.contains(a) && a.dataset ? (a.dataset.boAct + '|' + (a.dataset.tab || '')) : null;
  renderBrandOrient(host);
  if (keep) {
    const [act, tab] = keep.split('|');
    const el = host.querySelector('[data-bo-act="' + act + '"]' + (tab ? '[data-tab="' + tab + '"]' : ''));
    if (el) el.focus();
  }
}

// 목록 받기 — 실패 null · not_found(연결이 풀림)는 로그인 판정을 다시 받는다(기본값 4)
async function loadBrandOrientList() {
  const brandId = getCurrentBrandId();
  if (!brandId) return;
  const seq = ++_brandOrientLoadSeq;
  if (!_brandOrientList || _brandOrientList.brandId !== brandId) { _brandOrientList = undefined; _rerenderOrientIfShown(); }
  const { data, error } = await brandRpc('get_my_orient_sheets', { p_brand_id: brandId });
  if (seq !== _brandOrientLoadSeq) return;   // 그사이 브랜드가 바뀌거나 다시 불렀다
  if (!error && data && data.success === false && data.reason === 'not_found') {
    _brandOrientList = null;
    const state = await refreshBrandLoginState();   // 연결이 풀렸으면 판정이 다른 브랜드·안내로 보낸다
    if (state && state.state === 'ok' && getCurrentBrandId() !== brandId) return;   // 다른 브랜드로 옮겨 감 — 그쪽 목록을 받는다
    _rerenderOrientIfShown();
    return;
  }
  if (error || !data || data.success !== true || !Array.isArray(data.sheets)) { _brandOrientList = null; _rerenderOrientIfShown(); return; }
  _brandOrientList = { brandId, serverNow: data.server_now || null, sheets: data.sheets };
  _rerenderOrientIfShown();
}

// ── 시트 열기 — 조각 6·7 이 채운다(상태별 갈래: 작성 모달 · 완료 · 만료 01b · 등록 01c · 옛 구조 안내)
//   opts.prefetched = 「가려던 시트」가 브랜드 확인용으로 이미 받은 get_my_orient_sheet 응답 — 조각 6 은 이것이 있으면 다시 부르지 않는다
function openBrandOrientSheet(sheetId, opts) {
  if (!sheetId) return;
  brandToast('오리엔시트 작성 화면은 준비 중입니다.');
}

// ── 「가려던 시트」(기본값 7) — 메일 링크 ?orient=<시트 번호> · 옛 링크 이동 ?orient_token=<토큰>
//   부팅 때 세션 저장소에 옮기고 주소에서 곧바로 지운다(토큰을 주소·방문 기록에 남기지 않는다). 오리엔시트 페이지가 그릴 때 한 번 꺼낸다.
//   ⚠️ 로그인 직후 소비되는 것은 첫 페이지가 오리엔시트라서다(BRAND_FIRST_PAGE = 'orient', brand-shell.js) — 첫 페이지를 바꾸면
//      로그인 뒤 그 페이지에서도 consumeBrandOrientTarget 을 부르게 해야 한다(안 그러면 값이 세션 저장소에 남은 채 안 열린다).
function captureBrandOrientTarget(params) {
  const sheet = params.get('orient');
  const token = params.get('orient_token');
  if (!sheet && !token) return;
  const kind = token ? 'token' : 'sheet';
  const value = token || sheet;
  if (BRAND_UUID_RE.test(value)) {
    try { sessionStorage.setItem(BRAND_ORIENT_TARGET_KEY, JSON.stringify({ kind, value })); } catch (e) { /* 저장소 막힘 — 목록만 */ }
  }
  params.delete('orient');
  params.delete('orient_token');
  const q = params.toString();
  history.replaceState(null, '', location.pathname + (q ? '?' + q : '') + location.hash);
}

let _brandOrientConsuming = false;
async function consumeBrandOrientTarget() {
  if (_brandOrientConsuming || !brandAuthed) return;
  let t = null;
  try { t = JSON.parse(sessionStorage.getItem(BRAND_ORIENT_TARGET_KEY) || 'null'); sessionStorage.removeItem(BRAND_ORIENT_TARGET_KEY); } catch (e) { t = null; }
  if (!t || !t.value || !BRAND_UUID_RE.test(t.value)) return;
  _brandOrientConsuming = true;
  try {
    let sheetId = null, brandId = null, prefetched = null;
    // 호출 실패 — 목적지를 되돌려 두고(다음에 이 페이지를 그릴 때 다시) 안내만
    const keepAndWarn = () => {
      try { sessionStorage.setItem(BRAND_ORIENT_TARGET_KEY, JSON.stringify(t)); } catch (e) { /* 저장소 막힘 */ }
      brandToast(BRAND_ORIENT_MSG.openFail, { error: true });
    };
    if (t.kind === 'token') {
      const { data, error } = await brandRpc('resolve_my_orient_link', { p_token: t.value });
      if (error || !data) { keepAndWarn(); return; }
      if (data.success !== true) { brandToast(BRAND_ORIENT_MSG.cannotOpen, { error: true }); return; }
      sheetId = data.sheet_id; brandId = data.brand_id;
    } else {
      const { data, error } = await brandRpc('get_my_orient_sheet', { p_sheet_id: t.value });
      if (error || !data) { keepAndWarn(); return; }
      if (data.success !== true && data.reason === 'not_found') { brandToast(BRAND_ORIENT_MSG.cannotOpen, { error: true }); return; }
      sheetId = t.value; brandId = data.brand_id || null; prefetched = data;   // 만료 거부(expired)에는 brand_id 가 없다 — 지금 브랜드에서 연다
    }
    // 시트 브랜드가 지금 브랜드와 다르면 그 브랜드로 바꾼 뒤 연다(의심 14)
    if (brandId && brandId !== getCurrentBrandId()) {
      const r = await switchBrand(brandId);
      if (r !== 'ok') return;
    }
    openBrandOrientSheet(sheetId, { prefetched });
  } finally {
    _brandOrientConsuming = false;
  }
}

registerBrandPage('orient', {
  title: '오리엔시트',
  render(host) {
    renderBrandOrient(host);
    // 페이지에 들어올 때마다 새로 받는다(운영팀이 발급·등록했을 수 있다)
    loadBrandOrientList();
    consumeBrandOrientTarget();
  }
});

onBrandChanged(() => { _brandOrientList = undefined; _brandOrientLoadSeq++; });   // 옛 브랜드 응답은 버린다
_brandOrientMobileMq.addEventListener('change', () => _rerenderOrientIfShown());

// 페이지 안 단추(위임)
document.addEventListener('click', (e) => {
  const el = e.target.closest('#brandPageHost [data-bo-act]');
  if (!el || el.disabled) return;
  const act = el.dataset.boAct;
  if (act === 'tab') { _brandOrientTab = el.dataset.tab; _rerenderOrientIfShown(); return; }
  if (act === 'view-list' || act === 'view-card') {
    _brandOrientView = act === 'view-card' ? 'card' : 'list';
    _brandOrientSaveView(_brandOrientView);
    _rerenderOrientIfShown();
    return;
  }
  if (act === 'retry') { el.disabled = true; loadBrandOrientList(); return; }
  if (act === 'open' || act === 'start') {
    e.stopPropagation();
    openBrandOrientSheet(el.dataset.sheetId);
  }
});
// 리스트 줄은 키보드로도 연다(줄 자체는 단추가 아니므로 「상세」 단추가 Tab 대상 — 신규 줄은 줄에 초점)
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  const row = e.target.closest && e.target.closest('#brandPageHost tr.bo-row[tabindex]');
  if (!row || e.target !== row) return;
  e.preventDefault();
  openBrandOrientSheet(row.dataset.sheetId);
});
