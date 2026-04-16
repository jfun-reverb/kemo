// ══════════════════════════════════════
// NOTIFICATIONS — 햄버거 배지 + 슬라이드업 모달
// (dev/index.html 전용: 햄버거 메뉴 리팩토링)
// ══════════════════════════════════════

let _notifCache = [];

// ── 햄버거 메뉴 패널 ──
function openNavPanel() {
  const p = $('navPanel');
  if (!p) return;
  renderNavMenu();
  p.setAttribute('aria-hidden', 'false');
}
function closeNavPanel() {
  const p = $('navPanel');
  if (p) p.setAttribute('aria-hidden', 'true');
}

function renderNavMenu() {
  const menu = $('navMenu');
  if (!menu) return;
  const items = [];
  if (currentUser) {
    items.push({nav:'home', icon:'home', label: t('tab.home'), onclick:"navigate('home');closeNavPanel()"});
    items.push({nav:'campaigns', icon:'campaign', label: t('tab.campaigns'), onclick:"navigate('campaigns');closeNavPanel()"});
    items.push({nav:'mypage', icon:'person', label: t('tab.mypage'), onclick:"navigate('mypage');closeNavPanel()"});
    const isAdmin = currentUser._isAdmin || currentUser.email === (typeof ADMIN_EMAIL !== 'undefined' ? ADMIN_EMAIL : '');
    if (!isAdmin) {
      items.push({nav:'notif', icon:'notifications', label: t('menu.notifications'), onclick:"closeNavPanel();openNotifModal()", badge:true});
    }
    items.push({nav:'logout', icon:'logout', label: t('mypage.menu.logout'), onclick:"closeNavPanel();handleLogout()"});
  } else {
    items.push({nav:'home', icon:'home', label: t('tab.home'), onclick:"navigate('home');closeNavPanel()"});
    items.push({nav:'campaigns', icon:'campaign', label: t('tab.campaigns'), onclick:"navigate('campaigns');closeNavPanel()"});
    items.push({nav:'login', icon:'login', label: t('nav.login'), onclick:"navigate('login');closeNavPanel()"});
    items.push({nav:'signup', icon:'person_add', label: t('nav.signup'), onclick:"navigate('signup');closeNavPanel()"});
  }
  menu.innerHTML = items.map(it => `
    <button class="nav-item" data-nav="${it.nav}" onclick="${it.onclick}">
      <span class="material-icons-round notranslate nav-icon" translate="no">${it.icon}</span>
      <span class="nav-label">${esc(it.label)}</span>
      ${it.badge ? '<span class="notif-badge hidden" data-role="nav-badge"></span>' : ''}
    </button>
  `).join('');
  refreshNotifBadge();
}

// ── 미읽음 배지 갱신 ──
async function refreshNotifBadge() {
  const gnbBadge = $('gnbNotifBadge');
  const navBadges = document.querySelectorAll('[data-role="nav-badge"]');
  if (!currentUser) {
    if (gnbBadge) gnbBadge.classList.add('hidden');
    navBadges.forEach(b => b.classList.add('hidden'));
    return;
  }
  const isAdmin = currentUser._isAdmin || currentUser.email === (typeof ADMIN_EMAIL !== 'undefined' ? ADMIN_EMAIL : '');
  if (isAdmin) {
    if (gnbBadge) gnbBadge.classList.add('hidden');
    navBadges.forEach(b => b.classList.add('hidden'));
    return;
  }
  let unread = 0;
  try {
    const items = await fetchMyNotifications({unreadOnly: true, limit: 30});
    unread = items.length;
  } catch(e) {}
  const txt = unread > 9 ? '9+' : String(unread);
  if (gnbBadge) {
    if (unread > 0) { gnbBadge.textContent = txt; gnbBadge.classList.remove('hidden'); }
    else gnbBadge.classList.add('hidden');
  }
  navBadges.forEach(b => {
    if (unread > 0) { b.textContent = txt; b.classList.remove('hidden'); }
    else b.classList.add('hidden');
  });
}

// ── 알림 모달 ──
async function openNotifModal() {
  const m = $('notifModal');
  if (!m) return;
  m.setAttribute('aria-hidden', 'false');
  const body = $('notifModalBody');
  if (body) body.innerHTML = '<div class="notif-empty">' + t('common.loading') + '</div>';
  try {
    const items = await fetchMyNotifications({limit: 30});
    _notifCache = items;
    renderNotifModal(items);
  } catch(e) {
    if (body) body.innerHTML = '<div class="notif-empty">' + t('authError.serverError') + '</div>';
  }
}

function closeNotifModal() {
  const m = $('notifModal');
  if (m) m.setAttribute('aria-hidden', 'true');
}

function renderNotifModal(items) {
  const body = $('notifModalBody');
  const markBtn = $('notifMarkAllBtn');
  if (!body) return;
  if (!items.length) {
    body.innerHTML = '<div class="notif-empty">' + t('notif.emptyUnread') + '</div>';
    if (markBtn) markBtn.disabled = true;
    return;
  }
  const hasUnread = items.some(n => !n.read_at);
  if (markBtn) markBtn.disabled = !hasUnread;
  body.innerHTML = items.map(n => {
    const iconMap = {deliverable_rejected:{icon:'error_outline',color:'#C33'}, deliverable_changed:{icon:'change_circle',color:'#B8741A'}, deliverable_approved:{icon:'check_circle',color:'#2D7A3E'}};
    const ic = iconMap[n.kind] || {icon:'notifications', color:'#6B7280'};
    const unread = !n.read_at ? 'unread' : '';
    return `<div class="notif-item ${unread}" onclick="onNotifItemClick('${esc(n.id)}','${esc(n.ref_table||'')}','${esc(n.ref_id||'')}')">
      <div class="notif-item-icon" style="background:${ic.color}"><span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:#fff">${ic.icon}</span></div>
      <div class="notif-item-body">
        <div class="notif-item-title">${esc(n.title||'')}</div>
        ${n.body ? `<div class="notif-item-desc">${esc(n.body)}</div>` : ''}
        <div class="notif-item-time">${formatDateTime(n.created_at)}</div>
      </div>
    </div>`;
  }).join('');
}

async function onNotifItemClick(id, refTable, refId) {
  await markNotificationRead(id);
  if (refTable === 'deliverables' && refId && currentUser) {
    try {
      const delivs = await fetchDeliverablesForUser({user_id: currentUser.id});
      const hit = delivs.find(d => d.id === refId);
      if (hit) {
        closeNotifModal();
        openActivityPage(hit.application_id, hit.campaign_id, 'mypage');
        refreshNotifBadge();
        return;
      }
    } catch(e) {}
  }
  // 참조 없거나 실패: 배지·리스트 갱신
  await refreshNotifBadge();
  const items = await fetchMyNotifications({limit: 30});
  renderNotifModal(items);
}

// ── 비로그인 고정 CTA 표시 제어 ──
function updateFloatingAuthCta(pageName) {
  const cta = $('floatingAuthCta');
  if (!cta) return;
  const hiddenPages = ['login','signup','forgot','reset-pw'];
  const curPage = pageName || (location.hash.replace('#','').split('-')[0] || 'home');
  if (currentUser || hiddenPages.includes(curPage)) {
    cta.style.display = 'none';
  } else {
    cta.style.display = '';
  }
}

async function markAllNotifRead() {
  await markAllNotificationsRead();
  await refreshNotifBadge();
  const items = await fetchMyNotifications({limit: 30});
  renderNotifModal(items);
}
