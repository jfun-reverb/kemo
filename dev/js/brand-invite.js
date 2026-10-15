// 브랜드 페이지 — 받은 초대 수락·거절(w01-03 · w01-10 · w01-90 · w01-92 ⑥)
//   작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 3(로그인 경로) · 조각 4(메일 링크 경로가 같은 화면을 쓴다)
//   🔴 연결된 브랜드가 없고 받은 초대만 있는 계정은 로그아웃하지 않고 이 화면으로 온다(applyBrandLoginState).
//      이때 brandAuthed 는 null(틀 페이지에 못 들어간다) — 세션만 살아 있고 이 화면의 맥락은 _brandInviteCtx 가 갖는다.

const BRAND_INVITE_MSG = {
  invalid: '이 초대는 더 이상 쓸 수 없습니다.',                               // w01-90 토스트 2
  declined: '초대를 거절했습니다.',                                          // w01-90 토스트 1
  failed: '브랜드를 연결하지 못했습니다. 잠시 후 다시 시도해 주십시오.',        // w01-92 ⑥
  later: '초대는 기한까지 메일 링크로 다시 수락할 수 있습니다.'                // w01-03 「나중에」(대기 초대만 있는 계정)
};

// 지금 보고 있는 초대 — { source:'login'|'link', invite:{invite_id, brand_id, brand_name, inviter_name, expires_at}, linkId? }
let _brandInviteCtx = null;

// 수락·거절 — respond_brand_invite 감싸기. 반환 {result, brand_id} 또는 null(호출 실패).
//   result: ok · already_member · invalid · not_brand · setup_incomplete. 마이페이지 받은 초대(조각 7)도 이 함수를 쓴다.
async function respondBrandInvite(opts) {
  const o = opts || {};
  const { data, error } = await brandRpc('respond_brand_invite', {
    p_invite_id: o.inviteId || null, p_link_id: o.linkId || null, p_action: o.action
  });
  if (error || !data || typeof data !== 'object' || !data.result) return null;
  return data;
}

// 받은 초대 목록 — 배열 또는 null(호출 실패). 0건 [] 과 실패 null 을 가른다.
async function fetchMyBrandInvites() {
  const { data, error } = await brandRpc('get_my_brand_invites');
  if (error || !Array.isArray(data)) return null;
  return data;
}

function _brandInviteMd(iso) {
  const d = new Date(iso);
  return isNaN(d.getTime()) ? '' : (d.getMonth() + 1) + '/' + d.getDate();
}

// 초대 수락 화면을 채워 보인다. 「초대받은 계정」 칸 = 지금 로그인한 계정 이메일(작업표 S0-5).
function showInviteScreen(ctx, loginEmail) {
  _brandInviteCtx = ctx;
  const inv = ctx.invite || {};
  document.getElementById('inviteDesc').textContent =
    '「' + (inv.brand_name || '') + '」 브랜드의 대표 담당자 ' + (inv.inviter_name || '') + '님이 회원님을 멤버로 초대했습니다.';
  document.getElementById('inviteEmail').value = loginEmail || '';
  setNotice('inviteResult', '');
  _setInviteBusy(false);
  history.replaceState(null, '', location.pathname + location.search + '#invite');
  paintBrandScreen('invite');
}

function _setInviteBusy(busy, label) {
  const btn = document.getElementById('inviteSubmit');
  btn.disabled = busy;
  btn.textContent = busy ? (label || '수락하는 중…') : '초대 수락';
  document.querySelectorAll('#inviteLater, #inviteDecline').forEach(el => { el.disabled = busy; });
}

// 로그인 판정이 「연결 브랜드 없음 + 수락할 초대 있음」일 때 — 로그아웃하지 않고 첫 초대를 보인다.
//   반환 true(초대 화면을 띄움) / false(초대 목록을 못 받았거나 비어 있음 — 부르는 쪽이 원래 갈래로)
async function enterInviteOnly(state) {
  const list = await fetchMyBrandInvites();
  if (!list || !list.length) return false;
  showInviteScreen({ source: 'login', invite: list[0] }, state && state.email);
  return true;
}

// 수락·거절 뒤 갈래 — 연결 브랜드 있음 = 첫 페이지 / 남은 초대 있음 = 다음 초대 / 둘 다 없음 = 로그아웃 + 「연결된 브랜드 없음」
async function _brandAfterInvite(preferBrandId) {
  _brandInviteCtx = null;
  const state = await fetchBrandLoginState();
  if (state && state.state === 'ok') { enterBrandApp(state, { preferBrandId }); return; }
  if (!state) {
    // 판정을 못 받음 — 세션은 두고 「다시 시도」 화면(새로고침 실패와 같은 처리)
    _brandCheckPending = true;
    history.replaceState(null, '', location.pathname + location.search + '#check-fail');
    paintBrandScreen('check-fail');
    return;
  }
  await applyBrandLoginState(state);
}

async function acceptCurrentInvite() {
  const ctx = _brandInviteCtx;
  if (!ctx) return;
  _setInviteBusy(true, '수락하는 중…');
  setNotice('inviteResult', '');
  const r = await respondBrandInvite({ inviteId: ctx.linkId ? null : ctx.invite.invite_id, linkId: ctx.linkId || null, action: 'accept' });
  if (!r) { _setInviteBusy(false); setNotice('inviteResult', BRAND_INVITE_MSG.failed); return; }
  if (r.result === 'ok' || r.result === 'already_member') {
    // 초대 수락 화면에서 수락하면 그 브랜드로 연다(사양서 예외 — 마지막으로 본 브랜드도 그 브랜드)
    if (r.brand_id) await brandRpc('set_my_brand_last_viewed', { p_brand_id: r.brand_id });
    await _brandAfterInvite(r.brand_id);
    return;
  }
  if (r.result === 'invalid') { brandToast(BRAND_INVITE_MSG.invalid); await _brandAfterInvite(null); return; }
  // not_brand · setup_incomplete — 계정 상태가 바뀜. 판정 갈래를 그대로 따른다
  await _brandAfterInvite(null);
}

async function declineCurrentInvite() {
  const ctx = _brandInviteCtx;
  if (!ctx) return;
  const inv = ctx.invite || {};
  const brand = inv.brand_name || '';
  const until = _brandInviteMd(inv.expires_at);
  const ok = await brandConfirm({
    title: brand + ' 브랜드 초대를 거절하시겠습니까?',
    body: '초대한 사람 ' + (inv.inviter_name || '') + '(대표 담당자)' + (until ? ' · ' + until + '까지 수락할 수 있는 초대입니다.' : '') +
      '\n거절하면 이 초대로는 ' + brand + ' 브랜드 페이지에 들어갈 수 없습니다. 다시 함께하려면 대표 담당자에게 새로 초대해 달라고 요청해 주십시오.',
    okLabel: '거절', cancelLabel: '취소', danger: true, okFirst: true   // 피그마 w01-10 「거절 · 취소」
  });
  if (!ok || _brandInviteCtx !== ctx) return;
  _setInviteBusy(true, '처리하는 중…');
  setNotice('inviteResult', '');
  const r = await respondBrandInvite({ inviteId: ctx.linkId ? null : inv.invite_id, linkId: ctx.linkId || null, action: 'decline' });
  if (!r) { _setInviteBusy(false); setNotice('inviteResult', BRAND_INVITE_MSG.failed); return; }
  if (r.result === 'ok') brandToast(BRAND_INVITE_MSG.declined);
  else if (r.result === 'invalid') brandToast(BRAND_INVITE_MSG.invalid);
  await _brandAfterInvite(null);
}

// 「나중에」 — 연결 브랜드가 있으면 첫 페이지, 대기 초대만 있는 계정이면 로그아웃 + 안내
async function laterCurrentInvite() {
  _brandInviteCtx = null;
  const state = await fetchBrandLoginState();
  if (state && state.state === 'ok') { enterBrandApp(state); return; }
  await brandSignOutLocal();
  setBrandAuthed(null);
  goBrandScreen('login');
  setNotice('loginExpiredNotice', BRAND_INVITE_MSG.later);
}

function initInvite() {
  const btn = document.getElementById('inviteSubmit');
  btn.addEventListener('click', async () => {
    if (btn.disabled) return;
    if (!_brandInviteCtx) {
      // 미리보기 막대에서 연 화면 — 서버를 부르지 않는다
      btn.disabled = true; btn.textContent = '수락하는 중…';
      await brandFakeRequest('ok');
      btn.textContent = '수락했습니다';
      setNotice('inviteResult', '미리보기: 「하루담」 브랜드가 계정에 연결됐다고 가정합니다.');
      return;
    }
    await acceptCurrentInvite();
  });
  document.getElementById('inviteDecline').addEventListener('click', async (e) => {
    if (e.currentTarget.disabled) return;
    if (!_brandInviteCtx) return;
    await declineCurrentInvite();
  });
  document.getElementById('inviteLater').addEventListener('click', async (e) => {
    if (e.currentTarget.disabled) return;
    if (!_brandInviteCtx) { goBrandScreen('login'); return; }
    await laterCurrentInvite();
  });
}

// ── 메일 링크 초대 착지 (작업표 조각 4 — 피그마 w01-08 → w01-02b(새 이메일) / w01-03(이미 브랜드 계정))
//   메일 링크: …/brand/?link=<번호>&kind=invite (notify-brand-invite). 이 링크는 일회용 인증 값이 없어 열어도 소진되지 않지만,
//   모든 메일 링크는 w01-08 「계속하기」를 거친다(피그마 공통 규칙).
//   🔴 링크 번호는 주소에서 바로 걷어 메모리와 세션 저장소(reverb.brandInviteLink — 로그인을 거치는 ⓑ 갈래·새로고침용)에만 둔다.
//      쓰면 지운다 · 로그아웃·비밀번호 찾기로 빠지면 지운다 · 로그·토스트·오류 보고에 싣지 않는다.
const BRAND_INVITE_LINK_KEY = 'reverb.brandInviteLink';
let _brandInviteLanding = null;   // { linkId, state } — w01-08 화면에 있는 동안
let _brandInviteNewCtx = null;    // { linkId, email } — w01-02b(새 이메일 멤버 설정) 화면에 있는 동안

function _saveInviteLink(linkId) { try { sessionStorage.setItem(BRAND_INVITE_LINK_KEY, linkId); } catch (e) { /* 저장소 막힘 — 메모리만 */ } }
function _readInviteLink() { try { return sessionStorage.getItem(BRAND_INVITE_LINK_KEY) || ''; } catch (e) { return ''; } }
function clearBrandInviteLink() { try { sessionStorage.removeItem(BRAND_INVITE_LINK_KEY); } catch (e) { /* 무시 */ } }

// 링크 판정 — {state, recipient, brand_name, inviter_name, issued_at, expires_at, email?} 또는 null(호출 실패)
async function fetchBrandInviteLinkState(linkId) {
  const client = brandDb;
  if (!client) return null;
  try {
    const { data, error } = await client.rpc('get_brand_invite_link_state', { p_link_id: linkId });
    if (error || !data || typeof data !== 'object' || !data.state) return null;
    return data;
  } catch (e) { return null; }
}

// 착지 — 링크를 연 것만으로는 아무것도 하지 않고 w01-08 을 보인다
async function handleBrandInviteLanding(params) {
  const linkId = params.get('link') || '';
  history.replaceState(null, '', location.pathname);   // 주소창·방문 기록에 링크 번호를 남기지 않는다
  if (!BRAND_UUID_RE.test(linkId)) { clearBrandInviteLink(); endBrandLinkFlow('link-invalid'); return; }
  const st = await fetchBrandInviteLinkState(linkId);
  if (st && st.state === 'invalid') { clearBrandInviteLink(); endBrandLinkFlow('link-invalid'); return; }
  // 호출 실패(null)는 막지 않는다 — 「계속하기」에서 다시 판정한다(일시 오류로 멀쩡한 링크를 죽이지 않게)
  _saveInviteLink(linkId);
  _brandInviteLanding = { linkId, state: st };
  const existing = st && st.recipient === 'existing';
  document.getElementById('confirmTitle').textContent = existing ? '초대를 확인하시겠습니까?' : '비밀번호를 설정하시겠습니까?';
  document.getElementById('confirmDesc').textContent = existing
    ? '아래 「계속하기」를 누르면 초대 확인 화면으로 넘어갑니다.'
    : '아래 「계속하기」를 누르면 비밀번호 설정 화면으로 넘어갑니다.';
  const btn = document.getElementById('confirmBtn');
  btn.disabled = false; btn.textContent = '계속하기';
  paintBrandScreen('confirm');
  updatePreviewVisibility();
}

// 「계속하기」 — 다시 판정해 갈래를 정한다
async function continueBrandInviteLanding() {
  const landing = _brandInviteLanding;
  if (!landing) return;
  const btn = document.getElementById('confirmBtn');
  btn.disabled = true; btn.textContent = '확인하는 중…';
  const st = await fetchBrandInviteLinkState(landing.linkId);
  btn.disabled = false; btn.textContent = '계속하기';
  if (!st) { brandToast('링크를 확인하지 못했습니다. 잠시 후 다시 시도해 주십시오.'); return; }
  _brandInviteLanding = null;
  if (st.state !== 'valid') { clearBrandInviteLink(); endBrandLinkFlow('link-invalid'); return; }
  if (st.recipient === 'new') { showInviteNewSetpw(landing.linkId, st); return; }
  // ⓑ 이미 브랜드 계정 — 이 브라우저에 로그인돼 있으면 바로 초대 화면, 아니면 로그인 뒤 돌아온다
  const shown = await resumeBrandInviteLink();
  if (!shown) {
    goBrandScreen('login');
    setNotice('loginExpiredNotice', '초대를 수락하려면 로그인해 주십시오.');
  }
}

// 로그인된 세션이 있고 보관한 초대 링크가 있으면 w01-03 을 링크 번호로 띄운다. 반환 true(띄움) / false
async function resumeBrandInviteLink() {
  const linkId = _readInviteLink();
  if (!linkId || !brandDb) return false;
  let session = null;
  try { const { data } = await brandDb.auth.getSession(); session = data && data.session; } catch (e) { session = null; }
  if (!session) return false;
  const st = await fetchBrandInviteLinkState(linkId);
  clearBrandInviteLink();   // 쓰면 지운다
  if (!st || st.state !== 'valid') { brandToast(BRAND_INVITE_MSG.invalid); return false; }
  if (st.recipient !== 'existing') return false;
  // 로그인 판정이 ok 로 세워 둔 상태를 내린다 — 초대 화면에서 주소가 바뀌면 routeBrand 의 초대 정리 분기가 돌게
  setBrandAuthed(null);
  showInviteScreen({ source: 'link', linkId, invite: {
    brand_name: st.brand_name, inviter_name: st.inviter_name, issued_at: st.issued_at, expires_at: st.expires_at
  } }, (session.user && session.user.email) || '');
  return true;
}

// ⓐ 새 이메일 — w01-02b 비밀번호 설정(이름 필수 · 연락처 선택 · 약관 동의)
function showInviteNewSetpw(linkId, st) {
  _brandInviteNewCtx = { linkId, email: st.email || '' };
  document.querySelectorAll('#setpwForm [data-member-only]').forEach(el => { el.hidden = false; });
  resetSetpwForm();
  document.getElementById('setpwDesc').textContent =
    '「' + (st.brand_name || '') + '」 브랜드의 ' + (st.inviter_name || '') + '님이 회원님을 멤버로 초대했습니다. 이름과 비밀번호를 정하면 바로 시작할 수 있습니다.';
  // 이메일 칸 — 피그마 w01-02b 읽기 전용(작업표 S0-2). 서버가 이메일을 안 주면(534 전) 칸을 숨긴다
  const emailInput = document.getElementById('setpwEmail');
  emailInput.value = st.email || '';
  emailInput.closest('.brand-field').hidden = !st.email;
  paintBrandScreen('setpw');
  updatePreviewVisibility();
}

function endBrandInviteNew() {
  _brandInviteNewCtx = null;
  const f = document.getElementById('setpwEmail');
  if (f) f.closest('.brand-field').hidden = false;
}

// 새 이메일 멤버 — 계정 만들기(서버 함수) → 그 이메일·비밀번호로 로그인 → 그 브랜드 첫 페이지
async function submitInviteNew(pw) {
  const ctx = _brandInviteNewCtx;
  const name = document.getElementById('setpwName').value.trim();
  const phone = document.getElementById('setpwPhone').value.trim();
  const r = await brandCallFunction('brand-invite-accept', {
    link_id: ctx.linkId, password: pw, name, phone, terms_version: BRAND_TERMS_VERSION
  });
  const body = r.body || {};
  if (r.status === 200 && body.ok === false && body.reason === 'invalid_link') {
    clearBrandInviteLink(); endBrandInviteNew(); endBrandLinkFlow('link-invalid'); return;
  }
  if (r.status === 200 && body.ok === false && body.reason === 'password_rejected') {
    setFieldError('setpwPw', BRAND_MSG.weakPassword); document.getElementById('setpwPw').focus(); return;
  }
  if (!(r.status === 200 && body.ok === true && body.email)) {
    // 400·500·연결 끊김 — 같은 화면에 남는다(같은 링크로 다시 누르면 서버가 같은 계정을 이어서 쓴다)
    setNotice('setpwResult', BRAND_MSG.setupFinishFail); return;
  }
  clearBrandInviteLink();
  endBrandInviteNew();
  resetSetpwForm();   // 비밀번호 원문을 입력 칸에 남기지 않는다
  // 이 브라우저에 다른 브랜드 세션이 있으면 먼저 정리하고 새 계정으로 로그인
  await brandSignOutLocal();
  let signErr = null;
  try {
    const { error } = await brandDb.auth.signInWithPassword({ email: body.email, password: pw });
    signErr = error;
  } catch (ex) { signErr = ex || new Error('sign_in_failed'); }
  if (signErr) {
    goBrandScreen('login');
    document.getElementById('loginEmail').value = body.email;
    setNotice('loginExpiredNotice', BRAND_MSG.setupDoneRelogin);
    return;
  }
  const state = await fetchBrandLoginState();
  const res = await applyBrandLoginState(state);
  if (res === 'ok') enterBrandApp(state);
}
