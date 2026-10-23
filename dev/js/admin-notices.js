// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-notices.js
// ═════════════════════════════════════════════════════════════════
//
// 관리자 공지사항 페인 (admin.js 파일 분리).
//   · 페인 목록/렌더/배지 (loadAdminNotices/renderAdminNotices/refreshAdminNoticeBadge)
//   · 보기/편집/게시/회수/삭제 모달 (openAdminNoticeView/openAdminNoticeEdit/onSaveAdminNotice 등)
//   · 대시보드 카드 + 로그인 미읽음 팝업 (renderDashboardNotices/showAdminUnreadNoticesIfAny)
//   · 상태/상수: _adminNoticesCache/_adminNoticeCurrent/_adminNoticeQuill/ADMIN_NOTICE_CAT_LABEL/ADMIN_NOTICE_CAT_STYLE
//
// ⚠ loadAdminData(대시보드)·로그인 부트가 renderDashboardNotices/showAdminUnreadNoticesIfAny
//   /refreshAdminNoticeBadge 를 호출 → 전역 함수로 유지(이름 변경 금지). 빌드 순서상 admin.js 보다 앞.
// ═════════════════════════════════════════════════════════════════

var _adminNoticesCache = [];
var _adminNoticeCurrent = null;
var _adminNoticeQuill = null;
// 공지 보기 모달 본문 — 편집기와 동일한 Quill(읽기 전용)로 렌더해 "편집 = 보기" 일치
var _adminNoticeViewQuill = null;

// 공지 본문을 편집기와 "동일한 Quill 엔진"으로 렌더(읽기 전용).
// 정적 .rich-content 로 그리면 목록 마커·단락 여백이 Quill 편집기와 달라 두 화면이
// 어긋나므로, 보기 화면도 같은 Quill 2 + quill.snow.css 로 그려 구조적으로 일치시킨다.
// Quill 미로드 시 기존 renderRich 로 폴백.
function renderNoticeBodyRich(el, raw) {
  if (!el) return;
  const value = raw == null ? '' : String(raw);
  const looksHtml = /<[a-z][\s\S]*>/i.test(value);
  // 평문(legacy) 공지는 줄바꿈을 <br> 로 보존 (renderRich 와 동일 정책)
  const html = looksHtml
    ? ((typeof sanitizeRich === 'function') ? sanitizeRich(value) : value)
    : value.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>');
  if (typeof Quill === 'undefined') {
    if (typeof renderRich === 'function') renderRich(el, raw);
    else el.innerHTML = html;
    return;
  }
  if (!_adminNoticeViewQuill || _adminNoticeViewQuill.container !== el) {
    el.classList.add('notice-view-quill');
    el.classList.remove('rich-content');
    _adminNoticeViewQuill = new Quill(el, {
      theme: 'snow',
      readOnly: true,
      modules: { toolbar: false },
      formats: ['header','bold','italic','underline','strike','list','link','blockquote']
    });
  }
  _adminNoticeViewQuill.setContents([]);
  _adminNoticeViewQuill.clipboard.dangerouslyPasteHTML(html, 'silent');
}

const ADMIN_NOTICE_CAT_LABEL = {
  system_update: '시스템 업데이트',
  release: '릴리스',
  warning: '경고',
  general: '일반',
};
// 공지 종류 라벨 — 네 가지 모두 같은 포인트 컬러 스타일로 통일(연보라 배경 + 보라 글자, 6.07:1).
// 배지에 이름이 이미 쓰여 있어 색으로 종류를 구분할 필요가 없다.
// ⚠️ 「주의」도 같은 색이라 목록을 훑을 때 위험 공지가 눈에 띄지 않는다 —
//    구분이 필요해지면 warning 만 var(--red-l)/var(--red-d) 로 되돌리면 된다.
const NOTICE_LABEL_STYLE = 'background:var(--accent-tint);color:var(--accent-deep)';
const ADMIN_NOTICE_CAT_STYLE = {
  system_update: NOTICE_LABEL_STYLE,
  release: NOTICE_LABEL_STYLE,
  warning: NOTICE_LABEL_STYLE,
  general: NOTICE_LABEL_STYLE,
};

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-NOTICES — 공지사항 페인 + 대시보드 카드 + 미읽음 팝업
// ════════════════════════════════════════════════════════════════════

function adminNoticeCatPill(cat) {
  const style = ADMIN_NOTICE_CAT_STYLE[cat] || ADMIN_NOTICE_CAT_STYLE.general;
  return `<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;${style}">${esc(ADMIN_NOTICE_CAT_LABEL[cat]||cat)}</span>`;
}

// ── 보일 곳(관리자 / 브랜드 페이지) — 사양서 2026-07-15-brand-portal.md §16-8 표 3번 · 피그마 a11 · 마이그레이션 593 ──
// 🔴 출시 잠금: 보일 곳 칩·거르기·열은 _brandAccountEnabled()(개발서버)일 때만 — 운영 admin_notices 에는 새 칸이 없다.
//    관리자 공지 저장은 새 칸을 보내지 않는다. 출시 날 _noticeAudienceOn() 판정을 걷는다.
function _noticeAudienceOn() {
  return typeof _brandAccountEnabled === 'function' && _brandAccountEnabled();
}
// 관리자가 읽을 공지인가 — audience 가 없거나(운영처럼 칸이 없는 서버 포함) 'admin' 이면 참.
// 🔴 미읽음을 세는 자리(사이드바 배지·로그인 팝업·대시보드 카드·목록 「미읽음만」·읽음 칸·자동 읽음)는 모두 이 판정 하나를 쓴다.
//    조회(fetchAdminNotices)에서 거르지 않는다 — 목록은 브랜드 공지도 보여야 하고 캐시를 대시보드와 같이 쓴다
function isAdminAudienceNotice(n) {
  return !n || !n.audience || n.audience === 'admin';
}
const ADMIN_NOTICE_BRAND_KIND_LABEL = { terms: '약관', maintenance: '점검', outage: '장애', info: '안내' };

function adminNoticeAudiencePill(n) {
  return isAdminAudienceNotice(n)
    ? '<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;background:var(--surface-dim);color:var(--ink)">관리자</span>'
    : `<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;${NOTICE_LABEL_STYLE}">브랜드 페이지</span>`;
}

// 카테고리 칸 꼬리표 — 브랜드 페이지 공지는 카테고리 대신 종류 이름
function adminNoticeKindPill(n) {
  if (isAdminAudienceNotice(n)) return adminNoticeCatPill(n.category);
  const label = ADMIN_NOTICE_BRAND_KIND_LABEL[n.brand_kind];
  if (!label) return '<span style="font-size:11px;color:var(--muted)">—</span>';
  return `<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;${NOTICE_LABEL_STYLE}">${esc(label)}</span>`;
}

// 게시된 브랜드 공지의 「도움말」 보일 기간 밖 표시 — 'before' | 'after' | null (기기 시각 기준, 표시용)
function adminNoticeHelpWindowState(n) {
  if (isAdminAudienceNotice(n) || n.status !== 'published') return null;
  const now = Date.now();
  const from = n.help_show_from ? new Date(n.help_show_from).getTime() : NaN;
  const until = n.help_show_until ? new Date(n.help_show_until).getTime() : NaN;
  if (!isNaN(from) && now < from) return 'before';
  if (!isNaN(until) && now > until) return 'after';
  return null;
}

// 날짜·시각 입력 칸 값 — 값이 없으면 빈칸(csToLocalInput(null) 은 「지금」을 돌려주므로 감싼다)
function _noticeToLocalInput(iso) {
  return iso ? csToLocalInput(iso) : '';
}

// migration 071: 게시 상태 pill (draft/published)
function adminNoticeStatusPill(status) {
  if (status === 'published') {
    return '<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;background:#E8F5E9;color:#2E7D32">게시</span>';
  }
  return '<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;background:#EEEEEE;color:#616161">초안</span>';
}

async function loadAdminNotices() {
  _adminNoticesCache = await fetchAdminNotices();
  renderAdminNotices();
  refreshAdminNoticeBadge();
}

// 사이드바 배지: published 미읽음만 카운트
function refreshAdminNoticeBadge() {
  const badge = $('adminNoticesBadge');
  if (!badge) return;
  const unread = (_adminNoticesCache || []).filter(n => isAdminAudienceNotice(n) && n.status === 'published' && !n.is_read).length;
  if (unread > 0) { badge.textContent = unread > 9 ? '9+' : unread; badge.style.display = ''; }
  else badge.style.display = 'none';
}

// 카테고리 탭 (단일 선택, ''=전체). 구 드롭다운 adminNoticeCatFilter 를 대체.
//   공지 1건 = 카테고리 4종 중 하나로 상호 배타라 탭(단일)이 개념에 맞음.
var _adminNoticeCatTab = '';

// 카테고리 탭 정의 — 순서는 구 드롭다운·ADMIN_NOTICE_CAT_LABEL 과 동일
const ADMIN_NOTICE_CAT_TABS = [
  { code: '',              label: '전체' },
  { code: 'system_update', label: ADMIN_NOTICE_CAT_LABEL.system_update },
  { code: 'release',       label: ADMIN_NOTICE_CAT_LABEL.release },
  { code: 'warning',       label: ADMIN_NOTICE_CAT_LABEL.warning },
  { code: 'general',       label: ADMIN_NOTICE_CAT_LABEL.general },
];

// 카테고리 탭 바 렌더 — 건수는 renderAdminNotices 가 넘겨준 집계(카테고리 외 필터만 적용).
//   전체 탭 = 그 집계의 합(카테고리가 4종 밖인 legacy 행도 합에는 들어간다).
function renderAdminNoticeCatTabs(countsMap, totalAll) {
  const bar = $('adminNoticeCatTabBar');
  if (!bar) return;
  const c = countsMap || {};
  const active = _adminNoticeCatTab || '';
  bar.innerHTML = ADMIN_NOTICE_CAT_TABS.map(tab => {
    const n = tab.code === '' ? (totalAll || 0) : (c[tab.code] || 0);
    const isOn = tab.code === active;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-cat="${tab.code}" onclick="setAdminNoticeCatTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

// 카테고리 탭 클릭 → 단일 카테고리 필터로 목록 재렌더 (활성 표시는 renderAdminNotices 내부 재렌더로 갱신)
function setAdminNoticeCatTab(btn) {
  _adminNoticeCatTab = btn.dataset.cat || '';
  renderAdminNotices();
}

// 사이드바 공지 배지 클릭 → 다른 필터 초기화 후 「미읽음만」 (기준: openDelivPendingReview)
function openNoticesUnread() {
  _adminNoticeCatTab = '';
  const st = document.getElementById('adminNoticeStatusFilter'); if (st) st.value = 'all';
  const au = document.getElementById('adminNoticeAudienceFilter'); if (au) au.value = 'all';
  const sch = document.getElementById('adminNoticeSearch'); if (sch) sch.value = '';
  const un = document.getElementById('adminNoticeUnreadFilter'); if (un) un.checked = true;
  if (typeof navAdminPaneReload === 'function') navAdminPaneReload('admin-notices');
  else renderAdminNotices();
}

function renderAdminNotices() {
  const body = $('adminNoticeBody');
  if (!body) return;
  const cat = _adminNoticeCatTab || '';
  const status = $('adminNoticeStatusFilter')?.value || 'all';
  const q = ($('adminNoticeSearch')?.value || '').trim().toLowerCase();
  const unreadOnly = $('adminNoticeUnreadFilter')?.checked;
  const audOn = _noticeAudienceOn();
  _syncNoticeAudienceListUi(audOn);
  const aud = audOn ? ($('adminNoticeAudienceFilter')?.value || 'all') : 'all';
  let list = (_adminNoticesCache || []).slice();
  if (status !== 'all') list = list.filter(n => (n.status || 'draft') === status);
  if (aud === 'admin') list = list.filter(n => isAdminAudienceNotice(n));
  else if (aud === 'brand') list = list.filter(n => !isAdminAudienceNotice(n));
  if (q) list = list.filter(n => (n.title || '').toLowerCase().includes(q));
  // 미읽음만 = 관리자 공지 + 게시됨 + 안 읽음 (사이드바 배지 정의와 동일)
  if (unreadOnly) list = list.filter(n => isAdminAudienceNotice(n) && n.status === 'published' && !n.is_read);
  // 카테고리 탭 건수 = 자기 필터(카테고리)를 뺀 나머지 필터만 적용한 집계 → 탭을 눌러도 다른 탭 숫자가 안 변한다
  // ⚠️ 세는 열쇠와 거르는 열쇠가 같아야 한다(`n.category` 그대로) — 빈 값에 기본 카테고리를 씌워 세면
  //    그 행은 「일반」 숫자에는 들어가고 「일반」 탭 목록에는 안 나온다. DB 는 4종 NOT NULL(마이그레이션 063).
  const catCounts = {};
  list.forEach(n => { const k = n.category; if (k) catCounts[k] = (catCounts[k] || 0) + 1; });
  renderAdminNoticeCatTabs(catCounts, list.length);
  // 보일 곳 「브랜드 페이지」 거르기에서는 카테고리 탭이 전부 0건이라 탭 줄을 감추고 탭 거르기도 쓰지 않는다
  const catBar = $('adminNoticeCatTabBar');
  if (catBar) catBar.style.display = aud === 'brand' ? 'none' : '';
  if (cat !== '' && aud !== 'brand') list = list.filter(n => n.category === cat);
  const total = $('adminNoticeTotal');
  if (total) total.textContent = `${list.length}건`;
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const canEdit = (n) => isSuper || n.created_by === currentUser?.id;
  body.innerHTML = list.length ? list.map(n => {
    const isPub = n.status === 'published';
    const isAdm = isAdminAudienceNotice(n);
    // 브랜드 페이지 공지는 관리자가 읽을 공지가 아니라 읽음 칸 「—」·강조 없음
    const showUnread = isAdm && isPub && !n.is_read;
    const unreadDot = showUnread ? `<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:#C62828;margin-right:4px;vertical-align:middle"></span>` : '';
    const readCellInner = (!isPub || !isAdm)
      ? '<span style="font-size:11px;color:var(--muted)">—</span>'
      : (n.is_read
          ? '<span style="font-size:11px;color:var(--muted)">읽음</span>'
          : '<span style="font-size:11px;color:#C62828;font-weight:700">미읽음</span>');
    const pinIcon = n.is_pinned ? `<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--pink);vertical-align:-2px" title="상단 고정">push_pin</span> ` : '';
    const dateStr = isPub
      ? (n.published_at ? formatDateTime(n.published_at) : (n.created_at ? formatDateTime(n.created_at) : ''))
      : (n.created_at ? `<span style="color:#999">— · ${formatDateTime(n.created_at)} 작성</span>` : '');
    const winState = adminNoticeHelpWindowState(n);
    const winNote = winState ? ` <span style="font-size:10px;color:var(--muted);white-space:nowrap">${winState === 'before' ? '노출 전' : '노출 끝'}</span>` : '';
    const audCell = audOn ? `<td style="white-space:nowrap">${adminNoticeAudiencePill(n)}${winNote}</td>` : '';
    return `<tr data-id="${esc(n.id)}" style="cursor:pointer;${showUnread?'background:#FFFBEF':''}" onclick="openAdminNoticeView(this.dataset.id)">
      <td>${unreadDot}${readCellInner}</td>
      <td>${adminNoticeStatusPill(n.status)}</td>
      ${audCell}
      <td>${adminNoticeKindPill(n)}</td>
      <td style="font-weight:${(isAdm && !n.is_read)?'600':'400'};color:var(--ink)">${pinIcon}${esc(n.title)}</td>
      <td style="font-size:12px;color:var(--muted)">${esc(n.created_by_name || '—')}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${dateStr}</td>
      <td>${canEdit(n) ? `<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openAdminNoticeEdit(this.closest('tr').dataset.id)"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">edit</span> 수정</button>` : ''}</td>
    </tr>`;
  }).join('') : `<tr><td colspan="${document.querySelectorAll('#adminNoticeTable thead th').length || 7}" style="text-align:center;color:var(--muted);padding:24px">공지 없음</td></tr>`;
}

// 목록의 보일 곳 부품(머리 부제·거르기·「보일 곳」 열 머리) — 판정이 참일 때만.
// 열 머리는 HTML 에 두지 않고 여기서 한 번 끼워 넣는다 → 운영 HTML 은 7열 그대로, 빈 줄 칸 수는 머리 칸을 세서 맞춘다
function _syncNoticeAudienceListUi(on) {
  const sub = $('adminNoticeBrandSub'); if (sub) sub.style.display = on ? '' : 'none';
  const fg = $('adminNoticeAudienceFilterGroup'); if (fg) fg.style.display = on ? '' : 'none';
  if (!on || $('adminNoticeAudienceTh')) return;
  const statusTh = $('adminNoticeStatusTh');
  if (!statusTh) return;
  const th = document.createElement('th');
  th.id = 'adminNoticeAudienceTh';
  th.style.width = '130px';
  th.textContent = '보일 곳';
  statusTh.after(th);
}

// 보기 모달. 자동 읽음 처리는 published 공지에만. 푸터 버튼은 권한·상태별 분기.
async function openAdminNoticeView(id) {
  const n = (_adminNoticesCache || []).find(x => x.id === id);
  if (!n) return;
  _adminNoticeCurrent = n;
  const isPub = n.status === 'published';
  const isAdm = isAdminAudienceNotice(n);
  $('adminNoticeViewTitle').innerHTML = esc(n.title);
  const dateBlock = isPub
    ? (n.published_at ? `<span>${formatDateTime(n.published_at)} 게시</span>` : '')
    : `<span style="color:#999">${n.created_at?formatDateTime(n.created_at)+' 작성':''}</span>`;
  // 브랜드 페이지 공지 — 보일 곳 꼬리표 + 종류 + 「도움말」 보일 기간을 그대로
  const audBlock = _noticeAudienceOn() ? adminNoticeAudiencePill(n) : '';
  const helpBlock = isAdm ? '' : `<span>「도움말」 노출 ${n.help_show_from ? formatDateTime(n.help_show_from) : '—'} ~ ${n.help_show_until ? formatDateTime(n.help_show_until) : '—'}</span>`;
  $('adminNoticeViewMeta').innerHTML = `${adminNoticeStatusPill(n.status)}${audBlock}${adminNoticeKindPill(n)}${helpBlock}<span>${esc(n.created_by_name || '—')}</span>${dateBlock}${n.is_pinned?'<span style="color:var(--pink);font-weight:700;display:inline-flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">push_pin</span>상단 고정</span>':''}`;
  const bodyEl = $('adminNoticeViewBody');
  renderNoticeBodyRich(bodyEl, n.body_html || '');
  // 푸터: 작성자/super 만 표시
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const canEdit = isSuper || n.created_by === currentUser?.id;
  const footer = $('adminNoticeViewFooter');
  if (footer) {
    footer.style.display = canEdit ? 'flex' : 'none';
    const editBtn = $('btnEditAdminNoticeFromView');
    const pubBtn = $('btnPublishAdminNoticeFromView');
    const unpubBtn = $('btnUnpublishAdminNoticeFromView');
    if (editBtn) editBtn.style.display = canEdit ? '' : 'none';
    if (pubBtn) pubBtn.style.display = canEdit && !isPub ? '' : 'none';
    if (unpubBtn) unpubBtn.style.display = canEdit && isPub ? '' : 'none';
  }
  openModal('adminNoticeViewModal');
  // 자동 읽음은 관리자 공지만 — 브랜드 페이지 공지는 upsert_admin_notice_read 를 부르지 않는다
  if (isAdm && isPub && !n.is_read) {
    try {
      await markAdminNoticeRead(id);
      n.is_read = true;
      refreshAdminNoticeBadge();
      renderAdminNotices();
      renderDashboardNotices();
    } catch(e) {}
  }
}

// 보기 모달에서 "수정" 클릭 → 편집 모달로 전환
function onEditAdminNoticeFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  closeModal('adminNoticeViewModal');
  openAdminNoticeEdit(id);
}

// 보기 모달에서 "지금 게시" 클릭
async function onPublishFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  const pubMsg = isAdminAudienceNotice(_adminNoticeCurrent)
    ? '이 공지를 지금 게시할까요? 모든 관리자에게 미읽음으로 노출됩니다.'
    : '이 공지를 지금 게시할까요? 브랜드 페이지의 모든 브랜드 계정에 보입니다.';
  if (!confirm(pubMsg)) return;
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  try {
    await publishAdminNotice(id, name);
    toast('게시되었습니다', 'success');
    closeModal('adminNoticeViewModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('게시 오류: ' + friendlyError(e.message || e), 'error'); }
}

// 보기 모달에서 "게시 회수" 클릭 — published → draft (published_at 유지)
async function onUnpublishFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  if (!confirm('이 공지를 회수(초안으로 되돌리기)할까요? 노출 채널에서 사라지며 작성자/super_admin 만 볼 수 있습니다.')) return;
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  try {
    await unpublishAdminNotice(id, name);
    toast('초안으로 되돌렸습니다', 'success');
    closeModal('adminNoticeViewModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('회수 오류: ' + friendlyError(e.message || e), 'error'); }
}

function openAdminNoticeEdit(id) {
  const n = id ? (_adminNoticesCache || []).find(x => x.id === id) : null;
  _adminNoticeCurrent = n;
  const isNew = !n;
  const isPub = n?.status === 'published';
  $('adminNoticeEditTitle').textContent = isNew ? '공지 작성' : (isPub ? '게시중인 공지 수정' : '초안 수정');
  $('anEditTitle').value = n?.title || '';
  $('anEditCategory').value = n?.category || 'system_update';
  $('anEditPinned').checked = !!(n?.is_pinned);
  // 보일 곳 — 새 공지에서만 고른다(저장된 공지는 잠금: 관리자 공지 저장에 새 칸을 보내지 않기 위해)
  _adminNoticeEditAudience = (n && !isAdminAudienceNotice(n)) ? 'brand' : 'admin';
  _adminNoticeEditKind = n?.brand_kind || '';
  _adminNoticeEditAudienceLocked = !!n;
  $('anEditHelpFrom').value = _noticeToLocalInput(n?.help_show_from);
  $('anEditHelpUntil').value = _noticeToLocalInput(n?.help_show_until);
  _syncNoticeEditAudienceUi();
  const delBtn = $('btnDeleteAdminNotice');
  if (delBtn) delBtn.style.display = n ? '' : 'none';
  // 푸터 버튼 분기:
  //   신규 / draft 편집  → [초안 저장] [게시하기]
  //   published 편집     → [게시 유지하며 저장] [초안으로 되돌리고 저장]
  const btnDraft     = $('btnSaveAdminNoticeDraft');
  const btnPublish   = $('btnPublishAdminNotice');
  const btnKeepPub   = $('btnSaveAdminNoticeKeepPublished');
  const btnRevertDr  = $('btnSaveAdminNoticeRevertDraft');
  if (btnDraft)    btnDraft.style.display    = isPub ? 'none' : '';
  if (btnPublish)  btnPublish.style.display  = isPub ? 'none' : '';
  if (btnKeepPub)  btnKeepPub.style.display  = isPub ? '' : 'none';
  if (btnRevertDr) btnRevertDr.style.display = isPub ? '' : 'none';
  // 상태 안내 pill (모달 푸터 좌측)
  const pillEl = $('adminNoticeEditStatusPill');
  if (pillEl) {
    if (isNew) pillEl.innerHTML = '';
    else if (isPub) pillEl.innerHTML = `${adminNoticeStatusPill('published')} <span style="font-size:11px;color:var(--muted)">${n.published_at?formatDateTime(n.published_at)+' 게시':''}</span>`;
    else pillEl.innerHTML = adminNoticeStatusPill('draft');
  }
  // HTML 모드 기본 off. 기존 공지 중 '<p>&lt;' 같이 태그가 텍스트로 저장된 케이스 감지 시 자동 HTML 모드
  const rawHtml = n?.body_html || '';
  const tagAsText = /&lt;\w+/.test(rawHtml);
  $('anEditHtmlMode').checked = tagAsText;
  $('anEditBodyRaw').value = rawHtml;
  openModal('adminNoticeEditModal');
  setTimeout(() => {
    if (!_adminNoticeQuill && typeof Quill !== 'undefined') {
      _adminNoticeQuill = new Quill('#anEditBodyQuill', {
        theme: 'snow',
        modules: { toolbar: [[{header:[2,3,4,false]}],['bold','italic','underline','strike'],[{list:'ordered'},{list:'bullet'}],['link','blockquote'],['clean']], clipboard:{matchVisual:false} },
        formats: ['header','bold','italic','underline','strike','list','link','blockquote']
      });
    }
    if (_adminNoticeQuill) {
      const initHtml = (typeof sanitizeRich === 'function') ? sanitizeRich(rawHtml) : rawHtml;
      _adminNoticeQuill.clipboard.dangerouslyPasteHTML(initHtml, 'silent');
    }
    toggleNoticeHtmlMode();
  }, 0);
}

var _adminNoticeEditAudience = 'admin';
var _adminNoticeEditKind = '';
var _adminNoticeEditAudienceLocked = false;

function setNoticeEditAudience(aud) {
  if (_adminNoticeEditAudienceLocked) return;
  _adminNoticeEditAudience = aud === 'brand' ? 'brand' : 'admin';
  _syncNoticeEditAudienceUi();
}
function setNoticeEditKind(kind) {
  _adminNoticeEditKind = ADMIN_NOTICE_BRAND_KIND_LABEL[kind] ? kind : '';
  _syncNoticeEditAudienceUi();
}
// 작성 모달 — 보일 곳에 따라 칸을 바꾼다. 관리자: 카테고리·상단 고정 / 브랜드 페이지: 종류·보일 기간·안내
function _syncNoticeEditAudienceUi() {
  const on = _noticeAudienceOn();
  const isBrand = on && _adminNoticeEditAudience === 'brand';
  const wrap = $('anEditAudienceWrap'); if (wrap) wrap.style.display = on ? '' : 'none';
  document.querySelectorAll('#anEditAudienceWrap [data-aud]').forEach(b => {
    const isOn = b.dataset.aud === _adminNoticeEditAudience;
    b.classList.toggle('on', isOn);
    b.setAttribute('aria-pressed', String(isOn));
    b.disabled = _adminNoticeEditAudienceLocked && !isOn;
  });
  const lock = $('anEditAudienceLockNote'); if (lock) lock.style.display = _adminNoticeEditAudienceLocked ? '' : 'none';
  const kindWrap = $('anEditBrandKindWrap'); if (kindWrap) kindWrap.style.display = isBrand ? '' : 'none';
  document.querySelectorAll('#anEditBrandKindWrap [data-kind]').forEach(b => {
    const isOn = b.dataset.kind === _adminNoticeEditKind;
    b.classList.toggle('on', isOn);
    b.setAttribute('aria-pressed', String(isOn));
  });
  const helpWrap = $('anEditHelpWrap'); if (helpWrap) helpWrap.style.display = isBrand ? '' : 'none';
  const cat = $('anEditCategory'); if (cat) cat.style.display = isBrand ? 'none' : '';
  const row = $('anEditTitleRow'); if (row) row.style.gridTemplateColumns = isBrand ? '1fr' : '1fr 140px';
  const pin = $('anEditPinnedLabel'); if (pin) pin.style.display = isBrand ? 'none' : '';
  // 브랜드 갈래는 칸이 늘어 모달 본문을 스크롤로 — 관리자 갈래(운영 포함)는 지금처럼 overflow:hidden 그대로
  const body = $('adminNoticeEditBody'); if (body) body.style.overflowY = isBrand ? 'auto' : 'hidden';
}

function toggleNoticeHtmlMode() {
  const isHtml = !!$('anEditHtmlMode')?.checked;
  const quillHost = $('anEditBodyQuill');
  const raw = $('anEditBodyRaw');
  const toolbar = document.querySelector('#adminNoticeEditModal .ql-toolbar');
  if (isHtml) {
    if (_adminNoticeQuill && raw.value === '') {
      // 2026-05-07: HTML source 토글 시에도 root.innerHTML 대신 getSemanticHTML 우선
      let extracted;
      try {
        extracted = (typeof _adminNoticeQuill.getSemanticHTML === 'function')
          ? _adminNoticeQuill.getSemanticHTML(0)
          : _adminNoticeQuill.root.innerHTML;
      } catch(_) {
        extracted = _adminNoticeQuill.root.innerHTML;
      }
      raw.value = extracted;
    }
    if (quillHost) quillHost.style.display = 'none';
    if (toolbar) toolbar.style.display = 'none';
    if (raw) raw.style.display = '';
  } else {
    if (_adminNoticeQuill && raw.value) {
      const initHtml = (typeof sanitizeRich === 'function') ? sanitizeRich(raw.value) : raw.value;
      _adminNoticeQuill.clipboard.dangerouslyPasteHTML(initHtml, 'silent');
    }
    if (raw) raw.style.display = 'none';
    if (quillHost) quillHost.style.display = '';
    if (toolbar) toolbar.style.display = '';
  }
}

// 저장 모드 4종:
//   'draft'           : 신규 INSERT 또는 draft UPDATE 후 status=draft 유지
//   'publish'         : 신규 INSERT 또는 draft UPDATE 후 status=published 전환
//   'keep_published'  : published 편집 — status=published 유지 (오탈자 즉시 수정)
//   'revert_draft'    : published 편집 — status=draft 회귀 (안전 우선 기본)
async function onSaveAdminNotice(mode) {
  const title = ($('anEditTitle')?.value || '').trim();
  const category = $('anEditCategory')?.value || 'general';
  const is_pinned = !!$('anEditPinned')?.checked;
  if (!title) { toast('제목을 입력해주세요', 'error'); return; }
  // 브랜드 페이지 공지 — 판정이 참이고 보일 곳이 브랜드일 때만 새 칸을 읽고 보낸다(숨은 칸 값은 읽지 않는다).
  // 종류·기간은 데이터베이스 묶음 제약(593)보다 먼저 여기서 검사해 데이터베이스 오류 문구가 그대로 뜨지 않게 한다
  const isBrand = _noticeAudienceOn() && _adminNoticeEditAudience === 'brand';
  let brandFields = null;
  if (isBrand) {
    if (!ADMIN_NOTICE_BRAND_KIND_LABEL[_adminNoticeEditKind]) { toast('종류(약관·점검·장애·안내)를 골라 주세요', 'error'); return; }
    const help_show_from = csFromLocalInput($('anEditHelpFrom')?.value);
    const help_show_until = csFromLocalInput($('anEditHelpUntil')?.value);
    if (!help_show_from || !help_show_until) { toast('「도움말」 보일 기간의 시작과 끝을 모두 넣어 주세요', 'error'); return; }
    if (new Date(help_show_until) <= new Date(help_show_from)) { toast('보일 기간의 끝은 시작보다 뒤여야 합니다', 'error'); return; }
    brandFields = { brand_kind: _adminNoticeEditKind, help_show_from, help_show_until };
  }
  let body_html = '';
  const isHtmlMode = !!$('anEditHtmlMode')?.checked;
  if (isHtmlMode) {
    const raw = $('anEditBodyRaw')?.value || '';
    body_html = (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
  } else if (_adminNoticeQuill) {
    // 2026-05-07: root.innerHTML은 인접 리스트를 분리해 출력하는 버그가 있어
    // (공지 ol이 5개로 쪼개져 모두 "1."로 보임), Quill 2.x getSemanticHTML 우선 사용
    let raw;
    try {
      raw = (typeof _adminNoticeQuill.getSemanticHTML === 'function')
        ? _adminNoticeQuill.getSemanticHTML(0)
        : _adminNoticeQuill.root.innerHTML;
    } catch(_) {
      raw = _adminNoticeQuill.root.innerHTML;
    }
    body_html = (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
  }
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  const safeMode = mode || 'draft';
  try {
    if (_adminNoticeCurrent) {
      // 브랜드 공지 수정은 category·is_pinned 를 보내지 않는다(묶음 제약 admin_notices_audience_shape)
      const patch = brandFields
        ? {title, body_html, ...brandFields, updated_by_name: name}
        : {title, body_html, category, is_pinned, updated_by_name: name};
      if (safeMode === 'publish' || safeMode === 'keep_published') patch.status = 'published';
      else if (safeMode === 'revert_draft') patch.status = 'draft';
      // 'draft' 모드 (draft 편집): status 유지
      await updateAdminNotice(_adminNoticeCurrent.id, patch);
      const okMsg = safeMode === 'publish' ? '게시되었습니다'
                  : safeMode === 'keep_published' ? '게시 유지하며 저장되었습니다'
                  : safeMode === 'revert_draft' ? '초안으로 되돌리고 저장되었습니다'
                  : '초안 저장되었습니다';
      toast(okMsg, 'success');
    } else {
      const wantPublish = safeMode === 'publish';
      const base = {title, body_html, created_by_name: name, status: wantPublish ? 'published' : 'draft'};
      await insertAdminNotice(brandFields
        ? {...base, audience: 'brand', ...brandFields}
        : {...base, category, is_pinned});
      toast(wantPublish ? '게시되었습니다' : '초안 저장되었습니다', 'success');
    }
    closeModal('adminNoticeEditModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('저장 오류: ' + friendlyError(e.message || e), 'error'); }
}

async function onDeleteAdminNotice() {
  if (!_adminNoticeCurrent) return;
  const delMsg = isAdminAudienceNotice(_adminNoticeCurrent)
    ? '공지를 삭제할까요? 모든 관리자의 읽음 이력도 함께 삭제됩니다.'
    : '브랜드 페이지 공지를 삭제할까요? 브랜드 페이지에서도 사라집니다.';
  if (!confirm(delMsg)) return;
  try {
    await deleteAdminNotice(_adminNoticeCurrent.id);
    toast('삭제되었습니다');
    closeModal('adminNoticeEditModal');
    await refreshPane('admin-notices');
  } catch(e) { toast('삭제 오류: ' + friendlyError(e.message || e), 'error'); }
}

// 대시보드 최근 공지 3건 렌더 — published 만 노출
function renderDashboardNotices() {
  const card = $('dashboardNoticesCard');
  const body = $('dashboardNoticesBody');
  if (!card || !body) return;
  const grid = $('dashTopGrid');
  // 브랜드 페이지 공지는 관리자 대시보드에 안 보인다 — 0건 판정(no-notices)보다 앞에서 거른다
  const list = (_adminNoticesCache || []).filter(n => isAdminAudienceNotice(n) && n.status === 'published').slice(0, 3);
  // 공지가 없으면 왼쪽 칸이 비므로 KPI 가 전체 폭을 쓰도록 1단으로 전환
  if (!list.length) { card.style.display = 'none'; if (grid) grid.classList.add('no-notices'); return; }
  card.style.display = '';
  if (grid) grid.classList.remove('no-notices');
  body.innerHTML = list.map(n => `
    <div style="padding:12px 16px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:10px;cursor:pointer" onclick="openAdminNoticeView('${esc(n.id)}')">
      ${!n.is_read ? '<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:#C62828;flex-shrink:0"></span>' : '<span style="display:inline-block;width:6px;height:6px;flex-shrink:0"></span>'}
      ${adminNoticeCatPill(n.category)}
      <div style="flex:1;font-size:13px;color:var(--ink);font-weight:${n.is_read?'400':'600'};overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${n.is_pinned?'<span class="material-icons-round notranslate" translate="no" style="font-size:13px;color:var(--pink);vertical-align:-2px">push_pin</span> ':''}${esc(n.title)}</div>
      <div style="font-size:11px;color:var(--muted);flex-shrink:0">${n.published_at?formatDate(n.published_at):(n.created_at?formatDate(n.created_at):'')}</div>
    </div>
  `).join('');
}

// 로그인 직후 미읽음 공지 팝업 — published 미읽음만
async function showAdminUnreadNoticesIfAny() {
  if (!Array.isArray(_adminNoticesCache) || _adminNoticesCache.length === 0) return;
  const unread = _adminNoticesCache.filter(n => isAdminAudienceNotice(n) && n.status === 'published' && !n.is_read);
  if (unread.length === 0) return;
  const countEl = $('adminNoticeUnreadCount');
  if (countEl) countEl.textContent = `${unread.length}건`;
  const body = $('adminNoticeUnreadBody');
  if (body) {
    body.innerHTML = unread.slice(0, 5).map(n => `
      <div style="padding:14px;border:1px solid var(--line);border-radius:8px;margin-bottom:10px">
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">${adminNoticeCatPill(n.category)}<div style="font-weight:700;font-size:14px;color:var(--ink)">${n.is_pinned?'<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--pink);vertical-align:-2px">push_pin</span> ':''}${esc(n.title)}</div></div>
        <div style="font-size:11px;color:var(--muted);margin-bottom:8px">${esc(n.created_by_name||'—')} · ${n.published_at?formatDateTime(n.published_at):(n.created_at?formatDateTime(n.created_at):'')}</div>
        <div class="rich-content" data-notice-body="${esc(n.id)}" style="font-size:12px;line-height:1.6;color:var(--ink);max-height:140px;overflow:hidden"></div>
        <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:8px">
          <button class="btn btn-primary btn-xs" onclick="onShowDetailFromUnreadPopup('${esc(n.id)}')">상세 보기</button>
        </div>
      </div>
    `).join('');
    // 본문 부분만 renderRich(el, raw) 시그니처로 주입
    unread.slice(0, 5).forEach(n => {
      const el = document.querySelector(`[data-notice-body="${n.id}"]`);
      if (!el) return;
      if (typeof renderRich === 'function') renderRich(el, n.body_html || '');
      else if (typeof sanitizeRich === 'function') el.innerHTML = sanitizeRich(n.body_html || '');
      else el.innerHTML = n.body_html || '';
    });
  }
  openModal('adminNoticeUnreadModal');
}

// 미읽음 팝업 → 상세 모달로 전환 (전환 시 자동 읽음 처리는 openAdminNoticeView가 담당)
function onShowDetailFromUnreadPopup(id) {
  closeModal('adminNoticeUnreadModal');
  openAdminNoticeView(id);
}
