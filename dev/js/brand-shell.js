// 브랜드 페이지 — 로그인 뒤 틀(좌측 메뉴 · 모바일 맨 위 막대·메뉴 서랍)과 세션 상태
//   (Figma 「[1차] 03」 틀, 사양서 docs/specs/2026-07-15-brand-portal.md §16-4,
//    작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 1)
//   페이지 파일(brand-members.js·brand-mypage.js)은 registerBrandPage 로 자기를 등록한다 — 이 파일이 먼저 실린다.

// 로그인 판정(get_my_brand_login_state)을 화면 쪽 이름으로 옮긴 값. 서버 키 → 화면 키 대응은 작업표 조각 1 이 정본.
//   { name, email, brands:[{id,name,role}], currentBrandId, hasPendingInvite, newInviteDot, passwordChangedAt }
let brandSession = null;
const _brandChangeHandlers = [];

// 메뉴 — 순서·이름·아이콘은 피그마 w04-00·m03-01 그대로. 「마이페이지」는 메뉴 맨 아래 「이름 · 마이페이지」 자리.
//   ⚠️ 피그마에 「선택된 메뉴」 모양이 없다 — 코드가 정했다(흰 바탕·굵은 글자, brand.css .is-active).
const BRAND_MENU = [
  { hash: 'brand', label: '브랜드', icon: 'business' },
  { hash: 'orient', label: '오리엔시트', icon: 'assignment_turned_in' },
  { hash: 'campaigns', label: '캠페인', icon: 'campaign' },
  { hash: 'members', label: '멤버관리', icon: 'group' }
];
const BRAND_FIRST_PAGE = 'orient';   // 로그인 뒤 첫 페이지 = 오리엔시트(사양서 16-4 · 작업표 S0-1)

// 페이지 등록부 — hash → { title, render(host) }. 아직 없는 페이지는 「준비 중」(작업표 S0-1).
const _brandPages = {};
function registerBrandPage(hash, def) { _brandPages[hash] = def; }
function _brandComingSoon(title) {
  return {
    title,
    render(host) {
      host.innerHTML =
        '<div class="brand-page-head"><h1>' + brandEsc(title) + '</h1></div>' +
        '<div class="brand-empty"><p class="brand-empty-title">준비 중이에요</p>' +
        '<p class="brand-empty-desc">이 화면은 곧 열려요.</p></div>';
    }
  };
}
registerBrandPage('orient', _brandComingSoon('오리엔시트'));
registerBrandPage('campaigns', _brandComingSoon('캠페인'));
registerBrandPage('brand', _brandComingSoon('브랜드'));
registerBrandPage('members', _brandComingSoon('멤버 관리'));
registerBrandPage('mypage', _brandComingSoon('마이페이지'));

function isBrandShellPage(hash) { return Object.prototype.hasOwnProperty.call(_brandPages, hash); }

function getCurrentBrandId() { return brandSession ? brandSession.currentBrandId : null; }
function getCurrentBrand() {
  if (!brandSession) return null;
  return brandSession.brands.find(b => b.id === brandSession.currentBrandId) || null;
}
// 브랜드가 바뀌면 각 페이지가 자기 목록을 다시 받는다
function onBrandChanged(fn) { _brandChangeHandlers.push(fn); }
function _emitBrandChanged() { _brandChangeHandlers.forEach(fn => { try { fn(getCurrentBrandId()); } catch (e) { /* 한 페이지 실패가 다른 페이지를 막지 않게 */ } }); }

// 판정 결과를 세션 상태로 옮긴다. 첫 브랜드 = preferBrandId(활성 연결에 있을 때만) → last_brand_id → 서버 순서 첫 브랜드.
//   ⚠️ 조각 2 가 「서버 순서 첫 브랜드」를 이름순 첫 브랜드(sortBrandsForPicker)로 바꾼다.
function _brandSessionFromState(state, preferBrandId) {
  const brands = Array.isArray(state.brands) ? state.brands.map(b => ({ id: b.id, name: b.name || '', role: b.role })) : [];
  const has = (id) => !!id && brands.some(b => b.id === id);
  const keep = brandSession && has(brandSession.currentBrandId) ? brandSession.currentBrandId : null;
  const current = has(preferBrandId) ? preferBrandId
    : keep || (has(state.last_brand_id) ? state.last_brand_id : (brands[0] ? brands[0].id : null));
  return {
    name: state.name || '',
    email: state.email || '',
    brands,
    currentBrandId: current,
    hasPendingInvite: !!state.has_pending_invite,
    newInviteDot: !!state.new_invite_dot,
    passwordChangedAt: state.password_changed_at || null
  };
}

function setBrandSessionFromState(state, opts) {
  if (!state) { brandSession = null; return; }
  const prevBrand = getCurrentBrandId();
  brandSession = _brandSessionFromState(state, opts && opts.preferBrandId);
  renderBrandShellChrome();
  if (prevBrand && prevBrand !== brandSession.currentBrandId) _emitBrandChanged();
}

// 로그인 직후·초대 수락 뒤 — 첫 페이지로. 🔴 활동 기록은 남기지 않는다(로그인만 한 것은 활동이 아니다 — 사양서 16-4 ③).
function enterBrandApp(state, opts) {
  brandSession = null;          // 로그인 직후에는 이전 브랜드를 이어받지 않는다
  setBrandAuthed(state, opts);
  goBrandScreen(BRAND_FIRST_PAGE);
}

// 판정을 다시 받아 세션 상태를 갱신 — 반환 state 또는 null(호출 실패).
//   지금 브랜드가 연결 목록에서 빠졌으면 첫 브랜드로 옮긴다(조각 2 가 handleBrandNotLinked 로 바꾼다).
async function refreshBrandLoginState() {
  const state = await fetchBrandLoginState();
  if (!state) return null;
  if (state.state !== 'ok') {
    // 연결이 모두 사라졌거나 계정 상태가 바뀜 — 로그인 판정 갈래를 그대로 따른다
    await applyBrandLoginState(state);
    return state;
  }
  setBrandSessionFromState(state);
  return state;
}

// 「마지막 접속」 기록 — 지금 브랜드로. 사람이 누른 메뉴 이동·저장 성공·브랜드 바꾸기 때만 부른다.
//   마이페이지 이동·마이페이지 안의 저장·로그인 직후 자동 이동은 부르지 않는다(작업표 S0-4). 결과는 화면에 쓰지 않는다.
function brandTouchActivity() {
  const id = getCurrentBrandId();
  if (!id) return;
  brandRpc('touch_my_brand_activity', { p_brand_id: id }).catch(() => {});
}

// ── 틀 그리기
function renderBrandShellChrome() {
  if (!brandSession) return;
  const cur = getCurrentBrand();
  const curName = cur ? cur.name : '';
  document.querySelectorAll('[data-brand-current-name]').forEach(el => { el.textContent = curName; });
  const who = brandSession.name || brandSession.email;
  document.querySelectorAll('[data-brand-user-name]').forEach(el => { el.textContent = who; });
  document.querySelectorAll('[data-brand-user-initial]').forEach(el => { el.textContent = Array.from(who || '')[0] || ''; });
  refreshInviteDot();
}

// 빨간 점 — 새 초대(new_invite_dot). 마이페이지 화면 안에는 그리지 않는다(조각 7 이 들어올 때 끈다).
function refreshInviteDot() {
  const on = !!(brandSession && brandSession.newInviteDot);
  document.querySelectorAll('.brand-dot, .brand-dot-sr').forEach(el => { el.hidden = !on; });
  const menuBtn = document.getElementById('brandTopbarMenuBtn');
  if (menuBtn) menuBtn.setAttribute('aria-label', on ? '메뉴 열기 (새 초대가 있어요)' : '메뉴 열기');
}

function _brandMenuHtml(active) {
  return BRAND_MENU.map(m =>
    '<a class="brand-menu-item' + (m.hash === active ? ' is-active' : '') + '" href="#' + m.hash + '" data-brand-nav="' + m.hash + '"' +
      (m.hash === active ? ' aria-current="page"' : '') + '>' +
      '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">' + m.icon + '</span>' +
      '<span>' + brandEsc(m.label) + '</span></a>'
  ).join('');
}

// 틀 안 페이지를 그린다 — routeBrand 가 부른다
function showBrandShellPage(hash) {
  const page = _brandPages[hash] || _brandPages[BRAND_FIRST_PAGE];
  document.getElementById('brandStage').hidden = true;
  document.querySelectorAll('.brand-card[data-screen]').forEach(el => { el.hidden = true; });
  document.getElementById('brandShell').hidden = false;
  document.body.classList.add('is-shell');
  // 메뉴는 한 번만 그리고 표시만 바꾼다(다시 그리면 키보드 초점이 사라진다)
  document.querySelectorAll('#brandShell [data-brand-nav]').forEach(el => {
    const on = el.dataset.brandNav === hash;
    el.classList.toggle('is-active', on);
    if (on) el.setAttribute('aria-current', 'page'); else el.removeAttribute('aria-current');
  });
  renderBrandShellChrome();
  closeBrandDrawer(false);
  const host = document.getElementById('brandPageHost');
  host.innerHTML = '';
  try { page.render(host); }
  catch (e) { host.innerHTML = '<div class="brand-empty"><p class="brand-empty-title">화면을 그리지 못했어요</p><p class="brand-empty-desc">새로고침해 주세요.</p></div>'; }
  document.title = (page.title || '브랜드') + ' · REVERB JP';
  window.scrollTo(0, 0);
  const main = document.getElementById('brandMain');
  if (main) main.scrollTop = 0;
}

// 틀을 감춘다(로그인 전 카드 화면으로 갈 때) — showBrandScreen 이 부른다
function hideBrandShell() {
  const shell = document.getElementById('brandShell');
  if (shell) shell.hidden = true;
  // 로그아웃 뒤 이전 계정의 페이지 내용(멤버 이메일 등)을 DOM 에 남기지 않는다
  const host = document.getElementById('brandPageHost');
  if (host) host.innerHTML = '';
  const stage = document.getElementById('brandStage');
  if (stage) stage.hidden = false;
  document.body.classList.remove('is-shell');
  closeBrandDrawer(false);
}

// ── 모바일 메뉴 서랍(오른쪽에서 나온다)
let _brandDrawerReturnFocus = null;
function openBrandDrawer() {
  const d = document.getElementById('brandDrawer');
  if (!d) return;
  _brandDrawerReturnFocus = document.activeElement;
  d.hidden = false;
  document.getElementById('brandTopbarMenuBtn').setAttribute('aria-expanded', 'true');
  const first = d.querySelector('a, button');
  if (first) first.focus();
}
function closeBrandDrawer(restoreFocus) {
  const d = document.getElementById('brandDrawer');
  if (!d || d.hidden) return;
  d.hidden = true;
  const btn = document.getElementById('brandTopbarMenuBtn');
  if (btn) btn.setAttribute('aria-expanded', 'false');
  if (restoreFocus !== false && _brandDrawerReturnFocus) _brandDrawerReturnFocus.focus();
}

async function brandLogout() {
  await brandSignOutLocal();
  setBrandAuthed(null);
  goBrandScreen('login');
}

function initBrandShell() {
  document.querySelectorAll('[data-brand-menu]').forEach(el => { el.innerHTML = _brandMenuHtml(''); });
  // 메뉴 이동 — 사람이 눌렀을 때만 활동으로 센다(마이페이지는 세지 않는다 — S0-4).
  //   지금 페이지를 다시 누르면 해시가 안 바뀌어 화면 전환이 없으므로 서랍은 여기서 닫는다.
  document.getElementById('brandShell').addEventListener('click', (e) => {
    const nav = e.target.closest('[data-brand-nav]');
    if (!nav) return;
    if (nav.dataset.brandNav !== 'mypage') brandTouchActivity();
    closeBrandDrawer(false);
  });
  document.getElementById('brandTopbarMenuBtn').addEventListener('click', openBrandDrawer);
  document.getElementById('brandDrawerClose').addEventListener('click', () => closeBrandDrawer());
  const drawer = document.getElementById('brandDrawer');
  drawer.addEventListener('click', (e) => { if (e.target === drawer) closeBrandDrawer(); });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || drawer.hidden) return;
    closeBrandDrawer();
  });
  // 서랍 안에서만 초점이 돌게
  drawer.addEventListener('keydown', (e) => {
    if (e.key !== 'Tab') return;
    const items = Array.from(drawer.querySelectorAll('a, button')).filter(el => el.offsetParent !== null);
    if (!items.length) return;
    const i = items.indexOf(document.activeElement);
    if (e.shiftKey && i <= 0) { e.preventDefault(); items[items.length - 1].focus(); }
    else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
  });
  document.querySelectorAll('[data-brand-logout]').forEach(btn => btn.addEventListener('click', async () => {
    if (btn.disabled) return;
    btn.disabled = true;
    try { await brandLogout(); } finally { btn.disabled = false; }
  }));
}
