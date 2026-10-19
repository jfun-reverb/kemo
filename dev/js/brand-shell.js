// 브랜드 페이지 — 로그인 뒤 틀(좌측 메뉴 · 모바일 맨 위 막대·메뉴 서랍)과 세션 상태
//   (Figma 「[1차] 03」 틀, 사양서 docs/specs/2026-07-15-brand-portal.md §16-4,
//    작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 1)
//   페이지 파일(brand-info.js·brand-orient.js·brand-members.js·brand-mypage.js)은 registerBrandPage 로 자기를 등록한다 — 이 파일이 먼저 실린다.

// 로그인 판정(get_my_brand_login_state)을 화면 쪽 이름으로 옮긴 값. 서버 키 → 화면 키 대응은 작업표 조각 1 이 정본.
//   { name, email, brands:[{id,name,role}], currentBrandId, hasPendingInvite, newInviteDot, passwordChangedAt }
let brandSession = null;
const _brandChangeHandlers = [];

// 메뉴 — 순서·이름·아이콘은 피그마 bw04-00·bm03-01 그대로. 「마이페이지」는 메뉴 맨 아래 「이름 · 마이페이지」 자리.
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
        '<div class="brand-empty"><p class="brand-empty-title">준비 중입니다</p>' +
        '<p class="brand-empty-desc">이 화면은 곧 열립니다.</p></div>';
    }
  };
}
registerBrandPage('campaigns', _brandComingSoon('캠페인'));
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

// 브랜드 이름 정렬 — 한글 가나다 → 그 밖(영문 ABC 등). 서버 순서(대표 먼저·데이터베이스 이름순)와 다르다(사양서 16-4).
//   브라우저 한국어 정렬만으로는 한글이 영문보다 앞선다는 보장이 없어 글자 종류를 먼저 가른다.
const _brandCollator = (typeof Intl !== 'undefined' && Intl.Collator) ? new Intl.Collator('ko', { sensitivity: 'base', numeric: true }) : null;
function _brandNameGroup(name) { return /^[\s]*[가-힣ㄱ-ㅎㅏ-ㅣ]/.test(name || '') ? 0 : 1; }
function compareBrandNames(a, b) {
  const ga = _brandNameGroup(a), gb = _brandNameGroup(b);
  if (ga !== gb) return ga - gb;
  return _brandCollator ? _brandCollator.compare(a || '', b || '') : String(a || '').localeCompare(String(b || ''));
}
// 고르기 목록 순서 — 지금 브랜드 맨 위 + 나머지 이름순. 역할(대표/멤버)은 싣지 않는다(16-4 ①).
function sortBrandsForPicker(brands, currentId) {
  const list = (brands || []).slice().sort((x, y) => compareBrandNames(x.name, y.name));
  const i = list.findIndex(b => b.id === currentId);
  if (i > 0) list.unshift(list.splice(i, 1)[0]);
  return list;
}

// 판정 결과를 세션 상태로 옮긴다. 첫 브랜드 = preferBrandId(활성 연결에 있을 때만) → 이미 보던 브랜드 → last_brand_id → 이름순 첫 브랜드.
//   last_brand_id 는 서버가 「지금 활성 연결일 때만」 값을 준다(532) — NULL 이면 이름순 첫 브랜드(화면 몫).
function _brandSessionFromState(state, preferBrandId) {
  const brands = Array.isArray(state.brands) ? state.brands.map(b => ({ id: b.id, name: b.name || '', role: b.role })) : [];
  const has = (id) => !!id && brands.some(b => b.id === id);
  const keep = brandSession && has(brandSession.currentBrandId) ? brandSession.currentBrandId : null;
  const first = sortBrandsForPicker(brands, null)[0];
  const current = has(preferBrandId) ? preferBrandId
    : keep || (has(state.last_brand_id) ? state.last_brand_id : (first ? first.id : null));
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
//   지금 브랜드가 연결 목록에서 빠졌으면 이름순 첫 브랜드로 옮긴다(_brandSessionFromState).
//   연결이 하나도 안 남으면 로그인 판정 갈래(applyBrandLoginState)를 따른다 — 조각 3 전까지는 로그아웃 + 「연결된 브랜드 없음」.
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

// ── 떠나기 전 확인(오리엔시트 작업표 조각 6 · 피그마 bw04-13 · 결정 10)
//   저장되지 않은 입력이 있는 화면(지금은 오리엔시트 작성 모달 하나)이 registerBrandLeaveGuard(fn) 로 자기를 건다.
//   fn(kind) → Promise<boolean>(진행해도 되면 참). kind = 'brand'(브랜드 바꾸기) | 'nav'(메뉴·뒤로 가기) | 'logout'.
//   🔴 걸린 장치가 없으면 늘 통과한다 — 브랜드 정보·멤버·마이페이지 페이지의 이동에는 아무 영향이 없다.
//   등록은 하나만(모달은 한 번에 하나). 반환값(해제 함수)으로 풀고, 모달이 닫히면 반드시 푼다.
let _brandLeaveGuard = null;
let _brandLeaveGuardAsk = null;       // 지금 물을 일이 있는가(opts.needsAsk) — 없으면 주소를 되돌리지 않고 그대로 보낸다
let _brandLeaveGuardHash = '';        // 장치를 건 순간의 해시 — 뒤로 가기로 주소가 바뀌면 여기로 되돌려 놓고 묻는다
function registerBrandLeaveGuard(fn, opts) {
  _brandLeaveGuard = fn || null;
  _brandLeaveGuardAsk = (opts && typeof opts.needsAsk === 'function') ? opts.needsAsk : null;
  _brandLeaveGuardHash = location.hash;
  return () => { if (_brandLeaveGuard === fn) { _brandLeaveGuard = null; _brandLeaveGuardAsk = null; } };
}
async function brandConfirmLeave(kind) {
  const g = _brandLeaveGuard;
  if (!g) return true;
  try { return !!(await g(kind)); } catch (e) { return true; }   // 장치가 고장 나면 사용자를 가두지 않는다
}
// 주소(#해시)가 바뀌었을 때 — 메뉴 누르기·뒤로 가기 모두 여기로 온다(brand-app.js 의 hashchange).
//   장치가 걸려 있으면 주소를 원래대로 되돌려 둔 채 묻고, 「진행」이면 그때 다시 옮긴다. 반환: 지금 화면을 바꿔도 되면 참.
async function brandGuardHashChange() {
  if (!_brandLeaveGuard || !brandAuthed) return true;
  const target = location.hash;
  if (target === _brandLeaveGuardHash) return true;
  // 물을 일이 없으면 주소 기록을 건드리지 않는다 — 장치가 모달만 닫고 그대로 그린다(뒤로 가기 기록이 어긋나지 않게)
  if (_brandLeaveGuardAsk && !_brandLeaveGuardAsk()) { await brandConfirmLeave('nav'); return true; }
  history.replaceState(null, '', location.pathname + location.search + _brandLeaveGuardHash);
  if (await brandConfirmLeave('nav')) {
    if (_brandLeaveGuard) { _brandLeaveGuard = null; _brandLeaveGuardAsk = null; }   // 장치가 스스로 안 풀었어도 같은 질문을 두 번 하지 않게
    location.hash = target;                          // 다시 hashchange → 이번엔 장치가 없어 그대로 그린다
  }
  return false;
}

// 세션이 끊겼을 때(토큰 갱신 실패 등 — 로그인 시간 만료) · 틀이 감춰질 때 알림. 페이지가 자기 상태를 정리한다.
const _brandSessionLostHandlers = [];
const _brandShellHiddenHandlers = [];
function onBrandSessionLost(fn) { _brandSessionLostHandlers.push(fn); }
function onBrandShellHidden(fn) { _brandShellHiddenHandlers.push(fn); }
function emitBrandSessionLost() { _brandSessionLostHandlers.forEach(fn => { try { fn(); } catch (e) { /* 다른 처리기를 막지 않게 */ } }); }
function _emitBrandShellHidden() { _brandShellHiddenHandlers.forEach(fn => { try { fn(); } catch (e) { /* 다른 처리기를 막지 않게 */ } }); }

// 브랜드 바꾸기 — 서버에 「마지막으로 본 브랜드」를 남기고 보던 메뉴를 새 브랜드로 다시 그린다.
//   반환 'ok' | 'not_linked' | 'error' | 'cancelled'(떠나기 전 확인에서 「계속 작성」). 사람이 고른 것이므로 활동으로 센다(S0-4).
let _brandSwitching = false;
async function switchBrand(id) {
  if (!brandSession || _brandSwitching) return 'error';
  if (id === brandSession.currentBrandId) return 'ok';
  if (!(await brandConfirmLeave('brand'))) return 'cancelled';
  if (!brandSession) return 'error';   // 묻는 사이 로그아웃됨
  _brandSwitching = true;
  try {
    const { data, error } = await brandRpc('set_my_brand_last_viewed', { p_brand_id: id });
    if (error || (data !== 'ok' && data !== 'not_linked')) {
      brandToast('브랜드를 바꾸지 못했습니다. 잠시 후 다시 시도해 주십시오.');
      return 'error';
    }
    if (!brandSession) return 'error';   // 응답을 기다리는 사이 로그아웃됨
    if (data === 'not_linked') { await handleBrandNotLinked(); return 'not_linked'; }
    brandSession.currentBrandId = id;
    renderBrandShellChrome();
    _emitBrandChanged();
    rerenderCurrentBrandPage();
    brandTouchActivity();
    return 'ok';
  } finally {
    _brandSwitching = false;
  }
}

// 서버가 「이 브랜드에 연결돼 있지 않다」고 답했을 때(바꾸기·페이지 함수 공용 — 조각 5·7 도 부른다)
async function handleBrandNotLinked() {
  brandToast('이 브랜드에서 빠져서 바꿀 수 없습니다.');   // 피그마 bw03-90
  // 판정 조회가 실패(null)하면 목록을 그대로 둔다 — 다음 판정(새로고침·다음 동작)에서 바로잡힌다
  const state = await refreshBrandLoginState();
  if (state && state.state === 'ok') rerenderCurrentBrandPage();
}

// 지금 보던 틀 페이지를 다시 그린다(브랜드가 바뀌었을 때)
function rerenderCurrentBrandPage() {
  if (!brandAuthed) return;
  const hash = location.hash.replace(/^#/, '');
  showBrandShellPage(isBrandShellPage(hash) ? hash : BRAND_FIRST_PAGE);
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
  renderBrandPickers();
  refreshInviteDot();
}

// 빨간 점 — 새 초대(new_invite_dot). 마이페이지 화면 안에는 그리지 않는다(조각 7 이 들어올 때 끈다).
function refreshInviteDot() {
  const on = !!(brandSession && brandSession.newInviteDot);
  document.querySelectorAll('.brand-dot, .brand-dot-sr').forEach(el => { el.hidden = !on; });
  const menuBtn = document.getElementById('brandTopbarMenuBtn');
  if (menuBtn) menuBtn.setAttribute('aria-label', on ? '메뉴 열기 (새 초대가 있습니다)' : '메뉴 열기');
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
  closeBrandPickerFull();   // 뒤로 가기 등 주소가 바뀌면 고르기 화면을 남기지 않는다
  closeBrandDrawer(false);
  const host = document.getElementById('brandPageHost');
  host.innerHTML = '';
  try { page.render(host); }
  catch (e) { host.innerHTML = '<div class="brand-empty"><p class="brand-empty-title">화면을 그리지 못했습니다</p><p class="brand-empty-desc">새로고침해 주십시오.</p></div>'; }
  document.title = (page.title || '브랜드') + ' · REVERB JP';
  window.scrollTo(0, 0);
  const main = document.getElementById('brandMain');
  if (main) main.scrollTop = 0;
}

// 틀을 감춘다(로그인 전 카드 화면으로 갈 때) — showBrandScreen 이 부른다
function hideBrandShell() {
  _emitBrandShellHidden();   // 열린 모달(오리엔시트 작성 등)을 묻지 않고 닫는다 — 세션이 이미 없거나 사용자가 떠나기로 한 뒤다
  closeBrandPickerPop(false);
  closeBrandPickerFull();
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
  clearBrandInviteLink();
  const devMail = document.getElementById('brandDevMail');   // 개발서버 메일 대신 보기(링크가 든 채 남지 않게)
  if (devMail) devMail.remove();
  await brandSignOutLocal();
  setBrandAuthed(null);
  goBrandScreen('login');
}

function initBrandShell() {
  document.querySelectorAll('[data-brand-menu]').forEach(el => { el.innerHTML = _brandMenuHtml(''); });
  initBrandPicker();
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
    if (document.getElementById('brandPickerFull')) { closeBrandPickerFull(); return; }   // 위에 뜬 고르기 화면부터
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
    try {
      closeBrandDrawer(false);
      if (!(await brandConfirmLeave('logout'))) return;
      await brandLogout();
    } finally { btn.disabled = false; }
  }));
}

// ── 좌측 위 브랜드 고르기 (피그마 bw03-01·01a·01b · bm03-01·01a·02·02a, 작업표 조각 2)
//   연결 브랜드 2개 이상일 때만 ⌃⌄. 8개 이상이면 웹은 검색 칸 + 7줄 반 높이 스크롤, 모바일 서랍은 한 줄 → 전체 화면 고르기.
//   🔴 「8개」 기준은 로그인 판정이 준 활성 연결 브랜드 수(brandSession.brands — 초대 대기·해제 제외).
const BRAND_PICKER_SEARCH_MIN = 8;

// 검색 — 이름 일부 일치, 영문 대소문자·띄어쓰기 무시
function _brandSearchKey(v) { return String(v || '').toLowerCase().replace(/\s+/g, ''); }
function filterBrandsForPicker(list, q) {
  const k = _brandSearchKey(q);
  return k ? list.filter(b => _brandSearchKey(b.name).includes(k)) : list;
}
function _brandNoMatchText(q) { return '‘' + q + '’와 일치하는 브랜드가 없습니다'; }

function _brandPickerRowsHtml(list) {
  const cur = getCurrentBrandId();
  return list.map(b => {
    const on = b.id === cur;
    return '<button type="button" class="brand-pick-row' + (on ? ' is-current' : '') + '" role="option" aria-selected="' + on + '" data-pick-brand="' + brandEsc(b.id) + '">' +
      '<span class="brand-pick-name">' + brandEsc(b.name) + '</span>' +
      (on ? '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">check</span>' : '') +
    '</button>';
  }).join('');
}

function renderBrandPickers() {
  if (!brandSession) return;
  const many = brandSession.brands.length >= 2;
  const cur = getCurrentBrand();
  // 웹 — 브랜드명 단추
  const host = document.getElementById('brandSwitcherHost');
  if (host) {
    const name = brandEsc(cur ? cur.name : '');
    host.innerHTML = many
      ? '<button type="button" class="brand-switcher-btn" id="brandSwitcherBtn" aria-haspopup="listbox" aria-expanded="false" aria-controls="brandPickerPop">' +
          '<span class="brand-switcher-name">' + name + '</span>' +
          '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">unfold_more</span></button>' +
        '<div class="brand-pick-pop" id="brandPickerPop" hidden></div>'
      : '<span class="brand-switcher-name">' + name + '</span>';
  }
  // 모바일 서랍 — 브랜드 묶음
  const box = document.getElementById('brandDrawerBrands');
  if (box) {
    box.hidden = !many;
    if (!many) box.innerHTML = '';
    else if (brandSession.brands.length >= BRAND_PICKER_SEARCH_MIN) {
      box.innerHTML = '<p class="brand-pick-sub">브랜드</p>' +
        '<button type="button" class="brand-pick-row is-current brand-pick-more" id="brandDrawerPickMore">' +
          '<span class="brand-pick-name">' + brandEsc(cur ? cur.name : '') + '</span>' +
          '<span class="brand-pick-count">바꾸기 · ' + brandSession.brands.length + '개</span>' +
          '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">chevron_right</span></button>';
    } else {
      box.innerHTML = '<p class="brand-pick-sub">브랜드</p><div role="listbox" aria-label="브랜드">' +
        _brandPickerRowsHtml(sortBrandsForPicker(brandSession.brands, getCurrentBrandId())) + '</div>';
    }
  }
}

// 웹 펼친 목록
function _renderPickerPop(q) {
  const pop = document.getElementById('brandPickerPop');
  if (!pop) return;
  const all = sortBrandsForPicker(brandSession.brands, getCurrentBrandId());
  const withSearch = all.length >= BRAND_PICKER_SEARCH_MIN;
  const list = withSearch ? filterBrandsForPicker(all, q) : all;
  const listHtml = list.length ? _brandPickerRowsHtml(list)
    : '<p class="brand-pick-empty">' + brandEsc(_brandNoMatchText(q)) + '</p>';
  if (pop.dataset.ready === '1' && withSearch) {
    pop.querySelector('.brand-pick-list').innerHTML = listHtml;
    return;
  }
  pop.dataset.ready = '1';
  pop.innerHTML = '<p class="brand-pick-sub">브랜드 바꾸기</p>' +
    (withSearch ? '<label class="brand-pick-search"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">search</span>' +
      '<input type="search" class="brand-pick-input" placeholder="브랜드 이름으로 찾기" aria-label="브랜드 이름으로 찾기" autocomplete="off"></label>' : '') +
    '<div class="brand-pick-list' + (withSearch ? ' is-scroll' : '') + '" role="listbox" aria-label="브랜드">' + listHtml + '</div>';
}
function openBrandPickerPop() {
  const pop = document.getElementById('brandPickerPop');
  const btn = document.getElementById('brandSwitcherBtn');
  if (!pop || !btn) return;
  pop.dataset.ready = '';
  _renderPickerPop('');                 // 다시 열면 검색어는 비어 있다
  pop.hidden = false;
  btn.setAttribute('aria-expanded', 'true');
  const input = pop.querySelector('.brand-pick-input');
  (input || pop.querySelector('.brand-pick-row.is-current') || pop.querySelector('.brand-pick-row') || btn).focus();
}
function closeBrandPickerPop(restoreFocus) {
  const pop = document.getElementById('brandPickerPop');
  if (!pop || pop.hidden) return;
  pop.hidden = true;
  const btn = document.getElementById('brandSwitcherBtn');
  if (btn) { btn.setAttribute('aria-expanded', 'false'); if (restoreFocus) btn.focus(); }
}

// 모바일 전체 화면 고르기(bm03-02) — 8개 이상일 때만 서랍의 한 줄에서 연다
function openBrandPickerFull() {
  closeBrandPickerFull();
  const wrap = document.createElement('div');
  wrap.className = 'brand-pick-full';
  wrap.id = 'brandPickerFull';
  wrap.setAttribute('role', 'dialog');
  wrap.setAttribute('aria-modal', 'true');
  wrap.setAttribute('aria-labelledby', 'brandPickFullTitle');
  wrap.innerHTML =
    '<div class="brand-pick-full-head">' +
      '<button type="button" class="brand-pick-back" data-pick-back aria-label="메뉴로 돌아가기">' +
        '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">arrow_back</span></button>' +
      '<h2 id="brandPickFullTitle">브랜드 바꾸기</h2></div>' +
    '<div class="brand-pick-full-search"><label class="brand-pick-search"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">search</span>' +
      '<input type="search" class="brand-pick-input" placeholder="브랜드 이름으로 찾기" aria-label="브랜드 이름으로 찾기" autocomplete="off"></label></div>' +
    '<div class="brand-pick-list" role="listbox" aria-label="브랜드"></div>';
  const listEl = wrap.querySelector('.brand-pick-list');
  const draw = (q) => {
    const list = filterBrandsForPicker(sortBrandsForPicker(brandSession.brands, getCurrentBrandId()), q);
    listEl.innerHTML = list.length ? _brandPickerRowsHtml(list) : '<p class="brand-pick-empty">' + brandEsc(_brandNoMatchText(q)) + '</p>';
  };
  draw('');
  wrap.querySelector('.brand-pick-input').addEventListener('input', (e) => draw(e.target.value.trim()));
  wrap.addEventListener('click', async (e) => {
    if (e.target.closest('[data-pick-back]')) { closeBrandPickerFull(); return; }
    const row = e.target.closest('[data-pick-brand]');
    if (!row) return;
    closeBrandPickerFull();
    closeBrandDrawer(false);
    await switchBrand(row.dataset.pickBrand);   // 지금 브랜드를 다시 고르면 화면과 메뉴만 닫힌다
  });
  wrap.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.stopPropagation(); closeBrandPickerFull(); return; }
    if (e.key !== 'Tab') return;
    // 화면 안에서만 초점이 돌게(aria-modal)
    const items = Array.from(wrap.querySelectorAll('button, input'));
    const i = items.indexOf(document.activeElement);
    if (i === -1) { e.preventDefault(); items[0].focus(); return; }
    if (e.shiftKey && i === 0) { e.preventDefault(); items[items.length - 1].focus(); }
    else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
  });
  document.body.appendChild(wrap);
  wrap.querySelector('[data-pick-back]').focus();
}
function closeBrandPickerFull() {
  const el = document.getElementById('brandPickerFull');
  if (!el) return;
  el.remove();
  const more = document.getElementById('brandDrawerPickMore');
  if (more && !document.getElementById('brandDrawer').hidden) more.focus();
}

function initBrandPicker() {
  const side = document.getElementById('brandSideMenu');
  side.addEventListener('click', async (e) => {
    if (e.target.closest('#brandSwitcherBtn')) {
      const pop = document.getElementById('brandPickerPop');
      if (pop && pop.hidden) openBrandPickerPop(); else closeBrandPickerPop(true);
      return;
    }
    const row = e.target.closest('#brandPickerPop [data-pick-brand]');
    if (row) {
      closeBrandPickerPop(false);
      await switchBrand(row.dataset.pickBrand);   // 지금 브랜드를 다시 고르면 아무 일도 없다
      // 브랜드명 단추는 다시 그려져 새 요소다 — 초점을 그 단추로 돌려 놓는다
      const btn = document.getElementById('brandSwitcherBtn');
      if (btn && brandAuthed) btn.focus();
    }
  });
  side.addEventListener('input', (e) => {
    if (e.target.matches('#brandPickerPop .brand-pick-input')) _renderPickerPop(e.target.value.trim());
  });
  // 바깥 누르기·ESC → 닫힘(그대로)
  document.addEventListener('mousedown', (e) => {
    const pop = document.getElementById('brandPickerPop');
    if (pop && !pop.hidden && !e.target.closest('#brandSwitcherHost')) closeBrandPickerPop(false);
  });
  document.addEventListener('keydown', (e) => {
    const pop = document.getElementById('brandPickerPop');
    if (e.key === 'Escape' && pop && !pop.hidden) { closeBrandPickerPop(true); return; }
    // 목록 안 위·아래 화살표
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && pop && !pop.hidden && pop.contains(document.activeElement)) {
      const rows = Array.from(pop.querySelectorAll('.brand-pick-row'));
      if (!rows.length) return;
      e.preventDefault();
      const i = rows.indexOf(document.activeElement);
      const next = e.key === 'ArrowDown' ? (i < 0 ? 0 : Math.min(i + 1, rows.length - 1)) : (i <= 0 ? 0 : i - 1);
      rows[next].focus();
    }
  });
  // 모바일 서랍 — 7개까지는 서랍에서 바로 고르고, 8개 이상은 한 줄 → 전체 화면
  document.getElementById('brandDrawerBrands').addEventListener('click', async (e) => {
    if (e.target.closest('#brandDrawerPickMore')) { openBrandPickerFull(); return; }
    const row = e.target.closest('[data-pick-brand]');
    if (!row) return;
    closeBrandDrawer(false);
    await switchBrand(row.dataset.pickBrand);
  });
}
