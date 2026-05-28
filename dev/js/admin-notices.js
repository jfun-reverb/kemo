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

const ADMIN_NOTICE_CAT_LABEL = {
  system_update: '시스템 업데이트',
  release: '릴리스',
  warning: '경고',
  general: '일반',
};
const ADMIN_NOTICE_CAT_STYLE = {
  system_update: 'background:#E3F2FD;color:#1565C0',
  release: 'background:#E8F5E9;color:#2E7D32',
  warning: 'background:#FFEBEE;color:#C62828',
  general: 'background:#F5F5F5;color:#616161',
};

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-NOTICES — 공지사항 페인 + 대시보드 카드 + 미읽음 팝업
// ════════════════════════════════════════════════════════════════════

function adminNoticeCatPill(cat) {
  const style = ADMIN_NOTICE_CAT_STYLE[cat] || ADMIN_NOTICE_CAT_STYLE.general;
  return `<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;${style}">${esc(ADMIN_NOTICE_CAT_LABEL[cat]||cat)}</span>`;
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
  const unread = (_adminNoticesCache || []).filter(n => n.status === 'published' && !n.is_read).length;
  if (unread > 0) { badge.textContent = unread > 9 ? '9+' : unread; badge.style.display = ''; }
  else badge.style.display = 'none';
}

function renderAdminNotices() {
  const body = $('adminNoticeBody');
  if (!body) return;
  const cat = $('adminNoticeCatFilter')?.value || 'all';
  const status = $('adminNoticeStatusFilter')?.value || 'all';
  const q = ($('adminNoticeSearch')?.value || '').trim().toLowerCase();
  let list = (_adminNoticesCache || []).slice();
  if (cat !== 'all') list = list.filter(n => n.category === cat);
  if (status !== 'all') list = list.filter(n => (n.status || 'draft') === status);
  if (q) list = list.filter(n => (n.title || '').toLowerCase().includes(q));
  const total = $('adminNoticeTotal');
  if (total) total.textContent = `${list.length}건`;
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const canEdit = (n) => isSuper || n.created_by === currentUser?.id;
  body.innerHTML = list.length ? list.map(n => {
    const isPub = n.status === 'published';
    const showUnread = isPub && !n.is_read;
    const unreadDot = showUnread ? `<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:#C62828;margin-right:4px;vertical-align:middle"></span>` : '';
    const readCellInner = !isPub
      ? '<span style="font-size:11px;color:var(--muted)">—</span>'
      : (n.is_read
          ? '<span style="font-size:11px;color:var(--muted)">읽음</span>'
          : '<span style="font-size:11px;color:#C62828;font-weight:700">미읽음</span>');
    const pinIcon = n.is_pinned ? `<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--pink);vertical-align:-2px" title="상단 고정">push_pin</span> ` : '';
    const dateStr = isPub
      ? (n.published_at ? formatDateTime(n.published_at) : (n.created_at ? formatDateTime(n.created_at) : ''))
      : (n.created_at ? `<span style="color:#999">— · ${formatDateTime(n.created_at)} 작성</span>` : '');
    return `<tr data-id="${esc(n.id)}" style="cursor:pointer;${showUnread?'background:#FFFBEF':''}" onclick="openAdminNoticeView(this.dataset.id)">
      <td>${unreadDot}${readCellInner}</td>
      <td>${adminNoticeStatusPill(n.status)}</td>
      <td>${adminNoticeCatPill(n.category)}</td>
      <td style="font-weight:600;color:var(--ink)">${pinIcon}${esc(n.title)}</td>
      <td style="font-size:12px;color:var(--muted)">${esc(n.created_by_name || '—')}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${dateStr}</td>
      <td>${canEdit(n) ? `<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openAdminNoticeEdit(this.closest('tr').dataset.id)"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">edit</span> 수정</button>` : ''}</td>
    </tr>`;
  }).join('') : '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">공지 없음</td></tr>';
}

// 보기 모달. 자동 읽음 처리는 published 공지에만. 푸터 버튼은 권한·상태별 분기.
async function openAdminNoticeView(id) {
  const n = (_adminNoticesCache || []).find(x => x.id === id);
  if (!n) return;
  _adminNoticeCurrent = n;
  const isPub = n.status === 'published';
  $('adminNoticeViewTitle').innerHTML = esc(n.title);
  const dateBlock = isPub
    ? (n.published_at ? `<span>${formatDateTime(n.published_at)} 게시</span>` : '')
    : `<span style="color:#999">${n.created_at?formatDateTime(n.created_at)+' 작성':''}</span>`;
  $('adminNoticeViewMeta').innerHTML = `${adminNoticeStatusPill(n.status)}${adminNoticeCatPill(n.category)}<span>${esc(n.created_by_name || '—')}</span>${dateBlock}${n.is_pinned?'<span style="color:var(--pink);font-weight:700;display:inline-flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">push_pin</span>상단 고정</span>':''}`;
  const bodyEl = $('adminNoticeViewBody');
  if (typeof renderRich === 'function') renderRich(bodyEl, n.body_html || '');
  else if (typeof sanitizeRich === 'function') bodyEl.innerHTML = sanitizeRich(n.body_html || '');
  else bodyEl.innerHTML = n.body_html || '';
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
  if (isPub && !n.is_read) {
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
  if (!confirm('이 공지를 지금 게시할까요? 모든 관리자에게 미읽음으로 노출됩니다.')) return;
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  try {
    await publishAdminNotice(id, name);
    toast('게시되었습니다', 'success');
    closeModal('adminNoticeViewModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('게시 오류: ' + (e.message || e), 'error'); }
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
  } catch(e) { toast('회수 오류: ' + (e.message || e), 'error'); }
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
      const patch = {title, body_html, category, is_pinned, updated_by_name: name};
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
      await insertAdminNotice({title, body_html, category, is_pinned, created_by_name: name, status: wantPublish ? 'published' : 'draft'});
      toast(wantPublish ? '게시되었습니다' : '초안 저장되었습니다', 'success');
    }
    closeModal('adminNoticeEditModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('저장 오류: ' + (e.message || e), 'error'); }
}

async function onDeleteAdminNotice() {
  if (!_adminNoticeCurrent) return;
  if (!confirm('공지를 삭제할까요? 모든 관리자의 읽음 이력도 함께 삭제됩니다.')) return;
  try {
    await deleteAdminNotice(_adminNoticeCurrent.id);
    toast('삭제되었습니다');
    closeModal('adminNoticeEditModal');
    await refreshPane('admin-notices');
  } catch(e) { toast('삭제 오류: ' + (e.message || e), 'error'); }
}

// 대시보드 최근 공지 3건 렌더 — published 만 노출
function renderDashboardNotices() {
  const card = $('dashboardNoticesCard');
  const body = $('dashboardNoticesBody');
  if (!card || !body) return;
  const list = (_adminNoticesCache || []).filter(n => n.status === 'published').slice(0, 3);
  if (!list.length) { card.style.display = 'none'; return; }
  card.style.display = '';
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
  const unread = _adminNoticesCache.filter(n => n.status === 'published' && !n.is_read);
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
