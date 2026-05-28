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
  // 메시지 미읽음 최신화 (응모이력 미방문 상태로 햄버거 열어도 배지 정확)
  if (currentUser && typeof refreshMyMsgUnread === 'function') {
    refreshMyMsgUnread().then(() => updateNavMsgBadge()).catch(() => {});
  }
  // 프로필 최신화 — 폼 저장 직후 햄버거를 열어도 계정 카드·未登録 배지가 정확하도록.
  // 첫 렌더는 현재 currentUserProfile(stale 가능)로 즉시 그리고, fetch 완료 시 다시 그린다.
  if (currentUser && !currentUser._isAdmin && typeof db !== 'undefined' && db) {
    db.from('influencers').select('*').eq('id', currentUser.id).maybeSingle()
      .then(({data}) => { if (data) { currentUserProfile = data; renderNavMenu(); } })
      .catch(() => {});
  }
}
function closeNavPanel() {
  const p = $('navPanel');
  if (p) p.setAttribute('aria-hidden', 'true');
}

function renderNavMenu() {
  const menu = $('navMenu');
  if (!menu) return;
  // Admin 버튼 표시 제어
  const adminBtn = $('navAdminBtn');
  const isAdmin = currentUser && (currentUser._isAdmin || currentUser.email === (typeof ADMIN_EMAIL !== 'undefined' ? ADMIN_EMAIL : ''));
  if (adminBtn) adminBtn.style.display = isAdmin ? '' : 'none';

  let html = '';
  const divider = '<div class="nav-divider"></div>';
  if (currentUser) {
    // 계정 카드 (아바타·이름·핸들·이메일) — 마이페이지 랜딩 화면에서 이전
    html += navAccountCardHtml();
    html += divider;
    html += navItemHtml({nav:'home', icon:'home', label: t('tab.home'), onclick:"navigate('home');closeNavPanel()"});
    html += divider;
    html += navItemHtml({nav:'campaigns', icon:'campaign', label: t('tab.campaigns'), onclick:"navigate('campaigns');closeNavPanel()"});
    html += divider;
    // 마이페이지 — 접기/펼치기 아코디언 헤더 (기본 펼침, 클릭 시 토글만, 화면 이동 없음)
    html += `<button class="nav-item nav-accordion-head" data-nav="mypage" onclick="toggleMypageAccordion()" aria-expanded="${_navMypageOpen}">
      <span class="material-icons-round notranslate nav-icon" translate="no">person</span>
      <span class="nav-label">${esc(t('tab.mypage'))}</span>
      <span class="material-icons-round notranslate nav-accordion-arrow" translate="no" id="navMypageArrow">${_navMypageOpen ? 'expand_less' : 'expand_more'}</span>
    </button>`;
    // 未登録 배지 계산 (mypage.js computeProfileBadges 공용). 마이페이지 랜딩 화면과 동일하게
    // 모든 계정에서 미입력 항목에 배지 표시 (관리자도 인플루언서로 활동 시 입력 필요).
    const b = (typeof computeProfileBadges === 'function')
      ? computeProfileBadges(typeof currentUserProfile !== 'undefined' ? currentUserProfile : {})
      : {hasName:true, hasSns:true, hasAddress:true, hasPaypal:true};
    const subs = [
      {sub:'applications', label: t('mypage.menu.applications')},
      {sub:'profile-basic', label: t('mypage.menu.basic'), unreg: !b.hasName},
      {sub:'profile-sns', label: t('mypage.menu.sns'), unreg: !b.hasSns},
      {sub:'profile-address', label: t('mypage.menu.address'), unreg: !b.hasAddress},
      {sub:'paypal', label: t('mypage.menu.paypal'), unreg: !b.hasPaypal},
      {sub:'password', label: t('mypage.menu.password')},
      {sub:'email-settings', label: t('mypage.menu.emailSettings')}
    ];
    html += `<div class="nav-accordion${_navMypageOpen ? ' open' : ''}" id="navMypageAccordion">`;
    html += subs.map((s, i) => `
      ${i>0 ? '<div class="nav-divider-sub"></div>' : ''}
      <button class="nav-subitem" onclick="navigate('mypage', false);openMypageSub('${s.sub}');closeNavPanel()">
        <span class="nav-label">${esc(s.label)}</span>
        ${s.unreg ? `<span class="nav-unreg-badge">${esc(t('common.unregistered'))}</span>` : ''}
      </button>
    `).join('');
    html += `</div>`;
    html += divider;
    // 메시지 메뉴 항목 제거: 응모이력과 목적지 중복(응모건 카드 메시지 버튼으로 진입), 답장은 알림(message_received)으로 확인.
    // 알림도 계정 카드 우측 벨로 이전됨. 아코디언 뒤 divider 가 로그아웃 구분선 역할.
    html += navItemHtml({nav:'logout', icon:'logout', label: t('mypage.menu.logout'), onclick:"closeNavPanel();handleLogout()"});
    // 회원 탈퇴 — 마이페이지 랜딩에서 이전한 부차적 링크 (확인 후 LINE 안내)
    html += `<button class="nav-withdraw" onclick="closeNavPanel();handleWithdraw()">${esc(t('mypage.withdraw'))}</button>`;
  } else {
    html += navItemHtml({nav:'home', icon:'home', label: t('tab.home'), onclick:"navigate('home');closeNavPanel()"});
    html += navItemHtml({nav:'campaigns', icon:'campaign', label: t('tab.campaigns'), onclick:"navigate('campaigns');closeNavPanel()"});
    html += divider;
    html += navItemHtml({nav:'login', icon:'login', label: t('nav.login'), onclick:"navigate('login');closeNavPanel()"});
    html += navItemHtml({nav:'signup', icon:'person_add', label: t('nav.signup'), onclick:"navigate('signup');closeNavPanel()"});
  }
  menu.innerHTML = html;
  applyNotifBadge(_lastUnread);  // 캐시값으로 즉시 복원 (재렌더 직후 stale 가드로 fetch 스킵돼도 배지 유지)
  refreshNotifBadge();           // 백그라운드 최신화
  updateNavMsgBadge();
}

// 메시지 미읽음 배지 (GNB 「メッセージ」 항목) — _myMsgUnreadByApp(mypage.js) 합계
function updateNavMsgBadge() {
  const map = (typeof _myMsgUnreadByApp === 'object' && _myMsgUnreadByApp) ? _myMsgUnreadByApp : {};
  const total = Object.values(map).reduce((s, n) => s + (Number(n) || 0), 0);
  document.querySelectorAll('[data-role="nav-msg-badge"]').forEach(b => {
    if (total > 0) { b.textContent = total > 9 ? '9+' : String(total); b.classList.remove('hidden'); }
    else b.classList.add('hidden');
  });
}

function navItemHtml(it) {
  return `<button class="nav-item" data-nav="${it.nav}" onclick="${it.onclick}">
    <span class="material-icons-round notranslate nav-icon" translate="no">${it.icon}</span>
    <span class="nav-label">${esc(it.label)}</span>
    ${it.badge ? '<span class="notif-badge hidden" data-role="nav-badge"></span>' : ''}
  </button>`;
}

// 햄버거 상단 계정 카드 (아바타·이름·핸들·이메일) — 마이페이지 랜딩 헤더에서 이전
function navAccountCardHtml() {
  const p = (typeof currentUserProfile === 'object' && currentUserProfile) ? currentUserProfile : {};
  const displayName = p.name_kanji || p.name || (currentUser && currentUser.email) || '';
  const snsMap = {instagram: p.ig, x: p.x, tiktok: p.tiktok, youtube: p.youtube};
  const primary = (p.primary_sns && snsMap[p.primary_sns]) ? snsMap[p.primary_sns] : (p.ig || p.x || p.tiktok || p.youtube || '');
  const handle = primary ? '@' + primary : '';
  const email = (currentUser && currentUser.email) || '';
  return `<div class="nav-account">
    <div class="nav-account-info">
      <div class="nav-account-name">${esc(displayName)}</div>
      ${handle ? `<div class="nav-account-handle">${esc(handle)}</div>` : ''}
      <div class="nav-account-email">${esc(email)}</div>
    </div>
    <button class="nav-account-notif" onclick="closeNavPanel();openNotifModal()" aria-label="${esc(t('menu.notifications'))}">
      <span class="material-icons-round notranslate" translate="no">notifications</span>
      <span class="notif-badge hidden" data-role="nav-badge"></span>
    </button>
  </div>`;
}

// 마이페이지 아코디언 펼침 상태 (기본 펼침). renderNavMenu 재렌더 시에도 유지.
let _navMypageOpen = true;
function toggleMypageAccordion() {
  _navMypageOpen = !_navMypageOpen;
  const wrap = $('navMypageAccordion');
  const arrow = $('navMypageArrow');
  const head = document.querySelector('.nav-accordion-head[data-nav="mypage"]');
  if (wrap) wrap.classList.toggle('open', _navMypageOpen);
  if (arrow) arrow.textContent = _navMypageOpen ? 'expand_less' : 'expand_more';
  if (head) head.setAttribute('aria-expanded', String(_navMypageOpen));
}

// ── 배지 자동 갱신 (30초 폴링 + 탭 포커스, 로그인 상태에만 동작) ──
let _notifPollTimer = null;
let _notifLastFetchAt = 0;
let _lastUnread = 0;  // 마지막으로 조회한 미읽음 수 캐시 — 재렌더 시 배지 즉시 복원용
const _NOTIF_STALE_MS = 5000;  // 5초 이내 중복 요청은 스킵

function startNotifPolling() {
  if (_notifPollTimer) return;
  // 폴링 시작 직후 1회 즉시 갱신 — 30초 setInterval 때문에 첫 배지 표시가
  // 페이지 로드/로그인 직후 늦게 뜨던 문제 방지. force=true 로 stale 가드 우회.
  refreshNotifBadge({force: true});
  // 메시지 미읽음 배지도 같은 주기로 갱신 — 알림 배지와 갱신 속도 일치 (햄버거 배지만, 재렌더 제외)
  if (currentUser && typeof refreshMyMsgUnread === 'function') refreshMyMsgUnread({skipRerender: true});
  _notifPollTimer = setInterval(() => {
    if (currentUser && !document.hidden) {
      refreshNotifBadge();
      if (typeof refreshMyMsgUnread === 'function') refreshMyMsgUnread({skipRerender: true});
    }
  }, 30000);
}
function stopNotifPolling() {
  if (_notifPollTimer) { clearInterval(_notifPollTimer); _notifPollTimer = null; }
  _notifLastFetchAt = 0;
  _lastUnread = 0;
  applyNotifBadge(0);  // 배지 즉시 숨김 (로그아웃 등)
}

// 탭 포커스 이벤트는 매번 등록해도 부작용 없으므로 초기화 시 한 번
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && currentUser) {
    refreshNotifBadge();
    // 화면 복귀 시 메시지 배지도 함께 갱신 — 알림 배지와 동시 표시
    if (typeof refreshMyMsgUnread === 'function') refreshMyMsgUnread({skipRerender: true});
  }
});

// 앱 초기화: 로그인 상태면 시작
if (typeof window !== 'undefined') {
  const _maybeStart = () => { if (currentUser) startNotifPolling(); };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', _maybeStart);
  } else {
    _maybeStart();
  }
}

// ── 미읽음 배지 갱신 (stale 가드 적용) ──
async function refreshNotifBadge(opts) {
  const force = !!(opts && opts.force);
  if (!currentUser) { _lastUnread = 0; applyNotifBadge(0); return; }
  // 5초 이내 중복 호출 스킵 (force=true면 강제 갱신)
  const now = Date.now();
  if (!force && now - _notifLastFetchAt < _NOTIF_STALE_MS) return;
  _notifLastFetchAt = now;
  // 관리자라도 본인 알림은 받아야 하므로 숨기지 않음 (본인이 인플루언서로도 활동 가능)
  let unread = 0;
  try {
    const items = await fetchMyNotifications({unreadOnly: true, limit: 30});
    unread = items.length;
  } catch(e) {}
  _lastUnread = unread;
  applyNotifBadge(unread);
}

// 미읽음 수를 현재 DOM 의 배지들(GNB + 햄버거)에 동기 반영.
// renderNavMenu 재렌더로 배지 element 가 교체돼도 캐시값(_lastUnread)으로 즉시 복원하기 위해 분리.
function applyNotifBadge(unread) {
  const txt = unread > 9 ? '9+' : String(unread);
  const gnbBadge = $('gnbNotifBadge');
  if (gnbBadge) {
    if (unread > 0) { gnbBadge.textContent = txt; gnbBadge.classList.remove('hidden'); }
    else gnbBadge.classList.add('hidden');
  }
  document.querySelectorAll('[data-role="nav-badge"]').forEach(b => {
    if (unread > 0) { b.textContent = txt; b.classList.remove('hidden'); }
    else b.classList.add('hidden');
  });
}

// 알림 → deliverable → campaign.recruit_type 매핑 (렌더용 캐시)
let _notifRecruitTypeMap = {};

async function buildNotifRecruitTypeMap(items) {
  _notifRecruitTypeMap = {};
  const refIds = [...new Set(items.filter(n => n.ref_table === 'deliverables' && n.ref_id).map(n => n.ref_id))];
  if (!refIds.length || !db) return;
  try {
    const {data: delivs} = await db.from('deliverables').select('id, campaign_id').in('id', refIds);
    (delivs || []).forEach(d => {
      const camp = (typeof allCampaigns !== 'undefined' ? allCampaigns : []).find(c => c.id === d.campaign_id);
      if (camp?.recruit_type) _notifRecruitTypeMap[d.id] = camp.recruit_type;
    });
  } catch(e) {}
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
    await buildNotifRecruitTypeMap(items);
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
    const iconMap = {deliverable_rejected:{icon:'error_outline',color:'#C33'}, deliverable_changed:{icon:'change_circle',color:'#B8741A'}, deliverable_approved:{icon:'check_circle',color:'#2D7A3E'}, message_received:{icon:'forum',color:'#C878A3'}, application_approved:{icon:'celebration',color:'#E94F8A'}};
    const ic = iconMap[n.kind] || {icon:'notifications', color:'#6B7280'};
    const unread = !n.read_at ? 'unread' : '';
    const rt = _notifRecruitTypeMap[n.ref_id];
    const rtLabel = rt ? (typeof getRecruitTypeLabelJa === 'function' ? getRecruitTypeLabelJa(rt) : rt) : '';
    const rtBadge = rtLabel
      ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:2px">${esc(rtLabel)}</div>`
      : '';
    return `<div class="notif-item ${unread}" onclick="onNotifItemClick('${esc(n.id)}','${esc(n.kind||'')}','${esc(n.ref_table||'')}','${esc(n.ref_id||'')}')">
      <div class="notif-item-icon" style="background:${ic.color}"><span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:#fff">${ic.icon}</span></div>
      <div class="notif-item-body">
        ${rtBadge}
        <div class="notif-item-title">${esc(n.title||'')}</div>
        ${n.body ? `<div class="notif-item-desc">${esc(n.body)}</div>` : ''}
        <div class="notif-item-time">${formatDateTime(n.created_at)}</div>
      </div>
    </div>`;
  }).join('');
}

async function onNotifItemClick(id, kind, refTable, refId) {
  await markNotificationRead(id);
  closeNotifModal();
  // 메시지 알림 → 응모건 메시지 페이지 직접 오픈 (사양서 §5-5, 2026-05-22 모달→페이지 전환)
  //   주의: application_cancelled 알림도 ref_table='applications' 이므로 kind 로 한정 (회귀 방지)
  if (kind === 'message_received' && refId && currentUser) {
    if (typeof openMessagesPage === 'function') openMessagesPage(refId, 'mypage');
    refreshNotifBadge();
    return;
  }
  // deliverable 참조가 있으면 활동관리 이동
  if (refTable === 'deliverables' && refId && currentUser) {
    try {
      const delivs = await fetchDeliverablesForUser({user_id: currentUser.id});
      const hit = delivs.find(d => d.id === refId);
      if (hit) {
        openActivityPage(hit.application_id, hit.campaign_id, 'mypage');
        refreshNotifBadge();
        return;
      }
    } catch(e) {}
    // 참조는 있었으나 접근 불가 (삭제됨 등) → 알림도 제거
    await deleteNotification(id);
    toast(t('notif.refMissing'), 'warn');
  } else {
    // ref 없는 일반 알림: 응모이력으로 이동
    if (typeof navigate === 'function') { navigate('mypage', false); openMypageSub('applications'); }
  }
  refreshNotifBadge();
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
  await refreshNotifBadge({force: true});  // 전체읽음 직후는 즉시 반영 필수
  const items = await fetchMyNotifications({limit: 30});
  renderNotifModal(items);
}
