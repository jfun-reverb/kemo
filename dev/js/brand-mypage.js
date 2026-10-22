// 브랜드 페이지 — 마이페이지(07): 계정 정보 보기·수정 · 연결된 브랜드와 역할 · 받은 초대 수락·거절 · 빨간 점 끄기 · 로그아웃
//   작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 7 · 조각 8(비밀번호 변경 모달 bw07-01·01a·01b)
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
  phoneFormat: '연락처 형식을 확인해 주십시오(숫자와 하이픈).',          // bw07-91 ②
  declined: '초대를 거절했습니다.',                                    // bw07-90
  invalid: '이 초대는 더 이상 쓸 수 없습니다.',                        // bw07-90
  acceptFail: '브랜드를 연결하지 못했습니다. 잠시 후 다시 시도해 주십시오.',   // 초대 수락 화면(bw01-92 ⑥)과 같은 문구
  agreeRequired: '수락하려면 이용약관과 개인정보처리방침에 동의해 주십시오.',     // 초대 수락 화면과 같은 문구
  declineFail: '처리하지 못했습니다. 잠시 후 다시 시도해 주십시오.',          // 피그마에 없음 — 멤버 관리 임시 문구와 같게
  pwChanged: '비밀번호를 바꿨습니다.',                                  // bw07-90
  pwWrong: '현재 비밀번호가 맞지 않습니다.',                            // bw07-01a
  pwTooMany: '시도가 너무 많습니다. 잠시 후 다시 시도해 주십시오.',     // 피그마에 상태 없음(bw07-01 「확인 필요」) — 칸 아래에 낸다
  pwRelogin: '비밀번호를 바꿨습니다. 새 비밀번호로 다시 로그인해 주십시오.'
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
        '<input type="tel" id="brandMyPhone" class="brand-my-input" value="' + brandEsc(a.phone || '') + '" maxlength="20" inputmode="tel" autocomplete="tel"' + (_brandMyBusy ? ' disabled' : '') + '>' +
        '<p class="brand-field-error" id="brandMyPhoneError" hidden></p></div>' +
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

// 받은 초대 한 줄 — 멤버 초대와 연결 요청(invite_kind='owner_link')이 같은 묶음에 산다(연결 요청 사양서 L1).
//   수락 = 그때 시행 중인 약관 동의라 줄마다 동의 칸 하나 + 「보기」 둘(사양서 L3).
//   🔴 「보기」는 data-legal 이 아니라 data-my-act — data-legal 은 부팅 때 한 번만 묶여 나중에 그린 이 줄엔 안 붙는다(작업표 의심 5)
function _brandMyInviteRowHtml(inv) {
  const recv = _brandInviteMd(inv.issued_at);
  const until = _brandInviteMd(inv.expires_at);
  const who = isOwnerLinkInvite(inv)
    ? '보낸 곳 REVERB 운영팀 · 대표 담당자로 연결'
    : '초대한 사람 ' + (inv.inviter_name || '') + '(대표 담당자)';
  const meta = who + (recv ? ' · ' + recv + ' 받음' : '') + (until ? ' · ' + until + '까지 수락할 수 있습니다' : '');
  const id = brandEsc(inv.invite_id);
  const dis = _brandMyBusy ? ' disabled' : '';
  return '<li class="brand-my-invite"><div class="brand-my-invite-body">' +
    '<div class="brand-my-invite-top">' +
      '<div class="brand-my-invite-text"><p class="brand-my-invite-name">' + brandEsc(inv.brand_name || '') + '</p>' +
        '<p class="brand-my-invite-meta">' + brandEsc(meta) + '</p></div>' +
      '<div class="brand-my-invite-btns">' +
        _brandMyBtn('거절', 'decline', { data: 'data-invite="' + id + '"' }) +
        _brandMyBtn('수락', 'accept', { fill: true, data: 'data-invite="' + id + '"' }) +
      '</div></div>' +
    '<div class="brand-agree brand-accept-agree brand-my-invite-agree" data-agree-box="' + id + '">' +
      '<label class="brand-check"><input type="checkbox" class="brand-my-invite-agree-check" data-agree-invite="' + id + '"' + dis + '>' +
        '<span>[필수] 이용약관과 개인정보처리방침에 동의합니다</span></label>' +
      '<div class="brand-accept-agree-views">' +
        '<button type="button" class="brand-agree-view" data-my-act="legal" data-legal-kind="terms"' + dis + '>이용약관 보기</button>' +
        '<button type="button" class="brand-agree-view" data-my-act="legal" data-legal-kind="privacy"' + dis + '>개인정보처리방침 보기</button>' +
      '</div></div>' +
    '<p class="brand-field-error" data-agree-error="' + id + '" role="alert" hidden></p>' +
  '</div></li>';
}

function _brandMyAgreeEls(inviteId) {
  const host = document.getElementById('brandPageHost');
  if (!host) return {};
  const pick = (attr) => Array.from(host.querySelectorAll('[' + attr + ']')).find(el => el.getAttribute(attr) === inviteId) || null;
  return { check: pick('data-agree-invite'), box: pick('data-agree-box'), err: pick('data-agree-error') };
}
function _brandMyAgreeError(inviteId, msg) {
  const els = _brandMyAgreeEls(inviteId);
  if (els.box) els.box.classList.toggle('is-error', !!msg);
  if (els.err) { els.err.textContent = msg || ''; els.err.hidden = !msg; }
  if (msg && els.check) els.check.focus();
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
  return '<section class="brand-my-section" aria-labelledby="brandMyPwTitle">' +
    _brandMySectionHead('비밀번호', _brandMyBtn('비밀번호 변경', 'password')).replace('<h2>', '<h2 id="brandMyPwTitle">') +
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
  document.querySelectorAll('#brandPageHost [data-my-act], #brandPageHost .brand-my-input, #brandPageHost .brand-my-invite-agree-check').forEach(el => { el.disabled = busy; });
}

function _brandMyFieldError(id, msg) {
  const input = document.getElementById(id);
  const err = document.getElementById(id + 'Error');
  if (!input || !err) return;
  input.classList.toggle('is-error', !!msg);
  if (msg) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
  err.textContent = msg || '';
  err.hidden = !msg;
  if (msg) { input.setAttribute('aria-describedby', id + 'Error'); input.focus(); }
}
function _brandMyNameError(msg) { _brandMyFieldError('brandMyName', msg); }

// 연락처 형식(bw07-91 ②) — 숫자와 하이픈만, 숫자는 하나 이상. 빈 칸은 그대로 저장(선택 칸).
//   화면 검사만이다(서버는 형식을 안 본다). 저장된 값을 안 고쳤으면 검사하지 않는다 — 형식 검사 전에 들어간 옛 값 때문에 이름 저장이 막히지 않게
const BRAND_MY_PHONE_RE = /^[0-9-]*[0-9][0-9-]*$/;
function _brandMyPhoneIssue(phone) {
  if (!phone) return '';
  if (_brandMyAccount && phone === String(_brandMyAccount.phone || '').trim()) return '';
  return BRAND_MY_PHONE_RE.test(phone) ? '' : BRAND_MYPAGE_MSG.phoneFormat;
}

async function saveMyBrandProfile() {
  const nameEl = document.getElementById('brandMyName');
  const phoneEl = document.getElementById('brandMyPhone');
  if (!nameEl || !phoneEl) return;
  const name = nameEl.value.trim();
  const phone = phoneEl.value.trim();
  if (!name) { _brandMyFieldError('brandMyPhone', ''); _brandMyNameError(BRAND_MYPAGE_MSG.nameEmpty); return; }
  _brandMyNameError('');
  const phoneIssue = _brandMyPhoneIssue(phone);
  _brandMyFieldError('brandMyPhone', phoneIssue);
  if (phoneIssue) return;
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
  // 동의 없이 누르면 서버를 부르지 않는다
  const agreeEl = _brandMyAgreeEls(inviteId).check;
  if (!agreeEl || !agreeEl.checked) { _brandMyAgreeError(inviteId, BRAND_MYPAGE_MSG.agreeRequired); return; }
  _brandMyAgreeError(inviteId, '');
  _brandMySetBusy(true);
  const r = await respondBrandInvite({ inviteId, action: 'accept', termsVersion: BRAND_TERMS_VERSION });
  // 이용 제한 — 공통 입구가 이미 「이용이 제한된 계정」 화면으로 보냈다. 실패 안내를 겹쳐 띄우지 않는다(제한 14)
  if (!r && _brandRestrictedHandled) { _brandMySetBusy(false); return; }
  // terms_version_required 는 화면이 늘 보내므로 일반 실패로(연결 요청 사양서 4-4)
  if (!r || r.result === 'terms_version_required') { _brandMySetBusy(false); brandToast(BRAND_MYPAGE_MSG.acceptFail, { error: true }); return; }
  if (r.result === 'ok' || r.result === 'already_member') {
    brandToast(_brandMyAcceptedMsg(inv.brand_name));
    // 연결된 브랜드·브랜드 고르기 목록을 새로(둘이 되면 ⌃⌄ 생김). 지금 브랜드는 그대로 — 판정이 보던 브랜드를 이어받는다
    await refreshBrandLoginState();
  } else if (r.result === 'invalid') {
    brandToast(isOwnerLinkInvite(inv) ? BRAND_INVITE_MSG.linkInvalid : BRAND_MYPAGE_MSG.invalid, { error: true });
  } else if (r.result === 'owner_exists') {
    brandToast(BRAND_INVITE_MSG.ownerExists, { error: true });
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
  const ownerLink = isOwnerLinkInvite(inv);
  const t = brandInviteDeclineText(inv);
  const ok = await brandConfirm({
    title: t.title, sub: t.sub, body: t.body,
    okLabel: '거절', cancelLabel: '취소', card: true, wide: true   // 피그마 bw07-02 「취소 · 거절」, 거절은 검정 채움
  });
  if (!ok) return;
  _brandMySetBusy(true);
  const r = await respondBrandInvite({ inviteId, action: 'decline' });
  if (!r) { _brandMySetBusy(false); brandToast(BRAND_MYPAGE_MSG.declineFail, { error: true }); return; }
  if (r.result === 'ok') brandToast(ownerLink ? BRAND_INVITE_MSG.linkDeclined : BRAND_MYPAGE_MSG.declined);
  else if (r.result === 'invalid') brandToast(ownerLink ? BRAND_INVITE_MSG.linkInvalid : BRAND_MYPAGE_MSG.invalid, { error: true });
  else { _brandMySetBusy(false); await refreshBrandLoginState(); return; }
  _brandMyBusy = false;
  await reloadMyBrandInvites();
}

// ── 비밀번호 변경 모달(피그마 bw07-01 · 01a 현재 비밀번호 틀림 · 01b 규칙 미달)
//   회색 상자 + 흰 카드 + 오른쪽 「취소 · 변경」, 보기(눈) 단추 없음. 검사 순서: 빈 칸 → 규칙 → 두 칸 일치 → 서버의 현재 비밀번호 확인.
//   흔한 비밀번호 경고(bw07-01c)는 조각 9. 바꾸는 순서·세션 처리는 brandChangePasswordWithCurrent(brand-core.js).
const BRAND_PW_HINT = '8자 이상 · 영문 소문자와 기호 포함';
function openBrandPasswordModal() {
  closeBrandPasswordModal();
  const prevFocus = document.activeElement;
  const wrap = document.createElement('div');
  wrap.className = 'brand-modal';
  wrap.id = 'brandPwModal';
  wrap.setAttribute('role', 'dialog');
  wrap.setAttribute('aria-modal', 'true');
  wrap.setAttribute('aria-labelledby', 'brandPwTitle');
  const field = (id, label, opts) =>
    '<div class="brand-field">' +
      '<label for="' + id + '">' + label + '</label>' +
      '<input type="password" id="' + id + '" class="brand-input" autocomplete="' + opts.ac + '"' + (opts.ph ? ' placeholder="' + opts.ph + '"' : '') + '>' +
      (opts.hint ? '<p class="brand-pw-hint" id="' + id + 'Hint">' + opts.hint + '</p>' : '') +
      '<p class="brand-field-error" id="' + id + 'Error" hidden></p>' +
    '</div>';
  wrap.innerHTML =
    '<form class="brand-modal-box brand-modal-form is-pw" novalidate>' +
      '<h2 id="brandPwTitle">비밀번호 변경</h2>' +
      '<p class="brand-modal-sub">현재 비밀번호를 확인한 뒤 바꿉니다.</p>' +
      '<div class="brand-modal-card">' +
        field('brandPwCurrent', '현재 비밀번호', { ac: 'current-password' }) +
        field('brandPwNew', '새 비밀번호', { ac: 'new-password', ph: BRAND_PW_HINT, hint: BRAND_PW_HINT }) +
        field('brandPwNew2', '새 비밀번호 확인', { ac: 'new-password', ph: '한 번 더 입력해 주십시오' }) +
      '</div>' +
      '<div class="brand-modal-actions is-right">' +
        '<button type="button" class="brand-btn brand-btn-line" data-pw="cancel">취소</button>' +
        '<button type="submit" class="brand-btn" data-pw="ok">변경</button>' +
      '</div>' +
    '</form>';
  const form = wrap.querySelector('form');
  let busy = false;
  const close = () => {
    if (busy) return;
    wrap.remove();
    document.removeEventListener('keydown', onKey, true);
    if (prevFocus && prevFocus.isConnected) prevFocus.focus();
  };
  const onKey = (e) => {
    if (e.key === 'Escape') { e.stopPropagation(); close(); return; }
    if (e.key !== 'Tab') return;
    const items = Array.from(form.querySelectorAll('input, button')).filter(el => !el.disabled);
    if (!items.length) return;
    const i = items.indexOf(document.activeElement);
    if (i === -1) { e.preventDefault(); items[0].focus(); }
    else if (e.shiftKey && i === 0) { e.preventDefault(); items[items.length - 1].focus(); }
    else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
  };
  // 오류가 나면 규칙 안내 자리를 오류 문구가 대신한다(bw07-01b)
  const setErr = (id, msg) => {
    setFieldError(id, msg);
    const hint = document.getElementById(id + 'Hint');
    if (hint) hint.hidden = !!msg;
  };
  wrap._close = close;
  wrap.addEventListener('click', (e) => { if (e.target === wrap || e.target.closest('[data-pw="cancel"]')) close(); });
  form.querySelectorAll('input').forEach(el => el.addEventListener('input', () => setErr(el.id, '')));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    const cur = form.querySelector('#brandPwCurrent');
    const nw = form.querySelector('#brandPwNew');
    const nw2 = form.querySelector('#brandPwNew2');
    ['brandPwCurrent', 'brandPwNew', 'brandPwNew2'].forEach(id => setErr(id, ''));
    if (!cur.value) { setErr('brandPwCurrent', BRAND_MSG.pwEmpty); cur.focus(); return; }
    const rule = brandPasswordIssue(nw.value);
    if (rule) { setErr('brandPwNew', rule); nw.focus(); return; }
    if (!nw2.value) { setErr('brandPwNew2', BRAND_MSG.pw2Empty); nw2.focus(); return; }
    if (nw.value !== nw2.value) { setErr('brandPwNew2', BRAND_MSG.pwMismatch); nw2.focus(); return; }
    const email = (_brandMyAccount && _brandMyAccount.email) || (brandSession && brandSession.email) || '';
    if (!email) { brandToast(BRAND_MYPAGE_MSG.saveFail, { error: true }); return; }
    busy = true;
    form.querySelectorAll('input, button').forEach(el => { el.disabled = true; });
    const okBtn = form.querySelector('[data-pw="ok"]');
    okBtn.textContent = '바꾸는 중…';
    const res = await brandChangePasswordWithCurrent(email, cur.value, nw.value);
    busy = false;
    if (res === 'ok' || res === 'relogin') {
      // 「마지막 변경」 기록은 brandChangePasswordWithCurrent 가 남긴다
      cur.value = nw.value = nw2.value = '';
      close();
      if (res === 'relogin') { brandToast(BRAND_MYPAGE_MSG.pwRelogin); await brandLogout(); return; }
      brandToast(BRAND_MYPAGE_MSG.pwChanged);
      const acct = await fetchMyBrandAccount();
      if (acct) { _brandMyAccount = acct; _rerenderMypageIfShown(); }
      return;
    }
    form.querySelectorAll('input, button').forEach(el => { el.disabled = false; });
    okBtn.textContent = '변경';
    if (res === 'wrong') { setErr('brandPwCurrent', BRAND_MYPAGE_MSG.pwWrong); cur.focus(); return; }   // 새 칸 값은 그대로(01a)
    if (res === 'too_many') { setErr('brandPwCurrent', BRAND_MYPAGE_MSG.pwTooMany); cur.focus(); return; }
    if (res === 'same') { setErr('brandPwNew', BRAND_MSG.samePassword); nw.focus(); return; }
    if (res === 'weak') { setErr('brandPwNew', BRAND_MSG.weakPassword); nw.focus(); return; }
    brandToast(BRAND_MYPAGE_MSG.saveFail, { error: true });
    okBtn.focus();   // 잠그는 동안 빠진 초점을 창 안으로
  });
  document.addEventListener('keydown', onKey, true);
  document.body.appendChild(wrap);
  bindBrandCommonPwWarning('brandPwNew', BRAND_COMMON_PW_MSG_CHANGE);   // bw07-01c — 경고만, 「변경」을 막지 않는다(조각 9)
  form.querySelector('#brandPwCurrent').focus();
}
function closeBrandPasswordModal() {
  const m = document.getElementById('brandPwModal');
  if (m && m._close) m._close(); else if (m) m.remove();
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
  if (act === 'password') { openBrandPasswordModal(); return; }
  if (act === 'legal') { openLegalModal(btn.dataset.legalKind === 'privacy' ? 'privacy' : 'terms'); return; }
  if (act === 'logout') {
    _brandMySetBusy(true);
    try { await brandLogout(); } finally { _brandMySetBusy(false); }   // 실패해 화면에 남아도 단추가 잠긴 채로 두지 않는다
  }
});

// 받은 초대 줄 동의 칸 — 체크하면 그 줄의 오류를 지운다
document.addEventListener('change', (e) => {
  const c = e.target.closest('#brandPageHost [data-agree-invite]');
  if (c) _brandMyAgreeError(c.getAttribute('data-agree-invite'), '');
});

// 수정 중 엔터 = 저장
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || !e.target.matches('#brandPageHost .brand-my-input') || e.isComposing) return;
  e.preventDefault();
  if (!_brandMyBusy) saveMyBrandProfile();
});
