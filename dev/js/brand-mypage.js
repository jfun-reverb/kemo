// 브랜드 페이지 — 마이페이지(07): 계정 정보 보기·수정 · 연결된 브랜드와 역할 · 받은 초대 수락·거절 · 빨간 점 끄기 · 로그아웃
//   작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 7 (비밀번호 변경 모달은 조각 8)
//   피그마 bw07-00(보기)·bw07-00a(수정 중)·bw07-00b(받은 초대)·bw07-02(거절 확인)·bw07-90(토스트)
//   🔴 마이페이지는 계정 단위다 — 브랜드를 바꿔도 내용이 같다. 그래서 이 페이지의 저장·수락·거절은
//      brandTouchActivity(「마지막 접속」)를 부르지 않는다(작업표 S0-4).
//   🔴 마이페이지 수락은 지금 브랜드·마지막으로 본 브랜드를 바꾸지 않고 마이페이지에 머문다
//      (초대 수락 화면 bw01-03 의 「그 브랜드로 연다」와 다르다 — set_my_brand_last_viewed 를 부르지 않는다).

const BRAND_MYPAGE_MSG = {
  loadFail: '계정 정보를 불러오지 못했습니다.',
  invitesFail: '받은 초대를 불러오지 못했습니다.',
  saved: '계정 정보를 저장했습니다.',                                  // bw07-90
  saveFail: '저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.',        // bw07-90
  nameEmpty: '이름을 입력해 주십시오.',                                // 비밀번호 설정 화면과 같은 문구(피그마 bw07-00a 미정)
  declined: '초대를 거절했습니다.',                                    // bw07-90
  invalid: '이 초대는 더 이상 쓸 수 없습니다.',                        // bw07-90
  acceptFail: '브랜드를 연결하지 못했습니다. 잠시 후 다시 시도해 주십시오.',   // 초대 수락 화면(bw01-92 ⑥)과 같은 문구
  declineFail: '처리하지 못했습니다. 잠시 후 다시 시도해 주십시오.'           // 피그마에 없음 — 멤버 관리 임시 문구와 같게
};
function _brandMyAcceptedMsg(brandName) { return (brandName || '') + ' 브랜드가 연결됐습니다.'; }   // bw07-90

// 본인 계정 행 — undefined = 불러오는 중 · null = 실패 · { name, email, phone, password_changed_at }
let _brandMyAccount;
// 받은 초대 — undefined = 불러오는 중 · null = 실패 · [] = 없음
let _brandMyInvites;
let _brandMyEditing = false;
let _brandMyBusy = false;     // 저장·수락·거절 중 — 다른 단추를 잠근다
let _brandMyLoadSeq = 0;

// ── 서버
// 연락처는 로그인 판정에 없어 본인 행을 직접 읽는다(526 정책 brand_accounts_select — auth_id = 로그인 사용자만)
async function fetchMyBrandAccount() {
  if (!brandDb) return null;
  try {
    const { data: u } = await brandDb.auth.getUser();
    const uid = u && u.user ? u.user.id : null;
    if (!uid) return null;
    const { data, error } = await brandDb.from('brand_accounts')
      .select('name, email, phone, password_changed_at').eq('auth_id', uid).maybeSingle();
    if (error || !data) return null;
    return data;
  } catch (e) { return null; }
}

// 마이페이지를 연 시각을 남겨 빨간 점을 끈다 — 실패해도 화면은 그대로(다음 판정에서 다시 켜질 뿐)
async function markMyBrandMypageSeen() {
  const { data, error } = await brandRpc('mark_my_brand_mypage_seen');
  if (error || data !== 'ok') return false;
  if (brandSession) { brandSession.newInviteDot = false; refreshInviteDot(); }
  return true;
}

async function loadBrandMypage() {
  const seq = ++_brandMyLoadSeq;
  const [acct, invites] = await Promise.all([fetchMyBrandAccount(), fetchMyBrandInvites()]);
  if (seq !== _brandMyLoadSeq) return;
  _brandMyAccount = acct;
  _brandMyInvites = invites;
  _rerenderMypageIfShown();
}

async function reloadMyBrandInvites() {
  const seq = ++_brandMyLoadSeq;
  const invites = await fetchMyBrandInvites();
  if (seq !== _brandMyLoadSeq) return;
  _brandMyInvites = invites;
  _rerenderMypageIfShown();
}

function _rerenderMypageIfShown() {
  if (location.hash !== '#mypage' || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (!host) return;
  // 수정 중에 다시 그려지면(초대 수락·늦게 온 응답) 입력하던 글자를 지키고 초점도 돌려 놓는다
  const keep = _brandMyEditing ? ['brandMyName', 'brandMyPhone'].map(id => {
    const el = document.getElementById(id);
    return el ? { id, value: el.value, focused: document.activeElement === el } : null;
  }).filter(Boolean) : [];
  renderBrandMypage(host);
  keep.forEach(k => {
    const el = document.getElementById(k.id);
    if (!el) return;
    el.value = k.value;
    if (k.focused) el.focus();
  });
}

// ── 그리기
function _brandMyBtn(label, act, opts) {
  const o = opts || {};
  return '<button type="button" class="brand-my-btn' + (o.fill ? ' is-fill' : '') + '" data-my-act="' + act + '"' +
    (o.data ? ' ' + o.data : '') + (_brandMyBusy ? ' disabled' : '') + '>' + brandEsc(label) + '</button>';
}

function _brandMySectionHead(title, toolsHtml) {
  return '<div class="brand-my-head"><h2>' + brandEsc(title) + '</h2>' +
    (toolsHtml ? '<div class="brand-my-tools">' + toolsHtml + '</div>' : '') + '</div>';
}

function _brandMyAccountHtml() {
  const a = _brandMyAccount;
  let body;
  if (a === undefined) body = stateLoadingBrand();
  else if (a === null) {
    body = '<div class="brand-empty"><p class="brand-empty-title">' + brandEsc(BRAND_MYPAGE_MSG.loadFail) + '</p>' +
      '<button type="button" class="brand-btn brand-btn-line brand-btn-inline" data-my-act="reload">다시 시도</button></div>';
  } else if (_brandMyEditing) {
    // bw07-00a — 이름·연락처만 열린다. 입력 한도는 비밀번호 설정 화면과 같게(이름 40 · 연락처 20)
    body = '<div class="brand-my-fields">' +
      '<div class="brand-my-field"><label for="brandMyName">이름</label>' +
        '<input type="text" id="brandMyName" class="brand-my-input" value="' + brandEsc(a.name || '') + '" maxlength="40" autocomplete="name"' + (_brandMyBusy ? ' disabled' : '') + '>' +
        '<p class="brand-field-error" id="brandMyNameError" hidden></p></div>' +
      '<div class="brand-my-field"><span class="brand-my-label">이메일 (로그인 아이디)</span><div class="brand-my-value is-locked">' + brandEsc(a.email || '') + '</div></div>' +
      '<div class="brand-my-field"><label for="brandMyPhone">연락처</label>' +
        '<input type="tel" id="brandMyPhone" class="brand-my-input" value="' + brandEsc(a.phone || '') + '" maxlength="20" inputmode="tel" autocomplete="tel"' + (_brandMyBusy ? ' disabled' : '') + '></div>' +
    '</div>';
  } else {
    const val = (v) => v ? brandEsc(v) : '<span class="brand-dash">—</span>';
    body = '<div class="brand-my-fields">' +
      '<div class="brand-my-field"><span class="brand-my-label">이름</span><div class="brand-my-value">' + val(a.name) + '</div></div>' +
      '<div class="brand-my-field"><span class="brand-my-label">이메일 (로그인 아이디)</span><div class="brand-my-value is-locked">' + brandEsc(a.email || '') + '</div></div>' +
      '<div class="brand-my-field"><span class="brand-my-label">연락처</span><div class="brand-my-value">' + val(a.phone) + '</div></div>' +
    '</div>';
  }
  const tools = !a ? '' : (_brandMyEditing
    ? _brandMyBtn('취소', 'edit-cancel') + _brandMyBtn('저장', 'edit-save', { fill: true })
    : _brandMyBtn('수정', 'edit'));
  return '<section class="brand-my-section" aria-labelledby="brandMyAcctTitle">' +
    _brandMySectionHead('계정 정보', tools).replace('<h2>', '<h2 id="brandMyAcctTitle">') + body + '</section>';
}

function _brandMyInviteRowHtml(inv) {
  const recv = _brandInviteMd(inv.issued_at);
  const until = _brandInviteMd(inv.expires_at);
  const meta = '초대한 사람 ' + (inv.inviter_name || '') + '(대표 담당자)' +
    (recv ? ' · ' + recv + ' 받음' : '') + (until ? ' · ' + until + '까지 수락할 수 있습니다' : '');
  return '<li class="brand-my-invite">' +
    '<div class="brand-my-invite-text"><p class="brand-my-invite-name">' + brandEsc(inv.brand_name || '') + '</p>' +
      '<p class="brand-my-invite-meta">' + brandEsc(meta) + '</p></div>' +
    '<div class="brand-my-invite-btns">' +
      _brandMyBtn('거절', 'decline', { data: 'data-invite="' + brandEsc(inv.invite_id) + '"' }) +
      _brandMyBtn('수락', 'accept', { fill: true, data: 'data-invite="' + brandEsc(inv.invite_id) + '"' }) +
    '</div></li>';
}

function _brandMyBrandsHtml() {
  // 연결된 브랜드 — 지금 고른 브랜드와 상관없이 전부, 이름순. 역할 표시는 여기에만 있다(브랜드 고르기 목록에는 없다)
  const brands = brandSession ? brandSession.brands.slice().sort((x, y) => compareBrandNames(x.name, y.name)) : [];
  const rows = brands.map(b =>
    '<li class="brand-my-brand"><span class="brand-my-brand-name">' + brandEsc(b.name) + '</span>' +
      (b.role === 'owner' ? _brandPill('대표', 'is-owner') : _brandPill('멤버', 'is-member')) + '</li>'
  ).join('');
  // 받은 초대 — 없으면 묶음을 그리지 않는다(bw07-00b). 불러오는 중이면 아무것도, 실패면 한 줄 + 다시 시도
  const inv = _brandMyInvites;
  let invHtml = '';
  if (inv === null) {
    invHtml = '<div class="brand-my-invites"><p class="brand-my-small">' + brandEsc(BRAND_MYPAGE_MSG.invitesFail) +
      ' <button type="button" class="brand-text-btn" data-my-act="reload-invites">다시 시도</button></p></div>';
  } else if (Array.isArray(inv) && inv.length) {
    invHtml = '<div class="brand-my-invites">' +
      '<p class="brand-my-invites-head">받은 초대 ' + inv.length + '<span class="brand-my-invites-dot" aria-hidden="true"></span></p>' +
      '<ul class="brand-my-invite-list">' + inv.map(_brandMyInviteRowHtml).join('') + '</ul></div>';
  }
  return '<section class="brand-my-section" aria-labelledby="brandMyBrandsTitle">' +
    _brandMySectionHead('연결된 브랜드').replace('<h2>', '<h2 id="brandMyBrandsTitle">') +
    '<ul class="brand-my-brand-list">' + rows + '</ul>' + invHtml +
    '<p class="brand-my-small">좌측 위에서 브랜드를 바꿔 쓸 수 있습니다. 브랜드에서 빠지려면 그 브랜드의 대표 담당자나 운영팀에 요청해 주십시오.</p>' +
  '</section>';
}

function _brandMyPasswordHtml() {
  const a = _brandMyAccount;
  const at = a ? a.password_changed_at : (brandSession ? brandSession.passwordChangedAt : null);
  const day = brandFormatDate(at);
  // 「비밀번호 변경」 단추(bw07-01 모달)는 조각 8 이 붙인다
  return '<section class="brand-my-section" aria-labelledby="brandMyPwTitle">' +
    _brandMySectionHead('비밀번호').replace('<h2>', '<h2 id="brandMyPwTitle">') +
    '<p class="brand-my-small">마지막 변경 ' + (day ? brandEsc(day) : '—') + '</p>' +
  '</section>';
}

function renderBrandMypage(host) {
  host.innerHTML =
    '<div class="brand-page-head"><div><h1>마이페이지</h1><p>로그인한 담당자 본인의 정보입니다.</p></div></div>' +
    _brandMyAccountHtml() + _brandMyBrandsHtml() + _brandMyPasswordHtml() +
    '<div class="brand-my-foot">' + _brandMyBtn('로그아웃', 'logout') + '</div>';
}

// ── 동작
function _brandMySetBusy(busy) {
  _brandMyBusy = busy;
  document.querySelectorAll('#brandPageHost [data-my-act], #brandPageHost .brand-my-input').forEach(el => { el.disabled = busy; });
}

function _brandMyNameError(msg) {
  const input = document.getElementById('brandMyName');
  const err = document.getElementById('brandMyNameError');
  if (!input || !err) return;
  input.classList.toggle('is-error', !!msg);
  if (msg) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
  err.textContent = msg || '';
  err.hidden = !msg;
  if (msg) { input.setAttribute('aria-describedby', 'brandMyNameError'); input.focus(); }
}

async function saveMyBrandProfile() {
  const nameEl = document.getElementById('brandMyName');
  const phoneEl = document.getElementById('brandMyPhone');
  if (!nameEl || !phoneEl) return;
  const name = nameEl.value.trim();
  const phone = phoneEl.value.trim();
  if (!name) { _brandMyNameError(BRAND_MYPAGE_MSG.nameEmpty); return; }
  _brandMyNameError('');
  _brandMySetBusy(true);
  const { data, error } = await brandRpc('update_my_brand_profile', { p_name: name, p_phone: phone });
  _brandMySetBusy(false);
  if (!error && data === 'name_required') { _brandMyNameError(BRAND_MYPAGE_MSG.nameEmpty); return; }
  if (error || data !== 'ok') { brandToast(BRAND_MYPAGE_MSG.saveFail, { error: true }); return; }   // 수정 상태 유지
  if (_brandMyAccount) { _brandMyAccount.name = name; _brandMyAccount.phone = phone || null; }
  if (brandSession) { brandSession.name = name; renderBrandShellChrome(); }   // 좌측 아래 이름도 새 값으로
  _brandMyEditing = false;
  _rerenderMypageIfShown();
  brandToast(BRAND_MYPAGE_MSG.saved);
}

function _brandMyFindInvite(id) {
  return Array.isArray(_brandMyInvites) ? _brandMyInvites.find(i => i.invite_id === id) || null : null;
}

async function acceptMyBrandInvite(inviteId) {
  const inv = _brandMyFindInvite(inviteId);
  if (!inv) return;
  _brandMySetBusy(true);
  const r = await respondBrandInvite({ inviteId, action: 'accept' });
  if (!r) { _brandMySetBusy(false); brandToast(BRAND_MYPAGE_MSG.acceptFail, { error: true }); return; }
  if (r.result === 'ok' || r.result === 'already_member') {
    brandToast(_brandMyAcceptedMsg(inv.brand_name));
    // 연결된 브랜드·브랜드 고르기 목록을 새로(둘이 되면 ⌃⌄ 생김). 지금 브랜드는 그대로 — 판정이 보던 브랜드를 이어받는다
    await refreshBrandLoginState();
  } else if (r.result === 'invalid') {
    brandToast(BRAND_MYPAGE_MSG.invalid, { error: true });
  } else {
    // not_brand · setup_incomplete — 계정 상태가 바뀜. 로그인 판정 갈래를 그대로 따른다
    _brandMySetBusy(false);
    await refreshBrandLoginState();
    return;
  }
  _brandMyBusy = false;
  await reloadMyBrandInvites();
  _rerenderMypageIfShown();
}

async function declineMyBrandInvite(inviteId) {
  const inv = _brandMyFindInvite(inviteId);
  if (!inv) return;
  const brand = inv.brand_name || '';
  const until = _brandInviteMd(inv.expires_at);
  const ok = await brandConfirm({
    title: brand + ' 브랜드 초대를 거절하시겠습니까?',
    sub: '초대한 사람 ' + (inv.inviter_name || '') + '(대표 담당자)' + (until ? ' · ' + until + '까지 수락할 수 있는 초대입니다.' : ''),
    body: '거절하면 이 초대로는 ' + brand + ' 브랜드 페이지에 들어갈 수 없습니다.\n다시 함께하려면 대표 담당자에게 새로 초대해 달라고 요청해 주십시오.',
    okLabel: '거절', cancelLabel: '취소', card: true, wide: true   // 피그마 bw07-02 「취소 · 거절」, 거절은 검정 채움
  });
  if (!ok) return;
  _brandMySetBusy(true);
  const r = await respondBrandInvite({ inviteId, action: 'decline' });
  if (!r) { _brandMySetBusy(false); brandToast(BRAND_MYPAGE_MSG.declineFail, { error: true }); return; }
  if (r.result === 'ok') brandToast(BRAND_MYPAGE_MSG.declined);
  else if (r.result === 'invalid') brandToast(BRAND_MYPAGE_MSG.invalid, { error: true });
  else { _brandMySetBusy(false); await refreshBrandLoginState(); return; }
  _brandMyBusy = false;
  await reloadMyBrandInvites();
}

// 들어올 때마다 — 점 끄기 → 판정 다시 받기(연결 브랜드·역할을 서버가 지금 허용하는 것으로) → 계정·초대 받기
async function enterBrandMypage() {
  await markMyBrandMypageSeen();
  const state = await refreshBrandLoginState();
  if (state && state.state !== 'ok') return;   // 연결이 모두 사라짐 — 판정 갈래가 화면을 옮겼다
  _rerenderMypageIfShown();
  await loadBrandMypage();
}

registerBrandPage('mypage', {
  title: '마이페이지',
  render(host) {
    renderBrandMypage(host);
    if (this._entering) return;
    this._entering = true;
    // 브랜드를 바꿔 다시 그려질 때도 새로 받는다(계정 단위라 내용은 같다)
    enterBrandMypage().finally(() => { this._entering = false; });
  }
});

// 다른 페이지로 나가면 수정 상태를 버린다(저장하지 않은 입력 — 확인 창은 피그마 미정)
window.addEventListener('hashchange', () => {
  if (location.hash !== '#mypage') { _brandMyEditing = false; _brandMyAccount = undefined; _brandMyInvites = undefined; }
});

document.addEventListener('click', async (e) => {
  const btn = e.target.closest('#brandPageHost [data-my-act]');
  if (!btn || btn.disabled) return;
  const act = btn.dataset.myAct;
  if (act === 'reload') { _brandMyAccount = undefined; _rerenderMypageIfShown(); loadBrandMypage(); return; }
  if (act === 'reload-invites') { _brandMyInvites = undefined; _rerenderMypageIfShown(); reloadMyBrandInvites(); return; }
  if (act === 'edit') {
    _brandMyEditing = true;
    _rerenderMypageIfShown();
    const n = document.getElementById('brandMyName');
    if (n) n.focus();
    return;
  }
  if (act === 'edit-cancel') { _brandMyEditing = false; _rerenderMypageIfShown(); return; }   // 원래 값으로
  if (act === 'edit-save') { await saveMyBrandProfile(); return; }
  if (act === 'accept') { await acceptMyBrandInvite(btn.dataset.invite); return; }
  if (act === 'decline') { await declineMyBrandInvite(btn.dataset.invite); return; }
  if (act === 'logout') {
    _brandMySetBusy(true);
    try { await brandLogout(); } finally { _brandMySetBusy(false); }   // 실패해 화면에 남아도 단추가 잠긴 채로 두지 않는다
  }
});

// 수정 중 엔터 = 저장
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || !e.target.matches('#brandPageHost .brand-my-input') || e.isComposing) return;
  e.preventDefault();
  if (!_brandMyBusy) saveMyBrandProfile();
});
